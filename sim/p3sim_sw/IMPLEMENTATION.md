# P7B-SNDWND-GUARD 实施轮 IMPLEMENTATION（2026-10-11）

- 被实施件 = `_proj_10g/notes/P7B_SNDWND_GUARD_DESIGN.md`（477 行），按对抗审查
  `_proj_10g/notes/p7b_sndwnd_review_20261011/FINDINGS.md` 的修法实施（F3/F1/F2/F9/F4/U1/F11 已落）。
- 基线 = **`139d7b71bd320c5379600b17bd67b5b230285e87`**（= 审查基线；本 worktree 分支已 fast-forward 到它）。
- ⛔ 口径：**不下 PASS/FAIL 裁定**（判据裁定权在用户/判据所有者）；**不写"时序已解决"**（本轮零 Vivado）；
  **"未观测" ≠ "不存在"**。本件所有读数 = xsim 实测 + 逐行现读。
- 改动文件（本 worktree 内，4+3 件）：
  `rtl/tcp_rx.v` · `tb/tb_tcp_rx.v` · `tools/gen_stim_tcp_rx.py` ·
  `sim/p3sim_sw/run_sndwnd_gate.bat` + `sim/p3sim_sw/mut/mk_mut_acckadv.py` +
  `sim/p3sim_sw/IMPLEMENTATION.md` + `sim/p3sim_sw/logs/*.txt`（+ `.gitignore` 白名单 8 行）。

---

## §1 改了什么（RTL）

### 1.1 `rtl/tcp_rx.v` —— 两处守卫 + `SNDWND_GUARD` 参数（默认 1 = 修后）

| 位置 | 现读（改后） |
|---|---|
| `:17-31` | 模块头由 `module tcp_rx (` 改为 `module tcp_rx #( parameter SNDWND_GUARD = 1'b1 ) (`（含 14 行注释：谓词必须 `ackok_l` 的理由 / 禁 `ack_adv_l` / 禁 `dup_l` / 置位门与值锁存必须成对） |
| `:526`（原 `:509`） | `pend_wnd <= (s_axis_tcrs && (ackok_l \| !SNDWND_GUARD)) \|\| pend_wnd;` |
| `:536`（原 `:518`） | `if (s_axis_tcrs && (ackok_l \| !SNDWND_GUARD)) begin` |

- **零 FF 新增**（定义域，见 F11）：`ackok_l` 自 r6-fix 起就在（改后现读 `:225` 声明 /
  `:709` 无条件锁存，在 `:610-619` 的 `ifdef TCP_TX_OVL` **之外**）⇒ 在含 `TCP_TX_OVL` 的构建（= 板构建）里 **FF = 0**；
  **宏关构建里 `ackok_l` 是死寄存器，本守卫会让它复活 ⇒ +1 FF**（审查 F11 的限定成立，如实登记）。
- **零端口面改动**：全仓 `tcp_rx` 例化（`board/wrapper_p4.v:1807` / `board/wrapper_tcp.v:282` /
  8 个 TB）**一律具名连接、无参数表** ⇒ 加默认参数不触及任何例化点（现读 grep）。
- **无第二份分支**：本文件唯一宏分支 = 改后 `:610-619`（现核，改点不在其中）⇒ 无 `tcp_tx_frame.v` 那种镜像问题。

### 1.2 ⚠️ 与设计件的**有意偏离**（1 处表达式 + 1 处未采纳）

1. **用 `!SNDWND_GUARD`，不用设计件字面的 `~SNDWND_GUARD`**（理由 = 安静失效族）：
   `~` 对**宽位**实参是逐位取反 —— 调用方若传十进制 `1`（32 位常量），`~32'h1 = 32'hFFFFFFFE`
   **非零** ⇒ `ackok_l | ~guard` 恒 1 ⇒ **守卫被静默禁用**（本该是"修后"却跑"修前"）。
   `!` 是逻辑非，对任意宽度语义正确。**语义后果**：`SNDWND_GUARD=0` 时表达式与 HEAD **逻辑等价**
   （常量折叠），**不是源码文本逐字相同**（与审查 F7 的措辞收窄一致）。
