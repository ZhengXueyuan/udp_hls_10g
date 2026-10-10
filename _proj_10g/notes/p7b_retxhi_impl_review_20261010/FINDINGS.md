# P7B-RETXHI-GHOST 实施件对抗审查 + 独立复跑（2026-10-10）

> **落盘说明（TL）**：本件由 **TL 代 agent 落盘** —— agent 侧 harness 拦报告类 `.md`（本工程当日**第七次**）。**正文未改一字**。TL 的裁定见文末。
>
> - 被审 = `rtl/tcp_tx_frame.v`(2576 行) · `tb/tb_tcp_tx_ovl.v`(2706 行) · `sim/p7b_stagec_tx_regress/author_gate/**`；链 `11ad9ec` → `74f56cc` → `0bbda0e`(HEAD)。
> - **固定句（必守）**：核到与描述不符就如实说，别迁就。记号 = **成立/推翻/降级/无法判定**；【事实】= 我回源码或**我自己跑出**；【推断】= 由事实推得。
> - ⛔ 不下 PASS/FAIL；不写"可以构建了"；不把"未观测到"写成"不存在"。零 Vivado/零构建/零板卡/零 ssh。

## §0 一句话结论

实施件**在它自己声明的范围内基本站得住**：三个必需臂（S/T/M-3）我**逐字复现**；豁免作用域、承重登记四要素、13 条 seqcont 改判（**我用同位素臂把根因独立测出来了**）、B2 语义等价、`whi_r` 写者全集、`tot_red` 落位 —— **全核过、成立**。但有 **3 条实质发现 + 1 条判据面发现**：

1. ⭐ **PS j9/PS j6 的"同源"归属不成立（降级）**：同位素臂（撤 `cfg_up` 的 `whi` 清位、其余逐字不动）⇒ `seqcont 13→0`、`jump 2→0` 如实施者所述消失，**但 j9/j6 仍在**。
2. ⭐ **豁免的"覆盖代价"只写在 commit（`0bbda0e` ④），没进任何残留清单**：我实测 M-3 `ghost 30→25`（撤豁免前）⇒ 削掉 **5 条真幽灵类帧**。
3. **"板侧结构性不可达"只覆盖它声明的那句话（降级/需收窄）**：两条腿我都证实了；但我实测的假阳性形态 = "cfg_up 清位后、该连还没被活帧刷过高水位时探针帧上线"，这一子类**没被该论证关死**。
4. （既存非本刀）`e_j9`/`e_f1_ring` 在 `tot_red` **双计**；本跑读数不受影响（三臂 `J9=0/F1_ring=0`）。

行号：抽核 **24 条**，**代码位置全对**，**6 条散文引用不成立 + 1 条范围错**（错法 = 照抄设计件的**改前**行号）。

## (A) 对抗审查

### ① `is_probe` 豁免的作用域 —— **成立**（附 2 条边界）

**(a) 它是不是真的等价于"探针帧"？**【事实·回源码】豁免本体逐字 = `tb:762` `if (!is_probe &&`（A/D 行是 `whi_r` 比较）。B1c 的 TB diff（`git diff 74f56cc..HEAD`）**只有这一行被加进去 + 缩进**；条件本体/门限/打印/`e_ghost<6` 的 cap **一字未动**。
`is_probe` 真值源 = **TB 侧** `tb:664-674`（`ifdef ARM_PERSIST`；未定义该宏 ⇒ `is_probe=1'b0`，豁免惰性）：
`is_probe = (flags==8'h18) && (plen==12'd1) && (fseq==sh_una[t_conn]) && psc_win_closed[t_conn];`
四要素全部来自**线上字段 + TB 自维护模型**（`sh_una` = TB 对 TCB 写口重建的 snd_una 影子；`psc_win_closed` = TB 自己关的窗位图），**不是** DUT 的 `tx_is_probe`（设计件 v3 #12 明令不许取 DUT 信号，实施件遵守 ✓）。⇒ 它是"探针**类**"分类器（超集：任何"1 字节 ∧ 落在 snd_una ∧ 该连窗口被 TB 关着"的数据帧都归入）。

