# P7b `udp_split` app 分流板级失效 —— 根因定位报告 (2026-09-30)

> 输入 = `_proj_10g/notes/P7B_GATE4_ACCEPT.md` §4.3 + `_proj_10g/notes/p7b_gate4/live/` 原始件。
> 本报告**只做定位**；**未改任何 `rtl/` / `board/` 文件**（理由见 §6：根因未钉死 ⇒ 按"拿不准就不要改"）。
> 新增物 = 一条**此前不存在的** P7B_10G 真 wrapper 全链门（§7），它是本轮的判别工具。

---

## 0. 结论（要点先给）

| # | 结论 | 置信 |
|---|---|---|
| 1 | **不是配置回归**。`cfg_dst_ip`/`cfg_port0`/`EXCL_PORT` 自 P5e 起**一次都没被改过**，P6e 与 P7b 用的是**同一组常量**（git 实测，§3-Q2）。 | **实锤** |
| 2 | **不是 RTL 逻辑缺陷，也不是宏组合接线错**。新建的 **P7B_10G 真 wrapper 门**用**逐字节同几何**的教学帧（100 B 载荷 / 142 B 帧长 / 同一组宏）实测：`udp_rx.stat_pass=1 → meta_valid → app 口交付 stat_app=1`，**11 判据 0 fail**；长度扫描 60/98/142/333/1518 B 全认领；**第 120 帧才发教学帧**（复现板级 `W0=0x77` 的时序）仍认领；负对照 8080 按期望走 HLS（§7）。 | **实锤** |
| 3 | **板级帧确实到了、而且完好**：`snap_C.txt` 的 `W2 = 0x92 = 146`（= **142 内容 + 4 FCS**，我这条门的 `rx_stat_bytes` 对同一几何读数**也是 146**）⇒ **MAC 的"最近一帧"就是教学帧那一款**（本场次里唯一的 142 B 帧源就是 `p6e_udp_pattern` 的 teach 帧；ping 98 / ARP 60 / 8080-测试 60 都不是）；同一快照 `W3=W4=W38=0`、`W31 == W37 = 17853`、`W1 == 4·W0 + W31 = 18353` **逐位成立** ⇒ **从 MAC 输出到慢路径入口逐字节守恒**。（这条证据 accept 报告没用上，本轮补出。） | **实锤** |
| 4 | ⇒ **2 与 3 直接冲突**：帧完好 + RTL 会认领，却在板上被交给 HLS。 | — |
| 5 | **根因未钉死**。能钉死的只有"**到达 `udp_rx` 时它自己的 7 条判据里有一条不成立**"；而 **`udp_rx` 的 `stat_pass` / `stat_drop_ipcsum` / `stat_drop_nonmatch` 与 `udp_split` 的 `stat_app_frames`/`stat_hls_split`/`stat_drop_excl` 全部不在 51 字窗口里** ⇒ 观测盲区。**这是观测缺陷，不是"分流逻辑错"**（分流逻辑已被 §7 的门证明正确）。 | **实锤（=盲区）** |
| 6 | 连带发现（与本题无关但同属盲区）：**两次教学包的第一次根本没被板子收到**（`W0 0x72→0x72`，而 tcpdump 抓到它在线上）⇒ 10G RX 侧**存在丢帧**，而 `mac_rx_10g` 的 `short/long/frag/no_s/er_words/bad_words/q` **七个计数器都不在窗口里** ⇒ 同样无法归因。 | **实锤（计数不变）** |
| 7 | 连带发现：**闸 4 那颗位流的时序并不干净**——`WNS −0.173 / 39 个 setup 失败端点`（全在 TX MII 域）。accept 报告通篇未提。它**不能**解释 RX 侧症状（RX 域 `WNS +0.206 / 0 失败`），但引用该位流时必须写明。 | **实锤** |

---

## 1. 现象（复述 + 本轮订正一处口径）

