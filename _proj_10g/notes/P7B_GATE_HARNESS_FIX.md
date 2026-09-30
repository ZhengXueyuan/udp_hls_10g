# P7b 门修复：真回归收口 + 3 条哑门/坏脚本（2026-09-30）

> 对应 `_proj_10g/notes/P7B_REGRESSION.md` §3.1（★真回归 2 条）+ §5（哑门清单里的 3 条）。
> 施工纪律：**不烧板 / 不跑 Vivado 综合·实现 / 不改 RTL·XDC / 不改 TB / 不 `git add`·`commit`**。
> 原始日志：`_proj_10g/notes/p7b_gate_fix/logs/*.txt`（12 份，逐次运行一份，互不覆盖；
> 含 4 条反例）。`p4indm_4gates` 委托出去的那轮矩阵运行留了成套指纹：
> `sim/p4sim/P4_MATRIX_FINGERPRINT_20260930_140217_{before,after}.txt`（无 DRIFT ⇒ 结果绑定单一修订）。
> 补丁脚本（可复核、逐处断言 + CRLF 断言）：`_proj_10g/notes/p7b_gate_fix/patch_gates.py`。
> 扫描脚本：`_proj_10g/notes/p7b_gate_fix/scan_pct_comment_bats.py`（只读）。

## 0. 一句话

**真回归已收口（两条门由红转绿，判据与基线逐字相同）；3 条哑门/坏脚本里 3 条都修了并能自证；
反例均真跑（4 条，含 2 向对照，全按期望翻转）；另有 2 条越出本任务文件所有权的账
（回归门表仍指向 `.sh` / 两条门脚本在 `.gitignore` 里），见 §4。**

---

## 1. ★ 真回归 `p4_rxclass` / `p4_rxclass_xk` —— **已收口**

| 项 | 修前（= 回归报告读数） | 修后（本次实测） |
|---|---|---|
| `sim\p4sim\run_tb_rxclass.bat` | EXIT=1 · `ERROR: [VRFC 10-2063] Module <fifo_sync> not found ... [rtl/rx_classify.v:88]` | **EXIT=0** · `nostall: PASS (161 lines)` / `stall: PASS (161 lines)` / `hard: PASS (161 lines)` / `tb_rx_classify: PASS` |
| `sim\p4sim\run_tb_rxclass_xk.bat` | EXIT=1（同因，日志逐字同） | **EXIT=0** · 同上三模式各 161 行 + `tb_rx_classify: PASS` |
| 改动 | — | 两条门的 `xvlog` 行各加 **1 个文件** `..\..\rtl\fifo_sync.v` |

原始日志：`logs/p4_rxclass_after.txt`、`logs/p4_rxclass_xk_after.txt`。

**清单依据（任务要求"别自己猜"，这里如实交代）**：P4 矩阵（`sim/p4gates/run_matrix_p4dfix.bat` 的 16 门 +
`chain_src.f`）**不含 rxclass 门** —— 它覆盖的是 `tb_p4_chain` 全链，所以矩阵清单**不能**当这次的原型。
本仓**同一 TB/同一 DUT** 的另外两条现役门才是原型，二者都列了 `rtl/fifo_sync.v`：
① `_proj_10g/p7b_rxcls/sim/run_legacy_tb_rxclass.bat:30`（v2 源码 + 原 TB 交叉核对门）；
② `_proj_10g/p7b_rxcls/sim/run_tb_rxcls_v2.bat:32`（v2 单元门）。
⇒ 补的正是这两个文件清单里有的、而两条门缺的那一个。**未改 RTL** —— 设计本身无缺陷。

---

## 2. 哑门 / 坏脚本改动清单

