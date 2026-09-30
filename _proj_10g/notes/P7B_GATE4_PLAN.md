# P7b 闸 4（板级验收）runbook —— 拿到就能照着跑

- 日期：**2026-09-30**（侦察件；本文件**只读侦察**产出：未烧板、未改任何 RTL/XDC/脚本、未 git 写）
- 目的：让另一个 agent **不需要重新推理**就能跑完 P7b 闸 4。
- 判据原文出处：`udp_hls_10g/P7B_SPEC.md` §5.4（G1..G6）/ §6.1（G 组判据）/ §6.2（N 组负对照）
  + 交接件 `_proj_10g/notes/P7B_HANDOFF.md` §3① 的"硬判据"摘要。
- 现场读数出处：本轮**实际 ssh 到 `a@192.168.0.38` 跑过的只读命令**（下面逐条标注"【本轮实测】"）。

> ⚠️ **先读第 0 节的两条颠覆性发现** —— 它们改变"怎么判"，比 runbook 本身重要。

---

## 0. ⚠️ 两条必须先知道的事（**前提不成立 / 判据没牙**）

### 0.1 【本轮实测】`port_rx_good` **已经不是 0 了，而且它自己在涨** ⇒ 判据原文"`port_rx_good > 0`"**无判别力**

```
【本轮实测】ethtool -S enp1s0f1np1 （2026-09-30，两次相隔 6 s）
  port_rx_good        = 1376  →  1379      ← **在涨**（+3）
  port_rx_broadcast   = 1376  →  1379      （涨的全是广播）
  port_rx_64          = 1183  →  1185      （64 B 帧）
  port_rx_65_to_127   =  170  →   171
  port_rx_256_to_511  =   27  →    27
  rx_eth_crc_err      = 1020523634 → **不变**
  port_rx_bad         = 1020633510 → **不变**
  port_rx_packets     1020634886 → 1020634889
  链路：carrier=1 operstate=up speed=10000 carrier_changes=57
  对端机**自己不发**：port_tx_packets 恒 7585；`ip -4 addr` 该口无地址；
  `ip -6 addr` 只有 fe80::3dc:7cad:d0b1:8db0（**链路本地，不发 IPv4/ND**）
```
**⇒ 这些帧只可能来自 FPGA**（对端机在该口零发送，已用"网卡硬件 TX 计数 + 双栈地址视图"排除）。

**根因（读 RTL，非推断）**：本板的 **HLS 慢路径自带周期性发包**，**不经任何外部激励**：
- `hls/src/eth_types.h:175` —— `// RTL: ~5s between HELLO frames @ 125MHz (625,000,000 < 2^32)`
- `hls/src/layer_udp.cpp:138-152` —— `periodic HELLO goes to the fixed default destination (192.168.100.1)`；
  ARP 查不到 ⇒ `dst_mac = 0xFFFFFFFFFFFF`（**广播兜底**）
- `hls/src/layer_arp.cpp:143` / `layer_tcp.cpp:466` —— 对 `ACTIVE_IP`(192.168.100.1) 的 `arp_send_request`

它走的就是验收要验的那条链：`slow_tx_adp → tx_arb → **mac_tx_10g** → PCS → J8`。

**三条后果（都要写进结论）**：
1. **`port_rx_good > 0` 在"板子什么都不做"时已经成立** ⇒ 交接件 §3① 那句判据**必须改成增量 + 速率阈值**，否则就是一条"真空门"（跑了、过了、没验到东西）。
2. **同时也是一条免费的正证据**：`mac_tx_10g` 的 TX 通路（含 pad/FCS 修复）**此刻就在产出网卡认的好帧** —— `port_rx_bad` 与 `rx_eth_crc_err` 自闸 2 结算值以来**一个都没涨**。
   但它只覆盖 **64/66 B 广播小帧**，**不覆盖** app 图案通路的大帧/多字 TLAST ⇒ **不能拿它当闸 4 的通过件**。
3. 所有 NIC 侧判据**一律用两次快照的差**，并**先记基线**（见步骤 3）。

### 0.2 【本轮实测】PCIe 观测窗口**现在是死的** ⇒ 板侧判据（G1/G2/G3/G6）**必须先烧位流、再重启对端机**

```
【本轮实测】sudo reg_rw /dev/xdma0_control 0x00 w   →  0xffffffff
            （control 的 0x04 / 0x0C / 0x14 / 0x18 / 0x1C 同样全 0xffffffff）
【本轮实测】sudo reg_rw /dev/xdma0_user    0x00 w   →  0xffffffff   ← ⭐ **我们自己的寄存器窗口**
            （user 的 0x04 / 0x14 / 0x1C / 0x20 同样全 0xffffffff ⇒ MAGIC 0x50360001 读不出来）
【本轮实测】lspci -nn | grep 10ee  → 02:00.0 ... [10ee:9034]（**条目还在**）
【本轮实测】lspci -vv -s 02:00.0   → Kernel driver in use: xdma；但 Region 0/1 标了 **[virtual]**
【本轮实测】ls /dev/xdma0_* → 19 个节点都在（`/dev/xdma0_user` 的 mtime = Sep 29 13:53 = 驱动加载时刻，
            而 P7b 延迟探针位流是**之后**才烧的 ⇒ 链路就是那时掉的、再没回来）
```
⇒ **端点条目 / 驱动绑定 / 设备节点"都在"都不能当"通道活着"的证据** —— 唯一判据是 **BAR 读得动**
（这正是 `P6E_OBS.md` / `XCKU5PMini/CLAUDE.md` 那条"判活看 BAR 不看 lspci"）。现在读回全 F ⇒ **没应答**。

**⇒ 闸 4 的顺序被钉死：`烧位流 → 重启对端机 → 才读得到板侧计数`**（`p6b_accept.sh` 头注释的"上板运行手册"①②）。

---

## 1. 逐条回答任务书的 7 个问题

### Q1 判据原文是什么？现场 `ethtool -S` 里这两个字段**确实**叫什么？

**(a) 规格原文**（`P7B_SPEC.md` §5.4，逐字）：

| # | 判据 | 期望来源 |
|---|---|---|
| G1 | 位流 **sha256** + `BUILD_ID` 前置闸（必须是本轮新值，**当前 6 ⇒ 本轮应递增**） | `P6E_OBS.md:29` + 验收脚本。⚠️ **必须同步改验收脚本里"未实现地址"的取值**（当前 `0xB0`） |
| G2 | **新时钟域的频率正证据**：Δ(自由计数)/Δ(墙钟) = 标称 ±1%（`tx_mii_clk_0` / `rx_core_clk_0` / `dclk`） | 先例 W5 = 125.0061 / W24 = 156.2585 |
| G3 | **停机态守恒律逐字成立**（§5.3 F7 的式子在板级重跑） | `P6B_ACCEPT.md` E1a/E1b（147==147、21235==21235） |
| G4 | 10G 速率：**板子自报 × 帧长** 与 **网卡硬件计数** 互相对账（偏差 <1%） | P6b 的 956.0 Mbps 口径（99.9%）；**不用用户态 socket** |
| G5 | 前置纪律：**构建期间不烧**；每次测量前**重烧**；PCIe 观测 **烧完必重启主机**；判活**看 BAR 不看 `lspci`** | —— |
| G6 | `rx_classify` 修复的板级判据：最小帧洪泛下 `stat_drop_full` 增量 **恒 0** | 审计件 §4.3 |

**另有交接件 §3① 那条"硬判据"**（闸 2 给的、判"我们的帧被真网卡接受吗"）：
> **`rx_eth_crc_err` 必须为 0 且 `port_rx_good` > 0**

**(b) 【本轮实测】现场字段名 —— `ssh 过去实际跑了一次 `ethtool -S enp1s0f1np1``：**

