# P7B_BRAM_TIMING_LATENCY.md —— BRAM 在流水线里的位置 / 对延迟与对时序的影响

> 2026-09-30 · **BRAM 调查 A2 路**（A1 路负责清点；本文负责**位置 + 延迟 + 时序**）。
> **全程只读**：未改任何 RTL / 脚本 / 工程 / 笔记；**未启动 Vivado / xsim / xvlog**；
> 未碰 `vivado_prj/` 里正在跑的构建（**只读它的 `.rpt`**）；未动 git。
> 标记沿用本工程口径：**【读RTL】**=逐行读源码 · **【读报告】**=读 `.rpt` 原文 ·
> **【推算】**=由已证事实算出 · **【未核】**=没有证据。
>
> ⚠️ **本轮有一个全实现构建正在跑**（`vivado_prj/p7b_ku5p_prj`，19:39 起，route 未完成）。
> 它的 **placed** 利用率已落盘，可读；**routed 时序报告还没有** ⇒ 本文的时序读数一律取自
> **上一轮已收口的构建**，并逐条标注取材哪个文件、哪个宏配置。

---

## 0. 结论速览（先给判词）

| # | 问题 | 判词 |
|---|---|---|
| 1 | BRAM 在哪些级 | **必径（all-traffic）的只有 5 块**：`slow_rx_adp.u_ff`、`slow_tx_adp.u_wf`、`tcp_echo.u_fifo`、`udp_split.u_uf`、`slow_rx_adp.u_ofifo`/`slow_tx_adp.u_ififo` 一对。**最大的一块（`retx_ram` = 256 片 RAMB36 = 全部 BRAM 片的 73.6%）是旁路**——它只在重传时被读 |
| 2 | 延迟贡献 | **已实测的那 95.98 ns 流水里 BRAM 贡献 = 0 拍**（那三段全在 LUTRAM/组合上）。BRAM 的地盘全在 **(e) 点之后**，主项是「整帧 store-and-forward」的 **N 字**（N = 帧载荷字数），158 B 帧 = **20 拍 = 128 ns**；**但 (e) 之后真正的延迟主项不是 BRAM，而是 1 字节/拍的字节播放器**（8+158 = 166 拍 = **1062 ns**） |
| 3 | 时序瓶颈？ | **不是。** 200 条最差 setup 里只有 **2 条**含 BRAM，且都 **逻辑级数 = 0（纯布线）**、都不是该组最差；307 条 hold/removal 里 **0 条** BRAM 在数据通路上。**现行构建的 WNS +0.136 是 PCIe 复位网络的纯布线（Recovery）路径**，WHS +0.010 是 LUTRAM 写址/观测寄存器的短路经 —— 都与 BRAM 无关 |
| 4 | 但有一条真账 | **BRAM 的**问题不是"慢"，是**扇出/布局**：`retx_ram` 的写地址网要驱动 **256 片 RAMB36 的地址脚**，这正是历史上 `WNS −0.848 / 912 失败端点` 那一族（已用"入口寄存 + `max_fanout`"修掉）。本轮它又以 **第 3 差的 dp_clk setup 路径**（0.289，纯布线 5.625 ns）露头 |
| 5 | 唯一 BRAM 主导的时序桶 | **`u_pcie_xdma` 的 hold**：P6b 构建 400 条 hold 里 **73 条含 BRAM、全在 XDMA 内部**，slack **0.010 = 全局 WHS** ⇒ 要收 WHS 第一刀在 XDMA，**不在数据面** |

---

## 1. 位置测绘

### 1.1 数据通路（按 `board/wrapper_p4.v` 的 `P7B_10G + APP_MODE + DP_156MHZ + PCIE_OBS + UDP_TX_OVL` 构建）

```
RX  PCS(156.25M) ─ mac_rx_10g ─ u_rxcdc(FE↔DP) ─ vlan_strip ─ rx_classify ─┐
                                                                            │
      ├─ fast (IPv4/TCP) ─ tcp_rx ─ tcp_echo ─ axis_pipe ─ app_rx_*        │
      └─ slow (其余全部) ─ udp_split ─┬─ 透传 p_axis ─ slow_rx_adp ─ u_hls │
                                     └─ app UDP 口 (u_uf) ─ app_udp_rx_*  │
TX    app ─ udp_tx_cfg ─ udp_tx_frame ─┐                                    │
      app ─ tcb/tcp_tx_frame (含 retx_ram + payload fifo) ─┴─ tx_arb ─ mac_tx_10g ─ PCS
慢    u_hls (HLS udp_echo) ─ slow_tx_adp ─ tx_arb
观测  u_snap_* / snap_cdc / axi_regs / u_pcie_xdma
```

### 1.2 位置表（★ = 必径：该类流量**每一帧**都要过）

