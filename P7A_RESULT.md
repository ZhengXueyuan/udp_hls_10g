# P7a 板级验收记录（**正式验收**，2026-09-29）

> 验收对象 = `_proj_10g/vivado_prj/p7a_prj.runs/impl_1/p7a_top.bit`
> （**含 64b/66b gearbox 的 10GBASE-R PCS/PMA 通路**，quad 225 的 X0Y4/X0Y5 经 AOC 外部环回）。
> 本文件的每一个数字都能指到 `_proj_10g/` 下的**原始读数文件（含行号）**；从别处转述的读数一律注明来源。
> 施工规格（闸 0）在 `P7A_SPEC.md`；本节只记**已经发生的事**与**已经读到的数**。

## 0. 一句话结论

**通过（PASS）。** 这块板（`xcku5p-ffvb676-1-e`）的 **10G PCS/PMA 通路（含 64b/66b gearbox）已实测达标**：

| 项 | 读数 | 出处 |
|---|---|---|
| **BER（双向各 10 分钟）** | 每向 **6,003,265,225,472 bit / 0 错 / 0 头错** ⇒ 95% 置信上界 **4.997×10⁻¹³** | `board_scratch/logs/p7a_board_stdout.txt:707-726` |
| **速率（gearbox 正证据）** | **1.000025×10¹⁰ bit/s**（偏 +0.0025%）；整窗比率 **0.999995**（raw 会是 1.031250） | 同上 `:711-713` |
| **gearbox 三条腿** | 静态网表属性 / 频率恒等式 / 动态 `rxgearboxslip` 负对照 —— **全齐** | 本文 §3 |
| 阶段 1 对照件（iBERT 镜像） | LOS 0/0 · LINK 10.312 / 10.313 Gbps 双向立起 · 60 s 差分 6.27×10¹¹ bit **零错** | `ctrl_scratch/ctrl_console_v4.txt:331-337,359-360,376` |
| 时序 / DRC | `WNS +3.178 / WHS +0.018`，**0 失败端点**；DRC 无阻断项 | `reports/p7a_readback.txt:1370-1373` · `reports/p7a_drc.rpt` |
| 单元门 | **437 checks / 0 failures**，含**撕裂负对照 200 违例** | `sim/xsim_run.txt:63-83` |
| 位流 | `sha256 = f88d019f…8651d`（归档时**又独立算了一遍**，逐位相同） | `reports/p7a_bitstream_sha256.txt` + 本文 §6 |

**中途两次停下**（都不是被测对象的缺陷）：run1 = **物理拓扑错**（AOC 两头没落在板子的两个 SFP 笼子上），
run2 = **测量台架缺陷**（读点前没发快照请求 ⇒ 读的是冻结值 ⇒ "前后对比"变成拿一个值和它自己比）。
两次的处置与证据见 §5。

---

## 1. 目标，以及"为什么它是当时最大的未知数"

**目标**：证明 10G **PCS/PMA 一层**（不是模拟层）真的在跑 —— 即 **64b/66b gearbox 在数据通路里**，
并且 BER 优于 10GBASE-R 的 1×10⁻¹² 要求。

**为什么它单独是一个未知数**：2026-09-27 的 iBERT 轮把**模拟链路**测透了
（外部环回 BER < 2.4×10⁻¹²、双向各 1.239 Tbit 零错误；转述自 `../CLAUDE.md` 「本板实测修正 §1b」，
本轮**未复算**那一批原始读数），但那一轮的 GT 跑的是 **raw**：

- 本轮自己重读了**同类对照件镜像**（`ctrl_scratch/ibert_top_v3_corrected_map.bit`，sha256 `d5566b93…`）的
  datapath 配置：`TX_DATA_WIDTH = 80` / `TX_INT_DATAWIDTH = 2` / **`TXGEARBOX_EN = FALSE`** /
  **`RXGEARBOX_EN = FALSE`** —— 原始读数 `ctrl_scratch/ctrl_console_xdiag.txt:141-151`
  （脚本把要读的属性清单也打了出来，见同文件 `:141`）。
  ⇒ **"模拟链路干净"与"PCS/gearbox 能跑"是两件独立的事**：前者已经测过，后者一行证据都没有。
- 这也是"这块板能不能做 10G"最后一个**可能在逻辑层翻车**的地方：
  手册的 12 GHz 限制讲的是**连接器/板材**（模拟），管不到 gearbox；而 gearbox 一旦不成立，
  10GBASE-R 就根本无从谈起（fabric 侧会变成 161.1328125 MHz 的 64-bit raw 流，不是 156.25 MHz）。

**本阶段的判据设计原则**（写在 `P7A_SPEC.md` §4/§5，此处只留结论）：
不用 wizard example 的 `link_status_out`（它是**漏桶**：一次错只扣 34/67 ⇒ 容忍孤立错误，
"看着干净"≠零误码，`P7A_SPEC.md` §1.5）；BER 由**自己写的计数器** `rtl/p7a_counters.v` 判定，
语义可复算（`rtl/p7a_counters.v:1-50` 头注释）。

---

## 2. 上板流程与次序（每条都有实测教训）

```
① 前置闸: 确认没有 Vivado 构建/xsim 在跑（本工程的既有坑：不得从"被构建的工程"烧位流）
② 自核位流身份: sha256 与 .ltx 都要对（board_scratch/logs/hashes.txt:3-24）
③ JTAG 烧录（经 a@192.168.0.38:3121 的 hw_server，**volatile、未碰板载 QSPI**）
   判据 = 'End of startup status: HIGH' 且 DONE_PIN == 1
④ 安全闸: 单器件 + IDCODE == 04A62093，不满足就直接 exit 1（不编程）
⑤ VIO 探针自检: 11 个探针名与位宽**逐个断言**（位宽变了=packing 变了 ⇒ abort）
⑥ 读 status 的 build fingerprint 位（bit70）: 必须为 1，证明"探针映射到本次构建"
⑦ 才进入测量
```

