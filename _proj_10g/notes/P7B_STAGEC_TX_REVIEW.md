# 对抗审查：P7b Stage C（`tcp_tx_frame` 乒乓 `TCP_TX_OVL` + A2）—— **抓到 1 个阻断级真缺陷**

- 日期：**2026-10-07**　仓库 `D:\repo\XCKU5PMini\udp_hls_10g`，HEAD **`46b2f68`**（工作区未提交：`rtl/tcp_tx_frame.v`、`rtl/app_pattern.v`、`tb/tb_tcp_tx_ovl.v`、`tb/tb_app_a2_equiv.v`、`sim/p7b_stagec_{tx,a2}/`）。
- 性质：**只读**（未改任何既有 `rtl/`、`tb/` 文件；未提交 git；未烧板；`0x08` 一字未写）。新增件全在我独占目录 **`sim/p7b_stagec_tx_review/`**。**驳据都用"我自己的 TB"复现**，不采信作者自报。
- ⚠️ **并发**：全程有两支 xsim 在跑（另一 agent 的全仓回归）。我所有结论的 A/B 臂都**逐字复现**（确定性行为，非统计读数），未出现"孤零零一条红"，故无需隔离窗重跑。
- 立场：**默认它是错的**。结论 = "能不能进构建"，不是"实施态度好不好"。

---

## 0. 先给要点

| # | 被审面 | 裁定 |
|---|---|---|
| 1 | `+799/−0` 纯插入 / 宏关逐字回退 | ✅ **挡得住**（两套独立方法复核） |
| 2 | 门抓的真缺陷（`ring_eval` 漏 bank 门）修好了吗 / 同类漏项 | ✅ 修对；**但互斥表本身不全** ⇒ 见 **#5-F1** |
| 3 | `M-C6` 未证（"构造不出激励"） | ⛔ **作者结论不成立**：我构造出定向激励并**实测该变异变红**；⚠️ 交付门里的 `c6_n` 是**死计数器（结构性恒 0）** |
| 4 | J9 短差 1–1532 B 是不是真缺陷 | ✅ **不是真缺陷**（记账窗口伪影，有结构论证）；⚠️ **判据本身未收口**（TB 已自降级） |
| 5 | 7 条与设计件的偏差 | 逐条核过 ⇒ **偏离本身挡得住**；⛔ **但 D4( bank 门 ) × FIX-2'( 帧首预留 )** 的组合打开了 **F1（阻断级真缺陷）** |
| 6 | 余量 5 拍 vs 设计 4 拍 | ✅ **挡得住**（同一事实的两种口径；核心不变式"写同沿落地⇒下拍可读"与余量无关） |
| 7 | A2 的 `+72/−0` 与同批影响 | 等价性 ✅（我独立复核）；**同批交互 = 无法判定**（无门覆盖 `app_pattern(P7B_10G) × tcp_tx_frame(TCP_TX_OVL)`） |
| 8 | 门自身可信度（A 臂/见证/第 9 个变异） | ⚠️ **部分挡得住**：A 臂含义正确、8 个变异有牙；**但 `M-C6` 无牙、`M-C4` 未实现、2 条设计见证未实现、1 条见证只打印不断言** |
| 9 | 还有谁受 `TCP_TX_OVL` 影响 | 只有本门；`board/` 未加宏、`p4gates`/`p7b_chain` 和所有其它 TB 编的都是默认分支（= 基线逐字） |

> ⛔ **阻断项 = F1**（`retx_hi` 被控制帧预留 `+1` 越顶 ⇒ `ring_delta` 下溢 ⇒ **G9 类重放洪水**）。最小反例已复现（新 TB，生产合法路径）。

---

## 1. `+799/−0` 是"纯插入"—— ✅ 挡得住（我自己核的）

**方法一（自写预处理器，`sim/p7b_stagec_tx_review/chk_pure_insert.py`）**：先去 `//` 与 `/* */` 注释，再按 `ifdef/ifndef/else/elsif/endif/define/undef` 逐行求值（未平衡即硬失败）。读数：

