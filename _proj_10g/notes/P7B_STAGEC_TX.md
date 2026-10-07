# P7b Stage C —— `tcp_tx_frame` 乒乓（`TCP_TX_OVL`）+ A2 （**实施报告**）

- 日期：**2026-10-07**（REV2 = 对抗审查 `P7B_STAGEC_TX_REVIEW.md` 的 B1/B2/B4/B5 修完后重写）
  仓库 `D:\repo\XCKU5PMini\udp_hls_10g`，起点 HEAD **`46b2f68`**。
- 性质：**实施 + 门 + 读数**。只改：`rtl/tcp_tx_frame.v`、`rtl/app_pattern.v`（A2，**另一支 agent** 完成，见
  `P7B_STAGEC_A2.md`）、`tb/tb_tcp_tx_ovl.v`（新）、`tb/tb_integ_app_tx.v`（新，REV2）、
  `sim/p7b_stagec_tx/**`（新）、本文件。
  ⛔ **未碰**：`rtl/app_ctrl.v` / `board/**`（含 `build_p7b_ku5p.tcl`，宏由协调者加）/ `README.md` /
  `P7B_HANDOFF.md` / `udp_hls_10g/CLAUDE.md` / `PORT_NOTES.md` / `P7B_BIZ_PLAN.md` /
  `P7B_TX_PINGPONG_FIX_*.md` / `sim/p7b_stagec_tx_review/**`（审查件，只读引用）。**未烧板**
  （`0x08` 一字未写）；**未跑构建**；**未做任何 git 写操作**。
- ⚠️ **REV2 的诚实声明**：REV1 的"B 全绿"与"M-C6 未证"都已作废 —— 见 §0 第 5/6 条与 §1.3/§2.4。

---

## 0. 结论（先给要点）

| # | 项 | 结果 |
|---|---|---|
| 1 | **乒乓落地（宏 `TCP_TX_OVL`）** | ✅ 2100 个数据帧全绿；`rtl/tcp_tx_frame.v` **+823 / −1**（`git diff --stat`），默认分支逐字保留 + **1 处声明过的缺陷修复**（F1，见 §1.3） |
| 2 | **拍/帧（T8）** | ⭐ **RX 引擎 189 拍 / TX 引擎 191 拍 / 满长帧帧周期 191 拍**（1060 / 1114 个样本）——与设计件 §6.1 的 **189 / 191 逐数吻合** |
| 3 | **收发重叠（乒乓的结构性定义）** | 48%（RX 在飞期间 TX 也在飞）vs **退化单 bank 的 4%**（变异 H ⇒ 该判据有牙） |
| 4 | **门** | `TX_OVL_GATE: PASS`：A（现役串行）/ B（乒乓）双绿；**10 个变异全按预期变红**；**F1 负对照三臂**（P=现役 NOFLOOD / Q=`mut_f1` FLOOD / R=串行 NOFLOOD）；**集成门两臂**（S=真 app→真帧器 OK / T=+变异 红）|
| 5 | ⭐⛔ **F1（阻断级真缺陷）已修** | 控制帧帧首预留的 `+1` 可让 `rb_snd_nxt` **越过** `retx_hi` ⇒ `ring_delta` 32 位下溢成 `0xFFFFFFFF` ⇒ 伪 `ring_start` ⇒ **G9 类自持重放洪水**（每次 1460 B）。**两分支同修**（默认分支也中招 —— 审查 arm D 实测）。见 §1.3 |
| 6 | ⭐ **M-C6 已证（有牙）** | 审查给出的"槽内 FIN 已预留未发 + 窗口内拉 `retx_req`"激励**已收进本门**：现役 RTL `servedwhile=0 / gated=1160`；`mut_c6` ⇒ `payload=7` 红。见 §2.4 |
| 7 | ⭐ **B5 同批集成门** | 真 `app_pattern(P7B_10G)` → 真 `tcp_tx_frame(TCP_TX_OVL)`：**719 帧 / 1 MB 载荷逐字节 = app 的 xorshift64 序列**（`payload=0`），`前沿推进 == app.stat_tx_bytes`（**逐字节守恒**），重放段同判据 ✅。见 §2.5 |
| 8 | ⭐ **门抓到我自己的一个真缺陷（REV1）** | `ring_eval` 漏 `!bank_rdy[rx_bank]` ⇒ 重放写进**正在被 TX 发送的 bank** ⇒ 帧被截断/混拼。已修。 |
| 9 | **不确定 / 未证** | 面积/时序**零读数**（不许碰 `board/`）；**T11 真 wrapper 全链门未跑**；F1 事件**板上不可见**（登记为静默类，见 §1.3-③）；集成门不覆盖真 `tcp_rx`/`app_ctrl`；`rx1460_min` 集成档 194 ≠ 主门 189（差 = app 字流气泡，未逐拍归因）。逐条见 §5 |