原始读数（run3，全部在 `board_scratch/logs/p7a_board_stdout.txt`）：
`wordSize = 4`（`:43`）· `IDCODE=04A62093`（`:85`）· `SAFETY_GATE = PASS`（`:93`）·
`DONE_PIN = 1`（`:110`）· `PROBES RESOLVED -- all 11 present`（`:167`）·
`fingerprint bit 1 must be 1`（`:252-254`）。

**位流 sha256**（本轮产物，`reports/p7a_bitstream_sha256.txt`；归档时独立重算一致）：

```
f88d019fc53a8d07d04d14670188f8148d36e09bb9ba8d1b0df366cbf9f8651d  p7a_top.bit  (15,431,258 B)
5dd5fa692c315c51fa72d7283e67a8b97c235b9b0a63dd78f5137ab1045455db  p7a_top.ltx  (114,407 B)
```

---

## 3. 逐条判据

### 3.1 阶段 1 —— 对照件（iBERT v3 镜像）必须先把"板外那一段"重新证成

前置先验已经存在（09-27），但**本轮所有后续结论都以"同板同线同一条 AOC 现在还能通"为前提**，
所以先跑一遍对照件。原始读数 `ctrl_scratch/ctrl_console_v4.txt`（宿主侧完整捕获）：

| # | 判据 | 期望 | 期望来源 | 实测 | 判定 |
|---|---|---|---|---|---|
| P1a | VIO 采样的 SFP LOS（6 次采样） | **0 / 0** | 模块在位且发光（`XCKU5PMini/CLAUDE.md` 的 SFP 控制脚实测映射） | `SAMPLE-1..6 sfp1=0 sfp2=0`（`:221-226`）· `FINAL 0 / 0`（`:376`） | PASS |
| P1b | X0Y4 / X0Y5 的 `RX_BER` | **≪ 0.5**（0.5 = 无光/无锁） | iBERT 的 BER 语义（同类对照 `ctrl_console_xdiag.txt:114-120` 的 0.5 基线） | `9.617505395581214e-10` / `9.6502768616180211e-10`（`:331-332`） | PASS |
| P1c | 未接线通道作对照 | 仍 ≈ 0.5 | 同一 KPI 的负对照 | X0Y7 `0.48904632359635664`（`:334`） | PASS（对照成立） |
| P1d | 双向 LINK 立起 + 线速率 | 10.3125 GBd 附近 | 10GBASE-R 线速率 | `LINK A_to_B STATUS=10.312 Gbps` / `LINK B_to_A STATUS=10.313 Gbps`（`:336-337`） | PASS |
| P1e | **60 s 差分** bit / 错 | dBITS ≫ 0 且 dERR == 0 | 自定的差分协议（复位错误计数后取两次读数之差） | X0Y4 `dBITS=626584856000 dERR=0 BER=0.0`；X0Y5 `dBITS=626375624640 dERR=0`（`:359-360`） | PASS |

> ⚠️ **读 P1b 的正确姿势**：`RX_BER` 是 iBERT 的**累计**读数（含着此前"全黑"阶段与工程阶段的错误），
> 它**不是**判据；判据是 P1e 的**差分**（`dERR=0 / 6.266×10¹¹ bit` ⇒ 上界 3/B = **4.8×10⁻¹²**）。
> 两个数都列出来，是为了避免后人把累计读数当成本轮 BER。

**这一阶段同时给出了"板外那一段没问题"的当前证据**，后面所有"板内"结论才有归因边界。

### 3.2 阶段 2 —— P7a 位流（`p7a_top.bit`）

原始读数 `board_scratch/logs/p7a_board_stdout.txt`（run3，2026-09-29 17:28:09 起）：