| # | 块（网表名） | 链 / 级 | 组织 | 规模 | BRAM 片 | 必经还是旁路 |
|---|---|---|---|---|---|---|
| **B1** | `u_tcp_tx/u_retx`（`rtl/retx_ram.v`） | **TX·TCP** —— 首发时**与载荷同拍旁写**；读口只在 `S_RING`（重传会话）里动 | 2 bank × 64K 字 × 64b + 8 字节使能 | 8.39 Mbit | **256 × RAMB36E2**（= 已用 BRAM 的 **73.6%** / 全器件 **53.3%**）| **旁路**（首发不经过；**仅重传必经**）。⚠️ 但它**每写一个字都落笔**（`wr_tap = accept && tkeep!=0 && !len_bad`）⇒ 面积与扇出是全局的 |
| **B2** | `u_tcp_echo/u_fifo`（`frame_fifo` 8192×73） | **RX·TCP fast** 的 app 帧缓冲 | RAMB36 主存（SDP）+ LUTRAM 边存；FWFT + snap/rollback | 64 KB | **16 × RAMB36E2**（`gen_mem[0..15]`，DRC 逐片点名）| ★ **必经**（TCP fast 支每一帧） |
| **B3** | `u_slow_rx/u_ff`（`frame_fifo` 512×73） | **RX·慢支适配器**（在实测点 **(e) 之后**） | 同上 | 4 KB | **1 × RAMB36E2** | ★ **必经**（所有非 fast 帧） |
| **B4** | `u_udp_split/u_uf`（`frame_fifo` 512×73） | **RX·app UDP 帧缓冲** | 同上 | 4 KB | **1 × RAMB36E2** | **旁路**（只服务 `udp_rx.meta_valid` 匹配的 app 帧；HLS 透传支**不经过它** —— `uf_rd = play_v && app_rx_tready`，透传走 `u_pb` 的 32 深 LUTRAM） |
| **B5** | `u_slow_tx/u_wf`（`frame_fifo` 512×73） | **TX·慢支适配器**（HLS → `tx_arb`） | 同上 | 4 KB | **1 × RAMB36E2** | ★ **必经**（慢支 TX） |
| **B6** | `u_slow_rx/u_ofifo` / `u_slow_tx/u_ififo`（`fifo_sync` 2048×9） | 慢支 ↔ HLS 的**字节** FIFO | `fifo_sync`（`dout` 是寄存器 ⇒ "地址寄存 → 存储 → 输出寄存" ⇒ 可推 BRAM） | 18 Kb / 个 | **【未核】**推测各 1×RAMB36 或 2×RAMB18 | ★ **必经**（慢支） |
| **B7** | `u_hls/...`（HLS 核内部：`frame_fifo_fifo_U`、`buffer_r`、`frame_buf`、`grp_arp_rx_process` 的 3 片） | 慢路径 HLS 核 | HLS 推断 | — | 采样到 **≥2×RAMB36 + ≥4×RAMB18**；HLS `csynth.xml` 报 **43 BRAM_18K**（⚠️ **K7 口径**，非 KU5P） | **旁路**（8080 端口 / ARP 等） |
| **B8** | `u_pcie_xdma/inst/...` | **观测面**（PCIe 窗口） | 厂 IP + XDMA | — | **≥22 × RAMB36E2**（DRC SDP 清单）+ 数据面 FIFO（`ram_top/gen_c2h_bram.*`、`udma_wrapper/.../u_mem_rc`） | **旁路**（只有观测流量） |
| **B9** | `u_app_udp/u_txf`、`u_tcp_tx/u_fifo`、`u_udp_tx_frame/u_fifo{,_a,_b}`（`fifo_sync` 256×73） | TX 侧弹性 FIFO | `fifo_sync` | 18.7 Kb / 个 | **0（实测落 LUTRAM）** —— hold 报告里它们的单元名是 `mem_reg_64_127_*_RAMG` / `mem_reg_0_63_*_RAMA`（分布式 RAM） | ★ 必经（TX 支）。**这条是"小 FIFO 不一定要吃 BRAM"的实物证据** |

> ⚠️ **两条排除项（写给 A1，避免把不算数的算进去）**
> 1. **`rtl/udp_echo.v` 的 `frame_fifo #(.W(73),.D(2048))`（=4 片 RAMB36）不在本轮构建里**：
>    `board/build_p7b_ku5p.tcl:105` 是 `import_files ... [glob ${hls_dir}/*.v]`，
>    而 `rtl/udp_echo.v` **不在这份构建的源码表里**（`:84-94` 那份清单没有它）⇒ 本轮 `u_hls`
>    绑的是 **HLS 生成的 `udp_echo.v`**，那个 RTL 侧 4 片缓冲**没进网表**。
> 2. `u_rxcdc` / `u_txcdc`（`fifo_async` 256×76 / 256×73，FWFT=1）**不是 BRAM**：
>    FWFT 的组合读口 ⇒ 只能是 LUTRAM（`rtl/fifo_async.v:82-85` 自己写明；wrapper 注释同）。
>    它们**在**实测段 (a)→(b)→(c) 里，但**不在** BRAM 账上。

