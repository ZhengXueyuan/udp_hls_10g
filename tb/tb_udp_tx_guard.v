`timescale 1ns/1ps
//=============================================================================
// tb_udp_tx_guard — P5e-T2 UDP app 发送侧单元门 (自检式, 无 Python 依赖)
//=============================================================================
// 被测链 (与 wrapper APP_MODE 支的接线同构):
//   app AXIS 拍流 → udp_tx_cfg (peer 锁存/使能门) → udp_tx_frame (长度守卫)
//   → tx_arb (原样复用) → 消费者 (TB)
//
// 判据 (每条都是"只有正确实现才成立"的量):
//   ① 默认不发送: 无 peer 时帧首拍 tready=0 且线上零帧 (帧不丢, 停在门外)
//   ② peer 写入后原帧照发 (阻塞不是死锁)
//   ③ 1500B 边界: 恰 1500B **照发** (P1 门 LENS 含 1500 ⇒ 阈值下限), 头字段/
//      双校验和 (IP 头 + UDP 伪头)/载荷图案逐字节正确
//   ④ >1500B 中止: 1501B 帧**零字节上线** + stat_drop_len 计数, 下一帧逐字节照常
//   ⑤ >2048B 不再死锁: 4096B 帧中止后下一帧照常 (FIFO 256 字永远写不满)
//   ⑥ **负对照 (判别力)**: 同一 4096B 帧喂给 `PLEN_MAX=4095` (守卫结构性失效) 的
//      同模块实例 ⇒ 载荷 FIFO 写满 256 字后 tready 恒 0、永久无 tlast、stat_frames=0
//      ⇒ 证明 ⑤ 的"不死锁"是守卫带来的, 不是帧本来就过得去 (坑 18)
//   ⑦ cfg 锁存: 帧内 peer 源改变 ⇒ 本帧头字段仍用帧首值 (帧内稳定);
//      下一帧用新 peer (帧间可变)
//   ⑧ 零长数据报 (单拍 tkeep=0 + tlast) 照发, 帧长 = 42B, 后续帧不受影响
//=============================================================================
module tb_udp_tx_guard;
    localparam [47:0] MY_MAC    = 48'h000A3501FEC0;
    localparam [31:0] MY_IP     = 32'hC0A86402;
    localparam [15:0] MY_PORT   = 16'h1F91;   // 8081
    localparam [15:0] DST_PORT  = 16'h1F91;
    localparam [47:0] PEER_A_MAC = 48'h112233445566;
    localparam [31:0] PEER_A_IP  = 32'hC0A86401;
    localparam [47:0] PEER_B_MAC = 48'hAABBCCDDEEFF;
    localparam [31:0] PEER_B_IP  = 32'hC0A8647F;

    reg clk, rst_n;
    initial clk = 1'b0;
    always #4 clk = ~clk;                     // 125 MHz

    integer errs;
    task chk;
        input        cond;
        input [8*72:1] msg;
        begin
            if (!cond) begin
                errs = errs + 1;
                $display("  [FAIL] %0s", msg);
            end
        end
    endtask

    //=========================================================================
    // 拍流队列 (整个测试一条连续 AXIS 流; 帧间无间隙 = 最严苛背压场景)
    //=========================================================================
    localparam integer QMAX = 1200;
    reg [63:0] q_data  [0:QMAX];
    reg [7:0]  q_keep  [0:QMAX];
    reg        q_last  [0:QMAX];
    integer    q_stall [0:QMAX];
    integer    qn;
    integer    fidx_qi [0:7];      // 第 i 帧的起始拍号 (F0..F7)
    integer    qi_mid;

    // 载荷图案: 帧内递增, 帧间不同 (能抓帧拼接/错位)
    function [7:0] payb;
        input integer fidx;
        input integer i;
        begin
            payb = (i * 7 + 3 + fidx * 29) & 8'hFF;
        end
    endfunction

    task push_frame;
        input integer fidx;
        input integer len;
        integer k, j, nb, nby;
        reg [63:0] w;
        reg [7:0]  kp;
        begin
            fidx_qi[fidx] = qn;
            nb = (len == 0) ? 1 : (len + 7) / 8;
            for (k = 0; k < nb; k = k + 1) begin
                w  = 64'd0;
                kp = 8'h00;
                nby = len - k * 8;
                if (nby > 8) nby = 8;
                for (j = 0; j < 8; j = j + 1) begin
                    if (j < nby) begin
                        w[63 - 8*j -: 8] = payb(fidx, k * 8 + j);
                        kp[7 - j]        = 1'b1;
                    end
                end
                q_data[qn] = w; q_keep[qn] = kp;
                q_last[qn] = (k == nb - 1); q_stall[qn] = 0;
                qn = qn + 1;
            end
        end
    endtask

    // 被测拍流: F0 32B / F1 1500B / F2 1501B / F3 4096B / F4 64B / F5 100B /
    //           F6 100B / F7 0B   (期望上线帧 = F0,F1,F4,F5,F6,F7 = 6 帧)
    localparam integer NEXP = 6;
    integer exp_len  [0:7];
    integer exp_fidx [0:7];     // 期望上线帧 k ← 拍流帧号 (载荷图案按后者生成)
    integer exp_b    [0:7];     // 0 = peer A, 1 = peer B
    task build_queue;
        begin
            qn = 0;
            push_frame(0, 32);
            push_frame(1, 1500);
            push_frame(2, 1501);
            push_frame(3, 4096);
            push_frame(4, 64);
            push_frame(5, 100);
            push_frame(6, 100);
            push_frame(7, 0);
            qi_mid = fidx_qi[5] + 3;             // F5 中段 (第 4 拍前) 停顿
            q_stall[qi_mid] = 200;
            exp_fidx[0] = 0; exp_len[0] = 32;   exp_b[0] = 0;
            exp_fidx[1] = 1; exp_len[1] = 1500; exp_b[1] = 0;
            exp_fidx[2] = 4; exp_len[2] = 64;   exp_b[2] = 0;   // 1501B 中止后
            exp_fidx[3] = 5; exp_len[3] = 100;  exp_b[3] = 0;   // 4096B 中止后; 帧内写 peer B ⇒ 本帧仍 A
            exp_fidx[4] = 6; exp_len[4] = 100;  exp_b[4] = 1;   // 帧间可变 -> B
            exp_fidx[5] = 7; exp_len[5] = 0;    exp_b[5] = 1;   // 零长数据报
        end
    endtask

    //=========================================================================
    // 主激励驱动 (守卫实例): 无 peer 时被门挡住 ⇒ 天然覆盖"默认不发送"
    //=========================================================================
    wire [63:0] s_tdata;
    wire [7:0]  s_tkeep;
    wire        s_tvalid, s_tready, s_tlast;
    reg  [63:0] drv_data;
    reg  [7:0]  drv_keep;
    reg         drv_last, drv_valid;
    integer     qi, wc;
    reg         stall_mid;
    assign s_tdata = drv_data; assign s_tkeep = drv_keep;
    assign s_tvalid = drv_valid; assign s_tlast = drv_last;

    always @(posedge clk) begin
        if (!rst_n) begin
            drv_valid <= 1'b0; drv_data <= 64'd0; drv_keep <= 8'h00;
            drv_last <= 1'b0; qi <= 0; wc <= 0; stall_mid <= 1'b0;
        end else begin
            if (!drv_valid) begin
                if (wc != 0) wc <= wc - 1;
                else if (qi < qn) begin
                    drv_valid <= 1'b1;
                    drv_data  <= q_data[qi];
                    drv_keep  <= q_keep[qi];
                    drv_last  <= q_last[qi];
                end
            end else if (s_tready) begin
                // 接受拍 (坑 17: 只按 posedge 采样值推进, 无同拍组合反馈)
                qi <= qi + 1;
                wc <= (qi + 1 < qn) ? q_stall[qi+1] : 0;
                drv_valid <= 1'b0;      // 强制隔 1 拍再发下一拍 (presenting)
            end
            stall_mid <= (qi == qi_mid) && (wc != 0);
        end
    end

    //=========================================================================
    // DUT 链
    //=========================================================================
    reg         peer_wr;
    reg  [47:0] peer_mac;
    reg  [31:0] peer_ip;
    wire        u_busy;        // P5e-T2 cfg 稳定性握手 (帧器非空闲) — 先声明后用

    wire [63:0] utx_tdata;
    wire [7:0]  utx_tkeep;
    wire        utx_tvalid, utx_tready, utx_tlast;
    wire [47:0] cf_dmac, cf_smac;
    wire [31:0] cf_dip, cf_sip;
    wire [15:0] cf_dport, cf_sport;
    wire        cf_csum;
    wire        cf_ready;
    wire [31:0] cf_frames, cf_deny;

    udp_tx_cfg u_cfg (
        .clk(clk), .rst_n(rst_n),
        .peer_wr(peer_wr), .peer_mac(peer_mac), .peer_ip(peer_ip),
        .frame_busy(u_busy),
        .cfg_my_mac(MY_MAC), .cfg_my_ip(MY_IP),
        .cfg_my_port(MY_PORT), .cfg_dst_port(DST_PORT), .cfg_csum_en(1'b1),
        .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep),
        .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready), .s_axis_tlast(s_tlast),
        .m_axis_tdata(utx_tdata), .m_axis_tkeep(utx_tkeep),
        .m_axis_tvalid(utx_tvalid), .m_axis_tready(utx_tready), .m_axis_tlast(utx_tlast),
        .o_dst_mac(cf_dmac), .o_dst_ip(cf_dip), .o_dst_port(cf_dport),
        .o_src_mac(cf_smac), .o_src_ip(cf_sip), .o_src_port(cf_sport),
        .o_csum_en(cf_csum), .o_ready(cf_ready),
        .stat_frames(cf_frames), .stat_deny(cf_deny)
    );

    wire [63:0] u2_tdata;
    wire [7:0]  u2_tkeep;
    wire        u2_tvalid, u2_tready, u2_tlast;
    wire [31:0] tx_frames, tx_bytes, tx_drop_len;

    udp_tx_frame u_tx (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(utx_tdata), .s_axis_tkeep(utx_tkeep),
        .s_axis_tvalid(utx_tvalid), .s_axis_tready(utx_tready), .s_axis_tlast(utx_tlast),
        .cfg_src_mac(cf_smac), .cfg_dst_mac(cf_dmac),
        .cfg_src_ip(cf_sip), .cfg_dst_ip(cf_dip),
        .cfg_src_port(cf_sport), .cfg_dst_port(cf_dport),
        .cfg_csum_en(cf_csum),
        .m_axis_tdata(u2_tdata), .m_axis_tkeep(u2_tkeep),
        .m_axis_tvalid(u2_tvalid), .m_axis_tready(u2_tready), .m_axis_tlast(u2_tlast),
        .stat_frames(tx_frames), .stat_bytes(tx_bytes), .stat_drop_len(tx_drop_len),
        .o_busy(u_busy)
    );

    // 合流器 (原样复用): UDP app TX = fast 输入, slow 输入恒空
    wire [63:0] m_tdata;
    wire [7:0]  m_tkeep;
    wire        m_tvalid, m_ready, m_tlast;
    wire        mrg_slow_ready;

    tx_arb u_arb (
        .clk(clk), .rst_n(rst_n),
        .s_fast_tdata(u2_tdata), .s_fast_tkeep(u2_tkeep),
        .s_fast_tvalid(u2_tvalid), .s_fast_tready(u2_tready), .s_fast_tlast(u2_tlast),
        .s_slow_tdata(64'd0), .s_slow_tkeep(8'h00),
        .s_slow_tvalid(1'b0), .s_slow_tready(mrg_slow_ready), .s_slow_tlast(1'b0),
        .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep),
        .m_axis_tvalid(m_tvalid), .m_axis_tready(m_ready), .m_axis_tlast(m_tlast)
    );
    assign m_ready = 1'b1;                 // 消费者恒就绪 (最坏背压面由 DUT 内部承担)

    // ---- 帧捕获 (字节级; 只记不判 — 判据在全部帧到齐后一次过, 无时序竞争) ----
    localparam integer FBASE = 2048;       // 每帧槽步长
    reg [7:0]  fr [0:FBASE*8-1];
    integer    fr_len [0:7];
    integer    nfr, fcnt, bbi;

    always @(posedge clk) begin
        if (m_tvalid && m_ready) begin
            for (bbi = 0; bbi < 8; bbi = bbi + 1) begin
                if (m_tkeep[7-bbi] && (fcnt < FBASE - 1)) begin
                    fr[nfr*FBASE + fcnt] = m_tdata[63 - 8*bbi -: 8];
                    fcnt = fcnt + 1;
                end
            end
            if (m_tlast) begin
                fr_len[nfr] = fcnt;
                nfr = nfr + 1;
                fcnt = 0;
            end
        end
    end

    //=========================================================================
    // 负对照实例: 同一 4096B 帧喂给守卫失效 (PLEN_MAX=4095) 的同模块
    //=========================================================================
    reg         neg_go;
    reg  [63:0] nd_data;
    reg  [7:0]  nd_keep;
    reg         nd_last, nd_valid;
    integer     nqi, nwc;
    wire        nd_ready;
    wire [63:0] n_tdata;
    wire [7:0]  n_tkeep;
    wire        n_tvalid, n_tready, n_tlast;
    wire [31:0] n_frames, n_bytes, n_drop;
    wire        n_busy;
    integer     neg_tlast_seen;

    udp_tx_frame u_tx_neg (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(nd_data), .s_axis_tkeep(nd_keep),
        .s_axis_tvalid(nd_valid), .s_axis_tready(nd_ready), .s_axis_tlast(nd_last),
        .cfg_src_mac(cf_smac), .cfg_dst_mac(cf_dmac),
        .cfg_src_ip(cf_sip), .cfg_dst_ip(cf_dip),
        .cfg_src_port(cf_sport), .cfg_dst_port(cf_dport), .cfg_csum_en(cf_csum),
        .m_axis_tdata(n_tdata), .m_axis_tkeep(n_tkeep),
        .m_axis_tvalid(n_tvalid), .m_axis_tready(n_tready), .m_axis_tlast(n_tlast),
        .stat_frames(n_frames), .stat_bytes(n_bytes), .stat_drop_len(n_drop),
        .o_busy(n_busy)
    );
    // 守卫关断: plen 是 12 位 ⇒ plen_n > 4095 结构性不可能 (len_bad 永为 0)
    defparam u_tx_neg.PLEN_MAX = 12'd4095;
    assign n_tready = 1'b1;

    always @(posedge clk) begin
        if (!rst_n) begin
            nd_valid <= 1'b0; nqi <= 0; nwc <= 0; neg_tlast_seen <= 0;
        end else begin
            if (n_tvalid && n_tlast && n_tready) neg_tlast_seen <= neg_tlast_seen + 1;
            if (!nd_valid) begin
                if (neg_go && (nqi < 512)) begin   // 4096B = 512 拍
                    nd_valid <= 1'b1;
                    nd_data  <= q_data[fidx_qi[3] + nqi];
                    nd_keep  <= q_keep[fidx_qi[3] + nqi];
                    nd_last  <= q_last[fidx_qi[3] + nqi];
                end
            end else if (nd_ready) begin
                nqi <= nqi + 1;
                nd_valid <= 1'b0;
            end
        end
    end

    //=========================================================================
    // 判据辅助: 16 位反码和 (IP 头 / UDP 伪头)
    //=========================================================================
    integer    cbase;
    reg [31:0] csum_acc;
    task csum_add;
        input integer off;
        input integer nb;
        integer i;
        begin
            for (i = 0; i + 1 < nb; i = i + 2)
                csum_acc = csum_acc + {fr[cbase+off+i], fr[cbase+off+i+1]};
            if (nb % 2)
                csum_acc = csum_acc + {fr[cbase+off+nb-1], 8'h00};
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

    // 一帧全字段检查: 头/mac/ip/端口/长度/双校验和/载荷逐字节
    task check_frame;
        input integer k;          // 上线帧序 (期望表下标)
        integer i;
        reg [15:0] u_len;
        reg [47:0] edmac;
        reg [31:0] edip;
        begin
            cbase = k * FBASE;
            if (exp_b[k] == 0) begin edmac = PEER_A_MAC; edip = PEER_A_IP; end
            else               begin edmac = PEER_B_MAC; edip = PEER_B_IP; end
            $display("  帧 %0d: len=%0d (期望 %0d) dst_mac=%012h dst_ip=%08h",
                     k, fr_len[k], exp_len[k] + 42, edmac, edip);
            chk(fr_len[k] == exp_len[k] + 42, "帧长 = 42 + 载荷");
            chk({fr[cbase+0],fr[cbase+1],fr[cbase+2],fr[cbase+3],fr[cbase+4],fr[cbase+5]}
                === edmac, "dst mac = 本帧锁存的对端");
            chk({fr[cbase+6],fr[cbase+7],fr[cbase+8],fr[cbase+9],fr[cbase+10],fr[cbase+11]}
                === MY_MAC, "src mac = 本机");
            chk({fr[cbase+12],fr[cbase+13]} === 16'h0800, "ethertype = IPv4");
            chk(fr[cbase+23] === 8'h11, "IP proto = UDP");
            chk({fr[cbase+16],fr[cbase+17]} === (exp_len[k] + 28), "IP total_len");
            // IP 头校验和: 含校验和字段整体和为 0xFFFF
            csum_acc = 32'd0; csum_add(14, 20);
            chk(fold32(csum_acc) === 16'hFFFF, "IP 头校验和正确");
            chk({fr[cbase+26],fr[cbase+27],fr[cbase+28],fr[cbase+29]} === MY_IP, "src ip");
            chk({fr[cbase+30],fr[cbase+31],fr[cbase+32],fr[cbase+33]} === edip, "dst ip = 对端");
            u_len = {fr[cbase+38], fr[cbase+39]};
            chk(u_len === (exp_len[k] + 8), "UDP len");
            chk({fr[cbase+34],fr[cbase+35]} === MY_PORT, "src port");
            chk({fr[cbase+36],fr[cbase+37]} === DST_PORT, "dst port");
            // UDP 校验和 = 伪头 + UDP 头 + 载荷 (含校验和字段) 整体和为 0xFFFF
            csum_acc = 32'd0;
            csum_add(26, 8);            // 伪头: src_ip + dst_ip
            csum_acc = csum_acc + 16'h0011 + u_len;
            csum_add(34, 8 + exp_len[k]);   // UDP 头 + 载荷
            $display("    [dbg] ip_csum=%04h udp_csum=%04h 区域折叠和=%04h",
                     {fr[cbase+24],fr[cbase+25]}, {fr[cbase+40],fr[cbase+41]},
                     fold32(csum_acc));
            chk(fold32(csum_acc) === 16'hFFFF, "UDP 校验和正确 (伪头+头+载荷)");
            // 载荷逐字节
            for (i = 0; i < exp_len[k]; i = i + 1)
                chk(fr[cbase+42+i] === payb(exp_fidx[k], i), "载荷逐字节");
        end
    endtask

    //=========================================================================
    // 主控时间线
    //=========================================================================
    // ---- FIFO 满标志监测 (死锁的直接证据: 守卫实例永不满 / 负对照写满) ----
    integer full_seen, nfull_seen;
    always @(posedge clk) begin
        if (u_tx.fifo_full)     full_seen  <= 1;
        if (u_tx_neg.fifo_full) nfull_seen <= 1;
    end

    integer i;
    initial begin
        errs = 0; nfr = 0; fcnt = 0;
        full_seen = 0; nfull_seen = 0;
        rst_n = 1'b0; peer_wr = 1'b0; peer_mac = 48'd0; peer_ip = 32'd0;
        neg_go = 1'b0;
        build_queue;
        $display("P5E-T2 GUARD: 拍流 %0d 拍, 期望上线 %0d 帧", qn, NEXP);
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (50) @(posedge clk);

        // ---- ① 默认不发送 (无 peer): 帧停在门外, 线上零帧 ----
        repeat (300) @(posedge clk);
        chk(qi == 0,                     "① 默认不发送: 帧首拍未被接受");
        chk(s_tvalid === 1'b1 && s_tready === 1'b0, "① 默认不发送: tready=0 (帧被拒在门外)");
        chk(nfr == 0,                    "① 默认不发送: 线上零帧");
        chk(cf_ready === 1'b0,           "① app_udp_tx_ready=0 (peer 表空)");
        chk(cf_deny == 32'd1,            "① 被拒帧计数 = 1 (每帧 1 次, 非逐拍)");

        // ---- ② 写 peer A ⇒ 被挡的帧原样发出 (阻塞非死锁) ----
        peer_wr <= 1'b1; peer_mac <= PEER_A_MAC; peer_ip <= PEER_A_IP;
        @(posedge clk); peer_wr <= 1'b0;
        repeat (200) @(posedge clk);
        chk(cf_ready === 1'b1,           "② peer 学习中: ready=1");
        chk(nfr >= 1,                    "② 被挡的帧在新 peer 下发出");

        // ---- ⑦a 帧内改 peer 源 (F5 中段停顿拍) ----
        for (i = 0; i < 400000; i = i + 1) begin
            if (stall_mid === 1'b1) i = 400000;
            else @(posedge clk);
        end
        chk(stall_mid === 1'b1, "⑦ 拍到帧中段停顿点 (peer 源切换窗口)");
        peer_wr <= 1'b1; peer_mac <= PEER_B_MAC; peer_ip <= PEER_B_IP;
        @(posedge clk); peer_wr <= 1'b0;

        // ---- 负对照: 同一 4096B 帧喂守卫失效实例 ----
        neg_go <= 1'b1;

        // ---- 等全部期望帧到齐 (超时 = FAIL) ----
        for (i = 0; i < 400000; i = i + 1) begin
            if (nfr >= NEXP) i = 400000;
            else @(posedge clk);
        end
        repeat (3000) @(posedge clk);    // 静默尾窗: 不许再有帧 (被中止帧零泄漏)

        // ---- 判据: 帧序 + 全字段 ----
        chk(nfr == NEXP, "③-⑧ 上线帧数 = 期望 (中止帧零泄漏)");
        check_frame(0);   // ② 被挡帧 (peer A)
        check_frame(1);   // ③ 1500B 边界照发
        check_frame(2);   // ④ 1501B 中止后首帧
        check_frame(3);   // ⑤ 4096B 中止后首帧 + 帧内写 peer B ⇒ 仍 A
        check_frame(4);   // ⑦b 帧间可变 -> B
        check_frame(5);   // ⑧ 零长数据报

        // ---- ④⑤ 中止计数 + ⑥ 负对照死锁 ----
        chk(tx_drop_len == 32'd2, "④⑤ stat_drop_len = 2 (1501B + 4096B)");
        chk(tx_frames == 32'd6,   "stat_frames = 6 (中止帧不计数)");
        chk(tx_bytes == (32+1500+64+100+100+0), "stat_bytes = 各帧载荷和");
        // shim 对流透明: 8 帧全放行 (含 2 帧被帧器中止的) ⇒ 6 帧上线 + 2 帧丢弃
        chk(cf_frames == 32'd8,   "shim stat_frames = 8 (全放行, 中止发生在帧器内)");
        $display("    [dbg] neg: nqi=%0d s_ready=%b fifo_full=%b state=%0d nfifo_occ=%0d",
                 nqi, nd_ready, u_tx_neg.fifo_full, u_tx_neg.state,
                 u_tx_neg.u_fifo.wptr - u_tx_neg.u_fifo.rptr);
        chk(qi == qn,             "拍流全部被接受 (中止帧也不卡 app)");
        chk(full_seen == 0,       "⑤ 守卫实例的载荷 FIFO 从未写满 (>2048B 无死锁路径)");
        // 负对照: 守卫失效 ⇒ FIFO 写满 ⇒ tready 恒 0 + 永无 tlast + 零帧
        chk(nfull_seen == 1,          "⑥ 负对照: 守卫失效时载荷 FIFO 写满");
        chk(nd_ready === 1'b0,        "⑥ 负对照: 写满后 s_axis_tready 恒 0");
        chk(neg_tlast_seen == 0,      "⑥ 负对照: 永久无 tlast (死锁)");
        chk(n_frames == 32'd0,        "⑥ 负对照: stat_frames = 0");
        chk(n_drop == 32'd0,          "⑥ 负对照: 无中止 (守卫确实失效)");

        if (errs == 0) $display("P5E-T2 GUARD GATE: OK (frames=%0d drop_len=%0d deny=%0d neg_fifo_occ=%0d neg_sready=%0d)",
                                nfr, tx_drop_len, cf_deny,
                                u_tx_neg.u_fifo.wptr - u_tx_neg.u_fifo.rptr, nd_ready);
        else           $display("P5E-T2 GUARD GATE: FAIL errs=%0d", errs);
        $finish;
    end
endmodule