| # | 判据 | 期望 | 期望来源 | 实测 | 判定 |
|---|---|---|---|---|---|
| P2a | 状态字基线 | MMCM 锁、GT 上电、复位完成、CDR 稳、LOS 0/0 | `rtl/p7a_top.v` 的 "SFP control" 注释块 + `../CLAUDE.md` 的 SFP 引脚实测表 | `mmcm_locked=1 gtpowergood=11 tx/rx_reset_done=1 rx_cdr_stable=1 sfp*_rx_los=0`（`:252`） | PASS |
| P2b | PRBS31 锁定（`acq`） | **1/1**，且在 clear 后可重锁 | 计数器语义：`LOCK_THRESH` 连续匹配字（`rtl/p7a_counters.v`） | clear 后 **81 ms** 锁定（`:294-307`；run2 为 73 ms） | PASS |
| P2c | 腿 3：`rxheader` **稳定性** | 采样 5 次恒为同一值，且 `hdr_err_cnt == 0` | `P7A_SPEC.md` §4.3 / R3（**判"稳定"，不是判等于某个猜的常数**） | `hdr_ref ch0=0x01 ch1=0x01 valid=11`，`hdrs` 86406580→689213482 单调，`hdr_err_cnt=0/0`（`:343-368`） | PASS |
| P2d | **负对照 A**：强制 `rxgearboxslip` | 必须**掉链 + 重锁** | raw 通路里没有 gearbox 可滑 ⇒ 该动作本应无效果（`rtl/p7a_top.v` 与 spec §4.3） | Δerr **16640 / 16628**、`ref_down_latched 00→11`、此后 6 s 零错且 `bits` 推进 60829119552、`ref_link` 回 1/1（`:402,419-427,443-458`） | PASS（ERR_BURST/LINK_DROP/RELOCK = 1/1/1） |
| P2e | 短窗 60 s 体检 | 零错、比率 ≈ 1 | 同 P2f | 每通道 `bits=610401810176 err=0 hdre=0`，5 个子窗 ratio 0.999995..0.999995，rate 9.999277e9（`:583-596`） | PASS |
| P2f | **正式窗 600 s × 双向** | 零错 + 速率/比率同时成立 | `P7A_SPEC.md` §5.4 | 见 §4 | PASS |
| P2g | 头计数恒等式 | `hdrs_cnt == bits_cnt / 64` | 计数器语义（每个 payload 字都带 `rxheadervalid`） | `93801019148 == 6003265225472/64`（`:707-709`） | PASS（"0 错"不是真空 0 的旁证之一） |
| P2h | 静态判据（无板） | gearbox 属性 + 频率 + 时序 | `P7A_SPEC.md` §4.1/§4.2/§9 | 见 §3.3 | PASS |
| P2i | 单元门（无板） | 判据本身有判别力 | `P7A_SPEC.md` §9.11 | **437 checks / 0 failures**；`m=2`；注入 K=10 错 ⇒ `err0=20`；注入 5 个头错 ⇒ `hdre0=5 且 err0=0`；200 个快照 正例违例 **0** / **撕裂负对照违例 200**；ratio 156.25→1.000000、161.1328125→1.031252（`sim/xsim_run.txt:63-83`） | PASS |
| P2j | license 负对照 | 把 `Xilinx.lic` 改名后 gtwizard 仍不被锁 | `P7A_SPEC.md` §1.2/§9.1 | 见 §3.4 | PASS |

### 3.3 gearbox 在通路里的**三条腿**（§4 的判据，都是"只有 gearbox 在才算得通"的量）

**腿 1 —— 静态网表属性**（布局后回读原语，`reports/p7a_readback.txt` §[1]，两通道各一份）：

```
GT_CELL_COUNT = 2
  GEARBOX_MODE = 5'b10001
  TXGEARBOX_EN = TRUE
  RXGEARBOX_EN = TRUE
  TX_DATA_WIDTH = 64
（第二条通道逐字相同：readback.txt:13-18）
```

IP 侧有效配置（`reports/p7a_ip_config.txt`，全部 OK，`MISMATCHES = 0`）：
`TX_DATA_ENCODING = 64B66B_ASYNC` / `RX_DATA_DECODING = 64B66B_ASYNC` / `TX|RX_INT_DATA_WIDTH = 64` /
`TX|RX_USER_DATA_WIDTH = 64` / `TX|RX_LINE_RATE = 10.3125` / `TX|RX_REFCLK_FREQUENCY = 156.25` /
`TX|RX_OUTCLK_SOURCE = TX|RXPROGDIVCLK` / **`TXPROGDIV_FREQ_VAL = 156.25`**（raw 会是 161.1328125）。

**腿 2 —— 频率恒等式**（工具计算，`reports/p7a_readback.txt` §[2] `:1339-1352`）：

| 时钟 | 周期 | 频率 | 含义 |
|---|---|---|---|
| `sys_clk` | 10.000 ns | 100 MHz | 核心板 Y1 |
| `g_hw.clk_out0` | **6.400 ns** | **156.25 MHz** | 观测时钟（MMCM，与 GT 配置无关） |
| `gtwiz_userclk_{tx,rx}_srcclk_out[0]` | **6.400 ns** | **156.25 MHz** | fabric 侧 payload 时钟 |
| `GTYE4_CHANNEL_TXOUTCLKPCS[0..1]` | **6.206 ns** | **161.13 MHz** | **raw 会用的那个时钟 —— 它确实以"另一个数"存在** |

- fabric 侧每拍 64 payload bit @156.25 MHz ⇒ **只有"每 66 baud 承载 64 个 payload bit"才可能**
  （10.3125 GBd / 66 × 64 = 1.0×10¹⁰ bit/s）；raw 会给 161.1328125 MHz / 1.03125×10¹⁰ bit/s。
- 两个候选值**相差 3.125%**，而测量分辨力在 10⁻⁵ 量级 ⇒ 判据有充分判别力
  （单元门 C9 把两个方向都跑过：`156.25 → 1.000000`，`161.1328125 → 1.031252`，
  `sim/xsim_run.txt:79-81`）。

**腿 3 —— 动态：`rxgearboxslip` 有东西可滑**（P2d，上表）：一次脉冲 ⇒ 两个通道同时爆错
（16640 / 16628 个错字）并**latched 掉链**，随后零错重锁。
**raw 数据通路里没有 gearbox 边界可移**，这个动作在 raw 上不会产生错误突发 —— 所以"爆错 + 掉链"本身
就是"gearbox 在通路里、且它的块边界是可动的"的行为证据。

> ⚠️ 三条腿必须**同时**看：腿 1/腿 2 是"综合实现确实按 gearbox 配了"，腿 3 是"它在跑"。
> 只有腿 1+2 的话，"配了但没跑"仍未被排除；只有腿 3 的话，"错误突发"可能来自别处。

### 3.4 license 负对照（**实测免 license**）

`reports/p7a_lic_deny_stdout.txt`（把 `C:\AMDDesignTools\2025.2\data\ip\core_licenses\Xilinx.lic`
改名藏起来后，在同一 session 里做同一组操作）：

