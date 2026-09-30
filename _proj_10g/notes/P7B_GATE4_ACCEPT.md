# P7b 闸 4 板级验收 —— 报告 (2026-09-30)

> 验收 agent 独立跑、独立读数；本文件即归档物。**判据表按 `P7B_SPEC.md` §6.1 的
> B 组 / C 组 / E4 / F 组 / G 组逐条填**，另附板侧工具 `p6e_snap_check.sh` 的窗口读数。

---

## 0. 总判决 —— **部分通过 (PARTIAL)**：链路/PCS/MAC/RX/慢路径全通，**app-UDP 分流路径板级失效**

| 组 | 结果 |
|---|---|
| **B 组 (快照窗口)** | ✅ 全 PASS（B3 逐字读回 51 字、B5 = 0xEC、B6 51≤56、B7 三域自由计数、B9/B10 缺口字已接出） |
| **C 组 (PCS/链路)** | ✅ 全 PASS（含 ⭐C8 正证据 = `valid_ctrl_code_cyc` 非 0） |
| **E4 / G 组** | ⚠️ G1/G2/G3/G4 PASS；**E4「恒 0」成立但本轮无洪泛 ⇒ 无判别力**（见 §4.3） |
| **F 组 (端到端)** | F1 ✅ / F2 ✅ / **F3 ❌ / F4 ❌** / F5 未测 |
| **负对照** | N-a ✅ 按期望翻转（**但 runbook 的地址写错了**，见 §4.1）；N-b 无判别力（见 §4.3） |

**一句话**：`192.168.100.2` 的 10G 链路、PCS 锁定、新 MAC、RX 解析、HLS 慢路径**全部实测正常**
（ping 5/5、UDP:8080 echo 逐字节、51 字窗口、守恒律逐字成立）；但**发往 app 端口 8081 的帧
被 `udp_split` 判成"HLS 帧"转走**，app 从未收到 ⇒ peer 表永不填 ⇒ **图案流零帧** ⇒ F3/F4 FAIL。
**这是本轮新发现的板级缺陷**（此前假设"教学包一发板子就全速发"）。

---

## 1. 位流身份与前置（G1 的位流一半 + G5 纪律）

| 项 | 值 |
|---|---|
| 位流路径 | `vivado_prj/p7b_ku5p_prj.runs/impl_1/wrapper_p4.bit` |
| **sha256** | **`d1ddb3b44ba1dc94fa016b257b9f1b3ba9c49d16404aa881b7865d2dc47487aa`** |
| 大小 / mtime | 15,431,261 B / `2026-09-30 09:55:52` |
| 构建日志判据 | `P7B DONE` ✅ · `P7B_BIT_EXISTS = 1` ✅ · `tasklist \| grep vivado` = **0 进程** ✅ |
| 烧录 | `_proj_10g/notes/p7b_gate4/program_p7b_ku5p.tcl`（JTAG @1 MHz，经 `192.168.0.38:3121`）⇒ `End of startup status: **HIGH**`；**QSPI 命中 = 0** |
| 板侧身份 | `MAGIC=0x50360001` · `BUILD_ID=0x00000007`（= 本轮新值，规格要求"当前 6 ⇒ 递增"✅）· `MARKER=0xdeadbeef` |
| 次序纪律 | **先烧位流 → 再重启对端机**（`10:00:05` 发重启，`uptime -s = 10:00:26` 证明确实重启）⇒ 重启后 BAR 立刻读通 ⇒ 未走"四种主机侧补救全废"那条路 |
| 判活 | ⭐ **只按 BAR 读取**：`/dev/xdma0_user 0x00` = `0x50360001`（不用 `lspci`/config 空间） |

---

## 2. 板侧窗口读数（`p6e_snap_check.sh`，已按 51 字部署到对端机）

**停机态**（板子不发图案；`live/snap_check_halt.txt`）：

- `W0=69 W1=11188 W2=333 W3=0(FCS 错=0) W4=0 W6=69 W7=10 W8=0 W9=0 W10=0 W13=0 W20=10`
- `W30=69 W31=10912 W32=0 W33=0 W34=0 W35=0`
- `W38=0 W39=0x2000100C W40=0x000000FF W41=0 W42=0 W45=0 W46=W47=W48=0`
- 自报汇总 `PASS=13 FAIL=2`（那 2 条 FAIL 是**工具的度量缺陷**，见 §4.2，不是设计缺陷）

