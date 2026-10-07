# P7B_LOOP_HANDOFF ——「dup-ACK → 整窗重放」**自持环**（Build 3 下行退化）· **新 session 从这里进**

- 日期：**2026-10-07**（本件 = 交接件撰写 agent 在 **Stage C 板级轮**之后写；**只写文档** —— 未碰 `rtl/` `tb/` `board/` `sim/`、
  未烧板、未写 `0x08`、未起 xsim、未做 git 写操作）
- 仓库 `D:\repo\XCKU5PMini\udp_hls_10g`，**HEAD = `46b2f68`**（Stage B 闭环那笔）；工作区含**未提交**的 Stage C 改动
  （`M rtl/tcp_tx_frame.v` `+823/−1` · `M rtl/app_pattern.v` `+72/−0` · `M board/build_p7b_ku5p.tcl` 等 —— 逐处见 `P7B_BUILD_STAGEC.md` §2）
- **全部读数原件 = `_proj_10g/notes/P7B_BOARD_STAGEC.md`**（下称 **`STAGEC`**）+ 原始件目录 `_proj_10g/notes/p7b_board_stagec/`。
  本件**不复制读数**（除必须原地照抄的机制句），每个数字后面带 `文件:行` 的出处。
- ⛔ **纪律（本轮全程不变）**：只走 JTAG 易失烧录（**绝不写 QSPI**）· **绝不 `git add -A`** · 改动 RTL 与"跑回归"互斥（§8-#57）·
  **板子是"受控停流态"**（`0x08 = 0x2` ⇒ `carrier = 0`）—— 接手时**保持原样**或按 §7 的配方恢复。

> **30 秒版**：Stage C（把板子 TX 方向提速到 10G 的那一刀）**上板后下行从 889–890 Mbps 掉到 224–352 Mbps**（0.25–0.40×）。
> 根因不是"发不出去"也不是"收不下"，而是 **`tcp_tx_frame` 的"整窗重放"被对端的 dup-ACK 反复触发 ⇒ 线上重复率 13.8–19.3×
> ⇒ 自持反馈环**（`STAGEC:19`、`STAGEC:94`、`STAGEC:113-120`）。**它现在就是本工程的第一优先**：
> 新 session 的任务 = 判定"改重放策略"还是"先查透"（§4），并把环破掉；收口 = 下行回到 ≥890 Mbps 且**线上重复率 ≈1.0**。
> ⚠️ **这不是 Stage C 引入的新行为** —— 它是 `W55` 时代就定案的"一次回卷重放整段"（`P7B_BIZ_S2.md:540-551`）被**提速暴露**（§3）。

---

## 1. 问题一句话 + 现象表

**一句话**：板子把 dup-ACK 当成"丢包"信号 ⇒ **重放整个 `[snd_una, snd_nxt]`（≈29 帧）**，
而重放帧里**绝大多数是对端已收过的重复**；Linux 对重复段**立即回 ACK** ⇒ 板子看到更多 dup-ACK ⇒ **自持**。
有效速率 = 帧率 ÷ 重复率 ≈ `350k fps ÷ 15 ≈ 23k 段/s ≈ 0.27 Gbps`（`STAGEC:94`）。

### 1.1 ⭐ 主判据 + 同会话 A/B（**本轮最重要的对照**）

| 臂 | 位流 / BID | 30 连聚合 Mbps | 板侧载荷 Mbps | 拍/帧 | **重复率 `W15/W51`** | retx 会话 | `Δnodesc` |
|---|---|---:|---:|---:|---:|---:|---:|
| **Build 2**（负对照） | `1ccbd9cd…6cdd07` / **9** | **889.4 / 890.3** | 688.9 / 694.5 | **2600 / 2578** | **1.01 / 1.01** | 49 / 56 | 0 / 0 |
| **Build 3**（Stage C） | `1609d6f5…576f3c` / **0xA** | **224.1–352.5** | 208.8–316.6 | **416–461** | **13.8–19.3** | 6,970–11,449 | 0–17,278 |

出处 = `STAGEC:77-78`（表格逐字）。⇒ **Build 3 的下行 = Build 2 的 0.25–0.40×**（同会话、同工具、同 30 连）。
- Build 2 形态：拍/帧 ≈ 2578（app 1828 拍/帧是瓶颈 ⇒ **TX 线空转**）、重复率 **1%** ⇒ **干净**。
- Build 3 形态：拍/帧 416–461（**TX 线只忙 43–46%**，几何值是 193）、重复率 **14–19×** ⇒ **线上全是重放**。
- 历史基线对照：Stage 2（10-06）`SINK_SUM agg_Mbps = 895.445`（300 连）⇒ 与 Build 2 臂同量级（`STAGEC:83-84`）。

### 1.2 逐跑表（4 跑；`STAGEC:58-64` 逐字）

