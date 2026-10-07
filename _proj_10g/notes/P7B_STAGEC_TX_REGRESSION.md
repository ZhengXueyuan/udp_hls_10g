# Stage C（`tcp_tx_frame` 乒乓 `TCP_TX_OVL` + A2）—— **独立回归报告**

- 日期：**2026-10-07**　角色：**回归测试 agent**（独立于实现 agent 与对抗审查 agent）
- 基线：HEAD = **`46b2f68`**；工作区 tracked 改动 = **两个文件**：
  | 文件 | 开工时 sha256 | 字节 | `git diff --stat` |
  |---|---|---|---|
  | `rtl/tcp_tx_frame.v` | `10e75f21f0720b03f28706abcc27e8f9cb0cc24b913137f8af943cb891245f27` | 116,380 | **+799 / −0** |
  | `rtl/app_pattern.v` | `0e804099400c2e2b800ef66bbf49d0d26892bb977e4523de208581ef0d81ce06` | — | **+72 / −0** |
  （`10e75f21…` / `0e804099…` 与**作者报告 `P7B_STAGEC_TX.md` §1.1 / §1.2 逐字相同** ⇒ 本报告 §2 的第一轮矩阵与 §4 的追加门就是**作者那一版**的读数。）
- ⛔ **本次头号环境事实（必须先读）**：**测量窗口内有另一支 agent 在改被测源码** ——
  `rtl/tcp_tx_frame.v` 在 25 分钟内出现**三个** sha256，`tb/tb_tcp_tx_ovl.v` 也被改到**当前编不过**（§5.1）。
  第一轮 16 门矩阵因此被判 **`REVISION DRIFT` / `MATRIX_EXIT=2`（整轮形式作废）**；我随后在**冻结的一版**上重跑（§2.3）。
- 我做了什么：**两轮 16 门 P4 矩阵**（作者未跑）+ **作者未跑的追加门**（`p5_status` / `p5_pattern` / `p5_wrapper` /
  `p5d_multi` 五档 / 真 `P7B_10G` 门 `p7b_appsplit` + `p7b_chain`）+ **每一个红的 HEAD 双臂归属** +
  ⭐ **「两种盲」的裁定与可复算证据**（镜像树上的**单字节破坏实验** M0/M1/M2/M3 + 我自己的预处理器）+ 作者门独立重跑。
- 纪律：⛔ 不烧板 / **未写 `0x08`** / 未碰板子；⛔ **未改任何既存源文件·TB·bat**（所有副本在 `sim/p7b_stagec_tx_regress/`，
  破坏实验**只在镜像副本**上做）；⛔ 未提交 git、未 `git add -A`。**零位流、零板级读数。**

---

## 0. 一页结论

| # | 问题 | 结论 |
|---|---|---|
| ① | **16 门 P4 矩阵（第一轮，作者那版 `10e75f21…`）** | **16/16 EXIT=0**，每门都有**真判据行**、16 个 console 的 `grep -i fail` **全 0 命中**；关键读数与上一轮基线**逐数相同**（§2.1）。⛔ **但整轮被判 `REVISION DRIFT`（exit 2）= 形式作废** —— 跑动期间 `rtl/tcp_tx_frame.v` 被另一支 agent 改过（§2.2） |
| ② | **16 门矩阵（第二轮，冻结版 `1a1f0439…`）** | **16/16 EXIT=0 · `gates failed: 0` · `VERDICT: FROZEN`（237 文件逐字相同）· `MATRIX2_EXIT=0`**，绑定到 `DIGEST_COMPILE=ec00bfa7…`；⭐ **与第一轮逐门判据行集合逐条相同（16/16 门，0 门有差）** ⇒ 新版那刀 `ring_start` 修复**没有**在 P4 门族留下任何可观测差异 |
| ③ | ⭐ **「两种盲」** | **同时成立，且各自有可复算证据**：(a) `tcp_tx_frame.v` **不盲**（在 `chain_src.f:16`、13 份 p4sim bat、**矩阵指纹里**，指纹逐字把它标成 `M`）而 `app_pattern.v` **盲**（5 份 manifest / 18 份 bat / 指纹 **全 0 命中**）；(b) **`+799` 全在 `ifdef TCP_TX_OVL` 内，而全仓没有任何一条门/构建定义该宏** ⇒ 冻结版之前的所有 repo 门对**新分支零判别力** |
| ④ | ⭐ **可复算证据（镜像树，真树零写入）** | **M0** 纯净件 → `EXIT=0` / `P4 CHAIN OK`；**M1** 单字节变异（删 `;`，落在 `TCP_TX_OVL` 区内）→ **`EXIT=0` / `P4 CHAIN OK`**（**盲**）；**M2** 同 M1 + `-d TCP_TX_OVL` → **`EXIT=1`** + `VRFC 10-4982 syntax error near 'wire' … tcp_tx_frame.v:437`；**M3** 单字节变异落在**默认分支**（`else` 区内）→ **`EXIT=1`** @ `:1011`（**门有牙** ⇒ M1 的绿是盲、不是坏门）。全程核 sha256 |
| ⑤ | ⭐ **我自己写的预处理器（独立于作者工具）** | 对 `10e75f21…`：宏关活行 **1147 == 1147 逐行相同**（两文件都成立）⇒「**宏关 = 逐字回到 HEAD**」是**证明**不是声称。⚠️ **对当前冻结版 `1a1f0439…` 该性质已不成立**（§2.4/§3.4：宏关 `+8 / −1`，删的是**默认分支**的 `ring_start` 行） |
| ⑥ | 作者未跑的追加门 | `p5_status` **绿** · `p5_pattern` **内容 FAIL（既存，EXIT=0）** · `p5_wrapper` **FAIL（既存）** · `p5d_multi` 五档（main **122/0**、neg_wq **24 FAIL**、neg_mgn **7 FAIL**、neg_mgn0 **4 FAIL**、known_idle_fifo **绿**）全部与基线**逐条相同** · ⭐ **真 `P7B_10G` 门第一次实跑**：`p7b_chain` = **106 PASS / 0 FAIL / `VERDICT = PASS`**（改址后的 `0x11C` 判据**首次真的被评估且通过**）；`p7b_appsplit` = **26 checks / 0 fail** |
| ⑦ | 每一个红的归属 | **全部红都有双跑对照**（§5）：`p5_pattern`/`p5_wrapper`/`p5d` 五档的**工作区臂 vs HEAD 臂判据行逐字相同**（`p5_wrapper` 的 HEAD 臂整份日志 md5 与上一轮 HEAD 臂**逐字节相同**）；**零新红** |
| ⑧ | 超出派单的追加：作者门**独立重跑** | ⭐ **`TX_OVL_GATE: PASS` / `AUTHOR_GATE2_EXIT=0`**（逐字副本，只改相对深度）：**A=0**（现役串行）/ **B=0**（乒乓，`REDS` 全 0）/ **C..K 全 =1**（每个变异红在可指名的判据上）。⚠️ 第一次重跑时 B 假红（`RC=1`），根因是 **TB 正被另一支 agent 改到编不过**（`d_ctrl_win`/`win_prev`/`c6_req_win` 未声明）—— 已如实登记为**不可判**，TB 稳定后重跑才是上表读数（§5.1） |

