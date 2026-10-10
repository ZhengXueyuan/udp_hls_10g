# 微窗 stall 家族 —— 定位轮报告（2026-10-10）

> ⚠️ **本件由 TL 代落盘**（子 agent 写 `.md` 被 harness 拒绝，与上一轮同形态）；正文按子 agent 最终回复整理，**未改一字数字/行号**。
> 被测件 = **构建 F**（不换版）：sha256 `89e89f31efb5f1450a1c39acfce587bb4e4b6347c5fdc2f470c91ff0d4400f45`（15,431,261 B）·
> 板侧 **`ID_BID 0x0000001A`** · **`ID_UNIMPL 0xffffffff`**（未实现地址 `0x138`）· 快照 **70 字**。
> 本件 = **零构建**（`rtl/ tb/ sim/ board/*.v board/*.tcl` 一字未动；git 只读）· 只走 JTAG 易失烧录 · **只烧归档件**（烧录 ×5，每次重核 sha256 ↔ 板侧 `0x04`/`0x138`）·
> 对端 **sysctl 一字未动**（`Adaptive RX: off / rx-usecs 0`，逐跑见证）· **未覆盖 `/tmp/p7b_biz/` 与 `/tmp/p7b_board2/`**（两处 ≥5 个工具 md5 逐字未变）。
> ⚠️ 身份/几何**只引** `ID_BID` + `ID_UNIMPL`；`LF_GEOM_OK NW=63` 是硬编码字面量（本轮每跑逐字打出，**不作证据**）。
> ⚠️ **本件不给 PASS/FAIL 裁定**；含"未做到/未判定"（§4）与"与派单描述不符"（§5）。

---

## ① 五行结论

1. **Q1（RTL 事实）**：板的"无进展探询/重传"**只在窗口非 0 时存在** —— `rtl/tcp_tx_frame.v:1008-1009` 的 RTO 装表门
   = `scan_estab && ((rb_snd_wnd != 16'd0 && rb_snd_nxt != rb_snd_una) || fin_retx_pend[scan_id])`；
   **否则 `:1017-1018` 把 `rto_timer[scan_id] <= 21'd0`（结构性卸膛）** ⇒ **`snd_wnd == 0` 时 RTO 永不到期、无重传、更无探询**；
   **全仓无 persist/零窗探询机制**（`grep -rn "persist\|probe" rtl/ hls/src/` 只命中注释）。
   窗口非 0 的**微窗**形态下（MW9 实测 `eff=832`）RTO 会每 **20.0 ms**（`RTO_LIM = 12207 × 256 拍 @156.25MHz`，`:219-220` + `:1378-1379`）到期并**整窗重放**
   （`replay_full = !retx_req`，`:950`），但 `blocked`（`:509` `epoch[svc_id] >= 15`；`:522` `svc_rewind` 被禁；`epoch` 只在 `snd_una` 进展时清零 `:940-943`）
   会让回卷**永久停摆** ⇒ 第二把锁。
2. **Q2（板侧在做什么）**：stall 期板**先重传、后永久静默** —— 13 跑里 12 个 stall，`ΔW55` = 1…37（MW2 18 / MW9 24 / MW13 37），
   **全部集中在起始 0.1–0.5 s**（个别跑 ~10 s 有一次回潮，MW12/13）；此后 **`ΔW20 ≡ 0`（无线上帧）而 `W5` 照涨（时基活）** ⇒ **板确实停发**；
   `W69` 定格 `eff = 0`（9 个跑）或 `832`（MW9）。重传帧的落点（pcap 逐帧分类）= **317/336 BEYOND / 18 EDGE / 0 OLD**。
3. **Q3（对端那侧）**：**不是"对端不 ACK/不收"** —— 对端 NIC 收下板的每一帧（`Δpkts` 与板 `ΔW20` 对得上）、TCP 入口 `data_segs_in` = 板的帧数、
   0.17 s 内回 ~300 个 ACK（板 `W22` 收到同量级）。但**对端窗口通告停在 0**：pcap 逐包 `win` = `{0×82, 1460×211, 64240×4, 62780×1}`，
   **板停发前的最后两个包都是 `win=0`**；板停发后对端 **15 s 一个包都不发**。机理**已回内核源码核**（`/usr/src` 的 6.8 源）：
   `net/ipv4/tcp.c:1481` 的 `__tcp_cleanup_rbuf()` 只在 `copied > 0`（app 真读到字节）时才可能发窗口更新（`:1493` 还要求新窗至少翻倍），
   而 stall 中后续帧被"窗口外"规则丢弃（**不入队**）⇒ app 再无可读 ⇒ **对端永远不再通告窗口**。丢在哪：**不是** OFO/RcvCollapsed/BacklogDrop/nodesc；
   本轮新增的 `TCPRcvQDrop`/`TCPZeroWindowDrop` 也只 **+1…+6**（对不上 ~300 帧）—— 逐帧分类显示它们**在当时的 `rcv_nxt` 之后**。