| run | 配置 | sink 聚合 Mbps | 板侧载荷 Mbps | 拍/帧 | 重复率 | retx 会话 | 帧/会话 |
|---|---|---:|---:|---:|---:|---:|---:|
| DL2 | 20 连 | **312.1** | 270.7 | 445.97 | **15.08** | 6,970 | 29.1 |
| DL3 | 30 连 + pcap | **224.1** | 208.8 | 451.56 | **19.30** | 11,449 | 34.5 |
| DL4 | 30 连，**对端 RX ring 4096** | **239.5** | 222.2 | 460.50 | **17.77** | 10,828 | 33.5 |
| DL5 | 30 连，**sink `--nocheck`** | **352.5** | 316.6 | 415.95 | **13.81** | 10,051 | 27.6 |

⇒ 4 跑全部 `fail_conns=0`、`mismatch_bytes=0`（**每条连接收满 1,048,576 B 且逐字节等于图案**，`STAGEC:66-68`）
⇒ **Stage C 的数据内容是对的；坏的是速率与线上效率**。三种放松（`--nocheck` / ring 4096 / 无 tcpdump）**都没破环**（`STAGEC:227-228`）；
20 连档同病（重复率 15.08，`STAGEC:60`）。

### 1.3 附带项（都 ✅，说明"只坏了下行这一格"）

| 项 | 读数 | 出处 |
|---|---|---|
| **上行复验**（Stage C 没碰坏上行） | **4042.682 / 4149.076 Mbps**（Build 2 锚 4058.033 / 4142.682 / 4133.629）；`ΔW53/tx_bytes` **逐跑 1.000000**；**`ΔW54 ≡ 0`**（≈6.3 GB 逐字节） | `STAGEC:141-150` |
| **`J0` 快复验**（8 B/帧修复仍在） | pcap **300/300 = 1514 B** · **809,577.9 fps** · `ΔW43/ΔW20 = 193.0000` · 载荷 **9.5336 Gbps** · `ΔW9 == Σ线上载荷` 差 **+32 B** · 丢弃计数全 0 | `STAGEC:152-165` |
| **双向（数据帧 + 纯 ACK 共用 TX 线）** | ⭐ **设计件"每 ACK 11 拍"的首次板级读数**：**251.7k ACK/s** ⇒ UDP 下行只掉 **−1.772%** = `251,666×11/156.25e6` **逐位吻合**；停止上行后 fps **逐字回到 809,578** | `STAGEC:167-185` |
| **`J0` 是本节的关键负对照** | 同一个板、同一条 TX 线，**没有 TCP ACK 环时** 809,578 fps / 9.5336 Gbps / **零重复 / 零丢弃** | `STAGEC:164-165` |

⚠️ **双向那一格的构型要登记**：板侧 UDP 泛洪（数据帧）+ 对端 TCP 上行（板每收一帧发一纯 ACK）——
**不是 TCP 数据 + TCP 数据**（演示 app 单会话 ⇒ 结构性做不了，`STAGEC:229`）。

---

## 2. 机制（三台仪器同指；**逐字照抄** `STAGEC:113-120`）

```
板发一整窗（8–16 帧突发，窗口上限 33 帧）
  → 对端栈出现一个洞（0.16–0.4%；ring=4096 时为 0 的 NIC 丢失 ⇒ 洞在栈/软队列一侧）
  → 对端 quickack：洞存在期间**每收一帧回一个 dup-ACK**（pcap: 9815 ACK / 10183 数据帧）
  → 板子把 dup-ACK 当重传触发 ⇒ **重放整个 [snd_una, snd_nxt]（≈29 帧）**
  → 重放帧多数是**对端已收过的重复** ⇒ Linux 对重复段**立即回 ACK** ⇒ 板子看到更多 dup-ACK
  → 回到第二行 ⇒ **自持反馈环**（一次初始洞可自持放大 ~20×：627 个 OFO 事件 vs 36 万重复帧）
```

**三台独立仪器**（`STAGEC:102-109` 逐字）：
1. **板侧账**：`ΔW15(W15 = tx_stat_bytes 含重传)/ΔW51(app 载荷)` = **13.8–19.3**；`ΔW55(tx_stat_retx)` = **6,970–11,449 会话**，
   每次会话重放 `(ΔW20−ΔW52)/ΔW55` = **27.6–34.5 帧** ≈ **在飞窗口上限 33 帧**（`RING_CAP = 0xBFFE = 49150 B / 1460`）。
2. **线上账**（DL1 头段 20,000 帧 pcap）：第一条连接 **10,183 个数据帧 = 667 唯一 + 9516 重复（93.4%）**；
   时间线可见**重放突发（seq 回退重放）紧跟在对端同 ack 的 dup-ACK 批之后**（例：t=0.000206–0.000244 收 8 个
   `ack=305419897` 的 dup-ACK ⇒ t=0.000261 起板子重放 `seq=305419897…305425736`=前 5 帧）。
3. **对端账**：`TcpInSegs` 逐跑 ≈ 板侧 `ΔW20`（**无线上丢帧**），`TcpExtTCPOFOQueue` 只 +627…+1198（**0.16–0.4%** 乱序）；
   `port_rx_nodesc_drops` 在 DL4（ring 4096）为 **0** ⇒ **初始"洞"是 0.16–0.4% 量级的小事件，被放大成 1400–1900% 的线上重复**。

