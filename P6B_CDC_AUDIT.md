# P6B_CDC_AUDIT — 跨域 FIFO 边界审计（P6b 数据面 125MHz ↔ 156.25MHz）

> 审计对象 = `board/wrapper_p4.v` 里**两个新插进来的跨域 FIFO**（`u_rxcdc` / `u_txcdc`）
> 及其上/下游的握手，重点是"**会不会静默丢字/说谎**"（上一个 FIFO 的 F4(b) 形态）。
> **本 agent 只写了本文件 + `audit_scratch/`；未改 `rtl/`、`board/`、`tb/`、`_proj_pcie/` 任何既有文件；
> 未 commit；未烧板；未跑综合。** 全部结论都有 xsim 原始读数（证据文件见 §7）。
>
> **被审版本（锁定）**：`fifo_async.v 1c21c0244b49b6ed5310b9346fe7cc25`、
> `fifo_sync.v d0d133edebc8a6f8df3baba20fa907c1`、`mac_rx_64.v 029f831e5582a580601db23620347205`、
> `mac_tx_64.v 50d606947d28207f6776694316cd5374`、`tx_arb.v f634b13bcc46b44a30367a3f9e654877`、
> `wrapper_p4.v 03e76507605f88acf2847dc5101eca14`（2026-09-29 10:56 与 11:12 两次一致 ⇒ 审计期间未被并行改动）。

---

## 1. 架构核实（先把"谁搬字"钉死）

```
RX: RGMII →u_mac_rx(mac_rx_64, gmii_clk=125M) ──AXIS 直连──▶ u_rxcdc(fifo_async 76/256/FWFT)
      rtl/mac_rx_64.v:361 内部 fifo_sync(W=76,D=8)         board/wrapper_p4.v:430-441
      m_axis_tready=~rx_fifo_full (:440)  ⇒ 内部 FIFO 弹出与 CDC 写入**同拍同条件**
    ──▶ vlan_strip(dp_clk=156.25M, :470) → rx_classify(:493) → 快/慢路径
TX: 数据面 →u_tx_arb(tx_arb, dp_clk) ──AXIS 直连──▶ u_txcdc(73/256/FWFT)
      rtl/tx_arb.v:29-36 纯组合输出                        board/wrapper_p4.v:2205-2214
    ──▶ u_mac_tx(mac_tx_64, gmii_clk, :2226) → GMII
```

**A1 答案**：**没有"搬运模块"** —— `mac_rx_64.m_axis_*` 直接接在 `u_rxcdc` 的写口上。
搬运就是握手本身：`u_rxcdc.wr_en = rxsrc_tvalid = !fempty(内部 FIFO)`，
`mac_rx_64` 的内部弹出 `rd = m_axis_tvalid && m_axis_tready`，而 `m_axis_tready = ~rx_fifo_full`
（`wrapper_p4.v:440`）——**两者是同一个组合表达式**，因此"弹出"与"跨域写入"逐拍原子。

---

## 2. 发现清单（按严重度）

| # | 严重度 | 一句话 | 证据 |
|---|---|---|---|
| **F-1** | 🟠 **中**（潜伏契约漏洞 + 板上不可观测） | `fifo_async` 的 `full` 在**写域复位释放窗口**里读 0（复位值），而此时的 `wr_en` 被**静默丢弃**（无写入、无计数、无探针）。⇒ 生产者若"与 rst_n 同拍释放"就会丢字，且 `!full` 这个唯一闸门**在此期间不可信**。`fifo_sync` 有 `ovf_pulse` 自检回读（F4 加的），`fifo_async` **没有**任何 overflow/接受写探针 ⇒ 这类丢失在板级不可判。 | 实测（t4 实例 C）：`model_acc=3999`（`wr_en && !full` 的拍数）vs `dut_acc=3996`（DUT 写指针变化次数）⇒ **3 个字静默丢弃**，同期 `fullcyc=0`、`wref=0`。代码：`rtl/fifo_async.v:140-152`（本域同步释放）、`:164-187`（`full_r` 复位值 0）、`:216-219`（只有 `wr_ok` 才落笔）、`:98-124`（端口表**无** ovf 探针） |
| **F-2** | 🟠 **中**（F11 确认，线上坏帧当好帧） | `mac_tx_64` 帧内中止（源断供）后**残字被当成新帧的开头发出去**：线上出现一个 **FCS 完全正确的"幽灵帧"**，其载荷是被中止帧的**中段残字**。对端（含本板 RX 侧）无法分辨，会当合法帧收下 ⇒ 数据面被注入垃圾载荷。P6b 的 256 深 CDC **只是把中止门槛抬高**（要"持续型断供"才触发），**不改变后果**。 | 实测（t3）：线上 4 帧 = `B(完整✓) / 中止帧(runt 328B, FCS-BAD) / **幽灵帧 652B, FCS-OK, content = 帧A 字节[320..960)** / C(完整✓)`；`mac_abort=1, wire_frames=4, ghost=1`。代码：`rtl/mac_tx_64.v:148-152`（中止回 S_IDLE）+ `:107-128`（下一次 S_IDLE 直接把 FIFO 头字当新帧）+ `:179-186`（`stat_frames++`） |
| **F-3** | 🟡 **低-中**（复位不同源；未在链上实测） | 两个 CDC FIFO 的复位**只接板级 `reset_n`**，而数据面功能逻辑接 `dp_rst_n`（`clk_gen_p6b` 产生，**`locked` 参与**：`rst_async = (~locked_raw) | rst_ext`，`rtl/clk_gen_p6b.v:228`）。⇒ MMCM **失锁/重锁**时 DP 功能逻辑重启，而 FIFO 的**指针与内容保留**：DP 侧会在帧中重启。`vlan_strip` 以 `tuser` 认帧首（`rtl/vlan_strip.v:94-96,191`）⇒ 表现应为"丢一帧"而非脏数据，**但本审计未做链上实测**（诚实标注，见 §6）。 | 代码：`wrapper_p4.v:431,434,2206,2208`（四处 `rst_n`）+ `rtl/clk_gen_p6b.v:224-237` |
| ~~F-4~~ | ⚪ 记录 | `fifo_async` 的占用探针 `dbg_occ_w` 是**上界**（写域看同步过来的读指针），`dbg_occ_r` 是下界 —— 与审查 F13 一致；两个方向都"只多报占用"，「占用没贴 256」不能证明"从没贴过"。 | `rtl/fifo_async.v:117-123,255-256` |