---

## 1. 环境与并发（读数归属的前提）

| 项 | 值 |
|---|---|
| 仓库 | `D:\repo\XCKU5PMini\udp_hls_10g`，`git rev-parse HEAD` = **`46b2f68`** |
| 我的独占工作目录 | **`sim/p7b_stagec_tx_regress/`**（镜像树、HEAD 臂 rtl、追加门副本、变异件、日志全在这里） |
| 我改过的**已跟踪**文件 | **无**（矩阵 runner 自己的产物 `sim/p4sim/matrix_p4dfix.log` 与 `P4_MATRIX_FINGERPRINT_*` 是它自己的输出路径） |
| ⛔ 同机并发（**实测**） | **另一支 agent 在我窗口内改了被测源码**：`rtl/tcp_tx_frame.v` = `10e75f21…`(116,380 B) → `a37b41aa…`(117,808 B) → **`1a1f0439…`(118,054 B, 16:00:32, 此后稳定)**；`tb/tb_tcp_tx_ovl.v` = `ef34bd67…`(1107 行) → `5a8bea66…`(1252 行) → **`d27944e4…`(16:03:14)**。⇒ 第一轮矩阵 **exit 2（DRIFT）**，见 §2 |
| 我自己的收尾核账 | **两个被测源文件我一个字节都没改**（`app_pattern.v` 全程 `0e804099…` 未变；`tcp_tx_frame.v` 的三次变化全部来自另一支 agent）；`git status --short` 的 tracked 改动仍只有那 2 个源文件 + runner 自己的 `sim/p4sim/matrix_p4dfix.log` |

---

## 2. 全仓 16 门 P4 矩阵（作者未跑 · 我跑了两轮）

**逐字命令**（自定位 runner；git bash 经 `cmd //c`）：
```bash
cd /d/repo/XCKU5PMini/udp_hls_10g
cmd //c 'sim\p4gates\run_matrix_p4dfix.bat'                    # 第一轮 15:34:18 → 15:59:35
cmd //c 'sim\p4gates\run_matrix_p4dfix.bat'                    # 第二轮 16:01:36 → 16:26:36 (冻结版 1a1f0439)
```

### 2.1 第一轮（= 作者那版 `10e75f21…`）逐门表

| # | 门 | EXIT | A 列（门 console 尾）/ B 列（判据行） |
|---|---|---|---|
| 1 | `chain` | 0 | `frames RX=9 TX=11 (fast=6 slow=5)  STRIPPED=0` → **`P4 CHAIN OK`** |
| 2 | `burst200` | 0 | `TRUNCS (0, 0) ECOMAX 182` · `STATS_MAC (411, 0, 0)` → **`BURST OK`** |
| 3 | `trunc50` | 0 | **`BURST OK`** |
| 4 | `trunc100` | 0 | **`BURST OK`** |
| 5 | `halfdrop` | 0 | **`BURST OK`** |
| 6 | `txdrop50` | 0 | **`BURST OK`** |
| 7 | `gate4096` | 0 | **`BURST OK`**（`TCBF (…, 4096, …)`） |
| 8 | `dupstorm` | 0 | **`BURST OK`** |
| 9 | `pcackoob` | 0 | **`BURST OK`** |
| 10 | `vlanchain` | 0 | `STRIPPED=2 (期望 2, VLAN ON)` → **`P4 CHAIN OK`** |
| 11 | `vlanburst` | 0 | **`BURST OK`** |
| 12 | `stallgate` | 0 | `PCSTALL 停发拍=141623 … 高水位=1235EB75` → **`PCSTALL OK (burst=200, echo 帧 240)`** |
| 13 | `unit_retx` | 0 | ⚠️ 该门 bat 以 `type xsim.log` 收尾（**exit 0 无条件**）⇒ 读 B 列：**`ALL 7 GROUPS PASS`** |
| 14 | `unit_fifo` | 0 | ⚠️ 同上 ⇒ B 列：**`PASS_ALL  frame_fifo unit: writes A=568139 B=595715 C=616302 pops A=567224 B=591216 C=611802 cycles=750700`** |
| 15 | `unit_vlan` | 0 | **`VLAN_STRIP TB PASS (in=1595 words, out=1502 words, vlan frames=66, stripped=66)`** |
| 16 | `unit_uart` | 0 | **`ALL_OK`** + **`UART-GATE-OK`** |

**附加硬扫描**：16 个 `_gate_console.log` 的 `grep -i fail` **命中数全部为 0**；每门 `scanlog` 报 `0 outside the repo`。
**逐数对基线**（上一轮 `P7B_STAGEB_RX8_REGRESSION.md` §2.1）：`chain` 的 `RX=9 TX=11 (fast=6 slow=5)`、
`burst200` 的 `STATS_MAC (411,0,0)`、`unit_fifo` 的 `568139/595715/616302/567224/591216/611802/750700`、
`unit_vlan` 的 `1595/1502/66/66`、`stallgate` 的 `PCSTALL OK (burst=200, echo 帧 240)` —— **逐数相同**。

