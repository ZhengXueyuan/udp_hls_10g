`timescale 1ns/1ps
// TCP 连接微型 CAM: 4 元组 (sip/dip/sport/dport) 精确匹配 → conn_id。
// 16 条并行组合比较 + 优先级编码 (低序号优先, 唯一性由慢路径配置保证)。
// 配置口 = 慢路径 (P4 HLS 层) 写; 查询口 = 数据面组合查询 (每拍一次)。
// dmac 字段 + 读回口: TX 组帧按 conn_id 取对端 MAC/IP/端口 (rd_* 组合输出)。
module tcp_cam #(
    parameter N = 16
) (
    input  wire        clk,
    input  wire        rst_n,
    // 配置 (慢路径写, 一条一拍)
    input  wire        cfg_wr,
    input  wire [3:0]  cfg_addr,
    input  wire [31:0] cfg_sip,
    input  wire [31:0] cfg_dip,
    input  wire [15:0] cfg_sport,
    input  wire [15:0] cfg_dport,
    input  wire [47:0] cfg_dmac,
    // 查询 (组合, 每拍有效)
    input  wire [31:0] q_sip,
    input  wire [31:0] q_dip,
    input  wire [15:0] q_sport,
    input  wire [15:0] q_dport,
    output reg  [3:0]  q_id,
    output reg         q_hit,
    // 读回 (组合, TX 用): sip = 对端 IP (发送帧的 dst IP!), dip = 本地 IP,
    // sport = 对端端口 (发送时作 dst_port), dport = 本地端口
    input  wire [3:0]  rd_id,
    output wire [47:0] rd_dmac,
    output wire [31:0] rd_sip,
    output wire [31:0] rd_dip,
    output wire [15:0] rd_sport,
    output wire [15:0] rd_dport
);

    reg [31:0] sip_r [0:N-1];
    reg [31:0] dip_r [0:N-1];
    reg [15:0] sport_r [0:N-1];
    reg [15:0] dport_r [0:N-1];
    reg [47:0] dmac_r [0:N-1];

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < N; i = i + 1) begin
                sip_r[i] <= 0; dip_r[i] <= 0; sport_r[i] <= 0; dport_r[i] <= 0;
                dmac_r[i] <= 0;
            end
        end else if (cfg_wr) begin
            sip_r[cfg_addr]   <= cfg_sip;
            dip_r[cfg_addr]   <= cfg_dip;
            sport_r[cfg_addr] <= cfg_sport;
            dport_r[cfg_addr] <= cfg_dport;
            dmac_r[cfg_addr]  <= cfg_dmac;
        end
    end

    // 组合匹配 + 优先级编码
    always @* begin
        q_hit = 1'b0;
        q_id  = 4'd0;
        for (i = 0; i < N; i = i + 1) begin
            if (!q_hit && sip_r[i] == q_sip && dip_r[i] == q_dip &&
                sport_r[i] == q_sport && dport_r[i] == q_dport) begin
                q_hit = 1'b1;
                q_id  = i[3:0];
            end
        end
    end

    assign rd_dmac  = dmac_r[rd_id];
    assign rd_sip   = sip_r[rd_id];
    assign rd_dip   = dip_r[rd_id];
    assign rd_sport = sport_r[rd_id];
    assign rd_dport = dport_r[rd_id];
endmodule
