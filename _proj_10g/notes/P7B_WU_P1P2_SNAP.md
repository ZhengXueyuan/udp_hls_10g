# P7B-WU 二轮 —— P1/P2 修复 + `stat_wu`/`rx_occ_bytes` 接快照（施工与证据）

- 日期：**2026-10-07**　轮次：**P7B-WU 二轮（RTL 实现 agent，阶段 A）**　基线 HEAD = **`95c9485`**
- 性质：**RTL 施工 + 仿真验证**。**未上板、未烧板、未跑 Vivado 构建/实现**（构建由 TL 统一做；见 §6）。
- 未提交 git（TL 统一提交）。**未碰** `rtl/app_pattern.v` / `rtl/tcp_tx_frame.v`（另有 agent 在做设计）。
- 一句话：**P1 与 P2 都修了**（`rtl/app_ctrl.v` 功能代码 **7 行**），**两处都用"三臂同激励"TB 证了反例+修后对照**；
  **`stat_wu`/`rx_occ_bytes` 已接进快照 ⇒ 窗口 61 → 63 字（W61/W62）/ `BUILD_ID_V` 8 → 9 / 未实现地址 `0x114` → `0x11C`**。
- ⚠️ **一条不许当成"已验"的**：新字的**板级读数一个都没有**（要等下一轮构建+烧录）；本轮的"通过"全部止于
  **仿真 + 静态 + 编译面**（逐条读数见 §4/§5，负对照见 §4.3/§4.4/§4.6）。

---

## 0. 一页速查

| # | 项 | 结论 | 证据（可复跑） |
|---|---|---|---|
| ① | **P1**（`winq ≤ 3` 时武装恒假、比修复前更差） | ✅ **已修**：武装阈值加下界 1（等价式 `< winq/4 \|\| wscan==0`） | `tb/tb_wu_p1p2.v` PH1（三臂：修后 1 发 / HEAD 0 发 / 修复前 1 发） |
| ② | **P2**（共享 `occ` ⇒ 空转连接也发 wu） | ⚠️ **按"绑定本连接进度"修了**（新增 per-slot `wu_act`，16 个 FF）：**空转连接结构性不武装**；**残留 3 条如实登记**（§2.4） | 同上 PH2（修后只对活跃连接发；HEAD 对两条都发） |
| ③ | DOCFIX 登记的那条不符注释（`app_ctrl.v:205` 原句"对任意 winq 都可达"） | ✅ **已订正**（并把"可达到哪、退化成什么"写全） | `rtl/app_ctrl.v:220-231`（文件头 P7b-WU 二轮节） |
| ④ | **任务②**：`stat_wu` + `rx_occ_bytes` 接快照 | ✅ **已接**：**W61 / W62**，加在 **MSB 端**（旧字逐项未动，机器核过） | `check_window.py` PASS=42 / `check_wu_words.py` PASS=14 / `tb_snap63.v` 26 项 |
| ⑤ | 三处"判据结构性无牙"复核（SLVERR 恒不触发 / 6 位译码回绕别名 / `0x108→SCRATCH`） | ✅ **扩到 63 字后仍然守住**（译码 7 位不变即可：未实现字 = 71 < 128；回绕红线仍 ≥ `0x200`） | `check_window.py` 判据 8（`0x11C → word 71 < 2^7`）+ `tb_snap63.v` 判据 6/7/8/9 |
| ⑥ | 回归（既有门） | ✅ **6 门全绿**（含首轮 WU 门**必须仍过**） | §5 |

改动量（如实）：`rtl/app_ctrl.v` **+71/−10**（其中**功能代码 ≈ 7 行**，其余全是注释/注册）；
`board/wrapper_p4.v` **+64/−10**（功能 = 2 个 localparam 值 + 1 个 `BUILD_ID_V` + 10 行新线/assign + 2 项装配，其余是契约登记注释）。

---

## 1. 任务①-P1：武装阈值**下界**

### 1.1 缺陷定位（改动前 HEAD `95c9485`）

| 处 | 文件:行 | 原文 |
|---|---|---|
| 武装条件 | `rtl/app_ctrl.v:1184`（改动前） | `if ({1'b0, pb_wscan} < {2'b0, winq[pb_sid][15:2]}) begin` |
| 机理 | —— | `winq ≤ 3 ⇒ floor(winq/4) = 0 ⇒ 17 位无符号比较 x < 0` **恒假** ⇒ **永不武装**；而修复前 `pb_wscan == 0` 至少能发 1 次 ⇒ **净损失**（对抗审查 `P7B_WU_REVIEW.md` §2-P1，读数 `new=0 leg=1 head=1`） |
| 不符注释 | `rtl/app_ctrl.v:205`（改动前） | "归一后对任意 winq 都可达" —— **只对 `winq ≥ 8` 成立**（DOCFIX 轮登记） |

### 1.2 修法（极小）

```verilog
// rtl/app_ctrl.v:1243-1246（改动后）
if ((({1'b0, pb_wscan} < {2'b0, winq[pb_sid][15:2]}) ||
     (pb_wscan == 16'd0)) && wu_act[pb_sid]) begin
    wu_zero[pb_sid] <= 1'b1;     // 入危险区: 武装 (P1 下界 + P2 进度门)
```

**理由（等价性，逐位证明）**：目标语义 = `wscan < max(winq/4, 1)`。
- `winq/4 ≥ 1` 时：`wscan == 0` 已被前项 `wscan < winq/4` 蕴含 ⇒ 加后项**不改变任何取值**（产品配置逐位等价）；
- `winq/4 == 0`（即 `winq ≤ 3`）时：前项恒假 ⇒ 表达式退化为 `wscan == 0` = **修复前那条** ⇒ 可达性恢复（净损失消除）。
- ⚠️ **为什么不写成显式 `max` 的 mux**：那要多一级 14 位或树 + 16 位 mux；本式只多一级 16 输入或非门
  （`pb_wscan` 是寄存器，NOR 与比较器**并行**跑）—— DP 域余量只有 **2.3%（+0.147 ns）**，能省一级省一级。