### 1.3 片数对账（**【推算】**，A1 以网表清单为准）

```
Block RAM Tile 348 = 317 RAMB36 + 62 RAMB18(半片计)
  317 RAMB36 ≈ retx_ram 256 (RTL 注释自述 + 2×64K字/512 = 2×128)
             + frame_fifo 19 (tcp_echo 16 + udp_split 1 + slow_rx 1 + slow_tx 1 ← DRC 逐片点名)
             + u_pcie_xdma ≥22 (DRC SDP 清单 22 片)
             + u_hls ≈20 (K7 估计 43 BRAM_18K ≈ 21.5 片，⚠️ 口径不符)
             = 317 ✔（剩余项落在误差里）
```

---

## 2. 延迟预算（本路主产出）

### 2.1 单位与换算（一次性写清）

| 量 | 值 | 出处 |
|---|---|---|
| `dp_clk` 周期 **1 拍** | **6.400 ns**（标称 156.25 MHz）；实测 **6.39967 ns**（P6b） | `P6B_ACCEPT.md`；两者差 5×10⁻⁵（≤200 拍上差 < 0.007 ns，本文按 6.400 算） |
| 线上 1 个字（8 B） | **6.20606 ns**（64 bit / 10.3125 Gbit/s） | 硬下限公式 |
| 数据面"1 字/拍"= | **10.000 Gbit/s**，比 10.3125 Gbit/s 慢 **3.12%** | `P7B_LATENCY.md` §5.3 同一机制 |
| 帧字数 **N** | `ceil((L−4)/8)`：100 B→**12**、158 B→**20**、1514 B→**189** | `P7B_LATENCY.md` §5.1 |

### 2.2 ⭐ 延迟预算表

「读延迟」= **稳态下 FIFO 读写指针的结构性滞后**（**不是**深度/宽度！深度只有当 FIFO 真的被填满时才变成延迟）。
「S&F」= 该块是**整帧 store-and-forward**（消费者要等整帧写完才能动），额外代价 ≈ **N 字**。

| 块 | 链/级 | 读延迟 | S&F 附加 | **典型（158 B，N=20）** | **最坏** | 必经 |
|---|---|---|---|---|---|---|
| **B1 `retx_ram`** | TX·TCP 旁写 / 重传源 | — | 首发 **0 拍**（`wr_tap` 与 `accept` **同拍**，纯旁写）；重传：地址入口寄存器 1 拍 + 输出寄存 1 拍 = **读 2 拍**，且写 beat 取"读于 3 拍前" ⇒ 会话首字 **+3 拍** | **0 拍 / 0 ns** | 重传 **+3 拍 = 19.2 ns**（+ 该会话自身 N 拍播放） | 仅重传 |
| **B2 `tcp_echo.u_fifo`** | RX·TCP fast → app | **1 拍**（`DOA_REG=0` + 边存寄存器读并行） | **是**：`fend ⇒ pend ⇒ judged ⇒ fq≠0 ⇒ S_FWD` 起播 | 首字 **N+2 拍 = 22 拍 = 141 ns**；**【推算】**末字 ≈ **2N+2 = 42 拍 = 269 ns**（直通口径只要 N+1） | 排到 8192 字 ⇒ 单帧额外 **+8192 拍 = 52.4 µs**（消费者慢时；这是弹性，不是结构滞后） | ★ |
| **B3 `slow_rx.u_ff`** | RX·慢支（**(e) 之后**） | **1 拍** | **是**：`do_commit`（帧尾且 FCS 好）才开播 | 首字 **N+1 = 21 拍 = 134 ns** | 满卷不产生延迟而产生**丢弃**（吞字打 `abort` ⇒ 整帧回卷，`stat_drop++`） | ★ |
| **B4 `udp_split.u_uf`** | RX·app UDP | **1 拍**（FWFT 组合读） | **是**：描述符在**帧末字**才 `desc_wr`；播放器 `R_IDLE→R_PLAY` 另 +1~2 拍 | 首字 **N+2~3 = 22~23 拍 = 141~147 ns** | 512 字排满 ⇒ +512 拍 = 3.28 µs（随后溢出是**丢帧**，不是延迟） | 旁路 |
| **B5 `slow_tx.u_wf`** | TX·慢支 | **1 拍** | **是** | **N+1 = 21 拍 = 134 ns** | 同上（满 ⇒ 丢） | ★ |
| **B6 `u_ofifo`/`u_ififo`** | 慢支字节 FIFO | **1 拍**（输出寄存） | 否（流式） | **1 拍 = 6.4 ns** | 排满 2048 字节 ⇒ +2048 拍 = **13.1 µs** | ★ |
| **B9 TX 弹性 FIFO** | TX 支 | **1 拍** | 否 | 1 拍 = 6.4 ns | 排满 256 字 ⇒ +256 拍 = 1.64 µs | ★ |
| **B7/B8** | HLS 核内 / PCIe | （HLS 内部 / 厂 IP） | — | — | — | 旁路 |