**限速级判定**（`STAGEC:90-94`）：四个候选上界逐个比过 —— TX 引擎 9.456–9.555 Gbps（差 30–45×）·
线上载荷天花板 9.493 Gbps · 双向预算 8.86–8.95 Gbps · **对端接收能力（不是）** ⇒ **限速级 = 板侧"整窗重放"反馈环**。

⚠️ **归因的边界（不许读过头，`STAGEC:125-136`）**：
- **"洞从哪来"没定到最后一米**：pcap（对端驱动层）显示这些段**到过对端**，但对端 TCP 没前进（首连前 21 个 ACK 停在 `ISN+1`）
  ⇒ 洞在**对端栈内部**（软队列/socket 层）——**没有逐个洞的见证**。
- **"谁先动手"**：第一跳重放**紧跟 dup-ACK 批**（时序上）⇒ 触发键 = dup-ACK；但**板的 dup-ACK 阈值（≥3？）与重放粒度
  （整窗而非单洞）只有行为证据、没有 RTL 级证据**（本轮禁读 `rtl/`）。
- **A/B 只证明"Stage C 的两刀（A2 + `TCP_TX_OVL`）把下行打坏了"**，**没有拆开是哪一刀单独触发**（两者是乘法关系：
  只有 A2 ⇒ 帧器 379 拍；只有乒乓 ⇒ app 1828 拍 —— 两者都不足以让 TX 线跑到线速突发）。

---

## 3. ⭐ 历史脉络（**这段是"为什么以前没人抓到"的答案**）

**`W55` 定案当年被读成"良性小重放"** —— 摘 `P7B_BIZ_S2.md:540-551`（§10.3，2026-10-06）：

| 量 | 读数 | 结论 |
|---|---|---|
| `ΔW55`（`tcp_tx_frame.stat_retx` 回卷次数） | **365 / 374** | —— |
| pcap `dupseq`（重复 seq 数据段） | **1,695 / 1,878** | —— |
| **每次回卷重放段数** | **4.64 / 5.02** | ⇒ **一次回卷重放"当前在飞整段 `[snd_una, snd_nxt]`"** |
| `ΔW15 − 对端 socket 字节` | 2,474,700 = **1695×1460 精确** | 账目自洽 |

- 同件的登记口径 = **风险 a**："`dupseq = 1,695`（5.65/连接）……⚠️ **降低 ~2× 但未消失**"（`P7B_BIZ_S2.md:602`）。
- 独立验收那一轮（Stage B）的读数重心在**上游（credit / RTT）**（判据 `credit ≈ win − rate×RTT` 的恒等式 = `P7B_BOARD_STAGEB_ACCEPT.md:56`）；
  台架工具报的 `RETX_seq_backward = 159,852 (33.34%)` 还被判为 **32 位 seq 回卷假象**（`P7B_BOARD_STAGEB_ACCEPT.md:52`、`:135`）
  —— ⚠️ **下面这半句是本件的读法、不是原件结论**：那条判定对**当时的窗**是对的，但**在当时放大了"重放无害"的错觉**。
- ⭐⭐ **Build 2（`1ccbd9cd…`，R1 位流）因为慢从未触发它**：`STAGEC:81-82` 逐字 ——
  "Build 2 的形态：拍/帧 ≈ 2578（app 1828 拍/帧是瓶颈 ⇒ TX 线空转），重复率 **1%** ⇒ **干净**"。
- ⇒ **结论（本件的判读）**：**不是 Stage C 引入了新行为，是它把板子跑快到了会触发它的速度**。
  Stage C 两刀把帧周期从 2578/1828 拍压到 416–461 拍 ⇒ **板侧第一次能"整窗突发"** ⇒ 洞 + dup-ACK + 整窗重放的闭环被点燃。
- ⚠️ **与 Stage C 内抓到并已修的 F1 不是同一件事**（新人容易混）：F1 = 控制帧 `+1` 预留越顶 `retx_hi` ⇒ `ring_delta` 下溢
  ⇒ **伪 `ring_start`** 的洪水，**已在 Build 3 里修掉且门有牙**（`P7B_STAGEC_TX.md:95-118`；负对照 Q 臂 `frames=64` vs 修复后 `frames=3`）。
  本件这个环**用的是正常重放路径**（`W55` 口径的 `[snd_una, snd_nxt]` 重放），**不是** F1 的下溢路径。
  （另：F1 审查发现**同族下溢在默认分支也已存在**、触发窗 ~1–2 拍，Stage C 把它抬到 ≥124 拍 —— 那条已按 `P7B_STAGEC_TX.md` §1.3 **两分支同修**，登记在案。）

---

## 4. 三条候选路径 + 推荐（**分析层，非读数** —— 决策权在用户）

