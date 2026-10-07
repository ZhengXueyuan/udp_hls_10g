# P7B-WU 二轮 (P1/P2 + 快照 63 字) —— **对抗审查报告**

- 日期：**2026-10-07**　审查对象：`rtl/app_ctrl.v` (P1/P2) + `board/wrapper_p4.v` (61→63 字) +
  `tb/tb_wu_p1p2.v` / `tb/tb_snap63.v` + `_proj_10g/notes/P7B_WU_P1P2_SNAP.md`（作者笔记）
- 基线 = `95c9485`；被审工作区快照时刻 = **2026-10-07 08:51–08:59**（⚠️ 期间**另有 agent 在改测量脚本**，
  见 §10 的"快照时刻"声明）
- 我自写的门/脚本全部放在 **`sim/p5wu_p1p2_review/`**（独占）；新增 TB 两个：
  `sim/p5wu_p1p2_review/tb_rev_p2_gate.v`（P2 会话边界/残留）、`sim/p5wu_p1p2_review/tb_rev_p1_winq0.v`（winq=0 可达性）
- **未改**任何被审文件；**未烧板、未碰板子**（`0x08` 一次都没写）；**未提交 git**

---

## 0. 一页速查

| # | 攻击面 | 裁定 | 一句话 |
|---|---|---|---|
| 1 | P1 的等价性声称 | ✅ **挡得住**（但一句"净损失消除"**过宽**） | 实现 ≡ `wscan < max(winq/4,1)` **穷举成立**；产品配置逐位不变；**但 `winq==0` 仍不可达**（arm 恒真 ⇒ `else if` 永不求值） |
| 2 | P2 的 `wu_act` | ✅ **挡得住**（两条残留**实测确认**，其中一条比作者写的更差） | 会话边界**实测清干净**（作者 TB 未覆盖）；残留① 削减量 = **0**（不是"压小"）、残留② 实测**不发** |
| 3 | P2 粘滞是否必要 | ✅ **挡得住** | "当拍有进度"会把正主场景排除，论证成立；但"最小修法"的**唯一性未建立**（有一条同代价替代没被讨论） |
| 4 | `W62` 组合派生 / W49 先例 / hold | ⚠️ **部分挡得住**：先例**确是同款**；"无 tearing"**推理正确**；**新 hold 违例 = 无法判定（无构建）**，且**该问的指向本身要改**（应问 setup） | |
| 5 | 窗口装配 61→63 | ✅ **挡得住**（我自写脚本 39 判据 + 2 个变异体负对照） | 旧 26 项**逐项未动**（机器核过）；算术自洽；**但新注释里一道加法算错**（见 §5-F1） |
| 6 | 地址译码 / 回绕红线 | ✅ **挡得住** | 末字 `0x118` / 首个未实现 `0x11C` / 红线仍 `0x200` / `snap_base`(1984+32=2016) 正好贴顶 |
| 7 | `BUILD_ID_V 8→9` | ✅ **挡得住**（RTL 面）；脚本面**部分挡不住**（并发 agent 在我审查期间补上了，见 §10） | |
| 8 | TB 代表性 | ⚠️ **部分挡得住**（相对判别有效、绝对行为未覆盖；判据**计数抄错** 27→26） | |
| 9 | `check_wu_words.py` 第 5 对照 | ✅ **挡得住**（**我重建了它声称的那次假 FAIL**；另用自造变异体证明 3a/3c 有牙） | |
| 10 | 被漏掉的同类面 | ❌ **部分挡不住**：作者的"忘了改会**响亮**失败"**被推翻一半**（`full`/`snap` 路径**静默**）；j6 台架**结构性不读 W61/W62** | |

**真问题 3 条**（都在**注释/声称/台架**层，**没有一条是 RTL 功能缺陷**）：
**F1** 新注释 `wrapper_p4.v:3900` 加法算错（67≠63）；**F2** §1.2 "净损失消除" 对 `winq==0` 不成立；
**F3** §8-① "忘了改会响亮失败" 不成立（`p7b_snap.sh` 的 `full`/`snap` 不查身份 ⇒ 静默漏字），且
**§8-④ "一次 j6-ladder 读数即可把机理升为观测" 在当前台架上不成立**（`tcpreg_j6.sh` 只读 W5/W53/W54）。

---

## 1. 攻击面 ①：P1 的等价性声称

### 1.1 声称的三种读法（都核了）

| 读法 | 内容 | 裁定 |
|---|---|---|
| (a) | 实现 `(wscan < winq[15:2]) \|\| (wscan == 0)` **对任意 (winq,wscan)** 等于 `wscan < max(floor(winq/4),1)` | ✅ **穷举成立** |
| (b) | `winq/4 ≥ 1` 时后项被前项蕴含 ⇒ **相对旧式逐位不变** | ✅ **成立**（差异数 = 0） |
| (c) | `winq ≤ 3` 时"退化为 `wscan == 0` = 修复前的可达性 ⇒ **净损失消除**" | ⚠️ **对 `winq ∈ {1,2,3}` 成立；对 `winq == 0` 不成立** |

### 1.2 实验（逐字命令 + 读数）