- 对端发 `192.168.100.100:50177 → 192.168.100.2:8081` 的 UDP 帧（tcpdump 抓到，IPv4 total 128、UDP 长度 108、载荷 100 B ⇒ **帧内容 142 B、含 FCS 146 B**）。
- 板子收到（`W0` +1、`W3=0` FCS 干净），但 `W6`（慢路径收下）+1、`W10`（app 收帧）恒 0 ⇒ `udp_split.meta_valid` 从未脉冲 ⇒ peer 表空 ⇒ 图案帧零帧。
- 对照：同一对端发 8080 ⇒ 逐字节回显 ⇒ RX/MAC/HLS 清白。

**本轮订正（不重要但影响引用）**：accept 报告 §4.3-2 用"`W0` +1"当"板子确实收到了**那一帧**"的证据。**严格说 `W0` +1 只证明"多收了一帧"，不证明是哪一帧。** 本报告用 `W2 = 146` 把它补成实锤（§5 证据 E3）。

---

## 2. 逐条问答 1 —— 配置的实际取值（源码，非笔记）

全部在 `board/wrapper_p4.v` 的 `` `ifdef APP_MODE `` 块内（`u_udp_split` 例化 = `:2220`）：

| 配置 | 实际取值 | 出处 |
|---|---|---|
| `cfg_dst_ip` | `32'hC0A86402` = **192.168.100.2** | `board/wrapper_p4.v:2254` |
| `cfg_port0` | `UDP_APP_PORT` = `16'h1F91` = **8081** | `board/wrapper_p4.v:2219`（localparam）+ `:2256` |
| `cfg_port1/2/3` | `16'hFFFF` ×3（未配置哨兵，**不是 0**） | `board/wrapper_p4.v:2256-2257` |
| `cfg_port_any` | `1'b0` | `board/wrapper_p4.v:2258` |
| `cfg_multi_en` | `1'b0` | `board/wrapper_p4.v:2255` |
| `EXCL_PORT` | `16'd8080`（**例化点未覆盖 ⇒ 取参数默认**） | 默认值 `rtl/udp_split.v:156`；例化点 `board/wrapper_p4.v:2220` 无 `#(...)` |

**与"发往 192.168.100.2:8081"匹配得上吗？匹配得上。** 逐项：`ip_match`（`rtl/udp_rx.v:180-181`，`{dst_ip[31:16],dst_ip[15:0]} == 0xC0A86402`）、`port_match`（`:182-186`，`tdata[31:16] == 0x1F91`）、`udp_len_ok`（`:187`，`108 ≥ 8`）、`hdr_ok1/2`（`:189-191`）**四项全成立**；`EXCL_PORT` 不命中（`w4_dport=0x1F91 ≠ 0x1F90`、`w4_sport=0xC401 ≠ 0x1F90`，`rtl/udp_split.v:419-420`）⇒ `excl_hit=0` ⇒ 端口配置**不被覆盖**（`:422-426`）。

**⇒ 静态配置面找不到任何不成立的条件。**（这与 accept 报告 §4.3-6 的结论一致，本轮**独立复核并补上了 EXCL 的量化**：`excl_hit` 是唯一能在**同一帧内组合覆盖**端口配置的路径，它不命中。）

---

## 3. 逐条问答 2 —— 对照 P6e，与 P7b 期间的改动历史

**P6e 用的就是同一组常量**：`_proj_pcie/p6e_udp_pattern.cpp:71-72` 默认 `board="192.168.100.2"`、`port=8081`、`teach_len=100` —— 与 `_proj_pcie/p7b_gate4_accept.sh:45-46,57` 完全一致（`BOARD_IP=192.168.100.2`、`--port 8081`）。工具**没换**，帧**同几何**。

**git 实测（不是笔记转抄）**：

```text
$ git log --oneline -S "cfg_dst_ip"        -- board/wrapper_p4.v
5b1bab8 P5e: UDP app 接口收官 ... + learn-on-RX           ← 唯一一次
$ git log --oneline -S "UDP_APP_PORT"      -- board/wrapper_p4.v
5b1bab8                                                    ← 唯一一次
$ git log --oneline -S "cfg_port0"         -- board/wrapper_p4.v
5b1bab8                                                    ← 唯一一次
```

⇒ **P7b 期间（`effef26` 及之后）这三个常量一次都没动过**（`-S` 对"新增一处出现"同样敏感，P7B_10G 块里没有第二份例化）。

**P6e 时代的文件内容（`git show effef26^:board/wrapper_p4.v`）逐行相同**：

