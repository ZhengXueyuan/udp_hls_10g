# P7B-WU 修复 —— **对抗审查**（独立复核，2026-10-07）

- 角色：**对抗审查 agent**（默认被审对象是错的，去找它站不住的地方）。交付 = 本文件 + 独立三臂复核台
  (`sim/p5wu_review/`，**只读 `rtl/`、未改 `rtl/`、`board/`、`tb/` 既有文件、未烧板、未提交 git**)。
- 被审对象：`rtl/app_ctrl.v` 的 C6 修复（现盘 :1170-1193）+ `tb/tb_app_wu.v` + `sim/p5wu/run_tb_app_wu.bat`
  + 作者交付笔记 `P7B_WU_FIX.md`（**先读，不当证据**）。
- ⚠️ **环境变更（开工即发现）**：本轮派单写"HEAD 应为 `ff78247`"，但修复**在我读文件的同一分钟内被提交**：
  `git log -1 -- rtl/app_ctrl.v` = **`09d2189`（2026-10-07 01:44:49）**。⇒ 我用作"修复前"基准的文件取自
  **`git show ff78247:rtl/app_ctrl.v`**（1195 行、`WU_LEGACY` 0 次；`3257631` 未动该文件 ⇒ `09d2189^` 同源）。

---

## 0. 判决表（先给结论）

| # | 攻击面 | 结论 | 依据 |
|---|---|---|---|
| 1 | `winq` 小时 `winq/4` 塌到 0 ⇒ 同坑换形式？ | ⛔ **挡不住（发现真问题 P1）**：`winq ≤ 3` 时 `floor(winq/4)=0` ⇒ 武装条件 `wscan < 0` **恒假**（**结构性不可达，与修复前同形**） | 算术 + 我的 PH1 读数：新臂 0 次 / HEAD 1 次 |
| 2 | 整数除法截断 / 滞回区间消失 | ✅ **挡得住（winq ≥ 8）**；⚠️ `4 ≤ winq ≤ 7` 时 `floor(winq/4)=1` ⇒ 武装退化成**恰好 `wscan==0`**（= 修复前那条脆弱条件） | 位选算术 + PH2 |
| 3 | 假触发（健康态多发 wu ⇒ 掉吞吐） | ✅ **健康态挡得住**（实测 0 次额外 wu）；⚠️ **非健康态代价已量化**（每消费 ~15.6 KB 发 1 条）且**多连接下空转连接也会发**（真问题 P2） | 我的 PH5/PH6/PH4 |
| 4 | `wu_mark` / `0x9B` 语义自洽？ | ✅ 自洽；⚠️ 修复后 `wu_mark` **不再参与任何判据**（只剩观测） | `grep`：唯一消费者是 legacy 分支 |
| 5 | `WU_LEGACY=1` 是否"逐字 = 修复前"？ | ✅ **挡得住（独立证实）**：真 HEAD 源码与 `WU_LEGACY=1` 逐拍全等，**0 拍不符**（全仿真 177,654 拍 / 1,421,236 ns、6 个相位） | 我的 E1：`eq_bad=0`（负对照 E2：`new_diff=144935 > 0`） |
| 6 | 与 `tcp_tx_frame` wu 通路的相互作用 | ⚠️ **无法判定（只读分析，无实验）**：见 §4-6 | 静态 |
| 7 | 1G 路径（共享模块）行为是否被改 | ⚠️ **被改（同一份 RTL，无 ifdef）**；健康流实测不受影响（PH6），但**1G 板级无读数** | `app_ctrl` 无 `ifdef` 包 C6；`wrapper_p4.v:1214` |
| 8 | 饱和 / 边界（occ≥winq、winq=0、多连接同时武装） | ✅ 绝大部分挡住（`occ≥winq ⇒ wscan=0` 可武装；`winq=0` 新旧两版**都**不可达 ⇒ 非回归）；⚠️ 多连接同武装 = P2 | 算术 + 作者 P6 + 我的 PH4 |
| 9 | TB 激励代表性（会不会编码错模型） | ⚠️ **部分挡不住**：作者的"危险区模态"是**TB 夹出来的**（`occ ∈ [WINQ-128, WINQ-56]`）⇒ `P1f`（窗永不恰好 0）是**结构自证**、不是对板子的测量；板级事实靠 pcap（有效但是同源） | 读 `tb/tb_app_wu.v:238-246` |
| 10 | 锁步检查覆盖什么/漏什么 | ✅ 够用（漏的几项由我的 E1 补上：25 个信号/拍全等）；**两版 TB 都不含 `tcp_tx_frame`** | 我的 E1/E3 |

