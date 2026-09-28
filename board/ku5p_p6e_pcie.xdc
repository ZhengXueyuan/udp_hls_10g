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

# --- 跨时钟域约束 (set_clock_groups) **不在本文件**: 见 ku5p_p6e_cdc.xdc ---
#   原因 (2026-09-29 实测踩到): XDC 是在**综合前**解析的, 那一刻 create_clock 还没生效、
#   XDMA 也还是黑盒 ⇒ 本文件里的 get_clocks 拿到空对象 ⇒ Vivado 报
#   `CRITICAL WARNING [Vivado 12-4739] set_clock_groups: No valid object(s) found`
#   并**静默丢弃**该约束 (构建照样过, 但 report_clock_interaction 里两个域仍是
#   "Timed (unsafe)")。修法 = 把它单独放一个文件并标 used_in_synthesis=false (只在实际实现阶段
#   应用, 那时两个时钟都已存在)。
