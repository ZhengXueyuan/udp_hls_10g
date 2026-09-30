# P7B_MAC_TIMING_FIX.md —— P7b TX 域时序修复（等价化简，零语义改动）

- 日期：2026-09-30
- 触发：P7b 全设计重跑后 `P7B_WNS = −0.173` / **39 个 setup 失败端点**，全部落在
  `txoutclk_out[0]_1`（MAC TX / X0Y5 ch1 @156.25 MHz）。
- 性质：**修复报告**。改了 **1 个文件 / 5 处 / +28 −1 行**，全部是**等价化简**，无流水、无拍序改动。
- 纪律：**未烧板**、**未写 QSPI**、**未动 license**、**未碰 `D:\repo\perfv`**、**未做任何 git 写操作**、
  **未跑全设计构建**（按任务书由主线统一安排）、**未放宽约束 / 未改 XDC / 未加 false path**。
- 证据强度：【实测】= 本轮工具读数（文件 + 行号）；【推论】= 由读数推出；【未核实】= 不得当判据用。

---

## 0. 一页结论

| 项 | 结论 |
|---|---|
| **改了什么** | `_proj_10g/p7b_mac/rtl/mac_tx_10g.v`：把 `lw_ts`（尾起始 lane）从**两个进位链**里解放出来，改由**新寄存器 `padrem`（= max(0,60−plen)）**算。新增 `reg [5:0] padrem` + 3 处同拍赋值 + 1 行 `lw_ts` 重写。 |
| **为什么最小** | **零新增/删除逻辑层次**（只是把"进位链 + 比较器"换成"寄存器 + 比较器"）；`crc_keep/crc_d/crc_en` **一字未动**；不动 `crc32_64.v`、不动 `mac_rx_10g.v`、不动 XDC、不动接口、不动状态机、不动任何拍序。 |
| **等价性** | ① 单元门日志**逐行 byte-diff 只剩一行时间戳**（337 条判据行全同）；② 穷举 14409 组 `(plen,cw_len)` 逐点相同 + `padrem` 不变式零违反（`eqv_lw_ts.py`）。 |
| **三个验证** | ① MAC 单元门 **337 checks / 0 fail**（改前 = 改后逐行相同）+ 变异 **15/15 期望一致（MUT_VERDICT = PASS）**；② 链级门 **80 PASS / 0 FAIL**；③ 时序实测（OOC，见 §5.3）**忠实探针上同一 RTL 从 +0.199 → +0.677（+0.478 ns，全设计同款 strategy）**。 |
| **对全设计的预测** | 【推论】`−0.173 + 0.478 ≈ **+0.3**` ⇒ 39 → 0。**未验证**（我不能跑全设计构建）。 |
| **换 strategy 能不能收掉这 39 条** | 【实测】能撼动，但**不可控**：同设计同 RTL 只换 strategy，TX 域 slack 实测摆动 **0.197 ns（忠实探针）/ 0.464 ns（端口探针）**；且方向可以反（`Performance_ExtraTimingOpt` 在这里**比默认策略差**）。**它是掷硬币，不是修复** —— 见 §7.3。 |

---

## 1. 嫌疑核实（**独立核实，不是照抄任务书**）

### 1.1 逐字差异：`effef26` 到底加了什么【实测】

任务书给的两份件**逐字节对照**过（`_proj_10g/p7b_mac_synth/rtl/mac_tx_10g.v` = 修复前快照
`b1f4aaff…`；`_proj_10g/p7b_mac/rtl/mac_tx_10g.v` 改前 = `1e4a61b6…`，且 `git diff HEAD` 为空
⇒ 改前件 **== `effef26` 提交件**，只是 CRLF/LF 之别）。`effef26` 对 TX 的改动**只有三类**：

| # | 新增量 | 是否进入"寄存器 → PCS"的组合链 |
|---|---|---|
| 1 | `cmask64(cw_len)` → `crc_d = cw_data & cmask64(cw_len)` | 是（但起点是**寄存器** `cw_len`/`cw_data`，且只到 `zb*` 掩码） |
| 2 | `crc_keep = … : (cw_last ? (8'hFF << (5'd8 - **lw_ts**)) : cw_keep)` | ⭐ **是，且起点是组合量 `lw_ts`** |
| 3 | `p0_fcs = crc_nxt ^ 32'hFFFFFFFF`（S_TAIL0 用） | 是（S_TAIL0 分支） |