```
base == HEAD:rtl/tcp_tx_frame.v : True
P1' 宏关预处理输出 == 基线预处理输出 : True      (1147 行)
子序列检查 (基线全部行按序出现在新文件): OK
新文件多出的行数 = 799
```

**方法二（原始文本级定位，不信任何预处理器）**：插入区**两段、恰 799 行**，且 `else` 分支与基线逐字节对齐：

```
new[204..1001]  (798 行)  first='`ifdef TCP_TX_OVL'  last='`else'
new[1955..1955]  (1 行)   first='`endif'
new[1002] == base[204] : True    (S_IDLE localparam)
```

**嵌套/else 藏东西？** 区间内全部指令 = `` `ifdef TCP_TX_OVL ``(204) · 嵌套 `` `ifdef APP_MODE``/`` `else``/`` `endif``(405/408/411，平衡) · `` `else``(1001) · `` `endif``(1955)。⇒ 宏关时整段被丢弃、`else` 分支 = 基线 204..1155 逐字、尾部 `endif` 前插入 ⇒ **宏关输出 = 基线**。作者 `apply_ovl.py --check` 复跑亦 `P1/P2/P3 OK`（与我的独立结论一致，非同一工具的复述）。
**反例构造失败说明**：我尝试用三种方式找破绽（另一套预处理器、原始行级子序列、指令平衡扫描）**均未找到** ⇒ 判"挡得住"。

---

## 2. `ring_eval` 的 bank 门与"同类漏项"—— 修对了；**但表不全**

- 修复在位：`rtl/tcp_tx_frame.v:423-424` `ring_eval = rx_idle && … && !bank_rdy[rx_bank]` ✓ 与设计 §1.2 表逐字一致。
- 设计 §1.2 互斥表**逐条对 RTL**（我核的 5 行 + 写源 3 行 + 旗 1 行）：

| 设计门 | RTL | 结论 |
|---|---|---|
| `svc = rx_idle && !ack_pend_r && !retx_active && !flush_pend && (retx_req\|\|rto_pend_any)` | `:419-420`（`!rx_flush` 代替 `!flush_pend`，冗余但无害） | ✓ |
| `ring_eval … && !bank_rdy[rx_bank]` | `:423-424` | ✓（= 本轮的修复） |
| `scan_now = rx_idle && … && scan_tick` | `:425-426` | ✓ |
| `start_ack = rx_idle && ack_pend_r && !ackq_empty && !flush_pend && !ctrl_slot_busy` | `:427-428` | ✓ |
| `flush_act`（由状态承载） | `:392-393` / `RX_FLUSH` 分支 `:856-862` | ✓ |
| 写源三根 + `$onehot0` | `:436-444`（`upd_wr_data` 唯一定义处） | ✓ |
| `pend ⊆ busy` | `:777-778`（同拍置）/`:871,:877` 与 `:959`（清） | ✓ 结构性（清 pend 的拍上 busy 恒 1） |
| **跨拍独占（设计 §2.2b）** | bank ✓（接受门 `:462/465`）· 槽 ✓（`!ctrl_slot_busy`） | ✓ |

⇒ **表内的项一条不漏**。但"同类"的更深答案在下一条：**表只覆盖"同拍写口冲突"，没覆盖"控制帧预留 `+1` 与在飞 retx 会话"的跨拍相互作用** ⇒ 见 §5-F1（阻断级）。

---

## 3. `M-C6` 未证 —— ⛔ **判据可造、作者结论不成立**；且交付门里的 `c6_n` 是死计数器

**作者主张**（`P7B_STAGEC_TX.md` §5-2）：该窗口整轮只命中 2 次；把请求保持住会退化成风暴 ⇒ 给不出有统计力的激励。

**我的定向激励（新 TB `sim/p7b_stagec_tx_review/tb_mc6b_probe.v`）**：把"FIN 已预留未发"的窗口**撑开**（`m_tready=0` ⇒ 控制帧发不出去 ⇒ 槽 `busy` 恒 1 达 202 拍），窗口内拉 `retx_req`（电平）⇒ `svc` 每拍都够，但语义上必须被 `!ctrl_adv_inflight` 挡住。逐字复现命令：`cmd //c 'sim\p7b_stagec_tx_review\run_mc6b_probe.bat'`。