---

## 1. 改动

### 1.1 `rtl/tcp_tx_frame.v`：新增 `` `ifdef TCP_TX_OVL `` 分支（`:204` … `:1008` 的 `else`）

sha256 **`1a1f04397335a8d2c5d3b606bf91ea7796d688d3583046dab590df5d8039789a`**（118,054 B，1979 行）。

| 部件 | 落点 | 内容 |
|---|---|---|
| RX 引擎 4 态 | `:830-875` 区 | `RX_IDLE`（收帧 + 服务）· `RX_RING`（重放读 ring）· `RX_FIN`（5 拍收尾）· `RX_FLUSH`（中止冲洗） |
| TX 引擎 5 态 | `:995-1005` 区 | `T_IDLE/T_HDR/T_PAY/T_TAIL/T_DONE`；头字布局 / 尾字优先级 / 欠载防御**逐字照抄**默认分支 |
| 载荷 FIFO ×2 | `:560-580` 区 | 两个 `fifo_sync #(.W(73),.D(256),.AW(8))`；`ovf_pulse` 接出为 `dovf_a/dovf_b`（J10 哨兵） |
| 每 bank 上下文 304 bit | `:330-341` 区 | `f_seq/f_ack/f_wnd/f_doff/f_sport/f_dport/f_idcap/f_tcplen/f_totlen/f_ipcsum/f_tcpcsum/f_plen/f_conn/f_dmac/f_dip` |
| **FIX-1** 推进写 | `:436` / `:443` | `upd_wr_data = (rx_state==RX_FIN)&&(fin_cnt==3'd0)`；`upd_val = f_seq[rx_bank]+f_plen[rx_bank]` |
| **FIX-2'** 控制帧预留 + 组合校验和 | `:445` / `:522-529` / `:780-795` 区 | `upd_wr_ctrl = start_ack && (aq_syn|aq_fin|aq_rst)`，`upd_val = rb_snd_nxt+1`；TCP 校验和 = 组合树 |
| **双旗** | `:343-344` 区 | `ctrl_slot_busy ∈ [start_ack, 该帧 T_DONE]`；`ctrl_tx_pend ∈ [start_ack, 该帧启动拍]`（TX 帧边界仲裁键） |
| **回卷门** | `:429-432` 区 | `svc_x = svc && !ctrl_adv_inflight` |
| **FIX-4** 统一门 | `:413-435` / `:460-470` 区 | `rx_idle = (rx_state==RX_IDLE) && recv_first`；`s_axis_tready` 两子句 + `start_data` 同门（坑 10） |
| **FIX-3** 冲洗目标 | `:872-878` 区 | 只冲 `rx_bank` |
| **FIX-5** 重放落点 | `:830-838` 区 | `RX_RING` = 同一个 RX 引擎的第 4 态 |
| ⭐ **F1 修复（REV2）** | `:479-493`（OVL）/ `:1131-1145`（默认） | `retx_ovf` + `ring_start` 追加 `!retx_ovf`（§1.3） |
| ⭐ **F1 事件计数（REV2）** | `:375-376` / `:671` / `:697-698`（**仅 OVL 分支**） | `stat_retx_wrap`（上升沿计数）+ `retx_ovf_p` |

**机器证明（`sim/p7b_stagec_tx/apply_ovl.py`，可复跑 `--check`）** —— ⚠️ **REV2 口径已变**：
`P1` 宏关预处理输出 == **（纯基线 + 声明过的 F1 修复）** 逐字节相同（1154 行）；`P1b` 与**纯基线**的 diff = **恰好那 8 行**
（1 行删除 + 8 行新增，逐行打印，断言 `added == FIX_NEW`）；`P2` 0 deletions（+814 插入）；
`P3` 三个锚点各命中恰 1 次。
⇒ **"宏关 = 回到今天 + 这一处已声明的 bugfix"是证明，不是声称**；旧口径（"宏关 == 纯件逐字节"）**已作废**。

### 1.2 `rtl/app_pattern.v`：A2（**另一支 agent 交付**，本件不重复其证据）

`+72/−0`，sha256 `0e804099…d81ce06`；**实测 190.00 拍/帧**（默认 1828，×9.62）；A/B 29 文件 `fc /b` 逐字节相同；
5 个负对照全有牙。原件 `P7B_STAGEC_A2.md`。

### 1.3 ⭐ F1：一个**既存潜伏缺陷**（不是本刀引入）—— 把它从 ≤2 拍窗口抬到 ≥124 拍后暴露

