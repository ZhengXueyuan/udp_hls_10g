# P7B-RETXHI-GHOST 设计件 —— 重放上界越过"环已写高水位" ⇒ 线上出现【本圈未写过】的环字节

- **性质**：既有机制的**正确性缺陷**（**不是** persist 特性；persist 臂 T 的 `PERSIST_EN=0` 同族复现）。
- **边界（本件纪律）**：**纯纸面**。未改一行 RTL/TB/sim/board/脚本；零 Vivado / 零 xsim / 零构建 / 零板卡。
- **固定句（必守）**：**核到与本件描述不符就如实说，别迁就。** 下面每一个行号、每一处"已定案"都是本轮**回源码逐字核过**的；凡是**订正**或**未定**，都在原处显式标出。
- **标注约定**：【事实】= 回源码/回日志逐字可复算；【推断】= 由事实推得、未直接测量；【未定】= 我判不了。
- **证据地图（取证原件，先读这几件）**：
  `_proj_10g/notes/p7b_persist_impl/ev/orS_oracle_v6_xs.log`（关死证据 + SVC 判决行）·
  `…/ev/orS_oracle_v5_xs.log`（红帧逐字）· `…/ev/orT_oracle_v5_xs.log`（persist 关臂同族复现）·
  `…/ev/or{S,T}_oracle_xs.log`（v4 级）· `…/patch_oracle_v{4,5,6}.py`（探针真值与判读定义）·
  `…/ev/gate4_stdout.txt`（门记录，`[S]` 段）· `…/ev/q1_*_out.txt`（上一圈签名复算）·
  `…/ev/rerun_oracle.bat`（两臂定义 = 我核过臂 S/T 的真值源）。
  提交：`fd880e2`（发现）· `9d6554e`（机制到行）· `68bb98c`（关死到 (a)）· `22c0282`（取证件补录）· `3789beb`（进 OPEN_ITEMS §1-A19）。

---

## §0 一页摘要（现核结论 / 建议修法 / 代价 / 建议门）

| 项 | 结论 |
|---|---|
| 状态级缺陷 | 重放区间 `[snd_una, retx_hi)` 的**末 `drift = retx_hi − 环已写高水位` 字节**落在**本圈从未写过的环地址**（环地址只取 `seq[15:0]`，差一圈不改地址）⇒ 读回**上一圈/上一会话**的残留并当数据上线 |
| 机制 | 【事实·关死】`rtl/tcp_tx_frame.v:636` 的**控制帧 `snd_nxt + 1` 预留逐笔累积**；`retx_hi`（`:1131-1132`）**直接继承**这些幽灵 seq；`:760/:765` 的重放范围按被污染的差值走 |
| 两条既有缓解为什么不够 | `ctrl_adv_inflight`（`:612-613`）只推迟**在飞的**那一笔；`fin_seq_r` 支路（`:1131`）只消掉**最后一个** FIN 的 +1。**累计的 +1（早先的 RST、早先的 FIN 重推）没人消** ⇒ 这正是 Stage C 设计 §3-C6 自认"结构性排除"**没覆盖到的那一格**（见 §1.2） |
| 建议修法 | **候选 B（推荐）**：给每连接加"环已写高水位" `whi_r[0:15]`，会话装载拍锁存 `ring_hi`；**环侧**（`ring_delta`/`ring_start`/收尾跳写）改由 `ring_hi` 走；**`retx_hi`（= `tcp_rx` 的 ACK 上界）与 `:636` 一字不动**；并新增"排空拍把 `snd_nxt` 恢复到 `retx_hi`"的收尾写 |
| ⛔ 明确回答 | **不要动 `:636`**（`snd_nxt += 1` 是"控制帧占一个序号"的唯一落点；卡它会崩对端 ACK 语义 / `fin_push` 的 `snd_nxt==snd_una` 门 / 窗口门口径） |
| 代价（单报） | **≈ +544 FF**（16×32 高水位 + 32 位锁存）+ **≈ +100–200 LUT**，**0 BRAM**，**不新增长锥**（`ring_delta` 的锥形与今日**同型同深**，只换操作数来源） |
| 与 persist 的先后 | persist 的 RTL **已在 HEAD**（`git diff HEAD -- rtl board` = 空）且**尚未构建**；`wrapper` 的 `.PERSIST_EN(1'b1)` 是它的唯一打开点 ⇒ **要分离代价就先 `.PERSIST_EN(1'b0)` + 本修 单独构建**（详见 §8.3） |
| 建议门 | 复用**既有** J3(`e_payload`)/J4(`e_seqcont`) —— **改前必红已在案**（臂 S `payload=3 seqcont=1`）；**改后必须 = 0**。若加定向判据，**必须同时改进 `tot_red` 白名单和式**（`tb/tb_tcp_tx_ovl.v:2228`）—— 见 §5 的"合流入口"警告 |
| 板级首步 | ⛔ **先花 10 分钟证明"板上到底会不会出幽灵"**（零构建：一条关闭连接 + 慢读对端 + `ΔW55>0` 见证 + sink 逐字节计数器）—— 见 §6.2 |

---

## §1 缺陷的精确定义与边界

### 1.1 状态级定义（逐字回源码）

**定义**：对任一连接，令 `wrhi` = 该连接**环里真写出过的最高 seq**（= 最后一个数据帧的 `f_seq + f_plen`）。
重放会话把区间 `[snd_una, retx_hi)` 当"待重发数据"逐段读出组帧（OVL 支 `:1143-1166` 起帧、`:1146` `f_seq[rx_bank] <= rb_snd_nxt`、`:1162-1164` 预推进；else 支 `:2176-2199` 同构）。
**当 `retx_hi > wrhi` 时**，区间末 `drift = retx_hi − wrhi` 字节的**读地址**是"本圈从未写过"的。

**为什么"读地址 = 上一圈的字节"**（【事实】）：
`rtl/retx_ram.v:3` 逐字 "16 conns x 64KB ring (字节偏移 `w_seq[15:0]`, 模 `2^16`)"；`:36` `wire [12:0] w = w_seq[15:3];`、`:85` 读口同构 ⇒ **地址只由 seq 低 16 位决定** ⇒ 差 65536 不改地址。环里那个地址留着**上一次写它的内容** = 上一圈（同连接、流偏移 −65536）的字节；同槽重连后也可能是**上一会话**的字节。⇒ 这就是"线上出现上一圈字节"。

### 1.2 机制到行：`(a) +1 预留逐笔累积`（【事实·已关死】）

**OVL 支（板构建编的就是它；`board/build_p7b_ku5p.tcl:153` 有 `TCP_TX_OVL=1`）**：

```
rtl/tcp_tx_frame.v:635-637
    assign      upd_val = upd_wr_data ? (f_seq[rx_bank] + {20'b0, f_plen[rx_bank]}) :
                          (upd_wr_ctrl ? (rb_snd_nxt + 32'd1) :      // ← ⭐ :636 = 幽灵 seq 的产地
                           (replay_jump ? retx_hi : rb_snd_una));
rtl/tcp_tx_frame.v:628
    wire        upd_wr_ctrl = start_ack && !probe_sel && (aq_syn | aq_fin | aq_rst);
rtl/tcp_tx_frame.v:1131-1132   // 会话装载: 重放上界【直接继承】上面的 snd_nxt
                    retx_hi <= (fin_sent_r[svc_id] && svc_rewind) ? fin_seq_r[svc_id] :
                               rb_snd_nxt;
rtl/tcp_tx_frame.v:760
    wire [31:0] ring_delta = retx_hi - rb_snd_nxt;
rtl/tcp_tx_frame.v:765-766
    wire        retx_ovf = (rb_snd_nxt != retx_hi) &&
                           ((rb_snd_nxt - retx_hi) < 32'h8000_0000);
```

**else 支（`ifdef TCP_TX_OVL` 的 `else`）同款三处**（我逐行核过，【事实】）：
`:1791-1792` `assign upd_val = svc_rewind ? rb_snd_una : seq_r + (is_data_r ? {20'b0, plen_r} : 32'd1);`（`+1` = 同一产地）·
`:2162-2163` `retx_hi <= (fin_sent_r[svc_id] && svc_rewind) ? fin_seq_r[svc_id] : rb_snd_nxt;` ·
`:1631` `wire [31:0] ring_delta = retx_hi - rb_snd_nxt;` + `:1638-1639` 同型 `retx_ovf`。

**⛔ 行号订正三条（派单书 vs 现核）**【事实】：
1. 派单书写 `ifdef TCP_TX_OVL` 在 `:281` / `else` 在 `:1248` ⇒ **现核 = `:303` / `:1517`**（`endif` 在 `:2499`，`endmodule` 在 `:2501`）。
2. 派单书写"`:636` `assign upd_val = …`" ⇒ **现核：整条 `assign` = `:635-637`，`+1` 字面在 `:636`**（OPEN_ITEMS §A19 用 `:636` 指"产地"、`:635` 指"数据支"，与本处一致；引用时给全 `:635-637` 最稳）。
3. 派单书写"`:950` `replay_full = !retx_req`" ⇒ **现核：该赋值在 `:1136`**（`replay_full <= !retx_req;`，`// ⭐ r4: RTO 触发 (无挂起 dup 请求) ⇒ 全窗`）；而 `:950` 是 `checksum16` 例化后的**注释行**（"---- FIN/RST 排队…"）⇒ **`:950` 这条引用是错的**。
4. 派单书写"三条独立账本" ⇒ **现核应读作"独立的两账"**（OPEN_ITEMS §1-A19 ① 的现核口径，逐字）：① DUT 写口高水位 ② 对端 ACK 的 `snd_una`；第三个数（`snd_nxt`/`retx_hi`）是**同一 DUT 的自身寄存器**，**不算独立账本**。（`9d6554e` 的旧措辞"三条独立账本"已被 §A19 就地订正 —— 本件按订正后写。）

**（b）"单帧一次越顶"为什么被排除**【事实·可复算】：我实测复算 `grep -o "excess=[0-9]*" ev/orS_oracle_v5_xs.log | sort | uniq -c` ⇒ **`{1×53, 165226×6, 166727×1}`**（大值两族 = v6 注释点名的"按实例清零"假象族；**2..7 无样本**）⇒ 数据帧的单帧越顶不成立；而 `nxt_minus_wrhi = 21 = ctrl_n(22) − 1` 与"控制帧 +1 累积"严格吻合。

### 1.3 ⭐ 两条既有缓解为什么不够（**这是本刀真正的设计教训**）

Stage C 设计件 `_proj_10g/notes/P7B_TX_PINGPONG_FIX_DESIGN.md:242` **逐字**：
> 理由：预留后 `rb_snd_nxt` 在 FIN 在飞期间**领先 1**（`= fin_seq+1`）；若此时回卷，`retx_hi <= rb_snd_nxt` 就含这 1 字节 ⇒ `ring_delta = 1` ⇒ **在 FIN 的 seq 上重放 1 字节数据**（协议违规，G9 同族）。门后回卷推迟到该 FIN 落 `fin_sent_r` 之后（≤1 个帧期 ≈200 拍），G9 的 `retx_hi <= fin_seq_r[svc_id]` 规则随即生效 ⇒ **结构性排除**。

