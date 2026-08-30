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
endmodule
