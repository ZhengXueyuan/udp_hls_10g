#=============================================================================
# ku5p_p6b_cdc.xdc — P6b 的跨时钟域约束 (三组 set_clock_groups -asynchronous)
#
# ⚠️⚠️ **本文件必须 `set_property used_in_synthesis false`** (在 build tcl 里设)。
#   理由 (本工程已实测踩过一次, 见 ku5p_p6e_cdc.xdc 头注释与 `board/p6e_verify/`):
#   XDC 是在**综合前**解析的, 那一刻 create_clock 还没生效、XDMA/MMCM 还是黑盒 ⇒
#   `get_clocks` 拿到**空对象** ⇒ Vivado 只报一条
#     `CRITICAL WARNING [Vivado 12-4739] set_clock_groups: No valid object(s) found`
#   然后**静默丢弃**该约束 (构建照样过, 但 report_clock_interaction 里两个域仍是
#   "Timed (unsafe)")。⇒ 施工时**必须在 impl 日志里 grep `12-4739`; 命中 = 约束没生效**。
#
#   P6b 有**三个**互异步的域, 物理源各不相同:
#     · gmii_clk       ← 底板 RTL8211E 的 25MHz 无源晶体恢复出的 RXC (125MHz)
#     · sys_clk_100/MMCM 输出 (dp_clk 156.25MHz)
#                      ← 核心板 Y1 的 100.000000MHz **有源**晶振 (T25/U25)
#     · pcie_axi_aclk  ← 金手指的 100MHz PCIe 参考钟 (XDMA 内部生成, ≈250MHz)
#   两两异步:
#
#   域之间的跨域连接只有三处 (各有专门的同步器, 见 P6B_SPEC §3):
#     ① u_rxcdc / u_txcdc 两个异步 FIFO (灰码指针 2FF, ASYNC_REG)
#     ② u_snap_fe / u_snap_dp 两个相干快照 CDC (toggle 握手, ASYNC_REG)
#        + snap_seq 的链式触发 (req 1 拍脉冲跨过去, 回送走 valid)
#     ③ wl_last_lat 的 1 位触发同步器 (DP→FE, ASYNC_REG)
#   多比特路径的稳定性由**协议**保证 (FIFO 灰码 / 握手后 hold 稳定), 所以标准做法就是
#   把它们整体从时序分析里摘出去 —— 也就是本文件。
#
#   ⚠️ 若某个 get_clocks 拿到空对象 (症状 = 构建日志里 12-4739), 退路是改成按引脚取:
#        -group [get_clocks -of_objects [get_pins u_clkgen/u_mmcm/CLKOUT0]]
#=============================================================================
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks phy1_rxc] \
    -group [get_clocks -include_generated_clocks sys_clk_100] \
    -group [get_clocks -include_generated_clocks pcie_axi_aclk]