```
【本轮实测】python tools/peer_ssh.py "ethtool -S enp1s0f1np1"
NIC statistics:
     rx_noskb_drops: 0
     rx_nodesc_trunc: 0
     port_tx_bytes: 1250382
     port_tx_packets: 7585
     port_tx_pause: 0            port_tx_control: 0
     port_tx_unicast: 0          port_tx_multicast: 5818    port_tx_broadcast: 1767
     port_tx_lt64: 0             port_tx_64: 0
     port_tx_65_to_127: 4986     port_tx_128_to_255: 822
     port_tx_256_to_511: 1767    port_tx_512_to_1023: 2    port_tx_1024_to_15xx: 8
     port_rx_bytes: 253117205778
     port_rx_good_bytes: 95386
     port_rx_bad_bytes: 253117110392
     port_rx_packets: 1020634885
     port_rx_good: 1375
     port_rx_bad: 1020633510
     port_rx_pause: 0            port_rx_control: 0
     port_rx_unicast: 0          port_rx_multicast: 0      port_rx_broadcast: 1375
     port_rx_lt64: 0             port_rx_64: 1182
     port_rx_65_to_127: 170      port_rx_128_to_255: 1020633506
     port_rx_256_to_511: 27      port_rx_512_to_1023: 0    port_rx_1024_to_15xx: 0
     port_rx_15xx_to_jumbo: 0    port_rx_gtjumbo: 0        port_rx_bad_gtjumbo: 0
     port_rx_overflow: 0         port_rx_nodesc_drops: 109876
     …
     rx_eth_crc_err: 1020523634
     rx_frm_trunc: 0             rx_overlength: 0
     rx_reset: 0
```

**⇒ 结论（可以照抄的字段名，**不是记忆**）**：

| 用途 | **现场字段名** | 备注 |
|---|---|---|
| 好帧数 | **`port_rx_good`** | 存在；§0.1 说它**已经在涨** |
| 好帧字节 | `port_rx_good_bytes` | |
| 坏帧数 | **`port_rx_bad`** | 闸 2 结束时 1020633510，**至今未涨** |
| 坏帧字节 | `port_rx_bad_bytes` | |
| 收帧总数 | `port_rx_packets` | = `port_rx_good` + `port_rx_bad`（**可自洽校验**） |
| 收字节总数 | `port_rx_bytes` | |
| **FCS 错帧** | **`rx_eth_crc_err`** | 存在；判据用它 |
| 长度直方图 | `port_rx_64` / `_65_to_127` / `_128_to_255` / `_256_to_511` / `_1024_to_15xx` / `_15xx_to_jumbo` | 判别"帧真的是 1518 吗" |
| 帧类型 | `port_rx_unicast` / `_multicast` / `_broadcast` | app 图案是**单播** ⇒ `port_rx_unicast` 必须涨 |
| 丢弃 | `port_rx_overflow` / `port_rx_nodesc_drops` / `rx_frm_trunc` | 区分"板子没发对"与"主机丢" |

⚠️ **两条读数陷阱**（都在本工程踩过）：
1. **`Speed:` 字段在 `Link detected: no` 时是残留值**（`P7B_U7_AND_PEER.md` §B.1.2 实测）。**判 link 只认 `carrier` / `operstate` / `Link detected`**。
2. **多端口快照必须带端口限定**（`P7B_GATE2.md` §9 H1：取"整份快照里第一个匹配字段"⇒ 全读成 p0 的 0，白做一轮构建）。**所有读数一律写 `enp1s0f1np1`**。

### Q2 板子怎么收到帧？（对端机用什么发？）

**现成工具已经有了，就在对端机上，且默认参数正好对**：

```
【本轮实测】ls -la /home/a/xdma_test/
  -rwxrwxr-x  p6e_udp_pattern        （C++，17024 B，Sep 29 01:19）
  -rw-r--r--  p6e_udp_pattern.cpp    （源码，9069 B）
  -rwxr-xr-x  p6e_udp_pattern.py     （Python 功能口径版）
  -rwxr-xr-x  p6b_accept.sh / p6e_snap_check.sh / p6e_precheck.sh / p6e_rate.sh …
【本轮实测】sed -n '1,68p' /home/a/xdma_test/p6e_udp_pattern.cpp
```
`p6e_udp_pattern` 的**自述**（逐字）：
> 用法: `./p6e_udp_pattern [--secs 10] [--board 192.168.100.2] [--port 8081] [--no-teach] [--teach-n 1] [--teach-len 100]`
> 做两件事: ① 发教学包（图案前缀, offset 0）教板子 peer ⇒ 板子开始全速发图案帧;
> ② 收到即逐字节比对 + 1s 一次速率, 汇总给判据; **退出码 0=全对, 1=失配/没收到**。
> ⚠️ **接收侧丢包 ≠ 图案错**: … 先向前找这段载荷: 找到 @k ⇒ 记 `gap`（接收侧掉包）; 找不到 ⇒ 真失配记 `bad`。
> 图案 = xorshift64, 种子 `0x9E3779B97F4A7C15`, **先取后推进**（与 `rtl/app_udp_pattern.v` 逐字节一致）

**⇒ 这就是闸 4 的主激励 + 主内容判据**（默认 `--board 192.168.100.2 --port 8081` = 本板 app 端口 `16'h1F91`）。

**⚠️ 路由陷阱（会静默失效）**：对端机 `192.168.100.0/24` **挂在 1G 口 `enp3s0` 上**（`ip route` 原文：`192.168.100.0/24 dev enp3s0 proto kernel scope link src 192.168.100.1`），10G 口 **无 IPv4 地址**。
⇒ 直接跑工具，教学包会从 **enp3s0** 出去，**永远到不了板子** ⇒ 现象是"板子根本不发"。
**修法（两条，都已在 §2 步骤 5 给出原文）**：`ip addr add 192.168.100.100/32 dev enp1s0f1np1` + `ip route add 192.168.100.2/32 dev enp1s0f1np1 src 192.168.100.100`。
- `/32` 地址 **不会**与 `enp3s0` 的 `192.168.100.1/24` 冲突（不会 `File exists`，也不产生第二条 /24 连接路由）；
- `/32` 路由**最长前缀匹配**胜过 `enp3s0` 的 /24 ⇒ 去板子的流量一定走 10G 口；
- 顺带把 `rp_filter` 的逆向路径判据变成确定成立（`all/rp_filter=2` 宽松，本来也过）。

**零改配置的替代（只让板子"收"，不让板子"发"）**：`ping6 -c 1 ff02::1%enp1s0f1np1`
（链路本地地址 `fe80::3dc:7cad:d0b1:8db0` **在** ⇒ 可用；`P7B_LATENCY.md` §2.5 用过同一手法）。
⚠️ 但它**不会让板子回帧**（板子慢路径只做 IPv4）⇒ **不能当闸 4 的激励**。

**要发多少 / 发什么才有判别力**：
- **教学包 1 个就够**（填 peer 表）；判别力**不靠包数**，靠**速率差**：
  背景 `port_rx_good` ≈ **0.1–0.5 帧/s**（§0.1）；板子图案通路是 **~1.4 M 帧/s（~950 Mbps 载荷）**
  ⇒ 差 **6 个数量级**，不存在"分不清背景还是板子"的问题。
- ⚠️ **不要**把"`Δport_rx_good > 0`"当判据（背景就满足）；**要** `Δport_rx_good ≥ 10^5`（且 `Δport_rx_unicast` 同步涨）。
- 内容判据的期望值**手写死**：`p6e_udp_pattern` 自己用固定种子复算图案 ⇒ **不由 DUT 生成**（符合本工程"期望来源独立"的要求）。

### Q3 板子怎么发出帧？（`ifdef P7B_10G` + `APP_MODE` 里 TX 的条件）

**TX 链**（`board/wrapper_p4.v`，逐处出处）：
```
app_udp_pattern u_app_udp  (:2478)  i_en = 1'b1   ← **硬接常 1**
    │  .i_tx_ready (app_udp_tx_ready)  ← peer 门
    ▼
udp_tx_cfg    u_udp_tx_cfg (:2524)  .o_ready → app_udp_tx_ready (:2564)
    │  peer 表写口 = udp_split 的 meta 线束 (:2539 .peer_wr(udp_meta_valid))
    ▼
udp_tx_frame u_udp_tx   (PLEN_MAX=1500 守卫)
    ▼
tx_arb → mac_tx_10g u_mac_tx (:2700, P7B_10G 分支) → tx_mii_d_1 → PCS → X0Y5 → J8
```
**⇒ 板子唯一的 TX 使能条件 = `udp_tx_cfg.o_ready == 1` = peer 表被写过**，而 peer 表的**唯一**写源是
`udp_split.meta_valid`（`rtl/udp_split.v:745: assign meta_valid = u_meta_valid;` = `udp_rx.meta_valid`
= **"app-UDP 匹配帧 w5 接受拍"**）。