**机理（审查 B1 逐行验证，本件独立复现）**：`svc` 在**空闲会话**上开一次 `rewind=0` 的重放会话
⇒ `retx_hi := rb_snd_nxt`；会话因 D4 的 bank 门而**活得比预期长**；此时 `fin_push`（扫描支路，**不看 bank 门**）
把 FIN 推进 `ackq`；`start_ack` 同拍弹条目并**预留 `+1`** ⇒ `snd_nxt = retx_hi + 1`
⇒ 下一次 `ring_eval` 的 `ring_delta = retx_hi − snd_nxt = 0xFFFFFFFF`，而判据只测 `!= 0`
⇒ **伪 `ring_start`**、`plen_preset = 1460`（无符号比较恒真）⇒ **每次发 1460 B 的陈旧字节且 `snd_nxt` 继续前进**
⇒ **自持洪水**（审查实测：12000 拍内 61 个多余帧）。

- **修复（两分支都改）**：`ring_start` 追加**回绕安全的"正 delta"**门
  ```verilog
  wire retx_ovf = (rb_snd_nxt != retx_hi) && ((rb_snd_nxt - retx_hi) < 32'h8000_0000);
  wire ring_start = ring_eval && (ring_delta != 32'd0) && !retx_ovf && scan_estab;
  ```
  语义：`snd_nxt` 被 `+1` 预留越顶时**不再起重放**，会话改走**排空支收尾**（1 拍气泡后 `retx_active<=0`）。
  ⚠️ **越顶本身是合法的**（`+1` 预留确实可以越过 `hi`）⇒ 只禁"越顶还起重放"，不禁越顶。
- **读数（审查自己的 flood probe，`sim/p7b_stagec_tx/probe/`，逐字收编 = 本门的 P/Q/R 三臂）**：

  | 臂 | 对象 | 修复前 | 修复后 |
  |---|---|---|---|
  | A/P | 现役 OVL RTL | `frames=64 data=63 replay_after_2=61`（洪水） | **`frames=3 replay_after_2=0`** |
  | Q | `mut_f1`（撤修复） | — | **`frames=64 data=63 replay_after_2=61 snd_nxt=000251a9`**（洪水复现 ⇒ 判据有牙） |
  | C/R | 默认串行 RTL | 无洪水 | 无洪水（`frames=2`） |
  | D | 默认 HEAD（插入前） | **也洪水**（审查实测） | — |

- ③ **板上为什么看不见它（必须登记）**：`stat_retx` 只记**回卷次数**（洪水里每会话只回卷一次）；
  洪水的推进写**全是前向的**（`snd_nxt` 单调增）⇒ 影子账本/`seq_mono` 都不响；
  `stat_eend`/`ovf` 也不动（bank 门从来不是问题）。⇒ **这是一个"计数面盲区"缺陷**。
  已在 OVL 分支加**内部**事件计数器 `stat_retx_wrap`（上升沿计数，TB 读 `u_dut.stat_retx_wrap`；
  B 档实测 `wrap_ev=84`，`overtop_cyc=1481`）——
  ⚠️ **它没有接到快照面**（要接必须改 `board/wrapper_p4.v` + 扩观测窗口，本轮禁止）⇒
  **登记为 "silent class"（静默类）**：板级不可见，只有仿真门能看；下一轮的接口工作 = 把它接进快照（吃 WNS 余量）。
  ⛔ **不许**把这条读成"板上已验证 F1 不再发生"。

---

## 2. 门

**一行复现**：
```bash
cd /d/repo/XCKU5PMini/udp_hls_10g && cmd //c 'sim\p7b_stagec_tx\run_tx_ovl_gate.bat'   # 末行 TX_OVL_GATE: PASS
```

| 文件 | 作用 |
|---|---|
| `tb/tb_tcp_tx_ovl.v`（1265 行） | 主门：快照/判据主体（A..L + P/Q/R 共 15 臂） |
| `tb/tb_integ_app_tx.v`（576 行，REV2） | **B5 同批集成门**：真 app → 真帧器（S/T 两臂） |
| `probe/tb_flood_probe.v` | 审查 flood probe **逐字收编**（只加 3 处：模块改名 / 2 行判决串 / 出处注释；`diff` 可复核） |

**主门 TB 的独立 oracle**：J1 帧结构 · J2 **从线上字节独立复算 IP/TCP 校验和（含伪头）** ·
J3 **载荷逐字节**（无状态字节函数 `fb(流偏移)`；重放用同一偏移 ⇒ 幂等）· J4 seq 连续性四分类 ·
J5 影子账本（从写口逐拍重建）· J6 控制帧守恒 + 看门狗 · J7 `$onehot0` 三写源 · J8 `pend ⊆ busy` ·
J9 会话有界 + 覆盖记账（口径见 §2.4）· J10 两个 bank FIFO 的 `ovf_pulse ≡ 0`。

