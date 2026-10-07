`timescale 1ns/1ps
//=============================================================================
// tb_wu_f2: app_ctrl C6 二轮 **F2** (winq == 0 的显式语义) 的修前/修后**逐字对照**门
//
// 被修的问题 (对抗审查原件 _proj_10g/notes/P7B_WU_P1P2_REVIEW.md §1.3):
//   二轮修前的生产武装条件 `(wscan < winq/4) || (wscan == 0)` 在 **winq == 0** 时:
//     winq == 0 ⇒ wscan ≡ fq_calc(0, oc) ≡ 0 (rtl/app_ctrl.v:612-618, 对 oc 全饱和)
//     ⇒ 武装项恒真 ⇒ `if ... else if ...` 里的触发支**永不求值**, 且每个扫描拍
//     重写 wu_zero=1 —— "永不发"是**意外**而不是**规定**, 语义从代码读不出来。
//   修法 = 给生产块加显式前缀 `if (winq[pb_sid] != 16'd0)`:
//     **零配额 ⇒ 本块一个动作都不做** (既不武装也不触发)。
//     理由: 零配额时我们没有任何东西可通告 (发出去的也是 win=0 的 ACK);
//     信用恢复只可能来自 C15 的池补授 (winq>0 之后滞回正常接管)。
//
// 两臂 (同一激励/同 gnt/同波形; 锁步由监视器逐拍判 —— "同一激励"是证明不是声称):
//   u_dut = rtl/app_ctrl.v (F2 修复后, 默认参数)
//   u_pre = app_ctrl_prefix = sim/p5wu_f2fix/app_ctrl_prefix.v
//           (= 本轮编辑**前**的 rtl/app_ctrl.v 逐字快照, 仅模块改名;
//            未改名快照 sha256 = 871eab125a28f325839c99041c4fbe6d990385f4bcb1625eee970f23f007b2ff)
//           ⇒ 真"F2 未修"负对照臂 (不是用参数模拟的)
//
// 判据 (每项 PASS/FAIL + 末行 "F2 GATE OK"/"F2 GATE FAIL n"):
//   PH0 (winq=0)  ★ F2 主判据 + 修前/修后逐字对照:
//     DUT **不武装** (wu_zero 恒 0) / PRE **被钉在武装态** (每扫描拍重写 1);
//     两版 wu_pend **都是 0 次** (非回归: winq=0 新旧都不发)。
//     PH0j = 判据有牙的正证据: 同一激励在两臂上读出**不同**的 arm 态。
//   PH1/2/3 (winq = 1/2/3)  P1 的可达性恢复档: 两臂**各发恰好 1 次**且 wu_mark 逐字相同
//     ⇒ 证明 F2 的 block 没有把 1/2/3 档一起关掉 (反面: 判据能读出"发")。
//   PH4 (winq = 0xC000, 默认产品配置) 两臂逐字相同: 武装/发射/边界
//     (wscan == winq/4 恰好 ⇒ 不武装; winq/4-1 ⇒ 武装)。
//   PH5 (winq = 0x0C00 = 池/16, 最小产品配置) 两臂逐字相同 (武装 + 发射 + wu_mark)。
//
// ⚠️ 计数口径 = **每槽 wu_pend[c] 的上升沿** (与 tb_wu_p1p2 同口径)。
// ⚠️ PH0 的"数据到达"是**人为制造**的 (winq=0 时物理上对端发不进数据): 本门证的是
//    **代码可达性** (审查 §1.3 同口径), 不是板级场景。PH1..PH5 的进度是物理可达的。
// ⚠️ 本门**不写**寄存器 0x08 (板上 = SCRATCH 兼 TX_DIS 门), 只写 0x0C; 不碰板。
// ⚠️ 判据行一律 ASCII (xsim -log 走 ANSI 代码页, 中文会乱码) —— 中文解释留本头注释
//    与 _proj_10g/notes/P7B_WU_F2_F1_FIX.md。
//=============================================================================
module tb_wu_f2;
    localparam [15:0] W0 = 16'h0000;    // F2 档: 零配额 (退化配置)
    localparam [15:0] W1 = 16'h0001;    // 1/2/3 档 (P1 可达性恢复)
    localparam [15:0] W2 = 16'h0002;
    localparam [15:0] W3 = 16'h0003;
    localparam [15:0] WS = 16'h0C00;    // 3072 = 池/16 (最小产品配置, P5d D4 分池)
    localparam [15:0] WP = 16'hC000;    // 49152 = 默认满池 (产品配置)
    localparam [31:0] RN0 = 32'h1100_0001;
    localparam [31:0] RN1 = 32'h2100_0001;
    localparam [31:0] RN2 = 32'h3200_0001;
    localparam [31:0] RN3 = 32'h4300_0001;
    localparam [31:0] RN4 = 32'h5400_0001;
    localparam [31:0] RN5 = 32'h6500_0001;

    reg clk, rst_n;
    integer errs;

    // ---------------- 假 TCB (16 槽; 组合读口 C) ----------------
    reg [31:0] t_rcv_nxt [0:15];
    reg [31:0] t_snd_nxt [0:15];
    reg [31:0] t_snd_una [0:15];
    reg [15:0] t_rcv_wnd [0:15];
    reg [15:0] t_snd_wnd [0:15];
    reg [3:0]  t_state   [0:15];

    wire [3:0] rc_id_dut, rc_id_pre, rc_id_mut;
    wire [3:0] rc_id = rc_id_dut;           // 模型用 dut 的指针 (锁步由 mon 判)
    wire [31:0] rc_rcv_nxt = t_rcv_nxt[rc_id];
    wire [31:0] rc_snd_nxt = t_snd_nxt[rc_id];
    wire [31:0] rc_snd_una = t_snd_una[rc_id];
    wire [15:0] rc_rcv_wnd = t_rcv_wnd[rc_id];
    wire [15:0] rc_snd_wnd = t_snd_wnd[rc_id];
    wire [3:0]  rc_state   = t_state[rc_id];

    // ---------------- 共享激励 ----------------
    reg  [16:0] occ;
    reg         ev_up, ev_down;
    reg  [3:0]  ev_slot;
    reg  [15:0] fin_sent, rst_sent;
    reg  [7:0]  reg_addr;
    reg  [31:0] reg_wdata;
    reg         reg_wr;

    // ---------------- 三臂 ----------------
    wire        wu_req_dut, wu_req_pre, wu_req_mut;
    wire [3:0]  wu_id_dut, wu_id_pre, wu_id_mut;
    wire [31:0] wu_val_dut, wu_val_pre, wu_val_mut;
    wire        wu_gnt_dut, wu_gnt_pre, wu_gnt_mut;
    wire        fc_wr_dut, fc_wr_pre, fc_wr_mut;
    wire [3:0]  fc_id_dut, fc_id_pre, fc_id_mut;
    wire [2:0]  fc_sel_dut, fc_sel_pre, fc_sel_mut;
    wire [31:0] fc_val_dut, fc_val_pre, fc_val_mut;
    wire        fc_gnt;
    wire [31:0] rdata_dut, rdata_pre, rdata_mut;
    wire [15:0] ready_dut, ready_pre, ready_mut;
    wire [16:0] pool_d, pool_p;             // C18 池余额 (锁步监视 + 判据可读)

    // wu 消费者模型 = tcp_tx_frame.wu_push 的形状 (ackq 永不满 ⇒ gnt = 请求)。
    // **逐臂独立** (否则"无请求的臂"会被空加 stat_wu, 计数不再是它自己的)。
    assign wu_gnt_dut = wu_req_dut;
    assign wu_gnt_pre = wu_req_pre;
    assign wu_gnt_mut = wu_req_mut;
    // fc 消费者: 三臂锁步 ⇒ 请求逐位相同; OR 只为"锁步破裂时也不卡死" (破裂由 mon 判死)
    assign fc_gnt = fc_wr_dut || fc_wr_pre || fc_wr_mut;

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
        .dbg_redge0(), .dbg_winq0(), .dbg_wu_mark0(), .dbg_pool(pool_d),
        .stat_ev_up(), .stat_ev_down(), .stat_ev_drop(), .stat_cmd_close(),
        .stat_cmd_abort(), .stat_wu(), .stat_pool_exhaust(), .stat_fc_upd(),
        .stat_slot_reuse(), .stat_fc_wait_max()
    );

    app_ctrl_prefix #(.WIN_CAP(16'hBFFE), .WIN_POOL(16'hC000), .WIN_Q_MAX(16'hC000),
                      .FIN_TO_LIM(18'd10))
    u_pre (
        .clk(clk), .rst_n(rst_n),
        .ev_up(ev_up), .ev_down(ev_down), .ev_slot(ev_slot),
        .ev_peer_ip(32'h0), .ev_peer_port(16'h0), .ev_peer_mac(48'h0),
        .rc_id(rc_id_pre), .rc_snd_nxt(rc_snd_nxt), .rc_snd_una(rc_snd_una),
        .rc_rcv_nxt(rc_rcv_nxt), .rc_rcv_wnd(rc_rcv_wnd),
        .rc_snd_wnd(rc_snd_wnd), .rc_state(rc_state),
        .rx_occ_bytes(occ), .fin_sent(fin_sent), .rst_sent(rst_sent),
        .o_ev_up(), .o_ev_down(), .o_ev_slot(),
        .fin_req(), .rst_req(),
        .close_req(1'b0), .close_id(4'd0),
        .fc_upd_wr(fc_wr_pre), .fc_upd_id(fc_id_pre), .fc_upd_sel(fc_sel_pre),
        .fc_upd_val(fc_val_pre), .fc_gnt(fc_gnt),
        .wu_req(wu_req_pre), .wu_id(wu_id_pre), .wu_val(wu_val_pre),
        .wu_gnt(wu_gnt_pre),
        .reg_addr(reg_addr), .reg_wr(reg_wr), .reg_wdata(reg_wdata),
        .reg_rdata(rdata_pre),
        .app_tx_ready(ready_pre),
        .dbg_c0_state(), .dbg_c0_snd_nxt(), .dbg_c0_snd_una(), .dbg_c0_rcv_nxt(),
        .dbg_c0_rcv_wnd(), .dbg_c0_snd_wnd(), .dbg_estab_cnt(), .dbg_ev_cnt(),
        .dbg_redge0(), .dbg_winq0(), .dbg_wu_mark0(), .dbg_pool(pool_p),
        .stat_ev_up(), .stat_ev_down(), .stat_ev_drop(), .stat_cmd_close(),
        .stat_cmd_abort(), .stat_wu(), .stat_pool_exhaust(), .stat_fc_upd(),
        .stat_slot_reuse(), .stat_fc_wait_max()
    );

    // 第三臂 = **变异体** (负对照用): 把生产块的 `end else if (触发)` 改成 `end if (触发)`
    // (即"触发支不再被恒真武装挡住") —— 用于证明本门的 fire 判据**能读出**一个
    // "winq==0 会发"的实现 (反过来: DUT 的 0 次不是空判据)。
    // 除这一处外与 app_ctrl_prefix 逐字相同 (见 NEG2: winq!=0 档行为必须与 PRE 一致)。
    app_ctrl_mut #(.WIN_CAP(16'hBFFE), .WIN_POOL(16'hC000), .WIN_Q_MAX(16'hC000),
                   .FIN_TO_LIM(18'd10))
    u_mut (
        .clk(clk), .rst_n(rst_n),
        .ev_up(ev_up), .ev_down(ev_down), .ev_slot(ev_slot),
        .ev_peer_ip(32'h0), .ev_peer_port(16'h0), .ev_peer_mac(48'h0),
        .rc_id(rc_id_mut), .rc_snd_nxt(rc_snd_nxt), .rc_snd_una(rc_snd_una),
        .rc_rcv_nxt(rc_rcv_nxt), .rc_rcv_wnd(rc_rcv_wnd),
        .rc_snd_wnd(rc_snd_wnd), .rc_state(rc_state),
        .rx_occ_bytes(occ), .fin_sent(fin_sent), .rst_sent(rst_sent),
        .o_ev_up(), .o_ev_down(), .o_ev_slot(),
        .fin_req(), .rst_req(),
        .close_req(1'b0), .close_id(4'd0),
        .fc_upd_wr(fc_wr_mut), .fc_upd_id(fc_id_mut), .fc_upd_sel(fc_sel_mut),
        .fc_upd_val(fc_val_mut), .fc_gnt(fc_gnt),
        .wu_req(wu_req_mut), .wu_id(wu_id_mut), .wu_val(wu_val_mut),
        .wu_gnt(wu_gnt_mut),
        .reg_addr(reg_addr), .reg_wr(reg_wr), .reg_wdata(reg_wdata),
        .reg_rdata(rdata_mut),
        .app_tx_ready(ready_mut),
        .dbg_c0_state(), .dbg_c0_snd_nxt(), .dbg_c0_snd_una(), .dbg_c0_rcv_nxt(),
        .dbg_c0_rcv_wnd(), .dbg_c0_snd_wnd(), .dbg_estab_cnt(), .dbg_ev_cnt(),
        .dbg_redge0(), .dbg_winq0(), .dbg_wu_mark0(), .dbg_pool(),
        .stat_ev_up(), .stat_ev_down(), .stat_ev_drop(), .stat_cmd_close(),
        .stat_cmd_abort(), .stat_wu(), .stat_pool_exhaust(), .stat_fc_upd(),
        .stat_slot_reuse(), .stat_fc_wait_max()
    );

    always #4 clk = ~clk;

    //=========================================================================
    // 监视器: ① 锁步 ② wu_pend[c] 上升沿计数 (fire 口径, 槽 0..5)
    //=========================================================================
    integer lock_bad;
    integer f_dut [0:5];
    integer f_pre [0:5];
    integer f_mut [0:5];
    reg [5:0] pq_dut, pq_pre, pq_mut;
    integer k;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lock_bad <= 0;
            pq_dut <= 6'd0; pq_pre <= 6'd0; pq_mut <= 6'd0;
        end else begin
            // ---- ① 锁步 (同一激励的证明) ----
            if ((rc_id_dut !== rc_id_pre) || (rc_id_dut !== rc_id_mut) ||
                (u_dut.pa_v !== u_pre.pa_v) || (u_dut.pb_v !== u_pre.pb_v) ||
                (u_dut.pb_sid !== u_pre.pb_sid) ||
                (u_dut.winq[0] !== u_pre.winq[0]) ||
                (u_dut.winq[1] !== u_pre.winq[1]) ||
                (u_dut.winq[2] !== u_pre.winq[2]) ||
                (u_dut.winq[3] !== u_pre.winq[3]) ||
                (u_dut.winq[4] !== u_pre.winq[4]) ||
                (u_dut.winq[5] !== u_pre.winq[5]) ||
                (fc_wr_dut !== fc_wr_pre) ||
                ((fc_wr_dut || fc_wr_pre) &&
                 ((fc_id_dut !== fc_id_pre) || (fc_sel_dut !== fc_sel_pre) ||
                  (fc_val_dut !== fc_val_pre))))
                lock_bad <= lock_bad + 1;
            // ---- ② fire 计数 = wu_pend[c] 的上升沿 ----
            pq_dut <= u_dut.wu_pend[5:0];
            pq_pre <= u_pre.wu_pend[5:0];
            pq_mut <= u_mut.wu_pend[5:0];
            for (k = 0; k < 6; k = k + 1) begin
                if (u_dut.wu_pend[k] && !pq_dut[k]) f_dut[k] <= f_dut[k] + 1;
                if (u_pre.wu_pend[k] && !pq_pre[k]) f_pre[k] <= f_pre[k] + 1;
                if (u_mut.wu_pend[k] && !pq_mut[k]) f_mut[k] <= f_mut[k] + 1;
            end
        end
    end

    // ---------------- 工具 ----------------
    integer n_pass;
    task chk;
        input         cond;
        input [511:0] name;
        begin
            if (cond) begin n_pass = n_pass + 1; $display("  PASS %0s", name); end
            else begin errs = errs + 1; $display("  FAIL %0s", name); end
        end
    endtask

    wire scan_tick_d = (u_dut.tick_cnt == 4'd15);
    task wait_slot;                       // 等 n 次"扫描到槽 s" (含 T+2 的 C6 落地)
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

    task ev_up_at;   input [3:0] s; begin
        @(posedge clk); ev_up <= 1'b1; ev_slot <= s;
        @(posedge clk); ev_up <= 1'b0;
    end endtask

    // ⚠️ 本 task 必须把模型 TCB 的 state 也清 0 (DEL 的现实语义: 该槽被拆掉):
    //    只发 ev_down 而让 t_state[s] 停在 ESTAB, 会让 DUT 的 C15 增量补授**继续**
    //    给一个已归还配额的槽补授 (winq 已被 ev_down 清 0 ⇒ `winq < wq_cap_r` 成立)
    //    ⇒ 池被静默抽干 (本门首跑实测: winq[4] = 0xBFF7 而非 0xC000, pool = 0)。
    //    这是**TB 模型缺陷**, 不是 RTL 缺陷 (板级 DEL 流程 TCB state 确实归 0)。
    task ev_down_at; input [3:0] s; begin
        @(posedge clk); ev_down <= 1'b1; ev_slot <= s;
        @(posedge clk); ev_down <= 1'b0;
        t_state[s] <= 4'd0;                 // DEL: 该槽的 TCB 消失 (见上)
    end endtask

    task reg_write;  input [7:0] a; input [31:0] d; begin
        @(posedge clk); reg_addr <= a; reg_wdata <= d; reg_wr <= 1'b1;
        @(posedge clk); reg_wr <= 1'b0;
        repeat (3) @(posedge clk);
    end endtask

    task establish;  input [3:0] s; input [31:0] rn; begin
        t_state[s]   <= 4'd1;
        t_rcv_nxt[s] <= rn;
        t_rcv_wnd[s] <= 16'hC000;      // HLS ADD 写死的静态值 (C10 场景)
        t_snd_wnd[s] <= 16'h4000;
        ev_up_at(s);
        repeat (8) @(posedge clk);      // init 拍 + fc 写落地
    end endtask

    integer ti;
    initial begin
        clk = 0; rst_n = 0; errs = 0; n_pass = 0;
        ev_up = 0; ev_down = 0; ev_slot = 0; fin_sent = 0; rst_sent = 0;
        reg_addr = 8'h00; reg_wdata = 32'd0; reg_wr = 1'b0;
        occ = 17'd0;
        for (ti = 0; ti < 16; ti = ti + 1) begin
            t_rcv_nxt[ti] = 32'd0; t_snd_nxt[ti] = 32'd0; t_snd_una[ti] = 32'd0;
            t_rcv_wnd[ti] = 16'd0; t_snd_wnd[ti] = 16'd0; t_state[ti] = 4'd0;
        end
        for (ti = 0; ti < 6; ti = ti + 1) begin
            f_dut[ti] = 0; f_pre[ti] = 0; f_mut[ti] = 0;
        end
        #100; rst_n = 1;
        repeat (30) @(posedge clk);

        // ===================== PH0: winq == 0 (F2 主档) =====================
        $display("PH0: winq=0 -- DUT explicit no-arm; PRE arm saturated true (unfixed)");
        reg_write(8'h0C, {16'd0, W0});           // 建连之前写配额 (P5d D4 用法)
        establish(4'd0, RN0);
        chk(u_dut.winq[0] == W0, "PH0a DUT winq=0 (granted)");
        chk(u_pre.winq[0] == W0, "PH0b PRE winq=0");
        occ <= 17'd0;
        t_rcv_nxt[0] <= RN0 + 32'd64;            // 人为制造进度 (见头注释的口径声明)
        wait_slot(4'd0, 4);
        chk(u_dut.wu_act[0] == 1'b1, "PH0c DUT wu_act=1 (data seen; artificial)");
        chk(u_pre.wu_act[0] == 1'b1, "PH0d PRE wu_act=1");
        chk(u_dut.wu_zero[0] == 1'b0, "PH0e DUT NOT armed (F2: winq==0 arm is explicitly off)");
        chk(u_pre.wu_zero[0] == 1'b1, "PH0f PRE armed (old arm is saturated true)");
        wait_slot(4'd0, 8);
        chk(u_dut.wu_zero[0] == 1'b0, "PH0g DUT still not armed after 8 more scans");
        chk(u_pre.wu_zero[0] == 1'b1, "PH0h PRE still armed after 8 more scans (rewritten every scan)");
        $display("  [READ] PH0 fires: DUT=%0d PRE=%0d | wu_zero: DUT=%b PRE=%b",
                 f_dut[0], f_pre[0], u_dut.wu_zero[0], u_pre.wu_zero[0]);
        chk((f_dut[0] == 0) && (f_pre[0] == 0),
            "PH0i both arms: 0 fires for winq=0 (non-regression; both never fired)");
        chk((u_pre.wu_zero[0] == 1'b1) && (u_dut.wu_zero[0] == 1'b0),
            "PH0j judge has teeth: same stimulus => DIFFERENT arm state (F2 delta seen)");
        // ---- PH0 负对照: "会发"变异体 (end else if -> end if) 必须真的发 ----
        // 目的: 证明 PH0i 的 "0 fires" 不是空判据 —— 同一激励、同一 fire 计数器,
        // 在"winq==0 会发"的实现上读数 >= 1。
        $display("  [READ] NEG mutant fires: s0=%0d (DUT s0=%0d PRE s0=%0d)",
                 f_mut[0], f_dut[0], f_pre[0]);
        chk(f_mut[0] >= 1, "NEG0 would-fire mutant DOES fire at winq=0 (counter is live)");
        chk((f_dut[0] == 0) && (f_mut[0] >= 1),
            "NEG1 winq=0 fire reading discriminates DUT vs would-fire mutant");
        ev_down_at(4'd0);
        repeat (8) @(posedge clk);

        // ============ PH1/2/3: winq = 1/2/3 (P1 可达性档, 两臂都必须发) ============
        $display("PH1: winq=1 -- both arms must fire exactly once (F2 did not kill 1/2/3)");
        reg_write(8'h0C, {16'd0, W1});
        establish(4'd1, RN1);
        chk((u_dut.winq[1] == W1) && (u_pre.winq[1] == W1), "PH1a both winq=1");
        occ <= 17'd1;                            // wscan = fq(1,1) = 0 => arm
        repeat (4) @(posedge clk);
        t_rcv_nxt[1] <= RN1 + 32'd1;             // 1 字节 (winq=1 的物理可剂量)
        wait_slot(4'd1, 4);
        chk((u_dut.wu_act[1] == 1'b1) && (u_pre.wu_act[1] == 1'b1), "PH1b both wu_act=1");
        chk((u_dut.wu_zero[1] == 1'b1) && (u_pre.wu_zero[1] == 1'b1),
            "PH1c both armed (winq=1 arm reachable, P1 fix holds)");
        occ <= 17'd0;                            // wscan = 1 >= winq/2 = 0 => fire
        wait_slot(4'd1, 4);
        chk((f_dut[1] == 1) && (f_pre[1] == 1), "PH1d both fired exactly once");
        chk((u_dut.wu_mark[1] == 16'd1) && (u_pre.wu_mark[1] == 16'd1),
            "PH1e both wu_mark=1 (fire value identical)");
        ev_down_at(4'd1);
        repeat (8) @(posedge clk);

        $display("PH2: winq=2 -- same shape");
        reg_write(8'h0C, {16'd0, W2});
        establish(4'd2, RN2);
        occ <= 17'd2;                            // wscan = 0 => arm
        repeat (4) @(posedge clk);
        t_rcv_nxt[2] <= RN2 + 32'd2;
        wait_slot(4'd2, 4);
        chk((u_dut.wu_zero[2] == 1'b1) && (u_pre.wu_zero[2] == 1'b1), "PH2a both armed");
        occ <= 17'd0;                            // wscan = 2 >= 1 => fire
        wait_slot(4'd2, 4);
        chk((f_dut[2] == 1) && (f_pre[2] == 1), "PH2b both fired exactly once");
        chk((u_dut.wu_mark[2] == 16'd2) && (u_pre.wu_mark[2] == 16'd2), "PH2c both wu_mark=2");
        ev_down_at(4'd2);
        repeat (8) @(posedge clk);

        $display("PH3: winq=3 -- same shape");
        reg_write(8'h0C, {16'd0, W3});
        establish(4'd3, RN3);
        occ <= 17'd3;                            // wscan = 0 => arm
        repeat (4) @(posedge clk);
        t_rcv_nxt[3] <= RN3 + 32'd3;
        wait_slot(4'd3, 4);
        chk((u_dut.wu_zero[3] == 1'b1) && (u_pre.wu_zero[3] == 1'b1), "PH3a both armed");
        occ <= 17'd0;                            // wscan = 3 >= 1 => fire
        wait_slot(4'd3, 4);
        chk((f_dut[3] == 1) && (f_pre[3] == 1), "PH3b both fired exactly once");
        chk((u_dut.wu_mark[3] == 16'd3) && (u_pre.wu_mark[3] == 16'd3), "PH3c both wu_mark=3");
        ev_down_at(4'd3);
        repeat (8) @(posedge clk);

        // ============ PH4: 产品配置 winq = 0xC000 (武装/发射/边界 逐字对照) ============
        $display("PH4: winq=0xC000 (default product cfg) -- both arms bit-identical");
        reg_write(8'h0C, {16'd0, WP});
        establish(4'd4, RN4);
        $display("  [STATE] PH4 winq[4]: DUT=%h PRE=%h | pool: DUT=%h PRE=%h | cap=%h",
                 u_dut.winq[4], u_pre.winq[4], pool_d, pool_p, WP);
        chk((u_dut.winq[4] == WP) && (u_pre.winq[4] == WP), "PH4a both winq=0xC000");
        occ <= 17'hBF00;                         // wscan = 0x100 << winq/4 = 0x3000 => arm
        repeat (4) @(posedge clk);
        t_rcv_nxt[4] <= RN4 + 32'd64;
        wait_slot(4'd4, 4);
        chk((u_dut.wu_zero[4] == 1'b1) && (u_pre.wu_zero[4] == 1'b1), "PH4b both armed");
        occ <= 17'h0100;                         // wscan = 0xBF00 >= winq/2 = 0x6000 => fire
        wait_slot(4'd4, 4);
        chk((f_dut[4] == 1) && (f_pre[4] == 1), "PH4c both fired exactly once");
        chk((u_dut.wu_mark[4] == 16'hBF00) && (u_pre.wu_mark[4] == 16'hBF00),
            "PH4d both wu_mark=0xBF00 (fire value identical)");
        occ <= 17'h9000;                         // wscan == winq/4 exactly => must NOT arm
        wait_slot(4'd4, 6);
        chk((u_dut.wu_zero[4] == 1'b0) && (u_pre.wu_zero[4] == 1'b0),
            "PH4e at exactly winq/4: both NOT armed (strict < holds)");
        chk((f_dut[4] == 1) && (f_pre[4] == 1), "PH4f no extra fire at boundary");
        occ <= 17'h9001;                         // wscan = winq/4 - 1 => arm
        wait_slot(4'd4, 6);
        chk((u_dut.wu_zero[4] == 1'b1) && (u_pre.wu_zero[4] == 1'b1),
            "PH4g at winq/4 - 1: both armed (not a dead gate)");
        ev_down_at(4'd4);
        repeat (8) @(posedge clk);

        // ============ PH5: 最小产品配置 winq = 0x0C00 (池/16) ============
        $display("PH5: winq=0x0C00 (pool/16) -- both arms bit-identical");
        reg_write(8'h0C, {16'd0, WS});
        establish(4'd5, RN5);
        chk((u_dut.winq[5] == WS) && (u_pre.winq[5] == WS), "PH5a both winq=0x0C00");
        occ <= 17'd2816;                         // wscan = 256 < winq/4 = 768 => arm
        repeat (4) @(posedge clk);
        t_rcv_nxt[5] <= RN5 + 32'd32;
        wait_slot(4'd5, 4);
        chk((u_dut.wu_zero[5] == 1'b1) && (u_pre.wu_zero[5] == 1'b1), "PH5b both armed");
        occ <= 17'd0;                            // wscan = 3072 >= winq/2 = 1536 => fire
        wait_slot(4'd5, 4);
        chk((f_dut[5] == 1) && (f_pre[5] == 1), "PH5c both fired exactly once");
        chk((u_dut.wu_mark[5] == WS) && (u_pre.wu_mark[5] == WS), "PH5d both wu_mark=0x0C00");
        ev_down_at(4'd5);
        repeat (8) @(posedge clk);

        // ============================== 汇总 ==============================
        repeat (20) @(posedge clk);
        $display("------------------------------------------------------------");
        $display("lockstep violation cycles (must be 0) = %0d", lock_bad);
        $display("fires: DUT s0=%0d s1=%0d s2=%0d s3=%0d s4=%0d s5=%0d",
                 f_dut[0], f_dut[1], f_dut[2], f_dut[3], f_dut[4], f_dut[5]);
        $display("fires: PRE s0=%0d s1=%0d s2=%0d s3=%0d s4=%0d s5=%0d",
                 f_pre[0], f_pre[1], f_pre[2], f_pre[3], f_pre[4], f_pre[5]);
        $display("fires: MUT s0=%0d s1=%0d s2=%0d s3=%0d s4=%0d s5=%0d (negative control)",
                 f_mut[0], f_mut[1], f_mut[2], f_mut[3], f_mut[4], f_mut[5]);
        chk(lock_bad == 0, "Z1 lockstep across 2 arms (same stimulus)");
        chk((f_dut[0] == f_pre[0]) && (f_dut[1] == f_pre[1]) && (f_dut[2] == f_pre[2]) &&
            (f_dut[3] == f_pre[3]) && (f_dut[4] == f_pre[4]) && (f_dut[5] == f_pre[5]),
            "Z2 fire counts per slot identical DUT vs PRE (only arm state differs)");
        chk((f_dut[0] + f_dut[1] + f_dut[2] + f_dut[3] + f_dut[4] + f_dut[5]) == 5,
            "Z3 total fires == 5 (s1..s5 one each; s0 zero => discriminator saw both outcomes)");
        // ---- 变异体差异面的**如实登记** (不是"只在 s0 分叉"这种顺手话) ----
        // 实测: MUT 在 s0 多发 6 次 (被 NEG0/NEG1 采信), 在 s1 (winq=1) 多发 1 次 ——
        // 原因不是 F2, 而是 winq=1 时**触发阈值为 0** (`wscan >= winq/2 = 0` 恒真):
        // 去掉 else-if 之后, 武装拍 (wscan==0) 的同拍/次拍触发支也满足 ⇒ 多发一次。
        // s2..s5 (winq = 2/3/0xC000/0xC00, 阈值 >= 1) 与 PRE 逐字相同 ⇒ 突变的差异面
        // = {winq==0 的恒真武装} ∪ {winq==1 的零阈值触发}, 两者都是本次修复刻意
        // 排除/显式化的角落, 正是本门要盯的面。
        chk((f_mut[2] == f_pre[2]) && (f_mut[2] == 1) && (f_mut[3] == f_pre[3]) &&
            (f_mut[4] == f_pre[4]) && (f_mut[5] == f_pre[5]) && (f_mut[5] == 1) &&
            (f_mut[1] == 2) && (f_pre[1] == 1),
            "NEG2 mutant diff face logged: s2..s5 == PRE (1 each); s0 +6 / s1 +1 (threshold-0 corner)");
        $display("F2 GATE PASSCOUNT %0d", n_pass);
        if (errs == 0) $display("F2 GATE OK");
        else           $display("F2 GATE FAIL %0d", errs);
        $finish;
    end

endmodule
