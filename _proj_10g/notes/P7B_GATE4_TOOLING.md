# P7b 闸 4 验收工具: 三处修复 + 负对照 + dbg_hub 侦察

- 日期：**2026-09-30**（工具轮；**未烧板、未重启对端机、未改 RTL/XDC/构建脚本、未 git 写**）
- 范围：只改**验收脚本**、只写本文件与 `p7b_gate4_tools/**`（文件所有权互斥，见 §9）
- 一句话：**闸 4 现在可以照着 §8 跑；三处工具缺陷已修，且每一处都有"真跑过"的负对照在 `p7b_gate4_tools/` 里留档。**

| # | 缺陷 | 结论 |
|---|---|---|
| ① | `snap_words()` 只到 `0xAC`（36 字时代）+ **尾部 8 项重复** | ✅ 改成**由 `SNAP_WORDS` 派生**的 51 字（`0x20..0xE8`）；手抄重复结构性不可能再犯 |
| ② | "未实现地址" `0xB0`（旧值） | ✅ 自算得 **`0xEC`**（word 59 = 0x20+4·51）；**并修掉一处"判据与读数脱钩"的假 FAIL**（`$U84` 幽灵变量） |
| ③ | 网关判据 `port_rx_good > 0` 无判别力 | ✅ 做成 **Δ + 速率阈值 + 单播 + 长度桶** 四件套，另加 **N_BASE 判别力自检**（同一判据跑基线窗必须**不成立**） |

> ⚠️ **本轮的诚实边界**：所有脚本的 **live 路径（真板/真网卡）没有跑过** —— 闸 4 之前不许烧板，
> 且 PCIe 通道现在是死的（`P7B_GATE4_PLAN.md` §0.2）。跑过的是 **假板子 + 合成读数**（下文标注）。
> 首次上板请按 §8 先跑 `G4_SKIP_TRAFFIC=1` 那一档。

---

## 1. 缺陷①：`snap_words()` 只到 `0xAC` 且尾部 8 项重复

**原文**（旧 `_proj_pcie/p6e_snap_check.sh:43-45`，逐字）：

```bash
# 快照字 W0..W35 (0x20..0xAC) 一次读全, 打印成一行
snap_words(){          # 36 字 (P6b+F4: 双域两束 = FE 14 + DP 22): 0x20..0xAC
  local a
  for a in 20 24 28 2c 30 34 38 3c 40 44 48 4c 50 54 58 5c 60 64 68 6c 70 74 78 7c 80 84 88 8c 90 94 98 9c a0 a4 a8 ac 80 84 88 8c 90 94 98 9c; do printf "%s " "$(rd 0x$a)"; done
```
两个毛病：(a) 只列到 `0xAC`；(b) **尾部 `80 84 88 8c 90 94 98 9c` 又写了一遍**（36 字时代的笔误）。
同一张"手抄 44 项"表在本轮之前共有 **6 份**；本轮改了 2 份（`p6e_snap_check.sh` 与 `p6b_accept.sh`），
另外 **4 份故意没改**（`p6b_smoke_account.sh:28` / `p6e_capture.sh:30` / `p6e_slowpath_probe.sh:55` /
`p6e_watch.sh:37`）—— 它们服务的是 **P6b 位流**，改了反而让那一档失去工具；见 §7 警告 2。

**改成什么**（`_proj_pcie/p6e_snap_check.sh:36-43`，就地改）：

```bash
SNAP_WORDS=${SNAP_WORDS:-51}
UNIMPL_ADDR=${UNIMPL_ADDR:-$(printf '0x%X' $(( 0x20 + 4*SNAP_WORDS )))}   # 51 ⇒ 0xEC
snap_addr(){ printf '0x%X' $(( 0x20 + 4*$1 )); }                          # word 号 → 字节地址
W32=$((1<<32))
...
snap_words(){ local i; for (( i = 0; i < SNAP_WORDS; i++ )); do printf "%s " "$(rd "$(snap_addr $i)")"; done; echo; }
```
**只写"字数"这一个数，地址全部由它派生** ⇒ 读漏/读重都不再是"手抄失误"，而是不可能的。
`p6b_accept.sh` 的 `readall()` 同批改成 `READ_NW`（默认 36）派生（`_proj_pcie/p6b_accept.sh:161-164`（`READ_NW` 在 `:89`）），
它那句"尾部 8 项重复"的注释也换成了缺陷说明。

