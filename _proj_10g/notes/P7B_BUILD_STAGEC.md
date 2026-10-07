# P7B_BUILD_STAGEC —— Build 3（Stage C：TCP app TX 8 路 + `tcp_tx_frame` 乒乓，含 F1 洪水修复）构建读数

- 日期：**2026-10-07**　角色：**构建 agent**
- 工作区：HEAD = **`46b2f68`** + 未提交改动。被跟踪改动 = 开工时 **2 个 RTL**（`M rtl/tcp_tx_frame.v` / `M rtl/app_pattern.v`）
  + 本轮我改的 **3 个 board/** 文件。`git diff --stat`：`tcp_tx_frame.v +823/−1`、`app_pattern.v +72/−0`。
- 纪律执行：**未烧板 / 未写 `0x08` / 未改 `rtl/` 任何逻辑 / 未提交 git / 未 `git add -A`**。
  本轮同机**只有本构建一个重负载**（构建窗口内 `tasklist` 只见一个 `vivado.exe`；无 xsim）。

---

## 0. 一句话

Build 3 **建成**：三条硬门的**两栏命中数与基线逐数相同**（§4）、**三类失败端点 0/0/0**（§5）；
**WNS `+0.070`**（基线 `+0.006`，**反而好了 0.064**）—— 与派单预告的"WNS 变负很有可能"相反。
但 **DP 域前 10 换族**：新锥 `u_tcp_tx/retx_active_reg/C -> u_tcp_tx/ctrl_tcpcsum_reg[*]/D`
（**22 级 / logic 2.611 ns**）**整体占满 DP 前 10（10/10）**，老族
`u_app_udp/u_txf/dout_reg[*] -> u_udp_tx/ip_csum_r_reg[*]` 一条都没进（§5.2）。
位流 sha256 **`1609d6f55e8a119b2f88c1a57cd4776e2219f56d3d1e84f840b198555e576f3c`**（15,431,261 B）—— **未烧板**。

---

## 1. 开工前归档（第①件：全局经验 #54）

`board/build_p7b_ku5p.tcl` 用 `create_project -force` ⇒ `impl_1/` 与 `synth_1/` 在每次构建的**第一秒**被抹掉。
本轮做了**两件**：手工抢救一次（保证本轮有据）+ **把归档写进构建脚本**（保证以后不靠人记）。

### 1.1 手工归档（验证脚本能拿到的完整件）

目录 `_proj_10g/notes/p7b_build_stageC/baseline_archive/`（18 个文件 + `SHA256SUMS.txt`，sha256 为**归档副本**自己的）：

| 文件 | 字节 | sha256 |
|---|---|---|
| `wrapper_p4_timing_summary_routed.rpt`（含 `-max_paths 10`） | 8,521,384 | `9b6ecbf21c33bfdffa1d216eba7d56f7d8b27680ac000e72c1c10fdbb483f5c7` |
| `wrapper_p4_utilization_placed.rpt` | 14,004 | `dc0e21f02b30b7d90f2e4f26357cba750cf745de4ed1b5e8c8cd819ec412ba4d` |
| `wrapper_p4_routed_Build2.dcp` | 59,189,566 | `aa73857ac506afef7f2d534e82aea204634a29bf40d2c95644b455b34d234f2d` |
| `wrapper_p4_synth_Build2.dcp`（post-synth） | 65,433,302 | `6f348e5d4319e99eeaea8400f9b7fab2c0e7e077e96c4c6f1caaabc7328a21c0` |
| `wrapper_p4_control_sets_placed.rpt` | 3,873,861 | `1ee23dbe49d8d555cbd6bc7984611d40f5aaf04f84fb8ba382929f7ebc69ac1f` |
| `wrapper_p4_clock_utilization_routed.rpt` | 175,048 | `e1a4641f5f45e7afa36f745e8a6c82d8bb69fc47d0347cec33300a9ef9d0759c` |
| `wrapper_p4_drc_routed.rpt` | 66,346 | `caad1dfeb8f06de1d28a6bf6e921bfd37a2726174ab583f1600806554cdd50e3` |
| `wrapper_p4_power_routed.rpt` | 47,998 | `a523d3a4ef995ad4161fe9e678ab5bf29567b947da6d00cf7880e70dcb20cdbb` |
| `wrapper_p4_route_status.rpt` | 651 | `b52de7c33e0e920291603930b78f6e3d6753e02a9f4964d9a0b1937d66b14fed` |
| `wrapper_p4_utilization_synth.rpt`（post-synth） | 10,533 | `79273e3cd74fd23c78c86e6b31abb40f4af5b66ca3a4b608d38060d841933ef9` |
| `wrapper_p4_Build2.bit`（**板上现役**） | 15,431,261 | `1ccbd9cd84292d1a10973a1442f71ca2187e66834be5e09d7eeb22b42c6cdd07` |
| `runme_impl_1.log` / `runme_synth_1.log` | 66,949 / 426,701 | `bb96e8b67e…` / `2a48b77f8c…` |
| `p7b_ku5p_timing.rpt` / `_util` / `_drc` / `_clkinteract` | 589,820 / 13,982 / 66,312 / 51,022 | `f6357c830a…` / `5b52f11a72…` / `d0f5b25b7a…` / `142be0cd97…` |
| `p7b_ku5p_stdout.txt` | 521,986 | `b2ffbee0e9…` |

**归档保真自证**：`wrapper_p4_Build2.bit` 的 sha256 `1ccbd9cd…6cdd07` 与派单基线表**逐字相同**。

### 1.2 归档写进构建脚本（#54 要求的那件事）

`board/run_build_p7b_ku5p.bat` 新增 **pre-build archive 块**（+52 行，纯 ASCII + CRLF，插在 `set VV=` 之后、
`call vivado` 之前）。行为：

- 每次调用**无条件**执行；前一轮位流不在 ⇒ 打 `ARCHIVE_SKIP` 并继续（归档是尽力而为，**不阻断构建**）。
- 落点 `_proj_10g\notes\p7b_build_archive\<yyyyMMdd_HHmmss>\`，19 个文件（含两个 dcp 与位流）+ `SHA256SUMS.txt`
  （PowerShell `Get-FileHash`），末行 `ARCHIVE_DONE <stamp> files=<n> dir=<path>`。
- **本轮实测生效**：`ARCHIVE_DONE 20261007_163651 files=19 dir=D:\repo\XCKU5PMini\udp_hls_10g\board\..\_proj_10g\notes\p7b_build_archive\20261007_163651`
  （`_proj_10g/notes/p7b_build_stageC/bat_stdout.txt:2-3`）；该自动副本的 `wrapper_p4.bit` sha256 =
  `1ccbd9cd…6cdd07`，与 §1.1 手工副本**逐字相同**。
- 落盘成本：**约 150 MB / 次构建**。`_proj_10g/notes/p7b_build_archive/` **未被 `.gitignore` 覆盖** ⇒ 会以未跟踪文件出现在
  `git status`（同本轮 `p7b_build_stageC/`）。**是否给该目录加 ignore = 未做，留给 TL 决定**（`_proj_10g/p7b_mac_synth/baseline/`
  有先例：大快照 ignore、只放行 `.rpt`）。
- **落地前先做了隔离试跑**：16:36:43 我先用一份"只含归档块"的临时 bat 单独跑通（`ARCHIVE_DONE ... files=19` + 位流
  sha256 与手工副本逐字相同），确认块本身没错再挂进正式构建。**该试跑产生的重复归档 `20261007_163643/` 已删除**
  （留两个内容相同的基线快照会污染归属）⇒ 现役只有 `20261007_163651/` 一个。

### 1.3 ⚠️ 归档**没能**覆盖的一格（如实登记）

`wrapper_p4_control_sets_placed.rpt` 我按"可能对 FF 归因有用"抄了，但实测它**不含**
`ctrl_tcpcsum` / `retx_active` / `tx_bank` 任何网名（Build 2 与 Build 3 两边 `grep -c` 都是 **0**）⇒ 该件对本轮的
"新锥归属"**无判别力**。本轮的新锥归属改用**源码面**证据（§5.3），没有依赖它。

---

## 2. 加宏与 BID 的逐处改动（第②件）

### 2.1 我改的 3 个文件（`git diff --stat` 逐数）

| 文件 | 改动 | 摘要 |
|---|---|---|
| `board/build_p7b_ku5p.tcl` | **+10 / −1** | 第 145 行 `verilog_define` 末尾追加 **`TCP_TX_OVL=1`**；并把"这是本刀唯一开关 / 宏关 != HEAD"写成注释块 |
| `board/wrapper_p4.v` | **+9 / −1** | `BUILD_ID_V` `32'h00000009` -> **`32'h0000000A`**（第 3882 行）；同时补 1 段注释登记 `10 = P7b Stage C` |
| `board/run_build_p7b_ku5p.bat` | **+52 / −0** | §1.2 的 pre-build archive 块（纯 ASCII + CRLF） |

**没有改 `rtl/` 的任何一行**（`git status` 的 `M rtl/*` 两项是开工前就有的，且开工/收工的 sha256 逐字未变，见 §8）。

### 2.2 宏到位的日志自证

```
P7B_VERILOG_DEFINE = APP_MODE=1 DEV_USP=1 PCIE_OBS=1 DP_156MHZ=1 P7B_10G=1 UDP_TX_OVL=1 TCP_TX_OVL=1
```
出处：`board/p7b_ku5p_stdout.txt:269`（构建自己的 `puts`）。宏**不只是写进了脚本** —— 综合确实吃了它（§5.3 的
cell 名 `ctrl_tcpcsum_reg` 在 Build 2 的网表里根本不存在）。

### 2.3 ⚠️ "宏关 != HEAD"（必须写进提交说明的一条）

`rtl/tcp_tx_frame.v` 的 F1 修复（`retx_ovf` + `ring_start` 追加 `!retx_ovf`，**8 行**）落在**默认分支**里
⇒ 把 `TCP_TX_OVL` 关掉得到的是 **"纯基线 + 那 8 行 F1 修复"**，**不是** HEAD 的逐字行为。
证据（不是我推的，是回归 agent 逐行算的）：`_proj_10g/notes/P7B_STAGEC_TX_REGRESSION.md` §环境事实 2 / §0-⑤
（`P1b` 与纯基线的 diff **恰为那 8 行**）。**建议提交说明里点名这条**：`TCP_TX_OVL` 是"乒乓 vs 串行"的开关，
**不是**"本刀 vs HEAD"的开关。

### 2.4 全域 grep 引用清册（"改一处、N 处悬空"的高危面）

`git grep` 面 = 全仓**已跟踪**的 `*.sh *.py *.bat *.v *.tcl`。按"**改了 BID 之后谁还会读到 9**"分四类：

**(A) 真源（已改）**

| 文件:行 | 值 | 说明 |
|---|---|---|
| `board/wrapper_p4.v:3882` | 9 -> **0xA** | `axi_regs` 的 `BUILD_ID_V`。板侧身份门的唯一真源 |

**(B) 板级取数/验收台架（`_proj_pcie/`，**下一轮真正会跑的**）—— 默认值仍是 9，我**没有**改**

| 文件:行 | 现状 | 改 BID 后的行为 |
|---|---|---|
| `_proj_pcie/p7b_biz/p7b_snap.sh:40` | `EXPECT_BID=${EXPECT_BID:-0x00000009}` | 默认档**响亮失败** `ID_FAIL 身份不符 (烧了别的位流? 期望 BID=..., 实测 BID=...)`，并打印覆盖配方 |
| `_proj_pcie/p6e_snap_check.sh:46` | 同上 | 判据 `1.2 BUILD_ID (0x04)` FAIL |
| `_proj_pcie/p7b_gate4_accept.sh:115` | 同上 | 判据 `G1 位流身份` FAIL |
| `_proj_pcie/p7b_gate4_selftest.sh:95` | 假板 `FAKE_BID:-0x00000009` | **与上一行强耦合**（源码注释逐字："假板子的 BID 必须与 `p6e_snap_check.sh` 的 `EXPECT_BID` 同代"） |
| `_proj_pcie/p7b_gate4_livefake.sh:100` | `{63:"0x00000009", 61:..., 51:...}` | 同上 |
| `_proj_pcie/p7b_gate4_negctrl.sh:53` | 合成 `BID 0x00000009` | 同上 |
| `_proj_pcie/p6e_snap_selftest_fix2.sh:71` | 假板 `0X04) V=0x00000009` | 同上 |

**(C) 与 (B) 绑死的"判据/守卫"—— 改一处不改另一处会**静默拒绝**或**假红** *

| 文件:行 | 现状 | 耦合 |
|---|---|---|
| `_proj_10g/notes/p7b_gate4_criteria/gen_inputs.py:35` | `BID_FIX = 0x00000009` | **它有一个 `_geo_guard()` 主动读 `p7b_gate4_accept.sh` 的默认 `EXPECT_BID`**；两者不同代 ⇒ **`GEOM_GUARD_FAIL` + `exit 3` 拒绝生成**（`.../gen_inputs.py:53-60`）。⚠️ 这就是"只同步一半 = 结构性拒绝"的现成例子 |
| `_proj_10g/notes/p7b_wu_p1p2_tools/mk_accept_offline.py:54` | 合成 `BID 0x00000009` | 与 (B) 的 accept 同代 |

**(D) 静态门（**会因本次 BID bump 由 PASS 变 FAIL**）—— 未改**

| 文件:行 | 断言 | 后果 |
|---|---|---|
| `sim/p5wu_p1p2/check_wu_words.py:57` | `ck(... int(m.group(1),16) == 9, "2 BUILD_ID_V == 9")` —— 直接 `re` **读 `board/wrapper_p4.v`** | 判据 2 变 FAIL（判据 1/3..14 不受影响） |
| `sim/p5wu_p1p2_review/rev_window_check.py:170` | `A7 BUILD_ID_V == 9` | 同上（**另一支 agent 的独立复核件**） |
| `sim/p5wu_p1p2_review/rev_check_wu_words_copy.py:57` | 同上 | 同上 |

⚠️ **这三条不在 P4 16 门矩阵里**（`sim/p4gates/run_matrix_p4dfix.bat:163-178` 的 16 行逐条核过，无一条读 BID）
⇒ **常规回归不受影响**；但**单独复跑这三条会红**。它们钉的是"WU 轮那一代的 63 字 / BID 9"，
按本工程"期间门钉代"的惯例**属于陈旧引用、不是回归**。

**(E) 期间件 / 冻结夹具（**不应改**）**

- 各轮台架副本：`_proj_10g/notes/p7b_board_stagea/j6_stagea.sh:63` · `.../p7b_wu_w54/j6_fix.sh:44` ·
  `.../p7b_biz_tcpreg/tcpreg_j6.sh:49` · `.../p7b_gate4_3/final_state.sh:18` —— 都是**那一轮跑过的**台架快照。
- 冻结负对照/变异件（BID 7）：`_proj_10g/notes/p7b_chain_cov/mut_*/wrapper_p4.v` ·
  `.../p7b_biz_win/neg/wrapper_p4_{patho,declpatho}.v`。
- `_proj_pcie/rtl/pcie_min_top.v:141` —— **另一套工程**（`_proj_pcie` 自己的 mini top）的 `BUILD_ID_V=32'h1`，与本 RTL 无关。
- sim 镜像/TB（`tb/tb_snap63.v:53` · `sim/**`）—— 自持常量，不读真源。