现核（【事实】）：
- **缓解①** = `ctrl_adv_inflight`（`:612-613` `wire ctrl_adv_inflight = ctrl_slot_busy && (|ctrl_is) && (ctrl_id == svc_id); wire svc_x = svc && !ctrl_adv_inflight;`）—— 只挡"**帧首预留后、该帧未落**"的这**一笔**（≤1 帧期）。
- **缓解②** = `fin_seq_r` 支路（`:1131`）—— 只把**最后一个** FIN 自己的 +1 从区间里摘掉。
- ⇒ 两者合起来等于"**每一笔 +1 都各自被挡一次**"，但 `snd_nxt` 里**已经沉淀**的 +1（早先 RST 的 +1、早先 FIN 重推的 +1、同连接历史会话的 +1）**没有任何一处消** ⇒ 下一会话 `retx_hi = rb_snd_nxt` 把**全部沉淀**吃进区间。
- ⇒ 判决读数正好是这个形态：`ctrl_n = 22`（累计控制帧写 22 笔）而 `drift = 21`（**只有 1 笔**被环基址吸收）⇒ 【事实】。
- ⭐ **可复用的教训（建议进全局 §六）**：「**"结构性排除"的论证若是对"单笔"成立，就管不住"可累积的量"** —— 判据必须写明它排除的是**瞬时一笔**还是**累计沉淀**，并对后者给"累计上界 = 0"的**测量**（本缺陷就是靠 `ctrl_n` 与 `drift` 两个**按连接**计数才关死的）。

### 1.4 ⭐ 什么条件下会写错 / 什么条件下不会（逐条）

**会**（必要条件，三条同时成立）：
1. 该连接**在数据首字节写入环之后**又发过 ≥1 个走 `upd_wr_ctrl` 的控制帧（SYN/FIN/RST 任一）—— 即 `drift > 0`；
2. 之后该连接发生重放会话，且 `retx_hi > wrhi`（会话区间的尾段落在漂移区）；
3. 该漂移区间的环地址**在本圈确实没被写过**（由 1 保证：`snd_nxt` 跳过它 = 写游标跳过它；写游标 = `w_tap_seq = start_data ? rb_snd_nxt : tap_seq`（`:789`），与读游标同源（`:775` `r_tap_seq`）⇒ **数据覆盖是连续的，漂移处留 1 字节/笔的洞**）。

**不会**（逐条给读数/机制）：
- **不会 A（基址吸收）**：控制帧 +1 **全部发生在该连接写入首个数据字节之前** ⇒ 环基址偏移与 `snd_nxt` 偏移同相 ⇒ `drift = 0`。
  证据【事实】：`orS_oracle_v6_xs.log:389` `ORACLE WTRK cyc=330736 kind=SV c=0 … ctrl_n` 那一族 = 同日志 `:2695` `ORACLE4 @375000 ctrl=8/22/18/2` ⇒ **conn0 累计 8 笔而 `drift ≡ 0`**（`:389` `nxt_minus_wrhi=0`）。
  ⭐ **板配置下这条是常态**：`board/wrapper_p4.v:2101-2103` 把 `tx_ack_syn = tx_ack_fin = tx_ack_rst = 1'b0` **钉死**（SYN-ACK 由慢路径 HLS 发，`board/wrapper_p4.v:2128-2129` 的 r6 注释逐字"SYN-ACK 由慢路径发"）⇒ **板上本模块的控制帧 = FIN/RST 推(re-push) 一族**，SYN 的 +1 永不经过 `upd_wr_ctrl`。
- **不会 B（FIN 支路自洽）**：纯"数据 + 一个 FIN"且 FIN 直接跟在数据端 ⇒ `fin_seq = wrhi`，且 FIN 重推**先回卷再落 seq**（`fin_repush` 要求 `rb_snd_una == fin_seq_r`（OVL `:957-959`），回卷把 `snd_nxt` 拉回 `fin_seq`。）⇒ `retx_hi = fin_seq = wrhi` ⇒ **区间为空/无幽灵**。⇒ **纯 FIN 场景本缺陷不发作**（Stage C 的 C6 缓解在这一支是有效的）。
- **不会 C（区间全在高水位以下）**：`drift > 0` 但会话区间 `[snd_una, retx_hi)` 完全落在 `wrhi` 以下（下界被 ACK 顶上来）⇒ 读到的都是本圈正确字节。
- **不会 D（无会话）**：没有重放会话 ⇒ 没有任何环读 ⇒ 无幽灵（`drift` 仍存在，只是没被消费）。
- **不会 E（新连接重基）**：同槽重连后 `snd_nxt` 被慢路径重基到新 ISN ⇒ 旧漂移不再落在区间里（但**旧字节仍躺在环里**，一旦新会话读到该地址就是"上一会话"的残留 —— 与 A/B/C 同族，不是新机制）。

### 1.5 ⭐ 除了"发上一圈字节"，它还会不会导致别的后果（逐条回源码判）

| # | 后果 | 判据（回源码） | 结论 |
|---|---|---|---|
| ① | **字节账不错** | `:776` `plen_preset = (ring_delta >= 32'd1460) ? 12'd1460 : ring_delta[11:0]`；`:1157-1158` `f_tcplen/f_totlen` 由 `plen_preset` 派生；`stat_bytes` 由 `h_plen` 计（`:1470`） | **计数类判据（ΔW9==Σ线上载荷、pcap 帧长、NIC 字节/包比）结构性看不见它** —— 本缺陷只对**内容类**判据可见【事实】 |
| ② | **seq 不错、无整体偏移** | 重放帧 `f_seq[rx_bank] <= rb_snd_nxt`（`:1146`）+ 逐帧推进 `upd_val = f_seq+f_plen`（`:635`）⇒ 帧的 seq 区间严格铺满 `[snd_nxt, retx_hi]` | **正常数据不会被错发/漏发**：高水位**以下**的读地址本圈写过、内容正确（写游标 `:789` 与读游标 `:775` 同源）⇒ **不是"整相位错"**（与登记件的判形态一致） |
| ③ | **对端 `rcv_nxt` 会被推过幽灵** | 幽灵字节是**合法 TCP 数据段**：FCS 正确（MAC 层重算）、TCP/IP 校验和正确（`:1428-1455` 正常数据路）、seq 落在对端窗口内 | 两种结局、**取决于对端是否已在该 seq 消费过 FIN/RST**：(i) 已消费 ⇒ 幽灵段落在 `rcv_nxt` 之下 ⇒ RFC 作**重复段**处理（只回 ACK，不交付应用）；(ii) 未消费 ⇒ **被当新数据交付** ⇒ 对端流尾部**多出 `drift` 个垃圾字节**。⚠️ **板上属哪一支 = 【未定】**（见 §9-U2）—— 但**两种结局都让"载荷逐字节校验"出少量失配**（校验按**偏移**比对） |
| ④ | **`plen` 算错吗？** | `plen_preset = min(ring_delta, 1460)` ⇒ 末帧恰好覆盖到 `retx_hi` | **算术不错**，错的是"这段 seq 位里有一部分**从来不是数据**"这个**前提** |
| ⑤ | **会话终止不受影响** | 末帧推进写把 `snd_nxt` 推到 `retx_hi` ⇒ `ring_delta → 0` ⇒ 排空支收尾（`:1167-1181`） | **不会自持**（与 F1 的下溢自持族**不同**；F1 已在 `:765-766`/`:1638-1639` 两分支同修） |
| ⑥ | **ACK 上界被同步放宽** | `:984` `assign o_retx_hi = retx_hi;` → `board/wrapper_p4.v:1852` `.ra_retx_hi(tx_retx_hi)` → `rtl/tcp_rx.v:320` `ack_hi = ra_retx_active ? ra_retx_hi : ra_snd_nxt` | 放宽幅度 = `drift`，与幽灵同源、**自洽**（对端只可能为"它真收到的 seq"发 ACK）⇒ **不新增接受面**；⛔ **但它把"改 `retx_hi`"这条路封住了** —— 见 §2-A |
| ⑦ | **F1 越顶事件的另一条路径** | 会话期控制帧 +1 可让 `snd_nxt` 越过 `retx_hi` ⇒ `retx_ovf`（`:765`）⇒ 会话提前排空；计数 = `stat_retx_wrap`（`:1068-1071`），臂 S 读数 `wrap_ev=635`（`gate4_stdout.txt:2703` 一带） | 【事实】= **同一 +1 族的第二条路径**（F1 已消其"下溢洪泛"后果）；⛔ **本刀不改它的判据源** —— 理由见 §3.5（会打红 TB 既有硬判据 `e_f1_cyc`） |
| ⑧ | **对**后续活帧**无污染** | 活帧写游标 = `snd_nxt`（`:789`/`:1295`/`:1305`），总在漂移区**之上** | 幽灵区永不被后续正确数据覆盖（它是"洞"）⇒ **不会把错值喂回正常通路** |

### 1.6 证据（逐字·可复算）

**决定性读数**（`ev/orS_oracle_v6_xs.log:1750`，逐字复制）：
```
ORACLE SVC cyc=353120 c=1 una_off=246436 nxt_off=246457 wrhi_off=246436 nxt_minus_wrhi=21 new_retxhi_off=21 ctrl_n=22 data_n=438 fins=0 rsts=1
```
同拍/次拍两条 WTRK（`:1751` / `:1754`，同一会话，**判读顺序必须注意** —— SVC 行打印的是**装载前**的 `retx_hi`）：
```
:1751  ORACLE WTRK cyc=353120 kind=SV c=1 una_off=246436 nxt_off=246457 retxhi_off=4294921360 wrhi_off=246436 nxt_minus_wrhi=21 retxhi_minus_wrhi=4294674924 fins=0 rstss=1 svcw=1 rjmp=0 rleft=3
:1754  ORACLE WTRK cyc=353151 kind=RS c=1 una_off=246436 nxt_off=246436 retxhi_off=246457 wrhi_off=246436 nxt_minus_wrhi=0  retxhi_minus_wrhi=21          fins=0 rstss=1 svcw=0 rjmp=0 rleft=3
```
⇒ **`retxhi_off(246457) − wrhi_off(246436) = 21`，而 `una_off = 246436 = wrhi_off`** ⇒ **该会话的重放区间 `[246436, 246457)` 整段都是幽灵**（不是一个字节）【事实】。

**两账独立·逐字相同 = 246,436**【事实】：
- 账① DUT 写口高水位：`ev/orS_oracle_v6_xs.log:2693` `ORACLE2 @375000 … wrhi=1087302/246436/26511/26511`（连接 1 = **246436**；同日志 `:2688` @350000、`:2689`… 逐档同值）。
- 账② 对端 ACK 的 `snd_una`：TB 接收模型的 `peer_rcv[1]` 在红点会话装载拍的装载值（`tb/tb_tcp_tx_ovl.v:1067` `rx_upd_val <= peer_rcv[ack_sch]`；装载值由 `:1050-1051` 的 `isn+1` 起算、按帧 `fseq+plen` 推进）—— 台账逐字 = **246436**（OPEN_ITEMS §A19 ① 已登记为两账独立同值）。
- 第三个数 `snd_nxt/retx_hi = 246457` = **同一 DUT 的自身寄存器** ⇒ **不算独立账本**（订正见 §1.2-4）。

**写侧被排除**（`ev/orS_oracle_v6_xs.log:2692` 逐字）：
```
ORACLE @375000 src_b=1436291 src_ok=1436291 wr_b=1436291 wr_cyc=180182 e_conn=0 e_seq=0 e_val=0 e_data=0 ctl_src=0 ctl_miss=0 rd=46836 rdbad=19
```
⇒ 没有丢写、没有写去别址、写进去的值也合规（`rdbad=19` 属探针自身 lane 口径，见 `patch_oracle_v6.py:191-202` 的 `rdx/rd_bad` 分列，本件不采信为写侧证据）。

**读侧越界计数**（同日志 `:2690-2693`）：`rdahead=82`（重放读的 32 位游标越过已写高水位的次数，**下界**）· `rdx=147`。