**依据**：
- 51 字的来源 = `board/wrapper_p4.v:3078` `localparam SNAP_NW_P6E = 51;`（单一来源）
  + `:3513-3534` 的 `snap_dout_all` 逐项拼接（W0..W50，逐项注释了槽号）；
- 末字地址 = `0x20 + 4×(51−1) = 0xE8`（自算）；
- 前 36 字的语义**逐字未变** ⇒ `P6E_OBS.md` 的一表仍然有效（W36..W50 见 `P7B_GATE4_PLAN.md` Q4 ④）。

**怎么证明改对了**（真跑，日志在 `p7b_gate4_tools/selftest/`）：
`p7b_gate4_selftest.sh` 造了一个**假板子**（假 `reg_rw`/假 `lspci`/假 `date` + 51 字寄存器表），把
`p6e_snap_check.sh` **原样**跑一遍，并断言：

```
[OK] 旧手抄地址表已消失 / [OK] 源码里已按 SNAP_WORDS 派生
[OK] section5 地址序列 (51 个, 0x20..0xE8 连续不重复)  md5=42f0956b  (与期望表逐字节一致)
[OK] section5 序列长度 51 / [OK] 表里印出 W50 0xE8 / [OK] 表格行数 51
[OK] 正例读过末字地址 0xE8 ← 旧版只到 0xAC  [OK] 正例读过未实现地址 0xEC
[OK] 正例 6.1 PASS / 0 FAIL / 退出码 0
```
（`selftest/addrlog_good.txt` 是**假 `reg_rw` 的地址日志** —— 它是"到底读了哪些地址"的原始凭证；
`addrseq.txt` vs `addrseq_want.txt` 是那 51 项的逐字节比对。）

---

## 2. 缺陷②：未实现地址 `0xB0` → `0xEC`（**自算**，不照抄）

**自算链**（每一步都能独立复核）：
1. `axi_regs.v:118` `SNAP_LAST_IDX = 8 + SNAP_NW - 1 = 8 + 51 - 1 = 58`；
2. `axi_regs.v:265` 的 SLVERR 边界是 `r_word <= SNAP_LAST_IDX` ⇒ **word 58 是最后一个已实现字**；
3. word 58 的字节地址 = `0x20 + 4×(58−8) = 0xE8` ⇒ **第一个未实现地址 = word 59 = `0xEC`**；
4. 红线：`axi_regs.v:173` `ar_word = araddr[7:2]` 只有 6 位 ⇒ 地址每 256 B 回绕。
   `0xEC < 0x100` ⇒ **不触发回绕**（旧脚本注释警告的"挑 0x100 别名到 MAGIC ⇒ 假 FAIL / 挑 0x160 边界 ⇒ 假 PASS"两种情况都不沾）。

**同时修掉一处更隐蔽的错**（旧 `p6e_snap_check.sh:214`，逐字）：

```bash
UB0=$(rd 0xB0); U00=$(rd 0x00)
echo "  [INFO] 0xB0 (未实现) = $UB0 ; 0x00 (实现) = $U00"
if [ "$U84" = "0xffffffff" ] && [ "$U84" != "$U00" ]; then     # ← $U84 从未被赋值!
```
`$U84` 是 **0x84 时代的残留变量名**（现名 `UB0`），**从未被赋值** ⇒ 在 `set -u` 下它是空串，
判据**永远走 FAIL 分支**并把空值当"实测值"打印。这与本工程反复吃过的"假 PASS"是同一族：
**判据在报告里看着"跑了"，实际上它跟读数没关系**。改法：用 `$UNIMPL_ADDR` 的新变量，
并且**同趟再读一个已实现字做对照**（`0x14 == 0xdeadbeef`），否则"读数取不到"与"译码过宽"
在输出上不可区分。

