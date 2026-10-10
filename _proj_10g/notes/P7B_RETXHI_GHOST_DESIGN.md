# P7B-RETXHI-GHOST 设计件 —— 重放上界越过"环已写高水位" ⇒ 线上出现【本圈未写过】的环字节

- **性质**：既有机制的**正确性缺陷**（**不是** persist 特性；persist 臂 T 的 `PERSIST_EN=0` 同族复现）。
- **边界（本件纪律）**：**纯纸面**。未改一行 RTL/TB/sim/board/脚本；零 Vivado / 零 xsim / 零构建 / 零板卡。
- **固定句（必守）**：**核到与本件描述不符就如实说，别迁就。** 下面每一个行号、每一处"已定案"都是本轮**回源码逐字核过**的；凡是**订正**或**未定**，都在原处显式标出。
- **标注约定**：【事实】= 回源码/回日志逐字可复算；【推断】= 由事实推得、未直接测量；【未定】= 我判不了。
- **证据地图（取证原件，先读这几件）**：
  `_proj_10g/notes/p7b_persist_impl/ev/orS_oracle_v6_xs.log`（关死证据 + SVC 判决行）·
  `_proj_10g/notes/p7b_persist_impl/ev/orS_oracle_v5_xs.log`（红帧逐字）·
  `_proj_10g/notes/p7b_persist_impl/ev/orT_oracle_v5_xs.log`（persist 关臂同族复现）·
  `_proj_10g/notes/p7b_persist_impl/ev/or{S,T}_oracle_xs.log`（v4 级）·
  `_proj_10g/notes/p7b_persist_impl/patch_oracle_v{4,5,6}.py`（探针真值与判读定义）·
  `_proj_10g/notes/p7b_persist_impl/ev/gate4_stdout.txt`（门记录，`[S]` 段）·
  `_proj_10g/notes/p7b_persist_impl/ev/q1_*_out.txt`（上一圈签名复算）·
  ⚠️ **`_proj_10g/notes/p7b_persist_impl/rerun_oracle.bat`（两臂定义 = 我核过臂 S/T 的真值源；⛔ 不在 `ev/` 下 —— v1 写错过，v2 订正）**。

> ## ⭐ v2（2026-10-10，对抗审查后原地修订）
> 依据件 = `_proj_10g/notes/p7b_retxhi_review_20261010/FINDINGS.md`（275 行，含 **TL 核查批注**；**我全文读过并逐条回源码自核**）。
> **用户裁定 = 只收"板可达部分"的最小版**（洞读登记为残留）⇒ 本件 v2 = 6 条 blocking 全处置 + 5 项顺手改 + 9 条 E3 漏项逐条处置 + U1/U2/U4/U5 定 / U3/U6 后置说明。
> **逐条依据 ↔ 改前 ↔ 改后 ↔ 处置 = 文末 `## v2 修订记录`**（那一节是 v2 的权威口径；正文里凡被改处就地标注 `【v2】`）。
> ⛔ 本件仍是**纯纸面**：未改任何 RTL/TB/sim/board/脚本/`P7B_OPEN_ITEMS.md`；零 Vivado / 零 xsim / 零构建 / 零板卡 / 零 ssh；git 只读。
> ⚠️ **v1 的两条结论在 v2 被推翻/降级**（审查成立）：① §5.5 红① 的"两种可能都绿"⇒ **推翻**；② §1.1 的"区间**末** drift 字节"作为唯一形态 ⇒ **降级**（缺陷有**两种形态**，见 §1.1b）。

> ## ⭐⭐ v3（2026-10-10，第二轮窄口径审查后原地修订 —— **本轮是最后一轮设计，收敛优先**）
> 依据件 = `_proj_10g/notes/p7b_retxhi_review_20261010/REVIEW2.md`（203 行；我**全文读过并逐条回源码自核**）。
> **REVIEW2 判定的两格（我赢）：① 钳位（方向/阈值/比较/退回值/落位不踩 A1）被独立证实成立；② `tot_red` 行号 `:2228-2232` = 我对、v1 审查错。**
> v3 收 **6 条 blocking**（`e_ghost` 取样点钉死为**帧尾直读** / TB 前沿模型耦合进判据面 / `e_ringhi` 收窄+第 4 残留 / M-4 指名判据 / 5 处行号+拍数+归因 / `whi` 写者纪律）+ **N1 关闭（= 2）**。
> ⛔ **本轮起，凡定不下来的格子一律写进 §9.5「实施时必须现核定」**（原因 + 最小实验），**不再来回**（用户裁定 = 最小版；设计边际收益已递减 ⇒ 要的是**可照笔实施 + 可判定验收**）。
> **逐条依据 ↔ 改前 ↔ 改后 ↔ 处置 = 文末 `## v3 修订记录`**（那一节是 v3 的权威口径）。
  提交：`fd880e2`（发现）· `9d6554e`（机制到行）· `68bb98c`（关死到 (a)）· `22c0282`（取证件补录）· `3789beb`（进 OPEN_ITEMS §1-A19）。

---

## §0 一页摘要（现核结论 / 建议修法 / 代价 / 建议门）

| 项 | 结论 |
|---|---|
| 状态级缺陷（**两种形态**，v2 起） | **① 顶部漂移**：重放区间 `[snd_una, retx_hi)` 的**末 `drift = retx_hi − 环已写高水位` 字节**落在**本圈从未写过的环地址**（环地址只取 `seq[15:0]`，差一圈不改地址）⇒ 读回**上一圈/上一会话**的残留并当数据上线。**② 区间内洞**（v2 新增，见 §1.1b）：数据流**中段**发生控制帧 `+1` 时，写游标在下一个活帧首拍被 reload 到 `rb_snd_nxt`（`:789`）⇒ **跳过那个 seq** ⇒ 该地址本圈永不写 ⇒ 洞在**高水位以下**，重放区间只要覆盖它就照旧读到旧字节 |
| 机制 | 【事实·关死】`rtl/tcp_tx_frame.v:636` 的**控制帧 `snd_nxt + 1` 预留逐笔累积**；`retx_hi`（`:1131-1132`）**直接继承**这些幽灵 seq；`:760/:765` 的重放范围按被污染的差值走 |
| 两条既有缓解为什么不够 | `ctrl_adv_inflight`（`:612-613`）只推迟**在飞的**那一笔；`fin_seq_r` 支路（`:1131`）只消掉**最后一个** FIN 的 +1。**累计的 +1（早先的 RST、早先的 FIN 重推）没人消** ⇒ 这正是 Stage C 设计 §3-C6 自认"结构性排除"**没覆盖到的那一格**（见 §1.2） |
| 建议修法（v2 三件） | **候选 B（推荐）**：① 给每连接加"环已写高水位" `whi_r[0:15]`，会话装载拍**经 wrap-safe 钳位**锁存 `ring_hi`（**新 v2**：`whi ≤ snd_nxt` 才接受，否则退回 `rb_snd_nxt` ⇒ `ring_hi ≤ retx_hi` 变成**结构性**的，同时关掉"陈旧高水位"伪重放窗口）；② **环侧**（`ring_delta`/`ring_start`/收尾跳写）改由 `ring_hi` 走；③ 新增"排空拍把 `snd_nxt` 恢复到 `retx_hi`"的收尾写。**`retx_hi`（= `tcp_rx` 的 ACK 上界）与 `:636` 一字不动**。⚠️ **v2 补**：`upd_id` 也必须加 `ring_restore ? retx_id_r :`（否则写错连接 —— 审查 A1 成立） |
| ⛔ 覆盖边界（v2 新增，**用户裁定**） | 本修法**只治形态①**；**形态②（区间内洞）不闭合**（`ring_restore` 把漂移位变成"延迟的洞读"，见 §1.1b/A3）⇒ **登记为残留**；而形态②**板结构性不可达**（唯一路径 = `aq_syn` 型控制帧，板上 `tx_ack_syn = 1'b0`）⇒ **收"板可达部分的最小版"**（用户裁定） |
| ⛔ 明确回答 | **不要动 `:636`**（`snd_nxt += 1` 是"控制帧占一个序号"的唯一落点；卡它会崩对端 ACK 语义 / `fin_push` 的 `snd_nxt==snd_una` 门 / 窗口门口径） |
| 代价（单报） | **≈ +544 FF**（16×32 高水位 + 32 位锁存）+ **≈ +100–250 LUT**（v2 加：装载拍钳位 1 组 32 位减+比较+mux），**0 BRAM**，**不新增长锥**（`ring_delta` 的锥形与今日**同型同深**，只换操作数来源；⚠️ "同型同深" ≠ slack 不变，见 §8.2-R1） |
| 与 persist 的先后 | persist 的 RTL **已在 HEAD**（`git diff HEAD -- rtl board` = 空）且**尚未构建**；`wrapper` 的 `.PERSIST_EN(1'b1)` 是它的唯一打开点 ⇒ **要分离代价就先 `.PERSIST_EN(1'b0)` + 本修 单独构建**（详见 §8.3）。⚠️ **v2 订正引注**：≈522 FF 的真值源 = `P7B_PERSIST_DESIGN.md:481`（**不是** OPEN_ITEMS） |
| 建议门（v2 重写） | **本刀达成 = J3/J4 幽灵红里"可治的 3 条"清 0**（§5.2 定义）；⛔ **S 臂现盘是 5 条红**（第 5 条 = `PS j8 空判据`，persist 族）；⛔ **T 臂按门契约必须保持非 0**（`run_tx_ovl_gate.bat:115/139`）⇒ **不许再写"T 臂也必须绿"**。定向仪器 = **`e_ghost`**（半区判据：**帧尾直读**越过高水位）+ **`e_ringhi`**（A4 门，**判据本体豁免 R4 角**），**都必须进 `tot_red` 白名单和式**（`tb/tb_tcp_tx_ovl.v:2228-2232`；`e_f1_cyc` 在 `:2230`）。⭐ **【v3】判据面另含"TB 前沿耦合"两条支路（`e_j9`/`e_seqcont` 前沿侧，§5.5）**；可照笔实施 + 待现核项 = **§9.5（V1–V6）** |
| 板级首步（v2 订正构型） | ⛔ **先花 10 分钟证明"板上到底会不会出幽灵"**，但**构型必须改用 abort RST**（**FIN 支结构性 drift = 0**，审查 B3 成立）—— 见 §6.2 |

---

## §1 缺陷的精确定义与边界

### 1.1 状态级定义（形态①：顶部漂移）【v2：加形态限定】

**定义**（**形态①**）：对任一连接，令 `wrhi` = 该连接**环里真写出过的最高 seq**（= 最后一个数据帧的 `f_seq + f_plen`）。
重放会话把区间 `[snd_una, retx_hi)` 当"待重发数据"逐段读出组帧（OVL 支 `:1143-1166` 起帧、`:1146` `f_seq[rx_bank] <= rb_snd_nxt`、`:1162-1164` 预推进；else 支 `:2176-2199` 同构）。
**当 `retx_hi > wrhi` 时**，区间末 `drift = retx_hi − wrhi` 字节的**读地址**是"本圈从未写过"的。

**为什么"读地址 = 上一圈的字节"**（【事实】）：
`rtl/retx_ram.v:3` 逐字 "16 conns x 64KB ring (字节偏移 `w_seq[15:0]`, 模 `2^16`)"；`:36` `wire [12:0] w = w_seq[15:3];`、`:85` 读口同构 ⇒ **地址只由 seq 低 16 位决定** ⇒ 差 65536 不改地址。环里那个地址留着**上一次写它的内容** = 上一圈（同连接、流偏移 −65536）的字节；同槽重连后也可能是**上一会话**的字节。⇒ 这就是"线上出现上一圈字节"。

### 1.1b 【v2 新增】形态②：**区间内洞**（高水位**以下**的未写 seq）

**定义**：数据流**中段**发生一笔控制帧 `+1`（`:636`）时，写游标在**下一个活帧首拍被 reload 到 `rb_snd_nxt`**（`:789` 逐字 `wire [31:0] w_tap_seq = start_data ? rb_snd_nxt : tap_seq;`）⇒ **那一笔预留的 seq 位置被跳过**（= 那个环地址本圈永不写）。此后活帧的数据把它们自己的字节写到**更高**的地址 ⇒ **高水位 `wrhi` 被抬到洞之上**，洞就留在**高水位以下**。

**⇒ 与本修法（候选 B）的覆盖关系（审查 A2 成立，v1 判错）**：
- 候选 B 只改 `ring_delta` 的**操作数**与**收尾写** ⇒ **不改 `seq → 地址` 映射、不改帧的起始 seq**（`:1146` `f_seq[rx_bank] <= rb_snd_nxt`）⇒ **只要那个帧还生成，它读的就是同一个地址、同一个旧字节**；
- 而"帧还生成"是**常态**：洞之上的数据把 `whi_r` 抬高了 ⇒ `ring_delta = whi_r − snd_nxt > 0` ⇒ 帧照旧生成、照旧跨过洞 ⇒ **本修法对它 0 覆盖**。
- ⇒ **形态② = 修法外的残留**（用户裁定收"板可达部分的最小版"⇒ 登记，见 §9-R1）。

**板上可达性 = 结构性不可达**【事实+推断】：
- 形态②要求"**预留之后该连接还有数据在写**"。逐条核对本文件的三个控制帧源：`fin_push`（`:952-954`）含 `(rb_snd_nxt == rb_snd_una)` 门、`rst_push`（`:955-956`）之后 `tx_blk`（`:547`）封住该连数据 ⇒ **FIN/RST 都是该连最后一笔**；
- 唯一能在预留后继续写数据的是**不置 `fin_sent_r/rst_sent_r` 的 SYN 型条目** = `upd_wr_ctrl` 里的 `aq_syn`（`:628`）。TB 实测确实发 SYN（`OVS wsrc … issued fin/rst/syn = 17/22/11`，`ev/gate4_stdout.txt:2705` 一带）；
- 而**板 wrapper 把 `tx_ack_syn` 钉 `1'b0`**（`board/wrapper_p4.v:2101`）+ SYN-ACK 由慢路径 HLS 发（`:2128-2129` 逐字"SYN-ACK 由慢路径发"）⇒ **板上不存在这条路径** ⇒ **形态②板上不可达**（这条论证 v1 没有 —— 审查指出，采纳）。

**⚠️ 但形态②与 `ring_restore` 的关系必须写清（审查 A3 成立）**：本修法在排空拍把 `snd_nxt` 恢复到 `retx_hi`（= 高水位 + 本次 drift）⇒ **下一活帧的写游标从"高水位 + drift"起** ⇒ 漂移区 `[whi, whi+d)` 成为**永不写**的 seq 位置 ⇒ 它们对**后续会话**就是一个"区间内洞"（只要那次会话的区间覆盖到它们）⇒ **缺陷由"立即发旧字节"变成"延迟的洞读"** ⇒ **不闭合**，如实登记（§9-R2）。
⭐ **一处口径精度（如实标注，不迁就也不夸大）**：这个"洞"**不是 `ring_restore` 造出来的新状态** —— 今日（无本修法）一次会话的自然排空同样把 `snd_nxt` 停在 `retx_hi`（`:1167-1181` 的排空支），**末态逐字相同**；本修法改变的是"**那些位置没有被当数据发出去**"（今日它们被当数据发；修后它们不被发）。⇒ 形态②的**根因仍是 `:636` 的那笔预留本身**，`ring_restore` 只是把它从"当圈发掉"改成"留到下一圈"（【事实】= 末态同；【推断】= 根因归属）。

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
  ⚠️ **【v2】本条只覆盖这一支**（"全部 +1 都在数据之前"）；**"数据流中段的一笔 +1"不产生 drift、但产生【洞】** ⇒ 见 §1.1b（形态②）—— v1 把"drift = 0"直接读成"无幽灵"是**错的**（审查 A2 成立：conn0 `drift ≡ 0` 却出了 1 字节旧值）。
  证据【事实】：`orS_oracle_v6_xs.log:389` `ORACLE WTRK cyc=330736 kind=SV c=0 … ctrl_n` 那一族 = 同日志 `:2695` `ORACLE4 @375000 ctrl=8/22/18/2` ⇒ **conn0 累计 8 笔而 `drift ≡ 0`**（`:389` `nxt_minus_wrhi=0`）。
  ⭐ **板配置下这条是常态**：`board/wrapper_p4.v:2101-2103` 把 `tx_ack_syn = tx_ack_fin = tx_ack_rst = 1'b0` **钉死**（SYN-ACK 由慢路径 HLS 发，`board/wrapper_p4.v:2128-2129` 的 r6 注释逐字"SYN-ACK 由慢路径发"）⇒ **板上本模块的控制帧 = FIN/RST 推(re-push) 一族**，SYN 的 +1 永不经过 `upd_wr_ctrl`。