```text
1753:    localparam [15:0] UDP_APP_PORT = 16'h1F91;   // 8081
1788:        .cfg_dst_ip     (32'hC0A86402),  // 192.168.100.2 = 本板 IP
1790:        .cfg_port0      (UDP_APP_PORT), .cfg_port1(16'hFFFF),
1792:        .cfg_port_any   (1'b0),
```

**⇒ 不是配置回归。**

**两颗位流之间的全部差异（这才是真问题）**：

| 项 | P6e | P7b |
|---|---|---|
| 构建宏（`build_p6e_ku5p.tcl:110` / `build_p7b_ku5p.tcl:140`） | `APP_MODE DEV_USP PCIE_OBS DP_156MHZ` | **+ `P7B_10G`** |
| 前端 | `mac_rx_64`（RGMII，FE 125 MHz） | **`mac_rx_10g` + 官方 PCS（FE = 恢复钟 156.25 MHz）** |
| `rtl/rx_classify.v` | **v1**（`effef26` 之前） | **v2**（`effef26` 落地；`git log -1 -- rtl/rx_classify.v` = `effef26`） |
| `rtl/udp_split.v` | 与 P7b **同一份**（最后一次改动 = `448b9f7`/P5f，**不在 P7b**） | 同左 |

⇒ **嫌疑只有两个：`P7B_10G` 前端 / `rx_classify` v2。** 两者都被 §7 的新门覆盖，**都没能复现**。
（⚠️ 附带发现：v2 落地时只跑了 **P4 默认矩阵**，**没有**任何 APP_MODE 门回归 —— P5e 的 app 门（`sim/p5e_udp/*`）**不在** P4 矩阵里。这解释了"为什么这个改动没有板级前的把关"，但**不等于** v2 有缺陷 —— 见 §7。）

---

## 4. 逐条问答 3 —— 匹配逻辑逐行代入（把那一帧的字段代进去）

判据链在 `rtl/udp_rx.v`（例化于 `rtl/udp_split.v:432`），**帧首 6 字是 w0..w5**：

| 判据 | 出处 | 那一帧的代入 | 结论 |
|---|---|---|---|
| `s_axis_tkeep == 8'hFF`（w1..w4） | `rtl/udp_rx.v:251,261,270,281` | w1..w4 是整字（帧内容 142 B > 5×8） | **成立** |
| `hdr_ok1`：`w1[31:16]==0x0800 && w1[15:8]==0x45` | `:189-190` | w1 = `532c6801 0800 4500` | **成立** |
| `hdr_ok2`：`w2[7:0]==0x11` | `:191` | w2 = `0080 002a 4000 4011` | **成立** |
| `ipcsum_ok`：20 B 反码和 == 0xFFFF | `:170-178` | 见下 | **成立**（仿真实测） |
| `ip_match`：`{w3[15:0], w4[63:48]} == cfg_dst_ip` | `:180-181` | `C0A8 6402` == `C0A86402` | **成立** |
| `port_match`：`tdata[31:16]==cfg_portN` 或 `port_any` | `:182-186` | `1F91 == 1F91` | **成立** |
| `udp_len_ok`：`tdata[15:0] >= 8` | `:187` | `0x006C = 108` | **成立** |
| `tkeep[7:6]==2'b11`（w5 拍） | `:298` | w5 = `0000 a0a1a2a3a4a5`，`tkeep=0xFC` | **成立** |

**⇒ 逐项代入，7 条判据全部成立 ⇒ 应当在 w5 拍产生 `matched=1` 与 `meta_valid` 脉冲**（`:202,290-294`）。
**⇒ 与板级读数（`W10=0`、`W6+1`）矛盾。**

⚠️ **本轮自查踩到过一次同构的坑（值得记下，因为它正是"静默分流"的完整样本）**：我第一版 TB 把 IP 校验和算错（算成了**帧前 20 字节**而非 **IP 头 20 字节**，值 `0xC34C` 而不是 `0xF08B`）。**后果 = `ipcsum_ok=0` ⇒ `stat_drop_ipcsum+1` ⇒ 帧被 `S_DROP` ⇒ 原样交给 HLS ⇒ `W6+1`、app 0 帧、peer 表空、图案零帧 —— 与板级现象逐条一致，且 `W3`（FCS）恒 0（FCS 覆盖的字节与 IP 头无冲突）。**
⇒ **这条路径在板上是"一个字节的差"就能造出全部症状，而现有 51 字**一个字都照不到**。**（本轮已修正校验和，门转绿。）

