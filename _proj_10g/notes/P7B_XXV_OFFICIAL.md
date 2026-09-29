# P7B — 官方 `xxv_ethernet 5.0` 在 `xcku5p-ffvb676-1-e` 上的可构建性 + 接口合同

日期 2026-09-29。探针工程 `D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\xxv_probe\`（本次新建，未动仓库其它文件）。
**没有给板子烧任何东西，没有碰 QSPI，没有 git 写操作，license 文件全程在位（只读）。**

---

## 0. 一句话结论 —— **分 CORE：PCS-only 能出位流；MAC+PCS 不能**

在 `xcku5p-ffvb676-1-e` 上，凭本机 `C:\AMDDesignTools\2025.2\data\ip\core_licenses\Xilinx.lic`
（`License_Type:Design_Linking`，`permanent uncounted`）：

| 检查点 | **CORE = Ethernet PCS/PMA 64-bit** | **CORE = Ethernet MAC+PCS/PMA 64-bit** |
|---|---|---|
| IP 级 OOC 综合 | ✅ 过（`synth_design completed successfully`，`.dcp` 已生成） | ✅ 过（同） |
| 顶层综合 | ✅ 过（100%） | ✅ 过（100%） |
| 实现 opt/place/route/phys_opt | ✅ 过（WNS +2.283 / 0 失败端点） | ✅ 过（WNS +2.582 / 0 失败端点） |
| **`write_bitstream`（出位流）** | ✅ **过** —— `Bitgen Completed Successfully`，产出 **`probe_pcs64_top.bit` = 15,431,266 B**，sha256 `86fe9c7b54f652129ebf19750601f5885712f966670e6e54a0154f2b1ce6a905` | ❌ **不过 —— license 检查拦下** |

⇒ **核心问题的答案（二元）：能，但只有 `CORE = Ethernet PCS/PMA 64-bit` 变体能出位流。
`CORE = Ethernet MAC+PCS/PMA 64-bit` 变体出不了位流 —— 被 license 分级拒绝。**

### 0.1 PCS-only：**过**（原文行）

`pcs64/pcs64.runs/impl_1/runme.log`
```
:798 Command: write_bitstream -force probe_pcs64_top.bit
:801 CRITICAL WARNING: [Vivado 12-1790] Evaluation License Warning: This design contains one or more IP cores that use separately licensed features. ...
:803 Evaluation cores found in this design:
       IP core 'pcs64' (xxv_ethernet_v5_0_2) was generated with multiple features:
           IP feature 'xxv_eth_basekr@2025.05' was enabled using a design_linking license.
           IP feature 'xxv_eth_mac_pcs@2025.05' was enabled using a design_linking license.
           IP feature 'xxv_tsn_802d1cm@2025.05' was enabled using a design_linking license.