- **保留的已知退化**（如实，未修）：`4 ≤ winq ≤ 7` 时下界仍 = 1 ⇒ 武装退化为 `wscan == 0`（脆弱但**可达**）；
  产品配置 `winq = 池/N ≥ 3072` 不在此域。**不修它的理由**：那要把下界抬到 2 以上，属"改判据形状"，
  超出"消除净损失"的最小修复范围（记在这里，交给下一轮判断）。

### 1.3 TB 双跑读数（`sim/p5wu_p1p2/run_tb_wu_p1p2.bat`，逐字）

```
PH1: P1 -- winq=3 (winq/4==0). HEAD arm can never arm; fixed arm can.
  [STATE] wu_act(dut)=1 wu_zero: dut=1 base=0 leg=1
  PASS PH1d DUT progress flag set (data arrived)
  PASS PH1e DUT armed (floor=1 fix works)
  PASS PH1f BASE never armed (P1 counterexample)
  PASS PH1g LEG armed (pre-fix could fire once)
  PASS PH1h DUT fired exactly once
  PASS PH1i BASE fired 0 (net loss proven)
  PASS PH1j LEG fired once (pre-fix reachable)
```

三臂 = **同一激励/同一 gnt/同一波形**（锁步由监视器逐拍判，`lockstep violation cycles = 0`）：
`u_dut` = 工作树 / `u_base` = **`git show 95c9485:rtl/app_ctrl.v` 的真文件**（仅改名 `app_ctrl_base`，
源码 sha256 前缀 `c38b3b96`；落盘件 `sim/p5wu_p1p2/app_ctrl_base.v` sha256 前缀 `d26e4a0f`）/
`u_leg` = `WU_LEGACY=1`（逐字 = 首轮修复前）。
⚠️ 臂的选择有一条**必须写清**：`u_base` **不是**用参数模拟的 —— 参数只能切 `WU_LEGACY`，切不出"首轮已修但无 P1/P2"的形态
⇒ 只有"取真文件进 TB"这条路能给出真反例（这是首轮对抗审查用过的同一手法，本轮沿用）。

---

## 2. 任务①-P2：武装绑定"本连接自己的进度"

### 2.1 缺陷定位

| 处 | 文件:行 | 内容 |
|---|---|---|
| 窗口计算 | `rtl/app_ctrl.v:767`（改动前后同） | `fq_scan = fq_calc(winq[scan_id], rx_occ_bytes)` — `rx_occ_bytes` 是**全局** app RX 占用（单个 `frame_fifo` 服务所有连接） |
| 入口 | `rtl/app_ctrl.v:298`（端口） | `input wire [16:0] rx_occ_bytes` |
| 后果 | —— | 别的连接把 FIFO 顶满 ⇒ **本连接**的 `wscan` 也读小 ⇒ 空转连接照样"武装→触发" ⇒ ① 多发纯 ACK（与"每段两帧已近对端上限"的帧率纪律冲突）② `stat_wu` 分不清真通告与噪声（对抗审查 `P7B_WU_REVIEW.md` §2-P2，读数 `PH4 fires: new=2 head=0`） |

### 2.2 修法（新增 per-slot 1 位标志，粘滞到会话结束）

| 处 | 文件:行 | 内容 |
|---|---|---|
| 状态 | `rtl/app_ctrl.v:460` | `reg [15:0] wu_act;` —— "本会话该连接收到过数据" |
| 置位 | `:1070` | `if (act_now) wu_act[scan_id] <= 1'b1;`（扫描采样拍；`act_now` = **既有的** P5c 关闭超时活性判据 `rc_rcv_nxt != c_rcv_nxt[scan_id]`，**零新组合逻辑**） |
| 复位 | `:878` | 复位清 0 |
| 会话边界 | `:978`（ev_up）/ `:1015`（ev_down） | 事件脉冲清（坑 9：跨会话状态必须事件脉冲清） |
| 使用 | `:1245` | 武装条件 `&& wu_act[pb_sid]` |

**理由（为什么这条是"绑定本连接进度"的正确最小实现）**：
- 该连接**从未收过数据** ⇒ 它的对端不可能处在"被我们的窗压住"的状态（小窗只能经**我们发给它的段**被它看到，
  而我们的 ACK/数据段都要求它先发过东西 —— 除非它先收到 SYN+ACK 的窗字段后直接停等，见 §2.4-②）
  ⇒ **不武装**是对噪声的**结构性**免疫，不是调参。
- **粘滞**是必需的：对端被压住后 `rcv_nxt` 自然停推，而那正是要发通告的时刻 ⇒ 只用"当拍有进度"会把
  **正主场景（首轮修复要治的那个）**排除掉。
- 位宽/时序代价：16 FF + 一级 16:1 单比特 mux + 一个与门（§3 的 `wu_arm_lim` 一级 NOR）—— 全在
  `pb_*` → `wu_zero[*]/D` 这条**非关键**路径上（DP 域前 10 名全是 `u_app_udp/u_txf → u_udp_tx/ip_csum_r` 同源，见 `P7B_WU_TIMING_DELTA.md` §5.3）
  ⇒ **估计**不致翻负，但**必须由一次构建收口**（§6-①）。
- **正确性关键一步（易漏）**：本次会话**首次采样不得假报"有进度"**。已由既有代码保证 —— **init 拍**就把
  `c_rcv_nxt[init_slot] <= rc_rcv_nxt`（C10 注释处），且 `ev_up` 拍与 `init_pend` 拍都不采样
  ⇒ 首次采样比较的是"本会话初始 seq"，相等 ⇒ `act_now = 0` ✓（若不成立，本门会被"新会话 seq ≠ 复位残留 0"整体绕过）。

### 2.3 TB 读数（同一门，PH2）