2. **不写可选第二子句 `!fend_trunc`**（审查 U1 建议"不写"，已采纳）：今天结构性冗余
   （`fend` 块里 `pend_wnd` 被 `s_axis_tcrs` 保护，两个 MAC 的 `crs` 都只在 TLAST 字置位）；
   写了会让 `GUARD=0` 失去"文本级可回退"的性质。

---

## §2 改了什么（TB / 生成器 / 门）

### 2.1 `tb/tb_tcp_rx.v`

- **两臂机制**：`` `ifdef SNDWND_LEGACY `` ⇒ `localparam SNDWND_ARM=1'b0` 并**
  具名参数**例化 `tcp_rx #(.SNDWND_GUARD(SNDWND_ARM)) u_rx (...)`（xelab 见证：
  `Compiling module xil_defaultlib.tcp_rx(SNDWND_GUARD=1'b0)`）。
- **三腿快照机制**：9 个字节位置经 **`sw_legs.memh`**（由生成器写，与帧表同源 ⇒ 无硬编码漂移）导入；
  每点是"帧末字节 +30" ⇒ fend/drain 已完成。位置 = `SW_CFG2`(6 字节全字段重配窗) / `SW_ZERO`(snd_wnd=0 单字节慢路径写) /
  `SNAP_DIR` / `SNAP_A0` / `SNAP_A1` / `SNAP_A2` / `SNAP_Z` / `SNAP_B1` / `SNAP_B2`。
- **腿 A 承重件**：每腿断言 **`stat_pass`/`fend` 计数增量**（不只用 `ack_req` —— 纯 ACK 不触发
  `ack_req`，审查 §3.1 的实现注）。
- **期望红编码**：遗留臂打印专标记 `SNDWND LEGA XFAIL-REPRODUCED`（不是把判据放宽；先例
  `sim/p5e_udp` 的 `neglearn`"期望 exit 1"）；失败一律 `[FAIL] SNDWND ...`。
- **定向段自检检查点搬家（判据值一字未改）**：由"仿真终态"改为 `SNAP_DIR` 快照
  （值仍 = `0x44C / 0x1770 / 0x4000`）—— 因为其后新增了腿相位（B2 会推进 `snd_una` 到
  `0x1488`、写 `snd_wnd=0x1234`），终态已不代表定向段收口。**这是加腿的必然后果，不是放宽判据**。

### 2.2 `tools/gen_stim_tcp_rx.py`

- **腿帧表**（`build_sndwnd_legs`）：4 帧**真实 60B 纯 ACK**（`pad=True` ⇒ `S_PAD→fend_pad`，取
  **本帧** `wnd_l`）—— ⛔ 不用 w6-tlast 短帧（那里 `wnd_f` 取上一帧值 ⇒ 假阴性温床）：
  `sw_a1_stale`(ack=snd_una−0x100=4744, wnd=0x0100) · `sw_a2_oob`(ack=snd_nxt+0x1000=10096, wnd=0x1100) ·
  `sw_b1_zeroopen`(ack=snd_una=5000 零推进, wnd=0x4000) · `sw_b2_advshr`(ack=snd_una+0x100=**5256**, wnd=0x1234)。
- **F3 不变量写死**（`check_leg_intervals`，生成即硬断言）：A 腿两条必须在 `[snd_una, ack_hi]` **之外**、
  B 腿两条必须**在内**（含等号）；**腿前全 6 字段基线重配**（机制 = `D_CFG2` 式 `%6` 写、TB/模型同点注入）
  ⇒ 可接受区间 `[5000,6000]` —— 否则定向段终态 `snd_una=snd_nxt=6000` 会让 B2 的 ack 越界、
  **修复臂必假红**（审查 F3 的修法已按此实施）。
- **布局自检**：`generate()` 末尾 9 条 assert（窗/帧/快照点相对位置、`SNAP_DIR ≥ DIR_HOLD1+40`、
  尾长足够）⇒ 位置漂移 = 生成即失败（不许"位置漂了但门还绿"）。