| # | 路径 | 内容 | 代价 / 前提 |
|---|---|---|---|
| **A** | **退回**（宏关） | 关 `TCP_TX_OVL`（**默认就是关的**）⇒ 帧器回到串行；若连 A2 一起退（A2 包在 `P7B_10G` 内、**不能单独关**）则需**新构建**。 | 前提：**Build 2 位流在盘上**（`p7b_build_stageC/baseline_archive/wrapper_p4_Build2.bit`，sha256 `1ccbd9cd…6cdd07`，本件**已复核**）⇒ 可直接烧回做 A/B，**零构建**。代价 = **放弃 TX 方向的 10G**（只关乒乓 ⇒ 上界回到 `1460×8×156.25e6/379 = 4.8153 Gbps`；连 A2 也退 ⇒ 998 Mbps 级）。 |
| **B** | ⭐ **修重放策略**（**推荐**） | **限制重放粒度**（按洞/SACK 重放，而不是整段 `[snd_una, snd_nxt]`）**和/或** 给 **dup-ACK 驱动的重放加节流**（例如：同一会话内重放段数上限、dup-ACK 触发比例限制、回卷后冷却窗）。 | ⚠️ **它同时修好两个分支**：① 本环（Stage C 下行退化）；② **历史上一直存在的"每连接重复段"**（Stage 2 的 `dupseq = 1,695 / W55` 定案 —— 同一根因：重放粒度 = 整段；`P7B_BIZ_S2.md:540-551`）。⭐ 且**低延时行情/交易这个终局目标本来就要求它**（整窗重放 = 线上浪费 + 延迟灾难；见 `udp_hls_10g/CLAUDE.md` 的终局目标行）。不动速度（保留 9.456 Gbps 潜力），但**要动 `rtl/tcp_tx_frame.v`** ⇒ 需门 + 构建 + 板级两臂 A/B（Build 2 可当负对照）。 |
| **C** | **先查透** | ① 洞的**最后一米**（对端栈内部哪个环节丢/滞后 —— softnet backlog？socket 层？）；② **板侧 dup-ACK 阈值 / 重放粒度的 RTL 级证据**（读 `rtl/tcp_tx_frame.v` 的 `retx_req` 门与回卷写，本轮禁读未做）；③ **A2 与乒乓拆刀单独归因**（两次构建：只 A2 / 只乒乓）。 | 零 RTL 风险，但**三次板级轮次**（每次含构建或重烧）；且 **C 做完不修环，下行仍是 224–352 Mbps**。 |

**推荐 = B**（B 与 C 不互斥：B 落地时把 C-② 的 RTL 证据一并取到，是同一份 diff 的两面）。
⚠️ **若用户只想要"先恢复可用"**：A 是最便宜的（烧回 Build 2，零构建，A/B 归档已在）。

---

## 5. ⛔ 未证清单（**逐条照抄 `STAGEC:221-232`（§7），不许升格**）

1. **"洞"的最后一米**：对端栈内部哪个环节丢/滞后（softnet backlog？socket 层？）——没有逐洞见证；
   `Δnodesc=0`（ring 4096）下环仍自持 ⇒ 不是（仅）NIC ring，但**没有抓到第一个洞的直接证据**。
2. **拆刀**：A/B 只证明"Stage C 整体把下行打坏"，**没有**分别关掉 A2 / `TCP_TX_OVL` 各测一次（两个宏的组合需要重构建，本轮无授权）。
3. **板的 dup-ACK 阈值 / 重放粒度**：只有行为证据（pcap 时序 + `W55` 会话数 × 帧/会话），**没有 RTL 级证据**（本轮禁读 `rtl/`）。
4. **9.456 Gbps 是否可达**：本轮没能在板上让 TCP 下行接近它；`--nocheck`、ring 4096、无 tcpdump 三种放松都没破环
   ⇒ **可达性未证**（不是"已证不可达"——修复回路后应重测）。
5. **双向的 TCP 数据 + TCP 数据**构型：**没做**（演示 app 单会话 + 默认单池 ⇒ 结构性做不了；§1.3 用 UDP 数据帧 + TCP ACK 代理）。
6. **`tcp_rx` 每段拍数**（Stage B 遗留的"上行天花板另一半"）：**未做**（不在本轮授权内）。
7. **对端 NIC 计数虚高的机理**：只证了"物理不可能"，**未定位**（sfc 驱动/MAC 统计口径未查源码）。

---

## 6. ⚠️ 环境与地雷（**新人最容易踩的，逐条**）

