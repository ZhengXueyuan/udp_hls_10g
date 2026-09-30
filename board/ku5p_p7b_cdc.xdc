#=============================================================================
# ku5p_p7b_cdc.xdc -- P7b 的跨时钟域约束 (四域, 两两异步)
#
# ⚠️⚠️ **必须由构建脚本标 `used_in_synthesis false`** (只在实现阶段应用)。
#   理由 (本工程已实测踩过): XDC 在**综合前**解析, 那一刻 create_clock 还没生效、
#   PCS/XDMA 还是黑盒 ⇒ `get_clocks` 拿到空对象 ⇒ Vivado 只报一条
#     `CRITICAL WARNING [Vivado 12-4739] set_clock_groups: No valid object(s) found`
#   然后**静默丢弃**该约束 (构建照样过, 但 report_clock_interaction 里两个域仍是
#   "Timed (unsafe)")。⇒ 施工纪律: **在 impl 日志里 grep `12-4739`; 命中 = 约束没生效**。
#
# P7b 有**四个**互不相关的时钟源 (物理来源各不相同):
#   · `sys_clk_100` (核心板 Y1 100.000000MHz 有源晶振, T25/U25) —— 它的派生:
#        - `clk_in_100` (BUFG)  = PCS 的 `dclk` (DRP/复位控制域, 100MHz)
#        - MMCM 输出            = `dp_clk` (156.25MHz 数据面)
#     ⚠️ 这两个**同源** ⇒ 留在**同一组**里 (它们之间的路径应当被当作同步路径分析;
#        实际存在的跨域连接只有 PCS `stat_*` 的每位 2FF, 那是电平同步器)。
#   · `pcie_axi_aclk` (金手指 100MHz 参考钟 → XDMA 内部 ≈250MHz) —— 快照/寄存器域
#   · `gtrefclk0` (核心板 Y2 156.25MHz, V7/V6) —— 它的派生:
#        - `txoutclk_out[0]` = PCS `tx_mii_clk`  (MAC TX 域)
#        - `rxoutclk_out[0]` = PCS `rx_clk_out`  (CDR **恢复**钟; MAC RX 域)
#     ⚠️ 恢复钟**物理上**与 txoutclk 无关, 即使标称同频 —— 这正是本组要声明异步的原因
#        (闸 1 实测: `rxoutclk_out` 是从到来的数据里 CDR 恢复的)。
#   · `phy1_rxc` **不存在** (P7b 没有 RGMII) ⇒ **绝不能引用**它, 否则就是 12-4739。
#
# 域之间的跨域连接 (各有专门的同步器, 见 wrapper 与 P6B_SPEC §3):
#   ① `u_rxcdc` / `u_txcdc` 两个异步 FIFO (灰码指针 2FF, ASYNC_REG)
#   ② 五条相干快照链: snap_seq 的 FE/DP 两束 + P7b 的 p7bfe/p7bdp/tx 三束 (toggle 握手)
#   ③ PCS 状态位的**每位 2FF** (dclk/恢复域 → dp 域)
#   ④ `wl_last_lat` 的 1 位触发同步器, `tx_fe_clk` 活性 toggle 同步器
# 多比特路径的稳定性由**协议**保证 (FIFO 灰码 / 握手后 hold 稳定) ⇒ 标准做法就是
# 把它们整体从时序分析里摘出去 —— 也就是本文件。
#
# ⚠️ 若某个 get_clocks 拿到空对象 (症状 = 构建日志里 12-4739), 退路是按引脚取:
#      -group [get_clocks -of_objects [get_pins u_clkgen/u_mmcm/CLKOUT0]]
#=============================================================================
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks sys_clk_100] \
    -group [get_clocks -include_generated_clocks pcie_axi_aclk] \
    -group [get_clocks -include_generated_clocks gtrefclk0]