**匹配条件（wrapper 里的常参，逐字）**：
```
udp_split   .cfg_dst_ip(32'hC0A86402)  // 192.168.100.2 = 本板 IP
            .cfg_port0 (UDP_APP_PORT = 16'h1F91 = 8081)
            .cfg_port1..3(16'hFFFF 未配置哨兵)   .cfg_port_any(1'b0)  .cfg_multi_en(1'b0)
udp_split.EXCL_PORT = 8080   ← HLS udp_echo 的端口被**排除**，走它 **不会**填 peer 表
udp_tx_cfg  .cfg_my_mac(48'h000A3501FEC0)  .cfg_my_ip(32'hC0A86402)
            .cfg_my_port/dst_port = UDP_APP_PORT(8081)
```
**⇒ 让板子发帧的最小动作 = 从对端机往 `192.168.100.2:8081` 发**一个**匹配的 UDP 帧**（一次即可）。
发完板子就会**全速连续发**（`TX_GAP = 16'd0`，见 `:2478` 附近的注释"**行为变更（已记录）**: 板上默认从'限速演示'变为'学到 peer 后全速发流（~929 Mbps 载荷 @1472B/帧）'"）。

**要不要先学 peer / 先发 ARP 请求？** —— **不需要**。
- peer 表的两个字段（`peer_mac` / `peer_ip`）**都从收到的那一帧里解析**（`udp_rx` 的 w3/w4 拍），板子**不主动 ARP 对端**。
- 反向（板子→对端）的 MAC 由 peer 表直供；**对端不需要先出现在板子的 ARP 表里**。
- ⚠️ 唯一的坑：教学帧必须**真的到板子**（见 Q2 的路由陷阱）。

**怎么让板子停？**（`TX_GAP=0` 是"发布即全速"）
1. **重烧位流**（peer 表复位 ⇒ 零帧；本工程每次测量前本来就要重烧）；
2. 或写 `pcie_scratch` bit1 = 1（`wrapper_p4.v:3691-3692`，`assign sfp2_tx_dis = pcie_scratch[1]`）
   ⇒ 拉高 J8 通道的 `TX_DIS` ⇒ **网卡直接掉 carrier**（这也是负对照 N-a 的动作）。
   ⚠️ **scratch 的寄存器地址是 `0x08`**（不是 `0x10` —— `0x10` 是只读 `HW_STATUS`；实测订正见步骤 6.1）：
   `reg_rw /dev/xdma0_user 0x08 w 0x2`，写后**读回** `0x08` 应为 `0x2`。

**⚠️ 别指望 `port_rx_good` 靠"板子自发"**：本节说的是"**只要有匹配帧就全速发**"；
**是否触发**取决于我们有没有发教学包 ⇒ 步骤 5 的 `--no-teach` 负对照就是这条的牙。

### Q4 板侧自报计数：从哪读？这个位流里通道可用吗？

**① 该位流定义了哪些宏（逐字）** —— `board/build_p7b_ku5p.tcl:140`：
```tcl
set_property verilog_define {APP_MODE=1 DEV_USP=1 PCIE_OBS=1 DP_156MHZ=1 P7B_10G=1} [current_fileset]
```
⇒ **`PCIE_OBS=1` 在**（PCIe 观测/快照段编译进去了）·
**没有 `P7B_LAT`**（延迟探针不在）· **`P7B_10G` 与 `DP_156MHZ` 都在**。
⇒ 呼应 `XCKU5PMini/CLAUDE.md` 那条订正：**`PCIE_OBS` 与 `DP_156MHZ`/`P7B_10G` 是三个独立宏**，别混。

**② 有没有 VIO？—— 没有。** `build_p7b_ku5p.tcl` 只 `create_ip` 了两个：`xxv_ethernet`(pcs64) 与 `xdma`；
`board/wrapper_p4.v` 全文**零 `vio` 命中**。⇒ **JTAG 侧无寄存器窗口可用**。

**③ 结论：板侧计数只能走 PCIe 快照窗口（51 字），而它现在读不动（§0.2）**
⇒ **必须"烧位流 → 重启对端机"**。

**④ 51 字地址表（这是 P7b 的现役表；`P6E_OBS.md` 那张是 36 字的旧表）**
窗口起点 `0x20` = W0，**地址 = `0x20 + 4*i`**；**W50 = `0xE8`**；**第一个未实现地址 = `0xEC`**。

| 字 | 地址 | 束 | 内容（**生产者节点**，出处） |
|---|---|---|---|
| W0..W35 | `0x20..0xAC` | FE/DP | **与 `P6E_OBS.md` 36 字表逐字相同**（勿重写，照那张表读） |
| **W36** | **`0xB0`** | FE | `mrx_stat_rx_words`（`mac_rx_10g` 收字数）`wrapper_p4.v:3438-3440` |
| **W37** | `0xB4` | FE | `mrx_stat_rx_pay_bytes` |
| **W38** | `0xB8` | FE | `rxcdc_ovf_cnt`（`fifo_async` 拒写，**F-1 缺口补上**） |
| **W39** | `0xBC` | DP | `pcs_status_bundle`（**位域写死在 `wrapper_p4.v:3404-3417`**：`[29]gtpowergood [28]user_rx_reset [27]user_tx_reset [21]rx_error_valid [20:13]rx_error[7:0] [12]valid_ctrl_code [11]fifo_error [10]bad_code_valid [9]bad_code [8]framing_err_valid [7]framing_err [6]tx_local_fault [5]rx_local_fault [4]hi_ber [3]rx_status [2]block_lock [30]ch0 健康签名`） |
| **W40** | `0xC0` | DP | `pcs_evt_bundle` = `{framing_err_evt, bad_code_evt, rx_error_evt, valid_ctrl_code_cyc}`（8 位各一，**饱和计数**）|
| **W41** | `0xC4` | tx | `mtx_stat_flush_words` |
| **W42** | `0xC8` | tx | `mtx_stat_flush_done` |
| **W43** | `0xCC` | tx | `mtx_stat_tx_words` |
| **W44** | `0xD0` | tx | `mtx_stat_tx_ctrl_char` |
| **W45** | `0xD4` | DP | `txcdc_ovf_cnt` |
| **W46** | `0xD8` | DP | `cls_dbg_stat_ovf` |
| **W47** | `0xDC` | DP | `cls_dbg_stat_route_ovf` |
| **W48** | `0xE0` | DP | `cls_dbg_stat_stall_in` |
| **W49** | `0xE4` | DP | `cls_dbg_occ`（5 位） |
| **W50** | `0xE8` | DP | `tx_clk_act`（`tx_mii_clk` 的 1 位 toggle 跨域数沿 ⇒ **频率 = 值/1**）<br>⚠️ 2026-09-30 订正: RTL 是**每拍翻转一次**(`wrapper_p4.v:3387-3400`)，dp 侧数的是**每次变化** ⇒ 值/秒 = 该域频率（**÷1**）。板级独立两点实测 155.8406 MHz@÷1（−0.262%）把口径钉死；旧注释/旧脚本里的"÷2"读法会得 78.125 = **假 FAIL**（`P7B_GATE4_ACCEPT.md` §3.3） |

