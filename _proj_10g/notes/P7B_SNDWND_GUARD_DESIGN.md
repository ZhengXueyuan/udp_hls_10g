# P7B-SNDWND-GUARD 设计件：`pend_wnd` 写入无守卫（陈旧/不可接受 ACK 的窗口覆盖当前窗口）

- 轮次：**2026-10-11 `snd_wnd` 无守卫（现核 + 设计）**。**零构建 / 零 xsim / 零 Vulado / 零上板**（构建 agent 正在跑 ⇒ `rtl`/`tb`/`sim`/`board` 逐字冻结；本件只读源码 + 落一个 `.md`）。
- 派单出处：`_proj_10g/notes/P7B_TL_LEDGER_20261010.md` §3-3 / §10-1 #6 / §10-2（缺陷总账第 3 行）。
- 一句话：**`rtl/tcp_rx.v` 的 `pend_wnd`（发送侧"对端通告窗"的 TCB 更新 pend）在写入时没有任何 ACK 层面的守卫 —— 任何 FCS-OK 且走到 `fend` 的帧都会把它的 `window` 字段写进 TCB 的 `snd_wnd`，包括陈旧/不可接受/越界 ACK 的帧。** 本件给出：现核（行号 + 行内容）、"是不是真缺陷"的判定与证据、板级可达性分析、**保住零窗恢复**的最小修法（含 RFC 逐条依据）、门与判据、未定项。
- 口径纪律：**不下 PASS/FAIL 裁定**（判据裁定权在用户/判据所有者）；**不写"时序已解决"**；**不把"未观测到"写成"不存在"**；凡行号 = **2026-10-11 本 session 现读**（实施轮开工前先 `git rev-parse HEAD` 复核，见 §7 行号表）。

---

## §0 落笔基线（现核）

| 项 | 值 |
|---|---|
| 工作树 | `D:\repo\XCKU5PMini\udp_hls_10g`（`git status` 在飞改动 = `board/wrapper_p4.v` 等构建 agent 的文件；`rtl/` 本件全程只读） |
| 相关文件 | `rtl/tcp_rx.v`（缺陷本体）· `rtl/tcb.v`（`snd_wnd` 存储/消费）· `rtl/tcp_tx_frame.v`（下游门控/武装）· `rtl/slow_cfg_adp.v`（**另一个 `snd_wnd` 写者 = 建连配置**）· `tools/gen_stim_tcp_rx.py` + `tb/tb_tcp_rx.v`（现役单元门） |
| 在飞的相交刀 | persist 刀（`fd671b6` 已入库，`PERSIST_EN` 默认 `1'b0`）· 重放越界刀（`11ad9ec…7124147`）—— 两刀都在 `rtl/tcp_tx_frame.v`，**与本文的改动文件不相交**（见 §4.6） |
| 板上现役 | 构建 F（BID `0x1A`）/ 70 字窗口 —— **与本文无关，仅作背景**；缺陷批构建（含本修法）按台账 §10-3 排在 persist 之后、单独构建 |

---

## §1 现核：缺陷真实性（行号 + 行内容 + 消费者全清单）

### 1.1 三条 pend 的写入条件（现读，`rtl/tcp_rx.v`，逐字抄行内容）

`if (fend) begin`（`:502`）块内，三个 pend 的**置位**：

```
:506	                pend_rcv <= (acc_l && (adv_cnt != 16'd0) && s_axis_tcrs &&
:507	                             !fend_trunc) || pend_rcv;
:508	                pend_una <= (ack_adv_l && s_axis_tcrs) || pend_una;
:509	                pend_wnd <= s_axis_tcrs || pend_wnd;
```