### F-1 的可达性（决定严重度；**当前 wrapper 下不可达，但只靠上游时序侥幸**）

- **RX（`u_rxcdc`）**：写侧是 `mac_rx_64`，它的复位 = 原始 `reset_n`（`wrapper_p4.v:393`，**无同步释放**），
  而 FIFO 写域要等本域两级同步器释放。要"丢"必须在该窗口内有 `push`：
  `mac_rx_64` 复位后状态机在 `S_IDLE`，需先数**≥6 个 `55` + `D5`**（`mac_rx_64.v:210-227`）再进 `S_DATA`，
  且第一个整字要 `fbytes ≥ 4` + `bcnt == 7`（`:289-311`）⇒ 最早的第 1 次 `push` 在复位释放后 **≥19 个 gmii 拍**，
  远大于窗口（实测窗口量级 = 个位数 wr_clk）。⇒ **当前不可达**。
- **TX（`u_txcdc`）**：写侧 = `dp_clk`（MMCM），写域释放要等 `dp_clk` 起振后再同步 2 拍；
  而数据面功能逻辑由 `dp_rst_dp` 复位，其释放 = `rst_async` 撤销后**再数 4 个 clk_dp**
  （`clk_gen_p6b.v:224-237`），且 `rst_async` 含 `~locked` ⇒ **功能逻辑的释放恒不早于** FIFO 写域的释放。
  ⇒ **当前不可达**。
- ⇒ 结论：F-1 目前**不是活缺陷**，但它把"不丢字"押在"生产者的首个 push 比 FIFO 写域释放晚"这个**隐含时序假设**上；
  一旦有人把生产者改成"复位后立刻可推"（例如换成组合 valid 的源）、或把 `reset_n` 的释放提前，
  就会**静默丢第一个字**，且因为 `fifo_async` 没有 ovf 探针，**板级无法归因**。建议二选一：
  ① `fifo_async` 补一个 `ovf_pulse`/`acc_pulse` 类自检探针（对齐 `fifo_sync` 的 F4 修复）；
  ② 把两个 CDC FIFO 的 `wr_rst_n` 与**对应生产者的复位**绑成同一网络（而不是各自接 `reset_n`）。

---

## 3. A 组（RX 跨域边界）

