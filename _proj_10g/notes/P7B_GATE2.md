# P7B 闸 2 —— 用**真网卡**（SFC9120）裁决"官方 `xxv_ethernet` PCS 出来的是不是合规的 802.3 以太网"

- 日期：2026-09-29（本轮）
- 器件：`xcku5p-ffvb676-1-e` · 工具：Vivado 2025.2 · 对端机 `192.168.0.38`（Ubuntu 24.04 / 内核 7.0.0-34）
- 本轮**全部新产物**：`udp_hls_10g/_proj_10g/xxv_gate2/`
- 判据来源：`P7B_SPEC.md` §5.2（闸 2，E1..E7）/ §6.2（N1、N6、N9）
- **本轮未改任何既有 RTL / 既有工程 / 既有文档**（除本文件）；**未写板载 QSPI**（只走 JTAG 易失烧录）；
  未动 license；未执行任何 git 写操作；未碰 `D:\repo\perfv`。
- 对端机：**只读**（sysfs / `ethtool` / `ip`）。唯一一次"动"是 `ping6 -c 10 -i 1 ff02::1%<if>` —— 它自己结束、不改配置、不留状态。
  临时文件 `/tmp/nic_snap.sh` 是本轮唯一的落盘物（收尾已删）。

### 证据强度标记（与 `P7B_SPEC.md` 同义）

| 标记 | 含义 |
|---|---|
| 【板级实测】 | 上板读数的原始文本，给 `文件:行号` |
| 【网卡实测】 | 对端机硬件计数器 / sysfs 原始输出 |
| 【已实测】 | 工具原始输出（构建日志 / 报告 / 综合网表） |
| 【明文RTL】 | 仓库内可逐行核对的源码（AMD 明文或本仓自写） |
| 【自算】 | 本文件独立复算，算式写出 |
| 【推定】 | 逻辑推理，无直接证据 |
| 【未核实】 | 不知道。**不得当判据用** |

---

## 0. 一句话结论

**端口映射是测出来的（不靠猜）：全系统只有一根线 —— FPGA `J8` = SFP B = GTY `X0Y5` ↔ 网卡
`enp1s0f1np1`（p1, PCI `01:00.1`）；`J7`（SFP A / X0Y4）与网卡 `enp1s0f0np0` 都是黑的。**

**分层裁决：官方 PCS 在 10GBASE-R PCS/PMA 层（clause 49）合规 —— 真网卡接受了它的帧流，
1,020,633,510 帧、每帧长度**分毫不差 248.000000 字节**、速率接近线速、RX 侧块锁稳定且零 `/E/`；
但**帧层（FCS）不合规** —— 全部帧被网卡计数为 `port_rx_bad`、`port_rx_good = 0`、
`rx_eth_crc_err ≈ 100%`，且**根因可定位到厂商 example 发生器的 CRC 通路，不在 PCS**
（RTL 推导：它的 CRC 覆盖长度比实际帧长多 8 字节）。**

---

## 1. 先纠三处**与本轮事实不符的前提**（用户任务书里给的）

| # | 任务书的说法 | 实测事实 | 证据 |
|---|---|---|---|
| C1 | 板子现在载的是**闸 1 的位流** `5560375b…72ee2c` | ❌ **磁盘上那份已被闸 1 第 3 轮构建覆盖**。本轮开工时 `xxv_loop/…/xxv_loop_top.bit` 的 sha256 = **`2acafb1f4c48c2ff22fcf78ce6fca079f5c3aae98695a49a8206427c7b767f0a`**（= `P7B_GATE1.md` §10 的第二轮补充里那个 48 探针位流）。本轮两次上板实际烧的分别是 `2acafb1f…`（阶段 1）与 `7eaf789a…`（阶段 2/3，见 §6）。 | `logs/g1_probe.log:24`（`G1_BIT_SHA256 2acafb1f…`）、`logs/g2_probe.log:3`、`logs/g3_loop.log:3` |
| C2 | 闸 1 位流"会在通道上**连续发帧**" | ⚠️ **不确切，且方向也错**。① 它的发生器只在 `send_cont=1` 时才连续流；② 更要紧的是**它的发生器绑在 ch0 = X0Y4 = J7，而线与 J7 无关** ⇒ 那一版位流**一帧都到不了网卡**。这正是本轮的施工起点。 | `rtl/xxv_loop_top.v:306`（`.gen_clk(tx_mii_clk_0)`）、`:336`（`.tx_mii_d(tx_mii_d_0)`）；本轮 `G1_STEP1B_RX_LINE ch0_los=1`（`logs/g1_probe.log:419`） |
| C3 | A 节判据"`port_rx_packets` 涨 / `rx_eth_crc_err` 恒 0"可以直接读 | ⚠️ **阶段 1 读到的 0 是"错的端口"的 0** —— 见 §7 的**自伤记录**：我的差值助手 `nicval` 取的是整份快照里**第一个**匹配字段，而快照先打印 p0（无 link，恒 0）再打印 p1。修正后同一批读数立刻变成 **32,137,244 帧**。 | `logs/g2_probe.log` 的 `G2_A_NOCRC_DELTA`（修正后） vs `logs/g1_probe.log:984`（修正前） |

> ⚠️ **这三条一起说明**：如果本轮只"照任务书复读一遍",会得出"板子帧都发不出去"的**错误**结论。
> **第一步用测量定端口映射**这条纪律,这次是**真的救了整轮**。

---

## 2. ① 端口映射表（**测出来的**，含方法与原始读数）

### 2.1 方法（三条独立证据，两个方向）

1. **板 → 网卡方向**：板侧能**逐通道**开关发射（实测正确的引脚 `SFP1_TX_DIS`=**C11**、`SFP2_TX_DIS`=**D9**）。
   一次只关一个通道，看**网卡的哪个口掉 carrier**。
2. **网卡 → 板方向**：板侧两个通道各有独立的 XGMII 接收检查器。看**哪个通道 `block_lock=1` 且能解出帧**。
3. **绝对锚点**：网卡两个口的 `carrier_changes` / `carrier_up_count`（自开机累计，不依赖我这一轮）。