**红帧三连**（`ev/orS_oracle_v5_xs.log:965-966,1730` 逐字；v6 同族在 `orS_oracle_v6_xs.log:987,1757`）：
```
[FAIL] seq partial conn=1 seq=0004e59c plen=29 exp=0004e5a4 @347515
[FAIL] payload conn=1 seq=0004e59c off=8  got=2d exp=9f @347515
[FAIL] payload conn=1 seq=0004e5a4 off=0  got=2d exp=9f @353173
```
- `plen = 29 / 21` **恰 = `retx_hi(246457) − snd_nxt(246428 / 246436)`**；失配起点 `off = 8 / 0` ⇒ 折算流偏移**都是 246,436** = 本圈未写的第一字节【事实】。
- `seq partial` 的含义我已回源码核过（`tb/tb_tcp_tx_ovl.v:787-798`）：TB 的 `exp_new[c]` 只在"帧起点恰好接上前沿"时推进 ⇒ `exp = 246436` 说明**上游已有一段（止于 246436）被判为正确**，而这帧 `[246428, 246457)` 的**尾段越过了前沿 21 字节** ⇒ 红。⇒ **J4 这条红同样是幽灵的产物**（它的尾段就是幽灵段）。

**形态复算（"上一圈"签名）**（`ev/q1_*_out.txt` 逐字）：
```
[S#1] conn=0 fseq=000de510 plen=1460 … off=0: got=cf  同圈偏移 k=[-1]  ⇒ 本字节对应的流偏移 = 783376
   同圈解出: 本圈偏移 s=848912 = o +0圈 +0字节 -> 命中 15/16 字节
[S#2] conn=1 fseq=0004e59c plen=29 off=8: got=2d k=[-1] ⇒ 180892 ; 同圈命中 8/16
[S#3] conn=1 fseq=0004e5a4 plen=21 off=0: got=2d k=[-1] ⇒ 180900 ; 同圈命中 0/16
```
⇒ **三条红帧的失配字节全部 = 本圈偏移 − 65536 的值**（`783376 = 848912 − 65536`；`180892/180900 = 246428/246436 − 65536`）【事实】。
⭐ 且 `[S#1]` 的"**同圈命中 15/16**"自洽地说明：该帧 **drift = 1**（只有首字节是幽灵），其余 1459 字节是本圈**真数据** —— 因为 `wrhi` 在 FAIL 拍（`@317103`）早已高过 RD-AHEAD 打印拍（`@312207`，`差=4`）的值。⚠️ **读数协议提醒**：**RD-AHEAD/RDZOOM 是带时间戳的瞬时量，不得与数千拍之后的 FAIL 行交叉引用**（我本轮就是这么绕了一圈弯路）。

**门记录（改前必红的在案证据）**（`ev/gate4_stdout.txt:649-653`，`[S]` 段逐字）：
```
  [S]:
REDS parse=0 csum=0 payload=3 seqcont=1 seqmono=0 ctrl=0 ctrl_to=0 onehot=0 pendbusy=0 replay=0 stuck=0 ovf=0 ackf=0
T8 rx1460 min=189 n=973 (expect <=190)  tx1460 min=191 n=1232 (expect <=192)
T8 fp1460 min=191 (expect <=200)  overlap=52/100 of RX-inflight (131332/251227)
TB_TCP_TX_OVL: FAIL reds=5
```
（T 臂同批 = `payload=14`，见 `ev/orT_oracle_v5_xs.log:3465`；⚠️ T 臂只有 3 条 payload 落盘 —— 打印上限 `if (e_payload < 4)`（`tb:804`）⇒ **其余 11 条未枚举**【事实】。）

**臂定义**（`ev/rerun_oracle.bat` 逐字核过）：
`S` = `-d TCP_TX_OVL -d ARM_PERSIST -d PS_RINGORACLE` ⇒ `TB_PERSIST_EN = 1'b1`（`tb:76`）；
`T` = 再加 `-d PERSIST_NEGCTL` ⇒ `TB_PERSIST_EN = 1'b0`（`tb:74`，**负对照臂**）。
⇒ **臂 T（persist 关）同族复现** ⇒ **本缺陷不是 persist 引入**（`orT_oracle_v5_xs.log:3465` `payload=14`）【事实】。

---

## §2 修法选型（≥2 候选，逐条给代价；每条都回源码核过可行性）

> 选型的**唯一硬约束**（回源码得到）：`retx_hi` **同时**是 ① 环重放上界 ② `o_retx_hi` → `tcp_rx.ack_hi`（ACK 接受上界）。任何"夹 `retx_hi`"的方案都在动 ②。

### 候选 A：**夹住 `retx_hi`**（会话装载拍取 `min(rb_snd_nxt, 高水位)`）

⛔ **核结论：不可行（裸夹）**。逐条：
- **A-1（ACK 上界被夹）**【事实】：`:984` `assign o_retx_hi = retx_hi;`；`rtl/tcp_rx.v:320` `wire [31:0] ack_hi = ra_retx_active ? ra_retx_hi : ra_snd_nxt;`。
- **A-2（夹下去会命中已板级实证的死锁族）**【事实】：`rtl/tcp_rx.v:306-320` 的注释**逐字**记着既有事故："回卷把 `snd_nxt` 降到 `snd_una`, 若仍用 `snd_nxt` 判上界, 对端'确认已到达数据'的合法 ACK (`ack > 回卷后 snd_nxt`) 被拒 —— TCP 不重传 ACK, `snd_una` 永久冻结, in-flight 恒 = 满窗 → 窗口门永关 → **死锁**（**板级实证**: 48KB 窗 + RTO 重放 35 帧, PC ack=高水位 落在重放期被拒, 板侧 seq 永不前进）"。
- **A-3（FIN 的 seq 按 RFC 占一个序号 ⇒ 夹不干净）**【事实+推断】：控制帧的 seq **确实**进了对端 `rcv_nxt`（FIN 占 1）⇒ 对端会为 `fin_seq+1` 发 ACK；而 `fin_seq` **可以**高于 `wrhi`（历史 +1 沉淀）⇒ 夹完 `ack_hi = wrhi < fin_seq+1` ⇒ 该 ACK 被拒 ⇒ 该连接的 FIN 完成判据 `rb_snd_una == fin_seq_r`（OVL `:1192` 扫描清除 / `:957-959` 重推门）**走不到"经 ACK 收口"那条路**，只能靠扫描的清位退路。
- **A-4（把 `fin_seq_r` 支路夹坏）**【事实】：`:1131` 那条支路存在的**唯一目的**就是"别把 FIN 自己的 seq 当数据重放"；夹 `retx_hi` 会把它**连数据一起夹没**（因为 `fin_seq ≥ wrhi`）⇒ 区间 `[snd_una, min(fin_seq, wrhi))` 从"重放数据"退化成"什么都不重放" ⇒ **若此时 `snd_una < wrhi`（洞在数据里），会话变成空转** ⇒ 洞只能等下一个 RTO，而下一个 RTO 再夹一次 ⇒ **洞永不修复**。
- **A-5 修法（如果要救 A）**：必须"夹环侧 + 不夹 ack 侧 + 收尾恢复"三件套 ⇒ **那就已经是候选 B**（见下）。⇒ **A 无独立价值**。

### 候选 B：**让幽灵 seq 不进【环重放上界】**（= 拆出 `ring_hi`，`retx_hi`/`ack_hi` 一字不动）⭐ **推荐**

做法（细节在 §3）：新增每连接"环已写高水位" `whi_r[0:15]`（32 位，= 数据端 seq，只在**活帧推进写**时更新）；会话装载拍锁存 `ring_hi <= whi_r[svc_id]`；**环侧三处**（`ring_delta` / `ring_start` / 收尾跳写）改由 `ring_hi` 走；`:1131-1132` 的 `retx_hi` **原样保留**；新增"排空拍恢复写"`ring_restore`（把 `snd_nxt` 恢复到 `retx_hi`）。

- **可行性核（逐条）**：
  - **B-1（不动 ack 侧）** ⇒ `o_retx_hi`/`tcp_rx.ack_hi` **逐位不变** ⇒ 不碰 A-2 的死锁族。✔
  - **B-2（`fin_seq_r` 支路会不会被夹坏？）** ⇒ **不会，而且它变成冗余**【事实】：`whi_r = wrhi ≤ fin_seq`（FIN 的 seq ≥ 数据端）⇒ `ring_hi = wrhi` 天然排除 FIN 的字节，`:1131` 的 `fin_seq_r` 支路（对 `retx_hi`）**保持原样、继续服务 ack 语义**。
  - **B-3（`snd_nxt` 与环上界分离之后，`:760/:765` 还成不成立？）** ⇒ **成立，但要立第二条判据**：`ring_delta` 换成 `ring_hi − rb_snd_nxt` 后，"越顶"必须由**同型**的 `ring_ovf` 判（不能借 `retx_ovf`：`retx_ovf` 的语义是"越过 `retx_hi`"，两者不同对象）。⛔ **不许把 `retx_ovf` 的定义改指 `ring_hi`** —— 那会打红 TB 既有硬判据 `e_f1_cyc`（`tb:2025/2035` 生成、`tb:2230` 在 `tot_red` 和式内）【事实】；`retx_ovf` 必须**保持指向 `retx_hi`**。
  - **B-4（`replay_full = !retx_req`（`:1136`）与 RETXFIX 的 `blocked`/`epoch` 会不会被影响？）** ⇒ 【事实】它们不消费 `ring_delta`：`blocked = (epoch[svc_id] >= 4'd15)`（`:561`）只看 `epoch`；`svc_x = svc && !ctrl_adv_inflight`（`:613`）；`replay_full` 只做两件事 —— 允许/禁止 `ring_start`（`:768`）与禁止 `replay_jump`（`:773`）。⇒ 本刀改的是 `ring_delta` 的**操作数**，`replay_full` 的语义（预算逃逸）**不变** ✔。⚠️ **但有一条必须一起改**：`replay_jump` 的**触发条件**（见 B-5）。
  - **B-5（收尾必须补"恢复写"，否则回归 spurious FIN）**【事实+推断】：环上界降到 `whi` 后，排空拍 `snd_nxt = whi < retx_hi`；此时随后的控制帧（FIN 重推）会取 `ctrl_seq = rb_snd_nxt`（`:1264`）⇒ **seq 下漂**到下界 ⇒ 对端可能判 spurious FIN，而本文件自己逐字警告过（`:2003-2007`）："再推同 seq 条目就是 spurious FIN (seq 落在对端窗口外, **可诱发 RST**)"。⇒ 必须在排空拍把 `snd_nxt` 恢复到 `retx_hi`（复用 `upd_wr_rew`/`upd_val = retx_hi` 这条既有通道）。
  - **B-6（`$onehot0` 三写源纪律）** ⇒ 新写源 `ring_restore ⊆ ring_eval ⊆ (rx_idle ∧ retx_active ∧ !svc ∧ !ack_pend_r)`，与 `upd_wr_data`（RX_FIN）/`upd_wr_ctrl`（`start_ack` ⊆ rx_idle ∧ ack_pend_r）/`svc_rewind`（⊆ `!retx_active`）**三对结构性互斥**（论证与 `:621-623` 的 `replay_jump` 逐字同型）✔
- **代价**：`+16×32 + 32 = +544 FF`（全 DP 域）+ 1 个共享的 32 位 wrap-safe 比较/mux（≈70 LUT，**不需要**——见 §3.2 的写法：活帧高水位本身单调，不需要 max） + 16 路写解码（≈16–30 LUT）⇒ **≈ +544 FF / +100–200 LUT / 0 BRAM**。**不新增长锥**：`ring_delta` 的锥形与今日**同型同深**（只把操作数从 `retx_hi` 换成同类的寄存器 `ring_hi`）✔
- **风险**：① 漂移 = 0 时逐位不动（§7 的等价证据）；② 新增写源进 TCB 写口（DP 域）⇒ 时序由一次构建收口；③ `whi_r` 的**首次建立**依赖"活帧推进写"（`upd_wr_data`），若某连接从无数据就起会话 ⇒ `whi_r = 0` ⇒ 由既有 `ring_ovf` 判为"无数据可重放" ⇒ 安全（论证见 §3.4）。