:824 INFO: [Vivado 12-1842] Bitgen Completed Successfully.
:826 125 Infos, 11 Warnings, 2 Critical Warnings and 0 Errors encountered.
:827 write_bitstream completed successfully
```
**注意**：`[Vivado 12-1790]` 是 **Critical Warning**（"evaluation features ... will cease to function
after a certain period of time"），但它**没有拦住位流** —— 上面三行是同一段日志里的连续输出，
`Bitgen Completed Successfully` 与 `0 Errors` 是硬的。
⇒ 位流**已经生成**；**没有上板烧**（纪律要求），所以"能生成" ≠ "板上能用"，见 U13。

### 0.2 MAC+PCS：**不过**（原文行，且在 XDC 修正后**复现**过两次）

`macpcs64/macpcs64.runs/impl_1/runme.log` 尾部：
```
Command: write_bitstream -force probe_macpcs64_top.bit
Attempting to get a license for feature 'Implementation' and/or device 'xcku5p'
INFO: [Common 17-349] Got license for feature 'Implementation' and/or device 'xcku5p'
INFO: [Common 17-83] Releasing license: Implementation
write_bitstream failed
ERROR: [Common 17-69] Command failed: This design contains one or more cells for which bitstream generation is not permitted:
DUT/inst/i_macpcs64_top_0/i_macpcs64_CORE (<encrypted cellview>)
If a new IP Core license was added, in order for the new license to be picked up, the current netlist needs to be updated by resetting and re-generating the IP output products before bitstream generation.
The following IP(s) require licenses greater than a Design Linking license to generate bitstream:
xxv_eth_mac_pcs
```
**这不是我的探针 bug 造成的**：第一次跑时我的 XDC 文件名写错（设计零约束），第二次把 XDC 修好、
工程约束正常、opt/place/route 全部干净通过之后，**位流阶段给出的是同一条消息**（两次都到 83.33%，
都停在 `write_bitstream`）。**⇒ 可复现、与 RTL/约束无关的 license 分级拒绝。**

### 0.3 对项目路线的含义

- ✅ **好消息：`CORE = Ethernet PCS/PMA 64-bit` 这条路线在本机是通的、能出位流的。**
  也就是说：**10GBASE-R 的 PCS/PMA（加扰、块锁、对齐、XGMII、gearbox 控制）可以用官方核拿到，
  而且板上可跑**（位流已产出；上板验证待做）。**核心问题的答案是"能"。**
- ❌ **坏消息：`MAC+PCS/PMA` 变体拿不到位流** —— 即官方 MAC（IFG/前导码/FCS 全包）这条路被 license 卡死。
  要解锁只能拿到**高于 Design Linking** 的 `xxv_eth_mac_pcs` license（工具自己给的 resolution 是
  reset + regenerate IP output products，**不需要改任何 RTL/约束**）。
- ✅ **`Xilinx.lic` 里所有 `INCREMENT` 的 `VENDOR_STRING` 都是 `License_Type:Design_Linking`**
  ⇒ 换用 `ten_gig_eth_mac` / `l_eth_mac_pcs` / `cmac` 等别特性绕不过去（同一档）。
- ✅ 对照：我们的 `gt_10gbr`（`gtwizard_ultrascale`，免费核）也能出位流，且板级已验收
  （BER 上界 4.997×10⁻¹³，`_proj_10g/reports/p7a_bitstream_sha256.txt`）。

**⇒ 这直接把 §6 的架构选择从"二选一"压成一条：走 A（PCS-only）+ 自写 MAC，因为 B 出不了位流。**
（下面 §6 保留了 A/B 的技术比较，因为若将来拿到更高 license，B 仍然更省事。）

⚠️ **两个失败模式必须分开记**（本项目历史上吃过"把不同档的失败混为一谈"的亏）：
| 失败模式 | 触发条件 | 原文关键词 | 本次是否出现 |
|---|---|---|---|
| ① 完全没有 license | license 文件缺失 | `Fatal Error. License Check failed for secure IP for feature 'xxv_eth_mac_pcs@2025.05'. Exiting Synthesis.` | **否**（只在 `_lic/syn_stdout.txt:868`，且建在 `xc7k70tfbv676-1`，不引为 KU5P 结论） |
| ② license 在、级别不够 | Design Linking 级 + MAC 变体 | `require licenses greater than a Design Linking license to generate bitstream` | **是（MAC 变体）** |
| ③ license 级别够（PCS 变体） | Design Linking 级 + PCS-only | `Bitgen Completed Successfully` | **是（PCS 变体）** |

实现阶段还有几次失败，但**原因与 license 无关**，都是我们探针自己的问题（§5.4 逐条根因）。

---

## 1. License 结论（最关键的一段）

### 1.1 license 文件实况

`C:/AMDDesignTools/2025.2/data/ip/core_licenses/` 下只有两个文件：

| 文件 | 大小 | 说明 |
|---|---|---|
| `Xilinx.lic` | 7445 B | MD5 `9bab9853d542567cbae9e2152f04223e`，所有 `INCREMENT` 的版本号都是 `2025.11`、`permanent uncounted` |
| `XilinxFree.lic` | 5704 B | 只覆盖**老器件**免费核 |

`Xilinx.lic` 的 `INCREMENT` 特性名（只列名字，无 key/签名/hostid）：

```
axi_usb2_device can canfd cmac cmac_an_lt cmac_usplus cpri dcmac displayport dprx dptx
eth_avb_endpoint interlaken jesd204 l_eth_basekr l_eth_baser l_eth_mac_pcs mrmac nvmehc
pci32 pci64 roe_framer spdif srio_phylog_io ten_gig_eth_mac ten_gig_eth_pcs_pma_basekr
tri_mode_eth_mac tsn_bridged_endpoint_eth_mac tsn_endpoint_eth_mac usxgmii_mac_pcs
v_hdmi v_hdmi1 xxv_eth_basekr xxv_eth_mac_pcs xxv_tsn_802d1cm
```
（全部 `2025.11`、`VENDOR_STRING=...;ipman,<name>,ip,permanent,_0_0_0`、`START=13-Nov-2025`）

`XilinxFree.lic` 只覆盖：`PCIE_BLK_PLUS(_classic)` `RGB2YCRCB(_classic)` `S6_PCIE(_classic)`
`TC(_classic)` `V4_EMAC(_classic)` `V5_EMAC(_classic)` `V6_EMAC(_classic)` `V6_PCIE(_classic)`
`XAUI(_classic)` `YCRCB2RGB(_classic)` `ten_gig_eth_pcs_pma 2012.04`。
⇒ **`XilinxFree.lic` 对 `xxv_ethernet` 毫无贡献**，满足它的一定是 `Xilinx.lic`。

⚠️ **中途插播的一个环境事实（已核实并需要单列）**：本机确实有**两棵** Vivado 安装树，两边都有
`data/ip/core_licenses/`：
- `C:/AMDDesignTools/2025.2/data/ip/core_licenses/`
- `C:/AMDDesignTools/2025.2/Vivado/data/ip/core_licenses/`

**但这不是两个不同的 license 源 —— `Vivado/data` 是一个符号链接，指向 `../data`：**
```
$ ls -la "C:/AMDDesignTools/2025.2/Vivado/" | grep ' data'
lrwxrwxrwx 1 zhxue 197609  7 Jun 27 23:29 data -> ../data
$ powershell -NoProfile -Command "(Get-Item 'C:\AMDDesignTools\2025.2\Vivado\data').LinkType; ...Target"
SymbolicLink
..\data
```
旁证：两边的 `Xilinx.lic` `md5` 相同（`9bab9853d542567cbae9e2152f04223e`），
`ls -i` 的 inode 也相同（`1125899907768211`）。
**⇒ 结论：磁盘上只有一份 `core_licenses/`；"两棵树 license 解析规则不同"这个假设不成立，
也不存在"到底靠哪个文件解锁"的歧义。**

### 1.2 环境里的 license 相关变量

```
S1_ENV_XILINXD_LICENSE_FILE = <unset>
S1_ENV_XILINX_LICENSE_FILE  = <unset>
S1_ENV_LM_LICENSE_FILE      = <unset>
S1_LIC_MAIN_EXISTS = 1   (C:/AMDDesignTools/2025.2/data/ip/core_licenses/Xilinx.lic)
S1_LIC_HIDDEN      = 0   (没有 .HIDDEN 残留 —— license 全程在位)
```
⇒ 满足 license 的**不是**环境变量，而是 Vivado 自己的 `data/ip/core_licenses/` 内建目录。
（`get_param xilinx.lic.file` / `xilinx.lic.order` / `xilinx.lic.handle` **在本机 2025.2 不存在**：
`ERROR: [Common 17-153] Param 'xilinx.lic.handle' does not exist` —— 无法用 get_param 回读搜索路径。）

**⚠️ 原文抄回部分（如实报告）**：`xxv_ethernet` 成功 checkout 时，**日志里不打印 license 搜索路径**。
我把 `logs/s*_stdout.txt`、两个工程的 `*.runs/*/runme.log` 全部按
`license / .lic / flexlm / XILINXD_LICENSE_FILE` 扫过，命中的**只有**下面这几行，没有路径行：

```
S4_LICLINE S_pcs64 runme.log:18 : Attempting to get a license for feature 'Synthesis' and/or device 'xcku5p'
S4_LICLINE S_pcs64 runme.log:19 : INFO: [Common 17-349] Got license for feature 'Synthesis' and/or device 'xcku5p'
S4_LICLINE S_pcs64 runme.log:37 : INFO: [Common 17-83] Releasing license: Synthesis
```
⇒ "是哪个文件满足的" 这一条**只有逻辑证据、没有日志原文路径行**：
① 两个 core_licenses 目录是同一个 inode（上面）；② `XilinxFree.lic` 不含任何 `xxv_*`；
③ `USED_LICENSE_KEYS` 点名 `xxv_eth_mac_pcs@2025.05 / xxv_eth_basekr@2025.05 / xxv_tsn_802d1cm@2025.05`
（`Xilinx.lic` 里三者都在）。**这一条我列为"逻辑闭环、缺日志原文"，见 §7 未核实清单 U1。**

### 1.3 IP 自己声明的 license 需求（`USED_LICENSE_KEYS` 原文）

```
{implementation {xxv_eth_mac_pcs@2025.05 design_linking} {xxv_eth_basekr@2025.05 design_linking} {xxv_tsn_802d1cm@2025.05 design_linking}}
{simulation     {...同上...}} {synthesis {...同上...}}
{changelog      {...同上...}} {instantiation_template {...同上...}}
```
（`logs/s2_config_stdout.txt`，`pcs64` 与 `macpcs64` 两处一致）

### 1.4 三个检查点的原文行（① ② 过；③ 分 CORE）

**检查点 ①：IP 级 OOC 综合（第一次出现 design_linking 强制点的位置）**

`pcs64/pcs64.runs/pcs64_synth_1/runme.log`
```
:16 Command: synth_design -top pcs64 -part xcku5p-ffvb676-1-e -incremental_mode off -mode out_of_context
:19 INFO: [Common 17-349] Got license for feature 'Synthesis' and/or device 'xcku5p'
:634 INFO: [Common 17-83] Releasing license: Synthesis
:635 223 Infos, 6 Warnings, 0 Critical Warnings and 0 Errors encountered.
:636 synth_design completed successfully
```
`macpcs64/macpcs64.runs/macpcs64_synth_1/runme.log`
```
:19 INFO: [Common 17-349] Got license for feature 'Synthesis' and/or device 'xcku5p'
:501 INFO: [Common 17-83] Releasing license: Synthesis
:502 230 Infos, 6 Warnings, 0 Critical Warnings and 0 Errors encountered.
:503 synth_design completed successfully
```
另外两处辅助证据（说明加密 RTL 确实被展开，而不是被跳过）：
```
pcs64_synth_1/runme.log:  INFO: [Synth 8-6157] synthesizing module 'pcs64_wrapper' [.../xxv_ethernet_v5_0_2/pcs64_wrapper.v:63]
pcs64_synth_1/runme.log:  INFO: [Synth 8-6157] synthesizing module 'pcs64_common_wrapper' [...]
pcs64_synth_1/runme.log:  INFO: [Synth 8-6157] synthesizing module 'pcs64_ultrascale_tx_userclk' [...]
pcs64_synth_1/runme.log:  INFO: [Common 17-1381] The checkpoint '.../pcs64_synth_1/pcs64.dcp' has been generated.
pcs64_synth_1/runme.log:  INFO: [Coretcl 2-1648] Added synthesis output to IP cache for IP pcs64, cache-ID = 4a1e32638b86ef16
pcs64_synth_1/runme.log:  INFO: [Opt 31-441] Inserted BUFG_GT_SYNC ... for BUFG_GT inst/refclk_bufg_gt_i
pcs64_synth_1/runme.log:  INFO: [Project 1-111] ... RAM32M => RAM32M (RAMD32(x6), RAMS32(x2)): 12 instances
```

**检查点 ②：顶层综合**
```
pcs64/pcs64.runs/synth_1/runme.log:    Synthesis finished with 0 errors, 0 critical warnings and 1 warnings.
macpcs64/macpcs64.runs/synth_1/runme.log:22  INFO: [Common 17-349] Got license for feature 'Synthesis' and/or device 'xcku5p'
macpcs64/macpcs64.runs/synth_1/runme.log:251 Synthesis finished with 0 errors, 0 critical warnings and 1 warnings.
macpcs64/macpcs64.runs/synth_1/runme.log:270 synth_design completed successfully
```
（`S4_SYNTH_PROGRESS = 100%` ×2，`S4_IP_IS_LOCKED = 0` ×2）

**检查点 ③：实现 + 位流** —— 见 §0.1 / §0.2。摘要：
- **PCS-only：opt/place/route/phys_opt 全过，`write_bitstream completed successfully`，位流已产出。**
- **MAC+PCS：opt/place/route/phys_opt 全过，`write_bitstream` 被 license 拦下。**
- 中间几次失败与 license 无关（我自己的探针 bug），根因在 §5.4。

### 1.5 关键字扫描结果（决定性检查点）

对 `logs/s4_build_stdout.txt`、`logs/s5_*_stdout.txt` + 全部 `*.runs/*/runme.log` 扫
`License Check failed` / `secure IP` / `xxv_eth_mac_pcs` / `Internal_bitstream` / `Fatal Error` /
`evaluation` / `timeout` / `will stop working` / `expire`：

- **`License Check failed` —— 0 命中**（`Exiting Synthesis` 也是 0）
- `secure IP` —— 0 命中
- `Internal_bitstream` —— 0 命中
- `Fatal Error` —— 0 命中
- `xxv_eth_mac_pcs` 的命中来自三处：
  **(a)** `USED_LICENSE_KEYS` 属性打印（正常申报，两个工程都有）；
  **(b)** MAC 变体位流阶段的 `The following IP(s) require licenses greater than a Design Linking
  license to generate bitstream: xxv_eth_mac_pcs`（**MAC 变体的拦阻点**）；
  **(c)** `[Vivado 12-1790]` 里的 `IP feature 'xxv_eth_mac_pcs@2025.05' was enabled using a design_linking license`
  （两个工程都有，但**PCS 变体照样出了位流**）。
- ✅ **`evaluation` 有命中（`[Vivado 12-1790] Evaluation License Warning`），两个工程都有** ——
  **但它是 Critical Warning，PCS 变体带着它照样 `Bitgen Completed Successfully` / `0 Errors`。**
  ⇒ **不能把这条 warning 当作"出不了位流"的判据**；真正的判据是 `[Common 17-69] ... not permitted`
  那条 ERROR（只在 MAC 变体出现）。
- `timeout` / `will stop working` / `expire` —— 0 命中（除了 12-1790 里那句笼统的
  "will cease to function after a certain period of time"，**没有任何具体日期/期限**）。

> 对照（**只作原文对照，不作 KU5P 结论**）：`_lic/syn_stdout.txt:868` 在 **license 被藏起来** 时有
> `Fatal Error. License Check failed for secure IP for feature 'xxv_eth_mac_pcs@2025.05'. Exiting Synthesis.`
> —— 那是"**完全没 license**"的失败模式（连综合都进不去），本次在 KU5P + `-1` + license 在位下**不存在**。
> （那条旧证据建在 `xc7k70tfbv676-1` 上，不引为 KU5P 依据。）
> **⚠️ 顺带一条对旧结论的修正线索**：那次 license-absent 实验里，`macpcs64` 打了 Fatal Error，
> 而 **`pcs64` 段没有打**（`_lic/syn_stdout.txt:59` SYN_IS_LOCKED → `:772` SYN_SYNTH_IP rc=0 → `:776` SYN_END pcs64，
> 中间没有 Fatal 行）。这与本次"PCS 变体对 license 要求更低"的观察**方向一致**，
> 但那次是错的器件，只能当线索，见 U14。

---

## 2. 探针工程的配置（这是"我们真正要用的"配置）

`tcl/s2_config.tcl`，两个独立工程 `xxv_probe/pcs64/` 与 `xxv_probe/macpcs64/`，器件 `xcku5p-ffvb676-1-e`。

```
CONFIG.CORE                 = Ethernet PCS/PMA 64-bit        (另一个工程 = Ethernet MAC+PCS/PMA 64-bit)
CONFIG.LINE_RATE            = 10
CONFIG.CLOCKING             = Asynchronous
CONFIG.BASE_R_KR            = BASE-R
CONFIG.GT_REF_CLK_FREQ      = 156.25
CONFIG.GT_TYPE              = GTY
CONFIG.INCLUDE_SHARED_LOGIC = 1
CONFIG.GT_GROUP_SELECT      = Quad_X0Y1
```
回读逐项相符（`S2_POSTGEN_MISMATCH_N = 0`，两个工程都是 `S2_CONVERGED_AT_ROUND 1`）。

### ⚠️ 一条重要的施工坑：**`CONFIG.CORE` 会重置其它参数**

按 `_lic/tcl_a_prepare.tcl` 的参数顺序（`CONFIG.CORE` 放**最后**）跑，**每个 `set_property` 的即时回读都正确**，
但**存进 `.xci` 的却是** `LINE_RATE=25` / `BASE_R_KR=BASE-KR` / `GT_REF_CLK_FREQ=161.1328125`
（`logs/s1_prepare_stdout.txt` 的 `CFG_pcs64` 段 + 落盘 `.xci` 第 15/20/… 行）。
⇒ **设 `CONFIG.CORE` 会把它的依赖参数打回该 CORE 的默认值，而这次回滚是静默的**。
`_lic` 那条注释只说"某些顺序下 CORE 会锁住其余参数"，实测是**反过来的**：不是锁住，是**重置**。
**修法（已落地）**：`s2_config.tcl` 改成**不动点迭代** —— 每轮重新设全 8 个参数、全量回读比对，
直到 `MISMATCH_N == 0`（实测第 1 轮即收敛，因为 CORE 已经在正确值上）：
```
S2_ROUND pcs64 #1 MISMATCH_N = 0
S2_CONVERGED_AT_ROUND pcs64 = 1
S2_RB_AFTER_GENERATE:  ... 8/8 OK
S2_POSTGEN_MISMATCH_N = 0
```
**给后续设计的告诫**：改 xxv_ethernet 的任一参数后，**必须回读全部关键参数并重跑一次不动点**；
只信逐条 `set_property` 的即时回读会拿到一个和你想的不一样的设计（本次差点就是这样）。

### GT 通道确认（`Quad_X0Y1` → 通道 `X0Y4` = SFP A）

IP 自己生成的子核 `ip_0/<name>_gt.xci` 回读：
```
CHANNEL_ENABLE    = X0Y4          TX_REFCLK_SOURCE = X0Y4 clk0     RX_REFCLK_SOURCE = X0Y4 clk0
GT_TYPE           = GTY           TX_LINE_RATE     = 10.3125       RX_LINE_RATE     = 10.3125
TX_USER_DATA_WIDTH= 64            RX_USER_DATA_WIDTH = 64
TX_INT_DATA_WIDTH = 64            RX_INT_DATA_WIDTH  = 64
TXPROGDIV_FREQ_VAL= 156.25        FREERUN_FREQUENCY  = 100.00
INS_LOSS_NYQ      = 30            TX_PLL_TYPE = QPLL0   RX_PLL_TYPE = QPLL0
TX_BUFFER_MODE    = 1             RX_BUFFER_MODE = 1
TX_OUTCLK_SOURCE  = TXPROGDIVCLK  RX_OUTCLK_SOURCE = RXPROGDIVCLK
```
**`Quad_X0Y1` 这个组名对应的就是通道 X0Y4**（quad 225 = 通道 X0Y4..X0Y7），
与 P7a/iBERT 的 `X0Y4 = SFP A` 一致 —— **不是猜的，是子核 `CHANNEL_ENABLE` 的回读**。

---

## 3. 两套 CORE 的接口（给设计用的合同）

两种 CORE 的完整端口清单在 `.veo`（明文外壳）里，路径：
- `xxv_probe/pcs64/pcs64.gen/sources_1/ip/pcs64/pcs64.veo`
- `xxv_probe/macpcs64/macpcs64.gen/sources_1/ip/macpcs64/macpcs64.veo`

（RTL 本体是加密的；`.veo` 是 AMD 给的明文实例化模板，端口名/位宽/方向可当权威。）

### 3.1 两者共有的部分（GT / 时钟 / 复位 / 测试图案）

| 端口 | 方向/位宽 | 说明 |
|---|---|---|
| `gt_rxp_in_0` / `gt_rxn_in_0` | in | GT 串行输入（**由 IP 的内部 XDC 定 LOC 到 `GTYE4_CHANNEL_X0Y4` 决定球号**，见 §4） |
| `gt_txp_out_0` / `gt_txn_out_0` | out | GT 串行输出 |
| `gt_refclk_p` / `gt_refclk_n` | in | **156.25 MHz 差分参考钟**（IP 内部自带 `IBUFDS_GTE4`；顶层给差分输入即可） |
| `gt_refclk_out` | out | IBUFDS_GTE4 的 `O` 输出（裸参考钟，一般不接） |
| `dclk` | in | **100 MHz DRP/控制时钟**（IP 自己的 OOC XDC 里 `create_clock -period 10.000`） |
| `sys_reset` | in | 高有效总复位 |
| `rx_reset_0` / `tx_reset_0` | in | RX/TX 数据通路复位（**见 §5.4：这两个是输出，必须被消费**） |
| `user_rx_reset_0` / `user_tx_reset_0` | out | 用户侧复位（可用作自己的复位源） |
| `gtwiz_reset_tx_datapath_0` / `gtwiz_reset_rx_datapath_0` | in | 厂商 example 恒 `1'b0` |
| `qpllreset_in_0` | in | 厂商 example 恒 `1'b0`（多核时改它会扰动同 quad 的别的核） |
| `gt_loopback_in_0[2:0]` | in | GT 内部环回（example 恒 `3'b000`） |
| `txoutclksel_in_0[2:0]` / `rxoutclksel_in_0[2:0]` | in | **厂商 example 硬编码 `3'b101`（注释：as per gtwizard，不可改）** |
| `gtpowergood_out_0` | out | GT 电源好 |
| `rxrecclkout_0` | out | 恢复时钟原始输出（**不要接普通逻辑，见 §5.4**） |
| `ctl_rx_wdt_disable_0` | in | example 恒 `1'b0` |
| `stat_rx_block_lock_0` | out | **块锁**（64b/66b block lock） |
| `stat_rx_status_0` | out | **RX 链路健康**（厂商 example：`rx_block_lock_led = block_lock & stat_rx_status`） |
| `stat_rx_hi_ber_0` | out | 高误码率 |
| `stat_rx_local_fault_0` | out | local fault |
| `stat_rx_framing_err_0` / `stat_rx_framing_err_valid_0` | out | 帧定界错 |
| `stat_rx_valid_ctrl_code_0` / `stat_rx_bad_code_0` / `stat_rx_bad_code_valid_0` | out | 控制码 |
| `stat_rx_error_0[7:0]` / `stat_rx_error_valid_0` | out | 逐 lane 错 |
| `stat_rx_fifo_error_0` | out | 弹性 FIFO 错 |
| `stat_tx_local_fault_0` | out | TX local fault |
| `ctl_rx_test_pattern_0` / `ctl_rx_data_pattern_select_0` / `ctl_rx_test_pattern_enable_0` / `ctl_rx_prbs31_test_pattern_enable_0` | in | RX 测试图案（PRBS31 等） |
| `ctl_tx_test_pattern_*` / `ctl_tx_data_pattern_select_0` / `ctl_tx_prbs31_test_pattern_enable_0` / `ctl_tx_test_pattern_seed_a_0[57:0]` / `_b_0[57:0]` | in | TX 测试图案 |