**唯一把"组合算术"接进 CRC 的是第 2 条**：`crc_keep` 原来恒等于寄存器 `cw_keep`
（改前 `en/d/keep` 三个输入全是寄存器），改后**在末内容字那一拍等于 `f(lw_ts)`**。

### 1.2 为什么这一条就是那 39 条【实测】

- 39 条失败端点**同一个起点**：`u_mac_tx/plen_reg[6]/C`；终点全在 PCS TX 编码器。
- 最差路径的**逐段构成**（`board/p7b_ku5p_timing.rpt:787` 起）：
  `plen_reg[6] → CARRY8 plen_reg[7]_i_2 → CARRY8 plen_reg[15]_i_2 (lw_L[14]) → m_pad_left[5]_i_27 →
   m_pad_left[5]_i_16 → plen_reg[3]_1 → FSM_…_i_4__1 → cw_len_reg[2]_3 → u_pcs_i_323 → u_pcs_i_75 →
   crc[31]_i_93 → crc[31]_i_57 (**crc_keep[6]**, fo=37) → crc[28]_i_33 (fo=34, 布线 0.777 ns) →
   crc[9]_i_22 → crc[9]_i_8 → crc[9]_i_7 → crc[9]_i_2 → crc[9]_i_1 (**crc_nxt[9]**) →
   u_pcs_i_231 → u_pcs_i_105 → u_pcs_i_7 → [PCS 内部 3 级] → FDRE`
  ⇒ 就是 `lw_ts → crc_keep → popc/m_cnt → corr(9选1) → crc_nxt → lw_fcs → merge_d → PCS`。
- **改前那一轮**（`_proj_10g/notes/p7b_timing_rerun/before/p7b_ku5p_timing.rpt:767` 起）TX 域最差路径
  **已经是同一族的头**：`u_mac_tx/plen_reg[0] → CARRY8 → lw_L[7] → … → m_pad_left[5]_i_17 →
   m_tptr[2]_i_7 → … → PCS`，**15 级 / +0.625 ns**（那时它不经过 CRC）。
  ⇒ **pad/FCS 修复没有制造新家族，只是把同一个家族从 15 级拉到 21 级**（−0.798 ns）。

> ⚠️ 但 **−0.798 不能全记在这条链头上**：同一次构建里 **MAC RX 域（RTL 一行未动）也掉了 0.289 ns**
> ⇒ 其中**至少有一部分是"网表变了 ⇒ 布局布线全变"的全局项**。定量的因果量只能用 OOC 隔离测量（§5.3）。
> 另：改前件在全设计里是 `plen_reg[0]` 起点、改后是 `plen_reg[6]` —— 起点不同本身就是布局漂移的证据。

---

## 2. 改法（逐处，文件:行）

文件：`_proj_10g/p7b_mac/rtl/mac_tx_10g.v`（改后 sha256 `034282a37764b9ffe8b98d6bc9d2b8e7a7d10174caf2cae569654a9e9720f7bd`）

| # | 行 | 改动 |
|---|---|---|
| 1 | **105–111** | 新增 `reg [5:0] padrem;`（= `max(0, ETH_MIN_CLEN − plen)`，plen 的寄存器副本） |
| 2 | **248–249** | `lw_ts` 重写：`(padrem > 6'd8) ? 5'd8 : (({1'b0,cw_len} > padrem[4:0]) ? {1'b0,cw_len} : padrem[4:0])` |
| 3 | **322** | 复位：`padrem <= ETH_MIN_CLEN[5:0];`（与 `plen <= 16'd0` 同拍） |
| 4 | **345** | `S_PRE`：`padrem <= ETH_MIN_CLEN[5:0];`（与 `plen <= 16'd0` 同拍） |
| 5 | **387** | `S_DATA` 非末字：`padrem <= lw_pad;`（与 `plen <= plen + cw_len` 同拍） |

### 2.1 等价性推导（写进 RTL 注释，此处复述）