| 问 | 结论 | 依据（原始读数） |
|---|---|---|
| **A1** 谁把字从内部 8 深 FIFO 搬到 `u_rxcdc`？ | **安全（无中间模块）** | `wrapper_p4.v:391-417` + `:430-441` 的 AXIS 直连；`mac_rx_64.v:359` `rd = tvalid && tready` |
| **A2** 是否"先 pop 再看 full"？ | **安全** | `rxsrc_tready = ~rx_fifo_full` 与 `wr_en = m_tvalid` 使 `pop ⟺ CDC 接受写` 为**同一组合条件**（同拍）。t2 逐拍核对 **DUT 自己的两根探针**（`u_mac.u_fifo.dbg_rptr` vs `u_rxcdc.dbg_wbin`）：`atomic_ok=1805 / atomic_bad=0`，在 `refw=3064`（被拒写）与 `fullcyc=3379`（full 高电平拍）的重压下**零违例**。 |
| **A3** `u_rxcdc.full` 是不是"已含下一拍"的保守预测？ | **安全，但语义要写准** | 读实现：`full_r(T) ⟺ wbin_r(T) == rgray_s2_w(T-1)+DEPTH`（`fifo_async.v:164-187`）。**它不是"下一拍"预测，而是"本拍写入是否落笔"的精确闸门** —— 因为 CDC 的 `wr_en` 是**组合**的（与 mac_rx_64 内部那个**寄存器化** `push` 完全不同），同一拍判、同一拍落笔。保守性方向正确：`rgray_s2_w` 滞后真读指针 ⇒ full 只会**提前**拉高（最多白费 `DEPTH-1` 个空位），绝不会"真满却报不满"；归纳不变式 `wbin ≤ rptr_s2 + DEPTH` ⇒ 真实占用恒 `≤ DEPTH`（不覆盖未读槽）。⚠️ **唯一例外 = F-1**（写域复位窗口内 `full` 读 0 而写被丢）。 |
| **A4** 帧尾/TLAST 字的"多字语义" | **安全（本设计不存在多字 push）** | `mac_rx_64` 每拍最多 `push` 1 个字（TERM 块 `:199-208` 与各 case 分支互斥）。整链重压实测（t2，48 帧、最长 1514B、消费者长停 3350 拍）：`frames_in=48 → mac_frames=35 + drop=13`、`dfull=13`、`dpart=13`、`term=13`（TERM 数 == stat_drop_partial）、`orph=5656`、`ovf=0`、`bad=0`、`stale/半帧 = 0` ⇒ **要么整帧完整交付（含 TLAST，逐字节对拍），要么整帧丢弃并补一个 0 字节 TERM 字**；帧尾字从未"决策通过而下笔被挡"。 |
| **A5** FWFT 的 DP 侧 pop | **安全** | `rd_en = rx_tvalid && rx_tready`，`rx_tvalid = ~empty`（`wrapper_p4.v:434,441`）⇒ **empty 时结构上不可能 pop**；FWFT 下 `dout=mem[rbin]` 只在 `!empty` 时被消费（`vlan_strip.v:90,105` 的 `acc = tvalid && tready`）。t2 的逐字节对拍（35 帧全等）是"没读到空洞/陈旧字"的正面证据。 |

---

## 4. B 组（TX 跨域边界）

| 问 | 结论 | 依据 |
|---|---|---|
| **B6** 谁写 `u_txcdc`？写侧查 `full` 吗？ | **安全** | `u_tx_arb` 的**纯组合**输出直连（`tx_arb.v:29-36`），`txsrc_tready = ~tx_fifo_full`（`wrapper_p4.v:2213`），源只在自身 tready 高时才推进（`tx_arb.v:33-34,42-52`）⇒ 与 CDC 接受写同拍原子。实测 t3：`model_bad=0`（我的"接受写"模型逐拍 == DUT `dbg_wbin` 走位）、`pop_bad=0`、`dp_acc=cdc_wbin=mac_pop=148`。 |
| **B7** `mac_tx_64` 从 CDC 读：查 empty 吗？断供怎样？ | **安全（断供会 runt + F-2）** | `rd_en = m_tx_tvalid && m_tx_tready`，`m_tx_tvalid = ~tx_fifo_empty`（`:2208,2214`）；`mac_tx_64` 只在 `!fempty` 时 `frd`（`mac_tx_64.v:107-118,141-147`）。断供 ⇒ 内部 16 深 + CDC 排空后 `S_DATA` 中止（`mac_tx_64.v:148-152`），线上留一个**无 FCS 的 runt**（t3 实测 len=328、FCS-BAD）且 `stat_abort++`。receiver 按 FCS 丢弃 runt ✓，但**残字会在下一个 S_IDLE 变成新帧** ⇒ F-2。 |
| **B8** ⭐ F11：中止后残字会不会被当新帧发出去？ | **有缺陷（已确认，见 F-2）** | 判定实验（t3）：帧 A 发到第 40 字→断供 12000 拍→再发余下 80 字。线上实测：`frame#2 len=652 FCS-OK content = 帧A 的字节[320..960)`（= 断供后重发的**全部 80 字**），即**坏帧被包装成 FCS 正确的好帧发出**。判据不是"看起来"：① 该帧 FCS 残差 == 0xDEBB20E3（合法帧）；② 其 content 与**任何注入帧都不等**（只在 A 的尾段对上）；③ `mac_abort=1` 且线上帧数 = 4 > 注入帧数 3。 |

---

## 5. C 组（两侧共同）