### 候选 C：**16 位高水位**（省 256 FF）

- 核：与文件既有的**32 位化纪律**冲突（`:234-240` 逐字："窗帽与在飞差均 32 位计算, 全 4GB 序列空间回绕正确 … 无 16 位化边角"）；且现役帽下最坏在飞 = `(0xF000−1) + 4095 = 65534`，**距 2^16 只剩 2 B**，而该值"**本轮未重算**"（`rtl/retx_ram.v:8-12` 逐字登记）⇒ 余量未证。
- 代价：省 256 FF ⇒ **不推荐**（登记为"要省就省一半"的备选，启用前必须先把最坏在飞重算 + 记一条门）。

### 候选 D：**只在装载拍夹 + 不动收尾**（= B 的第一件）

- 核 = §2-B5：`snd_nxt` 会停在数据端 ⇒ 后续控制帧 seq 下漂 ⇒ **spurious FIN 风险** ⇒ **单独不可行**（D ⊂ B，且缺件正是不安全的那件）。

### 候选 E：**源头分离**（把控制帧的 +1 从 `snd_nxt` 分离 / 给 TCB 加"控制 seq 偏移"）

- 核：**不可行**。`snd_nxt` 是 TCB 的**唯一 seq 状态源**（本仓设计决策 §3 逐字："**TCB 唯一状态源归属 fast 数据面**"），消费者至少 5 处：`tcp_rx` 的 `ack_ok`/`dup_ack`（`tcp_rx.v:321/338`）、`tcb` 的窗口门（`tcb.v:142-148` 的注册比较）、`tcp_tx_frame` 的 `fin_push` 门（`:954` `rb_snd_nxt == rb_snd_una`）、`app_ctrl` 的 in-flight、wrapper 快照。⇒ 分离 = 每个消费者都要"合成"⇒ **面爆炸 + 破坏合同**；且会把 P4d 修复（`:306-320`）重新打开。

### 候选 F（对照）：**不动 RTL，改判据**（把幽灵位置豁免）

- 核：**不可接受** —— 线上仍发错字节；且把真缺陷洗进"已知偏差"，违反本工程"判据不得为空 / 不许把红解释成判据问题"的纪律（闸 4 的三条 FAIL 处置先例已把这条钉死）。

### ⭐ 明确回答：**要不要动 `:636`？⇒ 不动。**

`rb_snd_nxt + 32'd1` 是"控制帧占一个序号"的**唯一落点**；卡它的后果（逐条【事实】）：
1. 对端 ACK 语义错位：FIN/SYN 的 seq 必须 = "最后一个数据字节 + 1"之后按序，不动它 ⇒ 对端 `rcv_nxt` 与板 `snd_nxt` 永久差 1（`tcp_rx.v:306-320` 的死锁族会**换形态复活**）。
2. `fin_push` 的"无在飞数据"门（OVL `:952-954` `(rb_snd_nxt == rb_snd_una)`）失效 ⇒ 有在飞时也会排队 FIN ⇒ 正是注释 `:56-58` 点名的"把 FIN 的 seq 当 ring 数据重放"。
3. `tcb` 的 in-flight（`snd_nxt − snd_una`）与窗口门口径错 ⇒ 窗口门多放/少放帧。
⇒ **本刀的修法方向是"让重放侧不再把 seq 空间整段当数据"，不是"让 `snd_nxt` 不占号"。**

---

## §3 修法的精确形式（候选 B；两分支各一份，逐处 `file:line` + 改前/改后逐字）

> 命名：`whi_r`（ring **w**ritten **hi**gh water）· `ring_hi`（本会话环上界）· `ring_ovf`（环侧越顶）· `ring_restore`（收尾恢复写）。
> 三个名字已核：`grep -rn "whi_r\|whv_r\|ring_hi\|dend_r\|wr_hi_r" rtl/ board/ tb/` ⇒ **0 命中**，无冲突【事实】。
> 位宽/复位/cfg_up 惯例 = 照抄同文件既有的**每连接数组**（`rto_timer[0:15]` / `fin_seq_r[0:15]` / `epoch[0:15]`：`reg [W-1:0] x [0:15];` + 复位 `for (ri…)` 循环 + `cfg_up` 块里 `x[cfg_up_id] <= 0;`）【事实】。

### 3.1 新增信号清单（位宽 / 复位 / cfg_up 清理）

| 信号 | 位宽 | 复位 | `cfg_up` | 语义（一句话） |
|---|---|---|---|---|
| `whi_r` | `reg [31:0] [0:15]` | `for (ri) whi_r[ri] <= 32'd0;` | `whi_r[cfg_up_id] <= 32'd0;` | 该连接**环里真写出过**的最高 seq（= 数据端） |
| `ring_hi` | `reg [31:0]` | `32'd0` | —— | 本会话的环重放上界（`svc` 拍锁存） |
| `ring_ovf` | `wire` | —— | —— | `rb_snd_nxt` 越过 `ring_hi`（与 `retx_ovf` **同型式**） |
| `ring_restore` | `wire` | —— | —— | 排空拍且 `snd_nxt < retx_hi` ⇒ 收尾恢复写 |

### 3.2 OVL 支（`ifdef TCP_TX_OVL`，`:303`-`:1516`）逐处

**(1) 声明**（锚 = `:484` `reg  [31:0] retx_hi;` 之后）：
```
    reg  [31:0] retx_hi;
+   // ⭐ RETXHI-GHOST (P7B_RETXHI_GHOST_DESIGN.md): 环已写高水位 = 该连接"数据端" seq。
+   //   只在**活帧**推进写 (upd_wr_data && !retx_active) 时更新; 重放帧的推进写不算
+   //   (它写回的是同一批已写过/待重放的字节, 抬高或**压低**高水位都是错的)。
+   //   活帧推进写在无会话时严格单调 ⇒ **普通写即可, 不需要 wrap-safe max**。
+   reg  [31:0] whi_r [0:15];
+   reg  [31:0] ring_hi;      // 本会话环重放上界 (svc 拍锁存 = whi_r[svc_id])
```

**(2) 复位**（锚 = `:1021-1024` 的 `retx_active/retx_id_r/retx_hi/...` 段）：
```
            retx_active <= 0; retx_id_r <= 0; retx_hi <= 0; scan_id <= 0;
+           ring_hi <= 32'd0;
```
（照 `for (ri = 0; ri < 16; ri = ri + 1)` 循环 `:1040-1047` 补：）
```
                fin_seq_r[ri] <= 32'd0;
+               whi_r[ri]     <= 32'd0;
```

**(3) `cfg_up` 清理**（锚 = `:1050-1064` 的 `if (cfg_up) begin … end`，与 `fin_sent_r[cfg_up_id]` 同区）：
```
                fin_sent_r[cfg_up_id]    <= 1'b0;
+               whi_r[cfg_up_id]         <= 32'd0;   // ⭐ 新会话重基 ⇒ 高水位清零
```

**(4) 活帧推进写 ⇒ 刷高水位**（锚 = `:1069-1077` 的 `retx_ovf_p` / `stat_winstall` 统计区，同一 always 块内）：
```
            retx_ovf_p <= retx_ovf && retx_active;
+           // ⭐ RETXHI-GHOST: 数据端高水位 (活帧专有; 与同拍写进 TCB 的推进值同源同拍)
+           if (upd_wr_data && !retx_active)
+               whi_r[f_conn[rx_bank]] <= f_seq[rx_bank] + {20'b0, f_plen[rx_bank]};
```
⭐ **这一行"为什么普通写就够、且为什么 `!retx_active` 恰好等价于'这一笔是活帧'"—— 两条支撑（都必须成立，逐条给源码依据）**：
- **(i) 重放帧的推进写必定发生在会话中**（因此被 `!retx_active` 挡掉）：重放帧走 `RX_RING → RX_FIN`，其 `upd_wr_data` 落在 RX_FIN 首拍（`:625`）；会话的收尾（`retx_active <= 0`，`:1172/1176/1179`）**只**发生在 `ring_eval` 的排空支（`:1167-1181`），而排空支的进入条件是 `ring_delta == 0` —— 它必然**晚于**那最后一帧的 RX_FIN 推进写。⇒ 任一重放帧的推进写拍上 `retx_active = 1` ✔
- **(ii) 活帧的推进写必定发生在 `retx_active = 0` 时**（因此普通写 = wrap-safe max）：会话期间 `start_data`（`:666-669`）含 `!ring_eval` 且含 `!bank_rdy[rx_bank]`，而 `ring_eval = rx_idle && !ack_pend_r && retx_active && !svc && !rx_flush && !bank_rdy[rx_bank]`（`:566-567`）、`svc` 含 `!retx_active`（`:562`）⇒ 枚举四种情形（`!rx_idle` / `rx_flush` / `ack_pend_r` / 三者皆否 ⇒ `ring_eval = 1`）**全部使 `start_data = 0`** ⇒ **会话期间不可能起活帧** ⇒ 活帧的 `upd_wr_data` 必在 `!retx_active` 拍 ✔
- ⇒ 活帧的 `f_seq+f_plen` 在无会话期间**单调不减**（`snd_nxt` 在会话外只被数据写与 `+1` 推高）⇒ **普通写 = 高水位**（不需要比较器）✔
- ⚠️ **一个必须实施轮复核的前置**（写进实施清单）：`snd_nxt` 的写者清单 = 本模块的 `upd_*`（`:630-637`）+ 慢路径建连重基（`scfg`，`upd_sel=1`）。我已核过 `app_ctrl` 的流控通道**只**写 `upd_sel=3`（rcv_wnd）与 `5`（state）（`rtl/app_ctrl.v:717-718` + `rtl/tcb.v:5` 的编码表），**不会**在会话外把 `snd_nxt` 往低写 ⇒ 单调性成立。⛔ 若将来有人加一条"会话外的 `snd_nxt` 重基/纠偏写"，本行**必须**升级为 wrap-safe max（+1 个 32 位比较器，`whi_r` 的清理点改为"重基拍"）。

**(5) 会话装载拍锁存**（锚 = `:1131-1135`）：
```
                    retx_hi <= (fin_sent_r[svc_id] && svc_rewind) ? fin_seq_r[svc_id] :
                               rb_snd_nxt;
+                   ring_hi <= whi_r[svc_id];    // ⭐ 环上界 = 数据端 (与 retx_hi 分离)
                    if (fin_sent_r[svc_id]) fin_retx_pend[svc_id] <= 1'b1;
```

**(6) 环侧三处**（锚 = `:760` / `:765-768` / `:772-773`）：
```
-    wire [31:0] ring_delta = retx_hi - rb_snd_nxt;
+    wire [31:0] ring_delta = ring_hi - rb_snd_nxt;          // ⭐ 改: 环上界与 ack 上界分离
+    // ⭐ RETXHI-GHOST: 环侧越顶 (与 retx_ovf **同型式、不同对象**; retx_ovf 一字不动)
+    wire        ring_ovf   = (rb_snd_nxt != ring_hi) &&
+                             ((rb_snd_nxt - ring_hi) < 32'h8000_0000);
     wire        retx_ovf = (rb_snd_nxt != retx_hi) &&        // ← 一字不动 (见 §3.5)
                            ((rb_snd_nxt - retx_hi) < 32'h8000_0000);
-    wire        ring_start = ring_eval && (ring_delta != 32'd0) && !retx_ovf &&
+    wire        ring_start = ring_eval && (ring_delta != 32'd0) && !ring_ovf &&
                              scan_estab && ((replay_left != 4'd0) || replay_full);
-    assign      replay_jump = ring_eval && (ring_delta != 32'd0) && !retx_ovf &&
+    assign      replay_jump = ring_eval && (ring_delta != 32'd0) && !ring_ovf &&
                               scan_estab && (replay_left == 4'd0) && !replay_full;
+    // ⭐ RETXHI-GHOST: 排空拍恢复写 —— 环内数据已发完而 ack 上界还在更高处 (漂移区)
+    //   ⇒ 把 snd_nxt 恢复到 retx_hi。为什么不恢复不行: 随后的控制帧取 ctrl_seq =
+    //   rb_snd_nxt (:1264) ⇒ seq 下漂 ⇒ spurious FIN (本文件 :2003-2007 逐字警告)。
+    //   只增不减: 越顶 (snd_nxt > retx_hi) 时本项恒 0, 不夺 F1 的既有语义。
+    wire        ring_restore = ring_eval && !ring_ovf && scan_estab &&
+                               (ring_delta == 32'd0) &&
+                               (rb_snd_nxt != retx_hi) &&
+                               ((retx_hi - rb_snd_nxt) < 32'h8000_0000);
```