**怎么证明改对了**（真跑）：
- 假板子**正例**（`0xEC` 回 `0xffffffff`）：`[PASS] 6.1 ... 同趟已实现字仍读出真值` + 整脚本 `FAIL=0` / 退出 0；
- 假板子**负对照**（`FAKE_UNIMPL=0x12345678`）：`[FAIL] 6.1` + 退出码非 0（`selftest/wide.log`）；
- 闸 4 的合成读数负对照 `wideldecode`（`m_wide_a/b.txt` 把 `UNIMPL` 改成 `0x12345678`）：
  `wideldecode 退出码=1 命中=B_UNIMPL`（`negctrl/wideldecode.log`）。
- `B_WIN`（窗口内任何 `0xffffffff` 一律当"读失败"）另配 `allF` 负对照（把 `W40` 写全 F）⇒ `命中=B_WIN`。

---

## 3. 缺陷③：网关判据"没牙" → 四件套 + 判别力自检

**原文**（`P7B_HANDOFF.md` §3① / `P7B_GATE4_PLAN.md` §0.1 引自闸 2）：
> `rx_eth_crc_err` 必须为 0 且 **`port_rx_good` > 0**

**为什么没判别力**（本轮实测，非推断）：板子的 HLS 慢路径**自带周期性 HELLO/ARP 发包**，
走的就是验收要验的那条链（`slow_tx_adp → tx_arb → mac_tx_10g → PCS → J8`）⇒
`port_rx_good` 在**板子什么都不做**时**已经 >0 且在涨**（0.1–0.5 帧/s）。
⇒ `> 0` 这条在"验收对象完全坏掉"时也可能成立 = **真空门**。

**改成什么**：NIC 侧判据落在**新脚本** `_proj_pcie/p7b_gate4_accept.sh`（以前**没有** NIC 侧脚本，
只有文档；`p6b_accept.sh` 是 1G/ping 口径，不含四件套）：

| 判据 | 形式 | 为什么需要它 |
|---|---|---|
| `N_CRC` | `Δrx_eth_crc_err == 0` | FCS 正确（板子 MAC 的 pad/FCS 回归会立刻现形） |
| `N_BAD` | `Δport_rx_bad == 0` | 坏帧不许涨 |
| **`N_RATE`** | **`Δport_rx_good ≥ 1e5` 帧 且 ≥ 800 Mbps** | **增量 + 速率阈值**（背景 0.1–0.5 帧/s，差 6 个数量级） |
| **`N_UCAST`** | `Δport_rx_unicast ≥ 0.9·Δgood` | **单播**（图案是单播；背景是**广播**） |
| **`N_LEN`** | `Δport_rx_1024_to_15xx ≥ 0.9·Δgood` **且** `Δport_rx_64 ≤ 0.1·Δgood` | **长度桶**（1518B vs 背景 64/66B） |
| `N_AVG` | `Δbytes/Δpackets ∈ [1517.5,1518.5]` | 自算 1518.000000（同闸 2 的 "248.000000" 口径） |
| `N_SELF` | `Δgood + Δbad == Δpackets` | 字段自洽（防"字段名/端口串了口径"） |
| ⭐ **`N_BASE`** | **同一套 `N_RATE` 跑在"教学前"的基线窗上必须\*\*不成立\*\*** | **判别力自检**：把"判据有牙"这件事本身变成一条会 FAIL 的判据 |
| `N_XCHK` | 板侧 `ΔW20×1518×8/Δt` vs 网卡 `Δbytes×8/Δt`，偏差 <1% | G4 的"两个独立来源对账" |

**怎么证明有判别力**（真跑，`p7b_gate4_tools/negctrl/`）：