**⚠️ 用户问的"状态输出里有没有 block_lock / hi_ber / local_fault / align_status"：**
`block_lock` ✅ `hi_ber` ✅ `local_fault` ✅ 都有（且是**顶层端口**，不用 AXI）。
`align_status`（RX 字对齐）**不是端口**，但**在 IP 内部存在** —— 厂商 example 的 XDC 直接引用它：
`.../pcs64_example_top.xdc:  get_cells -hier -filter { name =~ */i_RX_WD_ALIGN/align_status_reg* }`。
它在 PCS 内部被与进 `stat_rx_status_0`。**要单独看它得上 ILA/AXI，普通端口拿不到。**

### 3.2 `CORE = Ethernet PCS/PMA 64-bit`（XGMII 出）—— 数据面端口

```
.tx_mii_clk_0   (output)          // XGMII TX 时钟，156.25 MHz（来自 TXOUTCLK/PROGDIV）
.tx_mii_d_0     (input  [63:0])   // XGMII TX 数据
.tx_mii_c_0     (input  [ 7:0])   // XGMII TX 控制
.rx_clk_out_0   (output)          // 恢复时钟 156.25 MHz（RXOUTCLK）
.rx_core_clk_0  (input)           // ★ RX 核时钟，必须由用户提供 156.25 MHz
.rx_mii_d_0     (output [63:0])   // XGMII RX 数据
.rx_mii_c_0     (output [ 7:0])   // XGMII RX 控制
```
**⇒ 确认是 XGMII**（`tx_mii_d[63:0] + tx_mii_c[7:0]`），**不是 AXIS**。
**没有 `tkeep`/`tlast`/`tuser`，没有任何 AXI4-Lite**（本配置 `CONFIG.INCLUDE_AXI4_INTERFACE=0`、
`INCLUDE_STATISTICS_COUNTERS=0`），所有状态都是上面那组 `stat_*` 单比特/窄总线端口。

### 3.3 `CORE = Ethernet MAC+PCS/PMA 64-bit`（AXIS 出）—— 数据面端口