### 2.2 ⛔ 但第一轮整轮被判 **REVISION DRIFT**（`MATRIX_EXIT=2`）

runner 自己的 before/after 指纹 diff（**唯一差异**）：

```
209c209
< SHA256 10e75f21f0720b03f28706abcc27e8f9cb0cc24b913137f8af943cb891245f27  rtl/tcp_tx_frame.v  116380  1791357969
> SHA256 a37b41aa37700a961b309b230c9c1855de2e1addb94c9d611a67e48b01e48916  rtl/tcp_tx_frame.v  117808  1791359694
DIGEST_COMPILE: e69ee6d6… → d3da2c88…
```
⇒ **另一支 agent 在 15:34–15:59 之间改了被测文件**；按 runner 的口径「**per-gate results 不再绑定到任何单一 revision**」。
⇒ 我立刻**冻结**当时的最新版（`frozen/tcp_tx_frame_rev1a1f0439.v`，sha256 与工作区**逐字核对**）并**重跑整轮**。

### 2.3 第二轮（冻结版 `1a1f0439…`，16:01:36 → 16:26:36）

| 项 | 读数（逐字） |
|---|---|
| 逐门 | **16/16 `EXIT=0`**（`chain`/`burst200`/`trunc50`/`trunc100`/`halfdrop`/`txdrop50`/`gate4096`/`dupstorm`/`pcackoob`/`vlanchain`/`vlanburst`/`stallgate`/`unit_retx`/`unit_fifo`/`unit_vlan`/`unit_uart`） |
| 总结行 | `gates run : 16 / 16` · `gates failed: 0` · **`MATRIX2_EXIT=0`** |
| 冻结 | **`VERDICT: FROZEN -- all 237 hashed files byte-identical across the run`**（`DIGEST_COMPILE` before == after == `ec00bfa7…`） |
| ⭐ 与第一轮对比 | **16 门判据行集合逐条相同（0 门有差）** —— 新版 `ring_start` 修复在该门族无差异 |

**⇒ 两轮合起来给出的结论**：**矩阵面在这两个 revision 上都是 16/16 绿，且逐门读数相同**；第一轮的形式缺陷（DRIFT）由第二轮的 `FROZEN` 补齐。
⚠️ 但**判别力仍为 0**（§3）：两轮跑的都是宏关构建。

### 2.4 ⭐ 两轮之间的**实质差异**（这是本轮最值得下游读的一条）

```diff
-    wire        ring_start = ring_eval && (ring_delta != 32'd0) && scan_estab;
+    wire        retx_ovf = (rb_snd_nxt != retx_hi) &&
+                           ((rb_snd_nxt - retx_hi) < 32'h8000_0000);
+    wire        ring_start = ring_eval && (ring_delta != 32'd0) && !retx_ovf &&
+                             scan_estab;
```
（注释逐字：`⭐ Stage C 修复 (对抗审查 B1/F1): 控制帧帧首预留的 +1 可以让 rb_snd_nxt 越过 retx_hi ⇒
ring_delta 32 位下溢成 0xFFFFFFFF … 改成回绕安全的"正 delta"`）

⇒ **这一刀改的是「默认分支」（宏关也编的活代码）**：`10e75f21…` 的「**+799 / −0、宏关逐字 = HEAD**」性质
在新版上**不再成立**（`git diff --stat` = **+822 / −1**；我自己的预处理器给出宏关 **+8 / −1**）。
⇒ 对本轮改动的**回归判据**而言：**新版的"宏关"本身就是一个真改动**，必须由矩阵/门重新覆盖 —— 这正是第二轮在做的事。

⭐ **旁证（不是我的结论，是另一支的）**：`_proj_10g/notes/P7B_STAGEC_TX_REVIEW.md` §0/§5.2 把这一族定成**阻断级 F1**
（「`retx_hi` 被控制帧预留 `+1` 越顶 ⇒ `ring_delta` 下溢 ⇒ G9 类重放洪水」），其**修法①（三选一里的"回放侧回绕安全守卫"）**逐字就是
「把 `(ring_delta != 0)` 升级为**正 delta**」 —— 与我观察到的 `retx_ovf` 补丁**同一形状**。
⇒ 时间线自洽：**审查 15:51 出 F1 → 作者 16:00 落地修复（落在默认分支）→ 我 16:01 起在冻结版上重跑**。
⚠️ 该修复的**语义**（是否闭合 F1）**不在我的判据内**，我只报：**它改变了宏关构建，且 P4 门族读数无差异**。

---

## 3. ⭐ 头号任务：两种「盲」的裁定 + 可复算证据

### 3.1 机制 (a)：清单里有没有这个文件（**逐份 grep**）

| 检查对象 | 命令 | `tcp_tx_frame` | `app_pattern` |
|---|---|---|---|
| **5 份 manifest** | `grep -c <f> sim/p4gates/*_src.f` | **`chain_src.f:16` = 1**（注：**已知事实，复核成立**） | **0** |
| **18 份 p4sim bat** | `grep -rc <f> sim/p4sim/*.bat` | **13 份含**（`run_probe`/`run_tb_p4_{burst,burst_vlan,burst_xk,chain,chain_active,chain_active_slow,chain_stall,chain_stall_xk,chain_vlan,chain_xk,replay}`/`xvlog_wp4b`）；`rxclass{,_xk}`/`slowrx`/`slowtx`/`txarb` 5 份不含 | **0** |
| **runner** `sim/p4gates/run_matrix_p4dfix.bat` | grep | 0（列表参数化） | 0 |
| **守卫** `sim/p4gates/p4gate.py` | grep | 0 | 0 |
| **路径表** `sim/p4gates/paths.txt` | grep | 0（指纹经 manifest 汇入） | 0 |
| ⭐ **矩阵修订指纹**（现役 `sim/p4sim/P4_MATRIX_FINGERPRINT_20261007_153418_before.txt`，237 文件） | grep | **在**：`SHA256 10e75f21…  rtl/tcp_tx_frame.v  116380`，且头部 `MODIFIED vs HEAD (tracked, inside the hashed set): 1 / M rtl/tcp_tx_frame.v` | **0 命中** |
| ⭐ **跨 revision 指纹 diff**（本轮 vs 上一轮 `…_115515_before`） | `diff` | **唯一差异行**就是 `rtl/tcp_tx_frame.v`（`d2dab616` → `10e75f21`），`DIGEST_COMPILE` 随之改变 | — |