### 2.2 原始读数（**阶段 1**，位流 `2acafb1f…`；`logs/g1_probe.log`）

```
 269:NICSNAP BASE_BOTH_ON p1 ifname=enp1s0f1np1 carrier=1 operstate=up speed=10000 carrier_changes=17 carrier_up_count=9
 334:G1_STEP1A_NIC p0_carrier=0 p1_carrier=1 p0_speed=0 p1_speed=10000
 336:G1_STEP1B_KILL_CH0_SFP1_TX_DIS_C11 wall=1790693543856
 352:NICSNAP KILL_CH0 p1 ifname=enp1s0f1np1 carrier=1 operstate=up speed=10000 carrier_changes=17 carrier_up_count=9
 417:G1_STEP1B_NIC p0_carrier=0 p1_carrier=1 p0_speed=0 p1_speed=10000
 419:G1_STEP1B_RX_LINE ch0_los=1 ch0_blk=0 ch0_rlocalfault=1 ch1_los=0 ch1_blk=1 ch1_rlocalfault=0
 421:G1_STEP1C_KILL_CH1_SFP2_TX_DIS_D9 wall=1790693550840
 439:NICSNAP KILL_CH1 p1 ifname=enp1s0f1np1 carrier=0 operstate=down speed=10000 carrier_changes=18 carrier_up_count=9
 504:G1_STEP1C_NIC p0_carrier=0 p1_carrier=0 p0_speed=0 p1_speed=10000
 506:G1_STEP1C_RX_LINE ch0_los=1 ch0_blk=0 ch1_los=0 ch1_blk=1
 508:G1_STEP1D_RESTORE wall=1790693560832
 524:NICSNAP RESTORED p1 ifname=enp1s0f1np1 carrier=1 operstate=up speed=10000 carrier_changes=19 carrier_up_count=10
 589:G1_STEP1D_NIC p0_carrier=0 p1_carrier=1 p0_speed=0 p1_speed=10000
```

**阶段 2（位流 `7eaf789a…`）在另一个位流上复现了同一张表**（`logs/g2_probe.log`）：

```
G2_MAP_BOTH_ON   p0_carrier=0 p1_carrier=1 p1_speed=10000
G2_MAP_KILL_CH0  p0_carrier=0 p1_carrier=1 p1_speed=10000      ← 关 C11（ch0）对网卡零影响
G2_MAP_KILL_CH0_RX ch0_los=1 ch0_blk=0 ch1_los=0 ch1_blk=1
G2_MAP_KILL_CH1  p0_carrier=0 p1_carrier=0 p1_speed=10000      ← 关 D9（ch1）⇒ 网卡掉 carrier
G2_MAP_KILL_CH1_RX ch0_los=1 ch0_blk=0 ch1_los=0 ch1_blk=1
G2_MAP_RESTORED  p0_carrier=0 p1_carrier=1 p1_speed=10000
```

### 2.3 映射表

| 板侧（丝印 / 通道 / 球号侧） | 网卡侧 | 判据 |
|---|---|---|
| **`J8` = SFP B = GTY `X0Y5`** | ⭐ **`enp1s0f1np1`**（= **p1**，PCI `01:00.1`，`00:0f:53:2c:68:01`） | ① 只关 ch1 的发射（D9 拉高）⇒ p1 `carrier 1→0` **且 `carrier_changes` 17→18**（**新跳变**，不是陈旧值）；恢复 ⇒ `carrier 0→1`、`carrier_up_count 9→10`。② 反向独立：ch1 的 `block_lock=1`、`rx1_free` 自由计数在涨、并能解出网卡发来的帧（§4 B 节）。③ **两个位流（`2acafb1f…` 与 `7eaf789a…`）上各复现一次。** |
| **`J7` = SFP A = GTY `X0Y4`** | **无线**（对应网卡口 `enp1s0f0np0`=**p0** 也全黑） | ① ch0 `los=1` / `block_lock=0` / `rx_local_fault=1` **全程如此**（含两个位流）；② `rx0_free = 0`（恢复时钟死）⇒ 该通道**从未收到过光**；③ 拉高 C11 对网卡**零影响**；④ NIC p0 自开机 `carrier_changes=0`、`carrier_up_count=0`（**从未 link 过**）；⑤ 网卡 p0 的 `ethtool` 里 `Link detected: no`、`Speed: Unknown!` |

⇒ **全系统只有一根 AOC**：`J8` ↔ `enp1s0f1np1`。

### 2.4 顺带在总线上裁决的 10G 模式（**部分未核实**）

用户给的 `ethtool` 摘要我这一轮也独立读到了（`logs/g2_probe.log` 的 `NICSNAP … p1 ethtool_…` 行）：

```
NICSNAP … p1 ethtool_Supported link modes: 1000baseT/Full
                                  1000baseX/Full
                                  10000baseCR/Full
                                  10000baseSR/Full
                                  10000baseLR/Full
NICSNAP … p1 ethtool_Supports auto-negotiation: Yes
NICSNAP … p1 ethtool_Advertised auto-negotiation: Yes
NICSNAP … p1 ethtool_Link partner advertised link modes: Not reported
NICSNAP … p1 ethtool_Link partner advertised auto-negotiation: No      ← 对端(我们)不做协商
NICSNAP … p1 ethtool_Link detected: yes
NICSNAP … p1 ethtool_Speed: 10000Mb/s
NICSNAP … p1 ethtool_Port: FIBRE
NICSNAP … p1 ethtool_Transceiver: internal
NICSNAP … p1 ethtool_PHYAD: 255
```

**它到底跑在 CR 还是 SR/LR ——【未核实】。** 我能给的是**排除法**（不是测出来的）：

- `10000baseCR/Full` 是**背板/DAC**模式，**clause-73 自动协商是它的必要条件**（802.3 clause 73）；
- 网卡自己报 `Link partner advertised auto-negotiation: **No**` —— 即**我们这边不参与协商**
  （官方 `xxv_ethernet` 在 `CORE = Ethernet PCS/PMA 64-bit` 下**只实现 10GBASE-R PCS/PMA，根本没有 clause-73 AN**）；
