#=============================================================================
# eco_rgmii_phy1.xdc — Kintex7 ECO 板 (XC7K325T-2FFG676C) 1G RGMII PHY1 引脚+时钟约束
# 来源: D:\repo\ECO\udp_hls_eco\xdc\eco_rgmii_phy1.xdc (板上 7/7 PASS 配方),
#       逐字复用; UART 约束 (P4b-7-P6 冻结诊断) 按 udp_hls_eco 原配方重新加入。
#       其余部分逐字同 wrapper_1g.v 时代的 eco_rgmii_phy1.xdc。
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

# --- UART TX (板载 CH340E USB 串口 → PC; k707 demo + udp_hls_eco 配方引脚 A17,
#     P4b-7-P6 冻结态全精度读出; 9600-8N1, LVCMOS33 TTL) ---
set_property PACKAGE_PIN A17 [get_ports uart_txd]
set_property IOSTANDARD LVCMOS33 [get_ports uart_txd]
set_property DRIVE 12 [get_ports uart_txd]
set_property SLEW SLOW [get_ports uart_txd]

# --- LEDs (k701/k720 demo 引脚; 板上 8 个 LED 中仅这 4 个有验证映射,
#          本工程 wrapper 只用这 4 个) ---
set_property PACKAGE_PIN A23 [get_ports led_d0]
set_property PACKAGE_PIN A24 [get_ports led_d1]
set_property PACKAGE_PIN D23 [get_ports led_d2]
set_property PACKAGE_PIN C24 [get_ports led_d3]
set_property IOSTANDARD LVCMOS33 [get_ports {led_d0 led_d1 led_d2 led_d3}]
set_property SLEW FAST [get_ports {led_d0 led_d1 led_d2 led_d3}]

#=============================================================================
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