| 变异（合成读数） | 结果 |
|---|---|
| `clean`（10G 线速 1518B 单播图案） | **`PASS=25 FAIL=0 SKIP=0` / 退出 0** ← 正对照，防"什么都报 FAIL"的坏脚本蒙混过关 |
| `nic_background`（`Δgood=+3`，只涨背景） | **`N_RATE` FAIL** ← 这正是"旧口径 `>0`"会假通过的那一条 |
| `nic_broadcast`（`Δgood=4.06M` 但全走广播 + 64B 桶） | **`N_UCAST` FAIL**（`N_LEN` 同时 FAIL） |
| `nic_crc`（`Δcrc=12`） | **`N_CRC` FAIL** |
| `nic_avg`（`Δbytes=Δgood×66`） | **`N_AVG` FAIL** |
| `nic_missing`（删掉 `port_rx_unicast` 字段） | **退出 2 + `NIC 文本缺字段`**（拒绝出结论，不拿旧数组算下去） |
| `clean` 的基线窗（`Δgood=+3`） | **`N_BASE` PASS**（判据在基线窗上确实不成立） |

---

## 4. 负对照总表（**15 条全部真跑**，原始输出留档）

- 驱动：`_proj_pcie/p7b_gate4_negctrl.sh`（合成读数喂**解析函数**，不碰板子/对端机）
- 原始件：`_proj_10g/notes/p7b_gate4_tools/negctrl/{<case>.log, SUMMARY.txt, s*.txt, n*.txt, m_*.txt}`

```
########## 负对照汇总: OK=15 BAD=0 ##########
  clean           退出码=0 命中=FAIL=0        ← 正对照（必须全 PASS）
  genstuck        退出码=2 命中=gen 不是恰好 +1
  emptyread       退出码=2 命中=空读
  missinglast     退出码=2 命中=窗口不完整: 缺 W50
  duptail         退出码=2 命中=下标重复          ← 直击缺陷①的那处"尾部重复"
  oldwindow       退出码=2 命中=窗口不完整: 缺 W36 ← 直击缺陷①的"只到 0xAC"
  offbyone        退出码=1 命中=B_CONS-a          ← "地址错一位"被守恒律抓住
  allF            退出码=1 命中=B_WIN             ← "某字全 FFFFFFFF"被抓住
  wideldecode     退出码=1 命中=B_UNIMPL          ← "未实现地址回真数据"被抓住
  w50stuck        退出码=1 命中=G2-W50
  nic_background  退出码=1 命中=N_RATE
  nic_broadcast   退出码=1 命中=N_UCAST
  nic_crc         退出码=1 命中=N_CRC
  nic_avg         退出码=1 命中=N_AVG
  nic_missing     退出码=2 命中=NIC 文本缺字段 port_rx_unicast  ← 结构坏必须拒绝出结论
```

另有一套**假板子**自证（`_proj_pcie/p7b_gate4_selftest.sh`，产物 `p7b_gate4_tools/selftest/`）：
`OK=14 BAD=0`，验的是 `p6e_snap_check.sh` 本体（51 地址序列 / 0xE8 / 0xEC / 6.1 正反两面）。

⭐ **这两套东西当场抓到 2 个真 bug（都不是"按构造它会失败"的纸面结论）**：
1. `freq_check` 里用了 `$W32`，而该变量在 `p6e_snap_check.sh` 里**从未定义** ⇒ `set -u` 下整脚本
   在 4.3 段崩掉（`line 151: W32: unbound variable`）。已补 `W32=$((1<<32))`（`p6e_snap_check.sh:43`）；
2. **解析失败时未清数组** ⇒ `nic_copy` 没被调用，全局数组还留着**上一对**的值，判据照样打印
   PASS/FAIL —— 而它与本块读数毫无关系（正是本工程最贵的"判据与读数脱钩"）。
   已加 `abort_if_fatal`（结构坏一律拒绝出结论，退出 2），负对照 `nic_missing` 就是它的牙。
⇒ **自证/负对照不是形式主义, 它们当真能抓错。**

---

## 5. `snap_idx` / `snap_base` 位宽核算（**逐行读过源码**，结论：够用，本轮不必改 RTL）