**裁定 (a)**：
- `tcp_tx_frame.v`：**在这条路上不盲**（编译表 + 指纹 + 只要它一变，同一个 runner 就会判 **DRIFT / exit 2**）—— 与派单给的已知事实一致。
- `app_pattern.v`：**盲**（不在任何 manifest/bat/指纹里；上一轮已实证，本轮复核仍为 0 命中）。

### 3.2 机制 (b)：宏关构建选中的是别的代码（**实证**）

**全域 grep（本仓到底有没有哪条门用 `TCP_TX_OVL` 构建）**：

| 命中处 | 是不是「门/构建」 |
|---|---|
| `rtl/tcp_tx_frame.v`（`:204` 的 `` `ifdef ``） | 设计本身 |
| `tb/tb_tcp_tx_ovl.v`（被测 TB 自己的 `` `ifdef ``） | 判据门 TB |
| `sim/p7b_stagec_tx/run_tx_ovl_gate.bat`（**A 关 / B..K 开**） | **作者 scratch 的门（唯一）** |
| `sim/p7b_stagec_tx_review/chk_pure_insert.py` | 对抗审查的检查器 |
| ⛔ `board/build_p7b_ku5p.tcl:145` | **不含**：`{APP_MODE=1 DEV_USP=1 PCIE_OBS=1 DP_156MHZ=1 P7B_10G=1 UDP_TX_OVL=1}`（**无 `TCP_TX_OVL`**） |
| ⛔ `_proj_10g/p7b_chain`、`_proj_10g/p7b_appsplit` 的 xvlog 行 | **不含**（`-d P7B_10G -d P7B_SIM_NOPCS -d PCIE_OBS -d DEV_USP -d APP_MODE -d DP_156MHZ -d P6B_SIM_CLKGEN`） |

**⇒ 判决：本仓（作者 scratch 之外）没有任何一条门/构建用 `TCP_TX_OVL` 构建。**
⇒ `+799` 行（乒乓分支）在 **P4 矩阵、p5 家族、p7b 两条真门、以及 `board/` 构建脚本**里**全部不编译**。

### 3.3 ⭐ 镜像树破坏实验（**可复算**；真树一个字节没动）

**做法**：把门机制（`sim/p4gates/*` + `sim/p4sim/run_tb_*.bat`）+ `rtl/`+`tb/`+`tools/`+`hls/…/verilog`
（+ `board/uart_dbg.v`，指纹会走 5 份 manifest 的并集）复制到 **`sim/p7b_stagec_tx_regress/mirror/`**；
镜像里的 `p4env.bat` **自定位** ⇒ `REPO_ROOT` = 镜像根 ⇒ **编译的是镜像里的源**（真树只被读）。
每次跑的是**同一个矩阵入口**：`mirror\sim\p4gates\run_matrix_p4dfix.bat -only chain`（`-only chain` = 只跑编译该文件的 12 门族里的代表门，其余 15 门打 `SKIPPED`）。
落位脚本 = `setup_arm.py`（每臂先复位）。变异件 = `mk_mut.py`（**逐字节自证**：基线 sha256、锚点恰 1 次命中、恰 1 字节删除、锚点行在声明的 `ifdef` 区间内）。

| 臂 | 镜像 `rtl/tcp_tx_frame.v` | 宏 | 矩阵 EXIT | 逐字结果 |
|---|---|---|---|---|
| **M0** | 纯净件（= 工作区 `10e75f21…`） | 关 | **0** | **`P4 CHAIN OK`**（基线；镜像 `DIGEST_COMPILE = e69ee6d6…` **与真树逐位相同**） |
| **M1** | **mut_ovl**（删 L436 行尾 `;`，**在 `ifdef TCP_TX_OVL` 区内**，`diff_at=[24975]`，sha `c4fe478c…`） | 关 | **0** | ⭐ **`P4 CHAIN OK`**（**盲**）；镜像 `DIGEST_COMPILE = e4066f7b…`（**指纹看见了这一字节**，判据看不见） |
| **M2** | 同 M1 | **开**（镜像 bat 的 rtl xvlog 行加 `-d TCP_TX_OVL`） | **1** | ⭐ **`ERROR: [VRFC 10-4982] syntax error near 'wire' […/mirror/rtl/tcp_tx_frame.v:437]`** + `10-8549` + `10-2989 'upd_wr_ctrl' is not declared` ×3 + `module 'tcp_tx_frame' is ignored` |
| **M3** | **mut_def**（删默认分支 L1010 `wait_cnt` 声明的 `;`，**在 `else` 区内**，`diff_at=[54966]`，sha `d3ff1ea7…`） | 关 | **1** | ⭐ **`ERROR: [VRFC 10-4982] syntax error near 'reg' […/tcp_tx_frame.v:1011]`** ⇒ **同一扇门对默认分支有牙** |

**⇒ 判决**：M1 的绿 **不是**「门坏了」（M3 同门同机制亮红），而是**结构性盲** ——
**要看见乒乓分支，必须同时做到**：① 该门编到 `tcp_tx_frame.v`（它已在清单里，M1 已满足）；
② **该门用 `-d TCP_TX_OVL` 构建**（当前**全仓无人做**，M2 才满足）。

### 3.4 独立佐证：**我自己写的**预处理器（不引用作者工具）