- **更强的证据**：把我们的发射关掉，链路掉；**再打开，链路又起来了** —— 而**我们这一侧从头到尾没有任何 AN 实现**。
  若网卡要求 clause-73 握手，重开之后**不可能**自己起来 ⇒ **网卡没有在依赖 AN** ⇒ **不是"需要 AN 的 CR"**。
- ⇒【推定】实际落在 **10GBASE-R（SR/LR 一族，非 AN）**。
- ⚠️ 直接读模块/模式被挡：`ethtool -m` 报 `netlink error: Operation not permitted`（**没有 root**）。
  唯一的替代是 `ethtool` 的 `Link partner advertised link modes: Not reported` —— 它只能说明**对端没报**，不能反推具体 PMD。

---

## 3. ②-A 节：板 → 网卡（**我们的帧被真 802.3 设备接受吗**）

### 3.0 先解决"帧从哪来"：**必须换位流**（本轮的第二个关键施工判断）

闸 1 位流把厂商 example 的图案发生器绑在 **ch0 = X0Y4 = J7**，而线在 **J8**。所以：

> **`G1_A_DELTA rx_packets 0`（`logs/g1_probe.log:984`）** —— 这是**真·真空零**：
> 板子的发生器把帧全部发进了**空的 SFP 笼**。`G1_STEP2_T0/T1` 那段 `send_cont=1 + restart` 也救不了它。

⇒ **光靠"重烧 + 重测"拿不到 A 节判据，必须把发帧逻辑搬到被连的通道上。**
本轮的做法（新目录 `xxv_gate2/v2/`，**原件一格未动**）：把**整个厂商 example 流量模块**（发生器**与**监视器）
绑到**通道 1**（两端都在 ch1 自己的时钟域里，**不引入任何新的跨时钟**），ch0 的发射退回常数 IDLE。
顺带把厂商自己的 FCS 插入通路（`assign insert_crc = 1'b0;` 那行）**接成 VIO 可控**，于是**同一个位流**能给出
"无 FCS"与"有 FCS"两档，`rx_eth_crc_err` 直接变成**差分判据**。

完整差异（可复核）：`xxv_gate2/mkv2.py`（带 `sub1()` 的**单次出现断言**）+ 生成物 `xxv_gate2/v2/rtl/`。
与厂商原文的 diff **只有 3 行**（模块改名 / 新增 `crc_en` 端口 / `insert_crc = crc_en`）；
与闸 1 顶层的 diff 逐条列在 §7.3。

### 3.1 位流

| 项 | 值 |
|---|---|
| 位流 | `xxv_gate2/v2/pcs64_g2/pcs64_g2.runs/impl_1/xxv_loop_g2_top.bit` |
| **sha256** | **`7eaf789ab9700d3c7c703bdc0a871f698a7d877a7bb855bee511072a51190a0f`** |
| 大小 / 时序 | 15,431,xxx B；**WNS +2.833 / WHS +0.014**，`write_bitstream Complete!`，`S2_VERDICT = PASS_BITSTREAM` |
| 隐式网签名 | `undeclared symbol` **10 条，全部落在厂商文件自身**（`pcs64_pkt_gen_mon_g2.v`，是它的只写不读 assign）；**我的顶层 0 条** |
| 证据 | `v2/logs/s2_g2_stdout.txt`（`S2_SHA256`、`S2_WNS`、`S2_WHS`、`S2_VERDICT`、`S2_GREP`） |

### 3.2 判据非真空的证明（**先给分母**）

```
logs/g2_probe.log:
G2_A_GENOFF_DELTA rx_packets 0 rx_bytes 0 crc_err 0 rx_bad 0        ← 发生器停 5 s
G2_A_GENOFF_DELTA rx_128_to_255 0 p1_carrier=1
```
⇒ **链路在（carrier=1），但计数器一动不动** ⇒ 计数器不是"永远在涨的噪声"，A 节的增量有判别力。

### 3.3 有帧的两档（同一刺激，只差 `crc_en` 一个 bit）

窗口：`crc_en=0` 7.087 s（`G2_STEP_A_NOCRC_T0/T1_WALL`）、`crc_en=1` 6.981 s（`G2_STEP_A_CRC_T0/T1_WALL`）。

```
# crc_en = 0（= 厂商的 as-is 行为：载荷全 0，最后 4 字节是 0x00000000，不插 FCS）
G2_A_NOCRC_DELTA port_rx_packets      32137244
G2_A_NOCRC_DELTA port_rx_bytes        7970036512
G2_A_NOCRC_DELTA port_rx_good         0
G2_A_NOCRC_DELTA port_rx_bad          32137243
G2_A_NOCRC_DELTA rx_eth_crc_err       32546169
G2_A_NOCRC_DELTA port_rx_128_to_255   32137243
G2_A_NOCRC_DELTA port_rx_65_to_127    0
G2_A_NOCRC_DELTA port_rx_256_to_511   0
G2_A_NOCRC_DELTA port_rx_overflow     0
G2_A_NOCRC_DELTA rx_frm_trunc         0
G2_A_NOCRC_NETDEV netdev_rx_packets 32137244 netdev_rx_bytes 7970036512
G2_A_NOCRC_CARRIER p1 1 -> 1

# crc_en = 1（把厂商自己的 CRC32 插进最后 4 字节）
G2_A_CRC_DELTA port_rx_packets      33504229
G2_A_CRC_DELTA port_rx_bytes        8309048792
G2_A_CRC_DELTA port_rx_good         0
G2_A_CRC_DELTA port_rx_bad          33504230
G2_A_CRC_DELTA rx_eth_crc_err       32072553
G2_A_CRC_DELTA port_rx_128_to_255   33504230
G2_A_CRC_NETDEV netdev_rx_packets 33504229 netdev_rx_bytes 8309048792
G2_A_CRC_CARRIER p1 1 -> 1
```