4. **Q4（可复现性）**：**按需复现做到了** —— `rcvbuf=2920` **5 stall / 1 健康**（MW1-6；上一轮同档 2/5 健康）、`rcvbuf=1460` **7/7 stall**（MW7-13；上一轮 2/2）。
   最强候选触发变量 = **开流竞态**：sink 的 `SO_RCVBUF` 在 `connect()` **之后**才设（`p7b_tcp_sink.cpp:306` 逐行可核）⇒ 线上先通告 64240、随即塌到 0/832/1460，
   而板的初突发（≤ `WIN_CAP` 61,440）**已获对端自己的窗口授权**发出 ⇒ 小缓冲被冲掉 ⇒ 窗口锁 0；档越小越易。
   **判别臂（方向相反）**：+3 s 注入 3 个"重复 ACK、`win=1460`" ⇒ **板 ≤0.16 s 内恢复**（sink 收满 1.6 GB、零失配）；
   同法注入 `win=0` ⇒ **0 帧、仍 stall**；+20 s 同样注入 ⇒ 板同样重放（269/313 帧）但只恢复一个突发后**再锁**。
5. **总判定 = (c) 协议栈缺一条机制：缺【发送侧 persist / 零窗探询】**（RFC 1122 §4.2.2.17：**MUST-36「Probing of zero (offered) windows MUST be supported」**；
   同节「SHOULD NOT send new data, but **SHOULD retransmit the old data normally**」）—— 板不但没有探询，还**把 RTO 在 `snd_wnd == 0` 时结构性卸膛**，
   使标准 TCP 的两条逃生路（探询 / 旧数据重传）**同时被封**；"微窗但非零"形态由 `blocked` 补上一刀。
   **不是 (b)**：对端行为与其内核源码规则一致（且它最终确实开过窗，见 MW1/MW11 的 FIN 带 `win=1460/832`）；**不是 (a)**：这不是"某处实现写错"，是**功能缺一整条**。

---

## ② 逐条依据

### 2.0 本轮跑一览（`runs/MW*.txt`）

| 跑 | rcvbuf | 结局 | `got` | `ΔW55` | `W69`终 (infl,eff) | `ΔW20` | 内容 | 注入 |
|---|---|---|---|---|---|---|---|---|
| MW1 | 2920 | **STALL** | 10,220 | 7 | (20,440, **0**) | 90 | 清 | — |
| MW2 | 2920 | **STALL** | 26,280 | 18 | (35,040, **0**) | 338 | 失配 | — |
| MW3 | 2920 | 健康 | 1,600,000,135 | 62 | (1,460, 1460) | 1,096,544 | 失配 | — |
| MW4 | 2920 | **STALL** | 32,120 | 26 | (4,380, **0**) | 227 | 清 | — |
| MW5 | 2920 | **STALL** | 27,740 | 23 | (8,760, **0**) | 217 | 失配 | — |
| MW6 | 2920 | **STALL** | 27,740 | 25 | (7,300, **0**) | 220 | 失配 | — |
| MW7 | 1460 | **STALL** | 4,380 | 4 | (0, 0) | 53 | 失配 | — |
| MW8 | 1460 | **STALL** | 24,820 | 20 | (39,420, **0**) | 411 | 失配 | — |
| MW9 | 1460 | **STALL** | 10,220 | 24 | (54,020, **832**) | 745 | 失配 | （探针未上线，见 §4-3） |
| **MW10** | 1460 | **STALL→恢复** | **1,600,000,135** | 3→24 | — | 1,096,074 | **清** | **win=1460 @+3.06 s** |
| **MW11** | 1460 | **STALL（不变）** | 1,460 | 1 | (0,0) | 42 | 清 | **win=0 @+3.10 s** |
| MW12 | 1460 | **STALL** | 21,900 | 20 | (40,880, **0**) | 413 | 清 | win=1460 @+20.1 s |
| MW13 | 1460 | **STALL** | 36,500 | 37 | (5,840, **0**) | 415 | 清 | win=1460 @+20.0 s |