- **不会 B（FIN 支路自洽）**：纯"数据 + 一个 FIN"且 FIN 直接跟在数据端 ⇒ `fin_seq = wrhi`，且 FIN 重推**先回卷再落 seq**（`fin_repush` 要求 `rb_snd_una == fin_seq_r`（OVL `:957-959`），回卷把 `snd_nxt` 拉回 `fin_seq`。）⇒ `retx_hi = fin_seq = wrhi` ⇒ **区间为空/无幽灵**。⇒ **纯 FIN 场景本缺陷不发作**（Stage C 的 C6 缓解在这一支是有效的）。⚠️ **【v2】这条的"板级含义"比 v1 写的强**（审查 B3 成立）：`fin_push`（`:952-954`）带 `(rb_snd_nxt == rb_snd_una)` 门 ⇒ **FIN 的 +1 永远是该连最后一笔且倒在 fin 支** ⇒ **板上"FIN 路径"结构性 `drift = 0`** ⇒ **板级构型若用 close(FIN) 路径去测，是结构性测不到幽灵的**（§6 据此改构型）。
- **不会 C（区间全在高水位以下）**：`drift > 0` 但会话区间 `[snd_una, retx_hi)` 完全落在 `wrhi` 以下（下界被 ACK 顶上来）⇒ 读到的都是本圈正确字节。⛔ **【v2】本条降级**（审查 A3 成立）：只有当**区间内也没有洞**时才成立；区间内若有洞（§1.1b），读址落在洞上 ⇒ **照旧读到旧字节** ⇒ 本条**不是**"没有幽灵"的充分条件。
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
⭐ **【v2 订正】三种失配形态必须分清（审查 A2 成立）**：
- `[S#2]`（`off=8` 起、命中 8/16 同圈）与 `[S#3]`（`off=0`、同圈 0/16）= **尾段漂移形态**（形态①）：失配从某个 `off` 起**直到帧尾**；
- `[S#1]`（`off=0` 单字节失配、**其余 15/16 = 本圈**）= **区间内洞形态**（形态②）：洞在**帧首**，其后是高水位**以下**的本圈数据。
  ⇒ v1 把 `[S#1]` 读成"drift = 1 的尾段漂移"是**错的**（它在帧**首**、且其后字节是本圈的 ⇒ 洞在高水位以下）。
- ⚠️ **举证范围如实登记**：`q1_*` 只比了每帧的**前 16 字节** ⇒ "其余 1459 字节 = 本圈真数据"是**【推断】**（不是【事实】—— v1 标错）；且 `e_payload` 是**按帧**计数（`tb/tb_tcp_tx_ovl.v:822` 的 `kk = 1536;` 是跳出循环）⇒ **`payload=3` = 3 个帧，不是 3 个字节**。
- ⚠️ **读数协议提醒（保留）**：**RD-AHEAD/RDZOOM 是带时间戳的瞬时量，不得与数千拍之后的 FAIL 行交叉引用**（我本轮就是这么绕了一圈弯路）。

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
  - **B-3（`snd_nxt` 与环上界分离之后，`:760/:765` 还成不成立？）** ⇒ **成立，但要立第二条判据**：`ring_delta` 换成 `ring_hi − rb_snd_nxt` 后，"越顶"必须由**同型**的 `ring_ovf` 判（不能借 `retx_ovf`：`retx_ovf` 的语义是"越过 `retx_hi`"，两者不同对象）。⛔ **不许把 `retx_ovf` 的定义改指 `ring_hi`** —— 那会打红 TB 既有硬判据 `e_f1_cyc`（生成条件 `tb:2034`、计数 `:2035`；`tb:2230` 在 `tot_red` 和式内）【v3 行号订正：v2 写 `:2025`，那是 `e_f1` 信息计数的计数行】【事实】；`retx_ovf` 必须**保持指向 `retx_hi`**。
  - **B-4（`replay_full = !retx_req`（`:1136`）与 RETXFIX 的 `blocked`/`epoch` 会不会被影响？）** ⇒ 【事实】它们不消费 `ring_delta`：`blocked = (epoch[svc_id] >= 4'd15)`（`:561`）只看 `epoch`；`svc_x = svc && !ctrl_adv_inflight`（`:613`）；`replay_full` 只做两件事 —— 允许/禁止 `ring_start`（`:768`）与禁止 `replay_jump`（`:773`）。⇒ 本刀改的是 `ring_delta` 的**操作数**，`replay_full` 的语义（预算逃逸）**不变** ✔。⚠️ **但有一条必须一起改**：`replay_jump` 的**触发条件**（见 B-5）。
  - **B-5（收尾必须补"恢复写"，否则回归 spurious FIN）**【事实+推断】：环上界降到 `whi` 后，排空拍 `snd_nxt = whi < retx_hi`；此时随后的控制帧（FIN 重推）会取 `ctrl_seq = rb_snd_nxt`（`:1264`）⇒ **seq 下漂**到下界 ⇒ 对端可能判 spurious FIN，而本文件自己逐字警告过（`:2003-2007`）："再推同 seq 条目就是 spurious FIN (seq 落在对端窗口外, **可诱发 RST**)"。⇒ 必须在排空拍把 `snd_nxt` 恢复到 `retx_hi`（复用 `upd_wr_rew`/`upd_val = retx_hi` 这条既有通道）。
  - **B-6（`$onehot0` 三写源纪律）** ⇒ 新写源 `ring_restore ⊆ ring_eval ⊆ (rx_idle ∧ retx_active ∧ !svc ∧ !ack_pend_r)`，与 `upd_wr_data`（RX_FIN）/`upd_wr_ctrl`（`start_ack` ⊆ rx_idle ∧ ack_pend_r）/`svc_rewind`（⊆ `!retx_active`）**三对结构性互斥**（论证与 `:621-623` 的 `replay_jump` 逐字同型）✔
  - **B-7【v2 补·审查 A1 成立·阻断级】`upd_id` 必须一起改**：`ring_restore` 拍上 `upd_wr_data = 0`（需 `rx_state == RX_FIN`，而 `ring_eval ⊆ rx_idle` 即 `RX_IDLE`）· `upd_wr_ctrl = 0`（需 `start_ack`，其两项与 `ring_eval` 结构性互斥）· `replay_jump = 0`（需 `ring_delta != 0`，而 `ring_restore` 要求 `== 0`）⇒ `:631-633` 的 `upd_id` 会落到**兜底支 `svc_id`**，而 `svc_id = svc_id_r`（`:560`）由 `:1078` **每拍自由重算**（`retx_req ? retx_id : prio_lo(rto_pend)`）—— **会话期 `svc_id_r ≡ retx_id_r` 的证明不存在**（`retx_req = 0` 时它跟着 `rto_pend` 的优先级走，可以是**别的连接**、也可以是 `prio_lo(0) = 0`）⇒ **不补就写错连接**（污染该连 `snd_nxt` ⇒ in-flight/窗口门/慢路径语义）。⛔ v1 的 else 支对照样张**写了**这条编辑而 OVL 支漏了（审查 C5 的"镜像不等价"即指此）⇒ v2 补齐 ✔
  - **B-8【v2 补·审查 A4/E3-6 合并处置】装载拍必须**经 wrap-safe 钳位**取 `ring_hi`**：
    `ring_hi ≤ retx_hi` 是"用 `!ring_ovf` 替换 `!retx_ovf`"的**前提**（`ring_hi ≤ retx_hi` ⇒ `snd_nxt > retx_hi ⇒ snd_nxt > ring_hi` ⇒ `retx_ovf ⇒ ring_ovf` ⇒ 替换**不削弱** F1 越顶保护）—— 它是 **F1（阻断级）保护面的一部分**，v1 只当"多半安全"没写进件（审查 A4 成立）。
    ⭐ **v2 把"可证"升级为"结构性"**（一条比较器换两条保障）：
    `ring_hi <= ((rb_snd_nxt - whi_r[svc_id]) < 32'h8000_0000) ? whi_r[svc_id] : rb_snd_nxt;` —— **仅当 `whi ≤ snd_nxt`（wrap-safe）才接受 `whi_r`，否则退回 `rb_snd_nxt`（= 今日行为）**。
    它同时关掉 **E3-6 的"陈旧高水位 ⇒ 伪重放"**（见 §3.4）：陈旧 `whi > snd_nxt` ⇒ 比较为假 ⇒ 退回 `rb_snd_nxt` ⇒ `ring_delta = 0` ⇒ 无重放（而不是"巨大 delta ⇒ 伪重放"）。
    ⛔ **为什么不采纳审查给的"把 `whi_r` 升级为 wrap-safe max"**（**部分采纳：危险坐实、药方更换**）：max 保护的方向是"**被压低**"（保证高水位单调不减），而 E3-6 的危险方向是"**陈旧偏高**"—— **max 会让陈旧大值活下来**，结构上关不掉它。⇒ 钳位是更强的处置；max 仍可作为"若实施轮发现无会话期重基写则不需要"的备选（那也正是 v1 §3.2-(4) 的 ⚠️ 前置）。
- **代价**：`+16×32 + 32 = +544 FF`（全 DP 域）+ 16 路写解码（≈16–30 LUT）+ **【v2 补】装载拍钳位 1 组**（32 位减 + 比较 + mux ≈ 60–70 LUT，B-8）⇒ **≈ +544 FF / +100–250 LUT / 0 BRAM**。**不新增长锥**：`ring_delta` 的锥形与今日**同型同深**（只把操作数从 `retx_hi` 换成同类的寄存器 `ring_hi`）✔；钳位在**装载拍**（汇入 `ring_hi` 寄存器）⇒ 不落 `ring_delta` 锥。
- **风险**：① 漂移 = 0 时逐位不动（§7 的等价证据）；② 新增写源进 TCB 写口（DP 域）⇒ 时序由一次构建收口；③ `whi_r` 的**首次建立**依赖"活帧推进写"（`upd_wr_data`），若某连接从无数据就起会话 ⇒ `whi_r = 0` ⇒ 由**钳位 + 既有 `ring_ovf`** 判为"无数据可重放" ⇒ 安全（论证见 §3.4）。
- ⛔ **覆盖边界（v2 新增，用户裁定）**：候选 B **只治形态①（顶部漂移）**；**形态②（区间内洞，§1.1b）不在覆盖内** —— 它不改 `seq → 地址` 映射、不改帧起始 seq ⇒ 洞上的帧照旧生成、照旧读到旧字节（审查 A2 成立、v1 判错）。**形态②板结构性不可达**（§1.1b 的采纳论证）⇒ 按用户裁定收"**板可达部分的最小版**"，形态② + `ring_restore` 的"延迟洞读"**登记为残留**（§9-R1/R2）。

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
- **(ii) 活帧的推进写必定发生在 `retx_active = 0` 时**（因此普通写 = 高水位）：见下方 **【v2 重写】的穷举（审查 A6-1 成立：v1 的四情形枚举漏项）**。
- **【v2 重写】会话期间不可能起活帧 —— 穷举（审查 A6-1 成立：v1 的四情形**漏了 `bank_rdy` 一支**；且 `rx_idle` 现核 = `(rx_state == RX_IDLE) && recv_first`（`:524`）⇒ **在飞活帧期 `rx_idle = 0`**，本支持比 v1 写的**更强**）**：
  设 `retx_active = 1`。要 `start_data`（`:666-669`）为 1，须**同时**满足下列全部合取项；逐支给出它必假的那一项：
  | # | 分支 | 必假的项 |
  |---|---|---|
  | 1 | `rx_state != RX_IDLE`（含**正在收字**的活帧期、`RX_FIN` 收尾期、`RX_RING`） | `start_data` 的 `rx_state == RX_IDLE` |
  | 2 | `recv_first == 0`（帧已开、正在收后续 beat） | 同上（`rx_idle` 的定义含 `recv_first`；`start_data` 同门子句） |
  | 3 | `rx_flush`（`RX_FLUSH` 冲洗期） | `!rx_flush` |
  | 4 | `ack_pend_r`（ACK 待发） | `!ack_pend_r` |
  | 5 | `bank_rdy[rx_bank] = 1`（**该 bank 的帧还没被 TX 发走** ← v1 漏项） | `!bank_rdy[rx_bank]` |
  | 6 | 以上全否 ⇒ `rx_state == RX_IDLE && recv_first && !ack_pend_r && !rx_flush && !bank_rdy[rx_bank]`，而 `retx_active = 1`、`svc = 0`（`svc` 含 `!retx_active`，`:562`） | `!ring_eval`（此时 `ring_eval ≡ 1`，`:566-567`） |
  ⇒ **六支穷尽 ⇒ `start_data ≡ 0`** ✔（⇒ 会话期既不可能起活帧、也不可能起**在飞**活帧。）
- ⇒ 活帧的 `f_seq+f_plen` 在无会话期间**单调不减**（`snd_nxt` 在会话外只被数据写与 `+1` 推高）⇒ **普通写 = 高水位**（不需要比较器）✔
- ⚠️ **一个必须实施轮复核的前置**（写进实施清单）：`snd_nxt` 的写者清单 = 本模块的 `upd_*`（`:630-637`）+ 慢路径建连重基（`scfg`，`upd_sel=1`）。我已核过 `app_ctrl` 的流控通道**只**写 `upd_sel=3`（rcv_wnd）与 `5`（state）（`rtl/app_ctrl.v:717-718` + `rtl/tcb.v:5` 的编码表），**不会**在会话外把 `snd_nxt` 往低写 ⇒ 单调性成立。⛔ **【v2】这条前置已由 B-8 的装载拍钳位结构性兜住**（陈旧高值不再有害），故它从"阻断级前置"降为"实施轮复核项"；若将来有人加"会话外的 `snd_nxt` 重基/纠偏写"，钳位仍成立（它只要求 `whi ≤ snd_nxt`）。
- ⭐ **【v3 新增·审查 §1-(1) 修正 B 采纳】`whi` 写者纪律（危险方向 = "被压低"，钳位管不了）**：
  ⚠️ 钳位管的是"`whi` 陈旧**偏高**"（⇒ 退回）；但若有人**错误压低** `whi`，钳位会**接受低值**（低值在回绕意义下 ≤ `snd_nxt` 恒真）⇒ `ring_delta` 巨大 ⇒ `ring_ovf = 1` ⇒ **静默不重放**（真数据不重传）—— 这是"安静地把功能关掉"的危险方向 ⇒ **必须立纪律**：
  | 写点 | 允许？ | 谁负责保证 |
  |---|---|---|
  | 活帧推进写（`upd_wr_data && !retx_active`，`:1069-1077` 区 v3 落点） | ✅ **唯一抬高者** | **单调性由 §3.2-(4) support(i)/(ii) 两条结构性事实保证**（会话期无活帧 ⇒ 无会话外低值写） |
  | `cfg_up` 清位（`whi_r[cfg_up_id] <= 0`） | ✅ **唯一压低者** | 语义正确（新连接无数据）；且**残余窗口已由钳位 ∪ 既有 `ring_ovf` 兜住**（§3.4(c)） |
  | ⛔ **任何其它降 `whi` 的写（将来的新代码）** | **禁止** | 一旦出现 ⇒ **静默不重放**；症状 = "重传不再发生"而非报错 ⇒ 加它的人**必须**同时给一条"重放仍发生"的判据（否则是哑门） |
  ⇒ **纪律一句话（照抄进 RTL 注释）**：**"`whi_r` 的写者集合 = {活帧推进写（单调抬高）, `cfg_up` 清位}；新增任何写者都必须证明它不压低 `whi`，否则静默关闭重放。"**

**(5) 会话装载拍锁存 ⇒ 经 wrap-safe 钳位（【v2】按 B-8 改；v1 写的是裸 `ring_hi <= whi_r[svc_id];`）**（锚 = `:1131-1135`）：
```
                    retx_hi <= (fin_sent_r[svc_id] && svc_rewind) ? fin_seq_r[svc_id] :
                               rb_snd_nxt;
-                   （v1: ring_hi <= whi_r[svc_id];  ← 裸取, 无钳位）
+                   // ⭐ RETXHI-GHOST (v2): 环上界 = 数据端; **仅当 whi ≤ 当前 snd_nxt (回绕安全)** 才接受 ——
+                   //   否则退回 rb_snd_nxt (= 今日行为) ⇒ ① `ring_hi ≤ retx_hi` 结构性成立 (A4)
+                   //   ② 陈旧高水位 (同槽重连的窗口) 不再产生 "巨大 delta ⇒ 伪重放" (E3-6)。
+                   ring_hi <= ((rb_snd_nxt - whi_r[svc_id]) < 32'h8000_0000) ?
+                              whi_r[svc_id] : rb_snd_nxt;
                    if (fin_sent_r[svc_id]) fin_retx_pend[svc_id] <= 1'b1;
```
⭐ **A4 不变式的逐条论证（写进本件的正文，审查要求）**【事实+推断】：
- **非 FIN 支**：`retx_hi` 取 `rb_snd_nxt`（`:1132`）⇒ 钳位后 `ring_hi ≤ rb_snd_nxt = retx_hi` **逐位成立** ✔
- **FIN 支**（`fin_sent_r[svc_id] && svc_rewind`）：`retx_hi = fin_seq_r[svc_id]`。钳位保证的是 `ring_hi ≤ rb_snd_nxt`，还需 `≤ fin_seq`。**依据**：`fin_seq` = 该 FIN 条目上线时的 `ctrl_seq = rb_snd_nxt`（`:1264`）⇒ 之后 `snd_nxt` 只在它之上加（`+1`/数据写）⇒ **`fin_seq ≤ rb_snd_nxt` 恒成立**；而 `ring_hi` 的**接受支**值 = `whi_r` = **数据端** ⇒ 而"FIN 能被排队"的前提 = `rb_snd_nxt == rb_snd_una`（`:952-954`）⇒ 数据端 ≤ 该拍的 `rb_snd_nxt` = `fin_seq` ⇒ **`whi_r ≤ fin_seq`** ✔【推断·由 `:952-954`/`:1132`/`:1264` 直推】
- ⛔ **【v3 收窄 · 审查 §1-(2) 采纳】`ring_hi ≤ retx_hi` 的成立范围 = 「接受支 + 非 FIN 支」**：**退回支 ∩ FIN 支**存在一个**合法可达角** ——
  `whi = 0`（连接零数据、app 只 close 不 send）∧ **FIN 已发未确认**（`snd_nxt ≠ snd_una` ⇒ `svc_rewind = 1`）∧ `snd_nxt ≥ 2^31`（**ISN 随机 ⇒ 板上 ~50% 量级**；TB 臂内不可达，因 `tb:280-281` 的 ISN 硬编码全 `< 2^31`）⇒ 钳位判假 ⇒ 退回 `rb_snd_nxt = fin_seq + 1`（**FIN 支的常态**）> `retx_hi = fin_seq` ⇒ **A4 违反**。
  - **功能实害 = 无**（逐项核过）：`ring_delta = 0` ⇒ 不重放；`ring_restore` 的 `(retx_hi − rb_snd_nxt) < 2^31` 门把它挡住（`fin_seq − (fin_seq+1) = 0xFFFFFFFF ≥ 2^31` ⇒ 不触发）⇒ **只会让 `e_ringhi` 红**。
  - ⇒ **登记为第 4 条残留（R4，§9.1）**；且 **`e_ringhi` 必须显式豁免这一角**（否则是"把真红解释成判据问题"的翻版 —— §5.4-③ 给收窄后的判据形状）。