```
SUBJ_AT_CREATE_IS_LOCKED = 0        SUBJ_AT_CREATE_USED_LICENSE_KEYS = <>
SUBJ_CONFIG rc = 0  SUBJ_EFF_ENCODING = 64B66B_ASYNC  SUBJ_EFF_PROGDIV = 156.25
SUBJ_GENERATE_TARGET_ALL rc = 0
SUBJ_POSTGEN_IS_LOCKED = 0          SUBJ_POSTGEN_LOCK_DETAILS = IP is not locked
SUBJ_POSTGEN_USED_LICENSE_KEYS = <> SUBJ_ART synth/*.v n=7
```

**同轮负对照**（同一台机、同一版本、同一被藏 license 的状态下，`xxv_ethernet` 长什么样）：

```
CTRL_IS_LOCKED = 1
CTRL_LOCK_DETAILS = * IP 'w2_pcs64_baser' requires one or more mandatory licenses but no valid
                    licenses were found. ...
```

⇒ 读数**有区分能力**（不是"什么都不会报锁"），因此 `IS_LOCKED=0` 是有效读数。
恢复已核对：`p7a_lic_deny_state.txt` 里改名前后 MD5 均为 `9bab9853d542567cbae9e2152f04223e`，
且 `RESTORE_HIDDEN_STILL_THERE=NO_OK`（没有残留 `.HIDDEN` 文件）。

### 3.5 静态判据里的其余项（时序 / 资源 / DRC / 域声明）

| 项 | 读数 | 出处 |
|---|---|---|
| WNS / WHS | **+3.178 ns / +0.018 ns** | `reports/p7a_readback.txt:1370-1371` |
| setup / hold 失败端点 | **0 / 0**（max_paths 封顶 20000） | 同上 `:1372-1373` |
| 资源 | LUT 2726（1.26%）· FF 5787（1.33%）· BRAM 0 · URAM 0 · DSP 0 · IOB 6 · **GTYE4 2（12.5%）** | `reports/p7a_utilization.rpt`；汇总在 `reports/p7a_gate_summary.txt` §[F] |
| 计数器代价（spec §9.11） | `u_counters` = 46 LUT / 1070 FF；`u_gt` = 103 LUT / 242 FF | `reports/p7a_utilization_hier.rpt` |
| 跨域声明真的生效 | `g_hw.clk_out0` × `gtwiz_userclk_{rx,tx}_srcclk_out[0]` 在时序分析里被读成 **Ignored / Asynchronous Groups，分析 0 条路径** | `reports/p7a_clock_interaction.rpt`（引文见 `p7a_gate_summary.txt:130-134`） |
| DRC | 无阻断项（`p7a_drc.rpt`）；`p7a_gate_summary.txt` 的 build 段 `12-4739` / `20-1307` 命中都是 **0** | `reports/p7a_gate_summary.txt` §[G] |

---

## 4. BER 与速率的**正证据**（逐字给读数）

原件 `board_scratch/logs/p7a_board_stdout.txt`，正式窗 = 600 s（`:601-663` 逐子窗，`:667-742` 汇总）：

```
=================== P7a BOARD ACCEPTANCE READOUT ===================
ELAPSED WALL     = 600.311317 s   (dFr = 93801518573 obs-domain 156.25 MHz cycles = 600.329719 s)
SUB-WINDOWS      = 59   ratio(dWords/dFr) range = 0.999995 .. 0.999995
--- channel 0  = B->A (ch0 RX receives ch1 TX) ---
BITS_CNT (payload) = 6003265225472   (= 93801019148 x 64-bit words)
ERR_WORD_CNT       = 0
HDRS_CNT           = 93801019148   (words with rxheadervalid)
HDR_ERR_CNT        = 0
RATE (bits/wall)   = 1.000025e+10 bit/s   target 1.0e10 +-0.1%  dev=0.0025%
RATE (words/dFr)   = 1.562492e+08 64-bit words/s  (x64 = 9.999947e+09 bit/s; 1.5625e8 words/s is the 66/64 gearbox answer)
RATIO whole window = 0.999995   (dWords/dFr over the WHOLE run: 1.000000 = 66/64 gearbox, 1.031250 = raw)
BER upper bound 95%CL = 4.997e-13  (0 errors in 6003265225472 bit < 3/B)
  criteria: bits>0=1  err==0=1  hdre==0=1  rate+-0.1%=1  subwindow-ratio==1.000=1  wholewindow-ratio==1.000=1  (subwindows=59)
--- channel 1  = A->B (ch1 RX receives ch0 TX) ---   （逐项同 ch0，读数逐字相同）
GEARBOX_RATIO_VERDICT = 1.000000 => ... the 64b/66b gearbox is IN THE DATAPATH
                        (raw would read 1.031250 and ~1.0313e10 bit/s)
P7A_BOARD_VERDICT = PASS
```

**逐项说明（"这个数为什么算正证据"）**