```
原:  lw_L = plen + cw_len ;  lw_pad = max(0, 60−lw_L) ;  lw_ph = min(lw_pad, 8−cw_len)
     lw_ts = cw_len + lw_ph
新:  padrem = max(0, 60−plen)  [寄存器, 与 plen 同拍更新] ;  lw_ts = min(max(cw_len, padrem), 8)
```
证明（两种情形穷尽）：
- `plen+cw_len ≥ 60`：原式 `lw_pad=0 ⇒ lw_ph=0 ⇒ lw_ts=cw_len`；
  新式此时 `60−plen ≤ cw_len ⇒ max(cw_len,padrem)=cw_len ⇒ min(…,8)=cw_len` ✔
- `plen+cw_len < 60`：原式 `cw_len + min(60−plen−cw_len, 8−cw_len) = min(60−plen, 8)`；
  新式 `max(cw_len,60−plen) = 60−plen`（因 `60−plen > cw_len`）⇒ `min(60−plen,8)` ✔

**不变式**：`padrem` 的赋值恰好是 `lw_pad`（本拍已算出的量），而 `lw_pad = max(0,60−(plen+cw_len))`
正是**下一拍的** `60 − plen` ⇒ 两寄存器永远描述同一个 `plen`，**无相位差**。
除 `S_DATA`/`S_PRE`/复位外，`lw_ts` 不被使用（`S_IDLE/S_IFG/S_ABORT` 的 `tx_d` 是常量分支），
所以不存在"陈旧 padrem"被读到的窗口。

### 2.2 为什么这是最小改动

1. **没有新增任何逻辑层次**：`padrem` 的比较/选择只有 2 级（`padrem>8` 与 `cw_len>padrem` 都是
   **寄存器到常量**的比较），替换掉原来"2 个 CARRY8 + 1 个减法比较 + 1 个选择 + 1 个加法"。**净减 ~5–6 级**。
2. **不碰模块接口 / 不碰 `crc32_64.v`**（那是 RX 共用的件，动它要同时改 `mac_rx_10g`，所有权与风险都更大）。
3. **不碰状态机、不碰拍序**：没有流水、没有 valid/pulse 寄存器 ⇒ 工程坑 6/12 的自伤面为零；
   XGMII 字流、`/S/`、`/T/`、IFG、字节序合同（`tdata[63:56]` 首发 + `align8/bswap64` 镜像）**全未触及**。
4. **不碰 `crc_keep/crc_d/crc_en` 三行**：它们语义正确，且是变异 M11a/M11b/M11c 的**锚点**
   （改了会让三条判据静默脱靶 —— 这也是一处"改动会废掉门"的陷阱）。

---

## 3. 验证①：MAC 单元门（`_proj_10g/p7b_mac/sim/run_tb_mac_10g.bat`）

```
=== tb_mac_10g done: 337 checks, 0 fail ===
VERDICT = PASS
```
与**修复前基线 337 / 0 一致**（改前我实测同门 = 337 checks / 0 fail，`logs/gate_mac_PREFIX.log`）。

### 3.1 变异测试 `scripts/mutate_gate.py`（15 条，含全部 M11 pad/CRC 族）

```
MUT_VERDICT = PASS (不等价变异漏掉 0 条)
  OK  M1   TX 字节序镜像变直通                expect=caught  got=caught
  OK  M1b  RX 字节序镜像变直通                expect=caught  got=caught
  OK  M2   CRC 残留魔数换大端魔数              expect=caught  got=caught
  OK  M3   F4 空间门退回寄存器 full           expect=caught  got=caught
  OK  M4   RX FCS 剥离关闭                  expect=caught  got=caught
  OK  M5   RX 起始 lane 不锁存               expect=caught  got=caught
  OK  M6   TX IFG 12→4                     expect=caught  got=caught
  OK  M7   TX F-2 冲刷被拆掉                 expect=caught  got=caught
  OK  M7b  TX 幽灵帧 + 计数器伪装             expect=caught  got=caught
  OK  M8   (等价) hi>=8 写成 hi>7            expect=missed  got=missed
  OK  M9   (等价) /T/ lane 判定等价写法        expect=missed  got=missed
  OK  M10  RX 帧闭合条件拆掉                 expect=caught  got=caught
  OK  M11a DEFECT#1 复现 (pad 不进 CRC)      expect=caught  got=caught
  OK  M11b pad 只从末内容字 CRC 去掉          expect=caught  got=caught
  OK  M11c pad 只从 S_TAIL0 续字 CRC 去掉     expect=caught  got=caught
  OK  M11d (等价) p0_rst!=0 写成 p0_use==8   expect=missed  got=missed
```
原件：`_proj_10g/notes/p7b_mac_timing_fix/logs/mutate_gate_postfix.txt`（改前 = 我复跑的 `337/0` 也在同目录）。
**M11b 的锚点正是 `cw_last ? (8'hFF << (5'd8 - lw_ts)) : cw_keep` 那一行 —— 我改的是 `lw_ts` 的来源，
没有碰这行的文本, 所以该变异仍然抓得住（实测 caught）**。

