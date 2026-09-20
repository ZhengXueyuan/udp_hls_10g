`timescale 1ns/1ps
//=============================================================================
// tb_app_fc: app_ctrl 流控单元/定向门 (P5b 规格 §3 "P5b 定向门")
//
// 为什么需要它: flow 全链门跑的是"真实对端 + 慢消费者", 这些边角只能靠运气撞到:
//   ① C1/C2 的算术边界 (occ = 0 / winq-1 / winq / winq+1)
//   ② 4GB seq 回绕 (redge/rcv_nxt 跨 0xFFFFFFFF)
//   ③ H3: ev_up 落在 tick_cnt==15 拍 (init 与扫描对撞 ⇒ 快照毒化/redge 毒化)
//   ④ C14: 同槽 DEL→ADD 且遗留 occ > 16KB (零拷贝占用不释放 ⇒ 溢出缺口)
//   ⑤ C4/C15: 池授予/增量补授/归还饱和
// 本 TB 用假 TCB (可任意设初值) + 假占用, 直接驱动 ev_up/ev_down, 并把 fc 写口
// 接到一个"最小 TCB 模型"(只实现 rcv_wnd 字段) 上, 逐项定向断言。
//
// 判据输出: 每项 PASS/FAIL + 末尾 "P5 FC UNIT OK"/"P5 FC UNIT FAIL n" (bat 判).
//=============================================================================
module tb_app_fc;
    localparam [15:0] WINQ = 16'hC000;      // WIN_Q_MAX = WIN_POOL = 0xC000

    reg clk, rst_n;
    integer errs;
    integer wg;                        // P5c-T3: T10/T11 的等待/静默计数

    // ---------------- 假 TCB (16 槽; 组合读口 C) ----------------
    reg [31:0] t_rcv_nxt [0:15];
    reg [31:0] t_snd_nxt [0:15];
    reg [31:0] t_snd_una [0:15];
    reg [15:0] t_rcv_wnd [0:15];
    reg [15:0] t_snd_wnd [0:15];
    reg [3:0]  t_state   [0:15];

    // state 写模型: set (DUT 写, always 驱动) 与 clr (TB 清, initial 驱动) 分开存
    // —— 同一 reg 被两个 always/initial 驱动是竞争, 这里结构上避免
    reg  [15:0] fc_st_wr_bmp, fc_st_clr_bmp;
    wire [15:0] fc_state_clr = fc_st_wr_bmp & ~fc_st_clr_bmp;
    // T11 用: slot6 的模型 state (与 rc_state 同一合成法则, 免依赖当拍 rc_id)
    wire [3:0]  rc_state_6_w = fc_state_clr[6] ? 4'd0 : t_state[6];

    wire [3:0]  rc_id;
    wire [31:0] rc_rcv_nxt = t_rcv_nxt[rc_id];
    wire [31:0] rc_snd_nxt = t_snd_nxt[rc_id];
    wire [31:0] rc_snd_una = t_snd_una[rc_id];
    wire [15:0] rc_rcv_wnd = t_rcv_wnd[rc_id];
    wire [15:0] rc_snd_wnd = t_snd_wnd[rc_id];
    // P5c-T3: fc 的 state 写 (sel=5) 由 fc_state_clr 模型合成 (见下面的写模型)
    wire [3:0]  rc_state   = fc_state_clr[rc_id] ? 4'd0 : t_state[rc_id];

    reg  [16:0] occ;
    reg         ev_up, ev_down;
    reg  [3:0]  ev_slot;
    reg  [15:0] fin_sent;
    reg  [15:0] rst_sent;              // P5c-T3 G3: tcp_tx_frame.o_rst_sent
    reg         wu_gnt_r;
    wire        fc_upd_wr, wu_req;
    wire [3:0]  fc_upd_id, wu_id;
    wire [2:0]  fc_upd_sel;
    wire [31:0] fc_upd_val, wu_val;
    wire        fc_gnt;
    wire [15:0] app_tx_ready;
    wire [15:0] dbg_winq0, dbg_wu_mark0;
    wire [31:0] dbg_redge0;
    wire [16:0] dbg_pool;
    wire [31:0] stat_wu, stat_px, stat_fc, stat_wa;
    wire [31:0] stat_reuse;            // C18: 已占槽二次 ev_up
    reg  [31:0] wu_base;               // T7 的 stat_wu 基线 (drain 后)
    reg  [7:0]  reg_addr;
    wire [31:0] reg_rdata;
    wire [3:0]  dbg_c0_state;
    // ---- P5c-T3: 超时/state 写观测 ----
    wire [15:0] rst_req_o;
    wire [15:0] stat_down_o;                    // (不用; 见下)
    wire        ac_ev_down_w;                   // 超时 CONN_DOWN 脉冲
    wire [3:0]  ac_ev_slot_w;
    reg  [3:0]  down_slot_r;
    reg  [15:0] down_seen;                      // 收到过 CONN_DOWN 的槽位图
    reg  [31:0] fc_st_wr, fc_wnd_wr, fc_wr_all; // fc 落地写分类计数
    reg  [3:0]  fc_st_id;                       // 最近一次 state 写的槽
    reg  [31:0] fc_st_val;                      // 最近一次 state 写的值
    reg  [31:0] down_base;                      // T10 的 stat_ev_down 基线
    reg  [31:0] st_base;                        // T10 的 fc state 写基线
    reg  [15:0] winq_base;                      // T10: 触发前的 winq[5]
    reg  [16:0] pool_base;                      // T10: 触发前的池余额
    reg  [17:0] fin_to9_r;                      // T13: 触发后计数快照 (不得被活性清零)
    reg  [31:0] sum_winq;                       // Σwinq (守恒式 Σwinq + pool == WIN_POOL)
    integer     kk;

    // ---- 第 4 级仲裁的接受端模型: fc 独占 (无 tx/rx/cfg 竞争) ⇒ 直接 gnt ----
    // P5c-T3: st_hold 只扣住 **state 写** (sel=5), 让窗口纠偏写 (sel=3) 照常落地。
    // 为什么不能扣全部: 超时/abort 收尾会归还配额 (winq=0) ⇒ 下一轮扫描必然产生一次
    // 窗口纠偏写; 若把它也扣住, 请求寄存器会被窗口写永久占住, state 写永远排不上
    // (实测踩过 — 那是 TB 模型的失真, 不是 RTL 缺陷: 真 wrapper 里 fc 是最低优先级
    //  电平请求, 窗口写会被 gnt 消化, 不会永久占位)。
    // st_hold 的用途: 把"state 写请求已挂出但未落地"的窗口拉长 —— 该窗口是
    // st_done 守卫 (只触发一次) 与 app_tx_ready fence 唯一可观测的时段。
    reg  st_hold;
    assign fc_gnt = fc_upd_wr && !(st_hold && (fc_upd_sel == 3'd5));
    // rst_req 置位观察 (粘滞位图): rst_req 会被"state 落地后扫描见非 ESTAB"清掉,
    // 故不能等测试末尾再采 (那是自愈之后的稳态)。
    reg  [15:0] rst_req_seen;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) rst_req_seen <= 16'd0;
        else        rst_req_seen <= rst_req_seen | rst_req_o;

    // ---- 最小 TCB 写模型: rcv_wnd (sel=3) + state (sel=5, P5c-T3) ----
    // P5c-T3: state 写不直接改 t_state 数组 (该数组由 TB 激励块驱动, 两个 always
    // 驱动同一 reg 是竞争) — 改为记在 fc_state_clr 位图里, 由 rc_state 读口组合
    // 合成 (模型语义: 被 fc 写过 state=0 的槽, 其 state 读回 0; TB 可用
    // fc_state_clr[x] <= 0 模拟"新会话 ADD 又把它写回 1")。
    integer ti;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (ti = 0; ti < 16; ti = ti + 1) t_rcv_wnd[ti] <= 16'd0;
            fc_st_wr_bmp <= 16'd0; fc_st_wr <= 32'd0; fc_wnd_wr <= 32'd0;
            fc_wr_all <= 32'd0; fc_st_id <= 4'd0; fc_st_val <= 32'd0;
        end else if (fc_gnt) begin
            fc_wr_all <= fc_wr_all + 32'd1;
            case (fc_upd_sel)
                3'd3: begin t_rcv_wnd[fc_upd_id] <= fc_upd_val[15:0];
                            fc_wnd_wr <= fc_wnd_wr + 32'd1; end
                3'd5: begin fc_st_wr_bmp[fc_upd_id] <= 1'b1;
                            fc_st_wr <= fc_st_wr + 32'd1;
                            fc_st_id <= fc_upd_id; fc_st_val <= fc_upd_val; end
                default: ;
            endcase
        end
    end

    // CONN_DOWN 脉冲监视 (T10): o_ev_down 是 1 拍脉冲, o_ev_slot 同拍有效
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            down_seen <= 16'd0; down_slot_r <= 4'd0;
        end else if (ac_ev_down_w) begin
            down_seen[ac_ev_slot_w] <= 1'b1;
            down_slot_r <= ac_ev_slot_w;
        end
    end

    app_ctrl #(.WIN_CAP(16'hBFFE), .WIN_POOL(16'hC000), .WIN_Q_MAX(16'hC000),
               // P5c-T3 G2: 超时阈值按本门规模缩小 (生产值 195313 轮 = 400ms;
               // 10 轮 = 2560 拍, 判据与阈值大小无关, 只要求"能数到")
               .FIN_TO_LIM(18'd10))
    u_dut (
        .clk(clk), .rst_n(rst_n),
        .ev_up(ev_up), .ev_down(ev_down), .ev_slot(ev_slot),
        .ev_peer_ip(32'h0), .ev_peer_port(16'h0), .ev_peer_mac(48'h0),
        .rc_id(rc_id), .rc_snd_nxt(rc_snd_nxt), .rc_snd_una(rc_snd_una),
        .rc_rcv_nxt(rc_rcv_nxt), .rc_rcv_wnd(rc_rcv_wnd),
        .rc_snd_wnd(rc_snd_wnd), .rc_state(rc_state),
        .rx_occ_bytes(occ), .fin_sent(fin_sent), .rst_sent(rst_sent),
        .o_ev_up(), .o_ev_down(ac_ev_down_w), .o_ev_slot(ac_ev_slot_w),
        .fin_req(), .rst_req(rst_req_o),
        .fc_upd_wr(fc_upd_wr), .fc_upd_id(fc_upd_id), .fc_upd_sel(fc_upd_sel),
        .fc_upd_val(fc_upd_val), .fc_gnt(fc_gnt),
        .wu_req(wu_req), .wu_id(wu_id), .wu_val(wu_val), .wu_gnt(wu_gnt_r),
        .close_req(1'b0), .close_id(4'd0),
        .reg_addr(reg_addr), .reg_wr(1'b0), .reg_wdata(32'd0),
        .reg_rdata(reg_rdata),
        .app_tx_ready(app_tx_ready),
        .dbg_c0_state(dbg_c0_state), .dbg_c0_snd_nxt(), .dbg_c0_snd_una(),
        .dbg_c0_rcv_nxt(), .dbg_c0_rcv_wnd(), .dbg_c0_snd_wnd(),
        .dbg_estab_cnt(), .dbg_ev_cnt(),
        .dbg_redge0(dbg_redge0), .dbg_winq0(dbg_winq0),
        .dbg_wu_mark0(dbg_wu_mark0), .dbg_pool(dbg_pool),
        .stat_ev_up(), .stat_ev_down(stat_down_o), .stat_ev_drop(),
        .stat_cmd_close(), .stat_cmd_abort(),
        .stat_wu(stat_wu), .stat_pool_exhaust(stat_px), .stat_fc_upd(stat_fc),
        .stat_fc_wait_max(stat_wa), .stat_slot_reuse(stat_reuse)
    );

    always #4 clk = ~clk;

    // ---------------- 工具 ----------------
    task chk;
        input        cond;
        input [255:0] name;
        begin
            if (cond) $display("  PASS %0s", name);
            else begin
                errs = errs + 1;
                $display("  FAIL %0s", name);
            end
        end
    endtask

    // 等待下一个"扫描到 slot s"的拍 (tick_cnt==15 && scan_id==s)
    // P5b 第二轮: 扫描块改成 3 拍流水 (拍 T 采样 / T+1 右沿 / T+2 fc+wu+C15),
    // 故末尾要多等 2 拍才算"判据已落地" (原来是 1 拍)。
    task wait_scan;
        input [3:0] s;
        integer g;
        begin
            g = 0;
            while (!((u_dut.tick_cnt == 4'd15) && (u_dut.scan_id == s) &&
                     !u_dut.init_pend) && (g < 4000)) begin
                @(posedge clk); g = g + 1;
            end
            repeat (3) @(posedge clk);   // T -> T+1 (redge/pb) -> T+2 (fc/wu/C15)
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

    // P5c-T3: 等 fc 通道**连续** q 拍无请求 (q=600 > 一轮 256 拍 ⇒ 16 个槽的窗口
    // 纠偏全部落地且无新请求)。只等"第一次空闲"是不够的: 期间出现的请求会被随后
    // 拉起的 fc_hold 卡住 (实测踩过 — 观测窗口被一个窗口写占住)。
    // 返回: 实际达到的连续静默拍数 (在 wg 里)。
    integer wgt;
    task fc_quiet;
        input integer q;
        integer cons;
        begin
            cons = 0; wgt = 0;
            while ((cons < q) && (wgt < 60000)) begin
                @(posedge clk); wgt = wgt + 1;
                if (fc_upd_wr) cons = 0; else cons = cons + 1;
            end
            wg = cons;
        end
    endtask

    // wu 排空: 把仍在挂起的电平请求逐个 gnt 清掉, 并把 stat_wu 记为基线。
    // 为什么需要: P5b 判据窗口 = 空闲量 fq, 故 occ >= winq 的定向用例 (T2c/T2d)
    // 会置 wu_zero ⇒ 窗口重开时挂出 wu 请求 (这是**正确**行为: 曾通告 W=0 就必须
    // 主动通知重开)。T7 之前必须先排空, 否则 T7 测的是残留请求。
    task wu_drain;
        integer g;
        begin
            g = 0;
            while (wu_req && (g < 200)) begin
                @(posedge clk); wu_gnt_r <= 1'b1;
                @(posedge clk); wu_gnt_r <= 1'b0;
                g = g + 1;
            end
            @(posedge clk);
            wu_base = stat_wu;
        end
    endtask

    // 建立连接 (slot s, rcv_nxt = rn)
    task establish;
        input [3:0]  s;
        input [31:0] rn;
        begin
            t_state[s]   <= 4'd1;
            t_rcv_nxt[s] <= rn;
            t_rcv_wnd[s] <= 16'hC000;      // HLS ADD 写死的静态值 (C10 场景)
            t_snd_wnd[s] <= 16'h4000;
            ev_up_at(s);
            repeat (6) @(posedge clk);     // 等 init 拍 + fc 写落地
        end
    endtask

    initial begin
        clk = 0; rst_n = 0; errs = 0;
        ev_up = 0; ev_down = 0; ev_slot = 0; occ = 0; fin_sent = 0;
        rst_sent = 0; st_hold = 0;
        fc_st_clr_bmp = 16'd0;   // 必须显式初值: 悬空 X 会让 fc_state_clr 变 X
                                 // (1 & X = X ⇒ "已写 state" 判据恒假 — 实测踩过)
        wu_gnt_r = 0; reg_addr = 8'h00;
        for (ti = 0; ti < 16; ti = ti + 1) begin
            t_rcv_nxt[ti] = 32'd0; t_snd_nxt[ti] = 32'd0; t_snd_una[ti] = 32'd0;
            t_rcv_wnd[ti] = 16'd0; t_snd_wnd[ti] = 16'd0; t_state[ti] = 4'd0;
        end
        #100; rst_n = 1;
        repeat (30) @(posedge clk);

        // ================= T1: C4/C3/C10 建立 (occ=0) =================
        $display("T1: C4/C3/C10 建立 (occ=0, 单连接拿满池)");
        establish(4'd0, 32'h2000_0001);
        chk(u_dut.winq[0] == WINQ, "T1a winq[0]=C000 (拿满池)");
        chk(dbg_pool == 17'd0, "T1b pool=0 (全部授予)");
        chk(u_dut.redge[0] == (32'h2000_0001 + WINQ),
            "T1c redge[0] = rcv_nxt + winq (C3)");
        chk(dbg_wu_mark0 == WINQ, "T1d wu_mark[0]=winq (C10)");
        chk(t_rcv_wnd[0] == WINQ, "T1e C10 立即纠偏 TCB.rcv_wnd = winq");

        // ================= T2: 算术边界 (occ = 0 / winq-1 / winq / winq+1) ====
        // P5b 第二轮: 探针从已删除的 warr[] (redge 组合重算) 换成**扫描流水线的
        // 判据寄存器 pb_wscan** (= 该次扫描真正判定的窗口 = fc_wq 写入值, 见
        // app_ctrl 文件头等价性证明)。四点断言改为精确值 (比原来 "<= winq" 更紧):
        // 窗口 = 空闲量 fq = max(0, winq - occ)。
        $display("T2: C1 饱和 (occ 四点; 判据窗口 = 空闲量, 无回绕)");
        // occ = 0: 全窗
        occ <= 17'd0;
        wait_scan(4'd0);
        chk(u_dut.pb_wscan == WINQ, "T2a occ=0: 判据窗 = winq");
        // occ = winq-1: 剩 1 字节
        occ <= WINQ - 16'd1;
        wait_scan(4'd0);
        chk(u_dut.pb_wscan == 16'd1, "T2b occ=winq-1: 判据窗 = 1");
        chk((u_dut.redge[0] - t_rcv_nxt[0]) <= {16'b0, WINQ},
            "T2b2 redge-rcv_nxt <= winq (只抬高/不越配额)");
        // occ = winq: 饱和为 0 (redge 不动 — 右沿不可撤回)
        occ <= WINQ;
        wait_scan(4'd0);
        chk(u_dut.pb_wscan == 16'd0, "T2c occ=winq: 判据窗 = 0");
        chk((u_dut.redge[0] - t_rcv_nxt[0]) <= {16'b0, WINQ},
            "T2c2 occ=winq: redge-rcv_nxt <= winq (未回绕)");
        // occ = winq+1: **关键** — 裸减法会回绕成巨值
        occ <= WINQ + 16'd1;
        wait_scan(4'd0);
        chk(u_dut.pb_wscan == 16'd0,
            "T2d occ=winq+1: 判据窗 = 0 (饱和; 裸减法回绕就 FAIL)");
        chk((u_dut.redge[0] - t_rcv_nxt[0]) <= {16'b0, WINQ},
            "T2d2 occ=winq+1: redge-rcv_nxt <= winq");
        // occ = 0 且 rcv_nxt 不动 (占用由消费释放 ⇒ 窗口重开)
        occ <= 17'd0;
        t_rcv_nxt[0] <= 32'h2000_0001;
        wait_scan(4'd0);
        chk(u_dut.pb_wscan == WINQ, "T2e occ=0 (消费后): 判据窗回到 winq");
        chk(u_dut.redge[0] == (32'h2000_0001 + WINQ),
            "T2f 消费后 redge 抬到 rn + winq (单调只升)");

        // ================= T3: 4GB 回绕 =================
        $display("T3: 4GB seq 回绕 (redge/rcv_nxt 跨 0xFFFFFFFF)");
        occ <= 17'd0;
        t_rcv_nxt[0] <= 32'hFFFF_FF00;      // 近回绕点
        u_dut.redge[0] = 32'hFFFF_FF00 + WINQ;   // 跨过 0xFFFFFFFF (值回绕)
        u_dut.c_rcv_nxt[0] = 32'hFFFF_FF00;
        wait_scan(4'd0);
        chk(u_dut.pb_wscan == WINQ, "T3a 跨回绕: 判据窗 = winq (与 redge 数值无关)");
        chk((u_dut.redge[0] - t_rcv_nxt[0]) == {16'b0, WINQ},
            "T3b 跨回绕: redge-rcv_nxt == winq (模 2^32 差)");
        chk($signed(u_dut.redge[0] - t_rcv_nxt[0]) > 32'sd0,
            "T3c 序比较: redge 领先 rcv_nxt (跨回绕不判负)");
        // redge 数值上"更小"但语义在后 (需抬高): 序比较必须判为可推进
        u_dut.redge[0] = 32'h0000_0010;          // 落后于 rn + winq (语义上)
        u_dut.c_rcv_nxt[0] = 32'hFFFF_FF00;
        wait_scan(4'd0);
        chk(u_dut.redge[0] == (32'hFFFF_FF00 + WINQ),
            "T3d 回绕语义: redge 抬到 rn + winq (数值上从 0x10 跳到 0xBF00)");
        chk((u_dut.redge[0] - 32'hFFFF_FF00) == {16'b0, WINQ},
            "T3e 跨回绕: 窗口 = winq (不被 32 位回绕骗成大数/0)");

        // ================= T4: H3 — ev_up 落在 tick_cnt==15 拍 =================
        $display("T4: H3 扫描/init 对撞 (ev_up 打在扫描拍)");
        // 准备: slot1 用与 slot0 完全不同的值, 便于识别快照毒化
        t_state[1]   <= 4'd1;
        t_rcv_nxt[1] <= 32'h3000_0001;
        t_rcv_wnd[1] <= 16'hC000;
        t_snd_wnd[1] <= 16'h4000;
        occ <= 17'd0;
        // 等到 tick_cnt==14 再拉 ev_up ⇒ 下一拍 (= 扫描拍) init_pend=1
        while (u_dut.tick_cnt != 4'd14) @(posedge clk);
        @(posedge clk); ev_up <= 1'b1; ev_slot <= 4'd1;
        @(posedge clk); ev_up <= 1'b0;
        repeat (8) @(posedge clk);
        chk(u_dut.winq[1] == 16'd0,
            "T4a 池空(slot0 已拿满): slot1 授予 0 (C15 语义)");
        chk(u_dut.redge[1] <= 32'h3000_0001,
            "T4b init 拍 redge[1] 用 occ 修正 (= rcv_nxt, W=0)");
        // 快照毒化检查: 若 init 拍采样未暂停, 会把 slot1 的值写进 c_*[scan_id]
        chk(u_dut.c_rcv_nxt[0] != 32'h3000_0001,
            "T4c 快照未毒化 (c_rcv_nxt[0] 不是 slot1 的值)");
        chk(u_dut.c_rcv_nxt[1] == 32'h3000_0001,
            "T4d init 拍把 slot1 的 rcv_nxt 写进 c_*[1] (fc 取值自洽)");

        // ================= T5: C15 增量补授 =================
        $display("T5: C15 增量授权 (池回收后自愈)");
        ev_down_at(4'd0);                       // 归还 slot0 的配额
        t_state[0] <= 4'd0;                     // DEL 同时写 state=0 (slow_cfg_adp 语义;
                                                // 不清则扫描会把配额又补授回 slot0)
        repeat (4) @(posedge clk);
        chk(dbg_pool == {1'b0, WINQ}, "T5a ev_down 归还后 pool=C000");
        wait_scan(4'd1);                        // 扫描 slot1 ⇒ 补授
        chk(u_dut.winq[1] == WINQ, "T5b 扫描补授: slot1 winq=C000");
        $display("DBG T5: winq1=%04x pool=%05x (exp winq=C000 pool=0)",
                 u_dut.winq[1], dbg_pool);
        chk(dbg_pool == 17'd0, "T5c 补授后 pool=0");

        // ================= T6: C14 — DEL→ADD 且遗留 occ > 16KB =================
        $display("T6: C14 零拷贝遗留占用 (DEL->ADD, occ=20KB)");
        occ <= 17'd20000;                       // 遗留占用 (app 没读走)
        ev_down_at(4'd1);                       // 拆连 (占用不释放)
        repeat (4) @(posedge clk);
        t_rcv_nxt[1] <= 32'h4000_0001; t_rcv_wnd[1] <= 16'hC000;
        t_state[1]   <= 4'd1;
        ev_up_at(4'd1);                         // 同槽重连
        repeat (8) @(posedge clk);
        chk(u_dut.winq[1] == (WINQ - 16'd20000),
            "T6a 授予 = pool - occ (预留物理占用)");
        chk((u_dut.redge[1] - 32'h4000_0001) <= {16'b0, u_dut.winq[1]},
            "T6b init redge 用 occ 修正 (不超配额)");
        // 溢出判据: 遗留占用 + 新承诺 <= 物理容量 (65536)
        chk(({1'b0, occ} + (u_dut.redge[1] - 32'h4000_0001)) <= 17'd65536,
            "T6c occ + 承诺 <= 65536 (物理不溢出)");
        $display("DBG T6: t_rcv_wnd1=%04x (exp winq1-occ=%04x) winq1=%04x pool=%05x fc_wr=%0d redge1=%08x rcv1=%08x",
                 t_rcv_wnd[1], u_dut.winq[1] - 16'd20000, u_dut.winq[1], dbg_pool,
                 fc_upd_wr, u_dut.redge[1], 32'h4000_0001);
        // C10 纠偏写落地值 = 该连接**当前应通告窗口** = min(winq, 空闲量):
        // 授予量已扣过 occ (C14-①), init/扫描又按 (winq - occ) 修正 (C14-②) ⇒
        // 落地值是"再扣一次 occ"的保守值 (双保险; 长期窗随占用释放长回 winq)。
        chk(t_rcv_wnd[1] == (u_dut.winq[1] - 16'd20000),
            "T6d C10 纠偏写落地 = 空闲量 (winq - occ)");

        // T7 前置: 排空 T2/T3 因 occ >= winq 触发的 wu 请求 (P5b 判据窗口语义下
        // wu_zero 更敏感 — 见 wu_drain 注释), 并记 stat_wu 基线
        wu_drain();

        // ================= T7: wu 通路 (电平 + gnt) =================
        $display("T7: C6 wu (窗口关->开 触发, gnt 才清)");
        // 先造"窗关": occ 顶满配额 ⇒ wscan 收到 0 ⇒ wu_zero 置位 (必须有这一步,
        // 否则窗从未关过, 不触发 wu 才是正确行为)
        // 窗关 = 占用顶满配额 **且** 对端把已承诺的数据发完 (rcv_nxt 追到 redge);
        // 只压 occ 不够: redge 领先 rcv_nxt 时窗口 = 承诺余量 (仍是正数, 不该关)
        occ <= {1'b0, u_dut.winq[1]};
        t_rcv_nxt[1] <= u_dut.redge[1];
        wait_scan(4'd1);
        // 再放开: 窗重开 ⇒ 应挂 wu 请求 (电平)
        occ <= 17'd0;
        wait_scan(4'd1);
        // 窗口重开后应挂一个 wu 请求; 不给 gnt 时应保持
        if (wu_req) begin
            chk(wu_req, "T7a 窗重开触发 wu_req");
            repeat (50) @(posedge clk);
            chk(wu_req, "T7b 无 gnt 时 wu_req 保持电平 (M1 教训)");
            // 给 gnt
            @(posedge clk); wu_gnt_r <= 1'b1;
            @(posedge clk); wu_gnt_r <= 1'b0;
            repeat (3) @(posedge clk);
            chk(!wu_req, "T7c gnt 后 wu_req 释放");
            chk(stat_wu == (wu_base + 32'd1), "T7d stat_wu 计数 +1 (相对基线)");
        end else begin
            chk(1'b0, "T7a 窗重开应触发 wu_req (未触发)");
        end

        // ================= T8: C18 — 同槽二次 ev_up 无 ev_down =================
        // 危险构型: 该槽持满配额而池为空 ⇒ 旧配额若被 g_grant 覆盖却不归池,
        // pool 恒 0 ⇒ C15 补授 (要求 pool != 0) 永远救不回 ⇒ **永久零窗**。
        $display("T8: C18 同槽二次 ev_up (旧配额先归还, 不蒸发)");
        occ <= 17'd0;
        u_dut.winq[1] = WINQ;               // 槽 1 持满配额
        u_dut.pool    = 17'd0;              // 池空 (旧版: 旧配额在此蒸发)
        @(posedge clk);
        t_state[1]   <= 4'd1;               // 已占用槽 (state 仍 ESTAB)
        t_rcv_nxt[1] <= 32'h6000_0001;
        t_rcv_wnd[1] <= 16'hC000;
        ev_up_at(4'd1);                     // 无 ev_down 的二次 ADD
        repeat (4) @(posedge clk);
        // 守恒式 (与扫描相位无关): 旧版 = 0 (旧配额蒸发), C18 修后 = WIN_POOL
        chk(({1'b0, dbg_pool} + {1'b0, u_dut.winq[1]}) == {1'b0, WINQ},
            "T8a 配额不蒸发: winq[1] + pool == WIN_POOL");
        $display("DBG T8: winq1=%04x pool=%05x (期望和 = %04x)",
                 u_dut.winq[1], dbg_pool, WINQ);
        reg_addr <= 8'h9E;
        repeat (2) @(posedge clk);
        chk(reg_rdata == 32'd1, "T8b stat_slot_reuse = 1 (观测到槽复用)");
        reg_addr <= 8'h00;
        repeat (2) @(posedge clk);
        wait_scan(4'd1);                    // C15 增量补授自愈
        chk(u_dut.winq[1] == WINQ, "T8c C15 补授自愈: winq[1]=C000 (不永久零窗)");
        chk(dbg_pool == 17'd0, "T8d 补授后 pool=0 (Σwinq + pool = WIN_POOL 守恒)");
        chk(({1'b0, dbg_pool} + {1'b0, u_dut.winq[1]}) == {1'b0, WINQ},
            "T8e 守恒: Σwinq + pool == WIN_POOL");

        // ================= T9: C17 — ev_up 同槽扫描拍对撞 (扫描让位) ==========
        // 症状 (规格 C17): 扫描块在 always 里更靠后 ⇒ 覆盖事件块的授权/清理:
        //  ① winq[slot] 走 C15 增量补授 (min(WINQ-winq, pool)) 而非 C14-① 的
        //     授予预留 (min(WINQ, pool-occ)) —— 记账偏离 (测试 agent TC-A 实测)。
        // 本用例: occ=20000 且 winq[3]=0 ⇒ 两式给出不同结果 (29152 vs 49152)。
        // ② (wu_zero 被覆盖) 已由 init 拍的清 0 兜住 ⇒ 不可观测, 见报告。
        $display("T9: C17 ev_up 落在同槽扫描拍 (扫描让位, 授予=预留量)");
        // **先同步到槽 3 扫描拍的前一拍**再布置状态 —— 否则布置期间槽 3 被扫到,
        // C15 就会先把 winq[3] 补到 WINQ (把用例前提毁掉)。
        while (!((u_dut.tick_cnt == 4'd14) && (u_dut.scan_id == 4'd3)))
            @(posedge clk);
        occ <= 17'd20000;
        u_dut.winq[3] = 16'd0;
        u_dut.pool    = {1'b0, WINQ};       // 池满 ⇒ C15 会补到 WINQ (若无 C17)
        t_state[3]   <= 4'd1;
        t_rcv_nxt[3] <= 32'h7000_0001;
        t_rcv_wnd[3] <= 16'hC000;
        t_snd_wnd[3] <= 16'h4000;
        // 下一拍 (= scan_id==3 的扫描拍) 拉 ev_up ⇒ 事件与扫描同拍对撞
        @(posedge clk); ev_up <= 1'b1; ev_slot <= 4'd3;
        @(posedge clk); ev_up <= 1'b0;
        repeat (8) @(posedge clk);
        chk(u_dut.winq[3] == (WINQ - 16'd20000),
            "T9a 授予 = min(WINQ, pool-occ) = 29152 (未被 C15 补授覆盖)");
        chk(dbg_pool == 17'd20000,
            "T9b 池扣 = pool - g = 20000 (记账与授予一致)");
        chk(({1'b0, dbg_pool} + {1'b0, u_dut.winq[3]}) == {1'b0, WINQ},
            "T9c 守恒: winq[3] + pool == WIN_POOL");

        // ================= T10: P5c-T3 G2 — 关闭超时 =================
        // fin_sent[c] && state==ESTAB 连续 FIN_TO_LIM 轮扫描 ⇒ ① rst_req[c]
        // ② CONN_DOWN 事件 (o_ev_down/o_ev_slot) ③ state=0 写 (fc 通道 sel=5)。
        // 用 fc_hold 把"请求挂出但未落地"的窗口拉长: 该窗口内才能同时看到
        // rst_req 仍置位 + state 仍是 1 (未拆) + 只发过一次事件 (st_done 守卫)。
        $display("T10: G2 关闭超时 (abort + CONN_DOWN + state=0, 只触发一次)");
        occ <= 17'd0;
        establish(4'd5, 32'h8000_0001);     // slot5 建连 (state=1)
        // 前置: fc 通道静默 >= 1 整轮扫描 (600 拍 > 256) —— C15 增量授权与窗口
        // 纠偏全部落地且无新请求 ⇒ 随后挂出的 state 请求是通道上唯一请求, 观测
        // (sel/id/val) 才不会指到别的槽的窗口写
        fc_quiet(600);
        chk(wg >= 600, "T10a 前置: fc 通道静默 >= 1 轮扫描 (观测窗口干净)");
        if (wg < 600) $display("DBG T10a: wg=%0d wgt=%0d fc_upd_wr=%0d sel=%0d id=%0d val=%08x fc_v=%0d pend=%04x",
                               wg, wgt, fc_upd_wr, fc_upd_sel, fc_upd_id, fc_upd_val,
                               u_dut.fc_v, u_dut.fc_pend);
        st_hold <= 1'b1;
        @(posedge clk);
        fin_sent <= 16'h0020;               // bit5: FIN 已发 (超时条件的一半)
        down_base = stat_down_o;            // CONN_DOWN 计数基线
        st_base   = fc_st_wr;               // state 写计数基线
        winq_base = u_dut.winq[5];          // 配额归还基线 (审查 F1)
        pool_base = dbg_pool;
        // 先自检"计数起点未被污染": 阈值 10 轮 = 2560 拍, 200 拍内最多扫到 slot5
        // 一次 ⇒ 不得触发 (计数不提前/不跨会话)
        repeat (200) @(posedge clk);
        chk(rst_req_seen[5] == 1'b0, "T10b 未到阈值不触发 (计数不提前)");
        // 等 state 写请求挂出 (阈值 10 轮到点后; st_hold ⇒ 它会一直挂着)
        wg = 0;
        while (!(fc_upd_wr && (fc_upd_sel == 3'd5) && (fc_upd_id == 4'd5)) &&
               (wg < 8000)) begin @(posedge clk); wg = wg + 1; end
        chk(wg < 8000, "T10c 超时到点 ⇒ state 写请求挂出 (阈值内触发)");
        // ---- 配额归还 (审查 F1 实测的缺陷): state=0 写不产生 ev_down, 只是写 state
        // 而不归还配额 ⇒ 池被死连接永久占住 ⇒ 后续新连接 winq=0 ⇒ 通告窗 0 ⇒
        // 收不了数据 (G2 的目标"再也建不了连"换一种形式复活)。 ----
        // 归还量精确值的检查在本 TB 不可靠: 池是全局共享的, 归还后 C15 会在最近一次
        // 扫描拍把余额授给别的 ESTAB 槽 (本 TB 里槽 1/3 仍 ESTAB) ⇒ pool 立即被合法
        // 消费; 且 T8/T9 用层次写值造过场景 ⇒ Σwinq + pool 的绝对值已被污染。
        // 本门只断言"死连接不再持有配额"(判据的充分条件: 不归还时 winq[5] 恒 20000);
        // "新连接仍能拿到配额"的端到端判据在跨模块 TB (审查 agent 的 R6) 与板级。
        chk(u_dut.winq[5] == 16'd0, "T10r 超时归还该槽配额: winq[5]=0 (死连接不占池)");
        chk(dbg_pool >= pool_base, "T10s 池余额未减少 (归还方向正确)");
        // 等 2 拍再读脉冲监视寄存器: 监视 always 与 @(posedge) 循环同沿触发,
        // 同沿读到的是监视寄存器的**旧值** (坑 3 同类边界 — 别急着改 RTL)
        repeat (2) @(posedge clk);
        chk(rst_req_seen[5] == 1'b1, "T10d 超时 ⇒ rst_req[5]=1 (abort 该连接)");
        chk(stat_down_o == (down_base + 32'd1), "T10e CONN_DOWN 事件恰一次 (+1)");
        chk(down_seen[5] == 1'b1, "T10f o_ev_down 脉冲 + o_ev_slot=5 (同拍一致)");
        chk(t_state[5] == 4'd1, "T10g 前置: 连接仍 ESTAB (state 写还没落地)");
        chk(fc_st_wr == st_base, "T10h state 写尚未落地 (st_hold)");
        chk(fc_upd_sel == 3'd5, "T10i fc_upd_sel = 5 (state 写)");
        chk(fc_upd_val == 32'd0, "T10j fc_upd_val = 0 (state=0)");
        // st_done 守卫: 阈值已过且条件仍成立 (fin_sent=1 / t_state=1), 再等 3 轮
        // 扫描不得重复触发 (事件计数与写请求都不得再变)
        repeat (800) @(posedge clk);
        chk(stat_down_o == (down_base + 32'd1), "T10k 只触发一次 (事件不再增)");
        chk(fc_st_wr == st_base, "T10l 只触发一次 (无重复 state 写请求)");
        // 放行 ⇒ 写落地 ⇒ TCB 模型 state=0 ⇒ app_ctrl 扫描见非 ESTAB 清 rst_req
        st_hold <= 1'b0;
        repeat (600) @(posedge clk);
        chk(fc_st_wr == (st_base + 32'd1), "T10m 放行后 state 写恰一次落地");
        chk(fc_st_id == 4'd5, "T10n state 写的 id=5");
        chk(fc_state_clr[5] == 1'b1, "T10o TCB state 被写 0 (拆连完成)");
        // state=0 落地后: 扫描见非 ESTAB ⇒ 清该槽 rst_req (自愈, 不需外部干预)
        chk(rst_req_o[5] == 1'b0, "T10p state=0 后扫描清 rst_req[5] (自愈)");
        // 同槽重连 (坑 9): ev_up 清 fin_to/st_done ⇒ 旧会话的 10 轮计数不得继承
        // (继承则重连后立即再次超时 — 用一个"条件刚成立"的短窗口判别)
        fc_st_clr_bmp[5] <= 1'b1;           // 新会话 ADD: 模型 state 回到 1
        t_state[5]  <= 4'd1;
        st_base = fc_st_wr;
        down_base = stat_down_o;
        establish(4'd5, 32'hB000_0001);     // ev_up 清 st_done/fin_to
        fin_sent <= 16'h0020;               // 条件立刻成立
        repeat (512) @(posedge clk);        // 2 轮 (阈值 10 轮) — 继承就会秒触发
        chk((fc_st_wr == st_base) && (stat_down_o == down_base),
            "T10q 同槽重连不继承旧计数 (2 轮内无新 state 写/无新事件)");
        fin_sent <= 16'd0;

        // ================= T11: P5c-T3 G3 — abort 完成 ⇒ state=0 写 + fence ====
        // rst_sent[c] (RST 确实发出) ⇒ 扫描请求 state=0 写; 同拍 app_tx_ready[c]
        // 必须为 0 (fin_req/fin_sent 都为 0 时仍被 rst 项挡下 = fence 生效)。
        $display("T11: G3 abort 完成 (rst_sent ⇒ state=0 写 + app_tx_ready fence)");
        establish(4'd6, 32'h9000_0001);
        fc_quiet(600);
        chk(wg >= 600, "T11a 前置: fc 通道静默 >= 1 轮扫描");
        st_hold <= 1'b1;
        @(posedge clk);
        t_snd_nxt[6] <= 32'h9000_0001;      // 无在飞数据 (否则 tx_ready 本来为 0)
        t_snd_una[6] <= 32'h9000_0001;
        t_snd_wnd[6] <= 16'h4000;           // 窗开 ⇒ 未 abort 时应 ready
        fin_sent[6]  <= 1'b0;               // FIN 未发 ⇒ 只有 rst 项能挡
        repeat (600) @(posedge clk);        // 至少一轮扫描把 c_*[6] 采新
        chk(app_tx_ready[6] == 1'b1, "T11b 前置: 无 rst 项时 slot6 tx_ready=1");
        st_base = fc_st_wr;
        rst_sent <= 16'h0040;               // bit6: RST 已发出 (= abort 完成)
        wg = 0;
        while (!(fc_upd_wr && (fc_upd_sel == 3'd5) && (fc_upd_id == 4'd6)) &&
               (wg < 4000)) begin @(posedge clk); wg = wg + 1; end
        chk(wg < 4000, "T11c abort 完成 ⇒ state 写请求挂出");
        chk(app_tx_ready[6] == 1'b0, "T11d rst_sent 置位 ⇒ tx_ready=0 (fence 生效)");
        chk(rst_req_seen[6] == 1'b0, "T11e abort 完成不置 rst_req (RST 已发过)");
        chk(fc_st_wr == st_base, "T11f state 写请求已挂出但未落地 (st_hold)");
        chk(fc_upd_sel == 3'd5, "T11g fc_upd_sel = 5");
        chk(fc_upd_val == 32'd0, "T11h fc_upd_val = 0");
        st_hold <= 1'b0;
        repeat (600) @(posedge clk);
        chk(fc_st_wr == (st_base + 32'd1), "T11i state 写恰一次落地");
        chk(fc_state_clr[6] == 1'b1, "T11j TCB state 被写 0");
        // rst_sent 保持 1 (RST 已发就不再撤) + state 已 0 ⇒ 不得再重复写
        repeat (800) @(posedge clk);
        chk(fc_st_wr == (st_base + 32'd1), "T11k 保持 rst_sent 不重复写 (st_done)");
        // 同槽重连: tcp_tx_frame 的 cfg_up 与 app_ctrl 的 ev_up 是**同一个**脉冲
        // (slow_cfg_adp.ev_up) ⇒ 重连时 rst_sent_r 与 st_done 同拍清 —— 本 TB 照此
        // 建模 (rst_sent 与 establish 同拍清)。新会话不得被旧会话的 state 写顶掉。
        rst_sent <= 16'd0;                  // 模拟 cfg_up 清 rst_sent_r
        fc_st_clr_bmp[6] <= 1'b1;           // 新会话 ADD: 模型 state 回到 1
        t_state[6] <= 4'd1;
        st_base = fc_st_wr;
        establish(4'd6, 32'hA000_0001);
        repeat (600) @(posedge clk);
        chk(rc_state_6_w == 4'd1, "T11l 前置: 新会话 state 读回 1 (模型已还原)");
        chk(fc_st_wr == st_base, "T11m 同槽重连后无残留 state 写 (st_done 被 ev_up 清)");

        // ============ T12: P5c 活性判据 — 对端持续有数据 ⇒ 永不触发 ============
        // 板级缺陷 (本次修正的起因): T3 的判据只看 "fin_sent && ESTAB" ⇒ 把
        // "半关闭但仍在合法收对端数据"的活连接在 FIN_TO_LIM 轮后 RST 掉
        // (板侧 FIN@41ms / PC 最后数据字节@62ms / 板侧 RST@FIN+400.017ms ⇒
        //  PC 的 4MB 全丢, RX=0/RS=1, WinError 10053)。
        // 本项同时断言两件相反的事 (这就是"per-slot 隔离"的直接证据):
        //   ① 活性槽 (slot7, 每轮 rcv_nxt 推进): 计数每轮被清零 ⇒ 永不触发,
        //      配额不被归还, 无 CONN_DOWN, 无 state=0 写;
        //   ② 静默槽 (slot8, rcv_nxt 不动): 同几轮内照常到期触发 + 归还配额
        //      ⇒ 活性判据**不是**"加了就永不超时"。
        $display("T12: P5c 活性判据 (活性槽永不触发 / 静默槽照常触发, per-slot 隔离)");
        occ <= 17'd0;
        fin_sent <= 16'd0;
        // 池复位为满 (前序 T8/T9 层次改过池与 winq): 让两个槽各自拿满配额,
        // "活性期配额未被归还"才有精确值可断言 (与 T9 同一手法)。
        u_dut.pool    = {1'b0, WINQ};
        u_dut.winq[7] = 16'd0;
        establish(4'd7, 32'hC000_0001);
        chk(u_dut.winq[7] == WINQ, "T12a slot7 winq=WINQ");
        u_dut.pool    = {1'b0, WINQ};
        u_dut.winq[8] = 16'd0;
        establish(4'd8, 32'hD000_0001);
        chk(u_dut.winq[8] == WINQ, "T12b slot8 winq=WINQ");
        fin_sent  <= 16'h0180;              // bit7 + bit8: 两槽都"FIN 已发"
        down_base  = stat_down_o;           // 事件计数基线 (复用 T10 的变量)
        st_base    = fc_st_wr;              // state 写计数基线
        // 20 轮 = 2 x FIN_TO_LIM (阈值 10 轮): 活性期长度远超阈值 ⇒ 旧判据必触发
        for (kk = 0; kk < 20; kk = kk + 1) begin
            t_rcv_nxt[7] <= t_rcv_nxt[7] + 32'd1;   // 对端数据到达 (推进 rcv_nxt)
            wait_scan(4'd7);
            chk(u_dut.fin_to[7] == 18'd0, "T12c fin_to[7]=0 清零");
        end
        chk(rst_req_seen[7] == 1'b0, "T12d rst_req[7]=0 不触发");
        chk(down_seen[7] == 1'b0, "T12e 无 CONN_DOWN");
        chk(fc_st_wr_bmp[7] == 1'b0, "T12f 无 state 写");
        chk(u_dut.winq[7] == WINQ, "T12g winq[7] 未归还");
        chk(app_tx_ready[7] == 1'b0, "T12h tx_ready[7]=0");
        // ② 同一时段里的静默槽 (slot8): 到期触发 + 归还配额全部照常
        chk(rst_req_seen[8] == 1'b1, "T12i rst_req[8]=1");
        chk(down_seen[8] == 1'b1, "T12j 事件 slot8");
        chk(u_dut.winq[8] == 16'd0, "T12k winq[8]=0 归还");
        chk(stat_down_o == (down_base + 32'd1),
            "T12l 事件计数 +1");

        // ============ T13: P5c 活性判据 — 活性停止 ⇒ 从停止时刻重新计时 ========
        // 判据: 计数只在"该轮无新数据"时 +1 ⇒ 超时从**最后一次收到数据的那一轮**
        // 起算, 而不是从 FIN 发出时刻起算 (T3 旧判据是从 FIN 时刻起算)。
        // 构造: 先跑 > FIN_TO_LIM 轮活性 (旧判据会在这期间触发 ⇒ 与前缀断言互斥),
        // 再停止活性 ⇒ 断言随后恰在 ~FIN_TO_LIM+1 轮后触发。
        $display("T13: 活性停止后重新计时 (从停止时刻起算 FIN_TO_LIM 轮)");
        fin_sent <= 16'd0;
        u_dut.pool    = {1'b0, WINQ};
        u_dut.winq[9] = 16'd0;
        establish(4'd9, 32'hE000_0001);
        fin_sent <= 16'h0200;               // bit9
        // 阶段 1: 12 轮活性 (> 阈值 10 轮) —— 旧判据 (不看活性) 会在此触发
        for (kk = 0; kk < 12; kk = kk + 1) begin
            t_rcv_nxt[9] <= t_rcv_nxt[9] + 32'd1;
            wait_scan(4'd9);
        end
        chk((rst_req_seen[9] == 1'b0) && (u_dut.fin_to[9] == 18'd0),
            "T13a 12轮活性不触发");
        // 阶段 2: 停止活性 ⇒ 每轮 +1, 第 FIN_TO_LIM+1 = 11 轮触发
        // (第 LIM 轮把计数写成 LIM, to_fire 用寄存器值 ⇒ 下一轮才置 rst_req)
        wg = 0;
        while ((rst_req_seen[9] == 1'b0) && (wg < 40)) begin
            wait_scan(4'd9); wg = wg + 1;
        end
        $display("DBG T13b: 停止活性后触发耗时 = %0d 轮 (期望 FIN_TO_LIM+1 = 11)",
                 wg);
        if ((wg < 10) || (wg > 12))
            $display("DBG T13b!: wg=%0d fin_to[9]=%0d to_fired[9]=%0d rst_req[9]=%0d",
                     wg, u_dut.fin_to[9], u_dut.to_fired[9], u_dut.rst_req[9]);
        chk((wg >= 10) && (wg <= 12),
            "T13b 停后 11 轮触发");
        chk(rst_req_seen[9] == 1'b1, "T13c rst_req[9]=1");
        // 触发后 (state=0 写要等 fin_to 饱和到 fin_to_max 的兜底轮, 此刻仍 ESTAB)
        // 到达的数据**不得**把计数清零 —— 否则兜底 (F2) 永远等不到, 槽永久不释放。
        fin_to9_r = u_dut.fin_to[9];
        t_rcv_nxt[9] <= t_rcv_nxt[9] + 32'd1;
        wait_scan(4'd9);
        chk((u_dut.fin_to[9] != 18'd0) && (u_dut.fin_to[9] >= fin_to9_r),
            "T13d 触发后不清零");
        // 兜底: to_fired 后计数继续走到 fin_to_max ⇒ st_grace 挂 state=0 写
        st_base = fc_st_wr;
        repeat (2000) @(posedge clk);       // ~8 轮: 足够走到 fin_to_max 并落地
        chk(fc_st_wr >= (st_base + 32'd1), "T13e 兜底 state 写");
        fin_sent <= 16'd0;

        repeat (20) @(posedge clk);
        if (errs == 0) $display("P5 FC UNIT OK");
        else           $display("P5 FC UNIT FAIL %0d", errs);
        $finish;
    end
endmodule
