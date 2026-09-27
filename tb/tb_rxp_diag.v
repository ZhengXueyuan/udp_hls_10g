`timescale 1ns/1ps
//=============================================================================
// tb_rxp_diag.v — RXP_DIAG 首失配快照的**仪器自检门** (ISSUE_RX_BYTE_CORRUPTION)
//
// 为什么要这条门: 诊断位流的价值全押在"快照字段到底对不对"上。仪器若把 idx/
// got/exp/prev 打偏一拍或漏采, 板级读数会被当成机制证据 ⇒ 必须先自证。
//
// 相位 (同一 TB, 相位间复位; 注入在**图案数组**上做, 故 lane 可任选):
//   相 1  干净, 背靠背           ⇒ 零失配 / ds_v=0 / 全部计数与桶为 0
//   相 2  **两处**注入, 背靠背   ⇒ idx 必须指**第一处**(100) 而不是最后一处;
//        BA==2 (两处都是单比特) ⇒ 「首个而非任意一个」+ 形状分类
//   相 3  **隔帧**注入 + 注入点落在**气泡后第一个字节**(lane 0) ⇒ prev 必须是
//        上一字节。**专测 ds_prev_exp 的门控**: 若它无条件跟拍, 引擎在帧间/空拍
//        停后读到的 prev 会等于 exp (独立审查 agent 用隔帧 TB 复现过), 而
//        udp_split 的播放器是帧级 store-and-forward ⇒ **每帧首字节必然踩洞**。
//
// v2 (2026-09-26) 追加的三个被测对象 (诊断位流升级: 单字节指纹 + 位置桶):
//   ① **整字指纹** ds_gw/ds_ew (首失配所在 64 位收字/期望字, 同字边界对齐):
//      相 2~6 每相都断言 ds_gw == 实际喂出的整字 (含该字内全部注入 lane)、
//      ds_ew == 干净图案整字, 且与 v1 字段自洽 —— ds_gw/ds_ew 在**失配 lane**
//      上的字节必须逐位等于 ds_got/ds_exp, 且 ds_gw^ds_ew 的**最低非零 lane**
//      就是首失配 lane。相 2 (lane 4) / 相 5 (lane 5) 特意把失配放在**字中**:
//      若期望字被写成"从 ds_idx 起的 8 个期望字节", 这两相必红 (整个期望字平移
//      出该字 ⇒ 失配 lane 上的字节不再是 ds_exp)。
//   ② **帧内偏移桶** OZ/OL/OM/OH: 相 4 专打**四个桶的全部边界**
//      (偏移 0 / 1 / 7 / 8 / 63 / 64, 用 i_paylen=128)。相 5 (帧长 40 != i_paylen
//      64) 是**判别性**用例: 「全局取模」的实现会把帧首字节判成 OM, 而"SOF 与数据
//      同管线、帧首字节拍复位"的实现判成 OZ ⇒ **这一相才是对齐的证明**。
//      相 6 (帧长 128 > i_paylen 64) 钉死 mod i_paylen 的环绕语义 (不环绕 ⇒ 全落 OH)。
//   ③ 每相断言两条恒等式: BA+BB+BC == UMM (形状划分) 与 OZ+OL+OM+OH == UMM
//      (位置划分)。它们把"漏计/重复计"变成一条硬判据。
//   相 7  **状态行格式门**: RXP_DIAG 的**字符布局** (ci 窗口) 是整套仪器里唯一
//     靠算偏移得来、又不会被任何功能仿真自然覆盖的部分 —— 9600 波特下一行要
//      ~170ms, 而全链门只跑 ~10ms ⇒ 板级之前发出去的整行**从没被仿真逐字符验证过**。
//      这里用短位周期 (7 拍/位) 让 app_status_uart 真发完一行, 逐字符解码后断言:
//      ① 行恰 971 字符 (CR/LF 在 969/970; v1/v2 时是 470 / 468·469, v3 时是
//         637 / 635·636, v4 时是 807 / 805·806, v5 时是 916 / 914·915 ——
//         沿革见 rtl/app_status_uart.v 的 TPL 段注释);
//      ② v1/v2/v3/v4/v5 既有字段在**发布偏移**上仍然正确 (前 916 字符不动);
//      ③ v2 新字段 GW/EW/OZ/OL/OM/OH、v3 新字段 SW..VN、**v4 新字段 CN..QH**、
//         **v5 新字段 DV..SB**、**v6 新字段 CV..CS** 的偏移与宽度正确 —— 每个
//         字段的输入值取互相可区分的图案 ⇒ 字段串位/串宽/漏字符必然红。
//      ⚠️ v4 段的 20 个字段全部逐值断言 (偏移由 sim/rxpdiag/gen_offsets.py
//        拼接 TPL 串算出, 该脚本还会**直接读 rtl/app_status_uart.v** 解码窗口
//        逐条对账; 本相则是"实跑出来的那一行"的独立复核)。
//
// 运行: sim/rxpdiag/run_tb_rxp_diag.bat (独立目录, 防 xsim.dir 文件锁 — 坑 7)
//=============================================================================
module tb_rxp_diag;

    reg clk = 1'b0, rst_n = 1'b1;
    always #4 clk = ~clk;                       // 125 MHz

    // 载荷数组上界 = 各相最大全局字节数 (相 4: 3 帧 x 128 = 384)
    localparam NBMAX = 384;

    function [63:0] xs_next;
        input [63:0] s;
        reg   [63:0] t;
        begin
            t = s ^ (s << 13);
            t = t ^ (t >> 7);
            t = t ^ (t << 17);
            xs_next = t;
        end
    endfunction

    reg [7:0] pay  [0:NBMAX+15];                // 干净图案 (期望值来源)
    reg [7:0] payc [0:NBMAX+15];                // 本相实际喂出的图案
    integer   k;
    reg [63:0] st;
    initial begin
        st = 64'h9E3779B97F4A7C15;
        for (k = 0; k <= NBMAX+15; k = k + 1) begin
            pay[k] = st[31:24];                 // 先取后推进 (与 RTL/peer 同款)
            st = xs_next(st);
        end
    end

    // ---- 帧几何 (每相设置; 声明必须在用之前 —— xvlog 先声明后用) ----
    // plen_v   = TB 喂出的**帧长**(字节)      paylen_v = DUT 的 i_paylen 端口
    // fw_v     = 帧长(字)                     nw_v     = 总字数
    // nbyte_v  = 总字节数                     nfrm_v   = 帧数
    reg [15:0] plen_v, paylen_v, fw_v, nw_v, nbyte_v, nfrm_v;

    task build_payload;                          // 清干净 (只保留待注入的图案)
        begin
            for (k = 0; k <= NBMAX+15; k = k + 1) payc[k] = pay[k];
        end
    endtask

    task inject;                                 // 在图案数组上注入 (lane 任选)
        input [15:0] a;
        input [7:0]  m;
        begin
            payc[a] = pay[a] ^ m;
        end
    endtask

    reg  [15:0] wi;                              // 已装载字数
    reg  [15:0] fwi;                             // 帧内字数 (0 = 本帧首字)
    reg         gap_en  = 1'b0;
    reg  [15:0] gap_cnt = 16'd0;
    localparam  GAPLEN  = 5;

    // 每载入一个字就停 GAPLEN 拍 (模拟帧级 store-and-forward 的帧间空隙)
    // 顺序: gap_cnt(寄存器) -> gap_run -> rx_tvalid -> rx_ld -> 两个时序块。组合环不存在
    // (gap_run 来自寄存器), 但 xvlog 要求逐个先声明后用, 故顺序不能动。
    wire       gap_run   = (gap_cnt != 16'd0);
    // 本字有效 lane 数 (帧末字可 < 8) —— 必须在按 nv16 索引的线之前
    wire [15:0] nv16 = (fwi == (fw_v - 16'd1))
                       ? (plen_v - 16'd8 * (fw_v - 16'd1)) : 16'd8;
    // ⚠️ 索引必须按**已交付字节数** dbyte 走, 不能按 8*wi: 帧末字是部分字时,
    //    8*wi 会让每帧"吞掉" (8-nv) 个图案字节 ⇒ 交付流出现空洞 ⇒ DUT 正确地报出
    //    大量失配 (实测 mm=180), 看起来像 DUT 坏 —— 其实是 TB 的模型错。
    //    满字时 dbyte == 8*wi, 故既有相位行为不变。
    reg  [15:0] dbyte;                           // 已交付字节数
    wire [7:0] c0=(16'd0<nv16)?payc[dbyte+16'd0]:8'h00;
    wire [7:0] c1=(16'd1<nv16)?payc[dbyte+16'd1]:8'h00;
    wire [7:0] c2=(16'd2<nv16)?payc[dbyte+16'd2]:8'h00;
    wire [7:0] c3=(16'd3<nv16)?payc[dbyte+16'd3]:8'h00;
    wire [7:0] c4=(16'd4<nv16)?payc[dbyte+16'd4]:8'h00;
    wire [7:0] c5=(16'd5<nv16)?payc[dbyte+16'd5]:8'h00;
    wire [7:0] c6=(16'd6<nv16)?payc[dbyte+16'd6]:8'h00;
    wire [7:0] c7=(16'd7<nv16)?payc[dbyte+16'd7]:8'h00;
    wire [63:0] rx_tdata = {c0, c1, c2, c3, c4, c5, c6, c7};
    wire        rx_tvalid = (wi < nw_v) && !gap_run;
    // 本字有效 lane 数: 帧末字可能 < 8 字节 (帧长非 8 的倍数) ⇒ tkeep 左对齐
    // ⚠️ 这一条是独立审查指出的**门覆盖漏洞**: 原来 rx_tkeep 恒 8'hFF, 于是
    //    RTL 的 lane 掩码 (无效 lane 清 0) 从未被激励 —— 审查实测"去掉掩码"和
    //    "期望字 lane 平移 +1" 两个变异都能让本门**保持全绿**。加相位 P8 堵上。
    wire [7:0]  rx_tkeep = (nv16 >= 16'd8) ? 8'hFF
                         : (8'hFF << (4'd8 - nv16[3:0]));
    // tlast/sof/len 一律由帧几何导出 (相 5/6 的帧长 != i_paylen, 故不能用常量)
    wire        rx_tlast = (fwi == (fw_v - 16'd1));
    wire        rx_sof   = (fwi == 16'd0) && (wi < nw_v);
    wire [15:0] rx_len   = plen_v;
    wire        rx_tready;
    wire        rx_ld    = rx_tvalid && rx_tready;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)      dbyte <= 16'd0;
        else if (rx_ld)  dbyte <= dbyte + nv16;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)               gap_cnt <= 16'd0;
        else if (rx_ld && gap_en) gap_cnt <= GAPLEN;
        else if (gap_cnt != 16'd0) gap_cnt <= gap_cnt - 16'd1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) wi <= 16'd0;
        else if (rx_ld) wi <= wi + 16'd1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) fwi <= 16'd0;
        else if (rx_ld) begin
            if (fwi == (fw_v - 16'd1)) fwi <= 16'd0;
            else                       fwi <= fwi + 16'd1;
        end
    end

    wire [31:0] ds_idx, ds_b1, ds_b2, ds_bg, ds_dup;
    wire [7:0]  ds_got, ds_exp, ds_prev;
    wire        ds_v;
    wire [63:0] ds_gw, ds_ew;
    wire [31:0] ds_oz, ds_ol, ds_om, ds_oh;
    wire [31:0] st_rx_bytes, st_rx_frames, st_rx_null, st_mismatch;
    wire        m_tvalid;

    // ---- 相 7: 状态行格式门用的**常量**输入 (互相可区分 ⇒ 字段错位必红) ----
    // 刻意不与上面 DUT 的输出相连: 这一相测的是**行的布局** (偏移/宽度/字符集),
    // 不是 DUT 数据通路 (那条由相 1..6 各自断言)。
    reg [3:0]  st_st;
    reg [31:0] st_nx, st_ua, st_rn, st_rx, st_tx;
    reg [15:0] st_rw, st_tf, st_mm, st_ev, st_dp, st_ry, st_ec;
    reg [15:0] st_dl, st_fi, st_rs;
    reg [16:0] st_oc, st_po;
    reg [15:0] st_ak, st_ad, st_wq, st_wm, st_wu, st_px;
    reg [2:0]  st_ts;
    reg [31:0] st_urb, st_umm, st_utb;
    reg [15:0] st_urf, st_uov, st_upc, st_upa, st_utf;
    reg [31:0] st_ii, st_ba, st_bb, st_bc, st_dd;
    reg [7:0]  st_gg, st_ee, st_pp;
    reg [63:0] st_gw, st_ew;
    reg [31:0] st_oz, st_ol, st_om, st_oh;
    // v3 (phase 7): frame-boundary accounting fields, constant inputs
    // (all values mutually distinguishable -> a field shifted / mis-width fails)
    reg [63:0] st_sw;
    reg [8:0]  st_sf;
    reg        st_sm;
    reg [7:0]  st_wd;
    reg [9:0]  st_fr, st_fw, st_fo, st_fh;
    reg [1:0]  st_fs;
    reg [15:0] st_fn;
    reg [9:0]  st_pr, st_pw, st_ph;
    reg [9:0]  st_lr, st_lw, st_lo, st_lh;
    reg [15:0] st_rc, st_vc;
    reg [9:0]  st_vx, st_vs, st_vr;
    reg [15:0] st_vn;
    // v4 (phase 7): exception-path counters + run structure / event FIFO
    // (constant inputs, mutually distinguishable -> a shifted or mis-widthed
    //  field cannot decode back to the expected value)
    reg [15:0] st_cn, st_rd, st_nc, st_np, st_wf, st_rl, st_wc;
    reg [15:0] st_ne, st_nr, st_mr;
    reg [3:0]  st_en;
    reg        st_eo;
    reg [23:0] st_qa, st_qb, st_qc, st_qd, st_qe, st_qf, st_qg, st_qh;
    // v5 (phase 7): write-side LFSR checker (udp_split) + parser counters (udp_rx)
    // (constant inputs, mutually distinguishable -> a shifted or mis-widthed
    //  field cannot decode back to the expected value)
    reg [31:0] st_dv, st_dm, st_ps, st_nm, st_ic, st_dc, st_sb;
    reg [7:0]  st_dg, st_de;
    reg [15:0] st_do;
    reg        st_vz;
    // v6 (phase 7): u_pre INPUT-PORT-SIDE LFSR checker (udp_split v6_*)
    reg [31:0] st_cv, st_cm;
    reg [7:0]  st_cg, st_ce, st_cs;
    reg [15:0] st_co;
    reg        st_cz;

    // 状态行 DUT 的复位与主 DUT **独立** (不然每相复位都会重发行, 解码器要跟着
    // 重对齐); 位周期 7 拍 (BIT_LAST=6) 只为把 470 字符的行在 ~263us 内跑完。
    reg  rst_s = 1'b0;
    localparam integer SBIT = 6;                 // 位周期 = SBIT+1 拍
    wire st_txd;

    app_status_uart #(.BIT_LAST(SBIT), .GAP_TICKS(28'd50)) u_st (
        .clk(clk), .rst_n(rst_s),
        .st0(st_st),
        .snd_nxt(st_nx), .snd_una(st_ua), .rcv_wnd(st_rw), .rcv_nxt(st_rn),
        .stat_rx_bytes(st_rx), .stat_tx_bytes(st_tx),
        .stat_tx_frames(st_tf), .stat_mismatch(st_mm),
        .rx_occ(st_oc), .ev_cnt(st_ev), .ev_drop(st_dp),
        .app_tx_ready(st_ry), .estab_cnt(st_ec),
        .stat_drop_len(st_dl), .stat_fin(st_fi), .stat_rst(st_rs),
        .stat_ack(st_ak), .stat_ack_drop(st_ad), .fsm_state(st_ts),
        .winq0(st_wq), .wu_mark0(st_wm), .stat_wu(st_wu), .pool(st_po),
        .stat_pool_exh(st_px),
        .udp_rx_bytes(st_urb), .udp_mismatch(st_umm), .udp_rx_frames(st_urf),
        .udp_drop_ovf(st_uov), .udp_drop_crc(st_upc), .udp_drop_part(st_upa),
        .udp_tx_bytes(st_utb), .udp_tx_frames(st_utf),
        .ds_idx(st_ii), .ds_b1(st_ba), .ds_b2(st_bb), .ds_bg(st_bc),
        .ds_dup(st_dd), .ds_got(st_gg), .ds_exp(st_ee), .ds_prev(st_pp),
        .ds_gw(st_gw), .ds_ew(st_ew),
        .ds_oz(st_oz), .ds_ol(st_ol), .ds_om(st_om), .ds_oh(st_oh),
        .v3_sw(st_sw), .v3_sf(st_sf), .v3_sm(st_sm), .v3_wd(st_wd),
        .v3_fr(st_fr), .v3_fw(st_fw), .v3_fo(st_fo), .v3_fh(st_fh),
        .v3_fs(st_fs), .v3_fn(st_fn),
        .v3_pr(st_pr), .v3_pw(st_pw), .v3_ph(st_ph),
        .v3_lr(st_lr), .v3_lw(st_lw), .v3_lo(st_lo), .v3_lh(st_lh),
        .v3_rc(st_rc), .v3_vc(st_vc),
        .v3_vx(st_vx), .v3_vs(st_vs), .v3_vr(st_vr), .v3_vn(st_vn),
        .v4_cn(st_cn), .v4_rd(st_rd), .v4_nc(st_nc), .v4_np(st_np),
        .v4_wf(st_wf), .v4_rl(st_rl), .v4_wc(st_wc),
        .v4_ne(st_ne), .v4_nr(st_nr), .v4_mr(st_mr),
        .v4_en(st_en), .v4_eo(st_eo),
        .v4_qa(st_qa), .v4_qb(st_qb), .v4_qc(st_qc), .v4_qd(st_qd),
        .v4_qe(st_qe), .v4_qf(st_qf), .v4_qg(st_qg), .v4_qh(st_qh),
        .v5_dv_idx(st_dv), .v5_dv_got(st_dg), .v5_dv_exp(st_de),
        .v5_dv_off(st_do), .v5_dv_mm(st_dm), .v5_dv_v(st_vz),
        .v5_up_pass(st_ps), .v5_up_nm(st_nm), .v5_up_ipc(st_ic),
        .v5_up_crc(st_dc), .v5_up_bytes(st_sb),
        .v6_dv_idx(st_cv), .v6_dv_got(st_cg), .v6_dv_exp(st_ce),
        .v6_dv_off(st_co), .v6_dv_mm(st_cm), .v6_dv_v(st_cz),
        .v6_dv_sk(st_cs),
        .txd(st_txd)
    );

    initial begin                                // 相 7 常量 (时刻 0 一次固化)
        st_st = 4'h1;
        st_nx = 32'h12345679; st_ua = 32'h12345678; st_rn = 32'h20000065;
        st_rw = 16'hC000;
        st_rx = 32'h00001234; st_tx = 32'h0056789A;
        st_tf = 16'h0123; st_mm = 16'h0007;
        st_oc = 17'h1ABCD; st_ev = 16'h0003; st_dp = 16'h0001;
        st_ry = 16'h8001; st_ec = 16'h0002;
        st_dl = 16'h0003; st_fi = 16'h0001; st_rs = 16'h0000;
        st_ak = 16'hBEEF; st_ad = 16'h00CD; st_ts = 3'd5;
        st_wq = 16'hC000; st_wm = 16'h6035; st_wu = 16'h0011;
        st_po = 17'h1C0DE; st_px = 16'h0009;
        st_urb = 32'h00ABCDEF; st_umm = 32'h00000047; st_utb = 32'h12345678;
        st_urf = 16'h05DC; st_uov = 16'h000A; st_upc = 16'h0002;
        st_upa = 16'h0001;  st_utf = 16'h0BB8;
        st_ii = 32'h00003039;
        st_ba = 32'h00000001; st_bb = 32'h00000002;
        st_bc = 32'h00000003; st_dd = 32'h00000004;
        st_gg = 8'h5F; st_ee = 8'h1A; st_pp = 8'hC3;
        st_gw = 64'h0123456789ABCDEF;              // 16 位 hex, 与其它字段全不同
        st_ew = 64'hFEDCBA9876543210;
        st_oz = 32'h0BADF00D; st_ol = 32'h00000007;
        st_om = 32'h12345678; st_oh = 32'hDEADBEEF;
        // v3: a 10-bit value shown in a 3-hex window always starts with 0..3
        // (that leading digit is itself a check on the left-alignment window)
        st_sw = 64'hA1B2C3D4E5F60718;
        st_sf = 9'h1AB;  st_sm = 1'b1;    st_wd = 8'h5A;
        st_fr = 10'h0F3; st_fw = 10'h1E7; st_fo = 10'h0F4; st_fh = 10'h0B8;
        st_fs = 2'd2;    st_fn = 16'h0123;
        st_pr = 10'h04F; st_pw = 10'h143; st_ph = 10'h0B8;
        st_lr = 10'h0BF; st_lw = 10'h1F3; st_lo = 10'h134; st_lh = 10'h07A;
        st_rc = 16'h0009; st_vc = 16'h0001;
        st_vx = 10'h0B8; st_vs = 10'h04F; st_vr = 10'h0BF; st_vn = 16'h0123;
        // v4: every field gets a DIFFERENT value (a shifted / mis-widthed window
        // cannot decode back to it). 16-bit fields: 4 hex each; EN: 1 hex;
        // EO: 1 hex; QA..QH: 6 hex each (= 24 bits).
        st_cn = 16'h0055; st_rd = 16'h00AA; st_nc = 16'h00F0; st_np = 16'h000F;
        st_wf = 16'h1234; st_rl = 16'h4321; st_wc = 16'h00C3;
        st_ne = 16'h0BEE; st_nr = 16'h0CAF; st_mr = 16'h0999;
        st_en = 4'h8;     st_eo = 1'b1;
        st_qa = 24'h0001C5; st_qb = 24'h0002D6; st_qc = 24'h0003E7;
        st_qd = 24'h0004F8; st_qe = 24'h000509; st_qf = 24'h00061A;
        st_qg = 24'h00072B; st_qh = 24'h00083C;
        // v5: 11 fields, all values pairwise distinct and != every v4 value
        // (DV/DM/PS/NM/IC/DC/SB: 8 hex; DG/DE: 2 hex; DO: 4 hex; VZ: 1 hex)
        st_dv = 32'h0A0B0C0D; st_dg = 8'hD3; st_de = 8'h7E; st_do = 16'h0F5A;
        st_dm = 32'h00C0FFEE; st_vz = 1'b1;
        st_ps = 32'h00123456; st_nm = 32'h00ABCDEF; st_ic = 32'h0000BEEF;
        st_dc = 32'h0ADD1E55; st_sb = 32'hCAFEF00D;
        // v6: 7 fields, all values pairwise distinct and != every v4/v5 value
        // (CV/CM: 8 hex; CG/CE/CS: 2 hex; CO: 4 hex; CZ: 1 hex)
        st_cv = 32'h0F1E2D3C; st_cg = 8'hB7; st_ce = 8'h4E; st_co = 16'h3A5C;
        st_cm = 32'h00FACADE; st_cz = 1'b1;  st_cs = 8'h6B;
    end

    // v4 观测口 (A 部在 udp_split 里, 本 TB 不例化它; B 部在这里)
    wire [15:0] v4_ne, v4_nr, v4_mr;
    wire [3:0]  v4_en;
    wire        v4_eo;
    wire [23:0] v4_qa, v4_qb, v4_qc, v4_qd, v4_qe, v4_qf, v4_qg, v4_qh;

    app_udp_pattern #(.TX_BYTES(32'd0), .TX_GAP(16'd0), .SEED(64'h9E3779B97F4A7C15)) u_dut (
        .clk(clk), .rst_n(rst_n),
        .i_en(1'b1), .i_tx_ready(1'b0), .i_paylen(paylen_v[11:0]),
        .m_tdata(), .m_tkeep(), .m_tvalid(m_tvalid), .m_tready(1'b0), .m_tlast(),
        .rx_tdata(rx_tdata), .rx_tkeep(rx_tkeep), .rx_tvalid(rx_tvalid),
        .rx_tready(rx_tready), .rx_tlast(rx_tlast), .rx_sof(rx_sof), .rx_len(rx_len),
        .stat_tx_bytes(), .stat_tx_frames(), .stat_rx_bytes(st_rx_bytes),
        .stat_rx_frames(st_rx_frames), .stat_rx_null(st_rx_null),
        .stat_mismatch(st_mismatch), .active(), .done(), .led(),
        .ds_idx(ds_idx),
        .ds_b1(ds_b1), .ds_b2(ds_b2), .ds_bg(ds_bg), .ds_dup(ds_dup),
        .ds_got(ds_got), .ds_exp(ds_exp), .ds_prev(ds_prev), .ds_v(ds_v),
        .ds_gw(ds_gw), .ds_ew(ds_ew),
        .ds_oz(ds_oz), .ds_ol(ds_ol), .ds_om(ds_om), .ds_oh(ds_oh)
`ifdef RXP_DIAG
        , .v4_ne(v4_ne), .v4_nr(v4_nr), .v4_mr(v4_mr),
        .v4_en(v4_en), .v4_eo(v4_eo),
        .v4_ea(v4_qa), .v4_eb(v4_qb), .v4_ec(v4_qc), .v4_ed(v4_qd),
        .v4_ee(v4_qe), .v4_ef(v4_qf), .v4_eg(v4_qg), .v4_eh(v4_qh)
