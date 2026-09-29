# P7B 未核实项闭合 —— U7（`swapn` 原文）与对端机现状

日期 **2026-09-29**（本机时钟；对端机时区同时刻为 `Tue Sep 29 07:42:38 PM CST 2026`）。
本轮**只读**：只新建本文件；未烧板、未碰 QSPI、未跑 Vivado、未改对端机任何配置/服务、无任何 git 写操作。

---

# A 节 —— `pcs64_pkt_gen_mon.v` 的 `swapn` 原文与字节序定案

> 目的：P7B_SPEC §11 的 **U7**（"`pcs64_pkt_gen_mon.v` 的 `swapn` 语义我**没有逐行读原文**"）。
> 结论先说：**文件找到了、是明文、读通了；规格 §3.3 的字节序论断方向正确，转述的行号逐条命中。**

## A.0 文件定位

| 项 | 值 |
|---|---|
| 路径 | `D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\xxv_probe\pcs64_ex\pcs64_ex\imports\pcs64_pkt_gen_mon.v` |
| 形态 | **明文 Verilog**（非加密、非 netlist），2374 行 / 145,846 B |
| sha256（前 32 位） | `2782d688b5ea4e676be4e984735f759d` |
| 同目录同批 | `pcs64_exdes.v`、`pcs64_exdes_tb.v`、`pcs64_example_top.xdc`（均明文） |
| 兄弟文件（MAC+PCS 变体） | `.../xxv_probe/macpcs64_ex/macpcs64_ex/imports/macpcs64_pkt_gen_mon.v`（155,290 B，也明文） |

**模块切分**（`grep -n "^module\|^endmodule"`）：

| 模块 | 行范围 | 角色 |
|---|---|---|
| `pcs64_mii_pkt_gen` | **926–1243** | ⭐ **TX 图案发生器 —— 全部 `swapn` 都在这里** |
| `pcs64_mii_traf_chk` | 1244–1469 | RX 检查器（吃 `rx_mii_d`） |
| `pcs64_mii_traf_gen_chk` | 1470–1606 | TX 计数/检查（吃 `tx_mii_d`） |
| `pcs64_pcs_pktprbs_gen` | 1607–2374 | PCS 层 PRBS 图案 |
| （另有 `pcs64_pkt_gen_mon` / `pcs64_cdc_sync_2stage` / `pcs64_mii_traffic_gen_mon` / `pcs64_example_fsm` 在 63–924） | | 包装层 |

## A.1 `swapn` 定义原文（`pcs64_pkt_gen_mon.v:1238-1241`）

```verilog
function [63:0]  swapn (input [63:0]  d);
integer i;
for (i=0; i<=(63); i=i+8) swapn[i+:8] = d[(63-i)-:8];
endfunction
```

逐项展开（i 取 0,8,16,…,56）：

| i | `swapn[i+:8]` | `= d[(63-i)-:8]` |
|---|---|---|
| 0 | `swapn[7:0]` | `d[63:56]` |
| 8 | `swapn[15:8]` | `d[55:48]` |
| 16 | `swapn[23:16]` | `d[47:40]` |
| 24 | `swapn[31:24]` | `d[39:32]` |
| 32 | `swapn[39:32]` | `d[31:24]` |
| 40 | `swapn[47:40]` | `d[23:16]` |
| 48 | `swapn[55:48]` | `d[15:8]` |
| 56 | `swapn[63:56]` | `d[7:0]` |

⇒ **纯 8 字节整字倒序**（byte i ↔ byte 7−i）。**字节内部位序不动**。

## A.2 `swapn` 的调用点（共 5 处，全部在 TX 侧）

| 行号 | 原文 | 目标信号 |
|---|---|---|
| `:1121` | `d_buff <= swapn(nxt_d);` | `d_buff`（CRC/LFSR 通路寄存器） |
| `:1135` | `d_buff <= swapn(nxt_d);` | 同上（S4/S5 状态） |
| `:1148` | `tx_mii_d <= swapn(tx_datain);` | ⭐ **XGMII TX 数据总线** |
| `:1155` | `tx_mii_d <= swapn(tx_datain);` | ⭐ 同上（`en_residue` 修正 CRC 残位那一拍） |
| `:1187` | `tx_mii_d <= swapn ( tmp_dat ) ;` | ⭐ 同上（在 `task end_packet` 里，末字） |

## A.3 作用在哪个信号上 —— **只有 TX；RX 侧没有任何交换**

1. **TX 侧**：`swapn` 作用在 `tx_mii_d`（3 处）+ `d_buff`（2 处）。`tx_mii_d` 的方向是
   `pcs64_mii_pkt_gen` 的 `output reg [63:0] tx_mii_d`（`:939`）。