| # | 地雷 | 细节 / 判据 |
|---|---|---|
| ① | **板上现态 = Build 3 / 下行退化版** | 位流 **`1609d6f55e8a119b2f88c1a57cd4776e2219f56d3d1e84f840b198555e576f3c`**（15,431,261 B）+ **受控停流**（`0x08 = 0x2`、`carrier = 0`、`0x11C = 0xffffffff`；`STAGEC:25`）。本件**复核过**盘上副本 = `p7b_build_stageC/stageC_wrapper_p4.bit`（sha 逐字相同）。**要不要先烧回 Build 2 是待定项**（见 §4-A）。 |
| ② | **Build 2 位流在归档里（两份，已复核）** | `_proj_10g/notes/p7b_build_stageC/baseline_archive/wrapper_p4_Build2.bit` 与 `_proj_10g/notes/p7b_build_archive/20261007_163651/wrapper_p4.bit` —— **两份 sha256 都 = `1ccbd9cd84292d1a10973a1442f71ca2187e66834be5e09d7eeb22b42c6cdd07`**（本件现核）。⚠️ **`vivado_prj` 里没有第二份**（`create_project -force` 已清）。 |
| ③ | **`BID = 0x0000000A`（首次含字母）** | `STAGEC:197-206`：`reg_rw` 打**小写** `0x0000000a`，而旧判据写成大写 ⇒ **字符串比较必假红**；本轮**已修 4 处**（`p7b_snap.sh` / 轮内 2 件 / `final_state.sh`，均大小写归一）· `p6e_snap_check.sh` **未改、已登记**。⚠️ **同类可能还有**（凡比较 BID 的地方都要看一眼）；`p7b_gate4_accept.sh` 是**数值**比较（免疫）。 |
| ④ | **窗口 63 字；未实现地址 `0x11C`** | 现役槽位表 = `_proj_10g/notes/P7B_BIZ_WINDOW.md` §1。⚠️ **旧地址 `0x114` 现在是 W61 真字**（拿旧口径读会**响亮失败**，不是静默）；**绝不能挑 ≥ `0x200`**（7 位译码回绕到 word 0 = MAGIC ⇒ 假 FAIL）。 |
| ⑤ | **32 位计数器 12 s 回卷**（`> 2.86 Gbps` 即触发） | `P7B_STAGEB_CRITERIA_FIX.md:54-87`：门槛 = `2³²/12 s = 2.8633 Gbps`（字节类）；**所有 ΔW 必须 mod 2³² 且记原始值与 k**。**8 个脚本已改**（6 个解析器 + 2 个台架）；真回卷族 = **`W1`/`W31`/`W37`（402–403 MB/s）+ `W53`**（`W54`/`W52` 是**错例**）。⚠️ **自由计数 `W5/W24/W36/W43` 27.487 s 回绕** ⇒ "把窗拉到 30 s"是错的。 |
| ⑥ | **`sim/p5wu_p1p2_review/` 有 2 条冻结件未改，红是预期的** | `rev_window_check.py` / `rev_check_wu_words_copy.py` 里钉的是 `BUILD_ID_V == 9` ⇒ BID 升 0xA 后**必 FAIL**。**属"陈旧引用、不是回归"**，TL 已裁定**不要去改**（`P7B_BID_SYNC.md:215-230`，含 30 秒改法备用）。⚠️ 与⑤的 32 位回卷**不是同一件事**。 |
| ⑦ | **对端 `/tmp/p7b_biz/` 有旧副本 —— 跑台架前必须先 `--put`** | **本件现核**：Stage C 台架（`stc_dl.sh` `f50e5f82…` / `stc_bidir.sh` `a716b53d…` / `j6_stagec.sh` `23c4a343…` / `p7b_snap.sh` `68d2f668…`）**对端与仓内逐字相同**；但 ⭐ **`/tmp/p7b_biz/j6_stagea.sh` 对端 = `0158ba1e…`（旧版），仓内 = `c6b27b1b…`（含 32 位回卷规则）** ⇒ **直接跑它 = 跑旧台架、判据静默错**（`P7B_STAGEB_CRITERIA_FIX.md:140-151`）。⇒ **部署配方**：`python tools/peer_ssh.py --put <仓内件> /tmp/p7b_biz/<同名>`（必要时再 `--sudo`；`PEER_PW` 环境变量、不落盘）。 |
| ⑧ | **对端 NIC 计数在 ~1M fps 虚高 ≈18%** | J0 窗 NIC 记 **983,201 fps > 几何上限 809,578 fps = 物理不可能**；`Δbytes/Δpkts` 比值仍是 1517.9994 ⇒ **虚高是共同乘性因子**（`STAGEC:214`）。⇒ **判据优先用板侧计数 + 比值口径**；`ethtool` 与 `ip -s link` 同源同偏。 |
| ⑨ | **FIN 卡死：1/280 连接收满 1 MB 后板侧不发 FIN** | `STAGEC:215`：conn#279 对端 `ss` 逐字 `bytes_received:1048576 … lastsnd:313168`（5.2 min 无发送）、`Recv_Q=0`、无 FIN；板侧 `ΔW51` 恰为 280 连的整数倍 ⇒ **未定位**。**台架已加 `timeout` 护栏**（无护栏时 sink 永久阻塞在 `recv`，第一跑就把 ssh 通道拖死）。 |
| ⑩ | **判"烧成了没有"要读板侧 BID，不信 bat stdout** | `STAGEC:217`：本轮抓到一次**静默的"没烧成"**（第一次 Build 2 烧录后板侧仍读 `0xA`、`tcpreg_program_stdout.txt` mtime 未更新 ⇒ 那次 bat 没真正落盘执行）。烧录判据 = **板侧 `0x04` 读数 + `End of startup status: HIGH`**。⚠️ 报"烧成"时**别只信 BID**（Build 2 与 Build 1 同 BID=9 的先例）—— **sha256 才是"是不是这个位流"**。 |
| ⑪ | **构建会摧毁上一轮取证**（`create_project -force` 开工即清 `impl_1/`） | 已把归档**写进 `board/run_build_p7b_ku5p.bat`**（pre-build archive 块 +52 行，落 `_proj_10g/notes/p7b_build_archive/<stamp>/` 19 件 + `SHA256SUMS.txt`，~150 MB/次；`P7B_BUILD_STAGEC.md:50-75`）—— **但"新 session 若手工构建"仍要注意**；⚠️ 该目录**未被 `.gitignore` 覆盖**（会以未跟踪文件出现在 `git status`）。 |
| ⑫ | **"改 RTL" 与 "在跑回归" 互斥**（全局 #57） | 一并发就会出"回归看半成品 + 修完 RTL 后旧读数作废且无标记"。要并行 ⇒ **`git worktree`**；判"回归有效"第一步 = **核它跑动期间源文件 sha256 有没有变**（`~/.claude/fpga_net_dev.md` §六 `57.`）。 |
| ⑬ | **板子现态是"停流"**（收尾纪律） | 恢复 = `reg_rw /dev/xdma0_user 0x08 w 0x0`（**一条命令**；`0x08` **既是 SCRATCH 又是 `TX_DIS` 门**）；⚠️ 恢复后 peer 表还在 ⇒ 会立刻恢复发流（要彻底停发只能重烧）。**重烧会清 peer 表** ⇒ 需重新 `p7b_udp_src` 建表。 |