| 量 | 值 | 为什么它算证据 |
|---|---|---|
| `BITS_CNT` | 6,003,265,225,472（双向相同） | **正对照**：`acq` 只在锁定后计数 ⇒ `bits>0` 证明"计数器真的在跑"，"0 错"不是空读数（`rtl/p7a_counters.v` 头注释） |
| `ERR_WORD_CNT` | **0** | 一次坏字 = 一个错字（`prbs_any` 在 check 模式从接收数据重播种 ⇒ 1 个坏 bit 污染恰 1 个**字**，`P7A_SPEC.md` §5.1） |
| `HDRS_CNT` | 93,801,019,148 **== BITS_CNT/64** | 恒等式逐位成立 ⇒ 每个 payload 字都带 `rxheadervalid`（第二重正对照） |
| `HDR_ERR_CNT` | **0** | 6-bit `rxheader` 相对锁定后第一个观测值**从未偏离** |
| `RATE (bits/wall)` | 1.000025×10¹⁰（+0.0025%） | 与 `10.3125 GBd × 64/66 = 1.0000×10¹⁰` 相差 **2.5×10⁻⁵** |
| `RATE (words/dFr)` | 1.562492×10⁸ 字/s（= ×64 → 9.999947×10⁹） | 与"观测时钟 156.25 MHz ⇒ 每拍 1 个 64-bit 字"一致 |
| `RATIO whole window` vs 59 个子窗 | 0.999995；子窗 range **0.999995..0.999995** | **比率判据**：1.000000（gearbox）/ 1.031250（raw）；实测偏离目标 5×10⁻⁶，由 59 个独立子窗复核 |
| `BER upper bound 95%CL` | **4.997×10⁻¹³** = 3/B | 优于 10GBASE-R 的 1×10⁻¹² 要求约 **2 倍** |

> ⚠️ **诚实的第三条**：整窗比率读 **0.999995**，不是"1.000000"。差 5×10⁻⁶（≈5 ppm），
> 一致性解释是"RX 恢复时钟与本地 156.25 MHz 观测时钟之间的**准同步频差**"（payload 流的时钟
> 链自对端 TX → AOC → 本端 CDR；观测时钟来自核心板 Y1/MMCM）。
> 它与 raw 候选值 **1.031250 相差 3.1%** ⇒ 判别力没有任何问题；但**"5 ppm 是真实频差还是测量效应"
> 本轮没查**，见 §7。
>
> ⚠️ **速率的两个口径要给对名字**：`RATE (bits/wall)` 用的是主机墙钟（含 VIO 读取的开销，
> 偏 +0.0025%），`RATE (words/dFr)` 用的是**板内观测域**的周期计数（偏 −5×10⁻⁶）。
> 两者都远优于判据的 ±0.1%；**判"是不是 gearbox"要用比率口径**，墙钟口径只作量级复核。

---

## 5. 中途两次停下：现象、归因、处置

### 5.1 第一次停下 —— **物理拓扑错**（run1，`exit 2`，16:52:37–16:53:18）

**现象**（`board_scratch/logs/prev_run1_failed_p7a_board_stdout.txt`）：
`sfp1_rx_los=1`（`:261`）· `acq=00 ref_link=00 ref_down_latched=11`（`:252`）·
等 20 s 无锁 ⇒ `acq(both) = 0 after 21300 ms`（`:308`）·
`P7A_BOARD_VERDICT = STOP_NO_PRBS_LOCK`（`:321-326`，**什么都没做就退出**）。

**同一时间窗的三条独立读数**（都指向"板外"）：

1. 16:59 与 17:11 两次 iBERT 对照件：`LINK A_to_B STATUS=NO LINK`、四个 GT `RX_BER ≈ 0.5`
   （16:59 那次：`ctrl_scratch/ctrl_console.txt:336-337,359`；17:11 那次：
   `ctrl_scratch/ctrl_console_run2.txt:336,359`）。
2. 17:15 的额外诊断轮（`extra_gate_diag.tcl`，**不编程、只读**，`XDIAG-COMPLETE -- nothing was
   programmed; LOOPBACK restored`，`:292`）：外部无内部环回时四个 GT 全 0.5
   （`ctrl_scratch/ctrl_console_xdiag.txt:112-123`，四个通道的 `RX_BER=0.49996…/0.49999…`），
   而**近端 PCS / PMA 内部环回的正对照 8 s 内零错**（`dBITS=85645421920 dERR=0` /
   `dBITS=85984964080 dERR=0`，同文件 `:220-224` / `:250-252`）⇒ **GT/CDR/PRBS 机制本身没问题**，
   黑的只是"板外那一段"。收尾把四个 GT 的 LOOPBACK 还原成 `None` 并核对
   （`GTs not back to None: 0`，`:282`）。
3. `reflash_p7a` 轮把板子恢复到 P7a 镜像时，`sfp1_rx_los=1` 依旧（`ctrl_scratch/reflash_console.txt:103-116`）。

**归因**：**AOC 环回线的两头没有同时落在板子的两个 SFP 笼子上**（当时是"一头板子、一头网卡"）。
注意这条**没有一条日志能证明装配形态** —— 它是**问出来的**，而且问法本身出过问题（见 §5.3 教训 1）。

**处置**：重新插线 ⇒ 17:23 的对照件立刻恢复正常
（`ctrl_scratch/ctrl_console_v4.txt:336-337`，`LINK A_to_B STATUS=10.312 Gbps`），
17:25 起 run2 的 `sfp1_rx_los` 变为 0（`prev_run2_stopsnap_p7a_board_stdout.txt:253`）。

**代价**：**白白多跑了一整轮**（run1 + 两次暗对照 + 一次诊断轮），全部来自"问的是简称不是拓扑"。

### 5.2 第二次停下 —— **测量台架缺陷**（run2，`exit 2`，17:25:01–17:25:39）

**现象**（`board_scratch/logs/prev_run2_stopsnap_p7a_board_stdout.txt`）：
链路本身**完全健康** —— `sfp*_rx_los=0/0`、`acq(both) = 1 after 73 ms`（`:253,308`）、
`hdr_ref=0x01/0x01 hdr_err_cnt=0`（`:343-347`）。
但负对照 A 判据崩了：

