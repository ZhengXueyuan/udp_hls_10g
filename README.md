# udp_hls_10g — 10G-ready 纯硬件 TCP/IP 数据面（1G 先行）

终局目标：10G 线速的纯硬件 TCP/IP 数据面（低延时行情 UDP 组播 + 交易 TCP 少量连接），
对上提供 TCP/UDP 调用接口。数据面统一 **64bit 左对齐字流**，每级 II=1、帧内零整包暂存。

- **当前板卡 = XCKU5P**（`xcku5p-ffvb676-1-e`）。顶层 = `board/wrapper_p4.v`。
- 板上两条前端并存。**1G RGMII** 前端 = `mac_rx_64` / `mac_tx_64`，绑 125MHz；
  **10G XGMII** 前端 = `_proj_10g/p7b_mac/rtl/mac_rx_10g.v` / `mac_tx_10g.v`，包在 `` `ifdef P7B_10G `` 内。

## 入口文档（先读哪份）

| 想知道什么 | 读哪份 |
|---|---|
| 现在在哪一步、下一步做什么 | 本文「现在是什么状态」 |
| 1G 数据面为什么这么做、35 条验收判据 | `P6B_SUMMARY.md`（一页式，先读这个）→ `P6B_ACCEPT.md`（原始记录） |
| 板级观测通道怎么读（36 字寄存器表） | `P6E_OBS.md` |
| 10G 施工规格（闸序 / 66 条正判据 + 9 条负对照） | `P7B_SPEC.md` |
| P7a 10G PHY（PCS/PMA + gearbox）板级验收原件 | `P7A_RESULT.md` + `P7A_SPEC.md` |
| P7b 闸 1 / 闸 2 / 闸 4 板级读数原件 | `_proj_10g/notes/P7B_GATE1.md` / `P7B_GATE2.md` / `P7B_GATE4_ACCEPT{,2,3}.md` |
| **P7b 下一轮开工先读**（环境现状 / 状态总表 / 下一步 / 待办账 / 产品级 Gap） | `_proj_10g/notes/P7B_HANDOFF.md` |
| ⭐ **10G 线速达标（RATE）的板级测量原件** | `_proj_10g/notes/P7B_RATE_RESULT.md` + 同族 `P7B_RATE_{BOTTLENECK,DATAPATH,8WAY,FRAMER,BUILD,MEASURE_PLAN}.md`（瓶颈定位 / 独立核算 / 两刀 / 构建 / 测量方案） |
| P7b 其余笔记 | `_proj_10g/notes/P7B_{XXV_OFFICIAL,MAC_DESIGN,MAC_REVIEW,MAC_GATEFIX,MAC_TIMING,RXCLASSIFY_AUDIT,RXCLASSIFY_DESIGN,IMPLICIT_GATE_FIX,IMPLICIT_GATE_ROLLOUT,U7_AND_PEER}.md` |
| 施工日志、踩坑、决策、教训 | `PORT_NOTES.md` |
| 工程规范与铁律 | `CLAUDE.md` |

## 现在是什么状态

**一句话**：1G 数据面已在 XCKU5P 上完成板级正式验收（P6b，156.25MHz 域，35/35 判据）；
10G 方向的**闸 0/闸 1/闸 2/闸 3/闸 4 全部收口** —— **闸 4 板级验收三轮 `PARTIAL → PARTIAL → 通过`**；
**唯一 FAIL = `C8`**（观测面 8 位饱和计数器，"在涨"结构性不可判；**判据一字未改、非设计缺陷**），
**另有 4 项未测（`F1-E4b` · `F1-E5` · `F1-E6` · `F5b`）—— 最终判据表 38 行 = `PASS=33` / `FAIL=1` / `未测=4`，以 `_proj_10g/notes/P7B_GATE4_ACCEPT3.md` §2 为准**。
⭐ **产品级第一优先 = 10G 线速未达标 ⇒ 本轮（2026-09-30 下午）已关闭**：两刀（**8 路并行图案发生器** +
**组帧器乒乓重叠**）落地后，**主判据（板内自洽、不依赖主机墙钟）`ΔW20/(ΔW5/156.25e6)` = 813,794.7 fps**，
四轮逐字一致到 3×10⁻⁶ ⇒ **线上载荷 9.531 Gbps（最保守口径）= 同几何上限的 99.61% · 达标界的 1.402 倍 ·
XGMII 占空 99.9991%**。读数与原件 = `_proj_10g/notes/P7B_RATE_RESULT.md`。
⚠️ 本构建的帧几何经三台独立仪器定案为 **载荷 1464 B / 线长 1510 B / 192.00 拍**，与测量计划书的
**1472 / 1518 / 193.24** 不同 —— **错的是计划书**（详见该笔记 §4）。

### ✅ 已完成

| 阶段 | 内容 | 状态 |
|---|---|---|
| P0–P5e | 1G 数据面 + 应用接口（K7 时期；逐项见「归档」） | ✅ 全部板级 PASS |
| P6a | 数据面移植到 KU5P（零 IDELAY RGMII 前端 + 闸 G 时序基线 + 真 ping） | ✅ 板级 PASS（931 Mbps） |
| P6e | 我们自己的 PCIe/XDMA 观测通道（user BAR 寄存器窗口 = 本板唯一观测手段） | ✅ 板级 PASS |
| P6b | 数据面 125 → 156.25MHz（前端留 125MHz + 手写异步 FIFO 跨域） | ✅ 板级正式验收 35/35（956.0 Mbps） |
| **P7a** | **10G PCS/PMA（含 64b/66b gearbox）在板上真的在跑**（X0Y4↔X0Y5 经 AOC 外部环回，自写 PRBS31 计数器判 BER） | ✅ 板级 PASS — 双向各 600 s / 6.003×10¹² bit 零错 ⇒ **BER 上界 4.997e-13**；速率 1.000025×10¹⁰ bit/s 钉死 gearbox 比率 |
| **P7b-闸0** | **选型定案**：官方 `xxv_ethernet`（`CORE = Ethernet PCS/PMA 64-bit`，**XGMII 出**）+ **自写 64 位 XGMII MAC** | ✅ PCS-only **能出位流**；含 MAC 的变体被 license 拒；官方核网表里确有加扰·解码·对齐 ⇒ **GT 不加扰** |
| **P7b-闸1** | **2 通道官方 PCS 板内自环**（J7↔J8，用官方 example 的图案发生器/监视器，**未改一行**） | ✅ 板级 PASS — 6.6 s / 30,056,095 帧零错 · 9,999.94 Mbps · 官方 FSM `completion_status = 1`；三条负对照按期望翻转 |
| **P7b-②** | **新 64 位 XGMII MAC**（`mac_rx_10g` / `mac_tx_10g` / `crc32_64`） | ✅ 单元门 **337 / 0 fail**（交付当时口径；⚠️ **lane4 修复后现为 391**，见下「10G 门」）；与 PCS 合并 **WNS +0.401 / 三类失败端点全 0**；**已接进 `board/wrapper_p4.v` 的 `ifdef P7B_10G`**（前端 = 官方 PCS **ch1 = X0Y5 = J8**） |
| **P7b-③** | **`rx_classify` 收发解耦 v2**（最小帧帧周期 14→8 拍；10G 最小帧 57.1%→100%） | ✅ **已落进 `rtl/`** — P4 矩阵 **16/16 EXIT=0** + 冻结校验 `FROZEN` |
| **P7b-门修复** | 隐式网门（`implicitly declared` 在 2025.2 是**哑门**）+ xelab 面判据铺开 | ✅ 87 文件 / 261 处、**假阳性 0** |
| **P7b-闸2** | 真网卡（SFC9120）802.3 裁决 | ✅ **已出分层裁决**（见下；其中 E3/E4 只到「部分」） |
| **P7b-闸3** | **全链门收口**：链级门 **80 → 106 判据**（lane4 注入 + 逐字节 + TERM 六元组 6/6）+ **全仓 136 门回归** | ✅ 反例双跑有牙（换回缺陷版 RTL ⇒ **106/12 fail 且 12 条全在新族、既有 80 条一条不红**）；136 门 = **112 通过 + 1 处真回归（✅ 已收口）+ 21 既存 + 1 偶发 + 8 哑门（3 条已修）** |
| **P7b-门修复收口** | 真回归（`p4_rxclass` / `p4_rxclass_xk` 门清单各补 1 个 `rtl/fifo_sync.v`）+ **3 条哑门/坏脚本**（`p4_replay` 补 DONE 判据 / `p5c_rev_elab` 补 2 件 + ERROR 硬判据 / `p4indm_4gates` 改委托 P4 矩阵） | ✅ 两条门由红转绿（**EXIT=0**，三模式 161 行 PASS，**与基线逐字相同；未改 RTL**）；哑门 3 条自证 + **反例 4 条真跑按期望翻转**；⚠️ 两条门脚本在 `.gitignore` 里 ⇒ **放行处理中** |
| ⭐ **P7b-闸4** | **10G 板级验收**（快照 51 字 + PCS 链路 + 端到端 F 组） | ✅ **通过** — 三轮 `PARTIAL → PARTIAL → 通过`：脚本 **`PASS=26/FAIL=1/SKIP=1`** + 快照 **`15/0/0`**；**最终判据表 38 行 = `PASS=33` / `FAIL=1`（仅 `C8`）/ `未测=4`（`F1-E4b`·`F1-E5`·`F1-E6`·`F5b`）—— 以 `P7B_GATE4_ACCEPT3.md` §2 为准**；F3 = 3000 帧逐字节 + GF(2) 反解（**无需重烧**），F4 = pcap 端点 **106,182 / 106,174 fps** vs 板侧 106,003 fps（**+0.17%**）；**`F5a`（不掉链）从"未测"升级为"定性 PASS"，`F5b`（重传计数）仍未测** |
| ⭐ **P7b-修** | **两个真缺陷修复**：① `/S/` 落 XGMII **lane4** 的帧 SOP 字非满对齐（`mac_rx_10g.v` **+122/−25**）；② pad/FCS 修复打出的 TX 时序回归（`mac_tx_10g.v` 的 `padrem`/`lw_ts` **等价化简** +28/−1） | ✅ **①** 板级复证：单发教学即被认领、成批 **20/20** 认领、图案流 **2999 帧逐字节**等于图案流且偏移 0 连续；**②** 合并构建 **WNS +0.128 / WHS +0.010 / 三类失败端点全 0**（上轮 39 条 setup 违例全部消失，位流 sha256 `0e1c8088…b557`） |
| ⭐ **P7b-线速（RATE）** | ⭐ **10G 线速达标**（**产品级第一优先，本轮关闭**）：两刀 = ① **8 路并行图案发生器**（`rtl/app_udp_pattern.v`，包在既有宏 `P7B_10G` 内，`M^k` 常量 XOR 网、**逐字节等价**，发生器 **1474 → 186 拍/帧**；TX 与 RX 校验器同批改）② **组帧器乒乓重叠**（`rtl/udp_tx_frame.v`，**新宏 `UDP_TX_OVL`**，**378 → 191 拍/帧**，`o_busy` 只在"帧首拍 → 上一实现窗口起点"之间变长且唯一消费方是 `udp_tx_cfg`）—— ⚠️ **`UDP_TX_OVL` 现在在 `board/build_p7b_ku5p.tcl` 里是打开的（只影响这一个 P7b 构建）；关掉它就回到 HEAD 的帧器行为（`ifdef` 的默认分支逐字保留，343 insertions / 0 deletions）** | ✅ **板级达标** — 主判据 `ΔW20/(ΔW5/156.25e6)` = **813,794.7 fps**（四轮 R1/R2/R3/L20 **逐字一致**到 3×10⁻⁶；FE/DP 双域交叉差 **+0.0003%**）；**拍/帧 192.00**；**线上载荷 9.531 Gbps（最保守口径）= 同几何上限 99.61% / 达标界 ×1.402 / XGMII 占空 99.9991%**；四项差分账 `d_dma/d_board = 0.99802`、**`Δcrc=Δbad=Δovf=0`**；负对照 N-a（拉 `TX_DIS`）⇒ NIC 计数全 0 而**同窗 `ΔW20` 仍 813,802 fps** ⇒ **两条口径的独立性被直接证明**；构建 `WNS +0.136 / 三类失败端点全 0`，位流 sha256 `4eeb0f5f…3133` |

**⭐ 新 MAC 修掉的一个真缺陷（DEFECT #1）**

- 现象：`mac_tx_10g` 对**需补 pad 的短帧**算出的 FCS **只覆盖数据字节、不含 pad**，
  而 `mac_rx_10g` 与标准对端都要求 pad 计入 ⇒ **自家 TX 与 RX 不一致**。
  1G 版 `rtl/mac_tx_64.v` 是 pad 计入 CRC 的，**10G 版是偏离方**。
- 影响面：10G 下所有 < 60 内容字节的帧（**ARP 应答 42B、TCP 纯 ACK 54B** …）会被对端丢。
- 判据：**252 → 337**（变异 16 条全符预期）。⚠️ 这是**修复当时**的口径；lane4 修复后现为 **391 checks / 0 fail**
  （变异 23 条），见下「10G 门」节。
- 附带修法：把**同源 oracle** 改成「**从线上解出的字节**」（原来 oracle 与实现同源 ⇒ 缺陷结构上看不见）。
- 证据：`_proj_10g/p7b_mac/scripts/mutate_gate.py` + `_proj_10g/p7b_mac/sim/_mut_logs/00_clean.log`（337 checks / 0 fail）。

**⭐ P7b 闸 2 的分层裁决**（原件 `_proj_10g/notes/P7B_GATE2.md`）

- **PCS/PMA 层（10GBASE-R, 802.3 clause 49）✅ 合规**：真网卡把链路锁上了（`Link detected: yes` +
  `Speed: 10000Mb/s` + carrier 成立）；`Δbytes/Δpackets = **248.000000**`（两档都是）；
  累计字节数与网卡 `port_rx_bytes` **逐字节相等**（1,020,633,510 帧）；速率 **≈9.58 Gbps**（自算）；
  **反向**：板侧对网卡发来的流 `block_lock` 恒 1、`framing_err/bad_code/fifo_error` 恒 0、无 `/E/`；
  关/开发射 ⇒ 链路精确掉/起。
- **帧格式 / FCS（802.3 clause 3.2.9）❌ 不合规**：1,020,633,510 帧**全部**被网卡计入 `port_rx_bad`、
  `port_rx_good = 0`、`rx_eth_crc_err ≈ 100%`。**根因在厂商 example 的 CRC 通路**（覆盖 252 B vs 实际 244 B，
  RTL 推导），**不在 PCS**。
- ⚠️ **由此一条限定**：**闸 1 的「零错」是自洽、不是合规** —— 它的监视器与发生器同为厂商件，同错即自洽。
- ⚠️ **厂商 example 的 FCS 缺陷未修（不要照抄那个例程）**；官方核 RTL **全加密**（读不到实现）。

### 🚧 进行中 / 未完成

- ~~**产品级第一优先 = 10G 线速未达标**（app 发生器 **1 字节/拍** ⇒ 实测载荷 **1.248 Gbps** / 线上 **1.287 Gbps**
  = 线速的 **~12.5%**；⚠️ 闸 1 的 9,999.94 Mbps 与闸 2 的 NIC link **只证明链路/物理层能到 10G ——
  数据面端到端从未跑过线速**）~~ ⇒ ✅ **已于 2026-09-30 下午关闭（见上表「P7b-线速（RATE）」）**。
  ⚠️ **但它这一轮的 4 项未测不许当通过**（登记在 `_proj_10g/notes/P7B_RATE_RESULT.md` §9）：
  **RX 方向载荷逐字节** · **工具自报的"图案真失配"**（未采信也未否定）· **`N-b1`（`TX_GAP` 低速档，未做）** ·
  **`W9` 与线上差 8 B/帧的 RTL 定位**（§4 末，**未定位**）。
- **`C8` 仍 FAIL**：`pcs_vcc_cyc` **8 位饱和** ⇒ "在涨"结构性不可判；**判据一字未改、非设计缺陷**，正证据（非 0）成立。
- **4 项未测**：`F1-E4b`（RX 方向载荷逐字节 —— 本构建 app 是 UDP 版，**TCP 载荷没有消费者**）·
  `F1-E5` · `F1-E6`（负对照，本轮未做）· `F5b`（RTO/重传计数 —— `tx_stat_retx` **不在 51 字快照窗口内 ⇒ 结构性不可读**，要闭合得改观测面）。
- ~~`p4_rxclass` / `p4_rxclass_xk` 真回归未收口~~ ⇒ ✅ **已收口**（见下）。
- **21 个既存失败门 + 8 个哑门**未修：其中 **`p5c_rev_elab` 的哑门正在掩盖一个既存 elab 硬失败**
  （`udp_tx_cfg`/`udp_tx_frame` 不在该门的 RTLF 清单里）、**`p4indm_4gates` 用 cmd 语法写 .sh = 真空门残留**。
  ⚠️ **哑门不止 `unit_retx` / `unit_fifo` 两条**（全清单见 `_proj_10g/notes/P7B_REGRESSION.md` §5/§7）。
- **延迟有三个缺口**：**`L_PCS`（PCS/PHY 内部 —— 最大缺口）** / **fast path → app 队列（零读数）** /
  **`(c)→(d)` 两个 tap**（已接好、只缺一个真 IPv4/UDP 帧 + 对端 root）。另：`P7B_LATENCY.md` 的
  **样本代表性**待修好后复跑 A/B 确认（lane4 修复已使审计件 §B.3.1 的"不加拍"理由失效）。
- **厂商 example 的 FCS 缺陷不修**（覆盖 252 B vs 实际 244 B，多算 8 B = 前导字；**我们自己的 MAC 没有这个缺陷**）；
  **10 条 `Synth 8-11241` 全在厂商例程里、无功能影响**（3 条宽度天然一致 + 7 条死网）—— 但门的两个洞仍在
  （IP OOC run 日志里同族 28 条不在 grep 面内；bat 命中后不置退出码）。
- 闸 2 未闭合的部分：E3 / E4 只到「**部分**」（载荷内容没有独立抓包比对；反向逐字节 FCS 需要我们自己的 MAC）；
  规格的 **U1–U10 未核实清单**仍未核实。
- ~~其余 76 门未逐门重跑~~ ⇒ ✅ **已由全仓 136 门回归覆盖**（见上表 P7b-闸3）；厂商 example 那 10 条隐式网未修（预先存在，与本轮无关）。
- 1G 侧的未修项：**F-3**（MMCM 失锁/重锁 ⇒ DP 侧在帧中重启 ⇒ 丢/重一帧；三种接线实测都无解，
  收口方向见 `P6B_CDC_AUDIT.md` §A.3）；**F-1 的板级缺口**（`ovf_pulse/ovf_cnt` 未接进快照）。
- **P5d 剩余 4 条（非阻断）**：`scan_now` 饥饿（app 饱和发送时 close/abort 被推到数据流结束才发）/
  ackq 条目不带 seq / HLS 硬编码 48K 通告窗（C21）未改 / 3 槽耗尽后的新连接仍被静默丢弃（策略问题）。
- **P5e 板级观测缺口**：`udpapp_*` / `app_udp_stat_*` 计数没有消费者（只接 LED 或悬空）
  ⇒ PC→板方向（app RX 口）的板侧校验读数与**全部丢帧计数读不出来**（只有 TB 门覆盖）。
- 长时「慢路径失聪」探针（348 轮 / 96.3 分钟，含历史上高发的「配置后 20 秒」窗口）**未复现**；
  结论措辞只能是「**F4/F-2 修复之后该现象没有出现**」（样本量 1，不能写「证明已修好」）。

**下一步**（细节与前置条件见 `_proj_10g/notes/P7B_HANDOFF.md` §3）：
① **把这条 10G 路径接到真实业务**（本轮线速是在**演示图案 app** 上跑出来的；真实 TCP/UDP 业务在 10G 下的
端到端验收仍是空的）；② **支线 —— PCS/PHY 内部延迟**（最大延迟缺口；需第二轮构建开 `C_ADD_GT_CNTRL_STS_PORTS` +
从 `generate_target example` 抄 45 个 GT 控制输入；⚠️ 厂商例程里 `assign ctl_local_loopback = 1'b1` 是**死网**，照抄拿不到 GT 环回）；
③ **把延迟终点推到 app 队列**（对端机 root 现已具备）。