| 问 | 结论 | 依据 |
|---|---|---|
| **C9** 位宽逐位验证（76 / 73）+ 变异 | **安全；且变异证明判据有区分力** | 每个宽度各打 walking-1/walking-0 全位 + 16 个字段组合，跨域往返：`SPAN76 W=76 NPAT=320 words=320 bad_raw=0 bad_map=0 acc=320 refw=2024 pop=320`、`SPAN73 NPAT=308 bad_raw=0 bad_map=0 acc=308 refw=1969`（`refw>0` ⇒ 真撞过 full 边界）。**判据 = 解包再打包的恒等**（同时验数据完整与字段映射）。变异：**MUT_W75**（端口少 1 位）⇒ `bad_raw=159`，典型行 `got=0 exp=8000000000000000000`（**MSB = tdata[63] = 帧首字节被静默清零**）；**MUT_SWAP**（读侧字段对调）⇒ `bad_raw=0 bad_map=304`。⚠️ **两个变异都必须 FAIL，实测都 FAIL；正例 PASS** ⇒ 判据不是空的。⚠️ 附带发现：**xvlog 对 W-1 的端口截断 0 警告**（`xvlog_mutw75.log` 只有 5 行 INFO，无 WARNING/3091）⇒ 这类错误**只能靠功能判据抓**。 |
| **C10** 守恒律（主判据） | **安全** | RX 链（t2）：`mac_words=1805 == dp_words=1805`、`dframes+stat_drop=35+13=48 == frames_in`、`term=13 == dpart=13`、`ovf=0`、CDC `wbin==rbin`（裸值 mod 512 一致，且逐拍 Δ 计数一致）。TX 链（t3）：`dp_acc=cdc_wbin=mac_pop=148`。复位/停钟（t4）：A 双复位后 `model_acc=19990 / dut_acc=19989 / get=19988`（差 1-2 = 在飞字），D 停钟恢复后 `get=40237 = dut_acc-1`。⚠️ 读**裸指针值**会被 mod-512 骗（本 TB 第一版就踩了：3982 与 398 同值）—— 守恒必须按**Δ 计数**，不能读指针终值。 |
| **C11** 复位（两侧独立） | **安全（按 wrapper 的接法）；单侧复位 = 脏数据（契约成立）；释放窗口 = F-1** | ① **两侧同源**（wrapper 就是 `wr_rst_n=rd_rst_n=reset_n`，`wrapper_p4.v:431,434,2206,2208`）：中途复位后 6 拍快照 `raw_wbin=0 raw_rbin=0 model_acc=0`（FIFO 已清空 ⇒ 复位前的字结构上不可能再被交付），随后 20000 拍 `stale=0`（交付流自洽、无回退）。② **只复位读侧**（禁止用法）：读指针归 0 去追写指针 ⇒ 实测 `STALE-EVENT t=37667000 got_seq=4407 exp=4663`（**回退 256 拍的旧字被重新交付** = 已被消费过的数据重现，脏数据），契约 §② 的可预测后果逐条兑现。③ **复位释放窗口**：见 F-1（3 字静默丢弃）。④ 两侧复位**不同代**（写侧先释放、读侧还在复位）是契约允许的：t4 的 A/C 实例都覆盖到，无脏数据。 |
| **C12** 时钟停摆 | **安全（不挂死、不丢、不乱；计数器不说谎）** | t4 实例 D：停 `rd_clk` 6000 个 wr_clk 周期 ⇒ 写侧被 `full` 挡住（`fullcyc=5746`、`wref=5746` 次重试，**不挂死**），恢复后 `stale=0`、`get=40237 = dut_acc-1`（逐字补齐、无丢无重）。另一侧停摆时的读数口径：**停摆侧的计数器冻结**（其时钟没了），工作侧的 `dbg_wbin`/`full` 仍真实 —— 我全程用"工作侧的 Δ 计数 + 停摆侧的 DUT 指针"对账，两侧都没有说谎。 |

---

## 6. 我做过的变异 / 负对照（判据有区分力的证明）

| 变异/负对照 | 期望 | 实测 | 说明 |
|---|---|---|---|
| t1 `MUT_W75`：FIFO 端口 = 逻辑宽 −1 | FAIL | **FAIL**（`bad_raw=159/320` 与 `153/308`） | 编译**零警告** ⇒ 只有功能判据能抓 |
| t1 `MUT_SWAP`：读侧字段顺序对调 | FAIL | **FAIL**（`bad_map=304`，`bad_raw=0`） | 数据通路完好、只有字段级判据能抓 |
| t2 `NEG_LATE_GATE`：`tready` 寄存器化（弹字与写 CDC 差一拍 = **F4(b) 在 CDC 上的等价形态**） | FAIL | **FAIL**：`atomic_bad=376`（例：`wbin 256→257 而 rptr 0→0` = 同一字被写两次；反向 = 丢字）、`dp_frames+drop=34+13≠48`、`BAD-SOP`（重复的 SOP 字） | 这正是"修复被挪到下游"的形态；判据逐拍抓到 |
| t2 `NEG_NO_BP`：`tready` 恒 1（忘接 full） | FAIL | **FAIL**：`mac_words=2787` vs `dp_words=1936`（851 字静默丢）、`atomic_bad=851`、`bad=4` | |
| t1 正例 / t2 正例 / t3 正例 | PASS | **PASS_ALL ×3** | 且三者的"证据非空"自检（`checks>0`、`refw>0`、`stat_drop>0`、`dframes>=4`）都通过 |