2. **RX 侧无交换**：
   - `:613-626` `pcs64_mii_traf_chk i_pcs64_TRAF_CHK1` 吃 **原始** `rx_mii_d`（`.mii_d ( rx_mii_d ),` `:621`），
     其内部只按 `mii_d[i*8+:8]` 直接找 `/S/`、`/T/`，**不经过 `swapn`**。
   - `:657-664` `pcs64_mii_traf_gen_chk i_pcs64_TRAF_CHK2` 吃 `tx_mii_d`（`.mii_d ( tx_mii_d ),` `:663`）——
     同样是"已交换后的 XGMII 车道序"，也没再交换。
3. **核与发生器之间没有第二处交换**：`pcs64_exdes.v:314-315` 把 `.tx_mii_d (tx_mii_d_0)` / `.tx_mii_c (tx_mii_c_0)`
   直连核的 `tx_mii_d_0`/`tx_mii_c_0`；`:284-285` 把 `.rx_mii_d (rx_mii_d_0)` 直连。
   ⇒ 全链路只有 `swapn` 这一处字节序处理。

> ⚠️ 措辞精确化：`d_buff`（`:1121/:1135`）**不是**"接口上的字节序翻转"。它喂的是
> `op_data = d_buff`（`:1042`，`default` 分支），而 `op_data` 又会在 `:1148` **被 `swapn` 第二次修饰**。
> 在本配置里 `assign data_select = 2'b0`（`:988`）⇒ `d_sel==2'b00` ⇒ `op_data = {64{1'b0}}`（`:1040`），
> 所以 `d_buff` 这条路在本配置下**不产生载荷**。**§3.3 的结论只依赖 `:1148/:1155/:1187` 三行**，与 `d_buff` 无关。

## A.4 它是否就是 `tx_mii_d` 与内部 64 位字之间的字节序翻转

**是。** 而且方向是：**内部字（左对齐，帧首字节在 `[63:56]`）→ `swapn` → `tx_mii_d`（帧首字节在 `[7:0]`）**。

## A.5 映射关系（逐位写清）—— lane0 落在内部字的哪一端

由 `:1148` + `:1238-1241` 直接得到：

| XGMII（`tx_mii_d`） | = 内部字 `tx_datain` 的哪 8 位 |
|---|---|
| `tx_mii_d[7:0]`（**lane 0**） | `tx_datain[63:56]` |
| `tx_mii_d[15:8]`（lane 1） | `tx_datain[55:48]` |
| `tx_mii_d[23:16]`（lane 2） | `tx_datain[47:40]` |
| `tx_mii_d[31:24]`（lane 3） | `tx_datain[39:32]` |
| `tx_mii_d[39:32]`（lane 4） | `tx_datain[31:24]` |
| `tx_mii_d[47:40]`（lane 5） | `tx_datain[23:16]` |
| `tx_mii_d[55:48]`（lane 6） | `tx_datain[15:8]` |
| `tx_mii_d[63:56]`（lane 7） | `tx_datain[7:0]` |

**⇒ `mii_d[7:0]`（lane 0）= 帧首字节；内部字把帧首字节放在 `[63:56]`（左对齐/MSB 端）。**

⚠️ 注意这不是"我们合同 vs 官方"的映射，而是"**官方发生器内部缓冲** vs **官方 XGMII 端口**"的映射。
对 P7b 直接有用的是下一条（A.6 的结论）：**官方 XGMII 端口本身就是 lane0（`[7:0]`）= 帧首字节**。

## A.6 为什么"lane0 = bits[7:0]"是硬的 —— **五条互相独立的证据**

**证据 1（最强，自洽且不依赖任何"约定"假设）—— preamble 常量 + 额按序取头**

```verilog
:995   localparam [63:0] preamble   = 64'hFB_55_55_55_55_55_55_D5 ;      // Broadcast
:996   localparam [47:0] dest_addr   = 48'hFF_FF_FF_FF_FF_FF;            // Broadcast
:997   localparam [47:0] source_addr = 48'h14_FE_B5_DD_9A_82;            // Hardware address of xowjcoppens40
:998   localparam [15:0] length_type = 16'h0600;                       // XEROX NS IDP
:999   localparam [175:0] eth_header = { preamble, dest_addr, source_addr, length_type} ;
:1145                else tx_datain = eth_header[header_bit_count-:64] ;
```
- `preamble` 写成 MSB-first 就是 `FB 55 55 55 55 55 55 D5` —— 正好是
  **`/S/`(0xFB) + 6×0x55 + SFD(0xD5)**，即 IEEE 802.3 的 8 字符前导（`/S/` 顶掉第 1 个 preamble 八位组）。