## 怎么跑

所有命令都在**本仓根**执行（本仓 = `udp_hls_10g`，它就是本工程的 git 仓库根）。
`board/` 与 `sim/` 下的 bat 都已**自定位**，所以用相对路径即可。

> ⚠️ **空门警示（全仓唯一一处；照抄任何命令之前先读这一段）**
>
> 本仓 2026-09-28 从 `D:\repo\ECO\udp_hls_10g` **整体拷贝**而来，而**那份拷贝源至今仍然活着**。
> 带 `D:\repo\ECO\udp_hls_10g\...` 绝对路径的旧命令是**空门/真空门**：跑起来编的是**另一个 checkout**、
> 日志写进**另一个仓**、然后 `exit 0`。全仓曾有多达 **243 个**这样的门（已修 340 个文件，并加了三层守卫）。
> ⇒ **跑门一律走现役入口 `sim/p4gates/run_matrix_p4dfix.bat`**（自定位 + `checkpaths`/`manifestcheck`/`scanlog`
> 守卫 + 修订指纹 + 每门独立工作目录），**不要再手抄单门 bat 的绝对路径**。
> 历史命令形态、就地警示文本与取证，见 `PORT_NOTES.md` 的「README 重写时移出的历史内容（2026-09-30）」节
> 与 P6b 收口 §⑤/§⑦。