```
BEFORE SLIP: err ch0=0 ch1=0  ref_link=11  ref_down_latched=00
AFTER SLIP +2 s: err ch0=0 ch1=0  (delta ch0=0 ch1=0)
  slip_echo=0   bits advanced since before-slip = 0          <-- 计数器"一点没动"
CLEAN 6 s AFTER SLIP: err delta ch0=0 ch1=0   bits advanced=0
NEGCTRL_A_ERR_BURST = 0      NEGCTRL_A_RELOCK = 0
P7A_BOARD_VERDICT = STOP_NEGCTRL_A                            （`:402,419-427,443-458,468-471`）
```

**归因（台架缺陷，不是被测对象）**：run2 在 STAGE C 用的是 `rd1 $vio $P(stat)` + `rdall $vio`，
**没有先发快照请求**（`raw_snap` 脉冲）。而计数器的语义是 **"快照冻结到下一次请求为止"**
（单元门 C7 专门断言了这一点：`sim/xsim_run.txt:68-71` — *bits/hdrs/err frozen*）⇒
两次"前后读数"读的是**同一批冻结值** ⇒ delta 恒 0 ⇒ 判据退化（拿一个值和它自己比）。
注意 `ref_down_latched` 仍在变（它是**实时**状态位），这正好解释了"部分读数在动、计数器不动"的
错觉 —— 这类假象最容易把矛盾指向被测对象。

**处置与验证**（`board_scratch/logs/diag_slip_stdout.txt`，17:27:13，**不编程、只读**）：
连发三次**真**快照（每次等 ack 翻转）复核 payload 域是否活着：

```
D1-a ack_flip_after=9ms   bits=1154998693248 err=16643,16623 ... fr_cyc=18046950480
D1-b ack_flip_after=9ms   bits=1223479928704 err=16643,16623
D1-c ack_flip_after=10ms  bits=1275746220352 err=16643,16623 ... fr_cyc=19933640583
```

⇒ 快照 ack 在 9/9/10 ms 内翻转、`bits/hdrs/rxcyc/fr_cyc` 全部推进 ⇒ **payload 域活着，
run2 的 delta=0 纯粹是台架没发请求**。
（该诊断脚本自己在最后的汇总循环里抛了个 Tcl 变量名错 `can't read "D1"`，
**但那三行原始读数已经打出来了**，判据不受影响；错误行见 `diag_slip_stdout.txt:182-191`。）

修法：把所有"取数点"改成**一律先 `snapwait`**（发请求 + 等 ack 翻转）再读，run3 即按此跑
（`board_scratch/probe_p7a_board.tcl` 的 `snapwait` / `run_window`；run3 的每一次读数前后都成对）。

### 5.3 本轮新增的四条教训（**原话可整理，要点不许丢**）

1. **问物理装配要问"线两头分别插在哪"，不能问简称。**
   问"SFP 环回还在吗"得到"还在、未动"，而实际拓扑是"**一头板子、一头网卡**" —— 简称为真、
   装配为假 ⇒ 白白多跑一轮（run1 + 两次暗对照 + 一次诊断轮）。
   **问法模板**：「这条线的 A 头插在哪个笼子、B 头插在哪个笼子 / 它俩在不在同一台设备上」。
2. **Vivado 2025.2 的 Tcl 是 32 位的**（run3 实测 `tcl = 8.6.13  wordSize = 4`，
   `p7a_board_stdout.txt:43`）⇒ **`format %d/%X` 对 > 2³¹ 的值会静默输出 0**
   ⇒ 读 `bits_cnt`（6×10¹²）会**伪装成"零误码"**。
   本轮的脚本因此**所有大数只用字符串插值打印，绝不过 `format`**
   （`dryrun_stub.tcl:78-81` 记着这条是怎么被发现的：干跑台架自己先中招）。
   ⚠️ 这是"**空读数伪装成好读数**"的一类，比"读不到"危险得多。
3. **XDC 只接受 Tcl 子集**：`if` / `foreach` / `puts` 会让整段约束被**静默跳过** ——
   构建**照样 exit 0、位流照样出**。本轮 build #1 中 `dbg_hub` 的频率设置、clock groups、
   CDC 假路径**全部没生效**。可复现的原始证据（单独重建的最小工程）：
   `reports/p7a_xdc_probe_stdout.txt` 里
   `CRITICAL WARNING: [Designutils 20-1307] Command 'if' is not supported ... :5` /
   `Command 'foreach' is not supported ... :9`，而紧接着 **`PROBE_SYNTH_RC = ok`**
   —— 即"报错了、但综合照样成功"。
   处置：约束拆成 `xdc/ku5p_p7a.xdc`（synth+impl）+ `xdc/ku5p_p7a_impl.xdc`
   （`used_in_synthesis false`），**只写平铺命令**；修后终版构建日志里 `12-4739` / `20-1307`
   命中 **0 次**，且 `dbg_hub` 实测 `freq=156250000 / divider=true`、`set_clock_groups rc=0`
   （`reports/p7a_gate_summary.txt` §[G]）。
   ⚠️ 本条的普遍形态：**构建工具的"成功"退出码不能证明约束生效** —— 判据要落到
   "约束的效果"（时序报告里的 clock group、dbg_hub 的实际频率），不是"脚本没报错"。
4. **测量台架缺陷会伪装成被测对象的缺陷**：读点前没发快照请求 ⇒ 读的是上一批**冻结值** ⇒
   "前后对比"变成**拿一个值和它自己比**（delta 恒 0）。见 §5.2 的完整链条。
   ⚠️ 加剧错觉的是**同一状态字里还有实时位**（`ref_down_latched` 照样翻转）⇒
   看着"有的数在动、有的数不动"，很容易归因到"RTL 里有条通路坏了"。

**另记两条（非教训，属事实更正/现状）**：