```bash
cd /d/repo/XCKU5PMini/udp_hls_10g
/c/Users/zhxue/anaconda3/python.exe sim/p5wu_p1p2_review/rev_p1_equiv.py   # exit=0
```
```
  [PASS] (c) 实现 == 目标语义 (全 winq 0..65535, 每值 38 点)
  [PASS] (d) T>=1 (winq>=4) 时 新式 == 旧式 (差异数 = 0)
  [INFO] T==0 (winq<=3) 时 差异数 = 4  (差异 = 修复点, 预期非零)
  [INFO] 差异仅出现在 winq ∈ [0, 1, 2, 3] ... [0, 1, 2, 3] (共 4 个值)
  [PASS] 产品配置抽样 (winq 3072..65535 步长 7): P1 子改动 0 处行为差
     winq=0      floor(winq/4)=0      arm@wscan=0:True/False
     winq=4      floor(winq/4)=1      arm@wscan=0:True/True
```
方法说明（不是抽样口号）：两个谓词都是 `wscan` 上的**单调阈值谓词** ⇒ 只需比临界点；
我对**全 65536 个 winq** 各取 38 个点（含 `T-1/T/T+1`）逐一比对，另对 3072..65535 抽样核 (b)。
**反例搜索结论 = 无反例。**

### 1.3 ⚠️ "净损失消除" 在 `winq == 0` 不成立（**F2**，最小反例）

机理（三行，可核）：`winq == 0 ⇒ wscan = fq_calc(0, oc) = (oc >= 0) ? 0 : …` **恒 0**
（`rtl/app_ctrl.v:612-618`）⇒ 武装项 `(0 < 0) || (0 == 0)` = **恒真** ⇒
`rtl/app_ctrl.v:1244-1252` 的 `if … else if …` 结构里 **`else if`（触发）永不求值** ⇒ `wu_pend` 永不置位。
`wu_act` 也救不了（它只是武装的**与**项）。

**实验（我自写，单臂，`sim/p5wu_p1p2_review/tb_rev_p1_winq0.v`）**：
```bash
cmd //c 'sim\p5wu_p1p2_review\run_tb_rev_p1_winq0.bat'
```
```
W0: winq=0 -- arm is saturated true => else-if never evaluated?
  PASS W0a dut winq=0 (granted)
  PASS W0b dut wu_act[1]=1 (progress flag set)
  PASS W0c dut wu_zero[1]=1 (arm saturated true, not blocked)
  [READ] W0 fires with winq=0 (wu_act forced 1): dut=0
  PASS W0d winq=0 NEVER fires (arm always true blocks the else-if => still unreachable)
```
⚠️ 口径如实：`wu_act` 是我**人为**制造的（`winq=0` 时窗口为 0，物理上对端发不进数据）⇒
本门证的是**代码可达性**，不是板级场景。
**影响 = 0**（产品配置 `winq ≥ 3072`；且原对抗审查已登记"`winq=0` 新旧都不可达 ⇒ 非回归"，
`P7B_WU_REVIEW.md` §3-8）⇒ 这是**声称过宽**，不是功能回归。
**建议改法（一行）**：`P7B_WU_P1P2_SNAP.md` §1.2 与 `rtl/app_ctrl.v:222-231` 的
"⇒ **净损失消除**" 改成 "⇒ `winq ∈ {1,2,3}` 可达性恢复；`winq == 0` 与修复前同为不可达（非回归）"。

### 1.4 "`winq[15:2]` vs `winq/4` 小数位语义" —— 真等价，但有一条**要说清**

`winq[15:2]` **就是** `floor(winq/4)`（无符号整数位选）。`winq` 的语义是**字节配额**（整数），
所以"除以 4"的自然读法就是向下取整 ⇒ 两者**逐位等价**，无小数位歧义。**但**两处阈值都是**向下取整**的：
武装 `floor(w/4)`（比 w/4 早 0–3 字节）、触发 `floor(w/2)`。
滞回带 = `[floor(w/4), floor(w/2))`，对 `w ≥ 4` 非空且有序（`floor(w/2) ≥ floor(w/4)`），
`w ∈ {1,2,3}` 时带被压到 `{0}` 或空 —— 这与作者"4..7 退化"的登记一致，
但作者**没写 `w ∈ {1,2,3}` 的触发侧含义**（触发阈值 `floor(w/2) ≤ 1` ⇒ 只要 wscan 离 0 一格就发）。
不影响产品，登记建议同上。

---

## 2. 攻击面 ②：P2 的 `wu_act`

### 2.1 ① 置位/清位事件"会在该触发的时刻触发吗" —— ✅ **挡得住（我自己造门实测）**

- 置位侧：`act_now = (rc_rcv_nxt != c_rcv_nxt[scan_id])`（`rtl/app_ctrl.v:822`），
  只在扫描拍求值（`:1051` 的守卫内，`:1070`）⇒ **任何一次推进都必然被下一次采样捕获**
  （`c_rcv_nxt[init_slot] <= rc_rcv_nxt` 只在 init 拍写，`:926`）。
- 清位侧：`:978`（ev_up）/ `:1015`（ev_down）/ `:878`（复位）。**作者 TB 未覆盖会话边界**，
  我补了（最小实验，两臂同激励）：