### 构建与烧录（`board/`）

```bash
cmd //c 'board\run_build_p4.bat'          # 默认构建（echo 数据面）→ p4_prj
cmd //c 'board\run_program_p4.bat'        # JTAG 烧录（1 MHz）
cmd //c 'board\run_build_p5.bat'          # APP_MODE（app 接口）→ p5_prj
cmd //c 'board\run_program_p5.bat'
cmd //c 'board\run_timing_p5.bat'         # 快速时序迭代（synth+place，不 route/bitgen）
cmd //c 'board\run_build_p7b_ku5p.bat'    # 10G 前端（官方 PCS + 自写 64 位 MAC）；本脚本不烧板
```

两套 1G 工程独立，**位流互不覆盖**。

### 门矩阵

```bash
cmd //c 'sim\p4gates\run_matrix_p4dfix.bat'                     # P4 默认构建 16 门全跑（~25 min）
cmd //c 'sim\p4gates\run_matrix_p4dfix.bat' -only stallgate     # 只跑指定门（'+' 分隔多门）
bash sim/p4sim/run_matrix_p4dfix.sh -only stallgate             # git-bash 入口（自定位 shim）
```

- ⚠️ **从 git bash 调用时开关必须用短横线 `-only`**：MSYS 会把 `/only` 改写成
  `"C:/Program Files/Git/only"`。2026-09-29 起，这种被改写的开关由 runner **硬失败（exit 97）**，
  不再静默跑满 16 门（纯 cmd 窗口里 `/only` 仍可用）。