---

## 3. 判据表（逐条：判据 / 期望来源 / 实测 / 判定）

### 3.1 B 组 —— 快照窗口

| # | 判据 | 期望来源 | 实测 | 判定 |
|---|---|---|---|---|
| B1 | `SNAP_NW` == 各束之和 == `axi_regs.SNAP_NW` | 【先例】`wrapper_p4.v:3078` `SNAP_NW_P6E=51` | 51（静态核） | **PASS** |
| B2 | `snap_idx`/`snap_base` 位宽**同时**加宽 | 【先例】`axi_regs.v:212(6 位),227(12 位)` | 6 位 / 12 位（静态核；51 字要求 6/11） | **PASS** |
| B3 | 逐字读回**每一个**快照字（含末字） | 【先例】`P6E_OBS.md` 7 处清单 | **W0..W50 全 51 字读出且无 `0xffffffff`**；末字 `W50@0xE8` 读到（旧脚本只到 `0xAC`） | **PASS** |
| B4 | 两束索引表与拼接项数逐项一致 | 【先例】`snap_seq.v:86-121` | 51 字无下标重复、无别名回绕（`B_WIN` PASS） | **PASS** |
| B5 | "未实现地址"已随窗口更新 | 【先例】`P6E_OBS.md:105` ⑤（旧 `0xB0`） | **`0xEC`** 回 `0xffffffff`；**同趟**已实现字 `0x14` 仍回 `0xdeadbeef` | **PASS** |
| B6 | 窗口字数 **≤ 56** | 【自算】`ar_word=araddr[7:2]` 6 位 | 51 ≤ 56 | **PASS** |
| B7 | 每个新时钟域都有 32 位自由计数 | 【先例】W5/W24 | `W5`(FE 恢复钟) / `W24`(DP) / `W50`(TX MII toggle) 三域各 1 字，且**都在涨** | **PASS** |
| B8 | 各束拼接恰好 `NW*32` 位 | 【先例】静默截断史 | 51 字全部读出、无 X/无 0 填充、无别名 ⇒ 无截断征象 | **PASS** |
| B9 | 缺口①：`stat_flush_words`/`stat_flush_done` 已接出 | 【先例】`wrapper_p4.v:2226-2239` 未连接 | **W41=0 / W42=0** 两字均在窗口内 | **PASS** |
| B10 | 缺口②：两个 `fifo_async.ovf_cnt` 已接出 | 【先例】`P6E_OBS.md:86-87` 悬空 | **W38(rxcdc)/W45(txcdc)** 两字均在窗口内，读数 0 | **PASS** |
| B11 | 束数与定序方向已随新域扩展写明 | 【自算】新增 3 域 | 51 字窗口读回自洽；`W0−W30` 方向性由 `B_DIR` 覆盖 | **PASS** |

### 3.2 C 组 —— PCS/链路状态（`W39`/`W40`）

`W39 = 0x2000100C` 逐位解码：

| # | 判据 | 期望来源 | 实测 | 判定 |
|---|---|---|---|---|
| C1 | `gtpowergood = 1` | 【.veo】 | bit29 = **1** | **PASS** |
| C2 | `stat_rx_block_lock = 1` | 【.veo】 | bit2 = **1** | **PASS** |
| C3 | `stat_rx_status = 1` | 【.veo】 | bit3 = **1** | **PASS** |
| C4 | `stat_rx_hi_ber = 0` | 【.veo】 | bit4 = **0** | **PASS** |
| C5 | `rx/tx_local_fault = 0` | 【.veo】 | bit5 = 0 / bit6 = 0 | **PASS** |
| C6 | `framing_err` 累计 = 0 | 【.veo】 | bit8 = 0；`W40` 事件段 = 0 | **PASS** |
| C7 | `bad_code` / `rx_error[7:0]` / `fifo_error` = 0 | 【.veo】 | bit10=0 · `(v>>13)&0xff`=0 · bit11=0；`rx_error_valid`(bit21)=0 | **PASS** |
| C8 | ⭐ `valid_ctrl_code` **非 0 且在涨** | 【自算】正证据防"恒 0 假干净" | `W40` 低 8 位 = **0xFF（非 0 ✅）**，但**已饱和**（两块快照都是 0xFF）⇒ **"在涨"无法证明** | **PASS(部分)** —— 非零正证据成立；"随窗口单调增"**不可判**（8 位饱和计数器） |
| C9 | 三域自由计数 Δ/墙钟 = 标称 ±1% | 【先例】W5/W24 口径 | 见 §3.3 | **PASS** |