**(7) 写源 mux**（锚 = `:624` 前置声明 / `:629` / `:635-637`）：
```
     wire        replay_jump;
+    wire        ring_restore;      // ⭐ 前置声明 (与 replay_jump 同惯例, 见 :620-624 注释)
...
-    wire        upd_wr_rew  = svc_rewind || replay_jump;
+    wire        upd_wr_rew  = svc_rewind || replay_jump || ring_restore;
...
-                          (upd_wr_ctrl ? (rb_snd_nxt + 32'd1) :
-                           (replay_jump ? retx_hi : rb_snd_una));
+                          (upd_wr_ctrl ? (rb_snd_nxt + 32'd1) :
+                           ((replay_jump || ring_restore) ? retx_hi : rb_snd_una));
```

**(8) 排空支无需改**（`if (ring_start) … else <排空>`，`:1167-1181`）：`ring_restore` 与排空发生在**同拍**（`ring_delta == 0`）⇒ TCB 写 `snd_nxt <= retx_hi` 与 `retx_active <= 1'b0` 同沿落地 ⇒ 下一拍 `ack_hi` 回到 `ra_snd_nxt = retx_hi` ✓（与 RETXFIX 注释 `:265-267` 的"跳写必要性"同源）。

### 3.3 else 支（`else`，`:1517`-`:2499`）逐处

⚠️ **本支没有 `replay_jump` / `replay_left` / `replay_full`**（我 grep 核过：三者只在 `:772/:1135/:1136` 出现，全在 OVL 支）⇒ 本支的镜像要多加**一个写源**（不是"改条件"）。

**(1) 声明**（锚 = `:1552` `reg  [31:0] retx_hi;` 附近）：同 §3.2-(1) 三行（注释里把"乒乓/`upd_wr_data`"的话改成"活帧推进写 = `upd_wr && is_data_r`"）。

**(2) 复位**（锚 = `:2073` 与 `for (ri…)` 循环）：同 §3.2-(2)。

**(3) `cfg_up` 清理**（锚 = `:2091-2100` 的 `if (cfg_up) begin …`）：
```
                fin_sent_r[cfg_up_id]    <= 1'b0;
+               whi_r[cfg_up_id]         <= 32'd0;
```

**(4) 活帧推进写 ⇒ 刷高水位**：本支的推进写在 **S_DONE**（`assign upd_wr = ((state == S_DONE) && (is_data_r || …)) || svc_rewind;`，`:1787-1788`），且 **ring 帧也置 `is_data_r = 1'b1`**（`:2179`）⇒ `!retx_active` 这道门在本支**承担"区分活帧/重放帧"** 的职责（与 OVL 支同口径、但更明显）：
```
+           // ⭐ RETXHI-GHOST: 数据端高水位 (仅活帧; ring 重放帧 is_data_r 亦为 1 ⇒ 必须门掉)
+           if (upd_wr && is_data_r && !retx_active)
+               whi_r[cur_id] <= seq_r + {20'b0, plen_r};
```
- **对偶的两条支撑（本支同样成立，逐条给源码依据）**：(i) 重放帧的 S_DONE 推进写在会话中（ring 会话在 `:2234-2242` 的排空支才 `retx_active <= 0`，晚于末帧 S_DONE）⇒ `retx_active = 1` ⇒ 被挡 ✔；(ii) 会话期不可能起活帧：`start_data`（`:1744-1746`）含 `!ring_eval`，而本支 `ring_eval`（`:1614-1615`）在 `state==S_IDLE && !ack_pend_r && !flush_pend` 时**恒为 1**（`svc` 在 `retx_active` 期恒 0，`:1611-1612`）⇒ 其余情形被 `state/ack_pend_r/flush_pend` 各自挡住 ⇒ `start_data = 0` ✔ ⇒ 活帧写必在 `!retx_active` 拍、且其 `seq_r+plen_r` 单调 ⇒ **普通写 = 高水位** ✔
（落位：实施轮放在 `always @(posedge clk…)` 第二段（`else begin`）里与其它每连接记账同区；本行取的是 `:1792` 那条表达式的**数据支**，逐字 `seq_r + {20'b0, plen_r}`。）

**(5) 会话装载拍锁存**（锚 = `:2162-2163`）：`+ ring_hi <= whi_r[svc_id];`

**(6) 环侧三处**（锚 = `:1631` / `:1638-1641`）：同 §3.2-(6) 的 `ring_delta`/`ring_ovf`/`ring_start` 三处改法（本支 `ring_start` 另含 `scan_estab`，一字不动）；本支**无** `replay_jump`、`ring_restore` 是**新写源**（未越顶门：本支的排空只要 `ring_delta == 0` 触发 ⇒ **必须补 `!ring_ovf`** 以免越顶拍误触发）。

**(7) 写源 mux**（锚 = `:1787-1792`）：
```
-    assign upd_wr  = ((state == S_DONE) && (is_data_r || is_syn_r || is_fin_r ||
-                      is_rst_r) && m_axis_tvalid && m_axis_tready) || svc_rewind;
-    assign upd_id  = svc_rewind ? svc_id : cur_id;
+    assign upd_wr  = ((state == S_DONE) && (is_data_r || is_syn_r || is_fin_r ||
+                      is_rst_r) && m_axis_tvalid && m_axis_tready) || svc_rewind ||
+                     ring_restore;
+    assign upd_id  = ring_restore ? retx_id_r : (svc_rewind ? svc_id : cur_id);
     assign upd_sel = 3'd1;
-    assign upd_val = svc_rewind ? rb_snd_una :
-                     seq_r + (is_data_r ? {20'b0, plen_r} : 32'd1);
+    assign upd_val = ring_restore ? retx_hi :
+                     (svc_rewind ? rb_snd_una :
+                      seq_r + (is_data_r ? {20'b0, plen_r} : 32'd1));
```
⚠️ 本支的 `$onehot0` 三源纪律 = 现在变**四源**：`ring_restore ⊆ ring_eval ⊆ (state == S_IDLE) && !ack_pend_r && retx_active && !svc && !flush_pend`（`:1614-1615`）；`svc_rewind ⊆ svc`（`svc ⊆ !retx_active`）；S_DONE 写 ⊆ `state == S_DONE` ⇒ **两两互斥**（S_IDLE vs S_DONE 是状态互斥；`retx_active` 与 `svc` 互斥）⇒ 不变式保持 ✔【事实·由状态定义直推】

### 3.4 为什么 `whi_r = 0`（本连接还没写过数据）是**安全的**

`ring_hi = whi_r[svc_id] = 0` ⇒ `ring_delta = 0 − rb_snd_nxt`（32 位回绕）= `2^32 − rb_snd_nxt`：
- `ring_ovf = (rb_snd_nxt != 0) && ((rb_snd_nxt − 0) < 2^31)` ⇒ 只要 `rb_snd_nxt < 2^31` 就**为真** ⇒ `ring_start = 0`、`replay_jump = 0`、`ring_restore = 0` ⇒ 会话走排空支收尾 ⇒ **"没有数据可重放"这一判断是对的** ✔
- ⚠️ **结构性盲点（必须登记）**：`rb_snd_nxt ≥ 2^31` 且 `whi_r = 0` ⇒ `ring_ovf = 0` 而 `ring_delta` 是个"看似正的大数" ⇒ `ring_start = 1` ⇒ 会拿 `plen_preset = 1460` 乱重放。**可达性论证**：`snd_nxt ≥ 2^31` 意味着该连接**发过 ≥ 2 GB 数据**，而每个数据帧首字节都会刷 `whi_r` ⇒ `whi_r = 0` 与 `snd_nxt ≥ 2^31` **结构性不相容**（除非全部由 2^31 笔控制帧 +1 推上去 —— 物理不可达）⇒ **判为不可达**【推断·需仿真】。
  （我**不**用"再多一个 valid 位"来堵它：见 §9-U3。）

### 3.5 三条**不许动**的既有口径（否则打红既有判据 / 夺既有语义）

1. **`retx_ovf` 保持指向 `retx_hi`**：TB 的 `e_f1_cyc`（`tb:2025` 生成条件 `d_ring_act && d_retx_ovf`；`:2035` 计数；`:2230` 在 `tot_red` 和式内 = **硬红**）与 `e_f1_ring`（`:2306`）都按 `u_dut.retx_ovf` 取值 ⇒ 改它的口径 = 改判据对象。**本刀不动它**；环侧另立 `ring_ovf` ✔
2. **`stat_retx_wrap`（F1 计数器）不动**：它数的是"会话期 `snd_nxt` 越过 `retx_hi`"（`:1068-1071`）⇒ 口径不变（本刀不碰 `retx_hi`）✔
3. **`o_retx_hi` / `o_retx_active` / `o_retx_id`（`:984-985`、`:982`、`:983`）不动** ⇒ 快照 **W57/W58** 与 `tcp_rx.ack_hi` 逐位不变 ✔

### 3.6 ⛔ 本刀**不**做的事（防范围蔓延）

- 不碰 `upd_wr_ctrl` 的 `+1`（§2 末）、不碰 `fin_seq_r` 支路的表达式、不碰 `ctrl_adv_inflight`、不碰 persist 的任何一处（`:299/:300/:301` 与 OVL 内的 persist 体）、不碰 `RETX_SPAN`/`replay_full` 的语义、不新增/不改**任何**快照字。

---

## §4 ⭐ 分支问题（blocking 级 —— 上一刀在这里栽过）

### 4.1 本文件里两种先例（逐条回源码/回件核）

| 先例 | 事实（逐字） | 与本刀的关系 |
|---|---|---|
| **镜像先例** | 构建 E/F 的 **W66/W67/W69**：`stat_winstall_ev` 两分支各一份（OVL `:721-725`；else `:1752-1754`），且 else 处注释逐字"**与 OVL 分支逐条同款**…完整语义/边界 = OVL 分支处那段注释(**权威**)"（`:1747-1751`）；`win_cap_bind/stat_winstall_cap_ev` 同样两份（`:735-736` / `:1756-1757`） | **同语义逻辑 → 两分支各一份** |
| **镜像先例（正确性）** | **F1 修复**（`P7B_STAGEC_TX.md:24` 逐字）："控制帧帧首预留的 `+1` 可让 `rb_snd_nxt` **越过** `retx_hi` ⇒ `ring_delta` 32 位下溢…**两分支同修**（默认分支也中招 —— 审查 arm D 实测）" ⇒ 源码面 = `retx_ovf` 在 `:765-766` **与** `:1638-1639` 各一份 | ⭐ **最贴近的先例**：同为"回卷/重放区间"族的**真缺陷**，处理 = **无条件 + 两分支** |
| **不镜像先例** | persist（`:287-290` 逐字）："逻辑体全部落在 `ifdef TCP_TX_OVL` 支内（**D-8 定"不镜像"**：默认支是另一套 FSM，**双实现 = 语义双支漂移**）"；r6 的 `ack_seen` 门（`:548-557` 逐字"默认分支(宏外, 文件后半支)不生效: `acks_ok` 恒 1 ⇒ 表达式逐位不变"） | 它们的理由是"**新特性/新门**，默认支不需要"⇒ **不适用于本刀**（本刀修的是两分支**共有**的既有机制） |