**三条要点（别被深度误导）**：

1. **FIFO 的深度不是延迟**。`frame_fifo` 的 `DOA_REG=0` 是**故意**的（见 §4.3），稳态读滞后恒 **1 拍**；
   深度只在"下游停 ⇒ 占用涨"时才兑现成延迟，且这里的占用有**结构性上界**：
   `tcp_echo.u_fifo` ≤ 8192 字、`u_uf`/`u_ff`/`u_wf` ≤ 512 字、TX 弹性 FIFO ≤ 256 字。
2. **本设计里"BRAM 变延迟"的唯一机制是 S&F 门控，不是容量**。`frame_fifo` 的 `snap/rollback + hold_rem`
   语义要求"整帧提交后才可见"⇒ 读者结构性晚 **N 拍**；**这跟它是不是 BRAM 无关**（换成 LUTRAM 也一样，
   只是 LUTRAM 放不下 8192 深）。
3. **单帧延迟 = 2N 而不是 N**：S&F 之后播放又是 1 字/拍 ⇒ 末字总延迟 ≈ **2N + 常数**。
   对比直通（cut-through）的 **N + 常数** ⇒ **S&F 把"帧内串行化"这一项翻倍**。
   1514 B 帧：2×189 = 378 拍 = **2.42 µs**（对 1.18 µs 的线上串行化）。

---

## 3. 与 `P7B_LATENCY*.md` 已有分段的对账

### 3.1 已有读数（原文引，不重算）

| 段 | 拍数 | ns | 出处 |
|---|---|---|---|
| (a)→(b) XGMII `/S/` → MAC RX SOP | 4 FE 拍 | 25.60 | `P7B_LATENCY.md` §3 |
| (b)→(c) MAC 输出 → `rx_classify` slow SOP | 4 DP 拍 | 25.58（含 ±26 ns 跨域偏置） | 同上 |
| (c)→(e) classify → `udp_split` **透传口** SOP | 7 DP 拍 | 44.80 | 同上 |
| **SOP→SOP 流水和** | — | **95.98** | 同上 |
| (e) 之后 | **未测** | — | `P7B_LATENCY.md` §7 U4/U5 |

### 3.2 ⭐ 对账结论一：**实测的 95.98 ns 里 BRAM 贡献 = 0 拍**

逐段核（依据 §1.2 与各模块 RTL）：

| 段 | 经过的存储 | 是不是 BRAM |
|---|---|---|
| (a)→(b) | `mac_rx_10g` 内部 `fifo_sync #(.W(76),.D(16))` | **否**（16×76 = 1216 bit ⇒ LUTRAM）【读RTL】 |
| (b)→(c) | `u_rxcdc`（`fifo_async` 256×76 **FWFT=1**）+ `vlan_strip`（**纯组合移位，零存储**）+ `rx_classify` 内部 `fifo_sync #(.W(76),.D(16),.AW(4))` | **否**（FWFT 组合读 ⇒ 结构性 LUTRAM；16 深 LUTRAM）【读RTL】 |
| (c)→(e) | `udp_split` 的**预取 FIFO**（`PRE_AW=4` = 16 深）+ **透传暂存 `u_pb`**（`PB_AW=5` = 32 深，`ram_style=distributed` 强制 LUTRAM） | **否**（`u_uf` 是 app 支专用，透传支不经它 —— `uf_rd` 只由 app 播放器驱动）【读RTL】 |

⇒ **已量到的三段里没有任何一块 BRAM**。这解释了为什么 95.98 ns 在三种帧长、27 个样本上"跨度只有 0.05 ns"
—— 它是纯组合+小 LUTRAM 的确定性流水，**没有块存储排队**。

### 3.3 ⭐ 对账结论二：**BRAM 的账全在 (e) 之后，而且不是最大项**

(e) 点 = `udp_split` 的 `p_axis_*`（透传口）⇒ 之后依次是 B3（`u_ff`，1 片 RAMB36，S&F）→
字节播放器 → B6（`u_ofifo`）→ HLS。用 158 B 帧算：

| 项 | 拍 | ns | 是 BRAM 吗 |
|---|---|---|---|
| B3 `u_ff` 整帧写入（S&F 门） | 20 | 128 | **是** |
| 提交 → 开播 + `ff_dout` 1 拍 | ~2 | 13 | 是（读口） |
| **字节播放器** 8 B 前导 + 158 B 内容，**1 B/拍** | **166** | **1062** | **不是** |
| B6 `u_ofifo` 1 拍 | 1 | 6 | 是（读口） |
| **合计（(e) → HLS 收完）** | **≈189** | **≈1209** | **BRAM 只占 ~23 拍（12%）** |