**(b) 会不会连带放过非探针帧？** 不会 —— 只对 `is_probe=1` 跳过，其余帧判定逐位未改。实施者的"arm A/B `ghost=0`"我核了：**arm B**（`-d TCP_TX_OVL`，无 ARM_PERSIST ⇒ 豁免惰性）我**自己重跑** = `TB_TCP_TX_OVL: OK`，`REDS` 全 0 ✓；⚠️ 但 **"arm A ghost=0"是空话**：arm A 根本没编 `e_ghost`（判据在 `ifdef TCP_TX_OVL` 内），REDS 行里连 `ghost=` 字段都没有（作为"已排除"的证据被高估，结论方向不变）。

**(c)** 非探针帧的判定规则/门限/`tot_red` 落位一字未动 ✓（逐字对 diff）。

**(d) 我这轮独立测到的两条边界**：
- **豁免确实正打在那两条假阳性上**（变体臂 V6：撤 `!is_probe`、其余同 S 臂 + `GHOST_DBG`）⇒ `ghost=2`、`reds=6`，两条打印**逐字**：
```
[FAIL] ghost conn=1 seq=000466e8 plen=1 tail=000466e9 whi=00000000 @300582 PROBE=1 shuna=000466e8 sndnxt=0004896f snduna=000466e8 ract=0 rid=2
[FAIL] ghost conn=1 seq=0004e59c plen=1 tail=0004e59d whi=00000000 @320233 PROBE=1 shuna=0004e59c sndnxt=0004eb98 snduna=0004e59c ract=0 rid=3
```
与实施件登记的原始证据（`PROBE=1`/`whi=00000000`/`sndnxt=0004896f 与 0004eb98`）**逐字复现** ✓（`GDBG cfgup @300587` 在其后；@300582 两条来自**更早**一次 cfgup(@296562) 之后的窗口）。
- **代价是真的、可测**：M-3 臂带豁免 = `ghost 25`（我复跑）/ 撤豁免 = `30`（实施者 11ad9ec 读数，我未重跑该配置）⇒ 削掉 **5 条**。commit `0bbda0e` ④ 登记属实，但**只在 commit 里**（见 ⑥ 第 5 残留）。
- 【推断·未观测】未登记子类：探针帧若出现在 `whi == snd_una` 的连接上（1 字节重发 ⇒ `tail=whi+1`）也会判 ghost。本 TB 未观测到（M-3 的 25 条在 conn3 = TB 从不开窗的连接 ⇒ **不是**探针类）；板上可达性**未证**（只影响 TB 仪器假阳性率，非板级缺陷）。

### ② 承重登记（`tb:735-761`/`tb:2223`/`tb:2631`/`rtl:2182-2188`）—— **成立**（四要素齐；3 处行号引用不成立）

1. **根因**由我的 V6 复现证实 ✓（`whi=0`、`fseq==shuna==snduna`、`sndnxt` 高）。
2. ⭐ **板侧结构性不可达** —— **两条腿都成立（我独立核源码）**：`wrapper_p4.v:2055 slow_cfg_adp u_slow_cfg`；`:2068-2071` `.upd_wr/.upd_id/.upd_sel/.upd_val(scfg_*)`；`:2076` `.ev_up(scfg_ev_up)`；`:2172-2173` `.cfg_up(scfg_ev_up)/.cfg_up_id(scfg_ev_slot)` —— 与设计件引的 `:2068-2071`/`:2172` **逐字相符** ✓；`rtl/slow_cfg_adp.v:156-198`：`S_TCB` 里 `upd_sel <= tcb_idx`（0→6；`tcb.v:5` 逐字 `0=rcv_nxt 1=snd_nxt 2=snd_una … 6=wscale`），`S_TCB_LAST` 里 `:192 upd_wr<=0 / :195 ev_up<=1 / :196 state<=S_RECV` ⇒ `snd_nxt`(sel=1) 重基**至少早 5 个字段写**于 `ev_up` ✓ ⇒ "清了 whi 而序号空间没重基"的窗口**确实不存在** ✓。
   ⚠️ **范围注（降级，非推翻）**：只关掉"**陈旧数据**"那一半。我实测的假阳性形态 = "cfg_up 清位后、该连**还没被任何活帧刷过高水位**时探针帧上线"⇒ "板上合法 cfg_up 后、首笔活帧前会不会有探针帧"**未被覆盖**（探针武装需"有在飞/被阻塞"⇒【推断】多半不可达，但**无读数、无源码论证**）。