---

## 7. 我没能验证的（诚实清单）

1. **亚稳态/MTBF**：行为级仿真没有亚稳态模型 ⇒ 两级同步链的**电气**正确性只能靠综合后 CDC 报告/STA（本审计只跑到 xsim，未综合）。
   （同步链**结构**是否有 2 级、空标志是否比写入沿晚 ≥4 个 rd 沿，已由 `sim/fifoasync/` 的单元门按延迟契约覆盖，不在本审计范围。）
2. **F-3（DP 功能复位 vs FIFO 复位不同源）未做链上实测**：我只从代码读出 `rst_dp` 的置位源含 `locked`，并确认 `vlan_strip` 以 `tuser` 认帧首 ⇒ 推断后果是"丢一帧"而非脏数据。**没有**跑"MMCM 失锁 → 重锁"的整链实验。
3. **TX 侧的 `full` 边界没在链上撞满**：t3 的 `fullcyc=0`（一轮只有 148 字，256 深没灌满）⇒ "TX 方向 full 期间不丢写"只有**模型/指针逐拍一致**（`model_bad=0`）与单元门的覆盖，没有"TX 链上真撞满"的读数。RX 侧是撞满的（`refw=3064`）。
4. **未综合/未上板**：LUTRAM/BRAM 推断结果、`ASYNC_REG` 是否被保留、CDC 时序报告，全部未测。
5. **未验证 `dbg_occ_w` 探针的数值口径**（W27/W28 是板上判据）：本审计只核了它的**方向性**（上界），没核它在满/边界时的具体读数。
6. **未覆盖 FWFT=0 与其它深度**：本审计只锁 wrapper 实际使用的 `FWFT=1 / DEPTH=256 / AW=8` 两个实例（那是**唯一上板**的配置）。
7. `mac_tx_64` 的 4 字节 FCS 前瞻、pad 长度的逐条边界只做了 3 个长度（24/200/960B）的正面验证，未穷举 60..1514 的边界（那块由既有 `tb_mac_tx_64` 覆盖）。

---

## 8. 证据文件索引（全部在 `audit_scratch/`，可复跑）

| 门 | 源码 | 运行 | 原始日志 |
|---|---|---|---|
| C9 位级/字段跨域（+2 变异） | `audit_scratch/t1_bits/tb_cdc_bits.v` | `cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\audit_scratch\run_t1.bat' pos\|mutw75\|mutswap` | `t1_bits/case_*/xsim_*.log` |
| A1-A5/C10 RX 整链（+2 负对照） | `audit_scratch/t2_rxcdc/tb_rx_cdc_chain.v` | `... run_t2.bat pos\|neg_late\|neg_nobp` | `t2_rxcdc/case_*/xsim_*.log` |
| B6-B8 TX 整链 + F11 判定 | `audit_scratch/t3_txcdc/tb_tx_cdc_chain.v` | `... run_t3.bat pos` | `t3_txcdc/case_pos/xsim_pos.log` |
| C11/C12 复位与停钟 | `audit_scratch/t4_reset/tb_cdc_reset.v` | `... run_t4.bat` | `t4_reset/case/xsim.log` |

（`audit_scratch/` 里另有我自己的 TB 踩坑留痕：复位释放窗口、NBA 下标竞争、`buf` 是 Verilog 关键字、
`xvlog.log` 命名冲突、指针 mod-512 假象 —— 这些都在 TB 注释里写明，便于后人复跑时不再踩。）

---

# 附录 A（2026-09-29 11:3x）：F-2 修复 + F-3 实测（协调者授权后的施工记录）

## A.1 F-2 已修：`rtl/mac_tx_64.v`（**本次唯一改动的 RTL 文件**）

**修前** `mac_tx_64.v md5=50d606947d28207f6776694316cd5374`（原样留档在
`audit_scratch/rtl_orig/mac_tx_64.v`，用于 A/B 与回归对照）；**修后 `md5=7e385623cfcb83ccd38be6348fc5dfce`**。