⇒ **慢路径的真实延迟主项是那个 1 字节/拍的播放器，不是 BRAM。** 这是本轮最有产品价值的推断：
若要把"慢路径整帧交付"从 ~1.2 µs 压下去，**加宽播放器到 1 字/拍**（166 B ⇒ ceil(166/8) = 21 拍）
**= −145 拍 = −928 ns**，**远大于任何 BRAM 改动**（BRAM 侧全部只有 ~23 拍 = 147 ns）。
（同一机制的姊妹读数：`P7B_LATENCY.md` §5.3 已量到 `udp_split` 播放器 1 字/拍带来的 3.12% 斜率。）

### 3.4 对账结论三：两个已有"预测/口径"被本文钉住

| 已有说法 | 本文的补充 |
|---|---|
| `P7B_LATENCY_GAPS.md` §2.1 "TCP fast 固定开销 13~15 拍 **外加 N 字×6.4 ns**" | 那"N 字"就是 **B2 的 S&F 门**（`fend⇒pend⇒judged⇒fq≠0⇒S_FWD`）。**S&F 使末字变成 2N**（不只是 N）—— 报告里 §2.1 的"外加 N 字"若被读成"末字延迟"，会低估 **N 拍**（158 B 上 128 ns） |
| `P7B_LATENCY.md` §7 U4 "终点是慢路径**适配器入口**，不是 app 队列" | 现在能给出那段的大小：**(e) → HLS 收完 ≈ 189 拍 ≈ 1.21 µs**（158 B），其中 BRAM 23 拍 |

---

## 4. 时序：BRAM 是不是瓶颈？

### 4.1 取材与覆盖（口径先写清）

| 报告 | 构建 | 配置 | 用途 |
|---|---|---|---|
| `vivado_prj/p7b_lat_prj.runs/impl_1/wrapper_p4_timing_summary_routed.rpt` | P7B 10G + **P7B_LAT 探针** | `APP_MODE/DEV_USP/PCIE_OBS/DP_156MHZ/P7B_10G` | **主样本**：每对时钟最多 ~20 条，共 **630 条**（setup 200 / hold+removal 307）【读报告】 |
| `_proj_10g/notes/p7b_ratebuild/new/p7b_ku5p_timing.rpt`（= `board/p7b_ku5p_timing.rpt`，2026-09-30 17:50） | **RATE 构建**（与本轮 placed 的 **348 片 BRAM 完全一致**） | 另加 `UDP_TX_OVL` | **WNS/WHS 与分组表**（该报告是 `report_timing_summary` 默认 `-max_paths 1` ⇒ 每对时钟 1 条）【读报告】 |
| `board/p6b_final_ku5p_hold_400.rpt` | P6b final | — | **hold 大样本（400 条）** 交叉核对【读报告】 |
| `vivado_prj/p7b_ku5p_prj.runs/impl_1/wrapper_p4_drc_opted.rpt` | **正在跑的构建**（opt 阶段，只读） | — | **网表级 BRAM 实例清单**（`Synchronous clocking ... for BRAM (<inst>)` 逐片点名）【读报告】 |

> ⚠️ **不做跨轮 clock-group 名对齐**：本文所有计数都是**同一份报告内部的端点指纹**（源/宿单元全名）+ 组内计数，
> 不跨报告比"组名后缀"。`_2`/`_3` 这类后缀会随构建漂移（本工程踩过）。

### 4.2 ⭐ 条数（判别性证据 1：计数）

| 方向 | 样本 | **含 BRAM 的条数** | 说明 |
|---|---|---|---|
| **Setup** | 200 条 | **2 条** | 两条都在 `g_hw.clk_out0`（= `dp_clk` 156.25 MHz） |
| **Hold / Removal** | **307 条**（= 184 `Hold` + 123 `Removal`） | **0 条**（BRAM 出现在数据通路表格里的） | 早先脚本报的"2 条"是把报告尾部 **Pulse Width / Min Period 表**的行混进了记录 —— 那是 `RAMB36E2/CLKARDCLK` 的**最小周期检查**（req 6.400 / 实际 1.739 / slack 4.661），**不是 hold 数据路径** |
| **Recovery / Removal（`**async_default**`）** | 246 条（= 123 `Recovery` + 123 `Removal`） | **0 条** | ⚠️ 那 123 条 `Removal` 与上一行的 123 条 `Removal` **是同一批**（重叠计数，不是两批） |

**那 2 条 setup 的全文**（`p7b_lat_prj`）：

