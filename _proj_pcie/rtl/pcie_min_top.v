`timescale 1ns/1ps
//=============================================================================
// pcie_min_top.v — P6e 最小版: **我们自己的 PCIe/XDMA 观测通道** (无数据面)
//=============================================================================
// 目标 (一次构建关掉三件事):
//   ① 证明"我们自己例化的 XDMA"能在 KU5P 上枚举并绑定驱动;
//   ② 打通**寄存器窗口** (user BAR / AXI-Lite) —— 主机 `reg_rw /dev/xdma0_user ...`;
//   ③ 满足板级测量的**前置闸**: 读回位流身份 (BUILD_ID) 确认烧的就是这一版。
//
// 接线配方**逐条照抄厂商 BD** (那是这块板上唯一跑通过的 XDMA 接法, 已从 .bd 的 nets 里读出):
//   · IBUFDS_GTE4.O    -> xdma.sys_clk_gt   (金手指来的 100MHz 差分参考钟, GT 侧)
//   · IBUFDS_GTE4.ODIV2-> xdma.sys_clk      (÷2; 厂商就是这么接的, 不要自作主张加 BUFG_GT)
//   · pcieReset        -> xdma.sys_rst_n    (**直连, 无反相器**; 金手指 PERST# 本身低有效)
//   · 参考钟引脚 AB7/AB6 = MGTREFCLK0_224 (来自金手指, 见 Demo 的 PCIe.xdc 与
//     XCKU5PMini/CLAUDE.md 的"Y2 换晶振不影响 PCIe"一条)
// ⚠️ **本设计没有数据面**: m_axi (DMA 通道) 全部 tie 成"永不应答", H2C/C2H 保持静止;
//    只用 user BAR 的寄存器窗口。数据面 + 观测通道的合体是下一步。
// ⚠️ **上板纪律 (实测)**: PCIe 端点只认"FPGA 配置先于主机 POST" ⇒ 烧完本设计后**必须重启主机**
//    才能在 lspci 里看到它 (四种主机侧手段实测全无效, 见 _pcie/README.md 第二节)。
//=============================================================================
module pcie_min_top (
    // ---- PCIe 参考钟 (金手指, 100MHz 差分) ----
    input  wire        pcie_sys_clk_p,      // AB7
    input  wire        pcie_sys_clk_n,      // AB6
    // ---- PCIe 复位 (金手指 PERST#, 低有效) ----
    input  wire        pcieReset,           // J9
    // ---- PCIe 通道 Gen3 x4 ----
    output wire [3:0]  pcie_txp,            // AF7 AE9 AD7 AC5
    output wire [3:0]  pcie_txn,
    input  wire [3:0]  pcie_rxp,            // AF2 AE4 AD2 AB2
    input  wire [3:0]  pcie_rxn,
    // ---- 板级指示 (KU5P 的 io_nor 空闲脚; 板上 LED 映射未核, 只当示波器探点) ----
    output wire        led_d0,              // = user_lnk_up
    output wire        led_d1               // = axi_aresetn (高=AXI 域已复位释放)
);

    // ---------------- 参考钟: 与厂商 BD 逐条同构 ----------------
    wire sys_clk_gt, sys_clk;
    IBUFDS_GTE4 #(
        .REFCLK_EN_TX_PATH (1'b0),
        .REFCLK_HROW_CK_SEL(2'b00),
        .REFCLK_ICNTL_RX   (2'b00)          // ⚠️ 2025.2 的参数名是 ICNTL_RX (不是 TX), 2 位
    ) u_refclk_ibuf (
        .O    (sys_clk_gt),     // 100 MHz -> xdma.sys_clk_gt
        .ODIV2(sys_clk),        //  ÷2     -> xdma.sys_clk   (厂商接法)
        .I    (pcie_sys_clk_p),
        .IB   (pcie_sys_clk_n),
        .CEB  (1'b0)
    );

    // ---------------- XDMA ----------------
    wire        user_lnk_up, axi_aclk, axi_aresetn;
    wire        msi_enable;
    wire [2:0]  msi_vector_width;
    wire [0:0]  usr_irq_ack;

    // user BAR (AXI4-Lite master) -> 我们的寄存器块
    wire [31:0] m_axil_awaddr, m_axil_wdata, m_axil_araddr;
    wire [2:0]  m_axil_awprot, m_axil_arprot;
    wire [3:0]  m_axil_wstrb;
    wire        m_axil_awvalid, m_axil_awready;
    wire        m_axil_wvalid,  m_axil_wready;
    wire [1:0]  m_axil_bresp;
    wire        m_axil_bvalid,  m_axil_bready;
    wire        m_axil_arvalid, m_axil_arready;
    wire [31:0] m_axil_rdata;
    wire [1:0]  m_axil_rresp;
    wire        m_axil_rvalid,  m_axil_rready;

    xdma_0 u_xdma (
        .sys_clk        (sys_clk),
        .sys_clk_gt     (sys_clk_gt),
        .sys_rst_n      (pcieReset),        // 直连, 见头注释
        .pci_exp_txp    (pcie_txp),
        .pci_exp_txn    (pcie_txn),
        .pci_exp_rxp    (pcie_rxp),
        .pci_exp_rxn    (pcie_rxn),
        .user_lnk_up    (user_lnk_up),
        .axi_aclk       (axi_aclk),
        .axi_aresetn    (axi_aresetn),
        .usr_irq_req    (1'b0),
        .usr_irq_ack    (usr_irq_ack),
        .msi_enable     (msi_enable),
        .msi_vector_width(msi_vector_width),
        // ---- DMA 通道 (m_axi) 本最小版**不用**: 全部回"永不应答" ----
        .m_axi_awready  (1'b0),
        .m_axi_wready   (1'b0),
        .m_axi_bid      (4'd0),
        .m_axi_bresp    (2'd0),
        .m_axi_bvalid   (1'b0),
        .m_axi_arready  (1'b0),
        .m_axi_rid      (4'd0),
        .m_axi_rdata    (128'd0),
        .m_axi_rresp    (2'd0),
        .m_axi_rlast    (1'b0),
        .m_axi_rvalid   (1'b0),
        .m_axi_bready   (),          // 输出, 不用
        .m_axi_awid     (), .m_axi_awaddr(), .m_axi_awlen(), .m_axi_awsize(),
        .m_axi_awburst  (), .m_axi_awprot(), .m_axi_awvalid(), .m_axi_awlock(),
        .m_axi_awcache  (), .m_axi_wdata(), .m_axi_wstrb(), .m_axi_wlast(),
        .m_axi_wvalid   (), .m_axi_arid(), .m_axi_araddr(), .m_axi_arlen(),
        .m_axi_arsize   (), .m_axi_arburst(), .m_axi_arprot(), .m_axi_arvalid(),
        .m_axi_arlock   (), .m_axi_arcache(), .m_axi_rready(),
        // ---- user BAR (AXI4-Lite master) ----
        .m_axil_awaddr  (m_axil_awaddr),
        .m_axil_awprot  (m_axil_awprot),
        .m_axil_awvalid (m_axil_awvalid),
        .m_axil_awready (m_axil_awready),
        .m_axil_wdata   (m_axil_wdata),
        .m_axil_wstrb   (m_axil_wstrb),
        .m_axil_wvalid  (m_axil_wvalid),
        .m_axil_wready  (m_axil_wready),
        .m_axil_bvalid  (m_axil_bvalid),
        .m_axil_bresp   (m_axil_bresp),
        .m_axil_bready  (m_axil_bready),
        .m_axil_araddr  (m_axil_araddr),
        .m_axil_arprot  (m_axil_arprot),
        .m_axil_arvalid (m_axil_arvalid),
        .m_axil_arready (m_axil_arready),
        .m_axil_rdata   (m_axil_rdata),
        .m_axil_rresp   (m_axil_rresp),
        .m_axil_rvalid  (m_axil_rvalid),
        .m_axil_rready  (m_axil_rready),
        // ---- 配置管理接口: 不实现, 输入 tie 0 / 输出悬空 ----
        .cfg_mgmt_addr      (19'd0),
        .cfg_mgmt_write     (1'b0),
        .cfg_mgmt_write_data(32'd0),
        .cfg_mgmt_byte_enable(4'd0),
        .cfg_mgmt_read      (1'b0),
        .cfg_mgmt_read_data (),
        .cfg_mgmt_read_write_done()
    );

    // ---------------- 我们的寄存器块 ----------------
    wire [31:0] reg_scratch, reg_wrcnt;
    wire        reg_decode_err;
    wire [31:0] hw_status = {26'd0, msi_vector_width, msi_enable, user_lnk_up, 3'd0};

    axi_regs #(
        .MAGIC_V    (32'h50360001),
        .BUILD_ID_V (32'h00000001)      // ⚠️ 改动时自增: 它是"前置闸"读的那一项
    ) u_regs (
        .clk            (axi_aclk),
        .rst_n          (axi_aresetn),
        .s_axil_awaddr  (m_axil_awaddr),
        .s_axil_awprot  (m_axil_awprot),
        .s_axil_awvalid (m_axil_awvalid),
        .s_axil_awready (m_axil_awready),
        .s_axil_wdata   (m_axil_wdata),
        .s_axil_wstrb   (m_axil_wstrb),
        .s_axil_wvalid  (m_axil_wvalid),
        .s_axil_wready  (m_axil_wready),
        .s_axil_bresp   (m_axil_bresp),
        .s_axil_bvalid  (m_axil_bvalid),
        .s_axil_bready  (m_axil_bready),
        .s_axil_araddr  (m_axil_araddr),
        .s_axil_arprot  (m_axil_arprot),
        .s_axil_arvalid (m_axil_arvalid),
        .s_axil_arready (m_axil_arready),
        .s_axil_rdata   (m_axil_rdata),
        .s_axil_rresp   (m_axil_rresp),
        .s_axil_rvalid  (m_axil_rvalid),
        .s_axil_rready  (m_axil_rready),
        .hw_status      (hw_status),
        .scratch        (reg_scratch),
        .wr_count       (reg_wrcnt),
        .decode_err     (reg_decode_err)
    );

    // 指示 (io_nor 空闲脚, 只当探点): d0 = 链路起, d1 = AXI 域已就绪
    assign led_d0 = user_lnk_up;
    assign led_d1 = axi_aresetn;

endmodule
