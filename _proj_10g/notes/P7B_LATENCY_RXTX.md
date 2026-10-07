# P7B_LATENCY_RXTX.md —— 「乒乓测试中，一个 TCP 包从收到发在板上（不含光模块）的穿透延时」

> 2026-10-07 · **只读取证**：未改任何 RTL / 未烧板 / 未跑仿真综合 / 未动 git（除本文件）。
> 全部换算按 **1 拍 = 6.4 ns @156.25 MHz**（域内实测周期：FE **6.39989 ns** ← P7a 实测 156.253906 MHz；
> DP **6.39967 ns** ← P6b 实测 156.2585 MHz —— 出处 `P7B_LATENCY.md:183-185`。两者与标称差 5×10⁻⁵，本文按 6.4 算）。
> 来源四分，**逐格标注**：**【实测】**=板上取数（给原始件行号）· **【RTL导出】**=逐行读 RTL 数拍（给 文件:行）
> · **【推算】**=由已证事实/既有报告算出 · **【未知】**=没有证据。
> ⚠️ 本工程纪律：**RTL 拍数不等于实测延迟** —— 两者在下面每张表里**分列**，不混用。

---

## 0. 一句话答案（三个口径，先给数）

| 口径 | 数（板上，不含光模块） | 性质 |
|---|---|---|
| **① TCP 数据段进来 → 纯 ACK 段出去**（**现役位流里唯一真实存在的「TCP 进 / TCP 出」路径**） | **≈ 294 – 301 ns** | 2 段实测 + 6 段 RTL导出 |
| **② TCP 数据段进来 → 同一数据段回发出去**（echo 构建；**现役位流没有这条路**，见 §1） | **≈ 384 – 390 ns**（100 B 载荷；末字节出 ≈ 506 – 512 ns） | 同上 |
| **④ TCP 数据段进来 → app 口看到**（现役位流的真实终点，tcp_echo→app_rx_*） | **首字 ≈ 217.6 ns**（整帧入队 ≈ 198.4 ns） | 2 段实测 + RTL导出 |
| **③ UDP echo（HLS 慢路径 8080 端口；唯一"真回显"通路，是 UDP 不是 TCP）** | **≥ ~1.3 µs + HLS 内部（未知）** | 1 段实测 + 1 段推算 + 未知 |

⚠️ **以上全部不含 PCS/PMA 内部**（`L_PCS`，最大缺口，零读数）与 **TX 侧 PCS 内部**（同样零读数，
且此前**未登记**——本轮新增登记，见 §5-U2）。**也不含光模块**（用户口径已排除）。
要换成"第一个 bit 离开/到达光口"：再 +`6.21 ns`（前导串行化）+ 两个 PCS 内部值。

---

## 1. 前置问题 1：板上到底有没有「TCP 包收到就发回」这条路？

**答：现役位流（`APP_MODE=1`）里没有。** 逐条核过：