```
PH2: P2 -- conn1 idle / conn2 active, shared occ pushes BOTH windows low
  [STATE] wu_act(dut): c1=0 c2=1 | wu_zero c1: dut=0 base=1 | c2: dut=1 base=1
  PASS PH2c DUT progress only on conn2
  PASS PH2d DUT armed on active conn
  PASS PH2e DUT NOT armed on idle conn (P2 gate)
  PASS PH2f BASE armed on idle conn (noise proven)
  PASS PH2g BASE armed on active conn too
  PASS PH2h DUT: idle=0 active=1 fires
  PASS PH2i BASE: BOTH fired (noise on idle conn)
  PASS PH2j LEG: 0 fires this phase
...
fires: DUT c0=1 c1=0 c2=1 | BASE c0=0 c1=1 c2=1 | LEG c0=1 c1=0 c2=0
  [READ] stat_wu: dut=2 base=2 leg=1
```

⭐ **这张表是本轮最强的单条读数**：DUT 与 BASE 的 `stat_wu` **总数相同（都是 2）**，但**组成不同** ——
BASE 的 2 条里有 1 条是**空转连接**的噪声（`c1=1`），DUT 的两条都是真通告（`c0=1`/`c2=1`）。
⇒ "拿 `stat_wu` 当判据会高估通告次数"这条隐患在**计数总数上不可见**，只在**按槽分解**时才现形
（这正是审查 §2-P2 第②条的实测形态）。

### 2.4 ⚠️ P2 的残留（**没修掉的、如实登记**）

1. **"曾活跃、之后空闲"的连接仍有（有界）噪声**：`wu_act` 是会话级粘滞 ⇒ 一个连接收过一段数据后完全静默，
   之后别人把 FIFO 顶满再放开，它仍会走"武装→触发"发一条。**代价仍是**审查量化的那个尺度
   （每消费 ~15.6 KB/条，单连接 ~0.4–0.6 MB/s 额外字节 ≈ 10G 线的 0.04%）⇒ 这一格**只被压小、没被消掉**。
2. **"从未收过数据、但先看到小窗而停等"的连接**：恢复仍要等对端 **persist（~208 ms）**。
   什么时候会发生：该连接的对端只从**我们发出的段**看到了小窗（SYN+ACK 的窗字段 / 我们发给它的数据段 /
   对它纯 ACK 的应答），随后它有数据要发但窗为 0 ⇒ 停等/零窗探询。
   **口径**：这不是"新增的正确性缺口" —— 它与**首轮修复前**在那一格的行为**相同**（等 persist）；
   但它确实**不是**"任意情况都不受影响"。⇒ 拿 `wu` 做产品判据时，**"空转连接"这个词必须限定为
   "本会话从未收到过数据"**，不能读成"此刻没有流量"。
3. **活跃连接的重开频率没变**（有意）：那是本机制在干活（每个 wu 换回 `winq/4..winq/2` 字节）。
   想更省帧只能改阈值形状（属产品取舍，不在本轮范围）。

⚠️ **结论句（写法纪律）**：本轮的 P2 **不是**"彻底消除噪声"，而是"**把噪声源从'与全局占用耦合'改成'与本连接进度耦合'**"，
并把**不可达/不可分的那一格**明确登记。**不许**把它写成"P2 已解决"。

---

## 3. 注释订正（DOCFIX 登记的那条）

| 处 | 改动前 | 改动后 |
|---|---|---|
| `rtl/app_ctrl.v:205` | "……归一后对**任意** winq 都可达。" | 见 `:202`（阈值式写成 `max(winq/4,1)`）+ **`:220-231` 新增二轮注册块**：逐条写出 `winq ≥ 8` 正常 / `4..7` 退化为 `wscan==0` / `≤3` 修复前**不可达且更差**、修复后**可达**；P1/P2 的修法与残留、门与读数位置一并登记 |
| `rtl/app_ctrl.v:401`（`WU_STEP` 注释） | "生产路径的新阈值 = 本连接配额的 1/4 与 1/2" | 改成 "`max(配额/4, 1)` 与 `配额/2`"（下界 1 是二轮 P1） |
| `rtl/app_ctrl.v:1211`（C6 块注释） | "武装 wu_zero : wscan < winq/4" | 改成 `wscan < max(winq/4,1) **且** wu_act[pb_sid]`，并附 P1 等价式与 P2 门的代价说明 |

---

## 4. 任务②：`stat_wu` / `rx_occ_bytes` 接进快照（61 → 63 字）

### 4.1 我做了什么（对照 RECON §5 的 11 处清单逐处对账）

| # | 清单处 | 本轮动作 |
|---|---|---|
| 1 | `SNAP_NW_P6E 61 → 63` | ✅ `board/wrapper_p4.v:3125` |
| 2 | `SNAP_P7BDP_NW 22 → 24` | ✅ `:3132` |
| 3 | 加两个别名（**包 `ifdef APP_MODE`**） | ✅ `:3563-3570`（`biz_w61 = app_stat_wu`；`biz_w62 = {15'd0, app_rx_occ}`；`else` 兜常量） |
| 4 | 两条 `assign p7bdp_din[...]` | ✅ `:3612-3613`（槽 22/23） |
| 5 | 装配段**最上面**（MSB 端）加 2 项 | ✅ `:3663-3664`（`p7bdp_dout[23*32]` / `[22*32]`，旧 26 项逐字未动） |
| 6 | `BUILD_ID_V` 自增 | ✅ `:3866` `8 → 9`（含版本行注释） |
| 7 | `_proj_pcie/rtl/axi_regs.v` | ✅ **功能上不需要改**（已核：`SNAP_NW` 由参数派生；`ar_word/w_word/r_word` 已是 **7 位**；`snap_base [11:0]` 装得下 `(63-1)<<5 = 1984`）⚠️ **其头部注释里"未实现地址 = 0x114"这一行已过时 —— 越界未改，登记在 §8** |
| 8 | `_proj_pcie/p7b_biz/p7b_snap.sh`（NW/EXPECT_BID/NAME） | ⛔ **越界未改**（§8 第①条；不做会**响亮失败**：`0x114` 现在会回真数据 ⇒ 身份闸/未实现地址闸当场红） |
| 9 | 4 个验收脚本的默认字数/未实现地址 | ⛔ **越界未改**（§8 第①条） |
| 10 | `check_window.py`（静态装配核对） | ✅ **跑了，PASS=42/FAIL=0**（该脚本本来就是 NW 参数化的，扩窗即自动跟随；见 §4.2） |
| 11 | 文档 | ✅ 本文 + `P7B_BIZ_WINDOW.md` §1（现役表） |

