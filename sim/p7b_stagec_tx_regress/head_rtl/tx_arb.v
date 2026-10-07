`timescale 1ns/1ps
// TX 帧级 2:1 仲裁: fast (tcp_tx_frame) 严格优先于 slow (slow_tx_adp)。
// 空闲时按请求选择并寄存, 锁定到 TLAST 消费拍; 帧间 1 拍重仲裁气泡。
// 纯组合数据通路 (无时钟延迟), II=1。
module tx_arb (
    input  wire        clk,
    input  wire        rst_n,
    // fast (TCP)
    input  wire [63:0] s_fast_tdata,
    input  wire [7:0]  s_fast_tkeep,
    input  wire        s_fast_tvalid,
    output wire        s_fast_tready,
    input  wire        s_fast_tlast,
    // slow (HLS 慢路径)
    input  wire [63:0] s_slow_tdata,
    input  wire [7:0]  s_slow_tkeep,
    input  wire        s_slow_tvalid,
    output wire        s_slow_tready,
    input  wire        s_slow_tlast,
    // 去 mac_tx_64
    output wire [63:0] m_axis_tdata,
    output wire [7:0]  m_axis_tkeep,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast
);
    reg busy, sel_fast;

    assign m_axis_tdata  = sel_fast ? s_fast_tdata : s_slow_tdata;
    assign m_axis_tkeep  = sel_fast ? s_fast_tkeep : s_slow_tkeep;
    assign m_axis_tlast  = sel_fast ? s_fast_tlast : s_slow_tlast;
    assign m_axis_tvalid = busy && (sel_fast ? s_fast_tvalid : s_slow_tvalid);
    assign s_fast_tready = busy &&  sel_fast && m_axis_tready;
    assign s_slow_tready = busy && !sel_fast && m_axis_tready;

    wire fin = m_axis_tvalid && m_axis_tready && m_axis_tlast;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 1'b0; sel_fast <= 1'b0;
        end else begin
            if (!busy) begin
                if (s_fast_tvalid) begin
                    busy <= 1'b1; sel_fast <= 1'b1;
                end else if (s_slow_tvalid) begin
                    busy <= 1'b1; sel_fast <= 1'b0;
                end
            end else if (fin) begin
                busy <= 1'b0;
            end
        end
    end
endmodule