（`ΔW55/ΔW20` = `W*_post − W*_pre`，全 32 位、本批**无回卷**；`W69` 取 post 快照。）

### 2.1 Q1 —— RTL 逐字（`rtl/tcp_tx_frame.v`；板上走 `TCP_TX_OVL=1` 分支 = 文件前半支，`board/build_p7b_ku5p.tcl:153`）

**装表门（`:1008-1018`，逐字）**：
```verilog
1008  if (scan_estab && ((rb_snd_wnd != 16'd0 && rb_snd_nxt != rb_snd_una) ||
1009      fin_retx_pend[scan_id])) begin
1010      if (rto_timer[scan_id] == 21'd0)
1011          rto_timer[scan_id] <= RTO_LIM;
1012      else if (rto_timer[scan_id] == 21'd1) begin
1013          rto_pend[scan_id] <= 1'b1;
1014          rto_timer[scan_id] <= RTO_LIM;
1015      end else
1016          rto_timer[scan_id] <= rto_timer[scan_id] - 21'd1;
1017  end else
1018      rto_timer[scan_id] <= 21'd0;
```
**到期动作链**（`:1012-1014` → `rto_pend` → `:510-511 svc` → `:521-524 svc_x/retx_begin` → `:945-954` svc 拍）：
```verilog
510  wire svc = rx_idle && !ack_pend_r && !retx_active && !rx_flush && (retx_req || rto_pend_any);
509  wire blocked   = (epoch[svc_id] >= 4'd15);
522  wire svc_rewind= svc_x && (rb_snd_nxt != rb_snd_una) && !blocked;
524  wire retx_begin= svc_x && !retx_deny;
945      retx_hi <= (fin_sent_r[svc_id] && svc_rewind) ? fin_seq_r[svc_id] : rb_snd_nxt;
949      replay_left <= RETX_SPAN;      // 预算仅对 dup-ACK 会话生效
950      replay_full <= !retx_req;      // ⭐ RTO 触发 ⇒ 全窗 (不受预算约束)
953      rto_timer[svc_id] <= RTO_LIM;
940-943  epoch[svc_id] 仅在 rb_snd_una 有进展时清零 (否则 +1, 封顶 15)
```
- ⭐ **"谁复位 `rto_timer`"（`P7B_OPEN_ITEMS.md` §1-A14 那笔悬账）四个出口**：① **装表门为假 ⇒ `:1018` 清零**（= **窗口 0 时卸膛，这就是本缺陷的 RTL 正身**）；
  ② `!scan_estab` ⇒ `:1004-1005` 清 `rto_pend`；③ svc 拍重装 ⇒ `:953`；④ 复位 ⇒ `:881`。
- **两种情形**：
  - `snd_una == snd_nxt`（无在飞）：门为假 ⇒ 计时器恒 0 ⇒ **无 RTO**（正确）；但**也没有 persist** ⇒ 若此后窗口为 0，板连"要不要发"都无从探询。
  - **`infl > 0` 且窗口 = 0：门为假 ⇒ 计时器恒被清零 ⇒ RTO 永不到期 ⇒ 无重传、无探询 ⇒ 死锁**。
- ⭐ **对称性证据（很有说服力）**：`rtl/app_ctrl.v:191/:263` 的注释**恰好记录了对称情形** ——
  "对端 pcap 显示『每 ~208ms 静默段 + 双向零包』, 周期恰等于**对端 persist/RTO 定时器**"、"恢复仍要等**对端 persist**"
  ⇒ 即 **板当接收方**时靠**对端的 persist** 解过锁（后来用 WU 修复改成主动通告窗重开），**板当发送方这一半从未实现**。
- ⚠️ 附带发现（本轮未观测到它起作用，只登记）：**`snd_wnd` 的写入没有"只在 ACK 推进时采"的守卫** ——
  `rtl/tcp_rx.v:509` `pend_wnd <= s_axis_tcrs || pend_wnd;`（**任何 FCS-OK 的 TCP 帧都写**）、`:519` `pend_wnd_val <= wnd_ws;`、`:467-469` `upd_sel = 3'd4`；
  对比 `:508` `pend_una <= (ack_adv_l && s_axis_tcrs) || pend_una;`（**有**守卫）。⇒ **陈旧/乱序 ACK 的 `win` 字段会覆盖当前窗口**（"最后一个 ACK 说了算"）。