| 臂 | `gated`(=svc∧adv_inflight) | `rew` | 线上 `onebyte_seqF` | 判定 |
|---|---|---|---|---|
| **A = 现役 rtl** | **207** | **0** | **0**（只有 1 个 FIN） | 门在工作 |
| **B = `mut_c6`（撤门）** | 2 | **2** | **2**（`seq=F plen=1` 两帧上线） | **变异红** = C6 的 1 字节重放签名 |

⇒ **M-C6 可判**（我构造出了激励，且它红在一条可打印的判据上）。作者"构造不出"的失败来自其 TB 的**无界保持**写法（空 ring ⇒ 每拍 1–2 拍空会话风暴），不是设计的性质。

⚠️ **顺带抓到一个交付件缺陷**：`tb/tb_tcp_tx_ovl.v` 的 `c6_n` **从未自增**（全文件命中只有 `:209` 声明 / `:222` 初始化 / `:1033` 打印）⇒ 印出的 `c6_fires=0` **是结构性恒 0**（本工程 #37/#38 同族："自检被预 AND 成结构性恒 0"）。**作者笔记里"命中 2 次"在交付件里不可复现**（该读数不来自本件）。

---

## 4. J9 的 1–1532 B 短差 —— ✅ **不是真缺陷**（但判据未收口）

**结构论证（我从 RTL 读出的，替代"行/列交错"的叙事）**：

1. 会话终止条件 = `ring_delta == 0`（`ring_delta = retx_hi - rb_snd_nxt`，`:478`；排空拍 `:735-749`）⇒ 会话结束时 `snd_nxt` **必然已追平 `retx_hi`**。
2. `snd_nxt` 的**每一次**推进都来自 `upd_wr_data`（`:436`/`:443`，`RX_FIN` 首拍），其值 = 该帧自己的 `f_seq + f_plen` ⇒ **推进量与被推进区间一一对应**（区间 [旧值, 新值) 由**这一帧**的线上字节覆盖）。
3. 被推进的帧此刻已写进 bank（`RX_FIN` 末拍 `bank_rdy <= 1`，`:847`）；`bank_rdy` **只由 TX 的 `T_DONE` 清**（`:971`），而接受门要求 `!bank_rdy[rx_bank]` ⇒ 该 bank 不可能被新帧覆盖/冲洗 ⇒ **必然上线**。
4. ⇒ 重放窗口 `[snd_una, retx_hi)` 的覆盖**由构造保证**；若真少一段，后续帧的 seq 前沿会出现**空洞** ⇒ TB 的 J4（hole 分类，`tb_tcp_tx_ovl.v:448-453`）必红——而 B 跑 `seqcont=0`。

⇒ 短差 = **记账窗口伪影**（会话结束前后仍留在 bank 里待发的帧 + 会话期外别的连接的推进写；而 `retx_active` 是全局旗 ⇒ TB 的窗口计数天然切不干净）。**作者的降级处置是对的**。
⚠️ **残留**：判据层仍空着。建议补一条可切分的判据（见 §6-B4）：*"会话结束后 N 拍内，该连接线上**覆盖并集**必须达到 `retx_hi`"*（并集用 TB 侧按 seq 区间记，而不是"会话期内的帧"）。

---

## 5. 7 条与设计件的偏差 + **新缺陷 F1**（阻断级）

### 5.1 逐条核（偏离本身能不能把安全性论证推翻）