---

## 7. 怎么复跑（逐字命令）

**0）前置（对端，需 root；每次发送前现取）** —— `/32` 与路由（`P7B_WU_LOOP_RECON.md` §4.4；`final_state.sh` 收尾会把它们清掉）：

```bash
PY=/c/Users/zhxue/anaconda3/python.exe      # 本机 python（anaconda）
PEER_PW=<pw> $PY tools/peer_ssh.py --sudo \
  'ip link set enp1s0f1np1 up; ip addr add 192.168.100.100/32 dev enp1s0f1np1; \
   ip route add 192.168.100.2/32 dev enp1s0f1np1'
PEER_PW=<pw> $PY tools/peer_ssh.py --sudo 'nmcli device set enp1s0f1np1 managed no'   # 根治 NM 冲 /32
$PY tools/peer_ssh.py 'ip route get 192.168.100.2; cat /sys/class/net/enp1s0f1np1/carrier'
```

**1）烧录（本机，经 192.168.0.38:3121 的 hw_server；JTAG 1 MHz）**：

```bash
# 模板 = _proj_10g/notes/p7b_biz_tcpreg/{program_tcpreg_ku5p.tcl, run_program_tcpreg.bat}
#   ⚠️ 该 .bat 是已知的**纯 LF**（ASCII）—— 历史上能跑，但属未结项的纪律偏差
# .bat 读环境变量 TCPREG_BIT（位流绝对路径，Build 2 / Build 3 任选）：
TCPREG_BIT='D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_build_stageC\stageC_wrapper_p4.bit' \
  cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_biz_tcpreg\run_program_tcpreg.bat'
# 判据（不信 stdout）：烧后板侧读 0x04（=0xA 是 Build 3 / =9 是 Build 2）+ 'End of startup status: HIGH'
```

**2）PCIe 恢复（烧后）**：`lspci` 看 `LnkSta`：**`x4` 有救 / `x0` 没救**；先**设备级** `remove`+`rescan`，
失败（`BAR 1 … can't assign`）才升到**连根端口**（`P7B_HANDOFF.md` §1 的配方行；`STAGEC:46` 记录本轮设备级一次成功）。

**3）恢复发流（板子现在是停流态）**：

```bash
PEER_PW=<pw> $PY tools/peer_ssh.py --sudo \
  '/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools/reg_rw /dev/xdma0_user 0x08 w 0x0'
```
（`reg_rw` 路径 = 台架变量 `T=${P7B_TOOLS:-/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools}`，见 `stc_dl.sh` 头注。）

**4）快照读法**（`_proj_pcie/p7b_biz/p7b_snap.sh`；**协议**：字 `Wi` 地址 = **`0x20 + 4*i`** ·
**触发 = 写 `0x18=1`** · **done = `0x1c` 的 bit1** · `gen = 0x1c>>16`；read = `reg_rw $D 0x20 w`（第 3 参是**位宽**））：