- 退出码：`0` 全过 / `1` 有门失败 / `2` 跑动期间源码被改（修订漂移 ⇒ 整轮作废）/ `97` 前置拒绝。
- ⚠️ **跑门 ≠ 判门**：16 门里 `unit_retx` / `unit_fifo` **无条件 exit 0**，要读它们的日志尾。
- **判据**：BURST OK + 载荷逐字节全等 + ECOMAX≤182（无合并巨帧）+ TRUNCS/HALFD 哨兵 +
  ACK 位置合法性（截断段/OOO/补缺口段）+ abort/eend=0。

**P4 矩阵各门**（`sim/p4sim/`，P6 类改动的固定回归门）：

| 门 | 命令 | 抓什么 |
|---|---|---|
| 门1 | `run_tb_p4_burst.bat 200` | 无注入基线 |
| 门2 | `TRUNC=100 TRUNCM=8 …` | 截断帧 |
| 门3 | `HALFDROP=100 HALFDROPK=990 …` | 半帧中止 |
| 门4 | `run_tb_p4_chain.bat` | 全链 |
| 门5 | `run_tb_p4_chain_stall.bat` | 死锁复现（P4d-fix）：复现板级 48KB 满窗 + RTO 重放期收到「已收全部数据」的高水位 ACK |
| 附加 | `TXDROP=50`（快速重传自愈）/ `gate-4096` / `dupstorm` / `pause-300k` / `PCACKOOB=1`（纯 ACK 窗口右沿语义，w6a 修复复现门）/ `conn1` 判据 | —— |
| 单元 | `retx_ram`（7 组含 latency=2cyc）/ `frame_fifo`（D=8192）/ `uart_dbg` | 单元 TB |