- **周期精确模型**：新增 `ackok_l` 状态位（`wc==5` 锁存，镜像 RTL `:707`）；`pend_wnd` 置位与值锁存
  **同款加 `(crs and (ackok_l or not guard))`**；`model(simdir, mode, guard=True)`；`check(..., guard)`；
  CLI = `check [arm] [modes]`（**F9**：模型必须与 DUT **同臂同参**；缺省 = `fixed` 全三模 ⇒
  既有 `run_tb_tcp_rx.bat` 的调用**逐字兼容**）。
- **⭐ 一处勘误（设计件/审查的算术笔误）**：B2 的 `ack = snd_una + 0x100 = 5000+256 = 5256 = 0x1488`
  —— 设计件 §5.1 写 `0x100` ✓、审查 F3 的 "6256 = 6000+0x100" ✓ 但同一句又把重配后的值写成
  `5100`（= +100 十进制，与 0x100 不一致）。实施取 **0x100 = 256** ⇒ TB 断言 `snd_una → 0x1488`
  （模型实测同为 5256）。**这一格已按 0x100 的含义钉死并机器断言**。
- **`SW_LEGDROP_A=1`（环境变量，默认关 = 零行为改动）**：腿 A 两帧 seq 挪到窗口外
  （`rcv_nxt+0x3000`）⇒ 被 `S_DROP` 静默丢弃 ⇒ 供门做 **"承重件有牙"对照**（见 §4-D）。

### 2.3 新门 `sim/p3sim_sw/run_sndwnd_gate.bat`（自定位 + pathguard + 隐式网键 + 编译源见证）

四臂：**A=FIXED / B=LEGACY / M=MUTANT / D=DROPA**，每臂 3 模式（nostall/stall/hard）+
python 模型 check（臂配）+ 6 条判据（见脚本文档头）。变异件由
`mut/mk_mut_acckadv.py` **锚点计数**生成（锚点 `(s_axis_tcrs && (ackok_l | !SNDWND_GUARD))` 必须
恰好 2 处，否则硬失败；`changed_lines=[526, 536]`、字节差 = 2×(替换长差)、CRLF 计数不变；
**变异件本身不入库**（可再生成，同 `sim/_mut_rtl/` 政策））。

---

## §3 逐腿读数（机器原文，`logs/*.txt` 逐字）

### 腿 A（判别：陈旧/越界 ACK 不得覆盖 snd_wnd）

| 臂 | 读数（nostall/stall/hard 三模式逐字相同） | 判读 |
|---|---|---|
| FIXED | `SNDWND LEGA PASS wnd1=2000 wnd2=2000 base=2000 passd=2 fendd=2` | 窗保持重配值 0x2000；**且两帧确实被收下+fend**（passd/fendd=2） |
| LEGACY | `SNDWND LEGA XFAIL-REPRODUCED wnd1=0100 wnd2=1100 passd=2 fendd=2` | 缺陷**复现**：A1 写 0x0100、A2 写 0x1100（专标记 = 期望红） |
| MUTANT | `SNDWND LEGA PASS`（同上） | mutant 只碰 B1 ⇒ 腿 A 仍绿（红的**专属**性） |
| DROPA | `[FAIL] SNDWND LEGA ... passd=0 fendd=0` | 帧被丢弃 ⇒ **收下断言有牙**（值判据此格仍满足 ⇒ 只挂值判据会安静退化） |

### 腿 B1（正对照：零推进窗口更新 = 零窗重开，必须活着）

| 臂 | 读数 | 判读 |
|---|---|---|
| FIXED | `SNDWND LEGB1 PASS wnd_zero=0000 wnd=4000 passd=1 fendd=1` | 慢路径先把窗写成 0（见证 0000），零推进 ACK 把它重开成 0x4000 ✓ |
| LEGACY | 同上（`wnd=4000`） | 遗留臂也绿 ⇒ 腿 A 的变红不是"把别的东西弄坏" |
| MUTANT | `[FAIL] SNDWND LEGB1 wnd_zero=0000 wnd=0000 (exp 4000) passd=1 fendd=1` | **谓词写错（`ack_adv_l`）⇒ 零窗恢复被打死**；且 `passd=1 fendd=1` = 帧被收下、只是窗没被写 ⇒ **腿 B 测的就是这个谓词**（设计 §4.2 否决理由的机器证明） |

### 腿 B2（正对照：推进 + 窗变小必须照收）