| 偏差 | 我的核 | 裁定 |
|---|---|---|
| **D1** 无 per-bank `is_*`（帧类型由来源结构决定） | 控制帧 `doff` 由 `ctrl_doff_now`（`:519-520`）· 数据/重放硬编码 `16'h5018`（`:718,:802`）· `stat_ack` 用 `tx_is_ctrl`（`:957-958`）= 默认分支 `!is_data_r` 逐字同义 | ✅ 等价 |
| **D2** `flush_pend` 由 `RX_FLUSH` 状态承载 | `rx_flush`/`flush_act`（`:392-393`）+ 排空退出（`:856-862`）；所有服务门都含 `rx_idle` ⇒ 冲洗期结构性互斥（比 flag **更强**，flag 还需逐个门检查） | ✅ 等价且更强 |
| **D3** 活帧/重放校验和统一在 `RX_FIN` 末拍算 | 值是**同一批已锁存字段**（`f_*[rx_bank]`）+ 同一函数 ⇒ 与默认的"首拍算"同值；`csum_valid` 相对时序逐拍一致（fin@3→latch@4 vs fin@wait3→latch@wait4） | ✅ 等价 |
| **D4** `ring_eval` 补 `!bank_rdy[rx_bank]` | 在位（`:423-424`） | ✅ 修对 — ⛔ **但见 F1** |
| **D5** 控制帧 TX 占 8 拍（无 `S_WAIT`） | 组合校验和（`:517-530`）+ 槽装载（`:775-793`）⇒ `T_HDR 6 + T_PAY 1 + T_DONE 1` = 8 ✓ | ✅ |
| **D6** 变异集缺 `M-C4` | 未实现（作者已登记）⇒ **会话终止/`stuck` 判据无负对照** | ⚠️ 登记 |
| **D7** TB 口径用"交棒拍→下一帧首拍" | 实测 `min_fin_gap=1`、`cov_fin_min=714`；另量 `advwrite_to_next_start=5` | ✅ 见 §7 |

**"无 per-bank `is_*`"与"flush 由状态承载"这两条**（任务点名）——都不会推翻设计的安全论证：前者只删了 4 位**未被消费**的冗余（消费点全部由来源决定），后者把"旗"换成"状态"，是**更强的互斥**。（反例构造失败说明：我为 D1 逐一列了 `is_*` 在默认分支的全部消费点——`S_DONE` 的 `fin_sent_r/rst_sent_r/fin_seq_r`、`stat_ack`、`upd_val`——在 OVL 里分别由 `ctrl_is`、`tx_is_ctrl`、写源选择器一一对应，找不到不等价处。）

### 5.2 ⛔ **F1（新，阻断级）：控制帧预留 `+1` 越顶 `retx_hi` ⇒ `ring_delta` 下溢 ⇒ G9 类重放洪水**

**一句话**：`svc` 在"无事在飞"时开一个**空转会话**（`svc_rewind=0` ⇒ `retx_hi := rb_snd_nxt`，`:702-703`），该会话因 **D4 的 bank 门**（`:423`）被挡而**长时间存活**；期间一条 FIN/RST 被推入 ackq，`start_ack` 弹条目并**同拍预留 `+1`**（`:437`/`:443`）⇒ `snd_nxt = retx_hi + 1` ⇒ 下一个干净 `ring_eval`：`ring_delta = 0xFFFFFFFF`，而 `ring_start` 只看 `!= 0`（`:479`）⇒ **伪真** ⇒ 每次 1460 B 的重放帧，且 snd_nxt 继续前进 ⇒ **自持洪水**（每次重放把 snd_nxt +1460，delta 从 4.29e9 收敛要 ~2.94M 帧 ≈ 3.6 s @156 MHz）。

**最小反例（生产合法路径，`tb_ovl_flood_probe.v` arm A；`cmd //c 'sim\p7b_stagec_tx_review\run_flood_probe.bat'`）**：

```
[TCBW] @45  val=0000f008          ← 数据帧 A(8B) 的推进写 (app s_axis)
[TCBW] @168 val=0000f010          ← 数据帧 B(8B) 的推进写
[SVC]  @196 rew=0 snd_nxt=0000f010 una=0000f010    ← 空转会话 (retx_req 电平, 无事在飞)
[TCBW] @320 val=0000f011          ← FIN 的**帧首预留 +1** (start_ack; 该拍 retxact=1)
[RING] @336 delta=ffffffff preset=1460 snd_nxt=0000f011 retx_hi=0000f010   ← 下溢 ⇒ 洪水
线上: 64 帧 (期望 3) — 61 个 1460B 重放帧, seq 从 0x0000F011 起每次 +1460
      snd_nxt 12000 拍内被推到 0x000251A9 (+~90 KB 越权 seq)
```

