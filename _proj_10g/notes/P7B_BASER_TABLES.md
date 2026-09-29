# P7b 10GBASE-R / XGMII 常量表（每条带出处）

> 侦察任务：只读。本文件是本次任务**唯一**写入的文件。
> 日期：2026-09-29。作者：侦察 agent（常量表专项）。
> 目标：给"自己写的 64 位 @156.25MHz 10GBASE-R 成帧/解帧层"提供**可直接当 Verilog 参数用**的常量，
> 每条都带可核实出处；查不到的**明确标"未核实"**，绝不填猜测值。

---

## 0. 来源清单（全文用编号引用）

| 编号 | 内容 | 获取方式 / 落盘路径 | 权威性 |
|---|---|---|---|
| **【S1】** | **IEEE Std 802.3-2008 Section 4**（第 44–55 节：RS / XGMII / 10GBASE-R PCS/PMA/PMD / WIS）。正文页脚印的是 `IEEE Std 802.3-2005`（2008 版该分册正文沿用 2005 文本），封面为 `TTAE.IE-802.3-2008-section4` | 公开副本：`https://committee.tta.or.kr/include/Download.jsp?filename=choan/TTAE.IE-802.3-2008-Section4.pdf`（本次下载 2,527,121 B，`pdftotext -enc UTF-8` 得 24,794 行）。**本次落到 `%TEMP%\ieee8023_s4.txt`（临时文件，非仓库文件）** | ★★★★★ 标准正文 |
| **【S2】** | **IEEE Std 802.3-2008 Section 1**（第 1–20 节：含 Clause 3 帧结构、Clause 4 MAC） | `https://committee.tta.or.kr/include/Download.jsp?filename=choan/TTAE.IE-802.3-2008-section1.pdf`（11,586,307 B，32,721 行）→ `%TEMP%\sec1.txt` | ★★★★★ 标准正文 |
| **【S3】** | **UNH IOL 10 Gigabit Ethernet Consortium《Clause 49 PCS Test Suite v0.4》**（© 2004 University of New Hampshire） | `https://www.iol.unh.edu/sites/default/files/testsuites/10gec/Clause_49_PCS_Test_Suite_v0.4.pdf` → `%TEMP%\unh49.txt` | ★★★★ 独立测试机构，引用 802.3ae 条款号 |
| **【S4】** | **IEEE P802.3ae 64b/66b: coding update**, Rich Taborek, 2000-11-20（**草案**，已作废） | `https://www.ieee802.org/3/10G_study/email/pdf00022.pdf` | ★★ **草案**，与最终标准有出入（见 §1.4） |
| **【S5】** | **UG576 (v1.7.1) UltraScale Architecture GTH Transceivers** | `https://twiki.cern.ch/twiki/pub/Main/EpicSH/UG576_2021.pdf` → `%TEMP%\ug576.txt`（25,648 行） | ★★★★ AMD 正式文档，但**是 GTH 不是 GTY** |
| **【S6】** | 本仓库内的 **AMD 明文示例 RTL**：`_proj_10g/rtl/gt_10gbr_example_stimulus_64b66b_async.v`（文件头 `(c) Copyright 2023 Advanced Micro Devices`）、`_proj_10g/rtl/p7a_top.v`、`.../w2_pcs64_baser/ip_0/synth/w2_pcs64_baser_gt_gtwizard_gtye4.v` | 仓库内，绝对路径见各条 | ★★★★★ 本地生成物（AMD 明文 RTL） |
| **【S7】** | 本仓库**我们自己、已板级验证过**的 1G RTL：`rtl/crc32_8b.v`、`rtl/mac_tx_64.v`、`rtl/mac_rx_64.v` | 仓库内 | ★★★★ **仅作"现有实现"记录，不作规范依据**；但其 FCS 约定有板级实证（ping 5/5、FCS 错帧恒 0） |
| **【S8】** | 另一路侦察的笔记 `_proj_10g/notes/P7B_PHY_IFACE.md` | 仓库内（**本次只读，未改动**） | 本文件在 GT fabric 接口一节引用它 |

### ⚠️ 重要**负面**结论（先看这条，省得再去找）

> **`xxv_ethernet_v5_0_vl_rfs.sv` 是加密的，里面一个常量都读不到。**