| 门 | 修前（回归报告） | 本轮核实 | 改动 | 修后实测 |
|---|---|---|---|---|
| **`p4_replay`** | "bat 里 `CACK` 笔误 ⇒ 空门，什么都没跑" | ⚠️ **订正**：`CACK` 是真现象但**机理与结论都不对**（见 §2.1）；门其实跑了 117 s 并跑到 TB 末尾 | ① 修 `%`-注释行；② 加 **DONE 完成判据**；③ 显式 `exit /b 0` | **EXIT=0** · `DONE rx(pass=407 nm=0 ack=203) tx(fr=406 ack=203) eco(echo=203) slow(cmt=5 drp=0 tx=5 pg=0)` · 输出里**不再有** `'CACK' ...` |
| **`p5c_rev_elab`** | 哑门（末行 `echo DONE` ⇒ 恒 exit 0），**掩盖了一个既存 elab 硬失败** | ✅ **是"门的清单缺件"，不是"模块不存在"**：`rtl/udp_tx_cfg.v:62` / `rtl/udp_tx_frame.v:26` 都在、模块名都在 ⇒ 只改门，**未动 RTL** | ① `RTLF` 补 `%RTL%\udp_tx_cfg.v %RTL%\udp_tx_frame.v`；② 加 **ERROR 硬失败判据** | **EXIT=0** · `[ELAB-CHK PASS] both configs elaborated with 0 ERROR lines`（[A] 默认构建 + [B] `-d APP_MODE` 两配置都过） |
| **`p4indm_4gates`** | `run_4gates.sh` 里 `%REPO_ROOT%`（cmd 语法串进 bash）⇒ 结果永远写不出去 | ✅ 成立：bash 下 `%VAR%` 永不展开 ⇒ `cd` 失败、**一门没跑**、末行 `echo` 仍 exit 0 | ① 新建 `sim/p4indm/run_4gates.bat`：**委托** P4 矩阵 runner `-only pcackoob+vlanchain+vlanburst+stallgate`（这 4 门本来就是 16 门里的 4 门 ⇒ 不再维护第二份清单）；② `run_4gates.sh` 改**薄 shim**（自定位 → `cmd //c` 调 .bat）—— 与 `sim/p4sim/run_matrix_p4dfix.sh` 同一架构 | **EXIT=0** · `GATE pcackoob EXIT=0` / `vlanchain EXIT=0` / `vlanburst EXIT=0` / `stallgate EXIT=0` · `gates run : 4 / 16` · `gates failed: 0`（且 4 门各自过了 `checkpaths` + `manifestcheck` 守卫） |

`unit_retx` / `unit_fifo` / `d2_suite` / `f4_sttrace` / `p7b_impl_*`：**按任务要求未改**，
回归报告 §5 的结论（无条件 `exit 0`，其中 `unit_retx`/`unit_fifo` 的日志尾真实判定是 PASS）
**经本轮复核无变化**，不改动。

### 2.1 `p4_replay` 的 `CACK` 到底是什么（机理已用 echo-on 二分实测钉死）

不是"笔误"，而是 **cmd 把一行 REM 当活命令执行了**：

```
REM   %1 = NOPCACK (缺省 +PCACK); %2 = 运行日志名 (默认 xsim_run.log)
```
实测（`@echo on` 二分，同目录 scratch 副本，已删）：
`>CACK (缺省 +PCACK);  = 运行日志名 (默认 xsim_run.log)` → `'CACK' 不是内部或外部命令…`
成因 = **同一行里既有 `%` 又有非 ASCII 字节**（`%1`/`%2` 是空参 ⇒ 展开后这行被重新切分，
GBK 控制台下把 `REM   %1 = NOP` 吞掉、从 `CACK` 起当成命令名）。三方对照（真跑，全在 scratch）：

| 用例 | 该行内容 | 结果 |
|---|---|---|
| t1 | `REM %1 = NOPCACK (缺省 +PCACK); %2 = 运行日志名 …`（中文 + `%`） | ❌ 执行 `CACK` |
| t2 | `REM %1 = NOPCACK; %2 = runlog`（纯 ASCII + `%`） | ✅ 正常当注释 |
| t3 | `REM arg1 = NOPCACK (xx +PCACK); arg2 = runlog`（无 `%`） | ✅ 正常当注释 |