### 2.2 Q2 —— 板级读数（stall 期）
- **判据 1（板确实停发）**：MW1 `W20` 在 0.06 s 后冻结（`0x5b`）、`W5` 照涨；MW2 `W20` 冻结在 `0x1b7`、`W5 = 0x5bd5c49d → 0xaa196a18`（跨 ~70 s）。
- **判据 2（重传发生过、然后停）**：`ΔW55 > 0` 在 **12/12 stall 跑**成立（1…37），且 **`W55` 在 stall 后半段逐位不动**。
- **判据 3（窗口状态）**：`W69` 定格 `eff = 0`（9 跑）⇒ 板侧 `snd_wnd = 0`；MW9 定格 `eff = 832`（微窗非零）。
  ⚠️ `W69` 是**事件锁存**且在两个值间交替 ⇒ **不作窗口主判据**，主判据 = **pcap 的 `win` 字段**（§2.3）。
- **判据 4（重传帧对端收没收到）**：pcap 逐帧分类 —— MW2 `BEYOND 317 / EDGE 18 / PRE_ACK 1`（336 帧）；
  `EDGE = 18 ⇔ got = 26,280 = 18×1460 ⇔ ΔW68 = 18`（**三处逐位吻合**）。`rcv_nxt` 轨迹（每 20 ms 只推进 2 段、**每一跳 `win` 都是 0**）：
```
   t= 0.0243 ack= 305424277 win=0     t= 0.1255 ack= 305438877 win=0
   t= 0.0649 ack= 305430117 win=0     t= 0.1661 ack= 305444717 win=0
   t= 0.1662（板最后一帧）… 15.1804 ack= 305446177 win=1460   ← 15 s 静默后 sink 放弃时的 FIN
```

### 2.3 Q3 —— 对端 socket / 内核计数 / pcap
- **`ss` 10 ms 序列**（MW2）：`Recv-Q` 全程 0、`skmem r=0`、`bytes_received` 2,920 → 26,280（18 段）后**冻结**；
  `rcv_space:14600`（**缓冲区是空的**）；`data_segs_in = 336`（**入口计数** = 板发的帧数，**不等于被栈收下**）。
- **内核计数前后差**（本轮新增采样器 `_tools/ctr.sh`，0.2 s；含上一轮**没查**的三个计数器）：

| 计数器 | MW3（健康） | MW4（stall） | MW5（stall） | MW6（stall） |
|---|---|---|---|---|
| `TcpExtTCPZeroWindowDrop` | +4 | +6 | +2 | +3 |
| `TcpExtTCPRcvQDrop` | +1 | +1 | +1 | +1 |
| `TcpExtTCPOFOQueue` / `OFODrop` | +2 / +14 | +0 / +0 | +0 / +0 | +1 / +0 |
| `TcpExtTCPToZeroWindowAdv` / `From…` | +42 / +43 | +20 / +21 | +14 / +15 | +17 / +18 |

  ⇒ **健康跑反而有更多零窗翻转**（窗口在 0 附近振荡本身**不是判据**）；**~300 帧的丢弃没有任何计数器对上**。
  ⚠️ 采样器**漏采了 `TcpExtDelayedACKLost`**（写的模式是 `TCPDelayedACKLost`，真名无 `TCP` 前缀）⇒ "那条路有没有动"**本轮未测**（登记为未做到）。
- **pcap 逐包**：MW1 = 板 86 包（85 data + SYN-ACK）/ 对端 83 包（全纯 ACK）；MW2 `win = {1460×211, 0×82, 64240×4, 62780×1}`；
  **板停发前最后两包 = `win=0`**；此后 **0 个包**直到 15.07 s 的 FIN（带 `win=1460/832`）。
  ⇒ 直接回答三问：**① 板停发后不再发包；② 对端也不 ACK（沉默）；③ 对端在整个 stall 期间不发窗口更新**（唯一带非零 win 的包是 sink 放弃后的 FIN）。