### 2.5 我为什么**没有**同步 (B)(C)(D)（这一格请 TL 裁定）

派单的「②」要求"同步所有读取它的脚本/判据"，而纪律「⛔」写的是"**只许**改 `BUILD_ID_V` 那一处常量与构建脚本；
其它一律报告"。我按**后者的字面**执行，理由是：

1. **不做半同步**：`gen_inputs.py` 有一个**活守卫**会在"accept 默认值 != 自己的 `BID_FIX`"时**拒绝运行**（§2.4-C）。
   只改一部分 ⇒ 从"响亮失败"变成"结构性拒绝"，比不改更糟。
2. **全同步要动 10+ 个文件**，其中含**另一支 agent 的独立复核件**（`sim/p5wu_p1p2_review/*`）与**冻结负对照夹具** ——
   改它们等于重写历史证据的默认值。
3. **不改的失效是响亮的**：`p7b_snap.sh` 会打 `ID_FAIL ... 期望 BID=X, 实测 BID=Y`，且其文件头第 3-5 行与
   `:42-43` **逐字写着覆盖配方**。不是静默。

**如果 TL 要全同步**，最小完整清单 = §2.4 的 **(B) 7 处 + (C) 2 处 + (D) 3 处**（(E) 不动），
且 `gen_inputs.py` 的 `BID_FIX` 必须与 `p7b_gate4_accept.sh` 的默认**同批**改。**下一轮板级开工的覆盖配方**：