**总判**：**修复的方向与实现都成立，且 `WU_LEGACY` 负对照臂确实逐字等价于修复前**（这条我独立证实了，
不是采信作者）。但作者的 §2.1-2 那句"**归一后对任意 `winq` 都可达**"**不成立** —— 只对 `winq ≥ 8` 成立；
`winq ≤ 3` 是**同形不可达且比修复前更差**（修复前能发、修复后不能发）。产品配置（`winq = 池/N`，N ≤ 16 ⇒
`winq ≥ 3072`）**不在**这个坑里。

---

## 1. 我跑的实验（逐字命令 + 原始读数）

### 1.1 复现作者的门（确认工具面/台架可用）

```bash
cmd //c 'sim\p5wu_review\run_author_wu.bat'        # 我自己的 runner (不写作者的 sim/p5wu/run)
```
读数（全文 `sim/p5wu_review/run/xsim_wu.log`）：**P7B WU GATE OK**，与 `P7B_WU_FIX.md` §4 **逐行相同**
（`min=63 max=120 (40 scans)`、`fire#1 wu_mark=24695 @cyc~34850`、`lockstep violation cycles = 0`、
`NEW=3 OLD=1`）。⇒ 作者的读数可复现。

### 1.2 ⭐ 三臂独立复核台（我的主判据）

```bash
cmd //c 'sim\p5wu_review\run_tb_wu_review.bat'     # 自定位; 输出 sim/p5wu_review/runrev2/xsim_out.txt
```
三臂同激励：`u_new`（默认=修复后）· `u_leg`（`WU_LEGACY=1`）· `u_head`（**`app_ctrl_head` = 从
`ff78247` 取出的原文件，仅改模块名**）。判据：E1 `u_leg` 逐拍 === `u_head`；E2 `u_new` 至少一拍 ≠ `u_head`。

原始读数（`WU-REVIEW GATE OK`）：

```
PH0: random walk (occ full range + events + gnt jitter)
  [READ] PH0 stat_wu: new=43 leg=58 head=58
  PASS E1 u_leg === u_head per-cycle (all phases)
  PASS E2 u_new != u_head at least one cycle (comparator has teeth)
  PASS E3 three arms lockstep (rc_id/tick_cnt/scan_id)
  [READ] eq_bad=0 new_diff=144935 lock_bad=0          <-- ⭐ E1 = 0 拍不符
PH1: winq = 3
  [READ] winq[0]: new=0003 leg=0003 head=0003
  [READ] wscan=0: new wu_zero=0 leg=1 head=1
  [READ] PH1 fires: new=0 leg=1 head=1                <-- ⭐ P1: 新臂净损失
  PASS PH1a NEW 0 fires ... PASS PH1b HEAD >=1 fire ... PASS PH1c LEGACY count == HEAD count
PH2: winq = 5 + Zeno hover (win 1..3)
  [READ] PH2 fires: new=0 leg=0 head=0                <-- 小配额下两版都不可达
PH3: winq = 3072 (N=16 pool split, product config)
  PASS PH3a winq=0x0C00 · PH3b armed@wscan=72 · PH3c 1072<1536 => 0 fires · PH3d 仍武装
  [READ] PH3 fires: new=1 head=0; wu_mark[0]=0624 (expect ~061c)   <-- 1572, ∈[1536,1936]
PH4: two connections, conn0 busy / conn1 fully idle
  PASS PH4a 两条都武装
  [READ] PH4 fires: new=2 head=0                      <-- ⭐ P2: 空转连接也发
PH5: oscillation across 3/4 (occ 40000 <-> 20000)
  [DBG] iter0 arm-check: occ=40000 winq0=c000 wz=1 pbws=23c0
  [DBG] iter0 after drain: occ=24400 cycles=15601 wz=1 pbws=0000 statwu=0
  [READ] PH5 fires: new=5 head=0 (5 cycles)
PH6: healthy high-window phase (occ 500..8000, data flowing, 40 scans)
  [READ] PH6 fires: new=0 leg=0 head=0
cumulative: eq_bad=0 (E1) new_diff=144935 (E2) lock_bad=0
WU-REVIEW GATE OK
```