| slack | 宿 | 逻辑级数 | Data Path Delay | 说明 |
|---|---|---|---|---|
| **0.289** | `u_tcp_tx/u_retx/g_byte[1].mem_e_reg_3_bram_9/**ADDRBWRADDR[11]**` | **0** | 5.625 ns（**100% 布线**）| 该组**第 3 差**（最差 0.279） |
| **0.333** | `u_tcp_tx/u_retx/g_byte[1].mem_o_reg_7_bram_13/**RSTRAMB**`（IS_INVERTED） | **0** | 5.482 ns（**100% 布线**）| 复位恢复 |

> 同组最差 3 条（对照用）：
> `u_tcp_tx/u_csum/acc_reg[31]/D` @0.279（**18 级逻辑**、CARRY8×6、6.017 ns，源 = `u_tcp_tx` FSM → `u_ackq` → `u_tcb`）、
> `acc_reg[29]` @0.280、然后才是 `retx` 的写地址 @0.289。
> **即：dp_clk 的临界路径是 TCP 控制算术，BRAM 排第 3，且它那一份 100% 是布线。**

### 4.3 DOA_REG / DOB_REG：**输出寄存器被故意关掉**

【读RTL】`rtl/frame_fifo.v:153`（RAMB36E2 支）与 `:190`（RAMB36E1 支）都是
**`.DOA_REG(0), .DOB_REG(0)`**，且文件头写明**必须**这样：

> "`DOA_REG=0`: 沿 N 捕获的字在 N+1 呈现（1 拍延时, 与边存寄存器读逐拍一致); `DOA_REG=1` 是 2 拍延时,
>  **无法逐拍复刻**, 故必须 `DOA_REG(0)`。"

⇒ **读数据的组合路径 = `RAMB36 Tco` + 各片 DOA 的 `main_sel` OR 归约树（NB 个输入）+ 消费者逻辑**，
全部要落在**同一拍**（6.400 ns）里。`assign dout = bypass_r ? din_r : ((W>64) ? {side_dout_r, main_sel} : main_sel[W-1:0]);`
—— **BRAM 的输出直接以组合形式出现在 `dout` 上**（FWFT）。`u_tcp_echo` 的 NB=16 ⇒ OR 树 ≈ 2 级 LUT6。

这条机制**历史上的代价已实测**：`rtl/axis_pipe.v:3` 的头注释写着它存在的理由 ——
"拆板级临界路径（**源端 RAMB36E1 数据口 → 下游校验和累加器**）……插在 `tcp_echo` → `tcp_tx_frame` 之间"。
**当时的修法是插 1 拍寄存器（`axis_pipe`），不是打开 `DOA_REG`** —— 因为打开就多 1 拍读延迟，与边存对不齐。

**对照**：`retx_ram` 相反 —— 读口**完全寄存器化**（地址入口寄存 1 拍 + `q_e <= mem_e[ra_e_r]` 输出寄存 1 拍 = **2 拍**），
所以它的读路径**结构上不可能**以 BRAM 为组合源端出现在报告里。

### 4.4 现行构建的 WNS / WHS 落在哪（判别性证据 2：落点）

RATE 构建（348 片 BRAM，与本轮同）：

| 组 | WNS | 端点 | WHS | 端点 |
|---|---|---|---|---|
| **`**async_default**` @ `pcie_axi_aclk`** | **+0.136 ← 全局 WNS** | 4284 | 0.171 | 4284 |
| `g_hw.clk_out0`（`dp_clk`） | +0.295 | **135218** | **+0.010** | 135218 |
| `pcie_axi_aclk` | +0.288 | 48636 | **+0.010** | 48636 |
| `rxoutclk_out[0]_3`（FE ch1 RX） | +0.342 | 9673 | 0.011 | 9673 |
| `txoutclk_out[0]_3` | +0.141 | 2380 | 0.011 | 2380 |

**WNS 那条路径的全文**：

```
Slack (MET) : 0.136ns
  Source:      u_pcie_xdma/inst/pcie4_ip_i/inst/user_reset_reg/C
  Destination: u_snap_dp/dout_a_reg[254]/CLR        (recovery check)
  Path Group:  **async_default**   Path Type: Recovery (Max at Slow)
  Data Path Delay: 3.625ns (logic 0.096ns (2.6%)  route 3.529ns (97.4%))
  Logic Levels: 0
```

⇒ **全局 WNS 是"PCIe user_reset 扇出到快照块异步 CLR 脚"的纯布线延迟（逻辑级数 0）**。
它既不是数据路径，也和 BRAM 无关。同族的 `dp_clk` 侧 `**async_default**`（26662 端点）WNS = **+0.897**，宽裕。

**WHS 一侧**（P6b 400 条 hold 大样本，本文最强的判别读数）：

| 组 | 条数 | 含 BRAM | 最差 |
|---|---|---|---|
| `pcie_axi_aclk` | 250 | **71** | **0.010 = 全局 WHS** |
| `g_hw.clk_out0`（`dp_clk`） | 113 | **2** | 0.011（组内最差，**不是**那 2 条 BRAM） |
| `gmii_clk` / `pcie_ref_clk` / `pipe_clk` | 37 | 0 | 0.011~0.014 |