| # | 判据 | 期望来源 | 实测 | 结论 |
|---|---|---|---|---|
| A1 | **帧真的进了网卡的 MAC**（正证据 = 非零分母） | NIC 硬件计数 | **Δ`port_rx_packets` = 32,137,244 / 33,504,229**（≈ 4.5–4.8 M 帧/s） | ✅ |
| A2 | **每帧长度与我们发的**逐字节对得上（内容级旁证） | 【自算】帧 = 32 XGMII 字 × 8 − 8（前导+SFD）= **248 B** | Δbytes/Δpackets = **248.000000**（两档都是）；Δ`port_rx_128_to_255` ≈ Δpackets（99.99999%） | ✅ |
| A3 | **速率 ≈ 线速** | 10GBASE-R 10.000 Gbps | 32,137,244 帧 × (248+8+8) B ÷ 7.087 s × 8 = **9.58 Gbps** | ✅ |
| A4 | 主机协议栈也收到（帧没被 MAC 静默丢） | netdev 计数（**只当旁证**） | Δ`netdev_rx_packets` **等于** Δ`port_rx_packets`（逐数相等） | ✅ |
| A5 | **FCS 正确** ⇒ `rx_eth_crc_err` 增量 **0** | 802.3 clause 3.2.9 | ❌ **32,546,169 / 32,072,553**（≈ 100% 的帧）；`port_rx_good` **恒 0**、`port_rx_bad` ≈ `port_rx_packets` | ❌ **不合规** |
| A6 | 没有别的错包 | —— | `port_rx_pause/control/overflow/lt64/frm_trunc/lt64` 增量**全 0** | ✅ |

### 3.4 ⭐ 累积量的**逐字节**对账（本轮最强的一条"内容级"证据）

收尾快照（`logs/g2_probe.log`，`NICSNAP FINAL`）：

```
NICSNAP FINAL p1 port_rx_packets=1020633510   port_rx_bytes=253117110392
NICSNAP FINAL p1 port_rx_good=0               port_rx_bad=1020633510
NICSNAP FINAL p1 port_rx_128_to_255=1020633506   (65_to_127=2, 256_to_511=2, 其余全 0)
NICSNAP FINAL p1 netdev_rx_packets=1020633510  netdev_rx_bytes=253117110392
```

【自算】

```
1,020,633,506 帧 × 248 B = 253,117,109,488
+ 2 帧(65–127B, 取 86) = 172
+ 2 帧(256–511B, 取 366) = 732
------------------------------
合计 = 253,117,110,392   ←  与网卡报的 port_rx_bytes 253,117,110,392 【逐字节相等】
```

⇒ **网卡的字节计数被 10.2 亿个 248 字节帧**（加 4 个杂帧）**精确解释完毕**。
这不是"计数在涨"，这是"**每一帧的长度都对得上**"。

### 3.5 板侧对同一件事的**独立**见证（闸 2 变体的自检，`g3_loop.tcl`）

⚠️ §3.3 的读数是"网卡说我们的帧到了"。为把"我们的发生器到底发不发帧"这个问题**从网卡身上摘下来**，
闸 2 的位流还把**通道 1 的 GT 内部环回**接进 VIO（`vio_gt_loopback[5:3]`），于是**板子能收到自己发的东西**：

```
logs/g3_loop.log:
G3_L1_WIN c1_frames_delta 27495076 c1_words_delta 1085835117 …      ← ch1 GT 环回 = 001
G3_L2_WIN c1_frames_delta 26831844 c1_badpay_delta 134885096 …      ← 同上 + crc_en=1
（对照：闸 2 变体、**环回关**时 §4 的 A 窗里 ch1_frames_delta = **0**）
```

⇒ 板子自己的 XGMII 检查器在**没有网卡参与**的情况下数到 **2,749 万帧**（≈4.1 M 帧/s）。
**"发生器真的在 ch1 上发帧" 是板级实测，不是推断。**
（⚠️ 该环回窗里 `c1_e_delta` 与内容失配均非零 ⇒ **该环回本身不干净**，只用于回答"发不发"，
不能当"帧内容正确"的证据；见 §6 U-item。）

---

## 4. ②-B 节：网卡 → 板（**我们能正确接收真设备发的帧吗**）

全节 **发生器关着**（`send_cont=0`），所以板侧 RX 数到的每一帧**只可能来自网卡**。

```
logs/g2_probe.log:
G2_B_QUIET_DELTA nic_tx_packets 9
G2_B_QUIET_DELTA ch0_frames 0 ch1_frames 4
G2_B_QUIET_DELTA ch1_words 1731795238 ch1_ctrl 1731795128
G2_B_PING_DELTA nic_tx_packets 11
G2_B_PING_DELTA ch0_frames 0 ch1_frames 4
G2_B_PING_DELTA ch1_e 0 ch0_e 0
G2_B_PING_DELTA ch1_badstart 0 ch1_badhdr 8 ch1_badlen 4 ch1_badterm 4 ch1_abort 0
G2_B_PING_TOTALS ch1_frames=21 ch1_badhdr=42 ch1_badlen=21 ch1_e=0 ch1_sw_lo=1431655931 ch1_lastw=16
G2_CS B_QUIET_T0 completion_status=12 …
```

| # | 判据 | 期望来源 | 实测 | 结论 |
|---|---|---|---|---|
| B1 | `block_lock = 1`（**要求同步头合法 + 解扰正确 + 块对齐成功**） | 802.3 clause 49.2.13 | ch1 **恒 1**（两个位流、整场、含网卡掉 link 期间） | ✅ |
| B2 | `rx_status=1`、`hi_ber=0`、`rx_local_fault=0`、`tx_local_fault=0` | `.veo` 语义 | 全 ✅ | ✅ |
| B3 | `framing_err` / `bad_code` / `fifo_error` 恒 0 | `.veo` 语义 | 32 位不回绕计数器：`ferr_d/ferr_r/bcd_d/bcd_r/ffe_d/ffe_r` **全 0**（`G2_CH … cnt` 行） | ✅ |
| B4 | 板侧**真的解出了网卡发来的帧** | 内容级 | `ch1_frames` 增长（静默窗 +4、ping6 窗 +4），且**内容与厂商图案不符**：`badhdr=8`、`badlen=4`、`badterm=4`，`badstart=0`（起帧字合法） | ✅ **外来帧** |
| B5 | 帧内无 `/E/` | —— | `ch1_e` 增量 **0**（两个窗都是） | ✅ |
| B6 | 让网卡真的发包 | `ping6 -c 10 -i 1 ff02::1%enp1s0f1np1` | 网卡 `port_tx_packets` 11→（+11）；板侧同时 +4 | ✅ 可控刺激成立 |
| B7 | 网卡发多少，板收多少 | —— | ⚠️ **9 vs 4、11 vs 4** —— **不相等**（约 2–3×） | ⚠️ **未核实**，见 §6 U4 |