**修复形态**：新增状态 `S_FLUSH`（唯一入口 = `S_DATA` 的 `!fempty` 中止分支）+ 两个计数器输出
`stat_flush_words`（冲刷期被丢弃的输入字数）/ `stat_flush_done`（冲刷完成次数 = 重对齐到帧边界的次数）。
中止后**一个字都不发**（`gmii_tx_en` 在 `S_FLUSH` 恒 0），把输入 FIFO 的头字逐个弹掉并计数，直到吞掉
**本帧自己的 TLAST 字**（TX 字流不带 tuser ⇒ 唯一可用的帧边界），再等够 IFG 12 字节才回 `S_IDLE`。
**时序要点（第一版在此差一拍，实测吃掉下一帧首字）**：`frd` 是寄存的弹出请求，本拍 `frd=1` 弹出的正是
**本拍头字** ⇒ 判据必须是 `frd && !fempty && fdout[0]`（本拍真弹且弹的就是 TLAST），并同拍停止再请求；
用"上一拍看到的 tlast"会多弹一个字（实测：幽灵帧变成"帧C 的 [1..24] 字"）。

**覆盖性论证**：① 中止点全模块唯一（`S_DATA` 的 `!fempty` 分支）⇒ 进 `S_FLUSH` 的唯一入口；
② 上游帧契约（`tx_arb.busy` 锁到 tlast 被消费；DP 各源都是帧器）⇒ 被中止帧的 TLAST 必然在路上 ⇒ 冲刷必终止；
③ 唯一"TLAST 永不到来"的情形 = DP 被复位/弃帧 ⇒ 冲刷会连下一帧整帧一起吃掉（代价 = 丢 1 帧，
**有界、自愈、有计数**，仍绝不发坏帧）；④ 不触发中止 ⇒ `S_FLUSH` 不可达 ⇒ 数据通路逐位不变（见 A.2 的指纹）。

## A.2 F-2 的判据读数（同一 TB `audit_scratch/t3_txcdc/`，同一激励，只换 RTL）

| 运行 | 线上帧 | ghost | flush_words / flush_done | 线上指纹 `wf` |
|---|---|---|---|---|
| **修后** `run_t3.bat pos` | B(完整✓) / 中止帧 runt 328B FCS-BAD / **帧C 212B 完整✓** | **0** | 80 / 1 | `13389747` |
| **修前**（撤回修复 = `rtl_orig` 副本）`orig` | … / **幽灵帧 652B FCS-OK, content = 帧A 字节[320..960)** / … | **1 → 判据 FAIL** | (无此端口，哨兵 `DEADBEEF`) | `0b4540e9` |
| 无中止 `nostall_new` | B / A(972B) / C 全完整✓ | 0 | **0 / 0** | **`33f82978`** |
| 无中止 `nostall_orig` | 同上 | 0 | — | **`33f82978`（逐位相同）** |

⇒ ① 幽灵帧 0 ✓；② 撤回修复 ⇒ FAIL（`TXCHAIN FAIL: F-2 幽灵帧 = 1`）✓ 判据有牙；
③ **无中止路径逐位不变**（同指纹 + 新 RTL 的 flush 计数器为 0 = 冲刷从未运行的正证据，非"读不到"）✓。

**工程既有单元门回归**（`tools/run_mac_tx_tb.py` 的等价重跑，见 `audit_scratch/regress_mactx.py`，
逐拍比对 gmii 流 + stats）：`main` 模式 **修前/修后都 PASS**（254 拍全等，独立 Python 模型）；
`abort` 模式：修前 PASS、修后 **FAIL @10002**（= 残字到达的那一拍）——因为
`tools/gen_stim_tx.py:6,161` 的参考模型**把缺陷写进了期望**（"残余 2 词开新帧"）⇒
**该参考需要同步更新**（改法与 `S_FLUSH` 同形），否则 `abort` 门会一直"红"。
`tools/` 不在本次授权范围内 ⇒ 未改，此处如实上报。

**链级回归**：`sim/p4sim/run_tb_p4_chain.bat` ⇒ **P4 CHAIN OK**；`run_tb_p4_chain_stall.bat` ⇒ **PCSTALL OK**（均用私有 `P4_WORKDIR`）。

## A.3 F-3 实测（协调者要求"不再是推断"）：**改接线不足以解决；且字面建议有害**

TB：`audit_scratch/t9_f3restart/tb_f3_restart.v`（GMII 帧源 → mac_rx_64 → u_rxcdc 76/256 →
**真 vlan_strip** → DP 水槽；重启模型 = 停 DP 钟 + 断言 `dp_rst_dp`，1500 gclk 后恢复钟、4 个 DP 沿释放，
与 `clk_gen_p6b.v:224-237` 同形）。帧内容 = `(f*67 + k*29)&0xFF` ⇒ 任 (帧,偏移) 组合可唯一反解。
`W_snap` = 重启瞬间 DUT 已接受的字数；判据 `stale_words = dw_all − (dut_acc_final − W_snap)`
（重启后 DP 消费的字数 − 重启后新推入的字数；>0 ⇒ **交付了重启前的字**）。