- ⇒ **合起来（在"接受支 + 非 FIN 支"范围内）：`ring_hi ≤ retx_hi`** ⇒ `!ring_ovf` 的替换不削弱 F1 越顶保护 ✔（**配门**见 §5.4-③；R4 角的豁免也写在那里）。

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

**(7) 写源 mux（【v2】加 `upd_id` 一条 —— 审查 A1 成立、阻断级）**（锚 = `:624` 前置声明 / `:629` / `:631-633` / `:635-637`）：
```
     wire        replay_jump;
+    wire        ring_restore;      // ⭐ 前置声明 (与 replay_jump 同惯例, 见 :620-624 注释)
...
-    wire        upd_wr_rew  = svc_rewind || replay_jump;
+    wire        upd_wr_rew  = svc_rewind || replay_jump || ring_restore;
-    assign      upd_id  = upd_wr_data ? f_conn[rx_bank] :
-                          (upd_wr_ctrl ? start_id :
-                           (replay_jump ? retx_id_r : svc_id));
+    assign      upd_id  = upd_wr_data ? f_conn[rx_bank] :
+                          (upd_wr_ctrl ? start_id :
+                           ((replay_jump || ring_restore) ? retx_id_r : svc_id));
-                          (upd_wr_ctrl ? (rb_snd_nxt + 32'd1) :
-                           (replay_jump ? retx_hi : rb_snd_una));
+                          (upd_wr_ctrl ? (rb_snd_nxt + 32'd1) :
+                           ((replay_jump || ring_restore) ? retx_hi : rb_snd_una));
```
⛔ **为什么 `upd_id` 这条不能省（逐字复核）**：`ring_restore` 拍上三个高优先支**全 0** —— `upd_wr_data` 需 `rx_state == RX_FIN`（而 `ring_eval ⊆ rx_idle` = `RX_IDLE`）· `upd_wr_ctrl` 需 `start_ack`（其 `ack_pend_r`/`probe_sel` 两项与 `ring_eval` 结构性互斥）· `replay_jump` 需 `ring_delta != 0`（与 `ring_restore` 的 `== 0` 互斥）⇒ 兜底落到 `svc_id`，而 `svc_id_r` 由 `:1078` **每拍自由重算**（`retx_req ? retx_id : prio_lo(rto_pend)`，`retx_req = 0` 时跟着 `rto_pend` 优先级 ⇒ 可以是**别的连接**、最坏 `prio_lo(0) = 0`）⇒ **会把本会话的 `retx_hi` 写进另一条连接的 `snd_nxt`**（污染其 in-flight/窗口门/慢路径语义；板级台架常用 6–30 连 ⇒ 可达）【事实·`file:line` 全部核过】。

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

**(5) 会话装载拍锁存 ⇒ 经 wrap-safe 钳位（【v2】按 B-8 改，与 OVL 支同款）**（锚 = `:2162-2163`）：
```
                     retx_hi <= (fin_sent_r[svc_id] && svc_rewind) ? fin_seq_r[svc_id] :
                                rb_snd_nxt;
+                    ring_hi <= ((rb_snd_nxt - whi_r[svc_id]) < 32'h8000_0000) ?
+                               whi_r[svc_id] : rb_snd_nxt;
```

**(6) 环侧三处**（锚 = `:1631` / `:1638-1641`）：同 §3.2-(6) 的 `ring_delta`/`ring_ovf`/`ring_start` 三处改法（本支 `ring_start` 另含 `scan_estab`，一字不动）；本支**无** `replay_jump`、`ring_restore` 是**新写源**（未越顶门：本支的排空只要 `ring_delta == 0` 触发 ⇒ **必须补 `!ring_ovf`** 以免越顶拍误触发）。

**(7) 写源 mux（本支 v1 已含 `upd_id` 编辑 ⇒ 审查 A1 的"镜像不等价"即指 OVL 支漏了它；本条**保留不回退**）**（锚 = `:1787-1792`）：
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

### 3.4 【v2 重写】`whi_r = 0`（本连接还没写过数据）/ **陈旧高水位** / **`cfg_up` vs `scfg` 重基**（E3-6）

**(a) `whi_r = 0` 是安全的，且钳位顺手关掉了 v1 登记的盲点（U3）**【事实+推断】：
- 钳位条件 = `(rb_snd_nxt − whi) < 2^31`（= `whi` 在"回绕安全意义下 ≤ `snd_nxt`"）：
  - `whi = 0` 且 `rb_snd_nxt < 2^31` ⇒ 比较为真 ⇒ **接受** ⇒ `ring_hi = 0` ⇒ `ring_delta = 0 − snd_nxt`（回绕大数）⇒ `ring_ovf = ((snd_nxt − 0) < 2^31) = 1` ⇒ `ring_start = 0`、`replay_jump = 0`、`ring_restore = 0` ⇒ 排空支收尾 ⇒ **"无数据可重放"判对** ✔
  - `whi = 0` 且 `rb_snd_nxt ≥ 2^31` ⇒ 比较为**假** ⇒ **退回 `rb_snd_nxt`** ⇒ `ring_hi = rb_snd_nxt` ⇒ `ring_delta = 0` ⇒ 不重放 ✔ ⇒ **v1 登记的那个"看似正的大数 ⇒ 伪重放"盲点（v1 §3.4 第二条 / U3）被钳位结构性关闭**（不再是"靠可达性论证"，而是"靠钳位条件本身"）✔
- ⇒ **U3 从"未定"降为"已由钳位关闭"**（原先的不可达论证仍保留为旁证）。

**(b) 陈旧高水位（同槽重连窗口）**⇒ **同样被钳位结构性关闭**：陈旧 `whi` 是**旧会话**的数据端，而 `snd_nxt` 已被重基到新 ISN ⇒ 二者关系任意；若陈旧的 `whi > snd_nxt`（回绕意义下）⇒ 比较为假 ⇒ 退回 `rb_snd_nxt` ⇒ 无伪重放 ✔（这比"升级为 wrap-safe max"更强 —— **max 会把陈旧大值留下来**，见 §2 的 B-8 说明）。

**(c) ⭐ E3-6 现核 = "不同拍，且顺序有利；残余窗口 1–2 拍，由钳位兜住"**【事实+推断】：
- TL 现核坐实（我复核一致）：`board/wrapper_p4.v:2068-2071` = `.upd_wr/.upd_id/.upd_sel/.upd_val(scfg_*)`（TCB 写口），而 `.cfg_up(scfg_ev_up)` 在 **`:2172`** ⇒ **两个不同信号**；
- **我进一步回源码核了顺序**（`rtl/slow_cfg_adp.v`，逐字；**【v3 行号订正】**）：写 TCB 字段走 `S_TCB`（`:156-185`，`upd_sel <= tcb_idx`，`tcb_idx` 从 0 递增到 6），最后一个字段后进 `S_TCB_LAST`（**`:187-198`** —— ⛔ v2 写 `:187-196` 少算 2 行）；而 **`ev_up <= 1'b1` 与最后一次写（`upd_sel = 6`，wscale）在 S_TCB_LAST 的**同一拍**置位**（⛔ **v2 的"`:190-196` 逐字"不精确，真值 = 三句分别在 `:192`（`upd_wr <= 1'b0;`）/`:195`（`ev_up <= 1'b1;`）/`:196`（`state <= S_RECV;`）**）⇒
  - **`snd_nxt`（`upd_sel = 1`）的重基早于 `ev_up`**：字段按 `tcb_idx = 0,1,…,6` 递增（`:171-184`，`sel=1` 是**第 2 个**、`sel=6`(wscale) 是**最后一个**）⇒ `snd_nxt` 的重基比 `ev_up` **至少早 5 个字段写** ⇒ **重基先于 `whi_r` 的清位** ⇒ **不存在"清位后仍保留旧 `snd_nxt`"的窗口** ✔
  - **残余窗口 = 恰好 2 拍（下界；gnt 无竞争时）**【v3 钉死 · 审查 §5 采纳】：边序（k0 = `S_CAM` 拍，每 gnt 一拍）= `snd_nxt` 落地 k0+3→k0+4 · `snd_una` k0+4→k0+5 · **`state=1` 落地 k0+7→k0+8** · `wscale` k0+8→k0+9 · **`ev_up` 与 wscale 同一边置位**（`:192/:195/:196`）· **`cfg_up` 清位落地 k0+9→k0+10** ⇒ **陈旧 `whi` 暴露窗 = 拍 k0+8、k0+9 = 2 拍**（有竞争只会整体拉长、**相对间隔不变**）⇒ ⛔ **v2 的"≈1–2 拍"下限写松了**（1 拍不可达）。
  - **窗口内的安全性 = 钳位 ∪ 既有 `ring_ovf`（【v3 归因订正 · 审查 §5 采纳】）**：窗口内 `snd_nxt == snd_una`（两者重基仅差 1 个字段写）⇒ `svc_rewind = 0` ⇒ **FIN 支在窗口内结构性不可选**（⇒ **R4 的 FIN 角不是走这条窗，而是走"真·零数据 + FIN"那条**，见 §3.2-(5)）；钳位两分支：**accept**（陈旧 `whi` 落后）⇒ `ring_hi = whi` ⇒ `ring_delta` 巨大 + **既有 `ring_ovf = 1`** ⇒ 不重放；**reject** ⇒ 退回 `rb_snd_nxt` ⇒ `ring_delta = 0` ⇒ 不重放；`ring_restore` 两分支下恒 0 ⇒ **窗口安全** ✔
    ⛔ **v2 把这段归因写成"由钳位兜住"** —— 不精确：**accept 支靠的是既有 `ring_ovf`**（钳位只新增覆盖了"`(snd_nxt − whi) ≥ 2^31`"那一半）⇒ v3 改为"**钳位 ∪ 既有 `ring_ovf`**"。
  - ⇒ **处置 = 解决（钳位 ∪ `ring_ovf`）+ `cfg_up` 清位保留为纵深防御** ✔
  - ⚠️ 边界（如实登记）：`slow_cfg_adp` 的这段是**我给板侧读的**；TB 侧 `tb_tcp_tx_ovl.v` 的 setup FSM 是**另一份**（`tb:1019-1041` 的 `scfg_upd_sel` 序列 + `:1040` 的 `cfg_up`），两处**顺序同向**（先写字段、后 cfg_up）但**不是同一份代码** ⇒ 门与板的一致性由 §5 的"要求 `whi_r` 清位与重基的顺序"这条**不做**依赖（钳位不依赖顺序）【事实】。

### 3.5 三条**不许动**的既有口径（否则打红既有判据 / 夺既有语义）

1. **`retx_ovf` 保持指向 `retx_hi`**：TB 的 `e_f1_cyc`（**生成条件 `tb:2034`** = `if (d_ring_act && d_retx_ovf) begin`、`:2035` 计数 ⇒ 【v3 行号订正：v2 写 `:2025`，那是 `e_f1` 信息计数的计数行】；`:2230` 在 `tot_red` 和式内 = **硬红**）与 `e_f1_ring`（`:2306`）都按 `u_dut.retx_ovf` 取值 ⇒ 改它的口径 = 改判据对象。**本刀不动它**；环侧另立 `ring_ovf` ✔
2. **`stat_retx_wrap`（F1 计数器）不动**：它数的是"会话期 `snd_nxt` 越过 `retx_hi`"（`:1068-1071`）⇒ 口径不变（本刀不碰 `retx_hi`）✔
3. **`o_retx_hi` / `o_retx_active` / `o_retx_id`（`:984-985`、`:982`、`:983`）不动** ⇒ 快照 **W57/W58** 与 `tcp_rx.ack_hi` 逐位不变 ✔
4. **【v2 新增·审查 A6-3】** ⭐ **`whi_r`（本修法的新量）与 §1.6 用来做证据的探针 `wrhi`**（`patch_oracle_v6.py:80-81` 在**写口取 max**）**不是同一个量** ⇒ **引用探针量给本修法背书时必须注明口径差**（v1 没注，v2 补）：
   | | `whi_r`（本修法） | 探针 `wrhi`（`patch_oracle_v6.py:77-81`） |
   |---|---|---|
   | 取法 | `upd_wr_data && !retx_active` 拍的 **TCB 推进值** `f_seq + f_plen` | `wr_en` 拍**逐笔取 max**（`o_wrhi[w_c] <= o_wseq32 + o_wn`） |
   | 含"已承诺但未成帧"？ | **不含**（半帧中止/超长中止不写 TCB ⇒ 不计） | **含**（`wr_tap` 写了就计） |
   | 在飞活帧期 | = 上一帧的数据端（可能 < `snd_nxt`） | 可短暂 **> `snd_nxt`** |
   ⇒ 两者**在"帧内中止"与"在飞活帧"两处会分叉** ⇒ 本修法要的量是**前者**（"已承诺的数据端"语义）；日志里的 `wrhi`/`nxt_minus_wrhi` 是**后者** ⇒ **不可拿探针值当 `whi_r` 的实现真值**（方向性结论不受影响，只影响量纲口径）。

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
- ⚠️ **代价不对称（必须写清）**：else 支**没有** `replay_jump/upd_wr_rew` 这套写源结构（§3.3）⇒ 镜像 = **给该支加它自己的第 3 个 TCB 写源**（OVL 支是在既有 3 源上"改一个条件"）⇒ **else 支的改动面更大**。
  ⚠️ **【v2 措辞订正·审查 C1】**：v1 写"第 4 个"是含 OVL 的口径（OVL 支加完确实是 4 源），**else 支自身是 2 → 3 源** ⇒ 两处口径必须分开写，否则实施轮点不清。

### 4.3 ⭐ 本缺陷在**默认支**里存不存在 / 可不可达

- **存不存在** ⇒ **存在（源码级）**：`:1791-1792` 的 `+1`、`:2162-2163` 的继承、`:1631/:1638` 的重放范围，三处逐字同款【事实】。
- **可不可达（板/默认配置）** ⇒ **结构性不可达**【事实】：
  - 板上**唯一**的 `tcp_tx_frame` 例化（`board/wrapper_p4.v:2150`）拿到的 `tx_ack_syn/ack_fin/ack_rst = 1'b0`（`:2101-2103`，**在 `ifdef APP_MODE` 之外、无条件**）；
  - 非 APP_MODE（= 默认构建）下 `tx_fin_req = tx_rst_req = 16'h0`（**`:2121-2122`** —— ⛔ **v1 写 `:2124-2125` 是错的，v2 订正**；`else` 块起于 `:2120`）⇒ 本模块**没有任何控制帧源** ⇒ `upd_wr_ctrl` 恒 0 ⇒ `drift ≡ 0` ⇒ **else 支在本板的默认配置里写不出幽灵**。**【v2 加证】**：矩阵侧同款（`tb/tb_p4_chain.v:196/788-789` 全钉 0，§4.4）⇒ **"不可达"这条有两处独立现核** ✔
  - OVL 支（**板构建编的那一支**，`board/build_p7b_ku5p.tcl:153` `TCP_TX_OVL=1`）拿到的是 `APP_MODE` 下的 `fin_req/rst_req`（`:2112-2115`）⇒ **板上唯一的漂移源 = FIN/RST 推**（FIN 重推 / abort RST）⇒ 缺陷**可达**（已由 TB 复现）。