门5 的参数与两跑证据（`run_tb_p4_chain_stall.bat [N [BYTES [DELAY]]]`，默认 `200 49150 300`；
`BYTES/DELAY` 经 `pcstall.memh` 同源传入 TB 与 checker；证据 `sim/p4sim/stall_gate_*.log`）见
`PORT_NOTES.md` 的移出节。

**P5 / UDP app 门**（每门都能回答一个具体问题，一行一门）：

| 门 | 抓什么 |
|---|---|
| `sim/p5sim/run_tb_p5_app.bat` | 1MB 图案逐字节 |
| `sim/p5sim/run_tb_p5_wrapper.bat` | **wrapper APP_MODE 全链 —— 接线错误只有它能抓** |
| `sim/p5sim/run_tb_p5_status.bat` | 状态行 |
| `sim/p5sim/run_tb_p5_adv.bat <case>` | 对抗集 11 例（含 `accmgn` 接受裕度定价） |
| `sim/p5sim/run_tb_p5_app.bat close` | **P5c 关闭语义门**：恰一 FIN / FIN 丢失 RTO 重发 / abort→RST+fence / 同时关闭 / 超时（5 条判据 + 3 条负向对照） |
| `sim/p5sim/run_tb_p5_fc.bat` | P5b 定向单元门：池 / 右沿算术边界 / 4GB 回绕 / 事件撞车 |
| `sim/p5sim/run_tb_p5_flow.bat` | P5b 窗口闭环门：慢消费者 + 对端灌数据（逐拍占用/右沿/零重传） |
| `sim/p5close/run_tb_tcp_close.bat` | P5c 定向证伪门（G1 FIN 重推死锁 / G9 回卷洪水；修复前 FAIL、修复后 PASS） |
| `sim/p5d_multi/run_tb_p5_multi.bat main` | P5d 多连接门：3 连接并发大流量 + 可编程慢消费者 + 并发 close；判据 ①-⑨ = **122 checks / 0 FAIL** |
| `… multi neg_wq / neg_mgn / neg_mgn0` | 负对照：不分池 ⇒ ① FAIL / 裕度 4096 ⇒ ④ FAIL / 裕度 0 ⇒ ⑥⑦ FAIL（各自**期望 exit 1**） |
| `… multi known_idle_fifo` | 长只写后首读**逐字节守卫**（曾误判为 `frame_fifo` 预存缺陷，已证伪：实为 TB 激励的 0 延迟竞争） |
| `sim/p5d_d1/run_tb_p5d_d1.bat` | D1 单元门：abort 请求窗 `rst_req` + 残余 F 项 ESTAB 状态门 + 释放（6 条判据） |
| `sim/p5e_win/run_tb_p5e_win.bat` | 0 载荷 opener 窄窗门（pipe 残余字跨会话 ⇒ 逐字节图案零泄漏） |
| `sim/p5c_t3/run_tb_p5c_fence.bat` | abort fence 单元门 F1-F5（判据文本未改、激励按真链路补 `rst_req` 释放） |
| `sim/p5udp/run_tb_udp_split.bat` | P5e-T1 分流器单元门：分流 / 结构性不反压（`tready` 恒 1）/ 透传逐字保真 / 坏帧与半帧整帧丢弃 / 缓冲溢出整帧丢 |
| `sim/p5e_t2/run_tb_udp_tx_guard.bat` | P5e-T2 守卫单元门：peer 门 + `PLEN_MAX` 守卫（+ 内置负对照） |
| `sim/p5e_t2/run_tb_p5e_t2_wrapper.bat` | P5e-T2 **真 wrapper 全链**（含隐式网检查：`Synth 8-11241` / `VRFC 10-3091] actual bit length 1 differs from formal bit length` / `VRFC 10-2989`；⚠️ 裸 `10-3091` 不行 —— 见 `CLAUDE.md` 坑 24） |
| `sim/p5e_udp/run_tb_app_udp.bat <case>` | P5e-T4 UDP 演示 app：`pos` 正例 EXIT=0；负对照 `splitoff`/`portout`/`badcrc`/`nopeer` 各 EXIT=0 且正向判据不成立；`neglearn` **期望 exit 1** = 判别力实证 |
| `sim/p5e_udp/run_tb_p5e_udp_wrapper.bat` | P5e-T5 真 wrapper 全链：真 GMII 注入 + 内部 GMII 解码 + `+NOUDP` 零帧对照 + DRC |
| `bash sim/p5e_udp/run_regress.sh` | P5e 一键回归 **49 门**，唯一非零 = `t4_neglearn`（期望值） |

**10G 门**：

- 单元门 `_proj_10g/p7b_mac/`：干净件 **391 checks / 0 fail**（lane4 修复后 +54 条）；
  变异 **23 条**（`scripts/mutate_gate.py`，含本轮新增 `M12..M17`；**2 条等价如实报"没抓到"**）。
- 真 wrapper 全链门：`cmd //c '_proj_10g\p7b_chain\sim\run_tb_p7b_chain.bat'` — **106 checks / 0 fail**
  （覆盖面补齐：lane4 注入 + 逐字节 + TERM 六元组 6/6；**反例**：换回修复前 RTL ⇒ 106 / **12** fail，且 12 条全在新族、既有 80 条一条不红）。
- wrapper app 分流门：`cmd //c '_proj_10g\p7b_appsplit\sim\run_tb_p7b_appsplit.bat'` — **26 checks / 0 fail**（lane0 13 + lane4 13）。
  ⚠️ 上述全链门里 PCS 那个 socket 放的是 `board/p7b_pcs_stub.v`（端口表与真核逐一相同）；
  **真核的证据在闸 1 / 闸 2 / P7a / 闸 4（板级），不在这些门里**。