### 4.2 ⭐ 本刀表态：**两支都改（镜像）、无条件、不设参数**

- 依据三条：(i) **F1 先例**（同族真缺陷，两分支同修）；(ii) 机制在 else 支**逐处同款**（§1.2 的四行我逐行核过 —— 这不是"可能"，是源码事实）；(iii) 不镜像 ⇒ **语义双支漂移**（persist D-8 反对的正是这个）。
- ⚠️ **代价不对称（必须写清）**：else 支**没有** `replay_jump/upd_wr_rew` 这套写源结构（§3.3）⇒ 镜像 = **给该支加第 4 个 TCB 写源**（OVL 支只是"改一个条件"）⇒ **else 支的改动面更大**。

### 4.3 ⭐ 本缺陷在**默认支**里存不存在 / 可不可达

- **存不存在** ⇒ **存在（源码级）**：`:1791-1792` 的 `+1`、`:2162-2163` 的继承、`:1631/:1638` 的重放范围，三处逐字同款【事实】。
- **可不可达（板/默认配置）** ⇒ **结构性不可达**【事实】：
  - 板上**唯一**的 `tcp_tx_frame` 例化（`board/wrapper_p4.v:2150`）拿到的 `tx_ack_syn/ack_fin/ack_rst = 1'b0`（`:2101-2103`，**在 `ifdef APP_MODE` 之外、无条件**）；
  - 非 APP_MODE（= 默认构建）下 `tx_fin_req = tx_rst_req = 16'h0`（`:2124-2125`）⇒ 本模块**没有任何控制帧源** ⇒ `upd_wr_ctrl` 恒 0 ⇒ `drift ≡ 0` ⇒ **else 支在本板的默认配置里写不出幽灵**。
  - OVL 支（**板构建编的那一支**，`board/build_p7b_ku5p.tcl:153` `TCP_TX_OVL=1`）拿到的是 `APP_MODE` 下的 `fin_req/rst_req`（`:2112-2115`）⇒ **板上唯一的漂移源 = FIN/RST 推**（FIN 重推 / abort RST）⇒ 缺陷**可达**（已由 TB 复现）。
- ⚠️ **未定**：矩阵的 chain 族 TB（`tb/tb_p4_chain.v`）是否在 else 支注入控制帧 —— 我**未**逐个读 TB 激励（见 §9-U4）。这决定"镜像是否有门可测"。

### 4.4 ⭐ 常驻 P4 矩阵对本刀覆盖多少（逐字核）

- **配置面**：矩阵 **17 门**（`sim/p4gates/run_matrix_p4dfix.bat:184-211` 的 `call :gate` 行）**全部** `-d APP_MODE`，**不含** `TCP_TX_OVL`（逐字：`:206` "**CONFIG COVERAGE = `-d APP_MODE` ONLY (single-domain / legacy branch)**"、"It does NOT cover the board wrapper configuration (DP_156MHZ), does not compile PCIE_OBS / P7B_10G / UDP_TX_OVL, and **with TCP_TX_OVL off the r6 tcp_tx_frame `ack_seen` start gate is NOT in it either**"）。
- **编到 `rtl/tcp_tx_frame.v` 的门**：（我核过源码清单）`chain_src.f` + `p5wrapper_src.f` 两个文件表都含 `rtl/tcp_tx_frame.v` ⇒ **12 条 chain 族门（chain/burst200/trunc50/trunc100/halfdrop/txdrop50/gate4096/dupstorm/pcackoob/vlanchain/vlanburst/stallgate）+ `p5_wrapper` = 13 门**覆盖它。
- ⇒ **结论（三条，必须写清）**：
  1. **矩阵覆盖的是 `else` 支**（无 `TCP_TX_OVL`）；
  2. **OVL 支（= 板构建那一支）在常驻矩阵里 0 覆盖** ⇒ 若只改 OVL 支，则**本刀的改动面完全在常驻回归网之外**；
  3. **镜像是唯一能让本刀的改动落进常驻矩阵的选法**；⚠️ 但**矩阵的 13 门不测幽灵**（它们没有"FIN/RST 后重放"的激励，且默认配置下 `drift ≡ 0`）⇒ **"矩阵绿"不是本刀的判据**，只是"没把别的东西改坏"的回归网。**判据面 = 臂 S/T（§5）**。
- ⚠️ 另：**"改 RTL" 与 "在跑回归" 互斥**（全局 #57）⇒ 本刀实施前必须先确认矩阵没在跑，或改完重跑整轮。

---

## §5 观测量 / 判据 / 门 + 负对照

### 5.1 观测量：**复用既有，不加新快照字**

⛔ **不加新字**：本工程"加一个重要快照字"要走整条读侧同步（`P7B_BIZ_WINDOW.md` §2 的"五处同改" + 构建 F 轮实测 **20 文件 / 56 处**）⇒ **本刀零新增字**。可用既有字：
- **W55** = `tcp_tx_frame.stat_retx`（回卷会话**次数**，`P7B_BIZ_WINDOW.md` §1 逐字）⇒ **非空见证**（"本窗真的发生过重放会话"）。
- **W57** = `tcp_tx_frame.o_retx_hi`（回卷重放上界，**只在 `retx_active=1` 时有效**，同表逐字口径）· **W58** = `o_retx_active`。
- **W59/W60**（两个适配器 ovf，恒 0 守卫）· **W5/W43**（时基与 tx 拍钟，速率口径）· 对端侧 = NIC/内核计数 + sink 的逐字节校验。
- ⚠️ **本刀不改 W57 的语义**（§3.5-3）⇒ W57/W58 的读法逐字不变。

### 5.2 判据（**主判据 = 既有 J3/J4**，零 TB 改动）

- **J3（载荷逐字节）= `e_payload`**（生成处 `tb/tb_tcp_tx_ovl.v:800-806`；**已在 `tot_red` 白名单和式内** `:2228`）。
- **J4（seq 连续性）= `e_seqcont`**（生成处 `tb:787-798`；**同在和式内**）。
- **改前必红（在案）**：臂 S `payload=3 seqcont=1`（`ev/gate4_stdout.txt:650`）；臂 T `payload=14`（`ev/orT_oracle_v5_xs.log:3465`）⇒ **"能演示改之前会红"这条已经满足**，无需新造。
- **改后必须 = 0**（S 与 T 两臂都跑；T 臂是 persist-关的负对照 ⇒ 它也必须绿，否则说明修法与 persist 有未知耦合）。

### 5.3 ⭐ 判据合流入口（**上一刀踩过的坑，逐字写清**）

`tb/tb_tcp_tx_ovl.v` 的**末行判决唯一入口** = `task summary_and_exit` 里的 `tot_red`，而它的**第一项是白名单式和**（`:2228-2232` 逐字）：
```
            tot_red = e_parse + e_csum + e_payload + e_seqcont + e_seqmono + e_ctrl +
                      e_ctrl_to + e_onehot + e_pendbusy + e_replay + e_replay_stuck +
                      e_ovf + e_ackf + e_f1_ring + e_j9 + e_c6 + e_f1_delta + e_f1_cyc +
                      e_replay_span + e_replay_jump + e_c2_resv +
                      e_ag_block + e_ag_resume;
```
⇒ **若加新计数器（如 `e_ghost`），必须同时改三处**：(a) 声明（`:189`/`:192` 那一带）、(b) 检测（`:790` 一带的帧检查块）、(c) **本和式 + `:2267` 的 REDS 显示行**。**只做 (a)(b) ⇒ 再红也不影响末行**（这正是上一刀查到的坑）。
⇒ **本刀的建议**：**先不加新计数器**（J3/J4 已经够且有在案红）；若 TL 要一条"直指机制"的判据，才按上面三处一起加（判据候选见 §5.4-②）。

### 5.4 建议的门 + 负对照

1. **门 = 既有 `author_gate`（`sim/p7b_stagec_tx_regress/author_gate`）的 S/T 两臂**（`ev/rerun_oracle.bat` 逐字给了两臂 defs）⇒ 判据 = **S 臂 `payload=0 && seqcont=0`、T 臂 `payload=0`**，且**其余全部计数逐字不变**（`n_frames`/`stat_*`/`wsrc`/`T8` 数字 —— 见 §7）。
   - **它是非常驻门** ⇒ 建议**同批把它登记进常驻矩阵或至少写进 `P7B_OPEN_ITEMS.md`**（否则下一个人重跑不到）。⚠️ 我不在本件里改门（边界）。
2. （可选）**定向判据 `e_ghost`**：判据语义 = "任何被发出的数据帧，其 `[fseq, fseq+plen)` 不得越过该连接已写高水位（`+7` 容差用于 8 字节 beat 的尾字）"。
   - 数据源已在 TB 侧可得：`u_dut.w_tap_seq`/`w_n`（已由 oracle 探针消费，`patch_oracle_v6.py:43-48`）+ 线上 `fseq/plen` 分类器 ⇒ **不需要改 RTL**。
   - ⚠️ 落地必须走 §5.3 的三处。
3. **负对照（三条，缺一不可）**：
   - **N-1（改前臂）**：`git stash`/worktree 版跑同一门 ⇒ **必红**（在案：S `payload=3 seqcont=1`）；⛔ **必须与"改后"同会话同配置**（否则是跨会话对比）。
   - **N-2（天然负对照 = drift 0 的会话）**：本刀在 `whi_r == retx_hi` 时**逐位可折回原式**（§7.1）⇒ 用"该跑存在 drift=0 的会话"作正控，用"该跑存在 drift>0 的会话"作非空见证（否则判据是**空判据**：`ΔW55 = 0` 或 `drift ≡ 0` 的跑**绿了也不能算通过**）。
   - **N-3（变异门）**：把 `ring_hi <= whi_r[svc_id]` 改成 `ring_hi <= 32'hFFFF_FFFF`（或把 `ring_start` 的 `!ring_ovf` 去掉）⇒ 门**必须变红**（证明判据有牙）。⚠️ 变异器在这文件上会**撞 CRLF 锚点问题**（`P7B_OPEN_ITEMS.md` §4 已登记 G3 门跑不通 = CRLF 2040 个 + 锚点陈旧）⇒ 变异要按 `\r\n` 写锚点（或先做 `.gitattributes` 归一化，见 §9-U5）。

### 5.5 ⭐ 上一刀 S 臂那 3 条 payload + 1 条 seqcont 红，本刀修完后应不应该变绿？

**应该变绿。** 依据（逐条可复算）：

| # | 红 | 折算流偏移 | 与幽灵的关系 | 修后预测 |
|---|---|---|---|---|
| 1 | `payload conn=0 seq=000de510 off=0` | 848,912 = `wrhi`（RD-AHEAD 拍值） | 该帧 `drift = 1`，**只有首字节**是幽灵（同圈命中 15/16，`q1_*` 逐字） | 两种可能**都绿**：① 该拍 `whi_r = 848912`（幽灵位未被后续活帧覆盖）⇒ `ring_delta = 0` ⇒ **该帧根本不生成**；② `whi_r > 848912` ⇒ 帧生成但首字节改读**本圈**地址 ⇒ 内容 = fb(848912) ⇒ 内容校验过 |
| 2 | `seq partial conn=1 seq=0004e59c plen=29 exp=0004e5a4` | 帧弧 = [246428, 246457) | 尾段 21 B 是幽灵 ⇒ 越过 TB 前沿 21 B | 修后 `plen = ring_delta = 8` ⇒ 帧弧 = [246428, 246436) = **恰好接上前沿** ⇒ **绿** |
| 3 | `payload conn=1 seq=0004e59c off=8` | 246,436 = 幽灵起点 | 同上帧的 `off≥8` 段 | 同 2 ⇒ 该帧不再含幽灵 ⇒ **绿** |
| 4 | `payload conn=1 seq=0004e5a4 off=0` | 246,436 = 幽灵起点 | plen=21 的帧 = 整段幽灵 | 该帧不再生成（`ring_delta = 0` ⇒ 无帧）⇒ **绿** |