- ⚠️ **未定**：矩阵的 chain 族 TB（`tb/tb_p4_chain.v`）是否在 else 支注入控制帧 —— 我**未**逐个读 TB 激励（见 §9-U4）。这决定"镜像是否有门可测"。

### 4.4 ⭐ 常驻 P4 矩阵对本刀覆盖多少（逐字核）

- **配置面**：矩阵 **17 门**（`sim/p4gates/run_matrix_p4dfix.bat:184-211` 的 `call :gate` 行）**全部** `-d APP_MODE`，**不含** `TCP_TX_OVL`（逐字：`:206` "**CONFIG COVERAGE = `-d APP_MODE` ONLY (single-domain / legacy branch)**"、"It does NOT cover the board wrapper configuration (DP_156MHZ), does not compile PCIE_OBS / P7B_10G / UDP_TX_OVL, and **with TCP_TX_OVL off the r6 tcp_tx_frame `ack_seen` start gate is NOT in it either**"）。
- **编到 `rtl/tcp_tx_frame.v` 的门**：（我核过源码清单）`chain_src.f` + `p5wrapper_src.f` 两个文件表都含 `rtl/tcp_tx_frame.v` ⇒ **12 条 chain 族门（chain/burst200/trunc50/trunc100/halfdrop/txdrop50/gate4096/dupstorm/pcackoob/vlanchain/vlanburst/stallgate）+ `p5_wrapper` = 13 门**覆盖它。
- ⇒ **结论（三条，必须写清）**：
  1. **矩阵覆盖的是 `else` 支**（无 `TCP_TX_OVL`）；
  2. **OVL 支（= 板构建那一支）在常驻矩阵里 0 覆盖** ⇒ 若只改 OVL 支，则**本刀的改动面完全在常驻回归网之外**；
  3. **镜像是唯一能让本刀的改动落进常驻矩阵的选法**；⚠️ 但**矩阵的 13 门不测幽灵**（它们没有"FIN/RST 后重放"的激励，且默认配置下 `drift ≡ 0`）⇒ **"矩阵绿"不是本刀的判据**，只是"没把别的东西改坏"的回归网。**判据面 = 臂 S/T（§5）**。
- ⭐ **【v2 新增·U4 = 定，逐字现核】**：**矩阵 13 门里连到 `tcp_tx_frame` 的那个例化把全部控制帧源钉 0** —— `tb/tb_p4_chain.v:196` `wire tx_ack_syn = 1'b0;` + `:788-789` `.ack_fin(1'b0), .ack_rst(1'b0), .fin_req(16'h0), .rst_req(16'h0), .o_fin_sent(), .cfg_up(1'b0), .cfg_up_id(4'd0),`（注释逐字："P5: FIN/RST 发送通道本门不驱动 (fin_req/rst_req 接地 = P4 行为不变)"）⇒ **else 支在矩阵里 `drift ≡ 0` 且无洞** ⇒ **镜像对幽灵 = 无门可测、空动作**；它的收益 = **代码一致 + 回归网（"没改坏别的"）+ 防未来**（有人给默认支接上控制帧源）。
  ⇒ **镜像的决策因此从"覆盖"降为"一致性"**（审查 C2/C3 的结论一致）；⚠️ 若 TL 因此选择**不镜像**，本件要求：**在 `P7B_OPEN_ITEMS.md` 登记 else 支为 latent（未修 + 不可达）**（⛔ 我不改那份文件 —— 边界）。**我的建议仍是镜像**（F1 先例 + 双支漂移纪律），但**理由要按本条写**。
- ⚠️ 另：**"改 RTL" 与 "在跑回归" 互斥**（全局 #57）⇒ 本刀实施前必须先确认矩阵没在跑，或改完重跑整轮。

---

## §5 观测量 / 判据 / 门 + 负对照

### 5.1 观测量：**复用既有，不加新快照字**

⛔ **不加新字**：本工程"加一个重要快照字"要走整条读侧同步（`P7B_BIZ_WINDOW.md` §2 的"五处同改" + 构建 F 轮实测 **20 文件 / 56 处**）⇒ **本刀零新增字**。可用既有字：
- **W55** = `tcp_tx_frame.stat_retx`（回卷会话**次数**，`P7B_BIZ_WINDOW.md` §1 逐字）⇒ **非空见证**（"本窗真的发生过重放会话"）。
- **W57** = `tcp_tx_frame.o_retx_hi`（回卷重放上界，**只在 `retx_active=1` 时有效**，同表逐字口径）· **W58** = `o_retx_active`。
- **W59/W60**（两个适配器 ovf，恒 0 守卫）· **W5/W43**（时基与 tx 拍钟，速率口径）· 对端侧 = NIC/内核计数 + sink 的逐字节校验。
- ⚠️ **本刀不改 W57 的语义**（§3.5-3）⇒ W57/W58 的读法逐字不变。

### 5.2 判据（**主判据 = 既有 J3/J4**，零 TB 改动）—— **【v2 重写：判据口径按门契约切开】**

- **J3（载荷逐字节）= `e_payload`**（生成处 `tb/tb_tcp_tx_ovl.v:800-806`；**已在 `tot_red` 白名单和式内** `:2228-2232`）。
- **J4（seq 连续性）= `e_seqcont`**（生成处 `tb:787-798`；**同在和式内**）。
- **改前必红（在案）**：臂 S `payload=3 seqcont=1`（`ev/gate4_stdout.txt:**433-437**` 的 5 条 `[FAIL]` 逐字；整块 `:432-440`。【v3 行号订正：v2 写 `:436-440`】）；臂 T `payload=14`（`ev/orT_oracle_v5_xs.log:3465`）⇒ **"能演示改之前会红"这条已经满足**，无需新造。
- ⭐ **"本刀达成"的**可判定**定义（v2 重写；⛔ 替代 v1 的"改后必须 = 0"）**：
  **`J3/J4` 幽灵红里**本修法可治的 3 条**清 0** —— 即：
  `[S#2]`/`[S#3]` 那族 = `[FAIL] seq partial conn=1 seq=0004e59c plen=29 exp=0004e5a4` · `[FAIL] payload conn=1 seq=0004e59c off=8` · `[FAIL] payload conn=1 seq=0004e5a4 off=0`；
  **修后这 3 条必须消失**（复算见 §5.5 行 2/3/4）。
  ⛔ **不在本判据内、也不许算作"修没修好"的**：
  - **第 1 条**（`[FAIL] payload conn=0 seq=000de510 off=0`）= **形态②（区间内洞）**，本修法**覆盖不到**（§1.1b / §5.5 行 1）⇒ **残留**；
  - **第 5 条**（`[FAIL] PS j8 空判据: epoch 未饱和 (blocked 见证=0)`，`ev/gate4_stdout.txt:437` 逐字）= **persist 族**（`PERSIST_NEGCTL`/`ARM_PERSIST` 的 PS 判据组），**不属本刀**；⚠️ **它是否受幽灵影响 = 未定**（审查 D2 明示"我没有证据"）⇒ **不许默认它会被本刀清掉**。
- ⛔ **T 臂的口径（v2 推翻 v1）**：门契约逐字（`sim/p7b_stagec_tx_regress/author_gate/run_tx_ovl_gate.bat`）：
  `:114 echo   S PERSIST clean arm     RC=%RCS% (expect 0; ARM_PERSIST)` ·
  `:115 echo   T PERSIST negctl        RC=%RCT% (expect nonzero; PERSIST_EN=0)` ·
  `:138 if not "%RCS%"=="0" set /a FAILS+=1` · `:139 if "%RCT%"=="0" set /a FAILS+=1`
  ⇒ **T 臂按设计必须保持非 0**（`TB_PERSIST_EN=0` ⇒ PS 判据组必红，`orT_oracle_v5_xs.log:3482-3488` 逐字 7 条 PS 红）⇒ **v1 的"T 臂也必须绿"与门自身冲突**。
  **正确口径**：**T 臂的 `payload` 项应回 0**（那才是幽灵族），**但 T 臂的 RC 必须继续保持非 0** ⇒ 本刀**不**能、也不该把 `TX_OVL_GATE: FAIL count=1` 变成绿。
- ⇒ **诚实收口**：本刀的可判定达成 = "**S 臂 5 条红里 3 条幽灵红清 0（且 `e_ghost ≡ 0`，见 §5.4）+ 其余 2 条各有归属（1 条残留 / 1 条 persist 账）**"；门级 `PASS` 不在本刀范围内。
- ⭐ **【v3 补】判据面还必须含"TB 前沿耦合"两条支路**（`e_j9` / `e_seqcont` 的前沿侧）—— 机制与逐条依据见 **§5.5 的 v3 新增块**；本跑预期：`e_j9 = 0`（靠跑长）、`e_seqcont` 的 seq-hole 新红**未定**（§9.5-V3 现核）。**不含这两条的"达成"定义不完整**（v2 口径即缺此）。

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
⇒ ⛔ **【v2 订正】v1 在这里的建议"先不加新计数器（J3/J4 已经够）"已被**推翻**（审查 D4 成立）**：只靠 `e_payload`/`e_seqcont` ⇒ **没有仪器区分"红#1 是残留（洞）"与"修法没生效"**（两者都表现为 payload 红）。⇒ **v2 的口径 = `e_ghost`（§5.4-②）+ `e_ringhi`（§5.4-③）都**必须加**，且**都必须走本节的三处**（声明 / 检测 / **`tot_red` 白名单和式**）。

### 5.4 建议的门 + 负对照 —— **【v2 重写：加 `e_ghost`（审查 D4）+ 修 N-2（审查 D5）+ 加两条变异】**

**① 主门 = 既有 `author_gate` 的 S/T 两臂**（两臂 defs 真值源 = `_proj_10g/notes/p7b_persist_impl/rerun_oracle.bat`）⇒ 判据 = §5.2 的"**3 条幽灵红清 0**"（**不是** S 臂全绿 / 不是门 PASS）。⚠️ 它**非常驻** ⇒ 建议同批把它登记（写 `P7B_OPEN_ITEMS.md` 或常驻矩阵；⛔ 我不在本件里改任何门/清单 —— 边界）。

**② 【v2 新增·必做】定向仪器 `e_ghost`（审查 D4；不加就没有仪器区分"红#1 是残留"与"修法没生效"）**
- ⭐⭐ **【v3 取样点钉死 —— 审查 §2.1 采纳（阻断级）】判据 = 在**线上帧尾拍**直读 `u_dut.whi_r[t_conn]`（不锁存）**：
  - **天然落点已经是对的**：`frame_check`（task 定义 `tb:612`）的**唯一调用点 = `tb:870`，且包在 `if (m_tlast)` 里**（我现核逐字：`:869 if (m_tlast) begin` / `:870 frame_check;`）⇒ **检查块天然在帧尾
执行**。
  - **为什么帧尾读安全且正确**：① **活帧自抑制** —— 活帧的 `whi_r` 在其 **RX_FIN** 落地（`:625` 的 `upd_wr_data` 拍），而该帧**上线**的尾拍要再等 ≈180+ 拍（TX 从 bank 发）⇒ 帧尾读时 `tail − whi ≤ 0` ⇒ 活帧**不可能误报**；② **重放帧无差别** —— 会话期 `whi_r` **冻结**（§3.2-(4) support(ii)：会话期无活帧）⇒ 帧尾读与帧首读**同值** ⇒ **没有"可漏"**。
  - ⛔ **v2 那句"必须在帧首拍锁存，不能在帧尾读"是**反的**，两种实施方式都会翻车**：按"该帧被**分类**的那一拍"锁存 ⇒ **每条活帧必误报**（`tail − whi_old = plen ∈ (0, 2^31)`）；按"线上首拍"锁存 ⇒ 与 `whi` 落地存在 **1–2 拍竞争**（TX 起步 ≈ RX tlast+2~3 vs `whi` 落地 = RX_FIN 首拍+1）⇒ **非确定性地误报**。⇒ **按帧尾直读实施**（若将来坚持锁存，必须把锁存拍写明为线上首拍并把竞争面显式豁免）。
- **判据语义（半区判据，帧尾口径）**：一个数据帧若满足 `(fseq + plen − whi_r[t_conn]) < 2^31` 且 `!= 0`（回绕安全：**帧尾越过了该连当前已写高水位**）⇒ `e_ghost++`。
- **它靠什么独立于幽灵的可达路径（审查要求的"非空判据"）**：
  - (a) **与 `e_payload` 独立**：`e_ghost` 只依赖 **DUT 的高水位寄存器 + 线上帧的 seq/plen**；`e_payload` 依赖 **TB 的图案函数 `fb()`** ⇒ 两条不同链；
  - (b) **有牙（正控）= 变异 M-3**：把 `ring_hi` 换回 `retx_hi`（= 退回缺陷语义）⇒ `e_ghost` **必须 > 0** ⇒ 声明的牙在**变异臂**上；
  - ⛔ **(c) v2 的那条（"把 `whi_r` 改为永不更新"）**已删**（审查 §2.2 推翻）**：它演示的是**沉默**（`whi ≡ 0` ⇒ 钳位退回 ⇒ `ring_ovf` ⇒ 永不重放 ⇒ `e_ghost ≡ 0`）⇒ 那是"不误报"的证据、**不是一条可命中的路径** ⇒ 不能当牙。
- **改前计数 = 2（【v3 关闭 N1】· 审查 §2.4 采纳）**：① `[S#1]` 是**重放帧**（首字节 = −1 圈值）⇒ 其 `tail ≤ retx_hi`（`:1146`/`:776`）；② conn0 的**每个**会话装载拍 `retx_hi == wrhi`（`ev/orS_oracle_v6_xs.log:390` 逐字 `kind=RS c=0 … retxhi_minus_wrhi=0`）⇒ `tail ≤ whi` ⇒ **不命中**；③ `[S#2]`/`[S#3]`（tail = 246457 > whi = 246436）⇒ **命中 2 条**；④ conn1 那两个会话各只生成 1 帧（`ring_delta = 29/21`）⇒ 无额外跨界帧 ⇒ **`e_ghost`(改前) = 2**（⚠️ 残余不确定 = 1 字节幽灵帧的字节巧合可让命中 > 红数；本跑两帧 21/29 B ⇒ 概率可忽略）。
- **判别规则（v2 的核心用途）**：修后
  - `e_ghost ≡ 0` **且** `e_payload/e_seqcont` 的可治幽灵红清 0 ⇒ **达成**（§5.2 口径 —— ⚠️ 但须叠加 §5.5 的**前沿耦合**条目）；
  - `e_ghost ≡ 0` **但仍有** payload 红 ⇒ **那些红 = 形态②（洞族）** ⇒ 归**残留**（§9-R1），**不是**"修法没生效"；
  - `e_ghost > 0` ⇒ **修法没生效/被绕过** ⇒ 直接判"未达成"。
- **落地（三处，缺一不可 —— 全局 #53 哑门陷阱）**：(a) 计数器声明（`tb:232` 那一族 `integer e_…`）、(b) 检测点（**帧尾**：在 `frame_check` 的帧检查块内加，锚 `tb:781-830`；`kk = 1536;` 在 **`:827`** ⛔ v2 写 `:822` 错）、(c) **`tot_red` 白名单和式 `tb:2228-2232`** + **`:2267`** 的 `REDS` 显示行（⛔ v2 件内两处写成 `:2269`，真值 = `$display("REDS parse=…")` 起点 **`:2267`**，`:2269` 是它的**参数行**；v3 统一到 `:2267`）。⛔ **只做 (a)(b) ⇒ 再红也不进末行**。
- ⚠️ **v1 的"先不加新计数器"已被推翻**（那会让判据面只剩 `e_payload`，无法区分残留 vs 失效）。

**③ 【v2 新增·A4 的配门】不变式门 `e_ringhi` —— 【v3 收窄 + 显式豁免 + 改判据口径（审查 §2.5 采纳）】**
- **判据（收窄后）**：在**每个 `svc_x` 拍**（DUT 内部量，TB 已按先例直引），要求 **`ring_hi` 的将装载值 ≤ `retx_hi` 的将装载值**（同一拍操作数、回绕安全比较），**但**：⛔ **仅当"钳位接受支 + 非 FIN 支"时计入**（等价地：**把 R4 角显式豁免**）—— 即豁免条件 = `(钳位判假) ∧ (fin_sent_r[svc_id] && svc_rewind)`（R4：`whi=0` + FIN 支 + `snd_nxt ≥ 2^31` ⇒ 退回值 `fin_seq+1 > retx_hi = fin_seq`，**无功能实害**，见 §3.2-(5)/§9.1-R4）。
  - ⛔ **为什么必须豁免（审查 §2.5 的关键点）**：不豁免 ⇒ **板上 ~50% 量级的假红**（ISN 随机）⇒ 那就是本工程最忌的"**把真红解释成判据问题**"的翻版。⇒ **豁免写进判据本体（不是事后解释）**。