| 项 | 源码 | 51 字的要求 | 结论 |
|---|---|---|---|
| `SNAP_NW` | `axi_regs.v:78`（由 wrapper `:3708` 传 `SNAP_NW_P6E=51`） | 51 | ✅ 单一来源 |
| `SNAP_LAST_IDX` | `axi_regs.v:118` `= 8 + SNAP_NW - 1` | 58 (=0xE8) | ✅ 派生 |
| `snap_idx` | `axi_regs.v:212` `wire [5:0] snap_idx = r_word[5:0] - SNAP_W0_IDX[5:0]` | 最大 50 ⇒ `ceil(log2(51))=6` 位 | ✅ **6 位正好**（够，无余量；扩到 57 字就要 6 位仍够，64 字要 7 位） |
| `snap_base` | `axi_regs.v:227` `wire [11:0] snap_base = {snap_idx, 5'b0}` | 最大 `50<<5 = 1600` ⇒ 需 11 位 | ✅ **12 位**（4095），余量 2.5× |
| 地址译码上限 | `axi_regs.v:173` `ar_word = araddr[7:2]`（6 位 ⇒ word 0..63），快照从 word 8 起 | **NW ≤ 56** | ✅ 51 ≤ 56（余 5 字） |
| 绝对上限（12 位口径） | `(NW−1)<<5 ≤ 4095 ⇒ NW ≤ 129` | —— | 56 更紧 ⇒ **56 才是硬上限**（见 `P7B_SPEC.md:684` B6） |

**结论**（可直接引用）：`snap_idx`(6) 与 `snap_base`(12) **已经同时加宽过**（`axi_regs.v:208-227`
的注释记着两次踩坑史：只改一处 ⇒ 高地址字**静默回绕**读成低地址字 = 假 PASS），
**51 字在这两条线上都成立，本轮不需要动 RTL**；扩窗到 57 字起必须重新核算这四行。

---

## 6. `dbg_hub` 侦察结论（备选观测通道）

**结论：闸 4 位流不会有 `dbg_hub`，`get_hw_probes` 读数会**是空的**；它**不能**当第二个观测通道。**
（严格措辞：位流尚未构建完成 ⇒ 板上复核未做；下面是**源码/工程产物**级的证据，板上复核留给闸 4 执行者。）

**依据（逐条可复核）**：

1. **`dbg_hub` 是 Vivado 为调试核自动插入的 JTAG→AXI 桥**，只有存在 ILA/VIO 时才出现；
   它本身**不是**用户可读的探针 —— 探针是 ILA/VIO 的 `probe_in/probe_out`。
2. **闸 4 的设计没有任何调试核**：
   - `board/build_p7b_ku5p.tcl` 全文只 `create_ip` 两个（`:45` `xxv_ethernet`、`:114` `xdma`），
     **零** `vio`/`ila`/`create_debug_core`；
   - `board/wrapper_p4.v` 对 `vio|ila|dbg_hub|BSCAN` 的命中仅 3 处，全是**信号名**
     （`v7_id_viol_w` 等，`:1365,:1458,:2329`）⇒ 无调试原语、无 `mark_debug`。
3. **同形状构建的经验证据**：`vivado_prj/p6e_ku5p_prj.runs/impl_1/` 与 `p6b_final_ku5p_prj.runs/impl_1/`
   **都没有 `.ltx`**（Vivado 只在有调试核时才生成 `debug_nets.ltx`/`<top>.ltx`）；
   而**有** VIO 的 `p7b_lat_prj.runs/impl_1/` 有 `debug_nets.ltx` + `wrapper_p4.ltx`。
4. **`P7B_LATENCY.md:422` 里那 8 条 `dbg_hub` 时序端点属于哪个位流**：属于 **p7b_lat 延迟探针**
   —— `_proj_10g/p7b_lat/scripts/build_p7b_lat_ku5p.tcl:142` `create_ip -name vio -module_name vio_lat`
   + `_proj_10g/p7b_lat/rtl/p7b_lat_top.v:547` `vio_lat u_vio`；`grep dbg_hub` 命中的
   `p7b_lat_timing.rpt:170/208/239/243/253` 是 `dbg_hub/inst/BSCANID.u_xsdbm_id/.../SERIES7_BSCAN...`。
   ⇒ **那是"加了 VIO 的那个位流"的产物，不是闸 4 位流的**。
   （闸 1 的 `xxv_loop` 同理：`xxv_loop_top.v:117-144` 一堆 `vio_*`，工程里有 `.ltx`。）