| 核点 | 结论 | 证据 |
|---|---|---|
| fast path 收到数据后**发出去的是什么**？ | ① **纯 ACK 段**（`ack_req` → `tcp_tx_frame` 的 ackq，ACK 优先于数据）；② 载荷**不是回发**，而是送进 `tcp_echo` 帧 FIFO → `axis_pipe` → **`app_rx_*`**（= 演示 app 的 RX 校验器，只比对不回发） | `rtl/tcp_rx.v:360-369`（`ack_req`）；`wrapper_p4.v:1073-1079`（`app_rx_* = eco2_*`）；`rtl/app_pattern.v:19`（RX = 逐字节比对） |
| `tcp_echo` 是回显吗？ | **是零拷贝回显件**（模块头注自述"echo 为测试件"），但它的消费方**只在 `APP_MODE` 未定义时才接到 `tcp_tx_frame`**：`wrapper_p4.v:1485-1490`（`#else` 支）`assign txin_* = eco2_*`；`APP_MODE` 支（`:1088-1092`）是 `txin_* = app2_*`（**app 自己的发流**） | `rtl/tcp_echo.v:2-3`；`wrapper_p4.v:1064-1067` 注释逐字："默认 (未定义 APP_MODE): txin_* = eco2_*" |
| 现役位流的构建宏 | `APP_MODE=1 DEV_USP=1 PCIE_OBS=1 DP_156MHZ=1 P7B_10G=1 UDP_TX_OVL=1` ⇒ **`APP_MODE` 是开的** | `board/build_p7b_ku5p.tcl:145`；`_proj_10g/notes/P7B_WU_BUILD.md:36`（stdout 自证） |
| HLS 里的 "TCP echo / Port 7" | HLS 源码头确实写 "TCP Echo Server / Port 7 echo"（`#define TCP_PORT_ECHO 8080`），但本设计里 **HLS 的 TCP 数据面结构性不可达**：`rx_classify` 把 IPv4/TCP 的**数据段**一律判 fast（`dec_w5`：flags 无 SYN/FIN/RST ⇒ `RT_FAST`，**不看 CAM**），而 fast 支里 CAM 未命中的段被 `tcp_rx` 判 nonmatch **丢弃**（`S_DROP`）—— HLS 只见到 SYN/FIN/RST 控制帧 | `hls/src/layer_tcp.cpp:3-4,17`；`rtl/rx_classify.v:99-107`；`rtl/tcp_rx.v:299-300`（`base_ok = cam_hit_l && …`）、`:671-694`（nonmatch → S_DROP）；`hls/src/layer_tcp.cpp:13-16` 注释（"数据面全在 fast path RTL, HLS 只见 SYN/FIN/RST"） |
| `udp_echo`（HLS, 8080 端口） | **唯一真回显**通路：UDP 载荷原样发回（慢路径）。是 **UDP**，且走 HLS | `rtl/udp_split.v:416-426`（EXCL_PORT=8080 留给 HLS）；`hls/.../udp_echo.v` 进现役网表（`P7B_BRAM_REPORT.md`） |
| `peer.exe --echo` / `tb_p4_chain` / P5c echo 门 | 都是**对端/仿真侧的** echo（PC 栈或 TB 模型），不是板上通路 | `tb/tb_p4_chain.v:2-3`（含"真 HLS udp_echo"）；`tb/tb_tcp_echo.v` |

⇒ **「TCP 包原样回发」在本板现役位流里不存在**。下面给**最接近的三种口径** + 一个附加口径（现役终点），全部逐段给数。

---

## 2. 前置问题 2：「乒乓」指哪一个？两个口径下的延迟是否不同？

**本仓「乒乓」只有两处，且都不在 TCP 的 RX→TX 回发路径上：**

| 乒乓 | 位置 | 现状 | 对**单包穿透延时**的影响 | 对**帧周期/吞吐**的影响 |
|---|---|---|---|---|
| **UDP 组帧器乒乓重叠**（宏 `UDP_TX_OVL`） | `rtl/udp_tx_frame.v:69-215`（双 bank + RX/TX 双引擎） | ✅ **现役构建已开**（`build_p7b_ku5p.tcl:145`） | **≈ 0（不缩反微增）**。它把"收帧 N+1"与"发帧 N"**重叠**，但每帧仍是**整帧 store-and-forward**：`bank_rdy[rx_bank]` 交棒后 TX 才起跑（`:222-268`）⇒ 单帧"首字入→首字出" = **整帧收完 + ~5 拍**，与默认版**同量级**（乒乓版交棒 = `RX_FIN` 3 拍 + `T_IDLE→T_HDR` 1 拍；默认版 = `S_WAIT` 3 拍 ⇒ **乒乓版约 +1 拍**，是代价不是收益） | ✅ 收益全在周期：378 → **191 拍/帧**（【仿真实测】`P7B_RATE_FRAMER.md` §3）；4.87 → 9.63 Gbps |
| **`tcp_tx_frame` 乒乓** | —— | ❌ **未做**（设计件：`P7B_BIZ_PLAN.md:543` 行 f、`P7B_GAP9_TCPAPP_8WAY_DESIGN.md:22`） | 若实现，同样**不缩单包穿透延时**（同一 store-and-forward 结构，只是把**下行帧周期** 380 → ~193 拍） | 4.803 → ~9.5 Gbps（预期） |

⇒ **回答"乒乓测试里的 TCP 包延时"：乒乓只改吞吐，不改单包穿透延时；且 `UDP_TX_OVL` 与 TCP 包**毫无关系**（它只在 UDP app TX 支：`app_udp_pattern → udp_tx_cfg → udp_tx_frame`）。
**TCP 包的 TX 走 `tcp_tx_frame`（无乒乓）** ⇒ 口径 ①/②/④ 的延时**不受乒乓宏影响**。
（"乒乓"在本仓的唯一实战用途 = RATE 线速测量的第二刀，那是 **UDP 图案流**的测试，见 `P7B_RATE_FRAMER.md`。）

