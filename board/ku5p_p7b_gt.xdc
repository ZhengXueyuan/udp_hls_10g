#=============================================================================
# ku5p_p7b_gt.xdc -- P7b 10G 构建的引脚约束 (只含 10G 前端 + 与基线相同的周期脚)
#
# 引脚来源 (全部**实测**过, 不抄任何厂商 XDC):
#   · reset_n / led_d0..3 / uart_txd -- 与 ku5p_p6a_t8p0.xdc 同脚同标准
#     (照抄, 不 source: 那个文件里还有 RGMII 的 15 根脚, P7b 设计里**不存在** ⇒
#      直接复用会让每条 set_property 报 `[Vivado 12-4739] No valid object(s) found`
#      并被**静默丢弃**, 而构建脚本正是靠 grep 12-4739 判"约束有没有生效"。)
#   · SFP 控制脚 -- 2026-09-27 三态判别实验的结果 (厂商两份 XDC 都错):
#       SFP1_TX_DIS=C11 SFP1_RX_LOS=B11 SFP2_TX_DIS=D9 SFP2_RX_LOS=C9
#   · GT 参考钟 V7/V6 -- 核心板 Y2 = 156.25MHz 有源晶振 → MGTREFCLK0_225。
#     156.25 × 66 = 10.3125 GHz (**不换晶振这块板做不了 10GBASE-R**)。
#   · GT 串行脚(**故意不约束**): 通道 LOC 由核内 XDC 钉死
#     (`ip_0/synth/pcs64_gt.xdc` = GTHE4_CHANNEL_X0Y4, `ip_1/...` = _X0Y5),
#     串行球号由站点推导 ⇒ 写在这里反而是"第二个来源"。
#
# ⚠️ XDC 只接受 Tcl 子集 (没有 if/foreach/proc) -- 本文件全是平铺的约束命令。
# ⚠️ 需要**已展开设计**的约束 (set_clock_groups) 在 ku5p_p7b_cdc.xdc, 它由构建脚本
#    标 `used_in_synthesis false` 只在实现阶段应用。
#=============================================================================

# ---- PCIe 槽复位 (PERST#) —— 与 P6a/P6e 同脚同标准 --------------------------
set_property PACKAGE_PIN J9  [get_ports reset_n]
set_property IOSTANDARD LVCMOS33 [get_ports reset_n]
set_property PULLUP true [get_ports reset_n]

# ---- GT 参考钟: 核心板 Y2 = 156.25MHz → V7/V6 = MGTREFCLK0_225 --------------
# 核自带的 XDC 也声明了这个钟 (pcs64.xdc), 这里**重新声明**会把它替换成一个具名副本
# (闸 1 实测过这条替换), ⇒ 端口上只有一个时钟对象。
create_clock -period 6.400 -name gtrefclk0 [get_ports gt_refclk_p]
set_property PACKAGE_PIN V7 [get_ports gt_refclk_p]
set_property PACKAGE_PIN V6 [get_ports gt_refclk_n]

# ---- SFP 控制 (TX_DIS 高有效 + 板上 10k 上拉 ⇒ 悬空 = 发射关闭 = 全黑) ------
set_property -dict {PACKAGE_PIN C11 IOSTANDARD LVCMOS33} [get_ports sfp1_tx_dis]
set_property -dict {PACKAGE_PIN D9  IOSTANDARD LVCMOS33} [get_ports sfp2_tx_dis]
set_property -dict {PACKAGE_PIN B11 IOSTANDARD LVCMOS33 PULLTYPE PULLUP} [get_ports sfp1_rx_los]
set_property -dict {PACKAGE_PIN C9  IOSTANDARD LVCMOS33 PULLTYPE PULLUP} [get_ports sfp2_rx_los]

# ---- 状态读出 (与 P6a 逐脚相同) ---------------------------------------------
set_property PACKAGE_PIN AD15 [get_ports uart_txd]
set_property IOSTANDARD LVCMOS25 [get_ports uart_txd]
set_property DRIVE 12 [get_ports uart_txd]
set_property SLEW SLOW [get_ports uart_txd]

set_property PACKAGE_PIN AF14 [get_ports led_d0]
set_property PACKAGE_PIN AF15 [get_ports led_d1]
set_property PACKAGE_PIN AE13 [get_ports led_d2]
set_property PACKAGE_PIN AF13 [get_ports led_d3]
set_property IOSTANDARD LVCMOS25 [get_ports {led_d0 led_d1 led_d2 led_d3}]
set_property SLEW FAST [get_ports {led_d0 led_d1 led_d2 led_d3}]
