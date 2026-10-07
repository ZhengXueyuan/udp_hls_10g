# Stage C / A2：`rtl/app_pattern.v` TX 侧到 **1 拍/字**（实测 **190 拍/帧**）—— 实现 + 门 + 读数

- 日期：**2026-10-07**　性质：**RTL 实现 + 仿真门**（xsim）。⛔ **未烧板、未写 `0x08`、未提交 git、未做任何构建**
  （面积/时序一律按"估计"读，见 §6）。
- 任务口径：`app_pattern` 的 TX 吞吐改动，包在**既有宏 `P7B_10G`** 内；宏关时**逐字节等于改动前**（机器证明，§5）。
- 基线 `sim/p7b_stagec_a2/app_pattern.v.pre_a2` sha256 **`da7a2c7c…a499e1`**，
  与 `git show HEAD:rtl/app_pattern.v`（HEAD=`46b2f68`）**实测逐字节相同**（`cmp` 静默）⇒ **基线就是 HEAD 件，
  且 HEAD 件里已含 Stage B 的 RX 8 路**（`grep -c "RX 8 路并行" HEAD件` = 1）。
- 改后 `rtl/app_pattern.v` sha256 **`0e804099…d81ce06`**；diff = **+72 / −0 行**（纯插入：原语句全部留在 `` `else `` 分支里）。

---

## 0. 判决（先给读数）

| 判据 | 读数 | 等级 |
|---|---|---|
| **A2 拍/帧**（帧 2→22 差分 / 20，下游恒 ready） | **190.00**（opener→opener 与 tlast→tlast 两个口径都是 `dcyc=3800`，余数 0） | **仿真实测** |
| 默认构建拍/帧（同 TB 同激励） | **1828.00**（`dcyc=36560`） | **仿真实测**（与 Gap#9 §1.3 的 1828.000 逐位相同） |
| A/B 字节等价 | **29 个 dump/stats 文件逐字节相同**（`fc /b`，含 14 实例 × 载荷字节流 + 每帧字节数 + stats） | **文件对比** |
| 宏关构建等价 | 预处理输出与改动前**逐字节相同**（25386 字符），且 5 处锚点各命中恰 1 次 | **机器证明** |
| 负对照 C/D/E/G（4 个行为变异） | 全部 **RC≠0**，且文件集与 A 不同 | 见 §4 |
| 负对照 F（A1 形态：只退时间） | **恰 2 红，且都红在"拍/帧判据"**；29 个文件与 A **逐字节相同** | 见 §4 ⇒ **拍/帧门有牙** |
| 回归 | Stage B 的 **RX8 门**（同一文件、同一 TB）在**两种宏态**下 8 个文件与 `sim/p7b_stageb_rx8/run*` 记录**逐字节相同** | 见 §5 |
| 端到端 | **未测**：本改动只是"app 不再限速"；下行仍受 `tcp_tx_frame`（另一支 agent 的乒乓）约束 | 见 §6 |

一句话：**A2 把 app 单独从 1828 拍/帧 打到 190 拍/帧（×9.62），且与默认构建在 14 个实例、9 种段长、坏帧/收尾/换流/tx_ok 暂停全场景下逐字节相同**。
`190` 与设计件 `P7B_SINGLE_FLOW_10G_DESIGN.md` §3.2 / `P7B_GAP9_TCPAPP_8WAY_DESIGN.md` §3.2 的**设计值精确相等**（不是 ±1）。

---

## 1. 交付物与一行复现

```
rtl/app_pattern.v                              （A2；宏 `ifdef P7B_10G`）
tb/tb_app_a2_equiv.v                           （14 实例的自检式门 TB）
sim/p7b_stagec_a2/apply_a2.py                  （应用 + 机器证明；--check 只证明）
sim/p7b_stagec_a2/gen_negctl_a2.py             （5 个负对照变异件）
sim/p7b_stagec_a2/run_a2_gate.bat              （自定位门：xvlog→xelab→xsim，7 次跑）
sim/p7b_stagec_a2/app_pattern.v.pre_a2         （基线，勿删）
sim/p7b_stagec_a2/gate_out.txt                 （本轮门日志，末行 = `A2-GATE: PASS`）
sim/p7b_stagec_a2/rx8regA|rx8regB/             （RX8 回归两跑）
```

一行复现（在**本仓根**执行；重跑会覆盖 `sim/p7b_stagec_a2/run*`）：

```bash
cd /d/repo/XCKU5PMini/udp_hls_10g && cmd //c 'sim\p7b_stagec_a2\run_a2_gate.bat'    # 期望末行: A2-GATE: PASS
```

---

## 2. 改动（行号为**改后** `rtl/app_pattern.v`，831 行）

| # | 位置 | 内容 |
|---|---|---|
| 1 | `:383-397` | **前瞻量**（`ifdef`）：`pw_take / sent_a / left_a / need_a`。`sent_a = seg_sent + (pw_take ? pw_n : 0)`；`pw_take ≡ 消费块的门` |
| 2 | `:447-453` | **`a2_hold`**（帧拆除拍让位）+ `asm_go` 唯一放宽 + `a2_ldw`（整字预取命中线网） |
| 3 | `:469-471` | `asm_full` 口径改用 **`need_a`** |
| 4 | `:705-720` | **整字 1 拍装载分支**（`a2_ldw`）插在"收尾分支"之后、"逐字节填充"之前 ⇒ 尾字结构性回落 |
| 5 | `:781` | **装载赢 `pw_valid`**（写在消费块之后；同拍"消费+预取"时把刚预取的字写回） |

### 2.1 与设计件/父 agent 推演的三处**有意偏差**（都附证明）

**(a) 收尾判据**：设计件说"把 `need/left` 重定义为前瞻版"。本实现**没有**——收尾分支 `if (need == 4'd0)` **仍用非前瞻 need**，
`left/need` 一行未改（`:379-380` 原文保留）。
理由（推演）：前瞻收尾会让"末字被消费"与"帧收尾"**同拍**，那一拍消费块必然后写 `seg_sent <= seg_sent + pw_n`
（并且收尾分支还会读到**尚未扣减**的 `remain`）⇒ 下一帧从 `seg_sent = 旧 seg_len` 起（多一帧/帧长错）。
本实现让收尾保持"最后一个字被消费后的**下一拍**"⇒ 收尾与默认构建**同拍采样** `tx_ok/remain/frm_idx`，
坏帧序号、下一帧长度、`frm_wait` 判定全部不移相 ⇒ **`remain_a` 前瞻不需要存在**。
**这不是"声称"，有负对照**：m2 = "收尾改用前瞻 need_a"（即设计件的写法）⇒ 门变红（§4-D：12/14 实例 `stat_tx_frames` 对不上 + 帧长序列被 0 字节帧污染）。
⇒ 父 agent 推演的"坑 1"（`seg_sent` 被盖）**真实存在**，但本设计让它**结构性不出现**（不靠"修"，靠"不撞"）。

**(b) 装载块的门没有放宽**：父 agent 要求把 `if (asm_full && !pw_valid)` 放宽成 `(!pw_valid || m_tready)`。
**证明它在这套结构里恒为惰性**：`asm_full ⟹ bcnt == need_a > 0`；而 `pw_valid==1` 时 `bcnt` 恒 0
（整字分支每次都把 `bcnt<=0`，且填充分支只在 `pw_valid==0` 的拍上推进；`pw_valid==1` 时 `asm_go` 需要 `m_tready`，
分支取整字路径 ⇒ 不碰 bcnt）⇒ **两者不可能同拍**。故保留原判据（少一处改动）。

**(c) 新增 `a2_hold`**（设计件没有）：`a2_hold = ev_restart || (ev_down && active && ev_slot==act_id)`。
判据与 RTL 里那两个事件块**逐字同款**。这些拍上默认构建因 `!pw_valid` 而不装配；预取若不让位：
①`ev_down` 撞 payload beat ⇒ 收尾帧**多 8 字节载荷**（默认是 0 载荷收尾字，线上帧长改变）；
②`ev_up` 换流拍 ⇒ 残余字会占住呈交口把新会话 opener 顶掉。让位后这些拍与默认**逐位同行为**（整字分支同门让位 ⇒ 回落逐字节）。

**(d) `asm_full` 用 `need_a`**：尾字的**第一个填充拍**落在"最后一个满字的消费拍"上（前瞻 `need_a` 就是尾字长）；
若那里用非前瞻 `need`（=8）会多填 1 字节 + 多推进 1 步 LFSR ⇒ **整条图案流从此偏移 1 字节**。
**负对照 m5**（§4-G，64700 红，13/14 实例 oracle 失配）证明这条不是纸上推理。

### 2.2 为什么"字节流一模一样"（设计要点）

* 满字路径：`xs_word8(tx_lfsr)` 与逐字节路径是**同一组映射**（`M^0..M^7` 的字节行），LFSR 同拍推进 `xs_next8 = M^8`
  （两函数在本文件 `ifdef P7B_10G` 块里，**逐字未改**，与 `rtl/app_udp_pattern.v` 的同名函数逐字节相同）。
* 尾字路径：整字分支只在 `need_a == 8` 时命中 ⇒ 尾字（<8B）**结构性**走原逐字节路径。
* 判据采样点未动（见 (a)）；`seg_sent/remain/stat_tx_bytes/stat_tx_frames` 的推进口径一字未改（消费拍推进）。
* 坏帧：整字分支自己带 `bad_frm ? 0xA5… : xs_word8(tx_lfsr)` + `if (!bad_frm)` 冻结 LFSR（与逐字节路径同款）。

---

## 3. 门（`sim/p7b_stagec_a2/run_a2_gate.bat`，跑 7 次）

**TB 设计要点（值得复用）**：两个构建吞吐差 ~10×，**事件不能按绝对拍号驱动**（否则两次跑落在完全不同的帧相位、dump 不可比）。
本 TB 的每条事件都是 `(计数器 == K) && m_tvalid && m_tready …` 的**组合脉冲**（按 DUT 可见的 beat 对齐）⇒ 两个构建在**同一逻辑点**经历同一事件。

| 实例 | 配置 | 覆盖 |
|---|---|---|
| `u_s0..u_s7` | 段长 `{1,4,7,8,9,63,1472,1500}`，`TX_BYTES` 非段整数倍 | 非 8 倍数 / 恰 8 倍数 / 全尾字 / >8 倍数大段 |
| `u_tx0` | 33000B / 1460，恒 ready | 拍/帧测量（帧 2→22 差分） |
| `u_bad` | `i_bad_frame=3` | 2000B 超长 ⇒ RTL 丢弃 + LFSR 冻结 + 图案流连续（2000 = 250×8，全整字） |
| `u_bp` | 伪随机 `m_tready`（寄存器化消费者） | AXIS 保持合同 + "装载与消费同拍那一拍消费者必须采到旧值" |
| `u_evd` | `ev_down` 落在第 100 个 payload beat 那拍 | W3 收尾（closing） |
| `u_evr` | `ev_down` 落在 frame2 opener 拍 + `ev_up` 落在收尾拍 | `ev_restart`/`rst_close`（换流） |
| `u_tok` | 第 50 个 payload beat 后 `app_tx_ready` 掉 → 静默 40 拍 → 恢复 | `frm_wait` 暂停再续 |

每实例都做 5 类判据：① 交付字节流 dump ②每帧字节数 dump ③**TB 自己的 xorshift 模型逐字节 oracle**
④AXIS 保持合同（`tvalid&&!tready` 期间 `tdata/tkeep/tlast` 必须不变）⑤`stat_*` 与 TB 逐 beat 记账对账
（⇒ "没有任何 beat 被消费两次/漏消费"）。拍/帧读数落 `rate.txt`（**唯一允许两个构建不同的量**），
**判据本身在 TB 内**（`` `ifdef P7B_10G `` 期望 190 / 否则 1828）。

**本门抓到的 TB 自身两个坑（登记，别重复踩）**：
① `tkeep[7]` 对应 `tdata[63:56]`（lane0 = keep 的**最高位**）—— 按 `keep[li]` 取 lane 会整体错位一字，症状是"oracle 全红而两个构建同红"（**同红 = 先怀疑 TB**）；
② `i_bad_frame=N` 时坏帧是**第 N+1 帧**（RTL 在"第 N 帧收尾"那拍装载 `bad_frm`，作用于下一帧）—— 见 §6-①。

---

## 4. 逐门读数

### 4.1 正例（A/B）

```
A default  RC=0   拍/帧 = 1828 (opener→opener 与 tlast→tlast 都是 dcyc=36560/20)
B P7B_10G  RC=0   拍/帧 =  190 (                        都是 dcyc= 3800/20, 余数 0)
[PASS] byte-equivalence: A vs B identical on 29 dump/stats files
```
非空性证据：`d8.hex` 68062 字符（≈33000 B）、`d9.hex` 16500（≈8000 B）、`f*.txt` = 14 实例的每帧字节数表。

### 4.2 负对照（每个都给"红在哪条判据"）

| 变异 | 内容 | 红总数 | **红在哪** |
|---|---|---|---|
| **C = m1** | 撤前瞻（`sent_a = seg_sent`） | 216 | 3×oracle + 8×`frame count == 算术模型` + 8×`stat_tx_bytes == TX_BYTES` + `u_tx0` 4 条读数 —— **字节流/帧长真错**（`d0/d8.hex` 与 A 不同） |
| **D = m2** | 收尾改用前瞻 `need_a`（设计件写法 = 父 agent 的"坑 1"） | 3641 | **12/14** 实例 `stat_tx_frames == TB 帧数` 失配 + 11×算术模型 + `u_tx0/u_bad/u_evr` 帧长读数 + 大量 payload/坏帧字节失配 —— **多出 0 字节帧、帧边界错位**（`f9.txt` = 1460/1460/**0**/2000/…） |
| **E = m3** | 整字装载 `xs_next8 → xs_next` | 77017 | **11/14** oracle（`u_s0`（seg=1，从不走整字路径）与另外 2 个不红 = 一致性自证）—— 字节流从第 2 个字起全错 |
| **F = m4** | 撤 `asm_go` 放宽（= A1 形态：2 拍/字） | **2** | **只有 `cycles/frame (A2) == 190` 两条**；**29 个文件与 A 逐字节相同** ⇒ 拍/帧门有牙（时间变、字节不变） |
| **G = m5** | 填充/装载用非前瞻 `need` | 64700 | **13/14** oracle ⇒ "尾字起始拍多填 1 字节 + LFSR 多推 1 步 = 整条流偏移" **被证实**（只有 `seg=1` 那个实例不红，它压根没有满字） |

`A2-GATE: PASS`（全 7 次跑的 RC 与文件对比都符合预期；日志 `sim/p7b_stagec_a2/gate_out.txt`）。

---

## 5. 机器证明 + 回归

* `apply_a2.py`：**5 处锚点各断言命中恰 1 次**；**宏关预处理输出与基线逐字节相同**（25386 字符，`pp()` 极简预处理器）；
  宏开时 +246 行且新线网（`a2_ldw/need_a/sent_a/pw_take/a2_hold`）都在。`--check` 可离线复核（不写文件）。
* **RX8 回归**（我自己目录里重跑 Stage B 的门，不动 Stage B 的目录）：
  `tb/tb_app_rx8_equiv.v` + A2 后的 `rtl/app_pattern.v`，宏关/宏开各一次 ⇒ **两跑都 `TB_APP_RX8_EQUIV: OK`**，
  且 `rx8regB` 的 8 个文件（`dump_tx.hex/dump_tx.frm/acc_w*.txt/stats.txt`）与 `sim/p7b_stageb_rx8/runB/` 记录 **逐字节相同**（`rx8regA` 同 `runA` 一致）
  ⇒ **A2 对 RX 8 路零扰动**（含 RX8 TB 顺带 dump 的 TX 流）。RX 拍/段读数：默认 1643.000 / A2 构建下 187.000（与 Stage B 一致）。

---

## 6. 诚实登记：**没证明的**、**未覆盖的**、顺手发现的**既存现象**

**未测/未做**
1. **无构建**：面积/时序/DRC 一律**未测**。估计（**只是估计**）：新增 ≈ **50–120 LUT、+0 FF、0 BRAM**（2 个 12 位加 + 6 个线网 + 一个 64 位 mux 级；`xs_next8/xs_word8` 是 Stage B 已有的），
   数据面域 WNS 现状 `+0.006`（Stage B 后）⇒ **必须由一次构建收口**（本 agent 无构建权限，未跑）。
   结构风险面：`a2_ldw/asm_go` 多带一项 `m_tready`，即 `tcp_tx_frame.s_axis_tready → axis_pipe → asm_go` 这条**跨模块新路径**（GAP9 §5.2 已点名）。
2. **端到端（下行 Gbps）未测**：`190` 只说明 app 单独不再限速；端到端仍由 `tcp_tx_frame`（**另一支 agent 的乒乓**）决定。
   按 `P(c)=197+182c` 的模型：`c=1 ⇒ 379 拍/帧 = 4.80 Gbps`（**模型值**）；两刀齐 ⇒ 193 拍 = 9.456 Gbps（**模型值**）。
3. **未覆盖的角落**：`ev_up` 恰好落在"整字预取/填充拍且 `seg_sent==0`"（即 `asm_go==1` 的实时换流拍）。
   `a2_hold` 按构造让它回落默认行为，但**本门没有一条激励打在那里**（按 beat 对齐的激励打不到"恰好那一拍"；
   打进去还需要给 TB 建一个"预存在 `seg_sent` 被消费块覆盖"的模型）。⇒ 登记为**未测**。
4. **未跑**旧 p5 系列门（`run_tb_p5_app/adv/fc/flow/multi/…`）：它们会写进其它 stage 的目录，且不在本任务范围内。P4 矩阵 manifest 不含本文件（Stage B 已实测 0 命中）⇒ 跑了也没有判别力。

**顺手发现的既存现象（⛔ 都不是 A2 引入；两个构建/两个方向上一致）**
1. **坏帧注入是"第 `i_bad_frame+1` 帧"**：`bad_frm` 在**第 N 帧收尾**那拍装载、作用于下一帧。
   证据：逐拍 trace（默认构建，`TX_BYTES=6000/SEG=1460/i_bad_frame=3`）第 4 个 tlast beat 的 `seg_len=2000, bad_frm=1`；
   且每帧字节数 = `1460,1460,1460,2000,1460,160`。文件头注释写的是"第 N 个 app 帧" ⇒ **注释与行为差一**（**未改**，本任务只做吞吐）。
2. **`dbg_lfsr` 端口声明是 `[31:0]`**（模块内按 64 位赋值）⇒ 高 32 位被截断；外部 TB 若把它接 64 位 wire，上半会读到 `zzz…`
   （我踩过一次：一度以为 LFSR 有 Z，实际是端口位宽）。**既存、与 A2 无关，未改**。

**方法学登记（供复核）**
- 事件对齐 = beat 对齐（见 §3）；**"两个构建同红" 第一反应应是 TB 的模型错**（本轮真实发生：lane↔keep 位序）。
- 本轮所有 "等价" 结论都是**文件对比**（`fc /b`/`cmp`）+ **TB 内 oracle**，不是措辞。
- 单次 `xsim` 红不作为证据：本轮所有红都复现过 ≥2 次（A/B 各自重跑一致），且与本机并发的 `sim/p7b_stagec_tx/`（另一支 agent）无相互干扰。