---

## 5. 逐条问答 4 —— 定性（附判别性证据）

| 假设 | 判别性证据 | 判定 |
|---|---|---|
| **(a) 纯配置回归** | `git log -S` 三常量只命中 `5b1bab8`(P5e)；`git show effef26^:` 的 P6e 文件逐行相同；`_proj_pcie/p6e_udp_pattern.cpp:71-72` 与 `p7b_gate4_accept.sh:45-57` 的 IP/端口/载荷长度逐一相同 | **否（实锤）** |
| **(b) RTL 逻辑缺陷** | §7 新门：P7B_10G 真 wrapper + 同几何帧 ⇒ `stat_pass=1`、`meta_valid` 脉冲、`stat_app_frames=1`、`hls=0`；长度 60/98/142/333/1518 全认领；120 帧历史后仍认领；负对照 8080 正确落 HLS | **否（实锤）** |
| **(c) 构建宏组合差异** | P6e 与 P7b 的宏差 = `P7B_10G`；wrapper 里 `udp_split` **只有一个例化点**（`:2220`，在 `APP_MODE` 内），`P7B_LAT`/`P7B_LAT_DRP` **本轮未定义**（`build_p7b_ku5p.tcl:140` 只有 5 个宏）⇒ 没有第二个源接到 `cfg_*`/`udp_split` 上；`rtl/udp_split.v` 在 P7b 期间**零改动** | **否（实锤）** |

**⇒ 三个假设全部被否。剩下的唯一解释方向 = "到达 `udp_rx` 的那个帧（的某个头字段）与我们在线上看到的帧不同"，而它必须满足"字节数守恒、FCS 依然正确"。**
**⇒ 本报告不给这一条背书为结论**：`u_rxcdc`(fifo_async) / `vlan_strip` / `rx_classify` / `u_pre` 都是**字节数守恒**的模块，任何"内容变而字数不变"的机理都必须从它们内部找，而**目前没有任何计数器能看见内容**（§6）。

**一条被本轮否掉的候选（留档，免得后人重走）**：`W26 = 3`（RX CDC FIFO 满拍数）**不是**溢出 —— `fifo_async` 的 `full` **复位值是 1**（悲观设计，`rtl/fifo_async.v:202`），释放后 2 拍同步链才落地 ⇒ **3 拍 = 复位窗口**；`W27`（写域峰值占用）= 6/256 佐证。
**另一条被否掉的**：`udp_split.pw_cnt` 只靠 SOP 复位（`rtl/udp_split.v:394,396`），看起来"丢 SOP 就漂移"；但**即便 SOP 全丢**，`app_sel_r` 仍会在 `u_meta_valid` 拍锁存（`:664-665`），`pb_dec_cyc` 会在帧尾经 `f_l` 触发（`:646`）⇒ 帧**仍会被认领**（只是回卷点推迟到帧尾）⇒ 产生的是"**HLS 与 app 同时看到**"（`W6+1` **且** `W10+1`），**与板级"W6+1 而 W10=0"不符** ⇒ **SOP 丢失不是根因**。

---

## 6. 逐条问答 5 —— 最小修法

### 6.1 我**没有**改任何 RTL —— 理由

任务书：**"必须是已用证据钉死根因之后的改动"**。本轮把 (a)/(b)/(c) 全部用实锤否掉，但**没能钉死"哪一条判据在板上不成立"**（因为它落在观测盲区里）。**在这种状态下改 `rtl/` 或 `board/` 就是乱改**（本工程最贵的一类改动）。⇒ **本轮只交定位 + 修法建议。**

### 6.2 建议的下一步：**只加观测、不改逻辑**（一次 build 把 7 条判据压到 1 条）

`udp_split` 里**已经有**全套解析器计数器（`ifdef RXP_DIAG` 下作为 `v5_up_*` 端口引出，`rtl/udp_split.v:282-286`），**零新增逻辑、零新增寄存器**：