### 4.2 静态装配核对（`check_window.py`，跑了，未改）

```
  [PASS] 1 **总字数 == SNAP_NW_P6E** (项数=28, 逐项字数之和=63, NW=63)
  [PASS] 3 束宽等式 == NW (14+22+3+(24-4)+4 = 63)
  [PASS] 4 * 旧字未移位 (HEAD 的项 == 新表的尾部) (HEAD 26 项, 新表 28 项 => 新增 2 项全在 MSB 端)
  [PASS] 5a 最上面 12 项 = W62..W51 的槽 (MSB 先写)
  [PASS] 5b 槽号映射 W61 (p7bdp_din[22*32 +: 32] = biz_w61)
  [PASS] 5b 槽号映射 W62 (p7bdp_din[23*32 +: 32] = biz_w62)
  [PASS] 6 p7bdp_din 驱动项数 == SNAP_P7BDP_NW (generate 12 + 显式 12 = 24, NW=24)
  [PASS] 8 * 未实现地址不回绕 (addr=0x11C => word 71 < 2^7=128)
  [PASS] 8c snap_base 装得下 (NW-1)<<5 (need=1984 < 2^12=4096)
PASS=42 FAIL=0 / CHECK_WINDOW_PASS
```

⭐ 判据 4 是"**旧字逐项未动**"的**机械证明**（拿 `git show HEAD:board/wrapper_p4.v` 的项列表当尾部逐字比对）。

### 4.3 我另加的定向静态核对（`sim/p5wu_p1p2/check_wu_words.py`，14 判据，`PASS=14 FAIL=0`）

为什么必须另加一条（**覆盖面理由，不是重复劳动**）：`check_window.py` 的第 7 条只扫装配的**顶层项**
（`p7bdp_dout/txsnap_dout/p7bfe_dout/snap_dout` 四个名字）⇒ 它**看不到 `biz_w61/biz_w62` 有没有被声明**；
而**未声明的名字在 xvlog 下是合法隐式 1 位网**（rc=0、日志全空，坑 24）⇒ 只能静态守。本定向件核的是：