**值寄存器**的三段（`:`510-521`）：

```
:510	                if (acc_l && (adv_cnt != 16'd0) && s_axis_tcrs && !fend_trunc) begin
:511	                    pend_rcv_val <= rcv_nxt_l + {16'b0, adv_cnt};
:512	                    pend_id <= conn_id_l;
:513	                end
:514	                if (ack_adv_l && s_axis_tcrs) begin
:515	                    pend_una_val <= ack32_l;
:516	                    pend_id <= conn_id_l;
:517	                end
:518	                if (s_axis_tcrs) begin
:519	                    pend_wnd_val <= wnd_ws;
:520	                    pend_id <= conn_id_l;
:521	                end
```

**对照**（这是本缺陷的第一支证据）：

| pend | 置位条件 | 值锁存条件 | 有 ACK 层守卫? |
|---|---|---|---|
| `pend_rcv` | `acc_l && adv_cnt!=0 && tcrs && !fend_trunc` | 同款 | ✅（`acc_l` = 序列/窗口/四元组全过） |
| `pend_una` | `ack_adv_l && tcrs` | 同款 | ✅（`ack_adv_l` = **可接受且推进**的 ACK） |
| **`pend_wnd`** | **`s_axis_tcrs`** | **`s_axis_tcrs`** | ❌ **只有"帧没坏"一条** |

`ack_adv_l` 的定义链（现读）：`:322` `wire ack_adv = ack_ok && (ack32 != ra_snd_una);` → `:321` `wire ack_ok = ((ack32 - ra_snd_una) <= (ack_hi - ra_snd_una));` → `:320` `wire [31:0] ack_hi = ra_retx_active ? ra_retx_hi : ra_snd_nxt;` → `:684` `ack_adv_l <= ack_adv;`（w5→w6 沿锁存）。另有 `:691` `ackok_l <= ack_ok;`（**r6-fix 的锁存，见 §1.4**，本修法用它）。

### 1.2 模块自己的成文合同（第二支证据：它违反自己的注释）

`rtl/tcp_rx.v:83-87`（现读逐字）：

```
:83	    // P4b-7-P6 ROOT CAUSE #2 修复: pend 标志 sticky — fend 只置位不覆盖, drain 在
:84	    // 写被 gnt 时逐字段清除。旧实现每 fend 重锁存 (非推进帧的 fend — 重复纯 ACK
:85	    // 突发 / 坏 FCS 帧 — 把未写出的推进 pend_una/pend_rcv 重锁成 0 → snd_una/
:86	    // rcv_nxt 永久停滞 → 在飞涨到 RING_CAP → 窗门误关 → 死锁)。值寄存器只在
:87	    // 对应条件成立时更新 (否则挂起推进值被重复帧的旧 ack/旧窗口覆盖)。
```

`:86-87` 逐字写的规则是"**值寄存器只在对应条件成立时更新（否则……被重复帧的旧 ack/旧窗口覆盖）**"——句子里**点名了"旧窗口"**。这条合同对 `pend_rcv`/`pend_una` 被实现（`:`510/:514` 各带自己的条件），对 `pend_wnd` **没有实现**：它的"对应条件"被写成了仅仅 `s_axis_tcrs`（= "这帧 FCS 没错"），而**帧没错 ≠ 帧里的 ACK/窗口是当前有效的**。

### 1.3 值路径现读（含两个"值也陈旧"的子情形 —— 如实登记）

```
:456	    wire [15:0] wnd_f = fend_w6 ? s_axis_tdata[63:48] : wnd_l;
:460	    wire [31:0] wnd_scaled = {16'b0, wnd_f} << ra_wscale;
:461	    wire [15:0] wnd_ws    = |wnd_scaled[31:16] ? 16'hFFFF : wnd_scaled[15:0];
```

`wnd_l` 的锁存点（现读）：`:706` `wnd_l <= s_axis_tdata[63:48];`（在 `default:` = `wcnt==6` 的 accept 分支里）与 `:746`（同分支的 `else if (acc_l)` 子支）。**非阻塞语义** ⇒ 在**同一拍**发生的 `fend` 上，`wnd_f` 读到的 `wnd_l` 是**上一帧**留下的值。由此：

| fend 形态 | 本拍拿到的 window 值 | 结论 |
|---|---|---|
| `fend_w6`（w6 帧尾、plen≤2、keep 匹配） | `s_axis_tdata[63:48]`（**本帧**） | ✅ |
| `fend_pay` / `fend_pad`（真实 60B 纯 ACK / 带载荷帧） | `wnd_l`（**本帧** w6 已锁存） | ✅ |
| `fend_w6t`（acc_l 但 w6 帧尾被截断） | `wnd_l` = **上一帧的窗口** | ⚠️ 值陈旧（登记，§1.4/D-2） |
| `fend_w6a`（P4c 短帧 ACK-early 路径） | `wnd_l` = **上一帧的窗口** | ⚠️ 同上（TB 可注入；真实 60B 帧走 `S_PAD`） |

⚠️ 这一格**不是**本修法必须处理的，但**门的设计必须知道它**：想造"陈旧 ACK 带小窗"的 TB 用例，**必须用真实 60B 纯 ACK（`S_PAD→fend_pad`）或载荷帧（`fend_pay`）**，否则注入的 `wnd` 根本不会成为被写进 TCB 的值（会写成上一帧的 `wnd_l`）——"注入对了、值错了"是最容易造出**假阴性门**的地方（§5.1）。

### 1.4 消费者全清单（按"信号"逐个列全；含"第 5 个消费者"排查）

> 纪律来源：台账 §8-4 #9（"改一个 mux 的 arm = 必须先列出读它的**全部**消费者"；persist v2 就漏过 `rb_id` 的第 5 个消费者）。**本件对所有相关信号逐个 grep + 逐行核对，结论 = 无遗漏的第 5 个（清单如下）。**

**A. `pend_wnd`（1 位，`rtl/tcp_rx.v:228` 声明）的读者（全仓只有本文件，`grep -rln pend_wnd --include=*.v` 另命中的 9 份全是 `sim/` 下的**冻结变异/取证副本**，不是活代码）：**
1. `:464-465` `assign upd_wr = ((drn == 2'd1) && pend_rcv) || ((drn == 2'd2) && pend_una) || ((drn == 2'd3) && pend_wnd);` —— **TCB 写请求**（本符号唯一的"功能"消费者）。
2. `:535-536` drain FSM `2'd3` 支：`if (!pend_wnd || upd_gnt) begin if (upd_gnt) pend_wnd <= 1'b0; drn <= 2'd0; end` —— 清除/推进。
3. `:485` 复位清零。
（`:509` 置位本身、`:526-540` drain 其余支不读它。）

**B. `pend_wnd_val`（16 位，`:231`）：**
4. `:468-469` `upd_val` mux 的 `drn==2'd3` 臂（`{16'b0, pend_wnd_val}`）。
5. `:519` 锁存、`:486` 复位。

**C. `pend_id`（4 位共享，`:229`）：** `:466`（`upd_id`）、`:512` / `:516` / `:520`（三个值锁存处各写一次，后者覆盖前者 = 既有语义）、`:486` 复位。

**D. 出模块之后的"有效写"路径（TSB 之外）：**
6. `board/wrapper_p4.v:2016-2048` TCB 写仲裁：`sel_tx = tx_upd_wr; sel_rx = !sel_tx && rx_upd_wr; assign rx_upd_gnt = sel_rx;`（`:2026-2028`）⇒ 本模块的 `upd_wr/upd_sel/upd_id/upd_val` 被 mux 进 `tcb_wr/tcb_sel/…`。
7. `rtl/tcb.v:100` `3'd4: snd_wnd_r[upd_id] <= upd_val[15:0];` —— **落盘点**。

**E. `snd_wnd`（落盘真实值）的消费者（下游/旁路，全列）：**
8. `rtl/tcb.v:152-156` `win_cap = min(snd_wnd, WIN_CAP)` → **`win_open`（注册输出）= TX 数据门的唯一源头**；`win_wnd_eff` 供调试/统计。
9. `rtl/tcp_tx_frame.v:93`（`rb_snd_wnd` 端口）→ 消费点：`:553-554`（`wnd_open = win_open` 帧器窗口门）、**`:753` `ps_arm`（persist 武装：`rb_snd_wnd == 16'd0 && rb_snd_nxt != rb_snd_una`）**、`:1231`（**OVL 支** RTO 扫描武装：`rb_snd_wnd != 16'd0 && …`）、**`:2361`（`else` 支的同款 RTO 武装 —— 同一信号的第二个消费者，宏分叉两条都要算）**、`:1709-1721`/`:1777`（`wnd_open` 并联进 tready 的注释点）。
10. `rtl/tcb.v:112` `ra_snd_wnd`（读口 A）—— ⚠️ **`tcp_rx` 自己根本没有这个端口**（`:70-77` 的读口 A 只拿 `rcv_nxt/snd_nxt/snd_una/rcv_wnd/state/wscale`）⇒ **本模块内部无法与"当前存储窗"比较**（这条决定了 §4.2 的修法选型：任何"窗不许收缩"的 Linux 式判断都需要新端口 ⇒ 非最小）。
11. `rtl/tcb.v:127` `rc_snd_wnd`（读口 C，app_ctrl 轮扫）→ `app_ctrl` 每连接状态块。
12. `rtl/tcb.v:134` `dbg_snd_wnd0` → `board/wrapper_p4.v:2907` `snap_wnd <= dbg_snd_wnd0` → `:3043` `uart_dbg.snd_wnd`（⚠️ **板上无 UART** ⇒ 这条线上板不可读）；**PCIe 快照窗口（W0..W69）里没有 `snd_wnd` 直读字**（见 §5.5）。
13. 间接：`win_wnd_eff` → `W67`（`stat_winstall_cap`）与 `W69`（`o_win_at_winstall` 的 `win_wnd_eff` 半字）。

**另有一个"上游写者"必须登记（否则会误判"pend_wnd 是唯一写者"）**：`rtl/slow_cfg_adp.v:86` `3'd4: tcb_val_c = {16'b0, w5[15:0]}; // snd_wnd = 对端窗口(已缩放)` —— **建连配置（HLS 慢路径）会在 ADD 序列里整字段写 `snd_wnd`** ⇒ 即使守卫拦掉全部 ACK 侧更新，`snd_wnd` 仍有建连初值来源（**不会**被"锁死在 0"）。这条同时说明：本缺陷的作用面 = **连接生命周期内的更新**，不是初值。

### 1.5 判定：**是缺陷**（规范层/合同层成立；触发层待实测）

三支证据（**证据强度分别标注**）：

1. **合同/一致性（结构性，强）**：同一模块同一段注释（`:86-87`）明文规定了"值寄存器只在对应条件成立时更新"，`pend_una`/`pend_rcv` 都实现了自己的条件，`pend_wnd` 没有（§1.1/§1.2）。缺陷的形态 = **三条兄弟写路径的守卫不齐**。
2. **规范（逐字，强）**：RFC 793 §3.9 p.72 的窗口更新判据（§2.1 逐字引）+ 其自带的理由句"**The check here prevents using old segments to update the window**"。现实现**没有任何 ACK 检查**（连 RFC 用作"可接受"界的那条比较都没有）⇒ 偏离是**规范文本级**的，不是口味问题。
3. **测试语料已把它当基线（行为性，强）**：
   - `tools/gen_stim_tcp_rx.py:170` `add('ack_badwin', 0, 'ack', ack=9000, wnd=0x1100)` —— TCB0 初始 `snd_nxt=6000`（`:39-43` 同源），**ack=9000 = "ack 了还没发的东西"**（RFC 793 p.72 对这类段的指示是 *"then send an ACK, drop the segment, and return"*）⇒ 该帧**不应**更新窗口，而现实现会写 `snd_wnd ← 0x1100`；
   - 生成器自己的注释（`:181` 附近）逐字写"**基流尾帧 ack_badwin 已把它改坏**"，并用定向段的全字段重配（`:97` `D_CFG2` / `:212-222` TB 侧）把它"洗回来" ⇒ **测试作者撞见过这个行为、把它当既定事实绕过，而没有当成缺陷登记**。

**严重度分层（如实口径）**：
- **规范层**：成立（是缺陷）。
- **现役板级链路层（Linux 直连 + AOC）**：**无已知自然触发序列、且从未被观测过**——⚠️ 这不是"不存在"（本工程没有任何仪器在看该事件的更新历史，见 §5.5）；按 §3.2 至少两条**可构造/瞬态**路径真实存在。
- **判据层**：本件**不下裁定**（无 PASS/FAIL）。

---

## §2 RFC 依据（逐字引文 + 引文层级标注）

> 取文方式：本机 `curl https://www.rfc-editor.org/rfc/rfc793.txt` / `rfc1122.txt`（**一手源**，非二手转述；RFC 编号 + 页号/节号按原文印刷标注）。**层级申明**：RFC 793 早于 RFC 2119，**通篇为小写规范散文**（"should"/"can be ignored"），本件引用时按其散文层级标注；RFC 1122 才有大写 **MUST / SHOULD**。

### 2.1 RFC 793 §3.9（SEGMENT ARRIVES，ESTABLISHED STATE，p.72）逐字

> "If SND.UNA < SEG.ACK =< SND.NXT then, set SND.UNA <- SEG.ACK. … **If the ACK is a duplicate (SEG.ACK < SND.UNA), it can be ignored.** If the ACK acks something not yet sent (SEG.ACK > SND.NXT) then send an ACK, drop the segment, and return."
>
> "**If SND.UNA < SEG.ACK =< SND.NXT, the send window should be updated. If (SND.WL1 < SEG.SEQ or (SND.WL1 = SEG.SEQ and SND.WL2 =< SEG.ACK)), set SND.WND <- SEG.WND, set SND.WL1 <- SEG.SEQ, and set SND.WL2 <- SEG.ACK.**"
>
> "Note that SND.WND is an offset from SND.UNA, that SND.WL1 records the sequence number of the last segment used to update SND.WND, and that SND.WL2 records the acknowledgment number of the last segment used to update SND.WND. **The check here prevents using old segments to update the window.**"

变量定义（RFC 793 §3.2，TCB 段，p.25 附近）逐字：

> "SND.WL1 - segment sequence number used for last window update / SND.WL2 - segment acknowledgment number used for last window update"

**落到判据（三层）**：
1. **陈旧/越界 ACK**（`SEG.ACK < SND.UNA` 或 `> SND.NXT`）：RFC 文本"can be ignored" + "drop the segment and return" ⇒ **窗口不得被它更新**。现实现违背（§1.1）。
2. **可接受 ACK**（`SND.UNA < SEG.ACK =< SND.NXT`）：窗口"should be updated"——但要过关 **WL1/WL2**。现实现**无 WL1/WL2 状态** ⇒ 层 2 的部分覆盖（§4.5 残留登记）。
3. RFC 文本用 `SND.UNA <` **严格大于**（`SEG.ACK == SND.UNA` 归入"duplicate ⇒ can be ignored"）——**这一条今天不能字面采用**，理由见 §2.3（会把零窗恢复打死，且 RFC 1122 的探测机制正是为这种"不前进的 ACK 会丢"而存在的）。

### 2.2 RFC 1122 §4.2.2.16 "Managing the Window"（p.91）逐字

> "A TCP receiver SHOULD NOT shrink the window, i.e., move the right window edge to the left. However, **a sending TCP MUST be robust against window shrinking**, which may cause the 'useable window' (see Section 4.2.3.4) to become negative."
>
> "If this happens, the sender SHOULD NOT send new data, but SHOULD retransmit normally the old unacknowledged data between SND.UNA and SND.UNA+SND.WND. … If the window shrinks to zero, the TCP MUST probe it in the standard way (see next Section)."
>
> DISCUSSION: "… Note that TCP has a **heuristic to select the latest window update despite possible datagram reordering**; as a result, it may **ignore a window update with a smaller window than previously offered if neither the sequence number nor the acknowledgment number is increased**."

**落到判据**：① 窗口**变小**只要是"最新的、可接受 ACK 携带的"就必须照收（**不许**把守卫做成"只许变大"）；② 讨论段明确认可"**同 (seq, ack) 下忽略更小窗**"这一启发式 —— 也就是"陈旧/乱序 ACK 不许把窗改小"的规范落点；③ 本工程的"对端窗口收缩"是**真实事件**（sink 修复轮实测：同二进制两臂首窗 `2920` vs `65495`；微窗档亦然）⇒ 判据 ① 必须保。

### 2.3 RFC 1122 §4.2.2.17 "Probing Zero Windows"（p.92）逐字

> "**Probing of zero (offered) windows MUST be supported.**" … "As long as the receiving TCP continues to send acknowledgments in response to the probe segments, the sending TCP MUST allow the connection to stay open."
>
> DISCUSSION: "It is extremely important to remember that **ACK (acknowledgment) segments that contain no data are not reliably transmitted by TCP. If zero window probing is not supported, a connection may hang forever when an ACK segment that re-opens the window is lost.**"
>
> "The transmitting host SHOULD send the first zero-window probe when a zero window has existed for the retransmission timeout period …, and SHOULD increase exponentially the interval between successive probes."

**落到判据**：零窗**重开**的载体就是一条"**不前进的纯 ACK**"（`ack == snd_una`，`win` 从 0 变大）；RFC 明言这类段"不可靠传输"⇒ 守卫**必须**让这一类通过，否则每一次零窗都要靠下一轮探测重来（RFC 意义上把"能恢复"退化成"多数时候能恢复"）。⇒ **守卫的谓词必须是"ACK 可接受"（含等号），不是"ACK 推进"**。

### 2.4 判据汇总表（本修法要满足的语义）

| # | 帧类（本板为发送侧，帧来自对端） | 现行为 | 修后 | RFC 落点 |
|---|---|---|---|---|
| C1 | 陈旧 ACK（`ack < snd_una`）带窗 | **覆盖**（缺陷） | **不覆盖** | 793 p.72 "duplicate … can be ignored" |
| C2 | 越界 ACK（`ack > ack_hi`）带窗 | **覆盖**（缺陷） | **不覆盖** | 793 p.72 "acks something not yet sent … drop" |
| C3 | 可接受且推进的 ACK 带窗（含窗变小） | 覆盖 | **照收** | 793 p.72 第二条 + 1122 §4.2.2.16 MUST-robust |
| C4 | 零推进纯 ACK（`ack == snd_una`）带窗（**零窗重开**） | 覆盖 | **照收** | 1122 §4.2.2.17 DISCUSSION（上面逐字） |
| C5 | 可接受但**乱序**到达的 ACK 带更小窗（同 seq/ack） | 覆盖 | 覆盖（**残留**） | 1122 §4.2.2.16 DISCUSSION 的启发式 = 需 per-conn WL 状态 ⇒ §4.5 登记 |

---

## §3 可达性分析（板级）

### 3.1 线上帧 → 能否走到 `pend_wnd`（现核枚举）

`pend_wnd` 的写只在 `if (fend)`（`:502`）块里，而 `fend`（`:379`）只有六种来源：`fend_w6` / `fend_w6t` / `fend_w6a` / `fend_pay` / `fend_pad` / `fend_trunc`。**逐类核**：

| 线上帧类 | 走到的路径 | 会写 `pend_wnd`? |
|---|---|---|
| `seq == rcv_nxt` 的**顺序数据段**（含截断段） | `acc_l` → `S_PAY` → `fend_pay`（或 w6 尾 `fend_w6/w6t`） | ✅ **写**（其 ACK 字段可以是**任意值**，无守卫） |
| `seq == rcv_nxt` 的**纯 ACK**（真实 60B） | `acc_l`（`plen=0`）→ `S_PAD` → `fend_pad` | ✅ **写** |
| **窗口内非边界纯 ACK**（`w6a_ok`：`seq_diff ≤ rcv_wnd` **或 `seq_lt`**，`:334-335`） | `fend_w6a`（短帧/TB）或 `S_PAD→fend_pad`（真实 60B） | ✅ **写** —— ⭐ **`seq_lt` 分支让"上一圈的旧纯 ACK"也能进来**（见 R2） |
| 窗口内**乱序数据段**（`seq > rcv_nxt`）/ **重复数据段**（`seq < rcv_nxt`） | 走 `ackresp` → `S_DROP`（`:754-756`）—— **`fend` 六式不含 `S_DROP`** ⇒ 无 fend | ❌ 不写 |
| 窗口外段 | `S_DROP` / 丢弃 | ❌ |
| 坏 FCS 帧 | `fend` 可能有（`ferr=1`），但 `tcrs=0` | ❌（`s_axis_tcrs` 项为假） |
| 半帧中止拍（`fend_trunc`，`S_PAY` 见 SOP） | `fend` 有、`tcrs=?` | ❌ **今天不写**：`tcrs` 只在 TLAST 字上有效（`mac_rx_64.v:241/276/329` 只在 `push_last` 拍置 `push_crs`；`p7b_mac/rtl/mac_rx_10g.v:388` `push_crs <= b_emit_last && res_ok`）⇒ SOP 拍 `tcrs=0`。**结构性论证 + 建议**：见 §4.1 的可选第二子句 |

⇒ **结论：写口的有效帧类 = "被序列层接受的那一档"（顺序数据段 / 顺序纯 ACK / 窗口内纯 ACK），ACK 层完全不设防。**

### 3.2 什么线上序列能让它真的发生（四条候选，按可复现性排序）

- **R1（可控、可上板，优先级最高）—— raw 注入**：用现成的注入器（`_proj_10g/notes/p7b_microwin_20261010/_tools/stall_probe.py`）造一条纯 ACK：`seq = 板的 rcv_nxt`（`stall_probe.py:69` `seq = (isn+1)`）、`ack = 板 snd_una 之前的值`（陈旧）或 `= snd_nxt + Δ`（越界）、`win = 0` 或小值（`:72` 帧构造里 `win` 是命令行参数）。**这是唯一能在板上把本缺陷变成"可判读数"的路径**（无 pcap 层的重建风险，帧是我们自己造的）。
- **R2（自然、概率性）—— 同槽重连的"上一圈纯 ACK"**：`w6a_ok` 的 `seq_lt` 分支（`:335`）**主动接受 seq 比 `rcv_nxt` 旧的纯 ACK**；而 `base_ok` 的四元组 CAM 命中在"同四元组重连"后再次为真（重连是本工程的既测场景：D1 同槽重连 / A7 重连吞 `ev_up`）。⇒ 若上一圈连接的**残留纯 ACK**（延迟在网卡/链路/对端栈里）在新连接的 TCB 装好之后到达，它带着**上一圈的 ack 号 + 上一圈的窗**进来，现实现照写。守卫把其中 `ack ∉ [新 snd_una, ack_hi]` 的那些挡掉（**概率性缓解**：旧空间 ack 恰落在新空间可接受区间的概率 ≈ 窗/2³² 量级），**不清零** ⇒ 登记（§6-U4）。
- **R3（自然、现役链路未观测）—— ACK 乱序/重复**：直连 AOC + Linux 对端（不重传纯 ACK、链路上无乱序）⇒ **无已知自然触发**；但"未观测"是因为**没有任何仪器在看这件事**（§5.5），不是因为它被排除。
- **R4（产品构型）—— 真实网络**：10G 产品的目标构型含交换/中间设备 ⇒ ACK 乱序、窗口快速收缩/重开都是常规事件 ⇒ 这是本缺陷的**产品级暴露面**（未实测）。

### 3.3 影响面（从落盘点到系统行为，逐环）

1. **`snd_wnd` 被写小/写 0**（`ack_badwin` 类）：
   - `win_open`（`tcb.v:151-156`）⇒ 0 ⇒ **TX 数据门关**；
   - `tcp_tx_frame.v:1231`（OVL 支）/ `:2361`（else 支）的 **RTO 武装条件含 `rb_snd_wnd != 0`** ⇒ **RTO 计时器被清零、不再武装**；
   - `tcp_tx_frame.v:753` 的 **persist 武装条件含 `rb_snd_wnd == 0`** ⇒（persist 开）转入探测；
   - ⇒ **若"零窗"是假的且 persist 关/未实施**：在飞数据无人重传、对端不回 ACK、"下一帧"不来 ⇒ **无界停流**（形状与"微窗 stall 家族"**同形**：`p7b_microwin_20261010/REPORT.md` 的判定 (c)）。⚠️ **口径**：微窗家族的既有归因（缺 persist + **真实**零窗）**不因此改变**；本条只是说"**零窗来源**"多了一条**尚未被排除**的候选 —— 停机态的仪器（`W66/W67/W69/W63`）**分不出**"真零窗"与"被陈旧 ACK 打出来的假零窗"。
   - 写**小但非 0** 的假窗：TX 降速到假窗/RTT；**自愈**（下一条真 ACK 就纠正）⇒ 表现为**短暂降速**。
2. **`snd_wnd` 被写大**（假大窗）：立刻多发真窗之外的字节 ⇒ 对端丢/拒 ⇒ dup-ACK/RTO 重传 ⇒ 速率掉且污染 `W55`（重传次数）与重复率判据。RFC 1122 §4.2.2.16 的 *"MUST be robust against window shrinking"* 直指这一类"用陈旧的大窗盖住刚收缩的小窗"。
3. **对在飞两刀的判据污染面**：persist 刀的板级 A/B 判据全部以 `rb_snd_wnd == 0` 为函数（武装/解除武装），重放刀的判据边界用 `ack_hi`（受 `retx_active` 影响，**与该窗无关**）。⇒ 本缺陷**只污染 persist 那条**（假武装/假解除），因此**不许与 persist 同批构建**（台账 §10-3-5 已定，本件给出一条**技术**理由而不只是纪律理由）。

### 3.4 保护性因素（为什么它至今没造成可见事故 —— 如实列出，不夸大）

- **合流/去重**：写口只对"序列层被接受的帧"开放（§3.1 表），把乱序/重复**数据**帧、窗口外帧、坏 FCS 帧整类挡在外面；
- **sticky pend 语义**：`pend_wnd` 是"合并"的（一个 pend 位 + 一个值），一帧一写、drain 清位 ⇒ **同拍多帧不会互相覆盖**（也正因如此，它不像无合并的设计那样容易炸）；
- **本工程的对端**：`app_pattern` 场景下对端是**纯接收方**（只回 ACK，不发数据），其 ACK 的 `seq` 恒定、`ack` 单调 ⇒ 四元组/序列门后的"陈旧窗"来源几乎只剩 R2/R4；
- **建连初值的另一个写者**（`slow_cfg_adp.v:86`）⇒ 即使守卫全面拦停 ACK 侧更新，连接也不会失去窗口来源；
- **单连接数据面假设**（`:88` 注释：三个 pend 共享一个 `pend_id`）⇒ 多连接下"值串连接"的风险面本来就被登记过（P2-5 修过一次 wnd_l 的漏锁存），本修法**不改变**该结构。

---

## §4 设计：最小修法

### 4.1 精确改法（两处，逐行；`rtl/tcp_rx.v`）

**核心（必须）：守卫 = 帧的 ACK 可接受（`ackok_l`）+ 帧 OK（`s_axis_tcrs`）。**

改点 ① 置位（`:509`）：

```verilog
// 修前（现读 :509）
                pend_wnd <= s_axis_tcrs || pend_wnd;
// 修后
                pend_wnd <= (s_axis_tcrs && (ackok_l | ~SNDWND_GUARD)) || pend_wnd;
```

改点 ② 值锁存（`:518-521`）：

```verilog
// 修前（现读 :518-521）
                if (s_axis_tcrs) begin
                    pend_wnd_val <= wnd_ws;
                    pend_id <= conn_id_l;
                end
// 修后
                if (s_axis_tcrs && (ackok_l | ~SNDWND_GUARD)) begin
                    pend_wnd_val <= wnd_ws;
                    pend_id <= conn_id_l;
                end
```

**参数（推荐，回退开关；默认 = 修后）**：在 `rtl/tcp_rx.v` 的模块头加（现读 `:17` 为 `module tcp_rx (`，**当前无参数表**）：

```verilog
module tcp_rx #(
    // ⭐ P7B-SNDWND-GUARD: 1 = 修后 (窗口更新按"可接受 ACK"门控, RFC 793 p.72);
    //     0 = 修前 (任何 FCS-OK 的 fend 帧都写) —— 仅供 A/B 复现历史行为, 板构建必须为 1。
    parameter SNDWND_GUARD = 1'b1
) (
```

- `SNDWND_GUARD = 1` 时两条表达式化简为 `s_axis_tcrs && ackok_l`；`= 0` 时化简为 `s_axis_tcrs`，**与 HEAD 的表达式逐字相同**。
- **零端口面改动**（参数不是端口；全仓例化一律具名连接 ⇒ 不需要改任何 TB/wrapper 的接线），**零 FF 新增**（`ackok_l` 自 r6-fix 起就在，`:210` 声明 / `:691` 锁存，**无条件锁存、不在任何 `ifdef` 内** —— 现核）。
- **不加新信号/不改值路径**（`wnd_ws`/`wnd_f`/`:456` 不动）。
- ⭐ **`tcp_rx.v` 有没有"同类分支结构"（派单问的）—— 现核结论：没有。** 本文件里**唯一**的宏分支是 `:592-601`（`ifdef TCP_TX_OVL` 内的 `ack_obs` 置位/默认清），而**两处改点（`:509` / `:518-521`）都不在任何 `ifdef`/`generate` 分支里** ⇒ **不存在 `tcp_tx_frame.v` 那种"单 module、双分支逐字同款"的镜像问题**（对比：`tcp_tx_frame.v` 的 `ifdef TCP_TX_OVL` 在 `:303`，配对的 **`` `else `` 在 `:1554`**、`` `endif `` 在 `:2576`（**2026-10-11 现核**；⚠️ persist 设计里流传的 "`else :1248`" 是**陈旧行号**，引用前现读）；同一逻辑两份 —— persist 审查的头号结构风险就在那里；本修法不碰）。
- **`else` 支处理**：**无需** —— 由上一条，`tcp_rx.v` 无第二份。

**可选第二子句（推荐做，但要作为独立决策登记）**：把 `!fend_trunc` 一起写上：

```verilog
                pend_wnd <= (s_axis_tcrs && (ackok_l | ~SNDWND_GUARD) && !fend_trunc) || pend_wnd;
```

- 理由：`if (fend)` 块里五个兄弟表达式中四个都带 `!fend_trunc`（`:506-507` `pend_rcv`、`:545` dup 计数、`:576` in_retx 清、`:594` ack_obs）；只有 `pend_una`（`:508`）与 `pend_wnd`（`:509`）不带 —— 后者被 `tcrs` 保护（§3.1 已证 SOP 拍 `tcrs=0`）。
- **代价**：1 级 AND，**结构性冗余（今天）**；写它的价值 = "四条写口对 `fend_trunc` 的处理统一"，将来若有 MAC 变体在 SOP 拍给 `crs`，这一条就是防线。
- ⚠️ 写了它，`SNDWND_GUARD=0` 时表达式**不再逐字等于 HEAD**（多了 `!fend_trunc`，其等价性由上面的 MAC 语义论证支撑、不是文本级）。⇒ **二选一由实施轮按"回退开关要文本级可核"还是"写口统一"取舍**（§6-U1）。

### 4.2 为什么是 `ackok_l`，不是 `ack_adv_l`（也不是 `dup_l`）

- **`ack_adv_l`（任务点名的坑）**：`ack_adv = ack_ok && (ack32 != snd_una)`（`:322`）⇒ **零推进的窗口更新 ACK 会被打死** ⇒ 零窗恢复从"一条 ACK 即恢复"退化成"等下一轮探测"，**并与 RFC 1122 §4.2.2.17 的 DISCUSSION 直接冲突**（那一段逐字讲的就是"重开窗的 ACK 可能丢，所以必须靠探测"）。⇒ **不可用**。
- **`dup_l`**：`dup_ack = base_ok && plen==0 && ack_ok && !ack_adv && (ra_snd_nxt != ra_snd_una)`（`:338-339`）—— 它额外要求"有在飞"。**r6-fix 的板级死锁就是这个坑的实测版**（`:586-591` 注释逐字："r6 首版只有前两个 ⇒ **板级死锁**（实测）：门锁住数据后 `snd_nxt==snd_una` ⇒ 握手完成 ACK（`ack==snd_una`，零推进）两个判据都不成立 ⇒ 永不置位"）。零窗恢复的现场**正是** `snd_nxt==snd_una`（没有在飞数据、窗被关）⇒ `dup_l` **在恢复现场为假** ⇒ **不可用**。
- **`ackok_l`**：`ackok_l <= ack_ok`（`:691`），即 `snd_una ≤ ack ≤ ack_hi`（等价式，`ack_hi = retx_active ? retx_hi : snd_nxt`，与 RFC 793 的 `SND.UNA < SEG.ACK =< SND.NXT` **只差等号**；等号那格必留，见 §2.3）。**它是 r6-fix 为"零推进 ACK"专门引入的锁存，且注释里已写明它是 `dup_ack`/`ack_adv` 的超集**（`:589-590`）⇒ 语义、可见度、板级前科齐备。**本修法 = 复用它，不新造信号。**

### 4.3 零窗恢复仍成立 —— 三段论证

**待保性质 P**：对端在零窗后重开，板必须在收到该"窗口更新 ACK"后**一个往返内**恢复发送（不许只靠 persist 探测）。

1. **形式**：该 ACK 的 `win > 0`；其 `ack` 是"对端已收字节的累计确认" ⇒ 在发送侧坐标系里 `ack ≤ snd_nxt`（对端不可能确认没收到的东西），且 `ack ≥ snd_una`（`snd_una` 的定义就是"已确认水位"，对端不会倒退）⇒ **`ack ∈ [snd_una, ack_hi]`**（`ack_hi ≥ snd_nxt` 在无会话时取等、会话时取 `retx_hi ≥ snd_nxt`）。
2. **判定**：该帧若为纯 ACK，走 `w6a_ok`（`:334-335`：`plen=0` 且 `seq_diff ≤ rcv_wnd` 或 `seq_lt`）——零窗静置态下对端的 `seq = rcv_nxt`（它没发新数据）⇒ `seq_diff = 0` ⇒ 接受；或走 `acc_l`（`:340`）⇒ 无论哪条都会到 `fend_pad` ⇒ **到得了守卫**。
3. **守卫放行**：`ackok_l` 在 `snd_una ≤ ack`（**含等号**）时为真 ⇒ **放行** ⇒ `pend_wnd` 照旧置位、值照旧锁存 ⇒ drain 写 `sel=4` ⇒ `snd_wnd ← wnd_ws` ⇒ `win_open` 重开、persist 解除武装（`:753` 条件转假）⇒ **恢复链路与修前逐级同构**（唯一差别 = 不可接受 ACK 不再进来）。

**边界核对（三条最容易漏的）**：
- 零窗态**可能没有在飞数据**（`snd_nxt == snd_una`）：`ack_ok` 只做区间比较、**不要求有在飞**（与 `dup_ack` 的关键差别）⇒ 放行 ✅；
- 对端的窗口更新 ACK **可能与握手完成 ACK 同形**（`ack == snd_una`）：同上 ✅（这正是 r6-fix 板级证明过的那类帧确实存在于线上）；
- **重传会话期**（`retx_active=1`）：`ack_hi = retx_hi`（`:320`），探测/重放的应答 ACK 落在 `[snd_una, retx_hi]` ⇒ 放行 ✅。

### 4.4 代价（纸面；**不下时序结论**）

| 面 | 估计 | 依据 |
|---|---|---|
| FF | **0** | `ackok_l` 已存在（`:210`/`:691`）；参数是 elaboration 常数 |
| LUT | **≈1–2**（含可选子句 ≈2–3） | 两处各加一个 AND 项（项本身已在同一锥里） |
| 时序锥 | 改的是 **控制锥**（`pend_wnd` → `upd_wr`/`upd_val` 使能 + drain 清除项）。两处操作数全是**寄存器/输入**（`fend`/`s_axis_tcrs`/`ackok_l`/`fend_trunc`/参数常量）⇒ 加 1 级 AND，**不引入新的长组合链**；⚠️ **本件不声称任何时序结论** —— 缺陷批构建必须现读 `WNS/WHS/WPWS` + 三类失败端点 + **DP 域 setup WNS 与前三族**（构建 F 的 DP 宿主 = `u_tcp_tx/u_retx/…` retx_ram 族；`tcp_rx` 的 pend/drain 锥不在已登记的最差族里 —— **这是"未命中已知族"的观察，不是"不会命中"的保证**） |
| 行为面 | **只减少**写入次数（放行的集合是原集合的子集）⇒ 不可能新增"窗口没被更新"以外的行为；**被挡掉的那一类正是 RFC 说该忽略的**（§2.4 C1/C2） | §3.1 枚举 |
| 快照/窗口 | **0 新字**（守则：能不加就不加；判据见 §5.5） | — |

### 4.5 残留（如实登记，不许当已修）

- **R-A：可接受 ACK 之间的乱序**（C5）——两条 `ack` 都落在 `[snd_una, ack_hi]`、到达顺序与发出顺序相反时，"最后一条仍说了算"。RFC 793 用 `SND.WL1/SND.WL2` 治它、Linux 用 `tcp_may_update_window()` 的三子句治它（RFC 1122 §4.2.2.16 DISCUSSION 描述的就是这个启发式）。实现它需要**每连接 64 位 WL 状态**（16 连接 ≈ 1024 FF）+ TCB 写口新增字段 + **`tcp_rx` 新增读端**（因为它连 `ra_snd_wnd` 都没有，`:70-77`）⇒ 波及 `tcb.v`/wrapper/全部 TB 镜像 ⇒ **判为"非最小"，本件不做**（与派单的"只许动 `tcp_rx.v`（或明确论证）"一致）。
- **R-B：`fend_w6t` / `fend_w6a` 的"值来自上一帧"**（§1.3）——独立子情形（值陈旧，与 ACK 守卫正交）；最小修法**不处理**；若同批处理 = 把 `:456` 的 mux 条件从 `fend_w6` 扩到 `(state==S_HDR && wcnt==3'd6)`（此时 `s_axis_tdata` 必为 w6 字）⇒ 三式都取到本帧窗。**判为可分离的第二决策**（§6-U2）。
- **R-C：`ackok_l` 的采样时基**（`:691` 用的是 w5 拍采样的 `ra_snd_una/ra_snd_nxt`，而 TCB 落地要到 drain 的 `drn==2` 拍）⇒ 极小概率用"略旧"的 `snd_una` 判可接受性 ⇒ 边界 ACK 的放行**略偏宽**（方向与保守相反，量级 = 1–2 拍窗口）；与 `P7B_L_INSTRUMENT_DESIGN.md` §2.3 边角 4（`stat_ack_adv` 的多计）同族，**登记不修**。
- **R-D：`upd_gnt` 被长挂起时**（板级 TX 优先仲裁的真实形态，TB 的 `gnt_hold` 复现）：`pend_wnd` sticky ⇒ 守卫只在**值被锁存的那拍**起作用；挂起期间的重复帧不再能刷新该值 ⇒ 这正是修法想要的（粘滞值 = 最后一条**可接受**的窗），但要在 TB 里显式覆盖（§5.1 的 B 腿落在 gnt 窗内）。

### 4.6 与两把在飞刀的相交面（**必须写清楚，供 TL 排批**）

| 刀 | 改动文件（现核） | 与本文的相交 |
|---|---|---|
| **persist 刀**（`fd671b6` 已入库；设计件 v3） | `rtl/tcp_tx_frame.v`（13 处落点）+ `board/wrapper_p4.v` 2 处（`.PERSIST_EN` / BID） | **文件面不相交**。**语义面相交 3 条**：① persist 武装/解除武装读的就是 `rb_snd_wnd`（`:753`），本修法改变"何时能被写成 0"；② **persist 板级的零窗正控（P-A = 注入伪造零窗 ACK）必须复核注入器的 `ack` 字段**：`stall_probe.py:62/93` 注入的是"**最后一次嗅到的** `(ack, win)`"——若嗅探之后板又推进过 `snd_una`，该 `ack` 会**落在守卫之外 ⇒ 注入被静默吞掉、正控失效**（安静失效族）。⇒ **要求**：P-A 注入器的 `ack` 取"注入时刻的 `snd_una..snd_nxt`"（现读快照/重嗅），并把"注入被收下"写成见证（例如注入前后 `ΔW66/ΔW67` 的形态 + `W69` 的 `win_wnd_eff`）；③ **不许同批构建**：台账 §10-3-5 已定；本件补一条**技术**理由 = 本修法恰好动 persist 的武装变量，同批会让 persist 的板级 A/B 失去归因（不是纯纪律问题）。 |
| **重放越界刀**（`11ad9ec`/`74f56cc`/`0bbda0e`/`7124147`） | `rtl/tcp_tx_frame.v`（`retx_hi`/`ring_hi`/`e_ghost`）+ TB/门 | **文件面不相交**、**判据面不相交**（该刀的边界量是 `ack_hi`/`retx_hi`，与 `snd_wnd` 无关）；无额外约束。 |
| **本修法** | **只 `rtl/tcp_rx.v`**（两处 + 可选参数）；**不碰** `tcp_tx_frame.v`/`tcb.v`/`wrapper`/TB 的 RTL 面 | 与上述两刀**无文件冲突** ⇒ 可在缺陷批里独立实施（缺陷批另含 F-3 等，见台账 §10-2 —— ⚠️ 同批内仍要**逐缺陷独立判据**） |

**回退**：首选 = `SNDWND_GUARD` 参数（`0` = 历史行为；wrapper 一处传参即回退）；备选（不采参数时）= 恢复 `:509`/`:518-521` 两处原文（`git diff` 只有 2 处 hunk）。**板级回退** = 烧回缺陷批之前的位流（0x1C 或 0x1A —— ⚠️ 每次测量前必重烧 + 核 sha256 ↔ 板侧 BID）。

---

## §5 门与判据（TB / 模型 / 常驻矩阵 / 板级）

### 5.1 TB：三条腿（判别 + 正对照 + 遗留行为臂）

**落点建议**：扩 `tools/gen_stim_tcp_rx.py` + `tb/tb_tcp_rx.v`（现役单元门，直接可见 `u_tcb.snd_wnd_r[*]`、`TCBF` 行已有 `snd_wnd` 字段:263-267），并把该门**登记进常驻矩阵**（§5.4）。

**构造要点（先钉死，避免假阴性）**：
- TCB0 初值：`snd_una = 5000`、`snd_nxt = 6000`（= `cfg_tcb` 同源，`:39-43`）、`rcv_nxt = 1000`、`snd_wnd = 0x2000`、`wscale = 0`（TB 只写 sel 0..5 ⇒ `wnd_ws == wnd_f`，缩放是恒等，判据可以直接比 16 位数）；
- ⚠️ **每个新腿之前必须用慢路径（`cfg_upd_sel=4`）把 `snd_wnd` 重配成已知值**（机制现成：`:212-222` 的 `D_CFG2` 段 + `cfg_upd_sel <= (i - D_CFG2) % 6`）；**不要假设"定向段之后还是 0x2000"** —— 定向段自己的 4 帧会把窗写成 `0x4000`（`:187-193`），TB 的既有自检（`:271-277`）也正是断言 `0x4000`。⇒ 腿 A 的"保持不变"要对着**腿前重配值**断言（例：重配 `snd_wnd = 0x2000` ⇒ 腿 A 判 `== 0x2000`）；
- **帧形态必须用"本帧窗"路径**：**真实 60B 纯 ACK**（`S_PAD→fend_pad`）或**顺序数据段**（`fend_pay`）——⛔ **不许用 w6-tlast 短帧**（`fend_w6t`/`fend_w6a` 会写入**上一帧**的 `wnd_l`，§1.3 ⇒ 注入的 `wnd` 根本到不了 TCB，是**假阴性**的温床）；
- `ra_retx_active` 恒 0（TB `:130` 已钉）⇒ `ack_hi = snd_nxt`；
- 时间序：所有新腿放在**定向段之后**，且腿间留足 drain 完成 + 慢路径重配的间隙（既有 `D_HOLD0/D_HOLD1` 那种窗式间隔即可，`:98-99`）。

**腿 A（判别腿 —— 陈旧/越界 ACK 不许覆盖；两条子形态，任一可判别）**：
- A1「陈旧」：`seq = rcv_nxt`、**`ack = snd_una − 0x100`**（回绕后远大于 `ack_hi−snd_una` ⇒ `ack_ok=0`）、`win = 0x0100`（假小窗）；
- A2「越界」：`ack = snd_nxt + 0x1000`（"ack 了没发的"，= 既有 `ack_badwin` 形态）、`win = 0x1100`；
- **判据**：drain settle 之后 `u_tcb.snd_wnd_r[0]` **== 腿前重配值**（例 `0x2000`，保持不变）。⚠️ 同时断言"该帧**确实被接受并 fend 了**"（用 `ack_req`/`stat_pass` 或 `FEND` 行计数），否则"窗没变"可能只是"帧没被收下"（**空判据**）。

**腿 B（正对照 —— 零窗恢复必须活着；两条）**：
- B1「零推进窗口更新」：先把 conn0 的 `snd_wnd` 经慢路径配成 **0**（`cfg_upd_sel=4`，TB 已有该机制 `:212-222`），再注入 `seq = rcv_nxt`、**`ack = snd_una`（零推进）**、`win = 0x4000`；
- B2「推进 + 窗变小」：`ack = snd_una + 0x100`（可接受、推进）、`win = 0x1234`（比当前小）；
- **判据**：B1 ⇒ `snd_wnd_r[0] == 0x4000`（**修前修后都必须成立** ⇒ 这条同时是"守卫没有打死零窗恢复"的机器证据）；B2 ⇒ `snd_wnd_r[0] == 0x1234`（说明"变小照收"没被误伤）。

**腿 C（遗留行为臂 = "有牙"的机器证明）**：同一 TB 用 `SNDWND_GUARD=0` 再跑一遍（靠 `ifdef` 选择例化参数，与仓内既有的两臂门形态同款）：
- **A1/A2 必须变红**（`snd_wnd` 被写成 `0x0100`/`0x1100`）⇒ 证明腿 A **测的正是这个守卫**（不是真空判据）；
- **B1 必须仍绿** ⇒ 证明腿 A 的变红不是"把别的东西弄坏了"。
- 若采用"无参数 + 文本变异"路线：变异 = 从两份现读行里删 `ackok_l &&`（生成变异件的脚本与既有的 `sim/*/mut/` 手法同款）。

### 5.2 参考模型（同源 oracle 的登记点）

`tools/gen_stim_tcp_rx.py` 的周期精确模型**镜像**了本节缺陷的语义（现读）：

```
:605	            pend_rcv_n = (acc_l and plen_l != 0 and crs) or pend_rcv
:606	            pend_una_n = (ack_adv_l and crs) or pend_una
:607	            pend_wnd_n = crs or pend_wnd
:614	            if crs:
:615	                pend_wnd_val_n = ((w[0] >> 48) & 0xFFFF) if fend_w6 else wnd_l
```

⇒ **实施轮必须同批改模型**（`ackok_l` 需要在模型里新增 1 个状态位 + 在 w5 分支锁存 `ack_ok`（`:446-448` 已有 `ack_ok`/`ack_adv` 的局部计算）+ 上面两行加条件），否则 `check()`（`:823-858` 对比 line/STATS/STATM/TCBF）会红。
⚠️ **口径登记（不许含糊）**：模型是**镜像**、不是独立 oracle ⇒ 改完模型后，**腿 A/B 的判别力只能来自"显式终态断言 + 腿 C 的遗留臂"**，不能来自"TB 与模型一致"（本工程的先例：#39/#40 一致 ≠ 正确；#29/#30 同源 oracle）。

### 5.3 现有门的敏感性（**下发前必须由实测裁决的预判**）

- `sim/p3sim/run_tb_tcp_rx.bat`（不在常驻矩阵；`:26-40`：生成器 → 三模式 xsim → `gen_stim_tcp_rx.py . check`）：**预判不判别本修法** —— 现役语料里唯一的"不可接受 ACK + 带窗"帧是 `ack_badwin`（`:170`），它落在**定向段之前**，而其后的 `D_CFG2` 整字段重配会把 conn0 恢复成基线、定向四帧再写 `0x4000` ⇒ **终态 `TCBF` 两臂相同**；`resp_*.memh` 的**行集合里没有 `upd_*` 轨迹**（`:294-302` 只记 mdata/meta/fend/ack）⇒ 中间差异不上报。**结论：若不加腿 A/B，这个门对本次改动**大概率**是"两臂全绿"= 空证据**（⚠️ 是预判，**必须以实施轮的实测为准**；本件不下裁定）。
- 常驻矩阵里**编译 `rtl/tcp_rx.v` 的门**：`chain` / `burst200` / `trunc50` / `trunc100` / `halfdrop` / `txdrop50` / `gate4096` / `dupstorm` / `pcackoob` / `vlanchain` / `vlanburst` / `stallgate`（`chain_src.f` 含 `rtl/tcp_rx.v`，现读）与 `p5_wrapper`。`tb_p4_chain.v` 的**注入 ACK** 现读用 `ack_b = inj_ack_val`（`:1492-1499` 由"顺序累计水位 / OOO 水位"派生 ⇒ 语义上应恒在 `[snd_una, snd_nxt]`）与 `PCSTALL` 的 `hi_wm` ⇒ 预判**不受影响**；`inj_wnd`（`:1163`）默认 `0x4000`，另有 `PCWND1K` 变体（`0x0010`）**未被任何门使用**（现核 grep）。⇒ 同样：**以实施轮的矩阵复跑 + 逐门 diff 裁决**（任何红都要**先判断它是不是预期内的行为改动**、再决定改判据还是改实现 —— 不许"重跑到过为止"）。
- `tb_p5_wrapper.v:75` 直接 **force** `u_dut.u_tcb.snd_wnd_r[0] = 16'h4000;` ⇒ 该门对本改动结构性不敏感。

### 5.4 常驻矩阵登记（建议）

新增一行（形态照既有 17 行，`sim/p4gates/run_matrix_p4dfix.bat:184-211`）：

```
call :gate unit_sndwnd  sim\p3sim\run_tb_tcp_rx.bat  <src.f>  "SNDWND_LEGACY=0"  -
```

- 配套：① 在 `run_tb_tcp_rx.bat` 里加"两臂"（默认臂 + `-d SNDWND_LEGACY` 臂，臂的**期望结果不同**：默认臂期望 A 腿绿、遗留臂期望 A 腿红 ⇒ **门必须能表达"这一臂本来就该红"**，否则会走进"哑门/假红"老坑）；② 把该门列入矩阵的编译清单（`p4gate.py` 的 manifest 面）——⚠️ 台账 §10-2 已登记的另一处盲区（矩阵不含 `app_pattern.v`/`wrapper_p4.v`）**不是**本门的借口，本门自己要做到"清单含 `rtl/tcp_rx.v` + 指纹随修订变"；③ 源文件编辑（`sim/`）按纪律**等构建结束再动**。

### 5.5 板级判据（现有字够不够？）

**先回答"现有字够不够"**：**没有 `snd_wnd` 直读字** —— `dbg_snd_wnd0` 只接 `snap_wnd → uart_dbg`（`wrapper_p4.v:2907/3041-3043`），而**板上无 UART**；PCIe 快照的 70 字里没有任何 TCB 字段字（现核 FE/DP/P7BFE/TX 四束装配）。**但够用**（判据不必直读 `snd_wnd`，只要**行为**可判）：

- **主判据（行为面，复用现有字）**：造"陈旧/不可接受 ACK 带假零窗"（R1 注入，`ack` 必须取**注入时刻的** `snd_una..snd_nxt`，§4.6）之后，看**窗口门停顿族**：`ΔW66`（帧器等窗拍）与 `ΔW67`（其中板帽侧）/`ΔW63`（app 侧 `frm_wait`）/帧率 `ΔW20` 的组合 ——
  - **修前臂**（0x1C 构建 = 只有重放越界修复、**无本守卫**，正好是"pre"对照）：注入假零窗 ⇒ `snd_wnd=0` ⇒ `ΔW66` 起跳、帧率掉（若在飞无数据 ⇒ **一直不掉回来** = 无界停流的形态）；
  - **修后臂**（缺陷批构建）：同一注入 ⇒ `ΔW66` **无形态变化**、帧率不跌；**同时 B1 型注入（可接受 + 窗 > 0）两臂都必须立刻恢复**（正对照 = 证明"没跌"不是因为注入没生效 —— 这条**必须**有，否则"没变化"是空判据）。
  - `W69`（`o_win_at_winstall` 的 `win_wnd_eff` 半字）作为**见证**：修前臂在等窗拍锁存的生效窗 = 0，修后臂该注入不产生等窗拍 ⇒ 不作主判据（也符合既有口径：`W69` 是操作点锁存、只在 `ΔW66>0` 时有效）。
- **前置闸**：BID/窗口字数/未实现地址（现役口径 = 70 字 / `0x138`；缺陷批会 bump BID ⇒ **以缺陷批自己的台账为准，别抄 0x1A**）；每次测量前必重烧 + 核 sha256 ↔ 板侧 BID。
- **可选升级（未定项 U3）**：若 TL 要求**直读**，最便宜的是**加 1 字 = `dbg_snd_wnd0`（线已在 `wrapper_p4.v:1576/2013`，只需进 `p7bdp` 束 + 五处同改 + 读侧同步 ~75 处）**，代价 ≈ **96 FF/字**（32×3 份：`snap_cdc.hold_b` + `dout_a` + `snap_words_r`）+ 一次构建；**本件建议先不加**（守"能不加就不加"），把它与"本修法是否需要独立板级直读"一起作为决策点。

### 5.6 "有牙"要求（不许放宽）

- 腿 A 必须**能演示"改之前会红"**（腿 C 遗留臂 = 同文件、一个参数/一处文本变异 ⇒ 与仓内既有两臂门同款）；
- 腿 A 必须**同时断言"帧被收下 + fend"**（防空判据）；
- 腿 B 必须**两臂都绿**（防"守卫把零窗恢复打死"这类假修）；
- 不允许为了让门变绿而放宽任何既有判据（改判据要走"判据层裁定"，裁定权在用户/判据所有者）。

---

## §6 未定项（⛔ 不许当已答）

- **U1**：可选第二子句 `!fend_trunc` 是否采纳 —— 取舍 = "回退开关文本级可核"（不写）↔ "四条写口对 `fend_trunc` 统一"（写）。**今天结构性冗余**（两 MAC 现读证据），不写不构成缺陷。
- **U2**：`fend_w6t`/`fend_w6a` 的"值来自上一帧"（§1.3）是否同批修（改 `:456` 的 mux 条件）。**本件判为可分离第二刀**，未裁。
- **U3**：板级是否加 1 个直读字（`snd_wnd0`）—— 本件建议不加（间接判据 + 两臂 A/B 已够）；代价与做法已给（§5.5）。
- **U4**：R2（同槽重连的上一圈纯 ACK）在真实链路上的发生率 —— **未观测**（需要 pcap 见证"旧空间 ack 的纯 ACK 落在新连接 ESTAB 之后"）；本件只登记路径，不声称它发生过。
- **U5**：R-A（可接受 ACK 之间的乱序，C5）的处置 —— 需要 per-conn WL1/WL2 或 Linux 三子句（+ `tcp_rx` 新读端）⇒ 本件判"非最小、不做"；是否在产品化前另立一刀 = 未裁。
- **U6**：现有门的敏感性预判（§5.3）**必须由实施轮实测裁决**（本件只给预判与理由；不许把预判当读数）。
- **U7**：persist 板级 P-A 注入器（`stall_probe.py`）的 `ack` 字段是否需要改造（§4.6 ②）—— 属 persist 刀的交付面，本件只登记跨支要求。
- **U8**：`SNDWND_GUARD` 参数名/落点/默认值的最终形态（本件推荐"参数默认 1 + wrapper 不传 = 修复后"）；以及**缺陷批构建里 wrapper 是否显式传参**（显式传更可核，但要防"传错 0"⇒ 建议加一条静态门：wrapper 里该参数必须为 `1'b1`）。

---

## §7 附：现核行号表（2026-10-11；实施轮开工先 `git rev-parse HEAD` 复核，行号漂移以**行内容**为准）

| 位置 | 行号 | 现读内容（摘要） |
|---|---|---|
| `rtl/tcp_rx.v` | `:83-87` | pend sticky 合同（"值寄存器只在对应条件成立时更新…旧 ack/旧窗口覆盖"） |
| `rtl/tcp_rx.v` | `:210` | `reg acc_l, ackresp_l, ack_adv_l, ackok_l;   // ackok_l: r6-fix (L-A)` |
| `rtl/tcp_rx.v` | `:320-322` | `ack_hi` / `ack_ok` / `ack_adv` |
| `rtl/tcp_rx.v` | `:334-335` | `w6a_ok`（含 `seq_lt` 分支） |
| `rtl/tcp_rx.v` | `:338-339` | `dup_ack` |
| `rtl/tcp_rx.v` | `:379` | `assign fend = fend_w6 || fend_w6t || fend_w6a || fend_pay || fend_pad || fend_trunc;` |
| `rtl/tcp_rx.v` | `:456` | `wire [15:0] wnd_f = fend_w6 ? s_axis_tdata[63:48] : wnd_l;` |
| `rtl/tcp_rx.v` | `:460-461` | `wnd_scaled` / `wnd_ws` |
| `rtl/tcp_rx.v` | `:464-469` | `upd_wr` / `upd_sel` / `upd_val` 组合 |
| `rtl/tcp_rx.v` | `:502` | `if (fend) begin` |
| `rtl/tcp_rx.v` | `:506-509` | 三个 pend 置位（**缺陷行 = `:509`**） |
| `rtl/tcp_rx.v` | `:510-521` | 三个值锁存（**改点 = `:518-521`**） |
| `rtl/tcp_rx.v` | `:526-540` | drain FSM |
| `rtl/tcp_rx.v` | `:684-691` | w5 锁存（`:684` `ack_adv_l <= ack_adv;`，`:691` `ackok_l <= ack_ok;`） |
| `rtl/tcp_rx.v` | `:701-706` | w6 锁存 `wnd_l`（P2-5 注释） |
| `rtl/tcp_rx.v` | `:70-77` | 读口 A 端口表（**无 `ra_snd_wnd`**） |
| `rtl/tcb.v` | `:100` / `:112` / `:119` / `:127` / `:134` | `snd_wnd_r` 写口 / 三个读口 / `dbg_snd_wnd0` |
| `rtl/tcb.v` | `:151-156` | `win_diff` / `win_cap` / `win_open` |
| `rtl/tcp_tx_frame.v` | `:753` | `ps_arm`（persist 武装 = `rb_snd_wnd == 0`） |
| `rtl/tcp_tx_frame.v` | `:1231` / `:2361` | RTO 武装（OVL 支 / else 支，均含 `rb_snd_wnd != 0`） |
| `rtl/slow_cfg_adp.v` | `:86` | 建连时 `sel=4: snd_wnd = w5[15:0]` |
| `rtl/mac_rx_64.v` | `:241/276/329`（+`:197` 默认 0） | `push_crs` 只在 TLAST 字置位 |
| `_proj_10g/p7b_mac/rtl/mac_rx_10g.v` | `:388` | `push_crs <= b_emit_last && res_ok;` |
| `board/wrapper_p4.v` | `:2016-2048` / `:2907` / `:3041-3043` | TCB 写仲裁 / `snap_wnd` / uart_dbg |
| `tools/gen_stim_tcp_rx.py` | `:605-616` / `:446-448` / `:170` / `:97,181,212` | 模型镜像 pend / `ack_ok` / `ack_badwin` / 定向段与注释 |
| `tb/tb_tcp_rx.v` | `:100-101` / `:263-267` / `:271-277` | D_RCVX/D_UNAX / TCBF / 定向自检 |
| `sim/p4gates/run_matrix_p4dfix.bat` | `:184-211` | 17 门表 |
| `.../p7b_microwin_20261010/_tools/stall_probe.py` | `:62,66-72,93` | 注入器（`seq=isn+1`，`ack` = 最后嗅到值，`win` = 参数） |

---

## §8 交付摘要（给 TL 的一句话版）

1. **是不是真缺陷**：**是**（规范/合同层；RFC 793 p.72 逐字 + 模块自身 `:86-87` 合同 + 测试语料 `ack_badwin` 已把它当基线三支证据）。**现役直连链路无已知自然触发、从未被观测**（且**没有仪器在看**）⇒ 不许写成"不存在"。
2. **可达性**：结构性可达（§3.1 表）；**可构造触发 = raw 注入**（唯一能上板判的路径）；**自然候选 = 同槽重连的上一圈纯 ACK（`seq_lt` 被收下，概率性）**；产品构型（真实网络乱序）是暴露面。影响 = 假零窗 ⇒ **RTO 撤装 + persist 武装** ⇒ 无界停流（persist 关时）/ 假大窗 ⇒ 越窗发送 + 重传污染。
3. **精确改法**：`rtl/tcp_rx.v` 两处（`:509`、`:518-521`）加 `s_axis_tcrs && ackok_l`（推荐包 `SNDWND_GUARD` 参数，默认 1，`0` = 历史行为），**零 FF / ≈1–2 LUT / 控制锥 1 级 AND**；**零窗恢复成立的论证 = §4.3 三段**（正是不能用 `ack_adv_l`/`dup_l` 的理由，r6-fix 有板级前科）。
4. **门与判据**：TB 三腿（A 判别 / B 正对照 / C 遗留臂）+ 模型同步点 + 新矩阵行；**板级复用现有字（`W66/W67/W63/W20` + `W69` 见证）**，可选 +1 直读字（建议不加）；预判现有门不判别（**待实测裁决**）。
5. **未定**：U1–U8（§6）。