- 文件：`D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\lic_deny_ctrl_prj\lic_deny_ctrl.gen\sources_1\ip\w2_pcs64_baser\hdl\xxv_ethernet_v5_0_vl_rfs.sv`（21,560,191 B / 280,035 行）
- 证据（本次实测）：第 4 行起是 `` `pragma protect begin_protected `` / `encrypt_agent = "XILINX"` / `key_keyowner = "Synopsys"` …；
  全文 **只有 1 个** `pragma protect begin_protected`，`grep -c "pragma protect begin_protected"` = 1；
  **`grep -v -E "^[A-Za-z0-9+/=]{1,80}$|^$|^\`pragma"` 的输出为 0 行** ⇒ 除 pragma 头以外**全部是 base64 密文**，无 module、无 localparam、无明文表。
- 同类：`vivado_prj\p6_ip_probe\axi_10g_ethernet_v3_1\...\bd_0\ip\ip_1\hdl\ten_gig_eth_pcs_pma_v6_0_rfs.v`（2,317,237 B）**同样是全密文**（非 base64/pragma 行数 = **0**）。
  这是本地唯一一个**含软核 64b/66b 编解码**的 IP（XGMII ↔ 66 位映射就在它里面），但**读不到**。
- 另外：`w2_pcs64_baser` 那个 IP 是 **纯 GT 向导核**（只有 gearbox，没有软 PCS），本来也不含 block type 表。

**⇒ 结论：本文件 §1/§5 的 XGMII/64b-66b 表，权威来源是【S1】标准正文，不是 Xilinx 源码。**

---

## 1. XGMII 控制字符表

### 1.0 先纠正两处命名（任务书里的假设与 802.3-2008 不符）

| 任务书假设 | 802.3-2008 实际 | 证据 |
|---|---|---|
| "IEEE 802.3 Table 46-1 是 XGMII 控制字符表" | ❌ **Table 46-1 = "Round-trip delay constraints"**（往返回环时延约束）。XGMII 的**编码**表是 **Table 46-3 "Permissible encodings of TXC and TXD"**；控制码与 64b/66b 的映射表是 **Table 49-1 "Control codes"** | 【S1】`:9357`（Table 46–1 标题）、`:9684`（Table 46–3 标题）、`:13642`（Table 49–1 标题） |
| "IEEE 802.3 Table 49-2" | ❌ **不存在 Table 49-2**。第 49 节全文只有 **Table 49-1**；64b/66b 的块格式是**图**不是表：**Figure 49-7 "64B/66B block formats"** | 【S1】全文 `grep "Table 49–"` 只命中 Table 49–1（`:13642`）与对它的引用 |

### 1.1 XGMII 控制码全表（TXC=1 时 TXD 的取值）

来源：【S1】Table 46–3（`:9689`–`:9718`，"TXC=1" 各行）＋ Table 49–1 的 **XGMII Control Code** 列（`:13644`–`:13690`）。两处逐项一致。

| TXD 值 | 记法 | 说明（Table 46-3 原文） | 备注 |
|---|---|---|---|
| `0x07` | `/I/` idle | "No applicable parameter (Normal inter-frame)" | |
| `0x08`–`0x9B` | — | Reserved | |
| `0x9C` | `/Q/` Sequence | "Sequence (**only valid in lane 0**)"，Table 46-3；Table 49-1 记作 `Sequence ordered_set` | 10GBASE-R 用它做**链路故障**（remote/local fault）信令 |
| `0x9D`–`0xFA` | — | Reserved | |
| `0xFB` | `/S/` Start | "Start (**only valid in lane 0**)"；"replaces first eight ZERO, ONE of a frame (**preamble octet**)" | 见 §2 |
| `0xFC` | — | Reserved | |
| `0xFD` | `/T/` Terminate | `DATA_COMPLETE` | |
| `0xFE` | `/E/` Error | "Transmit error propagation" | |
| `0xFF` | — | Reserved | |
| `0x00`–`0x06` | — | Reserved（Table 46-3 的 `1 00 through 06 Reserved`） | |

Table 49-1 另外列出（都属"reserved"，XGMII 上**正常无错时不应出现**）：

| XGMII 控制码 | 记法 | Table 49-1 的行名 | 备注 |
|---|---|---|---|
| `0x1C` | `/R/` | reserved0 | 脚注 b：/A/、/K/、/R/ **只在 XAUI 上用来表示 idle**；无错时不出现在 XGMII 上，但某些位错误会让 XGXS 把它们发到 XGMII |
| `0x3C` | （无记法） | reserved1 | 同上 |
| `0x7C` | `/A/` | reserved2 | 同上 |
| `0xBC` | `/K/` | reserved3 | 同上 |
| `0xDC` | （无记法） | reserved4 | 同上 |
| `0xF7` | （无记法） | reserved5 | 同。⚠️ **后续修订（如 802.3dm 基线文本）把它称作 `/F/`**，但 **802.3-2008 里叫 reserved5、没有 /F/ 这个记法** |
| `0x5C` | `/Fsig/` | Signal ordered_set | 脚注 c："**Reserved for INCITS T11 Fibre Channel use**" |

**证据行**：【S1】`:13644`–`:13690`（Table 49–1 全表，含 8B/10B 码列，8B/10B 列脚注 a 注明"for information only"）。
Table 46–3 的值列原文脚注："NOTE—Values in TXD column are in hexadecimal, **most significant bit to least significant bit (i.e., <7:0>)**"（【S1】`:9718`）。

### 1.2 10GBASE-R 侧的 "C 码"（7 位，块载荷里用的控制码）

来源：【S1】Table 49-1 "10GBASE-R Control Code" 列。

| 控制字符 | 记法 | 10GBASE-R 控制码（7 位 C 码） | O 码 |
|---|---|---|---|
| idle | `/I/` | **`0x00`** | — |
| start | `/S/` | **由 block type field 隐含编码**（无独立码） | — |
| terminate | `/T/` | **由 block type field 隐含编码** | — |
| error | `/E/` | **`0x1E`** | — |
| Sequence ordered_set | `/Q/` | 由 block type field **＋ 4 位 O 码** | **`0x0`** |
| reserved0 | `/R/` | `0x2D` | — |
| reserved1 | — | `0x33` | — |
| reserved2 | `/A/` | `0x4B` | — |
| reserved3 | `/K/` | `0x55` | — |
| reserved4 | — | `0x66` | — |
| reserved5 | — | `0x78` | — |
| Signal ordered_set | `/Fsig/` | 由 block type field ＋ 4 位 O 码 | **`0xF`** |

标准原文（【S1】`:13552`–`:13560`）：
> "The 10GBASE-R PCS encodes the start and terminate control characters **implicitly by the block type field**.
> The 10GBASE-R PCS encodes the ordered_set control codes using a **combination of the block type field and a 4-bit O code** …
> The 10GBASE-R PCS encodes **each of the other control characters into a 7-bit C code**."

### 1.3 哪些是 10GBASE-R 真的会用到 / 哪些只在 1G/XAUI

| 码 | 10GBASE-R 会不会发 | 依据 |
|---|---|---|
| `/I/` `0x07` | ✅ 必用（帧间填充） | 【S1】49.2.4.7（`:13631`–`:13641`） |
| `/S/` `0xFB` | ✅ 必用（帧首） | §2 |
| `/T/` `0xFD` | ✅ 必用（帧尾） | 49.2.4.9（`:13701`–`:13706`） |
| `/E/` `0xFE` | ✅ 会发（收到无效块/收到 /E/ 时转发） | 49.2.4.11（`:13728`–`:13732`） |
| `/Q/` `0x9C` | ✅ 会发（**Sequence ordered_set，做 remote/local fault**） | 46.3.4 + 49.2.4.5（`:13612`–`:13620`） |
| `/Fsig/` `0x5C` | ⛔ **保留给 Fibre Channel（INCITS T11）**，以太网不发 | 【S1】Table 49-1 脚注 c |
| `/R/` `/A/` `/K/` | ⛔ **XAUI 专用**（XAUI 用它们表示 idle/align/sync）。以太网上只在**出错的 XGXS** 上才可能出现 | 【S1】Table 49-1 脚注 b |
| `0x3C` `0xDC` `0xF7` | ⛔ 保留，不发 | 【S1】Table 49-1 |

**注意（区分 1G/GMII）**：GMII 是 `TXC/TX_ER` + 8 位数据，**没有这些控制码**；`/R/ /A/ /K/` 是 XAUI（8B/10B）的 K 码概念（K28.0/K28.3/K28.5，见 Table 49-1 的 8B/10B 列）。**别把 K 码当成 XGMII 控制码用。**

### 1.4 ⚠️ 草案 vs 最终标准的两处差异（网上抄错的重灾区）

【S4】（2000-11 草案）与【S1】（标准）**不一致**：

| 项 | 【S4】草案 2000-11 | 【S1】标准 2008（以这个为准） |
|---|---|---|
| `0x9C` | 叫 `/P/` "Pulse Ordered Set" | 叫 **`/Q/` Sequence ordered_set**，O 码 `0x0` |
| `0x1C` | "reserved 3"，C 码 `0x2D` | **`/R/`**，C 码 `0x2D` |
| `0x3C` | `/A/`，C 码 `0x33` | **reserved1**（无记法），C 码 `0x33` |
| `0x7C` | `/K/`，C 码 `0x4B` | **`/A/`**，C 码 `0x4B` |
| `0xBC` | "reserved 6"，C 码 `0x55` | **`/K/`**，C 码 `0x55` |
| `0xFC` | "reserved 7"，C 码 `0x66` | **未列入控制码表**（Table 46-3 里 `0xFC` = Reserved） |
| `0xF7` | （空），C 码 `0x78` | **reserved5**，C 码 `0x78` |

**⇒ `/A/` 与 `/K/` 的 XGMII 码在草案与标准里是反的**。**以及 Table 49-1 里 `/A/`=0x7C→8B/10B K28.3、`/K/`=0xBC→K28.5**，与 XAUI 的语义（/A/=align=K28.3、/K/=sync=K28.5）自洽 ⇒ **进一步确认标准那版是对的**。

---

## 2. ⭐ 帧起始：preamble / SFD（最容易做错的一条）

### 2.1 位数与值

标准原文（【S1】46.2.2，`:9592`–`:9612`）：

> "The preamble `<preamble>` … **consists of 7 octets** with the following bit values:
> `10101010 10101010 10101010 10101010 10101010 10101010 10101010`"
> "The start of frame delimiter `<sfd>` … immediately follows the preamble. The bit value of `<sfd>` **at the XGMII is unchanged** from the Start Frame Delimiter (SFD) specified in 4.2.6 and is the bit sequence: `10101011`"

⚠️ **这两串是"串行发送顺序"（最左 = 最先发）**，标准紧接着说明（【S1】`:9614`–`:9616`）：
> "The preamble and SFD are shown previously **with their bits ordered for serial transmission from left to right**. As shown, **the left-most bit of each octet is the LSB of the octet** and the right-most bit of each octet is the MSB of the octet."

⇒ 把它当**字节值**看：`10101010`(串行序) → MSB..LSB = `01010101` → **`0x55`**；`10101011` → **`0xD5`**。

| 项 | 串行位序（标准写法） | 字节值 |
|---|---|---|
| preamble 每个 octet | `10101010` | **`0x55`** ×**7** |
| SFD | `10101011` | **`0xD5`** ×1 |

### 2.2 ⭐ 64 位 XGMII 上的排布 —— 与"7×0x55 + 1×0xD5 正好一拍"**不同**

标准给出的是 **32 位** XGMII 上的逐 lane 排布（【S1】46.2.2，`:9618`–`:9629`），**原文照抄**：

> "The preamble and SFD are transmitted through the XGMII as octets sequentially ordered on the lanes of the XGMII.
> **The first preamble octet is replaced with a Start control character and it is aligned to lane 0**, the second octet on lane 1, the third on lane 2 and the fourth on lane 3, and the four octets are transferred on the next edge of TX_CLK.
> The fifth octet is assigned to lane 0 with subsequent octets sequentially assigned to the lanes with **the SFD assigned to lane 3**."

| | Lane 0 | Lane 1 | Lane 2 | Lane 3 |
|---|---|---|---|---|
| 第 1 个 32 位传输 | **Start** (`/S/`) | `10101010` | `10101010` | `10101010` |
| 第 2 个 32 位传输 | `10101010` | `10101010` | `10101010` | `10101011`(**SFD**) |

**⇒ 扩到 64 位（8 字节）视图**（把 2 次 32 位传输拼成一个 64 位字；**这一步是"2 次 32 位传输 = 1 个 64 位字"的直接推论，标注为【推论】**）：

| 字节 0 | 字节 1..6 | 字节 7 |
|---|---|---|
| **`/S/` = `0xFB`（TXC=1，控制字符）** | **`0x55` ×6（数据，TXC=0）** | **`0xD5`（SFD，数据，TXC=0）** |

### 2.3 直接回答任务书里那个"常见混淆点"

| 问题 | 答案 | 出处 |
|---|---|---|
| XGMII 上 SFD 是 `0xD5` 还是 `0xFB`？ | **两个都在，但在不同位置**：**帧的第一个字符位置是 `/S/`（0xFB），SFD `0xD5` 是最后一个（第 8 个）数据字节** | 【S1】`:9618`–`:9629` |
| `/S/` 替换的是哪一字节？ | **替换 preamble 的第 1 个 octet（不是 SFD！）**。原文两处："The first octet of preamble shall be converted to a Start control character and aligned to lane 0"（`:9451`）；"the RS converts the first data octet of preamble transferred from the MAC into a Start control character"（`:9599`–`:9600`） | 【S1】 |
| preamble 真的出现在 XGMII 上吗？ | **出现 —— 7 个 octet 里有 6 个以 `0x55` 数据字节的形式出现**（只有第 1 个被 `/S/` 顶掉） | 【S1】`:9618`–`:9622` |
| 接收方向呢？ | RS 会把 `/S/` **还原成 preamble 数据字节**再交给 MAC："The RS shall convert a valid Start control character to a preamble octet prior to generation of the associated PLS_DATA.indication transactions"（`:9489`） | 【S1】 |
| **10GBASE-R PCS 会不会"处理" preamble/SFD？** | **不会**。`/S/` 由 **block type field `0x78`** 隐含编码；剩下 7 个数据字节（`0x55`×6 + `0xD5`）**就是普通载荷数据**，和别的数据一视同仁地被加扰。**SFD 对 PCS 不可见** | **【推论】**：依据是 Figure 49-7 的 `0x78` 行 = `S0 D1 D2 D3/D4 D5 D6 D7`（【S1】`:13602`）+ 49.2.4.3"start/terminate … implicitly encoded by the block type field"（`:13552`）。**标准没有一句话直接说"SFD 不可见"，所以标为推论** |

### 2.4 与 1G/GMII 的差异（**不要把 1G 写法当 10G 规范**）

- **现有 1G 实现**【S7】：`rtl/mac_tx_64.v:99` `S_PRE: txd_c = (pre_cnt == 6'd7) ? 8'hD5 : 8'h55;`，即 **在线上直接生成 `0x55`×7 + `0xD5` 共 8 字节**；`rtl/mac_rx_64.v:115,220` 收侧要求"`0xD5` 且 `pre_cnt>=6`"。
- **10GBASE-R 的正确做法**：帧首那 8 个字符里**第 0 个必须是 `/S/`（0xFB，TXC=1）**，只剩 6 个 `0x55` + 1 个 `0xD5` 是数据。
  **⇒ 直接照搬 1G 的 "55×7+D5" 会多一个 0x55、少一个 `/S/`，帧根本起不来。**（板级表现：对端永远见不到块类型 `0x78`，静默丢帧。）

---

## 3. IFG / IPG（帧间隔）

| 项 | 值 | 出处 |
|---|---|---|
| MAC 层 `interPacketGap` 参数 | **96 bits = 12 octets**（100 Mb/s、1 Gb/s、10 Gb/s **三档相同**） | 【S2】Clause 4.4 MAC 参数表，`sec1.txt:6506` |
| 它是"最小值"还是"平均值" | **最小值**。标准原文旁注："the spacing between two successive non-colliding packets … can have a **minimum** value of …"；1 Gb/s 那条注同理（`sec1.txt:6529` 起） | 【S2】4.4 NOTE |
| **XGMII 上的 `<inter-frame>` 定义** | "begins with the **Terminate** control character, continues with **Idle** control characters and ends with the Idle control character prior to a Start control character" | 【S1】46.2.1（`:9579`–`:9588`） |
| **接收 RS 侧 XGMII 的最小 IPG** | **5 octets**（原文："The **minimum IPG at the XGMII of the receiving RS is five octets**."） | 【S1】46.2.1（`:9588`） |
| **发送 RS 侧可以缩短到多少** | RS 为把 `/S/` 对齐到 lane 0 可用 **DIC（Deficit Idle Count，界 0..3）** 增删 idle ⇒ "may result in inter-frame spacing observed on the transmit XGMII that is **up to three octets shorter** than the minimum transmitted inter-frame spacing specified in Clause 4" ⇒ **发送 XGMII 上最短可能只看到 9 octets** | 【S1】46.3.1.4（`:9774`–`:9800`） |
| PCS 能不能动 idle？ | 能，但 **`/I/` 增删必须以 4 个为一组**，且 "When deleting /I/s, **the first four characters after a /T/ shall not be deleted**" | 【S1】49.2.4.7（`:13638`–`:13642`） |
| **在 64 位接口上怎么计数？** | **按"字节/字符"数，不要按 64 位字整拍数**。理由：`/T/` 可以落在任意 lane，帧尾与帧首不在整字边界上。**"接收侧最小 5 字节" = 1 个 `/T/` + 至少 4 个不能删的 `/I/`** ⇒ 这条是那个 4 的由来。 | 【S1】上述两处组合 ⇒ **【推论】**（"5 = 1+4" 这个算式标准没写出来） |
| 现有 1G 实现 | `rtl/mac_tx_64.v:216-222` `S_IFG: if (ifg_cnt == 4'd11) …` ⇒ **12 个 idle 字节** | 【S7】现有实现 |

**⇒ 给 10G 的建议书写**：帧尾 `/T/` 之后至少补 **12 个 `/I/`**（保守、与 MAC 参数一致）；若要严格对齐 lane0 可以做 DIC，但**别低于 9**，且**接收侧判"帧间空闲"的阈值按 ≥5 字节**更保险。

---

## 4. 帧长 + FCS

### 4.1 帧长

| 项 | 值 | 出处 |
|---|---|---|
| `minFrameSize` | **512 bits = 64 octets**（含 FCS；10 Mb/s/100 Mb/s/1 G/10 G 四档相同） | 【S2】Clause 4.4 表，`sec1.txt:6513` |
| `maxBasicFrameSize` | **1518 octets**（不带 tag） | 【S2】Clause 4.4 表，`sec1.txt:6510` |
| Q-tagged frame（带 VLAN tag）最大 | **1522 octets** | 【S2】1.4.291 定义，`sec1.txt:3057` |
| `maxEnvelopeFrameSize` | **2000 octets**（"信封帧"，用于封装类） | 【S2】Clause 4.4 表，`sec1.txt:6512` |
| 10 Gb/s 的 `slotTime` | **not applicable**（全双工） | 【S2】Clause 4.4 表，`sec1.txt:6501` |

### 4.2 FCS 位置

FCS 是**帧的最后 4 个 octet**，紧跟在 `Pad`（若需补齐）之后（【S2】3.2.8/3.2.9 结构图 `sec1.txt:3906` 与正文 `:4127`）。`Pad` 的引入规则：帧（DA..FCS）必须至少 64 octets，不够则补 0（【S2】3.2.8，`sec1.txt:4114`）。

### 4.3 CRC32 定义（**照抄标准**）

【S2】3.2.9（`sec1.txt:4127`–`:4150`）：

> 生成多项式：`G(x) = x32 + x26 + x23 + x22 + x16 + x12 + x11 + x10 + x8 + x7 + x5 + x4 + x2 + x + 1`
> a) **The first 32 bits of the frame are complemented.**
> b) …（M(x) 定义）
> c) M(x) 乘 x^32 除以 G(x)，余 R(x)（次数 ≤ 31）
> d) R(x) 的系数作为 32 位序列
> e) **The bit sequence is complemented and the result is the CRC.**
> "The 32 bits of the CRC value are placed in the FCS field so that **the x31 term is the left-most bit of the first octet**, and the **x0 term is the right most bit of the last octet**. (The bits of the CRC are thus transmitted in the order x31, x30, …, x1, x0.)"