```bash
cmd //c 'sim\p5wu_p1p2_review\run_tb_rev_p2_gate.bat'      # 新 TB: sim/p5wu_p1p2_review/tb_rev_p2_gate.v
```
```
RA: same-slot reconnect -- wu_act must be a SESSION property
  PASS RAa session A: dut wu_act[1]=1 (data seen)
  PASS RAb dut wu_act[1]=0 after ev_down
  PASS RAc dut wu_act[1]=0 right after new session
  PASS RAd dut wu_act[1] still 0 (init != false progress)
  PASS RAe dut NOT armed at low window (P2 gate blocks)
  [READ] RA fires: dut=0 base=1 | wu_act dut=0
  PASS RAf dut fires 0 on reconnected IDLE session (P2 gate holds)
  PASS RAg base fires 1 (no gate => noise on idle conn)
  PASS Z1 lockstep across 2 arms (same stimulus)
REV_P2_GATE OK
```
⇒ **"同槽重连不继承进度"实测成立**，且 `RAg` 是判别性正对照（同场景 base 必发 1）——
证明 RAe/RAf 不是"死门"。
⚠️ 一条**依赖**（如实）："init 拍 `c_rcv_nxt` 已等于本会话 rcv_nxt" 依赖 `ev_up` 拍七字段已落地的
P5a 既有不变量；该不变量**本来就承重**（`redge_init` 用同一个值），本轮只是多了一个消费者。

### 2.2 ② 两条残留 —— **实测确认，其中①比作者写的更差**

```
RB: residual (1) -- conn that HAD data then went silent still fires
  PASS RBa dut wu_act[1]=1 (had data)
  [READ] RB fires over 2 occ cycles: dut=2 base=2
  PASS RBb residual (1) CONFIRMED: dut fires 1 per occ cycle while silent
RC: residual (2) -- never-received conn that saw a small window still waits
  PASS RCa dut wu_act[1]=0 (never received)
  PASS RCb dut NOT armed even though window is small
  [READ] RC fires after reopen: dut=0 base=1
  PASS RCc residual (2) CONFIRMED: dut does NOT notify (waits for persist)
  PASS RCd base DOES notify (this is what P2 gives up)
```

**残留① 的严重度（订正作者措辞）**：作者写"这一格**只被压小**、没被消掉"。
我实测：**"曾活跃后空闲"这一类上削减量 = 0**（dut=2 / base=2，逐字相同）——
P2 的削减**全部**来自"从未收过数据"这一类；对"收过数据的静默连接"，P2 一点也没压小。
代价尺度沿用原审查的量化（每 occ 涨落 1 条 ≈ 每消费 15.6 KB/条）⇒ 对**别的连接**造成的
occ 涨落照样让它发；N 条连接同时振荡 ⇒ 噪声按 N 走（原审查 P2-①已登记）。
**结论**：残留① = **有界但未削减**，与产品结论无关（只影响"拿 `stat_wu` 当判据"的解读）。

**残留② 的严重度（我补了机理，比作者写得更具体）**：作者只说"小窗只能来自我们发给它的段"。
我核到具体路径：**建连时 `init` 拍立刻把 `fq_calc(winq, rx_occ_bytes)` 写进 TCB.rcv_wnd**
（`rtl/app_ctrl.v:942` + `:908-933` 的 C10 注释明说"对端拿到 SYN+ACK 就可能开始发"）⇒
**新的连接在共享 FIFO 被别的连接占住时建连，SYN+ACK 里带的就是小窗**；
若对端因此一个字节都不发（窗恰好 0）⇒ `wu_act` 永远为 0 ⇒ **本板永不主动通告**
⇒ 该连接要等对端 persist（~208 ms 量级，与首轮修复前的行为相同）。
**这是 P2 用"少发帧"换"少发噪声"时**主动放弃**的那一格的具体形态**（作者已如实登记，我补的是触发路径）。

---

## 3. 攻击面 ③：粘滞是否必要 / 有没有更简单的修法

**粘滞必要性的论证成立**：触发要发生在"对端已被压住、`rcv_nxt` 自然停推"的那一刻，
所以任何"当拍有进度"的门都会把正主场景排除 ⇒ 必须粘滞。
我另做了一次**穷尽式找存量代理**（有没有既有的 per-slot 量能直接当门）：把 `app_ctrl` 的 per-slot
状态列了一遍（`redge/winq/wu_mark/wu_zero/wu_pend/fc_pend/fc_wq/fin_to/to_fired/to_pend/
st_pend/st_done/fin_sent/rst_sent/fin_req/rst_req/c_*`）——**没有一个编码"本会话收过数据"** ⇒
新增 1 位是**当时能做的最小的**。

**但"最小修法"的唯一性没建立（不是缺陷，是论证边界）**：有一条**同代价**替代没被讨论 ——
把"粘滞的**内容**"换成"**我们曾通告过一个小窗**"（判据量 `pb_rwnd = rc_rcv_wnd` 的 T+1 采样**已经存在**，
`:1180-1183` 就在用），代价同样是 16 FF + 一条比较。
取舍**不同**：它会**保留残留②**（该发就发）但**重新引入残留①的噪声**（空转连接被共享占用"通告小窗"后照样发）。
⇒ 两条路线的差异正是"帧率纪律 vs 通知完备性"的产品取舍；作者写的是"**绑定本连接进度**的**正确最小实现**"
（限定语在，读法上不算错），但**没有把这条替代摆上台面**。建议在 §2.2 加一句登记。

---

## 4. 攻击面 ④：`W62` 组合派生 / W49 先例 / hold

### 4.1 W49 先例 —— ✅ **是真同款（逐条核过定义链）**

