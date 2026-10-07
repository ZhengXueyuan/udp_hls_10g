`timescale 1ns/1ps
//=============================================================================
// tb_rev_p2_gate -- 对抗审查 agent 自写: P2 进度门 (wu_act) 的**会话边界**与**残留**取证
//
// 被检声称 (作者 note §2.2 / §2.4):
//   C1 "wu_act 是**会话属性**: ev_up/ev_down 事件脉冲清 (同槽重连不继承)"  -- 作者 TB **未覆盖**
//   C2 "从未收过数据的连接结构性免疫噪声"                              -- 作者 TB 覆盖 (PH2)
//   C3 "残留 ①: 曾活跃、之后空闲的连接仍有 (有界) 噪声"                 -- 作者 TB **未量化**
//   C4 "残留 ②: 从未收过数据却先看到小窗而停等的连接仍要等对端 persist"  -- 作者 TB **未覆盖**
//
// 两臂 (同激励, 锁步由 mon 逐拍判):
//   u_dut  = rtl/app_ctrl.v 工作树 (P1/P2 修复后)
//   u_base = app_ctrl_base (sim/p5wu_p1p2/app_ctrl_base.v = git HEAD 文件)
//
// 相位:
//   RA  同槽重连: 会话 A 收过数据 (wu_act=1) -> ev_down -> ev_up 新会话 (零数据)
//       => DUT: wu_act 必须被清 0, 且新会话**不武装**; BASE(无门): 照样武装 (对照)
//   RB  残留 ①: 会话里收过数据后**完全静默** (仍 ESTAB), 共享 occ 两次涨落
//       => DUT 仍会发 (每个 occ 周期 1 条) —— 证残留存在 + 量化
//   RC  残留 ②: 从未收数据的连接先看到小窗 (occ 高) 再看到重开 (occ 低)
//       => DUT **不**发 (要等对端 persist); BASE 发 —— 证残留的"少发"方向
//
// ⚠️ 判据行一律 ASCII。n_occ 用 8 的倍数 (真实 occ = 字数 x 8)。
//=============================================================================
module tb_rev_p2_gate;
    localparam [15:0] WINQ = 16'hC000;      // 满池 (单连接)
    localparam [16:0] OCC_HI = 17'hBF00;    // wscan = 0x100 (远在 winq/4 = 0x3000 之下)
    localparam [31:0] RNA = 32'h1000_0001;  // 会话 A 的 rcv_nxt
    localparam [31:0] RNB = 32'h7100_0001;  // 会话 B (重连后) 的 rcv_nxt —— 与 A 不同 (C10 的关键)

    reg clk, rst_n;
    integer errs;

    reg [31:0] t_rcv_nxt [0:15];
    reg [31:0] t_snd_nxt [0:15];
    reg [31:0] t_snd_una [0:15];
    reg [15:0] t_rcv_wnd [0:15];
    reg [15:0] t_snd_wnd [0:15];
    reg [3:0]  t_state   [0:15];

    wire [3:0] rc_id_dut, rc_id_base;
    wire [3:0] rc_id = rc_id_dut;
    wire [31:0] rc_rcv_nxt = t_rcv_nxt[rc_id];
    wire [31:0] rc_snd_nxt = t_snd_nxt[rc_id];
    wire [31:0] rc_snd_una = t_snd_una[rc_id];
    wire [15:0] rc_rcv_wnd = t_rcv_wnd[rc_id];
    wire [15:0] rc_snd_wnd = t_snd_wnd[rc_id];
    wire [3:0]  rc_state   = t_state[rc_id];

    reg  [16:0] occ;
    reg         ev_up, ev_down;
    reg  [3:0]  ev_slot;
    reg  [15:0] fin_sent, rst_sent;
    reg  [7:0]  reg_addr;
    reg  [31:0] reg_wdata;
    reg         reg_wr;

    wire wu_req_dut, wu_req_base;
    wire [3:0] wu_id_dut, wu_id_base;
    wire [31:0] wu_val_dut, wu_val_base;
    wire fc_wr_dut, fc_wr_base;
    wire [3:0] fc_id_dut, fc_id_base;
    wire [2:0] fc_sel_dut, fc_sel_base;
    wire [31:0] fc_val_dut, fc_val_base;
    wire fc_gnt;
    wire [31:0] rdata_dut, rdata_base;
    wire [15:0] ready_dut, ready_base;

    wire wu_gnt_dut, wu_gnt_base;
    // wu 消费者模型 (同 tb_wu_p1p2): ackq 永不满 => gnt = 请求 (逐臂独立)
    assign wu_gnt_dut  = wu_req_dut;
    assign wu_gnt_base = wu_req_base;

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
    // fc 消费者: 两臂锁步 (请求逐位相同); OR 只为锁步破裂时不卡死
    assign fc_gnt = fc_wr_dut || fc_wr_base;

    always #4 clk = ~clk;

    integer lock_bad;
    integer f_dut, f_base;          // wu_pend[1] 上升沿计数 (只关心槽 1)
    reg     pq_dut, pq_base;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lock_bad <= 0; f_dut <= 0; f_base <= 0; pq_dut <= 1'b0; pq_base <= 1'b0;
        end else begin
            if ((rc_id_dut !== rc_id_base) || (u_dut.pa_v !== u_base.pa_v) ||
                (u_dut.pb_v !== u_base.pb_v) || (u_dut.pb_sid !== u_base.pb_sid) ||
                (u_dut.winq[0] !== u_base.winq[0]) || (u_dut.winq[1] !== u_base.winq[1]))
                lock_bad <= lock_bad + 1;
            pq_dut  <= u_dut.wu_pend[1];
            pq_base <= u_base.wu_pend[1];
            if (u_dut.wu_pend[1]  && !pq_dut)  f_dut  <= f_dut + 1;
            if (u_base.wu_pend[1] && !pq_base) f_base <= f_base + 1;
        end
    end

    task chk;
        input         cond;
        input [511:0] name;
        begin
            if (cond) $display("  PASS %0s", name);
            else begin errs = errs + 1; $display("  FAIL %0s", name); end
        end
    endtask

    wire scan_tick_d = (u_dut.tick_cnt == 4'd15);
    // 等 n 次"扫描到槽 s"的 T+2 落地
    task wait_slot;
        input [3:0]   s;
        input integer n;
        integer i, g;
        begin
            for (i = 0; i < n; i = i + 1) begin
                g = 0;
                while (!(scan_tick_d && !u_dut.init_pend && (u_dut.scan_id == s)) && (g < 4000)) begin
                    @(posedge clk); g = g + 1;
                end
                repeat (6) @(posedge clk);
            end
        end
    endtask

    task ev_up_at; input [3:0] s; begin
        @(posedge clk); ev_up <= 1'b1; ev_slot <= s;
        @(posedge clk); ev_up <= 1'b0;
    end endtask
    task ev_down_at; input [3:0] s; begin
        @(posedge clk); ev_down <= 1'b1; ev_slot <= s;
        @(posedge clk); ev_down <= 1'b0;
    end endtask
    task reg_write; input [7:0] a; input [31:0] d; begin
        @(posedge clk); reg_addr <= a; reg_wdata <= d; reg_wr <= 1'b1;
        @(posedge clk); reg_wr <= 1'b0;
        repeat (3) @(posedge clk);
    end endtask
    task establish; input [3:0] s; input [31:0] rn; begin
        t_state[s]   <= 4'd1;
        t_rcv_nxt[s] <= rn;
        t_rcv_wnd[s] <= 16'hC000;
        t_snd_wnd[s] <= 16'h4000;
        ev_up_at(s);
        repeat (8) @(posedge clk);
    end endtask

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

        // ================= RA: 同槽重连 (C1) =================
        $display("RA: same-slot reconnect -- wu_act must be a SESSION property");
        reg_write(8'h0C, {16'd0, WINQ});
        establish(4'd1, RNA);
        occ <= OCC_HI;                          // 窗压小 (occ 高)
        repeat (4) @(posedge clk);
        t_rcv_nxt[1] <= RNA + 32'd64;           // 会话 A: 对端发来数据
        wait_slot(4'd1, 3);
        chk(u_dut.wu_act[1] == 1'b1, "RAa session A: dut wu_act[1]=1 (data seen)");
        // 会话 A 结束 (DEL) -> 立刻同槽重连 (ADD), 新 seq, 零数据
        ev_down_at(4'd1);
        repeat (4) @(posedge clk);
        chk(u_dut.wu_act[1] == 1'b0, "RAb dut wu_act[1]=0 after ev_down");
        establish(4'd1, RNB);                   // 会话 B: 零数据 (seq 与 A 不同)
        chk(u_dut.wu_act[1] == 1'b0, "RAc dut wu_act[1]=0 right after new session");
        wait_slot(4'd1, 3);
        chk(u_dut.wu_act[1] == 1'b0, "RAd dut wu_act[1] still 0 (init != false progress)");
        chk(u_dut.wu_zero[1] == 1'b0, "RAe dut NOT armed at low window (P2 gate blocks)");
        occ <= 17'd0;                           // 窗重开
        wait_slot(4'd1, 4);
        $display("  [READ] RA fires: dut=%0d base=%0d | wu_act dut=%b", f_dut, f_base, u_dut.wu_act[1]);
        chk(f_dut == 0, "RAf dut fires 0 on reconnected IDLE session (P2 gate holds)");
        chk(f_base == 1, "RAg base fires 1 (no gate => noise on idle conn)");

        // ================= RB: 残留 (1) 曾活跃后空闲 =================
        $display("RB: residual (1) -- conn that HAD data then went silent still fires");
        ev_down_at(4'd1);
        repeat (4) @(posedge clk);
        establish(4'd1, RNB);
        t_rcv_nxt[1] <= RNB + 32'd128;          // 收一段数据 (之后永远静默)
        wait_slot(4'd1, 3);
        chk(u_dut.wu_act[1] == 1'b1, "RBa dut wu_act[1]=1 (had data)");
        f_dut = 0; f_base = 0;                  // 计数清零 (本相只看新发的)
        occ <= OCC_HI;  wait_slot(4'd1, 3);     // 共享 occ: 涨
        occ <= 17'd0;   wait_slot(4'd1, 4);     // 共享 occ: 落 => 重开
        occ <= OCC_HI;  wait_slot(4'd1, 3);     // 再涨
        occ <= 17'd0;   wait_slot(4'd1, 4);     // 再落
        $display("  [READ] RB fires over 2 occ cycles: dut=%0d base=%0d", f_dut, f_base);
        chk(f_dut == 2, "RBb residual (1) CONFIRMED: dut fires 1 per occ cycle while silent");
        chk(f_base == 2, "RBc base same (control)");

        // ================= RC: 残留 (2) 从未收数据 + 先看到小窗 =================
        $display("RC: residual (2) -- never-received conn that saw a small window still waits");
        ev_down_at(4'd1);
        repeat (4) @(posedge clk);
        occ <= OCC_HI;                          // 小窗先立起来 (新会话第一眼就是小窗)
        establish(4'd1, 32'h2200_0001);         // 零数据 (rcv_nxt 永不推进)
        wait_slot(4'd1, 3);
        chk(u_dut.wu_act[1] == 1'b0, "RCa dut wu_act[1]=0 (never received)");
        chk(u_dut.wu_zero[1] == 1'b0, "RCb dut NOT armed even though window is small");
        f_dut = 0; f_base = 0;
        occ <= 17'd0;                           // 窗重开: 该发而 DUT 不发
        wait_slot(4'd1, 5);
        $display("  [READ] RC fires after reopen: dut=%0d base=%0d", f_dut, f_base);
        chk(f_dut == 0, "RCc residual (2) CONFIRMED: dut does NOT notify (waits for persist)");
        chk(f_base == 1, "RCd base DOES notify (this is what P2 gives up)");

        repeat (20) @(posedge clk);
        $display("------------------------------------------------------------");
        $display("lockstep violation cycles (must be 0) = %0d", lock_bad);
        chk(lock_bad == 0, "Z1 lockstep across 2 arms (same stimulus)");
        if (errs == 0) $display("REV_P2_GATE OK");
        else           $display("REV_P2_GATE FAIL %0d", errs);
        $finish;
    end
endmodule