| 臂 | 读数 | 判读 |
|---|---|---|
| FIXED / LEGACY / MUTANT / DROPA | `SNDWND LEGB2 PASS wnd=1234 snd_una=00001488 passd=1 fendd=1` | 窗变小 0x1234 照收；`snd_una` 5000→5256(0x1488) 证明 ACK 确被处理 ✓ |

### 定向段自检（旧判据，检查点搬到 SNAP_DIR）

四臂 3 模式全绿：`P4b7 DIRECTED PASS rcv_nxt=0000044c snd_una=00001770 snd_wnd=4000`
（⇒ 本守卫**没有碰坏** sticky pend / gnt-hold 定向段语义）。

### 模型 check（F9 同臂同参）

- FIXED：`nostall OK / stall OK`（`logs/A_fixed_chk_ns.txt`）—— **DUT↔模型逐行逐字一致**
  （含新增腿帧的 FEND/META/STATS/TCBF）。
- LEGACY：`nostall OK / stall OK`（`logs/B_legacy_chk_ns.txt`）—— 模型臂镜像生效（TCB1 的
  `snd_wnd` 在遗留臂被 base 流 conn1 帧写成 0x1234，模型同臂同值）。
- **臂错配负对照**（机器证据）：拿**遗留臂的 resp** 跑 `check fixed` ⇒
  `nostall TCBF: exp [... '2000' ... '2000'] resp [... '2000' ... '1234']  MISMATCH`
  （`logs/B_legacy_chk_mismatch_armctl.txt`）⇒ **臂镜像是有承重力的**（不配臂 = 红）。
- ⚠️ **登记**：MUTANT / DROPA 两臂的模型 check 也 OK —— 因为**模型看不见**这两类注入
  （mutant 只改窗写入、resp 行集合无 TCB 轨迹；drop 注入被模型同样镜像）。
  ⇒ **这两臂的判别力 100% 来自 TB 显式断言，不来自模型比对**（与设计 §5.2 的口径一致；
  这正是"同源 oracle 一致 ≠ 正确"的又一实例）。

---

## §4 门的现核（真跑了，逐条读数）

| 门 | 现核读数 | 备注 |
|---|---|---|
| `sim/p3sim/run_tb_tcp_rx.bat`（现役单元门；**不在常驻矩阵**） | **RC=1**；三模式 `SNDWND ALL PASS`；模型 `nostall OK / stall OK / hard MISMATCH` | ⚠️ **RC=1 是既存红**：HARD 模式模型/DUT 第 63 行分歧（`exp 'META ...' resp 'FEND 1'`），**HEAD 基线同样红**（见下） |
| `gate4096`（**PCWND1K**，审查 F2 点名优先复跑） | `GATE gate4096 EXIT=0` | 矩阵 `-only` 实跑（~2 min/门） |
| chain 族 + `p5_wrapper`（共 12 门） | 见 §4.1（本轮后台实跑，逐门 EXIT 码） | `run_matrix_p4dfix.sh -only ...`；含 pathguard/manifest/指纹 |
| FIXED 臂 × 3 模式（新门） | 全绿（§3） | |
| LEGACY / MUTANT / DROPA（新门） | 全部按设计红/绿（§3） | 期望红 = 专标记 |

**HEAD 基线对照（消掉"是不是我弄红的"）**：把 `rtl/tcp_rx.v` / `tb/tb_tcp_rx.v` /
`tools/gen_stim_tcp_rx.py` 的 **HEAD 副本**放进干净目录重跑同一条 p3sim 流程 ⇒
`nostall OK / stall OK / hard MISMATCH`，**RC=1**（`logs/baseline_head_hard_evidence.txt`，
逐字含 `hard LINE 63: exp 'META 0A000001 D431 0014 1 00000000' resp 'FEND 1'`）
⇒ **HARD 分歧与本次改动无关（既存，形状逐字相同）**；同时新门把它写成**签名断言**
（签名变了就响亮失败 ⇒ 不会被静默翻绿）。

### 4.1 常驻矩阵实测（chain 族 12 门 + gate4096，逐门现核）

```
bash sim/p4sim/run_matrix_p4dfix.sh -only chain+burst200+trunc50+trunc100+halfdrop+txdrop50+dupstorm+pcackoob+vlanchain+vlanburst+stallgate+p5_wrapper
```

