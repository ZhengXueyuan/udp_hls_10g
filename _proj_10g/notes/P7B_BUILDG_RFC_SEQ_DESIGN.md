# P7B_BUILDG_RFC_SEQ_DESIGN —— Build G：`tcp_rx` 两处绝对比较 → RFC 相对比较 + 「让它有牙」的观测量设计

- 轮次：**P7b 设计研究轮（2026-10-10，Build G 派单）**。派单 = 「① 现核 / ② RFC 正确形式 / ③ 计数器设计 /
  ④ 负对照与门 / ⑤ 注释订正 / ⑥ 未定不做的」。
- **本轮纯纸面**：**未改 `rtl/`、未改 `tb/`、未构建、未跑 xsim、未上板、未碰对端**。本文件是**唯一新增件**。
  所有源码引用都是**逐字读值**（带 `文件:行号`），所有板级数字都是**引用既有原件**（逐处标出处）。
- **基线（本轮现核，工作树 = 构建 F 态）**：
  - `rtl/tcp_rx.v` sha256 `b080c5df8dd9178a9a3859719f0021a2bccbbaab996eebefa1bc65365916b580`
    （git blob `0b95ff90eb2f61817adfffcdba5d0837dfec17d6`；**≠ HEAD** `dedc9234…` ⇒ F 改动**未提交**）
    ⛔ **2026-10-10 订正（构建 F 轮：已随 `34fb68b` 入库 ⇒ 工作树 = HEAD）**：本行判断**已过时** —— 现核 `git hash-object rtl/tcp_rx.v` = `0b95ff90…` = `git rev-parse HEAD:rtl/tcp_rx.v`（**逐字相同**）、`git status --porcelain -- rtl/` 为空 ⇒ **F 改动已提交、工作树 = HEAD**（`dedc9234…` 是**提交前**的旧 HEAD）。**原句保留**。
  - `rtl/tcb.v` sha256 `a449d1ef6ec4f200d161c333f3e05edb0fa54d5d780737eff1fc9bf7aa745d68`
  - `board/wrapper_p4.v` sha256 `fe75b74751d84b8803817ccced27f317a804bd2559f3a2434841b41e9c5d15d7`
  - 现役窗口 = **70 字 / `BUILD_ID_V = 0x1A` / 未实现地址 `0x138`**（`board/wrapper_p4.v:3228/4050`）
  - 上游登记 = `_proj_10g/notes/P7B_OPEN_ITEMS.md` §1-**A8**（表行 = `:27`）；设计前身 = `P7B_L_INSTRUMENT_DESIGN.md` §4.1
- **标签约定**：【事实】= 源码逐行读值 / 既有原件读数（带 `文件:行号`）；【推演】= 由【事实】按逻辑或算术推出，
  **未经仿真或综合**；【需仿真/综合】= 必须跑 xsim 或 Vivado 才能定；【未量】= 没量到，**不猜**。
- ⛔ **裁定权不在本件**：本件**不下任何 PASS/FAIL**；判据的所有权与裁定权在用户/TL。

---

## §0 结论速览（一页）

| 问 | 结论 | 依据 |
|---|---|---|
| 登记的"**两处**绝对比较"是什么？ | **一处定义 + 两处判据位点**：唯一绝对比较是 `seq_lt`（`rtl/tcp_rx.v:305`）；它的两个消费者 = `w6a_ok` 尾项（`:334-335`）与 `ackresp`（`:347-348`）。**修好那一处定义 = 两处判据同时修好**（1 行改动） | §1.3 |
| 登记的行号能用吗？ | **不能**：`P7B_OPEN_ITEMS.md:128` 的 `:283-284`/`:307-308` 与 `P7B_LONGSEND_ACCEPT.md:158` 同款，都是**两代之前的行号**（对 HEAD）；对**工作树**差 **+21 行**（`:305`/`:334-335`）。照抄行号会改错地方（⛔ **2026-10-10 订正（构建 F 轮）：F 已随 `34fb68b` 入库 ⇒ 工作树 = HEAD ⇒ "对 HEAD" 与"对工作树"**已是同一列**、登记行号对**现 HEAD** 同样差 +21；**原句保留**）| §1.1 勘误表 |
| RFC 正确形式 | `seq_lt := seq_diff[31]`（= `$signed(seq32-ra_rcv_nxt) < 0`）。**不新增宽运算**（`seq_diff` 已存在于 `:296`），并**删掉一个 32 位比较器** | §2.1 |
| `d = 0x80000000` 判什么？ | 判 **`seq_lt = 1`（"旧段"）**——理由 = ①逐字对齐 `$signed` 语义；②**零额外逻辑**（另一约定要加 32 位相等比较）；③合法对端**结构性到不了**（板 `rcv_wnd ≤ 61440 ≪ 2³¹`）；④两种选择的后果都只是"给一个畸形段回不回 ACK"，RFC 两种都允许 | §2.2 |
| 哪些输入行为会变？ | **只有 `(seq32−rcv_nxt)` 作为普通整数落在「≥ +2³¹ 或 > 2³¹ 反方向」的输入**（= 两值分处 2³¹ 圆环两半）。**等价域 = `−2³¹ ≤ seq32−rcv_nxt ≤ 2³¹−1`（逐位相同，已证）**；回卷角例恰在等价域之外 | §2.4、§2.3 |
| 改了之后**没有判据**怎么办？ | 新增 **1 个 32 位计数器 `stat_absrej`（W70）**：数的是"**该 w5 样本在修复前语义下会被静默误拒、而 RFC 语义认为它是旧段**"的帧数。谓词 = `base_ok && seq_diff[31] && !seq_lt_abs && (某支路条件)`（§3.1 逐字）。**两臂（修复前/后）谓词相同** ⇒ 读数可比；**非结构性恒 0** | §3.1、§3.4 |
| 与 W0..W69 重叠吗？ | **不重叠**：70 字里没有任何字带 seq/段分类语义；**最近的 W23（`rx_stat_nonmatch`）是"上游宽口径"**——修复前该类事件落 W23，**修复后改落 `stat_drop_seq`，而后者根本不在窗口里** ⇒ 新字是修复后**唯一**还跟踪该类的仪器 | §3.2 |
| 扩窗代价 | 现役 **70 → 71 字**（新字落 **dp 束槽 30 = W70 @ `0x138`**），未实现地址 `0x138 → 0x13C`，`BUILD_ID_V 0x1A → 0x1B`。FF = **128/字**（快照通路 96 = 32 dp `hold_b` + 32 pcie `dout_a` + 32 pcie `snap_words_r`；计数器本体 32 dp）⇒ **DP 域 64 + pcie 域 64** | §3.5、§3.7 |
| 门怎么建？ | **必须新建独立门**（`sim/p7bg_seqwrap/`）：A 臂 = 现役 RTL、**G 臂 = 冻结的修复前 RTL**、+4 个变异体；`A=RC0 / G=RC≠0 且红点恰好是 {F1,F2,F5} 三帧`。理由：现成门 `sim/p3sim/run_tb_tcp_rx.bat` **已经是红的**（`P7B_REGRESSION.md:219`，RC=1/既存）⇒ 挂在它上面等于"红里套红"，读不出来 | §4.1、§4.4 |
| ⭐ 谁被漏了？ | **门的 oracle 本身站在错的一边**：`tools/gen_stim_tcp_rx.py:445` 的 `seq_lt = seq32 < t['rcv_nxt']` 也是**绝对比较** ⇒ **必须与 RTL 同批改**，否则修复后模型与 RTL 打架（且此前的红会被"换个形状复发"）。且该模型**根本没有实现 `w6a_ok`**（`grep -c w6a` = **0**） | §4.5 |
| 时序 | ⛔ **不许写"时序已解决"**。风险在 **pcie 侧 `bbstub_axi_aresetn` 的 Recovery 族**（F 档全局 WNS `+0.111` 就是它，`:107-124` 的读数）——每个新字往这条网上再挂 64 FF。【需综合】 | §3.7 |

---

## §1 现核（先做）

### 1.1 行号勘误表（⭐ 照抄登记行号会改错地方）

| 内容 | 登记写的（`P7B_OPEN_ITEMS.md:128` / `P7B_LONGSEND_ACCEPT.md:157-158`） | **HEAD**（`dedc9234…`） | **工作树 = 构建 F**（现役，`b080c5df…`） |
|---|---|---|---|
| `seq_diff` 定义 | （未登记） | `rtl/tcp_rx.v:275` | **`rtl/tcp_rx.v:296`** |
| `seq_eq` | （未登记） | `:283` | **`:304`** |
| **`seq_lt` 定义** | `:283-284` | `:284` | **`:305`** |
| **`w6a_ok` 尾项 `\|\| seq_lt`** | `:307-308`（原文注为"注释块"） | `:313-314`（`:306-312` 是注释块） | **`:334-335`** |
| `ackresp` | （另处引作 `:326-327`，见 `P7B_L_INSTRUMENT_DESIGN.md` §4.1） | `:326-327` | **`:347-348`** |

> ⛔ **2026-10-10 订正（构建 F 轮：已随 `34fb68b` 入库 ⇒ 工作树 = HEAD）**：上表**"HEAD（`dedc9234…`）"列**是**提交前**的 HEAD 读数；提交后 **HEAD = 原"工作树 = 构建 F"列（`b080c5df…`）** ⇒ **两列现已合一**（**现役行号 = 原"工作树"列**，即 `:296` / `:304` / `:305` / `:334-335` / `:347-348`）。**原句保留**。

- 位移 = **+21 行**（来源 = 构建 F 在 `:132-152` 新加的 `stat_ack_adv` 端口注释块 21 行，**未提交**）。⛔ **2026-10-10 订正（构建 F 轮）：该 21 行已随 `34fb68b` 入库 ⇒ 不再是"未提交"（工作树 = HEAD）；+21 的位移量本身不变。原句保留。**
- 【事实】`git log --oneline -3 -- rtl/tcp_rx.v` 顶条 = `92cbeee`（RETXFIX r6-fix）；HEAD 的 tcp_rx **不含** F 的两个新端口。⛔ **2026-10-10 订正（构建 F 轮）：现核顶条 = `34fb68b`、且 `grep -c stat_ack_adv rtl/tcp_rx.v` = 3 ⇒ 现 HEAD 的 tcp_rx **已含** F 的两个新端口（`92cbeee` 是**提交前**的顶条）。原句保留。**
- ⇒ **施工以本件的行号（工作树）为准**；若先提交了 F，则行号以 `git show HEAD:rtl/tcp_rx.v | grep -n` 现取。⛔ **2026-10-10 订正（构建 F 轮）：该条件**已发生**（`34fb68b`）⇒ 工作树 = HEAD ⇒ **本件行号 = HEAD 行号**（两列合一、无需现取）；仅当**再改** RTL 后才须按 `git show HEAD:<file> | grep -n` 现取。原句保留。**
- ⚠️ 另：`:307-308` 即便对 HEAD 也**不是代码行**（是 P4d-fix 注释块的头部）。**"两处绝对比较"这个说法本身也需要澄清**（见 §1.3）。⛔ **2026-10-10 订正（构建 F 轮）：该"HEAD"指**提交前**的 `dedc9234…`；换到现 HEAD（= 原"工作树"列）后，登记号 `:307-308` 仍落注释块（现 HEAD 的 P4d-fix 注释块 = **`:306-319`**）⇒ **实质结论不变**，只需把"HEAD"的指代写清。原句保留。**

### 1.2 逐字原文（工作树；`rtl/tcp_rx.v` = **CRLF**，见 §1.5）

下段每条 = `工作树行号` + `:` + **逐字内容**（含中文注释与行内注释，未改一字；行之间被跳过的行用 `...` 标出）：

```
296:    wire [31:0] seq_diff = seq32 - ra_rcv_nxt;
302:    wire [16:0] acc_wnd  = {1'b0, ra_rcv_wnd} + {1'b0, ACC_MARGIN};
303:    wire        win_ok   = (seq_diff < acc_wnd);
304:    wire        seq_eq   = (seq32 == ra_rcv_nxt);
305:    wire        seq_lt   = (seq32 < ra_rcv_nxt);   // 重复/旧段 (回绕安全: 无符号比较)
...
320:    wire [31:0] ack_hi   = ra_retx_active ? ra_retx_hi : ra_snd_nxt;
321:    wire        ack_ok   = ((ack32 - ra_snd_una) <= (ack_hi - ra_snd_una));
322:    wire        ack_adv  = ack_ok && (ack32 != ra_snd_una);
323:    wire [15:0] plen_w   = w2_r[63:48] - 16'd40;
325:    wire        base_ok  = cam_hit_l && state_ok && flags_ok && doff_ok && len_ok &&
326:                           frag_ok;
334:    wire        w6a_ok   = base_ok && (plen_w == 16'd0) &&
335:                           ((seq_diff <= {16'b0, ra_rcv_wnd}) || seq_lt);
338:    wire        dup_ack  = base_ok && (plen_w == 16'd0) && ack_ok && !ack_adv &&
339:                           (ra_snd_nxt != ra_snd_una);
340:    wire        acc      = base_ok && win_ok && seq_eq;
347:    wire        ackresp  = base_ok && (plen_w != 16'd0) &&
348:                           ((!seq_eq && (win_ok || seq_lt)) || (seq_eq && !win_ok));
```