- 首个 TX 字：`header_bit_count` 初值 175（`:1128` `header_bit_count <= 9'd175 ;`），
  `175 >= 63` ⇒ 走 `:1145` ⇒ `tx_datain = eth_header[175:112] = preamble` ⇒
  **`tx_datain[63:56] = 0xFB`**。
- `:1148` `tx_mii_d <= swapn(tx_datain)` ⇒ **`tx_mii_d[7:0] = 0xFB`**。
- IEEE 46.2.2 硬性要求 **`/S/` 必须在 lane 0**（本仓已核：`P7B_BASER_TABLES.md:58,162,181`）⇒
  **lane 0 = `tx_mii_d[7:0]`**，且内部字是左对齐（preamble 的 MSB 字节就是首发字节）。

**证据 2 —— 起始字把控制位 0 拉高（lane 0 是控制字符）**
```verilog
:1147              tx_mii_c <= { 8 { 1'b0 }} ;
:1148              tx_mii_d <= swapn(tx_datain);
:1149              if(state==S4) tx_mii_c[0] <= 1'b1;
```
S4 = 帧首字 ⇒ `tx_mii_c[0]`=1（lane 0 是控制字符）。控制与数据同 lane 编号 ⇒ lane 0 ↔ `tx_mii_c[0]`/`tx_mii_d[7:0]`。

**证据 3 —— 帧尾 `/T/` 落 lane 0（字边界特例）**
```verilog
:1169    if(set_eop) begin tx_mii_d[0+:8] <= 8'hFD ; tx_mii_c[0] <= 1'b1; end
```
`set_eop <= (full_bits==0)`（`:1197`）⇒ 帧恰好在字边界结束的那一拍，`/T/` 进 **lane 0**。

**证据 4 —— 帧尾 `/T/` 落 lane = "已发字节数"（一般情形）**
```verilog
:1021  localparam integer full_bits = xfer_rmdr * 8,
:1199    if(full_bits != 0 ) tx_mii_d[full_bits+:8] <= 8'hFD ;
```
`full_bits` 是末字的有效位数 ⇒ `tx_mii_d[full_bits+:8]` 即"前 `full_bits/8` 个 lane 已被数据占满，
`/T/` 落在下一个 lane" ⇒ **lane i ↔ bits[8i+:8]**。与证据 1/2/3 完全一致。

**证据 5 —— RX 侧检查器（**无 `swapn`**）按同样的 lane 编号找 `/S/` 与 `/T/`**
```verilog
:1366            for(i=0; i<7;i=i+4) if( (mii_d[i*8+:8] == 8'hFB) && mii_c[i] ) begin start_flag = 1; byte_count = 8-i; end
:1378            for(i=7;i>=0;i=i-1) if( (mii_d[i*8+:8] == 8'hFD) && mii_c[i] ) begin end_flag = 1; byte_count1 = i; end
:1549            for(i=0; i<7;i=i+4) if( (mii_d[i*8+:8] == 8'hFB) && mii_c[i] ) begin start_flag = 1; byte_count = 8-i; end
:1561            for(i=7;i>=0;i=i-1) if( (mii_d[i*8+:8] == 8'hFD) && mii_c[i] ) begin end_flag = 1; byte_count1 = i; end
```
`mii_d` 这里是**原始 `rx_mii_d`**（`:621`），且 `:1366` 的 `i<7` / `i=0,4` 步长正是
"`/S/` 只能落在 lane 0 或 lane 4"（64 位 XGMII 上帧首两拍位置）⇒ **lane i ↔ bits[8i+:8]，lane 0 = `[7:0]`**。

### A.6.1 转述行号核对结果

| 规格/笔记里的转述 | 核对结果 |
|---|---|
| `:1148` `tx_mii_d <= swapn(tx_datain);` | ✅ **逐字命中** |
| `:1240` `swapn[i+:8] = d[(63-i)-:8];` | ✅ **逐字命中**（函数定义在 `:1238-1241`） |
| `:1199` `tx_mii_d[full_bits+:8] <= 8'hFD` | ✅ **命中**（原文含 `if(full_bits != 0 )` 前缀与尾分号） |
| `:1169` `tx_mii_d[0+:8] <= 8'hFD` | ✅ **命中** |
| `:1078` `tx_mii_d <= {8{8'h07}}`（idle） | ✅ **命中**（另一处同文在 `:1097`，带 `// default to idle` 注释） |

⇒ **转述的行号没有一个是错的**（U7 可以关掉）。