- 板上这两个模块是 **SFP+ 10G**（**不是 SFP28**）—— 对 10GBASE-R 完全适用
  （读数侧的证据：iBERT 把两个通道的 `LINE_RATE` 落到 **10.312 / 10.313 Gbps** 并稳定锁定，
  `ctrl_ibert_v3.log:350-351`）。`P7A_SPEC.md` §5.5/§10 里"两个 SFP28 模块"的措辞按此更正。
  ⚠️ 本条的**来源是口头信息（TL 在 P7a 汇报中的更正）**，本轮日志里没有模块型号字符串
  （板上未引出 I2C/DOM，见 §7）。
- **本文件写成时，板子载的是 P7a 位流**（volatile；最后一次编程动作是 run3 的烧录，
  判据 `DONE_PIN = 1` / `End of startup status: HIGH`，`p7a_board_stdout.txt:106-110`；
  之后只有读操作，17:39:44 断开 hw_server）。**下一次上板前必须重烧并重新核对 sha256。**

---

## 6. 产物、指纹与复现

### 6.1 位置与 sha256

| 物 | 路径 | sha256 |
|---|---|---|
| 位流 | `_proj_10g/vivado_prj/p7a_prj.runs/impl_1/p7a_top.bit` | `f88d019fc53a8d07d04d14670188f8148d36e09bb9ba8d1b0df366cbf9f8651d` |
| 探针 | 同目录 `p7a_top.ltx` | `5dd5fa692c315c51fa72d7283e67a8b97c235b9b0a63dd78f5137ab1045455db` |
| iBERT 对照件镜像 | `_proj_10g/ctrl_scratch/ibert_top_v3_corrected_map.bit` | `d5566b93b89f0a7b80a7901949e059464f2822f1d60f91e53170b1532b0f1ae0`（`ctrl_console_v4.txt:45`） |

### 6.2 RTL / XDC 指纹（**上面那个位流与那些读数出自这些字节**）

`reports/p7a_gate_summary.txt` §[J] 与 `board_scratch/logs/hashes.txt:9-21`（两处逐字一致）：
11 个 RTL 文件（`clk_gen_p6b.v` / `gt_10gbr_example_{checking_64b66b_async,reset_sync,stimulus_64b66b_async}.v` /
`gt_10gbr_prbs_any.v` / `p7a_{bit_sync,counters,ref_bucket,tgl_sync,top,vio_ctrl}.v`）逐个 sha256。
`reports/p7a_gate_summary.txt:129` 记着"**本指纹之后再跑一次门：1 行 GATE PASS**"。

### 6.3 独立复现步骤

```bash
# 0) 前置闸: 确认没有 Vivado 构建/xsim 在跑（本工程铁律）
# 1) 认位流: sha256 必须 == f88d019fc53a8d07d04d14670188f8148d36e09bb9ba8d1b0df366cbf9f8651d
# 2) 正式窗 = 烧录 + 安全闸 + 负对照 + 短窗 + 600 s 窗, 一条 bat 全包 (JTAG, volatile):
#    cmd //c '_proj_10g\board_scratch\run_probe_p7a_board.bat'      # P7A_SECS=600 P7A_SHORT=60
#    判据: 'DONE_PIN = 1' / 'End of startup status: HIGH' 之后
#          尾行 'P7A_BOARD_VERDICT = PASS' + 'P7A_VERDICT_END'
# 4) 无板判据（可随时复跑）:
#    cmd //c '_proj_10g\sim\run_tb_p7a_counters.bat'   # 期待 'GATE PASS' / checks=437 failures=0
#    cmd //c '_proj_10g\tcl\run_lint_p7a.bat'          # 期待 LINT-OK
#    cmd //c '_proj_10g\tcl\run_readback_p7a.tcl'      # 静态判据 (需重建工程)
# 5) ⚠️ 若要复跑阶段 1（对照件），**重烧 P7a 之后再离开**（reflash_p7a.tcl），别把板子留在 iBERT 镜像上
```

---

## 7. 本轮**未覆盖 / 未确证**（诚实清单）

1. **超过 10 分钟的长期稳定性**：正式窗是 600 s（双向各 6.0×10¹² bit）。没有 soak/长时探针，
   **"跑几小时会不会掉链"本轮没有数据**（对照：P6b 那轮做了 348 轮 / 96.3 分钟的长时探针）。
2. **SFP 模块的身份与 DOM**：底板**未引出 SFP 的 I2C**（`../CLAUDE.md` 「SFP 的 I2C 在底板上未引出」）
   ⇒ 无法读模块型号/温度/光功率；"模块是 SFP+ 10G"这条只有**口头来源**（§5.3 另记）。
3. **手册的 12 GHz 边界未触及**：本轮只跑到 10.3125 GBd，`10.3125 < 12` 这个不等式**没有被验证或推翻**
   （与 09-27 的结论同：一致但不构成检验）。
4. **`inf` 与 X0Y6 未深究**：对照件里 X0Y6 读 `LINE_RATE=0.000 / RX_BER=inf /
   RX_RECEIVED_BIT_COUNT=0`（`ctrl_console_v4.txt:333,361`），X0Y7 读 10.304 GBd / 0.489。
   脚本自己的注记是"未接线通道上 `dERR=0` 是假象（未锁的 PRBS 校验器不计数）"
   （`ctrl_console_v4.txt:363-365`）—— 这与"X0Y6 为什么连线速率都是 0"是两件事，**本轮只记录**。