修法 = 该行改纯 ASCII、去掉 `%`。**全仓扫描**（`scan_pct_comment_bats.py`，609 份 .bat/.cmd）：
同类"`%` + 非 ASCII"的 REM 行**只剩 3 处，且全在归档/历史私有副本里**
（`sim/p4gates/evidence/negctl/foreign/...`、`sim/p5b_ind/p4/…`、`sim/p5e_win/p4prv/…`），
**现役门 0 处**（回归已把私有副本按同 TB 去重，它们不是门）。归到用户全局经验里的
"**bat 注释禁 UTF-8 中文**"一族，本轮补上了**精确触发条件**（`%` ∧ 非 ASCII）。

**新增判据**（此前 xsim 的退出码分不出"跑到底"和"根本没跑/中途死"）：
`findstr /C:"DONE rx" %RUNLOG%`（TB 末行 `DONE rx(pass=…)`，全日志唯一）。

---

## 3. 反例实测（**真跑**，不是"按构造应当失败"）

| # | 反例 | 做法 | 实测 |
|---|---|---|---|
| A | rx_classify 门**缺 `fifo_sync.v`** | 用 `git show HEAD:sim/p4sim/run_tb_rxclass.bat`（= 修前逐字版本）跑 | **EXIT=1** · `ERROR: [VRFC 10-2063] Module <fifo_sync> not found while processing module instance <u_wf> [rtl/rx_classify.v:88]` → `[XSIM 43-3322] Static elaboration … failed`（`logs/negctl_rxclass_nofifo.txt`） |
| B | elab 门**把 2 个 RTL 文件从 RTLF 删掉** | 现版本删 `%RTL%\udp_tx_cfg.v %RTL%\udp_tx_frame.v` 后跑 | **EXIT=1** · `[ELAB-CHK FAIL] xelab reported ERROR in one of the two configs:` + 2×`VRFC 10-2063 Module <udp_tx_cfg>/<udp_tx_frame> not found`（`logs/negctl_elab_nocfg.txt`）——**修前的同一状态是 exit 0** |
| C | `p4_replay` 的 DONE 判据 | 把**逐字同一行** `findstr` 分别喂"截断日志"与"真日志" | 截断 ⇒ **EXIT=1** + `[P4_REPLAY FAIL] TB never reached its final DONE line:`；真日志 ⇒ **EXIT=0** + `[NEGCTL OK]`（`logs/negctl_replay_trunc.txt` / `negctl_replay_full.txt`） |
| D | `p4indm_4gates` 的**拒绝传播** | .bat 的门名表里塞一个 runner 未声明的门 ⇒ 跑 .bat 与跑 .sh 各一次 | 两条入口都 **EXIT=97** + `refusing: a filter matching nothing would run 0 gates and still exit 0`（`logs/negctl_p4indm_boggate.txt`）。对照：**老 .sh 这一侧没有任何可传播的东西** —— 它连路径都解析不出来（bash 不展开 `%VAR%`），且 harness 用 `cmd /c <*.sh>` 根本起不动它（实测 0.1 s / 空日志 / **EXIT=0**） |

反例 A/B/C 的 scratch 文件（`_negctl_*.bat`）跑完即删；重建方法写在上面（A 一条 git 命令，B = A 的镜像操作）。
A/B/D 的注入都是**临时改门脚本后跑、跑完还原**（D 已 `md5` 核对还原）。

---

## 4. 没修动的 / 残留 / 需要别的所有权去动的