## A.7 有没有配套的**位序**（bit order）翻转？—— **没有**

`swapn` 只做字节序（`:1240` 的循环步长 `i=i+8`，每次搬整个 8 位字节）。**字节内位序不动。**
本文件里另有一个 `crc_swapn`（在 macpcs64 变体 `:2826-2828`）是**逐位**置换，但它只服务于
**CRC 多项式方向**，与接口字节序无关 —— ⚠️ 别把两者混淆。
（`BIT_REVERSE` 那种"64 位整字逐位反转"在本文件里**不存在**。）

## A.8 与另一份独立来源对账 —— **两源一致**

被对账的结论（`_proj_10g/notes/P7B_LIB_SURVEY.md:485`，`P7B_BASER_TABLES.md:148-165`）：

> **`XGMII lane0 = txd[7:0]` = 线上首字节**；证据 = `verilog-ethernet` 的
> `axis_xgmii_tx_64.v:369 / :409` 与 `axis_xgmii_rx_64.v:208`（AXIS 字节道与 XGMII 车道 1:1）；
> 而 `BIT_REVERSE` 同时翻 64 位 data 与 2 位同步头（`eth_phy_10g_tx_if.v:95-106`、`rx_if.v:99-110`）。

| 判据 | 来源①：官方 `pcs64_pkt_gen_mon.v` 的 `swapn`（本轮亲读） | 来源②：`verilog-ethernet` 的 `BIT_REVERSE`（笔记转述） |
|---|---|---|
| **XGMII lane 0 在哪一端** | `tx_mii_d[7:0]`（A.5/A.6） | `txd[7:0]` |
| **lane 0 是否 = 线上首字节** | 是（`/S/` 在 lane 0） | 是 |
| **相对"帧首字节在 `[63:56]`"的合同要不要镜像** | **要**（8 字节镜像） | **要**（8 字节车道反转，笔记列为"需要一层 shim"） |
| 翻转形态 | **字节序**（纯字节倒序） | 在 GT 边界是**逐位**反转（含字节序效果） |

**⇒ 两源一致（无冲突）**：都把"**lane 0 = bits[7:0] = 帧首字节**"钉在同一个方向，
都要求对 `tdata[63:56]`-首发的合同做 8 字节镜像。
翻转**形态**不同（字节序 vs 逐位）是因为两者作用在**不同接口**上（前者 = 发生器内部字 ↔ XGMII 端口；
后者 = fabric ↔ GT serdes），**不是矛盾**。

## A.9 对 P7b 的直接影响（一句话）

新 MAC 对官方 `xxv_ethernet`（`CORE = Ethernet PCS/PMA 64-bit`）的 XGMII 接口，
**必须做 8 字节镜像：我们的 `tdata[63:56]`（首字节）→ `tx_mii_d[7:0]`；`rx_mii_d[7:0]` → 我们的 `tdata[63:56]`**。
**纯字节级镜像即可，不需要位序翻转。** 方向若做反 = 全帧字节倒序（安静失效）——
A.6 的五条证据就是判据的"尺子"。

## A.10 附带发现（不影响方向，但别踩）

1. **`swapn` 在本配置下会双重抵消**：`d_buff <= swapn(nxt_d)`（`:1135`）→ `op_data = d_buff`（`:1042`）
   → `tx_datain = op_data`（`:1142`）→ `tx_mii_d <= swapn(tx_datain)`（`:1148`）
   ⇒ `tx_mii_d = nxt_d`。**但本配置 `data_select = 2'b0`（`:988`）使 `op_data = {64{1'b0}}`，
   这条"抵消"路径实际不产生载荷。** 写 TB 时别照抄这个推断。
2. 官方 example 把 **`rx_reset`/`tx_reset` 当输出驱动**、`user_*_reset` 当输入消费
   （`pcs64_exdes.v:266-315` 接线；`swapn` 所在模块的 `tx_reset` 是 `assign tx_reset = 1'b0;`）
   —— 与 `P7B_SPEC.md:173` 记的一致。

---

# B 节 —— 对端机 `192.168.0.38` 现状事实表

## B.0 访问方式（先记录，供下次复用）

| 项 | 值 |
|---|---|
| 可用命令 | `ssh -o BatchMode=yes a@192.168.0.38 '<cmd>'` ⇒ **免密可用**（本机 `~/.ssh/id_ed25519`，`known_hosts` 已有该机） |
| ⚠️ **用户名** | **`a`**。用 `zhxue@192.168.0.38` 会 **`Permission denied (publickey,password)`** |
| 主机名 / 内核 | `a-MS-7850` / `Linux 7.0.0-34-generic #34~24.04.1-Ubuntu SMP PREEMPT_DYNAMIC Fri Sep 4 15:38:29 UTC 2 x86_64` |
| 采集时刻 | 对端机 `date` = **`Tue Sep 29 07:42:38 PM CST 2026`**（命令窗口 ~19:42–19:56 CST） |
| 未用 root | `sudo -n true` ⇒ `sudo: a password is required`（**未使用任何密码，未提权**） |