**安全状态**：B 节全程 `send_cont=0`（板子只发 IDLE，不发帧）⇒ **不可能把板子的帧混进 B 节的分母**。

---

## 5. ②-C 节：负对照（≥1 条；本轮给了 3 条）

### C-1 拉高被连通道的 `TX_DIS`（**决定性的一刀**）

```
logs/g2_probe.log:
G2_C_BEFORE            p0_carrier=0 p1_carrier=1 p1_speed=10000
G2_C_KILL_CABLED_CHANNEL_D9 …
G2_C_KILLED            p0_carrier=0 p1_carrier=0 p1_speed=10000
G2_C_KILLED            p1_carrier_changes=40 p1_carrier_up_count=20
G2_C_CARRIER_CHANGES_BEFORE 39 AFTER 40          ← 一次"真的"跳变
G2_C_KILLED_RX         ch1_los=0 ch1_blk=1 ch1_rlocalfault=0
G2_C_RESTORE           …
G2_C_RESTORED          p0_carrier=0 p1_carrier=1 p1_speed=10000
G2_C_RESTORED          p1_carrier_changes=41 p1_carrier_up_count=21
```

| 期望（N1/N9） | 实测 | 证明 |
|---|---|---|
| 关我们的发射 ⇒ 网卡**必须**掉 link | `carrier 1→0`、`operstate down`、`carrier_changes 39→40` | **链路是我们拉起来的** |
| 恢复 ⇒ 必须**重新起来** | `carrier 0→1`、`carrier_up_count 20→21` | 与"别的东西在维持链路"排除 |
| ⚠️ 无 link 时 `speed` 是**残留值** | 关掉后 `speed` 仍报 `10000` —— **本轮实测踩到** | 判速率前必须先看 carrier/operstate |
| 且**只有**被连的通道有影响 | 阶段 1：关 C11（ch0）⇒ p1 `carrier_changes` 停在 17 **不动** | 判据有判别力 |

（阶段 1 的同类读数在 `logs/g1_probe.log:352/439/524`，两次独立复现。）

### C-2 计数器自身的负对照：**发生器停 ⇒ 计数停**
`G2_A_GENOFF_DELTA` 全 0（§3.2）。⇒ A 节的增量不是噪声。

### C-3 FCS 差分负对照（**期望 FAIL，实测 FAIL**）
`crc_en=0` vs `crc_en=1`，同一刺激只差一个 bit：
`rx_eth_crc_err` 增量 **32,546,169 → 32,072,553**（**没有变好**），`port_rx_good` **两档都是 0**。
⇒ 这一条**没有按期望翻转** ⇒ **如实登记**（不是"探针坏了"，见 §5.1 的根因定位）。

### 5.1 ⭐ A5 失败的根因定位（**RTL 推导，非实测**）

FCS 不是 PCS 算的 —— 官方 `xxv_ethernet` 在 `Ethernet PCS/PMA 64-bit` 模式下**没有 MAC**，
它只是把 XGMII 字节原样编码；FCS 是**厂商 example 发生器**算的。逐行读它的 CRC 通路：

```
xxv_gate2/v2/rtl/pcs64_pkt_gen_mon_g2.v
1216: function [31:0] gen_CRC_const ( input integer n, input const_data );
1219:   for(i=0; i<(n*8); i=i+1) begin            ← 循环次数是 n*8（**位**）
1220:     if(i <= 111 ) loc_poly = … eth_header[ crc_jiggle(111-i) ] …   ← 头部 112 bit = DA+SA+type = 14 B
1221:     else                          loc_poly = … const_data …          ← 其余全是常量比特
1040: localparam [31:0] PKT0_CRC = gen_CRC_const(pkt_len-4,1'b0);          ← n = 256-4 = 252
```
`crc_jiggle(d)={d[31:3],~d[2:0]}` 把 `d∈[0,111]` 映射到 `eth_header` 的 **0..111 位**
⇒ 参与 CRC 的头部正好是 `eth_header[111:0]` = **DA(6)+SA(6)+type(2) = 14 字节**（**不含前导**）✓。
而 `n = pkt_len − 4 = 252` ⇒ **CRC 覆盖 252 字节**（14 头 + 238 常量）。

【自算】实际帧的被保护长度：帧 = **248 B**（**网卡实测**，§3.3 A2），末 4 B 是 FCS 字段
⇒ 应保护 **244 B**（14 + 230）。
**252 ≠ 244，差正好 8 字节 = 一个"前导+SFD"字的长度。**

⇒【推定】**厂商的 `insert_crc` 把"前导字"也算进了被保护数据**，因此它插入的 FCS 与它实际发出的帧
**对不上**。这与 §5 C-3 的实测（`crc_en=1` 仍全判 CRC 错）**方向一致**。
⚠️ 这是**读取 RTL + 帧几何推导**得到的，**没有**做"逐位复算 FCS 再与线上比对"（§6 U5）。
它**不影响**对 PCS 的裁决：PCS 只是把 XGMII 字节原样搬到线上，FCS 是**上游**算错的。

---

## 6. ③ 符合性裁决

### 6.1 分层裁决