**⭐ 关键（标准里唯一一条"反着来"的位序规则）** ——【S2】3.3 Order of bit transmission（`sec1.txt:4171`）：

> "**Each octet of the MAC frame, with the exception of the FCS, is transmitted least significant bit first.**"

⇒ **整帧 LSB-first，唯独 FCS 是 MSB(x31)-first。**

### 4.4 落到 8 字节流上的"字节序"该取哪个（这是我们能直接用的形式）

标准只给了**位**序，没给"CRC 寄存器值 → 4 个字节"的字节序。**本地有板级实证的实现给出了答案**（【S7】，且经 ping 5/5、FCS 错帧恒 0 的板级验证）：

`rtl/crc32_8b.v` 头注释（原文）：
> `// 以太网 CRC-32 (反射多项式 0xEDB88320, 初值 0xFFFFFFFF, 无终值取反)。`
> `// 帧全字节 (目的MAC..FCS 含 FCS) 流过后的寄存器残留 == 32'hDEBB20E3 表示 FCS 正确`
> `// (FCS 为 zlib.crc32 值小端/线上 LSB-first 字节序; 0xC704DD7B 是 FCS 大端魔数, 勿用)。`

`rtl/mac_tx_64.v:170,213`：`fcs_shr <= crc_nxt ^ 32'hFFFFFFFF;` 且 `S_FCS: txd_c = fcs_shr[7:0]; … fcs_shr <= fcs_shr >> 8;`
⇒ **先把反射寄存器的下一值取反，再按"低字节先出"（小端字节序）串出 4 个字节。**