### 1.3 静态核对（不靠仿真）

| 项 | 命令/位置 | 结果 |
|---|---|---|
| 端口面 0 改动 | `git diff`（全文已读） | ✅ 只有 `parameter WU_LEGACY`（:250）+ C6 块（:1170-1193）+ 注释；**端口 0 处改动** |
| 生产路径 = 修复后？ | `board/wrapper_p4.v:1214` `app_ctrl #(.WIN_CAP(WIN_CAP_5)) u_app_ctrl (` | ✅ **命名例化、只传 WIN_CAP ⇒ `WU_LEGACY=0`**；全仓 `grep WU_LEGACY` 只命中 `rtl/app_ctrl.v` 与 TB ⇒ 板级不可能是 legacy |
| `wu_mark` 的消费者 | `grep -n wu_mark rtl/app_ctrl.v`（:1176 唯一判据处 = legacy 分支；:889 init；:725 `0x9B`；:547 dbg；`app_status_uart.v:972` 状态行） | ✅ 修复后 `wu_mark` **纯观测** |
| wu 条目确实会发出 | `rtl/tcp_tx_frame.v:334` `start_ack = (state==S_IDLE) && ack_pend_r && !ackq_empty && !flush_pend`（**无 `rb_state` 门**）；:699-708 `wu_push`/`wu_gnt`；:844/:969 `wnd_r <= rb_rcv_wnd` | ✅ wu 是纯 ACK 条目，窗字段来自 TCB（fc 通路每轮刷新） |
| 新增组合链 | C6 新逻辑 = 17 位比较（~5 CARRY4）+ 已在的 `winq[pb_sid]` 16:1 mux；两端点皆寄存器 | ✅ 不可能成为本模块最差路径（与作者 OOC A/B 一致；**我未复跑 OOC**） |

---

## 2. ⭐ 找到的真问题（含最小反例）

### P1（真问题·边界）`winq ≤ 3` ⇒ 新武装条件**结构性不可达**，且**比修复前更差**

- **机理**：`arm = ({1'b0, pb_wscan} < {2'b0, winq[pb_sid][15:2]})`（`rtl/app_ctrl.v:1184`）。
  `winq[15:2]` = `floor(winq/4)`；`winq ≤ 3 ⇒ = 0 ⇒ 17 位无符号比较 `x < 0` 恒假` ⇒ 永不武装；而
  `winq ∈ {1,2,3}` 时触发侧 `floor(winq/2) ≤ 1`，即使武装也只是"窗=1"这种无意义值。
- **与修复前的关系（反向对照）**：修复前 `wscan == 0` **能**武装（窗口真的关到 0 时）⇒ 窗 0→3 时会发一条。
  ⇒ 这不是"没变好"，是**净损失**。
- **最小反例（我的 TB，PH1，逐字可复跑）**：
  - 激励：`wr_reg(0x0C, 3)`（配额 3）→ `ev_up(0)` → `occ=3`（`wscan=0`，等 3 轮扫描）→ `occ=0`（`wscan=3`）
  - 期望（修复前逻辑）：1 次 wu；**实际**：`new=0 leg=1 head=1`（`PH1a/PH1b/PH1c` 全 PASS）。