```bash
EXPECT_BID=0x0000000A bash _proj_pcie/p7b_biz/p7b_snap.sh ...        # 现役 63 字 / BID 10
EXPECT_BID=0x00000009 ...                                            # 读 Build 2（板上现役那版）
EXPECT_BID=0x00000009 bash sim/p5wu_p1p2/check_wu_words.py           # 该门不接受覆盖时按 (D) 判"陈旧引用"
```

---

## 3. 逐字命令 / 时刻 / 耗时 / 配置自证

```
cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\board\run_build_p7b_ku5p.bat'
```

| 项 | 值 | 来源 |
|---|---|---|
| START / END | `2026-10-07 16:36:51 +0800` -> `17:05:34 +0800` | `p7b_build_stageC/bat_stdout.txt` 首尾行 |
| **耗时** | **28 min 43 s**（派单预告 23-27 min） | 同上 |
| 宏 | `APP_MODE=1 DEV_USP=1 PCIE_OBS=1 DP_156MHZ=1 P7B_10G=1 UDP_TX_OVL=1 TCP_TX_OVL=1` | `board/p7b_ku5p_stdout.txt:269` |
| IP 收敛 | `P7B_CONVERGED_AT_ROUND = 2`（与基线逐字相同） | stdout `:75` |
| IP 读数 | `P7B_IS_LOCKED_POSTGEN = 0` | stdout `:186` |
| 综合 | `P7B_SYNTH_STATUS = synth_design Complete!` | stdout `:3255` |
| 实现 | `P7B_IMPL_STATUS = write_bitstream Complete!` | stdout `:4349` |
| 路由 | `INFO: [Route 35-16] Router Completed Successfully` | `impl_1/runme.log:976` |
| 完成判据 | `P7B_BIT_EXISTS = 1` · `P7B DONE` · `BITSTREAM-OK` · `BUILD_EXIT=0` | stdout + bat tee |
| `place`/`phys_opt` | `place_design completed successfully`（8 min 46 s）· `phys_opt_design completed successfully` | `impl_1/runme.log:637,672` |