### 3.3 G2/C9 —— 频率（独立两点测量，非脚本口径）

⚠️ **`p6e_snap_check.sh` 的 `freq_check()` 有度量缺陷**（§4.2），故本轮**另做**独立测量：
`触发→等 done→读字→记墙钟`，两次触发相隔 ~5 s；真实间隔落在 `[5.002403, 5.025897] s`
（区间中点 5.014150 s，半展宽 **0.234%**，远小于 ±1% 门限）。

| 域 | 字 | Δ | **实测频率** | 标称 | 判定 |
|---|---|---|---|---|---|
| 前端域 = **PCS 恢复钟** `rx_core_clk`（`P7B_10G` 分支 `assign gmii_clk = rx_clk_out_1`） | W5 | 783,203,164 | **156.1986 MHz** | 156.25 | **PASS**（−0.033%） |
| 数据面域 `dp_clk`（MMCM） | W24 | 783,200,189 | **156.1980 MHz** | 156.25 | **PASS**（−0.033%） |
| TX MII 域（W50 toggle 沿） | W50 | 781,408,336 | **155.8406 MHz（÷1 口径）** | 156.25 | **PASS**（−0.262%） |

- ⭐ **W50 的 ÷1/÷2 口径被钉死 = ÷1**（÷2 得 77.92 MHz，偏离 50%）⇒ `wrapper_p4.v:3389` 的
  "÷2"注释**需订正**，`P7B_GATE4_TOOLING.md` §7 警告 1 的分析**是对的**。
- ⭐ **W5 的标称是 156.25，不是 125**：`W5/W24 的 Δ 比值 = 1.0000038`（两域同频）⇒ 环境级独立证否
  "W5=125 MHz"这个 P6b 时代的假设。旧脚本把 W5 标称写成 125 才报 FAIL。

### 3.4 G 组 —— 观测完整性

| # | 判据 | 期望来源 | 实测 | 判定 |
|---|---|---|---|---|
| G1 | 位流 sha256 + `BUILD_ID` 前置闸 | 【先例】`P6E_OBS.md:29` | sha256 已记 + BID=7（本轮新值） | **PASS** |
| G2 | `SNAP_STATUS.gen` **恰好 +1**；无空读 | 【先例】`p6b_accept.sh` 四层守卫 | 每轮 `gen` 恰好 +1（`GEN 0 1`）；51 字无空读、无 `0xffffffff` | **PASS** |
| G3 | **停机态守恒律逐字成立** | 【先例】`P6B_ACCEPT.md` E1a/E1b | 快照①：`W30=69 == W0+W32=69` ✅ · `W31=10912 == W1−4·W0+W33=10912` ✅；快照②同式再成立（`114/120`、`16780`） | **PASS** |
| G4 | 未实现地址回 `0xffffffff` + 同趟已实现字对照 | 【先例】`P6B_ACCEPT.md` A5 | `0xEC=0xffffffff`；`0x00=0x50360001`、`0x14=0xdeadbeef` | **PASS** |

### 3.5 E4 / B_G6 —— `rx_classify` 修复的板级判据

| # | 判据 | 期望来源 | 实测 | 判定 |
|---|---|---|---|---|
| E4/G6 | 最小帧洪泛下 `stat_drop_full`(W34) 增量 **恒 0** | 【审计】§4.3 | 洪泛窗 `ΔW34 = 0` | ⚠️ **形式 PASS，但无判别力**：本轮 app 通路死（§4），**洪泛根本没发生**（`ΔW20=0`，即窗口内板子零发帧）⇒ 这个 0 是"没激励"的 0，不是"扛住了"的 0。**不得当 E4 通过引用。** |