### 2.1 整门（A=现役串行 / B=乒乓 / C..L=变异 / P/Q/R=F1 负对照 / S/T=集成）

| 案例 | RC | 红在哪条判据 | 备注 |
|---|---|---|---|
| **A** 默认（现役串行 RTL） | **0** | — | 400 帧，J1–J5/J10 全 0 ⇒ **S0：门在已知正确件上全绿** |
| **B** `-d TCP_TX_OVL` | **0** | — | 2100 帧，所有判据 0，见 §2.2 |
| **C** M-S0a：推进写值少一帧 | 1 | `seqmono=11` | 灵敏度证明（OVL 侧） |
| **D** M-S0b：同类，打在**默认分支** | 1 | `seqmono=10` | 灵敏度证明（现役 RTL 侧） |
| **E** M-C1：控制预留与数据推进**同拍** | 1 | **`onehot=2101`（唯一红灯）** | 判据最纯 |
| **F** M-C7：撤 `start_ack` 的 `!ctrl_slot_busy` | 1 | `csum=13`+`payload=2`+`pendbusy=191` | 槽被覆盖 ⇒ 帧头混拼 |
| **G** M-C9：仲裁键改回 `ctrl_slot_busy` | 1 | `parse=280` | 控制帧自重发 ⇒ T4 守恒 + 帧流畸变 |
| **H** M-C3：乒乓退化单 bank | 1 | **`overlap=4% < 25%`（结构性判据）** | 帧周期 min 抓不到它 ⇒ 结构性判据必要 |
| **I** M-C2：预留写寄存 8 拍 | 1 | `seqcont=1`+`seqmono=1` | 设计件称必红两族 ✓ |
| **J** M-C6：撤回卷门 `!ctrl_adv_inflight` | **1** | `payload=7` | ⭐ **REV2：不再算缺口** —— 激励 = 审查构造（§2.4） |
| **K** M-C8：撤 `start_ack` 的 `rx_idle` | 1 | `seqmono=80` | 控制帧在收帧期装载 |
| **L** M-C4：**会话自锁**（排空支不清 `retx_active`） | **1** | `stuck=1`（+ T5 见证红） | ⭐ REV2 新增；`stuck` 判据因此有牙（§2.4） |
| **P** F1 负对照：flood probe vs 现役 OVL | **0** | — | `FLOODPROBE: NOFLOOD`（`frames=3`）|
| **Q** F1 负对照：flood probe vs `mut_f1` | **0** | — | `FLOODPROBE: FLOOD`（`frames=64 replay_after_2=61`）⇒ **判据有牙** |
| **R** F1 负对照：flood probe vs 默认串行 | **0** | — | `FLOODPROBE: NOFLOOD` |
| **S** 集成门：真 app → 真帧器 | **0** | — | `TB_INTEG_APP_TX: OK`（§2.5）|
| **T** 集成门 + M-S0a | **1** | `payload=718` + `J5 守恒` | 集成门有牙 |

（P/Q/R 的 RC 口径：`:runp` 命中**期望判决串**时返回 0 —— Q 期望 `FLOOD`，故 RC=0 才是通过。）

### 2.2 B（乒乓）关键读数（`sim/p7b_stagec_tx/runB/xs.log`）

```
FRAMES recv=2443 data=2100 ctrl=343 dead_skip=3 cyc=356268
COV frames=2100 replay_sessions=23 replay_frames=67 conns=4 plen0=265 singlebeat=802 ctrlblock=9196 rewinds=23
MINGAP handoff_to_next_start=1 finmin1_hits=721 advwrite_to_next_start=5
CYCRX min=6 avg_milli=119046 n=2032    CYCTX min=8 avg_milli=105950 n=2100   FRAMEPERIOD min=8 n=2099
OVL F1 overtop_cyc=1481 wrap_ev=84 delta_red=0 cyc_red=0 cov_aborts=89 cov_cdadj=2070 ctrlblk_real=9196
OVL C6 wins=14 req_win=1168 gated=1160 grant_in_win=0 servedwhile=0_chk_red_0
OVL wsrc data=2101 ctrl=15 rew=23 pendclr_wrong=0 ovf=0 issued fin/rst/syn=4/1/10
REDS parse=0 csum=0 payload=0 seqcont=0 seqmono=0 ctrl=0 ctrl_to=0 onehot=0 pendbusy=0 replay=0 stuck=0 ovf=0 ackf=0
REDS2 replay_gap=11 below_una_during_retx=25 replay_tail_short=7 (info) F1_ring=0 J9=0
T8 rx1460 min=189 n=1060 (expect <=190)  tx1460 min=191 n=1114 (expect <=192)
T8 fp1460 min=191 (expect <=200)  overlap=48/100 of RX-inflight (120721/250256)
```

