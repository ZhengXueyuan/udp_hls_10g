# P7B_W9_GAP —— 「`W9` 口径 vs 线上实测 差 8 B/帧」定案

**一句话结论：分类 (B) 真丢字节。** 不是口径差、也不是量纲差 —— `rtl/app_udp_pattern.v` 的 TX 字 FIFO
（`u_txf`）写口用了**一拍错位的空间门**（`txf_wr` 是寄存器，却拿**本拍**的 `txf_full` 做门），
在 FIFO 饱和的那一拍**静默丢弃一笔已计数、已算进 `seg_sent` 的推入** ⇒ 每帧丢 **1 个整字 = 8 B**。
`W9` 计的是 *app 决定推入* 的载荷字节（= `i_paylen` = 1472/帧），线上载荷只有 **1464 B/帧**。
帧器（`udp_tx_frame`）**清白**：它没有 `i_paylen` 口，`udp_len = plen_n + 8` 里的 `plen_n` 就是它
**实收**的 1464 B ⇒ 线上 `udp_len = 1472` 与线上载荷 1464 **自洽**。

> 本轮**只读调查**：未改任何已跟踪文件。仿真台架与产物在 `_tmp_w9probe/`（新建、未跟踪）。
> 唯一新增的跟踪候选文件 = 本笔记。

---

## 0. 复现命令（最小台架）

```
_tmp_w9probe/
├── tb_w9probe.v    # app_udp_pattern(1472) → udp_tx_cfg → udp_tx_frame → sink(tready)
│                   # 探针: 决定推入数 / 真落笔数 / FIFO 读出数 / 帧器接受数 / 逐帧长度+udp_len
├── run_case.sh     # usage: sh run_case.sh <tag> "<xvlog -d ...>" "<xsim plusargs>"
├── mut/app_udp_pattern_fix.v   # 只在 scratch 里的**修法验证**副本 (原文件未动)
└── run_{def,p7bonly,ovlonly,rate_fast,rate_stall,rate_fix}/   # 各档 xsim.log
```

```sh
cd _tmp_w9probe
sh run_case.sh rate_fast "-d P7B_10G -d UDP_TX_OVL" ""            # = RATE 位流的宏组合
sh run_case.sh p7bonly   "-d P7B_10G"              ""            # 只开 8 路发生器
sh run_case.sh def       ""                        ""            # 默认构建
sh run_case.sh ovlonly   "-d UDP_TX_OVL"           ""            # 只开帧器乒乓
sh run_case.sh rate_stall "-d P7B_10G -d UDP_TX_OVL" "-testplusarg STALL"  # 下游每 8 拍停 1 拍
APPSRC=.../_tmp_w9probe/mut/app_udp_pattern_fix.v sh run_case.sh rate_fix "-d P7B_10G -d UDP_TX_OVL" ""
```

---

## 1. `W9` 到底是什么

| 环节 | 位置 | 原文 |
|---|---|---|
| 快照映射 | `board/wrapper_p4.v:3572` | `udpapp_tx_bytes,         // W9  → dp[3]  图案 app 发字节` |
| 线束声明 | `board/wrapper_p4.v:1289` | `wire [31:0] udpapp_tx_bytes, ...` |
| 接到状态行 | `board/wrapper_p4.v:1465` | `.udp_tx_bytes   (udpapp_tx_bytes),` |
| 来源 | `board/wrapper_p4.v:2496` | `app_udp_pattern` 实例内的 `.stat_tx_bytes  (udpapp_tx_bytes),`（该实例跨 `:2478-2523`） |

⇒ `W9` = `app_udp_pattern.stat_tx_bytes`。**累加的是「载荷字节数」，不是 `plen+8`**，只有两处赋值：

```
rtl/app_udp_pattern.v:778    stat_tx_bytes <= stat_tx_bytes + 32'd8;              ← P7B_10G 宽路径: 每推 1 个满字 +8
rtl/app_udp_pattern.v:797    stat_tx_bytes <= stat_tx_bytes + {28'b0, need};      ← 逐字节路径: 每推 1 字 +need
```

（`nul_push` 分支**不加**计数 —— 我在第一轮误读过，逐行核对后更正：`:785-787` 只推 `{tlast,keep=0}`，
不动 `stat_tx_bytes`。所以 `W9` 的口径**纯是载荷**，与线上 `payload` **同一量纲**。）