生产合法性逐条（这条决定它是不是"真问题"）：
1. 数据帧 = `s_axis`（与 `app_pattern` 同型）；
2. `snd_nxt == snd_una`（对端 ACK 到齐）= `rx_upd` 级写（真 wrapper `:1968` 的 tcp_rx 级）；触发源 = `retx_req`（dup-ACK；真 wrapper 接 tcp_rx），**gnt 后即撤**（本臂里 `retx_req` 早在 @196 就被 gnt 撤掉——洪水**不依赖**它继续存在）；
3. 会话之所以活到 @320：`bank_rdy[rx_bank]=1`（我以 `m_tready=0` 顶住 TX 复现乒乓流水常态）⇒ `ring_eval` 被 D4 门挡住；
4. FIN 走 **`fin_req` → 扫描 `fin_push` → ackq → `start_ack`**（真 wrapper 的关闭语义；`ack_fin` 在生产里恒 0，`wrapper_p4.v:2043-2045`）；
5. `+1` = FIX-2' 帧首原子预留。

**归因（默认分支 vs Stage C）—— 我两个臂都跑了**：

| 臂 | RTL | 结果 |
|---|---|---|
| **A** OVL（现役分支） | `mut_c6` 无关；**修复版** | **洪水**（对齐窗口 ≥124 拍：会话自 @196 活到 @336） |
| **C** 默认（HEAD，串行） | 我的同构激励 | 不洪水（`start_ack @336 retxact=0`：会话早已排空） |
| **D** 默认（HEAD）+ `fin_push` 同步激励 | 同上 | ⛔ **也洪水**！@335 `fin_repush` 压条目 → @336 `svc`（**落在 `ack_pend_r` 寄存器滞后窗内**）→ @350 第二个 FIN 的 `+1` → @351 `delta=ffffffff` → 1460B 重放帧从 `seq=F009` 起 |

⇒ **诚实的归因**：**同一族的下溢在默认分支（今天的生产 RTL）也已存在**（arm D 实测；触发要求 `svc` 拍落在条目压入后的 ~1–2 拍寄存器滞后窗内，且我这一臂还依赖 retx 请求被保持——**窗口窄**）；**Stage C 把窗口从"~1–2 拍"抬到"≥124 拍"**（D4 的 bank 门把会话拖长 + 帧首预留把 `+1` 提前到会话存活期）⇒ **从角例变成可实际发生**。⛔ **不能按"本来就有、不归本轮管"处置**：本轮**新开了可达面**，且后果是**静默数据损坏**类。

**板内可观测性（为什么它危险）**：`stat_retx` 只数 rewind；`seqmono` 看不见（推进写全是**前向**）；`ovf/eend/drop_len` 全 0；只有**线级**的洞（J4 的 hole 分类）或"帧数 vs app 期望"能抓到——**本门 2100 帧的激励从未命中这个相位**（B 臂全绿）。

**修复方向（作者定，我给三条，按代价排）**：
① **回放侧回绕安全守卫**（最小改动、最稳）：`ring_start` 增一项"`rb_snd_nxt` 未越过 `retx_hi`"的 wrap-safe 比较（或把负 delta 当"会话已完成"走排空支）——即把 `(ring_delta != 0)` 升级为"**正 delta**"；
② **源头 clamp**：控制帧预留写 `+1` 时若 `rb_snd_nxt >= retx_hi && retx_active` ⇒ 同步把 `retx_hi` 抬到新值（或直接推迟预留——会推迟 FIN，需评估）；
③ **门约束**：`start_ack` 增"该连接无在飞会话"（最保守，代价是 ACK/FIN 被推迟 ≤ 一个会话）。
**必须配的新判据**（我建议同时进门，负对照用我这条激励）：
- `retx_active=1` 期间**每拍** `retx_hi >= rb_snd_nxt`（wrap-safe 比较），或等价地在 `ring_start` 处断言 delta 非负；
- 或"会话存活期内不得有控制帧预留"（若采用 ③）。
**我的 TB 可直接当起点**：`sim/p7b_stagec_tx_review/{tb_ovl_flood_probe.v,run_flood_probe.bat}`（arm A 是正例=应红，修好后应转绿）。