**覆盖见证（T5，缺一条即整门作废 —— 现已全部变成硬断言）**：`frames=2100 ≥ 2100` ✓ ·
`replay_sessions=23 ≥ 5` ✓ · `conns=4 ≥ 3` ✓ · `plen0=265 ≥ 1` ✓ · `singlebeat=802 ≥ 1` ✓ ·
`ctrlblock=9196 ≥ 20` ✓ · **`cov_ctrlblock_real=9196 ≥ 1`** ✓（REV2 加 `rx_idle` 项：原 `ctrlblock` 是**超集**，
可能盖住"`rx_idle` 不成立"的拍）· **`cov_aborts=89 ≥ 2`** ✓（中止帧，REV2）·
**`cov_cdadj=2070 ≥ 20`** ✓（控制/数据写口相邻拍，REV2）· **`finmin1_hits=721 ≥ 20`** ✓（REV2 起是断言）·
**`c6_req_win=1168 ≥ 1` 且 `c6_gated=1160 ≥ 1`** ✓（M-C6 窗口真被武装，REV2）。

### 2.3 三条硬判据（任务点名的 T4/T5/T9）

- **T4 控制帧守恒**：`issued_*` 与线上帧逐条比对（不等即红，`transmitted > issued` 也红）+ 每条目
  `N=32×260` 拍看门狗。B：`4/1/10` 全中 ✓；G（M-C9）红 ✓。
- **T5 覆盖见证**：见 §2.2，**已全部进 `tot_red`**（REV2）。
- **T9 双旗时序**：`pend ⊆ busy` 每拍断言 + `pend` 清位拍 ∈ `T_HDR` 及之后 + `busy` 期 `start_ack` 被挡的计数。
  B：`pendbusy=0`、`pendclr_wrong=0` ✓；F（M-C7）红 ✓。
- **T8 结构性判据**：`overlap = (RX 在飞 && TX 在飞) 拍数 / RX 在飞拍数`。B=48%，H=4% ⇒ 有牙。

### 2.4 ⭐ REV2 新增判据（审查 B1/B2/B4 点名）与**各自的有牙证明**

| 判据 | 形式 | B 档读数 | 有牙证明 |
|---|---|---|---|
| **F1-①** | 每拍 `ring_start && retx_ovf` ⇒ 红（**delta 下溢当起重放**） | `F1_ring=0` | `mut_f1` + flood probe **Q 臂**：`FLOOD`（61 个重放帧）|
| **F1-②** | `ring_start` 拍上 `ring_delta > 0x7FFF_FFFF` ⇒ 红（**delta 非负断言**，直接量值） | `delta_red=0` | 同上 |
| **F1-③** | 重放期内每拍 `ring_act && retx_ovf` ⇒ 红（**wrap-safe `retx_hi >= snd_nxt`**） | `cyc_red=0` | 同上 |
| **F1 前提取证** | `retx_ovf && retx_active` 拍数 + 上升沿事件数（信息） | `overtop_cyc=1481` / `wrap_ev=84` | 证明"越顶"这件事**真的发生了**（不是空判据）|
| **M-C6** | `svc_rewind && ctrl_adv_inflight` 每拍 ⇒ 红；窗口内 `retx_gnt` ⇒ 红 | `servedwhile=0`、`grant_in_win=0` | `mut_c6` ⇒ `payload=7`；审查探头实测 `rew_=2 / onebyte_seqF=2` |
| **M-C4** | 会话活跃 > 120000 拍 ⇒ `stuck` 红（**每会话一次，早退**） | `stuck=0` | `mut_c4` ⇒ `stuck=1`（判据原先写在"会话结束沿"块里 ⇒ **结构性恒 0**，已按项目教训 #37/#38 改成每拍判据）|
| **J9（B4 口径）** | 会话结束后 **60k 拍**内，该连接**对端前沿**必须达到 `retx_hi`（`exp_new ≥ hi`） | `J9=0`（23 个会话） | 降级口径的理由见 §5-4；"覆盖由构造保证"的形式化见下 |
| **断言化** | `cov_aborts/cov_cdadj/finmin1_hits/cov_ctrlblock_real/c6_*` 全进 `tot_red` | 全达标 | — |