**RX（MAC → 用户）**
```
.rx_axis_tvalid_0   (output)
.rx_axis_tdata_0    (output [63:0])
.rx_axis_tkeep_0    (output [ 7:0])
.rx_axis_tlast_0    (output)
.rx_axis_tuser_0    (output)        // ★ 1 bit，不是向量
.rx_preambleout_0   (output [55:0]) // 收到的前导码回放（不用时悬空）
```
**TX（用户 → MAC）**
```
.tx_axis_tready_0   (output)
.tx_axis_tvalid_0   (input)
.tx_axis_tdata_0    (input  [63:0])
.tx_axis_tkeep_0    (input  [ 7:0])
.tx_axis_tlast_0    (input)
.tx_axis_tuser_0    (input)         // ★ 1 bit
.tx_unfout_0        (output)        // TX FIFO underflow
.tx_preamblein_0    (input  [55:0]) // 自定前导码（不用时 0）
```
**控制（`ctl_*`，全部是普通端口，不是寄存器）** —— 厂商 example 的稳态取值
（`macpcs64_pkt_gen_mon.v:1380-1395` 与 `:2497-2510`）：
```
ctl_tx_enable=1  ctl_tx_send_rfi=0  ctl_tx_send_lfi=0  ctl_tx_send_idle=0
ctl_tx_fcs_ins_enable=1  ctl_tx_ignore_fcs=0  ctl_tx_custom_preamble_enable=0  ctl_tx_ipg_value=4'd12
ctl_rx_enable=1  ctl_rx_check_preamble=1  ctl_rx_check_sfd=1  ctl_rx_force_resync=0
ctl_rx_delete_fcs=1  ctl_rx_ignore_fcs=0  ctl_rx_process_lfi=0
ctl_rx_max_packet_len=15'd9600  ctl_rx_min_packet_len=8'd64  ctl_rx_custom_preamble_enable=0
```
**状态（`stat_*`，都是单周期脉冲；RX 侧比 PCS-only 多一整组 MAC 统计）**：
`stat_rx_block_lock` `stat_rx_status` `stat_rx_hi_ber` `stat_rx_local_fault`
`stat_rx_remote_fault` `stat_rx_internal_local_fault` `stat_rx_received_local_fault`
`stat_rx_got_signal_os`（光模块无信号）`stat_rx_framing_err(_valid)`
`stat_rx_valid_ctrl_code` `stat_rx_bad_code` `stat_rx_bad_sfd` `stat_rx_bad_preamble`
`stat_rx_bad_fcs[1:0]` `stat_rx_stomped_fcs[1:0]` `stat_rx_truncated`
`stat_rx_oversize` `stat_rx_toolong` `stat_rx_undersize` `stat_rx_fragment` `stat_rx_jabber`
`stat_rx_inrangeerr` `stat_rx_vlan` `stat_rx_test_pattern_mismatch`
`stat_rx_total_bytes[3:0]`（nibble 计数！）`stat_rx_total_packets[1:0]`
`stat_rx_total_good_bytes[13:0]` `stat_rx_total_good_packets` `stat_rx_packet_bad_fcs`
`stat_rx_packet_{64,65_127,128_255,256_511,512_1023,1024_1518,1519_1522,1523_1548,1549_2047,2048_4095,4096_8191,8192_9215}_bytes`
`stat_rx_packet_small` `stat_rx_packet_large` `stat_rx_unicast` `stat_rx_multicast` `stat_rx_broadcast`
TX 侧对称一组 + `stat_tx_frame_error`。
**注意**：`stat_rx_total_bytes` 只有 **4 位**、`stat_rx_total_good_bytes` 只有 **14 位** —— 它们是
**nibble/分段累加器**，不是 64 位计数器（要用得上层自己拼）。

### 3.4 ⭐ 字节序：两种 CORE **不一样**（这是架构选择的核心事实之一）

**PCS-only（XGMII）：lane 0 = 帧内第一个字节，即 `tx_mii_d[7:0]` 是首发字节（LSB-first）。**
证据（厂商自己的图案发生器/校验器，不是我的推断）：
```
pcs64_pkt_gen_mon.v:1240  function swapn(input [63:0] d); for(i) swapn[i+:8] = d[(63-i)-:8];
pcs64_pkt_gen_mon.v:1199  if(full_bits != 0 ) tx_mii_d[full_bits+:8] <= 8'hFD;   // terminate 落在 lane=已发字节数
pcs64_pkt_gen_mon.v:1148  tx_mii_d <= swapn(tx_datain);                          // 内部左对齐 → lane0 是首字节
pcs64_pkt_gen_mon.v:1078  tx_mii_d <= {8{8'h07}}; tx_mii_c <= {8{1'b1}};         // idle = 全 lane ctl=1 / 0x07
pcs64_pkt_gen_mon.v:1169  if(set_eop) begin tx_mii_d[0+:8] <= 8'hFD ; ...        // 边界帧：terminate 在 lane 0
```

**MAC+PCS（AXIS）：`tdata[63:56]` = 帧内第一个字节（MSB-first / 左对齐），与`tkeep` 高位有效配套。**
证据：
```
macpcs64_pkt_gen_mon.v:1091  tx_axis_tdata[(8-1-0)*8+:8] = fifo_tx_datain[0*8+:8];   // byte0 -> tdata[63:56]
macpcs64_pkt_gen_mon.v:1098  tx_axis_tdata[(8-1-7)*8+:8] = fifo_tx_datain[7*8+:8];   // byte7 -> tdata[7:0]
macpcs64_pkt_gen_mon.v:1104-1111  tx_axis_tkeep = {8{1'b1}} >> n;                   // 末字：高位有效、左对齐
```

**⇒ 与本工程已冻结的帧流合同逐字对齐：**
本仓合同（`notes/P7B_DATAPATH_CONTRACT.md:40-47,63-72`）是
`tdata[63:56]` = 首字节、`tkeep` 高位有效、`tcrs`/`terr` 仅 TLAST 有效、FCS 已剥离。
- **MAC+PCS 的 AXIS ⇒ 字节序、tkeep、tlast 与合同逐字相同（0 改动）**，
  只差 `tuser` 的语义（见 3.5）与 `tcrs` 的生成。
- **PCS-only 的 XGMII ⇒ 需要一次 64 位字节反转**（纯连线，0 逻辑），
  外加**整层以太网 MAC**（前导码/SFD 插拔、IFG、FCS 生成与校验、S/T 控制码、runt/oversize）。

### 3.5 `tuser` 的语义（**与我们的合同同名不同义，务必小心**）

- 我们的合同：`tuser = 1` 标在**帧首字**（SOP 标记）。
- `xxv_ethernet MAC`：**`rx_axis_tuser` / `tx_axis_tuser` = "这一帧有错"**。
  证据（厂商自己的 monitor 用法）：
  ```
  macpcs64_pkt_gen_mon.v:1076  rx_errout <= rx_axis_tuser;                      // 收到的帧错
  macpcs64_pkt_gen_mon.v:1101  tx_axis_tuser = fifo_tx_eopin && fifo_tx_errin;  // 发送时可注入坏帧
  ```
  ⇒ 所以 **`tcrs ≈ ~rx_axis_tuser`（在 TLAST 拍）、`terr ≈ rx_axis_tuser`**，
  而 **SOP 标记必须由我们自己产生**（AXIS 上没有 SOP 边带；用 `tlast` 后一拍或计数复位即可）。
  ⚠️ 我们的 `terr` 是"帧内逐字 rx_er"，`tuser` 是"帧级"。位宽/粒度不同，shim 里要显式降级。

### 3.6 AXI4-Lite 配置/状态寄存器口

**本配置下：没有。** `CONFIG.INCLUDE_AXI4_INTERFACE=0` + `CONFIG.INCLUDE_STATISTICS_COUNTERS=0`，
所以既没有 `s_axi_*` 端口，也没有寄存器表 —— 全部 ctl/stat 都是**普通端口**（§3.3）。
**寄存器表只在你把 `CONFIG.INCLUDE_AXI4_INTERFACE` 打开时才存在**（那会多出 AXI4-Lite 与
累计统计计数器），本次**没有生成**，所以**没有寄存器表可提取**。
（生成目录里的 `<name>.xml` 是 IP 元数据，不是给你的寄存器手册。）
**⇒ 观测方案应继续用"普通端口 + 我们自己的寄存器窗口/ILA"，不要指望 AXI 寄存器表。**

---

## 4. 时钟 / 复位结构

### 4.1 需要用户提供的时钟（IP 的 OOC XDC 原文，两份一模一样）

`pcs64/synth/pcs64_ooc.xdc`:
```
create_clock -period 6.40  [get_ports rx_core_clk_0]
set_property HD.CLK_SRC BUFGCTRL_X0Y1 [get_ports rx_core_clk_0]
create_clock -period 10.000 [get_ports dclk]
set_property HD.CLK_SRC BUFGCTRL_X0Y2 [get_ports dclk]
create_clock -period 6.400  [get_ports gt_refclk_p]
```
`pcs64/synth/pcs64.xdc`: `create_clock -period 6.400 [get_ports gt_refclk_p]`（+ 一批内部 CDC waiver / max_delay）
⇒ **只要 3 个用户时钟**：`gt_refclk_p/n` 156.25 MHz、`dclk` 100 MHz、
`rx_core_clk_0` **156.25 MHz**（MAC+PCS 变体同样只要这三个，`tx_clk_out_0` 是输出）。

### 4.2 `rx_core_clk_0` 怎么接 —— 厂商 example 的答案是**自环**

`pcs64_ex/pcs64_ex/imports/pcs64_exdes.v`:
```verilog
wire rx_core_clk_0;  wire rx_clk_out_0;
assign rx_core_clk_0 = rx_clk_out_0;      // ← 恢复时钟直接绕回来当 RX 核时钟
...
assign txoutclksel_in_0 = 3'b101;  // "this value should not be changed as per gtwizard"
assign rxoutclksel_in_0 = 3'b101;
assign gtwiz_reset_tx_datapath_0 = 1'b0;  assign gtwiz_reset_rx_datapath_0 = 1'b0;
assign qpllreset_in_0 = 1'b0;             assign ctl_rx_wdt_disable_0 = 1'b0;
assign gt_loopback_in_0 = 3'b000;
assign rx_block_lock_led_0 = block_lock_led_0 & stat_rx_status_0;
```
`macpcs64_ex/macpcs64_ex/imports/macpcs64_exdes.v:97-98` 同（把注释掉的
`//assign rx_core_clk_0 = tx_clk_out_0;` 放在旁边，成品用的是 `rx_clk_out_0`）。

### 4.3 手册/端口层面的 TX/RX 时钟

- **PCS-only**：`tx_mii_clk_0`（out，TX XGMII 时钟）、`rx_clk_out_0`（out，恢复时钟）。
  XGMII TX 侧跑 `tx_mii_clk_0`，RX 侧跑 `rx_core_clk_0`（= `rx_clk_out_0`）。
  ⇒ **TX 与 RX 是两个不同的 156.25 MHz 域**（一个是 QPLL 派生，一个是 CDR 恢复）。