5. **6-bit `rxheader` 的编码未解码**，2-bit 64B/66B **sync header 不在 fabric 可观测面上**
   （gearbox 会插/剥）⇒ 判据只能是"**稳定**（等于锁定后第一个观测值）"。
   **这是已承认的覆盖缺口**（`rtl/p7a_counters.v:1-50` 头注释 / `P7A_SPEC.md` R3）。
   间接覆盖：腿 2 的比率恒等式只有在"同步头被正确找到并剥掉"时才成立。
6. **`0.999995` 那 5 ppm 的成因未查**（真实准同步频差？测量口径？）—— 见 §4 的注。
7. **只有 PRBS31，没有真实以太网帧**：本轮不涉及 MAC/FCS/帧长，也不涉及 10G 的 XGMII/背压；
   P7a 的边界就是"PCS/PMA + gearbox 能跑且 BER 达标"。
8. **单元门汇总行里的 `ratio_abs_gb=0.974091` 口径本文未解释**
   （`sim/xsim_run.txt:85` 的 `SUMMARY` 行；它同行还有 `ratio_gb=1.000000` / `ratio_raw=1.031252`，
   **判据用的是后者那两个**）—— 列出来是防止后人把它误当成判据。

---

## 8. 交付给下一个 session 的状态

- **板子**：载 P7a 位流（volatile），DONE 判据通过，最后一次操作是断开 hw_server（2026-09-29 17:39:44）。
  **下一次测量前必须重烧 + 重核 sha256**（本工程既有铁律）。
- **对端机 `192.168.0.38`**：hw_server（`0.0.0.0:3121`）在用；本轮**没有重启、没有改动**。
- **可复用件**：`_proj_10g/board_scratch/probe_p7a_board.tcl`（VIO 读写 + 快照协议 + 负对照 + 窗口测量，
  已含"大数不过 format"与"取数前必 snapwait"两条护栏）、`obs/probe_p7a.tcl`（同族）、
  `ctrl_scratch/ctrl_ibert_v3.tcl`（iBERT 对照件全套）、`tcl/build_p7a.tcl`（构建）。
- **下一步的自然对象**：把 PCS/PMA 这一层接上真正的 10G MAC/XGMII（数据面 156.25 MHz 已经在 P6b 落地）。

---

## 9. 引用地图（本文件用到的每一份原始读数）

> ⚠️ **行号口径**：本文件引用的一律是**入库的那份文本捕获**。
> 每次运行的 Vivado `.log` / `.jou` 按本仓全局规则（`*.log`）**不入库、留在盘上**，
> 与它们**逐字同值**的入库版本是宿主侧 console/stdout 捕获（`*_console.txt` / `*_stdout.txt`）
> ⇒ **行号按后者给** —— 直接去 grep 那份 `.log` 会得到不同的行号，这不是错，是两份文件。

| 文件 | 本文件用到它的哪一部分 |
|---|---|
| `_proj_10g/board_scratch/logs/p7a_board_stdout.txt` | run3 全量读数（§2/§3.2/§4/§5.2） |
| `_proj_10g/board_scratch/logs/p7a_board_run3_console.txt` | run3 宿主侧 console（`---- vivado exit=0 ----`） |
| `_proj_10g/board_scratch/logs/prev_run1_failed_p7a_board_stdout.txt` | §5.1 第一次停下 |
| `_proj_10g/board_scratch/logs/prev_run2_stopsnap_p7a_board_stdout.txt` | §5.2 第二次停下 |
| `_proj_10g/board_scratch/logs/diag_slip_stdout.txt` | §5.2 的 payload 域活性复核 |
| `_proj_10g/board_scratch/logs/hashes.txt` | §2/§6.2 指纹 |
| `_proj_10g/board_scratch/probe_p7a_board.tcl` · `dryrun_stub.tcl` · `logs/dryrun_stdout.txt` | §5.3 教训 2 的原话与出处（干跑台架的输出） |
| `_proj_10g/ctrl_scratch/ctrl_console_v4.txt` | §3.1 阶段 1 判据 + §4 的对照基线 + §6.1 镜像 sha256 |
| `_proj_10g/ctrl_scratch/ctrl_console.txt` · `ctrl_console_run2.txt` | §5.1 两次暗链证据（16:59 / 17:11） |
| `_proj_10g/ctrl_scratch/ctrl_console_xdiag.txt` | §1 的 `TXGEARBOX_EN=FALSE` + §5.1 内部环回正对照 |
| `_proj_10g/ctrl_scratch/reflash_console.txt` | §5.1 收尾、回 P7a 镜像 |
| `_proj_10g/reports/p7a_gate_summary.txt` | 全部静态判据的汇总（A–J 段） |
| `_proj_10g/reports/p7a_readback.txt` | 腿 1（§[1]）· 腿 2（§[2]）· 时序（§[3]） |
| `_proj_10g/reports/p7a_ip_config.txt` · `p7a_clock_interaction.rpt` · `p7a_timing_summary.rpt` · `p7a_utilization*.rpt` · `p7a_drc.rpt` | §3.3/§3.5 |
| `_proj_10g/reports/p7a_lic_deny_stdout.txt` · `p7a_lic_deny_state.txt` | §3.4 |
| `_proj_10g/reports/p7a_xdc_probe_stdout.txt` | §5.3 教训 3 |
| `_proj_10g/sim/xsim_run.txt` · `xvlog.txt` · `xelab.txt` · `tcl/lint/xvlog.txt` | §3.2 P2i/P2j、§5.2 C7 证据 |
| `_proj_10g/rtl/*.v` · `_proj_10g/xdc/ku5p_p7a*.xdc` | 判据语义的出处（通篇引用） |
| `P7A_SPEC.md` | 施工规格（判据的"期望来源"栏） |