- **改后会不会恒 0（【v3 订正】）**：**"结构性恒 0"过强** —— ① TB 臂内应恒 0（`tb:280-281` 的 ISN 硬编码全 `< 2^31` ⇒ R4 角不可达）；② **板上不是**（ISN 随机）⇒ 所以恒 0 只在"豁免后的判据"上成立。**该门的作用** = 防未来有人改 `whi_r` 的更新面/钳位条件（症状 = G9 类自持重放洪水，见 §3.5-1 的 F1 保护面）。**必须进 `tot_red` 和式**（三处惯例同 §5.3）。
- ⛔ **改前对它 = 空判据（【v3 订正】审查 §2.5 采纳）**：`e_ringhi` 检查的是 `ring_hi`（**本刀新信号**）的不变式 ⇒ **改前 `ring_hi` 不存在** ⇒ "改前跑一次"是**空动作**（TB 无信号可引）。⇒ **牙只能挂变异臂**：**M-5（新）** = 拆掉钳位（`ring_hi <= whi_r[svc_id]` 裸取）+ 把 `whi_r` 注入一个陈旧大值（或 `whi=0` + 造 `snd_nxt ≥ 2^31` 的激励）⇒ `e_ringhi` **必须命中**。（⇒ §9.4 的 N2 测试计划据此改写。）

**④ 负对照（v2 重写）**
- **N-1（改前臂）**：worktree/`git stash` 版跑同一门 ⇒ 必红（在案：S `payload=3 seqcont=1`，`gate4_stdout.txt:433-437`）；⛔ **必须与"改后"同会话同配置**。
- **N-2（v2 推翻 v1 的"drift≡0 作无幽灵正控"）**：审查 D5 成立 —— 按 §1.1b，**`drift ≡ 0` 不保证无幽灵**（conn0 就是 `drift ≡ 0` 而出了 1 字节旧值）。
  **改成**：正控口径 = "**该跑内所有重放区间的读址都落在'本圈写过且非洞'的 seq 上**" ⇒ **这条需要洞的可观测性** ⇒ 由 `e_ghost`（判"越过"）+ 剩余 payload 红的**位置分类**（`off==0` 且其后同圈 = 洞族 vs 失配延伸到帧尾 = 尾段族）承担；**判据必须带非空见证**：该跑至少有一次 `ΔW55 > 0` 的会话**且**该会话区间非空（否则"绿"是**空判据**）。
- **N-3（变异门，【v3】补指名判据 + 新增 M-5）**：
  ① `ring_hi <= whi_r[svc_id]` → `ring_hi <= 32'hFFFF_FFFF`（或去掉钳位）；
  ② **M-3**：`ring_hi` 换回 `retx_hi`（退回缺陷语义）⇒ **验 `e_ghost` 有牙**（预期：`e_ghost > 0`）；
  ③ **M-4**：**去掉 `ring_restore`** ⇒ **指名判据 = `e_replay_jump`**（审查 §3-3 采纳；真值现核：判据 B 的注释在 `tb:2130-2132`（逐字"⭐ P7B-RETXFIX 判据 B (收尾跳写): 会话结束时 snd_nxt 不得低于 retx_hi"）、**判定行 `:2133-2134`**（`if ((u_tcb.snd_nxt_r[j9_conn] - rep_hi_w) >= 32'h8000_0000) e_replay_jump = e_replay_jump + 1;`）、**在 `tot_red` 和式内 `:2231`**）⇒ 去 `ring_restore` 后 `snd_nxt = whi < retx_hi` ⇒ **确定性命中**（⛔ 不指名 ⇒ M-4 是**哑门**）；
  ④ **M-5（新，给 `e_ringhi` 有牙）**：拆钳位（裸取 `whi_r`）+ 注入陈旧大值 / 造 `whi=0 ∧ snd_nxt ≥ 2^31` 的激励 ⇒ 验 `e_ringhi` 命中（见 §5.4-③）。
  ⚠️ **CRLF 锚点**：`rtl/tcp_tx_frame.v` 是 CRLF（2040 个 CR）+ 既存锚点陈旧（`P7B_OPEN_ITEMS.md` §4 登记 G3 门跑不通）⇒ 变异必须按 `\r\n` 写锚点（**U5 = 定：这条作为变异的前置纪律**，不另做 `.gitattributes` 归一化 —— 那会动全仓行尾，属另一刀）。

### 5.5 ⭐ S 臂 **5 条**红的逐条去向（**【v2 重写：4 条 → 5 条；行 1 由"会绿"改为"修不掉"】**

⛔ **v1 在这里栽了一次**：只枚举 4 条、且判 `[S#1]` "两种可能都绿" —— **两者都错**（审查 A2/D2 成立）。v2 逐条：

| # | 红（`ev/gate4_stdout.txt:433-437` 逐字） | 形态 | 修后预测 | 去向 |
|---|---|---|---|---|
| 1 | `[FAIL] payload conn=0 seq=000de510 off=0 got=cf exp=6b @317103` | **形态②（区间内洞）**：首字节 = 上一圈、**其余 15/16 = 本圈**（`q1_*` 逐字）⇒ 洞在帧**首**、其上还有本圈数据 ⇒ **洞在高水位以下** | ⛔ **修不掉**：候选 B 不改 `seq → 地址` 映射、不改帧起始 seq ⇒ **该帧照旧生成、照旧读到旧字节**（v1 的 case②"首字节改读本圈地址"**推翻** —— 地址不变） | **残留 R1**（§9；板结构性不可达） |
| 2 | `[FAIL] seq partial conn=1 seq=0004e59c plen=29 exp=0004e5a4 @347515` | **形态①（尾段漂移）** | 修后 `ring_delta = whi − snd_nxt = 246436 − 246428 = 8` ⇒ `plen = 8` ⇒ 帧弧 [246428, 246436) = **恰好接上前沿** ⇒ **绿** | 达成判据（§5.2 的 3 条之一） |
| 3 | `[FAIL] payload conn=1 seq=0004e59c off=8 got=2d exp=9f @347515` | 形态①（同上帧的 `off ≥ 8` 段） | 同 2 ⇒ 该帧不再含幽灵 ⇒ **绿** | 同上 |
| 4 | `[FAIL] payload conn=1 seq=0004e5a4 off=0 got=2d exp=9f @353173` | 形态①（plen=21 的整段幽灵帧） | `ring_delta = 246436 − 246436 = 0` ⇒ **该帧不再生成** ⇒ **绿** | 同上 |
| 5 | `[FAIL] PS j8 空判据: epoch 未饱和 (blocked 见证=0)` | **persist 族**（PS 判据组的空判据守护） | **不属本刀**；⚠️ **是否受幽灵影响 = 未定**（审查 D2：无证据） | **persist 账**（§9-R3） |

**⭐⭐ 【v3 新增 · 审查 §3-2 采纳：修法与 TB"对端前沿"模型耦合 —— §5.2/§5.5 的"清 0"预测**不完整**】**
- **【事实】TB 的"对端前沿" `exp_new` 的**全部**推进支**（我现核；审查说"赋值点仅 4 处" = **对**，但其中一处的行号有小误）：
  | # | 行 | 语义 |
  |---|---|---|
  | 1 | `tb:274` | 复位清零 |
  | 2 | `tb:701-702` | **SYN**：`if ((fseq − exp_new[t_conn]) < 2^31) exp_new[t_conn] = fseq + 32'd1;`（消耗 1 个 seq —— 注释逐字"SYN 消耗 1 个 seq => 发侧前沿 (exp_new) 与对端前沿都要 +1"） |
  | 3 | `tb:782-784` | **in-order 数据帧**：`if (fseq == exp_new) exp_new = fseq + plen;` |
  | 4 | `tb:1051`（⛔ 审查写 `:1052`，**真值 `:1051`**） | 建连：`exp_new[setup_c] <= isn[setup_c] + 32'd1;` |
  ⇒ **FIN/RST 不吞 seq**（无对应的 `exp_new` 更新）⇒ **前沿只能被"in-order 数据帧 + SYN"推**。
- **【事实】pre-fix 下正是**幽灵帧**把前沿推过漂移区**：`[S#3]` 那帧 `fseq == exp_new = 246436` ⇒ 命中 in-order 支 ⇒ `exp_new ← 246457`（= 漂移区顶）—— 这也是 pre-fix `J9 = 0` 的成因（`ev/orS_oracle_v6_xs.log:2710` 逐字 `… F1_ring=0 J9=0`）。
- **【推断】post-fix ⇒ 漂移区永不作数据上线 ⇒ 该连前沿**停在 `whi`**，两条后果**：
  - **(a) `e_j9`（**在 `tot_red` **双计****：和式 `tb:2230` + 独立判定 `tb:2308-2309`，逐字 `[FAIL] J9: 会话结束后 60k 拍内对端前沿未达 retx_hi`）的前提不成立**。
    ⚠️ **本跑仍应为 0（"跑长兜住"，不是"判据无影响"）**【推断】：S 臂跑长 = `cyc=386286`（`ev/orS_oracle_v6_xs.log:2697` 逐字 `FRAMES recv=2502 data=2100 ctrl=402 … cyc=386286`），末个漂移会话 ≈353.2k ⇒ 期限 ≈353.2k + 60k = **≈413k > 386.3k** ⇒ 落在跑长之外。⇒ **延长跑长 / 缩短期限 / 换 TB 即变红**。
  - **(b) 后续**活帧**可能变 "seq hole" 新红**：`ring_restore` 把 `snd_nxt` 提到 `retx_hi` 之后，后续活帧的 `fseq = retx_hi > 前沿 = whi` ⇒ 落 `(fseq − exp_new) ∈ (0, 2^31)` ⇒ 走 **else 支**（`tb:794-798` 的 `[FAIL] seq hole`）⇒ **`e_seqcont` 新红**（在 `tot_red` 和式内）。⚠️ **本跑是否命中 = 未定**：conn1 已被 RST 封（`tx_blk ⊆ rst_sent_r`，`rtl/tcp_tx_frame.v:547`）⇒ 可能为 0；**347.5k–353k 之间 conn1 有无活帧 = 审查未现读、我亦未逐拍读** ⇒ 见 §9.5-V3。
- ⇒ **判据面必须含这两条支路**（`e_j9` / `e_seqcont` 的前沿侧），否则验收会被新红打断而无人能判。

**⇒ 本刀的可判定达成 = 行 2/3/4 清 0（配 `e_ghost ≡ 0`）** **＋ 【v3】接受上述耦合带来的两类**预期变化**：① `e_j9` 在本跑仍为 0（靠跑长；⚠️ 若换更长的跑 ⇒ 需按此条重判）② 若 (b) 命中 ⇒ 那是**本刀的预期后果**（前沿停在 `whi`），必须**逐条登记其 `(conn, seq, cyc)` 并归入"前沿耦合"账**，**不许当回归**。**

⚠️ **两点保留（v2 保留并加严）**：
- **T 臂 14 条 payload 只有 3 条落盘**（打印上限 `if (e_payload < 4)`，`tb:804`）⇒ **T 臂"全绿"属【推断】**（三条落盘签名 = `conn=0 seq=00140c02`、k=−1，`q1` 已复算 ⇒ 同源）；且 ⛔ **T 臂的 RC 必须保持非 0**（§5.2）。
- 若修后仍剩红，**必须先看它是不是"形态②归残留"还是"另一条独立成因"**（用 `e_ghost` 分流，§5.4-② 的判别规则）—— **不许先改判据**。

---

## §6 板级怎么测（零窗造法 / 台架翻面 / 判据不许钉在"先大窗再塌"上）

### 6.1 台架现状（逐字回件）

- **sink 已翻面**（`_proj_10g/notes/p7b_sinkfix_20261010/REPORT.md:13` 逐字）：`SO_RCVBUF` 的落点已移到 `connect()` **之前**（默认 = 修复后行为），旧行为（先通告大窗、随后才塌）由开关 **`--rcvbuf-after-connect`** 逐字复现（`:70/:79`），并打见证行 `SINK_RCVBUF_ORDER RCVBUF_ORDER=before_connect|after_connect_LEGACY`（`:85-87`）。
- ⇒ ⛔ **凡要造历史那种小窗构型，必须显式带 `--rcvbuf-after-connect`**（否则默认臂会先通告大窗 ⇒ 板的首突发被对端自己授权 ⇒ 小窗被冲掉）。
- ⛔ **不许把判据建立在"先大窗再塌"上**（真 Linux 栈实测**未再现**，见同件 §4）。

### 6.2 ⭐ 三条构型（按"先证明会出幽灵"到"完整判据"排序）

**S-0（零构建 · **首步**）**：**证明"板上到底会不会出幽灵"**
- ⛔ **【v2 订正构型·审查 B3 成立】必须用 `abort RST` 造，不能用 close(FIN)** —— 逐条源码依据：
  - `fin_push`（`:952-954`）含 `(rb_snd_nxt == rb_snd_una)` 门 ⇒ FIN 的 +1 是**该连最后一笔**且落在 **fin 支**（`retx_hi = fin_seq`，`:1131`）⇒ **FIN 路径结构性 `drift = 0`** ⇒ **用 close 路径去测 = 结构性测不到形态①**；
  - `rst_push`（`:955-956`）**无**该门（`scan_now && rst_req && !rst_sent_r && !ackq_full && (rb_state == 4'd1)`）⇒ RST 的 +1 可以落在**数据之后、fin 支之外** ⇒ **板上唯一可达的形态① 源 = abort RST**（【推断】：drift = 1 笔；条件 = 该连仍 ESTAB + 对端未 ACK 越过该 seq + 起过一次会话）。
  - 构造：`app` 走 **abort（`CMD abort` → `app_ctrl.rst_req` → `rst_push`）**，并要求该连**保持 ESTAB**、其 `snd_nxt` 不被 ACK 越过、随后**起一次会话**（RTO/dup-ACK）。
- 台架：`p7b_tcp_sink --check lane8 --rcvbuf 2920 --rcvbuf-after-connect --conns 6 --seconds 60`（**显式**旧落点，与 sink 默认无关；数字沿用同件 §5 的"正控场景"逐字例子）。
- 观察（不需要新字）：`ΔW55`（会话数 > 0 = 非空见证）· `ΔW57/ΔW58`（`retx_hi` 有效拍）· **sink 的逐字节校验计数器**（`mism_bytes` / `first_mismatch`）。
- 判决口径：`mism_bytes == 0` ⇒ **未观察到**（**不许**写成"板上不存在"：也可能只是这次构造没造出 drift —— 形态①在板上的量级【推断】= **0 或 1 字节/事件**，见 §6.3）。
- ⭐ **这一步的优先级最高**：它把"板级有没有这条病"从推断降为观测，代价 = 一次现有的台架跑（零构建）。
- ⛔ **另有一条构造性提醒（B3 的推论）**：**形态②（洞）板上不可达**（§1.1b）⇒ **板级判据不可能覆盖全部幽灵族**；板级只能回答"形态①有没有、量级多少"。

**S-1（主判据构型 · abort RST + 慢读对端）**
- 目的：让**重放区间越过高水位**（形态①）。
- 必要条件（§1.4-会）：该连接**数据之后还有控制帧 +1** ⇒ 板上唯一可达源 = **abort RST**（S-0 的三条依据）⇒ 构造 = "**发数据 → abort(RST) → 让该连尾部长期不确认**（小窗/慢读）⇒ RTO 会话重放 `[snd_una, retx_hi)`，其尾段落在漂移区"。
- **判据**：sink 侧 `mism_bytes == 0`（**内容校验**是唯一能看见本缺陷的口径 —— 计数类判据结构性看不见，§1.5-①）。
- **非空见证（硬要求）**：`ΔW55 > 0` **且** `ΔW58` 在该窗内至少一次 = 1（确实起过会话）；**缺见证 ⇒ 按"未测"读**（本工程既有纪律）。
- **零窗造法与台架开关无关的写法**：**两种都可以，但必须选一种并写进判据**：① 显式 `--rcvbuf-after-connect + --rcvbuf 2920|1460`（确定性最好；⚠️ Linux 会把 `SO_RCVBUF` 双计并按 `rmem_max` 夹取 ⇒ **判"小值"看量级不钉字面数**，同件 §5 逐字）；② **SIGSTOP 住 sink 进程**（对端停止读取 ⇒ 自己的接收窗自然关死）—— 这条**不依赖 sink 的任何开关**，代价 = 跑完后 SIGCONT 并核对 sink 的墙钟/计数不变量。

**S-2（负对照构型 · 同一板同一时隙）**
- 关掉 `drift` 的来源：**只用数据、不发 FIN/RST**（纯长流档，例如 `TX_CONTINUOUS=1` 的 A/构建 F 档 + 不断流）⇒ 该跑**必须不出现**新增失配（`mism_bytes == 0` 且 `ΔW55` 可 > 0 —— 会话仍会起，只是区间不含幽灵）。
- ⇒ 这条是"**S-1 的失配是幽灵而非别的**"的对照臂。

### 6.3 ⛔ 未证的事（不许当已答）