- **MAC+PCS**：`tx_clk_out_0`（out）、`rx_clk_out_0`（out），AXIS 各跑自己那个。

### 4.4 复位序列

IP **自带** reset controller（`INCLUDE_SHARED_LOGIC=1` ⇒ GT common + reset controller 都在核内）。
用户侧只有 `sys_reset`（高有效）+ `rx_reset_0`/`tx_reset_0`；
核自己给出 `user_rx_reset_0` / `user_tx_reset_0` 供用户逻辑复位用，
并给出 `gtpowergood_out_0` 作为 GT 就绪。
**没有 `gt_*_ready/lock` 之外的握手**；`stat_rx_status_0` + `stat_rx_block_lock_0` 就是链路健康的判据。

### 4.5 它内部确实例化了自己的 `gtwizard` 子核 —— 而且**与我们的 `gt_10gbr` 几乎逐项相同**

生成物里明确有：`<tag>.gen/sources_1/ip/<tag>/ip_0/<tag>_gt.xci` + `hdl/gtwizard_ultrascale_v1_7_*.v`
（含 `..._gtye4_common.v`、`..._gtwiz_reset.v`、`..._gtwiz_userclk_tx/rx.v`、`..._gtye4_cpll_cal*.v`）。
**逐项对账**（左 = 本次从 xxv 子核 `.xci` 回读；右 = `_proj_10g/tcl/build_p7a.tcl` 里 `gt_10gbr` 的
实测配置，那是**板级已验收**的基准：双向各 600 s / 6.003×10¹² bit 零错，BER 上界 4.997×10⁻¹³）：

| 参数 | xxv_ethernet 内部 GT | 我们的 `gt_10gbr`（板级实测） | 一致？ |
|---|---|---|---|
| `TX_DATA_ENCODING` / `RX_DATA_DECODING` | `64B66B_ASYNC` | `64B66B_ASYNC` | ✅ |
| `TX/RX_LINE_RATE` | 10.3125 | 10.3125 | ✅ |
| `TX/RX_INT_DATA_WIDTH` | 64 | 64 | ✅ |
| `TX/RX_USER_DATA_WIDTH` | 64 | 64 | ✅ |
| `TX/RX_BUFFER_MODE` | 1 | 1 | ✅ |
| `TX/RX_PLL_TYPE` | QPLL0 | QPLL0 | ✅ |
| `TX/RX_REFCLK_FREQUENCY` | 156.25 | 156.25 | ✅ |
| `TX/RX_REFCLK_SOURCE` | `X0Y4 clk0` | `X0Y4 clk0 X0Y5 clk0` | ✅（通道数不同） |
| `TX/RX_OUTCLK_SOURCE` | `TXPROGDIVCLK` / `RXPROGDIVCLK` | 同 | ✅ |
| `TXPROGDIV_FREQ_VAL` | 156.25 | 156.25 | ✅ |
| **`FREERUN_FREQUENCY`** | **100.00** | **156.25** | ❌ **唯一实质差异** |
| `CHANNEL_ENABLE` | `X0Y4`（1 通道） | `X0Y4 X0Y5`（2 通道） | 差异（核数） |
| `LOCATE_COMMON`（子核属性） | `EXAMPLE_DESIGN` | `CORE` | ⚠️ 见下 |
| `INS_LOSS_NYQ` | 30 | （未在 p7a 显式设） | — |
| `RX_TERMINATION` | `PROGRAMMABLE 800` | （未显式设） | — |

**两条要写清的解释边界**：
1. `FREERUN_FREQUENCY = 100.00` 而**顶层没有 100 MHz 的自由运行钟端口**（只有 `dclk`），
   ⇒ **推断**它是从 `dclk`（100 MHz）派生的。这是**推断不是回读**（GT 内部实现加密）。
   对我们无影响：我们已经给 `dclk` 供 100 MHz。
2. `LOCATE_COMMON = EXAMPLE_DESIGN` 是子核 `.xci` 里的字面值，但**生成的 RTL 文件集里确实包含**
   `gtwizard_ultrascale_v1_7_gtye4_common.v` 与 `<tag>_gt_gtye4_common_wrapper.v`，
   综合日志也确实例化了 `pcs64_common_wrapper`（§1.4 检查点①），
   而顶层也**没有** common 端口 ⇒ 实际是**核内自带 common**（=`INCLUDE_SHARED_LOGIC=1` 生效）。
   **子核那个字面值的语义我列为未核实 U3。**

> 关于 `GTY-10GBASE-R.tcl` preset：**本次没有用它**（按协调者要求不去读那个加密/二进制 preset），
> 走的是 `create_ip` + 显式 `CONFIG.*` + **回读落盘 `.xci`** 的路线 ——
> 上表左列就是**这个核实际生效的 GT 配置**，比任何 preset 文件都权威。
> （也**没有**用 `CONFIG.preset` 去套 preset —— 所以"preset 里到底写了什么"本次仍然未核实，
> 但那不影响任何结论：我用的是回读值。）

### 4.6 ⭐ 官方核补的到底是不是"闸 0 缺的那一层"？—— **是，有 netlist 级证据**

路由后设计的**层次单元名**（`macpcs64/macpcs64.runs/impl_1/probe_macpcs64_top_timing_summary_routed.rpt` 里
被引用到的 `i_*` 单元，去重）：
```
i_TX_TOP  i_TX_CORE  i_TX_CORE_STRIPER  i_TX_ENCODER  i_TX_SCRAMBLER  i_TX_FCS  i_TX_LBUS_ADAPTER
i_RX_TOP  i_RX_CORE  i_RX_CORE_LANE  i_RX_DESTRIPER  i_RX_DECODER  i_RX_WD_ALIGN
i_RX_HI_BER_MONITOR  i_RX_FCS  i_RX_DELETE_FCS  i_RX_STATS  i_RX_LBUS_FIFO  i_RX_LBUS_FIFO_RAM
i_FCS_64_FULL  i_LANE_RESET_SYNC  i_RX_RESET_SERDES_SYNC  i_RESET_FLOP_TX_LBA  i_RAM_28 …
```
**⇒ `i_TX_SCRAMBLER`（加扰）、`i_TX_ENCODER`/`i_RX_DECODER`（64b/66b 编解码）、
`i_TX_CORE_STRIPER`/`i_RX_DESTRIPER`、`i_RX_WD_ALIGN`（字对齐）、`i_RX_HI_BER_MONITOR`、
`i_TX_FCS`/`i_RX_FCS`/`i_RX_DELETE_FCS`/`i_FCS_64_FULL` 全是 fabric 逻辑里真实存在的单元。**
这正是 **P7a/闸 0 证明"GT 里没有"的那一层** —— 也就是说：

> **官方核补上的，恰好就是我们自己要在 `gt_10gbr` 之上写的那部分**，
> 而且它跟我们的 GT 用的是**同一份 GT 配置**（§4.5 表） ⇒ 物理层结论可以直接继承。

PCS-only 变体同样带这一层（其路由后报告里可见
`i_pcs64_common_wrapper`、`i_pcs64_rx_64bit_gt_pipeline_serdes_data0_0`、
`i_pcs64_core_cdc_sync_stat_rx_block_lock_dclk_0` 等；`block_lock` 是真实 fabric 信号）。

> ⚠️ 这条**只证明"逻辑在里面"**，**不证明它工作**（没上板、没仿真）。见 U13/U15。

---

## 5. 资源、时序、位流（**针对"-1 未验证"这条风险**）

### 5.1 资源（综合后，`xcku5p-ffvb676-1-e`）

| | PCS/PMA 64-bit（IP 本体） | MAC+PCS/PMA 64-bit（IP 本体） | 顶层探针逻辑 |
|---|---|---|---|
| CLB LUTs | **2,238** (1.03%) | **4,917** (2.27%) | 36 |
| CLB Registers | **3,000** (0.69%) | **4,875** (1.12%) | 149 |
| CARRY8 | 20 | 34 | 10 |
| **Block RAM Tile** | **0** | **0** | 0 |
| URAM / DSP | 0 / 0 | 0 / 0 | 0 / 0 |
| **GTYE4_CHANNEL** | **1** | **1** | 0 |
| Bonded IOB | 2 | 2 | 8 |

报告：`pcs64/pcs64.runs/pcs64_synth_1/pcs64_utilization_synth.rpt`、
`macpcs64/macpcs64.runs/macpcs64_synth_1/macpcs64_utilization_synth.rpt`、
`.../synth_1/probe_*_utilization_synth.rpt`。

**⇒ 连 MAC+PCS 全功能核只要 ~4.9k LUT / ~4.9k FF / 0 BRAM / 1 个 GTY 通道**，
对 KU5P（216,960 LUT / 480 BRAM / 16 GTY）是**极轻**的：数据面搬过来毫无资源压力。
（注：本次把大部分 `stat_*` 悬空，所以统计块被裁掉一部分；接上会略涨，量级不变。）

### 5.2 时序收敛（-1）：**完全收敛，余量很大**

**路由后（`*_timing_summary_routed.rpt`），`xcku5p-ffvb676-1-e`（-1 最慢等级）：**

| 设计 | WNS (ns) | WHS (ns) | WPWS (ns) | setup 失败端点 | hold 失败端点 | 总端点 | 结论 |
|---|---|---|---|---|---|---|---|
| **MAC+PCS/PMA 64-bit** | **+2.582** | **+0.023** | **+0.514** | **0** | **0** | 7179 | `All user specified timing constraints are met.` |
| **PCS/PMA 64-bit**（**最终版**：引脚 XDC 已生效，8 个 pad 有 LOC） | **+2.337** | **+0.019** | **+0.514** | **0** | **0** | 5543 | `All user specified timing constraints are met.` |

报告：`macpcs64/macpcs64.runs/impl_1/probe_macpcs64_top_timing_summary_routed.rpt`（表格在 145-150 行）、
`pcs64/pcs64.runs/impl_1/probe_pcs64_top_timing_summary_routed.rpt`。
（PCS 变体早先那版 `+2.283 / 5204 端点` 是**引脚 XDC 还没被加进去**时跑的；上表给的是最终版。）