---

## 6. 其余裁定要点

### 6.1 余量 5 拍 vs 设计 4 拍（任务 6）
**同一事实的两种口径**：写点 `W = T_last+1`（`fin_cnt==0`），最早下一帧首拍 = `W+5`（我按 RTL 复算：`fin_cnt` 0→4 共 5 拍 ⇒ `RX_IDLE` 首拍 = W+5）⇒ "距离 5 拍" = "余量 4 拍" ✓。**订正后正确性论证仍成立**：不变式是"写在 `W` 沿落地 ⇒ `W+1` 起组合读即新值"（`tcb.v:91` 同步写 + `:110` 组合读），余量只是边际；且**所有读 `rb_snd_nxt` 的决策点都被门限定在 `rx_idle`**（RTL 逐条核过：`svc/ring_eval/scan_now/start_ack/start_data/w_tap_seq/upd_val`）⇒ 最早帧首拍 = W+5 > W+1 ⇒ 结构性安全。

### 6.2 A2（任务 7）
- **等价性我独立复核**（`pre_a2 == HEAD` 逐字节 ✓；宏关预处理输出逐字节同 ✓；纯插入 **+72** ✓）⇒ 作者的机器证明**成立**。
- **29 文件 A/B 等价覆盖面**：够（14 实例 × 5 类判据 + 逐 beat `stat_*` 对账 + AXIS 保持合同 + 5 个负对照，其中 F=m4 只红"拍/帧"⇒ 判据有牙）。**不全的两格**（作者已自报其一）：
  ① **`ev_up` 恰落在"整字预取/填充拍且 `seg_sent==0`"**——无激励（作者登记"未测"）；
  ② **同批交互无门**：**没有任何 TB 把 `app_pattern(P7B_10G)` 接到 `tcp_tx_frame(TCP_TX_OVL)`**（A2 门无帧器、乒乓门用自造 app 源）⇒ 设计 §6.2 的接口义务（tready 只当背压、帧间 ≤3 拍、收帧拍 190）**没有门**（= T11 的缺口）。
- **同批会不会互相影响**：结构上兼容（`s_axis_tready` 在 OVL 分支对 ≤1500 B 帧**帧内不会中途掉**：帧 ≤188 字 < FIFO 深 256；`bank_rdy` 只在帧首门挡，A2 按标准 AXIS 挂起）⇒ **判"挡得住（各自门内）"；集成面"无法判定"**。

### 6.3 门自身可信度（任务 8）
- **A 臂绿说明了什么**：① 门的 oracle（校验和/载荷逐字节/seq 记账）在**已知正确件**（= HEAD 逐字件）上无系统性假红；② 共享判据可用；③ 与 D 臂（现役分支上打变异 ⇒ 红）合起来 = **现役串行支路有灵敏度**。**它不证明 OVL 分支的任何东西**（作者 §2.1 也是这么写的 ✓）。
- **覆盖见证 7 条**（B 臂）：`frames=2100≥2000` ✓ · `replay_sessions=17≥5` ✓ · `conns=4≥3` ✓ · `plen0=269≥1` ✓ · `singlebeat=812≥1` ✓ · `ctrlblock=7883≥20` ✓（+ `T8 rx1460=189≤190 / tx1460=191≤192` ✓ · `overlap=48%≥25%` ✓ · 三写源 >0 ✓）。⚠️ **与设计 §4.2 的清单比，缺口三类**：
  ① **`cov_aborts ≥ 2`**：TB 无该计数器（事实上有——`runB` 的 `drop_len=91` ⇒ 91 个中止帧 ⇒ 事实达标，**但无断言**）；
  ② **`cov_ctrl_data_write_adjacent ≥ 20`**：未实现；
  ③ **`finmin1_hits ≥ 20`**（设计见证 (iii)）：**只打印不断言**（`tb_tcp_tx_ovl.v:1009-1010` 打印，`summary_and_exit` 里无对应 `tot_red` 分支）；
  ④ `cov_ctrlblock` 是**超集计数**（`tb_tcp_tx_ovl.v:894-895`：`slot_busy && ack_pend_r`，**不含 `rx_idle`**）⇒ "槽忙时 `start_ack` 真被挡"的见证偏松。