## B.1 事实表

### B.1.1 SFC9120 在不在、驱动状态 —— ✅ **在，驱动正常**

| 项 | 事实 | 证据（命令） |
|---|---|---|
| 器件 | **`01:00.0` + `01:00.1`：Solarflare SFC9120 10G Ethernet Controller `[1924:0903]` (rev 01)** | `lspci -nn \| grep -i -E "sfc\|solarflare\|ethernet"` |
| 驱动 | **`sfc` 已加载**（`659456` B，引用计数 `0`） | `lsmod \| grep -i sfc` |
| 绑定 | 两个功能都 `Kernel driver in use: sfc` / `Kernel modules: sfc` | `lspci -vv -s 01:00.0` / `-s 01:00.1` |
| 固件 | `firmware-version: 6.2.7.1001 rx1 tx1`（driver `sfc`，`supports-eeprom-access: no`、`supports-register-dump: yes`） | `ethtool -i enp1s0f0np0` |
| dmesg 报错 | ⚠️ **未能取到 `dmesg`**（`dmesg: read kernel buffer failed: Operation not permitted`）⇒ 改读内核日志：`journalctl -k` 里 **只有 link up/down 事件、无 sfc 错误/复位告警** | `journalctl -k --no-pager \| grep -i -E "sfc\|solarflare"` |

### B.1.2 两个 10G 口的状态 —— ✅ **两口都空闲可用，但当前都无 link**

| 接口 | `phys_port_name` | MAC | `carrier` | `operstate` | `speed`(sysfs) | `carrier_changes` | `mtu` | IPv4 |
|---|---|---|---|---|---|---|---|---|
| `enp1s0f0np0` | `p0` | `00:0f:53:2c:68:00` | **0** | `down` | 0 | **0**（从未 link 过） | 1500 | 无 |
| `enp1s0f1np1` | `p1` | `00:0f:53:2c:68:01` | **0** | `down` | **10000**（**残留值**） | **8**（`carrier_up_count=4`） | 1500 | 无 |

`ip -br link` 原文：
```
enp1s0f0np0      DOWN           00:0f:53:2c:68:00 <NO-CARRIER,BROADCAST,MULTICAST,UP>
enp1s0f1np1      DOWN           00:0f:53:2c:68:01 <NO-CARRIER,BROADCAST,MULTICAST,UP>
```
`ethtool` 原文（关键行）：
```
===== enp1s0f0np0 =====        ===== enp1s0f1np1 =====
Port: FIBRE                     Port: FIBRE
Speed: Unknown!                 Speed: 10000Mb/s
Duplex: Full                    Duplex: Full
Auto-negotiation: on            Auto-negotiation: on
Link detected: no               Link detected: no
Supported link modes: 1000baseT/Full   ← ⚠️ 驱动的报法（SFC9120 的既有怪癖），不是真能力
```

**⚠️ 读数陷阱（必须记住）**：`ethtool` 的 `Speed` 字段在 `Link detected: no` 时**不可信**
（`f1` 显示 `10000Mb/s` 是上一次 link 的残留）。**判 link 只认 `carrier`/`operstate`/`Link detected`。**

**link 史（`journalctl -k` 原文，今天）**：
```
Sep 29 17:02:41 a-MS-7850 kernel: sfc 0000:01:00.1 enp1s0f1np1: link up at 10000Mbps full-duplex (MTU 1500)
Sep 29 17:10:06 a-MS-7850 kernel: sfc 0000:01:00.1 enp1s0f1np1: link up at 10000Mbps full-duplex (MTU 1500)
Sep 29 17:10:11 a-MS-7850 kernel: sfc 0000:01:00.1 enp1s0f1np1: link up at 10000Mbps full-duplex (MTU 1500)
Sep 29 17:11:40 a-MS-7850 kernel: sfc 0000:01:00.1 enp1s0f1np1: link down
Sep 29 17:21:58 a-MS-7850 kernel: sfc 0000:01:00.1 enp1s0f1np1: link down
```
⇒ **`enp1s0f1np1` 是本机唯一实测能上 10000Mbps 的口**（`p0` 的 `carrier_changes=0`，从未 link）。
**闸 2 建议用 `enp1s0f1np1`（p1）。** 两口当前均无 IPv4、无占用。