- **可达性/严重度（算到底）**：
  `winq = min(wq_cap_r, pool - occ)`（C14-①，`app_ctrl.v:740`）向上又被 C15 补授到 `wq_cap_r`。
  - 产品配置：`wq_cap_r = 池/N`，N = 预期连接数 **≤ 16（槽数是 16，`:422-423`）** ⇒
    `winq ≥ 49152/16 = 3072 ≫ 8` ⇒ **产品路径不在坑里**（我的 PH3 已在 `winq=3072` 上三点验证：武装 72 / 不触发 1072 / 触发 1572）。
  - 要落进坑必须 `wq_cap_r ≤ 3`（app 自己写 `0x0C ≤ 3` —— 配置错误），或"池被别的连接占满 ⇒ 该槽 `winq ≤ 3`"这种**瞬态**
    （池一有余额，C15 下一轮扫描就把它补到 `wq_cap_r`；且 `winq=0` 时新旧两版**都**不可达 ⇒ 那一格不是回归）。
  ⇒ **严重度：低**。但**文档陈述必须订正**：`P7B_WU_FIX.md` §2.1-2 "归一后**对任意 winq 都可达**"、
  `rtl/app_ctrl.v:205` "归一后对任意 winq 都可达" —— **只对 `winq ≥ 8` 成立**；
  `4 ≤ winq ≤ 7` 时武装退化为 `wscan == 0`（= 修复前那条被本修复判定为脆弱的条件，PH2 实证两版都 0 次）。

### P2（真问题·噪声/范围）共享 `occ` ⇒ **空转连接也会发 wu**；`stat_wu` 不再是"真通告"的特异计数器

- **机理**：`fq = max(0, winq[c] - rx_occ_bytes)`，而 `rx_occ_bytes` 是**全局** app RX FIFO 占用
  （`app_ctrl.v:767` 的 `fq_calc`）。⇒ 别的连接把 FIFO 顶满时，**本连接的"窗"也会读成小值** ⇒ 武装；
  全局占用一落 ⇒ 触发 ⇒ **给一个完全没流量的对端发一条纯 ACK**。
- **最小反例（我的 PH4）**：`0x0C = 0xC00`（两条各 3072）；conn0 有流量、conn1 **全程零流量**；
  `occ: 0→3000→1000` ⇒ `PH4 fires: new=2 head=0`（**两条各 1 条**，含空转的 conn1）。
- **代价（量化，我的 PH5）**：一个"塌陷→重开"周期（`occ 40000→24400`，即**消费 15.6 KB**）恰好 1 条 wu
  （`PH5a 5/5`）⇒ 单连接满池下 `wu 率 ≈ 消费率/15.6KB`：板级 app 100–134 MB/s ⇒ **6.4–8.6k 条/s**，
  即 **~0.4–0.6 MB/s 额外线上字节（64 B/条）≈ 10G 线的 0.04%**（作者 §7-#5 估的是 `消费/(winq/2)` ⇒ 我实测的
  有效步长 15.6 KB 比他估的 `winq/2 = 24.6 KB` **小 1.58 倍**（理论下界 = `winq/4 = 12.3 KB`））。⇒ **量级无害**，但：
  ① N 条连接同时振荡时按 N 倍增长（PH4 实证）；② 与 `P5a-0` 记录的"**每段两帧已近对端上限**"这一帧率纪律
  相冲（新增的是**额外帧**，不是替换）；③ `stat_wu`（`0x96`）从此**分不清"真重开通告"与"共享占用噪声"**
  ⇒ 若下一轮把 `stat_wu` 接进快照当 `J6` 的判据，读数会**高估**通告次数。**作者未登记这一条。**

---

## 3. 逐条攻击面（完整版）

1. **`winq/4` 塌 0** ⇒ **挡不住**，见 P1（产品配置不受影响）。
2. **截断/滞回区间**：`winq[15:2]`/`winq[15:1]` 是位选（= 向下取整）；滞回带 = `[floor(w/4), floor(w/2))`。
   `w ≥ 8` 时非空且 ≥ 2；`w = 4..7` ⇒ `floor(w/4)=1`（只在 `wscan==0` 武装，**退化为修复前**）；
   `w ≤ 3` ⇒ 空（P1）。**没有"`winq/2 <= winq/4`"的中间态**（单调）。
