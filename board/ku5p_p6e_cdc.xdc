#=============================================================================
# ku5p_p6e_cdc.xdc — P6e 的跨时钟域约束 (只有一条 set_clock_groups)
#   为什么单独一个文件: 见 ku5p_p6e_pcie.xdc 末尾的说明 —— 综合前解析 XDC 时
#   create_clock 还没生效 ⇒ 本约束会被**静默丢弃** (只留一条 CRITICAL WARNING)。
#   构建脚本对本文件设 `used_in_synthesis false` ⇒ 只在实现阶段应用 ⇒ 两个时钟都已存在。
#
#   背景: gmii_clk (来自 phy1_rxc = 底板 PHY 的 25MHz 晶振) 与 pcie_axi_aclk
#   (来自金手指 100MHz 参考钟, XDMA 内部生成) **不同源**, 它们之间只有 snap_cdc 一处连接:
#     · 三条同步器链 (toggle/ack/复位) 已打 ASYNC_REG ⇒ Vivado 自己的 CDC 报告把它们
#       认成 CDC-3 / CDC-9 (Info, 无违例);
#     · hold_b → dout_a 是**多比特**路径, 它的稳定由**握手协议**保证 (锁存后 hold_b 至少
#       稳定 3 个 axi 拍才被采样) ⇒ 由 CDC-15 (clock-enable controlled) 识别,
#       靠 set_clock_groups 把它从时序分析里摘出去才是标准做法。
#   ⚠️ 实测留档 (BUILD_ID=2 那位流): 这条约束当时**没有生效** (解析时机问题), 两个域仍是
#      "Timed (unsafe)"。但那一版仍然 0 失败端点、CDC 报告无违例 ⇒ 功能无影响;
#      本文件让下一版构建真正生效 (并会在 report_clock_interaction 里变成异步组)。
#=============================================================================
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks phy1_rxc] \
    -group [get_clocks -include_generated_clocks pcie_axi_aclk]