**未被占用的证据**：`ip -br addr` 显示两个 10G 口**无任何地址**（只有 `lo` / `enp3s0`(1G,`192.168.100.1/24`) /
`wlp6s0`(`192.168.0.38`) 有地址）；`dpdk-devbind.py --status` 显示两口 `drv=sfc unused=`
（**未绑 vfio/uio，可随时被 DPDK 接管**）。

### B.1.3 光模块 / 线缆 —— ❌ **未能读到**（需 root），槽型**未核实**

| 问题 | 结果 |
|---|---|
| `ethtool -m` 能读模块信息吗 | **不能（无权限）**：`netlink error: Operation not permitted`（需 `CAP_NET_ADMIN`；本机 `sudo` 需密码，**按纪律未提权**） |
| 模块是否插着 / 类型 / 速率 / 厂商 | **未核实** |
| 端口槽是 SFP+ 还是 SFP28 | **未核实**（`ethtool` 只报 `Port: FIBRE`；**未做物理查看**） |

⚠️ 无权限的旁证只有一条弱的：两口 `NO-CARRIER`。**"无 carrier" 既可能是"没插模块"，也可能是"插了但没 link"**
⇒ **不能据此推断模块是否存在**。

### B.1.4 能不能做 10G 打流/收包 —— ✅ **能；硬件计数齐全**

**`ethtool -S` 共 99 行，全部是网卡侧计数**（不是 socket 计数）—— 满足本工程"速率/错包判据只能看网卡硬件计数"的硬规矩。
闸 2 最该用的几个（`enp1s0f0np0` 与 `enp1s0f1np1` 的名字一致）：

| 计数名 | 用途 |
|---|---|
| `port_tx_bytes` / `port_tx_packets` | TX 速率（**发送侧速率判据**） |
| `port_rx_bytes` / `port_rx_good_bytes` / `port_rx_good` / `port_rx_packets` | RX 速率与好帧数（**接收侧速率判据**） |
| `port_rx_bad` / `port_rx_bad_bytes` | 坏帧数（**错包判据**） |
| `rx_eth_crc_err` | **FCS 错帧数**（与板子自报的"FCS 错帧恒 0"对账） |
| `port_rx_overflow` / `port_rx_nodesc_drops` / `rx_noskb_drops` / `rx_frm_trunc` | 丢弃/溢出（区分"板子没发对"与"主机丢包"） |
| `port_rx_lt64` / `port_rx_64` … `port_rx_1024_to_15xx` / `port_rx_gtjumbo` / `port_rx_bad_gtjumbo` | 长度分布（判"少发/多发"与截断） |
| `port_rx_unicast` / `port_rx_multicast` / `port_rx_broadcast` | 帧类型对账 |
| `port_tx_pause` / `port_rx_pause` / `port_rx_control` | 流控/控制帧（判是否被 PAUSE 干扰） |

**当前读数（基线，全部为 0）**：`enp1s0f0np0` **所有计数恒 0**（从未收/发）；
`enp1s0f1np1` 仅 `port_tx_bytes=35988` / `port_tx_packets=221`（+ 长度直方图 144/26/51）
—— 是它 17:02–17:11 那几次 link 期间的零星发包，**RX 全部为 0**。

**Solarflare 专有工具**：`sfboot` / `sfctool` / `sfupdate` / `efvi` ⇒ **全部 NOT FOUND**（`command -v`）。
⇒ **不能用 `sfboot` 改端口模式**（闸 2 若需调 `port_mode` 会缺工具；本轮未尝试安装）。

**DPDK**：✅ **已装 `23.11.4-0ubuntu0.24.04.2`**（`dpdk` / `dpdk-dev` / `libdpdk-dev`）；
`dpdk-devbind.py` 与 `dpdk-testpmd` 均在 `/usr/bin/`。
**sfc PMD 已编译**：`librte_net_sfc.so`（+ `librte_common_sfc_efx.so`）在
`/usr/lib/x86_64-linux-gnu/dpdk/pmds-*/`。⚠️ **只核了 `.so` 存在，未核它能否真的绑上 SFC9120**
（绑定/运行 = 状态变更，按纪律未做）。
大页：`HugePages_Total: 4` / `Free: 4`（各 1G）；`/proc/cmdline` 含
`intel_iommu=on iommu=pt default_hugepagesz=1G hugepagesz=1G hugepages=4`（与记忆件一致）。

### B.1.5 `hw_server` —— ✅ **在跑**