**B4 的口径论证（为什么"会话内覆盖到 `retx_hi`"抓不到的 1–1532 B 短差**不是**缺陷）**：
回卷拍仍在 **bank 里未发送**的那一帧，其字节由 bank 在会话窗口**前后**照常送出（不占会话窗口），
而 `retx_active` 是**全局**旗 ⇒ 无法把"会话期间别的连接的推进写"从会话记账里分离。
⇒ 判据改成**可切分**的形式：**"会话有界终止 + 会话结束后对端前沿追上 `retx_hi`"**——
若存在**真的**覆盖缺口，`exp_new` 永远追不上 `retx_hi` ⇒ J9 红；
而若只是记账窗口的交错，60k 拍内必然追上（B 档 23/23 追上）。
**这条不掩盖真缺口**：真缺口会同时触发 J4 的空洞判据（`seqcont`）与 J3 的载荷判据。

### 2.5 ⭐ B5 同批集成门（`tb/tb_integ_app_tx.v`，S 档读数）

```
FRAMES recv=1708 data=735 ctrl=973 fin=1 cyc=198770
WIRE payload_bytes=1071936 frontier_adv=1048576  DUT stat_frames=1708 stat_bytes=1071936 stat_ack=973 eend=0 retx=3
APP  tx_bytes=1048576 tx_frames=719 badframes=0 mismatch=0
T8   rx1460_min=194 (主门/设计 189; 差 = 真 app 字流气泡)  full_frames=718  ovf_ok=1
T8b  avg_cyc_per_data_frame=270  bytes_per_cyc_x1000=5392
REDS parse=0 csum=0 payload=0 seq=0
REDS2 cons=0 (J5 守恒/J6 静默丢/J7 收尾)
TB_INTEG_APP_TX: OK
```

- **接法**：真 `app_pattern #(.TX_BYTES(1MB), .TX_SEGSZ(1460))`（`-d P7B_10G`）的 `m_axis` 直连真
  `tcp_tx_frame`（`-d TCP_TX_OVL`）的 `s_axis`；`app_tx_ready` 由 TB 按 `app_ctrl.tx_ready_calc`
  （`rtl/app_ctrl.v:557` 的公式）用 **live** TCB 值复算（比板上的 256 拍轮扫**更紧**，不会放松门）；
  `ev_up` 在建连完成后脉冲；`close_req` 由 TB 转 `fin_req`（app_ctrl 的角色）。
- **J3 的 oracle 独立性**：期望图案由 TB **按 app 头注释的 xorshift64 递推预生成 1 MB 查表**
  （种子 `0x9E3779B97F4A7C15`，`取 s[31:24]`，**先取后推进**），**不调 app 内部函数、不读 app 状态**；
  `seq → 偏移`由**线上第一帧的 seq** 锚定（不看 TCB、不看 ISN）。`exp_b[0..3] = 7f 0b 02 e5`。
- **读数含义**：719 个 app 帧 + 16 个重放帧（`retx=3` 个会话）全 1 MB 载荷**逐字节**等于 app 图案
  （`payload=0`，重放帧同样按偏移判定）⇒ **"帧器重放的是真 app 数据"这一格被覆盖**；
  `前沿推进 == app.stat_tx_bytes == 1048576` **逐字节守恒**；DUT 自报 `stat_bytes` 与线上一致；
  `eend=0`、两 bank `ovf_pulse` 恒 0；`fin=1`（close_req 闭环）。
- ⚠️ **登记**：`rx1460_min=194` ≠ 主门 189（+5 拍）。差的一拍级归因**未做**（app 的帧首空字 + A2 预取让位；
  TB 侧 ACK 与数据交错）。**不许**把它读成"帧器退化"或"已达设计值"。
- ⚠️ **覆盖边界**：单连接（槽 0）单向；ACK 走 TB 合成的 `rx_upd`（**不含真 `tcp_rx`**）；
  不校验线上 ack/窗口字段（那是主门判据）；`app` 的 RX 校验器未被喂（`mismatch=0` 是空判据）。
- **有牙**：**T 档**（集成 TB + `mut_s0a`）⇒ `payload=718`、`前沿推进=2920 ≠ 1048576`、cons=2 ⇒ 红。

---

## 3. T1–T12 逐条