**声明处 / 驱动者（谁在驱动它）**：

| 信号 | 声明/驱动处 | 上游 |
|---|---|---|
| `seq32` | `:289` `wire [31:0] seq32 = {seq_hi_r, s_axis_tdata[63:48]};` | `seq_hi_r` 声明 `:204`（`reg [15:0] src_port_r, seq_hi_r, dport_r;`），驱动 `:673`（w4 分支 `seq_hi_r <= s_axis_tdata[15:0];`） |
| `ra_rcv_nxt` | 端口 `:72` | `tcb.v:108` `assign ra_rcv_nxt = rcv_nxt_r[ra_id];`（阵列 `tcb.v:78`） |
| `ra_rcv_wnd` | 端口 `:75` | `tcb.v:111` ← `rcv_wnd_r`（`tcb.v:81`） |
| `ra_snd_una` / `ra_snd_nxt` | 端口 `:74` / `:73` | `tcb.v:110` / `:109` |
| `ra_retx_hi` / `ra_retx_active` | 端口 `:79` / `:80` | `tcp_tx_frame.o_retx_*`（wrapper 接线；`:78-80` 端口注） |
| `seq_diff` | 组合 `:296` | `seq32` − `ra_rcv_nxt` |
| `w2_r` | `reg [63:0]` 声明 `:199`，驱动 `:646`（w2 分支 `w2_r <= s_axis_tdata;`） | `plen_w`（`:323`）= `w2_r[63:48] − 40` |
| `cam_hit_l` / `conn_id_l` | 声明 `:207-208`，驱动 `:669-670`（w4 分支） | `cam_q_hit`/`cam_q_id`（`:122-123` 端口 → `tcp_cam`） |
| `acc_wnd` | 组合 `:302` | `ra_rcv_wnd` + 端口 `ACC_MARGIN`（`:37`；wrapper 送 `acc_margin_eff`，`board/wrapper_p4.v:1811`，例化点 `:1807`；⚠️ **板上 ≠ TB 的 `16'd0`** —— 板侧是动态值，单元 TB 显式传 `16'd0`，`tb/tb_tcp_rx.v:117`） |
| `state_ok` | `:294` `(ra_state == ESTAB)`；`ESTAB = 4'd1` 定义 `:194` | — |

**latch（w5 拍 → w6 拍）**：`:682-692`（`acc_l/ackresp_l/ack_adv_l/dup_l/ackok_l/w6a_ok_l`）；**复位清位** `:479-480`。

### 1.3 ⭐ 这两处比较**具体在哪个判据里起作用**（调用链）

**唯一的绝对比较 = `seq_lt`（`:305`）**；它进**两条判据**：

**链 A —— 数据段的接收决策（`ackresp`）**：
```
seq_lt (:305) ─┐
win_ok (:303) ─┼→ ackresp (:347-348) ──[w5→w6 latch :683 `ackresp_l <= ackresp`]──┐
seq_eq (:304) ─┘                                                                  │
      ┌───────────────────────────────────────────────────────────────────────────┘
      ├─ 非 tlast 的 w6 拍: :754-756  `state <= S_DROP; drop_ack <= 1'b1; stat_drop_seq <= +1`
      └─   tlast 的 w6 拍: :725-726  `else if (ackresp_l) stat_drop_seq <= +1`
                ↓
   S_DROP 的 tlast 拍 (:900-906) ⇒ `ack_req` 第三项 :396 `(state==S_DROP) && accept && tlast && drop_ack && s_axis_tcrs`
                ↓
   `ack_req / ack_id / ack_val` (:389-398; `ack_val = rcv_nxt_l`)，计数 `stat_ack <= +1` (:604)
```
⇒ 结论：**数据段的接收决策 = 「不回 ACK 静默丢」 vs 「回 ACK 但照样不交付」**。载荷交付走 `acc`（`:340` = `base_ok && win_ok && seq_eq`）——**`acc` 不含 `seq_lt`**，所以**修复不改变"交付/不交付"**（该帧本来就不是顺序段）。

**链 B —— 纯 ACK 帧（`plen_w == 0`）的接收决策（`w6a_ok`）**：
```
seq_lt (:305) ─┐
seq_diff (:296)┼→ w6a_ok (:334-335) ─[latch :692 `w6a_ok_l`]─┐
ra_rcv_wnd ────┘                                              │
   ┌──────────────────────────────────────────────────────────┘
   ├─ w6 拍 tlast: `fend_w6a` (:377-378) ⇒ 进 `fend` (:379)
   └─ w6 拍非 tlast: :748-752 `state <= S_PAD` ⇒ 帧尾 `fend_pad` (:370) ⇒ 进 `fend`
                        ↓
   `fend` (:502) ⇒ pend 置位: `pend_una <= (ack_adv_l && s_axis_tcrs) || pend_una` (:508)
                            `pend_wnd <= s_axis_tcrs || pend_wnd` (:509)
                        ↓
   drain FSM (:526-538) ⇒ TCB 写口 `upd_*` (:464-469) ⇒ **`snd_una` / `snd_wnd` 推进**
```
⇒ 结论：**纯 ACK 帧的接收决策 = 「该帧的 ACK/window 字段是否被处理」**（这是 `snd_una` 推进的唯一途径之一，`:327-333` 的注释逐字说明了这一点）。

**第三处（被动）引用**：注释 `:344-345` 把 `!seq_lt` 当作"**远超前段**"的定义
（`(!seq_eq && !win_ok && !seq_lt) 仍不回 ACK (与原语义一致)`）。⚠️ 严格说这句**措辞不准**：
`:757-760` 的 `else` 支路实际是"**没被 acc / w6a_ok / ackresp 收下的都在这里**"的兜底，
不只"远超前段"（例如 `plen=0` 且 w6a_ok=0 的距离过远纯 ACK 也落这里）。⇒ 进 §5.2 清单。

**不在链上的**（澄清）：`dup_ack`（`:338-339`）**不含 `seq_lt`**；`ack_ok`/`ack_adv`（`:321-322`）**已是相对差**；
`win_ok`（`:303`）用的是**相对差 `seq_diff`**。⇒ 登记的那句"主体已经是相对差"【成立】。

### 1.4 登记陈述逐条判定

| `P7B_OPEN_ITEMS.md` §1-A8 的陈述 | 判定 | 依据 |
|---|---|---|
| "主体（`tcb.v:142` `win_diff`、`tcp_rx.v:303` `ack_ok`）= 相对差 ⇒ 安全" | **内容成立；行号全错**（`win_diff` 在工作树 `tcb.v:**151**`；`ack_ok` 在 `tcp_rx.v:**321**`） | §1.1 + `tcb.v:151`（`wire [31:0] win_diff = snd_nxt_r[win_id] - snd_una_r[win_id];`） |
| "两处绝对比较 = `:283-284`（`seq_lt`）与 `:307-308`（`w6a_ok` 尾项）" | **一半对**：`seq_lt` 确是一处**定义**；`w6a_ok` 尾项是它的**消费者**，不是第二处独立比较。行号亦错（→ `:305` / `:334-335`） | §1.3 |
| "后果限于：回卷后重发旧段被静默忽略（不回 ACK），不是数据损坏" | **成立**（链 A 逐拍可推：`:757-760` 走 `stat_drop_nonmatch`，无 `ack_req`）。⚠️ **不完整**：还有**链 B**（纯 ACK 被拒 ⇒ `snd_una`/`snd_wnd` 不推进）与**两个次生后果**（`:545` dup-ACK 计数、`:594-595` `ack_obs`）——见 §2.5 | §1.3、§2.5 |
| "`:284` 注释逐字写'回绕安全: 无符号比较'，措辞过宽" | **成立**（工作树在 `:305`，逐字相同） | §5.1 |
| "236 s / 62 次 2³² 回卷未观测到任何痕迹（`ΔW23` 恒 0 等）" | **成立**，但**只能说"未观测到"** | `P7B_LONGSEND_ACCEPT.md:163`（L1 `ΔW11/ΔW13` 那条是另一件事） |
| "板侧还没有'回卷后忽略段'的专用计数器 ⇒ 就算改了也难有正面判据" | **成立** —— 这正是本件 §3 要解的；且**本件发现一个更硬的事实**：该角例**需要「rcv 侧 4 GiB 跨界 + 一个旧段」同时发生**，自然流量下**可能一次都不触发**（§3.4 的口径边界） | §3.4 |

### 1.5 行尾与其它施工面【事实】

- `rtl/tcp_rx.v`：**UTF-8 + 纯 CRLF**（实测 `CR=911 / LF=911`，即 0 个裸 LF）。
  ⇒ **变异器 / `sed` / 按 `\n` 做锚点的工具在它上面会 0 命中**（本工程已踩：`mk_mut_tx.py` 对 CRLF 的
  `tcp_tx_frame.v` 报 `MUTGEN FAIL 5`，`P7B_LONGSEND_ACCEPT.md:168-169`）。
- `rtl/tcb.v`：**纯 LF**（实测 `CR=0 / LF=158`）—— ⚠️ **同一仓两种行尾并存**，别按"整个 `rtl/` 都是 CRLF"处理。
- `git config core.autocrlf = true`（`P7B_LONGSEND_ACCEPT.md:190`）；`.gitattributes` 只给 `*.sh` 定了 `text eol=lf`。
- 本轮的**写入面**（Build G 施工时）：`rtl/tcp_rx.v`（1 行定义 + 1 处注释 + 1 个新端口 + 1 段计数器）
  + `board/wrapper_p4.v`（6 处，§3.5）+ `tools/gen_stim_tcp_rx.py`（§4.5）+ 读侧 17 处（§3.6）。

---

## §2 RFC 正确形式

### 2.1 逐位定义

**RFC 793 的 `SEQ_LT(a,b)`** 定义在"序号算术"上：把 32 位序号当"模 2³² 的整数"，`a` 在 `b` 之前
⟺ `(a − b) mod 2³²` 落在**上半圆**（MSB = 1），即 `$signed(a-b) < 0`。

**要写的 Verilog（逐字）**：

```verilog
// 现在 (rtl/tcp_rx.v:305)
wire        seq_lt   = (seq32 < ra_rcv_nxt);   // 重复/旧段 (回绕安全: 无符号比较)

