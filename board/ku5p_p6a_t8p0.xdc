#=============================================================================
# ku5p_p6a_t8p0.xdc — P6a: KU5P (xcku5p-ffvb676-1-e) 的 1G RGMII 前端 + 64bit 数据面
#   与 K7 的 board/eco_p6_t8p0.xdc **逐项同构**（唯一差异 = create_clock 周期），
#   以便**闸 G 与闸 B 直接对照**（K7 @6.400ns: WNS -0.948 / 647 失败端点）。
# 引脚来源: Demo/XCKU5P_PCIe_DDR4_ETH_aurora_12g/src/PCIe.xdc（厂商 2019.2 工程）
#   ETH 8+3 根由本工程早前实测核对（见 XCKU5PMini/CLAUDE.md 的引脚表）；
#   空闲引脚用厂商的 io_nor[] 总线（LVCMOS25，ball 明确）。
# ⚠️ 与 K7 板的差异（逐条，均由 P6a-T2 实证决定）:
#   ① IOSTANDARD: K7 是 LVCMOS18 → 这里是 **LVCMOS33**（RGMII 在 KU5P 的 bank 86 = HDIO）
#   ② generated clock **去掉 -invert**: K7 前端是 BUFG(~rxc)，US+ 前端是 BUFG(rxc)
#      + IDDRE1 的 IS_CB_INVERTED ⇒ 时钟极性不同（见 util_gmii_to_rgmii_us.v 头注释）
#   ③ **无 fpga_gclk / 无 MMCM / 无 IDELAYCTRL**: US+ 前端零 IDELAY（HDIO 放不了 IDELAYE3，
#      且底板 PHY 的 RXDLY/TXDLY 已搭接为 1，2ns 由 PHY 内部提供）
#   ④ reset_n 接 PCIe 槽的 pcieReset（J9, LVCMOS33）；uart_txd / LED 走 io_nor[]
#=============================================================================