`my_preproc.py`（行级 `` `ifdef/`ifndef/`elsif/`else/`endif `` + 嵌套，其余行原样）：

| 文件 | 宏关活行（工作区 vs HEAD） | 逐行相同 | 宏开 |
|---|---|---|---|
| `tcp_tx_frame.v`（**`10e75f21…` 那一版**） | **1147 == 1147** | ✅ **是**（`13bee796aef9329f` == `13bee796aef9329f`） | `+791 / −0` |
| `app_pattern.v`（`0e804099…`） | **557 == 557** | ✅ **是**（`f4f3a85c4b87cde4` == `f4f3a85c4b87cde4`） | `+251 / −0` |

> ⚠️ 对**当前冻结版 `1a1f0439…`** 同一脚本给出 **宏关 `+8 / −1`（不相同）** ⇒ §2.4 的 `ring_start` 修复正是那 8+1 行。

### 3.5 顺带：A2（`app_pattern.v`）的覆盖面

`-d P7B_10G` 的门（`_proj_10g/p7b_chain`、`_proj_10g/p7b_appsplit`、`sim/p5e_rate`、`sim/p5wu_p1p2/run_xvlog_wrapper63.bat`、
`_proj_10g/notes/p7b_biz_win/run_xvlog_wrapper.bat`、作者门、`board/build_p7b_ku5p.tcl`）**会编译 A2 的代码**（语法/elaborate 面有覆盖，§4 的 `p7b_*` 两门实测通过即为此面证据）；
但 **p5 家族与 P4 矩阵全是宏关**（`p5_pattern` 的 xvlog 行**连 `-d` 都没有**）⇒ A2 的行为面（TX 拍/帧）**只**在作者自己的 `sim/p7b_stagec_a2/run_a2_gate.bat` 里有覆盖。

---

## 4. 作者未跑的追加门（**我做**；副本在我的 scratch，canonical 目录零写入）

> ⚠️ **读法坑（先读）**：投影纪律要求 bat 必须 CRLF。我第一次生成副本时**用文本模式读 + 二进制写，把 CRLF 压成 LF**，
> 导致 `p7b_chain` 的 bat 被 **cmd.exe 逐行错位执行**（`REM` 里的单词被当命令跑：`'clk_gen_p6b' is not recognized…` ⇒ `EXIT=255`）。
> 已修为**逐字节复制 + bytes 层替换**（`mk_extra.py` 里有断言），**受影响的全部门均已重跑**；下表全部是 **CRLF 修复后**的读数。
> （`p5_status`/`p5_pattern`/`p5d_main` 在 LF 版下也跑通并给出与基线相同的判据行，但**不作为证据**，一律以 CRLF 版为准。）

| 门 | EXIT | 关键读数（逐字） | 归属 |
|---|---|---|---|
| `p5_status` | **0** | `P5 STATUS OK`（`STATUS got` 与 `exp` 逐字符相同） | 绿（⚠️ 该门**只编 `app_status_uart.v`** ⇒ 结构上与本改动无交集） |
| `p5_pattern` | **0（内容 FAIL）** | `P5 PATTERN FAIL viol=0 last_beats=2 keep_bad=1 active=0` + `W3 case1: beats 40 -> 42, last_beats=1, viol=0 keep_bad=1 active=0` + `W3 case2: beats=64 last_beats=2 viol=0 keep_bad=1 active=0` | ⭐ **既存红**（§5.2） |
| `p5_wrapper` | **1** | `wrapper GMII: 0 帧 (conn0 数据 0 / 其它 0 / 坏 FCS 0)` → `MISMATCH: wrapper 只出了 0 个 conn0 数据帧 (<2)` → `P5 WRAPPER FAIL (1 项)` | ⭐ **既存红**（§5.3） |
| `p5d_multi main` | **0** | `== P5d multi: 122 checks, 0 FAIL ==` | 绿（与基线 122/0 相同） |
| `p5d_multi neg_wq` | **1** | `== P5d multi: 112 checks, 24 FAIL ==`（① 族） | 设计性红 ✔（§5.4） |
| `p5d_multi neg_mgn` | **1** | `112 checks, 7 FAIL`（④ 族） | 设计性红 ✔ |
| `p5d_multi neg_mgn0` | **1** | `112 checks, 4 FAIL`（⑥×2 + ⑦×2） | 设计性红 ✔ |
| `p5d_multi known_idle_fifo` | **0** | `[probe] 失配字节=0 kaerr=0 evfrm=0 sink=73728 occ=0 accepted=73728` | 绿 |
| ⭐ `p7b_chain`（**第一次实跑**） | **0** | **`106 PASS / 0 FAIL`**，`VERDICT = PASS`；其中 **`[PASS] 7b 0x11C reads 0 no wrap`**（原 `0xEC` 陈旧判据已被改址） | **绿** |
| `p7b_appsplit` | **0** | `==== tb_p7b_appsplit done: 26 checks, 0 fail ====`（`LANE 0` 13/0 · `LANE 4` 13/0） | 绿（复现上一轮 26/0） |

### 4.1 ⭐ 冻结版（`1a1f0439…`）上的**第二次**追加门批（`r2_log_*`）

| 门 | r1（`10e75f21`） | r2（`1a1f0439`） | 判据行对比 |
|---|---|---|---|
| `p5_wrapper` | EXIT=1（FAIL） | EXIT=1（FAIL，逐字同 3 行） | **相同** |
| `p7b_appsplit` | `26 checks, 0 fail` | `26 checks, 0 fail` | **相同** |
| `p7b_chain` | `106 PASS / 0 FAIL / VERDICT = PASS` | `106 PASS / 0 FAIL / VERDICT = PASS` | **相同** |
| `p5d_multi main` | `122 checks, 0 FAIL` | `122 checks, 0 FAIL` | **相同** |
| `p5d_multi` 四档 | 24 / 7 / 4 FAIL + probe 全 0 | 24 / 7 / 4 FAIL + probe 全 0 | **逐条相同**（FAIL 行集合比对） |

⇒ **冻结版那刀（默认分支 `ring_start` 回绕守卫）在追加门上也零差异**（8/8 次执行判据行相同）。

**⭐ `p7b_chain` 的改址前后对照（这次是它第一次真的跑到那条判据）**：

| | 上一轮（判据修正**前**的本门副本） | 本轮（真门 + `0x11C`） |
|---|---|---|
| 逐字 | `[FAIL] 7b 0xEC reads 0 no wrap  src=axi_regs decode; 51-word bound`，`VERDICT = FAIL`，**105 PASS** | **`[PASS] 7b 0x11C reads 0 no wrap`**，`VERDICT = PASS`，**106 PASS** |
⇒ **既存红已随判据修正消失，且没有引入新红**（106 = 105 + 修好的那一条）。

---

## 5. 逐红归属（**每一个红都配双跑对照**）

**HEAD 臂做法**：`head_rtl/` = 工作区 `rtl/` 的副本 + **`git show 46b2f68:rtl/{tcp_tx_frame,app_pattern}.v`** 覆盖
（sha256 核过 = `d2dab616…` / `da7a2c7c…`）；门 bat 的副本里只改 `set RTL=` 指向它（自检 `selfcheck` 照跑）。

| # | 红 | 工作区臂 | HEAD 臂 | 判定 |
|---|---|---|---|---|
| 5.1 | 作者门 **B 臂 RC=1** | 见下 | 见下 | ⛔ **不可判**（TB 正在被改） |
| 5.2 | `p5_pattern` 内容 FAIL | EXIT 0；三行判据 | EXIT 0；**判据行逐字相同**（另与上一轮工作区臂/HEAD 臂 2 份**共 5 路相同**） | **既存红**，对本改动**零敏感**（该门编 `app_pattern.v` 但**宏关**） |
| 5.3 | `p5_wrapper` FAIL | EXIT 1 | EXIT 1；**整份日志与我本人 HEAD 臂只差一行（我手工追加的 `P5_WRAPPER_EXIT=1`）⇒ 门输出逐字节相同**；且我的 HEAD 臂日志 md5 `e042afb3ab402e547abfa83380868ff8` **= 上一轮 HEAD 臂 = 上一轮工作区臂（三份逐字节相同）** | **既存红**（根因仍未定位 ⇒ 沿用上一轮登记；与本轮改动无关的**结构性**证据：该门编 `tcp_tx_frame.v` 但**宏关** ⇒ 与 `10e75f21…` 的 `+799` 无交集） |
| 5.4 | `p5d_multi` 五档 | EXIT 0/1/1/1/0；判据行集合 | 五档**判据行集合逐条相同**（`main` 122/0；`neg_wq` 24 FAIL ①族；`neg_mgn` 7 FAIL ④族；`neg_mgn0` 4 FAIL ⑥⑦；`known_idle_fifo` probe 全 0），且与**上一轮基线**的 FAIL 行集合**逐条相同** | **设计性红**（负对照本应非零）+ 对本改动**零敏感** |
| 5.5 | `p7b_chain` / `p7b_appsplit` | **两门全绿** | 未跑（无红可归） | — |

**（`known_idle_fifo` 是绿，也做了双臂：判据行相同。）**

### 5.1 作者门独立重跑（**超派单的追加**）：先假红、后真绿

**结论（收尾时的有效读数）**：**`TX_OVL_GATE: PASS` / `AUTHOR_GATE2_EXIT=0`**（`author_gate_stdout2.txt`）

| 案例 | A | B | C | D | E | F | G | H | I | J（作者已登记"未证"，不计入） | K |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 我实测 RC | **0** | **0** | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 |
| 期望 | 0 | 0 | ≠0 | ≠0 | ≠0 | ≠0 | ≠0 | ≠0 | ≠0 | ≠0 | ≠0 |
| TB 结语（`TB_TCP_TX_OVL`） | **OK** | **OK** | FAIL reds=18 | FAIL reds=11 | FAIL reds=2102 | FAIL reds=207 | FAIL reds=284 | FAIL reds=2 | FAIL reds=2 | FAIL reds=15 | FAIL reds=81 |

B 的独立读数（`author_gate/runB/xs.log`）：`FRAMES recv=2443 data=2100 ctrl=343` ·
`COV frames=2100 replay_sessions=23 conns=4 plen0=265 singlebeat=802 ctrlblock=9196` ·
`MINGAP handoff_to_next_start=1 finmin1_hits=721 advwrite_to_next_start=5` ·
`T8 rx1460 min=189 / tx1460 min=191 / fp1460 min=191 · overlap=48/100` ·
**`REDS parse=0 csum=0 payload=0 seqcont=0 seqmono=0 ctrl=0 ctrl_to=0 onehot=0 pendbusy=0 replay=0 stuck=0 ovf=0 ackf=0`**。
⚠️ 与作者报告 §2.2 的 `recv=2436 / ctrl=336 / replay_sessions=17` **不是同一组** —— 因为**RTL 与 TB 都已不是作者那一版**（`10e75f21`→`1a1f0439`，TB 1107→1252 行）；**判据全 0 与 T8 的 189/191 不变**。

**⛔ 第一次重跑（TB 编辑中）的形态，作为"不可判"的实例留档**：

- **根因（逐字证据）**：同一份 stdout 里有
  `ERROR: [VRFC 10-2989] 'd_ctrl_win' is not declared [tb/tb_tcp_tx_ovl.v:724]`（+ `win_prev` `:725,:732`、`c6_req_win` `:728,:729`）
  ⇒ **`tb/tb_tcp_tx_ovl.v` 被另一支 agent 改到当时 `xvlog` 编不过**（1107 → **1252** 行；sha `ef34bd67…` → `5a8bea66…` → 收尾时 `d27944e4…`）。
  ⇒ **B 的 RC=1 是"TB 半成品"的产物，不是乒乓分支的读数**。
  （旁证：审查件 §0-#3 逐字说 `M-C6` 未证的作者结论**不成立**、且门里 `c6_n` 是**死计数器**；
  新加的 `c6_req_win`/`win_prev`/`d_ctrl_win` 正是补这条 —— 与 TB 的改动方向一致。）
- ⚠️ **两次重跑之间我只做了两件事**：`rm -rf author_gate/run[A-K]`（清掉半成品 workdir）+ 在**同一份副本**上重跑
  ⇒ 假红→真绿的唯一变量是**另一支 agent 把 TB 改到能编**。
- **C..K 变异**全红且红在可指名的判据上（`[C] seqmono` · `[E] onehot=2100` · `[F] csum` · `[G] parse=276 + T4 FIN/RST/SYN issued≠transmitted` ·
  `[H] T5 finmin1_hits=0 + T8 overlap 4%` · `[I] seqcont/seqmono` · `[J] payload=7` · `[K] seqmono=80`）。

---

## 6. 未测 / 未定位清单（**不许当已答**）

| # | 项 | 状态 |
|---|---|---|
| ① | **乒乓分支（`TCP_TX_OVL`）在 repo 门里的行为覆盖** | **= 0**（§3.2/§3.3）。唯一覆盖 = 作者 scratch 门 + 对抗审查的检查器 |
| ② | **作者门 B 臂** | ✅ **已测**（TB 改到能编后重跑）⇒ `TX_OVL_GATE: PASS`，B=0（§5.1）。⚠️ 但读数绑定的是 **TB=`d27944e4…` + RTL=`1a1f0439…`**（不是作者报告里那对），且**该门此后是否再被改未知** |
| ③ | 冻结版 `1a1f0439…` 的 `ring_start` 修复对**默认构建**的行为影响 | **已测两面**：矩阵第二轮 **16/16 FROZEN、与第一轮逐门相同**；追加门 r2 批 **8/8 判据行相同**（§2.3/§4.1）。⚠️ 这一刀**不是**「纯插入」⇒ 不能用"宏关 = HEAD"免测；且**它的语义是否闭合 F1 不在我的判据内** |
| ④ | 作者报告 `P7B_STAGEC_TX.md` 里登记的三格 | 原样转移：`M-C6` 未证（作者自陈；其 TB 正在补）· `J9 会话内覆盖到 retx_hi` 未收口 · T11/T12（真 wrapper 全链门 / 构建）未做 |
| ⑤ | 面积/时序/DRC | **零读数**（纪律：不跑构建、不碰板） |
| ⑥ | `p5e_rate` / `p5wu_p1p2` 编译面门 / `notes/p7b_rate8` 一族 | **未跑**（非本刀面；派单外） |
| ⑦ | `p5_app`/`p5_adv_*`/`p5_fc`/`p5_flow`/`p5close` 等其它 P5 家族门 | **未跑**（派单只点名 `p5_status`/`p5_pattern`/`p5d_multi`/`p5_wrapper`；⚠️ 它们**全部宏关**，对 `+799` 无判别力；`p5_wrapper` 我加跑了） |
| ⑧ | `unit_retx`/`unit_fifo` 的 `EXIT=0` | **假的**（bat 以 `type` 收尾）⇒ 已按 B 列读真判据（`ALL 7 GROUPS PASS` / `PASS_ALL`） |

---

## 7. 证据地图（全部在 `sim/p7b_stagec_tx_regress/`）+ 逐字命令

```bash
cd /d/repo/XCKU5PMini/udp_hls_10g