⚠️ 关键语义（文件自己的注释与代码不符）：`rtl/app_udp_pattern.v:40-41` 写
`stat_tx_bytes/TX_GAP 都记在**推送侧** ⇒ "app 已发" = "app 已交付"` ——
**代码只在"决定推入"那一拍加计数**，而**不做**任何落笔确认 ⇒ "已发" ≠ "已交付"。
这正是本缺陷能藏在 `W9` 背后的原因。

## 2. `i_paylen` 从哪来、到哪去（这条链与交接件的假设不同）

* 来源 = 常量：`board/wrapper_p4.v:2483` `.i_paylen (12'd1472), // MTU 内最大 UDP 载荷`（`app_udp_pattern` 的实例）。
* 去向 = **只到 app**。`udp_tx_frame u_udp_tx`（`board/wrapper_p4.v:2569`）**没有 `i_paylen` 端口**
  （端口表见 `rtl/udp_tx_frame.v:28-58`）。帧器**完全**从输入字流的 `tkeep` 自己数长度：

```
rtl/udp_tx_frame.v:181 (UDP_TX_OVL 分支) / :483 (else 分支)
    wire [11:0] plen_n = (recv_first ? 12'd0 : plen) + {8'b0, pop8(s_axis_tkeep)};
rtl/udp_tx_frame.v:271 / :568
    udp_len_r[rx_bank] <= plen_n + 12'd8;      /   udp_len_r <= plen_n + 12'd8;
```

⇒ **`i_paylen` 不参与 `udp_len` 的计算**。交接件 §4-#17-② 的推理链
（"`i_paylen=1472` ⇒ `plen_n=1472` ⇒ `udp_len` 应为 1480"）第一步就不成立：
`plen_n` = 帧器**实收**字节数，可以是 1464。线上读到的 `udp_len=1472` 恰好证明 `plen_n = 1464`。

## 3. 帧器看到的 `plen_n` 到底是多少（仿真读数）

`tb_w9probe` 逐帧解码，六档对照（`len` = 帧器输出字节数 = 42 + 载荷；线上 = `len+4` FCS）：

| 档 | 宏 | 帧器实收/帧 | `udp_len` | 帧器输出 `len` | 丢字（committed-but-dropped） |
|---|---|---|---|---|---|
| `def` | 无 | **1472** | **1480** (`w4=...05c8`) | 1514（线上 1518） | **0**（`full_cyc=0`） |
| `ovlonly` | `UDP_TX_OVL` | **1472** | **1480** | 1514 | **0** |
| `p7bonly` | `P7B_10G` | **1464** | **1472** (`w4=...05c0`) | 1506（线上 1510） | **53 / 53 帧 = 1.0/帧** |
| `rate_fast` | 两个都开 | 1464 或 1472 | 1472 / 1480 | 1506 / 1514 | 54 / 106 帧 ≈ 0.5/帧（相位依赖） |
| `rate_stall` | 两个都开 + 下游慢 | 1464 为主 | 1472 | 1506（81/91） | 85 / 94 ≈ 0.9/帧 |
| **`rate_fix`** | 两个都开 + **修法副本** | **1472（全部 103 帧）** | **1480** | **1514 全部** | **0** |

示例读数（`rate_fast`）：
```
W9PROBE app: bytes=156616 frames=106 pushdec=19577 actual=19523 refused=0
W9PROBE xfer: fiford=19268 frmacc=19268  (delta_to_framer=255)
W9PROBE fifo: occ_max=256 full_cyc=210
W9PROBE framer: frames=103 bytes=151216 drop_len=0
W9PROBE wire: frames=103 len_min=1506 len_max=1514 n1506=50 n1510=0 n1514=53
W9PROBE FRAME 3 w2=05d4000300004011 w4=64031f911f9105c0      ← ip_tot=0x05d4=1492, udp_len=0x05c0=1472
```
**恒等式闭合**：`pushdec(19577) = actual(19523) + dropped(54)`；`actual(19523) = fiford(19268) + FIFO 余量(255)`；
`framer stat_bytes(151216) = 50×1464 + 53×1472` **逐字节精确**。⇒ 8 B 不是"没生成"，是**生成并计数后被丢在 FIFO 写口**。

**板级 = 饱和那一列（100% 帧 −8 B）**：pcap 40/40 帧 `eth=1506`、对端 NIC `Δbytes/Δpackets = 1510.0000`
（四轮逐字相同）⇒ 板上是**锁相极限环，恒 1 字/帧**。仿真里 `rate_fast` 50/50、`rate_stall` 81/91 的
非 100% 是**模型相位**造成的（我这台模型每帧周期不恒等 ⇒ 饱和时刻相对帧边界的相位在漂）；
`p7bonly`（帧器最慢 ⇒ 字 FIFO 长期满）能给到 100%，与板级同形。