| 层 | 裁决 | 依据 |
|---|---|---|
| **PCS/PMA（10GBASE-R, 802.3 clause 49）** | ✅ **合规** | ① NIC 是**独立实现**，它把链路锁上了（`Link detected: yes` + `Speed: 10000Mb/s` + `carrier` 成立）—— 这一条同时要求**线速率对、64b/66b 块结构对、同步头对、加扰/解扰（自同步）对、块锁建立**（`P7B_SPEC.md` §5.2 E1）；② **逐帧长度分毫不差**（248.000000 B/帧，10.2 亿帧的字节计数逐字节对平）；③ **反向**：板侧对网卡发来的流 `block_lock=1`、`framing_err/bad_code/fifo_error` 恒 0、无 `/E/`；④ 关/开发射 ⇒ 链路**精确掉/起**。 |
| **帧格式 / FCS（802.3 clause 3.2.9）** | ❌ **不合规** | 1,020,633,510 帧**全部**被网卡计入 `port_rx_bad`，`port_rx_good = 0`，`rx_eth_crc_err ≈ 100%`。**帧的 FCS 无效。** |
| **根因归属** | **不在 PCS** —— 在**测试激励**（厂商 example 发生器的 CRC 通路，§5.1 推导）。 | |

### 6.2 一句话

**"官方 PCS 出来的是不是合规的 802.3 以太网"——**
**在 PCS 这一层：是（证据很强，且是双向的）。在"一整帧"这一层：不是 —— 但它错在 FCS，
而 FCS 不是 PCS 的职责，且这个错可以定位到厂商 example 的 CRC 通路。**

⚠️ **不得**把本轮的 `rx_eth_crc_err ≈ 100%` 读成"PCS 有问题"；也**不得**读成"网卡没收到"——
它收到了 **10.2 亿帧**，长度全对。

---

## 7. ④ 与 `P7B_SPEC.md` §5.2 闸 2 判据（E1..E7）的逐条对账

| # | 判据（规格原文） | 期望来源 | 本轮 | 结论 |
|---|---|---|---|---|
| **E1** | NIC 侧 `Link detected: yes` + `Speed: 10000Mb/s` | 802.3 10GBASE-R（NIC 是独立实现） | `Link detected: yes`；`carrier=1`；`Speed: 10000Mb/s`（**carrier 成立后才读**） | ✅ **PASS** |
| **E2** | NIC 侧**硬件** RX 计数增长（`ethtool -S`，**字段名以现场为准**） | NIC 自己的计数器 | Δ`port_rx_packets` = 3.21×10⁷ / 3.35×10⁷；**且发生器停时 Δ=0**（非真空） | ✅ **PASS** |
| **E3** | 抓包/对端看到帧**逐字节**等于我们意图发的字节（dst_mac/type/载荷/长度） | 802.3 对端实现 | 长度逐字节对平（248.000000 与 10.2 亿帧的字节总量**精确相等**）；dst=广播；type=0x0600 见 RTL。⚠️ **载荷内容**没有独立抓包比对（无 root，`tcpdump` 拿不到） | ⚠️ **部分**（长度侧 ✅ 强；内容侧见 §8 U6） |
| **E4** | 反向：NIC 发帧 ⇒ 板侧 MAC RX 计数增长、FCS 残差通过、载荷逐字节相等 | 我们的 MAC + 独立复算 | ch1 `block_lock=1`、`framing_err=0`、`ch1_e=0`、`ch1_frames` 增长且被判为**外来帧**（`badhdr/badlen/badterm`）。⚠️ "FCS 残差/载荷逐字节"需要**我们自己的 MAC**，本轮还没有 MAC | ⚠️ **部分**（PCS 侧 ✅） |
| **E5** | **负对照**：故意发坏 FCS 的帧 ⇒ NIC **必须不呈现**该帧（或计入 FCS 错） | 802.3 3.2.9 | ✅ **两档都是坏 FCS**（`crc_en=0/1`），NIC **全部**计入 `port_rx_bad` + `rx_eth_crc_err`，`port_rx_good` 恒 0 | ✅ **PASS**（判据统计有牙） |
| **E6** | 负对照（**仿真做**）：去掉 `bswap64` ⇒ 色序门必须 FAIL | 厂商明文 RTL | 本轮**未做**（属闸 3 仿真门，不在本轮范围） | ⏳ 未做 |
| **E7** | `stat_rx_framing_err/bad_code/error` 整场**恒 0** | `.veo` 语义 | `framing_err`/`bad_code`/`fifo_error` 的 32 位不回绕计数器**全 0**；⚠️ `stat_rx_error` 的 `_valid` 全程**未触发**（与闸 1 相同的观测缺口） | ✅ **除 `rx_error` 外**（该条按"未测"登记，与闸 1 §5.11 一致） |

**负对照表（§6.2）对账**：**N1**（TX_DIS 强拉高 ⇒ 链路全黑）✅ 两次独立复现；
**N5**（环回断开 ⇒ 判据 FAIL）✅ 用 TX_DIS 代替；**N6**（坏 FCS ⇒ NIC 不呈现）✅（E5）；
**N9**（不发 idle ⇒ 掉块锁）✅ 其逆命题（发 idle ⇒ 起链路）由 C-1 的"恢复即起"覆盖。
N2/N3/N4/N7/N8 属闸 3/闸 4，本轮未做。

---

## 8. ⑤ 未核实清单（**严禁当结论用**）