- ⭐ **"为什么对端不发窗口更新"已回码**（`/usr/src/linux-source-6.8.0.tar.bz2` 流式解出 `net/ipv4/tcp.c`，逐字）：
```c
1451  void __tcp_cleanup_rbuf(struct sock *sk, int copied)
1481  if (copied > 0 && !time_to_ack && !(sk->sk_shutdown & RCV_SHUTDOWN)) {
1482      __u32 rcv_window_now = tcp_receive_window(tp);
1483      if (2*rcv_window_now <= tp->window_clamp) {
1484          __u32 new_window = __tcp_select_window(sk);
1493          if (new_window && new_window >= 2 * rcv_window_now)
1494              time_to_ack = true;
```
  ⇒ **窗口更新的必要前提是 `copied > 0`（app 这一轮真读到了字节）**；stall 中被丢的帧**从不入队** ⇒ app 无字节可读 ⇒ `copied ≡ 0` ⇒ **对端结构性不会主动通告窗口重开**。
  （同函数 `:1455-1471` 的另一条 `time_to_ack` 路径同样以 `copied > 0` 为前提。）

### 2.4 Q4 —— 可复现性 + 判别臂
- **同档多跑**：2920 ⇒ `S,S,H,S,S,S` = **5 stall / 1 健康**；1460 ⇒ **7/7 stall**。
  （上一轮：11680 2/2 健康 · 5840 2/3 健康 · 2920 2/5 健康 · 1460 0/2 ⇒ **1460 档跨会话一致**，2920 档 stall 率**漂移**：本轮 5/6 vs 上轮 2/5，档位/工具相同 ⇒ **含竞态成分**。）
- **触发变量的最强候选 = 开流竞态**：`p7b_tcp_sink.cpp:306` 在 `connect()` **之后** `setsockopt(SO_RCVBUF)`
  ⇒ 线上先通告 64240、随即塌到 0/832/1460；而板初突发已按 64240 授权发出（本批最大 `ΔW20 = 415` 帧）。
- **判别臂**（本轮新增 `_tools/stall_probe.py`：**对端 raw socket 注入，不改任何配置**）：

| 臂 | 注入 | 结果（逐字） |
|---|---|---|
| **MW10** | 3× 重复 ACK `win=1460` @SYN+3.06 s | `POST_INJECT_BOARD_FRAME t=3.517952`（**末次注入后 0.158 s 起板发帧**）；1.5 s 内 **57,078 帧**；sink **收满 1,600,000,135 B / 572.3 Mbps / `first_mismatch=-1` / `stall_conns=0`** |
| **MW11** | 3× 重复 ACK `win=0` @SYN+3.10 s | `PROBE_DONE board_frames_after_inject=0`；sink **仍 STALL**（`got=1460`、`poll_tmo=3`） |
| MW12 / MW13 | 3× 重复 ACK `win=1460` @SYN+20.1/20.0 s | pcap 逐字：板 **269 / 313 帧**回复（首帧 t=20.154/20.043 s）；sink 的 poll 计时器被重置（`poll_tmo=8`）⇒ **注入生效**；但突发后**再锁**（20.5 s 之后双方零包到 60 s） |

⇒ **方向相反的双臂**把"板只是缺一个窗口通告"从推断变成**实测**；MW12/13 说明**一次通告只能换回一个突发**（突发后对端窗口又回到 0、且不再更新）。

---

## ③ 机制一句话（把上一轮的 §④-D 推断改成证）

**初突发（板按对端自己通告的 64,240 授权、≤ `WIN_CAP` 61,440）冲掉对端的小接收缓冲（`rcvbuf` 在 `connect()` 后才设）**
⇒ 对端把后续帧按"窗口外"丢掉（**不入队、不带计数**）⇒ 对端窗口通告停在 **0**（或微窗 832）⇒
**板侧两条路同时被封**：① `rtl:1008/:1018` 窗口 0 ⇒ **RTO 卸膛**；② 无 persist ⇒ **永不探询**；
⇒ 对端侧再无人触发 `__tcp_cleanup_rbuf` 的窗口更新（`copied ≡ 0`）⇒ **双向永久静默**。

⇒ **协议栈缺的那条机制 = 发送侧 persist / 零窗探询**（RFC 1122 §4.2.2.17 **MUST-36**）；
**附带**：RTO 不该在窗口 0 时卸膛（标准："**SHOULD retransmit the old data normally**"）。