3. **为何豁免而非修源头**：6 处共用清除例程 ✓（我 grep `pe_ret <= 7'd…` 命中 `tb:1254/1411/1488/1565/1610/1671` + `:1568`(conn2 走 7'd73) ⇒ `pe_ep 1/3/4/5/6/7` 全复用 `7'd70/71` ✓）；"必须重基对端模型"与"会撞 PS j3"两条推理方向成立 ✓（j3 判据文本 `tb:2627-2630`）。
4. **将来收紧的最小实验**（写 `sel=2 → sel=1 → cfg_up` + 重基对端模型）与 TB 的 setup FSM **逐字相符** ✓（`tb:1094-1117`：`4'd0` 写 sel=2、`4'd1` 写 sel=1、… `4'd6` 脉冲 cfg_up）⇒ 可执行。

**行号缺陷**：`tb:735-761` 里 "(tb:1219/1464)" 标 cfg_up ⇒ **不成立**（`:1219` 是注释、`:1464` 是 `$display` 块内语句；真值 = 写该行时的 `11ad9ec` `:1225/:1470`，**现 HEAD** `:1266`(`7'd70`)/`:1511`(E4 `7'd28`)）；`tb:751` "(…只在建连路径写, tb:1085-1087)" ⇒ **不成立**（建连重基写在 `tb:1126-1128`）；`tb:753` "撞 PS j3 (tb:2580)" ⇒ **不成立**（判定在 `:2627-2630`）；另 `rtl:2182-2188（6 行）` 范围尾偏 1（6 行登记 = `:2182-2187`，`if` = `:2188-2189`，写 = `:2190`）。

### ③ 13 条 `seqcont` 的改判 —— ⭐ **成立（我用同位素臂把根因独立测出来了）**

**(a) 逐条核（我自己的 TDBG 复跑，13/13 行逐字）**：`exp` **恒** `0004784c`，跨 `cyc 446531→450628` = **4097 拍** ✓（实施者"约 4100 拍"✓）；`whi` 从 `00047dc7` 涨到 `00049a9b` ✓（**逐字相符**）⇒ **不是"前沿停在 whi"**（设计件 v3 §5.5(b) 的预测）⇒ 改判成立 ✓。1 条 `kind=partial`（`fseq=47813 < exp=4784c < tail=47dc7` ⇒ **跨**前沿）+ 12 条 `hole`；前沿模型 `tb:847-849`（只认 `fseq==exp` 才推进）⇒ 此后永不推进 ⇒ 逐条 hole ✓ 机制吻合。我另复算 13 条的连续性：`47813+1460=47dc7`、`47dc7+1=47dc8`、`47dc8+63=47e07`、`47e07+1460=483bb`、`483bb+7=483c2`、`483c2+1460=48976`、`48976+1460=48f2a`、`48f2a+1460=494de`、`494de+8=494e6`、`494e6+1460=49a9a` ⇒ **一条不断链的顺序重发流** ✓。

**(b) 三条自核**：
1. ⭐ **"若 `ring_hi` 是真 whi 则 0 红"这条判别式 —— 我把它测出来了（比纸面版更强）**：同位素臂 **V5 = HEAD RTL 只撤 `cfg_up` 的 `whi_r` 清位**（其余逐字不动）+ T 臂 defs：
```
REDS parse=0 csum=0 payload=1 seqcont=0 … ghost=0 ringhi=0
TB_TCP_TX_OVL: FAIL reds=9        （对照 T 臂 = seqcont 13 / reds 22）
```
⇒ **`seqcont 13→0`、`RETXFIX jump 2→0`** ⇒ "13 条 + 2 条 jump 的**必要成因** = episode `cfg_up` 清 whi" **成立** ✓（S 臂配置同理：V1 撤清位 ⇒ `reds 4→3`，少的那条正是 `RETXFIX jump @342415`）。
2. "payload=0 ⇒ 不是内容红、是前沿簿记红" ✓（T 臂复跑 `payload=0`）。
3. "`snduna=0x466e8` 与'停在 snd_una、app 重发'一致" ✓（13 条前 7 条 `snduna=000466e8`、后 6 条 `=0004784c`；`sndnxt/whi` 同步）。

**(c) 该不该并进 jump / PS j9/j6 那条登记？分开判**：**jump 该并、已并** ✓；**PS j9/j6 不该并** —— ⛔ 同一条同位素臂上 **j9/j6 没消失**（V1 `reds=3 = payload1 + PSj9 + PSj6`；V5 `reds=9` 含 `PS j9`）。

### ④ B2 的收紧（else 支 `:2176-2184`）—— **成立**（等价性成立；无新洞；"逐字相同"证据力量低）

- **语义等价**【事实】：`assign upd_wr = ((state==S_DONE) && (is_data_r||is_syn_r||is_fin_r||is_rst_r) && m_axis_tvalid && m_axis_tready) || svc_rewind || ring_restore;` ⇒ B2 门 `(state==S_DONE) && is_data_r && tvalid && tready && !retx_active` **逐位等于**"该帧**数据**推进写那一拍"；写值 `seq_r + {20'b0, plen_r}` 与 TCB 的 `upd_val` 数据支**同一表达式** ✓；索引 `cur_id` 与 `upd_id` 同源 ✓。
- **没有引入新洞**（三条路径）：① `tx_abort`/半帧中止/超长帧（`len_over`）⇒ 永不到 `S_DONE` ⇒ `whi_r` 不刷，与"`snd_nxt` 也不推进"**同向** ⇒ 语义一致（`whi` = 已承诺数据端，设计件 §3.5-4 已登记口径差）✓；② **`!retx_active` 不会误挡活帧**：两分支都核了"会话期无活帧"（OVL：`svc = rx_idle && … && !retx_active`(`rtl:570`)、`ring_eval ⊆ rx_idle && retx_active`(`:574`)；else：`svc = (state==S_IDLE) && … && !retx_active`(`:1653`)、`start_data` 含 `!ring_eval`）⇒ 活帧推进写拍 `retx_active≡0`；③ `ring_restore`/`svc_rewind` 拍与 `state==S_DONE` **状态互斥** ⇒ 不误刷 ✓。
- **"chain/burst200 stdout 与改前逐字相同"**：我 diff 归档件 ⇒ **逐字节相同** ✓；我**重跑**两门（post-B2 HEAD）⇒ `GATE chain EXIT=0` / `GATE burst200 EXIT=0`，且**我的两门 console 与归档 `chain_post_b2.txt`/`burst_post_b2.txt` 逐字节相同**（`diff` 空）。⚠️ **但证据力量低**：两份 stdout 内都写 `RETX=0` ⇒ 该两门**没有会话装载拍** ⇒ `whi_r→ring_hi→ring_delta` 通路**不被激励** ⇒ 只能证"没编坏/没改坏别的"，**不能**证 else 支语义等价（实施件自己把位级比对标为"未做" ✓ 诚实）。

### ⑤ `whi_r` 写者全集 —— **成立**（无第三写者、无第二压低路径）

逐处 grep（`grep -n whi_r rtl/tcp_tx_frame.v` 全命中逐条核）：

| 支 | 写点 | 行 | 方向 |
|---|---|---|---|
| OVL | 复位 `for(ri…)` | `:1070` | 压低（复位，合法） |
| OVL | `cfg_up` 清位 | `:1078` | **压低（唯一**，语义正确） |
| OVL | 活帧推进写 `upd_wr_data && !retx_active` | `:1099` | **抬高（唯一）** |
| else | 复位 / `cfg_up` / 推进写 / 读口 | `:2141` / `:2149` / `:2190` / `:2237-2238` | 同形 |

⇒ **没有第三处写**；**除 `cfg_up` 外没有任何降低 `whi_r` 的路径** ✓。设计件 §3.2-(4) 的"写者纪律一句话"**逐字进了 RTL 注释** ✓（OVL `:489-490`、else `:1598-1600`）。

### ⑥ 判据面 / `tot_red` / 残留 / 达成

- **三个定向计数器都在和式里** ✓：`tb:2377-2381` 逐字 `… e_ag_block + e_ag_resume + e_ghost + e_ringhi;`。
- ⚠️ **`e_j9` 双计（既存）**：和式 `:2379` + `:2457 if (e_j9>0) tot_red+=1`；`e_f1_ring` 同款（`:2455`）。本跑**无影响**（三臂 `J9=0/F1_ring=0`）。`e_ghost/e_ringhi` **只计一次** ✓（全仓仅 `:765`/`:2361` 两处自增）。
- **残留 R1–R4**：设计件 §9.1 齐（R4 = 审查新增 A4 角 ✓）；实施件里 R1（payload 残留）与 R4（豁免实现）有落点，**R2/R3 只在设计件**（清单所有者是设计件，可接受，但应写清"实施件不重复登记"）。
- ⭐ **第 5 个残留（豁免的覆盖代价）= 真的、且只写在 commit**：M-3 `ghost 30→25`；TB/RTL 注释里**没有**这条 ⇒ 建议升 **R5** 并写进 `tb:735-761`。
- **"达成"裁定（只给证据面）**：
  - **3 条幽灵红清 0 = 成立** ✓：`PRE1`（改前 RTL+改前 TB，我跑）= `reds=5`，5 条 `[FAIL]` 与设计件 §5.5 表**逐字相同**（含 3 条幽灵红）；`S` 臂这 3 条全消失 ✓。
  - **S 臂 4 条归属表：3 条站得住、1 组（j9/j6）站不住**：① `payload conn=0 off=7 @264351` = 洞族残留 ✓（未被 `e_ghost` 命中 ⇒ 错字节在 `whi` 以下，该推理成立；⚠️ 它与改前 `[S#1]`（`seq=000de510 off=0`）**不是同一帧** ⇒ "就是 R1 那条"是【推断】，且 **R1(aqsyn 洞) 与 R2(restore 延迟洞) 本跑未分开**）；② `RETXFIX jump @342415` = cfg_up 假构造 ✓（同位素臂：撤清位 ⇒ 0）；③ **`PS j9`/`PS j6` = 我不支持"同源"**（下表）；④ **没有第 5 条未归属** ✓。
  - ⭐ **j9/j6 的新证据（本轮最重要的实质发现）**：

| 臂 | clear | PERSIST_EN | payload | seqcont | jump | PS j9 | PS j6 | reds |
|---|---|---|---|---|---|---|---|---|
| PRE1（改前 RTL+TB） | n/a | 1 | 3 | 1 | 0 | 0 | 0 | 5 |
| PRE2（改前 + NEGCTL） | n/a | 0 | 14 | 0 | 0 | 0 | 0 | 21 |
| **S** | 有 | 1 | 1 | 0 | **1** | **1** | **1** | 4 |
| **V1（=S 只撤清位）** | 无 | 1 | 1 | 0 | **0** | **1** | **1** | 3 |
| **T** | 有 | 0 | 0 | **13** | **2** | 0 | 0 | 22 |
| **V5（=T 只撤清位）** | 无 | 0 | 1 | **0** | **0** | **1** | 0 | 9 |

    读法：撤清位后 jump/seqcont 消失、**j9/j6 不消失**；j9 在 T 臂**缺席**、在 V5 出现 ⇒ "j9/j6 = `whi=0 ∧ snd_nxt 高`（ring_ovf 关重放 ⇒ RTO 反复）"这条机制**被否**。⇒ 诚实口径：**j9/j6 是本刀在 persist 臂引入的新红（改前两臂都没有）、归因未定位**；候选 = ① `ring_restore` 的延迟洞读（残留 **R2** 的可观测面）② TB `cfg_up` 的**其它**清位（`rto_pend/timer/epoch`，我的实验未分离）③ persist FSM 相位漂移。**不许**再写"与 `e_ghost` 假阳性同源"（"不可判"可保留，但要换理由）。
  - **T 臂 `payload 14→0` = 可信** ✓：两跑对撞独立证实（`PRE2`=14、签名 `conn=0 seq=00140c02` 与设计件逐字相同 → `T`=0）；M-3 臂 `payload=3` ⇒ 判据有牙 ✓。

### ⑦ 静默漏项 / 行号

- **逐 hunk 对设计件 §3.2/§3.3："点了名但没做" = 0** ✓（两分支的 声明/复位/`cfg_up`/推进写/装载钳位/`ring_delta`/`ring_ovf`/`ring_start`/`replay_jump`/`ring_restore`/写源 mux（含 `upd_id` B-7）/`e_onehot` 扩项/写者纪律注释 **全部有落**；`slow_cfg_adp`/`tcb.v`/`wrapper_p4.v` **一字未动** ✓）。
- **行号抽核 24 条**：✅ 命中 = `tb:762`·`735`·`2223`·`2631`·`2377-2381`·`2416`(REDS 行)·`946`(`frame_check` 在 `if (m_tlast)` 内 ⇒ **帧尾直读** ✓)·`1266`/`1511`·`1126-1128`·`2627-2630`·`1094-1117`·`rtl:1070/1078/1099/1167-1168`·`rtl:2141/2149/2190/2237-2238`·`rtl:1300`·`wrapper:2055/2068-2071/2076/2172-2173`·`wrapper:2101-2103`·`slow_cfg_adp:156-198` 与 `:192/:195/:196`（**逐字精确**）·`tcb.v:5`·`rtl:489-490`/`:1598-1600`。
  ❌ 不成立 6 + 范围错 1：`tb:1219/1464`（标 cfg_up；真值 `:1266`/`:1511`）·`tb:1085-1087`（真值 `:1126-1128`）·`tb:2580`（真值 `:2627-2630`）·commit `0bbda0e` ② 的 `tb:818`（标"TB 前沿模型"；真值 `:847-849`）·`rtl:792` 的 `(:1264)`（`ctrl_seq=rb_snd_nxt` 真值 `:1300`）·`rtl:792` 的 `(:2003-2007)`（真值 `:2060`/`:2305`/`:2344`）·`rtl:2182-2188(6 行)` 范围尾。**错法一致**：照抄设计件**改前**行号或指向邻近段落，**无一条指向无关区域**。
- **CRLF/行数（我自己算）**：`rtl 2576 行 / 2576 CRLF / 0 纯 LF` ✓；`tb 2706/2706/0` ✓（与 `0bbda0e` 声明逐字相符）；TB 预处理器**栈平衡 final depth=0** ✓（naive 计数会被 `:934/:935` 的同行 `ifdef…`else…`endif` 误报 +2）。

## (B) 独立复跑（全部我自己跑的，不采信实施者日志）

方法：`xvlog -work xil_defaultlib <defs> <RTL> rtl/{tcb,fifo_sync,checksum16,retx_ram}.v <TB> → xelab -debug typical → xsim -runall`；工作目录在系统 temp（**不在仓内**）；三个必需臂用现役入口 `author_gate/run_ghost_arms.bat`（`run*/` 已被 `.gitignore:725` 忽略）。

### B-1 三个必需臂（我的原始行）

**S 臂**（`-d TCP_TX_OVL -d ARM_PERSIST`）—— 期望 `reds=4/ghost=0/e_ringhi=0/e_j9=0/e_seqcont=0`：
```
[FAIL] payload conn=0 seq=000bc8e5 off=7 got=36 exp=74 @264351
[FAIL] RETXFIX jump: session end snd_nxt=0004e59c < retx_hi=0004ebb9 conn=1 @342415
[FAIL] PS j9: Δstat_retx=21 > TB 注入的 retx 请求数=17 (探询引出会话?)
[FAIL] PS j6: 无在飞+窗0 时出现探询 =1
REDS parse=0 csum=0 payload=1 seqcont=0 seqmono=0 ctrl=0 ctrl_to=0 onehot=0 pendbusy=0 replay=0 stuck=0 ovf=0 ackf=0 ghost=0 ringhi=0
REDS2 replay_gap=65 below_una_during_retx=36 replay_tail_short=51 (info) F1_ring=0 J9=0
TB_TCP_TX_OVL: FAIL reds=4
```
⇒ **与实施者逐字相符**。⚠️ 口径：期望里的 "`e_j9=0`" 是 `REDS2` 的 **J9**（我核 = 0 ✓）；S 臂另有一条**同名不同物**的 `PS j9`（persist 族）。

**T 臂**（`PERSIST_NEGCTL`）—— 期望 `payload=0`：
```
REDS parse=0 csum=0 payload=0 seqcont=13 … ghost=0 ringhi=0
REDS2 replay_gap=77 below_una_during_retx=54 replay_tail_short=104 (info) F1_ring=0 J9=0
TB_TCP_TX_OVL: FAIL reds=22
```
⇒ **`payload=0` ✓**（`seqcont=13` 与实施者一致）。红构成我分组核过：`13 seqcont + 2 jump + 7 PS = 22` ✓。

**M-3（X 臂）**（`mut_ghost_m3.v` = `ring_hi` 退回缺陷语义；**是 HEAD RTL 的单 hunk 变异**，我 diff 过）—— 期望 `ghost=25/reds=30`：
```
[FAIL] ghost conn=3 seq=00006f8f plen=1 tail=00006f90 whi=00006f8f @36296   （共 25，打印限 5）
[FAIL] payload conn=0 seq=000de510 off=0 got=cf exp=6b @317103
[FAIL] seq partial conn=1 seq=0004e59c plen=29 exp=0004e5a4 @347515
[FAIL] payload conn=1 seq=0004e59c off=8 got=2d exp=9f @347515
[FAIL] payload conn=1 seq=0004e5a4 off=0 got=2d exp=9f @353173
[FAIL] PS j8 空判据: epoch 未饱和 (blocked 见证=0)
REDS parse=0 csum=0 payload=3 seqcont=1 … ghost=25 ringhi=0
TB_TCP_TX_OVL: FAIL reds=30
```
⇒ **`ghost=25/reds=30` 逐字成立** ✓。⭐ **分解式独立验证**：`xs.log` 全文 `[FAIL]` 行分组**只有 4 类**（`ghost`(计 25)/`payload`×3/`seq partial`×1/`PS j8`×1）⇒ **`25+3+1+1=30`** ✓；REDS 行内计数和 = 29 + `PS j8`（不在 REDS 行、直接进 `tot_red`）= 30 ✓ ⇒ **`e_ghost` 确实在和式里**（那条"唯一证据"成立）。`J9=0/F1_ring=0` ⇒ 双计没掺进来 ✓。

### B-2 我额外跑的臂

| 臂 | 内容 | 我的读数 | 用途 |
|---|---|---|---|
| **PRE1** | 改前 RTL+改前 TB | `payload=3 seqcont=1`、`reds=5`；5 条与设计件 §5.5 表**逐字相同** | "改前必红在案" ✓ |
| **PRE2** | 同上 + NEGCTL | `payload=14`、签名 `conn=0 seq=00140c02`；`reds=21` | "T 臂 14→0" ✓（对撞） |
| **arm B** | `-d TCP_TX_OVL`（无 ARM_PERSIST） | `TB_TCP_TX_OVL: OK`，REDS 全 0 | 豁免惰性面 ✓ |
| **SDBG/TDBG** | S/T + `GHOST_DBG` | 13/13 `GDBGSC` 行；`GDBG sessend @342415 c=1 snd=0004e59c ring_hi=00000000 retx_hi=0004ebb9 ovf=1 … rest=0 drain=1`（**与登记逐字相同**）；`GDBG cfgup @300587 id=1` | 登记引用证据 ✓ |
| **V1** | **同位素臂**：撤 `cfg_up` 的 whi 清位 + S defs | `payload=1 seqcont=0 ghost=0`、**jump 0**、`reds=3`(=payload1+PSj9+PSj6) | jump 与 clear 同因 ✓；**j9/j6 不同因** ⛔ |
| **V5** | 同上 + NEGCTL（=T 的对照） | `payload=1 seqcont=0 ghost=0`、jump 0、`reds=9`(含 PS j9) | **13 条根因 = clear** ✓✓ |
| **V2** | **变体 TB**：拆掉 `e_ghost` 的 `ifdef TCP_TX_OVL`（默认支也编） | `ghost=346`、`reds=346`；前 5 条形如 `… tail=0000f6b5 whi=00000000 @439`、`… tail=0000fc69 whi=0000f6b5 @838` | ⭐ **"默认支帧尾直读结构性误报（arm A e_ghost=346）"独立复现** ✓（"tail=本帧尾/whi=上帧尾"形态逐字可见） |
| **V6** | **变体 TB**：撤 `!is_probe` + `GHOST_DBG` | `ghost=2`、`reds=6`；两条 `PROBE=1`/`whi=0` | 豁免正打在那两条 ✓ |
| **P4 矩阵** | `run_matrix_p4dfix.bat -only chain+burst200`（post-B2） | `GATE chain EXIT=0` / `GATE burst200 EXIT=0` / `RC=0`；我的两门 console 与归档后件**逐字节相同** | else 支回归 ✓（力量低，见 ④） |

### B-3 与实施者读数不符之处：**无**（三臂逐字相符）

唯一"不符"是**口径**：commit 写 M-3 期望"30/35"（TL 预期）、实测 `25/30` 并如实上报 —— 我复跑确认 `25/30` 且分解式成立；采纳 (a) 的理由我也核了：`run_tx_ovl_gate.bat` 的 X/Y/Z 只查 `RC!=0`（计数不进退出码）✓。

## §C 卫生（硬边界自核）

- 报告文件被 harness 拦下 ⇒ **全文在本回复**；除本回复外**未新增任何文件**。
- **RTL/TB/门/脚本/设计件未改**；`git diff HEAD` = 空；`git status --porcelain` 已跟踪面 = **空**（我跑动的 `sim/p4sim/matrix_p4dfix.log` 已 `git checkout --` 复原；我误建在仓根的 `V1..V4` 已删除；我的 `P4_MATRIX_FINGERPRINT_20261010_232332_*` 已删除）。变体源/日志留在 `%TEMP%\retxhi_rerun\` 供复算。git 只读。

## 「TL 必须拍板」

1. ⭐ **PS j9/PS j6 的归属**（最高优先）：登记的机制**被同位素臂否掉**。三条路：① 补一条把"`cfg_up` 的**其它**清位（`rto_pend/timer/epoch`）"分离掉的实验；② 口径改成"**本刀在 persist 臂引入的新红、归因未定位（候选含 R2 的可观测面）**"并承认"不可判"暂缺依据；③ 直接判为"未解释的行为变化"升级待办。⛔ 现状（"同源+不可判"写进 TB 注释）**不该按原文接手**。
2. ⭐ **豁免的覆盖代价升 R5**（写进 `tb:735-761` + 设计件 §9.1）。
3. ⭐ **"板侧结构性不可达"补范围限定**（只覆盖"陈旧数据"那一半；探针子类另判）。
4. **6 处行号订正**（尤其 `tb:1219/1464`、`tb:1085-1087`、`tb:2580`、`rtl:792` 两条 —— 都在**新增的承重注释**里）。
5. （既存）`e_j9`/`e_f1_ring` 双计是否搭车修。
6. **构建前的时序账**：本刀两分支各加 16×32b 阵列 + 组合钳位 ⇒ 设计件 §8.1 的 `+544FF / +100–250 LUT`、"不新增长锥"仍是**纸面**，须一次构建收口。

## 「未做」

1. **未跑 `run_tx_ovl_gate.bat` 全 26 臂**（只跑了上表列出的臂；X/Y/Z 之外未重跑）。2. **未做位级/wdb 等价性**（除 chain/burst200 stdout diff）。3. **未综合/未构建/未上板/未 ssh** ⇒ 代价、时序、`ring_hi` 对 F1 保护面的板级影响全**未测**。4. **未核** else 支镜像在别的 TB（`p5close`/`p5d_*`）的行为变化（chain/burst200 不激励该通路）。5. **未分离** R1 与 R2 对 S 臂那条 `conn=0` payload 红的贡献。6. **未核** implicit-gate 键表对新增代码的命中；**未核**常驻矩阵 manifest 是否含本轮两文件（设计件 §4.4 说含 `tcp_tx_frame.v`）。7. **未判**设计件 §6（板级构型）/§8.3（persist 先后）—— 属 TL。8. **未核** §8.1 的 LUT/FF 估计与 §7.2 的两个替代口径可执行性。

---

## TL 核查批注（TL 追加，**非交付件原文**）

**TL 裁定（对 §「TL 必须拍板」六条）**：

1. **PS j9/PS j6 = 采路 ② + 要求补做 ①**。理由：同位素臂的证据是决定性的（撤清位后 `jump`/`seqcont` 消失而 `j9/j6` **不消失**；`j9` 在 T 臂缺席却在 V5 出现）⇒ **"同源"必须撤回**。口径改为"**本刀在 persist 臂引入的新红，归因未定位**"，候选三条（含 R2 的可观测面）写进登记；并**补做那条分离实验**（把 `cfg_up` 的其它清位分离掉）—— ⚠️ **这条不只是文档事**：它意味着**缺陷刀与 persist 刀存在未定位的交互**，直接影响构建与归因，必须在构建前尽量判清。
2. **升 R5** —— 采纳（写进 `tb:735-761` + 设计件 §9.1）。
3. **补范围限定** —— 采纳。
4. **6 处行号订正** —— 采纳（都在新增的承重注释里，必须准）。
5. **双计** —— **登记不修**（既存、非本刀、且本跑无影响；避免本刀再动 `tot_red` 算术）。
6. **时序账** —— 采纳：构建是一次性收口，**构建前不再声称时序**。