| 环节 | 证据 |
|---|---|
| W49 的源 | `board/wrapper_p4.v:3607` `(gi == 10) ? {27'd0, cls_dbg_occ}`；`:989` `.dbg_occ(cls_dbg_occ)` |
| 再往里 | `rtl/rx_classify.v:95` `assign dbg_occ = w_wptr - w_rptr;` ← `fifo_sync u_wf` 的 `dbg_wptr/dbg_rptr` |
| 是不是寄存器直出 | `rtl/fifo_sync.v:42,48,49` `reg [AW:0] wptr,rptr; assign dbg_wptr = wptr;`（**纯 assign**） |
| 同域 | `board/wrapper_p4.v:951-952` `rx_classify u_classify (.clk(dp_clk), .rst_n(dp_rst_n))` ⇒ **dp 域** ✓ |
| W62 的源 | `wrapper_p4.v:1033` `app_rx_occ = {(eco_dbg_fifo_wptr - eco_dbg_fifo_rptr), 3'b0}`，两指针出自 `tcp_echo u_tcp_echo (.clk(dp_clk))` 里的 `frame_fifo`（`rtl/frame_fifo.v:291-292` 纯 assign 引出 `reg wptr/rptr`，`:255-260` 在 `clk` 上赋值） |

⇒ 结构、域、源形态**逐项同款**；差别只有位宽（5 vs 17）与"W62 是判据的**输入**而非纯观测"。
**独立于 W49 的第二个论证也成立**：`hold_b <= din_b`（`rtl/snap_cdc.v:92-96`）是 **clk_b 域内的普通触发器**，
`hold_b` 的 D 端组合路径**由 STA 覆盖**（同沿采样 ⇒ 拿到的两个指针是**同一拍**的值 ⇒ 无 tearing）。
文件头那句"毛刺会在锁存沿被采到"针对的是**异步/异域**源 ⇒ 作者的两条理由**都站得住**。

### 4.2 "会不会在 `hold_b` 那族造出新的 hold 违例" —— ⚠️ **无法判定（无构建），且这一问的指向要改**

我读了现役 routed 报告（`board/p7b_ku5p_timing.rpt`，mtime 02:18，即**本轮之前**的构建）：

| 读数 | 值 | 出处 |
|---|---|---|
| 全局 | WNS `+0.147` / **WHS `+0.010`** / 失败端点 0 | `:154-156` |
| DP 域（`g_hw.clk_out0`，6.400ns） | Setup `+0.147` / **Hold `+0.010`** / PW 2.627 | `:2002-2004` |
| DP `async_default`（**同一族的另一面**） | Setup `+0.743` / Hold `+0.125`，宿端 = `u_snap_dp/hold_b_reg[2]/CLR` | `:3316-3317` / `:3326` |

**三点必须分开写**：
1. **`hold_b` 在报告里出现在 `async_default`（异步复位 Recovery/Removal）族**，**不是** hold 族
   ⇒ 问"`hold_b` 那族的新 hold 违例"**问错了族**（这条与 `CLAUDE.md` 里"扩窗吃的是异步复位 Recovery"
   的订正一致）。
2. **同域组合减法不可能自己造出 hold 违例**：它只会把 D 端路径**变长**（hold 放宽、setup 收窄）
   ⇒ 真正被吃的是 **setup**（DP 域只余 2.3%）。
3. **但**：全设计**最差的 hold 就在 DP 域（+0.010）**，而本轮往 DP 域加了 **16 FF（`wu_act`）+ 64 FF（2 字 × 32 的 `hold_b`）**
   ⇒ 新增端点的 hold 检查落在最薄的那条线上。**判据 = 构建后看 DP 组 `Hold Worst Slack` 与
   `u_snap_p7bdp/hold_b_reg[*]`**（作者已登记"必须由一次构建收口"，我同意，只是把**要看的族**写清）。
   ⚠️ **新字给 `hold_b` 的 D 端**：`biz_w61`(stat_wu 是计数器寄存器) 是**近零逻辑的寄存器到寄存器**路径
   —— 这正是 hold 违例的典型形状（同款端点 W51..W60 已有 320 个在产，家族最差 +0.010）。
   构建时**优先看 `u_snap_p7bdp/hold_b_reg`**（比看 `u_snap_dp` 更对准本轮的新增面）。

---

## 5. 攻击面 ⑤：窗口装配（我自写脚本，不用作者的 `check_window.py`）

```bash
/c/Users/zhxue/anaconda3/python.exe sim/p5wu_p1p2_review/rev_window_check.py    # 39 判据
```
```
  [INFO] 几何 {'SNAP_NW_P6E': 63, 'SNAP_FE_NW': 14, 'SNAP_DP_NW': 22, 'SNAP_P7BFE_NW': 3, 'SNAP_P7BDP_NW': 24, 'SNAP_TX_NW': 4}
  [PASS] A1c 束宽和 == NW (14+22+3+(24-4)+4=63)
  [PASS] A2b 项数对账 (27 单项 + 36 = 63)
  [PASS] A3b/A3c W 号严格递减 / 连续无跳号 (head=62 tail=36)
  [INFO] HEAD 项数 = 26 (末项 snap_dout) / 新表 28
  [PASS] A4b 新表尾部 == HEAD 逐字相同 (新增 2 项全在 MSB 端)
  [PASS] A5f 驱动项数 (12 gen + 12 显式) == SNAP_P7BDP_NW
  [PASS] A6h 每项 槽号+基址 == 注释 W 号 (坏项 [])
  [PASS] A8c u_app_ctrl.rx_occ_bytes <- app_rx_occ (W62 与判据同源)
  [PASS] A8d u_app_ctrl.stat_wu -> app_stat_wu (W61 与寄存器 0x96 同源)
REV_WINDOW PASS=39 FAIL=0
```
**`22+26+13` / `24+26+13` 的算术问题（任务点名）—— 两个数各代表什么，逐条核清**：
- `SNAP_P7BDP_NW 22→24` = **dp 束的槽数**（`p7bdp_din` 的 32 位槽个数），不是进入窗口的字数；
  该束的槽 2..5 **从不装进窗口**（`gen` 循环里落 `32'd0`，注释也写明"槽 2..5: 由 tx 束装配"）
  ⇒ 进入窗口的只有 **24−4 = 20** 项。所以"63 = 14+22+3+**24**+4"是**错的**（= 67），
  正确 = `14+22+3+20+4`。作者的 `check_window.py` 用的就是 `(24-4)` ✓。