---

## 3. 分段预算表

**统一起点 = `(a)` 点**：PCS 把帧首 `/S/` 呈现在 **XGMII** 上的那一拍（`rx_mii_c_1[l] && rx_mii_d_1[8l+:8]==8'hFB`，FE 域）。
**统一终点 = XGMII 上的首个「内容字」**（PCS 输入口；不含 PCS 内部与光模块）。
（起点口径沿用 `P7B_LATENCY.md:148` 的 (a) 定义；"首个内容字"= 前导/`/S/` 字之后的那个字 —— 即 DA 首字节所在字。）
⚠️ **口径说明**：起点是 `/S/` 字（前导组），比"DA 首字节（= 帧内容第一字节）"早 **1 个 XGMII 字**。
若要 **DA→DA** 的口径，各合计**各 −6.4 ns**（终点不动：内容字那一拍就是 DA 开始串行化的那一拍）。

### 3.1 口径 ①：TCP 数据段进来 → 纯 ACK 段出去（**现役位流**，100 B 载荷的段）

| # | 段 | 拍数 | ns | 来源 |
|---|---|---|---|---|
| 1 | `(a)` `/S/` 字 → `(b)` MAC RX 输出 SOP 被接收 | **4 FE 拍** | **25.60** | **【实测】** `P7B_LATENCY.md:243`（26 样本零离散；原始件 `p7b_lat/board_scratch/analysis.txt:8+` 逐行 `a->b = 25.60`） |
| 2 | `(b)` → **fast 支 SOP**（`(cf)`）：含 `u_rxcdc`(异步 FIFO) + `vlan_strip` + `rx_classify` 路由队列判决 | **7 DP 拍**（= 慢支实测 4 + TCP 支 +3） | **44.80** | 混合：4 DP = **【实测】** `P7B_LATENCY.md:244`（±26 ns 跨域偏置，见 §5-U4）；+3 = **【RTL导出】** `rx_classify.v:103-107`（`dec_w2` vs `dec_w5`）、`:131-133`（`rq_wr_ok`→`rq_empty` 清） |
| 3 | `(cf)` SOP → **本帧最后一个输入字**（= `ack_req` 触发拍） | 19 DP 拍 | 121.60 | **【RTL导出】** `tcp_rx.v:560-695`（`S_HDR` 吃 w0..w6 = 7 字）+ `:700-798`（载荷 1 字/拍）；100 B 载荷帧 = 20 字（w0..w19），末字在 `+19` 拍；触发式 `:360-369`（`fend_pay`） |
| 4 | `ack_req` → ackq 写 → `ack_pend_r` 置位 | 2 DP 拍 | 12.80 | **【RTL导出】** `tcp_tx_frame.v:678,701-715`（入 ackq）+ `fifo_sync` 写→空清 1 拍 + `:782`（`ack_pend_r <= !ackq_empty`） |
| 5 | `start_ack` → **首字在帧器 `m_axis` 就绪**（S_WAIT 5 + S_HDR 发射寄存器 1 + 首字 1） | 7 DP 拍 | 44.80 | **【RTL导出】** `tcp_tx_frame.v:334`（`start_ack`）、`:1024-1033`（S_WAIT = 5 拍）、`:1034-1055`（S_HDR 发射寄存器） |
| 6 | `tx_arb` 帧首重仲裁**把首字收下**（空闲→busy；首字在帧器输出多压 1 拍） | 1 DP 拍 | 6.40 | **【RTL导出】** `tx_arb.v:36-52`；同族【仿真实测】`P7B_RATE_DATAPATH.md:55`（+1 拍） |
| 7 | `u_txcdc`（DP→FE 异步 FIFO，FWFT） | **3~4 FE 拍** | 19.2 ~ 25.6 | **【RTL导出】** `rtl/fifo_async.v:47-50` 逐字契约："最快 2 个 rd_clk 才能被读侧看见 ⇒ `!empty` 最早出现在写入沿之后第 3 个 rd 沿（外部按 empty 变 0 数 = 第 4 个）"；实例 `wrapper_p4.v:2681-2690` |
| 8 | `mac_tx_10g`：输入 FIFO 写 → `!empty`(+) → `S_PRE` 前导(+) → **首内容字** | 3 FE 拍 | 19.20 | **【RTL导出】** `mac_tx_10g.v:91-97`(FIFO FWFT)、`:117-119`(`frd`)、`:335`(S_IDLE)、`:337-350`(S_PRE 发前导并捕获首字)、`:307`(TX 镜像 `bswap64`，**组合**，0 拍) |
| **合计（不含 PCS）** | | **≈ 43 拍** | **≈ 294.4 – 300.8** | |