---

## 4. 验证②：链级门（`_proj_10g/p7b_chain/sim/run_tb_p7b_chain.bat`）

```
VERDICT = PASS          （grep -c "[PASS]" = 80, grep -c FAIL = 0）
```
与基线 **80 判据 / 0 失败**一致（`logs/gate_chain_PREFIX.log` vs 修复后重跑）。

---

## 5. 验证③：时序实测（**小规模** OOC synth+impl+report_timing_summary）

### 5.1 先说方法学上的一个坑：**旧口径探针测的不是那条路径**【实测】

`_proj_10g/p7b_mac_synth` 原有的 `mac_tx_min_top` 把 XGMII 直接接到**输出端口**。
输出端口的 `DCD = 0`，而源寄存器背着 ~2.0 ns 的时钟插入（`SCD`）⇒ 每条 reg→port 路径被白扣
**−2.003 ns**（该件自己在 `P7B_MAC_TIMING.md` §2.3 记过这条偏置），于是 OOC 报出来的最差路径
永远是 `cw_keep_reg → xgmii_txd[*]`，**不是**全设计里失败的那条 `plen → PCS 捕获寄存器`。
⇒ 我加了一个**忠实探针** `rtl_probe/mac_tx_sink_top.v`：MAC 不变，只在 XGMII 出口加**一级捕获寄存器**
（就是 PCS 里那个捕获寄存器的模型，同钟、前面无逻辑）⇒ 端点变成**内部寄存器**，偏置消失。
两个口径都测，**结论只看 §5.3 的忠实口径**。

### 5.2 旧口径（端口端点，含 −2.003 ns 伪偏置；仅供对账）

| arm | RTL | strategy | WNS | 最差路径 sp→ep | 级数 |
|---|---|---|---|---|---|
| 归档 | 修复前 | ExtraTimingOpt | +0.285 | cw_keep_reg[7] → xgmii_txd[19] | 9 |
| A_old | 修复前 | **默认(无 directive)** | **+0.749** | cw_keep_reg[7] → xgmii_txd[11] | 10 |
| B_new | pad 修复（即失败那轮） | 默认 | **+0.101** | **plen_reg[1]** → xgmii_txd[20] | 18 |
| C_fix | **本次修复** | 默认 | **+0.201** | **padrem_reg[2]** → xgmii_txd[45] | **12** |

### 5.3 忠实口径（寄存器端点）—— **这一组是判据**

`rtl_probe/mac_tx_sink_top.v`（MAC 逐字节不变）。前 6 臂 strategy = 默认；后 3 臂 = 全设计同款的
`Performance_ExtraTimingOpt`。

| arm | RTL | strategy | **WNS** | 最差路径 sp→ep | 级数 |
|---|---|---|---|---|---|
| S_old / A_old2 | 修复前 | 默认 | **+1.502 / +1.502** | cw_len_reg[2] → stat_tx_ctrl_char_reg[31] | 15 |
| S_new | pad 修复 | 默认 | **+0.282** | **plen_reg[1] → cap_d_reg[62]** | 18 |
| S_fix / S_fix2 | **本次修复** | 默认 | **+0.874 / +0.874** | **cw_len_reg[2] → cap_d_reg[41]** | **12** |
| C_fix_explore | 本次修复 | Performance_Explore | **+0.874** | 同上（**逐位相同**） | 12 |
| E_old_eto | 修复前 | ExtraTimingOpt | **+1.033** | cw_keep_reg[5] → cap_d_reg[24] | 10 |
| E_new_eto | pad 修复 | ExtraTimingOpt | **+0.199** | **plen_reg[0] → cap_d_reg[45]** | 18 |
| **E_fix_eto** | **本次修复** | ExtraTimingOpt | **+0.677** | **cw_len_reg[2] → cap_d_reg[52]** | **12** |