### 3.6 F 组 —— 端到端

| # | 判据 | 期望来源 | 实测 | 判定 |
|---|---|---|---|---|
| F1 | NIC 侧 `Link detected: yes` + `Speed: 10000Mb/s`（= 802.3 独立实现对线速率/64b66b/同步头/加扰/block lock 的总裁决） | 【802.3】§5.2 E1 | `carrier=1` `operstate=up` `speed=10000` | **PASS** |
| F2 | 10G 口上 `ping` 通 | 【802.3】§6.1 F2 | **5/5 通**，rtt min/avg/max = `0.086/0.122/0.201 ms`；ARP 解到 `00:0a:35:01:fe:c0` | **PASS** |
| F3 | 图案流**逐字节** | 【先例】P6b 三口径 | **收 0 帧 / 0 字节 / 15.18 s**（工具退出码非 0） | ❌ **FAIL** |
| F4 | 速率：板子自报 × 帧长 与 网卡硬件计数对账（偏差 <1%） | 【先例】P6b 956.0 Mbps 口径 | 板侧 `ΔW20=0`、板侧 `W8/W9=0`；网卡 `Δport_rx_1024_to_15xx=0`、`Δport_rx_bytes` 无 1518B 贡献 | ❌ **FAIL**（无从对账：图案通路零帧） |
| F5 | TCP fast path 在 10G 下不掉链 | 【先例】P6b 基线 | 本轮**未跑 TCP 激励**（`W22/W23` 恒 0，未被激励） | **SKIP（未测）** |

### 3.7 N 组 —— NIC 侧四件套 + 判别力自检（`p7b_gate4_accept.sh`）

| 判据 | 期望 | 实测 | 判定 |
|---|---|---|---|
| N_CRC | `Δrx_eth_crc_err == 0` | **0**（重启后整场恒 0） | **PASS** |
| N_BAD | `Δport_rx_bad == 0` | 0 | **PASS** |
| ⭐N_BASE | 同一套 N_RATE 跑**基线窗**必须**不成立**（判别力自检） | 基线 `Δport_rx_good = 0` ⇒ 判据确实不成立 | **PASS** |
| N_RATE | `Δport_rx_good ≥ 1e5` 且 ≥800 Mbps | `Δ=0 帧` | **FAIL** |
| N_UCAST | `Δport_rx_unicast ≥ 0.9·Δgood` | `Δuni=0`（背景是广播：`broadcast=1527`, `unicast=11`） | **FAIL** |
| N_LEN | `Δ1024_to_15xx ≥ 0.9Δgood` 且 `Δ64 ≤ 0.1Δgood` | 1518 桶 = 0、64 桶 = 0 | **FAIL** |
| N_AVG | `Δbytes/Δpackets ≈ 1518` | `Δpackets=0` | **SKIP** |
| N_SELF | `Δgood+Δbad == Δpackets` | `0+0 == 0` | ⚠️ **形式 PASS，真空**（分母为 0 的自洽不是证据） |
| N_XCHK | 板侧 `ΔW20×1518×8/Δt` vs 网卡 `Δbytes×8/Δt`（<1%） | `ΔW20=0` ⇒ 无从对账 | **SKIP** |

### 3.8 负对照

| # | 做法 | 期望 | 实测 | 判定 |
|---|---|---|---|---|
| N-a | 拉高被连通道 `TX_DIS`（`pcie_scratch[1]`） | 网卡**必须**掉 carrier | ⭐ **按期望翻转**：`carrier 1→0`、`carrier_changes 1→2`、`operstate=down`；写回 0 ⇒ `carrier 0→1`、`carrier_up_count →2`。⇒ **链路是我们维持的、SFP 控制脚映射正确** | **PASS** |
| N-b | `--no-teach` ⇒ 零图案帧 | 只有背景小帧 | **无法做**：见 §4.3 | **SKIP（无判别力）** |

---

## 4. 三项发现（都带原始证据）

### 4.1 ⚠️ runbook 的 `TX_DIS` 寄存器地址是错的（**已在本轮订正**）