- 加 PCS：`+ L_PCS_rx + L_PCS_tx`（未知）+ 前导串行化 6.21 ns。
- 末字节（ACK 帧末尾）出 = 首内容字 + 7 个字 ≈ +44.8 ns。
- ⚠️ 前提：**TX 侧空闲**（无 app 数据帧在飞）。ACK 在帧级**优先**（`start_ack` 在 S_IDLE 仲裁链最高，`:277-335`），但正在发的帧要走完 ⇒ 若 app 流占满 TX，ACK 排到一个帧之后（单帧 ≤1518 B ≈ 193 拍 ≈ 1.24 µs）。

### 3.2 口径 ②：TCP 数据段进来 → **同一数据段回发**（echo 构建；现役位流无此路）

| # | 段 | 拍数 | ns | 来源 |
|---|---|---|---|---|
| 1 | `(a)`→`(b)` | 4 FE | 25.60 | **【实测】** 同上 |
| 2 | `(b)`→`(cf)` | 7 DP | 44.80 | 混合（同上） |
| 3 | `(cf)` → tcp_rx **首载荷字**（= 头 7 字 + 发射寄存器 1 拍） | 8 DP | 51.20 | **【RTL导出】** `tcp_rx.v:634-695`（w6 拍进 S_PAY）、`:700-798`（S_PAY 首拍 `emit_v<=1`，`:790-796`） |
| 4 | 帧内余下 12 字（13 字帧 = ⌈100/8⌉） | 12 DP | 76.80 | **【RTL导出】** `tcp_rx.v:781-797`（每接受 1 源字出 1 载荷字）；**【实测同族】** 1 字/拍播放的斜率 `P7B_LATENCY.md:377-384`（§5.3，`udp_split` 播放器实测） |
| 5 | `tcp_echo` 帧级判决（store-and-forward）→ 首字转发 | 2 DP | 12.80 | **【RTL导出】** `tcp_echo.v:76`(`judged`)、`:130-146`(pend/judged)、`:149-153`(fq)、`:156-158`(S_IDLE→S_FWD)、`:82`(m_axis_tvalid) |
| 6 | `axis_pipe`（1-deep 全速 AXIS 寄存器） | 1 DP | 6.40 | **【RTL导出】** `rtl/axis_pipe.v:1-24`；实例 `wrapper_p4.v:1887-1896` |
| 7 | `tcp_tx_frame`：首字入 → 收完 13 字 → S_WAIT 5 → S_HDR 发射 1 → **首字在 `m_axis` 就绪** | 19 DP | 121.60 | **【RTL导出】** `tcp_tx_frame.v:473-477`、`:1024-1055`；**【仿真实测同族】** 帧周期模型 `2·⌈plen/8⌉+14`（`P7B_RATE_DATAPATH.md:65,76`，本段即 `k+6`，k=13 ⇒ 19） |
| 8 | `tx_arb` **把首字收下** | 1 DP | 6.40 | 同 §3.1 段 6 |
| 9 | `u_txcdc` | 3~4 FE | 19.2 ~ 25.6 | 同 §3.1 段 7 |
| 10 | `mac_tx_10g` → 首内容字 | 3 FE | 19.20 | 同 §3.1 段 8 |
| **合计（不含 PCS）· 首字节进 → 首字节出** | | **≈ 60 拍** | **≈ 384.0 – 390.4** | |
| **末字节出**（20 个内容字，末字比首字晚 19 字） | | +19 拍 | **≈ 505.6 – 512.0** | **【RTL导出】** 帧内容 154 B = 20 字；FCS/pad 由 `mac_tx_10g` 并入末内容字（`mac_tx_10g.v:300-309`，**不额外占拍**） |