- `26 / 13` 不来自这两个 localparam：26 = **HEAD 的装配项数**（`snap_dout_all` 的逗号项），
  13 我不知道指什么（作者笔记里也没出现）——**判定：笔记/注释里没有任何地方需要 13**，
  这条攻击面**没有对应的错**，但 §5-F1 的加法错是同族。
- 真正的**独立**校验是 A4b（拿 `git show 95c9485:board/wrapper_p4.v` 的项列表当尾部**逐字**比对）
  + A6h（**表达式 ↔ 注释 W 号**逐项配对，专抓"注释没动、表达式写错"）。

### 5.1 负对照（证明我自己的脚本有牙）
```bash
# 变异 1: 交换装配最上两项 (表达式) —— 注释不动
# 变异 2: 深交换 W59/W60 (A4 只看头部, 抓不到; 指望 A6h)
```
| 变异 | 结果 |
|---|---|
| 顶部两项对调 | `FAIL A4c / A4d / A6h (坏项 [('p7bdp_dout',22,62),('p7bdp_dout',23,61)])` ✓ |
| 深交换 W59↔W60 | `FAIL A4b + A6h (坏项 [('p7bdp_dout',20,60),('p7bdp_dout',21,59)])` ✓ |

### 5.2 **F1（真问题·注释级）**：新增注释里一道加法算错

`board/wrapper_p4.v:3900`（本轮**新改的行**）：
```verilog
        .SNAP_NW    (SNAP_NW_P6E)       // 63 = 14+22 (snap_seq) + 3+24+4 (P7b 三束: BIZ 加 10, WU 加 2)
```
`14+22+3+24+4 = **67** ≠ 63`；正确 = `14+22+3+(24-4)+4`（p7bdp 的槽 2..5 不进窗口）。
⚠️ 上一代那行（`61 = 14+22 + 3+22+4 = 65`）**也不成立** ⇒ 是**继承的老毛病**，但本轮**碰了这一行**，
按本工程的记账习惯应当就地订正（否则下一个人会按这个式子算窗口）。

---

## 6. 攻击面 ⑥：地址译码 / 回绕红线 —— ✅ 挡得住

| 判据 | 值 | 出处 |
|---|---|---|
| 末字（W62） | `0x20 + 4×62 = **0x118**` | 静态 + 运行 |
| 首个未实现 | `0x20 + 4×63 = **0x11C**` = **word 71** | `check_window` 判据8 与我 A6b 一致 |
| 是否**恰好** | `SNAP_LAST_IDX = 8+63-1 = 70`，`0x11C>>2 = 71 = 70+1` ✓ 差 1，两侧都判 | `_proj_pcie/rtl/axi_regs.v:134,279-280,296` |
| 回绕红线 | `ar_word = araddr[8:2]` **7 位** ⇒ 0x200>>2 = 128 ⇒ 回 word 0 = MAGIC；现行 NW=63 ⇒ **成立** | `axi_regs.v:193`；TB 判据 7a/7b 实测 `OKAY + 0x50360001` |
| `snap_base` 装得下 | `{snap_idx,5'b0}`，`snap_idx_max = 62` ⇒ `1984`；`1984+32 = 2016 = 63×32` **正好贴顶** | `axi_regs.v:258,279` |
| NW 上限 119 | `0x1FC`（word 127）仍未实现（SLVERR）⇒ 负对照有牙 | TB 判据 7c 实测 `SLVERR` |

**32 位贴顶这句值得留档**：`(NW-1)<<5 + 32 == NW*32` 恒成立 ⇒ `snap_base` 只要不溢出就是**恰好**覆盖末尾，
不是巧合；真正的上限由 7 位 `ar_word` 的 119 字给。⇒ 63 字**没有**任何"差 1"风险。

---

## 7. 攻击面 ⑦：`BUILD_ID_V 8→9`

- RTL 面：`board/wrapper_p4.v:3882` `.BUILD_ID_V (32'h00000009)` ✓（我的 A7 判据）；
  且 `check_wu_words.py` 判据 2 也核了 ✓。
- **脚本面：作者 §8-① 说"越界未改"，但我审查期间（08:52–08:54）实测到并发 agent 正在逐个补**：
  `_proj_pcie/p7b_biz/p7b_snap.sh`（NW=63/`EXPECT_BID=0x00000009`/`NAME[61..62]` 已补）、
  `_proj_pcie/p6e_snap_check.sh`、`_proj_pcie/p7b_gate4_accept.sh`、`_proj_pcie/p7b_gate4_selftest.sh`、
  `_proj_10g/notes/p7b_gate4_3/final_state.sh`、`_proj_pcie/rtl/axi_regs.v`（**只改注释**，我逐 hunk 看过）
  —— **以我快照时刻为准，作者 §8-①/② 的清单基本已清空**。
