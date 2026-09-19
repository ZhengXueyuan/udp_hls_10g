`timescale 1ns/1ps
//=============================================================================
// app_ctrl: app 接口控制面 (P5a)
//
// 职责: ① 连接事件 FIFO (CONN_UP/CONN_DOWN, 源 = slow_cfg_adp) — 满则丢弃 +
// 计数, 绝不反压 HLS cfg 流; ② 16 分频轮扫 TCB 组合读口 C, 采集每连接
// state/snd_nxt/snd_una/rcv_nxt/rcv_wnd/snd_wnd 供寄存器读取 + 计算
// app_tx_ready; ③ 寄存器总线 (读组合, 写 1 拍); ④ FIN/RST 请求输出 (CMD 写
// close/abort 或 app_pattern 的 close_req)。
//
// P5a 范围: 不含 TCB 写口 / 窗口计算 (redge) / wu_req / 信用池 —— 那些是
// P5b/P5d (app 侧慢消费者与多连接配额)。这里的 app_tx_ready 用轮扫采到的
// 注册值算 (刷新周期 256 拍), 只作"能否呈现新帧"的粗门; 精门仍是
// tcp_tx_frame 的注册窗口门 win_open。
//
// 地址位宽: 8 位 (0x00..0xFF)。计划文档写"5 位地址", 但其自带的地址映射
// (0x10+4c 到 0x4F / 0x90+ 计数) 已超出 5 位可寻址范围 — 按映射实现, 位宽
// 放宽到 8 位 (将来 AXI-Lite 桥就是它的字节地址低位)。
//
// 事件字 (102 位, 入 16 深 FWFT FIFO; 头组合可读 = 寄存器 0x01..0x04):
//   {kind[1:0], slot[3:0], peer_mac[47:0], peer_port[15:0], peer_ip[31:0]}
//   kind: 0 = CONN_UP, 1 = CONN_DOWN
// 拆字 (寄存器读):
//   0x01 = {26'b0, kind, slot}
//   0x02 = peer_ip[31:0]
//   0x03 = {peer_port[15:0], peer_mac[47:32]}
//   0x04 = peer_mac[31:0]
//
// 寄存器映射 (8 位地址):
//   0x00 R: {30'b0, ovf, empty}   事件 FIFO 状态 (ovf = 曾丢弃, sticky)
//   0x01..0x04 R: 事件字 1..4 (FWFT 头)
//   0x05 W: 事件弹出脉冲 (写任意值即弹一项)
//   0x06 W: CMD = {cmd[3:0], id[3:0]}: cmd 1 = close (fin_req[id]), 2 = abort
//           (rst_req[id]); 其余忽略
//   0x07 R: {16'b0, app_tx_ready[15:0]}
//   0x08 R: {15'b0, rx_occ_bytes}   app RX 可读字节 (echo 缓冲占用)
//   0x09 R: {estab_cnt[15:0], ev_cnt[15:0]}   ESTAB 连接数 / 事件总数
//   0x0A R: conn7..0 的 state (每连接 4 位, conn0 在 [3:0])
//   0x0B R: conn15..8 的 state
//   0x10+4c R: 每连接块 4 字: +0 = {28'b0,state} +1 = snd_una +2 = snd_nxt
//              +3 = {rcv_wnd, snd_wnd}
//   0x50+c R: 每连接 rcv_nxt[31:0]
//   0x90 R: CONN_UP 计数      0x91 R: CONN_DOWN 计数
//   0x92 R: 事件丢弃计数      0x93 R: CMD close 计数
//   0x94 R: CMD abort 计数    0x95 R: 扫描心跳 (每 16 次采集 +1)
//   0x9F R: 设计标识 0x5035_4131 ("P5A1")
//
// 时序: 轮扫用自由运行 16 分频 (tick_cnt), 与 tcp_tx_frame 的 RTO 扫描同惯用法
// (scan 与数据路径无组合关系)。消费者是慢速寄存器逻辑 — 采集注册值, 无组合环。
//=============================================================================
module app_ctrl #(
    parameter [15:0] WIN_CAP  = 16'hBFFE,   // 与 tcp_tx_frame.RING_CAP 同值
    parameter [15:0] WIN_POOL = 16'hC000    // P5d 信用池初值 (P5a 未用)
) (
    input  wire        clk,
    input  wire        rst_n,
    // ---- 连接事件源 (slow_cfg_adp; 脉冲 + 保持字段) ----
    input  wire        ev_up,
    input  wire        ev_down,
    input  wire [3:0]  ev_slot,
    input  wire [31:0] ev_peer_ip,
    input  wire [15:0] ev_peer_port,
    input  wire [47:0] ev_peer_mac,
    // ---- TCB 组合读口 C (轮扫采样) ----
    output wire [3:0]  rc_id,
    input  wire [31:0] rc_snd_nxt,
    input  wire [31:0] rc_snd_una,
    input  wire [31:0] rc_rcv_nxt,
    input  wire [15:0] rc_rcv_wnd,
    input  wire [15:0] rc_snd_wnd,
    input  wire [3:0]  rc_state,
    // ---- 状态输入 ----
    input  wire [16:0] rx_occ_bytes,   // app RX 可读字节 (echo frame_fifo 占用)
    input  wire [15:0] fin_sent,       // tcp_tx_frame.o_fin_sent
    // ---- 事件脉冲转发 (app_pattern 用; 与事件 FIFO 推送同拍) ----
    output reg         o_ev_up,
    output reg         o_ev_down,
    output reg  [3:0]  o_ev_slot,
    // ---- FIN/RST 请求 (tcp_tx_frame.fin_req/rst_req) ----
    output reg  [15:0] fin_req,
    output reg  [15:0] rst_req,
    // ---- app_pattern 关闭请求 (等价 CMD close; 与寄存器写同源) ----
    input  wire        close_req,
    input  wire [3:0]  close_id,
    // ---- 寄存器总线 (读组合, 写 1 拍) ----
    input  wire [7:0]  reg_addr,
    input  wire        reg_wr,
    input  wire [31:0] reg_wdata,
    output reg  [31:0] reg_rdata,
    // ---- 状态输出 ----
    output wire [15:0] app_tx_ready,
    // conn0 采集快照 (纯线束; 板上状态行/调试用 — 免跨模块层次引用)
    output wire [3:0]  dbg_c0_state,
    output wire [31:0] dbg_c0_snd_nxt,
    output wire [31:0] dbg_c0_snd_una,
    output wire [31:0] dbg_c0_rcv_nxt,
    output wire [15:0] dbg_c0_rcv_wnd,
    output wire [15:0] dbg_c0_snd_wnd,
    output wire [15:0] dbg_estab_cnt,
    output wire [15:0] dbg_ev_cnt,
    output reg  [31:0] stat_ev_up,
    output reg  [31:0] stat_ev_down,
    output reg  [31:0] stat_ev_drop,
    output reg  [31:0] stat_cmd_close,
    output reg  [31:0] stat_cmd_abort
);
    // ESTABLISHED = state 1 (slow_cfg_adp ADD 写 state=1; DEL 写 0)
    localparam [3:0] ST_ESTAB = 4'd1;

    // ---- 事件 FIFO (FWFT, 102 位 x 16) ----
    localparam EW = 102;
    wire          ev_full, ev_empty;
    wire [EW-1:0] ev_dout;
    reg           ev_ovf;            // sticky: 满时丢弃过
    reg           ev_pop;            // 弹出脉冲 (寄存器 0x05 写)
    wire          ev_push = (ev_up || ev_down) && !ev_full;
    wire [EW-1:0] ev_din  = {ev_up ? 2'd0 : 2'd1, ev_slot, ev_peer_mac,
                             ev_peer_port, ev_peer_ip};
    wire [1:0]  hd_kind = ev_dout[101:100];
    wire [3:0]  hd_slot = ev_dout[99:96];
    wire [47:0] hd_mac  = ev_dout[95:48];
    wire [15:0] hd_port = ev_dout[47:32];
    wire [31:0] hd_ip   = ev_dout[31:0];

    fifo_sync #(.W(EW), .D(16), .AW(4)) u_evfifo (
        .clk(clk), .rst_n(rst_n),
        .wr(ev_push), .din(ev_din),
        .rd(ev_pop), .dout(ev_dout),
        .empty(ev_empty), .full(ev_full),
        .dbg_wptr(), .dbg_rptr(), .dbg_full(), .dbg_empty()
    );

    // ---- 16 分频轮扫 (自由运行 tick) ----
    reg  [3:0]  tick_cnt;
    reg  [3:0]  scan_id;
    wire        scan_tick = (tick_cnt == 4'd15);
    assign      rc_id = scan_id;
    reg  [3:0]  c_state   [0:15];
    reg  [31:0] c_snd_nxt [0:15];
    reg  [31:0] c_snd_una [0:15];
    reg  [31:0] c_rcv_nxt [0:15];
    reg  [15:0] c_rcv_wnd [0:15];
    reg  [15:0] c_snd_wnd [0:15];
    reg  [31:0] scan_round;          // 扫描心跳 (每 16 次采集 +1)

    // ---- app_tx_ready: ESTAB && 在飞 < min(snd_wnd, WIN_CAP) && !fin_req
    //      && !fin_sent (P5a 用轮扫注册值; 精门 = tcp_tx_frame 的 win_open) ----
    function [15:0] tx_ready_calc;
        input [3:0]  st;
        input [31:0] nxt;
        input [31:0] una;
        input [15:0] wnd;
        input        fr;
        input        fs;
        reg   [15:0] eff;
        begin
            eff = (wnd < WIN_CAP) ? wnd : WIN_CAP;
            tx_ready_calc = (st == ST_ESTAB) &&
                            ((nxt - una) < {16'b0, eff}) && !fr && !fs;
        end
    endfunction

    genvar gi;
    generate
        for (gi = 0; gi < 16; gi = gi + 1) begin : g_rdy
            assign app_tx_ready[gi] = tx_ready_calc(c_state[gi], c_snd_nxt[gi],
                                                    c_snd_una[gi], c_snd_wnd[gi],
                                                    fin_req[gi], fin_sent[gi]);
        end
    endgenerate

    // ---- ESTAB 计数 (读寄存器 0x09) ----
    reg [15:0] estab_cnt;
    integer    ci;
    always @(*) begin
        estab_cnt = 16'd0;
        for (ci = 0; ci < 16; ci = ci + 1)
            if (c_state[ci] == ST_ESTAB) estab_cnt = estab_cnt + 16'd1;
    end

    // conn0 采集快照 (纯线束; 板上状态行/调试用 — 免跨模块层次引用)
    assign dbg_c0_state   = c_state[0];
    assign dbg_c0_snd_nxt = c_snd_nxt[0];
    assign dbg_c0_snd_una = c_snd_una[0];
    assign dbg_c0_rcv_nxt = c_rcv_nxt[0];
    assign dbg_c0_rcv_wnd = c_rcv_wnd[0];
    assign dbg_c0_snd_wnd = c_snd_wnd[0];
    assign dbg_estab_cnt  = estab_cnt;
    assign dbg_ev_cnt     = stat_ev_up[15:0] + stat_ev_down[15:0];

    // ---- 寄存器读 (组合, 无等待) ----
    // 每连接块索引: 0x10 + 4c (0x10..0x4F) -> c = addr[5:2] + 12 (mod 16)
    wire [3:0] pc_c   = reg_addr[5:2] + 4'd12;
    wire [1:0] pc_sel = reg_addr[1:0];
    always @(*) begin
        reg_rdata = 32'd0;
        if (reg_addr <= 8'h0B) begin
            case (reg_addr[3:0])
                4'h0: reg_rdata = {30'b0, ev_ovf, ev_empty};
                4'h1: reg_rdata = {26'b0, hd_kind, hd_slot};
                4'h2: reg_rdata = hd_ip;
                4'h3: reg_rdata = {hd_port, hd_mac[47:32]};
                4'h4: reg_rdata = hd_mac[31:0];
                4'h7: reg_rdata = {16'b0, app_tx_ready};
                4'h8: reg_rdata = {15'b0, rx_occ_bytes};
                4'h9: reg_rdata = {estab_cnt,
                                   (stat_ev_up[15:0] + stat_ev_down[15:0])};
                4'hA: reg_rdata = {c_state[7],  c_state[6],  c_state[5],  c_state[4],
                                   c_state[3],  c_state[2],  c_state[1],  c_state[0]};
                4'hB: reg_rdata = {c_state[15], c_state[14], c_state[13], c_state[12],
                                   c_state[11], c_state[10], c_state[9], c_state[8]};
                default: reg_rdata = 32'd0;
            endcase
        end else if (reg_addr >= 8'h10 && reg_addr <= 8'h4F) begin
            case (pc_sel)
                2'd0: reg_rdata = {28'b0, c_state[pc_c]};
                2'd1: reg_rdata = c_snd_una[pc_c];
                2'd2: reg_rdata = c_snd_nxt[pc_c];
                default: reg_rdata = {c_rcv_wnd[pc_c], c_snd_wnd[pc_c]};
            endcase
        end else if (reg_addr >= 8'h50 && reg_addr <= 8'h5F) begin
            reg_rdata = c_rcv_nxt[reg_addr[3:0]];
        end else begin
            case (reg_addr)
                8'h90: reg_rdata = stat_ev_up;
                8'h91: reg_rdata = stat_ev_down;
                8'h92: reg_rdata = stat_ev_drop;
                8'h93: reg_rdata = stat_cmd_close;
                8'h94: reg_rdata = stat_cmd_abort;
                8'h95: reg_rdata = scan_round;
                8'h9F: reg_rdata = 32'h5035_4131;      // "P5A1"
                default: reg_rdata = 32'd0;
            endcase
        end
    end

    // ---- 事件脉冲转发 + 事件/命令写口 ----
    integer wi;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tick_cnt <= 4'd0; scan_id <= 4'd0; scan_round <= 32'd0;
            ev_ovf <= 1'b0; ev_pop <= 1'b0;
            o_ev_up <= 1'b0; o_ev_down <= 1'b0; o_ev_slot <= 4'd0;
            fin_req <= 16'h0; rst_req <= 16'h0;
            stat_ev_up <= 32'd0; stat_ev_down <= 32'd0; stat_ev_drop <= 32'd0;
            stat_cmd_close <= 32'd0; stat_cmd_abort <= 32'd0;
            for (wi = 0; wi < 16; wi = wi + 1) begin
                c_state[wi] <= 4'd0; c_snd_nxt[wi] <= 32'd0; c_snd_una[wi] <= 32'd0;
                c_rcv_nxt[wi] <= 32'd0; c_rcv_wnd[wi] <= 16'd0; c_snd_wnd[wi] <= 16'd0;
            end
        end else begin
            // 每拍默认清零 (脉冲型寄存器铁律)
            ev_pop    <= 1'b0;
            o_ev_up   <= 1'b0;
            o_ev_down <= 1'b0;
            tick_cnt  <= tick_cnt + 4'd1;

            // ---- 事件 (源脉冲) ----
            if (ev_up || ev_down) begin
                if (ev_full) stat_ev_drop <= stat_ev_drop + 32'd1;
                if (ev_up) begin
                    stat_ev_up <= stat_ev_up + 32'd1;
                    o_ev_up    <= 1'b1;
                    o_ev_slot  <= ev_slot;
                    fin_req[ev_slot] <= 1'b0;   // 新连接槽位清关闭/中止请求
                    rst_req[ev_slot] <= 1'b0;
                end else begin
                    stat_ev_down <= stat_ev_down + 32'd1;
                    o_ev_down    <= 1'b1;
                    o_ev_slot    <= ev_slot;
                    // CONN_DOWN: 清该连接的关闭/中止请求 (同时关闭不重复发 FIN)
                    fin_req[ev_slot] <= 1'b0;
                    rst_req[ev_slot] <= 1'b0;
                end
            end

            // ---- 轮扫: 采样该连接 TCB 状态 ----
            if (scan_tick) begin
                scan_id <= scan_id + 4'd1;
                if (scan_id == 4'd15) scan_round <= scan_round + 32'd1;
                c_state  [scan_id] <= rc_state;
                c_snd_nxt[scan_id] <= rc_snd_nxt;
                c_snd_una[scan_id] <= rc_snd_una;
                c_rcv_nxt[scan_id] <= rc_rcv_nxt;
                c_rcv_wnd[scan_id] <= rc_rcv_wnd;
                c_snd_wnd[scan_id] <= rc_snd_wnd;
                // 连接已不在 ESTAB: 清关闭/中止请求 (拆连后自愈; 同槽重连可再用)
                if (rc_state != ST_ESTAB) begin
                    fin_req[scan_id] <= 1'b0;
                    rst_req[scan_id] <= 1'b0;
                end
            end

            // ---- CMD 写 (0x06): {cmd[3:0], id[3:0]} ----
            if (reg_wr && reg_addr == 8'h06) begin
                case (reg_wdata[7:4])
                    4'd1: begin fin_req[reg_wdata[3:0]] <= 1'b1;
                               stat_cmd_close <= stat_cmd_close + 32'd1; end
                    4'd2: begin rst_req[reg_wdata[3:0]] <= 1'b1;
                               stat_cmd_abort <= stat_cmd_abort + 32'd1; end
                    default: ;
                endcase
            end

            // ---- app_pattern 关闭请求 (等价 CMD close) ----
            if (close_req) begin
                fin_req[close_id] <= 1'b1;
                stat_cmd_close <= stat_cmd_close + 32'd1;
            end

            // ---- 事件弹出 (0x05 写) ----
            if (reg_wr && reg_addr == 8'h05) ev_pop <= 1'b1;
            if ((ev_up || ev_down) && ev_full) ev_ovf <= 1'b1;
        end
    end

    // WIN_POOL: P5d 信用池初值 (本阶段未消费, 参数保留以免将来分叉)
endmodule
