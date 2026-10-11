`timescale 1ns/1ps
//=============================================================================
// aximm_h2c_discard.v — M1 期 B: 挂在 XDMA `m_axi` **写通道**上的"永远应答并丢弃"从机
//=============================================================================
// 为什么存在 (TL 2026-10-11 的 P2 裁定, 逐字口径): 期 B 只接读通道时, 安全性依赖一个
//   **明文网表核不出**的前提 —— "XDMA 内部仲裁不依赖写通道握手"。P2 用一个最小的
//   写通道从机把这个前提**结构性消除**: 写通道的每一条握手都有人应答 ⇒ 无论引擎内部
//   怎么写/怎么仲裁, 都不存在"等一个永不来的应答"这种状态。
//
// ⛔ 范围: **H2C 邮箱功能不在范围内** (本模块没有语义 —— 不解析地址、不存储数据、
//   不产生任何对外副作用)。它只保证 AXI4 写事务**完成** (BRESP = OKAY)。
//
// ---- 从机合同 (冻结; 每条都有单元门判据) ----
//   · **永远应答**: 任何合法的 AW/W 握手序列 ⇒ 迟早回一个 OKAY 的 B;
//     唯一的停顿源是主机的 `bready` 低 (B 必须保持到被接收)。⛔ 不悬空任何握手。
//   · **数据丢弃**: `wdata/wstrb/awaddr/awlen/...` 只被读进"未使用"的语义 ——
//     不驱动任何寄存器, 不进任何存储 (综合时整条数据通路被优化掉是**预期的**)。
//   · **WLAST 对齐**: B 在"WLAST 那拍握手成立"后才发 ⇒ 一拍 B 对应一整笔突发,
//     不会给半笔发应答 (AXI4: 主机会在收到 B 前发完 W 的最后一拍)。
//   · **ID 回填**: `bid` = 本笔 `awid` (照实现, **不依赖** "IP 把 awid 核内硬接 0"
//     这个明文事实 —— `xdma_0_sim_netlist.v:9869-9872`, 引用先例见 aximm_c2h_win.v)。
//   · **一次一笔 (one-outstanding)**: AW 被收到后 awready 拉低; `wlast` 收到后
//     wready 拉低; B 被接收后两者同时重新开。⇒ 不需要 ID 队列, 且"B 的 id"与
//     "W 的数据"永远属于同一笔。AXI4 允许从机对任一笔做这种背压。
//   · **到达顺序无关**: AW 与 W 两条通道**各自独立**就绪 ⇒ "W 先到 / AW 先到"两种
//     顺序都能完成 (不假设引擎的发法; 明文网表核不出引擎的发法 —— 见 aximm_c2h_win.v
//     头注释"引擎本体在加密块内")。
//   · **brst 类型/长度/地址一律忽略**: 丢弃语义与它们无关 ⇒ 没有任何"拒绝"路径,
//     也就没有任何"卡住"路径 (与读从机的 SLVERR 不同: 那边要保数据正确, 这边不保)。
//
// ---- 观测 (只给仿真) ----
//   `nbeat` = 被接收并丢弃的 W 拍数 (32 位)。⛔ 综合会把它整个优化掉 (无消费者) ——
//   它的唯一用途 = 单元门/全链门里当"数据真的来过并被丢"的见证 (层次引用读它)。
//
// ---- 时钟/复位 ----
//   clk/rst_n = `pcie_axi_aclk` / `pcie_axi_aresetn` (与 XDMA 的 m_axi 同域同源)。
//   ⛔ 复位时不发 B (bvalid 清 0) —— 复位期间主机若有在飞写事务, 其 B 会丢失;
//      本设计里 m_axi 只在 M1 构建里接上, 且主机(PC)只在板子跑起来后才发 DMA ⇒ 登记边界。
//=============================================================================
module aximm_h2c_discard (
    input  wire         clk,
    input  wire         rst_n,
    // ---- AW 通道 (来自 XDMA) ----
    input  wire [3:0]   awid,
    input  wire [63:0]  awaddr,     // 忽略 (丢弃语义)
    input  wire [7:0]   awlen,      // 忽略 (B 只锚在 WLAST 上)
    input  wire [2:0]   awsize,     // 忽略
    input  wire [1:0]   awburst,    // 忽略
    input  wire         awvalid,
    output wire         awready,
    // ---- W 通道 (来自 XDMA) ----
    input  wire [127:0] wdata,      // 忽略 (丢弃)
    input  wire [15:0]  wstrb,      // 忽略
    input  wire         wlast,
    input  wire         wvalid,
    output wire         wready,
    // ---- B 通道 (回 XDMA) ----
    output reg  [3:0]   bid,        // = 本笔 awid 的回填
    output wire [1:0]   bresp,      // 恒 OKAY (2'b00)
    output reg          bvalid,
    input  wire         bready
);

    reg        aw_got;      // 本笔 AW 已收到 (到 B 被接收才清)
    reg        w_done;      // 本笔 WLAST 已收到 (到 B 被接收才清)
    reg [3:0]  bid_r;       // 本笔 AW 的 id
    reg [31:0] nbeat;       // ⛔ 仿真见证 (丢弃拍数; 综合会优化掉, 见头注释)

    // 两条通道**各自独立**就绪 (不假设 AW/W 到达顺序)
    assign awready = !aw_got;
    assign wready  = !w_done;
    assign bresp   = 2'b00;                 // 恒 OKAY

    wire aw_go = awready && awvalid;
    wire w_go  = wready  && wvalid;
    wire w_last_go = w_go && wlast;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_got <= 1'b0;
            w_done <= 1'b0;
            bid_r  <= 4'd0;
            bid    <= 4'd0;
            bvalid <= 1'b0;
            nbeat  <= 32'd0;
        end else if (bvalid && bready) begin
            // 一笔收尾: 两条通道重新打开 (下一笔可以立刻开始)
            bvalid <= 1'b0;
            aw_got <= 1'b0;
            w_done <= 1'b0;
        end else begin
            if (aw_go) begin bid_r <= awid; aw_got <= 1'b1; end
            if (w_go)  nbeat <= nbeat + 32'd1;
            if (w_last_go) w_done <= 1'b1;
            // "AW 与 WLAST 都齐" ⇒ 发 B。⛔ 同拍到达也要认 (|| 形式):
            //   若只看寄存器, 同拍完成的一笔会被拖到下一拍才发 B (功能仍对, 但没有理由)。
            if ((aw_got || aw_go) && (w_done || w_last_go)) begin
                bvalid <= 1'b1;
                bid    <= aw_go ? awid : bid_r;   // 同拍新到 ⇒ 用新 id, 否则用锁存
            end
        end
    end

endmodule
