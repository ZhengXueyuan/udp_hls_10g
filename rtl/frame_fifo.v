`timescale 1ns/1ps
// 带帧回卷的 FWFT 同步 FIFO (fifo_sync 同语义 + 写指针快照/回卷)。
// snap (帧首拍): 快照本拍写后的 wptr; rollback (帧判定拍): wptr 回卷, 该帧已写字全部作废。
// full 为保守判定 (忽略同拍 rd), 无组合环; 深度必须 >= 单帧最大字数 (1518B = 190 字)。
module frame_fifo #(
    parameter W  = 73,
    parameter D  = 2048,
    parameter AW = 11
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        wr,
    input  wire [W-1:0] din,
    input  wire        snap,
    input  wire        rollback,
    input  wire        rd,
    output wire [W-1:0] dout,
    output wire        empty,
    output wire        full
);

    reg [W-1:0] mem [0:D-1];
    reg [AW:0]  wptr, rptr, wsnap;
    reg [W-1:0] dout_r;

    // full = 真满 (绕回位不同 + 低位相同), 与 fifo_sync 同式。
    // 曾用 "+1 保守式": wptr 低位==511 时等效 rptr 低位==512 (不可能) → rptr 低
    // 位==0 的窗口内 full 永不触发, 写入绕回踩槽 (P4a slowrx 单元 TB 实锤)。
    wire        full_n  = (wptr[AW-1:0] == rptr[AW-1:0]) && (wptr[AW] != rptr[AW]);
    wire        empty_n = (wptr == rptr);
    wire        rd_ok   = rd && !empty_n;
    wire        wr_ok   = wr && !full_n;
    wire [AW:0] rptr_n  = rptr + (rd_ok ? 1'b1 : 1'b0);
    wire [AW:0] wptr_n  = wptr + (wr_ok ? 1'b1 : 1'b0);
    wire        bypass  = wr_ok && (rptr_n[AW-1:0] == wptr[AW-1:0]);

    // mem 独立无复位块: 与指针/输出寄存器分开, 才能推断 BRAM
    // (带异步复位的 always 里写 mem 会被综合成寄存器数组 -> 2048 深 LUTRAM -> 时序炸)
    always @(posedge clk) begin
        if (wr_ok) mem[wptr[AW-1:0]] <= din;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wptr <= 0; rptr <= 0; wsnap <= 0; dout_r <= 0;
        end else begin
            if (rollback) wptr <= wsnap;
            else wptr <= wptr_n;
            if (rd_ok) rptr <= rptr_n;
            dout_r <= bypass ? din : mem[rptr_n[AW-1:0]];
            // 快照必须 = 本拍写入的槽 (wptr), 用 wptr_n 会把首字排除在回卷范围外
            if (snap) wsnap <= wptr;
        end
    end

    assign dout  = dout_r;
    assign empty = empty_n;
    assign full  = full_n;
endmodule