| # | 结论 | 依据 |
|---|---|---|
| **T1** 写点唯一性 | ✅ | `upd_wr_data` 只有一处定义，条件 = `(rx_state==RX_FIN)&&(fin_cnt==3'd0)`；全分支无第二写点 |
| **T2** seq/内容 oracle | ✅ | B：`seqcont=0 payload=0`（2100 帧 × 逐字节）；C/D/I 变红 |
| **T3** 每拍 `$onehot0`（三源） | ✅ | B：`onehot=0` 且三源触发 `2101/15/23` 全 > 0；E 只红此条 |
| **T4** 控制帧守恒 | ✅ | §2.3；`issued fin/rst/syn = 4/1/10` == 线上；G 红 |
| **T5** 覆盖见证 | ✅ | §2.2 **全部为断言**（REV2 起）；缺一即整门红 |
| **T6** 逐帧校验和 oracle | ✅ | B：`csum=0`（含控制帧组合树）；F 红 |
| **T7** 重放 | ✅（口径见 §2.4） | 会话有界（`stuck=0`，L 档 `stuck=1` ⇒ 判据有牙）；重放内容逐字节正确；覆盖改用 J9 的可切分口径（`J9=0`，23/23）|
| **T8** 拍/帧 | ✅ | **RX 189 / TX 191 / 帧周期 191**（与设计一致）；H 的 4% 证明结构性判据必要；集成档 194 已登记 |
| **T9** 双旗时序 | ✅ | §2.3；并在实测中修掉 `ring_eval` 的 bank 门缺陷（§5-1）|
| **T10** 默认构建等价 | ✅（新口径）/ ⚠️ | `git diff --stat` = **+823/−1**；`P1`（== 纯基线 + 声明修复）与 `P1b`（diff 恰 8 行）机器证明；A 档 400 帧全绿。⚠️ "默认档 380 拍/帧"未单独复现 |
| **T11** 宏开真 wrapper 全链门 | ⛔ **未跑** | 构建脚本不在我的文件所有权内 ⇒ 分支接线只有本门 + `xvlog/xelab` 隐式网判据兜（无 `10-3091/10-2989`、无隐式网）|
| **T12** 构建收口 | ⛔ **未做** | 宏由协调者加（`build_p7b_ku5p.tcl` 禁碰）⇒ **面积/时序一个数都没有** |

---

## 4. 与设计件（`P7B_TX_PINGPONG_FIX_DESIGN.md` REV3）的**偏差**（逐条）

| # | 设计件 | 本实现 | 为什么 |
|---|---|---|---|
| D1 | 每 bank 上下文 308 bit | **304 bit**（无 `is_*`） | 帧类型由来源结构决定 ⇒ `is_*` 无消费者（省 8 FF）|
| D2 | `flush_pend` 独立 flag | 由 `RX_FLUSH` 状态承载 | 语义等价且更强；少 1 FF |
| D3 | 活帧 IP 校验和在 TLAST 拍算、重放在 S_WAIT 算 | 统一在 `RX_FIN` 末拍算 | 两式等价且不给 TLAST 拍加锥 |
| D4 | `ring_eval && … && !bank_rdy[rx_bank]` | 同（`:423` 区）| ⚠️ 第一版漏了它，被本门抓到（§5-1）|
| D5 | 控制帧 TX 占 8 拍 | 同 | 组合树校验和 |
| D6 | 变异集 `M-C1…M-C9` | 实现了 **11 个**：`S0a/S0b/C1/C2/C3/C4/C6/C7/C8/C9/F1` | `M-C4` 按"会话永不终止"的**后果面**实现（排空支不清 `retx_active`）；`M-F1` 为 REV2 新增 |
| D7 | `cov_data_fin_to_next_start(min_gap==1)` 口径 | 用**交棒拍**→下一帧首拍；另量"推进写拍→下一帧首拍"= **5 拍** | 设计件两套口径并存 ⇒ 两个都量 |
| **D8** | （无）| ⭐ **等价规则变更**：宏关 == **纯基线 + F1 修复**（不再声称"== 纯件逐字节"）| F1 是**既存**缺陷（默认分支同样中招）⇒ 修复必须落两分支；`P1b` 逐行证明 diff 恰为该 8 行 |
| **D9** | （无）| ⭐ 主 TB 的 F1 判据**在 `mut_f1` 下不红**（主 TB 流量形态凑不出 `ring_eval ∩ 越顶` 同拍）⇒ 有牙的负对照由 **probe Q 臂**提供 | 如实登记：**不许**把主门的 `F1_ring=0` 读成"F1 已证"——它只是**不变量**，不是有牙判据 |
| **D10** | （无）| ⭐ `stat_retx_wrap` **只在 OVL 分支**（默认分支无此计数）| 快照面接不到（禁改 `board/`）⇒ 登记为静默类（§1.3-③）|