```
  [PASS] 1a SNAP_NW_P6E == 63 / 1b SNAP_P7BDP_NW == 24
  [PASS] 2 BUILD_ID_V == 9
  [PASS] 3a biz_w61/w62 在 `ifdef APP_MODE 块里声明 (非 APP_MODE 有 `else 兜常量)
  [PASS] 3c 非 APP_MODE 分支有 `biz_w61 = 32'd0` 占位 (防 X 传播)
  [PASS] 4 biz_w62 = {15'd0, app_rx_occ} (17 位显式零扩展)
  [PASS] 5 biz_w61 声明在两次使用之前 (decl=168129 assign=171012 asm=173552)
  [PASS] 6a/6b app_stat_wu / app_rx_occ 声明在别名之前
  [PASS] 7a/7b p7bdp_din[22/23] = biz_w61/w62 (槽号不串)
  [PASS] 8 装配最上两项 = W62/W61 (MSB 端先写) / 8b 最右一项仍是 snap_dout
CHECK_WU_WORDS_PASS
```

**负对照（判据有牙，4 个变异体，全部 exit=1）**：

| 变异 | 症状 | 结果 |
|---|---|---|
| `declpatho`（把 assign 里的 `biz_w61` 拼成 `biz_q61`） | "接线写了未声明网名"这一类 | ❌ FAIL（7a + 判据 5） |
| `narrow`（`{15'd0, app_rx_occ}` → `app_rx_occ`） | 17 位漏零扩展 | ❌ FAIL（判据 4） |
| `swap`（装配最上两项对调） | 新字错位 | ❌ FAIL（判据 8） |
| `nomode`（`ifdef APP_MODE` → `NOT_MODE`） | 丢守卫 ⇒ 非 APP_MODE 构建 X 传播 | ❌ FAIL（判据 3a） |
| `cmt_immu`（**在声明之前**加一段提到 `biz_w61/biz_w62` 的注释） | **这条期望 exit=0** —— 判据应**免疫**于"名字在别处被提到" | ✅ exit=0 |

⚠️ **最后一条是本轮自己踩出来的**：初版判据 3a/3c 用"名字**首次出现**处"当锚点 ⇒ 我给 W62 写契约登记注释
（在声明**之前**提到 `biz_w61`）之后，判据当场**假 FAIL**（`PASS=11 FAIL=2`）。
**修的是判据本身**（锚点改成"声明处" `wire [31:0] biz_w61`），并加 `cmt_immu` 把这条固化 ——
**注释不该让判据红**；反过来，也用这条证明"3a 的红是真红、不是文本巧合"。

### 4.4 读侧译码（`tb/tb_snap63.v`，26 项判据全过）

> 来源 = `_proj_10g/notes/p7b_biz_win/tb_biz_win.v`（NW=61）**复制 + 只改 NW 常数与 BUILD_ID 期望**
> （判据本体是 NW 参数化的，逐条未动 —— 这样"63 字下读侧无误"与"模板逐条同源"两件事同时成立）。

```
  [PASS] 3 W0..W62 共 63 字逐字一一对应 (无错位/无回绕)
  [PASS] 5a 末字 (0x20+4*62 = 0x118 = W62) 读得到
  [PASS] 6a 未实现地址 (0x11C = word 71) 回 0 / 6b rresp = SLVERR
  [PASS] 7a 0x200 rresp = OKAY (回绕别名是真实的) / 7b 0x200 别名回 word 0 = MAGIC
  [PASS] 7c 0x1FC (= 0x20+4*119) 仍未实现 ⇒ NW 上限 119 成立
  [PASS] 8b 写 0x108 = SLVERR (不是 SCRATCH) / 8c SCRATCH 未被 0x108 改到
  [PASS] 9b 写 0x118 = SLVERR / 9d done 未被 0x118 清掉 (⇒ 它没命中 SNAP_CTRL)
PASS_ALL  tb_snap63: 26 项判据全过 (窗口 63 字)
```

⚠️ **三处"判据结构性无牙"的复核（任务点名）—— 结论是"63 字下仍然守住"，理由逐条**：
1. **窗口吃满上限 ⇒ SLVERR 负对照恒不触发**：上限是读侧译码位宽决定的（7 位 ⇒ 字 0..127 可寻址，
   `SNAP_LAST_IDX = 8+63-1 = 70`）⇒ **未实现字 = 71 存在且可寻址** ⇒ 负对照有牙（判据 6 ✓）。
2. **6 位译码每 256 B 回绕别名**：BIZ 轮已把 `ar_word/w_word/r_word` 加宽到 **7 位**；本轮**复核不改**
   （`0x108 → word 66 ≠ 2` ⇒ SLVERR，判据 8b ✓；写 `0x118 → word 70` ⇒ 只是**已实现的快照字**，
   写通道只认 `w_word==2`(0x08) 与 `6`(0x18) ⇒ **SLVERR**，判据 9b ✓）。回绕红线仍是 **≥0x200**（判据 7 ✓）。
3. **`0x108` 别名到 SCRATCH（= `TX_DIS` 门）**：同上，已结构性排除；本轮**没有**碰写通道，判据 8 是回归 ✓。

### 4.5 ⚠️ 一条**契约登记**：W62 是组合派生，不是"寄存器输出"

`snap_cdc` 的文件头把前提写成硬要求：**"`din_b` 必须只在 `clk_b` 的沿上变化（即 b 域寄存器输出）"**
（`rtl/snap_cdc.v:18-19`），而既有几条束的注释都专门核过"源全是 dp 域寄存器输出"。
**本轮 W62 破了这条字面口径**：`app_rx_occ = {(eco_dbg_fifo_wptr - eco_dbg_fifo_rptr), 3'b0}`
（`board/wrapper_p4.v:1033`）是**组合减法**。

**判为可接受（两条理由，缺一不可；改口径的人必须同时改这两条）**：
1. **同域**：两个指针是 `tcp_echo u_tcp_echo (.clk(dp_clk))` 里 frame_fifo 的寄存器
   （`rtl/frame_fifo.v:291-292` 的纯 assign 引出）⇒ 减法是**同一时钟域内的普通组合路径**，
   `hold_b <= din_b` 是**同沿路径**、受 STA setup/hold 覆盖 ⇒ 采到沿前值、整字同拍 ⇒ **不存在 tearing**。
   （那条"毛刺会在锁存沿被采到"的警告针对**异步/异域**源。）
2. **有先例且已在产**：W49 (`rx_classify.dbg_occ = w_wptr - w_rptr`, `rtl/rx_classify.v:95`) 是
   **结构完全相同**的组合占用字，自 P7b 轮就在同一个 dp 束里 ⇒ **没有引入新缺陷族**。
⇒ 所以**不**为它加一级 dp 域寄存器（那要在余量 2.3% 的域里多 32 FF，换一个 STA 已保证的性质）。
⚠️ **未做**（如实）：没有跑 STA/构建 ⇒ 上面第 1 条的"受 STA 覆盖"是**论断**；
**构建后必须看 `u_snap_p7bdp/hold_b_reg[*]` 那族有无 setup/hold 违例**（DP 域）。

### 4.6 编译面（`sim/p5wu_p1p2/run_xvlog_wrapper63.bat`）

```
[OK  ] d0_default rc=0
[OK  ] d1_p7b rc=0
[OK  ] d2_app rc=0
[OK  ] d3_wu_full rc=0
XVLOG_WRAPPER63_PASS 4/4
```

**负对照（2 个）**：
- **版本指纹闸**：把源换成 61 字版 ⇒ `[FINGERPRINT FAIL] ... exit=92` ✓（防"编的是别的版本"的真空门）；
- **语法错（不碰指纹行）**：`wire [31:0] biz_w61 = app_stat_wu`（丢分号）⇒ d3 组合 `rc=1` ⇒ **整门 exit=1** ✓。
  ⚠️ 同一变异在 **d2（只 `-d APP_MODE`）下 rc=0** —— **这是结构性的，不是漏网**：整段快照（含新线）
  被外层 `` `ifdef PCIE_OBS ``（`board/wrapper_p4.v:3035`）包住 ⇒ "单 APP_MODE"构建根本**不编译**这段
  ⇒ **新字的编译面覆盖只来自 d3**。记在这里，免得下次有人拿 d2 的 PASS 当覆盖证据。
- **已知无覆盖（沿用 BIZ 轮的登记）**：**端口连接形式的静默截断（`VRFC 10-3091`）** 需要 `xelab/synth`
  过全套 IP ⇒ 属构建面（§6-①）；本轮的 `tb_snap63`/`check_*` 都不覆盖它。

---

## 5. 回归（跑过的门 + 读数）

| 门 | 命令（自定位） | 读数 |
|---|---|---|
| **首轮 WU 门**（必须仍过） | `cmd //c 'sim\p5wu\run_tb_app_wu.bat'` | **`P7B WU GATE OK`** —— `[WITNESS] danger-band sampled win: min=63 max=120 (40 scans)` · `fire#1 wu_mark=24695 @cyc~34850` · `lockstep violation cycles = 0` · `NEW notifications = 3 . OLD = 1`（⚠️ **与首轮 `P7B_WU_FIX.md` §4 逐字一致** —— 本轮的两处改动**没有**扰动首轮修复的现场模态与触发值） |
| 本轮 P1/P2 门（新） | `cmd //c 'sim\p5wu_p1p2\run_tb_wu_p1p2.bat'` | `P1P2 GATE OK`：**26 项全 PASS**、`lockstep = 0` |
| 快照 63 字读回门（新） | `cmd //c 'sim\p5wu_p1p2\run_tb_snap63.bat'` | `SNAP63 GATE PASS`（26 项） |
| 静态装配核对 | `python _proj_10g/notes/p7b_biz_win/check_window.py` | `PASS=42 FAIL=0` |
| 定向静态核对（新） | `python sim/p5wu_p1p2/check_wu_words.py` | `PASS=14 FAIL=0` + 4 变异体全红 |
| 编译面（新） | `cmd //c 'sim\p5wu_p1p2\run_xvlog_wrapper63.bat'` | `4/4` + 2 负对照 |
| **app_ctrl 流控单元门** | `cmd //c 'sim\p5sim\run_tb_p5_fc.bat'` | `P5 FC UNIT GATE PASS`（含 **T7a–T7d** wu 通路：`occ≥winq ⇒ 窗 0 ⇒ 重开触发 ⇒ gnt 清 ⇒ stat_wu +1` 全 PASS） |
| **P5 app 门**（含 `stat_wu==0` 硬判据） | `cmd //c 'sim\p5sim\run_tb_p5_app.bat'` | `P5 APP OK`；`winq0=c000 wu_mark0=c000 pool=00000 **stat_wu=0** stat_fc_upd=3`（健康流零额外 wu 保持 ✓） |
| **P5 流控闭环门** | `cmd //c 'sim\p5sim\run_tb_p5_flow.bat'` | `P5 FLOW OK`（`wu_mark0=60e0`；窗口序列 `[0, 368, …]` 含"关到 0 再重开"） |
| **P5d 多连接门** | `cmd //c 'sim\p5d_multi\run_tb_p5_multi.bat' main` | `122 checks, 0 FAIL`（`wq_cap=0x4000`、分池/裕度/物理界/close/drift 全过） |
| **P5 对抗集** | `cmd //c 'sim\p5sim\run_tb_p5_adv.bat' multi` | `P5 ADV[multi] OK` |

⚠️ **回归面的诚实边界**：**没有跑**全仓 16 门 P4 矩阵（`run_matrix_p4dfix.bat`，~25 min）与 `p5_wrapper`/`p5_status`/`p5_pattern` 门
（`app_ctrl` 不在默认构建路径里，但这些门里也有 APP_MODE 支）⇒ 见 §6-⑤。

---

## 6. ⚠️ 我没能证明的部分（**不许当已答**）

1. **没跑构建、没上板、零位流、零板级读数** ⇒ 以下全是**推断**，不是读数：
   ① 新线/新字的**板级**读写（身份闸 `0x04=9`、`0x114`/`0x118` 读回、`0x11C` 回 `0xffffffff`）**一次都没测**；
   ② **DP 域时序未收口** —— 本轮给 DP 域加的是 **16 FF + ~2 级 LUT**（`wu_act` mux + 一级 NOR + 一个与门），
   而 **DP 域 `g_hw.clk_out0` 已经是全局最差（WU 构建 WNS `+0.147 ns` = 周期 2.3%）**；
   `P7B_WU_TIMING_DELTA.md` §5.3 的"真实成本 ≈ 320 FF/字（其中 96 FF 落 DP 域）"意味着**本轮 +2 字 ≈ +192 FF
   （DP 域 +64）**，加上 P2 的 16 FF ⇒ **DP 域约 +80 FF**。
   ⇒ **必须由一次构建收口**（`三类失败端点 0/0/0` + `P7B_WNS` 读数），且**不许**把本轮的"仿真全绿"读成"时序没事"。
   ③ `tb_snap63` 例化的是 **`axi_regs`**，不是真 wrapper ⇒ **装配那一半**只由 `check_window.py` + `check_wu_words.py`
   静态核（这是 BIZ 轮定下的分工，不是本轮新增的缺口）。
2. **P1 无法板级触发**：板上默认 `WIN_POOL = 49152`、`wq_cap_r` 由 app 写 `池/N`（N ≤ 16）⇒ `winq ≥ 3072 ≫ 8`；
   `winq ≤ 3` 要 app 自己写 `0x0C ≤ 3`（配置错误）或池被占满的瞬态 ⇒ **只有 TB 能触发**（本轮 TB 已给反例+对照）。
3. **P2 只证到"空转连接不武装"这一格**；§2.4 的三条残留**没有**实验证据（没有多连接+共享占用的长跑，
   也没有"零窗探询"的板级场景）⇒ 它们是**分析 + 机制推断**，别当读数用。
4. **`stat_wu` 与"线上真的多了一条 ACK"之间没有任何本轮读数**：`stat_wu` 的语义 = "wu 条目确实入了 ackq"
   （不是"已上线"）⇒ 下一轮拿到板级读数时，仍需要 **对端 pcap 的同一时间窗**才能把"入了 ackq"接到"发出去了"
   （`app_ctrl` 的下游是 `tcp_tx_frame.wu_push`；本轮**未做**这半段的实验，首轮对抗审查 §4-6 也登记过同一盲区）。
5. **未跑的门**：全仓 `run_matrix_p4dfix.bat`（16 门）· `run_tb_p5_wrapper.bat` · `run_tb_p5_status.bat` ·
   `run_tb_p5_pattern.bat` · `p5d_multi` 的 4 个负对照档 · `tb_snap_cdc`/`tb_snap_seq`（本轮**没动** snap_cdc/snap_seq 的语义，
   只改了 `NW` 参数值与两束项数）⇒ 这些是 TL/下一轮的回归面。
6. **`W61/W62` 的实际读数含义未定标**：`rx_occ_bytes` 是**字节**、17 位；`stat_wu` 是**次数**。
   本轮只保证"接线与语义正确、装配未错位"，**没有**任何板级标定（例如"塌陷期 `stat_wu` 增量 ≈ 1/周期"这种断言，
   需要板上跑一次 j6 阶梯才有）。

---

## 7. 交付文件清单（含指纹）

| 文件 | 动作 | sha256 前缀 | 大小 |
|---|---|---|---|
| `rtl/app_ctrl.v` | 改（P1/P2 + 注释注册） | `871eab125a28f325` | 90,259 B |
| `board/wrapper_p4.v` | 改（61→63 / W61,W62 / BUILD_ID 9） | `a9231144070caa8f` | 233,044 B |
| `tb/tb_wu_p1p2.v` | 新（三臂 P1/P2 门） | `e1466a51768c198a` | 20,795 B |
| `tb/tb_snap63.v` | 新（63 字读回门，由 `tb_biz_win.v` 复制） | `c14d19f2ae38f800` | 13,304 B |
| `sim/p5wu_p1p2/app_ctrl_base.v` | 新（**`git show 95c9485:rtl/app_ctrl.v` + 仅改名**；负对照臂） | `d26e4a0f3d006040`（源内容 sha256 前缀 `c38b3b96`） | 84,674 B |
| `sim/p5wu_p1p2/run_tb_wu_p1p2.bat` · `run_tb_snap63.bat` · `run_xvlog_wrapper63.bat` | 新（3 个自定位 runner，ASCII+CRLF） | —— | —— |
| `sim/p5wu_p1p2/check_wu_words.py` | 新（14 判据 + 5 变异/免疫对照） | `017d1731c200bb33`（含 §4.3 的锚点修复） | —— |
| 本文件 + `P7B_BIZ_WINDOW.md` §1（现役表） | 新/改 | —— | —— |

**未改**（越界，见 §8）：`rtl/app_pattern.v` · `rtl/tcp_tx_frame.v` · `_proj_pcie/rtl/axi_regs.v` ·
`_proj_pcie/p7b_biz/p7b_snap.sh` · `_proj_pcie/p6e_snap_check.sh` · `p7b_gate4_accept.sh` ·
`p7b_gate4_selftest.sh` · `_proj_10g/notes/p7b_gate4_3/final_state.sh` · `_proj_10g/notes/p7b_biz_win/*`（只跑不改）。

---

## 8. TL 必须跟着做的（**不做就是"判据安静失效"**）

① **取数器/验收脚本的 `NW` 与 `EXPECT_BID`**（本轮越界未改）：
`_proj_pcie/p7b_biz/p7b_snap.sh:33-35`（`NW=${NW:-61}` → `63`、`EXPECT_BID` → `9`、`NAME` 数组补 `W61/W62`）、
`_proj_pcie/p6e_snap_check.sh:53`、`_proj_pcie/p7b_gate4_accept.sh:109`、`_proj_pcie/p7b_gate4_selftest.sh:31`、
`_proj_10g/notes/p7b_gate4_3/final_state.sh:14`（`rd 0x114` → `0x11C`，接口行加 `W61/W62`）。
**好消息：忘了改会响亮失败**（`0x114` 现在回真数据 ⇒ 未实现地址负对照红；`EXPECT_BID=8` ⇒ 身份闸红），
**不会静默误判**。
② `_proj_pcie/rtl/axi_regs.v` 的**头部注释**（功能未动）：`未实现地址 = 0x114` → `0x11C`，补 W61/W62 两行。
②b **文档里的现役窗口口径**（本轮越界未改）：`_proj_10g/notes/P7B_HANDOFF.md`（"窗口 61 字 / 未实现 0x114 /
`BUILD_ID=8`" 那些行）与 `udp_hls_10g/CLAUDE.md`（同款句子）⇒ 一律改成 **63 字 / `0x11C` / `9`**
（⚠️ 这两个文件本轮**都有别的 agent 在写**（DOCFIX4），别盲改，先核 `git status`）。
③ **一次合体构建收口**（§6-①）：看 `P7B_WNS` / `三类失败端点 0/0/0`；⚠️ 本轮同时有别的 agent 在改
`rtl/app_pattern.v`/`tcp_tx_frame.v`（Gap#9 方向）⇒ **构建前先核 `git status` 与改动归属**。
④ 下一轮板级：身份闸读 `0x04` 必须是 `9`、窗口 **63** 字、未实现地址 **`0x11C`**；
⭐ **一次 j6-ladder 读数即可把"wu 机理"从推断升为观测**（`ΔW61` 与 `ΔW62` + 对端 pcap 同窗）。
⑤ 若要判据级 FROZEN 回归：跑全仓 16 门矩阵（本轮未跑，§6-⑤）。
⑥ **`.gitignore` 未改**（越界）：新目录 `sim/p5wu_p1p2/` 不在现役忽略规则里（旧轮是 `sim/p5wu/*`，`.gitignore:646`）。
本目录里 `run/` `runsnap/` `work_xvlog/` 是**可重跑的产物**（本轮把它们留作读数原件，与 `sim/p5wu_review/runrev2/` 同惯例）
⇒ 建议照旧轮加一条 `sim/p5wu_p1p2/*` + `!` 例外（保留 3 个 `.bat`、`check_wu_words.py`、`app_ctrl_base.v`、
以及 `*/xsim_*.log` 之外的两份读数若要留档则反选）。**加规则是 TL 的事**（我把它们留在盘上，不擅自改 `.gitignore`）。

---

## 9. 本轮踩到并固化的两条（给下一个人）

1. **`tb` 的 `chk` task 里 `input [255:0] name` 只能装 32 字节** ⇒ 更长的判据名被**截掉前缀**（Verilog 取低位），
   日志里读成**另一个名字**（本轮首跑实测：`"PH1d DUT progress flag set"` → `"progress flag set"`）。
   ⇒ 判据名要么 ≤32 字符，要么把形参加宽（本轮改成 `[511:0]`）。**判据名被截 = 判据读数不可读**，
   与"空判据"同族，别留。
2. **"两个槽同时挂起 wu" 时不能用 `wu_req` 的上升沿计数**：round-robin 换 id 时电平**不落沿** ⇒ 漏计
   （本轮 PH2 一开始就会踩）⇒ 口径改成**每个槽 `wu_pend[c]` 的 0→1**（= C6"确实触发了一次通告"）。
   ⚠️ 这条也可能影响既有门的读法（`tb_app_wu` 的 `wu_req` 沿计数**恰好**没踩到，因为它每次只让一个槽挂起）。
3. **静态判据的锚点要用"声明处"，不能用"名字首次出现处"**：本轮我给 W62 写契约登记注释（在声明**之前**
   提到 `biz_w61`），自己写的 `check_wu_words.py` 判据 3a/3c 当场**假 FAIL**。
   ⇒ 凡是"找某个名字"的文本判据，锚点一律取**句法位置**（`wire [31:0] <name>` 之类），并给一条
   **"注释里提到这个名字 ⇒ 判据必须仍然绿"** 的免疫对照（`cmt_immu`）。**判据被注释绊倒 = 判据缺陷。**

---

## 10. ⛔ 订正节（2026-10-07 二轮修补轮 F2/F1；**只加不覆盖**）

- 本件其余章节**一字未动**。本节由**修补轮**追加，性质 = 对抗审查（`P7B_WU_P1P2_REVIEW.md`）两条真问题的落地：
  **F2**（本件 §1.2 的"净损失消除"对 `winq == 0` 不成立）+ **F1**（`wrapper_p4.v` 注释加法算错）。
  完整施工与证据 = **`P7B_WU_F2_F1_FIX.md`**。

### 10.1 对本件两处**声称**的订正（原文保留在 §1.1/§1.2，按本节的读法引用）

| 处 | 原文（保留） | 订正后的精确读法 |
|---|---|---|
| §1.1 机理行 | "修复前 `pb_wscan == 0` 至少能发 1 次 ⇒ **净损失**" | **只对 `winq ∈ {1,2,3}` 成立**。`winq == 0` 时 `wscan ≡ fq_calc(0, oc) ≡ 0`（`rtl/app_ctrl.v:638-645`）⇒ **修复前那条 `wscan == 0` 也是恒真** ⇒ `else if` 同样永不求值 ⇒ **三版都不发**（不是回归，但也不是"净损失"） |
| §1.2 末条 | "`winq/4 == 0` 时…退化为 `wscan == 0` = 修复前那条 ⇒ 可达性恢复（**净损失消除**）" | 同上：**`winq ∈ {1,2,3}` 可达性恢复**；`winq == 0` 一档**由 F2 显式改写为"永不发"**（整块 `if (winq[pb_sid] != 16'd0)`，`rtl/app_ctrl.v:1296`），理由 = 零配额时 `wscan ≡ 0`、没有任何东西可通告 |

### 10.2 F2 修完后的读数（本件未覆盖的一档）

- **等价性（穷举）**：`sim/p5wu_f2fix/f2_equiv.py` → 全 **2³² 格点**上，`winq != 0` 的全部取值
  武装/触发谓词与二轮修前**逐位相同（差异数 0）**；`winq >= 3072` 子域差异数 **0**；只有 `winq == 0` 一档变。
  ⇒ **产品配置逐位不变**（本件 §1.2 的"产品配置逐位等价"结论**仍然成立**，且现在覆盖到退化档的边界）。
- **TB 逐字对照**（`tb/tb_wu_f2.v`，`F2 GATE PASSCOUNT 38` / `F2 GATE OK`）：
  `winq=0` 档 `wu_zero`：修前 **1**（每扫描拍重写）/ 修后 **0**；两版 `wu_pend` **都 0 次**。
  负对照两侧：变异体（`end else if`→`end if`）在 `winq=0` **发 6 次**（证明 0 次不是空判据）；
  `winq ∈ {1,2,3,0xC000,0xC00}` 两臂**都发 1 次**（证明 F2 没关掉可达路径）。
- **审查的 `winq0` 探针**（`sim/p5wu_p1p2_review/tb_rev_p1_winq0.v`，**只读跑、未改**）现在 **W0c 翻红**
  （它断言的 `dut wu_zero[1]=1` 就是被 F2 改掉的那个态），W0a/W0b/W0d 仍 PASS ⇒ **按定义红，不是回归**。
- ⚠️ **本件 §5/§6 的口径不变**：仍然**无构建、无板级** ⇒ 时序增量（F2 的 guard = 一级 16 输入或非门 + 两个与门）
  **未判定**，与 P1/P2 的增量子项一并由下一次构建收口。

### 10.3 交付与纪律（补齐本件 §7 的清单）

`rtl/app_ctrl.v`（功能 +1/−0 行 + 注释）/ `board/wrapper_p4.v`（**仅注释** F1）/ `tb/tb_wu_f2.v`（新增）/
`sim/p5wu_f2fix/`（新增：`run_tb_wu_f2.bat` · `app_ctrl_prefix.v` 快照 · `app_ctrl_mut.v` 变异体 ·
`f2_equiv.py`/.log · `f2_rtl_diff.txt`）。**均未提交**；未碰 `sim/p5wu_p1p2_review/`（只读跑）/
`README.md` / `P7B_LATENCY_RXTX.md` / `P7B_WU_P1P2_TOOLS.md` / `sim/p5wu_p1p2_regress/`；未写 `0x08`。
