`timescale 1ns/1ps
//=============================================================================
// tb_rxp_v4.v — RXP_DIAG **v4** 的功能门 (ISSUE_RX_BYTE_CORRUPTION §16.7)
//
// 为什么另开一条门 (而不是往 tb_rxp_v3.v 里加相位):
//   ① v4 的两个被测对象与 v3 的**触发口径不同**: v3 的字段是在两个事件拍上
//      "锁存" (帧首/首失配), 而 v4 的计数器是**本轮累计**, 判据必须按**相位增量**
//      比 (v3 的门是"绝对值 + 帧几何"口径)。混进同一 TB 会让两套口径互相污染,
//      也说不清某条断言属于哪一代仪器。
//   ② tb_rxp_v3.v 的 md5 已被文档 (§16.8) 引用并经过 5 轮独立审查 —— 保持它
//      **逐字节不变**才能保住既有证据链; 新仪器新文件, 旧门的绿不作废。
//   两个 TB 共用同一套激励脚手架风格 (真 IPv4/UDP 帧 → 真 udp_split 播放器 →
//   真 app_udp_pattern 校验器), 故脚手架的可信度是继承的。
//
// 【被测对象】
//   A 部 (udp_split 的 7 个异常帧路径计数器, 均"本轮累计"):
//     CN 描述符 FIFO 满 ⇒ 本帧回卷 | RD 残帧边界回卷 | NC 0 长数据报事件
//     NP 0 长数据报提交 | WF uf_ovf 拍数(= 因满被吞的载荷字数) | RL 回卷拍数
//     WC 字数一致性违例 (提交拍 写字数 != ceil(len/8))
//   B 部 (app_udp_pattern 的受损帧运行结构 + 事件 FIFO):
//     NE 偏移 0 失配事件数 (= 与 OZ 同门, 门里互证) | NR 极大连续段数
//     MR 最长连续段长度 | EN 已入队条目数 | EO FIFO 曾满(后续事件未记录)
//     QA..QH 条目 0..7 = {帧号[15:0], 该事件处 rx_got[7:0]}
//
// 【相位与判据】
//   V1 干净 4x1472B (逐帧喂, 有间隔)      ⇒ **全部计数器增量 0** (负相例)
//   V2 帧首字节坏 x2, **隔帧** (帧 1 与 3) ⇒ NE=2 NR=2 MR=1 EN=2 EO=0
//                                            QA={1,got1} QB={3,got3} ("全孤立")
//   V3 帧首字节坏 x3, **连续** (帧 1,2,3)  ⇒ NE=3 NR=1 MR=3 EN=3 EO=0 ("含连续段")
//                                            逐条目 = 帧 1/2/3 的 {帧号, got}
//   V4 连坏 10 帧 (帧 1..10)               ⇒ NE=10 NR=1 MR=10 **EN=8 EO=1**
//                                            (FIFO 满 ⇒ 只计数不入队, 明示未记录)
//   V9 0 长数据报 + 其后 2 帧干净          ⇒ NC=1 NP=1, 其余全 0, 图案流不断
//                                            (app 侧 stat_rx_null 也 +1)
//   V6 强偏 u_meta_len (+8) x4 帧          ⇒ WC=4 (每帧恰 1 次), 其余全 0
//   V5 900 个小帧 (8B) 背靠背              ⇒ CN >= 1 (描述符 FIFO 被填满),
//                                            WF=0 (缓冲不满 ⇒ 两条路径被分开)
//   V7 声明长度 > 实际 (残帧)              ⇒ RD=1, 其余 (CN/NC/NP/WF/WC) 0
//   V8 12 x 1472B 背靠背 (消费者慢)        ⇒ WF >= 1 (缓冲满吞字), WC=0
//
// 【口径声明 (判读必读)】A 部计数器的条件口径见 rtl/udp_split.v 的 v4 段:
//   CN/RD/NC/NP 是**单拍脉冲** ⇒ 计数 = 事件数; WF 是**电平** ⇒ 计数 = 字数;
//   RL 与 v3 的 RC 同源 (回卷拍数)。本门用**相位增量**断言 (v4_snap 在每相起点
//   锁一份基线), 因为计数器是"本轮累计"。
//
// 运行: sim/rxpdiag/run_tb_rxp_v4.bat (独立目录, 防 xsim.dir 文件锁 — 坑 7)
//=============================================================================
module tb_rxp_v4;

    localparam [31:0] MY_IP    = 32'hC0A86402;   // 192.168.100.2
    localparam [31:0] PEER_IP  = 32'hC00A0001;   // 192.168.100.1
    localparam [15:0] APP_PORT = 16'd9000;
    localparam integer PLEN    = 1472;           // 板级载荷 (184 字)
    localparam integer FW      = PLEN / 8;       // 184 字/帧
    localparam integer NFRM    = 4;              // 常规相帧数

    // 各相帧数 (V5/V8 是"填满"类, 需要足够多帧才能触发)
    localparam integer NF_V4   = 11;             // V4: 11 帧, 前 10 帧坏
    // V5 帧数由**速率账**定: 喂 7 拍/帧 (6 头字 + 1 载荷字), 播放器 8 拍/帧
    //   (app 的 cmp 引擎 8 字节/字 ⇒ 1 字/8 拍) ⇒ 描述符净积压 ~0.018/拍
    //   ⇒ 填满 64 深需要 ~3600 拍 ≈ 520 帧; 取 900 帧留 1.7x 余量。
    //   (400 帧时实测 CN=0 —— 这正是"速率账要对"的实证, 不是门坏了。)
    localparam integer NF_V5   = 900;            // V5: 小帧背靠背 (填满描述符 FIFO)
    localparam integer NF_V8   = 12;             // V8: 1472B 背靠背 (填满载荷缓冲)
    localparam [15:0] PL_V5   = 16'd8;          // V5: 每帧 8 字节载荷 = 1 字
    localparam integer NB      = 65536;          // 图案数组 (V4: 11x1472 = 16192)

    reg clk = 1'b0, rst_n = 1'b0;
    always #4 clk = ~clk;                        // 125 MHz

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

    reg [7:0] pay  [0:NB-1];                     // 干净图案 (期望值来源)
    reg [7:0] payc [0:NB-1];                     // 线上实际 (含注入)
    integer   k;
    reg [63:0] st;
    initial begin
        st = 64'h9E3779B97F4A7C15;
        for (k = 0; k < NB; k = k + 1) begin
            pay[k] = st[31:24];                  // 先取后推进 (与 RTL/peer 同款)
            st = xs_next(st);
        end
    end

    // ---- 64 位整字 (lane0 = 最高字节 = tdata[63:56], 同 RTL 的 byte_at) ----
    function [63:0] w_of;
        input integer base;
        begin
            w_of = {payc[base+0], payc[base+1], payc[base+2], payc[base+3],
                    payc[base+4], payc[base+5], payc[base+6], payc[base+7]};
        end
    endfunction

    //=========================================================================
    // DUT: udp_split (真播放器 + 真回卷) + app_udp_pattern (真校验器)
    //=========================================================================
    reg  [63:0] s_tdata;  reg [7:0] s_tkeep;  reg s_tvalid;
    wire        s_tready;
    reg         s_tlast, s_tuser, s_tcrs, s_terr;
    wire [63:0] p_tdata;  wire [7:0] p_tkeep; wire p_tvalid;
    wire        p_tlast, p_tuser, p_tcrs, p_terr;
    wire        p_tready = 1'b1;
    wire [63:0] a_tdata;  wire [7:0] a_tkeep; wire a_tvalid; wire a_tlast, a_sof;
    wire [15:0] a_len;    wire [31:0] a_sip;  wire [15:0] a_sport;
    wire        a_tready;                        // ← app_udp_pattern 的校验器
    reg  [15:0] paylen_v;                        // app 的 i_paylen (逐相设置)

    reg  [31:0] cfg_dip;
    wire [31:0] st_app_frames, st_app_bytes, st_app_null, st_drop_crc,
                st_drop_ovf, st_drop_part, st_drop_excl,
                st_hls_frames, st_hls_drop, st_hls_split;

    // v3 观测口 (与 udp_split 的端口同宽: UDP_AW=9 ⇒ 10 位指针) —— 只为对账
    wire        ds_cap;
    wire [63:0] v3_sw;
    wire [8:0]  v3_sf;
    wire        v3_sm;
    wire [7:0]  v3_wd;
    wire [9:0]  v3_fr, v3_fw, v3_fo, v3_fh;
    wire [1:0]  v3_fs;
    wire [15:0] v3_fn;
    wire [9:0]  v3_pr, v3_pw, v3_ph;
    wire [9:0]  v3_lr, v3_lw, v3_lo, v3_lh;
    wire [15:0] v3_rc, v3_vc;
    wire [9:0]  v3_vx, v3_vs, v3_vr;
    wire [15:0] v3_vn;
    // v4 观测口 (A 部)
    wire [15:0] v4_cn, v4_rd, v4_nc, v4_np, v4_wf, v4_rl, v4_wc;

    udp_split #(.EXCL_PORT(16'd8080)) u_split (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep), .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_tready), .s_axis_tlast(s_tlast), .s_axis_tuser(s_tuser),
        .s_axis_tcrs(s_tcrs), .s_axis_terr(s_terr),
        .p_axis_tdata(p_tdata), .p_axis_tkeep(p_tkeep), .p_axis_tvalid(p_tvalid),
        .p_axis_tready(p_tready),
        .p_axis_tlast(p_tlast), .p_axis_tuser(p_tuser),
        .p_axis_tcrs(p_tcrs), .p_axis_terr(p_terr),
        .app_rx_tdata(a_tdata), .app_rx_tkeep(a_tkeep), .app_rx_tvalid(a_tvalid),
        .app_rx_tready(a_tready), .app_rx_tlast(a_tlast), .app_rx_sof(a_sof),
        .app_rx_len(a_len), .app_rx_src_ip(a_sip), .app_rx_src_port(a_sport),
        .cfg_dst_ip(cfg_dip), .cfg_multi_en(1'b0),
        .cfg_port0(APP_PORT), .cfg_port1(16'hFFFF),
        .cfg_port2(16'hFFFF), .cfg_port3(16'hFFFF), .cfg_port_any(1'b0),
        .stat_app_frames(st_app_frames), .stat_app_bytes(st_app_bytes),
        .stat_app_null(st_app_null), .stat_drop_crc(st_drop_crc),
        .stat_drop_ovf(st_drop_ovf), .stat_drop_part(st_drop_part),
        .stat_drop_excl(st_drop_excl), .stat_hls_frames(st_hls_frames),
        .stat_hls_drop(st_hls_drop), .stat_hls_split(st_hls_split),
        .ds_cap(ds_cap),
        .v3_sw(v3_sw), .v3_sf(v3_sf), .v3_sm(v3_sm), .v3_wd(v3_wd),
        .v3_fr(v3_fr), .v3_fw(v3_fw), .v3_fo(v3_fo), .v3_fh(v3_fh),
        .v3_fs(v3_fs), .v3_fn(v3_fn),
        .v3_pr(v3_pr), .v3_pw(v3_pw), .v3_ph(v3_ph),
        .v3_lr(v3_lr), .v3_lw(v3_lw), .v3_lo(v3_lo), .v3_lh(v3_lh),
        .v3_rc(v3_rc), .v3_vc(v3_vc),
        .v3_vx(v3_vx), .v3_vs(v3_vs), .v3_vr(v3_vr), .v3_vn(v3_vn),
        .v4_cn(v4_cn), .v4_rd(v4_rd), .v4_nc(v4_nc), .v4_np(v4_np),
        .v4_wf(v4_wf), .v4_rl(v4_rl), .v4_wc(v4_wc)
    );

    wire [31:0] ds_idx, ds_b1, ds_b2, ds_bg, ds_dup;
    wire [7:0]  ds_got, ds_exp, ds_prev;
    wire        ds_v;
    wire [63:0] ds_gw, ds_ew;
    wire [31:0] ds_oz, ds_ol, ds_om, ds_oh;
    wire [31:0] a_rx_bytes, a_rx_frames, a_rx_null, a_mismatch;
    // v4 观测口 (B 部)
    wire [15:0] v4_ne, v4_nr, v4_mr;
    wire [3:0]  v4_en;
    wire        v4_eo;
    wire [23:0] v4_qa, v4_qb, v4_qc, v4_qd, v4_qe, v4_qf, v4_qg, v4_qh;

    app_udp_pattern #(.TX_BYTES(32'd0), .TX_GAP(16'd0)) u_app (
        .clk(clk), .rst_n(rst_n),
        .i_en(1'b1), .i_tx_ready(1'b0), .i_paylen(paylen_v[11:0]),
        .m_tdata(), .m_tkeep(), .m_tvalid(), .m_tready(1'b0), .m_tlast(),
        .rx_tdata(a_tdata), .rx_tkeep(a_tkeep), .rx_tvalid(a_tvalid),
        .rx_tready(a_tready), .rx_tlast(a_tlast), .rx_sof(a_sof), .rx_len(a_len),
        .stat_tx_bytes(), .stat_tx_frames(), .stat_rx_bytes(a_rx_bytes),
        .stat_rx_frames(a_rx_frames), .stat_rx_null(a_rx_null),
        .stat_mismatch(a_mismatch), .active(), .done(), .led(),
        .ds_idx(ds_idx),
        .ds_b1(ds_b1), .ds_b2(ds_b2), .ds_bg(ds_bg), .ds_dup(ds_dup),
        .ds_got(ds_got), .ds_exp(ds_exp), .ds_prev(ds_prev), .ds_v(ds_v),
        .ds_gw(ds_gw), .ds_ew(ds_ew),
        .ds_oz(ds_oz), .ds_ol(ds_ol), .ds_om(ds_om), .ds_oh(ds_oh),
        .ds_cap(ds_cap),
        .v4_ne(v4_ne), .v4_nr(v4_nr), .v4_mr(v4_mr),
        .v4_en(v4_en), .v4_eo(v4_eo),
        .v4_ea(v4_qa), .v4_eb(v4_qb), .v4_ec(v4_qc), .v4_ed(v4_qd),
        .v4_ee(v4_qe), .v4_ef(v4_qf), .v4_eg(v4_qg), .v4_eh(v4_qh)
    );

    //=========================================================================
    // 接口侧模型 (真值源 = app RX 口的握手 + 已知帧几何)
    //=========================================================================
    integer m_pop;          // 已弹出字数 (= DUT 的 uf_rptr)
    integer m_sof;          // app 侧见过的帧首数 (= app 的帧序 fi_cnt)
    integer m_done;         // 已收完的帧数
    integer m_null;         // 已见的 0 长帧数 (与 app 的 stat_rx_null 对账)
    // 帧首拍锁到的 rx_len (V6 用来证明"强偏 u_meta_len 真的生效")
    reg [15:0] f_len_seen;
    integer    f_len_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_pop <= 0; m_sof <= 0; m_done <= 0; m_null <= 0;
            f_len_seen <= 16'd0; f_len_cnt <= 0;
        end else if (a_tvalid && a_tready) begin
            if (a_sof) begin
                m_sof <= m_sof + 1;
                f_len_seen <= a_len;
                f_len_cnt  <= f_len_cnt + 1;
                if (a_len == 16'd0) m_null <= m_null + 1;
            end
            if (a_len != 16'd0) m_pop <= m_pop + 1;   // 0 长帧的合成拍不弹字
            if (a_tlast)        m_done <= m_done + 1;
        end
    end

    // 绝不反压观测 (TB 若灌得比读者排空更快, 会破坏"结构性不反压"前提)
    integer stall_cyc;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) stall_cyc <= 0;
        else if (!s_tready) stall_cyc <= stall_cyc + 1;

    //=========================================================================
    // 激励: 构造 classify-slow 字流 (帧头与 tb_rxp_v3.v / tb_udp_split 同款)
    //=========================================================================
    localparam integer SN = 16384;
    reg [76:0] stim [0:SN-1];
    integer    sp;

    reg [7:0]  fb [0:2047];
    integer    flen;

    task fb_put(input [7:0] b); begin fb[flen] = b; flen = flen + 1; end endtask
    task fb_put16(input [15:0] v); begin
        fb[flen] = v[15:8]; fb[flen+1] = v[7:0]; flen = flen + 2; end endtask
    task fb_put32(input [31:0] v); begin
        fb[flen]=v[31:24]; fb[flen+1]=v[23:16]; fb[flen+2]=v[15:8]; fb[flen+3]=v[7:0];
        flen = flen + 4; end endtask

    integer h_i; reg [19:0] h_sum; reg [16:0] h_f1; reg [15:0] h_ck;
    task mk_hdr(input integer iplen);
        begin
            flen = 0;
            fb_put32(32'h000A3501); fb_put16(16'hFEC0);     // dst mac
            fb_put32(32'h11223344); fb_put16(16'h5566);     // src mac
            fb_put16(16'h0800);                             // ethertype IPv4
            fb_put(8'h45); fb_put(8'h00);                   // ver/ihl, dscp
            fb_put16(iplen[15:0]); fb_put16(16'h1234); fb_put16(16'h4000);
            fb_put(8'd64); fb_put(8'h11);                   // ttl, UDP
            fb_put16(16'h0000);                             // ip csum 占位 (14..33)
            fb_put32(PEER_IP); fb_put32(MY_IP);
            h_sum = 20'd0;
            for (h_i = 0; h_i < 10; h_i = h_i + 1)
                h_sum = h_sum + {4'b0, fb[14+2*h_i], fb[15+2*h_i]};
            h_f1 = h_sum[15:0] + {12'b0, h_sum[19:16]};
            h_ck = ~(h_f1[15:0] + {15'b0, h_f1[16]});
            fb[24] = h_ck[15:8]; fb[25] = h_ck[7:0];
        end
    endtask

    integer u_i; reg [15:0] u_len;
    // base = 该帧载荷在图案流里的起点; plen = 载荷字节数; bad_udplen: 声明 > 实际
    task mk_udp_frame(input integer base, input integer plen, input integer bad_udplen);
        begin
            mk_hdr(plen + 28);
            fb_put16(16'h3039);            // sport
            fb_put16(APP_PORT);            // dport (匹配 cfg_port0)
            u_len = plen + 8;
            if (bad_udplen) u_len = plen + 58;
            fb_put16(u_len); fb_put16(16'h0000);
            for (u_i = 0; u_i < plen; u_i = u_i + 1) fb_put(payc[base + u_i]);
        end
    endtask

    integer e_w, e_b, e_nw, e_nb;
    reg [63:0] e_d;  reg [7:0] e_k;
    task emit_frame(input integer crc_ok, input integer gap);
        begin
            e_nw = (flen + 7) / 8;
            for (e_w = 0; e_w < e_nw; e_w = e_w + 1) begin
                e_nb = flen - e_w*8;  if (e_nb > 8) e_nb = 8;
                e_d = 64'd0;  e_k = 8'hFF << (8 - e_nb);
                for (e_b = 0; e_b < e_nb; e_b = e_b + 1)
                    e_d[63 - 8*e_b -: 8] = fb[e_w*8 + e_b];
                stim[sp] = {1'b1, e_d, e_k, (e_w == e_nw-1), (e_w == 0),
                            (((e_w == e_nw-1) && (crc_ok != 0)) ? 1'b1 : 1'b0), 1'b0};
                sp = sp + 1;
            end
            for (e_w = 0; e_w < gap; e_w = e_w + 1) begin stim[sp] = 77'd0; sp = sp + 1; end
        end
    endtask

    integer r_i;
    // ⚠️ 逐拍**非阻塞**落地 (坑 3/17): 脚本进程 @(posedge clk) 后若用阻塞赋值写
    // DUT-facing 信号, 同一步内其它进程会采到不同值 ⇒ 假故障。v3 门同款写法。
    task run_stim(input integer a, input integer b);
        begin
            for (r_i = a; r_i < b; r_i = r_i + 1) begin
                @(posedge clk);
                s_tvalid <= stim[r_i][76];
                s_tdata  <= stim[r_i][75:12];
                s_tkeep  <= stim[r_i][11:4];
                s_tlast  <= stim[r_i][3];
                s_tuser  <= stim[r_i][2];
                s_tcrs   <= stim[r_i][1];
                s_terr   <= stim[r_i][0];
            end
        end
    endtask

    task idle_drive(input integer n);
        begin
            for (r_i = 0; r_i < n; r_i = r_i + 1) begin
                @(posedge clk);
                s_tvalid <= 1'b0; s_tdata <= 64'd0; s_tkeep <= 8'd0;
                s_tlast <= 1'b0;  s_tuser <= 1'b0; s_tcrs <= 1'b0; s_terr <= 1'b0;
            end
        end
    endtask

    integer wt_i;
    task wait_cap(input integer maxc);           // 有界等待 ds_cap (不给死锁留机会)
        begin
            for (wt_i = 0; wt_i < maxc; wt_i = wt_i + 1) begin
                if (ds_cap) wt_i = maxc; else @(posedge clk);
            end
        end
    endtask

    integer fail = 0;
    // ⚠️ 必须用 `!==` 判 X (v3 的 M4 变异实测: `if (!cond)` 会把 X 当通过)
    task chk(input cond, input [255:0] name);
        begin
            if (cond !== 1'b1) begin
                fail = fail + 1;
                $display("  FAIL: %0s", name);
            end
        end
    endtask

    task do_reset;
        begin
            @(negedge clk); rst_n = 1'b0;
            repeat (20) @(posedge clk);
            @(negedge clk); rst_n = 1'b1;
        end
    endtask

    //=========================================================================
    // 计数器基线快照 (v4 的 A/B 计数器都是**本轮累计** ⇒ 判据一律用增量)
    //=========================================================================
    integer s_cn, s_rd, s_nc, s_np, s_wf, s_rl, s_wc;
    integer s_ne, s_nr, s_mr, s_en, s_eo, s_oz;
    integer s_mm, s_null, s_pop, s_rxf, s_frm;
    task v4_snap;
        begin
            s_cn = v4_cn; s_rd = v4_rd; s_nc = v4_nc; s_np = v4_np;
            s_wf = v4_wf; s_rl = v4_rl; s_wc = v4_wc;
            s_ne = v4_ne; s_nr = v4_nr; s_mr = v4_mr;
            s_en = v4_en; s_eo = v4_eo; s_oz = ds_oz;
            s_mm = a_mismatch; s_null = a_rx_null; s_pop = m_pop;
            s_rxf = a_rx_frames; s_frm = st_app_frames;
        end
    endtask

    // A 部增量打印 (每相一次)
    task v4_dump(input [255:0] nm);
        begin
            $display("RXPV4 %0s dCN=%0d dRD=%0d dNC=%0d dNP=%0d dWF=%0d dRL=%0d dWC=%0d | dNE=%0d dNR=%0d dMR=%0d EN=%0d EO=%0d",
                     nm, v4_cn-s_cn, v4_rd-s_rd, v4_nc-s_nc, v4_np-s_np,
                     v4_wf-s_wf, v4_rl-s_rl, v4_wc-s_wc,
                     v4_ne-s_ne, v4_nr-s_nr, v4_mr-s_mr, v4_en, v4_eo);
        end
    endtask

    // 条目 k 的期望值 = {帧号, 该帧载荷 byte0} (注入只在 byte0 上做 ⇒ got = payc[..])
    function [23:0] q_exp;
        input [31:0] frm;
        begin
            q_exp = {frm[15:0], payc[frm*PLEN]};
        end
    endfunction

    task chk_q(input [255:0] nm, input integer idx, input [23:0] got,
               input [23:0] want);
        begin
            if (got !== want) begin
                fail = fail + 1;
                $display("  FAIL: %0s Q%0d = %06X, want %06X", nm, idx, got, want);
            end
        end
    endtask

    //=========================================================================
    // 相位
    //=========================================================================
    integer fi, wn, inj_i;

    task load_frames(input integer n, input integer plen, input integer gap);
        begin
            sp = 0;
            for (fi = 0; fi < n; fi = fi + 1) begin
                mk_udp_frame(fi*plen, plen, 0);
                emit_frame(1, gap);
            end
        end
    endtask

    // 逐帧喂 + 等它走完 (常规相: 占用恒在 1 帧量级 ⇒ 不撞满, 路径互相隔离)
    task feed_paced(input integer n, input integer plen);
        begin
            for (fi = 0; fi < n; fi = fi + 1) begin
                sp = 0;
                mk_udp_frame(fi*plen, plen, 0);
                emit_frame(1, 4);
                run_stim(0, sp);
                idle_drive(1800);
            end
        end
    endtask

    initial begin
        s_tvalid = 1'b0; s_tdata = 64'd0; s_tkeep = 8'd0;
        s_tlast = 1'b0; s_tuser = 1'b0; s_tcrs = 1'b0; s_terr = 1'b0;
        cfg_dip = MY_IP; paylen_v = PLEN[15:0];
        sp = 0; fail = 0;
        for (fi = 0; fi < NB; fi = fi + 1) payc[fi] = pay[fi];

        //---------------------------------------------------------------------
        // V1: 干净 4x1472B (逐帧, 有间隔) ⇒ **全部 v4 计数器增量必须为 0**
        //     (这是 A/B 两部的**负相例**: 没有一个计数器该动)
        //---------------------------------------------------------------------
        do_reset;
        for (fi = 0; fi < NB; fi = fi + 1) payc[fi] = pay[fi];
        paylen_v = PLEN[15:0];
        v4_snap;
        feed_paced(NFRM, PLEN);
        idle_drive(400);
        v4_dump("V1");
        chk(a_mismatch == s_mm, "V1 clean stream mismatched");
        chk(v4_cn == s_cn, "V1 CN != 0 on clean stream");
        chk(v4_rd == s_rd, "V1 RD != 0 on clean stream");
        chk(v4_nc == s_nc, "V1 NC != 0 (no null dgram)");
        chk(v4_np == s_np, "V1 NP != 0 (no null dgram)");
        chk(v4_wf == s_wf, "V1 WF != 0 (buffer never full)");
        chk(v4_rl == s_rl, "V1 RL != 0 (no rollback)");
        chk(v4_wc == s_wc, "V1 WC != 0 (word count probe)");
        chk(v4_ne == s_ne && v4_nr == s_nr && v4_mr == s_mr, "V1 NE/NR/MR != 0");
        chk(v4_en == 4'd0 && v4_eo == 1'b0, "V1 EN/EO != 0");
        chk(m_pop == NFRM*FW, "V1 delivered word count");

        //---------------------------------------------------------------------
        // V2: 帧首字节坏 x2, **隔帧** (帧 1 与 3) ⇒ **全孤立**
        //     NE=2 NR=2 MR=1 (判据: NR == NE) + 条目逐值
        //---------------------------------------------------------------------
        do_reset;
        for (fi = 0; fi < NB; fi = fi + 1) payc[fi] = pay[fi];
        payc[1*PLEN + 0] = pay[1*PLEN + 0] ^ 8'h40;
        payc[3*PLEN + 0] = pay[3*PLEN + 0] ^ 8'h01;
        paylen_v = PLEN[15:0];
        v4_snap;
        feed_paced(NFRM, PLEN);
        idle_drive(400);
        v4_dump("V2");
        chk(a_mismatch - s_mm == 2, "V2 mismatch bytes != 2");
        chk(v4_ne - s_ne == 2, "V2 NE != 2");
        chk(v4_nr - s_nr == 2, "V2 NR != 2 (must be 2 runs)");
        chk(v4_mr - s_mr == 1, "V2 MR != 1 (all isolated)");
        chk(v4_en == 4'd2, "V2 EN != 2");
        chk(v4_eo == 1'b0, "V2 EO != 0");
        // NE 与 v2 的 OZ 桶是**同一门** ⇒ 两条独立路径必须同步
        chk((v4_ne - s_ne) == (ds_oz - s_oz), "V2 NE != OZ delta (same gate!)");
        chk_q("V2", 0, v4_qa, q_exp(1));
        chk_q("V2", 1, v4_qb, q_exp(3));
        chk(v4_qc == 24'd0 && v4_qd == 24'd0, "V2 unused entries != 0");
        chk(v4_cn == s_cn && v4_wc == s_wc, "V2 CN/WC != 0");

        //---------------------------------------------------------------------
        // V3: 帧首字节坏 x3 **连续** (帧 1,2,3) ⇒ **含连续段**
        //     NE=3 NR=1 MR=3 (判据: NR < NE); 条目逐值 = 帧 1/2/3
        //---------------------------------------------------------------------
        do_reset;
        for (fi = 0; fi < NB; fi = fi + 1) payc[fi] = pay[fi];
        payc[1*PLEN + 0] = pay[1*PLEN + 0] ^ 8'h02;
        payc[2*PLEN + 0] = pay[2*PLEN + 0] ^ 8'h04;
        payc[3*PLEN + 0] = pay[3*PLEN + 0] ^ 8'h08;
        paylen_v = PLEN[15:0];
        v4_snap;
        feed_paced(NFRM, PLEN);
        idle_drive(400);
        v4_dump("V3");
        chk(v4_ne - s_ne == 3, "V3 NE != 3");
        chk(v4_nr - s_nr == 1, "V3 NR != 1 (one run expected)");
        chk(v4_mr - s_mr == 3, "V3 MR != 3");
        chk(v4_en == 4'd3, "V3 EN != 3");
        chk_q("V3", 0, v4_qa, q_exp(1));
        chk_q("V3", 1, v4_qb, q_exp(2));
        chk_q("V3", 2, v4_qc, q_exp(3));
        chk(v4_cn == s_cn && v4_wc == s_wc, "V3 CN/WC != 0");

        //---------------------------------------------------------------------
        // V4: 帧 1..10 **连坏 10 帧** ⇒ NR=1 MR=10 且 **EN=8 (FIFO 满) EO=1**
        //     (满了之后只计数不再入队 —— 明示"未记录", 不静默丢弃)
        //---------------------------------------------------------------------
        do_reset;
        for (fi = 0; fi < NB; fi = fi + 1) payc[fi] = pay[fi];
        for (fi = 1; fi <= 10; fi = fi + 1)
            payc[fi*PLEN + 0] = pay[fi*PLEN + 0] ^ 8'h33;
        paylen_v = PLEN[15:0];
        v4_snap;
        feed_paced(NF_V4, PLEN);
        idle_drive(400);
        v4_dump("V4");
        chk(v4_ne - s_ne == 10, "V4 NE != 10");
        chk(v4_nr - s_nr == 1, "V4 NR != 1");
        chk(v4_mr - s_mr == 10, "V4 MR != 10");
        chk(v4_en == 4'd8, "V4 EN != 8 (FIFO must saturate)");
        chk(v4_eo == 1'b1, "V4 EO != 1 (overflow flagged)");
        chk_q("V4", 0, v4_qa, q_exp(1));
        chk_q("V4", 1, v4_qb, q_exp(2));
        chk_q("V4", 2, v4_qc, q_exp(3));
        chk_q("V4", 3, v4_qd, q_exp(4));
        chk_q("V4", 4, v4_qe, q_exp(5));
        chk_q("V4", 5, v4_qf, q_exp(6));
        chk_q("V4", 6, v4_qg, q_exp(7));
        chk_q("V4", 7, v4_qh, q_exp(8));
        chk(v4_cn == s_cn && v4_wc == s_wc, "V4 CN/WC != 0");

        //---------------------------------------------------------------------
        // V9: **0 长数据报** + 其后 2 帧干净 ⇒ NC=1 NP=1, 其余全 0, 图案流不断
        //     (udp_rx 的 meta_len==0 特例; 也验证 app 侧的合成 null beat 不计失配)
        //---------------------------------------------------------------------
        do_reset;
        for (fi = 0; fi < NB; fi = fi + 1) payc[fi] = pay[fi];
        paylen_v = PLEN[15:0];
        v4_snap;
        sp = 0;
        mk_udp_frame(0, 0, 0);            // 帧 0: 0 长数据报 (42 字节, 6 字)
        emit_frame(1, 4);
        mk_udp_frame(0, PLEN, 0);         // 帧 1: 干净 1472B (图案流从 0 起)
        emit_frame(1, 4);
        mk_udp_frame(PLEN, PLEN, 0);      // 帧 2: 干净 1472B
        emit_frame(1, 4);
        run_stim(0, sp);
        idle_drive(4200);
        v4_dump("V9");
        chk(v4_nc - s_nc == 1, "V9 NC != 1 (null dgram event)");
        chk(v4_np - s_np == 1, "V9 NP != 1 (null dgram commit)");
        chk(v4_cn == s_cn && v4_rd == s_rd, "V9 CN/RD != 0");
        chk(v4_wf == s_wf && v4_rl == s_rl && v4_wc == s_wc, "V9 WF/RL/WC != 0");
        chk(v4_ne == s_ne && v4_nr == s_nr && v4_mr == s_mr, "V9 NE/NR/MR != 0");
        chk(a_mismatch == s_mm, "V9 null dgram broke stream");
        chk(a_rx_null - s_null == 1, "V9 app saw no null beat");
        chk(st_app_null == 32'd1, "V9 splitter null count != 1");

        //---------------------------------------------------------------------
        // V6: **字数一致性探针的正相例** —— 强偏 u_meta_len (+8 字节 = +1 字)
        //     4 帧 ⇒ WC=4 (每帧恰 1 次), 其余全 0。
        //     ⚠️ 这一相钉死 WC 的**口径**: 若照字面用"更新前的 hold_rem 值"直接比
        //        ceil(len/8), 干净流会**每帧都命中** (V1 已断言 WC==0 ⇒ 那种写法
        //        必然让 V1 变红); 而本相的 +8 强偏让"少算末字"与"多算一字"两种
        //        写法都能给出 4 ⇒ 真正有判别力的是 V1+V6 这一对。
        //---------------------------------------------------------------------
        do_reset;
        for (fi = 0; fi < NB; fi = fi + 1) payc[fi] = pay[fi];
        paylen_v = PLEN[15:0];
        v4_snap;
        @(negedge clk);
        force u_split.u_meta_len = 16'd1480;           // 真长度 1472 + 8 (= +1 字)
        feed_paced(NFRM, PLEN);
        @(negedge clk);
        release u_split.u_meta_len;
        idle_drive(400);
        v4_dump("V6");
        chk(f_len_seen == 16'd1480, "V6 force missed DUT (rx_len)");
        chk(v4_wc - s_wc == NFRM, "V6 WC != 4 (one per frame)");
        chk(v4_cn == s_cn && v4_rd == s_rd && v4_nc == s_nc && v4_np == s_np,
            "V6 CN/RD/NC/NP != 0");
        chk(v4_wf == s_wf && v4_rl == s_rl, "V6 WF/RL != 0");
        chk(v4_ne == s_ne && v4_nr == s_nr && v4_mr == s_mr, "V6 NE/NR/MR != 0");
        chk(a_mismatch == s_mm, "V6 pattern stream broke");

        //---------------------------------------------------------------------
        // V5: **CN 的正相例** —— 小帧 (8B = 1 字) 背靠背 ⇒ 消费者(1 字节/拍)
        //     跟不上生成器 ⇒ 描述符 FIFO 被填满 ⇒ CN >= 1 (载荷已写、帧没提交)。
        //     同时断言 WF=0: 载荷缓冲只涨 ~1 字/帧 ⇒ **两条路径被分开**
        //     (若这条红了, 说明本相的激励不是"只踩描述符满", 读数不可用)。
        //---------------------------------------------------------------------
        do_reset;
        for (fi = 0; fi < NB; fi = fi + 1) payc[fi] = pay[fi];
        paylen_v = PL_V5;
        v4_snap;
        load_frames(NF_V5, PL_V5, 0);      // 背靠背, 无帧间空隙
        run_stim(0, sp);
        idle_drive(20000);                 // 让读者把积压排空
        v4_dump("V5");
        // 机制旁证: 描述符 FIFO 的真实占用 (u_desc 的写-读指针差, 64 深)
        $display("RXPV4 V5 desc_occ=%0d (FIFO 深 64) app_frames=%0d st_drop_ovf=%0d",
                 u_split.u_desc.wptr - u_split.u_desc.rptr, a_rx_frames, st_drop_ovf);
        chk(v4_cn - s_cn >= 1, "V5 CN == 0 (desc FIFO not full)");
        // ★ 机制恒等式: 喂出的 900 帧 = 交付的帧 + 因描述符满被回卷的帧
        //   (本相无注入/无坏 FCS/无满溢出 ⇒ 无其他丢弃路径)。它把 CN 从"一个计数"
        //   变成"交付缺口"的直接度量 —— 若 CN 记错(漏拍/重计), 这条必红。
        chk(((a_rx_frames - s_rxf) + (v4_cn - s_cn)) == NF_V5,
            "V5 delivered+CN != fed");
        // C4 note: RL counts CYCLES; one cycle can serve CN++ and RD++ at once, so
        //   "CN+RD <= RL" is NOT a general law (it only holds for this stimulus,
        //   where each request gets its own rollback).  RL >= CN here is a
        //   phase-local check ("rollbacks are counted"), not a theorem.
        chk((v4_rl - s_rl) >= (v4_cn - s_cn), "V5 RL < CN (rollbacks missing)");
        chk(v4_wf == s_wf, "V5 WF != 0 (buffer hit full)");
        chk(v4_rd == s_rd && v4_nc == s_nc && v4_np == s_np, "V5 RD/NC/NP != 0");
        chk(v4_wc == s_wc, "V5 WC != 0");

        //---------------------------------------------------------------------
        // V7: **RD 的正相例** —— 声明长度 > 实际 (残帧: 无 TLAST) ⇒ 下一帧边界
        //     把它回卷作废。判据: RD=1; CN/NC/NP/WF/WC 全 0。
        //     ⚠️ 该帧的载荷字已被写进缓冲但从不交付 ⇒ 之后的图案流对不上,
        //        app 必然报失配 (本相**不**断言 NE/NR/MR, 只登记)。
        //---------------------------------------------------------------------
        do_reset;
        for (fi = 0; fi < NB; fi = fi + 1) payc[fi] = pay[fi];
        paylen_v = PLEN[15:0];
        v4_snap;
        sp = 0;
        mk_udp_frame(0, PLEN, 0);         // 帧 0: 好
        emit_frame(1, 4);
        mk_udp_frame(PLEN, PLEN, 1);      // 帧 1: 声明 > 实际 ⇒ 残帧
        emit_frame(1, 4);
        mk_udp_frame(2*PLEN, PLEN, 0);    // 帧 2: 好 (它的 meta_valid 触发回卷)
        emit_frame(1, 4);
        run_stim(0, sp);
        idle_drive(4200);
        v4_dump("V7");
        chk(v4_rd - s_rd == 1, "V7 RD != 1 (residue rewind)");
        chk((v4_rl - s_rl) >= 1, "V7 RL == 0 (rollback not counted)");
        chk(v4_cn == s_cn && v4_nc == s_nc && v4_np == s_np, "V7 CN/NC/NP != 0");
        chk(v4_wf == s_wf && v4_wc == s_wc, "V7 WF/WC != 0");
        chk(st_drop_part >= 32'd1, "V7 splitter stat_drop_part == 0");
        chk(v4_ne - s_ne >= 1, "V7 no offset-0 event after");

        //---------------------------------------------------------------------
        // V8: **WF 的正相例** —— 12 x 1472B 背靠背 (消费者 1 字节/拍, 生成器
        //     1 字/拍) ⇒ 载荷缓冲 (512 字) 被写满 ⇒ uf_ovf 吞字 (WF >= 1)。
        //     断言 WC=0: 被吞的帧不提交, 提交的帧字数仍自洽。
        //     CN == 0: 描述符 FIFO 不会满 (缓冲满 ⇒ 绝大多数帧被废, 提交数极少)。
        //---------------------------------------------------------------------
        do_reset;
        for (fi = 0; fi < NB; fi = fi + 1) payc[fi] = pay[fi];
        paylen_v = PLEN[15:0];
        v4_snap;
        load_frames(NF_V8, PLEN, 0);      // 背靠背
        run_stim(0, sp);
        idle_drive(30000);
        v4_dump("V8");
        chk(v4_wf - s_wf >= 1, "V8 WF == 0 (buffer never full)");
        chk(v4_wc == s_wc, "V8 WC != 0 (bad word count)");
        chk(v4_rd == s_rd && v4_nc == s_nc && v4_np == s_np, "V8 RD/NC/NP != 0");
        chk(v4_cn == s_cn, "V8 CN != 0 (desc FIFO filled)");
        chk(st_drop_ovf >= 32'd1, "V8 splitter stat_drop_ovf == 0");

        chk(stall_cyc == 0, "tready went 0 (TB over-fed)");
        if (fail == 0) $display("RXP-V4 GATE: OK");
        else           $display("RXP-V4 GATE: FAIL (%0d)", fail);
        $finish;
    end

    // 看门狗
    initial begin
        repeat (4000000) @(posedge clk);
        $display("RXP-V4 GATE: FAIL (timeout) pop=%0d done=%0d", m_pop, m_done);
        $finish;
    end
endmodule