⇒ **与既有登记（`P7B_OPEN_ITEMS.md` §1-A14：`ΔW55` 的 RTO 预测被实测证伪）的关系**：
`ΔW55` 实测 1…37（不是"饱和档 1/0/0/0"），且**停止增长的时点由"窗口归零 / `blocked`"决定，不由 RTO 量子决定**
⇒ **"RTO 预测"当初量的是"板还在不在重传"，而重传的开关是窗口**。

---

## ④ 未做到 / 未判定（逐条带原因）
1. **"丢在栈内哪一层"只到"分类级"**：逐帧分类（317 BEYOND / 18 EDGE）与内核源码的候选分支一致，但**没有逐帧 drop-reason 见证**（需 tracepoint/dropwatch）⇒ 具体出口 = **未逐帧证**。
2. **`blocked`/`epoch` 不可观测**（快照无此字）⇒ "微窗 832 形态（MW9）为何永久停摆"归因给 `:509/:522` 的 `blocked` 只是**候选**（另一候选 = `svc` 的前置被卡）⇒ **未做判别臂**。
3. **MW9 的注入臂没做成**：该跑探针因自己的 bug（TCP 头多塞 4 字节 + 注入时刻撞上 sink 拆连）**未上线** ⇒ MW9 仍只有被动读数。
4. **自己的探针监视窗有覆盖缺口**：MW12/13 的 `board_frames_after_inject=0` 是**仪器假阴性**（板在 20.04–20.52 s 的帧落在监视窗之前/边界）⇒ 已用 pcap 更正。**凡"仪器说没有"必须再对一台仪器。**
5. **FIN 行为未定位**（独立观察）：4 个 stall pcap 一致 —— 对端 FIN（+15.08 s，带 `win=832/1460`）被板重传 3–5 次（退避到 ~21.5 s）**而板一个包都不回**（连 ACK 都没有）；健康跑（MW10）收尾正常（对端 `ACK.RST`）。⇒ "板在 stall 态对**接收方向**的新段也失聪"这一格 = **未定位**。
6. **内容相位失配未定位**：13 跑中 6 跑失配（`first_mismatch=0`、`mism_bytes ≈ checked`），**全部出现在一次 stall 之后或同会话内**（唯一例外 MW3 = 健康+失配）⇒ 与 stall 的**因果未定**。
7. **`DelayedACKLost` 本轮漏采**（模式名写错）⇒ "旧数据丢弃路径有没有动"**未测**。
8. **未做**：`rcvbuf ≥ 11680` 档的本轮复跑（本轮只做 2920/1460）；"`SO_RCVBUF` 在 `connect` 前设"的**同位素臂**（需自建 sink 变体）⇒ **触发变量的判定仍是候选级**。
9. ⚠️ **纪律偏离（如实登记）**：MW1–MW9 **共用一次烧录**（每跑现核 `0x04`/`0x138`/`carrier`，但**不符合"每次测量前必重烧"的字面要求**）；MW10 起每次测量前重烧。

---

## ⑤ 现核到与派单 / 上一轮描述不符的地方

1. ⭐ **`first_mismatch=0` 的语义 = "第一个字节就不匹配"**，**不是**"连接头 ~170–206 B 之后才相位错"。
   证据：`p7b_tcp_sink.cpp:370/:386` 两条路径同一算式 `first_mis = got + f`（`f` = 块内首个失配偏移，`-1` = 全匹配）；`p7b_pattern.h:168-218` 的 `check_seq`/`check_lane8` 返回 `first`。
   ⇒ 而"~170/206 B" = `checked − mism` = **巧合匹配字节数**（≈ n/256；MW2 实测 26,280 − 26,187 = **93** vs 26,280/256 = 102 ✓；MW5 27,740 − 27,644 = 96 ✓）。
   ⇒ 正确读法：**整条流的相位从第 0 字节起就是错的**（不是"头部干净、之后才错"）。
2. ⭐ **`W69` 不宜作窗口主判据**：上一轮 6 个 stall 跑的 **post 快照**里 `Q5KD/Q2KD/Q2K2/Q1KD` 四个是 **`0x00000000`**（`Q1K = 0x4a240000`、`Q2KD2 = 0x1c840000`）——
   它是**事件锁存**，在 winstall 事件的低谷/别的连接/槽上会采到 0；MW9 实测它**逐点交替**两个值。
   ⇒ 本件窗口主判据 = **pcap 的 `win` 字段**（对端自己的通告）。
