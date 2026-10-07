`timescale 1ns/1ps
// axis_pipe: 1-deep 全速 AXIS 流水寄存器 (对齐 1 拍, 背压合同不变)。
// P4b-7-P6: 拆板级临界路径 (源端 RAMB36E1 数据口 -> 下游校验和累加器): 插在
// tcp_echo -> tcp_tx_frame 之间, 源端组合/BRAM 输出先落本级 FF, 下游 mux+累加
// 组合网自 FF 起点 — 不再从 BRAM DOBDO 直接长链到 u_csum acc。
// 全速: m_ready=1 时 s_ready=1 恒成立, m_valid/m_data 每拍重装 = 每拍 1 字;
// m_ready=0 期间 m_data/m_valid 为寄存器输出稳定保持, s_ready=0 反压源端。
// 源端合同: s_ready=0 期间须保持 s_data/s_valid (presenting, 同 tcp_tx_frame
// S_IDLE 帧首契约); 源端按沿推进, 无双重递交 (AXIS 标准 1-deep 前移寄存器)。
module axis_pipe #(parameter W = 77) (
    input clk, input rst_n,
    input [W-1:0] s_data, input s_valid, output s_ready,
    output [W-1:0] m_data, output reg m_valid, input m_ready
);
    reg [W-1:0] m_data_r;
    assign s_ready = m_ready || !m_valid;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) m_valid <= 0;
        else if (s_ready) begin m_valid <= s_valid; m_data_r <= s_data; end
    end
    assign m_data = m_data_r;
endmodule