**同 flow（ExtraTimingOpt）的三个因果量【实测】**：
- **pad/FCS 修复的代价**：`+1.033 → +0.199` = **−0.834 ns**（18 级 vs 10 级）
- **本次修复收回**：`+0.199 → +0.677` = **+0.478 ns**（12 级 vs 18 级；起点从 `plen_reg` 换成 `cw_len_reg`）
- 相对修复前仍差 **−0.356 ns** —— 那是"pad 必须进 FCS"这个**正确性需求**的固有价格，不是缺陷

**修复后那条最差路径逐格长什么样【实测】**（`reports/E_fix_eto_sink_worst_path.rpt`，slack +0.677 / 12 级）：

```
u_dut/cw_len_reg[2]/C
  → u_crc/cap_c[5]_i_5            (LUT6)   ← lw_ts 第 1 级 (cw_len 与 padrem 的比较)
  → u_crc/cap_d[63]_i_9           (LUT6)   ← lw_ts 第 2 级 + 选路
  → u_crc/crc[31]_i_84 … crc[28]_i_30 … crc[21]_i_21 … crc[4]_i_15 … crc[4]_i_5
  → u_crc/crc_reg[4]_i_2          (MUXF7)  ← ⭐ CRC 的 **9 选 1 修正 mux** (nv0..nv8)
  → u_crc/crc[4]_i_1              (= crc_nxt)
  → merge_d → cap_d_reg[52]/D
```
⇒ **来源换成了寄存器**（`cw_len`/`padrem`），**剩下的大头是 CRC 的"popc → m_cnt → 9 选 1 修正"**，
与 §7.2 P1 的判断一致。（改前同一位置是 18 级、起点是 `plen_reg`。）

**对全设计的预测【推论，未核实】**：全设计失败那一轮 = `pad 修复` RTL，TX 域 −0.173（21 级）与
`E_new_eto` 的 18 级同构（多出的 3 级在 PCS 内部）⇒
`−0.173 + 0.478 ≈ **+0.3 ns**` ⇒ **39 → 0**。
⚠️ 这是**外推**：OOC 与全设计的布局不同，且 §7.4 的全局项不可控。**必须由主线的合并构建裁决。**

### 5.4 可复现性与"抖动"的真实来源【实测】

- `S_fix` / `S_fix2` / `C_fix_explore` 三次构建 **WNS、级数、logic/net 延迟逐位相同（+0.874 / 12 / 1.672 / 3.792）**
  ⇒ **同 flow 是确定性可复现的**，"跑两次不一样"不成立。
- 归档 `+0.285` vs 我的 `+0.749`（**同一份 RTL**）：差异来自**strategy**——
  归档那轮用 `place_design -directive ExtraTimingOpt` + `route_design -directive NoTimingRelaxation`，
  我的默认臂用无 directive 的默认流程。**不是随机抖动，是我一开始没把 strategy 对齐**（已在本轮补齐 §5.3 的 E_* 三臂）。

---

## 6. 等效性凭证

### 6.1 单元门日志逐行 diff（**最强的一条**）

```
$ diff <(grep -v '^#' gate_mac_PREFIX.log) <(grep -v '^#' gate_mac_POSTFIX.log)
378c378
< INFO: [Common 17-206] Exiting xsim at Wed Sep 30 10:13:36 2026...
---
> INFO: [Common 17-206] Exiting xsim at Wed Sep 30 10:15:19 2026...
```
⇒ **337 条判据行 + 汇总行 + `VERDICT` 全部逐字节相同，唯一差异是一行时间戳。**
（sha256：`gate_mac_PREFIX.log = c318abbd…` / `gate_mac_POSTFIX.log = 82dcb1cf…`；
链级门同理 80/80 全 PASS。）

### 6.2 穷举等价证明（`eqv_lw_ts.py`，14409 点）

```
exhaustive compare: 14409 points, 0 mismatch          [plen 0..1600 × cw_len 0..8]
padrem invariant over all single steps: 14409 steps, 0 violations
S_PRE reset point (plen=0,padrem=60) agrees: True
EQV_VERDICT = PASS
```
原件 `_proj_10g/notes/p7b_mac_timing_fix/logs/eqv_lw_ts.txt`。
（这条证明的是**组合等价**；寄存器层面的"同拍更新、无相位差"由 RTL 结构保证，见 §2.1 不变式。）