### 3.3 口径 ④：TCP 数据段进来 → **app 口**（现役位流的真实终点；补 `P7B_LATENCY_GAPS.md` 缺口二）

| 终点信号 | 拍数（自 `(a)`） | ns | 来源 |
|---|---|---|---|
| **整帧入队**（末字写进 `tcp_echo` 帧 FIFO = 该报告推荐的**主判据** `stat_tlast_wr`） | 4 FE + 7 DP + 20 DP = **31 拍** | **198.4** | **【RTL导出】** `tcp_echo.v:93,125`（`accept && s_axis_tlast`）；末字 = `(cf)`+20 DP（同 §3.2 段 3+4 之和） |
| app 口**首字可见**（`app_rx_tvalid`，含 `axis_pipe`） | **34 拍** | **217.6** | **【RTL导出】** `wrapper_p4.v:1073-1079`、`:1887-1896` |
| app 口**整帧收齐** | ⚠️ **不可用**：演示校验器 8 B/9 拍（≈0.889 B/拍）⇒ 13 字要 ≈117 拍 ≈ **750 ns 的"假延迟"** | —— | **【实测】** `P7B_LATENCY_GAPS.md:186-187`、`:235` 逐字警告"别用 app 口可见当主判据" |

> 对账：`P7B_LATENCY_GAPS.md:179-180` 对 fast 支固定开销的**预测**是 **13~15 拍 ≈ 83~96 ns**
> （口径 = "①5 拍决策 + ②7 拍头 + ⑥2 拍起播 + ⑦1 拍 pipe"）。
> 我按 RTL 数到的是 **8 拍头（不是 7）= 头 7 字 + 发射寄存器 1 拍** ⇒ 预测值应 +1 拍。
> **两者都未实测**（该报告的实测量是零），列为 §5-U3。

### 3.4 口径 ③：UDP echo（HLS 慢路径，8080 端口）—— 板上唯一的"真回显"

| # | 段 | ns | 来源 |
|---|---|---|---|
| 1 | `(a)` → `(e)` 慢路径适配器入口（SOP） | **95.98**（= 25.60+25.58+44.80） | **【实测】** `P7B_LATENCY.md:243-246,252`（三种帧长、27 样本，跨度 0.05 ns） |
| 2 | `(e)` → HLS 收完整帧（B3 S&F ≈N+1 + **1 字节/拍播放器**(8+L 拍) + B6 1 拍） | **≈ 1209**（158 B 帧） | **【推算】** `P7B_BRAM_TIMING_LATENCY.md:145-156`（§3.3 预算：189 拍，其中播放器 166 拍 = 1062 ns 是主项） |
| 3 | HLS `udp_echo` 内部（S&F + 帧转发 + 慢支 TX 回程） | **未知** | **【未知】** 零读数；连 HLS 工作时钟/流水深度都没有台账 |
| **合计** | **≥ ~1.30 µs + 未知** | | |

---

## 4. 三个已知缺口补进去能改多少

| 缺口 | 补上后对本文四个口径的**增量** | 备注 |
|---|---|---|
| **`L_PCS`（PCS/PHY 内部：CDR→解串→gearbox→RX 弹性缓冲→PCS RX→XGMII）** | **每个口径都 +X，X 未知**（口径① 294→294+X）。它是**最大**的单块未知；**RX 侧与 TX 侧各一份**（TX 侧此前**未登记**，见 §5-U2） | 唯一存在的量级线索 = 一个**未核实**的寄存器字段：`P7B_LATENCY.md:131-134` 写明 `0x269 = RXGBOX_FIFO_LATENCY` **身份未被本仓任何文档证实**、只登记在 `P7B_PHY_IFACE.md:663`（U9），且提示"与 `33 拍 @156.25MHz = 211 ns` 做量级核对"。⚠️ **本文不采用这个数**（未核实） |
| **fast path → app 队列（零读数段）** | 把 §3.3 的 217.6 ns 从 **RTL导出** 升为**实测**；预期值不变（±1~2 拍）。**不改变** ①/② 的口径（那段在 `tcp_rx` 之前） | 施工法 = `P7B_LATENCY_GAPS.md:191-196` 方案 M（复用死字 W15/W16，VIO 位宽不变）+ 一次构建 |
| **`(c)→(d)` 两个 app UDP tap** | **对 TCP 口径 = 0**（本就在 UDP app 支上）。对 UDP app 口径 = 补上 `udp_split` 播放器的 N 字（**【推算】** 首字 N+2~3 拍 ≈ 141~147 ns，`P7B_BRAM_TIMING_LATENCY.md:100`） | 缺的只是**激励**（一个真 IPv4/UDP 帧），零 RTL 改动；机理见 `P7B_LATENCY_GAPS.md:15-16` |

