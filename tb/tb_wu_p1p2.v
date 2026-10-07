`timescale 1ns/1ps
//=============================================================================
// tb_wu_p1p2: app_ctrl C6 二轮 (P1 武装阈值下界 + P2 进度门) 的**三臂同激励**门
//
// 被证的两个真问题 (对抗审查抓到, 原件 _proj_10g/notes/P7B_WU_REVIEW.md §2):
//   P1  winq <= 3 时 floor(winq/4) = 0 ⇒ 武装条件 `wscan < 0` **恒假**
//       ⇒ 结构性不可达, 且**比修复前更差** (修复前 `wscan == 0` 至少能发 1 次)。
//   P2  `rx_occ_bytes` 是**全局** app RX 占用 (单 FIFO 服务所有连接) ⇒ 别的连接把
//       FIFO 顶满时**本连接**的 fq 也读小 ⇒ **空转连接也会发 wu** (纯噪声帧,
//       且把 stat_wu(0x96, 已接快照 W61) 变成"真通告 + 噪声"的混合计数)。
//
// 三臂 (同激励/同 gnt/同波形; "同一激励"由锁步监视器逐拍判, 不是声称):
//   u_dut  = rtl/app_ctrl.v 工作树 (P1/P2 修复后, 默认参数)
//   u_base = app_ctrl_base   (sim/p5wu_p1p2/app_ctrl_base.v = **git HEAD 95c9485 的
//            真文件**, 仅模块改名; sha256 前缀 c38b3b96) —— "P1/P2 未修"负对照臂
//            (**不是**用参数模拟出来的: 参数只能切 WU_LEGACY, 切不出"未修版")
//   u_leg  = app_ctrl #(.WU_LEGACY(1))  (逐字 = 2026-10-07 首轮修复前的两个条件)
//
// 判据:
//   PH1 (P1)  winq=3 + 本连接有数据到达: dut 武装并**发 1 次**; base **永不武装、
//             0 次** (净损失被证); leg 发 1 次 (证明"修复前可达"这一格真的存在)。
//   PH2 (P2)  两条连接 (conn1 全程零流量 / conn2 有数据), 共享 occ 把两条的窗都压小:
//             dut **只**对 conn2 武装+发 1 次, 对 conn1 **0 次**;
//             base 对**两条都**武装+各发 1 次 (噪声被证); leg 本相位 0 次。
//   PH3 (边界) wscan == winq/4 **恰好** ⇒ 不武装 (阈值语义仍是"严格小于");
//             wscan == winq/4 - 1 ⇒ 武装 (证明 PH3a 不是"永远不武装"的假门)。
//   PH4       reg 0x96 回读 = 上述计数 (dut=2 / base=2 / leg=1 —— **总数相同,
//             组成不同**: base 的 2 里有一条是空转连接的噪声, dut 的两条都真)。
//
// ⚠️ 计数口径 = **每个槽 `wu_pend[c]` 的上升沿** (不是 wu_req 的上升沿): 两个槽同时
//    挂起时, round-robin 换 id 时 wu_req 保持高电平不落沿 ⇒ 数 wu_req 的沿会**漏计**
//    (M1 同族)。`wu_pend[c]` 的 0->1 = C6 "确实触发了一次通告", 每槽每次危险区只升一次。
// ⚠️ 本门**不写**寄存器 0x08 (板上 = SCRATCH 兼 TX_DIS 门), 只读 0x96/写 0x0C; 不碰板。
// ⚠️ 判据行一律 ASCII (xsim -log 走 ANSI 代码页, 中文会乱码) —— 中文解释留在本头注释
//    与 _proj_10g/notes/P7B_WU_P1P2_SNAP.md。
//=============================================================================
module tb_wu_p1p2;
    localparam [15:0] WINQ = 16'hC000;      // 默认单连接满池 (wq_cap_r 复位值)
    localparam [15:0] WQ3  = 16'h0003;      // P1: 配额 3 (winq/4 == 0)
    localparam [15:0] HALF = 16'h6000;      // P2: 两条连接各拿 池/2
    localparam [31:0] RN0  = 32'h3000_0001;
    localparam [31:0] RN1  = 32'h5100_0001; // conn1 (全程零流量)
    localparam [31:0] RN2  = 32'h6200_0001; // conn2 (有数据)

    reg clk, rst_n;
    integer errs;

    // ---------------- 假 TCB (16 槽; 组合读口 C) ----------------
    reg [31:0] t_rcv_nxt [0:15];
    reg [31:0] t_snd_nxt [0:15];
    reg [31:0] t_snd_una [0:15];
    reg [15:0] t_rcv_wnd [0:15];
    reg [15:0] t_snd_wnd [0:15];
    reg [3:0]  t_state   [0:15];

    wire [3:0] rc_id_dut, rc_id_base, rc_id_leg;
    wire [3:0] rc_id = rc_id_dut;           // 模型用 dut 的指针 (锁步由 mon 判)
    wire [31:0] rc_rcv_nxt = t_rcv_nxt[rc_id];
    wire [31:0] rc_snd_nxt = t_snd_nxt[rc_id];
    wire [31:0] rc_snd_una = t_snd_una[rc_id];
    wire [15:0] rc_rcv_wnd = t_rcv_wnd[rc_id];
    wire [15:0] rc_snd_wnd = t_snd_wnd[rc_id];
    wire [3:0]  rc_state   = t_state[rc_id];

    // ---------------- 共享激励 ----------------
    reg  [16:0] occ;                        // app RX 可读字节 (echo frame_fifo 占用)
    reg         ev_up, ev_down;
    reg  [3:0]  ev_slot;
    reg  [15:0] fin_sent, rst_sent;
    reg  [7:0]  reg_addr;
    reg  [31:0] reg_wdata;
    reg         reg_wr;

    // ---------------- 三臂 ----------------
    wire        wu_req_dut, wu_req_base, wu_req_leg;
    wire [3:0]  wu_id_dut, wu_id_base, wu_id_leg;
    wire [31:0] wu_val_dut, wu_val_base, wu_val_leg;
    wire        wu_gnt_dut, wu_gnt_base, wu_gnt_leg;
    wire        fc_wr_dut, fc_wr_base, fc_wr_leg;
    wire [3:0]  fc_id_dut, fc_id_base, fc_id_leg;
    wire [2:0]  fc_sel_dut, fc_sel_base, fc_sel_leg;
    wire [31:0] fc_val_dut, fc_val_base, fc_val_leg;
    wire        fc_gnt;
    wire [31:0] rdata_dut, rdata_base, rdata_leg;
    wire [15:0] ready_dut, ready_base, ready_leg;

    // wu 消费者模型 = tcp_tx_frame.wu_push 的形状 (ackq 永不满 ⇒ gnt = 请求)。
    // **逐臂独立** (否则"无请求的臂"会被空加 stat_wu, 计数不再是它自己的)。
    assign wu_gnt_dut  = wu_req_dut;
    assign wu_gnt_base = wu_req_base;
    assign wu_gnt_leg  = wu_req_leg;
    // fc 消费者: 三臂锁步 ⇒ 请求逐位相同; OR 只为"锁步破裂时也不卡死" (破裂由 mon 判死)
    assign fc_gnt = fc_wr_dut || fc_wr_base || fc_wr_leg;

    app_ctrl #(.WIN_CAP(16'hBFFE), .WIN_POOL(16'hC000), .WIN_Q_MAX(16'hC000),
               .FIN_TO_LIM(18'd10))
    u_dut (
        .clk(clk), .rst_n(rst_n),
        .ev_up(ev_up), .ev_down(ev_down), .ev_slot(ev_slot),
        .ev_peer_ip(32'h0), .ev_peer_port(16'h0), .ev_peer_mac(48'h0),
        .rc_id(rc_id_dut), .rc_snd_nxt(rc_snd_nxt), .rc_snd_una(rc_snd_una),
        .rc_rcv_nxt(rc_rcv_nxt), .rc_rcv_wnd(rc_rcv_wnd),
        .rc_snd_wnd(rc_snd_wnd), .rc_state(rc_state),
        .rx_occ_bytes(occ), .fin_sent(fin_sent), .rst_sent(rst_sent),
        .o_ev_up(), .o_ev_down(), .o_ev_slot(),
        .fin_req(), .rst_req(),
        .close_req(1'b0), .close_id(4'd0),
        .fc_upd_wr(fc_wr_dut), .fc_upd_id(fc_id_dut), .fc_upd_sel(fc_sel_dut),
        .fc_upd_val(fc_val_dut), .fc_gnt(fc_gnt),
        .wu_req(wu_req_dut), .wu_id(wu_id_dut), .wu_val(wu_val_dut),
        .wu_gnt(wu_gnt_dut),
        .reg_addr(reg_addr), .reg_wr(reg_wr), .reg_wdata(reg_wdata),
        .reg_rdata(rdata_dut),
        .app_tx_ready(ready_dut),
        .dbg_c0_state(), .dbg_c0_snd_nxt(), .dbg_c0_snd_una(), .dbg_c0_rcv_nxt(),
        .dbg_c0_rcv_wnd(), .dbg_c0_snd_wnd(), .dbg_estab_cnt(), .dbg_ev_cnt(),
        .dbg_redge0(), .dbg_winq0(), .dbg_wu_mark0(), .dbg_pool(),
        .stat_ev_up(), .stat_ev_down(), .stat_ev_drop(), .stat_cmd_close(),
        .stat_cmd_abort(), .stat_wu(), .stat_pool_exhaust(), .stat_fc_upd(),
        .stat_slot_reuse(), .stat_fc_wait_max()
    );

    app_ctrl_base #(.WIN_CAP(16'hBFFE), .WIN_POOL(16'hC000), .WIN_Q_MAX(16'hC000),
                    .FIN_TO_LIM(18'd10))
    u_base (
        .clk(clk), .rst_n(rst_n),
        .ev_up(ev_up), .ev_down(ev_down), .ev_slot(ev_slot),
        .ev_peer_ip(32'h0), .ev_peer_port(16'h0), .ev_peer_mac(48'h0),
        .rc_id(rc_id_base), .rc_snd_nxt(rc_snd_nxt), .rc_snd_una(rc_snd_una),
        .rc_rcv_nxt(rc_rcv_nxt), .rc_rcv_wnd(rc_rcv_wnd),
        .rc_snd_wnd(rc_snd_wnd), .rc_state(rc_state),
        .rx_occ_bytes(occ), .fin_sent(fin_sent), .rst_sent(rst_sent),
        .o_ev_up(), .o_ev_down(), .o_ev_slot(),
        .fin_req(), .rst_req(),
        .close_req(1'b0), .close_id(4'd0),
        .fc_upd_wr(fc_wr_base), .fc_upd_id(fc_id_base), .fc_upd_sel(fc_sel_base),
        .fc_upd_val(fc_val_base), .fc_gnt(fc_gnt),
        .wu_req(wu_req_base), .wu_id(wu_id_base), .wu_val(wu_val_base),
        .wu_gnt(wu_gnt_base),
        .reg_addr(reg_addr), .reg_wr(reg_wr), .reg_wdata(reg_wdata),
        .reg_rdata(rdata_base),
        .app_tx_ready(ready_base),
        .dbg_c0_state(), .dbg_c0_snd_nxt(), .dbg_c0_snd_una(), .dbg_c0_rcv_nxt(),
        .dbg_c0_rcv_wnd(), .dbg_c0_snd_wnd(), .dbg_estab_cnt(), .dbg_ev_cnt(),
        .dbg_redge0(), .dbg_winq0(), .dbg_wu_mark0(), .dbg_pool(),
        .stat_ev_up(), .stat_ev_down(), .stat_ev_drop(), .stat_cmd_close(),
        .stat_cmd_abort(), .stat_wu(), .stat_pool_exhaust(), .stat_fc_upd(),
        .stat_slot_reuse(), .stat_fc_wait_max()
    );

    app_ctrl #(.WIN_CAP(16'hBFFE), .WIN_POOL(16'hC000), .WIN_Q_MAX(16'hC000),
               .FIN_TO_LIM(18'd10),
               .WU_LEGACY(1'b1))
    u_leg (
        .clk(clk), .rst_n(rst_n),
        .ev_up(ev_up), .ev_down(ev_down), .ev_slot(ev_slot),
        .ev_peer_ip(32'h0), .ev_peer_port(16'h0), .ev_peer_mac(48'h0),
        .rc_id(rc_id_leg), .rc_snd_nxt(rc_snd_nxt), .rc_snd_una(rc_snd_una),
        .rc_rcv_nxt(rc_rcv_nxt), .rc_rcv_wnd(rc_rcv_wnd),
        .rc_snd_wnd(rc_snd_wnd), .rc_state(rc_state),
        .rx_occ_bytes(occ), .fin_sent(fin_sent), .rst_sent(rst_sent),
        .o_ev_up(), .o_ev_down(), .o_ev_slot(),
        .fin_req(), .rst_req(),
        .close_req(1'b0), .close_id(4'd0),
        .fc_upd_wr(fc_wr_leg), .fc_upd_id(fc_id_leg), .fc_upd_sel(fc_sel_leg),
        .fc_upd_val(fc_val_leg), .fc_gnt(fc_gnt),
        .wu_req(wu_req_leg), .wu_id(wu_id_leg), .wu_val(wu_val_leg),
        .wu_gnt(wu_gnt_leg),
        .reg_addr(reg_addr), .reg_wr(reg_wr), .reg_wdata(reg_wdata),
        .reg_rdata(rdata_leg),
        .app_tx_ready(ready_leg),
        .dbg_c0_state(), .dbg_c0_snd_nxt(), .dbg_c0_snd_una(), .dbg_c0_rcv_nxt(),
        .dbg_c0_rcv_wnd(), .dbg_c0_snd_wnd(), .dbg_estab_cnt(), .dbg_ev_cnt(),
        .dbg_redge0(), .dbg_winq0(), .dbg_wu_mark0(), .dbg_pool(),
        .stat_ev_up(), .stat_ev_down(), .stat_ev_drop(), .stat_cmd_close(),
        .stat_cmd_abort(), .stat_wu(), .stat_pool_exhaust(), .stat_fc_upd(),
        .stat_slot_reuse(), .stat_fc_wait_max()
    );

    always #4 clk = ~clk;

    //=========================================================================
    // 监视器: ① 锁步 ② wu_pend[c] 上升沿计数 (fire 口径) ③ 槽号见证
    //=========================================================================
    integer lock_bad;
    integer f0_dut, f1_dut, f2_dut;
    integer f0_base, f1_base, f2_base;
    integer f0_leg, f1_leg, f2_leg;
    reg [2:0] pq_dut, pq_base, pq_leg;      // 上一拍的 wu_pend[2:0]

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lock_bad <= 0;
            f0_dut <= 0; f1_dut <= 0; f2_dut <= 0;
            f0_base <= 0; f1_base <= 0; f2_base <= 0;
            f0_leg <= 0; f1_leg <= 0; f2_leg <= 0;
            pq_dut <= 3'd0; pq_base <= 3'd0; pq_leg <= 3'd0;
        end else begin
            // ---- ① 锁步 (同一激励的证明) ----
            if ((rc_id_dut !== rc_id_base) || (rc_id_dut !== rc_id_leg) ||
                (u_dut.pa_v !== u_base.pa_v) || (u_dut.pa_v !== u_leg.pa_v) ||
                (u_dut.pb_v !== u_base.pb_v) || (u_dut.pb_v !== u_leg.pb_v) ||
                (u_dut.pb_sid !== u_base.pb_sid) || (u_dut.pb_sid !== u_leg.pb_sid) ||
                (u_dut.winq[0] !== u_base.winq[0]) || (u_dut.winq[0] !== u_leg.winq[0]) ||
                (u_dut.winq[1] !== u_base.winq[1]) || (u_dut.winq[1] !== u_leg.winq[1]) ||
                (u_dut.winq[2] !== u_base.winq[2]) || (u_dut.winq[2] !== u_leg.winq[2]) ||
                (fc_wr_dut !== fc_wr_base) || (fc_wr_dut !== fc_wr_leg) ||
                ((fc_wr_dut || fc_wr_base || fc_wr_leg) &&
                 ((fc_id_dut !== fc_id_base) || (fc_id_dut !== fc_id_leg) ||
                  (fc_sel_dut !== fc_sel_base) || (fc_sel_dut !== fc_sel_leg) ||
                  (fc_val_dut !== fc_val_base) || (fc_val_dut !== fc_val_leg))))
                lock_bad <= lock_bad + 1;
            // ---- ② fire 计数 = wu_pend[c] 的上升沿 (见头注释的口径说明) ----
            pq_dut  <= u_dut.wu_pend[2:0];
            pq_base <= u_base.wu_pend[2:0];
            pq_leg  <= u_leg.wu_pend[2:0];
            if (u_dut.wu_pend[0]  && !pq_dut[0])  f0_dut  <= f0_dut + 1;
            if (u_dut.wu_pend[1]  && !pq_dut[1])  f1_dut  <= f1_dut + 1;
            if (u_dut.wu_pend[2]  && !pq_dut[2])  f2_dut  <= f2_dut + 1;
            if (u_base.wu_pend[0] && !pq_base[0]) f0_base <= f0_base + 1;
            if (u_base.wu_pend[1] && !pq_base[1]) f1_base <= f1_base + 1;
            if (u_base.wu_pend[2] && !pq_base[2]) f2_base <= f2_base + 1;
            if (u_leg.wu_pend[0]  && !pq_leg[0])  f0_leg  <= f0_leg + 1;
            if (u_leg.wu_pend[1]  && !pq_leg[1])  f1_leg  <= f1_leg + 1;
            if (u_leg.wu_pend[2]  && !pq_leg[2])  f2_leg  <= f2_leg + 1;
        end
    end

    // ---------------- 工具 ----------------
    // ⚠️ name 位宽 = **512 位** (64 字节): `[255:0]` 只能装 32 字符, 更长的判据名会被
    //    **截掉前缀**(Verilog 取低位) ⇒ 日志里读成"另一个名字" (本门首跑实测:
    //    "PH1d DUT progress flag set" → "progress flag set")。判据名被截 = 判据读数
    //    不可读的一类, 不许留。
    task chk;
        input         cond;
        input [511:0] name;
        begin
            if (cond) $display("  PASS %0s", name);
            else begin errs = errs + 1; $display("  FAIL %0s", name); end
        end
    endtask

    wire scan_tick_d = (u_dut.tick_cnt == 4'd15);
    // 等 n 次"扫描到槽 s" (含 T+2 的 C6 落地)
    task wait_slot;
        input [3:0]   s;
        input integer n;
        integer i, g;
        begin
            for (i = 0; i < n; i = i + 1) begin
                g = 0;
                while (!(scan_tick_d && !u_dut.init_pend && (u_dut.scan_id == s))
                       && (g < 4000)) begin
                    @(posedge clk); g = g + 1;
                end
                repeat (6) @(posedge clk);
            end
        end
    endtask

    task ev_up_at;
        input [3:0] s;
        begin
            @(posedge clk); ev_up <= 1'b1; ev_slot <= s;
            @(posedge clk); ev_up <= 1'b0;
        end
    endtask

    task ev_down_at;
        input [3:0] s;
        begin
            @(posedge clk); ev_down <= 1'b1; ev_slot <= s;
            @(posedge clk); ev_down <= 1'b0;
        end
    endtask

    task reg_write;
        input [7:0]  a;
        input [31:0] d;
        begin
            @(posedge clk); reg_addr <= a; reg_wdata <= d; reg_wr <= 1'b1;
            @(posedge clk); reg_wr <= 1'b0;
            repeat (3) @(posedge clk);
        end
    endtask

    task establish;
        input [3:0]  s;
        input [31:0] rn;
        begin
            t_state[s]   <= 4'd1;
            t_rcv_nxt[s] <= rn;
            t_rcv_wnd[s] <= 16'hC000;      // HLS ADD 写死的静态值 (C10 场景)
            t_snd_wnd[s] <= 16'h4000;
            ev_up_at(s);
            repeat (8) @(posedge clk);     // init 拍 + fc 写落地
        end
    endtask

    integer ti;
    initial begin
        clk = 0; rst_n = 0; errs = 0;
        ev_up = 0; ev_down = 0; ev_slot = 0; fin_sent = 0; rst_sent = 0;
        reg_addr = 8'h00; reg_wdata = 32'd0; reg_wr = 1'b0;
        occ = 17'd0;
        for (ti = 0; ti < 16; ti = ti + 1) begin
            t_rcv_nxt[ti] = 32'd0; t_snd_nxt[ti] = 32'd0; t_snd_una[ti] = 32'd0;
            t_rcv_wnd[ti] = 16'd0; t_snd_wnd[ti] = 16'd0; t_state[ti] = 4'd0;
        end
        #100; rst_n = 1;
        repeat (30) @(posedge clk);

        // ================= PH1: P1 (winq = 3) =================
        $display("PH1: P1 -- winq=3 (winq/4==0). HEAD arm can never arm; fixed arm can.");
        reg_write(8'h0C, {16'd0, WQ3});        // 建连之前写配额 (P5d D4 用法)
        establish(4'd0, RN0);
        chk(u_dut.winq[0]  == WQ3, "PH1a DUT winq=3 (granted)");
        chk(u_base.winq[0] == WQ3, "PH1b BASE winq=3");
        chk(u_leg.winq[0]  == WQ3, "PH1c LEG winq=3");
        occ <= 17'd3;                          // 窗口关到 0 (occ >= winq)
        repeat (4) @(posedge clk);
        t_rcv_nxt[0] <= RN0 + 32'd64;          // 对端发来 64 B (本连接的一次进度)
        wait_slot(4'd0, 4);
        $display("  [STATE] wu_act(dut)=%b wu_zero: dut=%b base=%b leg=%b",
                 u_dut.wu_act[0], u_dut.wu_zero[0], u_base.wu_zero[0], u_leg.wu_zero[0]);
        chk(u_dut.wu_act[0]  == 1'b1, "PH1d DUT progress flag set (data arrived)");
        chk(u_dut.wu_zero[0] == 1'b1, "PH1e DUT armed (floor=1 fix works)");
        chk(u_base.wu_zero[0] == 1'b0, "PH1f BASE never armed (P1 counterexample)");
        chk(u_leg.wu_zero[0] == 1'b1, "PH1g LEG armed (pre-fix could fire once)");
        occ <= 17'd0;                          // 窗口重开 (wscan = 3 >= winq/2 = 1)
        wait_slot(4'd0, 4);
        chk(f0_dut  == 1, "PH1h DUT fired exactly once");
        chk(f0_base == 0, "PH1i BASE fired 0 (net loss proven)");
        chk(f0_leg  == 1, "PH1j LEG fired once (pre-fix reachable)");

        // ================= PH2: P2 (空转连接也发的噪声) =================
        $display("PH2: P2 -- conn1 idle / conn2 active, shared occ pushes BOTH windows low");
        ev_down_at(4'd0);
        reg_write(8'h0C, {16'd0, HALF});       // 池/2 (两条各一半)
        establish(4'd1, RN1);                  // conn1: 全程零流量
        establish(4'd2, RN2);                  // conn2: 有数据
        chk(u_dut.winq[1] == HALF, "PH2a DUT winq1 = pool/2");
        chk(u_dut.winq[2] == HALF, "PH2b DUT winq2 = pool/2");
        occ <= {1'b0, HALF} - 17'd100;         // 两条的窗都只剩 ~100 B (远在 winq/4 之下)
        repeat (4) @(posedge clk);
        t_rcv_nxt[2] <= RN2 + 32'd300;         // 只有 conn2 有进度
        wait_slot(4'd2, 3);
        wait_slot(4'd1, 1);
        $display("  [STATE] wu_act(dut): c1=%b c2=%b | wu_zero c1: dut=%b base=%b | c2: dut=%b base=%b",
                 u_dut.wu_act[1], u_dut.wu_act[2],
                 u_dut.wu_zero[1], u_base.wu_zero[1],
                 u_dut.wu_zero[2], u_base.wu_zero[2]);
        chk((u_dut.wu_act[2] == 1'b1) && (u_dut.wu_act[1] == 1'b0),
            "PH2c DUT progress only on conn2");
        chk(u_dut.wu_zero[2] == 1'b1, "PH2d DUT armed on active conn");
        chk(u_dut.wu_zero[1] == 1'b0, "PH2e DUT NOT armed on idle conn (P2 gate)");
        chk(u_base.wu_zero[1] == 1'b1, "PH2f BASE armed on idle conn (noise proven)");
        chk(u_base.wu_zero[2] == 1'b1, "PH2g BASE armed on active conn too");
        occ <= 17'd0;                          // 重开
        wait_slot(4'd2, 3);
        wait_slot(4'd1, 3);
        chk((f1_dut == 0) && (f2_dut == 1), "PH2h DUT: idle=0 active=1 fires");
        chk((f1_base == 1) && (f2_base == 1), "PH2i BASE: BOTH fired (noise on idle conn)");
        chk((f1_leg == 0) && (f2_leg == 0), "PH2j LEG: 0 fires this phase");

        // ================= PH3: 阈值边界 (严格小于) =================
        $display("PH3: boundary -- wscan == winq/4 exactly must NOT arm; winq/4-1 must arm");
        occ <= {1'b0, HALF} - {1'b0, HALF[15:2]};       // wscan = winq/4 = 0x1800
        wait_slot(4'd2, 4);
        chk(u_dut.wu_zero[2] == 1'b0, "PH3a DUT not armed at exactly winq/4");
        chk(f2_dut == 1, "PH3b no extra fire");
        occ <= {1'b0, HALF} - {1'b0, HALF[15:2]} + 17'd1;  // wscan = winq/4 - 1
        wait_slot(4'd2, 4);
        chk(u_dut.wu_zero[2] == 1'b1, "PH3c DUT armed at winq/4 - 1 (not a dead gate)");

        // ================= PH4: reg 0x96 回读 (即将进快照 W61 的那一格) ==========
        $display("PH4: stat_wu readback via reg 0x96 (same wire as snapshot word W61)");
        reg_addr <= 8'h96;
        repeat (2) @(posedge clk);
        $display("  [READ] stat_wu: dut=%0d base=%0d leg=%0d",
                 rdata_dut, rdata_base, rdata_leg);
        chk(rdata_dut  == 32'd2, "PH4a DUT stat_wu=2 (1 in PH1 + 1 in PH2)");
        chk(rdata_base == 32'd2, "PH4b BASE stat_wu=2 (0 + 2: one is idle-conn noise)");
        chk(rdata_leg  == 32'd1, "PH4c LEG stat_wu=1 (PH1 only)");
        reg_addr <= 8'h00;
        repeat (2) @(posedge clk);

        // ================= 汇总 =================
        repeat (20) @(posedge clk);
        $display("------------------------------------------------------------");
        $display("lockstep violation cycles (must be 0) = %0d", lock_bad);
        $display("fires: DUT c0=%0d c1=%0d c2=%0d | BASE c0=%0d c1=%0d c2=%0d | LEG c0=%0d c1=%0d c2=%0d",
                 f0_dut, f1_dut, f2_dut, f0_base, f1_base, f2_base, f0_leg, f1_leg, f2_leg);
        chk(lock_bad == 0, "Z1 lockstep across 3 arms (same stimulus)");
        if (errs == 0) $display("P1P2 GATE OK");
        else           $display("P1P2 GATE FAIL %0d", errs);
        $finish;
    end

endmodule