交叉验证（**算术自洽**，本次亲算）：`0xDEBB20E3` 的 32 位全位反转 = `0xC704DD7B`。
即"残留 `0xDEBB20E3`（反射引擎）"与"FCS 大端魔数 `0xC704DD7B`"**互为位反转**，与标准 §4.3 那句"FCS 位序与其余字节相反"完全吻合。**⇒ 两条独立证据一致。**

`rtl/mac_rx_64.v:96`：`localparam [31:0] CRC_RESIDUE = 32'hDEBB20E3;`（收侧判据，**帧长无关**）。

**⚠️ 严正提醒**：这一节给的是**我们的实现约定 + 板级实证**，**不是标准原文**；标准原文只说"x31 先发"。要做 10G 时**必须把这个约定原封不动搬过去**，否则 FCS 全错。

---

## 5. 10GBASE-R 64b/66b 块结构

### 5.1 同步头（sync header）

【S1】49.2.4.3（`:13516`–`:13522`）原文：
> "Blocks consist of **66 bits**. The first two bits of a block are the synchronization header (sync header). Blocks are either data blocks or control blocks. **The sync header is `01` for data blocks and `10` for control blocks.** Thus, there is always a transition between the first two bits of a block. … the sync header **bypasses the scrambler**."

**位序约定**（【S1】`:13505`）："Binary values are shown with the **first transmitted bit (the LSB) on the left**."
⇒ **`01` 表示"先发 0，再发 1"**；`10` 表示"先发 1，再发 0"。**写 RTL 时别把它当成 `2'b01` 的普通字面量就往 sync 线上捅** —— 见 §6.3。

**块类型字段的位置**（【S1】`:13544`–`:13546` 原文）：
> "Bits and field positions are shown with the least significant bit on the left. … For example the **block type field `0x1e` is sent as `01111000` representing bits 2 through 9** of the 66 bit block."

（`0x1E` = `00011110`，把 bit0 摆最左显示 ⇒ `0 1 1 1 1 0 0 0` = `01111000`。**⇒ 块类型字段就是字节值本身，bit0 先发，不需要移位/反转。**）