---

## 5. 我没能确定的（如实登记，禁止当结论用）

| # | 项 | 状态 | 影响 |
|---|---|---|---|
| U1 | **`L_PCS` 的绝对值** | **零读数**（`P7B_LATENCY.md:415` U1；`P7B_HANDOFF.md:193,359` 列为最大延迟缺口） | 四个口径全部要加它；"进出光口"的读数还要加它 |
| U2 | **TX 侧 PCS 内部延迟**（XGMII→64b/66b 编码→gearbox→串行） | **零读数，且此前全仓未登记** —— 本文**新增登记**。<br>既有报告只登记了 RX 侧（`P7B_LATENCY.md:311` 逐字只列 CDR/解串/gearbox/弹性缓冲/PCS RX） | 同 U1：所有"出线"口径都要加它 |
| U3 | **口径④ 的 RTL 导出未被任何实测校验** | 探针从未跑过（`P7B_LATENCY_GAPS.md` §2 全篇"零读数"；`(cf)` tap 在 4 轮取数里**恒 0**，因为激励是 IPv6） | ③④ 两列里的 RTL 导出值都建立在"fast 支拍数 = 慢支实测 + 3"这个**模型**上，不是读数 |
| U4 | **`(b)→(c)`/`(cf)` 的 ±26 ns 跨域偏置** | 只知 **2~4 拍**的界，没测出来（`P7B_LATENCY.md:415` U2） | 口径① 的 44.80 一项真值可能到 57.6~70.4 ns（**+13~26 ns 到总延时**） |
| U5 | **`u_txcdc` 的 3~4 拍** | **RTL 契约值**，非实测（`fifo_async.v:47-48` 是设计契约，实际相位还取决于两域相位） | 口径① 的 ±6.4 ns |
| U6 | **ACK 路径的"TX 空闲"前提** | 未实测带 app 流争用时的 ACK 延时 | 争用时 ACK 最多等一个在飞帧（≤193 拍 ≈ 1.24 µs） |
| U7 | **100 B 载荷 = 本文的段长假设** | 用户没说段长。换段长 P 时：口径① 段 3 变（= ⌈(154−100+P)/8⌉−1 = 帧字数−1 拍）；口径② 段 3~7 全变（帧长线性） | ② 首字节 ≈ 384 + (W−13)×12.8 ns，W ≈ ⌈P/8⌉ = tcp_rx 输出的载荷字数（**量级式，未逐点验算**；W−13 里 6.4 落在 RX 帧内、6.4 落在 TX 帧内） |
| U8 | **板上现役位流** | 按 `P7B_WU_BUILD.md:36` 的宏表 = `APP_MODE=1 … UDP_TX_OVL=1`，build 脚本 `build_p7b_ku5p.tcl:145`。**本文未上板核对**（纪律：不烧板、不动板） | 若板上其实是别的宏组合，§1 的"无 echo"结论要重核 |

---

## 6. 引用索引（全部可复核）

**实测原始件**
- `_proj_10g/p7b_lat/board_scratch/analysis.txt:8-60`：逐样本 `a->b=25.60 / b->c=25.56~25.59 / c->e=44.80`
- `_proj_10g/p7b_lat/board_scratch/run{1,2,3}_stdout.txt`：VIO 原始十六进制（4 轮独立取数，每轮重烧）
- `_proj_10g/notes/P7B_LATENCY.md:243-246`（分段表）· `:252`（95.98）· `:264-269`（(B) 读数表）· `:282-292`（硬下限校验）· `:321-331`（逐 ns 模型）· `:415-427`（未核实清单）