⚠️ **两处必须改的老脚本取值**（规格 B5/G1 明写）：
① 验收脚本里的 **"未实现地址" `0xB0` → `0xEC`**（`p6b_accept.sh` / `p6e_snap_check.sh` 都是 `0xB0`）；
② `p6e_snap_check.sh` 的 `snap_words()` 只列到 `0xAC`（且**尾部 8 个地址重复了一遍**，是既存笔误），
**跑闸 4 前必须换成 `0x20..0xE8` 的 51 项**。
③ ⚠️ `SNAP_NW` 已由 `axi_regs` 的 `SNAP_NW_V` 参数控制（`wrapper_p4.v` 传 `SNAP_NW_P6E = 51`，`localparam` 在 `:3078`）；
`snap_idx` 5 位 / `snap_base` **已加宽到 `[11:0]`**（`_proj_pcie/rtl/axi_regs.v:212,227`）—— 复查一次即可。

### Q5 PCIe 硬约束：要不要"先烧位流再重启对端机"？重启有什么后果？有没有不依赖 PCIe 的替代？

**(a) 是，必须。** 硬约束原文（`XCKU5PMini/CLAUDE.md` §2「硬约束（实测踩过）」+ `_pcie/README.md` + `p6b_accept.sh` 头注释）：
> **PCIe 端点只认"FPGA 配置先于主机 POST"** —— 主机开机时若 FPGA 跑的是无 PCIe 的设计，根端口**直接放弃链路**；
> 事后补烧带 PCIe 的设计**救不回来**（`rescan` / 桥复位 / `setpci` Retrain Link / Link Disable 1→0 **四种主机侧手段实测全无效**，恒 `LnkSta Width x0`）。

**本轮实测佐证**（比历史记录更硬）：现在 FPGA 上跑的是**带 PCIe 的**位流（`PCIE_OBS=1`），
`lspci` 条目在、`xdma` 驱动绑定、19 个 `/dev/xdma0_*` 都在 —— **而 BAR 全读 `0xffffffff`**。
⇒ **"条目在 / 驱动在 / 节点在" 三者都 0 证据力**；只有"**本轮烧录之后重启过主机**"这个条件能把它救回来。

**(b) 重启对端机的后果（逐条）**：
| 项 | 结论 | 依据 |
|---|---|---|
| `hw_server`（JTAG 通路） | ✅ **systemd `enabled; preset: enabled`，自起**（`P7B_U7_AND_PEER.md` §B.1.5 原文） | 服务文件 `/etc/systemd/system/hw_server.service`，`LISTEN 0.0.0.0:3121` |
| ssh 通路（`wlp6s0` 192.168.0.38） | ⚠️ **中断 1–3 min**（本次 ssh 走 WiFi，不影响） | 重启期间 `peer_ssh.py` 返回 255，**要写重试循环** |
| 其它服务 | 无关键常驻服务被打断（DPDK **未绑**口：`dpdk-devbind.py --status` 两口 `drv=sfc unused=`；大页靠 `/proc/cmdline`） | U7 §B.1.4 |
| **最大风险** | ⚠️ **重启若卡在 POST / 起不来 ⇒ 连 JTAG 通路一起失去**，只能人工现场恢复。**这是本 runbook 唯一的"不可逆"操作** | 本工程已成功过一次（P6e），但不是 100% |
| 板子本身 | ✅ **FPGA 配置不会丢**（JTAG 易失烧录 + 主机 warm reboot 不断 FPGA 供电/不断 `PROGRAM_B`） | `p6b_accept.sh` 的上板手册①②就是这个顺序，且 P6b/P6e 实测通过 |

**(c) 不依赖 PCIe 的替代取数方案 —— 有三条，代价递增：**
1. ⭐ **NIC 侧判据本来就不需要 PCIe**：闸 4 最核心的"**我们的帧被真 802.3 设备接受吗**"（`Δport_rx_good` / `Δrx_eth_crc_err` / 长度直方图 / 速率）**全部在网卡上量**，一条都不依赖板侧读数。
   ⇒ 若时间紧，可以**先跑通 NIC 侧全判据**（含内容判据 `p6e_udp_pattern` + `tcpdump`），板侧那几条（G1/G2/G3/G6）留到重启之后。
2. **内容判据**可用 `tcpdump`（对端机有，`/usr/bin/tcpdump`，需 sudo）⇒ 逐字节比对线上帧，**独立于板子自报**。
   ⇒ 规格 G4 的"板子自报 × 帧长"这一半，可以用"**板子自报 W20/W8 = 网卡 `port_rx_packets` 增量 ±1%**"替代；**若拿不到板侧，就退化成"网卡侧一方的速率 + tcpdump 内容"并在结论里如实标注哪一半缺**。
3. **加 VIO 重建**（唯一能"不重启就拿到板侧计数"的路）：给 `build_p7b_ku5p.tcl` 加一个 `vio` 实例，
   把 51 字与 `snap_req` 接出来 ⇒ 每字一个 `probe_in`、`snap_req` 一个 `probe_out`（**参考 `probe_lat.tcl` 的 `vset`/`viget`/`pulse` 五个 API 坑**）。
   代价：**一次 ~45 min 构建**。⚠️ 但 `_proj_10g/p7b_lat/scripts/probe_lat.tcl` 已经证明这条链是通的（它就在用 VIO 读板）⇒ **这是最便宜的"去 PCIe 依赖"方案，值得在闸 4 之前或之后追加**。

### Q6 前置闸与风险清单

**开工前必核（每条都给命令，见 §2 步骤 0）**：
| # | 核什么 | 期望 | 不满足时 |
|---|---|---|---|
| P1 | **有没有并发构建在跑** | 本 agent 已知另一路在跑 `board/run_build_p7b_ku5p.bat`。**构建期间绝不烧**、绝不跑仿真 | 等对方 `P7B DONE` + 位流文件出现 |
| P2 | 位流 sha256 + mtime | 记录三元组（sha256 / 大小 / mtime） | 没位流 ⇒ 停 |
| P3 | **线插在哪**（不许问简称） | **`J8`(=SFP B=GTY `X0Y5`) ↔ `enp1s0f1np1`(p1, `01:00.1`)**；`J7` 空着 | 不符 ⇒ 整个判据映射作废，停 |
| P4 | 对端机状态 | `carrier=1 up speed=10000`；`hw_server active`；`ssh` 通 | 见 §2 步骤 1 |
| P5 | 板载位流是什么 | 上电后**必重烧**（铁律：读数只对应"就是这一版"） | —— |
| P6 | NIC 计数器基线 | 先记两条读数（相隔 ≥6 s） | 基线不记 ⇒ 后面所有"Δ"不可判 |

**每步失败的最可能原因（分诊表）**：
| 症状 | 最可能原因 | 先查 |
|---|---|---|
| `reg_rw` 全 `0xffffffff` | **烧完没重启主机**（或重启后端点仍未起） | §0.2；`p6e_precheck.sh` |
| 端点 `lspci` 有、BAR 读不动 | **陈旧条目**（`lspci` 不能作判活证据） | 同上 |
| 教学包发了、板子零图案帧 | **路由陷阱**（包从 `enp3s0` 出去了）/ 端口不是 8081 / 用了 8080（EXCL_PORT） | `ip route get 192.168.100.2` 必须显示 `dev enp1s0f1np1` |
| 板子发了、`port_rx_good` 不涨 | 写的是 `port_rx_bad`（FCS 错）/ 长度不对 / 被 NIC 丢 | 同时看 `rx_eth_crc_err`、`port_rx_128_to_255`、`port_rx_bad` |
| `port_rx_good` 涨但 `p6e_udp_pattern` 收不到 | **主机侧没交付**（dst IP 是本机 `enp3s0` 的地址，到达 10G 口）/ `rp_filter` / 没绑 8081 端口 | 用硬件计数判"到没到"，用 `tcpdump` 判"手上有没有" |
| 图案失配（`bad` 涨） | **接收侧掉包**还是**真失配**：工具已分开报 `gap` vs `bad` | `gap` 与板侧 `W9(udpapp_tx_bytes)` 对账 |
| 速率上不去 | 用户态 socket 天花板（**本工程纪律：速率只看板子自报或网卡硬件计数**） | `port_rx_bytes` 增量 |
| `rx_eth_crc_err` 涨了 | 板子 TX 的 FCS/pad 缺陷回归 | 立刻停，回 `mac_tx_10g` 的 pad/FCS 修复（提交 `effef26`） |