**⇒ 明确回答"-1 上时序收敛吗"：收敛，而且宽松**（6.4 ns 周期上 WNS **+2.337 / +2.582 ns ≈ 40% 余量**）。
**唯一的薄处是 hold（+0.019 / +0.023 ns）**，与本项目一贯的观察一致（P6a 的 +0.012/+0.013 同性质）
—— 后续加逻辑时 hold 会最先出问题。

同类报告里的 `Clock Summary` 也确认了时钟结构（`macpcs64/.../probe_macpcs64_top_timing_summary_routed.rpt:155-165`）：
```
gt_refclk_p            6.400  156.250
  qpll0clk_in[0]       0.194 5156.250
    rxoutclk_out[0]    6.400  156.250
    txoutclk_out[0]    6.400  156.250
    txoutclkpcs_out[0] 6.206  161.133     ← PCS 侧的"raw 161.13 MHz"，与 P7a 的频率恒等式一致
  qpll0refclk_in[0]    6.400  156.250
```
（注意 `txoutclkpcs_out` = 161.133 MHz —— 这就是 P7a 里 `10.3125 GBd × 64/66 = 10.0 GHz` 的另一个侧面，
**再次印证 Y2 = 156.25 MHz**。）

### 5.2b 位流

| CORE | 结果 | 证据 |
|---|---|---|
| **PCS/PMA 64-bit** | ✅ **位流已生成** `probe_pcs64_top.bit` = **15,431,266 B**，sha256 `86fe9c7b54f652129ebf19750601f5885712f966670e6e54a0154f2b1ce6a905` | `pcs64/.../impl_1/runme.log:824,826,827`（`Bitgen Completed Successfully` / `0 Errors` / `write_bitstream completed successfully`） |
| **MAC+PCS/PMA 64-bit** | ❌ **被 license 拒绝** | `macpcs64/.../impl_1/runme.log` 尾部（原文见 §0.2） |

⚠️ **位流没有烧到板上**（纪律：不 `program_hw_devices`、不碰 QSPI）。所以本节的"位流"只证明
**工具链/许可层面走得通**，**不证明板上能跑** —— 见 U13。

### 5.3 时序基线对照（我们自己的 P7a 数据面，作为 -1 上的先验）

KU5P @6.400 ns（=`-1` 上的 156.25 MHz）我们自己的 64 位数据面是
`WNS +0.426 / 0 失败端点`（`p6a_ku5p_verify/`）。
**⇒ "-1 跑 156.25 MHz 是可行的"在本板已有先例**；xxv 核实测更宽松（见 §5.2）。

### 5.4 实现阶段踩到的坑（**都不是 license**：3 个是探针 RTL/约束的错，1 个是我脚本的错；对方核集成同样适用）

**(坑 1) `rx_reset_0` / `tx_reset_0` 悬空 ⇒ `opt_design` 直接失败**
```
macpcs64/.../impl_1/runme.log:117 WARNING: [Opt 31-155] Driverless net
    DUT/inst/i_macpcs64_core_cdc_sync_gt_rx_resetdone_0/rx_reset_0 is driving LUT input pin I0
    which is used by the LUT equation. If the LUT is not removed or a driver added, this warning will become an error.
    LUT cell name: DUT/inst/i_macpcs64_core_cdc_sync_gt_rx_resetdone_0/sig_in_cdc_from_inferred_i_1
macpcs64/.../impl_1/runme.log:118 WARNING: [Opt 31-155] Driverless net
    DUT/inst/i_macpcs64_core_cdc_sync_gt_tx_resetdone_0/tx_reset_0 ...
macpcs64/.../impl_1/runme.log:183 ERROR: [Opt 31-67] ... missing a connection on input pin I0 ...
opt_design failed
```
根因：把 `rx_reset_0`/`tx_reset_0` 接到一根没人用的线上 ⇒ 优化器把驱动剪掉 ⇒
核内部读这两个网络的那个 LUT 悬空。**修法：把 `rx_reset_0`/`tx_reset_0`（以及
`user_rx_reset_0`/`user_tx_reset_0`）**真正消费掉**（本探针用一个移位寄存器链接到 LED 上）。
**⇒ 对方核做集成时，这四个复位输出不能悬空。**

**(坑 2) 消费 `rxrecclkout_0` ⇒ `route_design` 失败**
```
pcs64/.../impl_1/runme.log:639 CRITICAL WARNING: [Route 35-54] Net: .../channel_inst/rxrecclkout_out[0] is not completely routed.
pcs64/.../impl_1/runme.log:664 ERROR: [Route 35-7] Design has 1 unroutable pin, ...
```
`rxrecclkout` 是 GT 的原始恢复时钟输出，只能进特定时钟资源；接到普通 LUT 上没法布通。
**厂商 example 里它也是悬空的。⇒ 不要消费 `rxrecclkout_0`（同理 `gt_refclk_out`）。**

**(坑 3，DRC) IP 自己的 XDC 不给 `IBUFDS_GTE4` 定 LOC**
```
pcs64/.../impl_1/runme.log:247 CRITICAL WARNING: [DRC AVAL-326] Hard_block_must_have_LOC:
   The hard block IBUFDS_GTE4 cell DUT/inst/IBUFDS_GTE4_GTREFCLK0_INST is missing a valid LOC constraint ...
```
IP 的 `ip_0/synth/<tag>_gt.xdc:57` 只给了通道：
```
set_property LOC GTYE4_CHANNEL_X0Y4 [get_cells -hierarchical -filter {NAME =~ *gen_channel_container[1].*gen_gtye4_channel_inst[0].GTYE4_CHANNEL_PRIM_INST}]
```
而 `synth/<tag>_board.xdc` **是空的**（只有一行注释 `#----Physical Constraints----`），
`synth/<tag>.xdc` 只 `create_clock` 参考钟端口 + CDC waiver —— **没有任何 PACKAGE_PIN**。
**⇒ 结论：xxv_ethernet 不会和我们的既有引脚约束冲突**（它连引脚都不碰）。
`AVAL-326` 是 **Critical Warning**，本次实测**没有拦住任何一步**：
`route_design` 成功、时序收敛，**PCS-only 变体带着它 `Bitgen Completed Successfully`（`2 Critical Warnings, 0 Errors`）**
⇒ **它不升级为 write_bitstream 的 DRC 错误。** 若要确定性清除，可在 impl-only XDC 里给 `IBUFDS_GTE4` 加
`set_property LOC IBUFDS_GTE4_X0Y1 [...]`（本次尝试自动生成，但 `get_sites` 在本工程上下文里
**返回 0 个 site**（`S5_IBUFDS_QUERY` 各拼法都 n=0，`get_sites` 总数也为 0），所以**没有写入**，
`AVAL-326` 原样保留 —— 见 U4。）

**(坑 4，我自己的脚本 bug，记录以便复现)**：`s4/s5_build.tcl` 里 XDC 的文件名写成了
`$root/xdc/$tag.xdc`，而实际文件名是 `probe_<tag>.xdc` ⇒ `add_files` 静默失败（被 `catch` 吞掉）
⇒ **整个第一轮跑的是"零约束"设计**，`write_bitstream` 的 DRC 报
`[DRC NSTD-1] Unspecified I/O Standard` + `[DRC UCIO-1] Unconstrained Logical Port`（10/10 端口无 LOC）。
**⇒ 教训：`catch {add_files ...}` 这种写法会把"文件不存在"吃成静默跳过；加了文件必须回读
`get_files` 确认。** 修正后重跑，位流阶段的报错就只剩下 license 那一条（§0）。

---

## 6. 架构建议（A vs B）——**license 已经把答案压成 A**

⚠️ **先读这一句**：`write_bitstream` 的实测结果（§0）是
**A（PCS-only）能出位流、B（MAC+PCS）不能**。
⇒ **在当前 license 下这不是一个可以自由选择的问题 —— 只有 A 是可行的。**

```
CORE = Ethernet PCS/PMA 64-bit  → 能出位流（本机已产出 probe_pcs64_top.bit）→ 走 A：自写 64 位 XGMII MAC
CORE = Ethernet MAC+PCS/PMA     → write_bitstream 被 license 拒绝          → B 在本机不可行
（若将来拿到高于 Design Linking 的 xxv_eth_mac_pcs license，B 仍然更省事，见下表）
```

**另一条仍然成立的价值**：license 在位 ⇒ `IS_LOCKED = 0` ⇒ **官方核可以在 xsim 里跑起来**
（`USED_LICENSE_KEYS` 的 `simulation` 一项同样满足；且 `xxv_probe/*_ex/` 里已经有官方 example 的
`*_exdes_tb.v`）。**⇒ 把 `CORE = MAC+PCS/PMA` 的核当"金标准参照物"在仿真里用，
验证我们自写 MAC（A 路线）的组帧/FCS/IFG 是否正确** —— 这是这份 Design Linking license 仍然给我们的最大价值。
（注意：仿真用途尚未实测跑通，列 U15。）

### 候选 A：`CORE = Ethernet PCS/PMA 64-bit`（XGMII 出）+ 自写 64 位 XGMII MAC
### 候选 B：`CORE = Ethernet MAC+PCS/PMA 64-bit`（AXIS 出）+ 一层 AXIS↔帧流合同 shim