`P7B_GATE4_PLAN.md` §6.1 写"写 `0x10` 的 bit1"。实测：**`0x10` 是只读的 `HW_STATUS`**，
写进去毫无效果（读回恒 `0x18`），`carrier` 纹丝不动 ⇒ **按 runbook 跑会得到"负对照不翻转"的假故障**。
`_proj_pcie/rtl/axi_regs.v:104,240` 明写 **`scratch` 在 `0x08`**（`w_word==6'd2`）。
⇒ **正确命令 = `reg_rw /dev/xdma0_user 0x08 w 0x2`**，实测立刻翻转到 `carrier=0`。
（原始证据：`live/negctrl_TXDIS.txt` 的两段——第一段 0x10 不动、第二段 0x08 翻转。）

### 4.2 ⚠️ `p6e_snap_check.sh` 的 `freq_check()` 有度量缺陷（**未改脚本**，改用独立测量）

`freq_check()` 的顺序是 `a=rd(字)` **→** `t1=date` **→** `snap_take`(触发) **→** `b=rd(字)` **→** `t2=date`，
分母用 `t2−t1`。问题：**`a` 是上一次触发锁存的陈旧值**（快照字只在触发时刷新），
而 `t1` 却记在**本次触发之前** ⇒ 真实间隔 `latchA→latchB` **大于** `t2−t1` ⇒ 频率被系统性**高估**。
实测后果：W5 报 **371.04 MHz**、W24 报 **293.58 MHz**（物理不可能，两者都超过 156.25 的 2 倍以上），
两条 `[FAIL]` 是**度量伪影**。另有 W5 标称写死 125（P6b 口径，见 §3.3）。
⇒ 本轮按 `P7B_GATE4_TOOLING.md` §8 的授权**改用 `p6e_snap_check.sh` 的窗口读数 + 自建两点测量**，
脚本本体**一字未改**（原始输出留档 `live/snap_check_halt.txt`，含那两条 FAIL 的原样文本）。

### 4.3 ⭐ 新发现：**app-UDP 分流路径在板上失效**（F3/F4 的根因）

**证据链（每步独立可复核）**：

1. **教学帧确实上了线**：对端 `tcpdump -i enp1s0f1np1` 抓到
   `00:0f:53:2c:68:01 > 00:0a:35:01:fe:c0, IPv4, length 142, 192.168.100.100.50177 > 192.168.100.2.8081, UDP length 100`
   ⇒ dst MAC / dst IP / **dst port 8081** 全部正确（`live/teach_probe.txt`）。
2. **板子收到了**：`W0` (MAC 收帧) `0x77→0x78`（**+1**），且 `W3` (FCS 错帧) 恒 **0** ⇒ **帧好、FCS 对**。
3. **但被交给慢路径**：`W6` (srx_stat_commit → HLS) 同步 `+1` ⇒ `udp_split` **没有认领**它，原样透传给了 HLS。
4. **app 从未收到**：`W10` (udpapp_rx_frames) 恒 **0**、`W12/W13` = 0；⇒ `udp_split.meta_valid` 从未脉冲
   ⇒ **peer 表空** ⇒ `udp_tx_cfg.o_ready = 0` ⇒ `W8/W9`（图案 app 发帧/字节）恒 **0** ⇒ 板子一个图案帧都不发。
5. **对照实验（定位到分流层，不是 RX/MAC/HLS）**：把同一个对端发一个 UDP 帧到 **8080**（HLS `udp_echo` 口）
   ⇒ 板子**正确回显**（`reply ... len 49, b'P7BG4ECHO...'`），`W0 +1`、`W6 +1`、`W7/W20 +3`。
   ⇒ **RX 解析、IPv4/UDP 校验、新 64 位 MAC、HLS 慢路径全部正常**（与 `ping 5/5` 互相印证）。
   ⇒ 失效点**精确落在 `rx_classify → udp_split` 的 app 端口匹配**这一层。
6. **静态核对无异常**：`wrapper_p4.v` 的配置与规格一致 ——
   `.cfg_dst_ip(32'hC0A86402 /*192.168.100.2*/)`、`.cfg_port0(UDP_APP_PORT=16'h1F91 /*8081*/)`、
   `.cfg_port_any(1'b0)`、`.cfg_multi_en(1'b0)`；`udp_split` 例化在 `ifdef APP_MODE` 内（本轮 `APP_MODE=1`），
   位于 `classify.m_slow → slow_rx_adp` 之间；`EXCL_PORT=8080`。
   ⇒ **配置面看不出原因**。