### Q7 时间预算

| 步骤 | 估计 |
|---|---|
| 0 前置闸 + 基线（NIC 两次读数） | **3 min** |
| 1–2 烧录（JTAG 1 MHz，经 `192.168.0.38:3121`）+ 判 DONE | **4–6 min** |
| 3 重启对端机 + 等端点 + 驱动 | **3–5 min**（含 2–3 min 的 POST） |
| 4 板侧判据（快照触发/51 字/频率/守恒律） | **5 min** |
| 5 教学 + 图案速率 + 内容判据 + tcpdump | **6 min** |
| 6 负对照（TX_DIS 掉 link / `--no-teach` 零帧） | **4 min** |
| 7 收尾（清路由、复原、写读数） | **2 min** |
| **合计** | **≈ 30 min**（不含"要加 VIO 就得重建 ≈ 45 min"） |

---

## 2. runbook（编号步骤；命令原文 + 期望输出 + 失败怎么办）

> **工作目录**：本机 = `D:\repo\XCKU5PMini\udp_hls_10g`（git 仓根）。
> **所有对端机命令**都经 `python tools/peer_ssh.py`（Git Bash 里先 `cd` 到仓根）。
> ⚠️ **Git Bash 下 python 输出是 GBK 会炸** —— 每条命令前加 `PYTHONIOENCODING=utf-8`（**本轮实测**：
> 不加就对含 `⇒` 的中文输出报 `UnicodeEncodeError: 'gbk' codec ...`，**exit 255**，看着像"ssh 不通"）。
> `--sudo` 需要密码：把 `PEER_PW=111111` 放在命令前（**不落盘**）。
> ⚠️ **绝不烧 QSPI**（`XCKU5PMini/CLAUDE.md` 纪律①）；**绝不改对端机的持久配置**。

### 步骤 0 —— 前置闸（**先做，不通过就停**）· ~3 min

```bash
# 0.1 确认没有并发构建在写位流 (若别人还在跑, 现在不要往下走)
ls -la vivado_prj/p7b_ku5p_prj.runs/impl_1/wrapper_p4.bit
#    期望: 文件存在, mtime = 本轮构建时间。不存在 ⇒ 停, 等构建 agent
sha256sum vivado_prj/p7b_ku5p_prj.runs/impl_1/wrapper_p4.bit
#    ⚠️ 记下三元组 (sha256 / 大小 / mtime) —— 它就是 G1 的"位流身份"

# 0.2 对端机 + 线缆 + 链路
PYTHONIOENCODING=utf-8 /c/Users/zhxue/anaconda3/python.exe tools/peer_ssh.py \
  "systemctl is-active hw_server; ss -ltn | grep 3121; \
   for f in carrier operstate speed carrier_changes; do echo -n \$f=; cat /sys/class/net/enp1s0f1np1/\$f; done"
#    期望: active / LISTEN 0.0.0.0:3121 / carrier=1 / up / 10000 / (记下 carrier_changes 的当前值)

# 0.3 ⭐ NIC 计数器**基线** (两次, 相隔 ≥6 s)
PYTHONIOENCODING=utf-8 /c/Users/zhxue/anaconda3/python.exe tools/peer_ssh.py \
  "ethtool -S enp1s0f1np1 | grep -E '^ +(port_rx_(packets|good|bad|bytes|unicast|broadcast|64|65_to_127|128_to_255|256_to_511|1024_to_15xx|overflow|nodesc_drops)|rx_eth_crc_err|port_tx_packets):' ; \
   echo '--- 6s ---'; sleep 6; \
   ethtool -S enp1s0f1np1 | grep -E '^ +(port_rx_(packets|good|bad|bytes|unicast|broadcast|64|65_to_127|128_to_255|256_to_511|1024_to_15xx|overflow|nodesc_drops)|rx_eth_crc_err|port_tx_packets):'"
```
**期望**：两条读数**几乎相同**（背景 `port_rx_good` 增量 0–3，`rx_eth_crc_err` 增量 **0**，`port_tx_packets` 增量 **0**）。
**失败怎么办**：
- `port_rx_good` 单次增量 > 10 ⇒ 背景另有源头（先查 `ip -4/-6 addr` 该口是否被加了地址、对端机是否在自发包），**记下来**、别直接开跑；
- `rx_eth_crc_err` 在**基线期**就涨 ⇒ 链路/对端有问题，**停**（先查模块/线，别往下走）；
- `carrier=0` ⇒ 板子在跑无 PCS 的位流或 `TX_DIS` 被拉高，**先烧位流**再看。

### 步骤 1 —— 板载位流核查（**只读**，可选，30 s）

```bash
# 只想确认"现在板上跑的不是 P7b 位流"才做; 不急可跳过
#   (g0_state.tcl 在 _proj_10g/xxv_gate2/tcl/, 只读查询)
```
**跳过也完全没问题** —— 步骤 2 会无条件重烧。

### 步骤 2 —— 烧录（JTAG，经对端 hw_server；**只走易失烧录**）· ~4–6 min

**2a. 准备 tcl**（仓库里**没有** `program_p7b.tcl`；下面是可用的最短版本，**别改别人的文件，自己在 `_proj_10g/notes/` 之外新建**：
建议落在 `_proj_10g/p7b_gate4/program_p7b_ku5p.tcl`，与本次验收产物同目录）：

```tcl
# program_p7b_ku5p.tcl — 闸 4 用; JTAG 易失烧录, 绝不 QSPI
set root [file normalize [file join [file dirname [info script]] .. ..]]
set bit  [file join $root vivado_prj p7b_ku5p_prj.runs impl_1 wrapper_p4.bit]
set url  192.168.0.38:3121
if {![file exists $bit]} { puts "G4-ABORT: no bitstream at $bit"; exit 1 }
puts "G4_BIT = $bit"
puts "G4_BIT_MTIME = [file mtime $bit]"
open_hw_manager
connect_hw_server -url $url
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
set tdev ""
foreach d [get_hw_devices] { if {[pget $d IDCODE_HEX] eq "04A62093"} { set tdev $d } }
if {$tdev eq ""} { puts "G4-ABORT: no KU5P (IDCODE 04A62093) on the chain"; exit 1 }
current_hw_device $tdev
set_property PROGRAM.FILE $bit $tdev
if {[catch {program_hw_devices $tdev} em]} { puts "G4-ABORT PROGRAM FAILED: $em"; exit 1 }
puts "G4_DONE_PIN = [pget $tdev REGISTER.CONFIG_STATUS.BIT\[14\]_DONE_PIN]"
puts "G4_PROGRAM_OK"
close_hw_manager
exit 0
```
> ⚠️ **`connect_hw_server` 必须指 `192.168.0.38:3121`**（`board/program.tcl` 写的是 `localhost:3121`，
> **在本机跑不通** —— 这个仓的 JTAG 电缆插在对端机上）。
> ⚠️ **Tcl 是 32 位**（`format` 对 >2³¹ 静默输出 0）⇒ 日志里**不做数值转换**。
> ⚠️ 成功判据 = 日志有 **`G4_PROGRAM_OK`** 且 **`G4_DONE_PIN = 1`**
> （2025.2 下 `program_hw_devices` 成功会打 `End of startup status: HIGH`，**没有独立 DONE 属性**）。
> 运行方式（Git Bash → bat → Vivado，本工程已验证的调法）：
> ```bash
> # 在 _proj_10g/p7b_gate4/ 建一个 run_program_p7b.bat (纯 ASCII + CRLF!):
> #   @echo off
> #   cd /d %~dp0
> #   call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source %~dp0program_p7b_ku5p.tcl -nojournal -nolog > %~dp0..\..\g4_program_stdout.txt 2>&1
> cmd //c '_proj_10g\p7b_gate4\run_program_p7b.bat'
> ```
**2b. 收尾自检（必做）**：
```bash
grep -E "G4_PROGRAM_OK|G4_DONE_PIN|End of startup status" g4_program_stdout.txt
grep -ciE "write_cfgmem|program_hw_cfgmem|QSPI" g4_program_stdout.txt     # **必须 = 0**
```
**失败怎么办**：
- `connect_hw_server` 失败 ⇒ `hw_server` 没起 / 对端机网络不通（回步骤 0.2）；
- `no KU5P` ⇒ 电缆被 `ftdi_sio` 占住 ⇒ 对端机上有 `xilinx-cable-prepare.sh` / `99-xilinx-ftdi-unbind.rules`（**U7 §B.1 已有先例**）；
- DONE ≠ 1 ⇒ **位流/器件不符**，停下查（别"重试一次看看"）。

