`timescale 1ns/1ps
// 以太网 CRC-32 (反射多项式 0xEDB88320, 初值 0xFFFFFFFF, 无终值取反)。
// 帧全字节 (目的MAC..FCS 含 FCS) 流过后的寄存器残留 == 32'hDEBB20E3 表示 FCS 正确
// (FCS 为 zlib.crc32 值小端/线上 LSB-first 字节序; 0xC704DD7B 是 FCS 大端魔数, 勿用)。
// en 与 d 必须同拍有效 (en=1 的周期内 d 就是参与计算的字节)。
module crc32_8b (
    input  wire       clk,
    input  wire       init,     // 1 拍脉冲: 寄存器复位为全 1
    input  wire       en,       // 本拍字节参与计算
    input  wire [7:0] d,
    output reg  [31:0] crc
);
    function [31:0] step8;
        input [31:0] crc_in;
        input [7:0]  byte_in;
        reg [31:0] c;
        reg [7:0]  dd;
        integer i;
        begin
            c = crc_in;
            dd = byte_in;
            for (i = 0; i < 8; i = i + 1) begin
                if (c[0] ^ dd[0])
                    c = (c >> 1) ^ 32'hEDB88320;
                else
                    c = c >> 1;
                dd = dd >> 1;
            end
            step8 = c;
        end
    endfunction

    always @(posedge clk) begin
        if (init)      crc <= 32'hFFFFFFFF;
        else if (en)   crc <= step8(crc, d);
    end
endmodule
