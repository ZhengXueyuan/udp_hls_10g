`timescale 1ns/1ps
//=============================================================================
// tb_rxp_v5.v — RXP_DIAG **v5** 的功能门 (ISSUE_RX_BYTE_CORRUPTION §14.6 / §18.8)
//
// 【v5 的被测对象】
//   A 部 (udp_split 内的**第二个 LFSR 校验器**, 直接架在 u_uf 的写数据口 u_m_d 上):
//     DV = 首个失配处的**累计字节序号** (纯计数锚, 不按帧号定址)
//     DG/DE = 该处收到的 / 期望的字节
//     DO    = 该失配在**本帧内**的字节偏移
//     DM    = 失配字节总数 (整轮累计)
//     VZ    = 快照有效 (粘滞, 只记首个)
//   B 部 (udp_split 内 udp_rx 的**解析器计数器**, 原来内部悬空、从未显示):
//     PS = stat_pass (匹配且 FCS 好)   NM = stat_drop_nonmatch
//     IC = stat_drop_ipcsum            DC = stat_drop_crc
//     SB = stat_bytes  (匹配帧的载荷字节数)
//
// 【A 部要证伪的那条假设 (§14.6 第一条)】
//   v3 的写侧指纹 SW (`wh_word[w_commit_cnt[2:0]]`, **按帧号定址**, 在帧首拍采样)
//   依赖"该帧的载荷字不与 meta_valid 同拍"这条**无法从 TB 构造**的结构假设。
//   v5 的校验器**不按帧号定址, 只按字节计数推进** ⇒ 机制不同 ⇒ 两条路径若结论一致,
//   SW 的归因就不再是孤证; 若不一致, 就是那条假设有假。
//
// 【LFSR 逐字节同约定的**动态证明** (本门最硬的一条)】
//   约定 (xorshift64, seed 0x9E3779B97F4A7C15, **先取后推进**, byte = s>>24) 由源码
//   同款写死; 但"同款"是**声明**, 不是证据。真正的证据是**同一次失配两条路径给出
//   同一个全局字节序号**: W1/W3/W4 里注入一个(或两个)已知坏字节, 断言
//     DV == app 的 ds_idx (II)   且   DM == app 的 stat_mismatch (UMM)
//   —— 若两个 LFSR 有任何一个字节的相位差, 首个失配点必然不同一 (先坏/后坏), 这两条
//   断言就会红。⇒ "逐字节同约定"是被**测**出来的, 不是被**声称**的。
//
// 【相位与判据 (每相先复位; A/B 两部的判据口径不同, 见下)】
//   W1 A 正相: 4x1472B 干净 + 帧 2 偏移 100 处翻 1 字节
//              ⇒ DV=3044 DG=坏值 DE=干净值 DO=100 DM=1 VZ=1
//                且 DV==ds_idx, DM==stat_mismatch, DO==DV%PLEN (与 II%paylen 对照)
//   W2 A 零相 + B 正相(PS/SB): 纯干净 4x1472B
//              ⇒ DM=0 VZ=0 且 DM/DV/DG/DE/DO 全 0; 同时 **v5_cnt == 4*1472**
//                (证明校验器**真的在跑**, 不是"死 0"); PS 增量=4, SB 增量=4*1472,
//                NM/IC/DC 增量=0; 且 PS == app 的 stat_rx_frames 增量 (URF 判据)
//   W3 A 正相(同字两处): 帧 2 偏移 100 与 103 各翻 1 字节
//              ⇒ DM=2 (计数全部失配字节) 而 DV/DO 仍指**第一个** (100)
//   W4 A 正相(部分末字): 帧长 1471 (非 8 的倍数, 帧末字 7 字节)
//              注入 全局 1470 (帧 0 偏移 1470, 帧末字 lane6) 与全局 1471 (帧 1 偏移 0)
//              ⇒ DV=1470 DO=1470 DM=2 且 DV==ds_idx
//   W5 B 正相(NM): 4 帧打到**未配置端口** ⇒ NM 增量=4, 其余四个增量全 0
//   W6 B 正相(IC): 4 帧 IP 头校验和被翻位 ⇒ IC 增量=4, 其余四个增量全 0
//   W7 B 正相(DC): 4 帧头好、FCS 坏       ⇒ DC 增量=4, PS/SB/NM/IC 增量全 0
//      ⚠️ **口径的现场证据 (我原先写错过一次, 在这里改正)**: 被回卷的整帧**不会**让
//         A 部的内容校验失真 —— 写流仍是"图案流的前缀"(回卷只把写指针退回去, 不改
//         内容; 下一帧仍在同一地址写自己的字节), 而 A 部的期望值也正是"按累计字节
//         序号取图案流" ⇒ 本相**断言 DM=0 / VZ=0** (这是**正**证据, 不是"作废")。
//         真正被回卷破坏的是**两条机制的序号可比性**: app 的字节序号只数**交付**的
//         字节, 回卷掉的整帧被跳过 ⇒ `DV == II` / `DM == UMM` 只在 RL==0 时成立。
//         (WF>0 则内容也不成立: 被吞的字让写流出现空洞。) 板级 8/8 轮 RL=WF=0。
//         ⇒ 本相单独断言 RL>=1 与 DM=0 同现 —— 这正是"内容 vs 序号"两件事的判别实验。
//
// 运行: sim/rxpdiag/run_tb_rxp_v5.bat (独立目录, 防 xsim.dir 文件锁 — 坑 7)
//=============================================================================
module tb_rxp_v5;

    localparam [31:0] MY_IP    = 32'hC0A86402;   // 192.168.100.2
    localparam [31:0] PEER_IP  = 32'hC00A0001;   // 192.168.100.1
    localparam [15:0] APP_PORT = 16'd9000;
    localparam integer PLEN    = 1472;           // 板级载荷 (184 字)
    localparam integer PLEN4   = 1471;           // W4: 非 8 的倍数 ⇒ 帧末字 7 字节
    localparam integer NFRM    = 4;
    localparam integer NB      = 32768;          // 图案数组 (W4: 5x1471 = 7355)

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

    //=========================================================================
    // DUT: udp_split (真播放器 + 真回卷 + **v5 写侧校验器**) + app_udp_pattern
    //=========================================================================
    reg  [63:0] s_tdata;  reg [7:0] s_tkeep;  reg s_tvalid;
    wire        s_tready;
    reg         s_tlast, s_tuser, s_tcrs, s_terr;
    wire [63:0] p_tdata;  wire [7:0] p_tkeep; wire p_tvalid;
    wire        p_tlast, p_tuser, p_tcrs, p_terr;
    wire        p_tready = 1'b1;
    wire [63:0] a_tdata;  wire [7:0] a_tkeep; wire a_tvalid; wire a_tlast, a_sof;
    wire [15:0] a_len;    wire [31:0] a_sip;  wire [15:0] a_sport;
    wire        a_tready;
    reg  [15:0] paylen_v;                        // app 的 i_paylen (逐相设置)

    reg  [31:0] cfg_dip;
    wire [31:0] st_app_frames, st_app_bytes, st_app_null, st_drop_crc,
                st_drop_ovf, st_drop_part, st_drop_excl,
                st_hls_frames, st_hls_drop, st_hls_split;

    // v3/v4 观测口 (与 tb_rxp_v4.v 同款; 本门只为跨代对账/probe 存在)
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
    wire [15:0] v4_cn, v4_rd, v4_nc, v4_np, v4_wf, v4_rl, v4_wc;

    // v5 观测口 (A 部: 写侧纯计数 LFSR 校验器; B 部: udp_rx 的解析器计数)
    wire [31:0] v5_dv, v5_dm;
    wire [7:0]  v5_dg, v5_de;
    wire [15:0] v5_do;
    wire        v5_vz;
    wire [31:0] v5_ps, v5_nm, v5_ic, v5_dc, v5_sb;

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
        .v4_wf(v4_wf), .v4_rl(v4_rl), .v4_wc(v4_wc),
        .v5_dv_idx(v5_dv), .v5_dv_got(v5_dg), .v5_dv_exp(v5_de),
        .v5_dv_off(v5_do), .v5_dv_mm(v5_dm), .v5_dv_v(v5_vz),
        .v5_up_pass(v5_ps), .v5_up_nm(v5_nm), .v5_up_ipc(v5_ic),
        .v5_up_crc(v5_dc), .v5_up_bytes(v5_sb)
    );

    wire [31:0] ds_idx, ds_b1, ds_b2, ds_bg, ds_dup;
    wire [7:0]  ds_got, ds_exp, ds_prev;
    wire        ds_v;
    wire [63:0] ds_gw, ds_ew;
    wire [31:0] ds_oz, ds_ol, ds_om, ds_oh;
    wire [31:0] a_rx_bytes, a_rx_frames, a_rx_null, a_mismatch;
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
    integer m_sof;          // app 侧见过的帧首数
    integer m_done;
    integer m_null;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_pop <= 0; m_sof <= 0; m_done <= 0; m_null <= 0;
        end else if (a_tvalid && a_tready) begin
            if (a_sof) begin
                m_sof <= m_sof + 1;
                if (a_len == 16'd0) m_null <= m_null + 1;
            end
            if (a_len != 16'd0) m_pop <= m_pop + 1;
            if (a_tlast)        m_done <= m_done + 1;
        end
    end

    // 绝不反压观测 (TB 若灌得比读者排空更快, 会破坏"结构性不反压"前提)
    integer stall_cyc;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) stall_cyc <= 0;
        else if (!s_tready) stall_cyc <= stall_cyc + 1;

    //=========================================================================
    // 激励: 构造 classify-slow 字流 (帧头与 tb_rxp_v3/v4 同款)
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

    // 每帧可变的头参数 (逐相设置; 必须在 task 之前声明 —— xvlog 先声明后用)
    reg [15:0] dport_v;         // 目的端口 (W5 = 未配置端口)
    reg        ipc_bad;         // 1 = IP 头校验和翻 1 位 (W6)

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
            if (ipc_bad) fb[24] = h_ck[15:8] ^ 8'h01;       // 翻 LSB ⇒ ipcsum_ok=0
            else begin fb[24] = h_ck[15:8]; fb[25] = h_ck[7:0]; end
        end
    endtask

    integer u_i; reg [15:0] u_len;
    // base = 该帧载荷在图案流里的起点; plen = 载荷字节数; bad_udplen: 声明 > 实际
    task mk_udp_frame(input integer base, input integer plen, input integer bad_udplen);
        begin
            mk_hdr(plen + 28);
            fb_put16(16'h3039);            // sport
            fb_put16(dport_v);             // dport
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
    // DUT-facing 信号, 同一步内其它进程会采到不同值 ⇒ 假故障。
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

    integer wt_i;
    task idle_drive(input integer n);
        begin
            for (r_i = 0; r_i < n; r_i = r_i + 1) begin
                @(posedge clk);
                s_tvalid <= 1'b0; s_tdata <= 64'd0; s_tkeep <= 8'd0;
                s_tlast <= 1'b0;  s_tuser <= 1'b0; s_tcrs <= 1'b0; s_terr <= 1'b0;
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
    // 基线快照 (B 部计数器是**本轮累计** ⇒ A 部用绝对值、B 部用增量)
    //=========================================================================
    integer s_ps, s_nm, s_ic, s_dc, s_sb, s_rxf, s_mm, s_rl;
    task v5_snap;
        begin
            s_ps = v5_ps; s_nm = v5_nm; s_ic = v5_ic; s_dc = v5_dc;
            s_sb = v5_sb; s_rxf = a_rx_frames; s_mm = a_mismatch; s_rl = v4_rl;
        end
    endtask

    task v5_dump(input [255:0] nm);
        begin
            $display("RXPV5 A %0s dv=%0d dg=%02X de=%02X do=%0d dm=%0d vz=%0d | cnt=%0d",
                     nm, v5_dv, v5_dg, v5_de, v5_do, v5_dm, v5_vz,
                     u_split.v5_cnt);
            $display("RXPV5 B %0s dPS=%0d dNM=%0d dIC=%0d dDC=%0d dSB=%0d | dURF=%0d dRL=%0d",
                     nm, v5_ps-s_ps, v5_nm-s_nm, v5_ic-s_ic,
                     v5_dc-s_dc, v5_sb-s_sb, a_rx_frames-s_rxf, v4_rl-s_rl);
        end
    endtask

    //=========================================================================
    // 相位
    //=========================================================================
    integer fi, wi, inj_i;

    // 逐帧喂 + 等它走完 (占用恒在 1 帧量级 ⇒ 路径互相隔离, 不撞满/不回卷)
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

    task clean_pat;
        begin
            for (fi = 0; fi < NB; fi = fi + 1) payc[fi] = pay[fi];
        end
    endtask

    initial begin
        s_tvalid = 1'b0; s_tdata = 64'd0; s_tkeep = 8'd0;
        s_tlast = 1'b0; s_tuser = 1'b0; s_tcrs = 1'b0; s_terr = 1'b0;
        cfg_dip = MY_IP; paylen_v = PLEN[15:0];
        dport_v = APP_PORT; ipc_bad = 1'b0;
        sp = 0; fail = 0;
        clean_pat;

        //---------------------------------------------------------------------
        // W1: A 部**正相** —— 单个已知失配 (帧 2 偏移 100 ⇒ 全局 3044)
        //---------------------------------------------------------------------
        do_reset;
        clean_pat;
        payc[2*PLEN + 100] = pay[2*PLEN + 100] ^ 8'h40;
        paylen_v = PLEN[15:0];
        v5_snap;
        feed_paced(NFRM, PLEN);
        idle_drive(400);
        v5_dump("W1");
        chk(v5_dv === 32'd3044, "W1 DV != 3044 (global byte index of the injection)");
        chk(v5_dg === (pay[3044] ^ 8'h40), "W1 DG != injected byte");
        chk(v5_de === pay[3044], "W1 DE != clean pattern byte");
        chk(v5_do === 16'd100, "W1 DO != 100 (frame offset)");
        chk(v5_dm === 32'd1, "W1 DM != 1");
        chk(v5_vz === 1'b1, "W1 VZ != 1");
        // ★ LFSR 逐字节同约定的**动态**证明: 同一失配两条路径给同一个全局字节号
        chk(v5_dv === ds_idx, "W1 DV != app ds_idx (LFSR phase mismatch!)");
        chk(v5_dm === a_mismatch, "W1 DM != app stat_mismatch");
        chk(v5_do === (v5_dv % 32'd1472), "W1 DO != DV % paylen");
        chk(u_split.v5_cnt === 32'd5888, "W1 v5_cnt != 4*1472 bytes fed");
        chk(v5_ps - s_ps === NFRM, "W1 PS != 4");

        //---------------------------------------------------------------------
        // W2: A 部**零相** + B 部正相 (PS/SB) —— 纯干净流
        //---------------------------------------------------------------------
        do_reset;
        clean_pat;
        paylen_v = PLEN[15:0];
        v5_snap;
        feed_paced(NFRM, PLEN);
        idle_drive(400);
        v5_dump("W2");
        chk(v5_dm === 32'd0, "W2 DM != 0 on clean stream");
        chk(v5_vz === 1'b0, "W2 VZ != 0 on clean stream");
        chk(v5_dv === 32'd0 && v5_dg === 8'd0 && v5_de === 8'd0 && v5_do === 16'd0,
            "W2 DV/DG/DE/DO != 0 on clean stream");
        // 反"死 0": 字节计数器必须恰好等于喂出的字节数 (校验器真的跑满了全程)
        chk(u_split.v5_cnt === 32'd5888, "W2 v5_cnt != 4*1472 (checker dead?)");
        chk(a_mismatch === s_mm, "W2 app mismatch != 0");
        // B 部正相
        chk(v5_ps - s_ps === NFRM, "W2 PS != 4");
        chk(v5_sb - s_sb === NFRM*PLEN, "W2 SB != 4*1472");
        chk(v5_ps - s_ps === a_rx_frames - s_rxf, "W2 PS != app frames (URF criterion)");
        chk(v5_nm - s_nm === 0, "W2 NM != 0");
        chk(v5_ic - s_ic === 0, "W2 IC != 0");
        chk(v5_dc - s_dc === 0, "W2 DC != 0");
        chk((v5_ps - s_ps) !== (v5_sb - s_sb), "W2 PS == SB (fields not distinguishable)");

        //---------------------------------------------------------------------
        // W3: A 部正相 —— **同一字内两处**失配
        //     ⇒ DM 记全部 (2) 而 DV/DO 仍指**第一个**
        //---------------------------------------------------------------------
        do_reset;
        clean_pat;
        payc[2*PLEN + 100] = pay[2*PLEN + 100] ^ 8'h40;   // 字内 lane4
        payc[2*PLEN + 103] = pay[2*PLEN + 103] ^ 8'h01;   // 同一字 lane7
        paylen_v = PLEN[15:0];
        v5_snap;
        feed_paced(NFRM, PLEN);
        idle_drive(400);
        v5_dump("W3");
        chk(v5_dv === 32'd3044, "W3 DV != 3044 (first of the two)");
        chk(v5_dg === (pay[3044] ^ 8'h40), "W3 DG != first bad byte");
        chk(v5_de === pay[3044], "W3 DE != clean pattern byte");
        chk(v5_do === 16'd100, "W3 DO != 100");
        chk(v5_dm === 32'd2, "W3 DM != 2 (must count BOTH bad bytes)");
        chk(v5_dv === ds_idx && v5_dm === a_mismatch, "W3 DV/DM != app II/UMM");
        chk(u_split.v5_cnt === 32'd5888, "W3 v5_cnt != 4*1472 bytes fed");

        //---------------------------------------------------------------------
        // W4: A 部正相 —— **部分末字** (帧长 1471, 非 8 的倍数 ⇒ 末字 7 字节)
        //     注入 全局 1470 (帧 0 偏移 1470, 帧末字 lane 6) 与 1471 (帧 1 偏移 0)
        //⇒ 同时验证: ① popcount 推进 (末字只推进 7 字节); ② 帧内偏移跨帧正确复位
        //---------------------------------------------------------------------
        do_reset;
        clean_pat;
        payc[1470] = pay[1470] ^ 8'h20;
        payc[1471] = pay[1471] ^ 8'h04;
        paylen_v = PLEN4[15:0];
        v5_snap;
        feed_paced(NFRM, PLEN4);
        idle_drive(400);
        v5_dump("W4");
        chk(v5_dv === 32'd1470, "W4 DV != 1470 (last byte of a 7-byte tail word)");
        chk(v5_dg === (pay[1470] ^ 8'h20), "W4 DG != injected byte");
        chk(v5_de === pay[1470], "W4 DE != clean pattern byte");
        chk(v5_do === 16'd1470, "W4 DO != 1470 (frame offset)");
        chk(v5_dm === 32'd2, "W4 DM != 2");
        chk(v5_dv === ds_idx, "W4 DV != app ds_idx (popcount anchor mismatch!)");
        chk(v5_dm === a_mismatch, "W4 DM != app stat_mismatch");
        chk(v5_do === (v5_dv % 32'd1471), "W4 DO != DV % paylen");
        chk(u_split.v5_cnt === 32'd5884, "W4 v5_cnt != 4*1471 bytes fed");
        chk(v5_ps - s_ps === NFRM, "W4 PS != 4");
        chk(v5_sb - s_sb === NFRM*PLEN4, "W4 SB != 4*1471");

        //---------------------------------------------------------------------
        // W5: B 部正相 (NM) —— 4 帧打到**未配置端口** ⇒ 解析器在 w4 丢弃
        //     (⇒ 无载荷字写入 ⇒ A 部校验器**零推进**, 这本身也是一条口径证据)
        //---------------------------------------------------------------------
        do_reset;
        clean_pat;
        dport_v = 16'h1234;                      // 未配置端口 (cfg_port0..3 = 9000/FF..)
        paylen_v = PLEN[15:0];
        v5_snap;
        feed_paced(NFRM, PLEN);
        idle_drive(400);
        v5_dump("W5");
        chk(v5_nm - s_nm === NFRM, "W5 NM != 4 (unconfigured port)");
        chk(v5_ps - s_ps === 0, "W5 PS != 0");
        chk(v5_sb - s_sb === 0, "W5 SB != 0");
        chk(v5_ic - s_ic === 0, "W5 IC != 0");
        chk(v5_dc - s_dc === 0, "W5 DC != 0");
        chk(u_split.v5_cnt === 32'd0, "W5 v5_cnt != 0 (no payload written)");
        dport_v = APP_PORT;

        //---------------------------------------------------------------------
        // W6: B 部正相 (IC) —— IP 头校验和翻 1 位 ⇒ 在 w4 被 ipcsum 丢弃
        //---------------------------------------------------------------------
        do_reset;
        clean_pat;
        ipc_bad = 1'b1;
        paylen_v = PLEN[15:0];
        v5_snap;
        feed_paced(NFRM, PLEN);
        idle_drive(400);
        v5_dump("W6");
        chk(v5_ic - s_ic === NFRM, "W6 IC != 4 (bad IP header checksum)");
        chk(v5_ps - s_ps === 0, "W6 PS != 0");
        chk(v5_sb - s_sb === 0, "W6 SB != 0");
        chk(v5_nm - s_nm === 0, "W6 NM != 0");
        chk(v5_dc - s_dc === 0, "W6 DC != 0");
        ipc_bad = 1'b0;

        //---------------------------------------------------------------------
        // W7: B 部正相 (DC) —— 头全好、**FCS 坏** ⇒ udp_rx 记 stat_drop_crc,
        //     udp_split 在帧尾回卷丢弃 ⇒ RL>0。
        //     ⚠️ 本相**只登记 B 部**: 回卷会把"已写但从不交付"的字节留在 A 部计数里
        //        ⇒ A 部必然错位 —— 这张表就是"读数前先看 RL"这条口径的现场证据。
        //---------------------------------------------------------------------
        do_reset;
        clean_pat;
        paylen_v = PLEN[15:0];
        v5_snap;
        for (fi = 0; fi < NFRM; fi = fi + 1) begin
            sp = 0;
            mk_udp_frame(fi*PLEN, PLEN, 0);
            emit_frame(0, 4);                    // crc_ok = 0
            run_stim(0, sp);
            idle_drive(1800);
        end
        idle_drive(400);
        v5_dump("W7");
        chk(v5_dc - s_dc === NFRM, "W7 DC != 4 (bad FCS, header fine)");
        chk(v5_ps - s_ps === 0, "W7 PS != 0");
        chk(v5_sb - s_sb === 0, "W7 SB != 0");
        chk(v5_nm - s_nm === 0, "W7 NM != 0");
        chk(v5_ic - s_ic === 0, "W7 IC != 0");
        chk(v4_rl - s_rl >= 1, "W7 RL == 0 (rollback not exercised)");
        // ★ 回卷不改写流内容: 期望值按**累计写入字节序号**取图案流, 被回卷的整帧
        //   内容仍是那条前缀 ⇒ DM/VZ 必须仍是 0 (与 app 的"0 交付"并存)。
        //   这一对 (RL>0 且 DM==0) 就是"内容 vs 序号"两件事的判别证据。
        chk(v5_dm === 32'd0, "W7 DM != 0 (rollback must not perturb the write stream)");
        chk(v5_vz === 1'b0, "W7 VZ != 0 (rollback must not perturb the write stream)");
        chk(u_split.v5_cnt === 32'd5888, "W7 v5_cnt != all words were written");
        chk(a_rx_frames - s_rxf === 0, "W7 app delivered frames != 0 (frames must be killed)");
        $display("RXPV5 W7 NOTE: RL=%0d (4 frames rolled back) while dURF=0 and DM=0 => rollback moves the write pointer but does NOT perturb the written byte sequence; it only shifts the app-side byte indices (DV==II holds only when RL==0 and WF==0).", v4_rl - s_rl);

        chk(stall_cyc == 0, "tready went 0 (TB over-fed)");
        if (fail == 0) $display("RXP-V5 GATE: OK");
        else           $display("RXP-V5 GATE: FAIL (%0d)", fail);
        $finish;
    end

    // 看门狗
    initial begin
        repeat (2000000) @(posedge clk);
        $display("RXP-V5 GATE: FAIL (timeout) pop=%0d done=%0d", m_pop, m_done);
        $finish;
    end
endmodule
