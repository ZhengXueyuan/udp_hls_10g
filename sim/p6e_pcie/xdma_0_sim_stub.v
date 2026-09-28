`timescale 1ns/1ps
//=============================================================================
// xdma_0_sim_stub.v — **仅仿真用**的 xdma_0 替身 (模块名故意就叫 xdma_0)
//=============================================================================
// 为什么需要: P6e 合体把 XDMA IP 例化进了 wrapper, 而 IP 的功能模型只在 Vivado 工程里
//   生成 (且带加密/黑盒) ⇒ 在工程 TB 目录里没法 xelab 一个例化了真 IP 的 wrapper。
//   工程坑 8 要求"每个 ifdef 构建配置都有一个例化**真 wrapper** 的全链门" ⇒ 必须有替身。
//
// 替身做什么:
//   · 产生 axi_aclk (250MHz) / axi_aresetn / user_lnk_up / msi_*, 让 wrapper 跑起来;
//   · 实现一个最小 **AXI4-Lite 主机**, 用两个**层次任务**暴露给 TB:
//         u_dut.u_pcie_xdma.axil_read (addr, data);
//         u_dut.u_pcie_xdma.axil_write(addr, data);
//     用任务而不是端口, 是因为 TB 只能层次**读**子模块端口, 不能对 input wire 做过程赋值
//     (要驱动就得 force, 那才容易踩 TB 竞争坑)。
//   ⚠️ 端口名/位宽与真 IP **逐字一致** (来源: _proj_pcie/vivado_prj/pcie_min_prj.gen/
//      sources_1/ip/xdma_0/xdma_0_stub.v 的 black_box 声明) —— 名字对不上 wrapper 就连不上,
//      而"连不上"正是本门要抓的那类错, 所以不能靠猜。
//   ⚠️ 本文件**只给仿真**, 绝不能出现在构建的文件清单里 (构建用真 IP)。
//=============================================================================
module xdma_0 (
    input  wire        sys_clk,
    input  wire        sys_clk_gt,
    input  wire        sys_rst_n,
    output wire [3:0]  pci_exp_txp,
    output wire [3:0]  pci_exp_txn,
    input  wire [3:0]  pci_exp_rxp,
    input  wire [3:0]  pci_exp_rxn,
    output wire        user_lnk_up,
    output wire        axi_aclk,
    output wire        axi_aresetn,
    input  wire [0:0]  usr_irq_req,
    output wire [0:0]  usr_irq_ack,
    output wire        msi_enable,
    output wire [2:0]  msi_vector_width,
    // ---- m_axi (本设计不用; 与真 IP 同名同位宽, 替身不驱动) ----
    input  wire        m_axi_awready,
    input  wire        m_axi_wready,
    input  wire [3:0]  m_axi_bid,
    input  wire [1:0]  m_axi_bresp,
    input  wire        m_axi_bvalid,
    input  wire        m_axi_arready,
    input  wire [3:0]  m_axi_rid,
    input  wire [127:0]m_axi_rdata,
    input  wire [1:0]  m_axi_rresp,
    input  wire        m_axi_rlast,
    input  wire        m_axi_rvalid,
    output wire [3:0]  m_axi_awid,
    output wire [63:0] m_axi_awaddr,
    output wire [7:0]  m_axi_awlen,
    output wire [2:0]  m_axi_awsize,
    output wire [1:0]  m_axi_awburst,
    output wire [2:0]  m_axi_awprot,
    output wire        m_axi_awvalid,
    output wire        m_axi_awlock,
    output wire [3:0]  m_axi_awcache,
    output wire [127:0]m_axi_wdata,
    output wire [15:0] m_axi_wstrb,
    output wire        m_axi_wlast,
    output wire        m_axi_wvalid,
    output wire        m_axi_bready,
    output wire [3:0]  m_axi_arid,
    output wire [63:0] m_axi_araddr,
    output wire [7:0]  m_axi_arlen,
    output wire [2:0]  m_axi_arsize,
    output wire [1:0]  m_axi_arburst,
    output wire [2:0]  m_axi_arprot,
    output wire        m_axi_arvalid,
    output wire        m_axi_arlock,
    output wire [3:0]  m_axi_arcache,
    output wire        m_axi_rready,
    // ---- user BAR (AXI4-Lite master) ----
    output wire [31:0] m_axil_awaddr,
    output wire [2:0]  m_axil_awprot,
    output wire        m_axil_awvalid,
    input  wire        m_axil_awready,
    output wire [31:0] m_axil_wdata,
    output wire [3:0]  m_axil_wstrb,
    output wire        m_axil_wvalid,
    input  wire        m_axil_wready,
    input  wire        m_axil_bvalid,
    input  wire [1:0]  m_axil_bresp,
    output wire        m_axil_bready,
    output wire [31:0] m_axil_araddr,
    output wire [2:0]  m_axil_arprot,
    output wire        m_axil_arvalid,
    input  wire        m_axil_arready,
    input  wire [31:0] m_axil_rdata,
    input  wire [1:0]  m_axil_rresp,
    input  wire        m_axil_rvalid,
    output wire        m_axil_rready,
    // ---- cfg mgmt (不实现) ----
    input  wire [18:0] cfg_mgmt_addr,
    input  wire        cfg_mgmt_write,
    input  wire [31:0] cfg_mgmt_write_data,
    input  wire [3:0]  cfg_mgmt_byte_enable,
    input  wire        cfg_mgmt_read,
    output wire [31:0] cfg_mgmt_read_data,
    output wire        cfg_mgmt_read_write_done
);

    // ---------------- 时钟: 真实板上是链路速率定的; 最小版实测 ≈250MHz (Gen2 x4) ----------------
    reg aclk = 1'b0;
    always #2 aclk = ~aclk;                 // 250 MHz
    assign axi_aclk = aclk;

    // ---------------- 复位/链路: sys_rst_n 落 ⇒ 复位; 释放后等一段再报 link up ----------------
    reg [11:0] rst_cnt = 12'd0;
    reg        aresetn_r = 1'b0;
    reg        lnk_r     = 1'b0;
    always @(posedge aclk) begin
        if (!sys_rst_n) begin
            rst_cnt <= 12'd0; aresetn_r <= 1'b0; lnk_r <= 1'b0;
        end else begin
            if (rst_cnt != 12'hFFF) rst_cnt <= rst_cnt + 12'd1;
            aresetn_r <= (rst_cnt >= 12'd16);      // 复位后 16 拍释放 (够 snap_cdc 的同步器跑完)
            lnk_r     <= (rst_cnt >= 12'd256);
        end
    end
    assign axi_aresetn = aresetn_r;
    assign user_lnk_up = lnk_r;

    assign usr_irq_ack   = 1'b0;
    assign msi_enable    = 1'b1;
    assign msi_vector_width = 3'd1;
    assign pci_exp_txp   = 4'd0;
    assign pci_exp_txn   = 4'd0;
    assign cfg_mgmt_read_data = 32'd0;
    assign cfg_mgmt_read_write_done = 1'b0;

    // ---------------- AXI4-Lite 主机 (任务驱动; 见头注释) ----------------
    reg [31:0] awaddr_r = 0, wdata_r = 0, araddr_r = 0;
    reg [3:0]  wstrb_r  = 4'hF;
    reg        awvalid_r = 0, wvalid_r = 0, bready_r = 0, arvalid_r = 0, rready_r = 0;
    reg [31:0] rd_data  = 0;
    reg [1:0]  wr_resp  = 0;
    // 最近一次读/写的响应码 (TB 可以层次读它来验 SLVERR —— 真 XDMA 在错误时把**数据**
    // 填 0xffffffff, 那是主机 IP 的行为、不是 axi_regs 的行为, 替身不模仿那一段)
    reg [1:0]  last_rresp = 2'd0;
    reg [1:0]  last_bresp = 2'd0;

    assign m_axil_awaddr  = awaddr_r;
    assign m_axil_awprot  = 3'd0;
    assign m_axil_awvalid = awvalid_r;
    assign m_axil_wdata   = wdata_r;
    assign m_axil_wstrb   = wstrb_r;
    assign m_axil_wvalid  = wvalid_r;
    assign m_axil_bready  = bready_r;
    assign m_axil_araddr  = araddr_r;
    assign m_axil_arprot  = 3'd0;
    assign m_axil_arvalid = arvalid_r;
    assign m_axil_rready  = rready_r;

    // m_axi 侧不驱动 (wrapper 里也没接) —— 显式 tie 0 免得 X 乱飘
    assign m_axi_awid = 4'd0;    assign m_axi_awaddr = 64'd0; assign m_axi_awlen  = 8'd0;
    assign m_axi_awsize = 3'd0;  assign m_axi_awburst = 2'd0; assign m_axi_awprot = 3'd0;
    assign m_axi_awvalid = 1'b0; assign m_axi_awlock = 1'b0;  assign m_axi_awcache = 4'd0;
    assign m_axi_wdata = 128'd0; assign m_axi_wstrb = 16'd0;  assign m_axi_wlast = 1'b0;
    assign m_axi_wvalid = 1'b0;  assign m_axi_bready = 1'b0;
    assign m_axi_arid = 4'd0;    assign m_axi_araddr = 64'd0; assign m_axi_arlen = 8'd0;
    assign m_axi_arsize = 3'd0;  assign m_axi_arburst = 2'd0; assign m_axi_arprot = 3'd0;
    assign m_axi_arvalid = 1'b0; assign m_axi_arlock = 1'b0;  assign m_axi_arcache = 4'd0;
    assign m_axi_rready = 1'b0;

    // AXI4-Lite 写: AW/W 同拍发, 等 B (与 tb_axi_regs 的主机同风格)
    task axil_write(input [31:0] a, input [31:0] d);
        begin
            @(negedge aclk);
            awaddr_r <= a;  awvalid_r <= 1'b1;
            wdata_r  <= d;  wstrb_r   <= 4'hF; wvalid_r <= 1'b1;
            bready_r <= 1'b1;
            while (!m_axil_bvalid) @(posedge aclk);
            @(negedge aclk);
            awvalid_r <= 1'b0; wvalid_r <= 1'b0;
            wr_resp   <= m_axil_bresp;
            last_bresp = m_axil_bresp;
            bready_r  <= 1'b0;
            @(posedge aclk);
        end
    endtask

    // AXI4-Lite 读
    task axil_read(input [31:0] a, output [31:0] d);
        begin
            @(negedge aclk);
            araddr_r <= a; arvalid_r <= 1'b1; rready_r <= 1'b1;
            while (!m_axil_rvalid) @(posedge aclk);
            d = m_axil_rdata;
            last_rresp = m_axil_rresp;
            @(negedge aclk);
            arvalid_r <= 1'b0; rready_r <= 1'b0;
            @(posedge aclk);
        end
    endtask

endmodule
