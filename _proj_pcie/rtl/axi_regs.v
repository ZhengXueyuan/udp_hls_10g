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
// 写法要点 (AXI4-Lite 最小正确实现):
//   - AW/W 两通道**独立**握手 (AXI-Lite 允许任意到达顺序), 两者都到才落寄存器并回 B;
//     B 被接收后才重新拉高 awready/wready (每笔一笔, 不复用握手中的地址)。
//   - 读通道 1 拍延迟 (锁存地址 -> 下一拍给数据), rvalid 保持到 rready。
//   - 只写 SCRATCH: 按字节选通 wstrb 合并, 其余地址写返回 SLVERR (安全: 不静默丢写)。
//   - 无复位寄存器数组; 计数器复位清 0 (便于"刚上电"判断)。
//=============================================================================
module axi_regs #(
    parameter [31:0] MAGIC_V    = 32'h50360001,
    parameter [31:0] BUILD_ID_V = 32'h00000001
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
    output wire        decode_err      // 命中未实现地址 (读或写) 的脉冲
);

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

    reg [31:0] rdata_mux;
    always @* begin
        case (r_word)
            6'd0:    rdata_mux = MAGIC_V;
            6'd1:    rdata_mux = BUILD_ID_V;
            6'd2:    rdata_mux = scratch;
            6'd3:    rdata_mux = freecnt;
            6'd4:    rdata_mux = hw_status;
            6'd5:    rdata_mux = 32'hDEADBEEF;
            default: rdata_mux = 32'h00000000;
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
                s_axil_rresp <= (r_word <= 6'd5) ? 2'b00 : 2'b10;   // 未实现 -> SLVERR
                decode_err_r <= (r_word > 6'd5);
                s_axil_rvalid <= 1'b1;
            end
            if (s_axil_rvalid && s_axil_rready) begin
                s_axil_rvalid <= 1'b0; s_axil_arready <= 1'b1; decode_err_r <= 1'b0;
            end
        end
    end

    assign decode_err = decode_err_r;

endmodule
