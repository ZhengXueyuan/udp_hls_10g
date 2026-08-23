#=============================================================================
# eco_rgmii_phy1.xdc — Kintex7 ECO 板 (XC7K325T-2FFG676C) 1G RGMII PHY1 引脚+时钟约束
# 来源: D:\repo\ECO\udp_hls_eco\xdc\eco_rgmii_phy1.xdc (板上 7/7 PASS 配方),
#       逐字复用; 仅删去 UART 约束 (本阶段 wrapper_1g.v 无 UART 端口)。
#=============================================================================
# 引脚策略 (2026-08-16 板上验证, 详见 udp_hls_eco/PORT_NOTES.md):
#   - PHY1 RGMII = k719/k720 DEMO 引脚组 — 板载验证: AB2 上有真实 2.5MHz
#     空闲时钟, 而 R3 原理图的 PHY1 引脚 (W1) 读零边沿 → 实物按 demo 引脚
#     排布, 不是 R3 原理图。
#   - 时钟/复位/LED = demo 验证过的引脚 (k701/k707)。
#   - mdc/mdio/nrst 不约束: wrapper 不驱动 (与 k720 demo 一致 — 只驱动 12 根
#     RGMII 引脚; 未用引脚靠 UNUSEDPIN Pullup 浮空, 不干扰 PHY 配置电阻)。
#=============================================================================

# --- 配置 ---
set_property CFGBVS VCCO [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN Pullup [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

# --- 时钟 ---
# phy1_rxc: 125MHz RGMII RX 时钟 @1G 链路。端口上定义 MASTER 时钟 (8ns)。
# 该时钟经 util_gmii_to_rgmii 内部 LUT1 倒相 BUFG (bufmr_rgmii_rxc) 成为
# gmii_clk — created clock 无法穿透 LUT1, 故在 BUFG 输出上定义 GENERATED
# 时钟 (-invert 给出边沿关系)。
# 注意: 实例名 u_rgmii 与 BUFG 名 bufmr_rgmii_rxc 必须与 wrapper_1g.v 一致,
#       否则约束失效 (这两处名字是本 xdc 与 RTL 的唯一耦合点)。
create_clock -period 8.000 -name phy1_rxc [get_ports phy1_rxc]
create_generated_clock -name gmii_clk \
    -source [get_ports phy1_rxc] -invert -divide_by 1 \
    [get_pins u_rgmii/bufmr_rgmii_rxc/O]
# fpga_gclk: 50MHz 板载晶振 (demo 验证引脚 G22); 经 wrapper 内 MMCM 产生
# 200MHz IDELAYCTRL 参考钟。
create_clock -period 20.000 -name fpga_gclk [get_ports fpga_gclk]

# --- PHY1 RGMII (bank 34, LVCMOS18) ---
set_property PACKAGE_PIN AB2 [get_ports phy1_rxc]
set_property PACKAGE_PIN AE2 [get_ports {phy1_rxd[0]}]
set_property PACKAGE_PIN AE1 [get_ports {phy1_rxd[1]}]
set_property PACKAGE_PIN AC1 [get_ports {phy1_rxd[2]}]
set_property PACKAGE_PIN AC2 [get_ports {phy1_rxd[3]}]
set_property PACKAGE_PIN AF3 [get_ports phy1_rxctl]
set_property PACKAGE_PIN AB1 [get_ports phy1_txc]
set_property PACKAGE_PIN AB4 [get_ports {phy1_txd[0]}]
set_property PACKAGE_PIN AA4 [get_ports {phy1_txd[1]}]
set_property PACKAGE_PIN AA3 [get_ports {phy1_txd[2]}]
set_property PACKAGE_PIN AA2 [get_ports {phy1_txd[3]}]
set_property PACKAGE_PIN Y3  [get_ports phy1_txctl]
# 无 mdc/mdio/nrst 引脚 — 与 k720 demo 相同, 只驱动 12 根 RGMII 引脚;
# 未用引脚经 UNUSEDPIN Pullup 浮空 (同 demo)。

set_property IOSTANDARD LVCMOS18 [get_ports phy1_rxc]
set_property IOSTANDARD LVCMOS18 [get_ports {phy1_rxd[*]}]
set_property IOSTANDARD LVCMOS18 [get_ports phy1_rxctl]
set_property IOSTANDARD LVCMOS18 [get_ports phy1_txc]
set_property IOSTANDARD LVCMOS18 [get_ports {phy1_txd[*]}]
set_property IOSTANDARD LVCMOS18 [get_ports phy1_txctl]
set_property SLEW FAST [get_ports {phy1_txd[*]}]
set_property SLEW FAST [get_ports phy1_txctl]
set_property SLEW FAST [get_ports phy1_txc]

# --- 板钟 / 复位 (demo 验证引脚) ---
set_property PACKAGE_PIN G22 [get_ports fpga_gclk]
set_property IOSTANDARD LVCMOS33 [get_ports fpga_gclk]
set_property PACKAGE_PIN D26 [get_ports reset_n]
set_property IOSTANDARD LVCMOS33 [get_ports reset_n]
set_property PULLUP true [get_ports reset_n]

# --- LEDs (k701/k720 demo 引脚; 板上 8 个 LED 中仅这 4 个有验证映射,
#          本工程 wrapper 只用这 4 个) ---
set_property PACKAGE_PIN A23 [get_ports led_d0]
set_property PACKAGE_PIN A24 [get_ports led_d1]
set_property PACKAGE_PIN D23 [get_ports led_d2]
set_property PACKAGE_PIN C24 [get_ports led_d3]
set_property IOSTANDARD LVCMOS33 [get_ports {led_d0 led_d1 led_d2 led_d3}]
set_property SLEW FAST [get_ports {led_d0 led_d1 led_d2 led_d3}]