### 步骤 3 —— **重启对端机**（PCIe 观测的前置；⚠️ 唯一不可逆的一步）· ~3–5 min

```bash
# 3.1 发重启 (会断 ssh, 这条命令预期"失败")
PYTHONIOENCODING=utf-8 /c/Users/zhxue/anaconda3/python.exe tools/peer_ssh.py --sudo "shutdown -r now"   # PEER_PW=111111
#     或:  ... peer_ssh.py --sudo "reboot"

# 3.2 等回来 (轮询; 每次失败都是正常的)
for i in $(seq 1 60); do
  PYTHONIOENCODING=utf-8 /c/Users/zhxue/anaconda3/python.exe tools/peer_ssh.py "uptime" 2>/dev/null && break
  sleep 10
done
#     期望: 10 min 内出现 "up 0 min"
```
**失败怎么办**：
- **>10 min 不通** ⇒ 对端机没起来 ⇒ **本 runbook 到此为止**，需要人工现场（也是 JTAG 通路一起失去的情形）；
- `hw_server` 起来后有 1–3 min 的 USB 重新枚举窗口 ⇒ 若 `connect_hw_server` 失败，**等一下再试**，不要重复烧。

### 步骤 4 —— 板侧：端点判活 + 快照 51 字 · ~5 min

```bash
# 4.1 ⭐ 判活**只看 BAR 读得动** (绝不用 lspci / config 空间)
PYTHONIOENCODING=utf-8 /c/Users/zhxue/anaconda3/python.exe tools/peer_ssh.py --sudo \
  "lspci -n | grep -i 10ee; T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools; \
   \$T/reg_rw /dev/xdma0_control 0x00 w; \$T/reg_rw /dev/xdma0_user 0x00 w"
#     期望: 0x50360001  (MAGIC; 0xffffffff ⇒ **没重启 / 端点没起, 回步骤 3**)
#     注: MAGIC 在 **user BAR** 上; 闸 4 的地址表是按 /dev/xdma0_user 的
#     (P6e 的脚本用 $DEV=/dev/xdma0_user; P6e 那一轮用 control 读过 config BAR)
```
```bash
# 4.2 前置闸三连 (身份)
#     MAGIC(0x00)=0x50360001 · BUILD_ID(0x04)=**本轮新值** · MARKER(0x14)=0xdeadbeef
#     ⚠️ BUILD_ID 现在源码里写的是 32'h00000007 (wrapper_p4.v 的 BUILD_ID_V, 注释行有 1..7 的定义)
#        —— **以现场 0x04 的读数为准**, 并回填验收脚本的 EXPECT_BID
PYTHONIOENCODING=utf-8 /c/Users/zhxue/anaconda3/python.exe tools/peer_ssh.py --sudo \
  "T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools; \
   for a in 0x00 0x04 0x14 0xEC; do echo -n \"\$a \"; \$T/reg_rw /dev/xdma0_user \$a w | tail -1; done"
#     期望: 0x50360001 / 0x00000007(或新值) / 0xdeadbeef / **0xffffffff(未实现地址=0xEC)**
#     ⚠️ 0xEC 是 51 字版的"第一个未实现地址" (旧脚本写 0xB0, **必须改**)
```
```bash
# 4.3 快照触发协议 + gen 恰好 +1 (来自 p6e_snap_check.sh; ⚠️ 必须**同一进程**内做)
PYTHONIOENCODING=utf-8 /c/Users/zhxue/anaconda3/python.exe tools/peer_ssh.py --sudo \
  "T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools; D=/dev/xdma0_user; \
   rd(){ \$T/reg_rw \$D \$1 w 2>/dev/null | tail -1 | sed 's/.*: *//'; }; \
   echo \"S0=\$(rd 0x1c)\"; \$T/reg_rw \$D 0x18 w 0x1 >/dev/null; sleep 0.2; echo \"S1=\$(rd 0x1c)\""
#     期望: S1 的 bit1(done)=1 且 [31:16](gen) = S0 的 gen + 1  ⇒ 用这条当"这一代是本进程触发的"的守卫
```
```bash
# 4.4 读 51 字 (0x20..0xE8) —— ⚠️ 用**新**地址表; 旧 p6e_snap_check.sh 的 snap_words() 只到 0xAC 且尾部重复 8 项
PYTHONIOENCODING=utf-8 /c/Users/zhxue/anaconda3/python.exe tools/peer_ssh.py --sudo \
  "T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools; D=/dev/xdma0_user; \
   for i in \$(seq 0 50); do printf 'W%d ' \$i; \$T/reg_rw \$D \$(printf '0x%X' \$((0x20+4*i))) w | tail -1 | sed 's/.*: *//'; done"
```
**判据（板侧，逐条对 `P7B_SPEC.md` §5.4 / §6.1）**：
- **G1**：sha256 + `BUILD_ID` 已记录；未实现地址 `0xEC` 回 `0xffffffff` **且同趟**读一个已实现字（如 `0x14` = `0xdeadbeef`）做对照；
- **G2**（频率正证据，窗口 **< 20 s**，因 32 位 @156.25 MHz 每 27.49 s 回绕）：
  `W5(0x34)` 前端域、`W24(0x80)` 数据面域、**`W50(0xE8)` = tx_mii_clk 的 toggle 数 ⇒ 频率 = ΔW50/**1**/Δ墙钟**（÷1，见上表 W50 行的订正）；
  三个都取两点 ⇒ 标称 ±1%（**前端 156.25** / 数据面与 tx 156.25）；
  ⚠️ 2026-09-30 订正: 前端域在 **P7B_10G 构建**里是 **PCS 的 CDR 恢复钟**，标称 **156.25 而非 125**
  （`board/wrapper_p4.v:658-659` `ifdef P7B_10G assign gmii_clk = rx_clk_out_1`；板级独立两点实测
  156.1986 MHz = −0.033%，P7B_GATE4_ACCEPT.md §3.3）。写 125 会把好读数判成 FAIL。
  ⚠️ 另: 快照字**只在触发时刷新** ⇒ 两点必须**各自**"触发 → 等 gen 恰好 +1 → 再取时间戳/读数"，
  否则分子量的是两个不同区间（真板上曾报出 371.04/293.58 MHz 的**伪 FAIL**，见 §4.2 教训）；
- **G3 停机态守恒律**（**必须在板子不发帧时做** ⇒ 先做完再教学）：`W30 == W0 + W32`、`W31 == W1 − 4·W0 + W33` **逐字成立**；
- **C1/C2/C3/C4**：`W39` 拆位 ⇒ `[29]gtpowergood=1`、`[2]block_lock=1`、`[3]rx_status=1`、`[4]hi_ber=0`、`[5]/[6]local_fault=0`；
- **C8 的"非零正证据"**：`W40` 的 `valid_ctrl_code_cyc` **必须非 0 且在涨**（否则"恒 0"不算干净）；
- **G6**：`W34 = rx_classify 的 stat_drop_full`（0xA8，属 W0..W35 旧表）在洪泛窗内 **Δ=0**。