**归因**：**「`udp_split` 未把发往 192.168.100.2:8081 的 UDP 帧判为 app 帧」这一层已由实验钉死；
再往下（是端口比较的取拍、还是 `udp_rx` 子例化的匹配时序在本构建里错位）—— **未归因**，
需仿真插桩或新增快照字（现 51 字里**没有任何一个字**暴露 `udp_split` 的
`stat_app_frames`/`stat_hls_frames`/`stat_drop_excl`，这一层目前是观测盲区）。**

**为什么从既有门里逃逸**：P5e-T3 的 app 门与 T5 的真 wrapper 门验的是 **1G 前端**构建；
P7b 的"链级门 80 判据"覆盖的是新 MAC 的帧流合同。**"P7B_10G 构建下 RX→app 端口分流"没有专属门**
⇒ 与工程坑 8/25 同族（每个 `ifdef` 配置都要有一条真 wrapper 全链门；事件/表项驱动必须单独回答"生产者是谁"）。

---

## 5. 未测 / 不可判（**不得当通过引用**）

| # | 项 | 状态 |
|---|---|---|
| 1 | **F5 TCP fast path @10G** | 本轮未跑 TCP 激励（`W22/W23` 恒 0）⇒ **未测** |
| 2 | **G4 速率对账 (N_XCHK)** | `ΔW20=0` ⇒ 无从对账 ⇒ **未测** |
| 3 | **E4 最小帧洪泛** | 洪泛未发生（app 通路死）⇒ 该 0 **无判别力** |
| 4 | **N-b (`--no-teach`)** | 板子本来就零图案帧 ⇒ 正/负对照不可分 ⇒ **无判别力**，不做 |
| 5 | **C8 "随窗口单调增"** | 8 位饱和计数器（恒 `0xFF`）⇒ **不可判** |
| 6 | **N_SELF** | 分母为 0 的 0==0 ⇒ 形式 PASS，**真空** |
| 7 | **B 组 B1/B2/B4/B8** | 静态核对（读源码/工具链），非板级读数 ⇒ 以"静态 PASS"标注 |

---

## 6. 原始日志落盘路径（全部在本仓内）

| 文件 | 内容 |
|---|---|
| `_proj_10g/notes/p7b_gate4/g4_program_stdout.txt` | 烧录日志（`End of startup status: HIGH`、QSPI 命中 0） |
| `_proj_10g/notes/p7b_gate4/program_p7b_ku5p.tcl` · `run_program_p7b.bat` | 本轮新建的烧录脚本（照抄 `_proj_pcie/program_p6e.tcl` 模板） |
| `_proj_10g/notes/p7b_gate4/py_nocrlf.sh` | **环境补丁**（见 §7），不改任何验收脚本 |
| `_proj_10g/notes/p7b_gate4/live/stage1_stdout.txt` | 停机态档（`G4_SKIP_TRAFFIC=1`，PASS=4 FAIL=0 SKIP=1） |
| `_proj_10g/notes/p7b_gate4/live/stage3_full_fixed_traffic.txt` | **全链档**（PASS=8 FAIL=3 SKIP=1，EXIT=1） |
| `_proj_10g/notes/p7b_gate4/live/stage1_attempt1_crlf_ABORT.txt` · `snap_A_crlf_attempt1.txt` | CRLF 导致 ABORT 的原始件（见 §7） |
| `_proj_10g/notes/p7b_gate4/live/snap_check_halt.txt` | 板侧 51 字窗口 + 4.3 频率段（含两条度量伪影 FAIL 的原样文本） |
| `_proj_10g/notes/p7b_gate4/live/freq_raw.txt` | **独立两点频率测量**原始读数 |
| `_proj_10g/notes/p7b_gate4/live/teach_probe.txt` · `teach_probe2.txt` | 教学帧 tcpdump + 板侧 `W0/W6/W10` 增量（§4.3 证据 1–4） |
| `_proj_10g/notes/p7b_gate4/live/udp8080_probe.txt` | **对照实验**：UDP:8080 echo 逐字节回显（§4.3 证据 5） |
| `_proj_10g/notes/p7b_gate4/live/negctrl_TXDIS.txt` | N-a 负对照（0x10 无效 / **0x08 翻转**两段） |
| `_proj_10g/notes/p7b_gate4/live/snap_post_teach_attempt.txt` | 第二次 51 字窗口读数 |
| `_proj_10g/notes/p7b_gate4/live/nic_*.txt` · `snap_*.txt` | 验收脚本落盘的 NIC 与快照原始文本 |