- 那 **71 条**全部指向 `u_pcie_xdma` 内部：`udma_wrapper/.../u_mem_rc/the_bram_*`、
  `ram_top/gen_c2h_bram.C2H_DAT0_FIFO/xpm_memory_sdpram_*`、`pcie_4_0_bram_inst/bram_post_inst/.../ECC_RAM`。
- `dp_clk` 组那 **2 条**是 BRAM **写数据脚**的内置保持检查（`Hold_RAMB36E2_RAMB36_CLKBWRCLK_DINBDIN[8]`
  @0.016、`DINADIN[24]` @0.016），**级别高于组内最差 0.011** ⇒ 它们不是限制项。
- `dp_clk` 组真正的 hold 最差是（`p7b_lat_prj` 报告）：
  `u_app_udp/u_txf/mem_reg_64_127_49_55/**RAMG**/I` @0.016（**LUTRAM 写址**）、
  `u_slow_rx/u_ff/gen_side.mem_s_reg_64_127_7_8/**RAMA**/WADR0` @0.020（**LUTRAM 边存写址**）、
  以及一堆**观测/状态寄存器到寄存器**的短路（`u_app/stat_rx_bytes_reg → u_app_status/sn_rx_reg` @0.011）。

### 4.5 判词：BRAM 是不是瓶颈？

**不是。** 证据（每条都可复核，不是"BRAM 慢"这种泛泛之谈）：

1. **计数**：200 条最差 setup 里 2 条含 BRAM（1%），307 条 hold/removal 里 0 条走 BRAM 数据路径。
2. **落点**：全局 WNS 在 **PCIe 复位网络的 Recovery 路径**上（逻辑级数 0，97.4% 布线）；
   全局 WHS 在 **XDMA 内部 BRAM 的 hold** 上。数据面（`dp_clk`）的 WNS/WHS 都不由 BRAM 定。
3. **级数**：那 2 条 BRAM 路径 **逻辑级数 = 0** ⇒ 延迟 100% 是**布线**（5.5~5.6 ns 的净延迟到
   RAMB36 的写地址/复位脚）⇒ 这是**扇出与布局**问题，**不是 BRAM 单元速度问题**。
   机制源文件里写着：`rtl/retx_ram.v:56-62` —— "最差路径 `u_tcp_tx FSM state_reg → 256 片 RAMB36 的 ADDRBWRADDR`
   （巨大 fanout + 布线拥塞，route 6.30 ns vs logic 1.53 ns）"，修法是"入口寄存 + `max_fanout=64` 交工具复制"。
   **本轮它又是 dp_clk 组的第 3 差（0.289，距最差 0.010 ns）⇒ 这一族没死透，加逻辑时会先冒头。**
4. **BRAM 从不出现在源端**：全部 630 条记录里，没有任何一条以 `RAMB36E2` 的输出（DOA/DOB）为源端。
   这与 §4.3 的 `DOA_REG=0 + main_sel OR 树` 一致 —— 读路径确实有 `Tco + OR 树` 的组合段，
   但它**没有一条落进任何时钟对的 ~10 条最差之内**。
   ⚠️ **这句的边界**：它证明的是"**读路径都不在各自时钟对的最差 ~10 条里**"，
   **不是**"所有 BRAM 读路径都有大余量" —— 想量那一段的组合长度需要
   `report_timing -from [get_cells -hier *u_main]`，**本轮不许起 Vivado**（见 §5 U3）。

**反过来，有一条真账要记**：如果哪天要收 **WHS**，第一刀在 **XDMA 的 BRAM**（71/250 条，slack = 全局 WHS），
**不在 10G 数据面**。而如果要把 `dp_clk` 的 setup 余量做厚，先动 **TCP 控制算术**（`u_csum` 18 级 / `u_tcb` 序号运算），
再动 BRAM 写地址的扇出。

---

## 5. 不确定 / 未核清单（严禁当结论用）