**无效块判据**（【S1】49.2.4.6，`:13622`–`:13629`）：
> a) sync field = `00` 或 `11`；b) 块类型字段是保留值；c) 任一控制字符的值不在 Table 49-1；d) 任一 O 码不在 Table 49-1；e) 这 8 个 XGMII 字符组不出 Figure 49-7 里的任何一种格式。

### 5.2 ⭐ 16 种合法块格式全表（Figure 49-7）

来源：**【S1】Figure 49–7 "64B/66B block formats"（PDF 第 256 页；文本行 `:13529`–`:13610`）**。
交叉验证：**【S3】列出的 16 种合法组合与下表**逐字符一致（`unh49.txt:404`–`:417`，"In total, there are **16** different valid data and control block combinations"）。

列的含义：`Input Data` 列的 `/` 左边 = XGMII lane 0–3（**先传的 4 个字符**），右边 = lane 4–7。
`D`=数据字节（TXC/RXC=0）；`C`=控制字符（TXC=1）；`S`=`/S/`（隐含）；`T`=`/T/`（隐含）；`O`=O 码字符。
**⇒ "哪些位置是控制、哪些是数据"就是这张表的左列。**

| # | Input Data（lane0-3 / lane4-7） | Sync | Block Type Field | 类别 | 含义 |
|---|---|---|---|---|---|
| 1 | `D0 D1 D2 D3 / D4 D5 D6 D7` | `01` | （无） | Data | 全数据块 |
| 2 | `C0 C1 C2 C3 / C4 C5 C6 C7` | `10` | **`0x1E`** | C | 全 8 字节控制（**Idle 块 / 也可用作 Error 块**） |
| 3 | `C0 C1 C2 C3 / O4 D5 D6 D7` | `10` | **`0x2D`** | C | 前 4 字符控制 + 1 个 O 码 + 3 数据 |
| 4 | `C0 C1 C2 C3 / S4 D5 D6 D7` | `10` | **`0x33`** | C→S | 前 4 控制 + `/S/` 在第 5 个字符 |
| 5 | `O0 D1 D2 D3 / S4 D5 D6 D7` | `10` | **`0x66`** | C→S | O 码在字符 0 + `/S/` 在第 5 个字符 |
| 6 | `O0 D1 D2 D3 / O4 D5 D6 D7` | `10` | **`0x55`** | C | **两个** O 码 |
| 7 | `S0 D1 D2 D3 / D4 D5 D6 D7` | `10` | **`0x78`** | S | `/S/` 在字符 0，**后面 7 个全是数据**（= preamble 尾 + SFD + DA 开头） |
| 8 | `O0 D1 D2 D3 / C4 C5 C6 C7` | `10` | **`0x4B`** | C | O 码在字符 0 + 后 4 控制 |
| 9 | `T0 C1 C2 C3 / C4 C5 C6 C7` | `10` | **`0x87`** | T | `/T/` 在第 0 位 |
| 10 | `D0 T1 C2 C3 / C4 C5 C6 C7` | `10` | **`0x99`** | T | `/T/` 在第 1 位 |
| 11 | `D0 D1 T2 C3 / C4 C5 C6 C7` | `10` | **`0xAA`** | T | `/T/` 在第 2 位 |
| 12 | `D0 D1 D2 T3 / C4 C5 C6 C7` | `10` | **`0xB4`** | T | `/T/` 在第 3 位 |
| 13 | `D0 D1 D2 D3 / T4 C5 C6 C7` | `10` | **`0xCC`** | T | `/T/` 在第 4 位 |
| 14 | `D0 D1 D2 D3 / D4 T5 C6 C7` | `10` | **`0xD2`** | T | `/T/` 在第 5 位 |
| 15 | `D0 D1 D2 D3 / D4 D5 T6 C7` | `10` | **`0xE1`** | T | `/T/` 在第 6 位 |
| 16 | `D0 D1 D2 D3 / D4 D5 D6 T7` | `10` | **`0xFF`** | T | `/T/` 在第 7 位 |

**⇒ 对任务书里那个问号的直接回答**：是 **`0x4B`，不是 `0x4E`**。`0x4E` **不是**合法块类型（不在 Figure 49-7 的 15 个控制块类型里）。

**拼写核对（本次逐项复核）**：15 个控制块类型 = `{0x1E, 0x2D, 0x33, 0x4B, 0x55, 0x66, 0x78}` ∪ `{0x87, 0x99, 0xAA, 0xB4, 0xCC, 0xD2, 0xE1, 0xFF}` —— **正好 7 + 8 = 15**，加数据块 = 16，与【S3】"In total, there are 16"**对账一致** ✅。

**保留值**（【S1】`:13548` + 脚注 7）："All unused values of block type field are reserved." 脚注 7 原文：
> "The block type field values have been chosen to have a **4-bit Hamming distance** between them. The only unused value that maintains the Hamming distance is **`0x00`**."

（本次自算抽查：`0x1E^0x2D=0x33`→4 位、`0x1E^0x33=0x2D`→4 位、`0x33^0x66=0x55`→4 位，全部 ≥4 ✅）

### 5.3 接收侧分类规则（R_TYPE）——**独立第二来源**

【S3】UNH Clause 49 测试套件对 `R_BLOCK_TYPE` 的原文描述（`unh49.txt:1564`、`:1702`、`:1792`）：

- **判为 C**：sync = `10` 且满足其一 —— 块类型 `0x1E` 且 8 个控制字符都合法**且不是 `/E/`**；或 块类型 `0x2D` 或 `0x4B` + 合法 O 码 + 4 个合法控制字符；或 块类型 `0x55` + **两个**合法 O 码。
- **判为 S**：sync = `10` 且满足其一 —— 块类型 `0x33` + 4 个合法控制字符；或 块类型 `0x66` + 一个合法 O 码；或 块类型 `0x78`。
- **判为 T**：sync = `10` 且块类型 ∈ {`0x87, 0x99, 0xAA, 0xB4, 0xCC, 0xD2, 0xE1, 0xFF`} 且所有控制字符合法。

**⇒ 这三条与 §5.2 的表逐项自洽**（例如 `0x2D`/`0x4B` 恰好各有 1 个 O 码 + 4 个控制字符；`0x55` 恰有 2 个 O 码）✅ **这是两条独立来源的交叉验证。**

### 5.4 加扰器

【S1】49.2.6（`:13741`–`:13758`）：
> `G(x) = 1 + x39 + x58` （式 49–1）
> "There is **no requirement on the initial value** for the scrambler. The scrambler is run **continuously** on all payload bits. **The sync header bits bypass the scrambler.**"

脚注 8 特别提醒：该多项式**按"最近进入的位 = 最低次项"的约定**书写，与常见教科书约定相反 —— **"以 Figure 49-8 的电路图为准，不以多项式等式为准"**。
⇒ **实现时务必照 Figure 49-8（PDF 第 234 页，本文档 `:13764` 起）画移位寄存器，不要凭多项式硬推。**