**回答"`UDP_TX_OVL` 开关会不会改变这个值"**：不会。`udp_len` 由 `P7B_10G`（app 变 8 B/拍）决定；
`UDP_TX_OVL` 只改帧器结构（`else` 分支 `plen_n+8` 与 OVL 分支逐字相同，`:568` vs `:271`）。

## 4. 电路层根因（定案）

```
rtl/app_udp_pattern.v:477-483   fifo_sync #(.W(73), .D(256), .AW(8)) u_txf (
                                    .wr(txf_wr && !txf_full), .din(txf_in), ...
rtl/app_udp_pattern.v:504       wire gen_ok = (txs == T_FRM) && !txf_full && !nul_pend && (seg_sent < seg_len);
rtl/app_udp_pattern.v:509       wire nul_push = (txs == T_FRM) && nul_pend && !txf_full;
```

`txf_wr` 是**寄存器**（`txf_wr <= 1'b1`，本轮决定、下拍落笔），而空间门用的是**本拍**的 `txf_full`。
本工程已把这条危害写成 `fifo_sync` 的合同并给了现成端口：

```
rtl/fifo_sync.v:6-17    ⚠️ `full` 是本拍的组合值, 不是"下拍还能不能写"… 空间门必须用 `full_next`
                        `ovf_pulse = wr && full`: 本拍有一次写被拒 (字静默丢失)… 恒 0 才叫"无静默丢失"
rtl/mac_rx_64.v:23-26,131   push 是寄存器 ⇒ push_ok = !fifo_full_next   （已按合同修好）
rtl/rx_classify.v:93        full_next 本版不用 (wr 是组合写, 见上)      （组合写 ⇒ 无此问题）
```

`app_udp_pattern` 是**唯一**没按合同改的生产者，而且它的实例化**连 `full_next`/`ovf_pulse` 都没接**
（`:480-483` 只有 `.empty/.full` + `dbg_*`）⇒ 而且因为 `.wr()` 已经把门 AND 进去了，FIFO **内部**的
`ovf_pulse = wr && full` 结构性恒 0 ⇒ **这个丢字在现有设计里没有任何计数器/现象能看见**
（工程坑 24「哑门」的同族：诊断被上游的预门杀死）。

**为什么只丢 1 字/帧、且只在 P7B_10G 出现**：饱和事件 = FIFO 被写满。`P7B_10G` 的 8 路发生器把
app 产能推到 **1 字/拍**（184 字/帧 = 184 拍），而帧器收帧节奏是 184 字 / ~192 拍 ⇒ app 每帧多出
~8 字 ⇒ 字 FIFO 必饱和（仿真 `full_cyc`：`p7bonly` 9819/10000、`rate_fast` 210）。饱和时刻**恰有一笔
在飞的写**，于是那一笔被丢（+ 计数照加）。默认构建（逐字节 1 字/8 拍）app 比帧器**慢 8 倍**，
FIFO 永不接近满（`def`/`ovlonly`：`full_cyc = 0`）⇒ 1G 时代（P6b 956 Mbps、字节级一致）**看不到**这个缺陷。

## 5. 修法建议（**未动手**）

最小改动（与 `mac_rx_64` 的先例同款，两处 + 一个声明）：
1. `:471` 旁加声明 `wire txf_full_n;` + 在 `:481`（`.empty(...), .full(...),`）后接 `.full_next(txf_full_n)`；
2. `:504` `gen_ok` 的空间门 `!txf_full` → `!txf_full_n`；
3. `:509` `nul_push` 同步改（0 长数据报路径）。

自检（防复发）：把 `.ovf_pulse(w_ovf)` 接出来进一个计数器（状态行/快照窗口），**恒 0 才叫无静默丢失**
—— 当前"恒 0"是结构性的，不是证据。

验证：`_tmp_w9probe/mut/app_udp_pattern_fix.v` 就是上面 3 步的副本（**只在 scratch**），
`rate_fix` 档读数 = **103/103 帧 `len=1514`、`udp_len=1480`、零丢字**（= 线上 1518 B，即
`P7B_SPEC §2.2` 的计划几何）。
⚠️ 注意速率影响：修好后线上帧长 1510→1518（+1 字/帧 ≈ +1 拍/帧），而载荷 +8 B/帧 ——
两者近似抵消（估 ≈ 9.53→9.54 Gbps 量级），**速率结论不翻转**，但 RATE 的帧几何判据
（`A1`/`B0-2` 的期望值 1518）会在修后**变成正确的口径**，需要重跑一轮再定案。