**RTL（逐行）**
- `_proj_10g/p7b_mac/rtl/mac_rx_10g.v:206-219`（RX 镜像 `align8`，组合）· `:476-507`（push + FIFO + AXIS）
- `_proj_10g/p7b_mac/rtl/mac_tx_10g.v:91-119`（FIFO/frd）· `:297-316`（发射 mux；`:307` `bswap64` = TX 镜像）· `:335-350`（S_IDLE→S_PRE）
- `rtl/rx_classify.v:84,103-107,131-138,165-173`（判决窗/路由队列/读门）
- `rtl/tcp_rx.v:560-695`（S_HDR 7 字）· `:360-369`（`ack_req`/`ack_val`）· `:700-798`（S_PAY 发射）
- `rtl/tcp_echo.v:76,82,130-158`（判决 + S_FWD）
- `rtl/axis_pipe.v:1-24`（1 拍）
- `rtl/tcp_tx_frame.v:277-335`（S_IDLE 仲裁链：ack > svc > ring > scan > data）· `:473-477`（接受门）· `:678-715`（ackq）· `:955-998`（帧首锁存）· `:1024-1055`（S_WAIT/S_HDR）· `:1056-1113`（S_PAY/S_TAIL）· `:1125-1144`（S_DONE）
- `rtl/tx_arb.v:36-52`（帧级 2:1，+1 拍）
- `rtl/fifo_async.v:47-50`（跨域可见性 3~4 rd_clk）
- `rtl/fifo_sync.v:53-59`（FWFT 写→有效 1 拍；`full_next` 契约）
- `rtl/udp_tx_frame.v:69-215,222-268,300-410`（乒乓双 bank + 交棒）

**装配/配置**
- `board/wrapper_p4.v:1064-1098`（APP_MODE 支：`app_rx_* = eco2_*`；`txin_* = app2_*`）· `:1485-1490`（`#else` 支：`txin_* = eco2_*` = echo）· `:1767-1773`（`cfg_suppress_data_ack(!APP_EN)`）· `:2655-2726`（`tx_arb` / `u_txcdc` / `mac_tx_10g`）· `:2634`（TX 域）
- `board/build_p7b_ku5p.tcl:140-145`（宏表）· `_proj_10g/notes/P7B_WU_BUILD.md:36`

**旁证（仿真/其它报告）**
- `P7B_RATE_DATAPATH.md:57`（`u_txcdc` "只加延迟不加拍"）· `:65,76`（TCP 帧周期模型 `2k+14`，固定项 14 = WAIT5+HDR6+TAIL1+DONE1+arb1）· `:101`（`tcp_rx` "S_HDR 7 拍 + 载荷 1 字/拍"，读-RTL 未实测）· `:55`（`tx_arb` +1 拍）
- `P7B_BRAM_TIMING_LATENCY.md:98`（`tcp_echo` 首字 N+2 拍）· `:145-156`（(e)→HLS ≈1209 ns）
- `P7B_RATE_FRAMER.md:8,76`（乒乓 378→191 拍；191 = 头 5 + 载荷 184 + 尾 1 + DONE 1）
- `P7B_LATENCY_GAPS.md:179-180`（fast 支固定开销预测 13~15 拍）· `:186-187,235`（app 消费者 0.889 B/拍 = 假延迟警告）

---

## 7. 复现本文的全部结论（只读，零重负载）

```bash
cd /d/repo/XCKU5PMini/udp_hls_10g
# ① 实测段（原始读数，逐样本）
sed -n '1,60p' _proj_10g/p7b_lat/board_scratch/analysis.txt
# ② 实测段的报告化引用
grep -n "25.60\|25.58\|44.80\|95.98" _proj_10g/notes/P7B_LATENCY.md
# ③ RTL 拍数锚点（逐行）
grep -n "S_IDLE: if (!fempty)\|S_PRE: begin\|bswap64" _proj_10g/p7b_mac/rtl/mac_tx_10g.v
grep -n "start_ack\s*=\|wait_cnt == 3'd4\|S_HDR: begin" rtl/tcp_tx_frame.v
grep -n "dec_w2\|dec_w5\|rd_ok" rtl/rx_classify.v
# ④ 装配（echo 在哪 / ACK 在 APP_MODE 是否发）
grep -n "APP_MODE\|eco2_tdata\|cfg_suppress_data_ack" board/wrapper_p4.v | head -20
```

⚠️ 本文**没有**、也**不能**给出 `L_PCS`、TX 侧 PCS、HLS 内部三个未知量 —— 它们是**构建+烧板+探针**级别的活，
不是读文件能得到的（路线见 `P7B_LATENCY.md` §1.5 / `P7B_HANDOFF.md` §3-③）。
