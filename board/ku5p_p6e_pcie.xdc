#=============================================================================
# ku5p_p6e_pcie.xdc — P6e: PCIe/XDMA 观测通道的引脚与时钟 (只含 PCIe 部分)
#   引脚来源: Demo/XCKU5P_PCIe_DDR4_ETH_aurora_12g/src/PCIe.xdc (厂商 2019.2 工程, 同板)
#   ⚠️ 本文件**故意只放 PCIe 约束**: 基线 (RGMII/时钟/LED/reset_n) 由
#      ku5p_p6a_t8p0.xdc **原样复用** (build_p6e_ku5p.tcl 同时加这两个文件) ——
#      不复制、不 source, 以免两份 XDC 悄悄分叉 (P6a 是闸 G 的基线, 必须保持逐字原样)。
#   ⚠️ **不重复约束 reset_n**: 本板 reset_n 就接在 PCIe 槽的 PERST# (J9) 上,
#      P6a XDC 已经把它约束好了 (PACKAGE_PIN J9) —— 在 wrapper 里同一个信号直接接
#      xdma.sys_rst_n (厂商 BD 也是这么接的)。这里再写一次会变成"一个脚两个端口"。
#=============================================================================

# --- PCIe 参考钟 (金手指 100MHz 差分 → MGTREFCLK0_224 = AB7/AB6) ---
# GT 参考钟引脚不设 IOSTANDARD (专用差分输入)
create_clock -period 10.000 -name pcie_ref_clk [get_ports pcie_sys_clk_p]
set_property PACKAGE_PIN AB7 [get_ports pcie_sys_clk_p]
set_property PACKAGE_PIN AB6 [get_ports pcie_sys_clk_n]

# --- PCIe 通道 Gen3 x4 (GT 引脚, 无 IOSTANDARD; _n 由差分对自动配套) ---
set_property PACKAGE_PIN AF7 [get_ports {pcie_txp[3]}]
set_property PACKAGE_PIN AE9 [get_ports {pcie_txp[2]}]
set_property PACKAGE_PIN AD7 [get_ports {pcie_txp[1]}]
set_property PACKAGE_PIN AC5 [get_ports {pcie_txp[0]}]
set_property PACKAGE_PIN AF2 [get_ports {pcie_rxp[3]}]
set_property PACKAGE_PIN AE4 [get_ports {pcie_rxp[2]}]
set_property PACKAGE_PIN AD2 [get_ports {pcie_rxp[1]}]
set_property PACKAGE_PIN AB2 [get_ports {pcie_rxp[0]}]

# --- 说明: axi_aclk / axi_aresetn 等由 XDMA IP 自带的 XDC 约束, 不在此重复 ---

# --- 跨时钟域: gmii_clk (来自 phy1_rxc, PHY 的 25MHz 晶振) 与 axi_aclk (来自金手指的
#     100MHz 参考钟, XDMA 内部生成) **不同源** ⇒ 它们之间是真正的异步关系。
#     这两个域之间**只有一处连接**: snap_cdc 的握手 (多比特数据 hold_b 靠握手保证稳定,
#     同步器链已打 ASYNC_REG)。切异步组, 别让工具去"凑"它们之间的时序。
#     ⚠️ XDC 里不能写 if/foreach (Designutils 20-1307), 用 get_clocks -quiet 兜住找不到的情况;
#        实测核对: 实现后的 timing 报告的 Clock Summary 必须同时列出 phy1_rxc/gmii_clk 与 axi_aclk
#        (若这里名字写错 ⇒ 组为空 ⇒ 会在日志里报 CRITICAL WARNING, 一眼可见而不是静默)。
set_clock_groups -asynchronous \
    -group [get_clocks -quiet -include_generated_clocks phy1_rxc] \
    -group [get_clocks -quiet -include_generated_clocks axi_aclk]