```
v5_up_pass (PS) = u_udp_rx.stat_pass           ← 匹配且 FCS 好
v5_up_nm   (NM) = u_udp_rx.stat_drop_nonmatch  ← 头坏/非 UDP/ip_match/port_match/长度 不成立
v5_up_ipc  (IC) = u_udp_rx.stat_drop_ipcsum    ← **IP 校验和错**（唯一单条件）
v5_up_crc  (DC) = u_udp_rx.stat_drop_crc
v5_up_bytes(SB) = u_udp_rx.stat_bytes
```

**改法（三处，全是"接线 + 常量"）**：
1. `board/build_p7b_ku5p.tcl:140` 的 `verilog_property verilog_define` 里加 **`RXP_DIAG=1`**；
2. `board/wrapper_p4.v:2269`（`udp_split` 例化的 `stat_*` 之后、`ifdef RXP_DIAG` 段之前）加 3 个字：把 `PS/NM/IC` 接进一个 3×32 的束；
3. 该束按既有惯例走一条 **`snap_cdc`**（`rtl/snap_cdc.v`，与 P7b 三条新束同一手法）进 51→**54** 字窗口；⚠️ **扩窗要按 `board/wrapper_p4.v:3053,3062` 注释的"七处"同步改**（含 `snap_base` 位宽 ≥12 位、`axi_regs.SNAP_NW`、验收脚本的"未实现地址" 0xEC→0xF8）。
   **为什么 3 个字够**：`PS+NM+IC+DC == 到达 udp_rx 的帧数`（互斥划分），所以 `IC=1` ⇒ 就是校验和；`NM=1 且 IC=0` ⇒ 就是 ip/port/长度/头格式；`PS=1` ⇒ 判据全过（那问题在 `udp_split` 的认领拍，另行插桩）。

**为什么这是最小**：不碰任何数据通路、不碰端口表（`RXP_DIAG` 段的端口是**条件追加**，默认构建逐位不变 —— 这是该文件既有的硬约定）、不动时序；且**这三个字在单元门里已经有完整回归**（`sim/p5e_udp/*`、`sim/rxpdiag/*`）。

**另一条零 build 的判别实验（更便宜，建议先做）**：**连发 20 个教学帧**，观察
- `ΔW0 == 20` 而 `W10` 不变 ⇒ 帧都到了、都在匹配层被拒 ⇒ 走 6.2 的插桩；
- `ΔW0 < 20` ⇒ **RX 侧在丢帧**（与 §0-6 同族）⇒ 优先查 `mac_rx_10g` 那 7 个**未接出的**丢弃计数（`stat_rx_short/long/frag/no_s/er_words/bad_words/q`，`board/wrapper_p4.v:833-839`（`mac_rx_10g` 例化处）有名端口，但线网只在 `:359-361` 声明、只被 `mrx_stat_rx_words/pay_bytes` 用掉 ⇒ 其余**未进快照**）。

### 6.3 会不会破坏别的构建？

- 6.2 的三处改动**只加在 `P7B_10G` / `RXP_DIAG` 内**：`build_p6e_ku5p.tcl` / `build_p6b_*` / K7 各档的宏表**不含 `RXP_DIAG`** ⇒ 它们逐位不变。
- ⚠️ **但 6.2 会让 P7b 位流与闸 4 那颗 sha256 `d1ddb3b4…87aa` 不同** ⇒ 引用板级读数时必须换 `BUILD_ID`（现 `0x00000007`）。

---

## 7. 逐条问答 6 —— 怎么证明修对了（**并且：现成门现在是绿的**）

### 7.1 ⭐ 先答"现成门现在是不是绿的" —— **全绿，而这正是最强线索**

| 门 | 命令 | 实测 |
|---|---|---|
| T1 单元门 | `cmd //c 'sim\p5udp\run_tb_udp_split.bat'` | **PASS**（`P5 UDP SPLIT UNIT GATE PASS`，12 app 帧 + 4 个负对照） |
| T3/T4/T5 app 门 | `cmd //c 'sim\p5e_udp\run_tb_app_udp.bat' pos` | **OK**（`rx_frames=10 rx_bytes=13305 tx_frames=25 ... split=15 pat_bad=0`） |