- 仍**硬编码 8**（我 grep 到的活脚本）：`_proj_pcie/p7b_gate4_livefake.sh:79`、
  `_proj_pcie/p7b_gate4_negctrl.sh:50`、`_proj_pcie/p6e_snap_selftest_fix2.sh:67`
  —— 这三个是**测试替身/负对照**（模拟板子回 BID=8 + 51 字窗口）。
  ⇒ 它们的后果是**响亮**的（新的 `SNAP_WORDS=63` 解析会报"窗口不完整"），**不是静默错读数**；
  但会让自检台架出现**假红**，需与并发 agent 对齐（见 §10 的待办）。

---

## 8. 攻击面 ⑧：TB 的代表性

### 8.1 三臂选择 —— **我复算过，站得住**
```bash
git show 95c9485:rtl/app_ctrl.v > sim/p5wu_p1p2_review/app_ctrl_head_raw.v
# sha256(head 原文) = c38b3b9640d55e50...   (笔记声称 c38b3b96 ✓)
# sha256(app_ctrl_base.v) = d26e4a0f3d006040... (笔记声称 d26e4a0f ✓)
# difflib: 全文件**只有 1 处**差异: `module app_ctrl #(` -> `module app_ctrl_base #(`
```
⇒ `u_base` **确实是真 HEAD 文件**（不是参数模拟），三臂的"未修/修复前/修复后"语义成立。
另外 §7 表里 6 个 sha256 前缀我逐个复算，**全部逐字相符**。

### 8.2 "三臂都错而 TB 看不出来" —— 可能的，但**不影响该 TB 想证的结论**
TB 证的是**相对差**（DUT 发/不发 vs BASE 发/不发 vs LEG 发/不发），
只要三臂共享同一套激励/模型，**"共同错"不会把相对结论反转**。真正的盲区在**绝对行为**：
- `wu_gnt = wu_req`（ackq 永不背压）⇒ 板上"ackq 满 ⇒ 水准请求保持"的模态**未覆盖**
  （与 P2 无关，但影响 `stat_wu` 与"发了几个 ACK"的对应关系）；
- 不驱动 `close_req/fin_req/rst_req`，也不跑超时/abort 拆除路径（`to_fire` 清 `wu_zero` 但不清 `wu_act` 的那条）——
  我用**代码核**覆盖了它：拆除路径把 `winq→0` ⇒ `wscan ≡ 0` ⇒ arm 恒真 ⇒ `else if` 不求值 ⇒ **不会误发** ✓（§1.3 的同一机理，这里反而是**好处**）。
- 三臂都跑 `winq ∈ {3, 0x6000}`，**没有一臂跑产品配置**（≥3072）；产品配置的结论靠 §1 的代数/穷举。

### 8.3 我复跑了作者的门，读数**逐字相符**（不是我信笔记）
```bash
cmd //c 'sim\p5wu_p1p2\run_tb_wu_p1p2.bat'     # P1P2 GATE PASS, exit=0
cmd //c 'sim\p5wu_p1p2\run_tb_snap63.bat'      # SNAP63 GATE PASS, exit=0 (26 项)
cmd //c 'sim\p5wu\run_tb_app_wu.bat'           # P7B WU GATE PASS (首轮门, 必须仍过)
cmd //c 'sim\p5sim\run_tb_p5_app.bat'          # P5 APP OK
```
- `tb_wu_p1p2`：`PH1d..PH4c` + `Z1` 全 PASS，`lockstep violation cycles = 0`，
  `fires: DUT c0=1 c1=0 c2=1 | BASE c0=0 c1=1 c2=1 | LEG c0=1 c1=0 c2=0`，
  `[READ] stat_wu: dut=2 base=2 leg=1` ⇒ 与笔记 §1.3/§2.3 **逐字一致**。
- `tb_app_wu`（首轮门）：`[WITNESS] min=63 max=120 (40 scans)` · `fire#1 wu_mark=24695 @cyc~34850` ·
  `NEW = 3 . OLD = 1` —— **与笔记声称的"没有扰动现场模态与触发值"逐字相符** ✓。
- `tb_p5_app`：`winq0=c000 wu_mark0=c000 pool=00000 **stat_wu=0** stat_fc_upd=3`
  ⇒ **健康流零额外 wu 的不变量在 P2 门下依然成立**（这是 P2 最该被怀疑的一条，实测守住）✓。
- **判据计数**：`tb_wu_p1p2` 日志实测 `PASS=27 / FAIL=0`（PH1 10 + PH2 10 + PH3 3 + PH4 3 + Z1 1），
  笔记 §5 写"**26 项全 PASS**" ⇒ **少算 1**（`tb_snap63` 的 26 是它自报的，✓）。

### 8.4 门 harness 的一处**弱点**（非本轮引入）
`run_tb_wu_p1p2.bat` 的唯一硬判据是 `findstr "P1P2 GATE OK"` —— 它**不核 PASS 条数**
（TB 自查 `errs==0` 才打印）。若将来某条 `chk` 被删掉/被跳过，门照样绿。
建议加 `findstr /C:"PASS=27"` 之类的**计数**判据（本工程"空判据"史的老坑）。

---

## 9. 攻击面 ⑨：`check_wu_words.py` 的第 5 个对照是不是自证式

**不是自证式，但它不是"检查器正确"的证据** —— 两点都给了证据：

1. **它声称的那次假 FAIL，我独立重建出来了**：当前文件里 `biz_w61`/`biz_w62` 的
   **首次出现**在 `board/wrapper_p4.v:3565` —— **契约登记注释里**（前置于声明）。
   用"名字首次出现"当锚点时，`[anchor-200, anchor+600]` 窗口里**既没有 `` `ifdef APP_MODE `` 也没有 `` `else ``**
   ⇒ 判据 3a/3c 双双假 FAIL = `PASS=11 FAIL=2`（与作者 §4.3 的读数**同数**）。⇒ 故事属实，
   "锚点用句法位置"的修法**是对的**（注释不是代码）。