**并发声明（全局 #50 防假红）**：16:36:51-17:05:34 全程 `tasklist` 只见**一个** `vivado.exe`（= 本构建）；
同窗口无 `xsim*`。本轮我是**唯一重负载**（回归/审查 agent 已在派单时停）。

---

## 4. 两栏门（`bash _proj_10g/notes/p7b_biz_build/gatecheck.sh /d/repo/XCKU5PMini/udp_hls_10g`）

⚠️ 该脚本自己也 `exit 0` —— 以下判定 = **我读它的输出**（留档 `p7b_build_stageC/gatecheck_out.txt`）。
栏 A = 主 stdout；栏 B = `{synth_1,impl_1,pcs64_synth_1,xdma_0_synth_1}/runme.log` 合计。
基线 = **Build 2**（`_proj_10g/notes/p7b_build_stageB/gatecheck_out.txt`）+ **WU**（`p7b_wu_build/gatecheck_out.txt`）。

| 硬门键 | 栏A | 栏B | 基线（Build2 / WU） | 判定 |
|---|---|---|---|---|
| `12-4739`（约束被静默丢弃） | 0 | 0 | 0/0 · 0/0 | 逐数相同 |
| `Synth 8-11241` | 0 | **33** | 0/**33** · 0/**33** | **逐数相同** |
| `undeclared symbol` | 0 | **33** | 0/**33** · 0/**33** | **逐数相同** |
| `VRFC 10-3091] actual bit length 1 differs...` | 0 | 0 | 0/0 | 过 |
| `VRFC 10-2989` | 0 | 0 | 0/0 | 过 |
| `implicitly declared` | 0 | 0 | 0/0（2025.2 下哑键） | 过 |
| `NSTD-1` / `UCIO-1` / `AVAL-326` | 0/0/0 | 0/0/0 | 0/0/0 | 过 |
| `Opt 31-155` / `Opt 31-67` / `Route 35-7` | 0/0/0 | 0/0/0 | 0/0/0 | 过 |
| 附加面 `^ERROR` | 0 | 0 | 0/0 | 过 |
| 附加面 `^CRITICAL WARNING` | **3** | **3** | **3/3** · **3/3** | **逐数相同** |
| 附加面 `VRFC 10-` | 0 | 0 | 0/0 | 过 |
| 附加面 `Synth 8-`（信息级） | 1395 | 2468 | 1354/2443 · 1384/2469 | +41 / +25（见下） |
| 附加面 `xelab` / `\[Synth 8-36\]` | 0/0 | 0/0 | 0/0 | 过 |

**33 条栏 B 命中的真实身份**（我逐条核过）：`pcs64_synth_1/runme.log` **28** 条 + `xdma_0_synth_1/runme.log` **5** 条，
**`synth_1` = 0、`impl_1` = 0** —— 命中的全是 **AMD IP 自己生成的代码**（路径均指向 `vivado_prj/.../ip/pcs64/...`、
`.../ip/xdma_0/...`）。与基线**同数同源**。

**3 条 CRITICAL WARNING**（`board/p7b_ku5p_stdout.txt`）：`[Constraints 18-1056] Clock 'gtrefclk0' completely overrides
clock 'gt_refclk_p'` **x2** + `[Vivado 12-1790] Evaluation License Warning` **x1** —— 与基线（Stage B 报告逐字列的三条）**同数同文**。

**DRC 对照**：`board/p7b_ku5p_drc.rpt` 与基线均 **`Checks found: 69`**，且**除 `| Date` 行外 `diff` = 0 行** ⇒ **无新增 DRC**。

**时钟交互对照**：归一化（数字全替换）后 `diff` = **0 行** ⇒ **每一行的 `Clean` / `Partial False Path` / `Timed`
分类逐字未变**；严格 `diff` = 70 行，**全部只在 slack 数值与端点数**（例：DP 域 `0.01 -> 0.07` / `162,574 -> 166,225` 端点）。
⇒ **未引入新的时钟交互分类**。

⚠️ **口径提醒（同外轮）**：`Synth 8-` 是**信息级**宽面计数（含 IP 的 `8-11241`、`8-6793` 等一切 `Synth 8-*`）。
本轮 +41/+25 我**未逐条归因**（登记为"未证明"，见 §9）；硬门族（上表 12 条）**一条未变**。

---

## 5. 时序对照表（基线 = Build 2，同流程同策略 `Performance_ExtraTimingOpt`）

**0 失败端点的出处（我亲自读到的报告行）**：`board/p7b_ku5p_timing.rpt:156`（总表数字行，逐字
`0.070 0.000 0 246497 0.010 0.000 0 246497 0.000 0.000 0 80320`）+
`:159` 逐字 `All user specified timing constraints are met.`；基线同位置 = `baseline_archive/p7b_ku5p_timing.rpt:156`
（`0.006 0.000 0 242843 0.008 0.000 0 242843 0.000 0.000 0 79109`）。

### 5.1 总表

| 指标 | 基线（Build 2） | **Build 3** | 差 |
|---|---|---|---|
| **WNS** | +0.006 | **+0.070** | **+0.064（变好）** |
| **WHS** | +0.008 | **+0.010** | +0.002 |
| **WPWS** | 0.000 | **0.000** | 0 |
| setup 失败端点 (TNS) | 0 | **0** | 0 |
| hold 失败端点 (THS) | 0 | **0** | 0 |
| PW 失败端点 (TPWS) | 0 | **0** | 0 |
| 端点总数（setup/hold） | 242,843 | **246,497** | **+3,654** |
| 端点总数（PW） | 79,109 | **80,320** | **+1,211** |
| DP 域 (`g_hw.clk_out0`) WNS / 失败 | 0.006 / 0 | **0.070 / 0** | +0.064 |
| DP 域 WHS / 失败 | 0.010 / 0 | **0.010 / 0** | 0 |
| DP 域 WPWS / 失败 | 2.627 / 0 | **2.627 / 0** | 0 |
| DP 域端点（setup/hold） | 135,660 | **138,690** | **+3,030** |
| DP 域 PW 端点 | 47,998 | **49,208** | +1,210 |
| `async_default` DP（异步复位 R/C） | 0.758 / 0.177 / 0 失败 | **1.216 / 0.105 / 0 失败** | +0.458 / −0.072 |
| `async_default` pcie_axi_aclk | 0.158 / 0.157 / 0 失败 | **0.230 / 0.156 / 0 失败** | +0.072 / −0.001 |
| 互时钟 `pcie_axi_aclk -> pipe_clk` | 3.071 / 0.045 / 0 失败 | **2.714 / 0.230 / 0 失败** | −0.357 / +0.185 |
| 互时钟 `pipe_clk -> pcie_axi_aclk` | 2.306 / 0.428 / 0 失败 | **2.326 / 0.152 / 0 失败** | +0.020 / −0.276 |

（新值出处：`board/p7b_ku5p_timing.rpt:156` 总表 · `:221` DP 段头 · `:241-256` Other Path Groups 表；
基线值出处：`baseline_archive/p7b_ku5p_timing.rpt` 同位置。**全部 0 失败。**）

⚠️ **口径提醒**：bat 打的 `P7B_WNS/WPWS` 行里 `WPWS` 是**一列每 group 的最差 slack**（非标量）；
WPWS 真值以报告总表（**0.000 / 0 失败**）为准 —— 两轮同形。

### 5.2 DP 域前 10 名单（`-max_paths 10` 的交涉件）

判据件 = `impl_1/wrapper_p4_timing_summary_routed.rpt`（`-max_paths 10 -routable_nets`），与基线**同一命令**。

**Build 3（本轮）—— 10/10 全被新族占满：**

| # | Slack | Source -> Destination |
|---|---|---|
| 1 | **0.070** | `u_tcp_tx/retx_active_reg/C` -> `u_tcp_tx/ctrl_tcpcsum_reg[14]/D` |
| 2 | 0.086 | 同上 -> `u_tcp_tx/ctrl_tcpcsum_reg[13]/D` |
| 3 | 0.093 | 同上 -> `...reg[15]/D` |
| 4 | 0.121 | 同上 -> `...reg[12]/D` |
| 5 | 0.123 | 同上 -> `...reg[7]/D` |
| 6 | 0.132 | 同上 -> `...reg[11]/D` |
| 7 | 0.142 | 同上 -> `...reg[9]/D` |
| 8 | 0.142 | 同上 -> `...reg[10]/D` |
| 9 | 0.144 | 同上 -> `...reg[8]/D` |
| 10 | 0.165 | 同上 -> `...reg[5]/D` |

**基线（Build 2）—— 10/10 全被老族占满**（`baseline_archive/wrapper_p4_timing_summary_routed.rpt`）：
`u_app_udp/u_txf/dout_reg[70]/C` -> `u_udp_tx/ip_csum_r_reg[0|1][...]/D`，slack 0.006 / 0.010 / 0.018 / 0.079 /
0.082 / 0.083 / 0.084 / 0.157 / 0.171 / 0.173。

=> **换族且是"整体换"**：两边各自 10/10 独占（不是"新族挤进一两条"）。
新族在本轮报告里**找不到一条老族路径**（`grep u_app_udp/u_txf/dout_reg` 命中 0）。

新族最差条的形态（`wrapper_p4_timing_summary_routed.rpt`）：
**Data Path Delay 6.234 ns（logic 2.611 / route 3.623）· Logic Levels 22**（`CARRY8=7 LUT1=1 LUT2=1 LUT3=1
LUT4=2 LUT5=4 LUT6=4 MUXF7=1 MUXF8=1`）—— 7 个 CARRY8 = `fold16` 的进位链，是本刀最长的一条锥。

### 5.3 新族是"新锥"还是"老路径被重排"？—— **新锥**（源码面证据）

| 问题 | 证据 | 结论 |
|---|---|---|
| `ctrl_tcpcsum` 在 HEAD 里存在吗？ | `git show HEAD:rtl/tcp_tx_frame.v \| grep -c ctrl_tcpcsum` = **0**；HEAD 文件 = **1158 行**，`ifdef` 表里**没有 `TCP_TX_OVL`** | **不存在** |
| OVL 分支本身？ | 工作区 `rtl/tcp_tx_frame.v`：`` `ifdef TCP_TX_OVL `` = `:204`，`` `else `` = `:1016`，`` `endif `` = `:1977` ⇒ 分支体 = `:205-1015`（约 **810 行**，全部为**新增**） | 工作区 `:538-547`（`ctrl_tcpcsum_now` / `h_tcpcsum = h_ctrl ? ctrl_tcpcsum : f_tcpcsum[tx_bank]`）**落在 OVL 分支内** |
| 宿端寄存器 | 新族宿端 = `u_tcp_tx/ctrl_tcpcsum_reg[*]` —— 该 cell 在 Build 2 的网表里**不可能存在**（源码里就不存在） | ⇒ **该路径不可能存在于 Build 2** |

⇒ 判定：**DP 前 10 是被本刀新增的锥整体接管的，不是同族内部换最差位**。
（对照 Stage B 的口径 "新锥一条都没进 DP 前 10" —— 本刀**相反**。这不是回归，本轮 **0 失败端点**；
WNS 反而比基线高 0.064，说明老族在本次 P&R 里被排布得更好。**但代价下轮要记**：DP 域现在的天花板
是这条 22 级的 `retx_active -> ctrl_tcpcsum` 链，任何再加逻辑都会先吃它。）

### 5.4 有违例吗？

**没有**。三类失败端点全 0（`board/p7b_ku5p_timing.rpt:156` + `:159` "All user specified timing constraints are met."）。
⇒ "列族并判是不是同族"这一格**不适用**（无违例可判）。**变好/变坏**的族判定见 §5.2/§5.3。

---

## 6. 资源对照（`utilization_placed`，逐数）

| 资源 | 基线（Build 2） | **Build 3** | 差 |
|---|---|---|---|
| CLB LUTs | 71,414 | **73,869** | **+2,455** |
| └ LUT as Logic | 64,760 | 66,879 | +2,119 |
| └ LUT as Memory | 6,654 | 6,990 | +336 |
| CLB Registers (FF) | 70,107 | **70,982** | **+875** |
| CARRY8 | 1,425 | 1,463 | +38 |
| F7 Muxes | 3,524 | 3,479 | −45 |
| F8 Muxes | 1,265 | 1,222 | −43 |
| Unique Control Sets | 2,926 | 2,936 | +10 |
| **Block RAM Tile** | 348 | **348** | **0** |
| └ RAMB36 / RAMB18 | 317 / 62 | 317 / 62 | 0 / 0 |
| URAM | 0 | **0** | 0 |
| DSP | 4 | 4 | 0 |
| Bonded IOB | 10 | 10 | 0 |
| MMCM | 1 | 1 | 0 |
| GTYE4_CHANNEL / COMMON | 6 / 2 | 6 / 2 | 0 / 0 |

- 派单估计 `+650-900 LUT / +0.66-1.6k FF`（都标注为"估计"）：**FF `+875` 落在区间内**；
  **LUT `+2,455` 是估计上界的 2.7 倍**。设计件的另一处估 `≈+1.8-2.1k LUT / +0.4-0.45k FF`（`P7B_STAGEC_TX.md` §5-2，
  自称"没有实测背书"）在 **LUT 上接近（2,455 vs 1.8-2.1k）**、在 **FF 上偏低（875 vs 400-450 的 2 倍）**。
- **BRAM 逐数不变（348）** —— 与 `P7B_BRAM_REPORT.md` 的"唯一可迁 URAM 的是 `retx_ram`"结论无冲突：本刀没动存储。

---

## 7. 位流

| 项 | 值 |
|---|---|
| 路径 | `vivado_prj/p7b_ku5p_prj.runs/impl_1/wrapper_p4.bit`（副本 `p7b_build_stageC/stageC_wrapper_p4.bit`） |
| **sha256** | **`1609d6f55e8a119b2f88c1a57cd4776e2219f56d3d1e84f840b198555e576f3c`** |
| 字节数 | **15,431,261**（与基线**同字节数** —— 同器件同布局规模） |
| 与基线比 | 基线 Build 2 `1ccbd9cd84292d1a10973a1442f71ca2187e66834be5e09d7eeb22b42c6cdd07` ⇒ **两版不同** |
| **板上状态** | **未烧**（本轮纪律：不烧板 / 不写 `0x08`）。板上仍应是 Build 2（`1ccbd9cd…`，BID 9） |

⚠️ **因为 BID 已 bump 到 10**，Build 3 一旦烧上去，板级身份门的读数应当是 `0x04 = 0x0000000A` —— **这次两版可分**
（#55 的教训已消除）。**但请用 sha256 复核，别只信 BID**（BID 只是"是不是这一版"，sha256 才是"是不是这个位流"）。

### 7.1 构建顺带改写的**已跟踪**文件（不是我的编辑，是构建的产物）

`git status` 里另有 5 个 `M` 是构建**自己**写的报告（同名文件每轮都被覆盖，历来如此）：

`board/p7b_ku5p_clkinteract.rpt` · `board/p7b_ku5p_drc.rpt` · `board/p7b_ku5p_stdout.txt` ·
`board/p7b_ku5p_timing.rpt` · `board/p7b_ku5p_util.rpt`

⇒ 现在盘中这 5 份 = **Build 3 的**；**Build 2 的**同批件在 `p7b_build_stageC/baseline_archive/`（§1.1）。
`git status` 的其余 `M` 全是**开工前就有**的（`rtl/*` 2 个 + `sim/p4sim/matrix_p4dfix.log`，后者是矩阵 runner 自己的输出）。
**本轮未提交任何东西**（未 `git add`、未 `git commit`）。

---

## 8. 修订漂移检查（构建前后各一次）

| 文件 | 构建前 sha256（16:36:15） | 构建后 sha256（17:05 之后） | 判 |
|---|---|---|---|
| `rtl/tcp_tx_frame.v` | `1a1f04397335a8d2c5d3b606bf91ea7796d688d3583046dab590df5d8039789a` | **逐字相同** | **与派单要求值 `1a1f0439…` 一致** |
| `rtl/app_pattern.v` | `0e804099400c2e2b800ef66bbf49d0d26892bb977e4523de208581ef0d81ce06` | **逐字相同** | 未漂移 |
| `board/wrapper_p4.v` | `ca1c503b149b737cce39a7c8fa841b040569083111449bb144471103bfd32d5b` | 逐字相同 | 我改的那个版本被构建 |
| `board/build_p7b_ku5p.tcl` | `48a29036c7b9f70ee6787e1b58aedcaffea055c497fe9b89433dd75b1ff467aa` | 逐字相同 | 同上 |
| `board/run_build_p7b_ku5p.bat` | `91ba3a442c39ec4310a5e60c117127a5f5fcd044c95fc607c14e023899289fee` | 逐字相同 | 同上 |

**⇒ 整轮有效**（构建期间 **没有任何 RTL 漂移**；派单要求的作废条件**未触发**）。
`git status --short` 的 `M rtl/*` 两项内容 = 开工前那一版，逐字未动。

---

## 9. 没能证明的部分（别当绿读）

1. **`Synth 8-` 宽面 +41（栏A）/ +25（栏B）未逐条归因**。硬门族 12 条一条未变；但我**没有**逐条核那 41 条是什么。
2. **"新族是不是 100% 由本刀引入"只做到了源码面**（`ctrl_tcpcsum` 不在 HEAD）。我**没有**用 Build 2 的
   routed dcp 做 `report_timing -from u_tcp_tx/retx_active_reg` 的网表级对照（§1.3：`control_sets` 报告不含网名，
   现成的归档件答不了）。**结论强度 = "源码面确证"，不是"网表面双证"。**
3. **`ctrl_tcpcsum` 那条 22 级锥的分解未做**（哪些级是 `fold16` 进位、哪些是 `h_ctrl` mux）—— 只给了级数构成计数。
4. **功能性：本报告零功能证据**。xsim 门族是回归 agent 的交付面，不是我这一轮的（我未跑任何仿真）。
   本报告的"建成"只指 **综合/实现/位流产出成功 + 时序达标**。
5. **板级：零读数**（未烧板、未写 `0x08`）。BID=10 的**板侧身份读数**尚未取得。
6. **归档脚本的边界**：只覆盖 `run_build_p7b_ku5p.bat` 这一条入口；别的构建脚本（`run_build_p5.bat` 等）
   **仍会**在 `create_project -force` 时抹掉自己的 `impl_1/`。
7. **两栏门的栏 B 是"四份 runme.log 的加总"**，不是逐 run 分栏；某一条键集中在哪个 run 需要另查
   （本轮除 `Synth 8-*` 外两栏全 0，不涉及）。
8. **`p7b_build_archive/` 的长期增长**未处理（150 MB/次），也未加 `.gitignore`（§1.2）。

---

## 10. 证据文件

| 路径 | 内容 |
|---|---|
| `p7b_build_stageC/baseline_archive/` | 开工前手工归档（18 件 + `SHA256SUMS.txt`） |
| `p7b_build_archive/20261007_163651/` | **自动归档**（19 件 + `SHA256SUMS.txt`），证明脚本化归档生效 |
| `p7b_build_stageC/bat_stdout.txt` | bat 的 stdout（起止时刻 / ARCHIVE_* / WNS-WHS-WPWS / BUILD_EXIT） |
| `p7b_build_stageC/gatecheck_out.txt` | 两栏门输出（脚本 `exit 0`，判定由我读） |
| `p7b_build_stageC/stageC_*` | 本轮读数原件（timing / util / drc / clkinteract / stdout / `-max_paths 10` 交涉件 / bit） |
| `board/p7b_ku5p_{timing,util,drc,clkinteract}.rpt` · `board/p7b_ku5p_stdout.txt` | 现役（= Build 3 的） |