# ---- ① 16 门矩阵（两轮） ----
cmd //c 'sim\p4gates\run_matrix_p4dfix.bat'                     # 轮1: 15:34:18→15:59:35 (DRIFT/exit 2)
cmd //c 'sim\p4gates\run_matrix_p4dfix.bat'                     # 轮2: 冻结版
C:/Users/zhxue/anaconda3/python.exe sim/p7b_stagec_tx_regress/collect_matrix.py \
    sim/p4sim/matrix_p4dfix.log sim/p4gates/work_<stamp>        # 两列取数

# ---- ② 两种盲: 我自己的预处理器 + 全域 grep ----
C:/Users/zhxue/anaconda3/python.exe sim/p7b_stagec_tx_regress/my_preproc.py
grep -rn "TCP_TX_OVL" . | grep -v "^./sim/p7b_stagec_tx/"        # 见 §3.2

# ---- ③ 镜像树破坏实验 (M0..M3) ----
C:/Users/zhxue/anaconda3/python.exe sim/p7b_stagec_tx_regress/mk_mut.py
C:/Users/zhxue/anaconda3/python.exe sim/p7b_stagec_tx_regress/setup_arm.py M0 --build
cmd //c 'sim\p7b_stagec_tx_regress\run_arm.bat' > sim/p7b_stagec_tx_regress/arm_M0.log 2>&1
C:/Users/zhxue/anaconda3/python.exe sim/p7b_stagec_tx_regress/setup_arm.py M1
cmd //c 'sim\p7b_stagec_tx_regress\run_arm.bat' > sim/p7b_stagec_tx_regress/arm_M1.log 2>&1
C:/Users/zhxue/anaconda3/python.exe sim/p7b_stagec_tx_regress/setup_arm.py M2
cmd //c 'sim\p7b_stagec_tx_regress\run_arm.bat' > sim/p7b_stagec_tx_regress/arm_M2.log 2>&1
C:/Users/zhxue/anaconda3/python.exe sim/p7b_stagec_tx_regress/setup_arm.py M3
cmd //c 'sim\p7b_stagec_tx_regress\run_arm.bat' > sim/p7b_stagec_tx_regress/arm_M3.log 2>&1

