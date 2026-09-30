`timescale 1ns/1ps
//=============================================================================
// tb_chain_w9.v —— 对抗复核 W9_GAP: app → cfg → 帧器 → mac_tx_10g 全段自建台架
//-----------------------------------------------------------------------------
// 与 `_tmp_w9probe/tb_w9probe.v` (原 agent 的台架)**不同**:
//   · 这里把**真 mac_tx_10g** 接在帧器下游 (原台架是自写 sink) ⇒ 同一台里就能读到
//     "线上帧内容长度"与"XGMII 拍/帧", 直接对板级 W43/W20=192.000 & pcap 1510 对账
//   · 探针全部走**层次引用** (只读), **未改任何 RTL**: u_app.u_txf.full_next 等
//   · 激励用不同 paylen / TX_GAP / 复位相位
// 判据 (与原 agent 的结论对照):
//   dec  = app 决定推入次数        (= W9/8 口径)
//   drop = txf_wr && full_next     (= 下拍会被 FIFO 拒绝的那一笔 ⇒ 静默丢字)
//   commit = txf_wr && !full_next  (= 真落笔)
//   rd   = u_txf.rd (帧器读走)
//   帧器/线上长度 ⇒ 与 pcap(1506/1472/1464) & NIC(1510) 对账
//=============================================================================
module tb_chain_w9;

    reg clk = 1'b0, rst_n = 1'b0;
    always #3.2 clk = ~clk;             // 6.4 ns

    integer PAY   = 1472;
    integer GAP   = 0;
    integer NFRM  = 4000;               // 跑到这么多帧就收工
    integer PHS   = 40;                 // peer_wr 脉冲出现的拍 (改启动相位)
    integer NCHK  = 50;                 // 做载荷图案逐字节比对的帧号

    initial begin
        if (!$value$plusargs("PAY=%d", PAY))  ;
        if (!$value$plusargs("GAP=%d", GAP))  ;
        if (!$value$plusargs("NFRM=%d", NFRM)) ;
        if (!$value$plusargs("PHS=%d", PHS)) ;
        if (!$value$plusargs("NCHK=%d", NCHK)) ;
        $display("W9V cfg PAY=%0d NFRM=%0d PHS=%0d", PAY, NFRM, PHS);
    end

    // ---------------- app ----------------
    wire [63:0] a_tdata; wire [7:0] a_tkeep; wire a_tvalid, a_tready, a_tlast;
    wire [31:0] a_tx_bytes, a_tx_frames, a_rx_bytes, a_rx_frames, a_rx_null, a_mismatch;
    wire a_active, a_done; wire [3:0] a_led;

    wire f_busy;                // 前向声明 (配置模块要它, 声明必须先于使用)
`ifdef GAPSET4
    localparam [15:0] GAP_V = 16'd4;
`elsif GAPSET32
    localparam [15:0] GAP_V = 16'd32;
`elsif GAPSET256
    localparam [15:0] GAP_V = 16'd256;