```bash
bash /tmp/p7b_biz/p7b_snap.sh id                 # 身份 + 通道活性（MAGIC/BID/MARKER/未实现地址 + gen）
bash /tmp/p7b_biz/p7b_snap.sh full  TAG          # 触发一次 + 打全 63 字（带名字）
bash /tmp/p7b_biz/p7b_snap.sh snap  TAG 5 51 52 15 20 43 55 54 61 62   # 只打指定字（省时）
```
⚠️ 每次读数必须**自证是新一代**（gen 恰好 +1）；`0xffffffff` = SLVERR（**不是数据**，整窗作废）。
⚠️ **读旧位流要显式覆盖身份**：Build 2（BID 9）用 `EXPECT_BID=0x00000009 bash p7b_snap.sh …`（几何 63 字不变）。

**5）下行 A/B（对端；同一会话前后紧挨 —— 本工程已验证的做法）**：

```bash
cd /tmp/p7b_biz && CONNS=30 SECS=25 TAG=X1 PCAP_ON=0 bash stc_dl.sh                          # Stage C (BID 0xA)
cd /tmp/p7b_biz && CONNS=30 SECS=25 TAG=X2 PCAP_ON=0 BID_EXPECT=0x00000009 bash stc_dl.sh     # Build 2 臂
```
⚠️ **跑之前先按地雷⑦ `--put` 台架到对端**（`stc_dl.sh` 等；`j6_stagea.sh` 必须换新版）。
台架测什么：板侧两代全窗快照 + t0/t1 窗读数 + 对端 NIC 前后计数 + `ss` 采样 + sink 逐连接读数 + CPU 见证 + pcap（`stc_dl.sh` 头注逐字）。

**6）分析（本机）**：

```bash
$PY _proj_10g/notes/p7b_board_stagec/an_runs.py <run_STC_*.log> ...   # 逐跑表（mod 2³² + raw/k 落表）
# pcap → tshark -T fields TSV → python _proj_10g/notes/p7b_board_stagec/an_dl.py <fields.tsv> [--conn N] [--events]
```

**7）上行/双向复跑**：`j6_stagec.sh`（上行；`J6_GEOM_OK NW=63 BID=0x0000000a`）· `stc_bidir.sh <secs> <tag>`（双向，需先跑一次
`p7b_udp_src` 触发板侧 UDP 泛洪建 peer 表）。

---

## 8. 相关全局经验（`~/.claude/fpga_net_dev.md` §六，**#52–#57 逐条一句话**）

> 映射提醒：`P7B_HANDOFF.md` §7 的表用**自己的本地编号**，与全局编号差 1（本地 51/52/53 = 全局 52/53/54）。
> 下面**一律用全局编号**；`~/.claude/fpga_net_dev.md` §六 里 #52–#57 六条**都已存在**（其中 #55/#56 是本工程近两轮回灌的，见本表末注）。

| # | 一句话 | 与本题的关系 |
|---|---|---|
| **52** | **"回归矩阵全绿"可能与你的改动无关 —— 指纹没变就是证据**（manifest 一个都不含被改文件；237 文件哈希集与上一轮逐行相同）。同族细化：**盲有两种** —— (a) 清单里根本没有；(b) 清单里有、但**宏关/平台分支选中的是别的代码**（`chain_src.f` 含 `tcp_tx_frame.v`，但跑的是宏关构建）。 | ⭐ 直接相关：`TCP_TX_OVL` / `P7B_10G` 都是**非默认宏** ⇒ 改完 `tcp_tx_frame.v` 后**默认矩阵覆盖不到你那条路径**（全局 #52 原文的实例：`git grep P7B_10G HEAD -- tb/` **全空**）。 |
| **53** | **哑门的最新变种：打出 `[FAIL]` 却 `exit 0`、末行还写 `PASS`**（+ 同族"默认值陷阱"：`NW=${NW:-61}` 未 `export` ⇒ 覆盖静默失效）。**"门打出了 FAIL" 与 "门失败了" 是两件事** —— 判决要一路走到**退出码**。 | ⭐ 直接相关：本工程台架的输出即判据（`STC_GEOM_OK` / `J6META_*`），**改台架后必须看退出码 + 身份行**，别只看末行。 |
| **54** | **每次构建都会摧毁上一次构建的取证**（`create_project -force` 开工即清 `impl_1/`）⇒ **归档必须写进构建脚本本身**；"与基线对照"的前提是"基线还在"。 | ⭐ 已收口：`run_build_p7b_ku5p.bat` 已含归档块（地雷⑪）；**手工构建仍会踩**。 |
| **55** | **高位速率下的 32 位计数器会在判据窗口内回卷 —— 差值必须 mod 2³²**（门槛 = `2³²/窗长`；12 s 窗 = 2.8633 Gbps；**必须同时记录原始值与 k**；既存工具会**静默印错数**）。 | ⭐ 直接相关：本环的判据全在 `ΔW15/ΔW51/ΔW55` 上 ⇒ **读任何 ΔW 前先看窗长与量级**（地雷⑤）。 |
| **56** | ⭐⭐ **"最漂亮的证据"可能是环路恒等式 —— 证据的论证负荷要单独称重**：`credit ≈ win − rate×RTT`，任何同速同 RTT 的发送方都给同一个数 ⇒ **零信息量**；判定"独立观测"的动作 = **构造反例看能不能复现同样形态**；**交付自带的原件（`ss` 的 `rwnd_limited`/`notsent`）常是最好的反例来源**。 | ⭐⭐ **本题的实例就是 Stage B 的 E5**（被降级为"形态描述"，`P7B_BOARD_STAGEB_ACCEPT.md` §3-②）；本环的机制句（duplicate ⇒ 立即 ACK ⇒ 更多 dup-ACK）**也要按这条自查**：它是"被读数支持的解释"，**不是已被证伪/证实到 RTL 级**。 |
| **57** | ⭐⭐ **"改 RTL" 与 "在跑回归" 是互斥的**（源码一改，正在跑的回归整轮作废、而它未必告诉你）；并行要么 `git worktree`，要么排队；**判"回归有效"第一件事 = 核跑动期间源文件 sha256**；"宏关等于 HEAD"这类免测金牌一旦有修复落到默认分支就**永久失效**。 | ⭐⭐ **下一轮极可能撞**：修重放策略（路径 B）会改 `rtl/tcp_tx_frame.v` ⇒ 与任何并发回归/构建互斥；且 **F1 修复已落到默认分支**（`+8/−1`，`P7B_STAGEC_TX.md` §1.1）⇒ "宏关 == HEAD"**已作废**，此后每次改动都必须由**绑定单一 revision 的矩阵**收口。 |