# --- 配置（与 K7 逐字一致）---
set_property CFGBVS VCCO [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN Pullup [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

# --- 时钟 ---
# phy1_rxc: RGMII RX 时钟。1G = 125MHz(8ns) / 闸 G 尖峰 = 156.25MHz(6.4ns)。
# 端口上定义 MASTER 时钟；经 u_rgmii 内 BUFG(bufmr_rgmii_rxc) 成为 gmii_clk，
# 在 BUFG 输出上定义 GENERATED 时钟（**不 -invert**，与 K7 不同）。
# 注意: 实例名 u_rgmii 与 BUFG 名 bufmr_rgmii_rxc 必须与 RTl 一致，否则约束失效。
create_clock -period 8.000 -name phy1_rxc [get_ports phy1_rxc]
create_generated_clock -name gmii_clk     -source [get_ports phy1_rxc] -divide_by 1     [get_pins u_rgmii/bufmr_rgmii_rxc/O]

# --- RGMII (bank 86, HDIO, LVCMOS33) — 厂商 Demo PCIe.xdc 的实测引脚 ---
set_property PACKAGE_PIN D11 [get_ports phy1_rxc]
set_property PACKAGE_PIN B10 [get_ports {phy1_rxd[0]}]
set_property PACKAGE_PIN E11 [get_ports {phy1_rxd[1]}]
set_property PACKAGE_PIN E10 [get_ports {phy1_rxd[2]}]
set_property PACKAGE_PIN D10 [get_ports {phy1_rxd[3]}]
set_property PACKAGE_PIN A10 [get_ports phy1_rxctl]
set_property PACKAGE_PIN J10 [get_ports phy1_txc]
set_property PACKAGE_PIN F9  [get_ports {phy1_txd[0]}]
set_property PACKAGE_PIN F10 [get_ports {phy1_txd[1]}]
set_property PACKAGE_PIN K9  [get_ports {phy1_txd[2]}]
set_property PACKAGE_PIN K10 [get_ports {phy1_txd[3]}]
set_property PACKAGE_PIN G9  [get_ports phy1_txctl]
set_property IOSTANDARD LVCMOS33 [get_ports {phy1_rxc phy1_rxctl phy1_txc phy1_txctl}]
set_property IOSTANDARD LVCMOS33 [get_ports {phy1_rxd[*] phy1_txd[*]}]
set_property SLEW FAST [get_ports {phy1_txd[*] phy1_txctl phy1_txc}]

# --- 复位 / 板级调试引脚 ---
# reset_n: PCIe 槽的 pcieReset（厂商 Demo 用它做 BD 的复位，ACTIVE_LOW ⇒ 与 reset_n 同极性）
set_property PACKAGE_PIN J9  [get_ports reset_n]
set_property IOSTANDARD LVCMOS33 [get_ports reset_n]
set_property PULLUP true [get_ports reset_n]
# uart_txd: KU5P 板上**没有 UART**（见 XCKU5PMini/CLAUDE.md），这里用厂商的 io_nor[] 空闲脚
# 引出（纯观测槽：先留线，后续按需求换 PCIe/XDMA 通道）
set_property PACKAGE_PIN AD15 [get_ports uart_txd]
set_property IOSTANDARD LVCMOS25 [get_ports uart_txd]
set_property DRIVE 12 [get_ports uart_txd]
set_property SLEW SLOW [get_ports uart_txd]
# LEDs: 同样走 io_nor[]（KU5P 的板载 LED 映射未核，避免误驱动）
set_property PACKAGE_PIN AF14 [get_ports led_d0]
set_property PACKAGE_PIN AF15 [get_ports led_d1]
set_property PACKAGE_PIN AE13 [get_ports led_d2]
set_property PACKAGE_PIN AF13 [get_ports led_d3]
set_property IOSTANDARD LVCMOS25 [get_ports {led_d0 led_d1 led_d2 led_d3}]
set_property SLEW FAST [get_ports {led_d0 led_d1 led_d2 led_d3}]


# P4c 时序修复 (步骤 2, 2026-09-12): retx_ram 读地址/环地址网强制复制
# 依据 (impl 报告 wrapper_p4_timing_summary_routed.rpt + report_timing -unique_pins):
#   300/300 失败终点全部同源: u_tcp_tx/FSM_sequential_state_reg[1]_replica →
#   组合深锥 (scan_id → retx_hi → rb_snd_nxt → nbeats/ring_rem → r_tap_seq → rpe)
#   → u_retx/g_byte[*] 的 RAMB36 地址/使能脚 (282 ADDRBWRADDR + 16 ENBWREN + 2 WEA)。
#   最差网 rpe[11] 扇出 128 (全为 BRAM 宏负载), 布线 2.43ns = 该路径 7.5ns 的 1/3。
#   负载全为宏原语的网被 phys_opt 扇出优化直接排除 (log: Physopt 32-1132 / 32-572),
#   FORCE_MAX_FANOUT 是其官方强制开关 (取值 < 负载数即触发复制), 不改变逻辑语义。
# 取值: 地址网 32 (2 bank x 8 lane x 16 深级联 = 128 脚/网, 期望 >= 4 份就近布局);
#       锥内高扇出网 64 (各 ~50..150 负载)。
# 注: 写地址网 (wa_e_r/wa_o_r) 综合已按 RTL max_fanout=64 自行复制 (384/1152 网),
#     读侧此前的 1 拍读延迟合同 (tcp_tx_frame S_RING) 未做任何改动。
#=============================================================================
# 注 1: XDC 禁用 foreach/if 等 Tcl 控制结构 (Designutils 20-1307)。实测: 循环会被
#       静默忽略 → 属性 0 个生效; 故按族展开为独立 set_property 语句。
# 注 2: wrapper_1g / wrapper_echo 无 retx 层次, 这 5 条会报 CRITICAL WARNING
#       [Common 17-55] 'set_property' expects at least one object (非致命, 不中断流程)。
set_property FORCE_MAX_FANOUT 32 [get_nets -hier -quiet -filter {NAME =~ "*u_retx/rpe*"}]
set_property FORCE_MAX_FANOUT 32 [get_nets -hier -quiet -filter {NAME =~ "*u_retx/r_tap_seq*"}]
set_property FORCE_MAX_FANOUT 64 [get_nets -hier -quiet -filter {NAME =~ "*u_retx/ring_rem*"}]
set_property FORCE_MAX_FANOUT 64 [get_nets -hier -quiet -filter {NAME =~ "*u_retx/nbeats*"}]
set_property FORCE_MAX_FANOUT 64 [get_nets -hier -quiet -filter {NAME =~ "*u_retx/rb_snd_nxt*"}]