2. **判据 3a/3c 真的有牙**（我自己造变异体）：把 `biz_w61/biz_w62` 的 `` `ifdef APP_MODE `` 守卫**拆掉**
   （声明裸露、`else` 兜常量仍留），复跑作者的检查器 ⇒ `[FAIL] 3a` + `[FAIL] 3c`，恰是那两条。
3. 呈现方式我核了：作者把 `cmt_immu` 明确标成"**这条期望 exit=0**"，与另外 4 个红变异体**分子列出**
   ⇒ 没有被当作覆盖证据使用。
⇒ **裁定：挡得住**。⚠️ 但要写清它的边界：这条对照只断言"**注释文本不该让判据红**"（作者选定的性质），
**不**断言检查器的核心覆盖；核心覆盖的证据是另外 4 个红变异体 + 我这条独立变异体。

---

## 10. 攻击面 ⑩：被漏掉的同类面（全域 grep + 逐条"响亮 vs 静默"）

⚠️ **快照时刻声明**：下列结论是 **2026-10-07 08:51–08:59** 的实测状态；
期间**另一个 agent 正在改测量脚本**（`git status` 在我两次调用之间由 11 个 M 变成 19 个 M，
`_proj_pcie/rtl/axi_regs.v` 的 mtime = 08:53:39、`p7b_snap.sh` = 08:52:12）。
凡"已改"的行，**归功/责任都不属于被审的这一轮**。

### 10.1 ⛔ **推翻作者"忘了改会响亮失败"的一半**（**F3**）

作者 §8-① 的原话：*"好消息：忘了改会**响亮失败**（`0x114` 现在回真数据 ⇒ 未实现地址负对照红；
`EXPECT_BID=8` ⇒ 身份闸红），**不会静默误判**。"*
**两个机制都在 `id_check` 里，而 `p7b_snap.sh` 的 `full`/`snap` 子命令根本不调用 `id_check`**：
```bash
# _proj_pcie/p7b_biz/p7b_snap.sh 末段 (逐字)
  id)   id_check || exit 1; ...;;
  full) trig || exit 1; dump_words "${2:-FULL}";;
  snap) trig || { echo "SNAP_ABORT"; exit 1; }; shift; dump_words "$@" ;;
```
⇒ **NW 落后（读 61 字而板上 63 字）时 `full` 完全静默**（少读 W61/W62，无任何红，
`dump_words` 的 `nff` 计数只数窗口**内部**的 `0xffffffff`，少的字根本进不了循环）。
`snap TAG W1 W2` 同理（只读点名的字）。⇒ **"响亮失败"只覆盖 `id` 这一条路**。
**最小反例**：`NW=61 bash p7b_snap.sh full T1` 在 63 字位流上 → 打印 61 行、`SNAP_END nff=0`、`exit 0`
（读起来**完全正常**，只是少了两个字）。**修法**：`full`/`snap` 里先 `id_check`（或至少核 BID）。

### 10.2 ⛔ **`j6-ladder` 台架结构性不读 W61/W62**（同属 F3）

作者 §8-④ 写：*"⭐ **一次 j6-ladder 读数即可把 'wu 机理' 从推断升为观测**（`ΔW61` 与 `ΔW62` + 对端 pcap 同窗）"*。
实测 `_proj_10g/notes/p7b_biz_tcpreg/tcpreg_j6.sh`（= J6-ladder 台架，`P7B_BIZ_PLAN.md` §4.1b 的判据要用它）：
```bash
bash "$S" full "${TAG}_pre" || ...           # 全窗 (NW 派生, 63) —— 有 W61/W62 ✓
bash "$S" snap "${TAG}_t0" 5 53 54 || ...    # ⛔ 只 5/53/54
bash "$S" snap "${TAG}_t1" 5 53 54 || ...    # ⛔ 只 5/53/54
bash "$S" full "${TAG}_post" ...             # 全窗 —— 有 W61/W62 ✓
```
⇒ **紧贴传输窗的两点对 (`t0/t1`) 不含 W61/W62**；只有跑**整个 run 前后**的 `full` 两点能出 `ΔW61/ΔW62`。
所以"一次 j6-ladder 读数"这句话要么(a)改成"用 pre/post 全窗", 要么(b)把 `t0/t1` 的字表加成 `5 53 54 61 62`。
另：脚本头部仍写 `NW=61`、`NW 默认 61 (BIZ 位流)`，而 `NW` **没有 export** ⇒
`NW=61 bash tcpreg_j6.sh` 里的 61 **不会**传给 `p7b_snap.sh`（后者用自己默认的 63）——
即"文档里的覆盖办法"在这个脚本里**是失效的**（本来无害，因为两边默认曾一致；现在默认分叉就会误导读数）。

### 10.3 其余"现役几何"句子的状态（快照时刻）

| 位置 | 状态 |
|---|---|
| `udp_hls_10g/CLAUDE.md:269` `快照窗口现为 **61 字** … 未实现地址 0x114` | ❌ **未改**（作者 §8-②b 已点名；另有 DOCFIX agent 在写） |
| `_proj_10g/notes/P7B_HANDOFF.md`（板上现态行） | ⚠️ 那些行讲的是**已烧的 BIZ 位流**（确为 61 字）⇒ **作为历史是对的**；需要改的是"现役"口径句 |
| **`D:\repo\XCKU5PMini\CLAUDE.md:156`** `快照窗口现为 61 字（P7b-BIZ 扩窗：BUILD_ID_V=8、未实现地址 0x114）` | ❌ **未改，且这个文件不在 `udp_hls_10g` 仓内** ⇒ 两个 agent 的清单里都可能没有它（**新登记**） |
| `README.md:381` 同款现役句 | ❌ 未改（快照时刻） |
| `_proj_10g/notes/P7B_BIZ_WINDOW.md` §1 表 | ✅ 已并入 W61/W62 + `0x11C`（我核过内容与 wrapper 一致） |

### 10.4 会**静默给错读数**的（按危害排序，全在快照时刻）

1. **`full`/`snap` 的 NW 落后 ⇒ 静默少字**（§10.1）—— 唯一一个**真静默**的。
2. **`tcpreg_j6.sh` 的 `snap 5 53 54`**（§10.2）—— 不是错读数，是"读不到该读的"，
   但会让"机理观测"计划落空而**没有红**。
3. `final_state.sh`（已由并发 agent 改成 `0x11C` ✓）—— 若未改，它会把 W61 的**真数据**打印在 `UNIMPL=` 标签下
   （人工读数脚本，无断言 ⇒ 静默误标）。**快照时刻已修**。
4. `_proj_10g/notes/p7b_biz_win/apply_c.py`（BIZ 轮的**补丁生成器**，内含 `NW=61` 的整段文本）
   —— **陷阱**：它**没有**被点名，若有人重跑它会把 61 字版**贴回** `wrapper_p4.v`。建议加一行 `# 历史件, 勿重跑`。