| 门 | 读数 |
|---|---|
| `chain` / `burst200` / `trunc50` / `trunc100` / `halfdrop` / `txdrop50` / `dupstorm` / `pcackoob` / `vlanchain` / `vlanburst` / `stallgate` / `p5_wrapper` | **12/12 `EXIT=0`**（`MATRIX-RC=0`） |
| `gate4096`（PCWND1K；F2 点名优先） | 单独先跑一轮：`GATE gate4096 EXIT=0` |

- 汇总行：`gates run 12 / 17 · gates failed: 0 · MATRIX DONE`。
- **冻结核**（#57 的"回归有效"第一步）：`VERDICT: FROZEN -- all 257 hashed files
  byte-identical across the run`；`GIT_HEAD = 139d7b7`；
  `DIGEST_COMPILE = 49b70767… / FILES_COMPILE = 212 / DIGEST_ALL = e873966f… / FILES_ALL = 257`
  ⇒ 跑动期间**源码零漂移**（`p5_wrapper` 的 `P5 WRAPPER OK` 也在日志里）。
- ⚠️ **口径（不许扩大）**：本矩阵只说明"`rtl/tcp_rx.v` 的新守卫在 chain 族配置
  + `p5_wrapper`（经 `wrapper_p4.v` 间接编译）下不破既有判据"；
  **矩阵的 manifest / 指纹不含 `tb/tb_tcp_rx.v` 与 `tools/gen_stim_tcp_rx.py`**
  （`grep` 逐条现核 = 0 命中）⇒ **"12/12 EXIT=0" ≠ "本刀全量回归通过"**（§6-6）。

---

## §5 与审查 FINDINGS 的逐条对照（落点自查）

| # | 审查要点 | 落点 |
|---|---|---|
| **F3** | 腿 B2 必假红 ⇒ 腿前全 6 字段基线重配 | ✅ 生成器 `check_leg_intervals` + `SW_CFG2` 6 字节重配窗（TB/模型同点）；实测 B2 四臂全绿 |
| **F1** | `rtl/tcp_synp.v:85` 是第二个 snd_wnd 上游写者 | ✅ 登记在本件（**未改**：不在允许清单、且与守卫语义正交 —— 建连初值来源）；设计件枚举缺口如实记录 |
| **F2** | `PCWND1K` 被常驻门 `gate4096` 使用 | ✅ `gate4096` 实跑 EXIT=0（§4） |
| **F9** | "必须同批改模型"无腿语料下不成立 ⇒ 改"同臂同参" | ✅ `check [arm] [modes]` + 臂错配负对照（§3） |
| **F4** | 引文出处 `tb/tb_tcp_rx.v:213` | ✅ 本件/提交信息按此出处（gen `:181` 是别的句子） |
| **U1** | 不写 `!fend_trunc` | ✅ 未写（§1.2-2） |
| **F11** | "0 FF"限 `TCP_TX_OVL` 开的构建 | ✅ §1.1 加了定义域（宏关构建 +1 FF） |
| **F7** | "逐字相同" = 折叠等价（措辞收窄） | ✅ §1.2-1；另因 `!`/`~` 偏离，`GUARD=0` 只承诺**逻辑**等价 |
| **F5/F6/F10** | `== SND.UNA` 非 RFC duplicate / "drop the segment" 残留 / `tb_p5_wrapper` 是层次赋值非 force | ✅ 只影响文档措辞，实施面无动作；本件按订正口径记录 |
| **U7** | persist 板级 P-A 注入器 `ack` 字段必须取注入时刻的 `snd_una..snd_nxt` | ⚠️ **未实施**（属 persist 刀交付面）；**排批后果**已登记：守卫默认 = 1 ⇒ 守卫进树后任何后续构建都带守卫 |
| **R-E 建议** | 越界 ACK 只拦窗口写入，载荷仍交付（RFC "drop the segment" 未实现） | ⚠️ 如实登记为**残留**（未改，非本轮范围） |

---

## §6 未定项 / 不许当已答（⛔）

1. **板级判据全部未跑**（本轮零 Vivado / 零上板）：设计 §5.5 的注入式判据
   （`W66/W67/W63/W20` + `W69` 见证；注入器 `stall_probe.py` 的 `ack` 需先按 U7 改造）
   **没有读数**；"本守卫在板上不产生退化"**未被观测**（只被"改动是放行集合的子集"的结构论证支持）。
2. **HARD 模式既存红未收口**（不是本刀引入，本刀也没修）：签名已入新门做**不变断言**；
   机理（模型保真度缺口）**未定位**。
3. **`rtl/tcp_synp.v:85` 的第二写者未处置**（F1）：它写的是**建连初值**，与"生命周期内的
   ACK 侧更新"正交 ⇒ 不构成本守卫的漏洞，但设计件的枚举缺口已在案。
4. **R-A（可接受 ACK 之间乱序，C5）未做**：需 per-conn WL1/WL2 + `tcp_rx` 新读端 ⇒ 判"非最小"
   （设计 §4.5 维持）。**R-C**（`ackok_l` 采样时基略旧 ⇒ 边界 ACK 放行略偏宽）**登记不修**。
5. **`fend_w6t/fend_w6a` 的"值来自上一帧"（R-B/U2）未做**：独立子情形，设计判"可分离第二刀"。
6. **回归指纹盲区（新登记，已现核）**：常驻矩阵 `FINGERPRINT_GLOBS` **不含** `tools/gen_stim_tcp_rx.py`、
   任何 manifest **不含** `tb/tb_tcp_rx.v`（`grep sim/p4gates/*.f + paths.txt` = **0 命中**）
   ⇒ 本轮矩阵**看不见**这两个文件的改动（同族于已知的"矩阵不含 `app_pattern.v`/`wrapper_p4.v`"）。
   ⇒ 本刀的矩阵读数**只**能证明"`rtl/tcp_rx.v` 的新守卫不破 chain 族"，**不能**替 p3sim/新门作证。
7. **新门未登记进常驻矩阵**（属"动别的文件先报"范围）：设计 §5.4 的登记建议 + F8 的
   `:gate` 清空清单/`<src.f>` manifest 要求**留待 TL 决策**。
8. **`p3sim` 门 RC=1（既存）**：它不在常驻矩阵 ⇒ 长期无人看它的退出码；本刀**未修**
   （修 = 改模型保真度，超出本刀范围）。
9. **跑过的门 = §4.1 那 13 门（12 + gate4096）+ p3sim + 新门四臂**；**未跑**：矩阵其余 4 门
   （`unit_retx`/`unit_fifo`/`unit_vlan`/`unit_uart`，与本刀不相干：不编译 `tcp_rx`）与
   板上/综合侧全部。**本刀从末跑过任何 Vivado**（构建/时序面零读数）。

---

## §7 给 TL 的两条操作要点

- **cherry-pick 注意事项**：本 worktree 分支从 **`139d7b71`** 起（= 审查基线），只含上述 7 件
  (+`.gitignore`) 改动；`sim/p3sim_sw/` 下**工作目录产物**（`runA_fixed/` 等）**按 .gitignore
  排除**，入库的是驱动器 + 变异生成器 + 报告 + `logs/*.txt`（含 `matrix_chainfamily_full.txt`
  矩阵全量日志）+ 矩阵最终轮的指纹对 `sim/p4sim/P4_MATRIX_FINGERPRINT_20261011_012427_{before,after}.txt`
  （`.gitignore:408` 既有白名单本来就要跟踪它；被跟踪的 `sim/p4sim/matrix_p4dfix.log` 已按
  `git checkout HEAD --` 还原 —— 它是主树共享产物，改它会把本 worktree 的运行混进共享账）。
  `.gitignore` 的新块用"整目录 + 白名单"写法 ⇒ 合并后**必须**用
  `git check-ignore --no-index -v` 逐件核（本仓 #79：被跟踪文件的 `check-ignore` 会因 index 优先而骗人）。
- **不可引用**：本件无任何时序/面积读数（零综合）；`rtl/tcp_rx.v` 的 `SNDWND_GUARD` **默认 1**
  ⇒ 一旦合并，后续任何构建（含 persist 刀）都带守卫 ⇒ persist 的板级 P-A 注入器需按 U7 先改。
