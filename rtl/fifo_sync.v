`timescale 1ns/1ps
// 同步 FWFT FIFO (首字直通): dout 与 !empty 同拍有效, 空时写入旁路到读口。
// rd 消费 rptr 当前项; 同时读写且仅 1 项时旁路新数据, 避免读口空洞。
module fifo_sync #(
    parameter W  = 76,
    parameter D  = 8,
    parameter AW = 3
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        wr,
    input  wire [W-1:0] din,
    input  wire        rd,
    output reg  [W-1:0] dout,
    output wire        empty,
    output wire        full
);
    reg [AW:0]  wptr, rptr;
    reg [W-1:0] mem [0:D-1];

    assign full  = (wptr[AW-1:0] == rptr[AW-1:0]) && (wptr[AW] != rptr[AW]);
    assign empty = (wptr == rptr);

    wire [AW:0] rptr_n = rptr + ((rd && !empty) ? 1'b1 : 1'b0);
    wire        bypass = (wr && !full) && (rptr_n[AW-1:0] == wptr[AW-1:0]);

    // mem 独立无复位块: 与指针/输出寄存器分开, 深 FIFO 才能推断 BRAM
    // (带异步复位的 always 里写 mem 会被综合成寄存器数组 -> LUTRAM -> 时序炸)
    always @(posedge clk) begin
        if (wr && !full) mem[wptr[AW-1:0]] <= din;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wptr <= 0; rptr <= 0; dout <= 0;
        end else begin
            if (wr && !full) wptr <= wptr + 1;
            if (rd && !empty) rptr <= rptr + 1;
            dout <= bypass ? din : mem[rptr_n[AW-1:0]];
        end
    end
endmodule
