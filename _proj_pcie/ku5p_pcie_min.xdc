#=============================================================================
# ku5p_pcie_min.xdc — P6e 最小版 (我们自己的 XDMA 观测通道)
#   引脚来源: Demo/XCKU5P_PCIe_DDR4_ETH_aurora_12g/src/PCIe.xdc (厂商 2019.2 工程, 同板)
#   参考钟: 金手指 -> MGTREFCLK0_224 (AB7/AB6); 100MHz 差分, 接 IBUFDS_GTE4 -> xdma
#   复位:   pcieReset = J9 (金手指 PERST#, 低有效; 直连 xdma.sys_rst_n)
#   探点:   led_d0/d1 用厂商 io_nor[] 空闲脚 (KU5P 板载 LED 映射未核)
#=============================================================================

# --- 配置 (同厂商工程的保守口径) ---
set_property CFGBVS VCCO [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN Pullup [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

# --- PCIe 参考钟 (金手指 100MHz 差分; GT 参考钟引脚, 无 IOSTANDARD) ---
create_clock -period 10.000 -name pcie_ref_clk [get_ports pcie_sys_clk_p]
set_property PACKAGE_PIN AB7 [get_ports pcie_sys_clk_p]
set_property PACKAGE_PIN AB6 [get_ports pcie_sys_clk_n]

# --- PCIe 复位 (PERST#, 低有效) ---
set_property -dict {PACKAGE_PIN J9 IOSTANDARD LVCMOS33} [get_ports pcieReset]

# --- PCIe 通道 Gen3 x4 (GT 引脚, 无 IOSTANDARD) ---
set_property PACKAGE_PIN AF7 [get_ports {pcie_txp[3]}]
set_property PACKAGE_PIN AE9 [get_ports {pcie_txp[2]}]
set_property PACKAGE_PIN AD7 [get_ports {pcie_txp[1]}]
set_property PACKAGE_PIN AC5 [get_ports {pcie_txp[0]}]
set_property PACKAGE_PIN AF2 [get_ports {pcie_rxp[3]}]
set_property PACKAGE_PIN AE4 [get_ports {pcie_rxp[2]}]
set_property PACKAGE_PIN AD2 [get_ports {pcie_rxp[1]}]
set_property PACKAGE_PIN AB2 [get_ports {pcie_rxp[0]}]
# tx_n / rx_n 由差分对自动配套 (与 _p 在同一对球上)

# --- 板级探点 (厂商 io_nor[] 空闲脚; LVCMOS25) ---
set_property PACKAGE_PIN AF14 [get_ports led_d0]
set_property PACKAGE_PIN AF15 [get_ports led_d1]
set_property IOSTANDARD LVCMOS25 [get_ports {led_d0 led_d1}]

# --- 时序: XDMA IP 自带的 XDC 已约束 axi_aclk 等; 这里只补一条异步复位路径豁免 ---
#   pcieReset 是异步引脚 (来自金手指), 到 xdma.sys_rst_n 的去抖同步在 IP 内部;
#   为避免把它当作同步路径做时序分析 (无源时钟域), 显式声明为伪路径。
set_false_path -from [get_ports pcieReset]