```
● hw_server.service - Xilinx Hardware Server (Vivado 2025.2)
     Loaded: loaded (/etc/systemd/system/hw_server.service; enabled; preset: enabled)
     Active: active (running) since Tue 2026-09-29 13:53:09 CST; 5h 50min
   Main PID: 1444 (hw_server)
             ├─1444 /bin/bash /opt/AMD/2025.2/Vivado/bin/hw_server -s tcp::3121
             └─1508 /bin/bash /opt/AMD/2025.2/Vivado/bin/loader -exec hw_server -s tcp::3121
```
```
LISTEN 0   16   0.0.0.0:3121   0.0.0.0:*      ← ss -ltnp | grep 3121
```
⇒ 本机 `connect_hw_server -url 192.168.0.38:3121` 通路**在**（服务已起 5h50min，未重启）。

### B.1.6 附带事实：**KU5P 板此刻在这台机的 PCIe 上，而且是活端点**

```
02:00.0 Serial controller: Xilinx Corporation Device 9034 (prog-if 01 [16450])
        Subsystem: Xilinx Corporation Device 0007
        Interrupt: pin ? routed to IRQ 67
        IOMMU group: 14
        Region 0: Memory at f7800000 (32-bit, non-prefetchable) [size=1M]
        Region 1: Memory at f7900000 (32-bit, non-prefetchable) [size=64K]
        Kernel driver in use: xdma
```
判活依据：**`xdma` 驱动已绑定 + BAR 大小读回正常**（陈旧条目只会给出 `ffffffff`），
故 **不是** `lspci` 陈旧条目（`CLAUDE.md` 那条警告不适用本例）。
⇒ **板子当前跑的是带 PCIe 的位流**，主机此刻能枚举到它。
⚠️ 闸 2 用的是 SFP 通路，不受影响；但**闸 2 期间若重烧位流，PCIe 端点会消失，
  且"事后补烧救不回来"**（`CLAUDE.md` 硬约束）—— 若还要用 PCIe 观测，顺序不能错。

## B.2 本轮执行的命令（可复现，全部只读）

```bash
ssh -o BatchMode=yes a@192.168.0.38 'date; uname -a'
ssh -o BatchMode=yes a@192.168.0.38 "lspci -nn | grep -i -E 'sfc|solarflare|ethernet'; lsmod | grep -i sfc"
ssh -o BatchMode=yes a@192.168.0.38 'ip -br link show; ip -br addr show; ls /sys/class/net/'
ssh -o BatchMode=yes a@192.168.0.38 'for i in enp1s0f0np0 enp1s0f1np1; do ethtool $i; done'     # grep 关键行
ssh -o BatchMode=yes a@192.168.0.38 'for i in enp1s0f0np0 enp1s0f1np1; do ethtool -m $i; ethtool -S $i; done'
ssh -o BatchMode=yes a@192.168.0.38 'lspci -vv -s 01:00.0; lspci -vv -s 01:00.1; ethtool -i enp1s0f0np0'
ssh -o BatchMode=yes a@192.168.0.38 'dmesg; journalctl -k --no-pager | grep -i -E "sfc|solarflare"'
ssh -o BatchMode=yes a@192.168.0.38 'systemctl status hw_server --no-pager; ss -ltnp | grep 3121'
ssh -o BatchMode=yes a@192.168.0.38 'for t in sfboot sfctool sfupdate efvi dpdk-devbind.py dpdk-testpmd; do command -v $t; done'
ssh -o BatchMode=yes a@192.168.0.38 'dpdk-devbind.py --status; dpkg -l | grep -i dpdk; grep -i huge /proc/meminfo; cat /proc/cmdline'
ssh -o BatchMode=yes a@192.168.0.38 'ls /usr/lib/x86_64-linux-gnu/dpdk/pmds-*/ | grep -i sfc'
ssh -o BatchMode=yes a@192.168.0.38 'lspci -nn | grep -i -E "xilinx|10ee"; lspci -vv -s 02:00.0'
ssh -o BatchMode=yes a@192.168.0.38 'for i in enp1s0f0np0 enp1s0f1np1; do for f in carrier carrier_changes carrier_up_count speed operstate mtu phys_port_name; do cat /sys/class/net/$i/$f; done; done'
```

## B.3 给闸 2 的结论（三条）

1. **SFC9120 在、驱动健康、两个口都空闲** ⇒ 闸 2 的"真链路对端"**可用**；**建议用 `enp1s0f1np1`**（唯一实测上过 10000Mbps）。
2. **速率/错包判据可用**：`port_{tx,rx}_{bytes,packets}` + `rx_eth_crc_err` / `port_rx_bad` 都是**硬件计数**，符合本工程硬规矩。
   ⚠️ 但 **`port_rx_good` 只统计 MAC 判定为好帧的**，判"板子发得对不对"要**同时**对账长度直方图与 `port_rx_bad*`。