**TB 侧的口径订正（都是"判据本身错"、不是 RTL 缺陷）**：① `ip_len == fpos` 应为 `fpos-14`；
② TCP 伪头漏了目的 IP；③ SYN 消耗 1 个 seq ⇒ 对端前沿须 +1；④ `seq+plen == exp` 是"完整重放到前沿"不是部分重叠；
⑤ "回卷会话内 `snd_nxt < snd_una`" 是**对端迟到的累计 ACK**（真实 TCP 同现象）⇒ 单列
`below_una_during_retx`（B=25，仅信息，不判红）；⑥ **`flags` 用 4 位会静默丢 ACK 位**（bit4）⇒ 分帧改按 `plen` 判；
⑦ ⭐ **连续赋值（`wire`）与阻塞赋值同拍读会落后一个 delta**：`iplen16` 类长度线网在 `tlast` 拍读到的是
**上一拍**的 `fpos`（差一整个末 beat）⇒ 集成门里长度/校验和判据全红、根因却是 TB 自身；
改成 task 内用 **reg 采样**（`flen = fpos`）。

---

## 5. 没能证明的 / 登记缺口（**别当绿读**）

1. ⭐ **本门在实测中抓到我实现里的一个真缺陷（REV1，已修）**：`ring_eval` 缺 `!bank_rdy[rx_bank]`
   ⇒ 重放会写进正在被 TX 发送的 bank ⇒ 帧被截断（线上 `total_len=1500` 而 `fpos=55`）/载荷错。
   证据 = 定向激励下两臂同红；修后 B 全绿。
2. **面积与时序 = 零读数**。宏由协调者加；本件被禁止碰 `board/` ⇒ 设计件估计的
   `≈+1.8–2.1k LUT / +0.4–0.45k FF` **没有实测背书**。⚠️ **本工程铁律：时序必须由一次构建收口** —— 这一格空着。
3. ⛔ **F1 之后的"事件计数"板上不可见**（silent class，§1.3-③）：`stat_retx_wrap` 未接快照面
   ⇒ **不能**用板级读数证明 F1 事件在板上"已不再发生"；只有仿真门（B 档 `wrap_ev=84` + probe 三臂）能给读数。
4. ⚠️ **J9/覆盖的口径仍是"形式化"的**（§2.4）：它抓"真缺口"，但**不能**证明"会话窗口内每一段都被原地重放过"
   —— 后者需要按 `retx_id_r` 切分的**每连接**会话窗口（当前 `retx_active` 是全局旗）⇒ 未做。
5. **T11 真 wrapper 全链门未跑**（文件所有权）；**T12 构建未做**；**任何板级动作未做**（未烧板、未写 `0x08`）。
6. **集成门（S）的覆盖边界**（§2.5）：单连接单向；无真 `tcp_rx`/`app_ctrl`；不校验线上 ack/窗口字段；
   app 的 RX 校验器未喂（`mismatch` 是空判据）；`rx1460_min=194` 的 +5 拍**未逐拍归因**。
7. **`M-C4` 的变异形态**是按"后果面"（会话永不终止）实现的，**不等于**设计件 `M-C4` 的原始描述
   （若原描述另有形态，本件未覆盖）；同时按项目教训 #37/#38 修掉了 `stuck` 判据的
   **"写在会话结束沿里 ⇒ 结构性恒 0"** 形态。
8. **未跑/未测**：真 wrapper 的 `pend ⊆ busy` 跨模块面、`W57/W58` 类快照观察
   （本件不产快照）、TCP 源的"全链 193 拍/帧"（含 `mac_tx_10g`；本件只到帧器自身 191）。

---

## 6. 证据文件（`sim/p7b_stagec_tx/`）

| 文件 | 内容 |
|---|---|
| `run_tx_ovl_gate.bat` | 一行复现入口（纯 ASCII + CRLF，自定位 + 路径守卫；`mut_gen` → A..L → P/Q/R → S/T）|
| `gate_full2.log` | 整门输出（15 臂 RC + 各案 REDS 行 + B 关键读数 + 集成门读数）|
| `runA/ … runT/` | 各臂独立工作目录的 `xs.log`（逐门读数原件）|
| `probe/run_probe.bat` · `probe/tb_flood_probe.v` | F1 负对照（审查 flood probe 逐字收编 + 3 处声明过的改动）|
| `apply_ovl.py` + `ovl_branch.v` + `tcp_tx_frame.v.base` | RTL 插入的机器证明（P1/P1b/P2/P3）与分支源码 |
| `mk_mut_tx.py` + `mut/mut_*.v` | **11 个**变异件（每个 = 1 处改动，脚本断言命中数）|
| `patch_gate_bat.py` / `patch_gate_bat2.py` | 门的补丁脚本（记录改动来源，可复核）|
| `chkA/ … chk_mut_*/ chkI/ chkT/` | 过程中的隔离复跑窗口（TB 调试用；全局 #50 的"孤零一条红先隔离重跑"）|