- **9 个变异**：8 个按预期红（C/D/E/F/G/H/I/K，我逐条看了 REDS 行与红点，与作者 §2.1 的记账一致 ✓）；**第 9 个 = `M-C6`（`J` 臂，RC=0）**——作者在 runner 里**明确不计入 PASS**（`run_tx_ovl_gate.bat` 的 `FAILS` 累加不含 `RCJ`，行内标 `KNOWN GAP`）⇒ 这一格**口径诚实地空着** ✓。⚠️ 但 `M-C4`（重放自锁）**未实现** ⇒ `stuck=0` 这条"会话有界终止"**没有负对照**（无牙未证）。

### 6.4 谁还会受影响（任务 9）
全仓 grep `TCP_TX_OVL`（含 sim/board/tb/tcl/bat/f）：
- **定义处只有** `rtl/tcp_tx_frame.v`；**编译器只有** `sim/p7b_stagec_tx/**`（本门）+ 并发 agent 的镜像件 `sim/p7b_stagec_tx_regress/mut/*.v`（它是"真空门/镜像"审计件，不是第二个门）。
- ⇒ **`board/build_p7b_ku5p.tcl` 未定义该宏**（T12 构建收口未做 ⇒ 面积/时序仍零读数）；**`sim/p7b_chain`（真 wrapper 全链门）未接宏**（T11 未跑）；`sim/p4gates` 矩阵与所有 p5 系列 TB 编的都是**默认分支**（其内容 = 基线逐字 ⇒ 不受影响，但它们对**新分支**零判别力）。
- ⭐ 一条**降低 T11 风险**的事实（作者已登记，我复核）：**插入点在端口列表之后 ⇒ 新分支端口面 = 0**（`wrapper_p4.v` 无需改接线）⇒ T11 的"接线错"面比其它 ifdef 小；但**真 wrapper 的时序/背压集成**仍只有 T11 能覆盖。

---

## 7. 进构建前的**阻断项清单**

| # | 阻断项 | 收口判据 | 级别 |
|---|---|---|---|
| **B1** | ⛔ **F1：`retx_hi` 被 `+1` 越顶 ⇒ 重放洪水**（§5.2） | 修法（三选一）+ **新判据**（`retx_active` 期间每拍 `retx_hi >= rb_snd_nxt`，wrap-safe；或 `ring_start` 的 delta 非负断言）+ **负对照 = 我的 arm A 激励应红、修复后转绿** | **硬** |
| **B2** | `M-C6` 判据空着（本门无牙 + `c6_n` 死计数器） | 把"槽内控制帧未发窗口"的定向激励并入主门（我的 `tb_mc6b_probe.v` 是现成起点）；或至少**修 `c6_n`**（否则打印值恒 0，永远读不出命中数） | 硬（判据层） |
| **B3** | 构建收口本身未做 | `board/build_p7b_ku5p.tcl` 加 `verilog_define TCP_TX_OVL=1` + 一次构建（三类失败端点 `0/0/0`、`WNS>0`、新锥不进 DP 前 10）+ **T11 真 wrapper 全链门（宏两态）**；⚠️ 与 A2 同批 | 硬（流程） |
| **B4** | 判据收口（非阻断，建议同批） | ① J9 的"覆盖并集"判据（§4）；② 补 `cov_aborts`/`cov_ctrl_data_write_adjacent` 断言；③ `finmin1_hits` 进 `tot_red`；④ `cov_ctrlblock` 加 `rx_idle`；⑤ `M-C4` 类变异的负对照 | 中 |
| **B5** | 同批集成面无门（A2 × OVL） | T11（与 B3 合并） | 中 |