**【S5】补充（对我们这套 gearbox 配置至关重要）**：
> TX 异步 gearbox："**Scrambling of the data is done in the interconnect logic**"（`ug576.txt:6615`）
> RX 异步 gearbox 同理（【S5】第 4 章 RX Asynchronous Gearbox）
⇒ **加扰/解扰必须我们自己写在 fabric 里**（GT 不会替我们做）。

---

## 6. 本板 GT 的 fabric 侧接口（`txheader` / `rxheader`）

> 本项由**另一路侦察**主责（`_proj_10g/notes/P7B_PHY_IFACE.md`，本次只读未改）。这里只记**本次独立查到的、与其结论一致的本地证据**。

| 结论 | 证据 |
|---|---|
| 6 位 `txheader` **逐位直通**到 GTY 原语，中间无任何重排 | 【S6】`...\w2_pcs64_baser\ip_0\synth\w2_pcs64_baser_gt_gtwizard_gtye4.v`：`:1885 assign txheader_int = txheader_in;`、`:2224 .GTYE4_CHANNEL_TXHEADER (txheader_int[...])` |
| **数据块的 header = `6'b000001`**（**AMD 明文 RTL 直证**） | 【S6】`_proj_10g/rtl/gt_10gbr_example_stimulus_64b66b_async.v:105-106`：注释 `// This module does not drive protocol-specific behavior when the gearbox is used, so tie txheader to the "data" type` + `assign txheader_out = 6'b000001;` |
| 同一文件还钉死：`txsequence` **不用**，接 0 | 同文件 `// txsequence is not used for 64B/66B async gearbox data transmission when a wide user data width is used` + `assign txsequence_out = 7'd0;` |
| 本配置（8 字节接口 / 非 CAUI）只用 `txheader[1:0]` | 【S5】UG576 Table 3-15（`ug576.txt:6705`）："**TXHEADER[1:0] is used in the normal mode**"；"**When using a 64-bit (8-byte) TXDATA interface to interconnect logic, tie TXSEQUENCE[0] to 1'b0**" |
| **位序（决定性）**：`TXHEADER[1]` = 块的第 1 个发送位 | 【S5】Figure 3-7 注 1（`ug576.txt:6203`）原文：**"Per IEEE802.3ae nomenclature, H1 corresponds to TxB<0>, H0 to TxB<1>, etc."** |
| RX 侧：8 字节接口时 `rxheadervalid` **恒 1**，别拿它当有效指示 | 【S5】Table 4-44（`ug576.txt:15858`）："When using an 8-byte RX data interface (RX_DATA_WIDTH = 64), **RXHEADERVALID[0] always outputs 1'b1**" |
| ⚠️ **P7a 只跑过数据块**：P7a 的 TX 全由那个 example stimulus 驱动，`txheader` 恒 `6'b000001`，`txsequence` 恒 0 | 【S6】`_proj_10g/rtl/p7a_top.v:236-238` 与 `:245-247`（两个通道各例化一个 `gt_10gbr_example_stimulus_64b66b_async`），`:250-253` 打包 |
| ⇒ **因此 P7a 的 6 Tbit 零错完全没有验证任何控制块（`/S/`、`/T/`、`/I/`）的 header 取值** | 上一条的必然推论 |

### 6.3 ⚠️ 一个**极易踩**的位序陷阱（本次查到、值得单独写出来）

两条**已核实**事实：
1. 【S5】`ug576.txt:6203`：`TXHEADER[1]` ↔ 块的第 1 个发送位（TxB<0>）。
2. 【S1】`13516`：sync header 数据块 = `01`（**先发 0，再发 1**）；控制块 = `10`（先发 1，再发 0）。

⇒ **TXHEADER[1:0] 的位序与标准里 `01`/`10` 的书写顺序是"反"的**：

| 块类型 | 标准写法（先发位在左） | 第 1 个发送位 → `TXHEADER[1]` | 第 2 个发送位 → `TXHEADER[0]` | 送达 GT 的 `txheader[5:0]` |
|---|---|---|---|---|
| **数据块** | `01` | 0 | 1 | **`6'b000001`** ← 与 AMD 例子逐位吻合 ✅（可视为对这套推导的实证） |
| **控制块** | `10` | 1 | 0 | `6'b000010` ← **【推导】**（由上述两条已核实事实唯一确定，但**没有厂商明文直接写这个值**，也没有板级证据） |

**【S8】`P7B_PHY_IFACE.md` 得出同一结论**（其 §2.3 给出数据块 `6'b000001`、控制块 `6'b000010`，并把控制块一值列为**待实验 E1 确认**）。两路侦察独立收敛 ⇒ 该推导可信度高，但**在 P7b 上板前仍建议按 E1 做一次自环回验证**。

---

## 7. ✅ 可直接粘进 Verilog 的参数定义（**只含已确证项**）