- **板级可复现性 = 未证**（本轮零构建零板卡）：已证的只是"机制存在 + xsim 复现"。**S-0 就是去证它**。
- **板上 `drift` 的实际量级 = 未证**：TB 里是 1/21（同一个连接 22 笔控制帧）；板上 FIN 重推**先回卷再落 seq**（§1.4-不会-B）⇒ 可能只有 abort RST 或"慢路径已占一个 seq"（"每连接 2 FIN"登记项）才贡献 1 笔 ⇒ **量级可能是 1 字节级**。⇒ 判据必须容忍"少量"（登记件影响面逐字：个位～几十字节）。
- ⭐ **【v2 新增】板上可达性剖面（三行表，供下游引用）**：

  | 形态 | 板上可达？ | 依据 | 量级【推断】 |
  |---|---|---|---|
  | ① 顶部漂移 | **可达** | 唯一源 = abort RST（`rst_push` 无 `snd_nxt==snd_una` 门） | **0 或 1 字节/事件** |
  | ② 区间内洞 | **不可达** | 唯一路径 = `aq_syn` 型控制帧，而板上 `tx_ack_syn = 1'b0`（`wrapper_p4.v:2101`） | —— |
  | `ring_restore` 的"延迟洞读" | **待判**（依赖形态①是否在板上发生过 + 后续会话是否覆盖那个 seq） | §1.1b 的精度注 | 未定 |

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
**【v2 加验：钳位不破坏本命题】** `drift == 0` ⇒ `whi = retx_hi ≤ rb_snd_nxt`（非 FIN 支二者相等；FIN 支 `rb_snd_nxt = fin_seq + 1`）⇒ 钳位条件 `(rb_snd_nxt − whi) < 2^31` **为真** ⇒ **接受 `whi`** ⇒ `ring_hi = whi = retx_hi` ⇒ 上面各项同值 ✔（⇒ 钳位只在"陈旧/异常"时改变行为，不触无漂移路径）。

**可判定的取证（v2 重写：审查 A5 成立 —— v1 的"逐字对照"作**证据**不可用）**：
⛔ **v1 §7.2-1 被推翻（作为证据）**：修复**必然改变发出的帧集** —— `[S#3]` 那帧（21 B 全幽灵）修后**不再生成**（`ring_delta = 0`），`[S#2]` 的 29 B 帧缩成 8 B ⇒ 同一次 `author_gate` 里 `n_frames / n_data / DUT stat_* / wsrc rew / T8 rx1460,tx1460,fp1460,overlap` **不可能逐字不变**（而它们正是 v1 点名"应逐字相同"的量）⇒ 按字面执行 **必红**；豁免"修复本就要改的量" = **空判据**。
**替代（两条，审查给的口径）**：
1. ⭐ **在 `drift ≡ 0` 的**配置**上做逐字/位级等价**（不是"同一跑的某个子集"）：`drift ≡ 0` 的配置**结构性存在且已在盘** = ① else 支（矩阵 13 门 —— 其 TB 把控制帧源钉 0，§4.4 的 U4 现核）；② **worktree 锚**（= **不接本修法**的那一版源码，`git worktree` 重建）。
   ⛔ **【v3 删除一个无效锚 · 审查 §6-4 采纳】**：v2 写的"**把 OVL 臂的 `whi_r` 强制为 0**"**不成立**作为等价锚 —— `whi ≡ 0` ⇒ 钳位接受 ⇒ `ring_hi = 0` ⇒ `ring_ovf = 1` ⇒ **会话永不重放** ⇒ 输出与**改前/改后两臂都不一致**（它是"把功能关掉"，不是"等价"）⇒ **删**（保留 worktree 锚）。
   ⇒ 在这类配置上，改前/改后**同一激励**的输出流指纹必须一致（`SW_CRC` 级 / `fc /b` 逐文件 —— 本工程"同输入重跑 = 位级复现、方差 0"的既有纪律，`p7b_build_longflow/INDEX.txt` 逐字）。
2. **OVL 支只声明"条件式等价"并把数字变化**预期化**（v1 §7.1 的表述 ✅ 对，保留）**：即"`drift == 0` 的**会话**逐位不动；有漂移的会话**必然**改变帧集" ⇒ 门读数里的差异必须**逐项对得上**"哪些帧该消失、哪些该缩短"（这就是 §5.5 的 3 条预测），**对不上的差异才算回归**。
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
| LUT | **+100–250**（v2 上限上调） | 16 路写解码（≈16–30）+ `ring_ovf`/`ring_restore`（两份 32 位减+比较+mux ≈ 各 30–40）+ `upd_val`/`upd_id`/`upd_wr` mux 的加宽（≈20–60）+ **【v2】装载拍钳位**（1 组 32 位减+比较+mux ≈ 60–70，§3.2-(5)） |
| BRAM/URAM | **0** | 无新存储 |
| **锥形** | **不新增**（与今日**同型同深**） | `ring_delta`/`ring_ovf` 的操作数与今日 `retx_hi`/`retx_ovf` **同类**（都是寄存器 + TCB 组合读）⇒ 只见操作数换源，不见级数增加；`ring_restore ⊆ ring_eval` 与 `replay_jump` 同层 |
| 量级对照 | ≈ **1.04 个 persist 刀**（后者 ≈522 FF，`P7B_PERSIST_DESIGN.md:481` 逐字） | 便于 TL 直接比 |

### 8.2 风险（逐条给缓解）

| # | 风险 | 缓解 |
|---|---|---|
| R1 | **DP 域时序**：构建 F 的 DP setup WNS = **`+0.281`**，其宿**恰好是 `u_tcp_tx/u_retx/…/RSTRAMB`**（构建 F 块逐字：`u_clkgen/rel_sr_reg[3]/C → u_tcp_tx/u_retx/…/RSTRAMB`，纯布线）⇒ 而 `ring_start` **正是**喂 `retx_ram` 读口那条锥（`:774` `rd_tap = ring_start \|\| …`）⇒ **本刀正落在 DP 最差族上** | ① 设计上**不加级**（用同型判据，见 §8.1）；② **一次构建收口** + 构建后**定向查** `-from u_tcp_tx/u_retx/* -to u_tcp_tx/u_retx/*` 与 DP 前 10（成例 `P7B_A7_CSUM_SINK_DESIGN.md` §1.6）；③ 预留退路：把 `ring_restore` 的 `upd_wr_rew` 合并项退化为"下一拍"（+1 FF，需重证 §3.4） |
| R2 | **新写源进 TCB 写口**（OVL 变四源 / else 变三源） | 【v2 订正·审查 A6-2 成立】⛔ v1 写"OVL 的 `$onehot0` **断言已存在**"**与源码不符**：`grep -n "onehot\|assert" rtl/tcp_tx_frame.v` 只有 **3 行注释**（`:323`/`:618`/`:623`，逐字"逐拍 `$onehot0`"），**RTL 内没有任何 `assert`** ⇒ **没有"RTL 里加一项"这回事**。**正确处置**：既有检查在 **TB** = `e_onehot`（声明 `tb:232`、计数 `:1921-1926`、**在 `tot_red` 和式内** `:2229`、显示画在 **`:2267`** 的 `REDS` 行【v3 订正：v2 写 `:2269` = 该 `$display` 的参数行】）⇒ 实施轮要做的 = **给 TB 的 `e_onehot` 的判据集合加上 `ring_restore` 项**（即把"同拍恰一个写源"的检查扩到四源/三源）+ 走 §5.3 的三处惯例。 |
| R3 | **`whi_r` 语义被后人误用**（例如有人拿它当"已 ACK 高水位"） | 端口注 + 「只在活帧推进写时更新」写进注释；本件 §3.1 表即口径 |
| R4 | **`drift` 在别处也被消费**（本刀只改了环侧） | 已逐条核过 `retx_hi` 的全部消费者（`:984`/`:1131`/`:760`/`:765`/`:772`/`:1068` + `tcp_rx.v:320`）⇒ 只 `:760/:772`（环侧）改源，其余一字不动 |
| R5 | **板级可复现性未证**（最贵的风险：可能白做一轮板级） | **S-0 先行**（§6.2，零构建） |
| R6 | **矩阵与改动互斥**（全局 #57） | 实施前确认矩阵不在跑；改完跑整轮（13 门覆盖 else 支） |

### 8.3 ⭐ 与 persist 的先后关系（**唯一决策点，交 TL**）

**事实**（我核过 git 与源码）：
- persist 的 RTL **已在 HEAD**（`git diff --stat HEAD -- rtl board` = **空**；`PERSIST_EN` 等三个参数在 `rtl/tcp_tx_frame.v:299-301`），**尚未构建**；
  ⛔ **【v2 订正引注·审查 E1 成立】**：≈**522 FF** 的**真值源 = `P7B_PERSIST_DESIGN.md:481`**（逐字 "| **合计（v3）** | | **≈ 522 FF**（全 DP 域） |"；同件 `:115` 亦载同数）—— **v1 把出处写成 `P7B_OPEN_ITEMS.md` §A19 是错的**（我现核：该文件里 `grep -n "522"` 唯一命中 = 第 282 行 `165226` 这个计数的一部分，与 FF 无关）。"**尚未构建**"【事实】由提交时序佐证：persist 实施 `fd671b6`（2026-10-10 20:46）晚于构建 F 位流（当日 09:15）⇒ 不在任何位流里 ✔
- 它的**唯一打开点** = `board/wrapper_p4.v:2150` 的 `.PERSIST_EN(1'b1)`（注释逐字："回退点 = 这一处改回 `1'b0`"）；
- 用户已裁定（`P7B_OPEN_ITEMS.md` §1-A19 ④ 逐字转述）："**先修缺陷、再构建 persist**"。

**两种读法与代价**：

| 读法 | 做法 | 代价 | 我的建议 |
|---|---|---|---|
| ① **分离代价**（推荐） | 先：`.PERSIST_EN(1'b0)` + 本刀 ⇒ **一次构建** + 板级；再：`.PERSIST_EN(1'b1)` ⇒ **再一次构建** | **2 次构建**，但**时序代价可分离**（R1 的风险可控可归因） | ✔ **在 R1 已知落在 DP 最差族上的前提下，我建议①** |
| ② **同批**（省一次构建） | 本刀 + persist 同批一次构建 | **1 次构建**，但 WNS 变化**不可归因**（`#66`："WNS 是不同对象"）⇒ 若变差，需再拆刀 | 若 TL 愿承担"归因不明"，可用；**必须把两个代价合并报**（544 + 522 ≈ **1066 FF**） |

---

## §9 残留 + 未定（**【v2 重写】**：残留单列一节；U 清单逐条给裁定）

### 9.1 残留（**本刀不闭合**，如实登记 —— 用户裁定：**只收"板可达部分"的最小版**）

| # | 残留 | 内容（一句话） | 板可达性 | 为什么本刀不收 / 谁收 |
|---|---|---|---|---|
| **R1** | **形态②：区间内洞** | 数据流中段的一笔控制帧 `+1` ⇒ 写游标跳过那个 seq ⇒ 洞在**高水位以下**；重放区间覆盖到它就照旧读到旧字节（`[S#1]` 即此形） | ⛔ **不可达**（唯一路径 `aq_syn`；板上 `tx_ack_syn = 1'b0`，§1.1b） | **不在"板可达部分"内** ⇒ 用户裁定收最小版；若要收它需**新状态**（"预留 seq 位"要从重放区间里排除 —— 设计 + 代价重估，属**另一刀**） |
| **R2** | **`ring_restore` 的"延迟洞读"** | 排空拍把 `snd_nxt` 恢复到 `retx_hi` ⇒ 漂移区 `[whi, whi+d)` 成为永不写的 seq 位 ⇒ **后续会话**若覆盖到它就是新的洞读（缺陷由"立即发"变"**延迟**"） | **待判**（依赖①形态①在板上是否发生过 ②后续会话是否覆盖那个 seq） | 如实写明**不闭合**（审查 A3 成立）；⚠️ 精度注：**末态与今日逐字相同**（今日自然排空也停在 `retx_hi`），本修法改的是"那些位没被当数据发出去"（§1.1b 末）—— ⛔ **不许**据此把 R2 写成"已闭合" |
| **R3** | **`PS j8 空判据`（S 臂第 5 条红）** | `[FAIL] PS j8 空判据: epoch 未饱和 (blocked 见证=0)`（`gate4_stdout.txt:437` 逐字） | —— | **persist 族**（PS 判据组的空判据守护）⇒ **不属本刀**；⚠️ **它是否受幽灵影响 = 未定**（审查 D2 明示无证据）⇒ **不许**默认它会被本刀清掉 |
| **R4** | **钳位**退回支**的 A4/`e_ringhi` 角**（【v3 新增 · 审查 §1-(2)/§2.5 采纳】） | `whi = 0`（连接零数据）∧ **FIN 支**（`fin_sent_r && svc_rewind`）∧ `snd_nxt ≥ 2^31` ⇒ 钳位判假 ⇒ 退回 `rb_snd_nxt = fin_seq + 1` > `retx_hi = fin_seq` ⇒ `ring_hi ≤ retx_hi` **不成立** | ⛔ **板上可达（ISN 随机 ⇒ ~50% 量级）**；TB 臂内**不可达**（`tb:280-281` 的 ISN 硬编码全 `< 2^31`） | **无功能实害**（`ring_delta = 0` 不重放；`ring_restore` 的 `(retx_hi − rb_snd_nxt) < 2^31` 门挡住）⇒ 只影响"结构性"表述与 `e_ringhi` ⇒ **处置 = 判据显式豁免这一角**（§5.4-③）+ 本行登记；⚠️ 注意它**不是** E3-6 窗口那条路（窗口内 `snd_nxt == snd_una` ⇒ `svc_rewind = 0` ⇒ FIN 支不可选，§3.4(c)） |

| **R5** ⭐【2026-10-10 实施轮/审查新增】 | **`e_ghost` 的 `is_probe` 豁免的覆盖代价** | 豁免按**帧类**划范围（先例 = `J9` 已把探询段排除出重放覆盖窗口）⇒ 它同样放过"**探针类**的真幽灵帧". 实测（M-3 臂 = 缺陷语义）: 带豁免 `ghost=25` / 撤豁免 `30` ⇒ **削掉 5 条** | —— | **登记不修**（TL 裁定 ②）；口径: ① 不影响"达成"证据（M-3 红分解 `25+3+1+1=30` 仍成立 ⇒ `e_ghost ∈ tot_red` 仍被证到；真内容红 `payload=3/seqcont=1` 与 `PS j8` 一字未变）② 收回覆盖的最小实验 = 在**缺陷语义臂**上关掉豁免（V6 构造 + M-3 RTL），直读 `ghost` 计数. 实施件登记 = `tb/tb_tcp_tx_ovl.v` 的 `e_ghost` 登记块 ⑤ 条 |

### 9.2 U 清单（v2 逐条裁定）

| # | 项 | **v2 裁定** | 依据 / 下一步 |
|---|---|---|---|
| **U1** | 板级会不会出幽灵 / 量级 | **定**（不再"未定"）：**构型改为 abort RST**（FIN 支结构性 `drift = 0`）；**可达性剖面**见 §6.3 三行表（形态①可达、量级 0 或 1 字节/事件；形态②不可达） | §6.2 的 **S-0**（零构建）—— **最高优先** |
| **U2** | 对端把幽灵段当重复还是新数据 | **定**（与 U1 同跑，零构建） | `tcpdump` + `TcpExtTCPOFOQueue` + sink 应用层计数 |
| **U3** | `whi_r = 0 且 snd_nxt ≥ 2^31` 的盲点 | ⭐ **已由钳位关闭**（§3.4(a)：该情形钳位判假 ⇒ 退回 `rb_snd_nxt` ⇒ 不重放）⇒ **从"未定"移出** | v1 的"上板前一条定向 xsim"仍可做（旁证），**不再是前置** |
| **U4** | else 支镜像有没有门可测 | **定（我本轮读完 TB）**：`tb/tb_p4_chain.v:196/788-789` 把 `ack_syn/ack_fin/ack_rst/fin_req/rst_req` **全部钉 0** ⇒ **矩阵里 else 支无 `drift` 无洞** ⇒ **镜像对幽灵无门可测**（收益 = 一致性 + 回归网 + 防未来） | §4.4 的 v2 追加条；镜像决策点仍建议"镜"，理由按 §4.4 写 |
| **U5** | 变异门 CRLF 锚点 | **定**：变异**必须**按 `\r\n` 写锚点；**不做** `.gitattributes` 归一化（动全仓行尾 = 另一刀） | §5.4-④ 的 M-3/M-4 |
| **U6** | `ring_ovf` 要不要计数器 | **后置**（保留"未观测 ≠ 不存在"的写法）；理由 = 新字要走整条读侧同步（20 文件/56 处），而它**不是**本刀的判据面（`e_ghost`/`e_ringhi` 已在 TB 面覆盖） | 若将来要 ⇒ 与下一次扩窗搭车 |
| **U7** | else 支落位 | 实施细节（不变） | 按"先声明后用 + 同块同区"，xelab 面确认无 `VRFC 10-3380` |
| **U8** | LUT/时序 | **必须做**（一次构建收口 + DP 定向路径报告）；区间已按 v2 上调为 **+100–250** | §8.1/§8.2-R1 |
| **U9** | 改后是否出现新红 | **必须做**；⚠️ **枚举基数从 4 条改为 5 条**（审查 D2）⇒ 且判据按 §5.2 的"3 条幽灵红"口径读 | 改后同跑 + `e_ghost` 分流 |