3. **两个未决点会卡闸 2 的"物理层确认"**：① **读不到 SFP 模块信息**（需 root）；
   ② **槽型（SFP+ / SFP28）未核实**。这两条开工前需现场确认或提权。

---

# 未核实清单（本轮明确**没有**关掉的）

| # | 项 | 为什么没关掉 / 该怎么关 |
|---|---|---|
| **U-A1** | 官方 **MAC+PCS 变体**的 AXIS 字节序 = `tx_axis_tdata[63:56]` 首发（`P7B_XXV_OFFICIAL.md:839` 转述自 `macpcs64_pkt_gen_mon.v:1091-1098`） | 我**核了那 8 行的原文**（`tx_axis_tdata[(7-i)*8+:8] = fifo_tx_datain[i*8+:8]`，i=0..7），但**这是"镜像映射"这一事实**，它到 `[63:56]` 还是 `[7:0]` 取决于 `fifo_tx_datain` 所在内部字的约定。我**没有**追通 `macpcs64_buf`（FIFO）的写入侧（该文件另有自己的 `swapn` `:1591`、在 `:1530/:1538` 用于 `d_buff`、在 `:2724/:2725` 用于 `exp1/exp2`）。**⇒ 该条的最终方向本轮未复核。** 关法：读 `macpcs64_buf` 的写端口来源，或跑官方 example 的 xsim。**注意：这条只影响"将来若拿到 MAC+PCS license"的路线，不影响当前 PCS-only 路线的 A 节结论。** |
| **U-A2** | `pcs64_mii_pkt_gen` 里 `d_buff`/`nxt_d`/`rand1` 的完整载荷语义 | 只确证"本配置 `data_select=2'b0` ⇒ `op_data=0` ⇒ `d_buff` 不产生载荷"。**没有**逐状态追 `nxt_d` 的生成。与本轮字节序结论无关。 |
| **U-A3** | 官方核**内部**（XGMII ↔ GT 之间）是否还有别的字节/位序处理 | 未读核的加密实现。**但 A.6 的五条证据只依赖"XGMII 端口面"**，端口面已闭合 ⇒ 对本轮结论无影响。 |
| **U-B1** | **SFP 模块信息**（是否存在 / 类型 / 速率 / 厂商） | `ethtool -m` 需 `CAP_NET_ADMIN`；本机 `sudo` 需密码，**按"只读不提权"纪律未取**。关法：提权跑 `sudo ethtool -m enp1s0f1np1`，或物理查看。 |
| **U-B2** | 对端机侧**槽型是 SFP+ 还是 SFP28** | 未做物理查看，`ethtool` 只报 `Port: FIBRE`。关法：看机箱/说明书，或提权读模块 EEPROM 的 `Module Type`。 |
| **U-B3** | `dmesg` 原文 | `dmesg` 被 `kernel.dmesg_restrict` 挡住（`Operation not permitted`）。**已用 `journalctl -k` 替代**（拿到了 link 史与"无 sfc 错误"）。关法：`sudo dmesg`。 |
| **U-B4** | DPDK 的 `sfc` PMD **能否真的绑定并跑通 SFC9120** | 只核了 `librte_net_sfc.so` 存在 + 两个口当前 `unused=`。**绑定/起 `testpmd` = 状态变更，按纪律未做。** |
| **U-B5** | SFC9120 的 **PCIe 链路速率/位宽**（记忆件称 3.0 x8） | `lspci -vv -s 01:00.0 \| grep -E "LnkCap:\|LnkSta:"` **在非 root 下未返回该两行**（返回了 Region/驱动行）⇒ **未核实**。⚠️ 若闸 2 要算"链路上限"，这条得补。 |
| **U-B6** | 两个 SFC 口**当前是否插着模块/线缆** | 与 U-B1 同因。`NO-CARRIER` **不能**区分"没插"与"插了没 link"。 |
| **U-B7** | 记忆件里"KU5P 板在芯片组槽、2.0 x4"与本次实测 `02:00.0` 的对应关系 | 本次只确证"板子的 XDMA 活在 `02:00.0`、`xdma` 已绑定"。**槽位归属（CPU 直连 vs 芯片组）本轮未核。** |

> ⚠️ 本文件**没有任何编造**：所有行号、原文、命令输出均来自本轮实际读取/执行；
> 凡未取到的（U-A1/U-B1…U-B7）已逐条写明"未核实"及原因。