```verilog
// ===========================================================================
// 10GBASE-R / XGMII 常量表  (P7b)
// 出处: IEEE Std 802.3-2008 Section 1 & Section 4 (见 notes/P7B_BASER_TABLES.md §0)
//       本地明文 AMD RTL: gt_10gbr_example_stimulus_64b66b_async.v
//       FCS 约定: 本仓库板级验证实现 rtl/crc32_8b.v / rtl/mac_tx_64.v
// 纪律: 本块内每一条都有出处；"未核实"的一律不写在这里（见 §8）
// ===========================================================================

// ---- 1. XGMII 控制字符 (802.3-2008 Table 46-3 + Table 49-1 "XGMII Control Code") ----
localparam [7:0] XGMII_IDLE   = 8'h07;  // /I/
localparam [7:0] XGMII_SEQ    = 8'h9C;  // /Q/  Sequence ordered_set (仅 lane0 合法)
localparam [7:0] XGMII_START  = 8'hFB;  // /S/  Start            (仅 lane0 合法)
localparam [7:0] XGMII_TERM   = 8'hFD;  // /T/  Terminate
localparam [7:0] XGMII_ERROR  = 8'hFE;  // /E/  Error
// 以下 7 个属 "reserved"，正常无错时不应出现在 XGMII 上；/R/ /A/ /K/ 是 XAUI 专用
localparam [7:0] XGMII_RES_R  = 8'h1C;  // reserved0  (记法 /R/，XAUI 用)
localparam [7:0] XGMII_RES1   = 8'h3C;  // reserved1  (无记法)
localparam [7:0] XGMII_RES_A  = 8'h7C;  // reserved2  (记法 /A/，XAUI 用)
localparam [7:0] XGMII_RES_K  = 8'hBC;  // reserved3  (记法 /K/，XAUI 用)
localparam [7:0] XGMII_RES4   = 8'hDC;  // reserved4  (无记法)
localparam [7:0] XGMII_RES5   = 8'hF7;  // reserved5  (无记法；后续修订叫 /F/)
localparam [7:0] XGMII_FSIG   = 8'h5C;  // /Fsig/ Signal ordered_set (以太网不用)

// ---- 2. 10GBASE-R 7 位 C 码 (Table 49-1 "10GBASE-R Control Code") ----
localparam [6:0] BASER_C_IDLE = 7'h00;  // /I/
localparam [6:0] BASER_C_ERR  = 7'h1E;  // /E/
localparam [6:0] BASER_C_RESR = 7'h2D;  // reserved0 (/R/)
localparam [6:0] BASER_C_RES1 = 7'h33;  // reserved1
localparam [6:0] BASER_C_RESA = 7'h4B;  // reserved2 (/A/)
localparam [6:0] BASER_C_RESK = 7'h55;  // reserved3 (/K/)
localparam [6:0] BASER_C_RES4 = 7'h66;  // reserved4
localparam [6:0] BASER_C_RES5 = 7'h78;  // reserved5
// /S/ 与 /T/ 没有独立 C 码 —— 由 block type field 隐含编码

// ---- 3. 4 位 O 码 (Table 49-1 "10GBASE-R O Code") ----
localparam [3:0] BASER_O_SEQ  = 4'h0;   // /Q/  sequence ordered_set
localparam [3:0] BASER_O_FSIG = 4'hF;   // /Fsig/ signal ordered_set

// ---- 4. 同步头 (802.3-2008 49.2.4.3；注意：标准里"先发位写在左边") ----
localparam [1:0] BASER_SYNC_DATA  = 2'b01;  // 数据块：先发 0 再发 1
localparam [1:0] BASER_SYNC_CTRL  = 2'b10;  // 控制块：先发 1 再发 0

// ---- 5. block type field 全 16 种 (Figure 49-7, PDF p.256) ----
//      (无类型 = 数据块)
localparam [7:0] BT_CTRL_ALL    = 8'h1E;  // C0 C1 C2 C3/C4 C5 C6 C7   全控制 (Idle / Error)
localparam [7:0] BT_CTRL_O4     = 8'h2D;  // C0 C1 C2 C3/O4 D5 D6 D7
localparam [7:0] BT_CTRL_S4     = 8'h33;  // C0 C1 C2 C3/S4 D5 D6 D7   (S 在第 5 字符)
localparam [7:0] BT_O0_S4       = 8'h66;  // O0 D1 D2 D3/S4 D5 D6 D7
localparam [7:0] BT_O0_O4       = 8'h55;  // O0 D1 D2 D3/O4 D5 D6 D7   两个 O 码
localparam [7:0] BT_START       = 8'h78;  // S0 D1 D2 D3/D4 D5 D6 D7   ★帧首块
localparam [7:0] BT_O0_CTRL     = 8'h4B;  // O0 D1 D2 D3/C4 C5 C6 C7
localparam [7:0] BT_T0          = 8'h87;  // T0 C1 C2 C3/C4 C5 C6 C7
localparam [7:0] BT_T1          = 8'h99;  // D0 T1 C2 C3/C4 C5 C6 C7
localparam [7:0] BT_T2          = 8'hAA;  // D0 D1 T2 C3/C4 C5 C6 C7
localparam [7:0] BT_T3          = 8'hB4;  // D0 D1 D2 T3/C4 C5 C6 C7
localparam [7:0] BT_T4          = 8'hCC;  // D0 D1 D2 D3/T4 C5 C6 C7
localparam [7:0] BT_T5          = 8'hD2;  // D0 D1 D2 D3/D4 T5 C6 C7
localparam [7:0] BT_T6          = 8'hE1;  // D0 D1 D2 D3/D4 D5 T6 C7
localparam [7:0] BT_T7          = 8'hFF;  // D0 D1 D2 D3/D4 D5 D6 T7
// 保留值: 上面 15 个之外的全部 (唯一"保持 4-bit 汉明距"的未用值是 0x00) -> 收到即判无效块

// ---- 6. 帧起始 (46.2.2 / 46.3.1.3；本设计用 64 位视图) ----
//   64 位 XGMII 一拍 = 8 字符: byte0 = /S/(控制) , byte1..6 = 0x55 , byte7 = SFD 0xD5 (数据)
localparam [7:0] ETH_PREAMBLE_BYTE = 8'h55;  // preamble octet (7 个里第 1 个被 /S/ 顶掉)
localparam [7:0] ETH_SFD_BYTE      = 8'hD5;  // <sfd>: 串行位序 10101011

// ---- 7. 帧长 / IFG ----
localparam integer ETH_MIN_FRAME_OCTETS   = 64;    // 512 bits, 含 FCS
localparam integer ETH_MAX_BASIC_OCTETS   = 1518;  // 不带 tag
localparam integer ETH_MAX_QTAGGED_OCTETS = 1522;  // 带 VLAN tag
localparam integer ETH_IPG_OCTETS         = 12;    // interPacketGap = 96 bits = 12 octets

// ---- 8. FCS (802.3 3.2.9 多项式 + 本仓库板级验证的字节序约定) ----
localparam [31:0]  ETH_CRC32_POLY_REFLECTED = 32'hEDB88320;  // 反射形式
localparam [31:0]  ETH_CRC32_INIT           = 32'hFFFFFFFF;  // "first 32 bits complemented"
localparam [31:0]  ETH_CRC32_FINAL_XOR      = 32'hFFFFFFFF;  // "The bit sequence is complemented"
localparam [31:0]  ETH_CRC32_RESIDUE_RX     = 32'hDEBB20E3;  // 全帧(含 FCS)流过后的残留(反射引擎)
// 字节序: 4 个 FCS 字节 = (crc ^ FINAL_XOR) 的【低字节先出】(小端)，见 rtl/mac_tx_64.v:170,213
// 危险: 0xC704DD7B 是"大端/非反射"实现的魔数，与上面这个残留互为位反转，千万别混用

// ---- 9. 加扰器 (802.3 49.2.6, 式 49-1) ----
//    G(x) = 1 + x^39 + x^58 ；无初始值要求；sync header 不过加扰器
//    ⚠️ 实现请照标准 Figure 49-8 的电路图(系数约定与教科书相反, 脚注 8 明确警告)
//    ⚠️ 本 GT 用的是异步 gearbox ⇒ 加扰/解扰【必须】我们在 fabric 里自己做
//       (UG576: "Scrambling of the data is done in the interconnect logic")

// ---- 10. 本板 GT fabric 侧 header (AMD 明文 example + UG576 Fig.3-7 注1) ----
localparam [5:0] GT_TXHDR_DATA = 6'b000001;  // 数据块 (AMD example 原文直证)
localparam [6:0] GT_TXSEQ_ASYNC64 = 7'd0;    // 8 字节接口 + 异步 gearbox: 不用, 接 0
```

**推导项（可信但非"厂商明文直证"）——故意**不**放进上面代码块**：
`GT_TXHDR_CTRL`（控制块）应为 **`6'b000010`**。理由链：UG576 Fig.3-7 注 1（`ug576.txt:6203`）"H1 corresponds to TxB<0>, H0 to TxB<1>" ＋ 802.3 同步头控制块 = `10`（先发 1 再发 0）⇒ TxB<0>=1→H1=1、TxB<1>=0→H0=0 ⇒ `6'b000010`。**同一推导对数据块给出 `6'b000001`，与 AMD 例子逐位吻合，可作交叉验证。** 但仍需 P7b 上板确认（见 §8）。

---

## 8. ❌ 未核实清单（**不要当事实用**）