| 变体 | 重启后首个交付帧 | `stale_words` | 带 crs=1 的截断帧 | 契约 |
|---|---|---|---|---|
| **A 现行**（两侧都只接 `reset_n`） | 40B **片段**（帧3 偏移24） | 0（DP 跟得上 ⇒ 重启瞬间 FIFO 近空） | **1** | 合规 |
| **B 只复位读侧**（= 字面建议） | 帧0 完整 ⇒ **帧0/1/2 被重复投递** | **26** | 0（但 3 个已消费帧重放） | **违反硬契约** |
| **C 两侧同源同拍复位**（FIFO 清空） | 48B **片段**（帧3 偏移16） | 0 | **1** | 合规（契约允许"同拍断言"） |

⇒ **结论**：① 三种接线**都会**让 DP 在重启后交付一个**帧中截断的片段，且携带原帧 `tcrs=1`**
（= 截断帧被当 FCS 有效帧交付）—— **F-3 的危害在接线层面无解**，根因是 **DP 侧没有以 SOP 为界的重启重同步**
（FIFO 无法提供帧对齐信息）；② **字面建议（只把读侧接 `dp_rst_n`，`:434`）必须不做**：它破坏
`fifo_async` 的复位硬契约（指针不同代），实测把**已被消费的整帧重新投递**（`stale_words=26`）。
③ 变体 C 额外观测到 FE 侧 8 帧丢弃 + DP 只消费 9 字 —— 未完全定因（疑为"两侧复位窗口内 FE 的 push
被静默丢弃而生产者以为成功"= F-1 同类），**故 C 也不是无条件更好**。
⇒ 本次**未改 `board/wrapper_p4.v`**（保持 `03e76507605f88acf2847dc5101eca14` 不变）。
真正的收口方向（均超出本次授权，建议单列）：
(i) 让 DP 侧重启后**等 tuser 才开帧**（`vlan_strip`/`rx_classify` 加入口门控）；
(ii) 把 `mac_rx_64` 也纳入"同源同拍复位"（其复位后必然从新前导/新帧首字开始 ⇒ 首个 push 就是 SOP 字）。

## A.4 版本提示（审计时效）

本次审计/修复基于 `rtl/fifo_async.v md5=1c21c0244b49b6ed5310b9346fe7cc25`；**工作期间另一 agent 已改动该文件**
（现 `11e8d82a034516d06e2299e9e7ead644`）⇒ 本文档中引用的 `fifo_async.v` 行号需按新版本复核；
t3/t9 的最新读数是在**新版本**上跑出来的（行为与旧版一致）。

---

# 附录 B（2026-09-29 11:4x）：`tools/gen_stim_tx.py` 参考模型修正（把缺陷当金标准的镜像）

## B.1 改动
`tools/gen_stim_tx.py`：修前 `md5=37af591692307d63d44b8be6db0dd90f`（留档 `audit_scratch/tools_orig/`）
→ 修后 `md5=b4ee17da968d5c5c3d038b20a901666f`。仅改 **abort 模式**的期望模型（+ 文件头注释）：
① 中止后进 `FLUSH`（不再 `IDLE`）；② 冲刷期 `en/txd = 0/0x07`，逐拍弹掉 FIFO 头字直到吞掉本帧 TLAST；
③ 吞到 TLAST 后再等 `flush_cnt` 数到 12（IFG）才回 `IDLE`；④ 此后没有任何帧（残字永不成为新帧内容）。
**`main` 模式逐字节不变**：`MAIN 期望模型 改前/改后 逐字节相同 = True`（模型级"无扰动"证据）。

## B.2 判据现在有牙（同一参考、只换 RTL）
| 运行 | 读数 |
|---|---|
| **正例**（修后 `rtl/mac_tx_64.v 7e385623…`） | `[new/abort] PASS: 10005 拍比对一致, stats (0, 1)` |
| **负对照**（副本 `audit_scratch/rtl_orig/mac_tx_64.v` = **撤回 S_FLUSH**） | `[orig/abort] FAIL @10002: resp (1, '55') exp (0, '07')` —— resp 在期望空闲处**起了新帧前导**（幽灵帧的形态）|
| `main`（两侧 RTL） | 都 `PASS: 254 拍比对一致, stats (3, 0)` |
`abort` 期望 trace：改前 10088 拍 / 改后 10007 拍，首个分歧 @10004（改前 `1 55` = 幽灵帧前导，改后 `0 07` = 空闲），改后尾部全 idle ✓。