3. **假触发**：**健康高窗实测 0 次**（我的 PH6：40 轮 × 2 次采样 = 80 次 slot0 采样、`occ ∈ [500,8000]`、有数据流 ⇒ `new=0/head=0`）；
   作者的门另有 P4c（高窗 20 轮 0 次）。**非健康态的代价** = P2 的量化。⇒ 结论 = 挡得住（有界），
   但"零额外帧"这句话的**前提必须写成"全程 `wscan ≥ winq/4`"**（作者文档已这么写）。
4. **`wu_mark` 语义**：触发时写 `pb_wscan`（= 触发拍采到的窗，实测 PH3 `0624 = 1572 ∈ [1536,1936]`）——
   与 `0x9B`"上次通告的窗口值"一致；**帧里真正的窗字段来自 TCB**（`rb_rcv_wnd`，:844/:969），
   由 fc 通路每 256 拍刷新 ⇒ 两者通常同量级但**不保证相等**（旧语义同病，非本轮引入）。
   修复后 `wu_mark` 无判据角色 ⇒ **没有自指死锁**（作者 §2.1-3 的论证成立）。
5. **`WU_LEGACY` 逐字等价**：**独立证实**（E1 `eq_bad=0`，跨 6 个相位、177,654 拍、25 个信号/拍；
   语料含随机遍历 + 事件 + gnt 抖动 + 5 个定向场景）。**这条不采信作者的"去注释去空白比对"**
   —— 我是拿 `ff78247` 的**真文件**编进去同时跑的。E2 保证比较器有牙（144935 拍不同）。
6. **与 `tcp_tx_frame` 的相互作用**：**无法判定**（我只读源码）。已核实的部分：wu 条目是纯 ACK、
   入队优先级最低（`ack_req > fin/rst > fin_repush > wu`），`wu_push` 排除全部更高优先源且 `gnt = push`
   ⇒ M1 类"gnt 给了但条目没入队"被结构性排除；`start_ack` 无 `rb_state` 门 ⇒ 条目不会被 FSM 状态吞。
   **未做**：wu 与数据 ACK 争用时**发送窗口/窗字段的实测**；wu 条目在拆除竞态下的陈旧发送（旧有风险，非本轮）。
7. **1G 路径**：`app_ctrl` 是共享模块，C6 没有 `ifdef` ⇒ **1G（P5/P6a/P6e 的 APP_MODE 构建）行为同样被改**。
   健康态不受影响（PH6 + 作者的 p5_app `stat_wu=0`），但**1G 板级无读数**；既有 1G 门的判据里有一条
   **硬判据**是 `stat_wu == 0`（`tools/gen_stim_p5_app.py:184`，"健康流零额外 wu 帧"）⇒ 该门是这条修复的
   **真回归面**（作者报了 PASS，**我未独立复跑**）。
8. **饱和/边界**：`occ ≥ winq ⇒ fq=0`（`:584` 饱和）⇒ 可武装 ✅；`occ` 17 位、`winq ≤ 49152` ⇒
   `wscan = fq[15:0]` 不溢出 ✅；`winq=0` 新旧都不可达（非回归）✅；多连接同时武装 ✅（但 = P2）。
9. **TB 代表性**：作者的 TB **把病态模态当输入夹死**（`occ ∈ [WINQ-128, WINQ-56]`，`tb/tb_app_wu.v:238-246`）
   ⇒ `P1f/P1g`（窗永不恰好 0）是**TB 结构自证**，只能证明"**若**板级窗在 56..128，**则**旧条件不可达"这个
   蕴含式；板级事实来自 pcap（2695 条 ACK 无 `win==0`）——**有效，但它与"板子发不出通告"同源**，
   不是独立第三方见证。作者自己在 §7-#3 登记了这点，**我认同且加强**：该 TB 不应被引用为"复现了板上模态"。
   另：TB 的 wu 消费者模型 `gnt = req && gnt_en`（ackq 永不满）与真 `wu_push` 的**优先级排除**不同构
   ⇒ "发了 wu"这一格在 TB 里是**必然**的，在没有 `tcp_tx_frame` 的前提下。