**无阻断的**：纯插入等价性 ✓ · 写点唯一性 ✓ · 互斥表（表内）✓ · 余量论证 ✓ · 7 条偏差（本身）✓ · A2 等价性 ✓。

---

## 8. 我没能判定的（别当结论读）

1. **面积 / 时序 = 零读数**（无构建权限）⇒ 本件所有"LUT/FF/级数"一字未给。
2. **F1 的生产触发率**给不出（需要真实 dup-ACK 与关闭时序的联合统计；无板级读数）。我只能给"结构可达 + 相对窗口宽窄"（≥124 拍 vs ~1–2 拍）。
3. **默认分支的"纯 1 拍精确构型"最小反例**没压出来——arm D 的臂里我保持了 `retx_req`；生产等价物是"`svc` 拍落在 `ack_pend_r` 滞后窗内"（我判 ≈1–2 拍，**未逐拍证死**）。
4. **`M-C4`（重放自锁）**类变异的灵敏度未测 ⇒ `stuck`/会话终止判据"无牙未证"。
5. **真 wrapper 集成**（T11）与 **TCP 源 193 拍全链**（MAC 不在本门内）未测。
6. **A2 × OVL 的同批交互**（背压/帧间气泡契约）无门 ⇒ 判"无法判定"（我给的是结构分析，不是读数）。
7. **F1 与设计件的关系**：设计 §3-C6 只分析了"预留先、回卷后"的方向（由 `!ctrl_adv_inflight` 兜住 ✓，我的 arm B 证明了该门的价值）；**"会话先、预留后"的反方向在设计件里没有条目** ⇒ 我判这是**设计面遗漏**，不是实施偏离。

---

## 9. 我跑过的每个动作（复现用）

```bash
cd /d/repo/XCKU5PMini/udp_hls_10g

# 1) 纯插入独立复核 (自写预处理器; 输出: P1' True / 子序列 OK / +799)
C:/Users/zhxue/anaconda3/python.exe sim/p7b_stagec_tx_review/chk_pure_insert.py
# 2) 作者件复跑 (P1/P2/P3 OK)
C:/Users/zhxue/anaconda3/python.exe sim/p7b_stagec_tx/apply_ovl.py --check
# 3) A2 宏关等价 (自写预处理器; pre_a2==HEAD True / 宏关输出逐字节同 / +72)
#    (chk_pure_insert.py 的 preprocess 复用; 见审查会话记录)
# 4) M-C6 定向门 (A=现役 207/0/0; B=mut_c6 → onebyte_seqF=2)
cmd //c 'sim\p7b_stagec_tx_review\run_mc6b_probe.bat'
# 5) F1 生产合法复现 (A=OVL 洪水 64 帧; B 同; C=默认不洪水; D=默认+相位同步 → 洪水)
cmd //c 'sim\p7b_stagec_tx_review\run_flood_probe.bat'
# 6) 作者整门复跑读数核对 (gate_out.txt / runB/xs.log)
grep -E "FRAMES|COV |MINGAP|DUT stat_frames|REDS2" sim/p7b_stagec_tx/runB/xs.log
# 7) 影响面 grep
grep -rln "TCP_TX_OVL" .   # 只有 rtl/tcp_tx_frame.v + sim/p7b_stagec_tx/** + 回归 agent 镜像件
```

新增件（全在 `sim/p7b_stagec_tx_review/`，独占目录）：
`chk_pure_insert.py` · `chk_ins_eq_branch.py` · `tb_mc6_probe.v`/`run_mc6_probe.bat` ·
`gen_mc6b.py` · `tb_mc6b_probe.v`/`run_mc6b_probe.bat` ·
`tb_ovl_flood_probe.v`/`run_flood_probe.bat` · `runA..runD/`（逐臂 xs.log 原件）。

**零板级动作**（未烧板、`0x08` 一字未写）；**零 git 写操作**；未碰 `board/`、`P7B_HANDOFF.md`、`udp_hls_10g/CLAUDE.md`、`PORT_NOTES.md`、`README.md`、`P7B_BIZ_PLAN.md`、以及另一支 agent 的 `sim/p7b_stagec_tx_regress/`。