`endif
    );

    // 复位: **只在 negedge 翻转 rst_n** (0 延迟竞争 —— 坑 17 同族)。若在任意时刻翻转,
    // 解除复位那一拍的 rx_ld 会在 DUT 与 TB 两侧算出不同值 ⇒ TB 的 wi 少加 1 ⇒
    // DUT 把第 0 个字收两次 (实测: idx=8 处 got=pay[0] 而 exp=pay[8])。
    task do_reset;
        begin
            @(negedge clk); rst_n = 1'b0;
            repeat (10) @(posedge clk);
            @(negedge clk); rst_n = 1'b1;
        end
    endtask

    task run_phase;                              // 跑到喂完 + 静置
        begin
            do_reset;
            wait (wi == nw_v);
            repeat (300) @(posedge clk);
        end
    endtask

    integer fail = 0;
    task chk;
        input         cond;
        input [255:0] name;
        begin
            // v3 附注: 必须判 X (`!==`) —— `if (!cond)` 会把 X 当"通过", 实测在
            // "写侧采集打死"的变异下让门保持全绿 (v3 门踩过同一个坑并已修)。
            if (cond !== 1'b1) begin
                fail = fail + 1;
                $display("  FAIL: %0s", name);
            end
        end
    endtask

    // ---- v2 判据 (整字 + 偏移桶) ----
    // 干净图案的 8 字节整字 (lane0 = 最高字节 = tdata[63:56], 同 RTL 的 byte_at)
    function [63:0] w_exp;
        input [15:0] base;
        begin
            w_exp = {pay[base+0], pay[base+1], pay[base+2], pay[base+3],
                     pay[base+4], pay[base+5], pay[base+6], pay[base+7]};
        end
    endfunction
    function [63:0] w_got;                       // 实际喂出的整字 (含全部注入)
        input [15:0] base;
        begin
            w_got = {payc[base+0], payc[base+1], payc[base+2], payc[base+3],
                     payc[base+4], payc[base+5], payc[base+6], payc[base+7]};
        end
    endfunction
    function [7:0] lane8;                        // lane i 的字节 (lane0 = [63:56])
        input [63:0] v;
        input [3:0]  i;
        begin
            case (i)
                4'd0: lane8 = v[63:56];
                4'd1: lane8 = v[55:48];
                4'd2: lane8 = v[47:40];
                4'd3: lane8 = v[39:32];
                4'd4: lane8 = v[31:24];
                4'd5: lane8 = v[23:16];
                4'd6: lane8 = v[15:8];
                default: lane8 = v[7:0];
            endcase
        end
    endfunction
    function [3:0] lowlane;                      // 最低非零 byte lane (全零 -> 7)
        input [63:0] v;
        begin
            if      (v[63:56] !== 8'd0) lowlane = 4'd0;
            else if (v[55:48] !== 8'd0) lowlane = 4'd1;
            else if (v[47:40] !== 8'd0) lowlane = 4'd2;
            else if (v[39:32] !== 8'd0) lowlane = 4'd3;
            else if (v[31:24] !== 8'd0) lowlane = 4'd4;
            else if (v[23:16] !== 8'd0) lowlane = 4'd5;
            else if (v[15:8]  !== 8'd0) lowlane = 4'd6;
            else                        lowlane = 4'd7;
        end
    endfunction

    // 整字快照判据: base = 收到字 lane0 的全局字节号 (= ds_idx - lane), ln = 失配 lane
    task chk_word;
        input [15:0] ph;
        input [15:0] base;
        input [3:0]  ln;
        begin
            if (ds_gw !== w_got(base)) begin
                fail = fail + 1;
                $display("  FAIL: P%0d ds_gw != 该字实际喂出的整字 (base=%0d) got=%016X want=%016X",
                         ph, base, ds_gw, w_got(base));
            end
            if (ds_ew !== w_exp(base)) begin
                fail = fail + 1;
                $display("  FAIL: P%0d ds_ew != 干净图案整字 (base=%0d) got=%016X want=%016X",
                         ph, base, ds_ew, w_exp(base));
            end
            if (lane8(ds_gw, ln) !== ds_got) begin
                fail = fail + 1;
                $display("  FAIL: P%0d ds_gw lane%0d = %02X != ds_got %02X (整字/单字节错位)",
                         ph, ln, lane8(ds_gw, ln), ds_got);
            end
            if (lane8(ds_ew, ln) !== ds_exp) begin
                fail = fail + 1;
                $display("  FAIL: P%0d ds_ew lane%0d = %02X != ds_exp %02X (期望字并未按收字边界对齐!)",
                         ph, ln, lane8(ds_ew, ln), ds_exp);
            end
            if (lowlane(ds_gw ^ ds_ew) !== ln) begin
                fail = fail + 1;
                $display("  FAIL: P%0d ds_gw^ds_ew 最低非零 lane = %0d != 首失配 lane %0d",
                         ph, lowlane(ds_gw ^ ds_ew), ln);
            end
        end
    endtask

    task chk_bk;                                 // 偏移桶逐值比对
        input [15:0] ph;
        input [31:0] eo, el, em, eh;
        begin
            if (ds_oz !== eo || ds_ol !== el || ds_om !== em || ds_oh !== eh) begin
                fail = fail + 1;
                $display("  FAIL: P%0d 偏移桶 OZ/OL/OM/OH = %0d/%0d/%0d/%0d 期望 %0d/%0d/%0d/%0d",
                         ph, ds_oz, ds_ol, ds_om, ds_oh, eo, el, em, eh);
            end
        end
    endtask

    // ===================== 相 7: 状态行逐字符解码 =====================
    // (这三个状态声明必须在 task 之前 —— xvlog 先声明后用, 坑 22)
    reg [7:0] line [0:1023];              // v6: line is 971 chars (> 512)
    integer   nchar;
    integer   dec_i;
    integer   jj;
    reg       line_done = 1'b0;

    // 收一个字节: 进入时 start 沿刚发生 (txd 已低)。**逐字符靠 start 沿重对齐**
    // (不靠位周期累加): 少算 1 拍会累积漂移, 几字符后整体错一位 (tb_p5_status 实测)。
    task get_byte;
        output [7:0] b;
        integer kk;
        begin
            // 1.5 位周期 -> d0 中点 (位周期 = SBIT+1 拍, 起点 = start 沿)
            repeat (SBIT+1 + (SBIT+1)/2) @(posedge clk);
            for (kk = 0; kk < 8; kk = kk + 1) begin
                b[kk] = st_txd;
                repeat (SBIT+1) @(posedge clk);
            end
            // 此刻在 d7 尾 (10+7*8 = 66 拍), 停位 = [63,70) —— **就地查**。
            // ⚠️ 不能再等 1 个位周期: board/uart_dbg.v 的 uart_tx_9600 在停位整周期
            // 发完那一拍拉低 busy, 下一拍 uart_go 才取新字节 ⇒ **字符周期 = 10 位 + 1 拍**
            // (BIT_LAST=6 时实测停位沿在 +71 拍, 与 txd 边沿探测一致)。等 7 拍就去
            // 下一字符的 start 位里了 (读回 0)，而且会**错过下一字符的 start 沿** ⇒
            // 整行从第 2 个字符起全错 (本相最初就是这么错的)。
            if (st_txd !== 1'b1) begin
                fail = fail + 1;
                $display("  FAIL: P7 停位不为 1 (第 %0d 个字符)", nchar);
            end
        end
    endtask

    // 从已解码的 line[] 读 [start, start+len) 的 hex 字符还原成值并与期望比对。
    // 非 hex 字符直接判错 —— 这能抓"字段串位到空格/'='上"这一整类静默错误。
    task chk_hex;
        input [15:0]  ph;
        input [15:0]  start;
        input [15:0]  len;
        input [63:0]  want;
        input [255:0] nm;
        integer kk;
        reg [63:0] acc;
        reg [7:0]  ch;
        reg [3:0]  nib;
        reg        bad;
        begin
            acc = 64'd0; bad = 1'b0;
            for (kk = 0; kk < len; kk = kk + 1) begin
                ch = line[start + kk];
                if      (ch >= "0" && ch <= "9") nib = ch - "0";
                else if (ch >= "A" && ch <= "F") nib = ch - "A" + 4'd10;
                else begin nib = 4'd0; bad = 1'b1; end
                acc = (acc << 4) | nib;
            end
            if (bad) begin
                fail = fail + 1;
                $display("  FAIL: P%0d %0s 偏移 %0d..%0d 含非 hex 字符 (字段错位/模板不符)",
                         ph, nm, start, start + len - 16'd1);
            end
            if (acc !== want) begin
                fail = fail + 1;
                $display("  FAIL: P%0d %0s 解出 %016X 期望 %016X", ph, nm, acc, want);
            end
        end
    endtask

    initial begin
        nchar = 0;                               // integer 复位值是 x, 必须显式清零
        @(negedge st_txd);                       // rst_s 释放前 txd 恒高 (空闲)
        for (dec_i = 0; dec_i < 1040; dec_i = dec_i + 1) begin
            get_byte(line[dec_i]);
            nchar = nchar + 1;
            if (line[dec_i] == 8'h0A) begin      // LF: 行结束
                line_done = 1'b1;
                dec_i = 1040;
            end else begin
                @(negedge st_txd);               // 下一字符 start 沿
            end
        end
    end

    initial begin
        // ================= 相 1: 干净, 背靠背 =================
        plen_v = 16'd64;  paylen_v = 16'd64;  fw_v = 16'd8;
        nfrm_v = 16'd4;   nbyte_v = 16'd256;  nw_v = 16'd32;
        gap_en = 1'b0;
        build_payload;
        run_phase;
        $display("RXPDIAG P1 rx_bytes=%0d(期望 %0d) mismatch=%0d ds_v=%b | gw=%016X ew=%016X | OZ=%0d OL=%0d OM=%0d OH=%0d",
                 st_rx_bytes, nbyte_v, st_mismatch, ds_v, ds_gw, ds_ew,
                 ds_oz, ds_ol, ds_om, ds_oh);
        chk(st_rx_bytes == nbyte_v, "P1 收字节数");
        chk(st_rx_frames == nfrm_v, "P1 帧数");
        chk(st_mismatch == 32'd0 && ds_v == 1'b0, "P1 零失配且无快照");
        chk(ds_b1 == 0 && ds_b2 == 0 && ds_bg == 0 && ds_dup == 0, "P1 四个形状计数全 0");
        chk(ds_gw == 64'd0 && ds_ew == 64'd0, "P1 整字字段未被写入 (恒 0)");
        chk_bk(16'd1, 32'd0, 32'd0, 32'd0, 32'd0);
        // v4 B 部: 干净流上运行结构/事件 FIFO 必须全 0 (也证明这些口真的被驱动,
        // 不是悬空 x —— 悬空时这几条会因 X 而红)
        chk(v4_ne === 16'd0 && v4_nr === 16'd0 && v4_mr === 16'd0,
            "P1 v4 NE/NR/MR zero or X");
        chk(v4_en === 4'd0 && v4_eo === 1'b0, "P1 v4 EN/EO zero or X");
        chk(v4_qa === 24'd0 && v4_qh === 24'd0, "P1 v4 QA/QH zero or X");

        // ================= 相 2: 两处注入, 背靠背 =================
        // CA1=100: 帧 1 (64..127) 帧内偏移 36, 字 96..103 的 **lane 4** (字中!)
        // CA2=150: 帧 2 帧内偏移 22
        plen_v = 16'd64;  paylen_v = 16'd64;  fw_v = 16'd8;
        nfrm_v = 16'd4;   nbyte_v = 16'd256;  nw_v = 16'd32;
        gap_en = 1'b0;
        build_payload;
        inject(16'd100, 8'h40);                  // 两处都是单比特
        inject(16'd150, 8'h01);
        run_phase;
        $display("RXPDIAG P2 idx=%0d got=%02X exp=%02X prev=%02X | b1=%0d b2=%0d bg=%0d dup=%0d mm=%0d | gw=%016X ew=%016X | OZ=%0d OL=%0d OM=%0d OH=%0d",
                 ds_idx, ds_got, ds_exp, ds_prev, ds_b1, ds_b2, ds_bg, ds_dup, st_mismatch,
                 ds_gw, ds_ew, ds_oz, ds_ol, ds_om, ds_oh);
        chk(st_mismatch == 32'd2,             "P2 恰 2 字节失配");
        chk(ds_idx == 32'd100,                "P2 快照 = **第一处**注入 (不是最后一处)");
        chk(ds_got == (pay[100] ^ 8'h40),     "P2 got = 第一处原值^掩码");
        chk(ds_exp == pay[100],               "P2 exp = 第一处图案原值");
        chk(ds_prev == pay[99],               "P2 prev = 第一处前一字节");
        chk(ds_b1 == 32'd2 && ds_b2 == 0 && ds_bg == 0, "P2 形状: 两处都判为单比特");
        chk(ds_dup == 32'd0,                  "P2 非重复签名");
        chk(ds_b1 + ds_b2 + ds_bg == st_mismatch, "P2 不变式 BA+BB+BC == UMM");
        chk_word(16'd2, 16'd96, 4'd4);        // 字中失配 (base 96, lane 4)
        chk_bk(16'd2, 32'd0, 32'd0, 32'd2, 32'd0);   // 36 与 22 都落 OM
        chk(ds_oz + ds_ol + ds_om + ds_oh == st_mismatch, "P2 不变式 OZ+OL+OM+OH == UMM");

        // ================= 相 3: 隔帧 + 注入落在气泡后第一个字节 =================
        plen_v = 16'd64;  paylen_v = 16'd64;  fw_v = 16'd8;
        nfrm_v = 16'd4;   nbyte_v = 16'd256;  nw_v = 16'd32;
        gap_en = 1'b1;
        build_payload;
        inject(16'd96, 8'h40);                   // CA3 = 96, lane 0 (帧 1 帧内偏移 32)
        run_phase;
        $display("RXPDIAG P3 idx=%0d got=%02X exp=%02X prev=%02X | b1=%0d mm=%0d | gw=%016X ew=%016X | OZ=%0d OL=%0d OM=%0d OH=%0d",
                 ds_idx, ds_got, ds_exp, ds_prev, ds_b1, st_mismatch,
                 ds_gw, ds_ew, ds_oz, ds_ol, ds_om, ds_oh);
        chk(st_mismatch == 32'd1,             "P3 恰 1 字节失配");
        chk(ds_idx == 32'd96,                 "P3 idx 正确");
        chk(ds_got == (pay[96] ^ 8'h40),      "P3 got = 原值^掩码");
        chk(ds_exp == pay[96],                "P3 exp = 图案原值");
        // ★ 本门最关键一条: 气泡后第一个字节的 prev 必须是**上一字节**, 不是 exp
        chk(ds_prev == pay[95],               "P3 prev = 上一字节 (气泡后也必须对)");
        chk(ds_prev != ds_exp,                "P3 prev 不得等于 exp (无条件跟拍的老缺陷)");
        chk_word(16'd3, 16'd96, 4'd0);        // 失配在**字首 lane**, 且前面隔着气泡
        chk_bk(16'd3, 32'd0, 32'd0, 32'd1, 32'd0);
        chk(ds_oz + ds_ol + ds_om + ds_oh == st_mismatch, "P3 不变式 OZ+OL+OM+OH == UMM");

        // ================= 相 4: 四个偏移桶的**全部边界** =================
        // 帧长 = i_paylen = 128 (16 字/帧, 3 帧)。注入点 = 帧 1 的偏移
        // 0 / 1 / 7 / 8 / 63 与帧 2 的偏移 64 ⇒ 恰打 OZ|OL 两端|OM 两端|OH 下沿。
        plen_v = 16'd128; paylen_v = 16'd128; fw_v = 16'd16;
        nfrm_v = 16'd3;   nbyte_v = 16'd384;  nw_v = 16'd48;
        gap_en = 1'b0;
        build_payload;
        inject(16'd128, 8'h40);                  // 帧 1 偏移 0   -> OZ (且是帧首字节拍)
        inject(16'd129, 8'h03);                  // 帧 1 偏移 1   -> OL 下沿
        inject(16'd135, 8'h0F);                  // 帧 1 偏移 7   -> OL 上沿
        inject(16'd136, 8'h80);                  // 帧 1 偏移 8   -> OM 下沿
        inject(16'd191, 8'hFF);                  // 帧 1 偏移 63  -> OM 上沿
        inject(16'd192, 8'h01);                  // 帧 2 偏移 64  -> OH 下沿
        run_phase;
        $display("RXPDIAG P4 idx=%0d mm=%0d | b1=%0d b2=%0d bg=%0d | gw=%016X ew=%016X | OZ=%0d OL=%0d OM=%0d OH=%0d",
                 ds_idx, st_mismatch, ds_b1, ds_b2, ds_bg, ds_gw, ds_ew,
                 ds_oz, ds_ol, ds_om, ds_oh);
        chk(st_mismatch == 32'd6,             "P4 恰 6 字节失配");
        chk(ds_idx == 32'd128,                "P4 首失配 = 帧 1 首字节 (全局 128)");
        chk(ds_got == (pay[128] ^ 8'h40),     "P4 got = 帧首字节原值^掩码");
        chk(ds_exp == pay[128],               "P4 exp = 帧首字节图案原值");
        chk(ds_b1 == 32'd3 && ds_b2 == 32'd1 && ds_bg == 32'd2, "P4 形状划分 (1/2/4/1/8/1 比特)");
        chk(ds_b1 + ds_b2 + ds_bg == st_mismatch, "P4 不变式 BA+BB+BC == UMM");
        // 字 128..135 内有 lane 0/1/7 三处注入 ⇒ gw 必须是**整个**收字, 而不是
        // "首个坏字节 + 干净尾巴" (那正是 v2 要防的错)
        chk_word(16'd4, 16'd128, 4'd0);
        chk_bk(16'd4, 32'd1, 32'd2, 32'd2, 32'd1);
        chk(ds_oz + ds_ol + ds_om + ds_oh == st_mismatch, "P4 不变式 OZ+OL+OM+OH == UMM");

        // ================= 相 5: 帧长 40 != i_paylen 64 —— 对齐的**判别性**用例 ===
        // 帧 0..5 = [40k, 40k+40)。注入: 帧 1 偏移 5 / 帧 2 偏移 0,3 /
        // 帧 3 偏移 0 / 帧 4 偏移 4。
        //   帧首字节复位 (本实现): OZ 命中帧 2/3 的首字节, OL 命中 5/3/4 ⇒ OZ=2 OL=3
        //   只按全局取模 64 的实现: 45%64=45 / 80%64=16 / 83%64=19 / 120%64=56 /
        //   164%64=36 全落 OM ⇒ OM=5。**两版在这相给出不同结果 ⇒ 这一相是证明。**
        plen_v = 16'd40;  paylen_v = 16'd64;  fw_v = 16'd5;
        nfrm_v = 16'd6;   nbyte_v = 16'd240;  nw_v = 16'd30;
        gap_en = 1'b0;
        build_payload;
        inject(16'd45,  8'h40);                  // 帧 1 偏移 5  -> OL
        inject(16'd80,  8'h01);                  // 帧 2 偏移 0  -> OZ (帧首字节)
        inject(16'd83,  8'h03);                  // 帧 2 偏移 3  -> OL
        inject(16'd120, 8'h0F);                  // 帧 3 偏移 0  -> OZ (帧首字节)
        inject(16'd164, 8'h80);                  // 帧 4 偏移 4  -> OL
        run_phase;
        $display("RXPDIAG P5 idx=%0d mm=%0d | gw=%016X ew=%016X | OZ=%0d OL=%0d OM=%0d OH=%0d",
                 ds_idx, st_mismatch, ds_gw, ds_ew, ds_oz, ds_ol, ds_om, ds_oh);
        chk(st_rx_bytes == nbyte_v,           "P5 收字节数");
        chk(st_rx_frames == nfrm_v,           "P5 帧数 = 6 (帧长 40)");
        chk(st_mismatch == 32'd5,             "P5 恰 5 字节失配");
        chk(ds_idx == 32'd45,                 "P5 首失配 = 帧 1 偏移 5 (全局 45)");
        chk(ds_got == (pay[45] ^ 8'h40),      "P5 got = 原值^掩码");
        chk(ds_exp == pay[45],                "P5 exp = 图案原值");
        chk_word(16'd5, 16'd40, 4'd5);        // 字 40..47 的 lane 5 (字中失配)
        chk_bk(16'd5, 32'd2, 32'd3, 32'd0, 32'd0);
        chk(ds_oz + ds_ol + ds_om + ds_oh == st_mismatch, "P5 不变式 OZ+OL+OM+OH == UMM");
        chk(ds_b1 + ds_b2 + ds_bg == st_mismatch, "P5 不变式 BA+BB+BC == UMM");

        // ================= 相 6: 帧长 128 > i_paylen 64 —— mod 环绕 =================
        // 帧 0..1 = [0,128) / [128,256)。帧内偏移按 mod 64 环绕。
        //   环绕 (本实现): 64->0(OZ) 65->1(OL) 127->63(OM) 128->0(OZ) ⇒ OZ=2 OL=1 OM=1
        //   不环绕的实现: 四个偏移 64/65/127/128 全 >= 64 ⇒ OH=4。两者可判。
        plen_v = 16'd128; paylen_v = 16'd64;  fw_v = 16'd16;
        nfrm_v = 16'd2;   nbyte_v = 16'd256;  nw_v = 16'd32;
        gap_en = 1'b0;
        build_payload;
        inject(16'd64,  8'h40);                  // 帧 0 偏移 64 == paylen -> 环绕到 0
        inject(16'd65,  8'h01);                  // 帧 0 偏移 65          -> 1  (OL)
        inject(16'd127, 8'h03);                  // 帧 0 偏移 127          -> 63 (OM 上沿)
        inject(16'd128, 8'h0F);                  // 帧 1 偏移 0 (帧首字节) -> OZ
        run_phase;
        $display("RXPDIAG P6 idx=%0d mm=%0d | gw=%016X ew=%016X | OZ=%0d OL=%0d OM=%0d OH=%0d",
                 ds_idx, st_mismatch, ds_gw, ds_ew, ds_oz, ds_ol, ds_om, ds_oh);
        chk(st_rx_bytes == nbyte_v,           "P6 收字节数");
        chk(st_mismatch == 32'd4,             "P6 恰 4 字节失配");
        chk(ds_idx == 32'd64,                 "P6 首失配 = 全局 64");
        chk_word(16'd6, 16'd64, 4'd0);
        chk_bk(16'd6, 32'd2, 32'd1, 32'd1, 32'd0);
        chk(ds_oz + ds_ol + ds_om + ds_oh == st_mismatch, "P6 不变式 OZ+OL+OM+OH == UMM");

        // ================= 相 7: 状态行 (=470 字符) 的逐字符格式门 =================
        @(negedge clk); rst_s = 1'b1;            // 释放 -> 立刻发一行
        wait (line_done);                        // 等解码器收完整行
        // ---------------- 相 8: **部分字** (帧长 60 ⇒ 帧末字只有 4 个有效 lane) ----------------
        // 目的: 激励 RTL 的 lane 掩码 (无效 lane 清 0)。注入点在帧末字的 lane 2,
        // 使该字的 lane 4..7 属于"无效但被喂了图案垃圾"—— 掩码必须把它们清成 0。
        plen_v = 16'd60;  paylen_v = 16'd64;  fw_v = 16'd8;
        nfrm_v = 16'd4;   nbyte_v = 16'd240;  nw_v = 16'd32;
        gap_en = 1'b0;
        build_payload;  inject(16'd58, 8'h40);          // payc[58] = 字7 lane2
        run_phase;
        $display("RXPDIAG P8 idx=%0d mm=%0d | gw=%016X ew=%016X | OZ=%0d OL=%0d OM=%0d OH=%0d",
                 ds_idx, st_mismatch, ds_gw, ds_ew, ds_oz, ds_ol, ds_om, ds_oh);
        chk(st_mismatch == 32'd1, "P8 恰 1 字节失配");
        chk(st_rx_bytes == nbyte_v, "P8 收字节数 = 帧长x帧数 (部分字按 tkeep 计)");
        chk(ds_idx == 16'd58, "P8 全局字节号 = 58 (帧内偏移 58)");
        // ★ 关键: 收到的字 lane4..7 是无效 lane, 必须被掩成 0 (而不是原始图案垃圾)
        chk(ds_gw == {payc[56], payc[57], payc[58], payc[59], 32'd0},
            "P8 收字 = 部分字且无效 lane 已清 0 (堵住 lane 掩码变异)");
        chk(ds_ew == {payc[56], payc[57], pay[58], payc[59], 32'd0},
            "P8 期望字 = 干净部分字且无效 lane 清 0");
        chk(ds_got == payc[58] && ds_exp == pay[58], "P8 GG/EE = 该 lane 的收/期望字节");
        chk(ds_om == 32'd1 && ds_oz == 0 && ds_ol == 0 && ds_oh == 0,
            "P8 分桶: 帧内偏移 58 属 OM (8..63)");
        chk(ds_b1 + ds_b2 + ds_bg == st_mismatch, "P8 popcount 分桶覆盖");
        chk(ds_oz + ds_ol + ds_om + ds_oh == st_mismatch, "P8 偏移分桶覆盖");

        $display("RXPDIAG P7 行长=%0d (期望 971) 末两字符=%02X %02X", nchar, line[969], line[970]);
        $write("RXPDIAG P7 LINE: ");              // 实收整行 (不含 CR/LF) —— 板级读数长这样
        for (jj = 0; jj < 969; jj = jj + 1) $write("%c", line[jj]);
        $write("%c", 8'h0A);                 // 行尾 (不写字面反斜杠, 免转义坑)
        chk(nchar == 971, "P7 行长 = 971 字符 (v6)");
        chk(line[969] == 8'h0D && line[970] == 8'h0A, "P7 CR/LF 落在 969/970");
        // ---- v6 新字段 (偏移全部由 sim/rxpdiag/gen_offsets.py 拼接 TPL 串算出) ----
        // 7 个字段各取**互不相同且非 0**的常量 ⇒ 窗口串位/少一字符/多一字符/
        // 左对齐错 (8 位值误写成"补到 32 位") 都会让解码值变红。
        chk_hex(16'd7, 16'd918, 16'd8, 64'h000000000F1E2D3C, "CV");
        chk_hex(16'd7, 16'd930, 16'd2, 64'h00000000000000B7, "CG");
        chk_hex(16'd7, 16'd936, 16'd2, 64'h000000000000004E, "CE");
        chk_hex(16'd7, 16'd942, 16'd4, 64'h0000000000003A5C, "CO");
        chk_hex(16'd7, 16'd950, 16'd8, 64'h0000000000FACADE, "CM");
        chk_hex(16'd7, 16'd962, 16'd1, 64'h0000000000000001, "CZ");
        chk_hex(16'd7, 16'd967, 16'd2, 64'h000000000000006B, "CS");
        // 追加性: ' CV=' 必须紧跟在 SB 值的 8 个 hex 之后 (前 916 字符未被推动)
        chk(line[914] == 8'h20 && line[915] == 8'h43 && line[916] == 8'h56
            && line[917] == 8'h3D, "P7 CV 字段紧接 SB 值 (v5 前缀未被推动)");
        // 追加性: ' DV=' 必须紧跟在 QH 值的 6 个 hex 之后 (前 805 字符未被推动)
        // ---- v5 新字段 (偏移全部由 sim/rxpdiag/gen_offsets.py 拼接 TPL 串算出) ----
        // 11 个字段各取**互不相同且非 0**的常量 ⇒ 窗口串位/少一字符/多一字符/
        // 左对齐错 (8 位值误写成"补到 32 位") 都会让解码值变红。
        chk_hex(16'd7, 16'd809, 16'd8, 64'h000000000A0B0C0D, "DV");
        chk_hex(16'd7, 16'd821, 16'd2, 64'h00000000000000D3, "DG");
        chk_hex(16'd7, 16'd827, 16'd2, 64'h000000000000007E, "DE");
        chk_hex(16'd7, 16'd833, 16'd4, 64'h0000000000000F5A, "DO");
        chk_hex(16'd7, 16'd841, 16'd8, 64'h0000000000C0FFEE, "DM");
        chk_hex(16'd7, 16'd853, 16'd1, 64'h0000000000000001, "VZ");
        chk_hex(16'd7, 16'd858, 16'd8, 64'h0000000000123456, "PS");
        chk_hex(16'd7, 16'd870, 16'd8, 64'h0000000000ABCDEF, "NM");
        chk_hex(16'd7, 16'd882, 16'd8, 64'h000000000000BEEF, "IC");
        chk_hex(16'd7, 16'd894, 16'd8, 64'h000000000ADD1E55, "DC");
        chk_hex(16'd7, 16'd906, 16'd8, 64'h00000000CAFEF00D, "SB");
        // 追加性: ' DV=' 必须紧跟在 QH 值的 6 个 hex 之后 (前 805 字符未被推动)
        chk(line[805] == 8'h20 && line[806] == 8'h44 && line[807] == 8'h56
            && line[808] == 8'h3D, "P7 DV 字段紧接 QH 值 (v4 前缀未被推动)");
        // ---- v4 新字段 (偏移全部由 sim/rxpdiag/gen_offsets.py 拼接 TPL 串算出) ----
        // 20 个字段各取互相可区分的常量 ⇒ 窗口串位/少一字符/左对齐错必红。
        // EN/EO 是 1 字符窗口 (hexc 天然右对齐); QA..QH 是 24 位值在 6 字符窗口
        // (hexd 左对齐 {v, 8'b0}) —— 这两类是最容易写错的地方, 故取值也刻意错开。
        chk_hex(16'd7, 16'd639, 16'd4, 64'h0000000000000055, "CN");
        chk_hex(16'd7, 16'd647, 16'd4, 64'h00000000000000AA, "RD");
        chk_hex(16'd7, 16'd655, 16'd4, 64'h00000000000000F0, "NC");
        chk_hex(16'd7, 16'd663, 16'd4, 64'h000000000000000F, "NP");
        chk_hex(16'd7, 16'd671, 16'd4, 64'h0000000000001234, "WF");
        chk_hex(16'd7, 16'd679, 16'd4, 64'h0000000000004321, "RL");
        chk_hex(16'd7, 16'd687, 16'd4, 64'h00000000000000C3, "WC");
        chk_hex(16'd7, 16'd695, 16'd4, 64'h0000000000000BEE, "NE");
        chk_hex(16'd7, 16'd703, 16'd4, 64'h0000000000000CAF, "NR");
        chk_hex(16'd7, 16'd711, 16'd4, 64'h0000000000000999, "MR");
        chk_hex(16'd7, 16'd719, 16'd1, 64'h0000000000000008, "EN");
        chk_hex(16'd7, 16'd724, 16'd1, 64'h0000000000000001, "EO");
        chk_hex(16'd7, 16'd729, 16'd6, 64'h000000000001C5, "QA");
        chk_hex(16'd7, 16'd739, 16'd6, 64'h000000000002D6, "QB");
        chk_hex(16'd7, 16'd749, 16'd6, 64'h000000000003E7, "QC");
        chk_hex(16'd7, 16'd759, 16'd6, 64'h000000000004F8, "QD");
        chk_hex(16'd7, 16'd769, 16'd6, 64'h00000000000509, "QE");
        chk_hex(16'd7, 16'd779, 16'd6, 64'h0000000000061A, "QF");
        chk_hex(16'd7, 16'd789, 16'd6, 64'h0000000000072B, "QG");
        chk_hex(16'd7, 16'd799, 16'd6, 64'h0000000000083C, "QH");
        // 追加性: ' CN=' 必须紧跟在 VN 值的 4 个 hex 之后 (前 635 字符未被推动)
        chk(line[635] == 8'h20 && line[636] == 8'h43 && line[637] == 8'h4E
            && line[638] == 8'h3D, "P7 CN 字段紧接 VN 值 (v3 前缀未被推动)");
        // ---- v3 新字段 (偏移全部由 sim/rxpdiag/gen_offsets.py 拼接 TPL 串算出) ----
        // 断言每个字段的**窗口与值**: 值互不相同、非 0、非全同 ⇒ 字段串位/窗口
        // 少一字符/多一字符/左对齐错 都会让解码值变红。
        chk_hex(16'd7, 16'd472, 16'd16, 64'hA1B2C3D4E5F60718, "SW");
        chk_hex(16'd7, 16'd492, 16'd3,  64'h00000000000001AB, "SF");
        chk_hex(16'd7, 16'd499, 16'd1,  64'h0000000000000001, "SM");
        chk_hex(16'd7, 16'd504, 16'd3,  64'h00000000000000F3, "FR");
        chk_hex(16'd7, 16'd511, 16'd3,  64'h00000000000001E7, "FW");
        chk_hex(16'd7, 16'd518, 16'd3,  64'h00000000000000F4, "FO");
        chk_hex(16'd7, 16'd525, 16'd3,  64'h00000000000000B8, "FH");
        chk_hex(16'd7, 16'd532, 16'd1,  64'h0000000000000002, "FS");
        chk_hex(16'd7, 16'd537, 16'd4,  64'h0000000000000123, "FN");
        chk_hex(16'd7, 16'd545, 16'd3,  64'h000000000000004F, "PR");
        chk_hex(16'd7, 16'd552, 16'd3,  64'h0000000000000143, "PW");
        chk_hex(16'd7, 16'd559, 16'd3,  64'h00000000000000B8, "PH");
        chk_hex(16'd7, 16'd566, 16'd3,  64'h00000000000000BF, "LR");
        chk_hex(16'd7, 16'd573, 16'd3,  64'h00000000000001F3, "LW");
        chk_hex(16'd7, 16'd580, 16'd3,  64'h0000000000000134, "LO");
        chk_hex(16'd7, 16'd587, 16'd3,  64'h000000000000007A, "LH");
        chk_hex(16'd7, 16'd594, 16'd4,  64'h0000000000000009, "RC");
        chk_hex(16'd7, 16'd602, 16'd4,  64'h0000000000000001, "VC");
        chk_hex(16'd7, 16'd610, 16'd3,  64'h00000000000000B8, "VX");
        chk_hex(16'd7, 16'd617, 16'd3,  64'h000000000000004F, "VS");
        chk_hex(16'd7, 16'd624, 16'd3,  64'h00000000000000BF, "VR");
        chk_hex(16'd7, 16'd631, 16'd4,  64'h0000000000000123, "VN");
        // 追加性: ' SW=' 必须紧跟在 OH 值的 8 个 hex 之后 (前 468 字符未被推动)
        chk(line[468] == 8'h20 && line[469] == 8'h53 && line[470] == 8'h57
            && line[471] == 8'h3D, "P7 SW 字段紧接 OH 值 (v2 前缀未被推动)");
        // v2 新字段 (偏移由脚本拼接模板串定位; 6 个值互不相同 ⇒ 串位/串宽必红)
        chk_hex(16'd7, 16'd384, 16'd16, 64'h0123456789ABCDEF, "GW");
        chk_hex(16'd7, 16'd404, 16'd16, 64'hFEDCBA9876543210, "EW");
        chk_hex(16'd7, 16'd424, 16'd8,  64'h0BADF00D, "OZ");
        chk_hex(16'd7, 16'd436, 16'd8,  64'h00000007, "OL");
        chk_hex(16'd7, 16'd448, 16'd8,  64'h12345678, "OM");
        chk_hex(16'd7, 16'd460, 16'd8,  64'hDEADBEEF, "OH");
        // v1 RXP_DIAG 字段: 发布偏移 (306/318/324/330/336/348/360/372) 逐字符不变
        chk_hex(16'd7, 16'd306, 16'd8,  64'h00003039, "II");
        chk_hex(16'd7, 16'd318, 16'd2,  64'h0000005F, "GG");
        chk_hex(16'd7, 16'd324, 16'd2,  64'h0000001A, "EE");
        chk_hex(16'd7, 16'd330, 16'd2,  64'h000000C3, "PP");
        chk_hex(16'd7, 16'd336, 16'd8,  64'h00000001, "BA");
        chk_hex(16'd7, 16'd348, 16'd8,  64'h00000002, "BB");
        chk_hex(16'd7, 16'd360, 16'd8,  64'h00000003, "BC");
        chk_hex(16'd7, 16'd372, 16'd8,  64'h00000004, "DD");
        // 更早的字段: 证明"新段只追加在行尾、前 382 字符没被推动"
        chk_hex(16'd7, 16'd223, 16'd8,  64'h00ABCDEF, "URB");
        chk_hex(16'd7, 16'd298, 16'd4,  64'h00000BB8, "UTF");
        chk_hex(16'd7, 16'd8,   16'd1,  64'h00000001, "ST");

        if (fail == 0) $display("RXP-DIAG GATE: OK");
        else           $display("RXP-DIAG GATE: FAIL (%0d)", fail);
        $finish;
    end

    initial begin
        #2000000;
        $display("RXP-DIAG GATE: FAIL (timeout, wi=%0d gap=%b)", wi, gap_run);
        $finish;
    end
endmodule