### 9.3 审查 E3 列的 **9 条"该列而未列"** —— 逐条处置（全部进件）

| E3-# | 内容 | 处置 |
|---|---|---|
| 1 | A1 的 `upd_id` | ✅ **采纳**，落 §2-B7 / §3.2-(7)（阻断级） |
| 2 | A2 的"区间内洞"形态与修法覆盖率 | ✅ **采纳**，落 §1.1b（新增小节）+ §2 的"覆盖边界" + §5.5 行 1（**推翻** v1） |
| 3 | A3 的"restore 造新洞" | ✅ **采纳**（登记为残留 **R2**），并加一处精度注（末态同今日） |
| 4 | `ring_hi ≤ retx_hi` 不变式 | ✅ **采纳**，落 §3.2-(5) 的论证 + §3.2-(6) 的替换前提 + §5.4-③ 的门 |
| 5 | `whi_r` vs 探针 `wrhi` 的口径差 | ✅ **采纳**，落 §3.5-4（对照表） |
| 6 | `cfg_up` 与 `scfg` 重基写是否同拍（**上板前必核的闸**） | ✅ **处置 = 解决**：现核 = **不同拍、顺序为"重基 → 清位"**（`slow_cfg_adp.v:171-196` 逐字：`sel=1` 是第 2 个字段、`sel=6` 是最后一个、`ev_up` 与最后一次写在 S_TCB_LAST 同拍置位）⇒ 残余窗口 1–2 拍（`[state=1 落地, cfg_up]`）⇒ **由装载拍钳位兜住**（§3.4(c)）⛔ **不采纳审查给的"升级为 wrap-safe max"**（max 保护方向相反、关不掉陈旧高值 —— §2-B8） |
| 7 | §5.5 枚举基数（4→5）+ 门契约（T 必须保持非 0） | ✅ **采纳**，落 §5.2（重写）/§5.5（5 行） |
| 8 | S-0/S-1 构型改 abort RST | ✅ **采纳**，落 §6.2（S-0/S-1 重写）+ §6.3 可达性剖面 |
| 9 | §7.2 证据不可实现 | ✅ **采纳**，落 §7.2（两条替代口径） |

### 9.4 v2 新增的"未定" —— **【v3 重写：N1 关闭；N2 降级为"变异臂 + 现核"】**

| # | 项 | **v3 裁定** |
|---|---|---|
| **N1** | `e_ghost` 的改前计数 | ✅ **关闭 = 2**（审查 §2.4 采纳；推导 = §5.4-② 的四步，全部用"按连接恒定的装载拍量 + 帧构造"，**不交叉引用瞬时打印**）。⚠️ 残余不确定（1 字节幽灵帧的字节巧合）由仪器自己在改前臂回答 |
| **N2** | `e_ringhi` 改后是否恒 0 | ⚠️ **降级**（审查 §2.5 采纳）：① **改后不是结构性恒 0**（R4 的 FIN 角；TB 臂内不可达、板上 ~50% 量级）⇒ 判据必须**显式豁免**（§5.4-③）；② **改前 = 空判据**（信号不存在）⇒ **"改前跑一次"是空动作、已删**；**牙改挂变异臂 M-5**（§5.4-④）|

### 9.5 ⭐⭐ **"实施时必须现核定"清单（【v3 新增；本轮起定不下来的格子一律进这里，不再来回】）**

> 用法：**照笔实施**；下表每一行给出"**为什么纸面定不下来**"+"**实施时用什么最小实验定**"。⛔ 不许把本表当"已定"读。

| # | 必须现核的格子 | 为什么纸面定不下来 | 实施时的最小实验（判据） |
|---|---|---|---|
| **V1** | `e_ghost`/`e_ringhi` 的**具体插桩行与层次路径名** | TB 已被 persist 实施**漂过一轮**（审查明示"行号全部为本轮现读真值"）；且层次名大小写/前缀需实测（本工程坑 22） | `grep -n "frame_check\|whi_r\|tot_red\|REDS" tb/tb_tcp_tx_ovl.v` 现读锚点；**加完立刻跑 M-3 变异**确认 `e_ghost > 0`（有牙） |
| **V2** | `e_ringhi` 豁免条件的**写法**与 `svc_x` 拍操作数的**同拍性** | 纸面未仿真（`fin_sent_r`/`fin_seq_r`/`whi_r` 在 svc 拍的可见性） | 加门后在**改前臂**跑 M-5 变异（拆钳位 + 注入陈旧 `whi`）⇒ 必须命中；正常臂必须 0 |
| **V3** | **(b) 的 "seq hole" 新红本跑是否为 0**（347.5k–353k 之间 conn1 有无活帧） | 未逐拍读日志（审查未做、我亦未做）；conn1 已被 RST 封（`tx_block ⊆ rst_sent_r`）⇒ **可能为 0** | 两条任选：① 现读 `orS_oracle_v6_xs.log` 在 `cyc∈[347500, 353000]` 的 `FRAMES/F1` 行；② **直接看改后跑的 `REDS seqcont` 值与 `frame_check` 的 `[FAIL] seq hole @cyc`**（带 `cyc` ⇒ 可判是不是那一段） |
| **V4** | **`e_j9` 的期限 vs 跑长** | 纸面只能给"≈413k > 386.3k ⇒ 本跑兜住"的【推断】 | 改后跑：确认 `REDS … j9=0`（`tb:2272` 的显示行）；**若改跑长/改期限 ⇒ 必须按 §5.5 的耦合条重判** |
| **V5** | **TB 侧 `cfg_up` 与 `scfg` 重基的顺序**（与板侧是两份代码） | 审查明示"TB 是另一份、窗口更短"；纸面无法判定 TB 的窗口内是否真起过会话 | 改后跑：若 `e_ringhi`（豁免后）与 `REDS` 的 `onehot/replay` 项全 0 且重放正常发生 ⇒ 视为顺序安全（**这是"没出问题"的证据，不是"顺序已证"**） |
| **V6** | `whi_r` 的**层次路径名**（`u_dut.whi_r`）在 **OVL 支**与 **else 支**下是否同名可引（TB 只编 OVL 支 ⇒ 只需 OVL） | 纸面可判 = OVL 支内部数组 ⇒ `u_dut.whi_r[c]`；但需实施轮实测（xelab 报 not declared under prefix = 坑 22） | 编译后看 xelab/xsim 日志有无 `not declared under prefix`；有 ⇒ 改路径名逐字对齐 RTL |

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
| 17 | `board/wrapper_p4.v:2101-2103`（`tx_ack_* = 1'b0`）· **`:2121-2122`**（非 APP 支 `fin/rst_req = 0`；⛔ v1 的 `:2124-2125` **订正**）· `:2150`（例化 + `PERSIST_EN(1'b1)`）· `:1852`（`ra_retx_hi`）· **【v2】`:2068-2071`（`scfg_upd_*` 接 TCB 写口）· `:2172`（`.cfg_up(scfg_ev_up)`）** | ✅ |
| 18 | `board/build_p7b_ku5p.tcl:153` `verilog_define {… TCP_TX_OVL=1}` | ✅ 逐字 |
| 19 | `sim/p4gates/run_matrix_p4dfix.bat:184-211` 17 门 · `:206` "`-d APP_MODE` ONLY … with TCP_TX_OVL off … NOT in it" | ✅ 逐字 |
| 20 | `sim/p4gates/{chain,p5wrapper}_src.f` 含 `rtl/tcp_tx_frame.v` | ✅ |
| 21 | `tb/tb_tcp_tx_ovl.v:2228-2232` `tot_red` 白名单和式 · `:2267` REDS 显示 · `:787-806` J3/J4 生成 · `:2020-2036` F1 判据 · `:2306` `e_f1_ring` · `:74-76` 臂 `TB_PERSIST_EN` · `:895-898` 源锚 `kw_live` · `:1050-1067` 对端模型 | ✅ 逐字 |
| 22 | `p7b_persist_impl/ev/orS_oracle_v6_xs.log:1750/1751/1754`（SVC/WTRK）· `:2692-2695`（@375000 四行）· `:2726`（`PS j8 空判据`）· `ev/orS_oracle_v5_xs.log:965-966,1730`（红帧）· `:2694`（同 PS j8）· `ev/orT_oracle_v5_xs.log:3465`（T 臂 `payload=14`）· `ev/gate4_stdout.txt:432-440`（`[S]` **明细块 = 5 条红**）+ `:649-653`（`[S]` 摘要块）· **`p7b_persist_impl/rerun_oracle.bat`**（两臂 defs；⛔ **v1 写 `ev/rerun_oracle.bat` 订正 —— 该文件不在 `ev/` 下**） | ✅ 逐字 |
| 23 | `_proj_10g/notes/P7B_TX_PINGPONG_FIX_DESIGN.md:242 / §3-C6`（"结构性排除"原文） | ✅ 逐字 |
| 24 | `_proj_10g/notes/P7B_PERSIST_DESIGN.md:481`（≈522 FF）· `:287-290`（D-8 不镜像） | ✅ 逐字 |
| 25 | `_proj_10g/notes/p7b_sinkfix_20261010/REPORT.md:13/70/79/85-87/227-233`（`--rcvbuf-after-connect` 与见证行） | ✅ 逐字 |
| 26 | `_proj_10g/notes/P7B_OPEN_ITEMS.md` §1-A19（登记件：两账口径 / 影响面判形态 / persist 先后裁定）· §4（CRLF 锚点） | ✅ 逐字（本件与它**口径一致**；仅"三条独立账本"按它的订正口径写）。⚠️ **【v2】该文件里没有"≈522 FF"这句**（`grep -n "522"` 唯一命中 = `:282` 的 `165226`）⇒ 522 的出处见 §附录#24 |
| 27 | `_proj_10g/notes/P7B_BIZ_WINDOW.md` §1（W55/W57/W58 口径）· §2（五处同改） | ✅ |
| 28 | `_proj_10g/notes/P7B_STAGEC_TX.md:24`（F1"两分支同修"） | ✅ 逐字 |
| **29** ⭐【v2 新增·A1】 | `rtl/tcp_tx_frame.v:631-633`（`upd_id` 兜底 = `svc_id`）· `:560`（`svc_id = svc_id_r`）· `:1078`（`svc_id_r` 每拍自由重算）· `:1134`（`retx_id_r <= svc_id` 只在 svc 拍） | ✅ 逐字 |
| **30** ⭐【v2 新增·D3】 | `sim/p7b_stagec_tx_regress/author_gate/run_tx_ovl_gate.bat:114-115`（`S expect 0` / `T expect nonzero`）· `:138-139`（对应 `FAILS+=1`） | ✅ 逐字 |
| **31** ⭐【v2 新增·A6-2】 | `rtl/tcp_tx_frame.v` 的 `onehot` 仅 3 行注释（`:323/:618/:623`，无 `assert`）· `tb/tb_tcp_tx_ovl.v:232/1921-1926/2229`（`e_onehot`）+ **`:2267`**（`REDS` 显示行起点） | ✅ 逐字 |
| **32** ⭐【v2 新增·U4】 | `tb/tb_p4_chain.v:196`（`wire tx_ack_syn = 1'b0;`）· `:788-789`（`.ack_fin(1'b0), .ack_rst(1'b0), .fin_req(16'h0), .rst_req(16'h0), … .cfg_up(1'b0), .cfg_up_id(4'd0),`；注释逐字"P5: FIN/RST 发送通道本门不驱动"） | ✅ 逐字 |
| **33** ⭐【v2 新增·E3-6】 | `rtl/slow_cfg_adp.v:156-198`（`S_TCB`：`upd_sel <= tcb_idx` 递增 0→6；`S_TCB_LAST`：最后一次写与 `ev_up <= 1'b1` **同拍**，注释逐字"wscale (最后一个字段) 落地拍 = ADD 序列收尾 -> CONN_UP 脉冲"） | ✅ 逐字 |
| **34** ⭐【v2 新增·A5/A2 举证】 | `tb/tb_tcp_tx_ovl.v:804`（`if (e_payload < 4)` —— 打印上限）· `:822`（`kk = 1536;` = 跳出循环 ⇒ `e_payload` **按帧**计数）· `ev/q1_frame_payload_origin_out.txt`（`[S#1]` 同圈命中 15/16） | ✅ 逐字 |

**本件全部改动均为纸面；未写任何 RTL / TB / sim / board / 脚本；未碰 `P7B_OPEN_ITEMS.md`；未跑任何工具。**

---

## v2 修订记录（2026-10-10；依据 = `p7b_retxhi_review_20261010/FINDINGS.md` + TL 批注 + **我逐条回源码自核**）

> 读法：**本节是 v2 的权威口径**；正文里被改处已就地标 `【v2】`/`【v2 订正】`/`【v2 新增】`。
> 裁定记号：**采纳** / **部分采纳**（危险成立、药方更换）/ **不采纳**（附理由与现核证据）。
> ⛔ 本件**不写**"已就绪/可以实施了"；**不下** PASS/FAIL 裁定。

### V.1 六条 blocking

| 依据 | 位置 | 改前（v1） | 改后（v2） | 处置 / 现核 |
|---|---|---|---|---|
| **A1**（OVL 支缺 `upd_id`） | §2-B7（新）/ §3.2-(7) / §8.2-R2 | 只改 `upd_wr_rew` 与 `upd_val` 两处；**`upd_id` 一字未改** ⇒ `ring_restore` 拍落到兜底 `svc_id` | 加 `assign upd_id = … ((replay_jump \|\| ring_restore) ? retx_id_r : svc_id);`；并把"为什么不能省"的逐条论证写进件 | ✅ **采纳（阻断级）**。我现核：`:631-633` 兜底 = `svc_id` ✔ · `:560` `svc_id = svc_id_r` ✔ · `:1078` 每拍自由重算（`retx_req ? retx_id : prio_lo(rto_pend)`）✔ · `:1134` 会话 id 只在 svc 拍锁存 ✔ ⇒ "会话期 `svc_id_r ≡ retx_id_r`"的证明**不存在** ✔ |
| **A2**（修法覆盖不到"区间内 1 字节洞"） | §1.1（定义加形态限定）/ **§1.1b（新增）** / §2 覆盖边界 / §5.5 行 1（**推翻**） | §1.1 把缺陷定义为"区间**末** drift 字节"为**唯一**形态；§5.5 行 1 判"两种可能都绿"（含"首字节改读本圈地址"） | 引入**形态①（尾段漂移，治）/ 形态②（区间内洞，不治）**；`[S#1]` 改判 **修不掉 ⇒ 残留 R1**；并给"形态②板上不可达"的源码论证（v1 缺） | ✅ **采纳（本报告最重要的一条）**。我现核：`:789` `w_tap_seq = start_data ? rb_snd_nxt : tap_seq` ✔（中段预留 ⇒ 写游标跳位）· `:952-954` `fin_push` 的 `snd_nxt==snd_una` 门 ✔ · `:955-956` `rst_push` 无该门 ✔ · `wrapper_p4.v:2101` `tx_ack_syn = 1'b0` ✔ ⇒ 形态② 板不可达 ✔；**"换操作数不改读址"** ⇒ 修法对它 0 覆盖 ✔ |
| **D2/D3**（S 臂 5 条红 / T 臂契约） | §5.2（重写）/ §5.5（5 行） | §5.2"改后必须 = 0（S 与 T 两臂都跑…**T 臂也必须绿**）" | 判据口径改为"**J3/J4 幽灵红中可治的 3 条清 0**"；**T 臂 RC 必须保持非 0**；第 5 条（PS j8）**另立账**（persist 族） | ✅ **采纳**。我现核：`gate4_stdout.txt:432-440` 的 `[S]` 明细块 = **5 条** `[FAIL]`（第 5 条 = `PS j8 空判据`，`:437` 逐字）✔；`run_tx_ovl_gate.bat:114-115`（`S expect 0` / `T expect nonzero`）+ `:138-139` ✔ ⇒ v1 与门契约冲突 ✔ |
| **E3-6**（`cfg_up` 与 `scfg` 重基写是否同拍） | §3.4(c)（新增）/ §2-B8 | §3.2-(4) ⚠️ 只把"会话外重基写"写成**未来风险** | **现场核清 + 结构性处置**：现核 = 二者不同信号（`:2068-2071` vs `:2172`）；**顺序 = 重基先于清位**（`slow_cfg_adp.v:171-196`，`sel=1` 是第 2 个字段、`sel=6` 最后、`ev_up` 与最后一次写同拍）；**残余窗口 1–2 拍由装载拍钳位兜住** | ✅ **采纳（危险成立）**；⛔ **药方部分不采纳**：审查建议"升级为 wrap-safe max"**保护方向相反**（max 让陈旧大值活下来）⇒ 换为**装载拍 wrap-safe 钳位**（§2-B8 / §3.2-(5)），它同时把 **A4 的不变式变成结构性** ⇒ 见 V.2 |
| **A4**（`ring_hi ≤ retx_hi` 不变式 + 配门） | §3.2-(5)（论证）/ §3.2-(6)（替换前提）/ §5.4-③（新门 `e_ringhi`） | 未写（只当"多半安全"） | ① 逐支论证（非 FIN 支 ⇒ 恒成立；FIN 支 ⇒ 由 `:952-954`+`:1264` 直推）；② **钳位把它升级为结构性**；③ 配 TB 门 `e_ringhi`（**进 `tot_red` 和式**） | ✅ **采纳**（F1 保护面，必须显式） |