# ---- ④ 追加门 (工作区臂 / HEAD 臂) ----
C:/Users/zhxue/anaconda3/python.exe sim/p7b_stagec_tx_regress/mk_extra.py      # 建 extra/ + extra_head/ + head_rtl/ + head_root/
cmd //c 'D:\...\sim\p7b_stagec_tx_regress\extra\p5_status\run.bat'  > extra_log_p5_status.txt  2>&1
cmd //c 'D:\...\sim\p7b_stagec_tx_regress\extra\p5_pattern\run.bat' > extra_log_p5_pattern.txt 2>&1
cmd //c 'sim\p7b_stagec_tx_regress\run_extra_head.bat'            # 两门 HEAD 臂
cmd //c 'D:\...\sim\p7b_stagec_tx_regress\extra\p5_wrapper\run.bat' > extra_log_p5_wrapper.txt 2>&1
cmd //c 'sim\p7b_stagec_tx_regress\run_p5d_cases.bat'             # neg_wq/neg_mgn/neg_mgn0/known_idle_fifo
cmd //c 'D:\...\sim\p7b_stagec_tx_regress\extra\p5d_multi\run.bat' main > extra_log_p5d_main.txt 2>&1
cmd //c 'sim\p7b_stagec_tx_regress\run_p5d_cases_head.bat'        # 四档 HEAD 臂
cmd //c 'D:\...\sim\p7b_stagec_tx_regress\extra_head\p5d_multi\run.bat' main > head_log_p5d_main.txt 2>&1
cmd //c 'D:\...\extra\p7b_chain\run.bat'    > extra_log_p7b_chain.txt    2>&1
cmd //c 'D:\...\extra\p7b_appsplit\run.bat' > extra_log_p7b_appsplit.txt 2>&1