5. **未确定项**：板上**现在**跑的是哪个位流未核实（`P7B_GATE4_PLAN.md` U2；PCIe BAR 全 F ⇒ 观测通道死）。
   若恰好是 p7b_lat，那么 `get_hw_probes` **能**读到**那个设计的**探针 —— 但那些数与闸 4 无关（陈旧），
   而且重烧闸 4 位流后它们就消失。

**要"第二个观测通道"的唯一便宜路**（与 `P7B_GATE4_PLAN.md` Q5(c)③ 一致）：
给 `build_p7b_ku5p.tcl` 加一个 `vio`（照抄 `p7b_lat` 的两处）⇒ Vivado 自动插 `dbg_hub` 并出 `.ltx`
⇒ `probe_lat.tcl` 的 `vset/viget/pulse` 五坑照用。代价 ≈ 一次 45 min 构建 + 一次烧录 + 一次重启。
**离线判据**（不用连板就能先判）：`ls <prj>.runs/impl_1/*.ltx` 存在 = 有可读探针。

---

## 7. 未确定项 / 给闸 4 执行者的三条警告

1. ⚠️ **W50（`tx_clk_act`）的 ÷1/÷2 口径在源码里自相矛盾，不许猜**：
   `board/wrapper_p4.v:3385` 注释写"频率 = 沿数/2"，但 RTL（`:3387-3400`）是
   `tx_tgl_tx <= ~tx_tgl_tx` —— **每拍 `tx_fe_clk` 翻转一次**，dp 侧数的是**每次变化**
   ⇒ 数学上 `沿数/秒 = tx_fe_clk`，即 **÷1**；按 ÷2 读会得 78.125 MHz = **假 FAIL**。
   两个口径差正好 2 倍，**不烧板判不了** ⇒ 本脚本（`p6e_snap_check.sh` 与 `p7b_gate4_accept.sh`）
   **两个都算**：命中 ÷1 ⇒ 该订正那份注释；命中 ÷2 ⇒ 订正本文件的分析。
   **一次上板把这条钉死**（这是本轮新增的未定项，`P7B_GATE4_PLAN.md` 尚未记录）。
2. ⚠️ **P6 时代的脚本不要拿去跑 P7b 位流**：`p6e_watch.sh` / `p6e_capture.sh` / `p6e_slowpath_probe.sh` /
   `p6b_smoke_{gate,account}.sh` 仍是 **36 字 / 未实现地址 = 0xB0** 口径。
   - 读窗口的那几个（`p6e_watch/capture/slowpath_probe`）会**只读前 36 字** —— W36..W50 的内容
     它们看不见（对旧判据无害，但**不能拿它们声称"窗口读全了"**）；
   - `p6b_smoke_gate.sh:29` 有 `A_UNIMPL=0xb0` 这条判据：在 P7b 位流上 `0xB0` 已经是**已实现**的
     W36（`mrx_stat_rx_words`）⇒ 它不再回 `0xffffffff`，那条判据从"验译码边界"**悄悄变成**
     `SKIP（该地址已实现）`（`RC_U=0` 分支）—— **口径变了而输出看着仍然正常**。
   本轮**故意没改它们**（它们服务的是 P6b 位流；改了反而让 P6b 档失去工具）。闸 4 一律用 `p7b_gate4_accept.sh`。
3. ⚠️ **live 路径未上板跑过**（本轮不许烧板）⇒ 首次上板先跑 `G4_SKIP_TRAFFIC=1` 那一档，
   它会先把板侧身份/51 字/频率/守恒/PCS 全部过一遍（≈3 min），过了再打流。

---

## 8. 怎么跑（命令原文）