// 改为 (RFC 793 SEQ_LT: $signed(seq32 - ra_rcv_nxt) < 0; 边界约定见 §2.2)
wire        seq_lt   = seq_diff[31];           // = (seq32-ra_rcv_nxt) 的模 2^32 差的高位
```

⭐ **`seq_diff` 已经存在**（`:296`），⇒ **不新增任何宽运算**，且把 `:305` 的 32 位无符号比较**删掉**
（净 LUT 【推演】下降，【需综合】定数）。**1 行改动同时修好两条链**（§1.3）。

**为什么消费者不用改**：
- `w6a_ok`（`:334-335`）的尾项 `|| seq_lt` —— 语义就是"旧段也接受"（`:327-333` 的 P4c 注释逐字"窗口内/
  **右沿/旧段都接受**"（`:328-329`）），换成 RFC 版后**意图不变、边界变对**。
- `ackresp`（`:347-348`）的 `(!seq_eq && (win_ok || seq_lt))` —— 同理。

⚠️ **两个等价写法（任选其一，二者逐位相同）**：
```verilog
wire seq_lt = seq_diff[31];                          // 版 1 (推荐: 最省)
wire seq_lt = seq_diff[31] && (seq_diff != 32'd0);   // 版 2 (P7B_L_INSTRUMENT_DESIGN.md §4.1 的写法)
```
【事实】**两版逐位恒等**（不是"消费者层面等价"）：`d == 0 ⇒ d[31] == 0 ⇒ 两版都是 0`；`d != 0 ⇒ 两版都 = d[31]`。
⇒ 版 2 的 `!= 0` 项**是纯冗余**（该件把它描述为"语义自明"是准确的，但它**不是**"需要仿真确认的等价"）。
**Build G 建议用版 1**，`!= 0` 可以放进注释里解释。

### 2.2 边界定义：差恰为 0x80000000 时判什么

**裁定（本件建议）：`d = 0x80000000` ⇒ `seq_lt = 1`（判为"旧段"）。**

理由（逐条）：
1. **逐字实现 `$signed(a−b) < 0`**：two's-complement 下 `0x80000000` 是负数 ⇒ `a` 判在 `b` 之前。
   RFC 793 的参考实现就是这么写的，**不需要额外解释**。
2. **零额外逻辑**：另一种约定（"恰好 2³¹ 算未来"）要写成
   `seq_diff[31] && (seq_diff != 32'h80000000)` ⇒ 多一个 **32 位相等比较**（≈ 16–32 LUT + 一级）。
3. **合法对端结构性到不了**：板通告的接收窗最大 `min(65535, WIN_CAP=61440)`（`board/wrapper_p4.v:227`）
   ⇒ 合法段的 `|d| ≤ 61440 ≪ 2³¹`。⇒ `d = 2³¹` 只可能是**畸形/伪造/跨协议误解**。
4. **后果对称且都合规**：两种选择只差"给这个畸形段回不回 ACK"。RFC 793 要求对不可接受的段回 ACK；
   RFC 5961 §4 进一步要求对窗口外段回 **challenge ACK**。⇒ **判 1（回 ACK）落在 RFC 允许的那一侧**。
5. ⚠️ **本节是【推演】+ 【需仿真】确认**：`d = 2³¹` 的边界行必须**进 TB 判据**（§4.3 的 F5 帧），
   否则"边界约定"只是纸上的一句话。

### 2.3 改动前后真值表（**用原始 RTL 表达式算，过程全部写出**）

记 `a = seq32`、`b = ra_rcv_nxt`、`d = (a − b) mod 2³²`。
- **旧式（`:305` 原文）**：`A = (a < b)`（32 位无符号比较 ⇒ **结果依赖 a、b 的绝对位置，不只是 d**）
- **新式（§2.1）**：`B = d[31]`（**只是 d 的函数**）

| 行 | `b` (rcv_nxt) | `a` (seq32) | `d = a−b mod 2³²` | 旧 `A = (a < b)` | 新 `B = d[31]` | 同否 |
|---|---|---|---|---|---|---|
| 1 | `0x0000_1000` | `0x0000_1000` | `0x0000_0000` | `0x1000 < 0x1000` = **0** | bit31(`0`) = **0** | ✅ |
| 2 | `0xFFFF_FFFF` | `0xFFFF_FFFF` | `0x0000_0000` | `= ` → **0** | **0** | ✅ |
| 3 | `0x0000_1000` | `0x0000_1001` | `0x0000_0001` | `0x1001 < 0x1000` = **0** | bit31 = **0** | ✅ |
| 4 ⭐ | `0xFFFF_FFFF` | `0x0000_0000` | `0x0000_0001` | `0 < 0xFFFF_FFFF` = **1** | **0** | ❌ **变** |
| 5 | `0x0000_0000` | `0x7FFF_FFFF` | `0x7FFF_FFFF` | **0** | **0** | ✅ |
| 6 | `0x8000_0000` | `0xFFFF_FFFF` | `0x7FFF_FFFF` | `0xFFFFFFFF < 0x80000000` = **0** | **0** | ✅ |
| 7 ⭐ | `0x0000_0000` | `0x8000_0000` | `0x8000_0000` | `0x8000_0000 < 0` = **0** | bit31 = **1** | ❌ **变（边界行，§2.2 的裁定）** |
| 8 | `0x8000_0000` | `0x0000_0000` | `0x8000_0000` | `0 < 0x80000000` = **1** | **1** | ✅（**同 d、不同位置 ⇒ 旧式翻了个个儿**） |
| 9 ⭐ | `0x0000_0000` | `0x8000_0001` | `0x8000_0001` | **0** | **1** | ❌ **变** |
| 10 | `0x7FFF_FFFF` | `0x0000_0000` | `0x8000_0001` | `0 < 0x7FFFFFFF` = **1** | **1** | ✅ |
| 11 ⭐⭐ | `0x0000_0000` | `0xFFFF_FFFF` | `0xFFFF_FFFF` | `0xFFFFFFFF < 0` = **0** | **1** | ❌ **变（= 本修复的目标行：rcv_nxt 刚回卷到 0，旧段 seq 还在回卷前）** |
| 12 | `0x0000_1000` | `0x0000_0FFF` | `0xFFFF_FFFF` | `0xFFF < 0x1000` = **1** | **1** | ✅ |

**从表里能读出的三件事**（这就是"改动前后哪些输入行为会变"的完整刻画）：
1. **行 8 vs 行 7**：**同一个 `d`**，旧式因 `a`、`b` 的绝对位置不同而给出**相反**的结论 —— 这就是"绝对比较"的病。
2. **行 11** = 目标角例；**行 4** = 反方向的同族角例（新式把"刚跨过回卷点的**未来**段"判成"前进"而不是"旧段"，
   旧式判成旧段 ⇒ 这一行旧式的"误判方向"是**回 ACK**（因为 `seq_lt=1` ⇒ `ackresp` 真），**新式反而更准**）。
3. 变化行 **只出现在 `d ≥ 2³¹`** 的行（4/7/9/11）；`d < 2³¹` 的 6 行**全部相同** ⇒ §2.4 的等价域。

### 2.4 等价性：对"不回卷"的输入域**逐位相同**（证明）

**命题**：设 `a, b` 为 32 位。若把 `a−b` 当**普通整数**（不取模）落在区间 `[−2³¹, 2³¹−1]`，则 `A ≡ B`。

**证明**（两分支，逐位）：
- **分支 1：`a ≥ b`（无借位）** ⇒ `d = a − b`（普通整数）∈ `[0, 2³¹−1]` ⇒ `d[31] = 0` ⇒ `B = 0`；
  又 `a ≥ b` ⇒ `A = 0`。⇒ **相等** ∎
- **分支 2：`a < b`（有借位）** ⇒ `d = 2³² + (a − b)`，其中 `a−b ∈ [−2³¹, −1]` ⇒ `d ∈ [2³¹, 2³²−1]`
  ⇒ `d[31] = 1` ⇒ `B = 1`；又 `a < b` ⇒ `A = 1`。⇒ **相等** ∎
- **反面（差异域）**：`a−b ≥ 2³¹` ⇒ `A = 0`、`d = a−b ∈ [2³¹, 2³²)` ⇒ `B = 1` ⇒ **不同**；
  `a−b < −2³¹`（即 `b−a > 2³¹`）⇒ `A = 1`、`d = 2³²+(a−b) ∈ [1, 2³¹)` ⇒ `B = 0` ⇒ **不同**。
  ⇒ **差异域恰为 `a−b ≥ 2³¹` 或 `a−b < −2³¹`**，即"两值分处 2³¹ 圆环的两个半空间"。∎

**等价域 = `a−b ∈ [−2³¹, 2³¹−1]`**（注意端点：`a−b = −2³¹` 时 `A = B = 1`，**仍在等价域内**；
`a−b = +2³¹` 时 `A = 0 / B = 1`，**在差异域**）。
- 【推演】**"本连接尚未跨 32 位回卷"是这个等价域的充分条件**：回卷前 `a`、`b` 都落在同一 2³¹ 半空间且
  合法流量满足 `|d| ≤ 窗 ≪ 2³¹`。**"合法域逐位不变"就是本条的直接推论**。
- ⚠️ **诚实边界**：这不是"改了等于没改"。**差异域非空**，且**正是本修复要动的地方**（行 11 / F1/F2/F5 帧）。
- ⚠️ 本证明是**纯组合代数**（对 `seq_lt` 这一个信号本身）；"端到端逐位相同"另需 §4 的门（因为
  `seq_lt` 下游还接了两条 FSM 链）。

### 2.5 ⭐ 改了之后**哪些行为会变、变成什么**（完整清单，4 条）

| # | 变化 | 修复前 | 修复后 | 谁看得见 |
|---|---|---|---|---|
| **①** | **回卷后旧数据段**（`plen≠0`，`abs_rej`） | 静默丢：`stat_drop_nonmatch +1`（`:757-760`），**不回 ACK** | `ackresp=1` ⇒ `S_DROP+drop_ack=1`（`:754-756`）⇒ tlast 拍 **`ack_req=1`**（`:396`），`ack_val = rcv_nxt_l`；统计改落 **`stat_drop_seq +1`** | 线上 ACK；**W23**（`rx_stat_nonmatch`，在窗口内）不再接收该类；`stat_drop_seq`（**不在窗口**）接收 |
| **②** | **回卷后旧纯 ACK**（`plen=0`，`abs_rej`） | 丢：`S_DROP`（`:757-760`）⇒ **无 `fend`** ⇒ **ACK/window 字段被忽略** ⇒ `snd_una`/`snd_wnd` 不推进 | `w6a_ok=1` ⇒ `S_PAD`（`:748-752`）⇒ `tlast` 走 `fend_pad`（`:370`）⇒ `pend_una`/`pend_wnd`（`:508-509`）⇒ **`snd_una` 推进**（`:464-469`） | TCB 终态 `snd_una`；`snd_wnd` |
| **③** | **该帧是否进 dup-ACK 计数** | 无 `fend` ⇒ `dup_l` 虽在 `:685` 锁存但**计数块 `:545` 从不执行** | 有 `fend` ⇒ 若 `dup_l` 为真则计数（`:545-558`） | `dup_cnt`/`retx_req`（**会触发重传**）⚠️ 见 §6-4 |
| **④** | **该帧是否置 `ack_obs`**（r6-fix 的 app 数据启动门） | 无 `fend` ⇒ 不置位 | 有 `fend` ⇒ `ackok_l`（`= ack_ok`，**不含 `seq_lt`**）为真即置位（`:592-598`） | `ack_seen` 位图 ⇒ app 数据能否启动 ⚠️ 见 §6-4 |

**+ 差异域的畸形输入**：`a−b ≥ 2³¹` 的段，修复前静默，修复后按 `seq_lt=1` 处理（回 ACK / 接受纯 ACK）。
【事实】RFC 793/5961 对不可接受段本来就要求回 ACK ⇒ **这条变化落在 RFC 允许侧**。
⚠️ 但它**不是"不可能发生"**：`a−b ≥ 2³¹` 也包含"对端序号语义完全错乱"的场景（如跨协议误解、seq 未初始化）。

**不变项（要写进判据的负对照）**：
- `acc`（`:340`）**不含 `seq_lt`** ⇒ **载荷交付路径逐位不变**（顺序段的交付/不交付与本次修复无关）。
- `ack_ok`/`ack_adv`（`:321-322`）、`win_ok`（`:303`）、`dup_ack`（`:338-339`）**都不含 `seq_lt`** ⇒ 不动。
- **等价域内的一切输入**（§2.4）⇒ 两版本输出逐位相同。

### 2.6 两种改法（**方案 A 推荐 / 方案 B 列出但否掉**）

**方案 A（推荐，1 行）**：只改 `:305` 的定义（§2.1）。两条链同时修好；**登记的"两处"一并闭合**。

**方案 B（保守：只修数据段那一站）**：
```verilog
wire seq_lt_rfc = seq_diff[31];
wire seq_lt_abs = (seq32 < ra_rcv_nxt);                       // 保留原式
wire w6a_ok = base_ok && (plen_w == 16'd0) && ((seq_diff <= {16'b0,ra_rcv_wnd}) || seq_lt_abs);  // 不动
wire ackresp = base_ok && (plen_w != 16'd0) && ((!seq_eq && (win_ok || seq_lt_rfc)) || (seq_eq && !win_ok));
```
**否掉的理由**：① 保留了一个同样的绝对比较 ⇒ **`P7B_OPEN_ITEMS.md:128` 的第一半闭合不了**
（"两处绝对比较 = 已知 RFC 偏离"仍然成立）；② 引入两个语义相近的线网（`seq_lt_rfc`/`seq_lt_abs`），
**下一个人极易接错**（本工程最贵的一类缺陷）；③ 多一个 32 位比较器的 LUT 成本。
⇒ 除非用户在 §6-1 裁定"只动数据段那一站"，否则走 A。

**Build G 的 RTL 改动量（逐字）**：`:305` 一行 + `:304-305` 注释重写（§5.1）+ 新增 `stat_absrej` 端口
与计数器（§3）+ 端口注；**不新增/不删除任何端口连接**（`stat_absrej` 是**新增输出端口** ⇒
**其余例化点不用改**（Verilog 允许具名端口实例化漏接输出；实测 `grep -rln "tcp_rx u_" --include=*.v .` = **77 文件**，
含 `sim/` 下的历史镜像 ⇒ **一个有意识的例外都没有**）。本工程先例 = 构建 F 的 `stat_ack_adv`：
只改了 wrapper 与 `tb/tb_tcp_rx.v`（`:140-141`）两处。

### 2.7 代价【需综合】

- **LUT**：删 1 个 32 位无符号比较器（`a < b`，≈ 8 CARRY4 + 少量 LUT）+ 新增 1 个 1 位抽头（§3.1 的 33 位减法器多 1 位）
  ⇒ 【推演】**净减或持平**；确切数【需综合】。
- **时序**：改动落在 **RX 功能锥**（`ra_rcv_nxt`（TCB 阵列组合读）→ 减法 → 比较 → `acc_l`/`ackresp_l`/`w6a_ok_l` 的 D 端）。
  现役 F 档 **DP 域最差 = `u_clkgen/rel_sr_reg[3]/C → u_tcp_tx/u_retx/g_byte[1].mem_e_reg_7_bram_7/RSTRAMB`，slack 0.281**
  （`_proj_10g/notes/p7b_buildF_build/READINGS.txt:126-129`）—— **不是这条族**，但"不是同一个宿≠没影响"（全局 #66）。
  ⇒ **必须定向 STA**（`-from` 该族 `/ -to acc_l|ackresp_l|w6a_ok_l`），**不许只读 top-N 清单**。

---

## §3 计数器设计（⭐ 本件最重要的一节）

### 3.1 语义与**精确谓词**（逐字 RTL）

**要数的不是"比较被走到了"**，而是：**"一个本来应当被接受/确认的段，因为绝对比较而被错误地拒了"**。

**逐拍定义（口径钉死）**：
> 在第 T 拍 +1 ⟺ 第 T 拍同时满足
> **(i)** 它是**该帧的 w5 判读拍**：`(state == S_HDR) && accept && !s_axis_tuser && (wcnt == 3'd5) && (s_axis_tkeep == 8'hFF)`
> （= `:677-699` 那个 `3'd5:` 分支里 `else` 支的条件 —— 它的外层是 `S_HDR: if (accept) if (s_axis_tuser) … else case (wcnt)`；
> **与 `acc_l/ackresp_l/w6a_ok_l` 的采样点逐字同拍同支**；⚠️ 施工时把 `+1` 直接放进那支 ⇒ 条件由**构造**保证，不必手抄）；
> **(ii)** **两个定义分歧且方向是"RFC 说旧段"**：`seq_lt_rfc && !seq_lt_abs`；
> **(iii)** **绝对比较导致它被静默误拒**（分两种帧型，见下）。

**RTL（逐字，全部信号带来源行号）**：

```verilog
// ---- Build G: 观测仪器 (纯观测; 真值源 = 本设计件 §3.1) ------------------------
// 33 位减法: 低 32 位 = 原 seq_diff (:296, 逐位不变), 第 33 位 = 借位 = 旧的"绝对比较"
wire [32:0] seq_sub33  = {1'b0, seq32} - {1'b0, ra_rcv_nxt};   // seq32 :289 / ra_rcv_nxt :72
wire [31:0] seq_diff_o = seq_sub33[31:0];                      // = :296 的原式 (逐位相同)
wire        seq_lt_abs = seq_sub33[32];                        // = :305 的原式 (seq32 < ra_rcv_nxt)
wire        seq_lt_rfc = seq_diff_o[31];                       // = 修好后的 seq_lt (§2.1)

wire abs_rej  = seq_lt_rfc && !seq_lt_abs;                     // 两定义分歧 (方向: RFC 说"旧段")

// (iii) 数据段支: 旧码下 ackresp=0 且 acc=0 ⇒ 落 :757-760 静默丢
wire evt_data = abs_rej && base_ok && (plen_w != 16'd0) && !seq_eq && !win_ok;
//      base_ok :325-326 / plen_w :323 / seq_eq :304 / win_ok :303
// (iii) 纯 ACK 支: 旧码下 w6a_ok=0 ⇒ 落 :757-760 丢 (acc 自动为 0: abs_rej ⇒ seq_eq=0)
wire evt_ack  = abs_rej && base_ok && (plen_w == 16'd0) && !(seq_diff_o <= {16'b0, ra_rcv_wnd});
//      ra_rcv_wnd :75 (注意: 此处用 (:335) 的裸窗, 不是 acc_wnd :302 —— 与 w6a_ok 逐字同款)

wire evt_absrej = evt_data || evt_ack;

// 计数 (与 w6a_ok_l 落笔于同一分支, 见下"落在哪一行")
reg [31:0] stat_absrej;
```

**落在哪一行（施工指令）**：把 `if (evt_absrej) stat_absrej <= stat_absrej + 32'd1;`
**加在 `rtl/tcp_rx.v:692`（`w6a_ok_l <= w6a_ok;`）的下一行** —— 那行已经在 `3'd5:` 的 `else`
（`s_axis_tkeep == 8'hFF`）分支里，**采样点天然与三条判据逐字同拍**，不给自己留"采样点漂移"的空间。
复位清位加在 `:493`（`stat_ack_adv <= 32'd0;`）的旁边。

**为什么谓词长这样（自证三条）**：
1. `abs_rej` 的分歧方向**只取一个方向**（`seq_lt_rfc && !seq_lt_abs`）：反方向（`!rfc && abs`）在行 4/8 出现，
   那时**旧码会回 ACK**（`seq_lt_abs=1` ⇒ `ackresp=1`）⇒ **不是"被误拒"，不该计**。
2. `(iii)` 的两个支路**恰好是"旧码会走到静默丢支"的充分必要条件**：
   - 数据段：旧 `ackresp = !seq_eq && (win_ok || seq_lt_abs)`；`abs_rej ⇒ seq_lt_abs = 0` ⇒
     要它 = 0 就需 `!seq_eq && !win_ok`（此时 `acc = win_ok && seq_eq = 0`）✔
   - 纯 ACK：旧 `w6a_ok` 的尾项为 0（`abs_rej`），头项要 = 0 就需 `!(seq_diff <= rcv_wnd)`；
     `acc = win_ok && seq_eq`，而 `abs_rej ⇒ seq_eq = 0` ⇒ `acc = 0` ✔ ⇒ 必落 `:757-760`。
3. **修复后同一谓词仍然为真**（它只依赖输入 + 两个定义，不依赖 RTL 走哪条支）⇒ **两臂读数可比**（§3.4）。

### 3.2 与现役 70 字字表的**语义不重叠**论证

现役表逐字读过 = `_proj_10g/notes/P7B_BIZ_WINDOW.md:28-51`（W51..W69 行）+ 表头更新块 `:12-24`
（**现役 = 70 字 / BID `0x1A` / 未实现 `0x138`**）。最近六轮的谓词逐条核过：

| 字 | 源 | 语义（读值） | 与本字的关系 |
|---|---|---|---|
| W23 | `rx_stat_nonmatch`（`rtl/tcp_rx.v:126`；装配 `board/wrapper_p4.v:3905`） | **tcp_rx 全部"未匹配/未接受"丢弃的总量**（`:757-760` 的兜底支 + 头/标志/长度/校验各支） | ⭐ **上游宽口径**：修复前本类事件落在这里；本字是**其中"RFC 应当回 ACK"的子类**。**总量 vs 子类 ≠ 同义**；且**修复后该类不再落 W23**（改落 `stat_drop_seq`，而后者**不在窗口里**：`grep -n "rx_stat_seq" board/wrapper_p4.v` 只命中 `:1557`（声明）/`:1884`（接线到 tcp_rx），**两个装配段 `:3839-3874`（`snap_dout_all`）与 `:3899-3920`（`dp_src`）零命中**）⇒ **新字是修复后唯一还跟踪该类的仪器** |
| W22 | `rx_stat_pass`（`:125`） | 接受且 FCS 好的帧数（含纯 ACK） | 本类事件**从不**进 pass；正交 |
| W68 | `tcp_rx.stat_ack_adv`（`:152`，谓词 `:382` `fend && s_axis_tcrs && ack_adv_l && !fend_trunc`） | **推进 `snd_una` 的 ACK 事件数**（ACK 字段侧） | ⭐ **同在 `tcp_rx`、但量的是"ACK 号推进"，不是"段的 seq 分类"**；且它是 `fend` 拍事件（**丢帧路径没有 `fend` ⇒ 结构性看不到本类**）。修复后本类**可能顺带**推进 `snd_una`（链 B）⇒ 两者**会同时动但不同义**（新字数"候选出现次数"，W68 数"确实推进了几次"） |
| W55 | `tcp_tx_frame.stat_retx` | 重传/RTO 回卷次数（TX 侧） | 方向相反（TX），正交 |
| W63/W64/W66/W67/W69 | `app_pattern` / `tcp_tx_frame` | app 侧停滞/背压、帧器侧窗口门等待/板帽侧/操作点锁存 —— **全是 TX/发送侧** | 域正交（本字在 **RX 段分类**） |
| W61/W62 | `app_ctrl` | 窗口重开通告数 / app RX 占用 | 正交 |

**⇒ 结论**：70 字里**没有任何字**带"段的 seq 分类 / 相对 vs 绝对比较"语义。
唯一邻近的是 **W23**，而它是"总量"、且**修复后不再覆盖该类** ⇒ 新字**必要且不重叠**。

**建议的字名/线名（与既有命名族一致）**：端口 = **`stat_absrej`**（`output reg [31:0]`）；
wrapper 线 = `rx_stat_absrej`；localparam = `biz_w70`；**字表行** = `W70`。
（⚠️ 名称一旦定下，`check_window.py` 判据 12 会**按名**核，改名 = 又一次五处同步 ⇒ **现在定死**。）

### 3.3 采样点与**口径边界**（必须随字一起登记）

- **每帧至多 +1**：`wcnt` 在一次 `S_HDR` 通过里只等于 5 一次（`s_axis_tuser` 中断会回 `S_HDR`，
  但那是**另起一帧**的判读）⇒ 与 W68 的"每帧至多 +1"同性质。
- ⚠️ **不含 FCS 条件（刻意）**：w5 拍**还不知道 FCS**（FCS 到 `tlast` 才知道）。
  ⇒ 本字数的是 **"w5 判读拍上该帧属于这一类"的**候选帧**，坏 FCS 帧也会计入**（发生率极低；
  且坏 FCS 帧本来就不该被 ACK —— 读表时**不许**把它读成"误拒次数"）。**不许**把 `s_axis_tcrs` 塞进谓词：
  ① 加了它，**修复前**的丢帧路径根本没有 `fend` 可挂 ⇒ 计数器**结构性恒 0**（全局 #37 同族陷阱）；
  ② 采在 `fend` 拍会让"数据段支"与"纯 ACK 支"落到不同的收尾形态（`S_DROP` 无 `fend` / `S_PAD` 有）⇒ 两臂不可比。
- **不含 `ra_rcv_wnd` 之外的动态量**：谓词的 `win_ok` 用的是 `acc_wnd`（含 `ACC_MARGIN`），
  与本模块自己的判据逐字一致；`evt_ack` 用的是裸 `ra_rcv_wnd`（与 `w6a_ok` `:335` 逐字一致）。
  ⇒ **谓词 = 判据的照抄**，不引入新口径。
- ⚠️ **板侧触发条件很苛刻（诚实登记）**：`abs_rej` 需要 `rcv_nxt` 与到达段的 `seq` **分处 2³¹ 圆环两半**
  ⇒ 现实里 = **"对端的数据流跨过 2³² 边界 + 有一个旧段（重传/迟到重复）撞在界前后"**。
  只做**下行**（板发对端收）的流量**结构性不会触发**（那时 `tcp_rx` 只见纯 ACK，对端 seq 固定不变）。
  ⇒ 板级要试，必须走**上行构型**（对端发数据、板收）且**累计 ≥ 4 GiB**（跨一次 2³²），
  并在跨越点附近**密集取快照**。**若自然流量不触发，ΔW70 会两臂都是 0** —— 那不是"证伪"，是
  "本工况判别力为空"（本工程已定型的口径：**空判据不许记 PASS/FAIL**）。

### 3.4 ⭐ 抗"结构性恒 0 / 环路恒等式"论证（本字为什么**有牙**）

| 陷阱 | 本字是否踩 | 论证 |
|---|---|---|
| **结构性恒 0**（谓词被预 AND 成恒假） | ❌ 不踩 | 谓词里**没有**"修复后才会成立"的项：`seq_lt_rfc`、`seq_lt_abs`、`base_ok`、`plen_w`、`win_ok`、`seq_eq`、`seq_diff` **全是输入侧量**，两臂都能为真。**修复前**该计数非 0 ⟺ **真的发生了静默误拒**（这就是缺陷的**直接读出**）；**修复后**非 0 ⟺ **同类输入出现了**（= 修复通路被激励的见证） |
| **环路恒等式**（用 DUT 的判据线当 oracle） | ❌ 不踩 | 谓词是**自己写的**（不复用 `ackresp`/`w6a_ok` 线）；TB 侧要独立复算（§4.2） |
| **"注入过"≠"测到了"** | 已覆盖 | 门里**期望命中条数写死**（§4.3：A/G 两臂都期望 **3**），并且有**不该计的负例**（F3/F4 两帧期望 0） |
| **"没观察到"≠"不存在"** | 已覆盖 | 本字把"62 次回卷没看到痕迹"**升级为**"该窗内该类事件 = 0 次"的**直接测量**（若真为 0）——比"看速率/计数的痕迹"强得多 |
| ⚠️ **本字不能单独回答"修复是否生效"** | **如实登记** | 它的读数**两臂相同**（同谓词）。"修复生效"必须由**行为面**回答：xsim 门（§4）+ 板侧 **W23 位移**（修复后该类不再进 W23）。⚠️ **不许**用"ΔW70 变了/没变"判修复 |

### 3.5 快照接线（**6 处**，逐处给 `文件:行号`）

| # | 处 | 位置（**现役 = 70 字**） | 动作（→ **71 字**） |
|---|---|---|---|
| 1 | 总字数（单一来源） | `board/wrapper_p4.v:3228` `localparam SNAP_NW_P6E = 70;` | `→ 71`（+ 改 `:3195-3227` 的几何注释块；**未实现地址 `0x20+4*71 = 0x13C`**；`(71−1)<<5 = 2240 < 4096` ⇒ `axi_regs.snap_base [11:0]` **不动**；`snap_idx = r_word[6:0]−8` 最大 70 ⇒ 7 位 ✓，回绕红线仍 ≥ `0x200`） |
| 2 | dp 束槽数 | `board/wrapper_p4.v:3249` `localparam SNAP_P7BDP_NW = 30;` | `→ 31`（**必须进 dp 束**：`tcp_rx` 在 `dp_clk`（`board/wrapper_p4.v:1808` `.clk(dp_clk)`），且 `stat_absrej` 是**寄存器输出** ⇒ 满足 `snap_cdc` 的 "b 域寄存器输出" 前提） |
| 3 | 逐槽接线 | `board/wrapper_p4.v:3786` 之后（现最后一项 = `p7bdp_din[29*32 +: 32] = biz_w69;`） | 加 `assign p7bdp_din[30*32 +: 32] = biz_w70;   // 槽 30 → W70 tcp_rx.stat_absrej`（**逐槽显式 assign，不进 `generate`** —— 理由见 `:3736-3741`） |
| 4 | 源线声明区 | `board/wrapper_p4.v:3675-3677`（`biz_w67/biz_w68/biz_w69` 三条） | 在 `:3677` 之后加 `wire [31:0] biz_w70 = rx_stat_absrej;   // 槽 30 → W70 tcp_rx.stat_absrej (构建 G)` + `wire [31:0] rx_stat_absrej;`（**防隐式 1 位网**，坑 24）；**不包 `ifdef`**（`tcp_rx` 的例化在 `APP_MODE` 之外 ⇒ 默认构建里也是真值，与 `biz_w68` 同款） |
| 5 | 装配（MSB 端） | `board/wrapper_p4.v:3839-3840`（现首项 = `p7bdp_dout[29*32 +: 32]` → W69） | 在**最前**插一项 `p7bdp_dout[30*32 +: 32],   // W70 tcp_rx.stat_absrej`（旧项逐字符不动） |
| 6 | BID | `board/wrapper_p4.v:4050` `.BUILD_ID_V (32'h0000001A)` | `→ 32'h0000001B`（与 `P7B_L_INSTRUMENT_DESIGN.md` §5.1 的排期表一致：F=`0x1A` / **G=`0x1B`** / H=`0x1C`） |

**7（无需改，只核）**：`_proj_pcie/rtl/axi_regs.v:266` 的 `snap_base [11:0]` **不动**（上限 129 字，见 `:95` 注释）；
`:262-265` 的注释可顺手订正。

### 3.6 读侧 + 门 + 夹具：**穷举清单**（每行给 `文件:行号` + **现在写的是什么**）

> ⚠️ **为什么必须穷举**：`P7B_OPEN_ITEMS.md:38`（表行 #20）逐字记着
> "**66 字同步轮与 67 字同步轮都只抬了 accept/negctrl/snap 一族，两轮都漏了它**"（指 `gen_inputs.py`）。
> 本清单的做法 = 照 `_proj_10g/notes/p7b_buildF/apply_readside.py` 的**八组结构**重走一遍，
> 并用下面三条搜索命令**交叉核对**（命令与命中见本节末）。

**A. 板侧/主机侧取数与验收（现役脚本）**

| # | 文件:行 | 现在写的是什么 | 改成 |
|---|---|---|---|
| A1 | `_proj_pcie/p7b_biz/p7b_snap.sh:49` | `NW=${NW:-70}` | `71` |
| A2 | `_proj_pcie/p7b_biz/p7b_snap.sh:50` | `UNIMPL_ADDR=…` 注释 `# 70 ⇒ 0x138 (67 ⇒ 0x12C; …)` | 注释加 `71 ⇒ 0x13C` |
| A3 | `_proj_pcie/p7b_biz/p7b_snap.sh:51` | `EXPECT_BID=${EXPECT_BID:-0x0000001A}` | `0x0000001B` |
| A4 | `_proj_pcie/p7b_biz/p7b_snap.sh:125,132` | `NAME[]` 表 `[65]=mac_tx_idle … [69]=tx_win_at_winstall` | 加 `[70]=rx_stat_absrej`（+ 口径注释：**两臂同谓词 / 非 FCS 条件 / 空判据边界**） |
| A5 | `_proj_pcie/p7b_biz/p7b_snap.sh:4` | 标题注释 `⭐ 构建 F … 70 …` | 加构建 G 行 |
| A6 | `_proj_pcie/p6e_snap_check.sh:71,72,60` | `SNAP_WORDS=${SNAP_WORDS:-70}` / `UNIMPL_ADDR` 注释 / `EXPECT_BID=${EXPECT_BID:-0x0000001A}` | 三个一起 → `71`/`0x13C`/`0x1B` |
| A7 | `_proj_pcie/p7b_gate4_accept.sh:137,138,131` | 同上三件 | 同上 |
| A8 | `_proj_10g/notes/p7b_gate4_3/final_state.sh:11,12,29,42` | `rd 0x138`（UNIMPL）/ 注释 `70 字 ⇒ 0x138` / `EXPECT_BID:-0x0000001A` / `echo "W67=… W69=…"` | `0x13C` / `71 字 ⇒ 0x13C` / `0x1B` / **加一行 `W70=$(rd 0x138)`** |
| A9 | `_proj_10g/notes/p7b_affinity/j6_r6fix.sh:75,76,82` | `NW=${NW:-70}` / `EXPECT_BID:-0x0000001A` / `GEOM_TIERS` 行 `"70|0x0000001A|61 62|构建 F …"` | `71` / `0x1B` / **表尾加一行**（旧档全留）`"71|0x0000001B|61 62|构建 G (2026-10-10) 71 字 / BID 0x1B (W70 = tcp_rx.stat_absrej)"` |
| A10 | `_proj_10g/notes/p7b_biz_tcpreg/tcpreg_j6.sh:69,70,77` | 同 A9 | 同 A9 |
| A11 | `_proj_10g/notes/p7b_gate4_criteria/gen_inputs.py:42,43` | `NW_FIX = 70` / `BID_FIX = 0x0000001A`（+ `:40-41` 历史注释） | `71` / `0x1B`（⚠️ **它自带 `_geo_guard()`（`:46-67`）：不同代 ⇒ `GEOM_GUARD_FAIL` + `exit 3` + **零文件** ⇒ 漏改它不是静默，是**响亮失败**；但**必须同批改**，否则 `negctrl_fix3.sh` 整轮打空） |
| A12 | `_proj_10g/notes/p7b_gate4_criteria/negctrl_fix3.sh` | 无硬编码几何（**读 accept 默认值** ⇒ 跟随 A7） | 只核 |

**B. 假板子 / 反例台架（三个"负对照"件）**

| # | 文件:行 | 现在写的是什么 | 改成 |
|---|---|---|---|
| B1 | `_proj_pcie/p6e_snap_selftest_fix2.sh:16-17` | 注释 `( = 70 字 / 未实现 0x138; 2026-10-10 构建 F; …)` | 加 G 行 |
| B2 | `_proj_pcie/p6e_snap_selftest_fix2.sh:77` | `0X04) V=\${FAKE_BID:-0x0000001A};;` | `0x0000001B` |
| B3 | `_proj_pcie/p6e_snap_selftest_fix2.sh:97-100` | `0X12C/0X130/0X134) V=0;;` + `0X138) V=0xffffffff;; # 未实现地址 (70 字…)` | **加 `0X138) V=0;;  # W70 tcp_rx.stat_absrej (71 字起; 构建 G)`**，并把 `0X13C) V=0xffffffff;;  # 未实现地址 (71 字)` |
| B4 | `_proj_pcie/p7b_gate4_selftest.sh:37,39` | `SW=${SNAP_WORDS:-70}` / `UNIMPL_A=$(printf '0X%X' $(( 0x20 + 4*SW )))` | 自动跟随 `SW`；`SW` → `71` |
| B5 | `_proj_pcie/p7b_gate4_selftest.sh:58-64` | 注释块 `SW ≥ 70 (构建 F 起) ⇒ …FAKE_UNIMPL 挪到 0x138` | **加一条 `SW ≥ 71 (构建 G 起) ⇒ 0x138 也是真字, FAKE_UNIMPL 挪到 0x13C`** |
| B6 | `_proj_pcie/p7b_gate4_selftest.sh:70-80` | `if [ "$SW" -ge 70 ]; then … 0X138) V=${FAKE_UNIMPL:-0xffffffff};;` | **新加 `-ge 71` 分支**（照 70 分支抄 + 加 `0X138) V=0;;` + `0X13C) V=${FAKE_UNIMPL:-…};;`），`elif` 链保留旧档 |
| B7 | `_proj_pcie/p7b_gate4_selftest.sh:137` | `0X04) V=\${FAKE_BID:-0x0000001A};;` | `0x0000001B` |
| B8 | `_proj_pcie/p7b_gate4_livefake.sh:89` | `+ [0] * 19   # W51..W69 = …` | `+ [0] * 20`（**少一个 `IndexError` ⇒ 假对端直接崩 = "整台安静"**，本件上一代踩过） |
| B9 | `_proj_pcie/p7b_gate4_livefake.sh:119` | `bid = {70: "0x0000001A", 67: …}.get(nw, "0x0000001A")` | 加 `71: "0x0000001B"` + **兜底改 `0x1B`** |
| B10 | `_proj_pcie/p7b_gate4_negctrl.sh:31-32` | 注释 `几何: 70 字 (W0..W69) —— 构建 F …` | 加 G 行 |
| B11 | `_proj_pcie/p7b_gate4_negctrl.sh:58` | `echo "BID 0x0000001A"` | `0x0000001B` |
| B12 | `_proj_pcie/p7b_gate4_negctrl.sh:63,64` | `0 0 0)   # W51..W69 …` / `for (( i = 0; i < 70; i++ ))` | 加一格 `0` + `i < 71` |
| B13 | `_proj_pcie/p7b_gate4_negctrl.sh:140` | `shift1(){ awk -v NW=70 …}` | `NW=71` |

**C. sim 侧 TB（BID / 未实现地址）**

| # | 文件:行 | 现在写的是什么 | 改成 |
|---|---|---|---|
| C1 | `sim/p6e_pcie/tb_p6e_pcie_counters.v:206` | `chk("0b BUILD_ID (构建 F 70-word = 0x1A; …)", v, 32'h0000001A);` | `0x1B`（+ 文案） |
| C2 | `sim/p6e_pcie/tb_p6e_pcie_wrapper.v:149` | `chk("2  BUILD_ID (构建 F 70 字=0x1A; …)", …, 32'h0000001A);` | `0x1B` |
| C3 | `sim/p6e_pcie/tb_p6e_pcie_wrapper.v:338,339` | `axil_read(32'h138, v);` / `chk("9  未实现地址 0x138 ⇒ rresp = SLVERR", …)` | `0x13C`（两处一起，**搬地址 = 两处编辑**，全局 #80） |
| C4 | `_proj_10g/p7b_chain/sim/tb_p7b_chain.v:1521,1523` | `chk("7b 0x138 reads 0 no wrap", …)` + 描述串 `70-word bound (原 67 字/0x12C …)` | `0x13C` + 文案 |
| C5 | `_proj_10g/notes/p7b_biz_win/tb_biz_win.v:3,26,173,179` | `SNAP_NW=70` / `NW = 70` / `5a 末字 … = 0x134 @NW=70` / `6a 未实现地址 … = 0x138 @NW=70` | `71` / `71` / `0x138` / `0x13C`（**判据 5b/6b 的 rresp 期望值不变**） |
| C6 | `_proj_10g/notes/p7b_biz_win/run_tb_biz_win.bat:22` | `findstr /C:"SNAP_NW_P6E = 70" …` | `= 71`（**指纹门：漏改 ⇒ exit /b 92 硬失败**，是好事） |
| C7 | `_proj_10g/notes/p7b_biz_win/run_xvlog_wrapper.bat:33` | 同上 | `= 71` |
| C8 | `sim/p5wu_p1p2/run_xvlog_wrapper63.bat:53` | 同上 | `= 71` |
| C9 | `_proj_10g/notes/p7b_biz_win/check_window.py:227`（`nnew_top = 4`）+ `:283-291`（判据 12 的 `w12` 表）+ `:292-301`（逐项断言循环） | 顶端 4 项 = W69/W68/W67/W66；W68 那项 = `("tcp_rx", rrx, "stat_ack_adv", "rx_stat_ack_adv", 68, pdp - 2, r"if \(ack_adv_ev\) stat_ack_adv <= stat_ack_adv \+ 32'd1;", 1)` | `nnew_top → 5` + **表里加第 5 项**：`("tcp_rx", rrx, "stat_absrej", "rx_stat_absrej", 70, pdp - 1, r"if \(evt_absrej\) stat_absrej <= stat_absrej \+ 32'd1;", 1)`（`n_inc=1` = **单分支**：该行不在任何 `ifdef` 里；槽号 `pdp-1` = 30 ✓ 与新 `SNAP_P7BDP_NW=31` 一致） |

**D. 生成产物（**不用手改**，但必须重跑 + 重读判据）**

| # | 文件 | 说明 |
|---|---|---|
| D1 | `_proj_10g/notes/p7b_gate4_tools/fix2/new_fake.sh` | 由 `_proj_pcie/p6e_snap_selftest_fix2.sh:141,146`（`sed` + `mkfake`）**生成** ⇒ 随 B1-B3 自动跟随 |
| D2 | `_proj_10g/notes/p7b_gate4_tools/selftest/p6e_snap_check_fake.sh` + `addrlog_*`/`addrseq.txt`/`SUMMARY.txt` | 由 `_proj_pcie/p7b_gate4_selftest.sh:197-223` **生成**；重跑后核 `OK=?/BAD=0` 与**地址序列条数 = 71** |

**E. 快照扩窗的"上一代快照副本"（**本轮目录内的历史件，原则上不追改**；规则写清楚）**

| # | 文件 | 现在写的是什么 | 处置 |
|---|---|---|---|
| E1 | `_proj_10g/notes/p7b_a3_negctl_20261010/{burn_arm.sh:21, step0_selfcheck.sh:4,46, _tools/p7b_snap.deployed.sh:4,49,50}` | F 代几何（`NW=70 / 0x138 / BID 0x1A`） | **上一轮板级轮的现场脚本 = 历史件**，保留原样（它的读数绑 F 位流）；**新一轮的部署副本按 `_proj_10g/notes/p7b_affinity/BUILD.md` 重新部署到对端 `/tmp/p7b_biz/`**，不复制它的数值 |
| E2 | `_proj_10g/notes/p7b_buildF_board_20261010/{burn_arm.sh, run_arm.sh, step0_selfcheck.sh, analyze.py, _tools/p7b_snap.deployed.sh, runs/*, burn/*}` | 同上（F 轮现场副本）—— ⚠️ **本件写作期间该目录正在被另一路 agent 实时写入**（= **Build F 板级轮在飞**，`git status` 的 untracked 增量 + `find -newermt` 实测） | **同上**；且 ⇒ 印证本轮的边界纪律：**不许碰板/对端**（本件确实一个字节都没碰） |

**F. 文档（现役表 = 下游按它读）**

| # | 文件:行 | 动作 |
|---|---|---|
| F1 | `_proj_10g/notes/P7B_BIZ_WINDOW.md:28-51` | 加 `W70` 行（真值源 = `board/wrapper_p4.v` 装配段）+ 更新 `:52` 的"未实现地址 = `0x138`"→`0x13C` |
| F2 | `_proj_10g/notes/P7B_BIZ_WINDOW.md:12-17` 的"2026-10-10 更新"块 | 加构建 G 一行（71 字 / BID `0x1B`） |

**搜索命令（本清单就是这三条 + `apply_readside.py` 逐组重走得到的；复算请照抄）**：
```bash
# ① 所有"几何默认值"落点
grep -rn "NW=\${NW:-\|SNAP_WORDS=\${SNAP_WORDS:-\|SW=\${SNAP_WORDS:-\|EXPECT_BID=\${\|UNIMPL_ADDR=\${\|FAKE_BID\|NW_FIX\|BID_FIX" \
     --include=*.sh --include=*.bat --include=*.py . | grep -v "^./vivado_prj"
# ② 所有提到"未实现地址"的文件
grep -rln "0x138\|0X138" --include=*.sh --include=*.bat --include=*.py --include=*.v . | grep -v "^./vivado_prj"
# ③ RTL/BID 面
grep -n "SNAP_NW_P6E\|SNAP_P7BDP_NW\|p7bdp_din\[\|BUILD_ID_V" board/wrapper_p4.v
# ④ 反例夹具自带守卫（必须与 accept 同代）
grep -n "NW_FIX\|BID_FIX\|_geo_guard" _proj_10g/notes/p7b_gate4_criteria/gen_inputs.py
```
⚠️ **已知不追改的两件**（照 `P7B_L_INSTRUMENT_DESIGN.md` §5.2 第 8 行末的登记）：`P7B_OPEN_ITEMS.md` §C6 的
硬编码 `NW`（文档类，随文档轮）；**`sim/` 下的镜像件**（`*_regress/mirror/` 等 71 个含 `app_pattern #(` 的件）
= **刻意的外来夹具/历史镜像**，**禁全局替换**（`P7B_LONGSEND_ACCEPT.md:174-175`）。

### 3.7 代价（**逐项核出，不照抄**）

【事实】**每 +1 字的 FF 成本 = 96 FF（快照通路）+ 32 FF（计数器本体）= 128 FF**：
| 组成 | 位宽 | 域 | 出处 |
|---|---|---|---|
| `snap_cdc.hold_b` | `NW*32` ⇒ **+32** | **源域 = `dp_clk`**（本字进 dp 束） | `rtl/snap_cdc.v:93`（`reg [NW*W-1:0] hold_b;`） |
| `snap_cdc.dout_a` | `NW*32` ⇒ **+32** | `pcie_axi_aclk` | `rtl/snap_cdc.v:118`（`output reg [NW*W-1:0] dout_a`） |
| `axi_regs.snap_words_r` | `SNAP_NW*32` ⇒ **+32** | `pcie_axi_aclk` | `_proj_pcie/rtl/axi_regs.v:202`（`reg [SNAP_NW*32-1:0] snap_words_r;`） |
| `stat_absrej` 本体 | 32 | `dp_clk` | 本设计 §3.1 |
⇒ **DP 域 +64 / pcie 域 +64**（与 `P7B_L_INSTRUMENT_DESIGN.md` §5.3-1 的"每字 ≈ 96 FF（其中 32 在 dp 域）+ 源侧 32 FF"**逐数吻合**）。

**组合逻辑（观测侧）**：
- 33 位减法器 = 现役 32 位减法器（`:296`）**多 1 位进位**（≈ 1 CARRY8 的一格 + 0–1 LUT）。
  ⭐ **替代写法（更省，二选一）**：直接留一行 `wire seq_lt_abs = (seq32 < ra_rcv_nxt);`
  —— 语义完全相同，但**重新引入一个 32 位比较器**（≈ 8 CARRY4）。**推荐 33 位抽头版**；两版都【需综合】对照。
- 事件谓词：`abs_rej` 1 AND + 两个支路（`!seq_eq && !win_ok` / `!(seq_diff <= rcv_wnd)`）+
  一个 mux（`plen_w != 0`）≈ **十几 LUT**。
- **落在哪条锥**：观测侧是 `ra_rcv_nxt`（TCB 组合读）→ 减法 → 1 位 → `stat_absrej` 的 CE。
  与**功能侧**（同源 → `win_ok`/`acc`/`ackresp` 的 D 端）**共享前段**，只多 1–2 级。
  ⛔ **不许写"不撞 WNS"**：F 档 DP 域 WNS 宿 = `u_tcp_tx/u_retx/…/RSTRAMB`（slack 0.281，`READINGS.txt:126-129`）
  —— 是**另一族**，但全局 #66 的纪律是"**必须逐族 `-from` 定向查询**，不许拿 top-N 清单当判据"。
- ⚠️ **真正的时序风险不在 DP**：F 档**全局 WNS = `+0.111`，是 pcie 侧 `user_reset_reg/C → snap_words_r_reg[1797]/CLR`
  的 `async_default`/Recovery 检查（fo = 5392 的共享复位网 `bbstub_axi_aresetn`）**（`READINGS.txt:111-124`）。
  **本字往这条复位网上再挂 64 FF**（`dout_a` + `snap_words_r`）⇒ 【推演】这条族的 slack 可能被再压薄。
  ⇒ **一次构建收口 + 定向查这条族**（不许先做 2 字再补）。

### 3.8 可选件（**明确标可选；默认不做**）

| 件 | 语义 | 代价 | 建议 |
|---|---|---|---|
| **O1** `stat_absrej_ans` | 该类中"**确实走了 `ackresp`/`w6a_ok` 支**"的事件数（`+1` 条件 = `evt_absrej && (ackresp || w6a_ok)`） | 再 +1 字（128 FF） | ⛔ **默认不做**。理由：它在**修复前结构性恒 0**（旧码的 `ackresp/w6a_ok` 对本类必为假）⇒ **单字是"结构性零"陷阱**；要它就必须**与 O2 成对**才有意义。而"修复是否真回 ACK"在 xsim 里可以直接看 `ack_req`（§4），**板侧不必花 256 FF** |
| **O2** 分裂：`stat_absrej` 拆成 data/ack 两支 | 分辨两个支路各发生多少 | +1 字 | 若将来板级真要量化（例如"纯 ACK 支是否真的存在"），再加；**先上单字** |
| **O3** 把 `stat_drop_seq` 接进窗口 | 让"修复后的落点"也在窗口里 | +1 字 | **不必**：O3 的信息被 W70 + W23 的**位移**覆盖，且 W23 是宽口径 ⇒ 单看它没有判别力 |

---

## §4 负对照 / 门的设计（**能在 xsim 里跑**，且"**改之前会红**"）

### 4.1 现成的门在哪 / 现在有没有牙（**现核结论**，与派单的已知三条逐条对）

**最近的现成入口 = `tb/tb_tcp_rx.v`（304 行）+ `sim/p3sim/run_tb_tcp_rx.bat` + oracle `tools/gen_stim_tcp_rx.py`（875 行）。**
它已经：驱动 GMII 字节流 + 配 CAM/TCB（`:179-190` 一带）、捕获 `m_axis`/`META`/`FEND`/**`ACK`**（`:296-303`）、
落 `TCB` 终态（`:280-291`）、并已有 W68 的"TB 侧独立复算"范例（`:61-72`）。

| 派单的已知项 | **现核判定** | 依据（逐字） |
|---|---|---|
| "`tb/tb_tcp_rx.v` 的判据是 **grep-only、没接到退出码**" | **一半对**：TB 内的 `[FAIL] …`（`:282,284`）**确实是 `$display` 打印型**（`run.tcl` 只有 `run all` + `quit`（`sim/p3sim/run.tcl`）⇒ **不进口/出口码**）。**但**权威判据在 python 侧：`gen_stim_tcp_rx.py` 的 `check()`（`:823-865`）比对 TB 落盘文件，`__main__` 走 `sys.exit(0 if ok else 1)`（`:870-874`），而 `run_tb_tcp_rx.bat` 末行 = `exit /b %errorlevel%` ⇒ **退出码这条链是有的** | `sim/p3sim/run.tcl` · `run_tb_tcp_rx.bat` 末两行 · `tools/gen_stim_tcp_rx.py:870-874` |
| "该门**在本轮之前就已经是红的**" | ✅ **属实**：`P7B_REGRESSION.md:219` = `p3_tcp_rx` / `run_tb_tcp_rx.bat` / **RC=1** / `hard: 92 lines, stats {…}` / **FAIL 既存**。TB 自己的注释也登记了（`tb/tb_tcp_rx.v:278-279` 逐字"⚠️ 本门的整体口径另有既存红 (HARD 臂的 python 期望失配), 与本判据无关"）。**根因【未定位】**——本件只登记两个**可疑面**（不裁定）：① oracle **没实现 `w6a_ok`**（`grep -c w6a tools/gen_stim_tcp_rx.py` = **0**；纯 ACK 进 `PAD` 的唯一入口是 `:485` 的 `acc_l` 支）② `hard` 臂的**硬停窗**会改变帧的时间关系 | 同上 |
| "把'新门挂在哪个能进退出码的入口'作为设计的一部分" | ✅ 见 §4.2/§4.4 | — |

### 4.2 新门设计（**独立门**，`sim/p7bg_seqwrap/`）

**为什么独立**：现成门的退出码**已经恒 1**（§4.1）⇒ 挂在它上面的新判据**无法与既存红区分**
（"红里套红" = 本工程"哑门"族的新变种）。⇒ **新建一个自己的入口**，照 `sim/p7b_longsend/run_cont_gate.bat`
的"多臂 + 冻结锚 + 变异体 + 逐条 RC 判据"模板（该门模板逐字可读：`:A/B/C/G + M1..M5 + RC 判据 5 条`）。

**目录（新建，全部新增文件，零改动既有门）**：
```
sim/p7bg_seqwrap/
├── tb_seqwrap.v            新 TB (GMII 注入 + ACK/m_axis/TCB 捕获; 期望值全硬编码)
├── run_seqwrap_gate.bat    自定位 + PATHGUARD (照 sim/p3sim/run_tb_tcp_rx.bat 的头 15 行)
├── frozen/tcp_rx_prefix.v  ⭐ 冻结的**修复前** rtl/tcp_rx.v 副本 (G 臂; 记录 sha256)
└── mut/m1..m4*.v           4 个变异体 (由 mk_mut_seqwrap.py 生成; 生成器与产物必须同源)
```

**臂与判据（逐条，写得出来就照抄）**：

| 臂 | 编译哪个 `tcp_rx.v` | 期望 | 判据 |
|---|---|---|---|
| **A**（正例） | 现役 `rtl/tcp_rx.v`（修复后） | **RC = 0** | 全部 5 帧判定逐条命中（§4.3 表） |
| **G**（负对照 = "**改之前会红**"） | `frozen/tcp_rx_prefix.v` | **RC ≠ 0** | 红点**恰好** = {F1 无 ACK、F2 `snd_una` 仍 0、F5 无 ACK} **三条**；且 {F3, F4} 两帧**必须不红**（等价域不许动） |
| **M1**（冗余项变体） | A + `seq_lt = seq_diff[31] && (seq_diff != 0)` | **RC = 0** | 证明该写法**逐位等价**（§2.1 的代数已证；此处是"实现无笔误"的实证） |
| **M2**（半成品） | A + **只修 `ackresp` 站**（`w6a_ok` 保留 `seq_lt_abs`） | **RC ≠ 0** | 红点 = {F2}（`snd_una` 不推进）⇒ 证明"两条链都要修" |
| **M3**（边界约定反转） | A + `seq_lt = seq_diff[31] && (seq_diff != 32'h80000000)` | **RC ≠ 0** | 红点 = {F5} ⇒ **把 §2.2 的边界裁定钉成判据** |
| **M4**（判据本身有牙） | A + `seq_lt = 1'b0` | **RC ≠ 0** | 红点 ⊇ {F1,F2,F5} ⇒ 证明"红"确实由这个信号驱动（防"门根本没牙"） |

**退出码纪律（三条硬要求，全部是本工程踩过的坑）**：
1. **`FAIL` 必须走到退出码**：bat 逐臂收 `%errorlevel%`（`call :run A …` + `set RCA=%errorlevel%`），
   末了按 **RC 判据**统一裁定并 `exit /b <非零>`；⛔ **末行不许无条件打 `PASS`**（全局 #53：打 `FAIL` 却 `exit 0`、末行写 `PASS`）。
2. **FATAL 分支必须计失败**（"什么都没跑"被判成 PASS 是本工程自研门踩过两次的坑，`P7B_BIZ_WINDOW.md:228-229`）：
   缺 python / 缺 RTL / 缺 TB / 缺 frozen 锚 ⇒ `exit /b 1`（照 `run_cont_gate.bat` 的头部四行）。
3. **指纹守卫**：对 A 臂要 `findstr /C:"SNAP_NW_P6E = 71"` 之类**反查几何**不合适（本门不编 wrapper）；
   改为**核 `rtl/tcp_rx.v` 的 sha256 ∈ {本设计件登记的 G 臂值}** —— 防止"跑的是别的 checkout/别的代"
   （真空门族，`P7B_LONGSEND_ACCEPT.md:171-175`）。

### 4.3 具体激励（**逐帧表：序列号取值 + 期望判定 + 期望命中条数**）

**配置阶段**（照 `tb/tb_tcp_rx.v:179-190` 的写法：CAM ← `cfg_*`；TCB conn0 ← 6 个字段）：

| 项 | 取值 | 备注 |
|---|---|---|
| CAM[0] | sip `10.0.0.1` / dip `192.168.100.2` / sport `12345` / dport `8080` / dmac `11:22:33:44:55:66` | 与既有 TB 的 conn0 同款（`:186-188`） |
| `rcv_nxt` | **`0x0000_0100`** | = 已跨过 2³² 边界之后的位置（模拟"rcv 侧 4 GiB 流量的下一个位置"） |
| `rcv_wnd` | `0x4000` | 与既有 TB 同量级 |
| `snd_una` | `0x0000_0000` | — |
| `snd_nxt` | `0x0000_0200` | 供 `ack_ok`/`dup_ack` 的上界 |
| `state` | `1`（ESTAB） | — |
| `wscale` | `0` | — |
| `ra_retx_hi/active` | `0` / `0` | `ack_hi = snd_nxt` |
| `ACC_MARGIN` | `16'd0` | 与既有单元 TB 同款（`:117`） |

**5 帧（全部 60 B 最小帧填充；FCS 正确；`doff=5`；`flags=0x10`）：**

| 帧 | `seq` | `ack` | 载荷 | `d = seq − 0x100` | 旧 `seq_lt_abs` | 新 `seq_lt_rfc` | 类别 |
|---|---|---|---|---|---|---|---|
| **F1** | `0xFFFF_FF80` | `0x0000_0010` | 100 B | `0xFFFF_FE80` | 0 | 1 | **回卷后旧数据段** |
| **F2** | `0xFFFF_FFC0` | `0x0000_0010` | 0 | `0xFFFF_FEC0` | 0 | 1 | **回卷后旧纯 ACK** |
| **F3** | `0x0000_0100`（= `rcv_nxt`） | **`0x0000_0000`**（= `snd_una`） | 100 B | `0x0000_0000` | 0 | 0 | **正常顺序段**（等价域正例） |
| **F4** | `0x0002_0100`（= `rcv_nxt+0x20000`） | `0x0000_0010` | 100 B | `0x0002_0000` | 0 | 0 | **远超前段**（等价域正例；d < 2³¹） |
| **F5** | `0x8000_0100`（= `rcv_nxt+2³¹`） | `0x0000_0010` | 100 B | `0x8000_0000` | 0 | 1 | **边界行**（§2.2 的裁定） |

**⚠️ 帧序与"哪一帧的 `ack` 是判据"（**这一条不写清，F2 的判据会失效**）**：
TCB 写的是**绝对值**（`upd_val <= ack32_l`，`:515`）⇒ 末次写覆盖前次 ⇒
**要判"F2 的 ACK 被处理了吗"，F2 必须是最后一帧**，且**中间的帧不许写 `snd_una`**。
逐帧核过（`pend_una` 只在 `fend` 拍置位 `:508`）：
- **F3**：`acc_l=1` ⇒ 走 `S_PAY` ⇒ **有 `fend_pay`** ⇒ `pend_una <= ack_adv_l`；把它的 `ack` 设成
  **`0x0000_0000`（= `snd_una`）** ⇒ `ack_adv = 0` ⇒ **不写 `snd_una`**，但仍写 `snd_wnd`（`pend_wnd` 无条件）；
- **F1/F4/F5**：三帧在两臂里**都**落 `S_DROP`（F1/F5 在 A 臂带 `drop_ack=1`，但 `S_DROP` **没有 `fend`**）⇒ **不写 TCB**；
- **F2 放最后** ⇒ 末次写 `snd_una` 的**唯一**候选就是 F2 ⇒ **终态可判**。
⇒ **推荐帧序 = `F3 → F4 → F5 → F1 → F2`**（若把 F2 放中间，就必须在 F2 与下一帧之间**按周期采样** `snd_una`，
那是更脆的判据形态）。

**期望判定（A 臂 = 修复后；命中条数写死）**：

| 帧 | A 臂（修复后）期望 | G 臂（修复前）期望 | **两臂差异** |
|---|---|---|---|
| F1 | `ack_req` **×1**（`ack_val = 0x0000_0100`）+ `stat_drop_seq +1` + `m_axis` **0 词** + `rcv_nxt` 不变 | `ack_req` **×0** + `stat_drop_nonmatch +1` | ⭐ **有**（本条 = 目标修复） |
| F2 | `fend_pad` 触发 ⇒ **终态 `snd_una` = `0x0000_0010`** + `stat_pass +1` + `ack_req` **×0** | **终态 `snd_una` = `0x0000_0000`** + `stat_drop_nonmatch +1` | ⭐ **有**（链 B） |
| F3 | 交付 **100 B 逐字节** + `rcv_nxt` → `0x0000_0164` + `ack_req` ×1（`ack_val=0x164`）+ `snd_una` **不变** | **逐位相同** | **无**（等价域：必须相同） |
| F4 | `stat_drop_nonmatch +1` + `ack_req` ×0 + `m_axis` 0 词 | **逐位相同** | **无**（等价域：必须相同） |
| F5 | `ack_req` **×1** + `stat_drop_seq +1`（§2.2：判"旧段"） | `ack_req` ×0 + `stat_drop_nonmatch +1` | ⭐ **有**（**边界约定**的钉死点） |

**汇总期望（写死）**：A 臂 `ack_req` 总脉冲 = **3**（F1/F3/F5）；G 臂 = **1**（F3）。差异集 = **{F1, F5}**（脉冲）+ **{F2}**（`snd_una`）。
⇒ 判据 = **"A−G 的差异恰好是这三格，且 F3/F4 两臂逐位相同"**。
**新计数器（§3）期望**：**A 臂 +3 / G 臂 +3**（F1/F2/F5 各 1；**F3/F4 必须 +0**）。
⇒ 这条同时是计数器的**正例（3）与负例（0）**，即"注入过 ≠ 测到了"的反面：**期望命中条数写死，多一条少一条都红**。

**TB 侧 oracle 纪律**（照 `tb/tb_tcp_rx.v:61-65` 的逐字教训）：
- ⛔ **不许**在 TB 里引用 DUT 的 `evt_absrej`/`ackresp`/`w6a_ok` 线当期望（那是**环路恒等式**，改 RTL 时 oracle 跟着改 ⇒ 永远相等 = 没牙）；
- TB 侧要**独立复算**计数器的分子（用自己的 `rcv_nxt` 影子寄存器 + 自己的 `base_ok` 项），或**直接用本表的常量 3**
  （本门的激励是固定的 ⇒ **常量期望是最强 oracle**）。

### 4.4 为什么必须新门（不能挂在现门上）——三行理由

1. 现门的**退出码已经恒 1**（`P7B_REGRESSION.md:219`）⇒ 新判据挂上去**读不出来**（红里套红）。
2. 现门的 oracle **站在绝对比较那一边**（§4.5）⇒ 同批改动会**改写它自己**，共享一个文件 = 一次改动两个语义。
3. 需要一条**冻结的修复前 RTL**（G 臂）—— 现门的编译行写死 `..\..\rtl\tcp_rx.v`（`run_tb_tcp_rx.bat`），
   要换源就得改既有门 ⇒ 违反"每轮一个独立臂"的纪律。

### 4.5 ⭐ 必须同批改的 **oracle**（这条不在 §3.6 的读侧清单里，**是本件的新发现**）

| 文件:行 | 现在写的是什么 | 为什么必须改 |
|---|---|---|
| `tools/gen_stim_tcp_rx.py:445` | `seq_lt = seq32 < t['rcv_nxt']` | ⛔ **它是绝对比较**（与 `rtl/tcp_rx.v:305` 逐字同义）。修复后 RTL 与模型**必然打架** ⇒ 该门的红会**换形状**（本工程已登记的"同一个验收缺陷在下一轮换形复发"）。改法 = `seq_lt = ((seq32 - t['rcv_nxt']) & 0xFFFFFFFF) >= 0x80000000` |
| `tools/gen_stim_tcp_rx.py`（全文） | **没有 `w6a_ok`**（`grep -c w6a` = 0；`PAD` 的唯一入口是 `:485` 的 `acc_l` 支） | 模型与 RTL 在**纯 ACK 非边界**路径上**本来就不同** ⇒ 该门的既存红**根因未定位**；改动前先把这条**登记**清楚（本件不裁定它是不是既存红的根因） |
| `sim/p7b_stageb_rx8_regress/mirror/tb/tb_tcp_rx.v` 等镜像件 | 同源副本（`grep` 实测存在） | ⚠️ **镜像件 = 历史夹具，不追改**（规则见 §3.6 末）；但要**知道它们存在**（`grep` 命中 3 处：`sim/p4gates/evidence/negctl/foreign/tb/`、`sim/p7b_stageb_rx8_regress/mirror/tb/`、`sim/p7b_stagec_tx_regress/mirror/tb/`） |

---

## §5 注释订正

### 5.1 `rtl/tcp_rx.v:305` 那行注释的**替换文字**（逐字可粘贴）

**原文（逐字，工作树 `:305`）**：
```verilog
    wire        seq_lt   = (seq32 < ra_rcv_nxt);   // 重复/旧段 (回绕安全: 无符号比较)
```

**替换（逐字；⚠️ 文件是 CRLF ⇒ 编辑器的行尾设置必须是 CRLF，别引入裸 LF）**：
```verilog
    // RFC 793 SEQ_LT: (int32)(seq32 - ra_rcv_nxt) < 0。旧写法 `seq32 < ra_rcv_nxt` 是**绝对比较**,
    // 只在 `seq32 - rcv_nxt` 作为普通整数落在 [-2^31, 2^31-1] 时与之逐位相同 (等价域; 极端点
    // -2^31 也相同)。回卷角例 (rcv_nxt 刚越过 0xFFFFFFFF 而旧段 seq 仍在回卷前) 恰在等价域**之外**:
    // 旧写法判"远超前段"⇒ 静默不回 ACK; 新写法判"旧段"⇒ 回 ACK (RFC 793/5961 要求)。
    // 边界: 差恰为 0x80000000 时判 seq_lt=1 (two's complement 直译; 见 P7B_BUILDG_RFC_SEQ_DESIGN.md §2.2)。
    wire        seq_lt   = seq_diff[31];           // = $signed(seq32 - ra_rcv_nxt) < 0
```

要求满足情况：**不过宽**（写明"等价域"与"两类例外"）；**含边界约定**；**含出处**（设计件名）。
⚠️ 纯注释改动的**网表差异为零**，但**文件哈希会变** ⇒ 走"搭下一次构建"的既有惯例（`P7B_OPEN_ITEMS.md:27` 的 A8 行已登记该动作）。

### 5.2 同族过宽措辞清单（**只列，不改**；本轮不碰 RTL）

| # | 位置 | 逐字（过宽的部分） | 为什么过宽 |
|---|---|---|---|
| 1 | `rtl/tcp_rx.v:305` | `// 重复/旧段 (回绕安全: 无符号比较)` | **"回绕安全"不成立**（绝对比较在差异域不等价于 RFC 语义）—— 本项修（§5.1） |
| 2 | `rtl/tcp_rx.v:344-345` | `// 远超前段 (!seq_eq && !win_ok && !seq_lt) 仍不回 ACK (与原语义一致);` | `:757-760` 的 `else` 支是"**没被 acc/w6a_ok/ackresp 收下的全部**"的兜底，**不只**"远超前段"（`plen=0` 且 `w6a_ok=0` 的距离过远纯 ACK 也落这里） |
| 3 | `rtl/tcp_rx.v:311` | `// 会话期 retx_hi >= snd_nxt 恒成立 (回卷只降 snd_nxt, 重放最多推回 retx_hi),` | "**恒**"字过强（依赖 `tcp_tx_frame` 侧行为；本件**未核**该不变量，只登记措辞） |
| 4 | `rtl/tcp_rx.v:327-333` | `// 窗口内/右沿/旧段都接受` | 是**意图**不是**实现**："旧段"的实现口径正是 `seq_lt`（本轮修复前它只覆盖"数值上的旧段"）⇒ 修复后才字面成立 |
| 5 | `rtl/tcb.v:13-18 / 148-150` | B8 订正块（`0xBFFE` → `0xF000`） | 措辞本身已订正 ✓（列出仅为"同族已处理"的对照） |
| 6 | `tools/gen_stim_tcp_rx.py:445`（oracle 里的同名比较） | `seq_lt = seq32 < t['rcv_nxt']` | **无注释**（静默的绝对比较）⇒ 比"过宽措辞"更隐蔽的一格（§4.5） |

⚠️ 扫描命令（复算用）：
`grep -n "安全\|恒\|必定\|不会\|绝不" rtl/tcp_rx.v`（命中已在表内逐条裁定；**其余命中**是"每拍默认清零"等
描述性文字，**不属过宽**）。

---

## §6 未定 / 不做的（不许掩饰）

1. **待用户/TL 裁定（决策点，本件不代行）**：
   - **D1**：走 §2.6 的**方案 A**（改 `:305` 一行，两链同时修）还是**方案 B**（只修数据段那一站）？
     本件推荐 **A**；
   - **D2**：**§2.2 的边界裁定**（`d = 0x80000000` 判 `seq_lt = 1`）是否接受？另一种约定要加 32 位相等比较；
   - **D3**：**Build G 搭不搭 §3 的计数器**？（不搭 = 修复**没有板侧正面判据**，只剩 xsim 门；
     搭 = 一次构建 + 128 FF + pcie 复位族的时序风险）；
   - **D4**：`stat_absrej` 这个**名字**是否接受（改名 = 再走一遍 §3.6 的同步）。
2. **【未量】/【需仿真·综合】**（本件一个读数都没产生）：
   - 33 位抽头 vs 保留 32 位比较器的**LUT/时序净变化** —— 【需综合】；
   - 新字对 **pcie 复位族（现役全局 WNS `+0.111` Recovery）** 与 **DP 域（现役 0.281）** 的影响 —— **必须一次构建 + 定向 STA**；
   - `evt_absrej` 在**真实板级流量**下的发生率 —— 【未量】：它需要"上行 ≥ 4 GiB 跨回卷 + 旧段撞界"，
     **本件不能断言它一定 > 0**；若板级两臂都是 0 ⇒ 口径 = **"本工况判别力为空"**（**不许记 PASS/FAIL**）。 ⚠️ **不许把"没观察到"写成"没有后果"**。
   - G 臂（冻结 RTL）在门里的实测红点集 —— 【需仿真】；本件只给**期望**（{F1,F2,F5}）。
3. **依赖的假设（明写）**：
   - 假设 §1.2/§3.1 引用的**信号全在 `dp_clk` 域且是寄存器输出**（`stat_absrej` 必须是 `reg`；这是 `snap_cdc` 的硬前提，`rtl/snap_cdc.v` 头注释"din_b 必须只在 clk_b 沿变化"）；
   - 假设"§2.4 的等价域证明"覆盖**所有合法输入**（合法 = 窗内 + 未跨回卷）—— **证明本身是硬的**，
     但因为下游是两条 FSM 链，"端到端等价"仍**必须由门回答**（本件只证了 `seq_lt` 这一个信号）。
4. **已知会变但**尚未**在板级量化**的两个次生后果（§2.5-③/④）：**dup-ACK 计数**与 **`ack_obs`**。
   ⚠️ 这两条在 `TCP_TX_OVL` 构建里连着**重传**与 **app 数据启动门**（r6-fix 的根修点）⇒
   一旦 `abs_rej` 在真实流量里非 0，它们**会**跟着动。**本轮不裁定这是好是坏**，只登记；
   ⛔ 尤其**不许**写"这只是多回一个 ACK"（因为 ③/④ 会让行为分叉到 TX 侧）。
5. **本件不做**：改 `rtl/`（含注释）、改 `tb/`、改 `tools/`、改 `sim/`、构建、跑 xsim、上板、动 git（除本文件外的读取）。
6. **时序口径**：⛔ **不许写"时序问题已解决"**；F 档 `+0.111` 是 **Recovery 族**（不是 setup），
   本字的 64 个 pcie 域 FF 就挂在那条共享复位网上 ⇒ 该族的走势**只能由一次构建给出**。
7. **不做的事（明确排除）**：不把 `seq_lt` 的修复与 `F-3`（MMCM 失锁）/`#18`（`_proj_mdio`）**同批**——
   机制无关（`P7B_L_INSTRUMENT_DESIGN.md` §5.1 已裁定）；不顺手改 `stat_drop_seq` 的窗口化（§3.8-O3）。

---

## 附录 A：本件引用到的既有件（逐条可核）

| 件 | 本件用到的内容 |
|---|---|
| `_proj_10g/notes/P7B_OPEN_ITEMS.md` | `:27`（表行 #9）· `:38`（表行 #20 `gen_inputs.py` 两轮漏改）· `:126-130`（§1-A8 逐字） |
| `_proj_10g/notes/P7B_LONGSEND_DESIGN.md` | `:948-971`（§5.5-8：两处偏离 + 注释待订正 + "62 次回卷未观测"） |
| `_proj_10g/notes/P7B_LONGSEND_ACCEPT.md` | `:154-175`（§4-④ 逐条 + 行尾/G3/oracle 的既有登记） |
| `_proj_10g/notes/P7B_L_INSTRUMENT_DESIGN.md` | `:396-450`（§4.1 = #9 的前身设计）· `:561-593`（§5.1 打包裁定 = **#9 单独一臂 Build G**）· `:594-610`（§5.3 需仿真/综合清单） |
| `_proj_10g/notes/P7B_BIZ_WINDOW.md` | `:12-24`（70 字更新块）· `:28-51`（W51..W69 字表）· `:52-54`（未实现地址逐代）· `:69-92`（五处同改 + 两个守卫） |
| `_proj_10g/notes/P7B_A7_BUILD.md` | `:59-79`（§1.4 = 读侧全链清单的**格式**模板） |
| `_proj_10g/notes/p7b_buildF/apply_readside.py` | 八组同步清单的**最全一版**（本件 §3.6 照它逐组重走） |
| `_proj_10g/notes/p7b_buildF_build/READINGS.txt` | `:90-99`（F 档 WNS/WHS + 三类失败端点）· `:106-152`（DP 域 / 全局 Recovery 族 / 新仪器锥的定向查询） |
| `_proj_10g/notes/P7B_REGRESSION.md` | `:216-220`（`p3_*` 四条门的 RC/状态，**`p3_tcp_rx` = RC 1 / FAIL 既存**） |
| `sim/p7b_longsend/run_cont_gate.bat` | 独立门的**模板**（A/B/C/G + M1..M5 + 逐条 RC 判据 + 冻结锚） |
| `tb/tb_tcp_rx.v` | `:61-72`（TB 侧独立复算的纪律）· `:113-142`（`tcp_rx` 例化，含 `ACC_MARGIN(16'd0)`）· `:296-303`（ACK/FEND 捕获） |
| `tools/gen_stim_tcp_rx.py` | `:442-455`（模型判据，**含绝对比较 `seq_lt`**）· `:817-874`（`check()` + 退出码） |
| `rtl/snap_cdc.v` · `_proj_pcie/rtl/axi_regs.v` | `:93`/`:118`/`:202`（**96 FF/字**的三处来源） |

## 附录 B：本件**没有**做的事（自证边界）

- 未运行任何 `xvlog/xelab/xsim/Vivado`；未读/写 `/dev/xdma*`；未 ssh 对端；未烧板；未跑 git 写操作。
- 未改 `rtl/`、`tb/`、`tools/`、`sim/`、`board/` 的**任何字节**；本文件是**唯一**新增件。
- 所有"行号"均为**工作树（构建 F 态）**读数；**若先提交 F，行号会整体位移，必须现取**（§1.1）。⛔ **2026-10-10 订正（构建 F 轮）：F 已随 `34fb68b` 入库 ⇒ **工作树 = HEAD** ⇒ **本件行号仍有效、且即 HEAD 行号**；该"若先提交 F"分支**已发生**，而**提交本身不改变行号** —— 位移只来自**后续再改 RTL**（届时按 `git show HEAD:<file> | grep -n` 现取）。原句保留。**