| # | 项 | 为什么没核到 | 建议怎么核 |
|---|---|---|---|
| **U1** | **控制块的 `txheader[5:0]` = `6'b000010`** | 由 UG576 Fig.3-7 注 1 + 802.3 sync header 两条已核实事实**推导**得出，但**无厂商明文写这个值**，也**无板级证据**。另：UG576 是 **GTH**，GTY 对应文档是 UG578，本次**下载不到** | 【S8】给的实验 E1：在现有 P7a 位流上加 VIO 选 `txheader`，自环回读 `rxheader` 看是否与期望一致 |
| **U2** | **`txdata[63:0]` 与"字节流"的精确映射** | 我手上 UG576 Figure 3-7 是 **4 字节(32 位)接口**的图（`ug576.txt:6146`–`6200`），它显示 `TXDATA[31]` 先发、`TXDATA[0]` 后发 ⇒ 32 位接口下 `TXDATA[31:24]` 是**第一个**字节。**64 位接口的图（UG578 Figure 3-11 一类）没拿到**。另有干扰项：AMD example 里有 `// Bit-reverse the txdata_out assignment … since gearbox modes transmit data MSb first`（`gt_10gbr_example_stimulus_64b66b_async.v:78-86` 做了一次全 64 位反序），但那是 example 为对齐 PRBS 收发而做的，**不能据此推断"真实数据也要反序"** | 板级/仿真确定：发一个已知字节序的图案，读 `rxdata` 比对 |
| **U3** | **7 位 C 码如何嵌入 8 位控制字符字段**（补的零位在 bit7 还是 bit0？） | Figure 49-7 的位级矩形无法从 PDF 文本层恢复（我用了 `-layout` 与 `-raw` 两种抽取，右列全糊）。标准只说"单比特字段（图中无标号的窄矩形）发送为 0 并在接收时忽略"（`:13538`–`:13540`）。**强提示**：【S3】给 `0x1E` 块的测试向量字面写的是 `0x1E`、`0x00` 这些值（`unh49.txt:421`），暗示"字节值 = C 码"，**但这不是逐位确证** | 用 Xilinx 加密 IP 做仿真（跑 `ten_gig_eth_pcs_pma` 的 sim netlist 看 RX 出 XGMII 的字节值），或板级自环回 |
| **U4** | **4 位 O 码在 8 位字段里的位置**（高半字节还是低半字节） | 同上，Figure 49-7 位级细节不可读 | 同上 |
| **U5** | **GTY（UG578）与 GTH（UG576）在 gearbox 细节上的差异** | `docs.amd.com` / `xilinx.com` / `docs.xilinx.com` 的 UG578 均**下载失败**（返回 HTML 而非 PDF，2,575 B）；WebFetch 对该域被环境策略拦截 | 换网络/换镜像取 UG578；或直接查 Vivado 安装目录下 `GTYE4_CHANNEL.v` 原语模型 |
| **U6** | **`/L/` 这个控制字符** | **802.3-2008 Table 46-3 / Table 49-1 里没有 `/L/`**（本次逐行核过全表）。任务书提到的 `/L/` 我在本版标准里找不到任何出处 | 若确需，指明是哪个修订/哪个 Clause 引入的再查 |
| **U7** | **`/F/` 这个记法** | 802.3-2008 里 `0xF7` 叫 **reserved5、无记法**。后续修订（802.3dm 基线文本）才把它叫 `/F/` | 若要跨修订统一，需引对应修订号 |
| **U8** | **UG578"16 字节接口时 `TXHEADER[4:3]` 也用于 normal mode"** 这条 | 我只在**搜索结果摘要**里见到（未取到原文），且**与本设计无关**（我们是 8 字节接口） | 仅作记录，不必核 |
| **U9** | 手册里"12 GHz"与 10GBASE-R 的关系 | 与本常量表无关，且 CLAUDE.md 已说明"本轮没触及 12 GHz 边界" | 不属于本任务 |

**⚠️ 再次强调**：U1–U4 这四条，**任何一条错都会导致"板上安静失效"**（帧发不出去 / FCS 全错 / 对端判无效块）。
P7b 上板前**至少**要有一条独立证据覆盖 U1 与 U3。

---

## 9. 10GBASE-R vs 1G/GMII/XAUI 差异速查（防止把 1G 写法当 10G 规范）

| 项 | 1G / GMII（现有实现） | 10GBASE-R / XGMII（本设计） |
|---|---|---|
| 数据通路 | 8 位 @125 MHz（GMII） | **64 位 @156.25 MHz**（XGMII） |
| 帧首 | **线上直接是 `0x55`×7 + `0xD5`**（`rtl/mac_tx_64.v:99`） | **第 0 字节是 `/S/`(0xFB，控制)，只剩 6×`0x55` + `0xD5` 是数据** |
| 帧尾 | `tx_en` 拉低 | `/T/`(0xFD) 控制字符，位置隐含在 block type field 里 |
| 帧间 | `tx_en=0` | **`/I/`(0x07) 控制字符**，最少 12 字节（XGMII 上发送侧可短到 9、接收侧最少 5） |
| 控制字符体系 | **无**（靠 TXC/TX_ER） | **有**：`/I/ /S/ /T/ /E/ /Q/`（+ 保留的 `/R/ /A/ /K/ /Fsig/`） |
| 编码 | 无（GMII 明文） | **64b/66b + 自同步加扰 `1+x^39+x^58`** |
| PHY | PHY 芯片（RTL8211E） | **GTY 硬核 PCS/PMA**（我们直接对接 GT 的 gearbox fabric 接口） |
| FCS | 同（`0xEDB88320` 反射 / init `0xFFFFFFFF` / 终值取反 / **小端字节序**） | **完全相同**（标准 3.2.9 对 1G/10G 是同一个定义） |

现有 1G 实现可复用：**FCS 那套（`crc32_8b.v` 的约定 + 残留 `0xDEBB20E3`）**；**不可复用**：帧首/帧尾/帧间的字节级形式。

---

## 10. 本次侦察的一页纸小结

- **已确证常量**：XGMII 控制码 12 条、10GBASE-R C 码 8 条、O 码 2 条、sync header 2 条、**block type field 全 16 种**、preamble/SFD 2 条、帧长 4 条、IFG 3 条、FCS 约定 5 条、加扰多项式 1 条、GT `txheader` 数据块取值 1 条 —— **合计约 55 条**，全部写进 §7 的 Verilog 块。
- **未核实**：9 条（§8），其中 **U1/U2/U3/U4 是"上板前必须再核"的关键项**。
- **本地 Xilinx 源码里没有可抄的表**（`_vl_rfs.sv` / `_rfs.v` 全是 `pragma protect` 密文，非 base64 行数 = 0）—— **这一条是本次最重要的"止损"结论**。
- **最容易错的三个点**：
  1. **帧首不是 `55×7+D5`，而是 `/S/ + 55×6 + D5`**（§2.2/§2.4）。
  2. **FCS 是唯一 MSB-first 的字段**，且 `0xDEBB20E3` / `0xC704DD7B` 两个魔数极易混用（§4.3/§4.4）。
  3. **`/A/` `/K/` 的 XGMII 码在 2000 草案与最终标准里是反的**，网上抄错极多；以 802.3-2008 Table 49-1 为准（§1.4）。