**⇒ 现成门全绿而板上红 ⇒ 门漏了什么？** 逐条说清：

1. **这两个门都是 1G 前端构建**（`gmii_clk` = RGMII 125 MHz，`mac_rx_64`）⇒ 它们**结构上不可能覆盖** `P7B_10G` 那条前端（官方 PCS + `mac_rx_10g` + 真 156.25 恢复钟 + `u_rxcdc` 两域近等频）。
2. **P7b 的"链级门 80 判据"覆盖的是新 MAC 的帧流合同**，**不含** RX→app 分流。
3. ⇒ **"P7B_10G 构建下 RX→app 端口分流"在 `effef26` 之前根本没有门** —— 与工程坑 8/25 同族（每个 `ifdef` 配置都要有一条真 wrapper 全链门）。

### 7.2 本轮补的那条门（**新物**）

```
_proj_10g/p7b_appsplit/sim/tb_p7b_appsplit.v       ← TB
_proj_10g/p7b_appsplit/sim/run_tb_p7b_appsplit.bat ← 门 (自定位 + 隐式网硬失败)
运行: cmd //c '_proj_10g\p7b_appsplit\sim\run_tb_p7b_appsplit.bat'
日志: _proj_10g/p7b_appsplit/sim/xsim_appsplit.log
```
编译宏与真位流**逐条一致**（`P7B_10G PCIE_OBS DEV_USP APP_MODE DP_156MHZ` + 两个仿真专用 `P6B_SIM_CLKGEN P7B_SIM_NOPCS`），PCS 槽位放 `board/p7b_pcs_stub.v`（端口表与真核相同）+ 自算位串行 CRC-32 构造**真几何**帧（dst mac/IP/port 与 `p6e_udp_pattern` 的 teach 帧同款）。

**实测输出（本轮，`11 checks / 0 fail`）**：

```
  [F1] rx_frames=1 rx_bytes=146 crc_err=0 | srx_commit=0 |
       split(stat_app=1 app_bytes=100 drop_crc=0 drop_ovf=0 drop_part=0 drop_excl=0 hls=0 hls_drop=0 hls_split=1) |
       udprx(pass=1 nm=0 ipc=0 crc=0 bytes=100)
  [F1] app_rx_frames(W10)=13 udpapp_rx_frames=1
  [PASS] A1 frame received by MAC
  [PASS] A2 udp_rx saw a matching frame (stat_pass)
  [PASS] A3 udp_split claimed it for app
  [PASS] SW app claim (len sweep)      ← 60 / 98 / 142 / 333 / 1518 / 50 B 六档全过
  [PASS] B1 teach frame after 120 frames is claimed   ← 复现板级"第 120 帧"时序
  [PASS] B2 udp_rx matched it
  [F2] rx_frames=129 | srx_commit=54 | stat_app=8 drop_excl=1 hls=121 | udprx(pass=8 nm=121 ipc=0)
==== tb_p7b_appsplit done: 11 checks, 0 fail ====
```

- **`rx_bytes=146` 与板级 `W2 = 0x92 = 146` 同值** —— 这是"我这条门的帧 == 板级那一帧"的独立交叉验证。
- `F2` 行是负对照（8080）：`drop_excl=1`、`hls=121`、`pass=8` —— **8080 被 EXCL 排除、正确落 HLS** ✓。
- ⚠️ **边界如实登记**：这条门的 PCS 是**桩**（真核是加密 GT IP，本工程从没在 xsim 里 bring-up 过）。所以它**不能**证明"真 PCS 交付的字节流与桩一致" —— 那正是 §5 里唯一剩下的解释方向。**这条门证明的是"RTL 与配置对这条路是通的"。**

### 7.3 三个门（单元 / 真 wrapper / 默认构建回归）的实测