**失败怎么办**：
| 症状 | 原因 | 处置 |
|---|---|---|
| BAR 全 F | 没重启 / 端点没起 | 回步骤 3；**别想主机侧补救**（四种手段实测全废） |
| `gen` 不是恰好 +1 | 有**别人**也在触发快照 / 本进程重复触发 | 立刻**停止**（读数不可归因），独自占用窗口重跑 |
| 某字恒 0 且**该字应有非零正证据** | 生产者节点没接出 / 被钉死 / 束拼接被静默截断 | 查 `SNAP_NW` 三处一致性（规格 B1/B8）；`10-3091] actual bit length 1` 当硬失败 |
| 读回"另一个字的正确值" | `snap_idx`/`snap_base` 位宽没同步加宽 | 规格 B2（本工程踩过：13d=8 字错 / 15b=0x320） |
| 频率算出来 ≈0 | 该域没起（`tx_mii_clk` 没跑 / PCS 没出钟） | 查 `W39[29]gtpowergood`、`W50` 是否恒 0 |

### 步骤 5 —— NIC 侧：教学 + 速率 + 内容判据 · ~6 min

```bash
# 5.1 把 10G 口的 IPv4 通路接上 (⚠️ /32, 不动 enp3s0 的 /24; 用完在步骤 7 删)
PYTHONIOENCODING=utf-8 /c/Users/zhxue/anaconda3/python.exe tools/peer_ssh.py --sudo \
  "ip addr add 192.168.100.100/32 dev enp1s0f1np1; \
   ip route add 192.168.100.2/32 dev enp1s0f1np1 src 192.168.100.100; \
   ip route get 192.168.100.2"
#     期望末行: 192.168.100.2 dev **enp1s0f1np1** src 192.168.100.100   ← **必须是这个 dev**
#     ⚠️ 若显示 enp3s0 ⇒ 教学包会从 1G 口出去, 板子永远收不到 (最贵的静默失效)

# 5.2 记录"教学前"的 NIC 读数 (与步骤 0.3 基线对账)
PYTHONIOENCODING=utf-8 /c/Users/zhxue/anaconda3/python.exe tools/peer_ssh.py \
  "ethtool -S enp1s0f1np1 | grep -E '^ +(port_rx_(packets|good|bad|bytes|good_bytes|unicast|broadcast|256_to_511|1024_to_15xx|15xx_to_jumbo|nodesc_drops)|rx_eth_crc_err):'"

# 5.3 ⭐ 教学 + 收图案 + 逐字节校验 (工具自带 tee: 教学包 → 板子全速发 → 逐字节比对)
# ⚠️⚠️ 2026-09-30 订正: 命令**不能以裸 `/` 开头** —— Git Bash/MSYS 会把传给 **Windows python.exe**
#     的参数做 POSIX→Windows 路径改写: `/home/a/...` ⇒ `C:/Program Files/Git/home/a/...`
#     ⇒ 远端报 `bash: line 1: C:/Program: No such file or directory` ⇒ **激励静默没跑**
#     (而 NIC 判据照常打 FAIL ⇒ **看着像板子坏了**; 闸 4 首次上板就踩了这个)。
#     ⇒ 写法: 首词用 `cd ... && ./<工具>` (实测可用); `p7b_gate4_accept.sh` 的 run_traffic()
#       已经**无条件**前置 `true; ` 兜底 (脚本内不再需要调用者操心)。
PYTHONIOENCODING=utf-8 /c/Users/zhxue/anaconda3/python.exe tools/peer_ssh.py --timeout 120 \
  "cd /home/a/xdma_test && ./p6e_udp_pattern --secs 15 --board 192.168.100.2 --port 8081"
#     期望: 每秒一行 [Δt] 帧=… 字节=… ≈9xx.x Mbps 失配=0 掉包=…
#           汇总 ⇒ **≈950 Mbps**; 载荷长度桶**只有 1472 那一桶**非零; **退出码 0**
#     ⚠️ 板子会**一直发下去** (TX_GAP=0)。要停: 重烧位流 (步骤 2) 或拉 TX_DIS (步骤 6.1)

# 5.4 板子发帧期间的 NIC 硬件计数 (⭐ 与 5.2 求差)
PYTHONIOENCODING=utf-8 /c/Users/zhxue/anaconda3/python.exe tools/peer_ssh.py \
  "ethtool -S enp1s0f1np1 | grep -E '^ +(port_rx_(packets|good|bad|bytes|good_bytes|unicast|broadcast|256_to_511|1024_to_15xx|15xx_to_jumbo|nodesc_drops)|rx_eth_crc_err):'"
```
**判据（NIC 侧，这是闸 4 的头条）**：
- ⭐ **`Δrx_eth_crc_err == 0`**（我们自己 MAC 的 FCS 正确）**且 `Δport_rx_good ≥ 10^5`**
  （**不是 `> 0`** —— 见 §0.1：背景 0.1–0.5 帧/s 就能让 `> 0` 成立）；
- **`Δport_rx_unicast` 同步涨**（app 图案是**单播**到学习到的对端 MAC；背景是**广播**）；
- **`Δport_rx_1024_to_15xx` ≈ `Δport_rx_good`**（1518 B 帧；背景是 64/66 B）；
- **`Δbytes/Δpackets ≈ 1518.000000`**（【自算】，与闸 2 的"248.000000"同款对账）；
- **`Δport_rx_bad == 0`**；
- **G4 速率对账**：`Δport_rx_bytes × 8 / Δt`（网卡硬件口径）vs **板侧自报** `ΔW20(mac_tx_frames) × 1518 × 8 / Δt`，**偏差 < 1%**。
  ⚠️ 板侧与 NIC 侧**不同刻**，必须各取自己的两点；或用"**同一秒内**工具打印的 Mbps" 与事后 `port_rx_bytes` 增量分别对账。
- **内容判据（独立于板子）**：`tcpdump` 抓 200 帧落盘后逐字节对图案（种子 `0x9E3779B97F4A7C15`，先取后推进）：
  ```bash
  PYTHONIOENCODING=utf-8 /c/Users/zhxue/anaconda3/python.exe tools/peer_ssh.py --sudo \
    "timeout 5 tcpdump -i enp1s0f1np1 -c 200 -w /tmp/g4.pcap 'udp and port 8081' ; ls -la /tmp/g4.pcap"
  #  ⚠️ 抓包量小 (200 帧 ≈ 300 KB) —— 不要长时间抓 (满速 1.4 Mpps 会写满盘)
  ```
  ⇒ 抓到后：dst MAC 必须是 `00:0f:53:2c:68:01`、dst IP `192.168.100.100`、dst port 8081、载荷 == 图案。

**失败怎么办**：
| 症状 | 原因 | 处置 |
|---|---|---|
| 工具报"没收到"但 `port_rx_good` 在涨 | 主机没交付（dst IP/`rp_filter`）| 用 `tcpdump` 确认"手上有没有"；必要时查 `accept_local` |
| `Δport_rx_good` 只涨几十 | **教学包没到板子**（路由陷阱）| 回 5.1，`ip route get` 必须是 `enp1s0f1np1` |
| 板子没发但教学包确实到了 | 端口不是 8081 / 用了 8080（`EXCL_PORT`）| 改回 `--port 8081` |
| `bad` 涨而 `gap`=0 | **真失配** ⇒ 图案/字节序问题（不是接收侧丢包）| 记下首个不同字节位置；对账 `app_udp_pattern` 的种子/顺序 |
| 速率只有几百 Mbps | 用户态 socket / 内核收包天花板 | **不以这个为准**，看 `port_rx_bytes` 硬件增量（本工程硬规矩）|
| `Δrx_eth_crc_err` ≠ 0 | MAC TX 的 pad/FCS 回归 | **停**，回 `mac_tx_10g`（提交 `effef26`）|

### 步骤 6 —— 负对照（**每条都要"按期望翻转"**）· ~4 min