3. **NIC `Δbytes ≈ 715 KB` 的口径**：数字对（上一轮 Q2K2 `d_bytes=715,042 / d_pkts=472 / 1514.919 B/pkt` 逐字复算），
   但它覆盖 **21.6 s（含跑前 2 s 与跑后取样）**，不是 stall 窗本身；本轮 MW1 = `d_bytes=130,196 / d_pkts=90`（同量级、同结论）。
4. **`LF_GEOM_OK NW=63`**：本轮每跑逐字打出（`LF_GEOM_OK NW=63 BID=0x0000001a`），而实测窗口 = **70 字 / 未实现 `0x138`** ⇒ 与派单一致（硬编码字面量，**不作证据**）。
5. **"tcpdump 会打掉速率 ⇒ 2920/1460 档拿不到同档对照"不成立**：本轮 2920 档**带 pcap** 也拿到 1 个健康跑（MW3，1.6 GB 全清速）+ 5 个 stall
   ⇒ **stall 不需要 tcpdump 触发**（每跑都带 pcap；MW3 反证"带 pcap ≠ 必 stall"）。
6. **`data_segs_in` 不是"被栈收下"**：它是**入口计数**，MW2 实测 `= 336`（= 板发的帧数）而 app 只拿到 18 段 ⇒ **不能用它判"对端收下了"**。

---

## ⑥ 留场状态

| 项 | 值 |
|---|---|
| 板上位流 | **构建 F**：`ID_BID 0x0000001A` / `ID_UNIMPL 0xffffffff`（末次烧录 `20261010_184240`，sha256 现核 `89e89f31…0f45`） |
| `0x08`（SCRATCH / `TX_DIS`） | **`0x00000000`** |
| `carrier` | **1** |
| 对端残留进程 | **无**（`p7b_tcp_sink` / `tcpdump` / `stall_probe` / `ctr.sh` 全空） |
| 对端 sysctl / COALESCE | **一字未动**：`Adaptive RX: off` / `rx-usecs 0`（逐跑见证） |
| 上一轮工具 | `/tmp/p7b_biz/{p7b_snap.sh,lf_dl.sh,wdump.sh,p7b_tcp_sink}` = `ba2faf79…` / `8c8301aa…` / `03f19245…` / `c6b62420…`（逐字未变）· `/tmp/p7b_board2/lf_dl_snmp.sh` = `817f4243…`（未变） |
| 本轮新增（只在 `/tmp/p7b_microwin/`） | `ctr.sh`（内核计数采样器 0.2 s）· `stall_probe.py`（对端注入探针） |
| PCIe | `LnkSta x4` · `2 BARs`（每次烧录后设备级 `remove`+`rescan` 成功） |

---

## ⑦ 出处对照（本目录）

`REPORT.md`（本件）· `runs/MW{1..13}.txt`（逐跑原始输出，含 11 字内窗系列）· `runs/MW*_ctr.log`（内核计数逐点）· `runs/MW*_ss.log`（对端 10 ms `ss -tinma`）·
`runs/MW*.pcap`（双向全窗抓包，128 B snaplen）· `runs/MW*_probe.log`（注入臂逐字）· `runs/MW*_id.txt` / `*_coalesce.txt` / `*_postid.txt` / `burn/`（身份与留场）·
`parse_ss.py` · `pcap_tcp.py`（`summary|classify|raw|frames|acks`）· `ctr_delta.py` · `run_mw.sh` · `burn_F.sh` · `_tools/ctr.sh` · `_tools/stall_probe.py`。
对端只读引用：`/tmp/p7b_biz/p7b_snap.sh`（**一字未改**）· `/tmp/p7b_board2/lf_dl_snmp.sh`（上一轮插桩件，**一字未改**）· `/usr/src/linux-source-6.8.0.tar.bz2`（内核规则回码源）。

### RFC 引文出处（WebSearch）
- RFC 1122 §4.2.2.17「Probing of zero (offered) windows MUST be supported (MUST-36)」+「SHOULD ... retransmit the old data normally」：
  [draft-ietf-tcpm-persist-07](https://www.ietf.org/archive/id/draft-ietf-tcpm-persist-07.xml) · [CERT VU#723308](https://www.kb.cert.org/vuls/id/723308) ·
  [tcpm-drafts.pdf MUST-36](https://datatracker.ietf.org/meeting/94/agenda/tcpm-drafts.pdf#29#10) · [RFC 1122 全文](http://abcdrfc.free.fr/rfc-vf/pdf/rfc1122.pdf#18#15)