1. ⚠️ **回归 harness 的门表指向的是 `.sh`**：`_proj_10g/notes/p7b_regression/run_all_gates.py:158`
   的 `p4indm_4gates` 条目 bat = `sim\p4indm\run_4gates.sh`，而 runner 用 `cmd /c <bat>` 起门
   —— **cmd 跑不动 .sh**（这也是它 0.1 s / 空日志 / exit 0 的另一半原因）。
   ⇒ **建议把该条目的路径改成 `sim\p4indm\run_4gates.bat`**（一行改动）。
   该文件不在本任务的文件所有权内（`_proj_10g/notes/p7b_regression/**`），**我没有改**。
2. ⚠️ **两条修好的门脚本在 `.gitignore` 里**（`sim/p4indm/**`、`sim/p5c_t3/**` 整树被忽略）：
   本轮的修复只存在于**工作区**，`git add` 常规做法不会带走它们（`git check-ignore` 已核）。
   要落库需 `git add -f` 或调整 ignore —— **由用户/后续所有权决定，我没有 add**。
   （三条 tracked 门脚本的改动正常可见：`git diff --stat` = 8 增 3 删 / 3 文件。）
3. **订正 `P7B_REGRESSION.md` §5 对 `p4_replay` 的描述**："bat 里 `CACK` 笔误 ⇒ 空门，什么都没跑" ——
   `CACK` 现象属实，但门**跑了 117 s 并打印了 TB 末行**（`logs/p4_replay_before.txt` 只有那一行 stderr，
   因为其它输出都重定向进了日志）。它真正的病是**没有判据**（末行 = xsim 的退出码），不是"没跑"。
4. **残留（未修）**：3 处同类 `%`+非 ASCII 的 REM 行，全在归档/私有副本，不是门（见 §2.1）。
5. **观察（既有，非本次引入）**：`p4_replay` 的 sim 日志里有 **31 条 `Memory Collision Error on RAMB36E1
   … tb_p4_chain.u_slow_rx.u_ff…`**（TB 竞争，工程坑 17 家族）；本次 exit 仍为 0，
   但同族现象在回归报告 §4.1（`p5e_udp_portout`）里**曾导致过非零退出** ⇒ 这条门有**间歇性假红**的可能。
6. **另**：`udp_tx_cfg` 缺件的**同类扫描不做数**（repo 里大量门用 `-f files.f`/glob 传清单，grep 结构性看不到）；
   经验上的权威判据是 136 门回归本身 —— 它只抓到 `p5c_rev_elab` 这一处。

---

## 5. 复跑方式

```bash
# ① 真回归（两条都跑，各约 40 s；同一目录，串行）
cmd //c 'sim\p4sim\run_tb_rxclass.bat'      # 末行期望: tb_rx_classify: PASS / EXIT=0
cmd //c 'sim\p4sim\run_tb_rxclass_xk.bat'   # 同上

# ② 哑门（各 15 s / 2 min / 8 min）
cmd //c 'sim\p5c_t3\rev\run_wrapper_elab_chk.bat'   # [ELAB-CHK PASS] / EXIT=0
cmd //c 'sim\p4sim\run_tb_p4_replay.bat'            # DONE rx(pass=…) / EXIT=0
cmd //c 'sim\p4indm\run_4gates.bat'                 # gates run 4/16 · failed 0 / EXIT=0
bash sim/p4indm/run_4gates.sh                       # 同一门的 git-bash 入口（薄 shim）
```

**一句话结论**：`p4_rxclass` / `p4_rxclass_xk` 已由红转绿（EXIT=0，三模式 161 行 PASS 与基线一致）；
`p5c_rev_elab` 的"masked elab 硬失败"是门的清单缺件（**RTL 清白**），补件 + 加 ERROR 判据后两配置皆 0 ERROR；
`p4_replay` 的 `CACK` 是 cmd 重解析 `%`+非 ASCII 注释行（非笔误，也不影响运行），真正的缺口是**没有判据**，
已补 TB 末行 DONE 判据；`p4indm_4gates` 从"cmd 语法串进 bash 的空门"改成**委托 P4 矩阵**的真门。
反例 4 条全部真跑并按期望翻转。
