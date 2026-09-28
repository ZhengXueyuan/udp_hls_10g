`timescale 1ns/1ps
//=============================================================================
// axi_regs.v — P6e 最小版: 挂在 XDMA **user BAR (AXI4-Lite master)** 上的寄存器块
//=============================================================================
// 这是"PCIe 观测通道"的第一块自己的 RTL: 主机侧用 `reg_rw /dev/xdma0_user <addr> w`
// 即可读/写这张表, 用来做 (a) 前置闸: 读回**位流身份**确认烧的就是这一版;
// (b) 状态读出; (c) 活体探针 (自由计数器)。
//
// 寄存器表 (字节地址; 32 位字; 只实现的地址返回 SLVERR):
//   0x00 RO  MAGIC     = 0x50360001  ("P6" + 版本 1) —— 用于区分"读的是我们的逻辑"
//   0x04 RO  BUILD_ID  = MAGIC 之外的**每次构建可自增**的身份号 (前置闸用)
//   0x08 RW  SCRATCH   = 读写回环 (通道功能判据; 默认 0)
//   0x0C RO  FREECNT   = 自由计数器 (axi_aclk 域) ⇒ 读两次可反解 AXI 时钟频率 + 证明活着
//   0x10 RO  HW_STATUS = 设计侧状态位束 (本最小版 = {link_up, msi_enable, 0...})
//   0x14 RO  MARKER    = 0xDEADBEEF  (地址译码正确性检查: 读错地址不会恰好是它)
//
//   ---- P6e 合体新增: 数据面快照窗口 (跨 gmii_clk → axi_aclk 的相干快照) ----
//   0x18 WO  SNAP_CTRL  = 写 bit0=1 ⇒ **触发一次**新快照 (同时清 done); 读回 0
//   0x1C RO  SNAP_STATUS= bit0 busy (CDC 还在飞) / bit1 done (sticky, 触发时清)
//                         bit2 seen (复位后完成过至少一次) / [31:16] gen (完成次数)
//   0x20 RO  SNAP_W0    = 快照字 0 (数据面 gmii 域)
//   0x24 RO  SNAP_W1    ... 一直到 0x7C SNAP_W23 (共 **24 字**, 2026-09-29 从 16 扩上来)
//   ⚠️ 扩窗要**五处同改** (2026-09-29 定为五处; 以前写"三处/四处"都漏了后两项):
//      ① `SNAP_NW` (单一来源: wrapper 的 `SNAP_NW_P6E`) ② `snap_src` 拼接项数
//      ③ **读侧 `snap_base` 的位宽** (装不下就静默回绕, 见读侧译码处注释)
//      ④ 本文件的读 mux 与 SLVERR 边界 (`r_word <= SNAP_LAST_IDX`)
//      ⑤ **验收脚本里"未实现地址"的取值** (每扩一次都要跟着挪, 见下)
//      漏一处的表现各不相同 (截断/回绕读错字/读到 SLVERR), 所以五处都要在门里被覆盖。
//   ⚠️ 扩窗会把"未实现地址"的边界推后 ⇒ 验收脚本里那个"读未实现地址应得 SLVERR"的**地址也得跟着挪**
//      (0x18→0x44→0x60 都是这么挪的; 24 字版 ⇒ **0x84**)。
//      ⚠️ 挪的时候**绝不能挑 ≥0x100**: `ar_word = araddr[7:2]` 只有 6 位 ⇒ 地址每 256 字节回绕,
//         挑 0x100 会别名到 word 0 = MAGIC (≠0xffffffff) ⇒ 判据假 FAIL; 24 字版挑 0x160 则别名到
//         已实现字 ⇒ 假 PASS。地址不挪的后果是"新功能上线"被门报成回归 (本工程已经踩过两次)。
//
// ⚠️ **为什么用"显式触发"而不是"自动周期刷新" (设计取舍, 别改成自动的)**:
//   主机读 N 个字要走 N 笔独立 PCIe 事务 (几十 µs), 而自动刷新的周期只要短于这个窗口,
//   读出来的字就会**跨越两代快照** (CDC 再相干也没用 —— 撕裂发生在寄存器文件这一层)。
//   显式触发把"快照"与"读"解耦: 触发后整束**冻结**到下一次触发为止 ⇒ 读窗口天然原子,
//   主机不需要 seqlock/重试, 也不需要在主机侧维护任何状态。
//   ⚠️ 代价: 快照是"上次触发时刻"的值, 不是"此刻"的值 —— 读计数类信号完全够用。
//   主机协议: 写 SNAP_CTRL.bit0=1 → 轮询 SNAP_STATUS.done==1 (带上限超时) → 读 8 个字。
//   ⚠️ done 是 sticky 的: 即使快照在第一次轮询之前就完成了也不会漏 (busy 只可能被漏看)。
//   ⚠️ busy 一直不落 = gmii 时钟没在跑 (snap_cdc 的行为, 见其头注释) ⇒ 这本身就是诊断信息:
//      计数不动是"数据面死了"还是"观测通道没时钟", 用这个位分开。
//
// 写法要点 (AXI4-Lite 最小正确实现):
//   - AW/W 两通道**独立**握手 (AXI-Lite 允许任意到达顺序), 两者都到才落寄存器并回 B;
//     B 被接收后才重新拉高 awready/wready (每笔一笔, 不复用握手中的地址)。
//   - 读通道 1 拍延迟 (锁存地址 -> 下一拍给数据), rvalid 保持到 rready。
//   - 只写 SCRATCH / SNAP_CTRL: 按字节选通 wstrb 合并, 其余地址写返回 SLVERR (不静默丢写)。
//   - 无复位寄存器数组; 计数器复位清 0 (便于"刚上电"判断)。
//   - **快照字只有一个驱动块** (触发清零与 valid 捕获在同一 always 里, 靠 snap_clr 选路),
//     避免"两个 always 块写同一个寄存器" ⇒ 综合报多驱动/仿真出 X。
//=============================================================================
module axi_regs #(
    parameter [31:0]  MAGIC_V    = 32'h50360001,
    parameter [31:0]  BUILD_ID_V = 32'h00000001,
    // 快照字数: 必须与 wrapper 的 `snap_cdc #(.NW())` 和 `snap_src` 项数**同值**。
    // 位宽由它推导 ⇒ 扩窗时端口宽度自动跟着走 (手写 256 位的话, 扩到 16 字就是静默截断)。
    // **上限 = 32** (受读侧选字 `snap_idx` 5 位与 SLVERR 边界 `r_word[5:0]` 限制)。
    // ⚠️ 2026-09-29 更正: 这里原先写"上限 16 (读侧选字用 r_word[3:0])" —— 那是**过时且错位**的
    //   说明。真正把上一版卡在 16 的是 `snap_base` 的**位宽** (旧 `[8:0]` 装不下 17 字起的
    //   {snap_idx,5'b0}), 与读侧的位宽无关; 该行已加宽到 `[9:0]` (见读侧译码处注释)。
    parameter integer SNAP_NW    = 8
) (
    input  wire        clk,
    input  wire        rst_n,
    // ---- AXI4-Lite 从口 (来自 XDMA 的 m_axil_*) ----
    input  wire [31:0] s_axil_awaddr,
    input  wire [2:0]  s_axil_awprot,
    input  wire        s_axil_awvalid,
    output reg         s_axil_awready,
    input  wire [31:0] s_axil_wdata,
    input  wire [3:0]  s_axil_wstrb,
    input  wire        s_axil_wvalid,
    output reg         s_axil_wready,
    output reg  [1:0]  s_axil_bresp,
    output reg         s_axil_bvalid,
    input  wire        s_axil_bready,
    input  wire [31:0] s_axil_araddr,
    input  wire [2:0]  s_axil_arprot,
    input  wire        s_axil_arvalid,
    output reg         s_axil_arready,
    output reg  [31:0] s_axil_rdata,
    output reg  [1:0]  s_axil_rresp,
    output reg         s_axil_rvalid,
    input  wire        s_axil_rready,
    // ---- 设计侧 ----
    input  wire [31:0] hw_status,      // 只读状态 (0x10)
    output reg  [31:0] scratch,        // 读写寄存器 (0x08)
    output reg  [31:0] wr_count,       // 成功写入笔数 (调试/活体)
    output wire        decode_err,     // 命中未实现地址 (读或写) 的脉冲
    // ---- 数据面快照接口 (接 snap_cdc: b 域 = 数据面 gmii_clk) ----
    output wire        snap_req,       // 1 拍脉冲: 请求一次快照
    input  wire        snap_busy,      // 来自 snap_cdc.busy_a (高 = 上一次还在飞)
    input  wire        snap_valid,     // 1 拍脉冲: 快照完成 (随 dout 有效)
    input  wire [SNAP_NW*32-1:0] snap_din   // 来自 snap_cdc.dout_a (SNAP_NW 字 × 32 位)
);

    localparam integer SNAP_W0_IDX   = 8;                   // 快照字起始 word 号 (= 0x20)
    localparam integer SNAP_LAST_IDX = 8 + SNAP_NW - 1;      // 最后一个快照字的 word 号

    // ---------------- 自由计数器 (0x0C) ----------------
    reg [31:0] freecnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) freecnt <= 32'd0;
        else        freecnt <= freecnt + 32'd1;
    end

    // ---------------- 写通道 ----------------
    reg        aw_hit, w_hit;
    reg [31:0] awaddr_r, wdata_r;
    reg [3:0]  wstrb_r;
    wire       wr_go   = aw_hit && w_hit && !s_axil_bvalid;
    wire [5:0] w_word  = awaddr_r[7:2];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axil_awready <= 1'b1; s_axil_wready <= 1'b1;
            s_axil_bvalid  <= 1'b0; s_axil_bresp  <= 2'b00;
            aw_hit <= 1'b0; w_hit <= 1'b0;
            awaddr_r <= 32'd0; wdata_r <= 32'd0; wstrb_r <= 4'd0;
            scratch <= 32'd0; wr_count <= 32'd0;
        end else begin
            if (s_axil_awready && s_axil_awvalid) begin
                awaddr_r <= s_axil_awaddr; aw_hit <= 1'b1; s_axil_awready <= 1'b0;
            end
            if (s_axil_wready && s_axil_wvalid) begin
                wdata_r <= s_axil_wdata; wstrb_r <= s_axil_wstrb; w_hit <= 1'b1; s_axil_wready <= 1'b0;
            end
            if (wr_go) begin
                s_axil_bvalid <= 1'b1;
                wr_count <= wr_count + 32'd1;
                if (w_word == 6'd2) begin                       // 0x08 SCRATCH (RW)
                    if (wstrb_r[0]) scratch[7:0]   <= wdata_r[7:0];
                    if (wstrb_r[1]) scratch[15:8]  <= wdata_r[15:8];
                    if (wstrb_r[2]) scratch[23:16] <= wdata_r[23:16];
                    if (wstrb_r[3]) scratch[31:24] <= wdata_r[31:24];
                    s_axil_bresp <= 2'b00;
                end else if (w_word == 6'd6) begin               // 0x18 SNAP_CTRL (写侧触发)
                    s_axil_bresp <= 2'b00;                       // 数据位在 snap_clr 里用掉
                end else begin                                   // 其余地址: 非法写
                    s_axil_bresp <= 2'b10;                       // SLVERR
                end
            end
            if (s_axil_bvalid && s_axil_bready) begin
                s_axil_bvalid <= 1'b0; aw_hit <= 1'b0; w_hit <= 1'b0;
                s_axil_awready <= 1'b1; s_axil_wready <= 1'b1;
            end
        end
    end

    // ---------------- 读通道 ----------------
    reg [31:0] araddr_r;
    reg [5:0]  r_word;
    wire [5:0] ar_word = s_axil_araddr[7:2];
    reg        decode_err_r;

    // ---------------- 数据面快照寄存器 (0x18-0x3C) ----------------
    // ⚠️ 本块必须放在**写/读通道的 wire 声明之后** (wr_go / w_word / r_word): xvlog 先声明后用 (工程坑 22)
    // 单驱动块: "触发清零" 与 "valid 捕获" 都在同一个 always 里 (避免两个 always 写同一寄存器)
    reg [SNAP_NW*32-1:0] snap_words_r;
    reg         snap_done_r, snap_seen_r;
    reg [15:0]  snap_gen_r;

    wire        snap_clr = wr_go && (w_word == 6'd6);      // 对 0x18 的一次成功写
    assign      snap_req = snap_clr;                       // wr_go 恰好 1 拍宽 ⇒ 天然是脉冲

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            snap_words_r <= {SNAP_NW*32{1'b0}}; snap_done_r <= 1'b0;
            snap_seen_r  <= 1'b0;               snap_gen_r  <= 16'd0;
        end else if (snap_valid) begin
            snap_words_r <= snap_din;
            snap_done_r  <= 1'b1;
            snap_seen_r  <= 1'b1;
            snap_gen_r   <= snap_gen_r + 16'd1;
        end else if (snap_clr) begin
            snap_done_r  <= 1'b0;
        end
    end

    // 读侧译码: SNAP_NW 个字 = word 8..(8+SNAP_NW-1) = 0x20.. (NW=24 时是 0x20..0x7C)
    // ⚠️⚠️ 下标必须是 `r_word - 8`, **不能**直接截 r_word 的低位 —— 这里连踩两次:
    //   8 字版写 `r_word[2:0]`, 恰好 8..15 → 0..7 正确 (纯属巧合);
    //   扩到 16 字时换 `r_word[3:0]` ⇒ word 16..23 回绕到 0..7, **且** 0x20 也被当成 W8
    //   (读出来是重复的另一路数据 —— 静默错, 单看某一遍读不出问题)。
    //   是单元门判据 15b (同代 + 字号逐一核对) 当场抓到的。
    wire [4:0]  snap_idx    = r_word[4:0] - SNAP_W0_IDX[4:0];
    // ⚠️⚠️ **这一行必须装得下 {snap_idx[4:0], 5'b0} = 10 位** —— 写成 `[8:0]` 时最高位被
    //   **静默截断**, symptom 精确且隐蔽: 字数 ≥ 9+8=17 起, 高地址的字会回绕读到低地址的字
    //   (NW=24 时 `0x60..0x7C` 这 8 个读回 W0..W7 的值; NW=32 时 16 个错)。
    //   xvlog 对"赋值右端比左端宽"**完全沉默** (lint 里 `10-3091` 计数 0) ⇒ 只有例化真 DUT
    //   并逐字读回的门能抓 (tb_axi_regs 判据 13d/15b 逐字核对就是为它准备的)。
    //   历史: 8 字/16 字两版都在 `[8:0]` 下工作 —— 因为 {snap_idx(0..15), 5'b0} 最高只到 480,
    //   9 位 (max 511) 恰好够; 是扩到 24 字才越界。**扩窗第一步就是这一行**。
    wire [9:0]  snap_base   = {snap_idx, 5'b0};
    wire [31:0] snap_status = {snap_gen_r, 13'd0, snap_seen_r, snap_done_r, snap_busy};

    reg [31:0] rdata_mux;
    always @* begin
        case (r_word)
            6'd0:    rdata_mux = MAGIC_V;
            6'd1:    rdata_mux = BUILD_ID_V;
            6'd2:    rdata_mux = scratch;
            6'd3:    rdata_mux = freecnt;
            6'd4:    rdata_mux = hw_status;
            6'd5:    rdata_mux = 32'hDEADBEEF;
            6'd6:    rdata_mux = 32'd0;                        // 0x18 写口, 读回 0
            6'd7:    rdata_mux = snap_status;                  // 0x1C
            // 快照字: word 8..(8+SNAP_NW-1) —— 用 if 按参数判范围 (case 的标签没法由参数生成),
            // 这样扩窗时只需要改 SNAP_NW 一个数, 不会漏掉某个标签 ⇒ 也就不会回绕读错字。
            default: rdata_mux = ((r_word >= SNAP_W0_IDX) && (r_word <= SNAP_LAST_IDX))
                                 ? snap_words_r[snap_base +: 32] : 32'h00000000;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axil_arready <= 1'b1; s_axil_rvalid <= 1'b0;
            s_axil_rdata <= 32'd0; s_axil_rresp <= 2'b00;
            araddr_r <= 32'd0; r_word <= 6'd0; decode_err_r <= 1'b0;
        end else begin
            if (s_axil_arready && s_axil_arvalid) begin
                araddr_r <= s_axil_araddr; r_word <= ar_word;
                s_axil_arready <= 1'b0;
            end
            if (!s_axil_arready && !s_axil_rvalid) begin
                s_axil_rdata <= rdata_mux;
                s_axil_rresp <= (r_word <= SNAP_LAST_IDX) ? 2'b00 : 2'b10;  // 未实现 -> SLVERR
                decode_err_r <= (r_word >  SNAP_LAST_IDX);
                s_axil_rvalid <= 1'b1;
            end
            if (s_axil_rvalid && s_axil_rready) begin
                s_axil_rvalid <= 1'b0; s_axil_arready <= 1'b1; decode_err_r <= 1'b0;
            end
        end
    end

    assign decode_err = decode_err_r;

endmodule