⚠️ **两点保留**：
- **T 臂 14 条 payload 只有 3 条落盘**（打印上限）⇒ "T 臂全绿"**属【推断】**（三条落盘的签名 = `conn=0 seq=00140c02`、k=−1、`q1` 已复算 ⇒ 同源）；
- 若修后仍剩红，**必须先看它是不是"另一条独立成因"**（本件 §1 只覆盖幽灵族）—— 不许先改判据。

---

## §6 板级怎么测（零窗造法 / 台架翻面 / 判据不许钉在"先大窗再塌"上）

### 6.1 台架现状（逐字回件）

- **sink 已翻面**（`_proj_10g/notes/p7b_sinkfix_20261010/REPORT.md:13` 逐字）：`SO_RCVBUF` 的落点已移到 `connect()` **之前**（默认 = 修复后行为），旧行为（先通告大窗、随后才塌）由开关 **`--rcvbuf-after-connect`** 逐字复现（`:70/:79`），并打见证行 `SINK_RCVBUF_ORDER RCVBUF_ORDER=before_connect|after_connect_LEGACY`（`:85-87`）。
- ⇒ ⛔ **凡要造历史那种小窗构型，必须显式带 `--rcvbuf-after-connect`**（否则默认臂会先通告大窗 ⇒ 板的首突发被对端自己授权 ⇒ 小窗被冲掉）。
- ⛔ **不许把判据建立在"先大窗再塌"上**（真 Linux 栈实测**未再现**，见同件 §4）。

### 6.2 ⭐ 三条构型（按"先证明会出幽灵"到"完整判据"排序）

**S-0（零构建 · **首步**）**：**证明"板上到底会不会出幽灵"**
- 构型：`p7b_tcp_sink --check lane8 --rcvbuf 2920 --rcvbuf-after-connect --conns 6 --seconds 60`（**显式**旧落点，与 sink 默认无关；数字沿用同件 §5 给出的"正控场景"逐字例子）。
- 观察（不需要新字）：`ΔW55`（会话数 > 0 = 非空见证）· `ΔW57/ΔW58`（`retx_hi` 有效拍）· **sink 的逐字节校验计数器**（`mism_bytes` / `first_mismatch`）。
- 判决口径：`mism_bytes == 0` ⇒ **未观察到**（**不许**写成"板上不存在"：可能只是 `drift = 0`，见 §1.4-不会-B/C）。
- ⭐ **这一步的优先级最高**：它把"板级有没有这条病"从推断降为观测，代价 = 一次现有的台架跑（零构建）。

**S-1（主判据构型 · 关闭路径 + 慢读对端）**
- 目的：让**重放区间越过高水位**。
- 必要条件（§1.4-会）：该连接**数据之后还有控制帧 +1** ⇒ 板上唯一来源 = **FIN/RST 推**（§1.4-不会-A 已证 SYN 不走本模块）。构造：让一个已发数据、且已发 FIN 的连接（app 的 close 路径）**尾部长期不确认**（小窗/慢读）⇒ RTO 反复会话（`fin_repush` 一族 + 可能的 abort RST）。
- **判据**：sink 侧 `mism_bytes == 0`（**内容校验**是唯一能看见本缺陷的口径 —— 计数类判据结构性看不见，§1.5-①）。
- **非空见证（硬要求）**：`ΔW55 > 0` **且** `ΔW58` 在该窗内至少一次 = 1（确实起过会话）；**缺见证 ⇒ 按"未测"读**（这是本工程既有纪律）。
- **零窗造法与台架开关无关的写法**：**两种都可以，但必须选一种并写进判据**：① 显式 `--rcvbuf-after-connect + --rcvbuf 2920|1460`（确定性最好；⚠️ Linux 会把 `SO_RCVBUF` 双计并按 `rmem_max` 夹取 ⇒ **判"小值"看量级不钉字面数**，同件 §5 逐字）；② **SIGSTOP 住 sink 进程**（对端停止读取 ⇒ 自己的接收窗自然关死）—— 这条**不依赖 sink 的任何开关**，代价 = 需要在跑完后 SIGCONT 并核对 sink 的墙钟/计数不变量。

**S-2（负对照构型 · 同一板同一时隙）**
- 关掉 `drift` 的来源：**只用数据、不发 FIN/RST**（纯长流档，例如 `TX_CONTINUOUS=1` 的 A/构建 F 档 + 不断流）⇒ 该跑**必须不出现**新增失配（`mism_bytes == 0` 且 `ΔW55` 可 > 0 —— 会话仍会起，只是区间不含幽灵）。
- ⇒ 这条是"**S-1 的失配是幽灵而非别的**"的对照臂。

### 6.3 ⛔ 未证的事（不许当已答）

- **板级可复现性 = 未证**（本轮零构建零板卡）：已证的只是"机制存在 + xsim 复现"。**S-0 就是去证它**。
- **板上 `drift` 的实际量级 = 未证**：TB 里是 1/21（同一个连接 22 笔控制帧）；板上 FIN 重推**先回卷再落 seq**（§1.4-不会-B）⇒ 可能只有 abort RST 或"慢路径已占一个 seq"（"每连接 2 FIN"登记项）才贡献 1 笔 ⇒ **量级可能是 1 字节级**。⇒ 判据必须容忍"少量"（登记件影响面逐字：个位～几十字节）。
- **对端会不会把幽灵当新数据交付**（§1.5-③ 的两支）= 未定（需要 pcap + 对端应用层见证）。

---

## §7 回退与逐位退化

### 7.1 默认关还是无条件修？⇒ **无条件修**（不设参数）

- 依据 = **F1 先例**（同族正确性缺陷 = 无条件 + 两分支，`P7B_STAGEC_TX.md:24`）；
- 加参数会把"错误行为"变成**可选语义**（本工程纪律：判据不得为空、不许把真缺陷做成开关），且 `#64`（改常量/参数会**确定性**改网表）会让"关"的那档也是一次独立构建 ⇒ **参数不但没省事，还多一个位流面**。

### 7.2 可判定的等价（"逐位退化"）证据 —— 本刀的**条件式**逐位不变

**结构命题**（逐项可核，【事实】）：当 `whi_r[svc_id] == retx_hi_at_svc`（即 `drift == 0`）时，
`ring_delta ≡ retx_hi − rb_snd_nxt`（原式）、`ring_ovf ≡ retx_ovf`、`ring_start`/`replay_jump` **同值**、`ring_restore ≡ 0`（条件里 `ring_delta == 0 ∧ snd_nxt != retx_hi` 互斥）
⇒ **本刀在无漂移会话上逐位不动**；有漂移时才产生差异（这正是要修的那一格）。

**可判定的取证（三条，照本工程成例）**：
1. **门读数逐字对照**（最强、最便宜）：改前/改后跑 `author_gate` 的 **S/T** 两臂，除 `payload/seqcont` 外**所有既有数字逐字相同**：`n_frames / n_data / n_ctrl`、`DUT stat_frames/stat_bytes/stat_ack/drop_len/fin/rst/retx/tlast_in`、`wsrc data/ctrl/rew`、`T8 rx1460/tx1460/fp1460/overlap`、`W66/W67/W69`。⇒ 这是"**只修了该修的**"的直接证据（也是"改前/改后"的 A/B 本体）。
2. **无漂移跑位级复现**（本工程既有成例口径）：对"drift ≡ 0"的配置（例如只发数据、不发 FIN/RST 的臂），改前/改后**同一激励**的输出流指纹（`SW_CRC` 级或 `fc /b` 逐文件）必须一致 —— 这是本工程"同输入重跑 = 位级复现、方差 0"的既有纪律（`p7b_build_longflow/INDEX.txt` 逐字）。
3. **冻结锚（若 TL 选择参数化形式才需要）**：`frozen/<file>.v` + 24 文件 `fc /b` 逐字节（成例 = LONGSEND 轮的 `CONT_GATE_stdout.txt`）。**本刀默认不做参数 ⇒ 这条不适用**（登记以免下游照抄）。

### 7.3 回退点

- **一键回退 = `git revert <本刀提交>`**（改动**自包含**：1 个 RTL 文件 × 2 处分支 + 0 端口 + 0 快照字 + 0 II/时序常数 ⇒ 无跨件残留）。
- ⚠️ **位流级回退**：本刀会产出一个新位流（BID 需 **bump**，纪律 `P7B_HANDOFF.md` §4-#55）⇒ 回退 = 烧回上一版位流（**只有 sha256 能分版**：六档位流全 15,431,261 B）。
- ⚠️ 与 persist 的耦合：persist 的开关在 wrapper（`.PERSIST_EN(1'b1)`，`board/wrapper_p4.v:2150`）⇒ **分离代价/分离回退 = 把该参数改回 `1'b0`**（一行，见 §8.3）。

---

## §8 代价与风险

### 8.1 本刀代价（**单独报**，逐项）

| 项 | 估计 | 依据 |
|---|---|---|
| FF | **+544**（`whi_r` 16×32 = 512 + `ring_hi` 32） | 位宽×数直算；全 DP 域 |
| LUT | **+100–200** | 16 路写解码（≈16–30）+ `ring_ovf`/`ring_restore`（两份 32 位减+比较+mux ≈ 各 30–40）+ `upd_val`/`upd_id`/`upd_wr` mux 的加宽（≈20–60） |
| BRAM/URAM | **0** | 无新存储 |
| **锥形** | **不新增**（与今日**同型同深**） | `ring_delta`/`ring_ovf` 的操作数与今日 `retx_hi`/`retx_ovf` **同类**（都是寄存器 + TCB 组合读）⇒ 只见操作数换源，不见级数增加；`ring_restore ⊆ ring_eval` 与 `replay_jump` 同层 |
| 量级对照 | ≈ **1.04 个 persist 刀**（后者 ≈522 FF，`P7B_PERSIST_DESIGN.md:481` 逐字） | 便于 TL 直接比 |

### 8.2 风险（逐条给缓解）

| # | 风险 | 缓解 |
|---|---|---|
| R1 | **DP 域时序**：构建 F 的 DP setup WNS = **`+0.281`**，其宿**恰好是 `u_tcp_tx/u_retx/…/RSTRAMB`**（构建 F 块逐字：`u_clkgen/rel_sr_reg[3]/C → u_tcp_tx/u_retx/…/RSTRAMB`，纯布线）⇒ 而 `ring_start` **正是**喂 `retx_ram` 读口那条锥（`:774` `rd_tap = ring_start \|\| …`）⇒ **本刀正落在 DP 最差族上** | ① 设计上**不加级**（用同型判据，见 §8.1）；② **一次构建收口** + 构建后**定向查** `-from u_tcp_tx/u_retx/* -to u_tcp_tx/u_retx/*` 与 DP 前 10（成例 `P7B_A7_CSUM_SINK_DESIGN.md` §1.6）；③ 预留退路：把 `ring_restore` 的 `upd_wr_rew` 合并项退化为"下一拍"（+1 FF，需重证 §3.4） |
| R2 | **新写源进 TCB 写口**（四源 `$onehot0`） | §3.2-(7)/§3.3-(7) 的互斥论证；建议**进门**（OVL 的 `$onehot0` 断言已存在 ⇒ 加 `ring_restore` 项；else 支同理） |
| R3 | **`whi_r` 语义被后人误用**（例如有人拿它当"已 ACK 高水位"） | 端口注 + 「只在活帧推进写时更新」写进注释；本件 §3.1 表即口径 |
| R4 | **`drift` 在别处也被消费**（本刀只改了环侧） | 已逐条核过 `retx_hi` 的全部消费者（`:984`/`:1131`/`:760`/`:765`/`:772`/`:1068` + `tcp_rx.v:320`）⇒ 只 `:760/:772`（环侧）改源，其余一字不动 |
| R5 | **板级可复现性未证**（最贵的风险：可能白做一轮板级） | **S-0 先行**（§6.2，零构建） |
| R6 | **矩阵与改动互斥**（全局 #57） | 实施前确认矩阵不在跑；改完跑整轮（13 门覆盖 else 支） |

