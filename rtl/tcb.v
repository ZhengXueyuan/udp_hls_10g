`timescale 1ns/1ps
// TCP 控制块寄存器组: 16 条 × (rcv_nxt, snd_nxt, snd_una, rcv_wnd, snd_wnd, state,
// wscale)。双读口 (ra/rb 组合输出, RX 与 TX 数据面并发查) + 单更新口 (每拍最多
// 1 字段写)。
// upd_sel: 0=rcv_nxt 1=snd_nxt 2=snd_una 3=rcv_wnd 4=snd_wnd 5=state 6=wscale
// wscale = 对端 window scale (握手时 HLS 从 SYN 选项解析, cfg 记录下发); tcp_rx
// drain snd_wnd 时按它缩放。复位 0 = 不缩放, 旧配置链路 (不写 sel=6) 语义不变。
module tcb #(
    parameter N = 16
) (
    input  wire        clk,
    input  wire        rst_n,
    // 读口 A (RX 侧)
    input  wire [3:0]  ra_id,
    output wire [31:0] ra_rcv_nxt,
    output wire [31:0] ra_snd_nxt,
    output wire [31:0] ra_snd_una,
    output wire [15:0] ra_rcv_wnd,
    output wire [15:0] ra_snd_wnd,
    output wire [3:0]  ra_state,
    output wire [3:0]  ra_wscale,
    // 读口 B (TX 侧)
    input  wire [3:0]  rb_id,
    output wire [31:0] rb_rcv_nxt,
    output wire [31:0] rb_snd_nxt,
    output wire [31:0] rb_snd_una,
    output wire [15:0] rb_rcv_wnd,
    output wire [15:0] rb_snd_wnd,
    output wire [3:0]  rb_state,
    // 窗口读口 (P4b-7-P6 时序: 注册输出, tcp_tx_frame 门控专用 — 门控决策
    // 只消费寄存器, 切断 rb_id -> TCB mux -> 减法/比较 -> tready -> retx_ram
    // 写口的最差前向链; ra/rb 组合读口及语义全部不动)
    // P4b-7-P6-fix (64K 边界误关根因): 16 位 hi_eq+低 16 位差门在在飞区间跨越
    // 任意 64K 边界时高半不等而误关 (板上 ISS 0x12345678 首跨 ~43KB 处实锤
    // 永久冻结) — 改为 32 位回绕正确减法 + 比较, 全部注册在本模块内, 输出
    // win_open 1 位即最终门; win_inflight/win_wnd_eff 保留 (低 16 位差/帽值,
    // wrapper 锁存 debug 用, 不再参与门控决策)。
    input  wire [3:0]  win_id,
    output reg         win_open,         // 32 位回绕正确门: (snd_nxt-snd_una) < 帽
    output reg  [15:0] win_inflight,     // 32 位差低 16 位 (debug 用)
    output reg  [15:0] win_wnd_eff,      // min(snd_wnd, 0x2FFE = RING_CAP)
    // ---- P6 冻结诊断: conn0 阵列快照 (纯 assign 组合读 entry[0], 无时序影响) ----
    output wire [31:0] dbg_snd_nxt0,
    output wire [31:0] dbg_snd_una0,
    output wire [31:0] dbg_rcv_nxt0,
    output wire [15:0] dbg_snd_wnd0,
    output wire [3:0]  dbg_wscale0,
    output wire [3:0]  dbg_state0,
    // 更新口
    input  wire        upd_wr,
    input  wire [3:0]  upd_id,
    input  wire [2:0]  upd_sel,
    input  wire [31:0] upd_val
);

    reg [31:0] rcv_nxt_r [0:N-1];
    reg [31:0] snd_nxt_r [0:N-1];
    reg [31:0] snd_una_r [0:N-1];
    reg [15:0] rcv_wnd_r [0:N-1];
    reg [15:0] snd_wnd_r [0:N-1];
    reg [3:0]  state_r  [0:N-1];
    reg [3:0]  wscale_r [0:N-1];

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < N; i = i + 1) begin
                rcv_nxt_r[i] <= 0; snd_nxt_r[i] <= 0; snd_una_r[i] <= 0;
                rcv_wnd_r[i] <= 0; snd_wnd_r[i] <= 0; state_r[i] <= 0;
                wscale_r[i] <= 0;
            end
        end else if (upd_wr) begin
            case (upd_sel)
                3'd0: rcv_nxt_r[upd_id] <= upd_val;
                3'd1: snd_nxt_r[upd_id] <= upd_val;
                3'd2: snd_una_r[upd_id] <= upd_val;
                3'd3: rcv_wnd_r[upd_id] <= upd_val[15:0];
                3'd4: snd_wnd_r[upd_id] <= upd_val[15:0];
                3'd5: state_r[upd_id]   <= upd_val[3:0];
                3'd6: wscale_r[upd_id]  <= upd_val[3:0];
                default: ;              // 3'd7 保留: 显式拒写 (防误落 wscale)
            endcase
        end
    end

    assign ra_rcv_nxt = rcv_nxt_r[ra_id];
    assign ra_snd_nxt = snd_nxt_r[ra_id];
    assign ra_snd_una = snd_una_r[ra_id];
    assign ra_rcv_wnd = rcv_wnd_r[ra_id];
    assign ra_snd_wnd = snd_wnd_r[ra_id];
    assign ra_state   = state_r[ra_id];
    assign ra_wscale  = wscale_r[ra_id];
    assign rb_rcv_nxt = rcv_nxt_r[rb_id];
    assign rb_snd_nxt = snd_nxt_r[rb_id];
    assign rb_snd_una = snd_una_r[rb_id];
    assign rb_rcv_wnd = rcv_wnd_r[rb_id];
    assign rb_snd_wnd = snd_wnd_r[rb_id];
    assign rb_state   = state_r[rb_id];

    // ---- P6 冻结诊断: conn0 快照 (恒等 array[0], 与 ra/rb mux 无关) ----
    assign dbg_snd_nxt0 = snd_nxt_r[0];
    assign dbg_snd_una0 = snd_una_r[0];
    assign dbg_rcv_nxt0 = rcv_nxt_r[0];
    assign dbg_snd_wnd0 = snd_wnd_r[0];
    assign dbg_wscale0  = wscale_r[0];
    assign dbg_state0   = state_r[0];

    // ---- 注册窗口读口 (无复位: 初值无意义, 门控只在 ESTAB 状态才起作用;
    //      1 拍旧值的影响见 tcp_tx_frame RING_CAP 注释: 最坏误开 1 拍) ----
    // P4b-7-P6-fix: 32 位回绕正确减法 win_diff (wrap-correct, snd_nxt 回绕过
    // 0xFFFFFFFF 也精确) + 16 位帽值 mux, 比较 < 帽后全注册输出 — tcb 到
    // tx 决策无任何组合链 (减/比较 皆在寄存器块内, 输入是 win_id 读出的
    // 阵列寄存器, 输出仍 1 拍后稳定)。
    wire [31:0] win_diff = snd_nxt_r[win_id] - snd_una_r[win_id];   // 32-bit wrap-correct
    wire [15:0] win_cap  = (snd_wnd_r[win_id] < 16'h2FFE) ? snd_wnd_r[win_id] : 16'h2FFE;
    always @(posedge clk) begin
        win_open     <= (win_diff < {16'b0, win_cap});
        win_inflight <= win_diff[15:0];
        win_wnd_eff  <= win_cap;
    end
endmodule