### 板级测试工具（`tools/`）

| 工具 | 用途 |
|---|---|
| `pc_tcp_rate_test.py [MB]` | TCP echo 吞吐（双线程，稳态 10-90% 速率） |
| `capture_rate_test.ps1 [MB]` | tshark 抓包 + 怪帧/重传统计 |
| `board_diag18_test.py [秒]` | UART 快照 + 并行抓包（⚠️ 脚本里的 **COM8 已过时**） |
| `board_vlan_test.py` | **P4d 板级 VLAN fast path 验收**（scapy 注入带 tag 段 + 回显判定；串口用 **COM9**，与 `board_p5b_check.py` 同） |
| `pc_p5b_win_test.py [--bytes 4194304]` | **P5b/P5c app RX 方向板级验收**：PC 全速灌图案（板侧校验器消费 ~0.89 字节/拍 ⇒ 必然积压 ⇒ 触发窗口收缩/wu 重开）；图案生成**先于 connect** |
| `board_p5b_check.py [--port COM9] [--expect-rx N]` | 读板侧 P5B1 状态行并自动判据（RX/MM/AD/DL/OC）；`WU`/`PX`/`FI`/`RS` 只作诊断，口径见脚本头注释 |
| `pc_p5d_reconn_test.py [--rounds 5] [--gap 0.6] [--bytes 32768]` | **P5d D6 同四元组重连板级验收**：固定本地源端口连续轮 [connect → 灌 32KB → drain → close]，每轮读 P5B1 状态行；判据 = 全部轮次建连 + 传输成功（槽泄漏未修时第 4 轮起（`MAX_TCP_CONN=3`）connect 失败/超时）。**必须用窄轮间隔**：默认 `4.0` 的轮周期（~5.5s）晚于 D6 的 RTO 自释放窗口 ⇒ 修前修后不可分 |
| `tools/cpp_peer/peer.exe` | C++ 合成对端（绕过内核栈）——**速率类测试用它，不用 Python** |

## 已建成的能力

### 数据面（fast path，纯 RTL，每级 II=1）

- 64bit 左对齐字流 MAC（`mac_rx_64` / `mac_tx_64`），FCS 校验/剥离（CRC 残留 **0xDEBB20E3**）
- TCP 数据段解析 + CAM 四元组匹配 + 16 连接 TCB（rcv/snd 状态机 + 窗口门控）
- 逐帧判定的 echo 管道（`tcp_rx → tcp_echo → tcp_tx_frame`，`frame_fifo` 8192 字坏帧回卷）
- **快速重传自愈**：3×dup-ACK 触发回卷重放 + RTO 兜底扫描器（`retx_ram` 每连接 64KB ring，
  读延迟 2 拍流水，窗口门控 `in_flight < min(peer_wnd, RING_CAP=0xBFFE)`，32 位回绕安全比较）
- **窗口**：通告 48KB（`0xC000`，免 WS）；纯 ACK 帧 seq 在窗口内（含右沿，RFC 零长段）即接受并处理其
  ACK/窗口字段 —— P4c 的 **w6a 修复**（板级 ACK-early 暴跌根因，顺带扩大 dup-ACK 快速重传检测覆盖）
- **板级吞吐（实测）**：C++ 合成对端 **1GB @ 891.5 Mbps / 256MB @ 890.4 Mbps**（逐字节零失配、零 RTO，
  双向近 1G 线速）；实测瓶颈 = 板侧 48KB 通告窗 × RTT（428µs，板子纯 ACK 仅 0.9%、全靠 echo 捎带）。
  旧记的「echo 架构 125Mbps 铁律」**已证伪**（那是 Python 内核栈 + 逐包 pcap 的工具链产物）。

### 慢路径（HLS 协议栈 IP，`ap_ctrl_none` @125MHz）

- ARP / ICMP echo / IGMP / UDP echo (8080) / TCP SYN-FIN-RST 握手（服务端被动打开）+
  DHCP DISCOVER / UDP HELLO 周期自发行文
- HLS cfg 通道（wscale/窗口）→ CAM/TCB；看门狗（饥饿超时 **64 拍**复位脉冲；**P6b 构建 (DP_156MHZ) 下是 80 拍**
  —— 同一墙钟 512ns，见 `P6B_SPEC` §5.1）防 HLS 死锁

### 协议功能全景（P4c 收官）

| 协议 | 能力 | 路径 |
|---|---|---|
| ARP | 应答 (192.168.100.2)、免静态 ARP 学对端身份 | HLS 慢路径 |
| ICMP | echo 应答 (ping 通) | HLS |
| IGMP | 接收处理 (组播入口) | HLS |
| UDP | **接收+回显** (8080) + **主动发送** (周期 UDP HELLO 广播) | HLS |
| DHCP | DISCOVER 自发行文 (主动 UDP 客户端行为) | HLS |
| TCP | 服务端被动握手 (SYN→SYN+ACK→ESTABLISHED / FIN→FIN+ACK→LAST_ACK / RST) + **数据 echo** | 握手 HLS；数据 fast path |

- **TCP 角色**：服务端（被动打开）+ **客户端（主动 connect，P4d）** —— `ACTIVE_CONNECT` 宏上电自动连
  固定 IP:port（ARP 前置 + `T_SYN_SENT` 状态 + SYN 限次重传，与被动监听共存）；端口 8080；16 连接 CAM/TCB
- **VLAN**：fast path 单层 802.1Q/1ad 剥离（P4d：`vlan_strip` shim —— `mac_rx` 后剥 TPID+TCI 重对齐，
  下游零改动；QinQ 剥一层后自然退化慢路径）；慢路径 HLS 支持多层 802.1Q/1ad；TX 恒无 tag
  （接 trunk 时回包不带 tag —— 已知语义）
- **流控**：TX 窗口门控 `in_flight < min(peer_wnd, RING_CAP)`；RX 通告 48KB；seq 窗口语义
  （边界接受 / 窗口内 OOO 丢数据回 dup-ACK / 超窗静默丢 / 零长 ACK 含右沿）；**无拥塞控制**（设计决策）