### 6.3 覆盖面声明

- 单元门覆盖：CRC 自检 / 逐字节 FCS / 短帧 pad / pad 进 FCS / TX→RX 自洽回放 / 幽灵帧 / 中止 /
  IFG / 突发 / 边界（含 L=1、20B、42B、54B、60B、1514B）。
- 链级门覆盖：MAC 单通道整链（含 PCS socket 模型）。
- **未覆盖**：全设计集成、板级、位流级 DRC（不属本轮）。

---

## 7. 残余风险与下一步

### 7.1 预测未验证（最高优先）

我**没有跑全设计构建**（任务书要求由主线统一安排）。上面的 `+0.3` 是外推。
⇒ **下一步就是主线的合并构建**：判据 = `txoutclk_out[0]_?` 组 setup 失败端点 = 0 且 `P7B_WNS > 0`。

### 7.2 若全设计仍不收敛，下一刀在哪（按本工程"等价化简 > 拆流水"排序）

| 优先级 | 动作 | 依据 / 代价 |
|---|---|---|
| **P1** | 砍 `crc_keep → popc8(keep) → m_cnt → 9 选 1 corr` 那 ~6 级：给 `crc32_64` 加一个 `cnt` 输入端口（`m_cnt` 直接给），TX 用 `8−lw_ts` 驱动（`= 8 − min(max(cw_len,padrem),8)`，两个寄存器就能算）。**注意**：`crc32_64` 是 TX/RX 共用件，加端口必须**同时**改 `mac_rx_10g.v` 的例化（当前所有权不覆盖）⇒ **需要主线指派**。 | 修复后最差路径 12 级里，前 2 级是 `lw_ts`，**剩下 6 级全在 CRC 的 popc/mux 网络**（§5.3 末的逐格路径） |
| **P2** | `mac_rx_10g` 的"逐 lane 解码 + 残差比较器"（RX 域最差 +0.206，尚未失败，但同族） | `P7B_MAC_TIMING.md` §6 P1 |
| **P3** | 拆流水（XGMII 出口加一级寄存器）—— **本轮明确不做**：它改变 MAC↔PCS 的拍级合同，必须逐位证明 `/S/`、`/T/`、IFG 落位不变；收益（省掉 PCS 内部那 3 级）也小于本轮的等价化简 | 任务书 §纪律 2 |
| — | ⚠️ **不要**用 `set_false_path` / 改周期 / 改 XDC 掩盖 | 任务书铁律 |

### 7.3 直接回答："在当前 RTL 上换 strategy/seed 是否更可能直接收掉这 39 条？"

**实测答复：能撼动，但不可控，且不解决因果 —— 不建议当作修复手段。**

- 敏感度量级【实测】：忠实探针上、**同一份修复后 RTL**，
  默认 = `+0.874`、`Performance_Explore` = `+0.874`、`Performance_ExtraTimingOpt` = `+0.677`
  ⇒ 摆动 **0.197 ns**；端口探针上、**同一份修复前 RTL**，ExtraTimingOpt `+0.285` vs 默认 `+0.749`
  ⇒ 摆动 **0.464 ns**。
- 而 39 条失败端点的 slack 区间是 **−0.173 … −0.003（均值仅 −0.075）** ⇒ 0.2–0.46 ns 的摆动
  **确实足以**把它们整体推过零。
- **但**：① 方向不可控（这轮 `Performance_ExtraTimingOpt` 反而**比默认差 0.464 ns**，与它名字的暗示相反）；
  ② 它**不改变**"pad 修复把这条链从 10 级拉到 18 级"这个事实 —— 换个 seed 让 slack 转正，
  下一次任意 RTL 改动又会把它翻下去；③ 本项目已有"静默地换了个东西跑"的惨痛先例（真空门史）。
- ⇒ **推荐组合**：先吃本次 RTL 修复（+0.478 ns 的确定性收益），若合并构建仍差一点点，
  **再**叠加 strategy 搜索（那时 strategy 是"锦上添花"而不是"遮羞布"）。

### 7.4 全局扰动项的定性【实测 + 推论】