⚠️ 本工程 §7 曾登记"本轮另两条教训（32 位回卷 / credit 恒等式）只在仓内、不在全局 §六" —— **现已回灌**：
= 全局 **#55** 与 **#56**（`grep -n "^5[5-6]\." ~/.claude/fpga_net_dev.md` 可核）。

---

## 9. 证据地图（原件在哪）

| 件 | 路径 |
|---|---|
| **板级原件（本件全部读数的源头）** | **`_proj_10g/notes/P7B_BOARD_STAGEC.md`**（22 个原始件在 `_proj_10g/notes/p7b_board_stagec/`：8 份 run 日志 · DL1 头段 pcap + TSV · J0 pcap · 台架 3 `.sh` + 分析/生成脚本 + sink 变体 + 2 份烧录控制台；逐件清单 = `STAGEC:237-249`） |
| 台架脚本（仓内副本） | `p7b_board_stagec/stc_dl.sh`（下行）· `stc_bidir.sh`（双向）· `j6_stagec.sh`（上行）· `an_runs.py` / `an_dl.py`（分析）· `p7b_tcp_sink_rate.cpp`（`--nocheck` 变体，对端编译） |
| 构建（Build 3） | `P7B_BUILD_STAGEC.md`：**WNS `+0.070` / WHS `+0.010` / 三类失败端点 `0/0/0`**（基线 +0.006，**反而好了 0.064**）；⚠️ **DP 域前 10 换族**：新锥 `u_tcp_tx/retx_active_reg/C → u_tcp_tx/ctrl_tcpcsum_reg[*]/D`（**22 级 / logic 2.611 ns**）**占满 DP 前 10（10/10）**（`P7B_BUILD_STAGEC.md:16-21`、§5.1–5.3）⇒ **再加逻辑先看这条** |
| 位流 | Build 3 = `p7b_build_stageC/stageC_wrapper_p4.bit`（`1609d6f5…576f3c`）· Build 2 两份归档（`1ccbd9cd…6cdd07`，见地雷②） |
| Stage C 的两刀（来源） | `P7B_STAGEC_TX.md`（乒乓实施 + **F1 修复**）· `P7B_STAGEC_TX_REVIEW.md`（对抗审查：F1 定案 = 阻断级）· `P7B_STAGEC_A2.md`（TX 8 路：190 拍/帧）· 设计件 `P7B_TX_PINGPONG_FIX_DESIGN.md`（REV3b） |
| **历史脉络的源头** | `P7B_BIZ_S2.md` **§10.3**（`W55` 定案：一次回卷重放整段 [snd_una, snd_nxt]、平均 4.6–5.0 段）+ §10.3.1（双向 pcap 的包级机理）· 风险 a 登记（`:602`） |
| Stage B（负对照基线 / 32 位回卷规则） | `P7B_BOARD_STAGEB.md` · `P7B_BOARD_STAGEB_ACCEPT.md`（**独立验收 = 权威**）· **`P7B_STAGEB_CRITERIA_FIX.md`**（mod 2³² 逐处订正 + 对端副本未重部署的登记） |
| 观测面（现役槽位表） | `P7B_BIZ_WINDOW.md` §1（63 字）；环境总表 = `P7B_HANDOFF.md` §1 |
| 环境配方 | `P7B_WU_LOOP_RECON.md` §4.4（网络前置）· `P7B_PCIE_RESCAN_RECOVERY.md` §3（PCIe 两级恢复） |

---

*本件 = 交接入口，不改任何读数；**判据层的 PASS/FAIL 裁定权在用户/判据所有者**（全局 #51）。*