## 6. §4-#17-② 的口径该怎么改（建议文本）

> ~~`i_paylen=1472` ⇒ `udp_len=1480`，而线上 1472 ⇒ 中间路径有 8 B/帧的差~~
> ⇒ **已定案（`P7B_W9_GAP.md`）**：`udp_tx_frame` 无 `i_paylen` 口，`udp_len = plen_n + 8`，
> `plen_n` = **实收**载荷；线上 1472/1464 自洽。差的 8 B/帧是**真丢失**：`app_udp_pattern` 的 TX
> 字 FIFO 写口空间门一拍错位（`rtl/app_udp_pattern.v:477-509`），每帧静默丢 1 个整字，`W9` 照计。
> ⇒ 单列一条**真缺陷**（不是一个口径问题）；`W9` 口径的速率（9.583 Gbps）必须标注为
> "**app 推送计数口径**（含被丢弃的字）"，线上载荷一律用 **9.531 Gbps**（RATE 轮已用该数，结论不变）。

## 7. §4-#20-② 三条注释的只读核实

| # | 注释原文（现行） | 实际是什么 | 差在哪 |
|---|---|---|---|
| ①  `board/wrapper_p4.v:2447` | `// UDP app 演示的统计线束 (板级不可观测, 由 TB/将来状态行读; 不接 = 无消费者)` | **已进 PCIe 快照窗口**：`udpapp_tx_bytes`=`W9`(`:3572`)、`udpapp_tx_frames`=`W8`(`:3573`)、`udpapp_rx_*`=`W10/W11`、`udpapp_mismatch`=`W13`、`udpapp_rx_null`=`W12`（`:3565-3574`），RATE 轮**已在板上读到** `ΔW8/ΔW9/ΔW13` | **过期**：线束已有消费者（快照窗口），"板级不可观测"不再成立 |
| ②  `board/wrapper_p4.v:2468` | `// i_paylen 恒 12'd1472 = app 契约上限 (1518 - 42);` | ① 算术：`1518-42 = 1476 ≠ 1472`；正确写法 = `1518-46`（1518 含 FCS）或 `1514-42`（不含 FCS），两者都 = 1472（已用 Python 复核）。② **"契约上限"不准确**：RTL 里的长度守卫是帧器的 `PLEN_MAX = 12'd1500`（`rtl/udp_tx_frame.v:65`）+ app 的 `parameter PLEN_MAX = 12'd1500`（`:93`）；1472 是**本构建配置的载荷**，不是契约上界 | 算术错 + 语义标签越界；`1518-42` 这个算式本身是笔误来源 |
| ③  `board/wrapper_p4.v:2474` | `// (~929 Mbps 载荷 @1472B/帧)。要恢复限速演示只需把本行改回 16'd58000 ——` | 那是**默认构建（125 MHz）**的读数（`P7B_RATE_8WAY.md §2.4` `sim/p5e_rate g0p1472`），P7B_10G 构建下不成立（RATE 轮 813,794.7 fps ⇒ `W9` 口径 9.583 / 线上载荷 9.531 Gbps） | **过期**（跨构建引用未标注）。另：`@1472B/帧` 这个标签在 P7B_10G 下也错（线上 1464）——**该标注与本笔记同源，可在订正时一并注明** |
| 附 `:2483` | `.i_paylen (12'd1472), // MTU 内最大 UDP 载荷` | **正确**：1472（载荷）+ 8 + 20 + 14 + 4(FCS) = 1518 ✓ | 无。§4-#20-② 里"`:2483` 语义标签与实测对不上"这句**是误推**（它默认线上该有 1472 载荷）；按本笔记，标签与语义自洽，对不上的是实现 |

## 8. 未做 / 边界

* 未改任何已跟踪文件；`board/wrapper_p4.v` / `rtl/app_udp_pattern.v` / `rtl/udp_tx_frame.v` 一字未动。
* 未跑真实 wrapper 全链（`_proj_10g/p7b_chain`）——本台架截取的就是可疑段（app→cfg→帧器），
  下游 `tx_arb/CDC/mac_tx_10g` 对长度字段透明（线上 `udp_len` 是帧器写的），不影响定案。
* `rate_fast` 的 50/50 混合是模型相位，不是"有时不丢"的另一种机理；板上 100% 的判据 =
  pcap 40/40 + NIC `1510.0000`×4。
* `pushdec` 里含"在飞"的 1 笔（停止采样瞬间），报告里的 `dropped` 数按
  `pushdec − actual − 在飞/余量` 的**恒等式**核对过（见 §3）。