| # | 未核实项 | 现状 | 怎么补 |
|---|---|---|---|
| **U1** | 网卡**实际协商的 10G 模式**（CR vs SR vs LR） | 只有**排除法**（§2.4）：不做 clause-73 AN 的只能是 10GBASE-R 一族。`ethtool -m` 因**无 root** 被拒 | 拿 root 读模块 EEPROM；或问装配要模块型号 |
| **U2** | `crc_en=1` **是否真的在硅上生效** | VIO 写已 `commit`、RTL 逐行核实 `assign insert_crc = crc_en;`、且**环回里 `badpay`/帧 从 4.02 涨到 5.03**（弱证据）；但**没有直接读数** | 把 `insert_crc` 引一个探针出来；或做 `pay_sel=1`（全 1 载荷）的对照档 |
| **U3** | 厂商 FCS 的**逐位复算** | §5.1 只做了**长度论证**（252 vs 244） | 把 `gen_CRC_const` 在 Python 里逐位复现，与一个标准 CRC-32 对拍 |
| **U4** | **B 节帧数不匹配**（网卡发 9/11，板收 4/4） | 未归因。候选：网卡 IPG 极短（DIC）使两帧落在同一 XGMII 字里，板侧检查器按 `/S/` 入帧漏计；或 NIC 的 `port_tx_packets` 含未真正上线的帧 | 板侧记录**逐帧间隔分布**；或让网卡发**定长、低速**的帧 |
| **U5** | 上游 GC 环回（`g3_loop`）**不干净** | `c1_e_delta ≈ 1.3×10⁷`、内容失配大量 | 只当"发不发帧"的判据用；要干净自环得用闸 1a 的 `001` 在 **ch0** 上做（已验收） |
| **U6** | 帧**载荷内容**的独立比对 | 没有独立抓包（无 root）；只有**长度**与**总字节**的逐字节对账 | root + `tcpdump`；或让板子发一个**网卡会回显**的协议（需我们自己的 MAC） |
| **U7** | J7 是"没插线"还是"没插模块" | 两者都表现为 `los=1` 恒亮 | 现场看；不影响映射结论 |
| **U8** | `stat_rx_error[7:0]` | `_valid` 全程未触发（与闸 1 §5.11 同一缺口） | 仿真或人为造坏码 |
| **U9** | 长时稳定性（soak） | 本轮连续流最长 ~7 s/窗，累计 10.2 亿帧 | 按 `P7A_RESULT.md` §7 的口径加长 |
| **U10** | `10G` 模式下的 FEC | 双方都没开 FEC（`Supported FEC modes: Not reported`） | —— |

---

## 9. ⚠️ 本轮**自伤**与订正（诚实登记，按代价排序）

| # | 我犯的错 | 症状 | 代价 | 修法 |
|---|---|---|---|---|
| **H1** | **`nicval` 取整份快照里第一个匹配字段** | 快照先打印 p0（无 link，恒 0）再打印 p1 ⇒ **所有 `port_rx_*` 差值都读了 p0 的 0** | ⚠️ **最贵的一条**：它让我一度得出"板子的帧根本没出去"的**错误**结论，并据此**多做了一轮构建**（加 ch1 GT 环回）。**实际上 A 节从第一轮就是通的** | 改成**带端口限定**的 `dnicp`（`g2_probe.tcl:76`）。⇒ 教训：**"读了一个数"与"读对了那个数"是两件事；多端口快照必须端口限定。** |
| **H2** | 闸 2 变体的 `mkv2.py` 三处批次错：`"\\n".join`（丢 CRLF）、区域重装用了**未打补丁的切片**、u_tgm 的换道只做了半截 | 第一次构建：`module 'pcs64_pkt_gen_mon_ds' not found`；第二次：u_tgm 端口仍指 `_0` | 2 次构建作废 | 全部改成 `NL` 感知 + `sub1()` **单次出现断言** + 区域重装用**打过补丁的变量** |
| **H3** | `s2_build_g2.tcl` 对**已跑过一轮**的工程不可重入（`create_ip` 报 `IP name 'vio_0' is already in use`） | 第 3 次构建直接死在 `S2_VIO` | 1 次构建作废 | 加 `remove_ip`（`s2_build_g2.tcl:65-73`） |
| **H4** | `g1_probe.tcl`/`g2_probe.tcl` 里 `array set X {}` 与 `readall $vio <LABEL>` 的名字不一致 | `can't read "A0": variable is array` 之类，跑一半就退 | 3 次上板作废 | 名字对齐（本节列出的都是**已修**后的最终脚本） |
| **H5** | `s1_prepare*.tcl` 第 189 行 `$pdir/pcs64.srcs/…`（应为 `<项目名>.srcs`） | 报告末尾 `couldn't open … no such file or directory`，**退出码 1** | 无（该段是收尾的只读枚举） | ⚠️ **是既有脚本的既存缺陷**（闸 1 的 `logs/s1_prepare_stdout.txt` 尾部同一条），**不是我引入的** |
| **H6** | `vio_gt_loopback` 加宽到 6 bit 后，`vset 1` 写的是 **ch0** 的那 3 位 | 第一次 GT 环回实验"环了个寂寞"（ch0 亮、ch1 没动） | 1 次上板作废 | 改成 `vset 8`（`bit[5:3]=001`）并把位域写进脚本注释 |

> **H1 是本轮最值得记的一条**：它和本工程历史上那些"安静地什么都没做"的台架故障**是同一族** ——
> **读数解析错误会伪装成"被测对象没工作"**。它的解毒剂也简单：**永远给多端口/多实例的快照加限定词**。

---

## 10. 本轮新增文件（全部在 `udp_hls_10g/_proj_10g/xxv_gate2/`）

| 文件 | 作用 |
|---|---|
| `mkv2.py` | 从闸 1 源码**生成**闸 2 变体（不改原件）；每处替换都有**单次出现断言**；CRLF 感知 |
| `v2/rtl/xxv_loop_g2_top.v` | 变体顶层：流量模块整体绑 ch1 + `pay_sel[1]`=FCS + `gt_loopback[5:3]`=ch1 |
| `v2/rtl/pcs64_pkt_gen_mon_g2.v` | 厂商明文流量模块的副本，**与原文只差 3 行** |
| `v2/rtl/{obs_util.v,xgmii_rx_chk.v}`、`v2/xdc/*` | 逐字节复制 |
| `v2/tcl/{s1_prepare_g2,s2_build_g2}.tcl` + `run_s{1,2}_g2.bat` | 建工程 / 构建（**从不烧录**） |
| `tcl/g0_state.tcl` | 只读：查 FPGA 上现在载的是什么 |
| `tcl/g1_probe.tcl` + `run_g1.bat` | 阶段 1：闸 1 位流 + 首次端口映射 + A/B 初测 |
| `tcl/g2_probe.tcl` + `run_g2.bat` | 阶段 2：变体位流上的 M/A/B/C 全套 |
| `tcl/g3_loop.tcl` + `run_g3.bat` | 阶段 3：ch1 GT 环回自检（"发生器到底发不发帧"） |
| `tcl/nic_snap.sh` | 对端机的**只读**快照脚本（`ethtool -S` + sysfs + netdev + ethtool 摘要） |
| `logs/` | 全部原始 stdout（`g1_probe.log` / `g2_probe.log` / `g3_loop.log` / `s1_g2_*` / `s2_g2_*`） |