---

## 11. 我没能判定的部分（**不许当已答**）

1. **时序/资源**：**无构建** ⇒ "DP 域 setup 是否仍为正"、"`hold_b` 新端点是否违例"、
   "pcie 域 `snap_words_r` 的 async Recovery 族会不会破" —— **全部未判定**
   （作者已登记"必须由一次构建收口"，我给的是**要看的族与端点名**，§4.2）。
2. **板级**：**未烧板**（遵守纪律，板子保持受控停流态）⇒ 新字的**板级读数一个都没有**；
   `ΔW61`/`ΔW62` 的标定、`0x04=9` 的身份闸、`0x11C` 回 `0xffffffff` —— **全未测**。
3. **`stat_wu` 与"线上真的多了一条 ACK"**：本轮也没有台架把"入 ackq"接到"上线"
   （作者 §6-④ 已登记；我复跑的门同样止于 `wu_gnt`）。
4. **残留②的板级发生率**：我证的是机理（`init` 拍即写小窗 ⇒ SYN+ACK 可带 0 窗）与
   "DUT 不发"这一格；**板上多久遇到一次（共享占用高时建连的频率）我没有数据**。
5. **P2 的替代门（§3）孰优**：**未做实验**，只做了机制分析 ⇒ 我的结论止于"作者的唯一性论证未建立"。
6. **并发面**：我审查期间有 agent 在改测量脚本 ⇒ §10 的"已改/未改"是**快照**；
   `p7b_gate4_*` 三个测试替身与 `SNAP_WORDS=63` 的对齐**我没跟踪到底**。

---

## 12. 附：本轮我跑过的全部命令（逐字，可复跑）

```bash
cd /d/repo/XCKU5PMini/udp_hls_10g
# 0) 基线核对
git status --short ; git log --oneline -3 ; git diff --stat
git show 95c9485:rtl/app_ctrl.v > sim/p5wu_p1p2_review/app_ctrl_head_raw.v
sha256sum rtl/app_ctrl.v board/wrapper_p4.v tb/tb_wu_p1p2.v tb/tb_snap63.v \
          sim/p5wu_p1p2/app_ctrl_base.v sim/p5wu_p1p2/check_wu_words.py
# 1) 静态核对（我自写）
/c/Users/zhxue/anaconda3/python.exe sim/p5wu_p1p2_review/rev_window_check.py       # PASS=39 FAIL=0
/c/Users/zhxue/anaconda3/python.exe sim/p5wu_p1p2_review/rev_p1_equiv.py           # exit=0
/c/Users/zhxue/anaconda3/python.exe sim/p5wu_p1p2_review/rev_check_wu_words_copy.py \
        --repo .../sim/p5wu_p1p2_review/mutw                                        # 变异体: FAIL 3a/3c
# 2) 作者的门（复跑，读数逐字相符）
cmd //c 'sim\p5wu_p1p2\run_tb_wu_p1p2.bat'      # P1P2 GATE PASS
cmd //c 'sim\p5wu_p1p2\run_tb_snap63.bat'       # SNAP63 GATE PASS
cmd //c 'sim\p5wu\run_tb_app_wu.bat'            # P7B WU GATE PASS (首轮门)
cmd //c 'sim\p5sim\run_tb_p5_app.bat'           # P5 APP OK (stat_wu=0)
# 3) 我自写的门（新增 TB）
cmd //c 'sim\p5wu_p1p2_review\run_tb_rev_p2_gate.bat'      # REV_P2_GATE PASS (15 项 PASS / 0 FAIL)
cmd //c 'sim\p5wu_p1p2_review\run_tb_rev_p1_winq0.bat'     # REV_P1_W0 PASS (5 项)
# 4) 负对照（我自写脚本的牙）
#    mut/: 顶部两项对调 / 深交换 W59↔W60  -> rev_window_check 分别在 3 / 2 处判据上红
```
