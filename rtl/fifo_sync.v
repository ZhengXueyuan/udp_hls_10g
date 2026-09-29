`timescale 1ns/1ps
// 同步 FWFT FIFO (首字直通): dout 与 !empty 同拍有效, 空时写入旁路到读口。
// rd 消费 rptr 当前项; 同时读写且仅 1 项时旁路新数据, 避免读口空洞。
//
// ---------------------------------------------------------------------------
// 写口合同 (P6b F4 修复后写明; 生产者必须按其设计空间门, 否则字会被**静默丢弃**)
// ---------------------------------------------------------------------------
//  * **深度 D; 满 = 占用 == D**。`wr && !full` 才落笔: 满时 `wr` 被**静默忽略**
//    (无背压、无计数) —— 这是本 FIFO 的既有语义, 生产者必须自己保证不越界。
//  * ⚠️ **`full` 是本拍的组合值, 不是"下拍还能不能写"**。若生产者的 `wr` 是**寄存器**
//    (本轮决定、下拍落笔), 用本拍的 `full` 做空间门会有**一拍错位**: 本拍正在执行的那次
//    写 (另一笔 `wr`) 会把 `wptr` 顶一格, 于是"本拍 full=0 (D-1 占) + 下拍有在飞写"
//    ⇒ 下拍 `full=1` ⇒ 该笔写被丢弃。**空间门必须用 `full_next`**:
//      `full_next` = **下一拍 `full` 的精确值** (含本拍 `wr` 与 `rd` 的影响, 组合推导,
//      无额外拍)。生产者判据: "本轮决定的推入下拍一定落笔" ⇔ `!full_next`。
//  * `ovf_pulse = wr && full`: 本拍有一次写**被拒** (字静默丢失)。它只应出现在生产者
//    违反上一条时 —— 生产侧应把它接成计数器 (自检回读), 恒 0 才叫"无静默丢失"。
//  * 读口: `rd && !empty` 消费; `empty` 时 `dout` = mem[rptr] 陈旧值 (valid=0 期间无意义)。
// ---------------------------------------------------------------------------
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
    output wire        full,
    // ---- P4b-7-P6 调试探针 (纯 assign 线束输出, 与上述逻辑零耦合) ----
    output wire [AW:0]  dbg_wptr,      // 写指针 (含绕回位)
    output wire [AW:0]  dbg_rptr,      // 读指针 (含绕回位)
    output wire         dbg_full,      // = full
    output wire         dbg_empty,     // = empty
    // ---- P6b F4: 写口空间/溢出 (纯组合, 未接者不受影响) ----
    output wire         full_next,     // 下一拍的 full (精确; 生产侧空间门用)
    output wire         ovf_pulse      // = wr && full: 本拍有一次写被拒 (静默丢失)
);
    reg [AW:0]  wptr, rptr;
    reg [W-1:0] mem [0:D-1];

    assign full  = (wptr[AW-1:0] == rptr[AW-1:0]) && (wptr[AW] != rptr[AW]);
    assign empty = (wptr == rptr);

    assign dbg_wptr  = wptr;
    assign dbg_rptr  = rptr;
    assign dbg_full  = full;
    assign dbg_empty = empty;

    wire [AW:0] rptr_n = rptr + ((rd && !empty) ? 1'b1 : 1'b0);
    wire        bypass = (wr && !full) && (rptr_n[AW-1:0] == wptr[AW-1:0]);
    // 下一拍指针 = 本拍的指针 + 本拍真正落笔/消费的那次; full_next 就是它们的满判据。
    wire [AW:0] wptr_n = wptr + ((wr && !full) ? 1'b1 : 1'b0);
    assign full_next = (wptr_n[AW-1:0] == rptr_n[AW-1:0]) && (wptr_n[AW] != rptr_n[AW]);
    // 拒写 (本拍 wr 但满): 该字不会被写入 —— 生产者必须计数, 不得静默
    assign ovf_pulse = wr && full;

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