```bash
# 6.1 ⭐ N-a 决定性一刀: 拉高被连通道的 TX_DIS ⇒ 网卡**必须**掉 carrier
#     (sfp2_tx_dis = pcie_scratch[1], 复位值 0 = 发射开)
# ⚠️⚠️ 2026-09-30 订正 (闸 4 首次上板实测): **scratch 在 `0x08`, 不在 `0x10`**。
#     本 runbook 旧版写的 `0x10` 是**只读的 HW_STATUS** (`_proj_pcie/rtl/axi_regs.v:242`
#     `6'd4: rdata_mux = hw_status;`) ⇒ 写进去**毫无效果** (读回恒 `0x18`), carrier 纹丝不动
#     ⇒ 按旧版跑会得到"负对照不翻转"的**假故障**。依据 (逐条可复核):
#       · `_proj_pcie/rtl/axi_regs.v:151` 写通道只认 `w_word == 6'd2` (= 0x08) 写 scratch;
#         其余地址写返回 SLVERR (`:159-161`) —— 所以对 0x10 的写**根本不落地**;
#       · `_proj_pcie/rtl/axi_regs.v:240` 读 mux `6'd2: rdata_mux = scratch;` (0x08 = word 2);
#       · `board/wrapper_p4.v:3691-3692` `assign sfp1_tx_dis = pcie_scratch[0]; sfp2_tx_dis = pcie_scratch[1];`
#         + `board/wrapper_p4.v:3723` `.scratch (pcie_scratch)` (即 axi_regs 的 0x08 端口)。
#     ⚠️ 成因留档: `board/wrapper_p4.v:3686` 的注释写的是"(0x10)"——**那句注释本身也是错的**
#        (本 agent 无该文件所有权, 未改; 见 `P7B_GATE4_TOOLING_FIX2.md` 待办)。
#     ⭐ **写后必须读回** `0x08` 自证写入落地 (闸 4 实测: 读回 `0x00000002`) —— 否则
#        "写没落地"与"链路不是我们维持的"在输出上不可区分。
PYTHONIOENCODING=utf-8 /c/Users/zhxue/anaconda3/python.exe tools/peer_ssh.py --sudo \
  "T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools; \
   \$T/reg_rw /dev/xdma0_user 0x08 w 0x2 >/dev/null; sleep 2; \
   echo -n scratch_readback=; \$T/reg_rw /dev/xdma0_user 0x08 w | tail -1 | sed 's/.*: *//'; \
   echo -n carrier=; cat /sys/class/net/enp1s0f1np1/carrier; \
   echo -n carrier_changes=; cat /sys/class/net/enp1s0f1np1/carrier_changes"
#     期望: scratch_readback=**0x00000002** (写落地) 且 carrier=**0** 且 carrier_changes **+1**
#           (必须看到新跳变, 不是陈旧值)
PYTHONIOENCODING=utf-8 /c/Users/zhxue/anaconda3/python.exe tools/peer_ssh.py --sudo \
  "T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools; \
   \$T/reg_rw /dev/xdma0_user 0x08 w 0x0 >/dev/null; sleep 3; \
   echo -n carrier=; cat /sys/class/net/enp1s0f1np1/carrier; \
   echo -n carrier_up_count=; cat /sys/class/net/enp1s0f1np1/carrier_up_count"
#     期望: carrier=1 且 carrier_up_count +1  ⇒ **"链路是我们拉起来的"被证明**
#     ⚠️ 判 link 只认 carrier/operstate, **speed 在无 link 时是残留值**
#     (原始证据: `_proj_10g/notes/p7b_gate4/live/negctrl_TXDIS.txt` —— 0x10 那一段不动、0x08 那一段翻转)

# 6.2 N-b 教学是必要触发: 重烧位流清 peer 表后, **不发**教学包 ⇒ 零图案帧
#     (顺序: 回步骤 2 重烧 → 步骤 3 重启 → 只跑工具 --no-teach)
#     ⚠️ 同 5.3: 首词用 `cd ... && ./` (裸 `/` 开头会被 MSYS 改写 ⇒ 激励静默没跑)
PYTHONIOENCODING=utf-8 /c/Users/zhxue/anaconda3/python.exe tools/peer_ssh.py --timeout 60 \
  "cd /home/a/xdma_test && ./p6e_udp_pattern --secs 10 --board 192.168.100.2 --port 8081 --no-teach"
#     期望: 收到的只有**背景 HELLO/ARP** (个位数帧、~66 B) ⇒ 退出码 1
#     ⇒ 证明"图案帧是教学触发的", 不是板子自发 (否则步骤 5 的速率判据没牙)
```
**失败怎么办**：6.1 里 `carrier_changes` **不动** ⇒ 链路不是我们维持的（**整个判据链作废**，先查线/模块）；
`--no-teach` 却收到满速图案 ⇒ **peer 表被别的东西填了**（回 `udp_split` 的 `meta_valid` 唯一源追）。

### 步骤 7 —— 收尾与复原 · ~2 min

```bash
# 7.1 删掉临时网络配置 (复原成"该口无 IPv4 地址")
PYTHONIOENCODING=utf-8 /c/Users/zhxue/anaconda3/python.exe tools/peer_ssh.py --sudo \
  "ip route del 192.168.100.2/32 dev enp1s0f1np1 2>/dev/null; \
   ip addr del 192.168.100.100/32 dev enp1s0f1np1 2>/dev/null; \
   ip -br addr show enp1s0f1np1; rm -f /tmp/g4.pcap"
# 7.2 让板子停下 (可选; 重烧会清 peer 表)
# 7.3 ⚠️ 板子现在的位流是 **P7b 位流**; 若要恢复别的用途, 重烧对应位流
# 7.4 记录: 位流 sha256 / BUILD_ID / 全部读数 / 负对照是否按期望翻转
```
**验收报告必须包含**（对照 `P7B_SPEC.md` §6.1 G 组的"期望来源"栏）：每条判据的**期望来源**、
**实测值**、**判定**（PASS/FAIL/SKIP），**没有期望来源的判据不得当判据用**。

---

## 3. 未确定项（**不许当结论用**）与补法

| # | 未确定 | 现状 | 补法 |
|---|---|---|---|
| **U1** | 背景小帧的**完整身份**（是 ARP 请求 + HELLO 的组合，还是还有别的） | 【推定】依 `eth_types.h:175`（HELLO ~5 s）+ 长度桶（64 B / 66 B） | 用 `tcpdump` 抓背景 20 帧看 ethertype/port |
| **U2** | 当前板上跑的到底是哪一个位流 | **未核实**（本轮未连 JTAG，遵守"不烧/不重负载"） | 步骤 2 反正要重烧 |
| **U3** | `tcpdump` 能否在该口抓到**满速**图案 | 未核实（200 帧 ≈ 300 KB 应该可以） | 步骤 5.4；**别超量写盘**（纪律：抓包 ≤ 几 MB） |
| **U4** | **G6 的"最小帧洪泛"在板上做不到线速** | 对端机用户态最多 ~10^5–10^6 pps；10G 最小帧线速 = 14.88 Mpps ⇒ **洪泛强度差 1–2 个数量级** | 如实标注"**弱化版洪泛**"；主判据回落到 `sim` 的 F3/F7 吞吐门 |
| **U5** | 重启对端机**这一次**会不会起不来 | 历史成功过一次 | 无远程兜底 ⇒ 记入风险（步骤 3） |
| **U6** | `p6e_udp_pattern` 的**接收侧**在满速 1.4 Mpps 下的 gap 率 | 未核实 | 与板侧 `W9(udpapp_tx_bytes)` 对账（工具自己的注释就建议这么做） |
| **U7** | `snap_words()` 的 51 项版本**尚不存在** | 旧脚本 36 项 + 尾部重复 | 步骤 4.4 已给等价的一次性命令（不改旧脚本） |

---

## 4. 一句话总结（给 TL）

**闸 4 可以跑，顺序是 `烧位流 → 重启对端机 → 读 51 字 → 教学 → 量 NIC`（≈30 min）。
但两条前提必须改口径：① `port_rx_good > 0` 已经被板子自己的 HELLO/ARP 背景流量满足（0.1–0.5 帧/s，**此帧来自 FPGA 已用"对端零发送"排除干净**），所以判据必须换成**增量 + 速率阈值（≥10^5 帧）+ 单播 + 1518 B 长度桶**三个一起；② 板侧 51 字只能走 PCIe，而**现在 BAR 全读 `0xffffffff`**（`lspci`/驱动/设备节点三样都不能当活的证据），所以"重启对端机"这一步不可省 —— 它是本 runbook 唯一不可逆的操作。**