- **重传**：3×dup-ACK 整窗口回卷重放 + RTO 兜底（16 连接轮扫，双丢自愈）；无 SACK/NewReno（echo 场景够用）
- **鲁棒性三层防御**：① 截断帧闭合（线上帧短于 IP 承诺载荷时按真实字节收下转发，缺口由 PC 重传自愈）
  ② 半帧中止防御（上游无 tlast 帧流中断时合成 ferr 尾拍闭合 echo 半帧，杜绝与后续帧合并成巨帧）
  ③ 对端风暴免疫（PC 网卡驱动重启引发的 dup-ACK/重传风暴全消化）

### 应用接口

- **P5a `APP_MODE`**：应用经 **AXIS 流**收/发 TCP 载荷（`app_tx_*` 一帧 = 一个 TCP 段 ≤1460B，`tid`=conn_id；
  `app_rx_*` 零拷贝直出接收缓冲 + `len` 边带），经**寄存器面**拿连接事件（CONN_UP/DOWN + peer ip/port/mac）、
  下发 close（发 FIN）/ abort（发 RST）、读每连接状态与计数。默认构建（宏未定义）仍为 echo 语义。
- **P5b 应用 RX 流控闭环**：每连接信用配额 `winq` + 单调右沿 `redge`，通告窗口 = `winq − occ`；
  慢消费者零窗后由 **`wu` ACK** 主动重开；接受界 = 通告界 + `ACC_MARGIN(4096)`，拒收段回 ACK
  （RFC 793）⇒ 慢消费者背压**零丢字节**。
- **P5c 关闭语义**：FIN 重推不再只有一次机会（修 **G1** 死锁）、`ring_delta` 下溢洪水修复（**G9**）、
  abort 后 TX fence + `state=0` 写 + 配额归还、**关闭超时 = 连续 400ms 对端无进展**
  （活性判据 = 该槽 `rcv_nxt` 未推进）。
- **P5d 多连接加固**：信用分池（可写寄存器 `app_ctrl` 地址 `0x0C` = `WIN_POOL/N`，复位默认 `0xC000`，
  **必须建连之前设小** —— 窗口一旦通告不可撤销）、动态接受裕度 `min(4096, 10550/N)`（下界钳 3328）、
  TX 双门硬化（补 `rst_req` + 「必须 ESTAB」）、0 载荷 opener（跨会话零载荷泄漏，代价 1 拍/帧）、
  HLS 槽释放（同四元组重连 ~1.0s → **15-23ms**）。
- **P5e UDP app 接口**：RX 侧 `rx_classify.slow → udp_split`（帧级缓冲 + **结构性不反压** + 坏 FCS 整帧丢 +
  长度不符整帧回卷 ⇒ **永不半帧**）；TX 侧 `udp_tx_cfg`（**learn-on-RX** peer 表）→ `udp_tx_frame`
  （长度守卫 ≤1500）→ 两级 arb（**TCP fast > UDP app > HLS**）；演示 app `app_udp_pattern`；
  **默认不激活**（cfg 全哨兵 + peer 表复位为空 ⇒ 零新增帧）⇒ 板上行为与 P5 逐位一致。

### 板级诊断接口（长期保留）

- **UART 9600-8N1**（板载 CH340E —— **枚举为 COM9**，换 USB 口会变）全精度快照：TCB/窗口/FSM/
  三站词计数/tlast 三计数/截断计数 (TRU)/慢路径存活字段 (SC/SD/SF/SP/SV/HR)/线缆帧长 (WL) +
  64 拍 TR/RXT 轨迹环 + FIFO tlast 位图 (TL)，boot 自检后每 5s 一行（见 `board/uart_dbg.v` 头注释）。
  ⚠️ **该 UART 诊断行在 KU5P 上不可观测**（本板无 UART），且它在 DP 域有 **48 位未同步穿越**
  （`u_dbg_line`）。历史与理由见 `PORT_NOTES.md` P6b 收口 §⑧。
- **LED**：boot 自检 3 闪 + 门控/锁存/满标志实时探针。
- **PCIe/XDMA 观测通道（P6e）**：user BAR 寄存器窗口 —— 无 UART 板上**唯一的观测手段**，
  36 字快照表见 `P6E_OBS.md`（`BUILD_ID=6`）。

## 资源与时序基线

**现役两份基线**（1G 数据面 = P6b 验收位流；10G = 最新 P7b 构建。历史基线见「归档」）：

| 基线 | 适用 | 时序（routed） | 资源 | 出处 |
|---|---|---|---|---|
| ⭐ **P7b 线速构建（RATE，最新）**（= 合并构建 + **两刀**：`P7B_10G` 内的 8 路并行发生器 + **`UDP_TX_OVL`** 乒乓组帧器） | KU5P；官方 PCS + 自写 64 位 MAC + 数据面（**10G 线速达标的位流**，sha256 `4eeb0f5f…3133`） | **WNS +0.136 / WHS +0.010 / 三类失败端点全 0**（全部 intra/inter/other path group **逐组 0 失败**）；两处重点：`txoutclk_out[0]_3` **+0.765 → +0.141**（路径属 `u_mac_tx` 的 CRC/padrem 局部簇、**无本轮新逻辑** ⇒ 布局漂移）、两个 256×73 bank **都落 LUTRAM** | LUT 71,727 (33.06%) · FF 69,287 (15.97%) · CARRY8 1410 · **BRAM tile 348 (72.50%，逐数不变)** · LUT as Memory 6654 (+336) · URAM 0 · DSP 4 · Bonded IOB 10 · GTYE4 6/16 | `board/p7b_ku5p_{timing,util}.rpt`（mtime 17:50）/ `_proj_10g/notes/P7B_RATE_BUILD.md` |
| **P7b 10G 变体（闸 4 验收构建）**（**合并构建** = lane4 修复 + TX 时序修复后） | KU5P；官方 PCS + 自写 64 位 MAC + 数据面 | **WNS +0.128 / WHS +0.010 / 三类失败端点全 0**（11 个 intra clock group + 3 条 inter + 3 条 async **逐组 0 失败**） | LUT 70,095 (32.31%) · FF 68,471 (15.78%) · CARRY8 1413 · **BRAM tile 348 (72.50%)** · URAM 0 · DSP 4 · Bonded IOB 10 · BUFGCE 5 · GTYE4 6/16 | `board/p7b_ku5p_timing.rpt` / `board/p7b_ku5p_util.rpt` / `_proj_10g/notes/P7B_BUILD_FINAL.md`（位流 sha256 `0e1c8088…b557`） |
| **P6b 1G 数据面** | KU5P；1G 验收位流（双时钟域） | **WNS +0.168 / WHS +0.010 / WPWS 0.000**，**0 失败端点** | —— | `P6B_ACCEPT.md` §1.1/§1.2（位流 sha256 `c1770086…48ca`，`BUILD_ID=6`） |

