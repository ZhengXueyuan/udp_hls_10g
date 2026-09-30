`timescale 1ns/1ps
// 16-bit 反码校验和运行累加器 (IP/UDP 通用): 32-bit 补码累加 + 帧尾折叠 + 取反。
// 契约 (fin 必须晚于最后一个 den/aen 至少一拍):
//   init  -> acc = init_val (伪头固定部分 src_ip+dst_ip+0x0011 的 32-bit 和);
//            与 den 同拍共存时先装初值再累加本拍半字 (首拍即数据拍)
//   den   -> acc += 本拍 4 半字 (左对齐, dkeep 高位有效; 奇字节尾半字低字节补 0)
//   aen   -> acc += add_val (伪头长度字段 udp_len, TLAST 后一拍)
//   fin   -> 折叠锁存; csum/csum_valid 在 fin 后一拍给出 ~fold16(acc)
// 1518B 载荷 max 累加 < 2^26, 32-bit acc 无溢出; 末尾折叠与增量折叠等价。
module checksum16 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        init,
    input  wire [31:0] init_val,
    input  wire        den,
    input  wire [63:0] din,
    input  wire [7:0]  dkeep,
    input  wire        aen,
    input  wire [17:0] add_val,
    input  wire        fin,
    output reg  [15:0] csum,
    output reg         csum_valid
);

    wire [15:0] h0 = dkeep[7] ? {din[63:56], dkeep[6] ? din[55:48] : 8'h00} : 16'h0000;
    wire [15:0] h1 = dkeep[5] ? {din[47:40], dkeep[4] ? din[39:32] : 8'h00} : 16'h0000;
    wire [15:0] h2 = dkeep[3] ? {din[31:24], dkeep[2] ? din[23:16] : 8'h00} : 16'h0000;
    wire [15:0] h3 = dkeep[1] ? {din[15:8],  dkeep[0] ? din[7:0]   : 8'h00} : 16'h0000;
    wire [17:0] wsum = {2'b00, h0} + {2'b00, h1} + {2'b00, h2} + {2'b00, h3};

    function [15:0] fold16;
        input [31:0] v;
        reg [16:0] f1;
        begin
            f1 = v[15:0] + v[31:16];
            fold16 = f1[15:0] + {15'b0, f1[16]};
        end
    endfunction

    reg [31:0] acc;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc <= 32'h0;
            csum <= 16'h0;
            csum_valid <= 1'b0;
        end else begin
            if (init)           acc <= init_val + (den ? wsum : 18'h0);
            else if (aen)       acc <= acc + add_val;
            else if (den)       acc <= acc + wsum;
            csum_valid <= fin;
            if (fin)            csum <= ~fold16(acc);
        end
    end
endmodule