## B.3 全模式扫描（有没有第二处把缺陷当期望）
- `gen_stim_tx.py`：只有 abort 这一处；`main` 的 IDLE/PRE/DATA/PAD/FCS/IFG 全部与 RTL 逐拍吻合（改前后都 PASS = 已验证）；
  `words_of`（keep/last 语义）由两个模式的帧长/RCS 读数佐证 ✓。
- ⚠️ 一处**脆弱但当前正确**的代理：`generate()` 用 `len(frame) >= 58` 判"完整帧/中止帧"来生成 stats。
  对现有两个模式取值与 RTL 一致（stats `(3,0)` / `(0,1)` 实测吻合 ✓），但它是**长度代理**而非显式标签 ——
  若将来加入"合法短帧/长 runt"的用例会静默错分类。**未改**（避免动 API），**记录待办**。
- 其它 `tools/*.py`：`gen_stim_p4_chain.py` 是**反向**的（把 `mac abort == 0` 当哨兵断言 ⇒ 不可能把缺陷当期望）；
  `gen_stim_tcp_echo.py` 无 mac_tx 中止建模（帧间 1500B 大间隔 ⇒ 不触发欠载）；
  `gen_stim_p4_slowrx.py` 建模的是**慢路径 RX** 的 rollback 契约（不同模块、非本次范围）。⇒ **没有第二处**。
- ⚠️ **同类的另一个地雷（不是"把缺陷当期望"，而是"测错仓库"）**：`tools/run_mac_tx_tb.py` 调用的
  `sim/run_tb_tx.bat` 里仍写着 `cd /d D:\repo\ECO\udp_hls_10g\sim` ⇒ 直接跑它会在**另一个 checkout**
  上编译+仿真并给出 PASS/FAIL。本目录的 `audit_scratch/regress_mactx.py` 用自定位路径重写了这一步
  （`sim/run_tb_tx.bat` 属 `sim/`，不在本次授权内 ⇒ **未改，报备**；建议按 `sim/p4gates/p4env.bat` 的
  自定位风格修那一行）。

## B.4 回归（跑门时刻的 md5 已记：`fifo_async 11e8d82a…` / `mac_tx_64 7e385623…` / `gen_stim_tx b4ee17da…`）
`P4 CHAIN OK`（9 RX 帧 / 11 TX 帧，fast=6 slow=5）· `PCSTALL OK`（210 RX 帧，停摆后 127 帧，echo 240）
· mac_tx 单元门 `main` 修前/修后都 PASS · `abort` 由"把缺陷当期望的假红"变为**真绿**，且撤回修复即真红。

## B.5 两个顺带问题（就现有证据 + 静态判读）
- **变体 A/C 的"帧中截断但 `tcrs=1`"片段会被下游当合法帧收下吗？**
  **不会进 fast 路，但 FCS 保护在 MAC 边界确实被击穿。** 静态判读：`rx_classify` 完全不用 `tuser`
  （`:123-128` 只把它存进 skid），ethertype 取**它自己对齐**的 `sk_d[1][31:16]`；片段起点是帧中，
  该字段是垃圾 ⇒ `is_tcp=0` ⇒ `n==2` 拍定案 `route <= RT_SLOW`（`:133-141`）⇒ **一律走慢路径**；
  短片段（40/48B = 5/6 字）还会在 tlast 分支提前判 slow（`:129-132`）。
  慢路径 `slow_rx_adp` 头注释自述"补前导但**不重生成 FCS**"⇒ 它（以及任何信 `tcrs` 的消费者）
  看到的是"`tcrs=1` 的未知协议短帧"，靠 IP `total_len`/ARP 定长自然忽略 —— 即**靠解析器兜底，
  不是靠 FCS 校验**。⇒ 危害有界（大概率被丢），但"坏帧带 tcrs=1"这条完整性属性已被破坏。
- **变体 C 的"FE 丢 8 帧 + DP 只消费 9 字"在 F-1 修复之后还成立吗？**
  **成立，但机制不是 F-1。** F-1 修复后重跑：`mac_frames=4 mac_drop=8`、DP 只消费 9 字（读数复现）。
  机制（静态+读数吻合）：两侧复位窗口内 FIFO 写侧 `full_r=1`（F-1 后）⇒ `m_tready=0` ⇒ FE 的
  8 深内部 FIFO 立刻填满 ⇒ `mac_rx` 按既有语义**整帧丢并计数**（`stat_drop=8` ✓ 非静默）⇒ 释放后
  只能从内部 FIFO 的残存 8 字续上 ⇒ DP 恰好看 9 字 ✓。⇒ 这是**设计内的背压丢帧路径**（有计数、
  可归因），不是 F-1 同类的新漏洞；`silent_drop=4294967295` 是 TB 两个计数器同块采样的 ±1 相位假象
  （`fe_acc` 与 wbin 增量差一拍），守恒判据本身不受影响（`stale_words=0`）。