# ---- ⑤ 作者门独立重跑 (副本; 第二遍 = TB 改到能编之后) ----
cmd //c 'D:\...\sim\p7b_stagec_tx_regress\author_gate\run_tx_ovl_gate.bat' > author_gate_stdout.txt  2>&1
rm -rf sim/p7b_stagec_tx_regress/author_gate/run[A-K]
cmd //c 'D:\...\sim\p7b_stagec_tx_regress\author_gate\run_tx_ovl_gate.bat' > author_gate_stdout2.txt 2>&1
```

| 文件 | 内容 |
|---|---|
| `matrix_stdout.txt` / `matrix_exit.txt` / `matrix_stdout2.txt` | 两轮矩阵 stdout（逐门 `GATE x EXIT=n` + `MATRIX_EXIT=n`） |
| `mirror/`（含 `mirror/sim/p4sim/matrix_p4dfix.log`） | 镜像树 + 它自己的矩阵日志/指纹（M0..M3 的 `VERDICT: FROZEN`） |
| `mut/mut_ovl.v` · `mut/mut_def.v` | 两个**单字节**变异件（+ `mk_mut.py` 的逐字节自证输出） |
| `arm_M{0,1,2,3}.log` | 四条臂的完整 stdout（含 `[P4GUARD OK] root=<mirror>` 的路径证据） |
| `head_rtl/` · `head_root/` | HEAD 版 rtl（两文件，sha256 核过）· p7b 门 HEAD 臂的最小根树 |
| `extra/` · `extra_head/` | 追加门的工作区臂 / HEAD 臂副本（含 `run*.bat`、`_log_*.txt`） |
| `frozen/` | **冻结版**源码快照（`tcp_tx_frame_rev1a1f0439.v` / `app_pattern_rev0e804099.v`） |
| `my_preproc.py` · `mk_mut.py` · `setup_arm.py` · `mk_extra.py` · `mk_extra_one.py` · `collect_matrix.py` | 可复算入口 |
| `author_gate/` · `author_gate_stdout.txt` · `author_gate_stdout2.txt` | 作者门的独立重跑（逐字副本 + 仅改相对深度）；第一遍 = TB 半成品（不可判），第二遍 = `TX_OVL_GATE: PASS` |
| `probe_tbx/probe_xvlog.log` | TB 可用性探针：`-d TCP_TX_OVL` 编 `tcp_tx_frame.v + tcb/fifo_sync/checksum16/retx_ram + tb_tcp_tx_ovl.v` ⇒ **RC=0 / 0 个 ERROR**（这是"第二遍重跑可行"的前置判据；⚠️ 该探针**只证明它能编**，不证明它跑对） |
| `r2_batch_stdout.txt` · `r2_log_*` | 冻结版（`1a1f0439…`）上的追加门第二批（`run_rev2_batch.bat`） |
| `run_arm.bat` · `run_p5d_cases{,_head}.bat` · `run_extra_head.bat` · `run_rev2_batch.bat` | 各批次的入口脚本（纯 ASCII + CRLF） |

---

## 8. 收尾核账（纪律）

| 项 | 结果 |
|---|---|
| 我改过的**既存源文件 / TB / bat** | **0 个**（所有副本都在 `sim/p7b_stagec_tx_regress/`；破坏实验只在**镜像树**上做，且 `mk_mut.py` 每次核对基线 sha256） |
| `rtl/app_pattern.v` | 全程 `0e804099400c2e2b800ef66bbf49d0d26892bb977e4523de208581ef0d81ce06` **未变** |
| `rtl/tcp_tx_frame.v` | 开工 `10e75f21…` → 收尾 **`1a1f0439…`**；**三次变化全部来自另一支 agent**（时间戳 16:00:32，我再无写入） |
| 冻结件 | `frozen/tcp_tx_frame_rev1a1f0439.v` 与**冻结时的**工作区**逐字相同**（sha256 核过） |
| `git status --short` | tracked 改动 = `M rtl/app_pattern.v` + `M rtl/tcp_tx_frame.v`（被测件，非我） + `M sim/p4sim/matrix_p4dfix.log`（runner 自己的输出路径，与实际无关） |
| ⛔ 板子 | **全程未碰**：零烧录、零 `0x08` 写入、零板级读数 |

---

## 9. 一句话交给 TL

**在作者报告描述的那一版（`tcp_tx_frame.v` = `10e75f21…`）上，16 门矩阵 16/16 EXIT=0、追加门 10 次执行全部与基线逐数/逐字相同、
零新红，且我在冻结的下一版（`1a1f0439…`）上复跑矩阵（16/16 `FROZEN`）与追加门（8/8 判据行相同）也全部一致，
作者门独立重跑 = `TX_OVL_GATE: PASS`（A=0 / B=0 / C..K 全红）** ——
但「矩阵全绿」对这把刀**结构性地没有判别力**：`+799` 全在 `ifdef TCP_TX_OVL` 内，而**全仓（作者 scratch 之外）
没有任何一条门或构建定义该宏**（镜像树单字节破坏实验 M0/M1/M2/M3 把这件事做成了可复算证据，且 M3 证明门本身有牙）；
`app_pattern.v` 更是**两种盲同时成立**（不在任何清单里 + 宏关）。
⛔ **且测量窗口内有另一支 agent 在改被测源码**（`rtl/tcp_tx_frame.v` 三个 sha256、`tb/tb_tcp_tx_ovl.v` 被改到一度编不过 ⇒
第一轮矩阵被 runner 判 `REVISION DRIFT`/exit 2、作者门第一次重跑的 B 臂 RC=1 **不可判**）；
其中**新版把 `ring_start` 的回绕安全修复打进了默认分支**（宏关 `+8/−1`，对应审查件 F1 阻断项的修法①）⇒
**「宏关逐字回到 HEAD」这条免测金牌在新版上已经失效**，后续每一次改动都必须由**绑定单一 revision** 的矩阵/门重新收口。