| 判据 | A（PCS-only + 自写 MAC） | B（官方 MAC + shim） |
|---|---|---|
| 数据面字节序 | **反的**：需 64 位字节反转（0 逻辑，纯连线） | **与合同逐字相同**（§3.4 证据） |
| tkeep / tlast | XGMII 没有，要自己造 | AXIS 直接给，语义与合同一致 |
| FCS 生成/校验 | **要自己写**（32 位反射 CRC，1 字/拍要 8 路并行） | 官方核做（`ctl_tx_fcs_ins_enable` / `ctl_rx_delete_fcs`） |
| 前导码/SFD/IFG | **要自己写**（S/T 控制码、IPG 计数） | 官方核做 |
| 块锁/加扰/对齐/PCS | 官方做 | 官方做 |
| 状态可观测性 | 有 `block_lock/hi_ber/local_fault/status`（无 MAC 统计） | 同上 **+ 全套 MAC 统计**（bad_fcs/undersize/oversize/broadcast/…） |
| 资源 | IP 2,238 LUT / 3,000 FF（综合）；放置后 1,765 LUT / 2,666 FF | IP 4,917 LUT / 4,875 FF（综合）；放置后 3,626 LUT / 3,622 FF |
| 时序（-1，路由后） | **WNS +2.337 / WHS +0.019 / 0 失败端点** | **WNS +2.582 / WHS +0.023 / 0 失败端点** |
| 保住 F4/F-2 知识转移 | ✅ 我们的 `mac_rx_64` 判据可逐条照搬（但整条 MAC 要按 XGMII 重写） | ⚠️ 官方 MAC 内部行为不可见，F4/F-2 判据变成**黑盒进/出**的合同检查 |
| 胶水规模 | **一个完整的 10G MAC**（XGMII 组帧/解帧 + FCS + IFG + 统计，估 700–1500 行 + 全新 TB） | **一个纯寄存器级 shim**（tuser→tcrs/terr、SOP 产生、tkeep 归一、TLAST 语义、复位/CDC；估 80–200 行 + 可复用现成 TB 骨架） |
| 新 bug 产地 | 全部在我们自己写的 MAC 里（**每一处都要新判据**） | shim 很小；官方 MAC 的风险靠"合同级"门覆盖（整帧进出比对） |
| **当前 license 能否出位流** | ✅ **能**（实测已产出位流） | ❌ **不能**（license 拒绝，可复现） |

### 推荐：**A —— `CORE = PCS/PMA 64-bit` + 自写 64 位 XGMII MAC**（被 license 逼出来的唯一可行解）

**为什么现在只能选 A**：B 在本机**拿不到位流**（§0.2，两次复现），所以不管 B 技术上多省事，
**它现在不能变成一块能跑在板上的东西**。

**走 A 要补的东西（按本项目的既有资产估）**：
1. **XGMII 组帧/解帧**：S(`0xFB`) / T(`0xFD`) / idle(`0x07`)、lane0 = 首字节（§3.4）、
   `c[7:0]` 逐 lane 控制位。**字号字节序与合同相反 ⇒ 一次 64 位字节反转**（纯连线，0 逻辑）。
2. **前导码 + SFD**：7×`0x55` + `0xD5`，在 XGMII 上按 §3.4 的 lane 布局插。
3. **IFG**：帧间 ≥12 字节（`ctl_tx_ipg_value=4'd12` 是官方 MAC 的对应旋钮；单位未核实 U10）。
4. **FCS**：32 位反射多项式 CRC，**1 字/拍要 8 路并行**（本仓已有 `crc32_d8` 风格的基础，
   `mac_rx_64.v` 的 `CRC_RESIDUE = 0xDEBB20E3` 判据可直接沿用）。
5. **状态机 + 统计**：runt/oversize/bad_fcs 计数；**这正好是官方 MAC 那一整组 `stat_*` 的等价物**。
6. **复用**：合同侧（`tdata[63:56]` 首字节 / `tkeep` 高位有效 / TLAST 上 `tcrs`/`terr` / FCS 已剥）
   **一行都不用动**，下游 "全是 64 位、零改动" 这个既定目标仍然成立。

**B 的优点不是消失了**（若将来拿到更高 license，值得重新评估）：见下。
1. **字节序/tkeep/tlast 与冻结合同逐字相同**（§3.4，厂商 monitor 的源码级证据）
   ⇒ **"下游已全是 64 位、零改动"这个目标在 B 上是直接成立的**；在 A 上要先做一次
   全局字节序反转并重验所有下游模块。
2. **A 要新写的不是胶水而是一整个 MAC**。10G 的 FCS 要在 1 字/拍下做 8 路并行 CRC，
   前导码/SFD/IFG 全要自己保证；这些正是"新 bug 的产地"，而且**判据也得全新写**。
   B 把这些交给官方核，我们只需要写一层能**用现成合同判据**（`tdata[63:56]` 首字节、
   TLAST 上 `tcrs`/`terr`、FCS 已剥）直接卡的 shim。
3. **B 的额外代价只有 2.7k LUT**（4.9k vs 2.2k，占器件 2.3% vs 1.0%）—— 在 KU5P 上不构成理由。
   时序上两者都宽松（+2.6 vs +2.3 ns）。
4. **B 多出来的 MAC 统计**（`stat_rx_bad_fcs`、`stat_rx_truncated`、`stat_rx_got_signal_os` …）
   对"链路健康"这个我们已经踩过坑的观测需求是**净收益**。
5. **物理层风险已被我们自己消除**：xxv 内部的 GT 与板级实测通过的 `gt_10gbr` **逐项相同**
   （§4.5 表），差别只有 `FREERUN_FREQUENCY` 与通道数 ⇒ P7a 的 BER 4.997×10⁻¹³ 结论可继承。

### 6a. 如果将来拿到了高于 Design Linking 的 license：那时才值得重新考虑 B

**B（`CORE = MAC+PCS/PMA 64-bit`）还要写多少胶水（具体清单）**
1. `rx_axis_* -> 合同`：`tdata`/`tkeep`/`tlast` 直通；**`tcrs = ~tuser` @TLAST，`terr = tuser` @TLAST**；
   **自己产生 SOP `tuser` 标记**（AXIS 无 SOP）；TLAST 后一拍清 SOP 标记。
   ⇒ 约 20–40 行。
2. `合同 -> tx_axis_*`：`tdata`/`tkeep`/`tlast` 直通；`tuser` **恒 0**（正常帧）；
   注意 `tx_axis_tready` 背压要回传到我们的 TX 流水（原有 `s_axis_tready` 合同不变）。
   ⇒ 约 20–40 行。
3. 时钟/复位：`tx_clk_out`/`rx_clk_out` 两个 156.25 MHz 域 + `dclk`（100 MHz，做 `sys_reset` 同步）；
   `rx_reset_0`/`tx_reset_0` **必须被消费**（§5.4 坑 1）；
   `rxrecclkout`/`gt_refclk_out` **不要消费**（坑 2）；impl-only XDC 给 `IBUFDS_GTE4` 定 LOC（坑 3）。
   ⇒ 约 40–80 行（含同步器）。
4. **不写**：FCS、前导码、IFG、块锁、加扰、8b/10b→64b/66b、统计 —— 官方核全包。

**A 还要写多少胶水**：一个完整 10G MAC（XGMII 收发组帧/解帧、S/T 控制码、FCS 8 路并行
生成与校验、IFG、runt/oversize 处理、统计），**外加** 64 位字节反转与全套新 TB。
⇒ 数量级 **5–10×** 于 B，且**每一行都是新判据**。

**给 B 的一条附加判据（防黑盒）**：shim 必须做**整帧进出比对**（RX AXIS 收到的帧 ↔ 我们在
合同侧看到的帧，逐字节 + 长度 + FCS 判定），并且**对"官方 MAC 会丢/改什么"单独设门**：
runt（<60B）、oversize（>1518B）、坏 FCS、`stat_rx_truncated` 四种病理帧各一条负对照
—— 这正是"闸 0 结论"留下的空白（官方 MAC 在 TLAST 才判 FCS，早于它的字节已经流出）。

### 6b. 如果连 PCS-only 也走不通（例如换板/换 license 环境）：给"P7a 路线"的具体建议

1. **PCS 要自己补的正好是 xxv 里那几块**，可以从官方核的**端口与状态命名**逆推需求边界：
   需要 `block_lock`、`hi_ber`、`align/status`、`framing_err`、`rx_error[7:0]` 这一组
   —— 与我们的 `p7a_counters.v` 现有观测量对照，缺的是**块锁/对齐状态机**与**加扰器**。
2. `gt_10gbr` 的 `TX_DATA_ENCODING=64B66B_ASYNC` 已经把 **gearbox** 做在 GT 里了
   （本次 §4.5 与 P7a 一致），所以我们自己写的 PCS 只需补 **加扰/解扰 + 块锁 + 对齐 + XGMII 组帧**，
   **不需要**自己实现 gearbox。
3. 物理层参数可直接照抄 xxv 子核里与 `gt_10gbr` 不同的两项（若要更贴近官方工作点）：
   `INS_LOSS_NYQ=30`、`RX_TERMINATION=PROGRAMMABLE/800`（本次只回读到值，**未做板级对照**，列 U12）。

---

## 7. 未核实清单（**没有一条是"猜测当结论"**）