| # | 门 | 实测 |
|---|---|---|
| ① 单元门 | `sim\p5udp\run_tb_udp_split.bat` | **PASS**（见 §7.1） |
| ② 真 wrapper 全链门 | `_proj_10g\p7b_appsplit\sim\run_tb_p7b_appsplit.bat`（**新**） | **11 checks / 0 fail** |
| ③ 默认构建回归 | `cmd //c 'sim\p4gates\run_matrix_p4dfix.bat'` | ✅ **16/16 `EXIT=0`，runner 退出码 0**（gate 序：chain / burst200 / trunc50 / trunc100 / halfdrop / txdrop50 / gate4096 / dupstorm / pcackoob / vlanchain / vlanburst / stallgate / unit_retx / unit_fifo / unit_vlan / unit_uart）。原始件 = `_proj_10g/p7b_appsplit/matrix_out.txt` |

> 说明：任务书要求"改动后必须跑"这三个门。**本轮没有改任何 `rtl/` / `board/` 文件**（`git status` 实测：`rtl/` 与 `board/wrapper_p4.v` 零改动），①② 是为"钉死 (b)/(c)"而跑的判别实验，③ 是为给主线一个"仓库默认构建仍绿"的交接基线而跑的。
> ⚠️ 跑 ③ 会**改写已跟踪文件** `sim/p4sim/matrix_p4dfix.log`（那是门自己的日志，属正常副作用）。

---

## 8. 未钉死 / 未测（**不得当结论引用**）

| # | 项 | 状态 |
|---|---|---|
| 1 | **七条判据里到底哪一条在板上不成立** | **未钉死**（盲区）。必须靠 §6.2 的插桩或 §6.2 的连发实验 |
| 2 | "到达 `udp_rx` 的字节流内容与线上不同" | **仅为方向性推断**，**无任何直接证据**；且需要"字节数守恒 + FCS 仍对"这个强约束 |
| 3 | §0-6 的"第一次教学帧没被收到" | 现象实锤（`W0` 不变），**机理未归因**；也不排除对端 TX 侧（工程教训第 8 条：注入路径不可假定无损） |
| 4 | 真 PCS 的 XGMII 交付与桩是否逐字节一致 | **本轮无能力测**（加密 IP 未在 xsim bring-up）；板级间接证据 ping/8080-echo 只覆盖 60–98 B 帧的**载荷** |
| 5 | 闸 4 位流的 39 个 setup 失败端点（TX MII 域） | 已登记（§0-7）；**与本题的因果关系未建立**（RX 域 0 失败） |

---

## 9. 原始件索引（全部在本仓内）

| 路径 | 内容 |
|---|---|
| `_proj_10g/p7b_appsplit/sim/tb_p7b_appsplit.v` · `run_tb_p7b_appsplit.bat` | **本轮新建的 P7B_10G 真 wrapper 全链门** |
| `_proj_10g/p7b_appsplit/sim/xsim_appsplit.log` | 该门 11/0 的原始日志（含逐字 `[SLOW]`/`[POP]`/`[UDPRX]` 轨迹） |
| `_proj_10g/p7b_appsplit/matrix_out.txt` | 默认构建回归矩阵原始输出（§7.3-③） |
| `_proj_10g/notes/p7b_gate4/live/snap_C.txt:7-9,31,37` | **`W2=0x92=146` 钉死教学帧身份** + `W6=W0=125` + `W31=W37=17853` 守恒 |
| `_proj_10g/notes/p7b_gate4/live/snap_post_teach_attempt.txt:7-9,38` | 同一守恒律（`W0=114 W1=17236 W2=91 W31=16780`，`4·114+16780=17236` ✓） |
| `_proj_10g/notes/p7b_gate4/live/teach_probe.txt` · `teach_probe2.txt` | 两次教学包：第 1 次 `W0` 不变（**没收到**）、第 2 次 +1 |
| `_proj_10g/notes/p7b_gate4/live/stage3_full_fixed_traffic.txt:15,20` | 证明 `p6e_udp_pattern --secs 15 --board 192.168.100.2 --port 8081` **确实跑了**并发了 1×100 B |
| `board/p7b_ku5p_timing.rpt:154-159,207-208` | 闸 4 位流：`WNS −0.173 / 39 失败`（全在 `txoutclk_out[0]_1`）；RX 域 `+0.206 / 0`；`g_hw.clk_out0` `+0.170 / 0` |
| `board/build_p6e_ku5p.tcl:110` · `board/build_p7b_ku5p.tcl:140` | 两颗位流的宏差 = `P7B_10G` |
