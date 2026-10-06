`timescale 1ns/1ps
//=============================================================================
// tb_app_wu: app_ctrl C6 (窗口重开通告 wu) 的 **同一激励双跑 A/B 门** (P7b-WU)
//
// 缺陷 (板级定案, 原件 _proj_10g/notes/P7B_BIZ_TCPREG.md §2): TCP 上行被压到
//   4.5-6.2 Mbps —— 对端每 ~208ms(persist/RTO 定时器) 才探一次, 因为板**从不主动
//   通告窗口重开**。原因 = 修复前 C6 的两个触发条件都**结构性不可达**:
//     ① `pb_wscan == 0` 武装: 现场模态是"app 持续消费把窗托在 **56..128**"
//        (对端 pcap win 范围 56..49152, 2695 条 ACK 里没有一条 win=0) ⇒ 采样
//        永不落在恰好 0;
//     ② "增长 >= WU_STEP(半个池)": 基线 wu_mark 建连 = 全池 49152 ⇒ 需 wscan >=
//        73728 > 池上限 49152 ⇒ 数学上不可达。
//
// 本门怎么证 (两臂同激励、同 gnt、同波形 —— **一次 xelab、一次仿真**):
//   u_new = app_ctrl (默认参数 ⇒ 修复后逻辑)
//   u_old = app_ctrl #(.WU_LEGACY(1))  (逐字 = 修复前逻辑)
//   两臂共享 ev_*/occ/TCB 模型/寄存器总线; 锁步 (扫描指针/流水/fc 请求) 由监视器
//   逐拍核对 ⇒ "同一激励"是被证明的, 不是被声称的。
//
// 判据 (每项 PASS/FAIL + 末行 "P7B WU GATE OK" / "P7B WU GATE FAIL n"):
//   A 模态见证: 危险区相位的**每一次**采样窗都在 [56,128] 内, 且**从未恰好 0**
//     (零命中是结构性的: TB 的占用模型把 occ 钳在 [WINQ-128, WINQ-56]);
//     同相位 u_old.wu_mark[0] 恒 = 全池 (增长分支的基线不动 ⇒ 该分支恒假)。
//   B 修复臂: 危险区内**武装但窗口未重开 ⇒ 一次都不发** (假失败方向的对照);
//     窗口重开 (wscan 越过 winq/2) ⇒ **恰好发一次**, 且 wu_mark = 触发时采到的窗
//     (∈ [winq/2, winq/2+步长]) —— 证明发的是"重开到值一个 ACK 的量"。
//   C 旧臂: **同一激励下 0 次通告** (可证伪性主判据)。
//   D 零额外帧不变量: 高窗相位 (wscan 恒 = 全窗) 连续 N 轮**不再发**。
//   E 可重复 (活性): 第二个"塌陷→重开"周期 ⇒ 第 2 次通告 (不是一次性)。
//   F 两臂都活着 (假失败方向对照之二): 末尾用"恰好 0"的**设计工况**驱动
//     (occ >= winq ⇒ wscan == 0): 两臂**各发一次** ⇒ "旧臂 0 次"不是实例坏了。
//
// ⚠️ 本门**不碰**寄存器 0x08 (板上 0x08 = SCRATCH 兼 TX_DIS 门, 写非 0 掉链),
//    也不写任何寄存器 (只读 0x96).
// ⚠️ 判据行一律 **ASCII**: xsim 的 -log 走 ANSI 代码页, 中文会变乱码 (既有门同病,
//    见 sim/p5sim/fcrun/xsim_fc.log) ⇒ 为了让"双跑读数"能直接读, 打印串用英文,
//    中文解释留在本头注释与 _proj_10g/notes/P7B_WU_FIX.md。
//=============================================================================
module tb_app_wu;
    localparam [15:0] WINQ = 16'hC000;      // 单连接拿满池 (WIN_Q_MAX = WIN_POOL)
    localparam [31:0] RN0  = 32'h3000_0001; // 会话初始 rcv_nxt (避免 0 附近的值)

    reg clk, rst_n;
    integer errs;
    integer cyc;

    // ---------------- 假 TCB (16 槽; 组合读口 C) ----------------
    reg [31:0] t_rcv_nxt [0:15];
    reg [31:0] t_snd_nxt [0:15];
    reg [31:0] t_snd_una [0:15];
    reg [15:0] t_rcv_wnd [0:15];
    reg [15:0] t_snd_wnd [0:15];
    reg [3:0]  t_state   [0:15];

    // ---- 两臂的扫描指针/流水锁步监视 (同一激励的证明) ----
    wire [3:0] rc_id_new, rc_id_old;
    wire [3:0] rc_id = rc_id_new;           // TCB 模型用新臂的指针 (锁步由 mon 保证)
    wire [31:0] rc_rcv_nxt = t_rcv_nxt[rc_id];
    wire [31:0] rc_snd_nxt = t_snd_nxt[rc_id];
    wire [31:0] rc_snd_una = t_snd_una[rc_id];
    wire [15:0] rc_rcv_wnd = t_rcv_wnd[rc_id];
    wire [15:0] rc_snd_wnd = t_snd_wnd[rc_id];
    wire [3:0]  rc_state   = t_state[rc_id];

    // ---- 共享激励 ----
    reg  [16:0] occ;               // app RX 可读字节 (echo frame_fifo 占用)
    reg         ev_up, ev_down;
    reg  [3:0]  ev_slot;
    reg  [15:0] fin_sent, rst_sent;
    reg  [7:0]  reg_addr;
    reg         gnt_en;            // 0 = 扣住 wu_gnt (测电平保持) / 1 = 正常消费

    // ---- 相位/占用驱动 (模式机) ----
    // mode: 0 = 保持 / 1 = 危险区振荡 [WINQ-128, WINQ-56] / 2 = app 消费 (occ--)
    //       3 = 对端突发 (occ += 8/拍, burst_left 计字节)
    reg  [1:0]  mode;
    reg         band_dir;          // 1 = 危险区里下落 (app 消费) / 0 = 上爬 (对端补)
    reg  [16:0] burst_left;

    // ---- 新臂 / 旧臂 ----
    wire        wu_req_new, fc_wr_new;
    wire [3:0]  wu_id_new, fc_id_new;
    wire [31:0] wu_val_new, fc_val_new;
    wire [2:0]  fc_sel_new;
    wire        wu_gnt_new, fc_gnt;
    wire        fc_wr_old;
    wire [3:0]  fc_id_old;
    wire [2:0]  fc_sel_old;
    wire [31:0] fc_val_old;
    wire        wu_req_old, wu_gnt_old;
    wire [3:0]  wu_id_old;
    wire [31:0] wu_val_old;
    wire [31:0] rdata_new, rdata_old;
    wire [15:0] ready_new, ready_old;

    // wu 消费者模型 = tcp_tx_frame.wu_push 的形状 (ackq 永不满 ⇒ gnt = 请求):
    // **逐臂独立** —— 否则"无请求的那一臂"会被空加 stat_wu (旧臂的计数就不再是 0)
    assign wu_gnt_new = gnt_en && wu_req_new;
    assign wu_gnt_old = gnt_en && wu_req_old;
    // fc 消费者模型 = 第 4 级仲裁 (本 TB 让 fc 独占; OR 两臂 ⇒ 锁步破坏时也不卡死,
    // 但锁步本身由 mon 判死)
    assign fc_gnt = fc_wr_new || fc_wr_old;

    app_ctrl #(.WIN_CAP(16'hBFFE), .WIN_POOL(16'hC000), .WIN_Q_MAX(16'hC000),
               .FIN_TO_LIM(18'd10))     // 超时阈值缩小: 本门只关心 wu (与 FC 门同惯例)
    u_new (
        .clk(clk), .rst_n(rst_n),
        .ev_up(ev_up), .ev_down(ev_down), .ev_slot(ev_slot),
        .ev_peer_ip(32'h0), .ev_peer_port(16'h0), .ev_peer_mac(48'h0),
        .rc_id(rc_id_new), .rc_snd_nxt(rc_snd_nxt), .rc_snd_una(rc_snd_una),
        .rc_rcv_nxt(rc_rcv_nxt), .rc_rcv_wnd(rc_rcv_wnd),
        .rc_snd_wnd(rc_snd_wnd), .rc_state(rc_state),
        .rx_occ_bytes(occ), .fin_sent(fin_sent), .rst_sent(rst_sent),
        .o_ev_up(), .o_ev_down(), .o_ev_slot(),
        .fin_req(), .rst_req(),
        .close_req(1'b0), .close_id(4'd0),
        .fc_upd_wr(fc_wr_new), .fc_upd_id(fc_id_new), .fc_upd_sel(fc_sel_new),
        .fc_upd_val(fc_val_new), .fc_gnt(fc_gnt),
        .wu_req(wu_req_new), .wu_id(wu_id_new), .wu_val(wu_val_new),
        .wu_gnt(wu_gnt_new),
        .reg_addr(reg_addr), .reg_wr(1'b0), .reg_wdata(32'd0),
        .reg_rdata(rdata_new),
        .app_tx_ready(ready_new),
        .dbg_c0_state(), .dbg_c0_snd_nxt(), .dbg_c0_snd_una(), .dbg_c0_rcv_nxt(),
        .dbg_c0_rcv_wnd(), .dbg_c0_snd_wnd(), .dbg_estab_cnt(), .dbg_ev_cnt(),
        .dbg_redge0(), .dbg_winq0(), .dbg_wu_mark0(), .dbg_pool(),
        .stat_ev_up(), .stat_ev_down(), .stat_ev_drop(), .stat_cmd_close(),
        .stat_cmd_abort(), .stat_wu(), .stat_pool_exhaust(), .stat_fc_upd(),
        .stat_slot_reuse(), .stat_fc_wait_max()
    );

    app_ctrl #(.WIN_CAP(16'hBFFE), .WIN_POOL(16'hC000), .WIN_Q_MAX(16'hC000),
               .FIN_TO_LIM(18'd10),
               .WU_LEGACY(1'b1))        // ⭐ 负对照臂 = 逐字修复前逻辑
    u_old (
        .clk(clk), .rst_n(rst_n),
        .ev_up(ev_up), .ev_down(ev_down), .ev_slot(ev_slot),
        .ev_peer_ip(32'h0), .ev_peer_port(16'h0), .ev_peer_mac(48'h0),
        .rc_id(rc_id_old), .rc_snd_nxt(rc_snd_nxt), .rc_snd_una(rc_snd_una),
        .rc_rcv_nxt(rc_rcv_nxt), .rc_rcv_wnd(rc_rcv_wnd),
        .rc_snd_wnd(rc_snd_wnd), .rc_state(rc_state),
        .rx_occ_bytes(occ), .fin_sent(fin_sent), .rst_sent(rst_sent),
        .o_ev_up(), .o_ev_down(), .o_ev_slot(),
        .fin_req(), .rst_req(),
        .close_req(1'b0), .close_id(4'd0),
        .fc_upd_wr(fc_wr_old), .fc_upd_id(fc_id_old), .fc_upd_sel(fc_sel_old),
        .fc_upd_val(fc_val_old), .fc_gnt(fc_gnt),
        .wu_req(wu_req_old), .wu_id(wu_id_old), .wu_val(wu_val_old),
        .wu_gnt(wu_gnt_old),
        .reg_addr(reg_addr), .reg_wr(1'b0), .reg_wdata(32'd0),
        .reg_rdata(rdata_old),
        .app_tx_ready(ready_old),
        .dbg_c0_state(), .dbg_c0_snd_nxt(), .dbg_c0_snd_una(), .dbg_c0_rcv_nxt(),
        .dbg_c0_rcv_wnd(), .dbg_c0_snd_wnd(), .dbg_estab_cnt(), .dbg_ev_cnt(),
        .dbg_redge0(), .dbg_winq0(), .dbg_wu_mark0(), .dbg_pool(),
        .stat_ev_up(), .stat_ev_down(), .stat_ev_drop(), .stat_cmd_close(),
        .stat_cmd_abort(), .stat_wu(), .stat_pool_exhaust(), .stat_fc_upd(),
        .stat_slot_reuse(), .stat_fc_wait_max()
    );

    always #4 clk = ~clk;

    //=========================================================================
    // 监视器: ① 锁步 (同一激励证明) ② 采样窗见证 ③ 通告次数/通告值
    //=========================================================================
    integer lock_bad;                 // 锁步破裂拍数 (0 = 同一激励)
    reg [15:0] min_scan, max_scan;    // 危险区相位里 DUT 实采到的窗
    reg        scan_zero_seen;        // ESTAB 采样窗**恰好 0** 出现过?
    reg        arch_zero_seen;        // 危险区里 TB 模型 wscan 恰好 0 出现过?
    reg        band_seen;             // 危险区相位至少采到过一次
    reg        band_phase;            // 当前处于危险区相位 (由 initial 置)

    integer new_fires, old_fires;
    reg [15:0] new_mark1, new_mark2, old_mark1;
    reg        req_new_d, req_old_d;

    // 采样拍 (新臂的轮扫指针; 两臂锁步 ⇒ 对两臂同拍)
    wire scan0_tick = (u_new.tick_cnt == 4'd15) && (u_new.scan_id == 4'd0) &&
                      !u_new.init_pend;
    wire band_sample = scan0_tick && band_phase;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lock_bad <= 0; min_scan <= 16'hFFFF; max_scan <= 16'h0000;
            scan_zero_seen <= 1'b0; arch_zero_seen <= 1'b0; band_seen <= 1'b0;
            new_fires <= 0; old_fires <= 0;
            new_mark1 <= 16'h0; new_mark2 <= 16'h0; old_mark1 <= 16'h0;
            req_new_d <= 1'b0; req_old_d <= 1'b0;
        end else begin
            // ---- ① 锁步 ----
            if ((rc_id_new !== rc_id_old) || (u_new.pb_v !== u_old.pb_v) ||
                (u_new.pb_sid !== u_old.pb_sid) || (u_new.pa_v !== u_old.pa_v) ||
                (u_new.winq[0] !== u_old.winq[0]) ||
                (fc_wr_new !== fc_wr_old) ||
                ((fc_wr_new || fc_wr_old) &&
                 ((fc_id_new !== fc_id_old) || (fc_sel_new !== fc_sel_old) ||
                  (fc_val_new !== fc_val_old))))
                lock_bad <= lock_bad + 1;
            // ---- ② 采样窗见证 (DUT 自己采到的值 = C6 判据的输入) ----
            // ⚠️ 只在 **ESTAB** 拍统计: 建连前 winq[0]=0 ⇒ wscan 恒 0, 那是"没有连接"
            // 而不是"窗跌到 0" (C6 块本身也被 pb_state==ST_ESTAB 门控) —— 统计口径
            // 必须与被测判据同门, 否则见证是假阳性。
            if (u_new.pb_v && (u_new.pb_sid == 4'd0) &&
                (u_new.pb_state == 4'd1)) begin
                if (u_new.pb_wscan == 16'd0) scan_zero_seen <= 1'b1;
                if (band_phase) begin
                    band_seen <= 1'b1;
                    if (u_new.pb_wscan < min_scan) min_scan <= u_new.pb_wscan;
                    if (u_new.pb_wscan > max_scan) max_scan <= u_new.pb_wscan;
                end
            end
            // 模型侧见证: 采样拍上 TB 自己的占用 (occ <= WINQ-56 由驱动块结构保证)
            if (band_sample && (occ >= {1'b0, WINQ})) arch_zero_seen <= 1'b1;
            // ---- ③ 通告次数 (wu_req 上升沿) + 通告值 ----
            req_new_d <= wu_req_new;
            req_old_d <= wu_req_old;
            if (wu_req_new && !req_new_d) begin
                new_fires <= new_fires + 1;
                if (new_fires == 0) new_mark1 <= u_new.wu_mark[0];
                else                new_mark2 <= u_new.wu_mark[0];
            end
            if (wu_req_old && !req_old_d) begin
                old_fires <= old_fires + 1;
                if (old_fires == 0) old_mark1 <= u_old.wu_mark[0];
            end
        end
    end

    // ---- 占用/rcv_nxt 驱动 (非阻塞, 免 0 延迟竞争 —— 本工程坑 17) ----
    // ⚠️ 与 initial 的手工写互斥: initial 只在 mode==0 时手工写 occ (先置 mode=0
    //    并隔几拍再写), 否则两个块同拍驱动 occ = 竞争。
    integer ti;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            occ <= 17'd0;
        end else begin
            case (mode)
                2'd1: begin // 危险区振荡: occ ∈ [WINQ-128, WINQ-56] ⇒ wscan ∈ [56,128]
                    if (!band_dir) begin
                        if (occ >= ({1'b0, WINQ} - 17'd56)) band_dir <= 1'b1;
                        else begin occ <= occ + 17'd1; t_rcv_nxt[0] <= t_rcv_nxt[0] + 32'd1; end
                    end else begin
                        if (occ <= ({1'b0, WINQ} - 17'd128)) band_dir <= 1'b0;
                        else occ <= occ - 17'd1;
                    end
                end
                2'd2: if (occ != 17'd0) occ <= occ - 17'd1;        // app 消费
                2'd3: begin                                       // 对端突发 (10G 量级)
                    if (burst_left != 17'd0) begin
                        occ <= occ + 17'd8; burst_left <= burst_left - 17'd8;
                    end
                end
                default: ;                                        // 保持
            endcase
        end
    end

    // ---- TCB 写模型 (rcv_wnd 字段; 与 tb_app_fc 同惯例) ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (ti = 0; ti < 16; ti = ti + 1) t_rcv_wnd[ti] <= 16'd0;
        end else if (fc_gnt && (fc_sel_new == 3'd3)) begin
            t_rcv_wnd[fc_id_new] <= fc_val_new[15:0];
        end
    end

    // ---------------- 工具 ----------------
    task chk;
        input         cond;
        input [255:0] name;
        begin
            if (cond) $display("  PASS %0s", name);
            else begin errs = errs + 1; $display("  FAIL %0s", name); end
        end
    endtask

    // 等 n 次 slot0 采样 (含流水 3 拍落地)
    task wait_scans;
        input integer n;
        integer i, g;
        begin
            for (i = 0; i < n; i = i + 1) begin
                g = 0;
                while (!(scan0_tick) && (g < 4000)) begin @(posedge clk); g = g + 1; end
                repeat (4) @(posedge clk);
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

    // 等新臂发出第 k 次通告 (带超时); 末尾多等 3 拍让监视器的上升沿计数落地
    task wait_fire;
        input integer k;
        input integer budget;
        integer g;
        begin
            g = 0;
            while ((new_fires < k) && (g < budget)) begin @(posedge clk); g = g + 1; end
            repeat (3) @(posedge clk);
        end
    endtask

    initial begin
        clk = 0; rst_n = 0; errs = 0; cyc = 0;
        ev_up = 0; ev_down = 0; ev_slot = 0; fin_sent = 0; rst_sent = 0;
        reg_addr = 8'h00; gnt_en = 1'b0;
        mode = 2'd0; band_dir = 1'b0; burst_left = 17'd0; band_phase = 1'b0;
        for (ti = 0; ti < 16; ti = ti + 1) begin
            t_rcv_nxt[ti] = 32'd0; t_snd_nxt[ti] = 32'd0; t_snd_una[ti] = 32'd0;
            t_rcv_wnd[ti] = 16'd0; t_snd_wnd[ti] = 16'd0; t_state[ti] = 4'd0;
        end
        #100; rst_n = 1;
        repeat (30) @(posedge clk);

        // ================= P1: 建立 (单连接拿满池) =================
        $display("P1: establish + danger-band modality (window held at 56..128 by app drain)");
        t_state[0]   <= 4'd1;
        t_rcv_nxt[0] <= RN0;
        t_rcv_wnd[0] <= 16'hC000;      // HLS ADD 写死的静态值 (C10 场景)
        t_snd_wnd[0] <= 16'h4000;
        ev_up_at(4'd0);
        repeat (10) @(posedge clk);
        chk(u_new.winq[0] == WINQ, "P1a NEW winq[0] = full pool");
        chk(u_old.winq[0] == WINQ, "P1b OLD winq[0] = full pool");
        // 进入危险区相位: occ 顶到 WINQ-128 (窗口只剩 128), 然后做 40 轮振荡
        occ <= {1'b0, WINQ} - 17'd128;
        band_dir <= 1'b0;
        repeat (3) @(posedge clk);
        band_phase = 1'b1;             // 从此刻起统计"危险区相位"的采样窗
        mode <= 2'd1;
        wait_scans(40);
        mode <= 2'd0;
        band_phase = 1'b0;
        $display("  [WITNESS] danger-band sampled win: min=%0d max=%0d (40 scans) exact0 hit: scan=%0d model=%0d",
                 min_scan, max_scan, scan_zero_seen, arch_zero_seen);
        chk(band_seen,        "P1c danger phase sampled");
        chk(min_scan >= 16'd56,  "P1d sampled win >= 56");
        chk(max_scan <= 16'd128, "P1e sampled win <= 128");
        chk(!scan_zero_seen,  "P1f win never exactly 0");
        chk(!arch_zero_seen,  "P1g model win never 0");
        chk(u_new.wu_zero[0] == 1'b1, "P1h NEW armed (wu_zero=1)");
        chk(u_old.wu_zero[0] == 1'b0, "P1i OLD not armed");
        chk(u_old.wu_mark[0] == WINQ, "P1j OLD wu_mark = full pool");
        // 假失败方向对照之一: 武装但窗口未重开 ⇒ 一次都不许发
        chk(new_fires == 0,   "P1k armed+small => 0 fires");
        chk(old_fires == 0,   "P1l OLD 0 fires same phase");

        // ================= P2: app 消费 ⇒ 窗口重开 ⇒ 通告 =================
        $display("P2: app keeps consuming => window reopens (peer stalled, no external frames)");
        mode <= 2'd2;                  // occ-- (app 消费, 1 B/拍 ≈ 156 MB/s)
        wait_fire(1, 60000);
        chk(new_fires == 1, "P2a reopened => 1 fire");
        chk(old_fires == 0, "P2b OLD 0 fires (same stim.)");
        chk((new_mark1 >= {WINQ[15:1]}) && (new_mark1 <= ({WINQ[15:1]} + 16'd400)),
            "P2c notified val in [wq/2,+step]");
        chk(new_mark1 > 16'd1460, "P2d notified val > 1 MSS");
        $display("  [READ] fire#1 wu_mark=%0d (expect ~%0d) @cyc~%0d",
                 new_mark1, WINQ/2, cyc);
        // 电平保持 (不给 gnt): M1 教训 —— 通告请求被吞 = 永久停等
        repeat (50) @(posedge clk);
        chk(wu_req_new, "P2e level holds w/o gnt (M1)");
        chk(!wu_req_old, "P2f OLD wu_req stays 0");

        // ================= P3: gnt ⇒ 计数与释放 =================
        $display("P3: wu_gnt handshake (ackq model: grant iff requested)");
        gnt_en = 1'b1;
        repeat (6) @(posedge clk);
        chk(!wu_req_new, "P3a wu_req released by gnt");
        reg_addr <= 8'h96;             // stat_wu (只读; ⚠️ 不碰 0x08)
        repeat (2) @(posedge clk);
        chk(rdata_new == 32'd1, "P3b NEW stat_wu=1 (reg 0x96)");
        chk(rdata_old == 32'd0, "P3c OLD stat_wu=0");
        reg_addr <= 8'h00;
        repeat (2) @(posedge clk);

        // ================= P4: 零额外帧不变量 (高窗相位) =================
        $display("P4: high-window phase (app drained the buffer => wscan = full) 20 scans, no more fires");
        // 让 app 把缓冲排空 (P2 的通告发生在 occ=winq/2 ⇒ 还要再排 24 KB)
        while ((occ != 17'd0) && (cyc < 300000)) @(posedge clk);
        mode <= 2'd0;                  // 停消费 (occ 已为 0)
        repeat (4) @(posedge clk);
        wait_scans(20);
        chk(occ == 17'd0,      "P4a occ drained (wscan=full)");
        chk(u_new.wu_zero[0] == 1'b0, "P4b disarmed (win>=winq/4)");
        chk(new_fires == 1,    "P4c 0 extra fires in high phase");
        chk(old_fires == 0,    "P4d OLD still 0");

        // ================= P5: 第二个塌陷→重开周期 (可重复/活性) ==========
        $display("P5: second cycle (peer burst fills buffer => consume again => notify again)");
        burst_left <= {1'b0, WINQ} - 17'd3200;   // 突发 45952 B ⇒ occ 顶到 45952 (wscan=3200 < winq/4)
        mode <= 2'd3;
        // ⚠️ 必须**先等一拍**再判 burst_left: 上面的 NBA 要在本拍末尾才落地,
        //    同一拍读它仍是 0 ⇒ while 会立即退出 (第一版就踩了这个坑)
        repeat (4) @(posedge clk);
        while ((burst_left != 17'd0) && (cyc < 300000)) @(posedge clk);
        mode <= 2'd0;
        wait_scans(2);                 // 让突发后的采样窗 (3200) 真的被采到一次
        chk(!scan_zero_seen, "P5a burst never pushed win to 0");
        chk(u_new.wu_zero[0] == 1'b1, "P5b NEW re-armed");
        chk(old_fires == 0, "P5c OLD 0 in burst phase");
        mode <= 2'd2;                  // 再消费
        wait_fire(2, 60000);
        chk(new_fires == 2, "P5d 2nd cycle => 2nd fire");
        chk((new_mark2 >= {WINQ[15:1]}) && (new_mark2 <= ({WINQ[15:1]} + 16'd400)),
            "P5e fire#2 val in [wq/2,+step]");
        chk(old_fires == 0, "P5f OLD 0 across both cycles");
        mode <= 2'd0;                  // 停消费, 与下面的手工 occ 写互斥
        repeat (10) @(posedge clk);
        chk(!wu_req_new, "P5g fire#2 consumed by gnt");

        // ================= P6: 两臂都活着 (假失败方向对照之二) ============
        // 设计工况: occ >= winq ⇒ wscan == 0 (修复前武装条件**能**命中) ⇒ 放开后
        // **两臂各发一次** ⇒ "旧臂 0 次"不是"实例坏了", 而是"这种工况现场不出现"。
        $display("P6: designed condition (occ >= winq => wscan exactly 0): BOTH arms must fire");
        occ <= {1'b0, WINQ} + 17'd100; // occ > winq (饱和到 wscan = 0)
        wait_scans(3);
        chk(u_old.wu_zero[0] == 1'b1, "P6a OLD armed at exactly 0");
        chk(u_new.wu_zero[0] == 1'b1, "P6b NEW armed too");
        occ <= 17'd0;                  // 放开 ⇒ 窗重开
        wait_fire(3, 20000);
        chk(new_fires == 3, "P6c NEW fire#3");
        wait_fire(1, 20000);
        chk(old_fires == 1, "P6d OLD fire#1 (arm alive)");
        chk(old_mark1 == WINQ, "P6e OLD notified val = full");

        // ================= 汇总 =================
        repeat (20) @(posedge clk);
        $display("------------------------------------------------------------");
        $display("lockstep violation cycles (must be 0) = %0d", lock_bad);
        $display("NEW notifications = %0d (expect 3) . OLD = %0d (expect 1 = P6 designed condition only)",
                 new_fires, old_fires);
        chk(lock_bad == 0, "Z1 lockstep (same stimulus)");
        if (errs == 0) $display("P7B WU GATE OK");
        else           $display("P7B WU GATE FAIL %0d", errs);
        $finish;
    end

    always @(posedge clk) cyc = cyc + 1;

endmodule