- ⚠️ **P7b 的 clock group 名后缀逐轮漂移**（裸名/`_1` ↔ `_2`/`_3`，根因已定位到工具侧 `opt_design` 的
  clock-buffer 插入：`BUFGCE` 6/4/5 而 BRAM/CARRY8/GT 逐数相同）⇒ **跨轮对比必须按端点指纹
  （3429 / 817 / 34 / ~2376 / ~9600）对齐，不能按名字**。
- ⚠️ **P7b 的三条构建硬门是 banner 不是退出码**（`run_build_p7b_ku5p.bat` 命中后只打一行、
  退出码仍由"位流是否存在"决定），且**看不到 IP 的 OOC run 日志**（那里有厂商同族的 28 条 `8-11241`）
  ⇒ **别把"bat 没报错"当"门通过了"**。
- ⚠️ **hold 余量一直很薄**（+0.010 ~ +0.051）：往这三族加逻辑会**先在这里失败** ——
  `u_app_ctrl/c_snd_una_reg[0][15] → u_app_status/sn_ua_reg[15]`（P5e 口径 +0.051，诊断状态行的跨模块
  短路径，纯布线主导）、`retx wa_o_r_reg → mem ADDRARDADDR`（0.056）、`mac_tx fifo wptr → RAMB WADR`（0.057）。
- 10G 侧另一条读数：**官方 PCS 单独**在 -1 上收敛，**WNS +2.337 / WHS +0.019 / 0 失败端点**（≈40% 余量；
  `_proj_10g/notes/P7B_XXV_OFFICIAL.md`）。
- ⚠️ 私有 route 门（`sim/p5e_udp/route_check.tcl`）报的 +0.123 属**流程差异**（手动 opt/place/route、
  未 `launch_runs` ⇒ strategy 未生效且缺 `phys_opt_design`），**不是布局方差**；绝对值以 `launch_runs` 全流程为准。

## 归档（历史阶段）

> 本节**只放索引**，正文不搬进来。

| 历史内容 | 在哪 |
|---|---|
| **2026-09-21 的旧状态块**、里程碑表（P0–P5e 逐项）、P5b/P5c/P5d/P5e 一句话结论、应用接口长条目、P5e 综合结果表与 cell 探针、**板级结果**全节、遗留 / P6 交接记录、历史「空门形态」命令块 | **`PORT_NOTES.md` 的「README 重写时移出的历史内容（2026-09-30）」节**（本次重写从本文件逐条移出，原文保留） |
| P6b 一页式总览（目标 / 改了什么 / 关键数字 / 证据地图 / 已知限制） | `P6B_SUMMARY.md`；验收原件 `P6B_ACCEPT.md` |
| 跨域审计（F-1/F-2/F-3）、对抗审查（F1–F13）、集成与「空门」核实 | `P6B_CDC_AUDIT.md` / `P6B_REVIEW.md` / `P6B_INTEGRATION_REVIEW.md` |
| P6a（K7 → KU5P 移植：`frame_fifo` 的 RAMB36E2 + RGMII 前端三条实证 + 闸 G 时序基线） | `PORT_NOTES.md` 的 "2026-09-28 P6a-T1/T2" 节 |
| **P6 交接记录（2026-09-20/21 的调研）**：定性一句「**10G 的技术前提不是『提时钟』而是『换前端 + 重收敛』**」（`mac_rx_64`/`mac_tx_64` 是字节串行 GMII 模块 ⇒ 10G 下**必须整体替换**；「流水线不改」对**中间各级**成立，**对 MAC 边界不成立**）；要做的 6 块 / 要准备的东西 / 前置实验 K1–K6 / 三个决策点 / 两个阻断级风险 / 阶段与工期 / 六条更正 | `PORT_NOTES.md` 末节 "P6 交接记录"（重启 10G 从那里读，**不要重新调研**）+ 本文移出节（含 2026-09-29 的复核更正） |
| P7a 10G PHY 板级验收（含四条新教训） | `P7A_RESULT.md` + `P7A_SPEC.md` |
| P7b 路线与 license 分叉 / 接口冻结 / 闸序 / 判据表 / 未覆盖清单 | `P7B_SPEC.md` |
| P7b 闸 1、闸 2、MAC 设计·审查·门修·时序、`rx_classify` 审计与设计、隐式网修复与铺开、字节序与对端现状 | `_proj_10g/notes/P7B_*.md` |
| **P7b 闸 3/闸 4 收口 + 两个真缺陷修复**（lane4 根因与修法 / 时序回归与修复 / 合并构建 / 闸 4 三轮与判据收口 / 136 门回归 / 链级门 80→106 / 历史证据污染审计 / 厂商两笔账 / 延迟两缺口 / **下一轮交接**） | `_proj_10g/notes/P7B_{UDP_APP_ROOTCAUSE,UDP_DIAG2,LANEFIX,TIMING_RERUN,MAC_TIMING_FIX,BUILD_FINAL,GATE4_ACCEPT,
GATE4_ACCEPT2,GATE4_ACCEPT3,GATE4_CRITERIA_CLOSEOUT,GATE4_PLAN,GATE4_TOOLING,GATE4_TOOLING_FIX2,REGRESSION,GATE_HARNESS_FIX,CHAIN_COVERAGE,EVIDENCE_AUDIT,VENDOR_EXAMPLE_DEFECTS,LATENCY_GAPS,HANDOFF}.md` |
| 里程碑日志与教训（P6b 收口 / P7a / P7b 等各节） | `PORT_NOTES.md` 对应各节 |