### 8.3 ⭐ 与 persist 的先后关系（**唯一决策点，交 TL**）

**事实**（我核过 git 与源码）：
- persist 的 RTL **已在 HEAD**（`git diff --stat HEAD -- rtl board` = **空**；`PERSIST_EN` 等三个参数在 `rtl/tcp_tx_frame.v:299-301`），**尚未构建**（`P7B_OPEN_ITEMS.md` §A19：**代价 ≈522 FF 尚未计入网表**）；
- 它的**唯一打开点** = `board/wrapper_p4.v:2150` 的 `.PERSIST_EN(1'b1)`（注释逐字："回退点 = 这一处改回 `1'b0`"）；
- 用户已裁定（`P7B_OPEN_ITEMS.md` §1-A19 ④ 逐字转述）："**先修缺陷、再构建 persist**"。

**两种读法与代价**：

| 读法 | 做法 | 代价 | 我的建议 |
|---|---|---|---|
| ① **分离代价**（推荐） | 先：`.PERSIST_EN(1'b0)` + 本刀 ⇒ **一次构建** + 板级；再：`.PERSIST_EN(1'b1)` ⇒ **再一次构建** | **2 次构建**，但**时序代价可分离**（R1 的风险可控可归因） | ✔ **在 R1 已知落在 DP 最差族上的前提下，我建议①** |
| ② **同批**（省一次构建） | 本刀 + persist 同批一次构建 | **1 次构建**，但 WNS 变化**不可归因**（`#66`："WNS 是不同对象"）⇒ 若变差，需再拆刀 | 若 TL 愿承担"归因不明"，可用；**必须把两个代价合并报**（544 + 522 ≈ **1066 FF**） |

---

## §9 未定（如实列；每条给"下一步最小实验"）

| # | 未定项 | 为什么未定 | 下一步最小实验 |
|---|---|---|---|
| **U1** | **板级会不会出幽灵 / 量级多少** | 零构建零板卡；TB 的 `drift` = 1/21，板上的控制帧源更窄（§1.4-不会-A） | §6.2 的 **S-0**（一次现有台架跑 + `ΔW55`/`ΔW57`/sink `mism_bytes`）—— **最高优先** |
| **U2** | 对端把幽灵段当**重复**还是当**新数据**（§1.5-③ 的两支） | 取决于对端在那一刻是否已消费该 seq 上的 FIN/RST；无 pcap/对端见证 | 与 S-0 同跑：对端加 `tcpdump`（或看 `TcpExtTCPOFOQueue`/`rcv_nxt` 跳变）+ sink 的应用层字节计数 |
| **U3** | `whi_r = 0 且 rb_snd_nxt ≥ 2^31` 这个结构性盲点要不要加 valid 位 | 我判**不可达**（§3.4 的论证 = 【推断】，未仿真） | 一条**定向 xsim**：把 `whi_r` 强置 0 + 把 TCB 的 `snd_nxt` 强置 `0x8000_0100` 起一次会话 ⇒ 看 `ring_start` 是否误起（期望：不误起则论证成立） |
| **U4** | **else 支的镜像是否有门可测**（矩阵 chain 族 TB 是否注入控制帧 ⇒ 该支是否有 `drift > 0` 的激励） | 我**未**逐个读 `tb/tb_p4_chain.v` 的激励（本轮范围外） | 一次 grep + 读该 TB 的 `ack_syn/fin_req/rst_req` 驱动 ⇒ 若恒 0 ⇒ 镜像**无门可测**，应在 OPEN_ITEMS 登记"以一致性为由镜像、缺陷不可达" |
| **U5** | 变异门在这文件上的 **CRLF 锚点**问题 | 已登记：`tcp_tx_frame.v` 是 CRLF（2040 个 CR）+ 锚点陈旧 ⇒ G3 类门跑不通（`P7B_OPEN_ITEMS.md` §4 逐字） | 做变异前先把锚点按 `\r\n` 写；或先做 `.gitattributes` 归一化（同 §4 的 B5 项） |
| **U6** | `shou`… **`stat_retx_wrap`（F1 计数器）与 `ring_ovf` 的关系是否要登记新口径** | 本刀**不动** `retx_ovf`/`stat_retx_wrap`（§3.5）⇒ 它们的口径确实不变；但**新出现的 `ring_ovf` 事件**（会话期 +1 把 `snd_nxt` 推过数据端 = 常态）**没有计数器** | 若要观测它 ⇒ 加 `stat_ring_ovf`（**新字/新端口 = 要走读侧同步**）⇒ 建议**先不加**（登记为"未观测"，而不是"不存在"） |
| **U7** | §3.3 的 else 支落位（新增写源在 `always` 块里的具体行） | 我只给了"语义 + 锚点"，未逐行数到 else 支第二段的插入点 | 实施轮：按"先声明后用 + 同块同区"落位，并在 xelab 面确认无 `VRFC 10-3380`（同文件既有惯例） |
| **U8** | 本刀的 **LUT 估计区间**（+100–200）与**时序影响** | 纸面估计，未综合 | 一次构建的 `utilization` + DP 定向路径报告（§8.2-R1） |
| **U9** | `S`/`T` 臂在**改后**是否出现**新**红（我预测 0，但只在 4 条已枚举红上核过） | T 臂 11 条未落盘的红**未逐条核**（打印上限） | 改后同跑，逐条看新增红；若出现 ⇒ **先查是不是§1 之外的独立成因**（不许先改判据） |

---

## 附录 A：引用核对表（逐条 `file:line` 逐字；本件所有引用的真值源）

| # | 引用 | 核结果 |
|---|---|---|
| 1 | `rtl/tcp_tx_frame.v:635-637` `upd_val` 三支（`+1` 在 `:636`） | ✅ 逐字（`:635` `assign upd_val = upd_wr_data ? (f_seq[rx_bank] + {20'b0, f_plen[rx_bank]}) :` / `:636` `(upd_wr_ctrl ? (rb_snd_nxt + 32'd1) :` / `:637` `(replay_jump ? retx_hi : rb_snd_una));`） |
| 2 | `:1131-1132` `retx_hi <=` | ✅ 逐字 |
| 3 | `:760` `ring_delta = retx_hi - rb_snd_nxt;` | ✅ 逐字 |
| 4 | `:765-766` `retx_ovf` | ✅ 逐字 |
| 5 | `:303` `ifdef TCP_TX_OVL` / `:1517` `else` / `:2499` `endif` | ✅（派单书的 `:281`/`:1248` **订正**） |
| 6 | `:628` `upd_wr_ctrl = start_ack && !probe_sel && (aq_syn\|aq_fin\|aq_rst);` | ✅ |
| 7 | `:612-613` `ctrl_adv_inflight` / `svc_x` | ✅ |
| 8 | `:984-985` `o_retx_hi`/`o_retx_active` | ✅ |
| 9 | `:952-954` `fin_push` 的 `(rb_snd_nxt == rb_snd_una)` 门 | ✅ |
| 10 | `:1192` 扫描清 `fin_retx_pend`（`rb_snd_una != fin_seq_r`） | ✅ |
| 11 | `:2003-2007` spurious FIN 警告 | ✅ 逐字"…可诱发 RST" |
| 12 | `:1791-1792` / `:2162-2163` / `:1631` / `:1638-1639`（else 支同款） | ✅ |
| 13 | `:1552` else 支 `reg [31:0] retx_hi;` / `:2073` 复位 / `:2091` `if (cfg_up)` | ✅ |
| 14 | `:1747-1754` else 支 `stat_winstall_ev`（镜像先例 + "权威注释在 OVL"） | ✅ |
| 15 | `rtl/retx_ram.v:3/36/85` 地址 = `w_seq[15:0]` 模 2^16 | ✅ |
| 16 | `rtl/tcp_rx.v:306-320`（P4d 死锁族 + `ack_hi`） | ✅ 逐字 |
| 17 | `board/wrapper_p4.v:2101-2103`（`tx_ack_* = 1'b0`）· `:2124-2125`（非 APP 支 `fin/rst_req = 0`）· `:2150`（例化 + `PERSIST_EN(1'b1)`）· `:1852`（`ra_retx_hi`） | ✅ |
| 18 | `board/build_p7b_ku5p.tcl:153` `verilog_define {… TCP_TX_OVL=1}` | ✅ 逐字 |
| 19 | `sim/p4gates/run_matrix_p4dfix.bat:184-211` 17 门 · `:206` "`-d APP_MODE` ONLY … with TCP_TX_OVL off … NOT in it" | ✅ 逐字 |
| 20 | `sim/p4gates/{chain,p5wrapper}_src.f` 含 `rtl/tcp_tx_frame.v` | ✅ |
| 21 | `tb/tb_tcp_tx_ovl.v:2228-2232` `tot_red` 白名单和式 · `:2267` REDS 显示 · `:787-806` J3/J4 生成 · `:2020-2036` F1 判据 · `:2306` `e_f1_ring` · `:74-76` 臂 `TB_PERSIST_EN` · `:895-898` 源锚 `kw_live` · `:1050-1067` 对端模型 | ✅ 逐字 |
| 22 | `ev/orS_oracle_v6_xs.log:1750/1751/1754`（SVC/WTRK）· `:2692-2695`（@375000 四行）· `ev/orS_oracle_v5_xs.log:965-966,1730`（红帧）· `ev/orT_oracle_v5_xs.log:3465`（T 臂 `payload=14`）· `ev/gate4_stdout.txt:649-653`（`[S]` 段）· `ev/rerun_oracle.bat`（两臂 defs） | ✅ 逐字 |
| 23 | `_proj_10g/notes/P7B_TX_PINGPONG_FIX_DESIGN.md:242 / §3-C6`（"结构性排除"原文） | ✅ 逐字 |
| 24 | `_proj_10g/notes/P7B_PERSIST_DESIGN.md:481`（≈522 FF）· `:287-290`（D-8 不镜像） | ✅ 逐字 |
| 25 | `_proj_10g/notes/p7b_sinkfix_20261010/REPORT.md:13/70/79/85-87/227-233`（`--rcvbuf-after-connect` 与见证行） | ✅ 逐字 |
| 26 | `_proj_10g/notes/P7B_OPEN_ITEMS.md` §1-A19（登记件：两账口径 / 影响面判形态 / persist 先后裁定）· §4（CRLF 锚点） | ✅ 逐字（本件与它**口径一致**；仅"三条独立账本"按它的订正口径写） |
| 27 | `_proj_10g/notes/P7B_BIZ_WINDOW.md` §1（W55/W57/W58 口径）· §2（五处同改） | ✅ |
| 28 | `_proj_10g/notes/P7B_STAGEC_TX.md:24`（F1"两分支同修"） | ✅ 逐字 |

**本件全部改动均为纸面；未写任何 RTL / TB / sim / board / 脚本；未碰 `P7B_OPEN_ITEMS.md`；未跑任何工具。**
