`timescale 1ns/1ps
//=============================================================================
// tb_app_udp — P5e-T3/T4: UDP 演示 app 单元门 (自检式, 无 Python 依赖)
//=============================================================================
// 被测链 (**与 board/wrapper_p4.v 的 APP_MODE 支逐项同构**):
//
//   [RX ]  TB 帧流 (UDP/IP/Eth 字流, 无前导/FCS) → udp_split
//              ├─ p_axis → slow_rx_adp (HLS 侧: stat_commit/stat_drop)
//              └─ app_rx → app_udp_pattern (逐字节图案校验)
//   [学习] udp_split.meta_* → udp_tx_cfg.peer_wr/mac/ip   (**learn-on-RX**)
//   [TX ]  app_udp_pattern.m_* → udp_tx_cfg (peer 门 + cfg 锁存)
//                              → udp_tx_frame (长度守卫) → tx_arb → TB 捕获
//
// 末行: "P5E UDP APP GATE: OK" / "P5E UDP APP GATE: FAIL <n>"
//
// ---- 正例 (默认模式) -------------------------------------------------------
//  P① app RX 载荷逐字节 = 图案 (跨帧连续) + meta_* 值正确 (src_mac/ip/port/len)
//  P② app TX 上线的 UDP 帧逐字节正确 (MAC/IP/UDP 头 + 双校验和 + 长度 + 载荷)
//  P③ 边界: i_paylen = 0 / 1472 / 1500 / 1501 (1501 帧内中止 + stat_drop_len,
//            前后帧照常; 每段之间静默窗验证"没有多余帧 / 中止帧零泄漏")
//  P④ 突发/背压: 8×1472B 零间隙线速连灌 (8x 于 app 消费率) ⇒
//            stat_app_frames + stat_drop_ovf == 8 (丢帧计数自洽),
//            stat_drop_part == 0, 交付字节 == stat_app_bytes, 且
//            s_axis_tready 全程恒 1 (T1 的"结构性不反压"性质不得被削弱)
//  P⑤ learn-on-RX: 收到一帧 ⇒ o_ready=1 且随后 TX 帧的目标 = **该帧的 src**;
//            再收到 peer B 一帧 ⇒ 后续 TX 帧目标换成 B (帧间可变)
//
// ---- 负对照 (plusarg 选模式; 断言"只有性质成立才成立"的量) -------------------
//  N1 SPLITOFF : 拆分器 cfg 全哨兵 (T1 的透明配置) ⇒ app RX **0 帧**,
//                HLS 侧 stat_commit = 注入帧数 (UDP 逐字走慢路径)
//  N2 PORTOUT  : 端口过滤外的 UDP (dport=9090) ⇒ app RX 0 帧 + HLS 侧见 echo
//  N3 BADCRC   : 匹配帧但 FCS 坏 ⇒ app RX 0 帧 + stat_drop_crc = 1 (不得误当好帧)
//  N4 NOPEER   : 一个 RX 帧都不注入 ⇒ peer 表空 ⇒ TX **零帧** (保守设计)
//=============================================================================
module tb_app_udp;
    // ---- 配置常量 (镜像 wrapper: MY_MAC/MY_IP/APP_PORT) ----
    localparam [47:0] MY_MAC   = 48'h000A3501FEC0;
    localparam [31:0] MY_IP    = 32'hC0A86402;   // 192.168.100.2
    localparam [15:0] APP_PORT = 16'h1F91;       // 8081 (udp_split.cfg_port0)
    localparam [47:0] PA_MAC   = 48'h112233445566;
    localparam [31:0] PA_IP    = 32'hC0A86401;   // 192.168.100.1
    localparam [15:0] PA_PORT  = 16'h3039;
    localparam [47:0] PB_MAC   = 48'hAABBCCDDEEFF;
    localparam [31:0] PB_IP    = 32'hC0A8647F;
    localparam [15:0] PB_PORT  = 16'h303A;
    localparam [15:0] OTHER_PORT = 16'd9090;     // N2: 过滤外端口

    localparam integer FBASE = 2048;             // 捕获帧槽步长 (B)
    localparam integer FTOT  = 32;               // 捕获帧数上限
    localparam integer STIMN = 8192;             // 激励拍数上限
    localparam [63:0]  SEED  = 64'h9E3779B97F4A7C15;

    reg clk, rst_n;
    initial clk = 1'b0;
    always #4 clk = ~clk;                        // 125 MHz

    // udp_split 的 RX 学习线束 (声明必须早于 peer_wr_eff / 两个例化点)
    wire        udp_meta_valid;
    wire [47:0] udp_meta_smac;
    wire [31:0] udp_meta_sip;
    wire [15:0] udp_meta_sport, udp_meta_len;

    integer errs;
    // 主时间线用的整型 (声明必须在引用它们的 task 之前: xvlog 先声明后用)
    integer i, t0, seg_a, seg_b;
    integer mis_base, split_base, bytes_base, frames_base;
    task chk;
        input          cond;
        input [8*96:1] msg;
        begin
            if (!cond) begin errs = errs + 1; $display("  [FAIL] %0s", msg); end
        end
    endtask

    // ---- 模式 ----
    reg m_splitoff, m_portout, m_badcrc, m_nopeer, m_any_neg, m_neglearn;
    initial begin
        m_splitoff = $test$plusargs("SPLITOFF");
        m_portout  = $test$plusargs("PORTOUT");
        m_badcrc   = $test$plusargs("BADCRC");
        m_nopeer   = $test$plusargs("NOPEER");
        m_neglearn = $test$plusargs("NEGLEARN");
        m_any_neg  = m_splitoff | m_portout | m_badcrc | m_nopeer;
    end
    // NEGLEARN (P5d 风格负对照, **期望门 FAIL / exit 1**): 把 peer 学习源钉成 0,
    // 复现 T2 的"UDP 无连接 ⇒ 学不到 peer"配置 ⇒ 正例判据 (P⑤/③) 必然不成立。
    // 这是"修复确实被门抓到"的唯一判别性证据 —— 没有它, 正例全绿也可能只是
    // 因为别处偶然把 peer 表填上了。
    wire peer_wr_eff = m_neglearn ? 1'b0 : udp_meta_valid;

    //=========================================================================
    // 图案流 (xorshift64, 先取后推进; 与 app_udp_pattern / peer.cpp 逐字节一致)
    //=========================================================================
    localparam integer PATMAX = 40000;
    reg  [7:0] pat [0:PATMAX-1];       // RX 侧注入图案 (按注入顺序连续)
    integer    pat_n;
    reg  [63:0] glfsr;
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
    task pat_push(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                pat[pat_n] = glfsr[31:24];
                glfsr      = xs_next(glfsr);
                pat_n      = pat_n + 1;
            end
        end
    endtask

    //=========================================================================
    // 帧构造 → 激励拍流 (与 mac_rx_64 语义一致: 无前导/FCS, tcrs 只落末拍)
    //=========================================================================
    reg  [7:0] fb [0:2047];
    integer    flen;
    reg [63:0] stim_d [0:STIMN-1];
    reg [7:0]  stim_k [0:STIMN-1];
    reg        stim_v [0:STIMN-1];
    reg        stim_l [0:STIMN-1], stim_u [0:STIMN-1], stim_c [0:STIMN-1];
    integer    sp;

    task fb_put(input [7:0] b); begin fb[flen] = b; flen = flen + 1; end endtask
    task fb_put16(input [15:0] v); begin
        fb[flen] = v[15:8]; fb[flen+1] = v[7:0]; flen = flen + 2; end endtask
    task fb_put32(input [31:0] v); begin
        fb[flen]=v[31:24]; fb[flen+1]=v[23:16]; fb[flen+2]=v[15:8]; fb[flen+3]=v[7:0];
        flen = flen + 4; end endtask

    integer h_i; reg [19:0] h_sum; reg [16:0] h_f1; reg [15:0] h_ck;
    task mk_eth_ip(input [47:0] dmac, input [47:0] smac, input [31:0] sip,
                   input [31:0] dip, input [15:0] iplen);
        begin
            flen = 0;
            fb_put32(dmac[47:16]); fb_put16(dmac[15:0]);
            fb_put32(smac[47:16]); fb_put16(smac[15:0]);
            fb_put16(16'h0800);
            fb_put(8'h45); fb_put(8'h00);
            fb_put16(iplen); fb_put16(16'h1234); fb_put16(16'h4000);
            fb_put(8'd64); fb_put(8'h11);
            fb_put16(16'h0000);
            fb_put32(sip); fb_put32(dip);
            h_sum = 20'd0;
            for (h_i = 0; h_i < 10; h_i = h_i + 1)
                h_sum = h_sum + {4'b0, fb[14+2*h_i], fb[15+2*h_i]};
            h_f1 = h_sum[15:0] + {12'b0, h_sum[19:16]};
            h_ck = ~(h_f1[15:0] + {15'b0, h_f1[16]});
            fb[24] = h_ck[15:8]; fb[25] = h_ck[7:0];
        end
    endtask

    // UDP 数据报: 载荷 = TB 图案流的**当前连续前缀** (pat_push 就地追加)
    task mk_udp_pat(input [47:0] dmac, input [47:0] smac, input [31:0] sip,
                    input [31:0] dip, input [15:0] sport, input [15:0] dport,
                    input integer plen);
        begin
            mk_eth_ip(dmac, smac, sip, dip, plen + 28);
            fb_put16(sport); fb_put16(dport);
            fb_put16(plen + 8); fb_put16(16'h0000);   // UDP 校验和占位 (RX 侧不判)
            pat_push(plen);
            for (h_i = 0; h_i < plen; h_i = h_i + 1)
                fb_put(pat[pat_n - plen + h_i]);
        end
    endtask

    // 把 fbuf 拍成 AXIS 字流段 (SOP=首字, crc_ok 只落末拍); gap 个空拍收尾
    integer e_w, e_b, e_nw, e_nb; reg [63:0] e_d; reg [7:0] e_k;
    task emit_frame(input integer crc_ok, input integer gap);
        begin
            e_nw = (flen + 7) / 8;
            for (e_w = 0; e_w < e_nw; e_w = e_w + 1) begin
                e_nb = flen - e_w*8;  if (e_nb > 8) e_nb = 8;
                e_d = 64'd0;  e_k = 8'hFF << (8 - e_nb);
                for (e_b = 0; e_b < e_nb; e_b = e_b + 1)
                    e_d[63 - 8*e_b -: 8] = fb[e_w*8 + e_b];
                stim_d[sp] = e_d; stim_k[sp] = e_k; stim_v[sp] = 1'b1;
                stim_u[sp] = (e_w == 0); stim_l[sp] = (e_w == e_nw-1);
                stim_c[sp] = (e_w == e_nw-1) && (crc_ok != 0);
                sp = sp + 1;
            end
            for (e_w = 0; e_w < gap; e_w = e_w + 1) begin
                stim_d[sp] = 64'd0; stim_k[sp] = 8'h00; stim_v[sp] = 1'b0;
                stim_u[sp] = 1'b0;  stim_l[sp] = 1'b0;  stim_c[sp] = 1'b0;
                sp = sp + 1;
            end
        end
    endtask

    //=========================================================================
    // DUT
    //=========================================================================
    reg        s_tv;
    reg [63:0] s_td; reg [7:0] s_tk; reg s_tl, s_tu, s_tc, s_te;
    wire       s_tr;
    wire [63:0] p_td; wire [7:0] p_tk; wire p_tv, p_tl, p_tu, p_tc, p_te;
    wire        p_tr;
    wire [63:0] ar_td; wire [7:0] ar_tk; wire ar_tv, ar_tl, ar_sof;
    wire [15:0] ar_len, ar_sport; wire [31:0] ar_sip;
    wire        ar_tr;
    reg  [31:0] cfg_dip_r; reg cfg_multi_r, cfg_any_r;
    reg  [15:0] cfg_p0_r, cfg_p1_r, cfg_p2_r, cfg_p3_r;
    reg  [31:0] cfg_dip; reg cfg_multi, cfg_any;
    reg  [15:0] cfg_p0, cfg_p1, cfg_p2, cfg_p3;
    wire [31:0] st_app_frames, st_app_bytes, st_app_null, st_drop_crc,
                st_drop_ovf, st_drop_part, st_drop_excl,
                st_hls_frames, st_hls_drop, st_hls_split;
    wire [31:0] srx_commit, srx_drop;
    wire [15:0] hls_rx_td; wire hls_rx_tv, hls_rst_n_w;
    wire [21:0] srx_starv; wire srx_hls_rst;
    wire        cf_ready;

    udp_split #(.EXCL_PORT(16'd8080)) u_split (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_td), .s_axis_tkeep(s_tk), .s_axis_tvalid(s_tv),
        .s_axis_tready(s_tr), .s_axis_tlast(s_tl), .s_axis_tuser(s_tu),
        .s_axis_tcrs(s_tc), .s_axis_terr(s_te),
        .p_axis_tdata(p_td), .p_axis_tkeep(p_tk), .p_axis_tvalid(p_tv),
        .p_axis_tready(p_tr), .p_axis_tlast(p_tl), .p_axis_tuser(p_tu),
        .p_axis_tcrs(p_tc), .p_axis_terr(p_te),
        .app_rx_tdata(ar_td), .app_rx_tkeep(ar_tk), .app_rx_tvalid(ar_tv),
        .app_rx_tready(ar_tr), .app_rx_tlast(ar_tl), .app_rx_sof(ar_sof),
        .app_rx_len(ar_len), .app_rx_src_ip(ar_sip), .app_rx_src_port(ar_sport),
        .meta_valid(udp_meta_valid), .meta_src_mac(udp_meta_smac),
        .meta_src_ip(udp_meta_sip), .meta_src_port(udp_meta_sport),
        .meta_len(udp_meta_len),
        .cfg_dst_ip(cfg_dip), .cfg_multi_en(cfg_multi),
        .cfg_port0(cfg_p0), .cfg_port1(cfg_p1),
        .cfg_port2(cfg_p2), .cfg_port3(cfg_p3), .cfg_port_any(cfg_any),
        .stat_app_frames(st_app_frames), .stat_app_bytes(st_app_bytes),
        .stat_app_null(st_app_null), .stat_drop_crc(st_drop_crc),
        .stat_drop_ovf(st_drop_ovf), .stat_drop_part(st_drop_part),
        .stat_drop_excl(st_drop_excl), .stat_hls_frames(st_hls_frames),
        .stat_hls_drop(st_hls_drop), .stat_hls_split(st_hls_split)
    );

    // ---- HLS 侧消费者 (与 wrapper 一致: slow_rx_adp + HLS 恒就绪) ----
    assign p_tr = 1'b1;                         // slow_rx_adp 契约: 恒 1
    slow_rx_adp u_slow_rx (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(p_td), .s_axis_tkeep(p_tk), .s_axis_tvalid(p_tv),
        .s_axis_tready(p_tr), .s_axis_tlast(p_tl), .s_axis_tuser(p_tu),
        .s_axis_tcrs(p_tc), .s_axis_terr(p_te),
        .hls_rx_tdata(hls_rx_td), .hls_rx_tvalid(hls_rx_tv),
        .hls_rx_tready(1'b1), .hls_rst_n(hls_rst_n_w),
        .stat_commit(srx_commit), .stat_drop(srx_drop),
        .dbg_starv(srx_starv), .dbg_hls_rst(srx_hls_rst)
    );

    // ---- app UDP 演示 (TX_GAP 放大到 5000: 给 TB 留停帧窗口; 板级 = 58000) ----
    reg         i_en, i_en_r;
    reg  [11:0] i_paylen, i_paylen_r;
    wire [63:0] am_td; wire [7:0] am_tk; wire am_tv, am_tr, am_tl;
    wire [31:0] a_tx_bytes, a_tx_frames, a_rx_bytes, a_rx_frames, a_rx_null, a_mismatch;
    wire        a_active, a_done; wire [3:0] a_led;

    app_udp_pattern #(.TX_BYTES(32'd0), .TX_GAP(16'd5000)) u_app (
        .clk(clk), .rst_n(rst_n),
        .i_en(i_en), .i_tx_ready(cf_ready), .i_paylen(i_paylen),
        .m_tdata(am_td), .m_tkeep(am_tk), .m_tvalid(am_tv),
        .m_tready(am_tr), .m_tlast(am_tl),
        .rx_tdata(ar_td), .rx_tkeep(ar_tk), .rx_tvalid(ar_tv),
        .rx_tready(ar_tr), .rx_tlast(ar_tl), .rx_sof(ar_sof), .rx_len(ar_len),
        .stat_tx_bytes(a_tx_bytes), .stat_tx_frames(a_tx_frames),
        .stat_rx_bytes(a_rx_bytes), .stat_rx_frames(a_rx_frames),
        .stat_rx_null(a_rx_null), .stat_mismatch(a_mismatch),
        .active(a_active), .done(a_done), .led(a_led)
    );

    // ---- 第二实例: **有界会话** TX_BYTES=1000 (连续模式 TX_BYTES=0 由主实例覆盖) ----
    // 判据: 恰好 1000 字节 / 1 帧 (单帧 = min(1000, i_paylen)) / done 粘滞 / 之后零拍。
    // (i_tx_ready 恒 1: 本实例只验"发完即停 + 末帧取余数", peer 门由主实例覆盖)
    wire [63:0] b_td; wire [7:0] b_tk; wire b_tv, b_tr, b_tl;
    wire [31:0] b_bytes, b_frames; wire b_act, b_done;
    integer     b_nbeats, b_nbytes, b_nbeats_late;

    app_udp_pattern #(.TX_BYTES(32'd1000), .TX_GAP(16'd10)) u_app_b (
        .clk(clk), .rst_n(rst_n),
        .i_en(i_en), .i_tx_ready(1'b1), .i_paylen(12'd1472),
        .m_tdata(b_td), .m_tkeep(b_tk), .m_tvalid(b_tv),
        .m_tready(b_tr), .m_tlast(b_tl),
        .rx_tdata(64'd0), .rx_tkeep(8'h00), .rx_tvalid(1'b0),
        .rx_tready(), .rx_tlast(1'b0), .rx_sof(1'b0), .rx_len(16'd0),
        .stat_tx_bytes(b_bytes), .stat_tx_frames(b_frames),
        .stat_rx_bytes(), .stat_rx_frames(), .stat_rx_null(), .stat_mismatch(),
        .active(b_act), .done(b_done), .led()
    );
    assign b_tr = 1'b1;
    always @(posedge clk) begin
        if (b_tv && b_tr) begin
            b_nbeats = b_nbeats + 1;
            b_nbytes = b_nbytes + {28'b0, pop8(b_tk)};
        end
    end

    // ---- TX 链: udp_tx_cfg (peer 门) → udp_tx_frame (守卫) → tx_arb ----
    wire [63:0] utx_td; wire [7:0] utx_tk; wire utx_tv, utx_tr, utx_tl;
    wire [47:0] cf_dmac, cf_smac; wire [31:0] cf_dip, cf_sip;
    wire [15:0] cf_dport, cf_sport; wire cf_csum;
    wire [31:0] cf_frames, cf_deny; wire u_busy;
    wire [63:0] u2_td; wire [7:0] u2_tk; wire u2_tv, u2_tr, u2_tl;
    wire [31:0] tx_frames, tx_bytes, tx_drop_len;
    wire [63:0] m_td; wire [7:0] m_tk; wire m_tv, m_tr, m_tl; wire mrg_slow_ready;

    udp_tx_cfg u_cfg (
        .clk(clk), .rst_n(rst_n),
        // **learn-on-RX**: 与 wrapper 同一驱动源 (udp_split.meta_*;
        // NEGLEARN 负对照时钉 0 = 复现 T2 的无学习源配置)
        .peer_wr(peer_wr_eff), .peer_mac(udp_meta_smac), .peer_ip(udp_meta_sip),
        .frame_busy(u_busy),
        .cfg_my_mac(MY_MAC), .cfg_my_ip(MY_IP),
        .cfg_my_port(APP_PORT), .cfg_dst_port(APP_PORT), .cfg_csum_en(1'b1),
        .s_axis_tdata(am_td), .s_axis_tkeep(am_tk), .s_axis_tvalid(am_tv),
        .s_axis_tready(am_tr), .s_axis_tlast(am_tl),
        .m_axis_tdata(utx_td), .m_axis_tkeep(utx_tk), .m_axis_tvalid(utx_tv),
        .m_axis_tready(utx_tr), .m_axis_tlast(utx_tl),
        .o_dst_mac(cf_dmac), .o_dst_ip(cf_dip), .o_dst_port(cf_dport),
        .o_src_mac(cf_smac), .o_src_ip(cf_sip), .o_src_port(cf_sport),
        .o_csum_en(cf_csum), .o_ready(cf_ready),
        .stat_frames(cf_frames), .stat_deny(cf_deny)
    );

    udp_tx_frame u_tx (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(utx_td), .s_axis_tkeep(utx_tk), .s_axis_tvalid(utx_tv),
        .s_axis_tready(utx_tr), .s_axis_tlast(utx_tl),
        .cfg_src_mac(cf_smac), .cfg_dst_mac(cf_dmac),
        .cfg_src_ip(cf_sip), .cfg_dst_ip(cf_dip),
        .cfg_src_port(cf_sport), .cfg_dst_port(cf_dport), .cfg_csum_en(cf_csum),
        .m_axis_tdata(u2_td), .m_axis_tkeep(u2_tk), .m_axis_tvalid(u2_tv),
        .m_axis_tready(u2_tr), .m_axis_tlast(u2_tl),
        .stat_frames(tx_frames), .stat_bytes(tx_bytes), .stat_drop_len(tx_drop_len),
        .o_busy(u_busy)
    );

    tx_arb u_arb (
        .clk(clk), .rst_n(rst_n),
        .s_fast_tdata(u2_td), .s_fast_tkeep(u2_tk), .s_fast_tvalid(u2_tv),
        .s_fast_tready(u2_tr), .s_fast_tlast(u2_tl),
        .s_slow_tdata(64'd0), .s_slow_tkeep(8'h00), .s_slow_tvalid(1'b0),
        .s_slow_tready(mrg_slow_ready), .s_slow_tlast(1'b0),
        .m_axis_tdata(m_td), .m_axis_tkeep(m_tk), .m_axis_tvalid(m_tv),
        .m_axis_tready(m_tr), .m_axis_tlast(m_tl)
    );
    assign m_tr = 1'b1;                        // 消费者恒就绪 (背压面在 DUT 内)

    //=========================================================================
    // 捕获: TX 帧字节流 (逐帧) + app RX 口 snoop (独立于 DUT 自计数的旁证)
    //=========================================================================
    reg  [7:0] fr [0:FBASE*FTOT-1];
    integer    fr_len [0:FTOT-1];
    integer    nfr, fcnt, bbi;
    always @(posedge clk) begin
        if (m_tv && m_tr) begin
            for (bbi = 0; bbi < 8; bbi = bbi + 1) begin
                if (m_tk[7-bbi] && (nfr < FTOT) && (fcnt < FBASE-1)) begin
                    fr[nfr*FBASE + fcnt] = m_td[63 - 8*bbi -: 8];
                    fcnt = fcnt + 1;
                end
            end
            if (m_tl) begin
                if (nfr < FTOT) fr_len[nfr] = fcnt;
                nfr = nfr + 1; fcnt = 0;
            end
        end
    end

    function [3:0] pop8;
        input [7:0] v;
        integer i; reg [3:0] c;
        begin
            c = 4'd0;
            for (i = 0; i < 8; i = i + 1) c = c + {3'b0, v[i]};
            pop8 = c;
        end
    endfunction

    // tkeep 必须高位连续 (本工程 AXIS 约定)
    wire ar_badkeep = (ar_tk !== (8'hFF << (4'd8 - pop8(ar_tk))));

    integer snoop_bytes, snoop_frames, snoop_null, snoop_badkeep;
    always @(posedge clk) begin
        if (ar_tv && ar_tr) begin
            snoop_bytes = snoop_bytes + {28'b0, pop8(ar_tk)};
            if (ar_badkeep) snoop_badkeep = snoop_badkeep + 1;
            if (ar_sof) snoop_frames = snoop_frames + 1;
            if (ar_sof && (ar_len == 16'd0)) snoop_null = snoop_null + 1;
        end
    end

    // s_axis_tready 恒 1 断言 (T1 的性质; 任何一拍掉 0 即 FAIL)
    integer stall_cyc;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) stall_cyc <= 0;
        else if (!s_tr) stall_cyc <= stall_cyc + 1;

    // meta 脉冲计数 + 最后一次快照
    integer meta_cnt;
    reg [47:0] meta_smac_l; reg [31:0] meta_sip_l;
    reg [15:0] meta_sport_l, meta_len_l;
    always @(posedge clk) begin
        if (udp_meta_valid) begin
            meta_cnt     = meta_cnt + 1;
            meta_smac_l  = udp_meta_smac;
            meta_sip_l   = udp_meta_sip;
            meta_sport_l = udp_meta_sport;
            meta_len_l   = udp_meta_len;
        end
    end

    //=========================================================================
    // 校验和辅助 / 判据
    //=========================================================================
    integer    cbase; reg [31:0] csum_acc;
    task csum_add;
        input integer off; input integer nb;
        integer i;
        begin
            for (i = 0; i + 1 < nb; i = i + 2)
                csum_acc = csum_acc + {fr[cbase+off+i], fr[cbase+off+i+1]};
            if (nb % 2) csum_acc = csum_acc + {fr[cbase+off+nb-1], 8'h00};
        end
    endtask
    function [15:0] fold32;
        input [31:0] s;
        reg [16:0] t;
        begin
            t = s[15:0] + s[31:16];
            t = t[15:0] + t[16];
            fold32 = t[15:0];
        end
    endfunction

    // 帧头/校验和检查 (载荷另由 check_all_pattern 统一逐字节过一遍)
    task check_frame;
        input integer k;
        input [47:0] edmac;
        input [31:0] edip;
        input integer plen;
        reg [15:0] u_len;
        begin
            cbase = k * FBASE;
            $display("  第 %0d 帧: len=%0d (期望 %0d) dst_mac=%012h dst_ip=%08h",
                     k, fr_len[k], plen + 42, edmac, edip);
            chk(fr_len[k] === (plen + 42), "TX 帧长 = 42 + 载荷");
            chk({fr[cbase+0],fr[cbase+1],fr[cbase+2],fr[cbase+3],fr[cbase+4],fr[cbase+5]}
                === edmac, "TX dst mac = 学到的 peer");
            chk({fr[cbase+6],fr[cbase+7],fr[cbase+8],fr[cbase+9],fr[cbase+10],fr[cbase+11]}
                === MY_MAC, "TX src mac = 本机");
            chk({fr[cbase+12],fr[cbase+13]} === 16'h0800, "TX ethertype = IPv4");
            chk(fr[cbase+23] === 8'h11, "TX IP proto = UDP");
            chk({fr[cbase+16],fr[cbase+17]} === (plen + 28), "TX IP total_len");
            csum_acc = 32'd0; csum_add(14, 20);
            chk(fold32(csum_acc) === 16'hFFFF, "TX IP 头校验和正确");
            chk({fr[cbase+26],fr[cbase+27],fr[cbase+28],fr[cbase+29]} === MY_IP, "TX src ip");
            chk({fr[cbase+30],fr[cbase+31],fr[cbase+32],fr[cbase+33]} === edip, "TX dst ip = peer");
            chk({fr[cbase+34],fr[cbase+35]} === APP_PORT, "TX src port = 8081");
            chk({fr[cbase+36],fr[cbase+37]} === APP_PORT, "TX dst port = 8081");
            u_len = {fr[cbase+38], fr[cbase+39]};
            chk(u_len === (plen + 8), "TX UDP len");
            csum_acc = 32'd0;
            csum_add(26, 8);
            csum_acc = csum_acc + 16'h0011 + u_len;
            csum_add(34, 8 + plen);
            chk(fold32(csum_acc) === 16'hFFFF, "TX UDP 校验和正确 (伪头+头+载荷)");
        end
    endtask

    // 全部捕获帧的载荷 = app TX 图案流的**连续**前缀 (中止帧不进流 ⇒ 连续)
    reg  [63:0] txv_lfsr;
    integer     txv_bad;
    task check_all_pattern;
        integer k, i;
        begin
            txv_lfsr = SEED; txv_bad = 0;
            for (k = 0; k < nfr && k < FTOT; k = k + 1) begin
                for (i = 42; i < fr_len[k]; i = i + 1) begin
                    if (fr[k*FBASE+i] !== txv_lfsr[31:24]) txv_bad = txv_bad + 1;
                    txv_lfsr = xs_next(txv_lfsr);
                end
            end
            chk(txv_bad == 0, "P② 全部 TX 帧载荷 = 图案流连续前缀 (逐字节)");
        end
    endtask

    //=========================================================================
    // 激励驱动 / 小工具
    //=========================================================================
    integer r_i;
    task run_stim(input integer a, input integer b);
        begin
            for (r_i = a; r_i < b; r_i = r_i + 1) begin
                @(posedge clk);
                s_tv <= stim_v[r_i]; s_td <= stim_d[r_i]; s_tk <= stim_k[r_i];
                s_tl <= stim_l[r_i]; s_tu <= stim_u[r_i]; s_tc <= stim_c[r_i];
                s_te <= 1'b0;
            end
            @(posedge clk);
            s_tv <= 1'b0; s_td <= 64'd0; s_tk <= 8'h00;
            s_tl <= 1'b0; s_tu <= 1'b0; s_tc <= 1'b0; s_te <= 1'b0;
        end
    endtask

    task wait_cycles(input integer n);
        integer i;
        begin for (i = 0; i < n; i = i + 1) @(posedge clk); end
    endtask

    // 等捕获帧数达到 tgt (最多 lim 拍), 然后立刻关 TX (i_en=0) ——
    // 靠 TX_GAP 窗口保证下一帧起不来 (i_en=0 落在 T_GAP/T_FRM 都只收尾当前帧)
    integer w_i;
    task one_frame_then_stop(input integer lim, input integer tgt);
        begin
            for (w_i = 0; w_i < lim; w_i = w_i + 1) begin
                if (nfr >= tgt) w_i = lim; else @(posedge clk);
            end
            i_en_r = 1'b0; i_en <= 1'b0;
            wait_cycles(3000);
        end
    endtask

    task set_cfg(input integer split_on);
        begin
            cfg_dip_r <= MY_IP;
            cfg_p0_r  <= split_on ? APP_PORT : 16'hFFFF;   // 关 = T1 透明哨兵配置
            cfg_p1_r  <= 16'hFFFF; cfg_p2_r <= 16'hFFFF; cfg_p3_r <= 16'hFFFF;
            cfg_any_r <= 1'b0;     cfg_multi_r <= 1'b0;
        end
    endtask

    initial begin
        errs = 0; pat_n = 0; glfsr = SEED; txv_lfsr = SEED; txv_bad = 0;
        sp = 0; flen = 0; nfr = 0; fcnt = 0;
        rst_n = 1'b0; s_tv = 1'b0; s_td = 0; s_tk = 0; s_tl = 0;
        s_tu = 0; s_tc = 0; s_te = 0;
        cfg_dip_r = MY_IP; cfg_multi_r = 0; cfg_any_r = 0;
        cfg_p0_r = APP_PORT; cfg_p1_r = 16'hFFFF;
        cfg_p2_r = 16'hFFFF; cfg_p3_r = 16'hFFFF;
        i_en_r = 1'b0; i_paylen_r = 12'd1472;
        snoop_bytes = 0; snoop_frames = 0; snoop_null = 0; snoop_badkeep = 0;
        b_nbeats = 0; b_nbytes = 0; b_nbeats_late = 0;
        meta_cnt = 0; meta_smac_l = 0; meta_sip_l = 0; meta_sport_l = 0; meta_len_l = 0;
        t0 = 0; seg_a = 0; seg_b = 0;
        mis_base = 0; split_base = 0; bytes_base = 0; frames_base = 0;

        // ---- cfg 落地 + 复位 ----
        cfg_dip <= cfg_dip_r; cfg_multi <= cfg_multi_r; cfg_any <= cfg_any_r;
        cfg_p0 <= cfg_p0_r; cfg_p1 <= cfg_p1_r; cfg_p2 <= cfg_p2_r; cfg_p3 <= cfg_p3_r;
        i_en <= 1'b0; i_paylen <= i_paylen_r;
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (40) @(posedge clk);
        $display("P5E UDP APP: splitoff=%b portout=%b badcrc=%b nopeer=%b",
                 m_splitoff, m_portout, m_badcrc, m_nopeer);

        //=====================================================================
        // N4 / P⑤-neg: peer 表空 ⇒ TX 零帧 (复位后未注入任何帧)
        //=====================================================================
        i_en_r = 1'b1; i_en <= 1'b1;
        wait_cycles(3000);
        chk(cf_ready === 1'b0, "N4 peer 表空 ⇒ o_ready = 0");
        chk(nfr == 0,          "N4 peer 表空 ⇒ TX 零帧 (保守设计)");
        chk(cf_deny == 32'd0,  "N4 app 侧先挡住 (i_tx_ready=0), 一帧都没推出去");
        if (m_nopeer) begin
            if (errs == 0) $display("P5E UDP APP GATE: OK (NOPEER: TX 零帧, meta 脉冲 %0d)", meta_cnt);
            else           $display("P5E UDP APP GATE: FAIL errs=%0d", errs);
            $finish;
        end

        //=====================================================================
        // 注入段 A: 命中帧 (peerA) ×2 + 0 长数据报 (图案跨帧连续)
        //=====================================================================
        set_cfg(!m_splitoff);                        // N1: 全哨兵 (拆分器"关")
        glfsr = SEED;                                // 本段图案自 offset 0
        if (m_splitoff) begin
            mk_udp_pat(MY_MAC, PA_MAC, PA_IP, MY_IP, PA_PORT, APP_PORT, 1472);
            emit_frame(1, 40);
            mk_udp_pat(MY_MAC, PA_MAC, PA_IP, MY_IP, PA_PORT, APP_PORT, 1472);
            emit_frame(1, 40);
        end else if (m_portout) begin
            mk_udp_pat(MY_MAC, PA_MAC, PA_IP, MY_IP, PA_PORT, OTHER_PORT, 1472);
            emit_frame(1, 40);
        end else if (m_badcrc) begin
            mk_udp_pat(MY_MAC, PA_MAC, PA_IP, MY_IP, PA_PORT, APP_PORT, 1472);
            emit_frame(0, 40);                       // 坏 FCS (tcrs=0)
        end else begin
            mk_udp_pat(MY_MAC, PA_MAC, PA_IP, MY_IP, PA_PORT, APP_PORT, 1472);
            emit_frame(1, 40);
            mk_udp_pat(MY_MAC, PA_MAC, PA_IP, MY_IP, PA_PORT, APP_PORT, 1472);
            emit_frame(1, 40);
            mk_udp_pat(MY_MAC, PA_MAC, PA_IP, MY_IP, PA_PORT, APP_PORT, 0);
            emit_frame(1, 200);
        end
        repeat (2) @(posedge clk);
        cfg_dip <= cfg_dip_r; cfg_p0 <= cfg_p0_r; cfg_p1 <= cfg_p1_r;
        cfg_p2 <= cfg_p2_r; cfg_p3 <= cfg_p3_r; cfg_any <= cfg_any_r;
        seg_a = 0; seg_b = sp;
        run_stim(seg_a, seg_b);
        wait_cycles(40000);                          // app RX 校验器排空 (1 字节/拍)

        //---------------------------------------------------------------------
        // 负对照分流点 (N1/N2/N3)
        //---------------------------------------------------------------------
        if (m_any_neg) begin
            $display("  [dbg] neg: app_frames=%0d drop_crc=%0d drop_ovf=%0d drop_part=%0d hls_frames=%0d hls_split=%0d commit=%0d srx_drop=%0d nfr=%0d ready=%b meta_cnt=%0d",
                     st_app_frames, st_drop_crc, st_drop_ovf, st_drop_part,
                     st_hls_frames, st_hls_split, srx_commit, srx_drop,
                     nfr, cf_ready, meta_cnt);
            chk(st_app_frames == 32'd0, "N? app RX 0 帧");
            chk(snoop_frames == 0,      "N? app 口零拍");
            if (m_splitoff || m_portout) begin
                chk(nfr == 0,           "N1/N2 无可学帧 (未匹配) ⇒ TX 仍零帧");
            end
            if (m_splitoff) begin
                chk(st_hls_frames == 32'd2, "N1 拆分器关 ⇒ 2 帧走 HLS 慢路径");
                chk(srx_commit == 32'd2,    "N1 拆分器关 ⇒ HLS 侧见 echo (stat_commit=2)");
                chk(meta_cnt == 0,          "N1 拆分器关 ⇒ 无 meta 脉冲 (零学习)");
            end
            if (m_portout) begin
                chk(st_hls_frames == 32'd1, "N2 端口过滤外 ⇒ 仍走 HLS");
                chk(srx_commit == 32'd1,    "N2 端口过滤外 ⇒ HLS 侧见 echo");
                chk(meta_cnt == 0,          "N2 端口过滤外 ⇒ 无 meta 脉冲");
            end
            if (m_badcrc) begin
                chk(st_drop_crc == 32'd1,   "N3 坏 FCS ⇒ stat_drop_crc = 1");
                chk(st_drop_part == 32'd0,  "N3 坏 FCS ⇒ 有 TLAST ⇒ 无残帧计数");
                chk(st_hls_frames == 32'd0, "N3 坏 FCS ⇒ 已判为 app 帧, 不进 HLS");
                chk(st_hls_split == 32'd1,  "N3 坏 FCS ⇒ 从 HLS 路撤回 1 帧");
                chk(meta_cnt == 1,          "N3 坏 FCS ⇒ meta 仍脉冲 1 次 (见下语义边界)");
                // **本层已文档化的语义边界**: meta_valid 在 w5 (头字段收全) 即脉冲,
                // FCS 到 TLAST 才知道 ⇒ 坏 FCS 帧也会被学入 peer 表 (下一好帧覆盖)。
                // 这条断言把该语义钉死; 要改成"仅好帧才学"必须同时改 udp_split 头注释
                // 与本条 (代价: 把 meta 缓存到 TLAST = 新增状态)。
                chk(cf_ready === 1'b1,      "N3 (文档化边界) 坏 FCS 帧头字段仍被学入 peer 表");
                chk(nfr > 0,                "N3 (文档化边界) 学到 peer 后 TX 照常启动");
            end
            if (errs == 0) $display("P5E UDP APP GATE: OK (neg mode)");
            else           $display("P5E UDP APP GATE: FAIL errs=%0d", errs);
            $finish;
        end

        //=====================================================================
        // P① app RX 载荷逐字节 + meta_* 正确
        //=====================================================================
        $display("  [dbg] RX: app_frames=%0d app_bytes=%0d rx_bytes=%0d rx_frames=%0d rx_null=%0d mismatch=%0d meta_cnt=%0d",
                 st_app_frames, st_app_bytes, a_rx_bytes, a_rx_frames, a_rx_null,
                 a_mismatch, meta_cnt);
        chk(st_app_frames == 32'd3,     "P① 3 帧交付 app (2×1472 + 1×0)");
        chk(snoop_frames == 3,          "P① app 口恰 3 帧");
        chk(snoop_null == 1,            "P① 其中 1 帧是 0 长 (null beat)");
        chk(a_rx_frames == 32'd3,       "P① app 计 3 帧");
        chk(a_rx_null == 32'd1,         "P① app 计 1 个 0 长数据报");
        chk(a_rx_bytes == 32'd2944,     "P① app 校验 2944 字节");
        chk(snoop_bytes == 2944,        "P① app 口 snoop 2944 字节 (独立旁证)");
        chk(a_mismatch == 32'd0,        "P① app RX **零失配** (载荷逐字节 = 图案)");
        chk(snoop_badkeep == 0,         "P① app 口 tkeep 全程高位连续");
        chk(meta_cnt == 3,              "P① meta_valid 恰 3 个脉冲 (每帧 1 次)");
        chk(meta_smac_l === PA_MAC,     "P① meta_src_mac = 注入帧的 src mac");
        chk(meta_sip_l === PA_IP,       "P① meta_src_ip = 注入帧的 src ip");
        chk(meta_sport_l === PA_PORT,   "P① meta_src_port = 注入帧的 src port");
        chk(meta_len_l === 16'd0,       "P① meta_len = 末帧 (0 长) 的载荷长度");
        chk(st_hls_frames == 32'd0,     "P① 命中帧零泄漏到 HLS");
        chk(st_hls_split == 32'd3,      "P① 3 帧从 HLS 路撤回");

        //=====================================================================
        // P⑤ learn-on-RX: 收到帧 ⇒ o_ready=1; 首帧 TX 目标 = 该帧 src
        //=====================================================================
        chk(cf_ready === 1'b1,          "P⑤ 收到对端一帧后 o_ready = 1 (learn-on-RX)");
        chk(nfr >= 1,                   "P⑤ 学到 peer 后 app 立即开始发帧");
        chk(fr_len[0] === (1472+42),    "P⑤ 首帧 = 42 + 1472");
        check_frame(0, PA_MAC, PA_IP, 1472);

        // ---- 停 TX (i_en=0): 当前帧收完即静默 ----
        i_en_r = 1'b0; i_en <= 1'b0;
        wait_cycles(6000);
        t0 = nfr;
        wait_cycles(3000);
        chk(nfr == t0, "P③ i_en=0 ⇒ TX 静默 (无残余帧)");

        //=====================================================================
        // P③ 边界扫描: i_paylen = 0 / 1472 / 1500 / 1501 (1501 中止)
        //=====================================================================
        // -- (a) 0 长数据报 --
        i_paylen_r = 12'd0; i_paylen <= i_paylen_r;
        wait_cycles(4);
        i_en_r = 1'b1; i_en <= 1'b1;
        one_frame_then_stop(60000, t0 + 1);
        chk(nfr == t0 + 1, "P③(a) 0 长: 恰 1 帧上线");
        check_frame(t0, PA_MAC, PA_IP, 0);
        $display("  [dbg] (a) 0 长: len=%0d drop_len=%0d tx_frames=%0d", fr_len[t0], tx_drop_len, tx_frames);

        // -- (b) 1472 (契约上限) --
        i_paylen_r = 12'd1472; i_paylen <= i_paylen_r;
        wait_cycles(4);
        i_en_r = 1'b1; i_en <= 1'b1;
        one_frame_then_stop(60000, t0 + 2);
        chk(nfr == t0 + 2, "P③(b) 1472: 恰 1 帧上线");
        check_frame(t0+1, PA_MAC, PA_IP, 1472);

        // -- (c) 1500 (udp_tx_frame.PLEN_MAX 阈值下限, 必须照发) --
        i_paylen_r = 12'd1500; i_paylen <= i_paylen_r;
        wait_cycles(4);
        i_en_r = 1'b1; i_en <= 1'b1;
        one_frame_then_stop(60000, t0 + 3);
        chk(nfr == t0 + 3, "P③(c) 1500: 恰 1 帧上线 (阈值下限)");
        check_frame(t0+2, PA_MAC, PA_IP, 1500);

        // -- (d) 1501 (> 契约上限): 帧内中止 + 零泄漏, 随后帧照常 --
        //    app 帧已启动后关 i_en 只会让当前帧收尾 ⇒ 恰好 1 次中止
        i_paylen_r = 12'd1501; i_paylen <= i_paylen_r;
        wait_cycles(4);
        i_en_r = 1'b1; i_en <= 1'b1;
        wait_cycles(3000);                     // 帧已启动 (交付 188 字 ~1504 拍)
        i_en_r = 1'b0; i_en <= 1'b0;
        wait_cycles(6000);
        chk(nfr == t0 + 3, "P③(d) 1501: **零帧上线** (帧内中止)");
        chk(tx_drop_len == 32'd1, "P③(d) stat_drop_len = 1");
        i_paylen_r = 12'd1472; i_paylen <= i_paylen_r;
        wait_cycles(4);
        i_en_r = 1'b1; i_en <= 1'b1;
        one_frame_then_stop(60000, t0 + 4);
        chk(nfr == t0 + 4, "P③(d) 中止后后续帧照常 (1472 上线)");
        check_frame(t0+3, PA_MAC, PA_IP, 1472);
        chk(tx_frames == nfr, "P③ TX 帧器计数 == 捕获帧数 (中止帧不计数)");

        //=====================================================================
        // P③(e/f) RX 侧边界: 1500 / 1501 字节载荷 (RX 路径无长度守卫, 走 4KB 帧缓冲)
        //=====================================================================
        glfsr = SEED;                                // i_en 上升沿 ⇒ app 期望序列自 SEED
        i_en_r = 1'b1; i_en <= 1'b1;
        wait_cycles(100);
        frames_base = st_app_frames; bytes_base = snoop_bytes;
        mk_udp_pat(MY_MAC, PA_MAC, PA_IP, MY_IP, PA_PORT, APP_PORT, 1500);
        emit_frame(1, 40);
        mk_udp_pat(MY_MAC, PA_MAC, PA_IP, MY_IP, PA_PORT, APP_PORT, 1501);
        emit_frame(1, 400);
        seg_a = seg_b; seg_b = sp;
        run_stim(seg_a, seg_b);
        wait_cycles(40000);
        $display("  [dbg] RX 边界: app_frames+%0d rx_bytes+%0d mismatch=%0d",
                 st_app_frames - frames_base, snoop_bytes - bytes_base, a_mismatch);
        chk(st_app_frames - frames_base == 32'd2, "P③(e/f) RX 1500+1501 字节载荷均交付 app");
        chk(snoop_bytes - bytes_base == 3001,     "P③(e/f) app 口收 3001 字节 (无半帧/无丢字)");
        chk(a_mismatch == 32'd0,                  "P③(e/f) RX 边界载荷逐字节零失配");
        chk(snoop_badkeep == 0,                   "P③(e/f) app 口 tkeep 仍高位连续");

        //=====================================================================
        // P⑤b 第二次 learn-on-RX: 换 peer B ⇒ 后续 TX 目标换成 B
        //=====================================================================
        // i_en 必须**先落再起** (上升沿才重置 RX 期望序列 ⇒ 新段图案自 SEED)
        i_en_r = 1'b0; i_en <= 1'b0;
        wait_cycles(200);
        glfsr = SEED;
        i_en_r = 1'b1; i_en <= 1'b1;
        wait_cycles(2000);
        mk_udp_pat(MY_MAC, PB_MAC, PB_IP, MY_IP, PB_PORT, APP_PORT, 1472);
        emit_frame(1, 200);
        seg_a = seg_b; seg_b = sp;
        run_stim(seg_a, seg_b);
        t0 = nfr;
        wait_cycles(20000);
        chk(nfr >= t0 + 2, "P⑤b 学到 peer B 后继续发帧");
        chk({fr[(nfr-1)*FBASE+0],fr[(nfr-1)*FBASE+1],fr[(nfr-1)*FBASE+2],
             fr[(nfr-1)*FBASE+3],fr[(nfr-1)*FBASE+4],fr[(nfr-1)*FBASE+5]} === PB_MAC,
                                        "P⑤b 换 peer 后 TX dst mac = peer B");
        chk({fr[(nfr-1)*FBASE+30],fr[(nfr-1)*FBASE+31],
             fr[(nfr-1)*FBASE+32],fr[(nfr-1)*FBASE+33]} === PB_IP,
                                        "P⑤b 换 peer 后 TX dst ip = peer B");
        chk({fr[(nfr-1)*FBASE+6],fr[(nfr-1)*FBASE+7],fr[(nfr-1)*FBASE+8],
             fr[(nfr-1)*FBASE+9],fr[(nfr-1)*FBASE+10],fr[(nfr-1)*FBASE+11]} === MY_MAC,
                                        "P⑤b src mac 仍为本机");
        chk(a_mismatch == 32'd0, "P⑤b RX 仍零失配 (换 peer 的那帧续图案)");

        //=====================================================================
        // P④ 突发/背压: 8×1472B 零间隙线速连灌 (8x 于 app 消费率) ⇒ 缓冲溢出丢整帧
        //=====================================================================
        i_en_r = 1'b0; i_en <= 1'b0;
        wait_cycles(4000);
        mis_base   = a_mismatch;
        split_base = st_hls_split;
        bytes_base = snoop_bytes;
        frames_base = st_app_frames;
        t0 = nfr;
        glfsr = SEED;
        for (i = 0; i < 8; i = i + 1) begin
            mk_udp_pat(MY_MAC, PA_MAC, PA_IP, MY_IP, PA_PORT, APP_PORT, 1472);
            emit_frame(1, 0);                        // gap=0 = 背靠背
        end
        seg_a = seg_b; seg_b = sp;
        run_stim(seg_a, seg_b);
        wait_cycles(60000);                          // 播放器把已提交帧排空
        $display("  [dbg] burst: app_frames+%0d drop_ovf=%0d drop_part=%0d drop_crc=%0d bytes+%0d split+%0d",
                 st_app_frames - frames_base, st_drop_ovf, st_drop_part, st_drop_crc,
                 snoop_bytes - bytes_base, st_hls_split - split_base);
        // 划分式: 本次 8 帧 = 交付 + 溢出丢 (无残帧)
        chk((st_app_frames - frames_base) + st_drop_ovf == 32'd8,
            "P④ 突发 8 帧: 交付 + 溢出丢 == 8 (丢帧计数自洽)");
        chk(st_drop_ovf > 32'd0,   "P④ 突发确实溢出丢帧 (8x 于消费率)");
        chk(st_drop_part == 32'd0, "P④ 突发: stat_drop_part = 0 (无半帧残帧)");
        chk(st_drop_crc == 32'd0,  "P④ 突发: 无 CRC 丢弃");
        chk(snoop_bytes == st_app_bytes, "P④ 交付字节 == stat_app_bytes (无半帧泄漏)");
        chk(snoop_badkeep == 0,    "P④ app 口 tkeep 仍全程高位连续");
        chk(stall_cyc == 0,        "P④ s_axis_tready 全程恒 1 (T1 结构性不反压)");
        chk(st_hls_split - split_base == 32'd8, "P④ 8 帧全被判定为 app 帧");

        // ---- 突发后校验器状态一致性: 重新使能 (LFSR 钉 SEED) ⇒ 新帧仍零失配 ----
        i_en_r = 1'b1; i_en <= 1'b1;
        wait_cycles(2000);
        glfsr = SEED;
        mk_udp_pat(MY_MAC, PA_MAC, PA_IP, MY_IP, PA_PORT, APP_PORT, 1472);
        emit_frame(1, 200);
        seg_a = seg_b; seg_b = sp;
        run_stim(seg_a, seg_b);
        wait_cycles(20000);
        chk(a_mismatch == mis_base, "P④ 突发丢帧后重新使能 ⇒ 新帧仍逐字节零失配");

        //=====================================================================
        // P② 全部捕获帧的载荷 = 图案流连续前缀 + 头/校验和 (逐帧)
        //=====================================================================
        check_all_pattern;
        check_frame(0, PA_MAC, PA_IP, 1472);
        check_frame(nfr-1, PA_MAC, PA_IP, 1472);   // 突发后目标回到 peer A

        //=====================================================================
        // P⑥ 有界会话 (TX_BYTES=1000): 恰好 1000 字节 / 1 帧 / done 粘滞 / 之后零拍
        //=====================================================================
        b_nbeats_late = b_nbeats;
        wait_cycles(4000);
        $display("  [dbg] TX_BYTES=1000 实例: bytes=%0d frames=%0d beats=%0d nbytes=%0d done=%b",
                 b_bytes, b_frames, b_nbeats, b_nbytes, b_done);
        chk(b_bytes == 32'd1000,  "P⑥ 有界会话: stat_tx_bytes = 1000 (逐字节精确)");
        chk(b_frames == 32'd1,    "P⑥ 有界会话: 恰 1 帧 (单帧 = min(TX_BYTES, i_paylen))");
        chk(b_nbytes == 1000,     "P⑥ 有界会话: 呈交 1000 有效字节");
        chk(b_nbeats == 125,      "P⑥ 有界会话: 125 拍 (= ceil(1000/8))");
        chk(b_done === 1'b1,      "P⑥ 有界会话: done 粘滞");
        chk(b_nbeats == b_nbeats_late, "P⑥ 有界会话: done 之后零新增拍");

        if (errs == 0) $display("P5E UDP APP GATE: OK (rx_frames=%0d rx_bytes=%0d tx_frames=%0d drop_len=%0d drop_ovf=%0d split=%0d pat_bad=%0d)",
                                a_rx_frames, a_rx_bytes, tx_frames, tx_drop_len,
                                st_drop_ovf, st_hls_split, txv_bad);
        else           $display("P5E UDP APP GATE: FAIL errs=%0d", errs);
        $finish;
    end
endmodule