---

## 7. ⚠️ 工具缺陷：`p7b_gate4_accept.sh` 的 **live 路径从未被跑过**（三处，均未改脚本）

`P7B_GATE4_TOOLING.md` 自己声明"live 路径没有跑过（只跑过假板子）"。本轮首次上板，
**合成文本路径过关而 live 路径三处失效** —— 都属"环境/接线"层，故**未改脚本**：

1. **CRLF**：`peer_ssh.py` 用 **Windows Python** 的 stdout 输出远程 Linux 的 LF 文本 ⇒ 被
   `os.linesep` 翻成 **CRLF** ⇒ `parse_snap` 的严格正则 `^0[xX][0-9a-fA-F]{1,8}$` 不匹配 ⇒ 前置闸 ABORT（退出 2）。
   证据：`python tools/peer_ssh.py "echo AAA; echo BBB" | od -c` = `A A A \r \n`；
   而对端机上同一读经 `od -c` = `0 x 0 0 ... 1 9 \n`（**无 \r**）。
   ⇒ 补丁 = `py_nocrlf.sh`（`tr -d '\r'` + 保留退出码），**用 `PY=` 覆盖注入**，脚本零改动。
2. **live 档永远只取一块快照**：`nsf` 只在 `G4_SNAP_TEXT` 非空时被赋值 ⇒ live 模式下
   `nsf` 恒 1 ⇒ `snap_fetch` 的"第二块"分支**不可达** ⇒ **G2 频率 / G3 守恒 / C 组 PCS / C8 / B_G6 / N_XCHK
   在 live 模式下全部被 SKIP**。⇒ 本轮按任务书改用 `p6e_snap_check.sh` 取板侧 B/C/E4/G（§2、§3.1–3.4）。
3. **`G4_TRAFFIC_CMD` 首词是绝对路径时被 MSYS 改写**：`/home/a/xdma_test/p6e_udp_pattern ...`
   被 MSYS 转成 `C:/Program Files/Git/home/...` ⇒ 远程报 `bash: line 1: C:/Program: No such file or directory`
   ⇒ 激励**静默没跑**（但 NIC 判据照常打 FAIL，**看着像板子坏了**）。
   ⇒ 绕法 = `G4_TRAFFIC_CMD="cd /home/a/xdma_test && ./p6e_udp_pattern ..."`（首词 `cd` ⇒ 不触发转换）。

另：`peer_ssh.py --put` 在本机**不可用**（远程 sftp open 报 `FileNotFoundError`），
本轮部署 `p6e_snap_check.sh` 改用 `scp`（同一把 key，`BatchMode=yes`，实测可用）。

---

## 8. 收尾状态（交接）

- **FPGA**：仍加载 **P7b 位流**（`d1ddb3b4…87aa`），**app 通路死 ⇒ 不发图案帧**；只有 HLS 的
  HELLO/ARP 背景流量（网卡侧 `port_rx_good` 以 ~0.1–0.5 帧/s 缓涨，全是广播）。
- **对端机**：`xdma.ko` 已 insmod，`/dev/xdma0_user` 可读；**临时网络配置已复原**
  （`enp1s0f1np1` 无 IPv4 地址、无 `192.168.100.*` 路由）；`hw_server` active。
- **下次测量前**：按纪律**重新烧录 + 重启对端机**（本轮读数只对应本 sha256）。
- **建议的下一步**（不在本单范围）：① 给 `udp_split` 的
  `stat_app_frames`/`stat_hls_frames`/`stat_drop_excl` 接出**快照字**（现在 51 字里没有 ⇒ 观测盲区）；
  ② 给"P7B_10G 构建下的 RX→app 分流"补一条**真 wrapper 全链门**（工程坑 8/25）。
