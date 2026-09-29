#=============================================================================
# ku5p_p6b_sysclk.xdc — P6b: 数据面时钟源 (核心板 Y1 100MHz 差分有源晶振)
#   只放**这一根时钟**: RGMII / LED / uart / reset_n 仍由 ku5p_p6a_t8p0.xdc 原样提供
#   (不复制、不 source, 以免两份 XDC 悄悄分叉 —— P6a 是闸 G 的基线)。
#
#   器件事实 (P6B_SPEC §8.2, 全部有实测出处):
#     · Y1 = SG7050VAN-100.000000M-KEGA3, 输出网络 SYS_CLK_P/N
#       (原理图 PDF 出图实测: 位号 Y1 与完整型号同框; 见 P6B_SPEC §8.2 的复跑命令)
#     · ball T25/U25 = IO_L14P_T2L_N2_GC_A04_D20_65, BANK=65, IS_GLOBAL_CLK=1,
#       DIFF_PAIR_PIN 互为对脚; 所在 CLOCK_REGION = X0Y1 **有 MMCM** (MMCM_X0Y1)
#       ⇒ 可直接驱动 MMCM (board/ku5p_probe/clkgen_p6b/pin_probe.log 的原始读数)
#     · IOSTANDARD: **`DIFF_SSTL12`** —— ⚠️ 这一行是 **TL 裁决**过的, 不要按"厂商 XDC
#       怎么写"改回去 (厂商 Demo/.../src/PCIe.xdc 写的是 `DIFF_POD12_DCI`)。
#       裁决依据 (时钟发生器 agent 实测 + TL 判定; 全部原始证据在
#       `board/ku5p_probe/clkgen_p6b/README.md` 与同目录的变体报告里 —— **别重造**):
#         板上是 0.1uF 交流耦合 + 1k/1k 分压到 VDD1.2 ⇒ 输入共模 = **0.600V = VCCO/2**。
#         ds922 Table 14: `DIFF_SSTL12` 的 VICM = 0.450/**0.600**/0.750 ⇒ 正中 typ ✅;
#         ds922 Table 15: `DIFF_POD12` 的 VICM = 0.76/0.84/0.92 ⇒ 0.600 **低于下限**
#         ⇒ 厂商的写法在手册范围内**不成立**。`DIFF_SSTL12` 无 DCI ⇒ 不需要 DCIRESET,
#         且板上已有外部 100Ω 端接 (R58)。探针构建实测该标准 place/route/DRC 全过。
#       ⚠️ **反方证据 (诚实留档, 不删)**: 厂商位流里 MIG 的 `sys_clk` 就是这一对脚,
#          而且是**实测跑通过**的 —— 所以"POD12 完全不能工作"这句话不能下; 本裁决只主张
#          "手册范围内 SSTL12 才是对的 typ 工作点"。
#       ⚠️ **退路**: 若板级出现 MMCM 失锁 / `SNAP_STATUS[6]=0`, **第一件事**是把这一行
#          改回 `DIFF_POD12_DCI` 重建 (变体报告里有那一档的读数)。
#       (历史注: 本条曾写"HP bank 的 LVDS 要求 VCCO=1.8V 所以用不了" —— 后半句不准确:
#        ds922 Table 19 Note 1 允许 input-only LVDS 走非 1.8V VCCO; 本板不用它的真正原因
#        是 0.600V 压在下界之外。)
#
#   ⚠️ 周期必须与 wrapper 里 clk_gen_p6b 的 CLKIN1_PERIOD_NS(10.000) **同值**;
#      156.25MHz 的输出时钟**不要手写 create_generated_clock** —— MMCME4_BASE 的输出
#      由 Vivado 依据上述参数**自动推导**(结果恰为 6.400ns), 手写反而会冲突
#      (两条同周期时钟 / CRITICAL WARNING)。P6B_SPEC §8.3 有这条的完整论证。
#=============================================================================

create_clock -period 10.000 -name sys_clk_100 [get_ports sys_clk_p]

set_property PACKAGE_PIN T25 [get_ports sys_clk_p]
set_property PACKAGE_PIN U25 [get_ports sys_clk_n]
set_property IOSTANDARD DIFF_SSTL12 [get_ports {sys_clk_p sys_clk_n}]

# 说明: gmii_clk / RGMII 相关的约束**不在本文件** —— 那是 ku5p_p6a_t8p0.xdc 的事
#       (基线不许分叉)。本文件也不写 set_clock_groups: 见 ku5p_p6b_cdc.xdc。