### V.2 其余 5 项（顺手改的单子）

| 依据 | 位置 | 改前（v1） | 改后（v2） | 处置 / 理由 |
|---|---|---|---|---|
| **B3**（板级构型选错） | §6.2（S-0/S-1 重写）/ §6.3（可达性剖面） | 用 **close(FIN) 路径**造构型 | 改用 **abort RST**（`rst_push` 无 `snd_nxt==snd_una` 门）；**并写清"FIN 路径结构性 drift = 0"** ⇒ 用 FIN 造 = 结构性测不到 | ✅ **采纳**。我现核 `:952-954`/`:955-956`/`:547` ✔ —— 这条也**直接改写 U1 的可判性** |
| **行号 2 处** | §4.3 / §附录#17 / 证据地图 / §5.4① | `wrapper_p4.v:2124-2125`；`ev/rerun_oracle.bat` | **`:2121-2122`**；**`p7b_persist_impl/rerun_oracle.bat`**（不在 `ev/` 下） | ✅ **采纳**（两处我现核一致） |
| **内容 1 处**（A6-2） | §8.2-R2 | "OVL 的 `$onehot0` **断言已存在** ⇒ 加 `ring_restore` 项" | 改为"**RTL 内无断言**（只有 3 行注释 `:323/:618/:623`）⇒ 检查在 **TB**（`e_onehot`，`tb:232/1921-1926/2229/2269`，在 `tot_red` 内）⇒ 实施轮 = **给 TB 的 `e_onehot` 加 `ring_restore` 项**" | ✅ **采纳**（我 `grep -n "onehot" rtl/tcp_tx_frame.v` 现核 = 3 行注释、无 `assert` ✔） |
| **A6-1**（枚举漏项） | §3.2-(4) support(ii)（**重写为 6 支穷举表**） | 四情形枚举（漏 `bank_rdy[rx_bank]`） | 六支穷举（补 `bank_rdy` 一支），并注明 `rx_idle` 现核 = `(rx_state==RX_IDLE) && recv_first`（`:524`）⇒ **在飞活帧期也挡住** ⇒ 结论**更强** | ✅ **采纳** |
| **A5**（§7.2-1 作为证据不可用） | §7.2（重写） | "零回归 = 除 payload/seqcont 外**所有**数字逐字相同" | 换两条：① 在 **`drift ≡ 0` 的配置**（else 支矩阵 13 门 / 强制 `whi_r=0` 变体）上做**逐字/位级**等价；② OVL 支只声明**条件式等价**并把**数字变化预期化**（差异必须逐项对得上 §5.5 的 3 条预测） | ✅ **采纳**（我复核：修复必然改帧集 —— `[S#3]` 帧消失、`[S#2]` 缩短 ⇒ v1 口径按字面执行必红） |

### V.3 A6-3 / D4 / D5 / D6（审查的四条补充）

| 依据 | 位置 | 处置 |
|---|---|---|
| **A6-3**（`whi_r` ≠ 探针 `wrhi`） | §3.5-4（新对照表） | ✅ **采纳**：两者在"帧内中止"与"在飞活帧"两处分叉 ⇒ 探针量**不可当 `whi_r` 的实现真值**（方向性结论不受影响，只影响量纲口径） |
| **D4**（必须加 `e_ghost` 且进 `tot_red`） | §5.4-②（**新，必做**） | ✅ **采纳**（**推翻 v1 的"先不加新计数器"**）：给出定义（帧尾越过"帧首拍锁存的高水位"）、三条独立性/有牙论证、**判别规则**（`e_ghost=0` 且仍有 payload 红 ⇒ 归洞族残留；`e_ghost>0` ⇒ 修法没生效）、**三处落地**（`:232` 声明 / `:787-825` 检测 + 帧首锁存 / **`:2228-2232` 和式 + `:2269` 显示**） |
| **D5**（N-2 口径错 + 两条新变异） | §5.4-④ | ✅ **采纳**：N-2 改为"所有重放区间读址落在本圈写过且非洞的 seq"（**推翻** v1 的"`drift ≡ 0` 作无幽灵正控"）；加 **M-3**（`ring_hi` 换回 `retx_hi` ⇒ 验 `e_ghost` 有牙）与 **M-4**（去掉 `ring_restore` ⇒ 验其必需） |
| **D6**（门能否成为可解释的绿） | §5.2（诚实收口） | ✅ **采纳**：门级 `PASS` **不在本刀范围内**；本刀达成 = "3 条幽灵红清 0 + 其余 2 条各有归属（1 残留 / 1 persist 账）" |

### V.4 E1 / E2 / E3（代价、U 清单、漏项）

| 依据 | 处置 |
|---|---|
| **E1**（522 FF 引注错） | ✅ **采纳**：真值源 = `P7B_PERSIST_DESIGN.md:481`（+`:115` 同数）；我现核 `P7B_OPEN_ITEMS.md` 的 `522` 唯一命中 = 第 282 行 `165226` 的一部分（与 FF 无关）✔ ⇒ v1 的出处订正；"尚未构建"由 `fd671b6`（20:46）晚于构建 F（09:15）佐证 ✔ |
| **E2**（U 清单逐条） | ✅ **采纳并升级**：U1/U2/U4/U5 = **定**（U4 我本轮读完 `tb/tb_p4_chain.v` ⇒ "镜像对幽灵无门可测"**已定**）；**U3 = 已由钳位关闭**（比审查的"可后置"更强）；U6 = **后置**（理由 = 新字要走整侧同步、非本刀判据面）；U8/U9 = 必须做（**U9 枚举基数 4→5**）—— 全部落 §9.2 |
| **E3-1..E3-9** | ✅ **逐条处置表 = §9.3**（9 条全进件；其中 E3-6 的**药方**部分不采纳，见上） |

### V.5 不采纳 / 与审查的出入（**如实列；固定句照守**）

| # | 审查/TL 的说法 | 我的处置 | 现核证据 |
|---|---|---|---|
| 1 | **E3-6 的备选处置 = "把 `whi_r` 升级为 wrap-safe max"** | ⛔ **不采纳**（部分采纳：危险成立）⇒ 换为**装载拍 wrap-safe 钳位** | max 保证"不被压低"（单调），而 E3-6 的危险是"**陈旧偏高**" ⇒ max 会让大值活下来 ⇒ **关不掉**；钳位（`(rb_snd_nxt − whi) < 2^31` 才接受）**双向都管**，且顺手关闭 U3 的盲点（`whi=0` 且 `snd_nxt ≥ 2^31` ⇒ 钳位判假 ⇒ 退回 ⇒ 不重放）——见 §2-B8/§3.4 |
| 2 | 审查 E4/§5.3 引 "`tot_red` 和式 = `:2229-2233`" | **按我的现核写 `:2228-2232`**（两处口径的差异 = 1 行；`e_f1_cyc` 在 `:2230` **双方一致**） | `sed -n '2228,2232p' tb/tb_tcp_tx_ovl.v` ⇒ `:2228` = `tot_red = e_parse + e_csum + e_payload + e_seqcont + e_seqmono + e_ctrl +`，`:2232` = `e_ag_block + e_ag_resume;` ✔ |
| 3 | 审查 A3 的措辞"**`ring_restore` 把幽灵区变成新的中段洞**" | ✅ **实质采纳**（登记 R2、"不闭合"照写）；⚠️ **加一处精度注**（不迁就、也不夸大）：那个洞**不是 `ring_restore` 造出的新状态** —— 今日（无本修法）一次会话的自然排空同样把 `snd_nxt` 停在 `retx_hi`（`:1167-1181`），**末态逐字相同**；本修法改变的是"**那些 seq 位没有被当数据发出去**" | `:1167-1181`（排空支）逐字。⇒ 形态②的根因仍是 `:636` 的那笔预留；`ring_restore` 只是把它从"当圈发掉"改成"留到下一圈" |

### V.6 v2 自己新加的两条"未定"（§9.4）

- **N1**：`e_ghost` 在改前臂的**实际计数**（2 还是 3）—— 取决于 `[S#1]` 那一拍 `whi` 是否小于该帧尾，而**打印拍与 FAIL 拍相差数千拍、不许交叉引用**（§1.6 的读数协议）⇒ 由"加上 `e_ghost` 后跑一次改前臂"回答。
- **N2**：`e_ringhi` 在改后是否**恒 0**（纸面 = 结构性应恒 0；`svc` 拍操作数的同拍性未仿真）⇒ 改前/改后各跑一次。

**⇒ v2 的实质性变化（一句话）**：修法从"3 件"变"**4 件**"（+ `upd_id` 编辑 + 装载拍钳位）；缺陷从"1 种形态"变"**2 种形态**"（治 ①、登记 ②）；判据从"全绿"变"**3 条幽灵红清 0 + `e_ghost` 半区判据 + T 臂契约保持**"；面板从"4 条红"变"**5 条红（+ PS j8 另立账）**"。

> ⚠️ **V 节读法**：V.1–V.6 是 **v2 当时**的口径记录（其中"帧首拍锁存"/"`:2269`"/"`e_ringhi` 应恒 0"/"改前跑一次"等**已被 v3 改写**）⇒ **现役口径以 `## v3 修订记录` 为准**。

---

## v3 修订记录（2026-10-10；依据 = `p7b_retxhi_review_20261010/REVIEW2.md` + **我逐条回源码自核**）

> 读法：**本节是 v3 的权威口径**（v1/v2 的记录节保留，但口径以本节为准）。
> ⭐ **REVIEW2 已判定的两格（我赢）**：① **钳位成立**（方向论证/阈值/比较方向/退回值/落位不踩 A1 —— 审查逐字核过）；② **`tot_red` 行号 = `:2228-2232`**（v1 审查的 `:2229-2233` 错；`e_f1_cyc` 在 `:2230` 双方一致）。
> 裁定记号：**采纳** / **部分采纳** / **不采纳**（附现核证据）。⛔ 不写"已就绪/可实施了"；不下 PASS/FAIL 裁定。

### V3.1 六条 blocking

| 依据 | 位置 | 改前（v2） | 改后（v3） | 处置 / 现核 |
|---|---|---|---|---|
| **1. `e_ghost` 取样点** | §5.4-②（重写） | "**必须在帧首拍锁存**，不能在帧尾读（帧期间 `whi_r` 可能被抬高 ⇒ 会漏判）" | **帧尾直读**（`u_dut.whi_r[t_conn]`，不锁存）；给出"活帧自抑制"+"重放帧无差别"两条依据；**删 (c)**（"`whi_r` 永不更新"变体 = 沉默，不是可命中的路径）；**N1 关闭 = 2** | ✅ **采纳（阻断级）**。我现核：`frame_check` 定义 `tb:612`、**唯一调用点 `tb:870` 且包在 `:869 if (m_tlast)` 里** ✔ ⇒ 检查块**天然在帧尾**；v2 的"帧尾会漏判"**两个方向都不成立**（会话期 `whi` 冻结 ⇒ 无差别）✔ |
| **2. TB 前沿模型 × 修法耦合** | §5.5（新增块） | "3 条幽灵红清 0 + 其余 2 条各有归属"（**不完整**） | 新增耦合块：`exp_new` **只按 in-order 数据帧 + SYN 推进**（四支逐行列出；FIN/RST 不吞 seq）⇒ pre-fix 幽灵帧**正是**推前沿过漂移区的载体 ⇒ post-fix 前沿停在 `whi` ⇒ ① `e_j9` 前提不成立（本跑**靠跑长兜住**）② 后续活帧可能 = "seq hole" `e_seqcont` 新红 ⇒ **判据面必须含这两条支路** | ✅ **采纳**。我现核：`exp_new` 赋值点 `:274`/`:701-702`(SYN)/`:782-784`(in-order)/`:1051`(建连) ✔；`e_j9` **双计**（和式 `:2230` + 独立判定 `:2308-2309`）✔；本跑 `cyc=386286`（`orS_oracle_v6_xs.log:2697` 逐字）⇒ 期限 ≈413k > 跑长 ✔（【推断】"跑长兜住"）。⚠️ 本跑 `e_seqcont` 是否为 0 ⇒ **V3 现核**（§9.5） |
| **3. `e_ringhi` 收窄 + 第 4 残留** | §3.2-(5)（收窄）/ §5.4-③（重写）/ §9.1-**R4（新增）** | "本刀把这条升级为**结构性**"（过强）；"改前/改后各跑一次" | R4 角（`whi=0` + FIN 支 + `snd_nxt ≥ 2^31` ⇒ 退回值 `fin_seq+1 > retx_hi`）**显式登记**；`e_ringhi` **判据本体豁免该角**；**"改前跑一次"删（空动作）**，牙改挂 **M-5 变异臂** | ✅ **采纳**（含"板上可达 ~50% 量级 / TB 臂内不可达"的逐条依据） |
| **4. M-4 指名判据** | §5.4-④ | "应有判据变红"（无指名 ⇒ 哑门） | **指名 = `e_replay_jump`**（注释 `tb:2130-2132`、判定 `:2133-2134`、**在 `tot_red` `:2231`**）⇒ 去 `ring_restore` 后 `snd_nxt = whi < retx_hi` ⇒ 确定性红 | ✅ **采纳**（我现核该块逐字 ✔，并补上判据 B 的三行定位） |
| **5. 行号 5 处 + 拍数 + 归因** | §3.5-1 / §2-B-3 / §5.2 / §5.4-② / §3.4(c) | `tb:2025`（e_f1_cyc 生成）/ `:822`（`kk=1536`）/ `gate4:436-440` / `:2269`（显示行）/ `slow_cfg_adp:187-196` + "`:190-196` 逐字" / 拍数"≈1–2 拍" / 归因"由钳位兜住" | `:2034` / `:827` / `:433-437` / **`:2267`**（统一）/ `:187-198` + `:192/:195/:196` / **2 拍（下界）** / **"钳位 ∪ 既有 `ring_ovf`"** | ✅ **采纳**（全部现核一致 ✔） |
| **6. `whi` 写者纪律** | §3.2-(4)（新增块） | 只把"snd_nxt 写者清单"降为复核项，**没有为 `whi` 立同款纪律** | 立纪律：**`whi_r` 写者集合 = {活帧推进写（唯一抬高者）, `cfg_up` 清位（唯一压低者）}**；任何其它降 `whi` 的写 ⇒ **静默不重放**（危险方向）⇒ 照抄进 RTL 注释 | ✅ **采纳**（附"谁负责保证单调性"的三行表） |

### V3.2 其余（N1 关闭 / §7.2 无效锚 / 审查自身的 1 处小错）

| 依据 | 处置 |
|---|---|
| **N1 = 2** | ✅ **采纳并关闭**（§5.4-② 四步推导：`[S#1]` 是重放帧且 `tail ≤ retx_hi = whi`（conn0 每会话 `drift ≡ 0`，`:390` 逐字）⇒ 不命中；`[S#2]`/`[S#3]` 命中 2 ⇒ **= 2**） |
| **§7.2 的"把 `whi_r` 强制为 0"作为等价锚** | ✅ **采纳（删）**：`whi ≡ 0` ⇒ 钳位接受 ⇒ `ring_ovf = 1` ⇒ **永不重放** ⇒ 输出与两臂都不同 ⇒ 保留 **worktree 锚**（= 不接本修法的变体） |
| **审查的 `exp_new` 建连支行号 = `:1052`** | ⛔ **不采纳（1 行小错）**：现核 `sed -n '1050,1052p'` ⇒ `:1050 peer_rcv[…] <= isn+1` / **`:1051 exp_new[…] <= isn+1`** / `:1052 ack_first[…] <= 1'b1` ⇒ **真值 `:1051`**（§5.5 已按 `:1051` 写，并就地标注该订正） |

### V3.3 不采纳清单（v3 仅 1 条）

| # | 审查的说法 | 处置 | 现核 |
|---|---|---|---|
| 1 | `exp_new` 的第 4 个赋值点 = `tb:1052` | ⛔ **不采纳（行号错 1 行）** | `:1051` = `exp_new[setup_c] <= isn[setup_c] + 32'd1;`；`:1052` = `ack_first[setup_c] <= 1'b1;`（`sed -n '1050,1052p'` 逐字） |

### V3.4 v3 的实质性变化（一句话）+ 交接

**修法不变**（钳位被独立证实成立）；v3 改的全是**判据/口径/精度**：`e_ghost` 取样点钉死为**帧尾直读**、`e_ringhi` **判据本体豁免 R4**、M-4 **指名 `e_replay_jump`**、**判据面加入"TB 前沿耦合"两条支路**、**`whi` 写者纪律成文**、**5 处行号 + 拍数 + 归因订正**、**N1 关闭 = 2**、**新增 R4 残留与 §9.5「实施时必须现核定」6 条**。
⛔ **本轮是最后一轮设计**（收敛优先）：**定不下来的格子已全部进 §9.5**（V1–V6），不再来回；实施照笔 + §9.5 现核即闭合。