- 全设计同一对构建里 **MAC RX 域也掉了 0.289 ns**，而 `mac_rx_10g.v` / `rx_classify.v` 构建前后
  **逐字节未变** ⇒ 这一块**只能是**"网表变了 ⇒ 布局布线整体重排"的**全局项**（CLB 用量 15619→16231、
  LUT 69886→69613 ⇒ 确实重排了）。**不得**把它记在 CRC 链的账上（同理，−0.798 里也含这一项）。
- 【推论】因此"全设计 −0.173"与"OOC 因果 −0.834（pad 修复）/+0.478（本次修复）"是**两个口径**，
  不可互相加减；上面的预测用的是"同 flow 同探针"的差量 **+0.478**，这是我能做的最干净的一条。

### 7.5 未做 / 未核实（不得当判据用）

| # | 项 | 状态 |
|---|---|---|
| U1 | 全设计合并构建 | **未跑**（任务书禁止）⇒ `+0.3` 是外推 |
| U2 | 板级 | **未烧**、**未写 QSPI**（本轮与板无关） |
| U3 | 位流级 DRC | OOC 只到 `route_design`；`12-4739`（约束被静默丢弃）实测 **0** |
| U4 | `mac_tx_min_top` 端口口径的绝对值 | 含 −2.003 ns 伪偏置，**不要引用它的绝对值** |
| U5 | RX 域 | 本轮**未改任何 RX 件**；RX 域的 −0.289 归全局项（§7.4），**未做隔离构建证伪** |
| U6 | strategy 敏感度的普适性 | 只在**本设计的 OOC 探针**上量到 0.197/0.464；不能外推到全设计 |

---

## 8. 证据索引

### 改动件
- `_proj_10g/p7b_mac/rtl/mac_tx_10g.v` — 改后 sha256 `034282a37764b9ffe8b98d6bc9d2b8e7a7d10174caf2cae569654a9e9720f7bd`
  （`git diff HEAD` = **28 insertions / 1 deletion**；`crc32_64.v` / `mac_rx_10g.v` / XDC / wrapper **未改**）

### 新增探针（**只属本轮**，不进构建）
- `_proj_10g/notes/p7b_mac_timing_fix/rtl_probe/mac_tx_sink_top.v` — 忠实探针（XGMII 出口加一级捕获寄存器）
- `_proj_10g/notes/p7b_mac_timing_fix/rtl_probe/mac_tx_sink.xdc`（= `mac_tx_min.xdc` + `cap_sig` 的输出延迟）
- `_proj_10g/notes/p7b_mac_timing_fix/tcl/run_ooc.tcl` + `tcl/run_ooc.bat`（**参数化 RTL 目录 + strategy** 的 OOC 流程）
- `_proj_10g/notes/p7b_mac_timing_fix/eqv_lw_ts.py` — 穷举等价证明
- `_proj_10g/notes/p7b_mac_timing_fix/stale_copy/new_padfix/` — **pad 修复后 / 时序修复前**的 RTL 快照
  （= `effef26` 的交付件，用于 A/B/C 三臂对照）
- `_proj_10g/notes/p7b_mac_timing_fix/tcl/path_cells.{tcl,bat}` — 打开 routed dcp 取最差路径逐格
  （产物 `reports/E_fix_eto_sink_worst_path.rpt`，见 §5.3 末）

### 日志（`_proj_10g/notes/p7b_mac_timing_fix/logs/`）
`gate_mac_{PREFIX,POSTFIX}.log`（337/0 逐行 diff）· `gate_chain_PREFIX.log`（80 PASS）·
`mutate_gate_postfix.txt`（MUT_VERDICT = PASS）· `eqv_lw_ts.txt` ·
`{A_old,A_old2,B_new,C_fix,C_fix_alt,C_fix_explore,S_old,S_new,S_fix,S_fix2,E_old_eto,E_new_eto,E_fix_eto}_stdout.txt`
（每份含 `_WNS/_WHS/_FAILING_ENDPOINTS/_IMPL_STATUS/_max_P*` 与 Intra Clock Table）

### 只读引用
`board/p7b_ku5p_timing.rpt`（失败读数）· `_proj_10g/notes/p7b_timing_rerun/before/p7b_ku5p_timing.rpt`
（改前 +0.625 那轮）· `_proj_10g/notes/P7B_TIMING_RERUN.md` · `_proj_10g/notes/P7B_MAC_TIMING.md` ·
`_proj_10g/p7b_mac_synth/reports/mac_tx_ooc_setup_paths.rpt`（归档 +0.285）