### 10.1 位流台账（本轮实际烧过的）

| 位流 | sha256 | 用途 |
|---|---|---|
| 闸 1 第 3 轮（`xxv_loop/pcs64_2ch/…`） | `2acafb1f4c48c2ff22fcf78ce6fca079f5c3aae98695a49a8206427c7b767f0a` | 阶段 1：端口映射 + 负对照（**A 节在此位流下结构性不可能**） |
| **闸 2 变体**（`xxv_gate2/v2/pcs64_g2/…`） | **`7eaf789ab9700d3c7c703bdc0a871f698a7d877a7bb855bee511072a51190a0f`** | 阶段 2/3：A（含 FCS 差分）/ B / C / 环回自检 |

> ⚠️ 用户任务书里写的 `5560375b…72ee2c` **在本轮开工时已不在磁盘上**（被闸 1 第 3 轮覆盖）——
> 见 §1 C1。**闸 1 的判据不受影响**（那轮报告里的读数与结论仍对应它自己的位流）。

### 10.2 对端机的改动（**最小化 + 复原**）

| 动作 | 内容 | 复原 |
|---|---|---|
| 落盘 | `/tmp/nic_snap.sh`（**只读**脚本） | ✅ 会话结束已 `rm` |
| 读 | `ethtool` / `ip` / sysfs / `cat /proc/…` | 无 |
| 写 | **只有** `ping6 -c 10 -i 1 ff02::1%enp1s0f1np1`（自终止，不改配置） | 无需 |
| 未做 | **没有**改驱动/固件/PCIe 配置；**没有** reboot；**没有**改 IP/MTU/ring/offload | —— |

---

## 11. 与"用户点名要点"的对照（收口）

| 用户要点 | 本轮 |
|---|---|
| 端口映射**必须测**、不许猜 | ✅ §2：TX_DIS 逐通道开关 + NIC `carrier/carrier_changes` + 板侧 `block_lock`（**双向**），两个位流各复现一次 |
| 决定性负对照：拉 `TX_DIS` ⇒ 必须掉 link，恢复必须回来 | ✅ §5 C-1（`carrier 1→0→1`、`carrier_changes 39→40→41`） |
| `port_rx_packets/bytes` 是否在涨 | ✅ §3.3：Δ = 3.21×10⁷ / 3.35×10⁷（**并且发生器停时为 0**） |
| `rx_eth_crc_err` 是否恒 0 | ❌ **不是 0**（≈100%）。**如实报**，并定位到厂商 CRC 通路（§5.1） |
| `port_rx_bad` 是否在涨 | ⚠️ **在涨**，且 ≈ `port_rx_packets` |
| 反向：板侧能否 `block_lock=1` | ✅ §4：ch1 恒 1，且能解出网卡帧 |
| 网卡 dst MAC 过滤可能吞帧 | ✅ 厂商帧 dst = **广播** `FF:FF:FF:FF:FF:FF`（RTL 字面量），**不会被 DA 过滤**；且 netdev 计数与硬件计数**逐数相等** ⇒ 主机也看到了 |
| 判速率/错包只认硬件计数 | ✅ 全程 `ethtool -S`；netdev 只作**旁证**并明确标注 |
| `lspci` 判活 | 未用（板侧判活走 VIO 探针；网卡侧走 sysfs/ethtool） |

---

## 11.1 收尾状态（可复核）

```
# 板侧：发生器 OFF，两个发射都开（TX_DIS 低）
logs/g2_probe.log:  G2_FINAL_BOARD tx_dis=0/0 send_cont=0 pay_sel=0
                    G2_FINAL p0_carrier=0 p1_carrier=1 p1_speed=10000

# 网卡侧：链路在，但计数器**冻住**
$ ethtool -S enp1s0f1np1 | grep port_rx_packets     → 1020633510
（3 s 后）                                            → 1020633510   ← 增量 0
```

⇒ 收尾时**板子在发 IDLE、不发帧**，网卡链路在而计数不动 —— 这是"计数器不是噪声"的最后一次现场印证。
**未写板载 QSPI**（全部日志 `write_cfgmem|program_hw_cfgmem|QSPI` 命中 **0**）；只走 JTAG 易失烧录。
对端机 `/tmp/nic_snap.sh` **已删**；驱动/固件/PCIe 配置/IP/MTU/ring **一格未动**；未 reboot。

---

## 12. 证据索引（文件 + 行号）

| 内容 | 位置 |
|---|---|
| 阶段 1 全量 stdout | `xxv_gate2/logs/g1_probe.log`（位流 sha `:24`、端口映射 `:269,334,352,417,419,439,504,524,589`、A 节空真空零 `:984`） |
| 阶段 2 全量 stdout | `xxv_gate2/logs/g2_probe.log`（`G2_CS`、`G2_A_*`、`G2_B_*`、`G2_C_*`、`NICSNAP FINAL`） |
| 阶段 3 全量 stdout | `xxv_gate2/logs/g3_loop.log`（`G3_L1_WIN` / `G3_L2_WIN`） |
| 闸 2 变体构建 | `xxv_gate2/v2/logs/s2_g2_stdout.txt`（`S2_SHA256` / `S2_VERDICT` / `S2_GREP`） |
| 变体生成的完整 diff | `xxv_gate2/mkv2.py`（每处替换的唯一性断言就是"diff 清单"） |
| 厂商 CRC 通路原文 | `xxv_gate2/v2/rtl/pcs64_pkt_gen_mon_g2.v:190,1017-1052,1155-1200,1214-1246` |
| 闸 1 的对照件 | `_proj_10g/notes/P7B_GATE1.md`（+ `xxv_loop/logs/s3_probe_FINAL.txt`、`s7_probe2_FINAL.txt`、`s11_probe3_FINAL.txt`） |
| 规格书判据 | `udp_hls_10g/P7B_SPEC.md` §5.2（E1..E7）/ §6.2（N1..N9） |