| # | 未核实项 | 现状 | 怎么补 |
|---|---|---|---|
| U1 | **license 搜索路径的日志原文行** | 成功 checkout 时 Vivado **不打印**路径；扫遍全部日志无 `.lic` 路径行。只有逻辑闭环（inode 相同 + `XilinxFree.lic` 不含 `xxv_*` + `USED_LICENSE_KEYS` 三键齐） | 需要"失败对照"才会打印路径 —— 本次按纪律**不做**（不移走 license）。建议接受逻辑闭环 |
| U2 | `rx_axis_tuser` 断言的**具体拍**（TLAST 拍？整帧？） | 只确证"语义 = 帧错"（`pkt_gen_mon.v:1076/1101`），**没实跑仿真**看它在哪一拍有效 | xsim 跑一次 IP 官方 example design（`*_exdes_tb.v` 已在 `xxv_probe/*_ex/`）抓波形 |
| U3 | 子核 `LOCATE_COMMON = EXAMPLE_DESIGN` 的字面值 vs 实际核内 shared logic | 文件存在 + 综合日志例化了 `*_common_wrapper` + 顶层无 common 端口 ⇒ 实际核内自带；**字面值语义未核实** | 读 `xxv_ethernet` 的 `component.xml` 依赖逻辑，或 placer 报告核对 |
| U4 | 为什么 `gt_10gbr` 不需要 `IBUFDS_GTE4` LOC、xxv 需要 | 现象：xxv 报 `AVAL-326`；在 `reports/p7a_drc.rpt` 与 `reports/p7a_build_stdout.txt` 里搜 `AVAL-326` **均 0 命中**（但该 DRC 报告未必是完整清单，所以这只是"没看到"，不是"证明没有"）。推测与端口名自带 `x0y1` 位置提示有关 | 机制未核实 |
| U5 | `FREERUN_FREQUENCY=100.00` 的来源 | 回读值确定；"由 dclk 派生"是**推断**（GT 内部加密） | 读 GT 生成的 `*.v` 端口连接，或 placer 时钟报告 |
| U6 | ~~位流 + 路由后 WNS/WHS~~ | ✅ **已闭合**：见 §0.1 / §5.2 / §5.2b | —— |
| U7 | 本次**没有**打开 `CONFIG.INCLUDE_AXI4_INTERFACE` / `INCLUDE_STATISTICS_COUNTERS`，**没有寄存器表** | 明确未生成 | 若要 AXI 配置口，另建一个探针变体 |
| U8 | ~~`-1` 上路由后是否 0 失败端点~~ | ✅ **已闭合**：两个 CORE 都是 0 失败端点（§5.2） | —— |
| U9 | XXV MAC 的 AXIS **延迟**（帧首到 `tvalid` 的拍数） | 未测 | 仿真 or 上板 ILA；影响"低延时"目标，必须补 |
| U10 | `ctl_tx_ipg_value = 4'd12` 的单位（字节？4 字节？） | 照抄厂商 example，**语义未核实** | PG157 / 仿真量 IFG |
| U11 | `stat_rx_total_bytes[3:0]` / `stat_rx_total_good_bytes[13:0]` 的累加口径 | 位宽确定，**语义未核实** | PG157 |
| U12 | `INS_LOSS_NYQ=30` / `RX_TERMINATION=PROGRAMMABLE 800` 与 `gt_10gbr` 的差异是否影响 BER | 只回读到值，**未做板级对照** | 若走 P7a 路线且想更贴官方工作点，可做 A/B |
| U13 | **PCS-only 的位流是否真的能在板上跑、有没有功能/时间限制** | **位流已生成但从未上板**（纪律要求不烧）；`[Vivado 12-1790]` 有"will cease to function after a certain period of time"的**笼统**措辞，但**日志里没有任何具体期限**，且 license 是 `permanent` | 需要一次带授权的上板验证（本次按纪律不做） |
| U14 | **为什么 PCS-only 能出位流而 MAC 变体不能** —— 机制 | 现象已两次复现（§0）；线索：`_lic/syn_stdout.txt` 的 license-absent 实验里 MAC 段有 Fatal、PCS 段没有（但那是错器件） | 比较两个变体 netlist 里的 bitstream-permission 元数据；或问 AMD FAE |
| U15 | 官方核在 **xsim** 里能不能跑起来（作为 A 路线的金标准参照） | `IS_LOCKED=0` + `simulation` 键满足 + `*_exdes_tb.v` 已生成 ⇒ **应该可以**，但**本次没跑** | 起一次 xsim（`xxv_probe/*_ex/`） |
| U16 | `write_bitstream` 的 `[DRC AVAL-326]`（IBUFDS_GTE4 无 LOC）会不会在别的场景升级成错误 | 本次**没有**拦住位流（PCS 变体带着 2 个 Critical Warning 出了位流） | 若要确定性清除，在 impl-only XDC 给 `IBUFDS_GTE4` 定 LOC（本次 `get_sites` 在该工程上下文里返回 0，没能自动生成） |

---

## 8. 证据索引（文件 + 行号/路径）

| 内容 | 位置 |
|---|---|
| license 文件清单 / md5 / inode | 本文件 §1.1；命令：`md5sum`、`ls -i` 两棵树的 `Xilinx.lic` |
| `Xilinx.lic` 全部特性名 | §1.1（`grep -a '^INCREMENT'`，只取第 2/4 列） |
| 环境变量未设 / 无 `.HIDDEN` | `xxv_probe/logs/s1_prepare_stdout.txt:20-33`（`S1_ENV_*`、`S1_LIC_*`） |
| `USED_LICENSE_KEYS` 原文 | `xxv_probe/logs/s2_config_stdout.txt`（两工程各一处，`S2_USED_LICENSE_KEYS`） |
| **IP OOC 综合成功（PCS）** | `xxv_probe/pcs64/pcs64.runs/pcs64_synth_1/runme.log:19,616,634-636`（含 `synth_design completed successfully`） |
| **IP OOC 综合成功（MAC+PCS）** | `xxv_probe/macpcs64/macpcs64.runs/macpcs64_synth_1/runme.log:19,481,501-503` |
| 顶层综合成功 | `xxv_probe/pcs64/pcs64.runs/synth_1/runme.log`；`.../macpcs64.runs/synth_1/runme.log:22,251,268-270` |
| `CONFIG.CORE` 静默重置其它参数 | `xxv_probe/logs/s1_prepare_stdout.txt`（`CFG_pcs64 CONFIG.LINE_RATE = 25` 等）vs `:145-151` 的即时回读；落盘 `.xci` `pcs64/srcs/sources_1/ip/pcs64/pcs64.xci` |
| 不动点收敛 | `xxv_probe/logs/s2_config_stdout.txt`（`S2_CONVERGED_AT_ROUND`、`S2_POSTGEN_MISMATCH_N`） |
| GT 通道 = X0Y4 | `xxv_probe/pcs64/pcs64.gen/sources_1/ip/pcs64/ip_0/pcs64_gt.xci`（`CHANNEL_ENABLE`/`TX_REFCLK_SOURCE`） |
| **PCS-only 端口表** | `xxv_probe/pcs64/pcs64.gen/sources_1/ip/pcs64/pcs64.veo`（`INST_TAG` 段） |
| **MAC+PCS 端口表** | `xxv_probe/macpcs64/macpcs64.gen/sources_1/ip/macpcs64/macpcs64.veo`（`INST_TAG` 段） |
| XGMII 字节序 = lane0 首发 | `xxv_probe/pcs64_ex/pcs64_ex/imports/pcs64_pkt_gen_mon.v:1078,1148,1169,1199,1240` |
| AXIS 字节序 = `tdata[63:56]` 首发 | `xxv_probe/macpcs64_ex/macpcs64_ex/imports/macpcs64_pkt_gen_mon.v:1091-1098,1104-1111` |
| `tuser` = 帧错 | 同上 `:1076`（RX）、`:1101`（TX） |
| ctl_* 稳态取值 | 同上 `:1380-1395`、`:2497-2510` |
| 时钟约束（3 个用户钟） | `xxv_probe/pcs64/pcs64.gen/sources_1/ip/pcs64/synth/pcs64_ooc.xdc`；`.../synth/pcs64.xdc`；macpcs64 同 |
| `rx_core_clk = rx_clk_out` 自环 | `xxv_probe/pcs64_ex/pcs64_ex/imports/pcs64_exdes.v`（`assign rx_core_clk_0 = rx_clk_out_0;` 及其后的 `3'b101`/`1'b0` 组） |
| 厂商 example 设计（可跑仿真） | `xxv_probe/pcs64_ex/pcs64_ex/imports/pcs64_exdes{,_tb}.v`、`xxv_probe/macpcs64_ex/macpcs64_ex/imports/macpcs64_exdes{,_tb}.v` |
| IP 自己的 XDC 不给 IBUFDS_GTE4 定 LOC | `xxv_probe/pcs64/pcs64.gen/sources_1/ip/pcs64/ip_0/synth/pcs64_gt.xdc:57`（只有 CHANNEL）；`synth/pcs64_board.xdc`（空） |
| 坑 1 原文 | `xxv_probe/macpcs64/macpcs64.runs/impl_1/runme.log:117,118,183` |
| 坑 2 原文 | `xxv_probe/pcs64/pcs64.runs/impl_1/runme.log:639,664`；`.../macpcs64.runs/impl_1/runme.log:644,669` |
| 坑 3 原文 | `xxv_probe/pcs64/pcs64.runs/impl_1/runme.log:247`；`.../macpcs64.runs/impl_1/runme.log:252` |
| 资源报告 | `xxv_probe/{pcs64,macpcs64}/*.runs/{synth_1,<tag>_synth_1}/*_utilization_synth.rpt` |
| **PCS-only 位流产出**（`Bitgen Completed Successfully` / `write_bitstream completed successfully` / 125 Infos, 0 Errors） | `xxv_probe/pcs64/pcs64.runs/impl_1/runme.log:824,826,827`；位流 `.../impl_1/probe_pcs64_top.bit`（15,431,266 B，sha256 `86fe9c7b…6a905`） |
| **MAC+PCS 位流被 license 拒** | `xxv_probe/macpcs64/macpcs64.runs/impl_1/runme.log` 尾部（`[Common 17-69]` / `require licenses greater than a Design Linking license`） |
| `[Vivado 12-1790] Evaluation License Warning` 原文 | `xxv_probe/pcs64/pcs64.runs/impl_1/runme.log:801-807`；`.../macpcs64.runs/impl_1/runme.log` 同段 |
| 路由后时序（-1） | `xxv_probe/macpcs64/macpcs64.runs/impl_1/probe_macpcs64_top_timing_summary_routed.rpt:145-150`；`.../pcs64.runs/impl_1/probe_pcs64_top_timing_summary_routed.rpt` 同段 |
| 放置后资源 | `xxv_probe/*/*.runs/impl_1/probe_*_utilization_placed.rpt`；`.../sysnt_1/`（综合）同 |
| 本探针的构建脚本 | `xxv_probe/tcl/s1_prepare.tcl` `s2_config.tcl` `s3_example.tcl` `s4_build.tcl` `s5_build.tcl`（+ `run_s1/s2/s3/s4/s5/s5_pcs64/s5_macpcs64.bat`） |
| 本探针的 RTL / XDC | `xxv_probe/rtl/probe_{pcs64,macpcs64}_top.v`；`xxv_probe/xdc/probe_{pcs64,macpcs64}.xdc`（+ `*_impl_only.xdc` 自动生成） |
| 旧（**非 KU5P**）license 否定对照 | `_lic/syn_stdout.txt:868`（建在 `xc7k70tfbv676-1`，**不引为 KU5P 结论**） |
| 冻结的帧流合同 | `_proj_10g/notes/P7B_DATAPATH_CONTRACT.md:40-47,63-72,147` |
| GT `gt_10gbr` 实测配置（板级已验收） | `_proj_10g/tcl/build_p7a.tcl:76-107`；读数 `_proj_10g/reports/p7a_ip_config.txt` |

---