10. **锁步**：作者比较 `rc_id/pa_v/pb_v/pb_sid/winq[0]/fc_wr,id,sel,val`（我复跑 = 0 违反）。漏的：
    `pool/redge/stat_fc_upd/stat_ev_up/winq[1..15]/pb_wscan/rd` —— 我用 E1 全补上（0 不符）⇒ **覆盖够**。
    真正的盲区不在锁步，而在**两版 TB 都不含 `tcp_tx_frame`/MAC**（由第 6 条覆盖不到造成）。

---

## 4. 我没能判定的部分（如实登记，别当已答）

1. **板级零读数**：本行**未烧板、零位流、零 `J6/J15`**。"TCP 上行会回到 app 消费率量级"仍是**推断**。
   我能补的算术：修复要求"**在对端 persist(207.6 ms) 之前把窗从触发点抬到 `winq/2`**"，即 app 需在
   207.6 ms 内消费 `winq/2 - 窗@塌陷`；按 `P7B_BIZ_TCPREG.md` §5 实测的 app 有效消费界 **⊂ (100, 134.2] MB/s**，
   单连接满池需消费 ~24 KB ⇒ **~180–240 µs**（比 persist 快 ~860–1150×）⇒ 机理上应当生效。
   ⚠️ 但这依赖"塌陷后对端停发（不再回灌）"这一条，而该条**只有那一条 pcap 证据**。
2. **全设计时序未复跑**（作者 §7-#2 同）：我只做了结构判断（C6 两端点皆寄存器 + 复用已有 mux），
   **未跑** OOC 综合，**未跑**全设计实现。
3. **既有 1G 门未独立复跑**（并发回归 agent 正在跑官方矩阵，我按纪律用了自己的目录、没去抢 `sim/p5sim`）。
   ⇒ `p5_app` 的 `stat_wu==0` 硬判据、`p5_flow` 的 `wu_mark0=60e0` **都是采信作者**，未复证。
4. **`tcp_tx_frame` 侧未实验**（见 §3-6）。
5. **`winq=0` 的连接**：新旧都不发 wu ⇒ 该槽在池被占满期间"永久零窗"；C15 自愈条件我在代码里核了
   （`winq < wq_cap_r && pool != 0`），但**没有板级/门级读数**。
6. **多连接 `wu` 频率上界**：单连接实测 1 条/15.6 KB；N 连接按 N 倍线性外推（PH4 已见 2 条），
   **未测** N = 16 的情形，也**未测**对端在 10G 帧率下的承受度。

---

## 5. 文件清单（我新增的、独占 `sim/p5wu_review/`）

| 文件 | 内容 |
|---|---|
| `sim/p5wu_review/tb_wu_review.v` | 三臂 TB（E1/E2/E3 + PH0..PH6） |
| `sim/p5wu_review/app_ctrl_head.v` | **`git show ff78247:rtl/app_ctrl.v`** + 模块改名 `app_ctrl_head`（真修复前源码） |
| `sim/p5wu_review/run_tb_wu_review.bat` | 自定位 runner（含坑-24 xelab 面判据；产物在 `runrev2/`） |
| `sim/p5wu_review/run_author_wu.bat` | 复跑作者门的 runner（产物在 `run/`，**不写 `sim/p5wu/run`**） |
| `sim/p5wu_review/runrev2/xsim_out.txt` | §1.2 的原始读数全文 |
| `sim/p5wu_review/run/xsim_wu.log` | §1.1 的原始读数全文 |

**给 TL 的两条建议**：
① 订正 `P7B_WU_FIX.md` §2.1-2 / `rtl/app_ctrl.v:205` 的"对任意 `winq` 都可达" ⇒ 改为"对 `winq ≥ 8` 可达，
`4..7` 退化为 `wscan==0`，`≤3` 不可达（且优于修复前的那一格**不存在**：修复前能发、现在不能）"。
② 若下一轮把 `stat_wu` 接进快照当 `J6` 判据：先登记 **P2**（空转连接/共享占用噪声会计入 `stat_wu`），
否则读数会**高估**"真通告"次数。
