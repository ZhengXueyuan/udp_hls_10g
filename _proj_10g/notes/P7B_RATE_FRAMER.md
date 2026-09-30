# P7B 组帧器收发重叠（乒乓双 bank）—— 改法 / 六项验证 / 拍数与 Gbps 前后对照

- 日期：**2026-09-30**（10G 线速第二刀，承接 `P7B_RATE_BOTTLENECK.md` §5.2）
- 性质：**只读 rtl/ 除一个文件外 + xsim 门**。未烧板、**未跑综合/实现**、未改 license、未 `git add/commit`。
- 文件所有权：只改 `rtl/udp_tx_frame.v`（343 行 insertion / **0 deletion**，且**全部在 `` `ifdef UDP_TX_OVL `` 内**）
  + 自建 `_proj_10g/notes/p7b_ratefrm/**`。**未碰 `rtl/app_udp_pattern.v`（另一路 agent 的 8 路并行）**；
  **`rtl/udp_tx_cfg.v` 未改**（见 §4：不需要改，理由在那一节）。
- 结论一句话：**帧周期 378 → 191 拍（帧器自身）/ 379 → 193 拍（帧器+arb+MAC 全链）**，
  载荷 **4.87 → 9.63 Gbps**（单级）/ **4.85 → 9.53 Gbps**（全链 = 802.3 载荷上限 9.571 的 **99.6%**）；
  线上帧流**逐字节不变**；`o_busy` **只在"帧首拍 → 上一实现窗口起点"之间变长**（超集），消费方只有 `udp_tx_cfg`，一处代价（改 peer 时多冻结几拍）已量化。

---

## 1. 改法（逐处）

`rtl/udp_tx_frame.v` 结构 = 端口表与 `parameter PLEN_MAX` 保留在 `ifdef` 外，body 一分为二：
`` `ifdef UDP_TX_OVL ``（新增，:67–:406）/ `` `else ``（**逐字保留 HEAD 的 334 行**，:408–:675）/ `` `endif ``。
`git diff --stat` = **343 insertions(+), 0 deletions** ⇒ **默认构建的源码一个字符都没动**（不只是"应该没变"）。
本报告全部读数对应 `rtl/udp_tx_frame.v` = **sha256 `ab96d7af1f196be2becc6a33f600020b50dd4c48d09b45285b9b8367520cf57c`**（34385 B，mtime 16:46:03，此后未再改动）。

| # | 位置 | 改动 | 为什么是最小 |
|---|---|---|---|
| 1 | `:87` | 旧单 FSM（S_RECV/S_WAIT/S_HDR/S_PAY/S_TAIL/S_DONE）拆成 **RX 引擎**（`RX_IDLE`/`RX_FIN`/`RX_FLUSH`）+ **TX 引擎**（`T_IDLE`/`T_HDR`/`T_PAY`/`T_TAIL`/`T_DONE`），同一个 always 块里两个 case | 状态语义**一一映射**旧状态：RX_IDLE≡S_RECV（含 `recv_first`）、RX_FIN≡S_WAIT、RX_FLUSH≡flush_pend 期间的 S_RECV、T_*≡S_HDR/S_PAY/S_TAIL/S_DONE |
| 2 | `:161,:167` | 载荷 FIFO 由 1 个 256×73 变 **2 个同参数 bank**（`u_fifo_a`/`u_fifo_b`），写口恒指 `rx_bank`、读口按 `tx_bank`（发）/`rx_bank`（冲洗）分流 | 不改 `fifo_sync.v`（**非本 agent 文件**）；写/读口天然分离，两个 bank 的读写指针互不干扰 |
| 3 | `:201` | `s_axis_tready` 增加 **`&& !bank_rdy[rx_bank]`** | 这是乒乓的**结构性约束**：上一轮用过该 bank 的帧必须已经发完才能覆写。默认实现里这一条由"发完才回 S_RECV"隐含保证，这里必须显式 |
| 4 | `:204–:207` | 读口拆 `rd_tx`（T_PAY）/ `rd_fl`（RX_FLUSH），按 bank 或起来 | 两 bank 恒不同（同一帧不可能既在发又在冲），故 `rd_a`/`rd_b` 不会同拍双读 |
| 5 | `:216` | **checksum16 仍只有 1 个实例**，但 `aen/fin/latch` 从旧 `S_WAIT` **搬进 RX 引擎**（`RX_FIN` 3 拍，与 `wait_cnt 0/1/2` 逐拍同构） | 这是 191 的来源：TX 侧不再占这 3 拍。校验和的 `init/den` 与收尾在**同一引擎内串行** ⇒ 不需要第二个累加器（省一份 checksum16） |
| 6 | `:100–:113` | 每 bank 的帧上下文（`plen_r/udp_len_r/total_len_r/ip_csum_r/udp_csum_r/id_cap` + `bank_rdy`）各一份 | 原来的"单份帧上下文"正是因为串行才够用；重叠后两帧同时活着，必须按 bank 分开 |
| 7 | `:213` | `o_busy` 重定义为"有帧在飞"：`(rx_state != RX_IDLE) \|\| !recv_first \|\| (tx_state != T_IDLE) \|\| (bank_rdy != 0)` | 见 §4 |
| 8 | `:303–:406` | TX 引擎的**头 5 字 / 载荷 2 字节偏移 / 尾字优先级 / 欠载防御 / 统计口径逐字照抄**旧 S_HDR/S_PAY/S_TAIL/S_DONE（只把 `plen_r`→`plen_r[tx_bank]`、`fdout`→`fdout_tx`） | 帧内容一字不改是在源码层面保证的，不是"对齐过" |
| 9 | `:391` | `T_DONE` 消费末字后**直接进 `T_HDR`**（若下一 bank 已就绪），不再经过一个空闲拍 | 省 1 拍；不影响语义（`thcnt` 在同拍清零） |

---

## 2. 六项验证（全部真跑，日志/原件在本目录）

一键复跑：`run_eq.bat`（验证 1/2/4）· `run_rate.bat`（验证 3）· `run_mut.bat`（验证 6）

### ① 逐字节等价 ✅ `run_eq.bat def|ovl`
同一拍流（53 帧：0/32/63/65/100/1471/1472/1500/1501(中止)/4096(中止)/17×1472 背靠背/8×64 背靠背/慢消费者 8×1472+2×800），
线上帧流逐字节落盘 `run_{def,ovl}/eq_frames.txt` ⇒ **`fc /b` = FRAMES-IDENTICAL**（51 帧 × 42..1542 字节全等）。
两版读数逐项相同：`WIRE frames=51 stat_frames=51 stat_bytes=44271 drop_len=2`，且每帧的
**dst_mac(随 peer)/src_mac/ethertype/IP total_len/IP 头校验和/src-dst ip/端口/UDP len/UDP 校验和(伪头+头+载荷)/载荷逐字节**全部通过（含 63/65/1471 这种非 8 倍数尾字）。

### ② `o_busy` 前后对照（单列）
逐拍轨迹 `eq_busy.txt` + 事件表 `eq_events.txt`（A=帧首拍被接受/O=末字被消费/D=帧首被阻塞），分析器 `an_busy.py`：

| 判据 | 默认构建 | 重叠构建 |
|---|---|---|
| **C5-old**：`[帧末拍接受+1, 末字消费]` 内 busy 恒 1（**两版都必须成立**） | **0 违反** | **0 违反** |
| C5-new：`[帧首拍接受+1, 末字消费]` 内 busy 恒 1 | **5488 违反**（结构性：默认实现在收帧期间 busy=0） | **0 违反** |
| busy 窗口数（上升沿）/ 51 帧 | **51 个**（每帧一个） | **12 个**（相邻帧的窗口合并） |
| busy 占比（同一激励） | 38.0% | 64.9% |
| 总拍数 | 18503 | **13722**（−25.8%） |

**结论（o_busy 变了吗？变了，只有一处，且方向单一）**：
- 默认窗口 = `[帧末(tlast)接受拍+1, 本帧末字被消费]`；重叠窗口 = `[帧首拍接受拍+1, 本帧末字被消费]`。
  ⇒ **逐帧是默认窗口的超集（帧首那一拍两版都允许 busy=0）**，C5-old 在两版都 0 违反就是这条的实测证据；
  **"变短"在任何激励下都不可能**（只可能变长）。
- **为什么必须变长**：重叠后"帧 N 的头字采样"发生在"帧 N+1 正在被收"的期间，而帧 N+1 的 `init_val` 采样又发生在帧 N 的窗口里
  ⇒ 两帧的**采样窗口在时间上相接**，任何"按帧收窄"的定义都会让某一帧的头部与校验和取自两个 cfg。
- **下游谁消费**：全仓唯一消费方 = `rtl/udp_tx_cfg.v:120` 的 `idle = first_r && !frame_busy`（`grep` 确认无第二处）。
  它用 `frame_busy` 决定"什么时候可以把 peer 表刷进 `o_*` 锁存器"。
- **代价（已量化，同一 TB 同一位置换 peer）**：换 peer 后到下一帧被放行的门阻塞拍数
  **默认 1 拍 → 重叠 16 拍**（整轮 `deny` 拍数 8 → 23）。**不是死锁**：被拒帧停在 `udp_tx_cfg` 门外（`stat_deny` 计数，
  证明见下），帧器把在飞的 1~2 帧排空后 `o_busy` 归零 → 刷新 → 原帧照发（TB 判据"帧 31-33 用 peer A、帧 34+ 用 peer B、
  每帧双校验和都对"两版都通过）。⇒ **`udp_tx_cfg.v` 无需改动**（这正是 §1 里"未改它"的理由）。
- 逐帧字段检查里没有任何一帧出现"头=新 peer / csum=旧 peer"，即**帧内 cfg 一致性未被削弱**。

### ③ 每帧拍数实测（用 `_proj_10g/notes/p7b_rate/` 的门复跑）✅
`tb_rate_frame.v` = `p7b_rate/tb_lvl_frame.v` 的**逐字拷贝**（md5 `064d7500…` 与原件相同）；时钟 6.4 ns：

| 被测 | 默认 | **重叠** | 换算 |
|---|---|---|---|
| `udp_tx_frame` 单独（无限就绪上游） | **378 拍** / 4867.7 Mbps | **191 拍** / **9633.5 Mbps** | 1.98× |
| 全链 `udp_tx_frame→tx_arb→mac_tx_10g`（自建 `tb_rate_chain.v`，真 RTL） | **379 拍** / 4854.9 Mbps | **193 拍** / **9533.7 Mbps** | 1.96× |

- 193 拍 ≈ `mac_tx_10g` 自身天花板 **193.24 拍**（`P7B_RATE_BOTTLENECK.md` §1 第 6 级）
  ⇒ **接棒的瓶颈确实换成了 MAC**（预测被实测证实），全链载荷 = 802.3 口径上限 9.571 Gbps 的 **99.6%**。
- 分解：191 = 头 5 + 载荷 184 + 尾 1 + `T_DONE` 1；RX 侧 184+3 = **187 < 191** ⇒ **TX 是单级瓶颈**（与设计意图一致）。

### ④ 既有门（含**两条既存红**，如实报）
| 门 | 结果 |
|---|---|
| `sim/p5e_t2/run_tb_udp_tx_guard.bat`（默认构建） | **OK**（`frames=6 drop_len=2 deny=2 neg_fifo_occ=256`，内置负对照全过） |
| `sim/p5e_udp/run_tb_app_udp.bat pos` | **OK**（`rx_frames=10 tx_frames=25 drop_len=1 pat_bad=0`） |
| ↳ 同门 `nopeer` / `neglearn` | exit 0 / **exit 1（期望红）** ⇒ 门的判别力仍在 |
| ↳ **同门加到重叠构建上**（`run_app_gate_head_ovl.bat pos`：`-d UDP_TX_OVL` + HEAD 版 app） | **OK，且 7 个计数器逐字相同**（`10/13305/25/1/5/15/0`）⇒ 新帧器在**真 app 图案激励**下与默认实现行为一致 |
| `sim/p5e_udp/run_tb_p5e_udp_wrapper.bat`（真 wrapper 全链） | **FAIL errs=1489 —— 既存红，与本次改动无关**：① `P7B_REGRESSION.md:210` 已登记为"既存"且 errs 数逐字相同；② 我用 **HEAD 版 `udp_tx_frame.v` + HEAD 版 `app_udp_pattern.v`** 复跑（`run_wrap_gate_pristine.bat`）得到**同一个 1489**；③ 与重叠构建的 **1490 条 FAIL 明细逐行 diff 为空**（失败内容是 TCP/app_pattern 侧的 SEED 与 GMII 检查） |
| `sim/p5e_t2/run_tb_p5e_t2_wrapper.bat`（真 wrapper 全链） | **FAIL errs=117 —— 同为既存红**（`P7B_REGRESSION.md:203`）；默认/重叠两版 **errs 数逐字相同** |
| `_proj_10g/p7b_chain` 真 wrapper 10G 全链门 ⭐ | 默认 **VERDICT = PASS**；**加 `-d UDP_TX_OVL` 也 PASS，107 条判据行逐行相同**（工程坑 8：ifdef 分支接线错只有这条能抓） |

> ⚠️ **两条历史 wrapper 门（`p5e_udp`/`p5e_t2`）在基线 revision 上就是红的**（`P7B_REGRESSION.md` §4「既存失败 21 门」，
> errs 数 1489/117 与本次实测逐字相同）⇒ **"既有门全过"对本改动不成立的不是我的改动**；
> 本轮对重叠构建真正的"真 wrapper 接线"证据是 **`p7b_chain` 门（P7B_10G + APP_MODE + DP_156MHZ + PCIE_OBS 全宏）**，
> 它把 `udp_tx_frame` 装在真 `wrapper_p4` 里跑，两版 107 条判据逐行相同且都 PASS。

### ⑤ 默认构建回归 `sim\p4gates\run_matrix_p4dfix.bat` ✅
`cmd //c 'sim\p4gates\run_matrix_p4dfix.bat'`（16 门全跑，17:08→17:21）：
```
gates run   : 16 / 16
gates failed: 0
VERDICT: FROZEN -- all 237 hashed files byte-identical across the run
GIT_HEAD    = aa60ab9
```
日志 `logs/matrix_p4dfix_ovlrun.txt`（+ 矩阵自身的 `sim/p4sim/matrix_p4dfix.log`，`EXIT=0`）。
⇒ 默认构建（宏未定义）**16/16 全过**，且跑动期间源码指纹冻结（无修订漂移）。

### ⑥ 反例门（判别力）✅ `run_mut.bat`
变异体 `mut_single_bank/udp_tx_frame.v`：由 `mk_mut.py` 从当前 RTL **只改 1 处**（RX 接受门再加
`&& (tx_state == T_IDLE) && (bank_rdy == 2'b00)` = 乒乓退化成"收完才发"）⇒ 拍/帧 **191 → 379**（帧器）/ **380**（全链），
`[MUT-GATE OK]` 判据变红。**同一变异体过等价门（`OVL EQ GATE: OK`，帧流与默认逐字节仍相同）**
⇒ **判别的是速率判据，不是内容判据**（证明"拍/帧变红"这件事本身有判别力）。

---

## 3. 拍/帧与 Gbps 前后对照（一表）

| 配置 | 拍/帧 | 载荷 Gbps | 帧率 | 瓶颈在哪一级 |
|---|---|---|---|---|
| 改动前（默认构建实测） | 378 / 379 | 4.868 / 4.855 | 413 kfps | 组帧器（**48.7% 收发不重叠**） |
| 改动后（`UDP_TX_OVL` 实测） | **191 / 193** | **9.634 / 9.534** | 818 kfps | **`mac_tx_10g` 自身 193.24 拍** |
| 802.3 口径上限（1472/1538×10G） | 192.25 | 9.571 | — | 物理口径 |
| 反例（乒乓退化） | 379 / 380 | 4.855 / 4.842 | — | 回到串行 |

---

## 4. `o_busy` 结论（一段话）

`o_busy` 的**对外含义仍是"帧器有帧在飞、cfg 必须冻结"**，但**窗口左边界从"帧末拍"提前到"帧首拍"**；
逐帧是旧窗口的**严格超集**（实测：旧的 C5-old 判据在新版 0 违反；旧版本身在 C5-new 判据下 5488 违反）。
唯一消费方 `udp_tx_cfg.v:120` 的冻结窗口因此变长 ⇒ **改 peer 时多了 15 拍（16 vs 1）的门阻塞**，
但 ① 帧不丢（`stat_deny` 计数、原帧照发）② 无死锁（在飞帧必被排空 ⇒ `o_busy` 必归零）③ 帧内 cfg 一致性只增不减。
**没有别的对外可观测语义变化**（帧内容/长度/FCS/pad/帧序/统计口径/`s_axis` 与 `m_axis` 的 AXIS 合同均逐字不变）。

---

## 5. 资源增量（**分析值，不是综合值** —— 本 agent 被禁止跑综合）

实测基线（P6a KU5P 层级利用率报告 `p6a_ku5p_verify/p6a_t6p4_util_hier.rpt:114-117`）：

| 层次 | LUT | 其中 LUTRAM | FF | RAMB36/18 |
|---|---|---|---|---|
| `u_udp_tx`（默认 `udp_tx_frame`） | 887 | **336** | 369 | **0 / 0** |
| ↳ `u_fifo`（256×73） | 579 | 336 | 91 | 0 / 0 |
| ↳ `u_csum`（checksum16） | 103 | 0 | 49 | 0 / 0 |

**改动增量（分析）**：`+1 个同参数 fifo_sync`（≈ **+579 LUT（含 336 LUTRAM）+91 FF**，仍是 LUTRAM 路线 ——
256×73 在综合里就落 LUTRAM，不是 BRAM）+ 73 位 2:1 输出 mux ×2 与 full/empty 2:1（≈ **+150 LUT**）
+ 第二份帧上下文（≈ **+92 FF**）+ 双引擎 FSM（≈ **+50 LUT**）
⇒ **≈ +780 LUT（其中 ~340 LUTRAM）/ +185 FF / +0 RAMB36 / +0 RAMB18 / +0 URAM**。
设计余量参考（P6a KU5P 合并构建）：LUT 46,842 / 216,960 ⇒ 增量 ≈ **+1.7%**。
⚠️ **两个"没省下"的点**：① 若把两个 bank 都推成 BRAM 需 `ram_style` 属性（本改动**没有**加，因为会改默认实现之外的实现风格）；
② 我**没有**用第二个 `checksum16`（收尾搬进 RX 引擎）⇒ 省掉一份 103 LUT/49 FF。
**WNS/失败端点必须由合并构建复核**（新增的 73 位 mux 落在 TX 载荷通路上）。
⚠️ **映射形态也要复核**：Vivado 对 256×73 的 `ram_style` 是 auto，本报告按"两份都落 LUTRAM"估算；
若综合把其中一份改判成 BRAM（LUTRAM 压力变大时可能发生），资源账会变成 **+1 RAMB36 级** 而 LUT 少增 ——
**两者都不影响功能，但数字必须重报**。

---

## 6. 残余风险

1. **未综合**：§5 全是分析值；`UDP_TX_OVL` 新增的 73 位 2:1 mux 在 TX 载荷组合路径上，合并构建必须重跑
   WNS/失败端点（当前基线 `+0.128 / 0`）。**启用宏需要主线在构建脚本加 `verilog_define UDP_TX_OVL=1`**（本 agent 未改构建脚本）。
2. **改 peer 的额外冻结**：实测 16 拍/次（vs 默认 1 拍）。板上 peer 只在 learn-on-RX 命中新对端时才变 ⇒ 属偶发；
   但**若将来有人周期性刷新 peer 表，就会周期性吃掉 ~2 帧**（≈2.4 µs）。这是一条**新引入的可用性约束**，必须记进 `udp_tx_cfg` 的设计说明。
3. **RX 侧只剩 4 拍余量**（187 vs 191）：若上游有气泡、或下游反压让 TX 变慢，RX 不会被拖累（它只受"本 bank 归还"约束），
   但**两 bank 都满时 `s_axis_tready` 会拉低**（背压语义正确，但比默认实现多缓存 1 帧）。
4. **未覆盖的激励**：① 真 app（`app_udp_pattern` 8 路并行版由另一路 agent 在改）与重叠帧器的**端到端**速率未测 ——
   本报告的 9.53 Gbps 用合成"无限就绪源"；② 未测"边收边发 + 校验和失败/冲洗 + 慢消费者"三者叠加的极端组合（本 TB 只有两两叠加）。
5. **默认构建"逐位不变"的证据链是三层**：源码 343 insertions/0 deletions（§1）→ 默认构建的守卫门/app 门全过（§2④）
   → 默认构建的 `tb_lvl_frame` 复现记录的 378 拍/4867.7 Mbps（与 `P7B_RATE_BOTTLENECK.md` §8 逐字相同）。
   ⚠️ **没有做网表级等价证明**（那需要综合，被禁止）。
6. **过程中被功能仿真（而非任何 lint 门）抓到的一处自伤**：`rx_state/tx_state` 曾共用 `reg [1:0]`，
   把 `T_DONE=3'd4` 截成 `T_IDLE=0` ⇒ TX 引擎死循环发同一 bank。**隐式网门/位宽门都抓不到**（不是隐式声明，是常量截断）。
   结论：新增"常量 + 状态编码"时，`localparam` 位宽必须与状态寄存器位宽**逐字核对**；本文件已改为分开声明并加注释。

---

## 7. 证据文件清单（本目录 `_proj_10g/notes/p7b_ratefrm/`）

| 文件 | 内容 |
|---|---|
| `run_eq.bat` / `tb_ovl_eq.v` | ① 逐字节等价 + ② `o_busy` 轨迹（`tb_ovl_eq` 自含激励，不依赖 `app_udp_pattern.v`） |
| `run_{def,ovl}/eq_frames.txt` | 线上帧流逐字节（两版 `fc /b` 相同） |
| `run_{def,ovl}/eq_busy.txt` + `eq_events.txt` | o_busy 逐拍（1 字符/拍）+ A/O(帧首/帧尾)/D(阻塞) 事件表 |
| `an_busy.py` | o_busy 分析（对齐自检 + 窗口并集 + 帧周期/窗口数） |
| `run_rate.bat` / `tb_rate_frame.v`（= `p7b_rate/tb_lvl_frame.v` 逐字拷贝, md5 `064d7500…`）/ `tb_rate_chain.v` | ③ 拍/帧：帧器单独 + 帧器→arb→MAC 全链（真 RTL） |
| `run_mut.bat` / `mk_mut.py` / `mut_single_bank/` | ⑥ 反例：乒乓退化单 bank（1 处变异） |
| `run_chain_gate{,_ovl}.bat` + `logs/chain_{def,ovl}.txt` | ④ P7B 真 wrapper 10G 全链门（默认 / 含宏，各 107 条判据） |
| `run_wrap_gate_{head,pristine,head_ovl}.bat` / `run_app_gate_head_ovl.bat` / `run_t2wrap_gate{,_ovl}.bat` | ④ 历史 wrapper/app 门的三方对照（默认 / HEAD 纯净件 / 含宏） |
| `scratch/{udp_tx_frame,app_udp_pattern}_head.v` | `git show HEAD:` 的纯净件（用于归因既存红） |
| `logs/matrix_p4dfix_ovlrun.txt` + `sim/p4sim/matrix_p4dfix.log` | ⑤ P4 16 门默认构建回归（16/16 / 0 失败 / FROZEN） |

---

## 8. 复现入口（全部自定位，只写本目录）

```bash
cd /d/repo/XCKU5PMini/udp_hls_10g
cmd //c '_proj_10g\notes\p7b_ratefrm\run_eq.bat'            # ① 逐字节等价 + ② o_busy 轨迹
cmd //c '_proj_10g\notes\p7b_ratefrm\run_rate.bat'          # ③ 拍/帧 (两版 × 帧器/全链)
cmd //c '_proj_10g\notes\p7b_ratefrm\run_mut.bat'           # ⑥ 反例 (乒乓退化 ⇒ 判据变红)
cmd //c '_proj_10g\notes\p7b_ratefrm\run_chain_gate_ovl.bat' # ④ P7B 真 wrapper 全链门 (含宏)
C:/Users/zhxue/anaconda3/python.exe _proj_10g/notes/p7b_ratefrm/an_busy.py   # o_busy 逐拍分析
```