```bash
cd /d/repo/XCKU5PMini/udp_hls_10g          # 本仓根 (git 仓根)

# ① 只做工具自证 (不碰任何板子; 秒级~分钟级)
bash _proj_pcie/p7b_gate4_negctrl.sh        # 14 条负对照 (合成读数) → negctrl/SUMMARY.txt
bash _proj_pcie/p7b_gate4_selftest.sh       # 假板子验 p6e_snap_check.sh → selftest/SUMMARY.txt

# ② 闸 4 板侧前置 (先烧位流 → 重启对端机, 见 P7B_GATE4_PLAN.md 步骤 2/3)
PEER_PW=111111 G4_SKIP_TRAFFIC=1 bash _proj_pcie/p7b_gate4_accept.sh
#    ⇒ 身份(G1) + 51 字窗口(B_WIN/B_UNIMPL) + 三域频率(G2-W5/W24/W50)
#      + 守恒律(B_CONS/B_DIR) + PCS(C1-C8) + NIC 基线窗判别力自检(N_BASE)

# ③ 全链 (会自己补路由、教学、打流、取测量窗 + 洪泛窗)
PEER_PW=111111 bash _proj_pcie/p7b_gate4_accept.sh
#    退出码: 0 全 PASS / 1 有 FAIL / 2 前置闸拒绝

# ④ 窗口快检 (只要 51 字与身份, 不要 NIC 那一套; 部署到对端机跑, 与 P6e 时代同款)
#   scp _proj_pcie/p6e_snap_check.sh a@192.168.0.38:/home/a/xdma_test/
#   sudo bash /home/a/xdma_test/p6e_snap_check.sh     # 默认 SNAP_WORDS=51 / EXPECT_BID=7
#   sudo bash /home/a/xdma_test/p6e_snap_check.sh     # 跑历史 P6b 位流时: EXPECT_BID=0x00000006 SNAP_WORDS=36
```

**开关速查**：`G4_SKIP_TRAFFIC=1`（只跑停机态）· `G4_TRAFFIC_CMD=...`（换激励）·
`G4_IFACE=`（口名）· `EXPECT_BID=`（认位流）· `SNAP_WORDS=`（窗口几何）· `G4_BIT=`（算 sha256）·
`NIC_GOOD_MIN` / `NIC_MBPS_MIN`（阈值）· `G4_SNAP_TEXT` / `G4_NIC_TEXT`（合成读数，逗号分隔 **2 或 4** 个文件）。

---

## 9. 文件清单（本轮新增/改动，全部在本 agent 的所有权范围内）

| 文件 | 动作 |
|---|---|
| `_proj_pcie/p6e_snap_check.sh` | **就地改**（缺陷① 51 字派生 / 缺陷② 0xEC + `$U84` / 4.3 三域频率 / 表 51 行 / `W32` bug） |
| `_proj_pcie/p6b_accept.sh` | **最小改**（`readall()` 44→36 项**去重复**、改由 `READ_NW` 派生；注释里的 0xB0→0xEC 提示） |
| `_proj_pcie/p7b_gate4_accept.sh` | **新建**：闸 4 验收主体（板侧 51 字 + NIC 四件套 + 判别力自检 + 合成读数入口） |
| `_proj_pcie/p7b_gate4_negctrl.sh` | **新建**：15 条负对照驱动 |
| `_proj_pcie/p7b_gate4_selftest.sh` | **新建**：假板子自证（验 `p6e_snap_check.sh`） |
| `_proj_10g/notes/P7B_GATE4_TOOLING.md` | **本文件** |
| `_proj_10g/notes/p7b_gate4_tools/**` | **新建**：`negctrl/`（14 条日志 + 输入文本 + SUMMARY）· `selftest/`（假板子 + 地址日志 + SUMMARY） |

**没碰**（按派单的文件所有权）：`board/p7b_ku5p_*`、`vivado_prj/p7b_ku5p_prj*`、
`P7B_TIMING_RERUN.md`、`P7B_VENDOR_EXAMPLE_DEFECTS.md`、`P7B_LATENCY_GAPS.md`、
`P7B_HANDOFF.md`、`P7B_F2_CHAIN_ATTRIB.md`、`P7B_COMMIT_PLAN2.md`、`P7B_GATE4_PLAN.md`（只读引用）。
**未做**：任何烧录 / 重启 / RTL / XDC / 构建脚本改动 / `git add|commit` / 对端机状态改动。