| # | 项 | 状态 | 影响 / 补法 |
|---|---|---|---|
| **U1** | **B6 的 2048×9 `fifo_sync` 到底落 BRAM 还是 LUTRAM** | **【未核】** | 只由"`dout` 寄存器化 ⇒ 可推 BRAM"推断。补法：在 DRC/网表清单里按 `u_slow_rx/u_ofifo` 找实例（A1 的路上） |
| **U2** | **62 片 RAMB18 的归属** | **【未核】**，只采样到 `u_hls/*`（`frame_fifo_fifo_U`、`grp_arp_rx_process` 的 `reply_1_U`/`arp_bytes_U`/`arp_bytes_1_U`） | 片数对账（§1.3）里有 ~20 片的松动量 |
| **U3** | **BRAM 读路径（DOA → 下游）的真实余量** | **【未核】**，报告采样不含它 | 需要 `report_timing -from ...` 或 `report_design_analysis`；**本轮禁起 Vivado** |
| **U4** | **B2/B3/B4/B5 的"末字延迟 = 2N+2"** | **【推算】**（由 `frame_fifo` + S&F 门 + 1 字/拍播放推出） | 与 `P7B_LATENCY_GAPS.md` §2.1 的"外加 N 字"**口径不同**（一个量首字、一个量末字）。实测要加探针（方案 M） |
| **U5** | **(e)→HLS 的 1.21 µs 预算** | **【推算】**（播放器 1 B/拍是【读RTL】；未板级实测） | `P7B_LATENCY.md` §7 U4/U5 已知缺口；本轮只是**给它一个量级** |
| **U6** | **A2 只看了 `report_timing_summary` 的采样路径** | 口径边界 | `report_timing_summary` 只报"每对时钟的 ~10~20 条最差"，**240450 个端点里绝大多数没被采样**。所有"条数"结论都应这样读："在报告覆盖的最差路径集合里" |
| **U7** | **`u_pcie_xdma` 的 BRAM 总数** | 只知道 **≥22 片（SDP 清单）**，数据面 FIFO（`ram_top`、`udma_wrapper`）另计 | 与 §1.3 的 317 片对账差 |
| **U8** | **`rtl/udp_echo.v` 的 4 片 RAMB36 在别的构建里** | 本轮构建**不含**（§1.2 的排除项 1） | 引用"udp_echo 用 4 片"时必须先确认是哪个构建 |
| **U9** | **时序读数取自 P7B-lat / RATE / P6b 三个构建，不是正在跑的那个** | 口径 | 那 348 片 BRAM 与 RATE 构建**逐数相同** ⇒ 上述结论对"当前这版"高度可迁移；但**严格说不是同一份网表** |

---

## 6. 复现（全部只读，零 Vivado）

```bash
cd /d/repo/XCKU5PMini/udp_hls_10g

# ① BRAM 片数 / 层次（正在跑的构建的 placed 报告，只读 .rpt）
grep -A 10 "3. BLOCKRAM" vivado_prj/p7b_ku5p_prj.runs/impl_1/wrapper_p4_utilization_placed.rpt

# ② 网表级 BRAM 实例清单（DRC 报告里每个推断/例化的 BRAM 一行）
grep -o "BRAM ([^)]*) in SDP mode" vivado_prj/p7b_ku5p_prj.runs/impl_1/wrapper_p4_drc_opted.rpt \
  | sed 's/BRAM (\(.*\)) in SDP mode/\1/' | sort

# ③ 关键路径里的 BRAM 条数（含"逻辑级数 = 0"的判别）
python - <<'PY'
import re
p='vivado_prj/p7b_lat_prj.runs/impl_1/wrapper_p4_timing_summary_routed.rpt'
L=open(p,encoding='utf-8',errors='replace').read().splitlines()
st=[i for i,l in enumerate(L) if l.strip().startswith('Slack (')]
n=nb=0
for a in range(len(st)):
    b=st[a+1] if a+1<len(st) else len(L); ch=L[st[a]:b]
    hi=next((k for k,l in enumerate(ch) if 'Delay type' in l and 'Location' in l),None)
    seg=ch[hi:] if hi is not None else ch
    pt=next((l.split(':',1)[1].strip() for l in ch[:14] if l.strip().startswith('Path Type:')),'')
    if 'Setup' not in pt: continue
    n+=1
    if re.search(r'RAMB36E2|RAMB18E2|FIFO36E2', '\n'.join(seg)): nb+=1
print('setup paths sampled=%d  with BRAM in data path=%d'%(n,nb))
PY

# ④ 现行 WNS 落在哪（RATE 构建，1 条/组）
grep -n -B2 -A 12 "Slack (MET) :             0.136ns" _proj_10g/notes/p7b_ratebuild/new/p7b_ku5p_timing.rpt
```

---

## 7. 给主线的一句话

**BRAM 在这份设计里不是延迟项、也不是时序项 —— 它是"面积 + 扇出"项。**
面积上 `retx_ram` 一块吃掉 73.6% 的已用 BRAM（却只在重传时被读）；
延迟上真正贵的是 `frame_fifo` 的整帧 store-and-forward（**N 字**）和 (e) 之后那个 **1 字节/拍的播放器**（**8+L 拍**）；
时序上唯一的 BRAM 主导桶在 **XDMA**，数据面的临界路径是 **TCP 控制算术 + 观测/复位网络的布线**。
⇒ **要砍延迟，第一刀是加宽播放器（~1 µs 量级），不是动 BRAM；要砍 BRAM 面积，第一刀是 `retx_ram` 的容量策略（256→更小），不是那些 512 深的帧缓冲。**