`else
    localparam [15:0] GAP_V = 16'd0;
`endif

    // peer 表: 复位后打一拍 peer_wr 就算学到
    wire a_tx_ready_v;
    reg peer_wr_r = 1'b0;
    reg [31:0] cyc = 0;
    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (cyc == PHS) peer_wr_r <= 1'b1;
        else          peer_wr_r <= 1'b0;
    end

    app_udp_pattern #(.TX_BYTES(32'd0), .TX_GAP(GAP_V)) u_app (
        .clk(clk), .rst_n(rst_n),
        .i_en(1'b1), .i_tx_ready(a_tx_ready_v), .i_paylen(PAY[11:0]),
        .m_tdata(a_tdata), .m_tkeep(a_tkeep), .m_tvalid(a_tvalid),
        .m_tready(a_tready), .m_tlast(a_tlast),
        .rx_tdata(64'd0), .rx_tkeep(8'd0), .rx_tvalid(1'b0), .rx_tready(),
        .rx_tlast(1'b0), .rx_sof(1'b0), .rx_len(16'd0),
        .stat_tx_bytes(a_tx_bytes), .stat_tx_frames(a_tx_frames),
        .stat_rx_bytes(a_rx_bytes), .stat_rx_frames(a_rx_frames),
        .stat_rx_null(a_rx_null), .stat_mismatch(a_mismatch),
        .active(a_active), .done(a_done), .led(a_led)
    );

    // ---------------- cfg ----------------
    wire [63:0] c_tdata; wire [7:0] c_tkeep; wire c_tvalid, c_tready, c_tlast;
    wire [47:0] c_dst_mac, c_src_mac;
    wire [31:0] c_dst_ip, c_src_ip;
    wire [15:0] c_dst_port, c_src_port;
    wire c_csum_en, c_ready;
    wire [31:0] c_frames, c_deny;

    udp_tx_cfg u_cfg (
        .clk(clk), .rst_n(rst_n),
        .frame_busy(f_busy),
        .peer_wr(peer_wr_r),
        .peer_mac(48'h001122334455),
        .peer_ip(32'hC0A86403),
        .cfg_my_mac(48'h000A3501FEC0),
        .cfg_my_ip(32'hC0A86402),
        .cfg_my_port(16'd8081),
        .cfg_dst_port(16'd8081),
        .cfg_csum_en(1'b1),
        .s_axis_tdata(a_tdata), .s_axis_tkeep(a_tkeep), .s_axis_tvalid(a_tvalid),
        .s_axis_tready(a_tready), .s_axis_tlast(a_tlast),
        .m_axis_tdata(c_tdata), .m_axis_tkeep(c_tkeep), .m_axis_tvalid(c_tvalid),
        .m_axis_tready(c_tready), .m_axis_tlast(c_tlast),
        .o_dst_mac(c_dst_mac), .o_dst_ip(c_dst_ip), .o_dst_port(c_dst_port),
        .o_src_mac(c_src_mac), .o_src_ip(c_src_ip), .o_src_port(c_src_port),
        .o_csum_en(c_csum_en), .o_ready(a_tx_ready_v),
        .stat_frames(c_frames), .stat_deny(c_deny)
    );

    // ---------------- 帧器 ----------------
    wire [63:0] f_tdata; wire [7:0] f_tkeep; wire f_tvalid, f_tready, f_tlast;
    wire [31:0] f_stat_frames, f_stat_bytes, f_stat_drop_len;

    udp_tx_frame u_frm (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(c_tdata), .s_axis_tkeep(c_tkeep), .s_axis_tvalid(c_tvalid),
        .s_axis_tready(c_tready), .s_axis_tlast(c_tlast),
        .cfg_src_mac(c_src_mac), .cfg_dst_mac(c_dst_mac),
        .cfg_src_ip(c_src_ip), .cfg_dst_ip(c_dst_ip),
        .cfg_src_port(c_src_port), .cfg_dst_port(c_dst_port),
        .cfg_csum_en(c_csum_en),
        .m_axis_tdata(f_tdata), .m_axis_tkeep(f_tkeep), .m_axis_tvalid(f_tvalid),
        .m_axis_tready(f_tready), .m_axis_tlast(f_tlast),
        .stat_frames(f_stat_frames), .stat_bytes(f_stat_bytes),
        .stat_drop_len(f_stat_drop_len), .o_busy(f_busy)
    );

    // ---------------- 真 MAC ----------------
    wire [63:0] xd; wire [7:0] xc;
    wire [31:0] m_stat_frames, m_stat_abort, m_stat_flush_words, m_stat_flush_done;
    wire [31:0] m_stat_tx_words, m_stat_tx_ctrl_char, m_stat_tx_short;
    wire [15:0] m_clen; wire [1:0] m_state;

    mac_tx_10g u_mac (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(f_tdata), .s_axis_tkeep(f_tkeep), .s_axis_tvalid(f_tvalid),
        .s_axis_tready(f_tready), .s_axis_tlast(f_tlast),
        .xgmii_txd(xd), .xgmii_txc(xc),
        .stat_frames(m_stat_frames), .stat_abort(m_stat_abort),
        .stat_flush_words(m_stat_flush_words), .stat_flush_done(m_stat_flush_done),
        .stat_tx_words(m_stat_tx_words), .stat_tx_ctrl_char(m_stat_tx_ctrl_char),
        .stat_tx_short(m_stat_tx_short),
        .dbg_tx_last_clen(m_clen), .dbg_tx_state(m_state)
    );

    //=========================================================================
    // 只读探针 (层次引用; 未改任何 RTL)
    //=========================================================================
    wire        p_txf_wr    = u_app.txf_wr;
    wire        p_full      = u_app.u_txf.full;
    wire        p_full_next = u_app.u_txf.full_next;
    wire        p_rd        = u_app.u_txf.rd;
    wire        p_empty     = u_app.u_txf.empty;
    wire [11:0] p_seg_sent  = u_app.seg_sent;
    wire [11:0] p_seg_len   = u_app.seg_len;

    integer n_dec = 0, n_drop = 0, n_commit = 0, n_rd = 0, n_nextfull = 0;
    integer n_drop_frm = 0, n_acc_frame_pos_sum = 0;
    integer min_occ = 99999, max_occ = 0;
    integer drops_at [0:255];       // 丢字时 seg_sent/8 (帧内第几个字, 0..184)
    integer drop_pos_min = 99999, drop_pos_max = 0;
    integer drop_seg_sum = 0;
    integer i3;
    reg [31:0] pf_app;

    wire [8:0] occ = u_app.u_txf.dbg_wptr - u_app.u_txf.dbg_rptr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            n_dec <= 0; n_drop <= 0; n_commit <= 0; n_rd <= 0; n_nextfull <= 0;
            n_drop_frm <= 0; min_occ <= 99999; max_occ <= 0;
            drop_pos_min <= 99999; drop_pos_max <= 0; drop_seg_sum <= 0;
        end else begin
            // ⚠️ 时序口径 (本轮自纠): txf_wr 是**本拍有效**的脉冲, FIFO 在本拍采样
            //   `wr = txf_wr && !full` 并于**本拍沿**落笔 ⇒ 被拒的判据是**本拍的 full**,
            //   不是 full_next (full_next 是"本笔落笔后会不会满" —— 那是下一笔的判据)。
            if (p_txf_wr) begin
                n_dec <= n_dec + 1;
                if (p_full) begin                     // ← 本拍 full = 本笔被拒 (静默丢字)
                    n_drop <= n_drop + 1;
                    drops_at[p_seg_sent[11:3]] <= drops_at[p_seg_sent[11:3]] + 1;
                    if (p_seg_sent < drop_pos_min) drop_pos_min <= p_seg_sent;
                    if (p_seg_sent > drop_pos_max) drop_pos_max <= p_seg_sent;
                    drop_seg_sum <= drop_seg_sum + p_seg_sent;
                end else n_commit <= n_commit + 1;
            end
            if (p_txf_wr && p_full_next) n_nextfull <= n_nextfull + 1;   // 诊断用 (非丢字)
            if (p_rd) n_rd <= n_rd + 1;
            begin : occupd
                integer o;
                o = occ;
                if (o < min_occ) min_occ <= o;
                if (o > max_occ) max_occ <= o;
            end
        end
    end

    // 帧器输出侧: 逐帧长度 (Σpopcount(tkeep)) 与 udp_len 字段 (帧内字节 38..39)
    integer frm_len, frm_cnt, len_min, len_max;
    integer blen_min, blen_max;          // udp_len 字段
    integer byidx;                       // 帧内字节下标
    reg [15:0] udplen_r;
    integer len_hist [0:7];
    integer hist_i;
    // ---- 载荷图案逐字节比对 (Q1: 丢的字在"帧内第几个字"? 是洞还是截尾?) ----
    reg  [7:0] pb [0:2047];        // 第 NCHK 帧的载荷字节 (帧器输出去掉 42B 头)
    reg  [7:0] expb [0:2047];      // TB 自算的期望图案 (与 app 的 xorshift 同款, 独立重写)
    integer    cap_fi = -1;        // 已捕获的帧号 (-1 = 未捕获)
    integer    cap_len = 0;
    function [63:0] xs_next_tb;
        input [63:0] s0; reg [63:0] t;
        begin t = s0 ^ (s0 << 13); t = t ^ (t >> 7); t = t ^ (t << 17); xs_next_tb = t; end
    endfunction

    function [3:0] pc8; input [7:0] v; integer i; reg [3:0] c;
        begin c = 4'd0; for (i = 0; i < 8; i = i + 1) c = c + {3'b0, v[i]}; pc8 = c; end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frm_len <= 0; frm_cnt <= 0; len_min <= 99999; len_max <= 0;
            blen_min <= 0; blen_max <= 0; byidx <= 0; udplen_r <= 0;
            for (hist_i = 0; hist_i < 8; hist_i = hist_i + 1) len_hist[hist_i] <= 0;
        end else begin
            if (f_tvalid && f_tready) begin
                // 本字前 b 个字节 = 帧内 [byidx, byidx+b-1]
                begin : dec
                    integer b, j; reg [7:0] bytev;
                    b = pc8(f_tkeep);
                    for (j = 0; j < 8; j = j + 1) begin
                        if (j < b) begin
                            bytev = f_tdata[63 - 8*j -: 8];      // lane j 的字节
                            if (byidx + j == 38) udplen_r[15:8] <= bytev;
                            if (byidx + j == 39) udplen_r[7:0]  <= bytev;
                            // 载荷 = 帧内 [42 .. len-1] ⇒ 落进 pb[]
                            if ((byidx + j >= 42) && (byidx + j - 42 < 2048) && (frm_cnt == NCHK))
                                pb[byidx + j - 42] <= bytev;
                        end
                    end
                    byidx <= byidx + b;
                    frm_len <= frm_len + b;
                end
                if (f_tlast) begin
                    if (frm_cnt == NCHK) begin cap_fi = frm_cnt; cap_len = frm_len + pc8(f_tkeep); end
                    frm_cnt <= frm_cnt + 1;
                    if (frm_len + pc8(f_tkeep) < len_min) len_min <= frm_len + pc8(f_tkeep);
                    if (frm_len + pc8(f_tkeep) > len_max) len_max <= frm_len + pc8(f_tkeep);
                    byidx <= 0;
                    frm_len <= 0;
                    // udp_len: 最后一个字节 (39) 已在本拍解码
                    if (frm_cnt > 1) begin
                        if (udplen_r < blen_min) blen_min <= udplen_r;
                        if (udplen_r > blen_max) blen_max <= udplen_r;
                    end
                end
            end
        end
    end

    // ---- 收工汇报 ----
    reg [31:0] pf_mac;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) pf_mac <= 0;
        else begin
            pf_mac <= m_stat_frames;
            if (m_stat_frames >= NFRM) begin
                $display("W9V APP   pay=%0d gap=%0d tx_frames=%0d tx_bytes=%0d (/frm=%0d)",
                    PAY, GAP_V, a_tx_frames, a_tx_bytes, a_tx_bytes/a_tx_frames);
                $display("W9V APPQ  dec=%0d drop=%0d commit=%0d rd=%0d occ_now=%0d occ=[%0d..%0d] nextfull=%0d",
                    n_dec, n_drop, n_commit, n_rd, occ, min_occ, max_occ, n_nextfull);
                $display("W9V FRAMER frames=%0d bytes=%0d (/frm=%0d) drop_len=%0d",
                    f_stat_frames, f_stat_bytes, f_stat_bytes/f_stat_frames, f_stat_drop_len);
                $display("W9V OUTLEN frames=%0d len_min=%0d len_max=%0d udplen=[%0d..%0d] clen=%0d",
                    frm_cnt, len_min, len_max, blen_min, blen_max, m_clen);
                $display("W9V MAC   frames=%0d tx_words=%0d ctrl=%0d cyc_per_frame=%0d.%04d ctrl_per_frame=%0d.%04d abort=%0d short=%0d",
                    m_stat_frames, m_stat_tx_words, m_stat_tx_ctrl_char,
                    m_stat_tx_words/m_stat_frames, ((m_stat_tx_words*10000)/m_stat_frames)%10000,
                    m_stat_tx_ctrl_char/m_stat_frames, ((m_stat_tx_ctrl_char*10000)/m_stat_frames)%10000,
                    m_stat_abort, m_stat_tx_short);
                begin : patcmp
                    integer m, mm, s8, s0cnt, s8cnt;
                    reg [63:0] st;
                    integer first_bad;
                    if (cap_fi >= 0) begin
                        st = 64'h9E3779B97F4A7C15;
                        for (m = 0; m < 1472 * NCHK; m = m + 1) st = xs_next_tb(st);
                        for (m = 0; m < 2048; m = m + 1) begin
                            expb[m] = st[31:24];
                            st = xs_next_tb(st);
                        end
                        first_bad = -1;
                        s0cnt = 0; s8cnt = 0;
                        for (m = 0; m < cap_len - 42; m = m + 1) begin
                            if ((first_bad < 0) && (pb[m] !== expb[m])) first_bad = m;
                            if (pb[m] === expb[m]) s0cnt = s0cnt + 1;
                            if ((m + 8 < 2048) && (pb[m] === expb[m+8])) s8cnt = s8cnt + 1;
                        end
                        $display("W9V PAYLOAD frame=%0d clen=%0d payload=%0d first_bad=%0d  (#match@same=%0d  #match@+8=%0d)",
                                 cap_fi, cap_len, cap_len-42, first_bad, s0cnt, s8cnt);
                        for (mm = 0; mm < 3; mm = mm + 1)
                          $display("W9V   around %0d: pb=%02x exp=%02x exp[+8]=%02x",
                                 (first_bad<0?0:first_bad)+mm, pb[(first_bad<0?0:first_bad)+mm],
                                 expb[(first_bad<0?0:first_bad)+mm], expb[(first_bad<0?0:first_bad)+mm+8]);
                        // 原始载荷 dump (供离线 Python 做对齐分析)
                        $write("W9VDATA frame=%0d len=%0d", cap_fi, cap_len-42);
                        for (m = 0; m < cap_len-42; m = m + 1) $write(" %02x", pb[m]);
                        $write("%c", 10);
                    end else $display("W9V PAYLOAD (no capture; NCHK=%0d not reached)", NCHK);
                end
                $display("W9V DROPPOS seg_sent bytes: min=%0d max=%0d mean=%0d (word idx min=%0d max=%0d mean=%0d)",
                    drop_pos_min, drop_pos_max,
                    (n_drop>0)? drop_seg_sum/n_drop : 0,
                    drop_pos_min/8, drop_pos_max/8,
                    (n_drop>0)? (drop_seg_sum/n_drop)/8 : 0);
                begin : hist
                    integer h, nd;
                    nd = 0;
                    for (h = 0; h < 256; h = h + 1) nd = nd + ((drops_at[h] != 0) ? 1 : 0);
                    $display("W9V DROPPOS distinct word-idx count = %0d", nd);
                    for (h = 0; h < 256; h = h + 1)
                        if (drops_at[h] != 0) $display("W9V   wordidx=%0d cnt=%0d", h, drops_at[h]);
                end
                $finish;
            end
        end
    end

    initial begin
        for (i3 = 0; i3 < 256; i3 = i3 + 1) drops_at[i3] = 0;
        #64 rst_n = 1'b1;
        #8000000 $display("W9V TIMEOUT app_frames=%0d mac_frames=%0d", a_tx_frames, m_stat_frames);
        $finish;
    end
endmodule
