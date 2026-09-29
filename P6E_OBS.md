# P6e 合体版: 数据面 + PCIe/XDMA 观测通道

> **一句话**: 一个比特流里既有 1G 数据面, 又有我们自己的 **PCIe 寄存器窗口** —— 主机用
> `reg_rw /dev/xdma0_user` 就能读到数据面的计数快照。**这块板没有 UART**, PCIe 是我们唯一的
> 高带宽观测通道 (见 `../XCKU5PMini/CLAUDE.md`「板上没有 UART」一节)。

| | |
|---|---|
| 构建 | `board/run_lint_p6e.bat` (秒级预检) → `board/run_build_p6e_ku5p.bat` (~30 min) |
| 产物 | `vivado_prj/p6e_ku5p_prj.runs/impl_1/wrapper_p4.bit` |
| 烧录 | `_proj_pcie/run_program_p6e.bat` (JTAG 1MHz; **绝不写 QSPI**) |
| ⚠️ 烧完 | **必须重启主机** —— PCIe 端点只认"FPGA 配置先于主机 POST" (四组对照实验见 `_pcie/README.md`) |
| 验收 | 对端机 `sudo bash /home/a/xdma_test/p6e_snap_check.sh` (日志 `/tmp/p6e_snap_check.log`) |
| 构建开关 | `APP_MODE=1 DEV_USP=1 **PCIE_OBS=1**` —— 所有 PCIe 内容都在 `ifdef PCIE_OBS` 内, 其余构建逐位不变 |

> ⚠️ **P6b 之后本节的口径已变（2026-09-29）**：`PCIE_OBS` 现在**同时**是"数据面跑 156.25MHz dp_clk"
> 的守卫（见 `P6B_REVIEW.md` F1）—— 这是个**潜伏设计债**：语义无关的宏被复用。当前树里没有会踩的
> 构建（P6a/P5 档不含 `PCIE_OBS`；`build_p6e_ku5p.tcl` 已被 P6b 取代并同步补齐三个新 RTL + 两个新 XDC），
> 但"要 PCIe 窗口 + 数据面仍 125MHz"这个组合**现在会拿到 8 个错的时间常数且无告警**。要拆开请单列任务。
> 本表的**权威构建**因此是 `board/build_p6b_final_ku5p.tcl`（BUILD_ID=6）与它的前身 `build_p6b_ku5p.tcl`。

## 一、寄存器表 (主机侧唯一要看的表)

`reg_rw /dev/xdma0_user <字节地址> w [值]` (带值 = 写, 不带 = 读)

| 地址 | 属性 | 内容 |
|---|---|---|
| `0x00` | RO | `MAGIC` = `0x50360001` —— 证明"读的是我们自己的逻辑" |
| `0x04` | RO | `BUILD_ID` —— **前置闸**: **当前 = `0x00000006`** (1=最小版 / 2=合体8字 / 3=合体16字 / 4=合体24字 / 5=P6b 32字 / **6=P6b 36字 + F-1/F-2 修复**) |
| `0x08` | RW | `SCRATCH` (读写回环 + wstrb 字节选通测试) |
| `0x0C` | RO | `FREECNT` (axi_aclk 自由计数 ⇒ 反解 AXI 时钟频率 + 证明 AXI 域活着) |
| `0x10` | RO | `HW_STATUS` = `[7:5]msi_vector_width [4]msi_enable [3]user_lnk_up [2:0]0` |
| `0x14` | RO | `MARKER` = `0xDEADBEEF` (地址译码检查) |
| `0x18` | WO | `SNAP_CTRL` —— 写 `bit0=1` ⇒ **触发一次快照** |
| `0x1C` | RO | `SNAP_STATUS` = `[31:16]gen [6]mmcm_locked_axi [5:3]fe_state(fe_busy/fe_seen/fe_done) [2]seen [1]done [0]busy`<br>⚠️ `[2:0]` 与 `[31:16]` 的语义**逐位未变** ⇒ 老脚本按 `(s>>16)&0xffff` 取 gen、`s&0x7` 取 busy/done/seen **都不用改** |

### 快照窗口 = **36 字** (`0x20..0xAC`)，分**两束**（每束一个 `snap_cdc`，链式触发：**FE 先 → DP 后**）

> ⚠️ **`域` 一栏是"该计数器的生产者所在时钟域"，不是地址属性**：
> FE = `gmii_clk`（PHY 回送的 125 MHz 前端）· DP = `dp_clk`（Y1 100 MHz 经 MMCM ×1.5625 出的 156.25 MHz 数据面）。
> 两束**不能混**：把 FE 的字塞进 DP 束就是多比特 CDC（`P6B_REVIEW.md` F13）。
> 生产者节点逐字核对见 `P6B_INTEGRATION_REVIEW.md` §1.3（作者按 wrapper 的拼接逐项读出，不是看导线名）。

| 地址 | 字 | 束 | 内容 | 生产者节点 |
|---|---|---|---|---|
| `0x20` | W0 | FE | `rx_stat_frames` (MAC 收帧数) | `mac_rx_64 u_u_mac_rx` |
| `0x24` | W1 | FE | `rx_stat_bytes` (MAC 收字节, 含 FCS 4B) | `mac_rx_64` |
| `0x28` | W2 | FE | `{16'd0, wl_last}` (**最近一帧的线上字节数**; 判别器: ≈1518 整帧 / ≈66 短帧) | wrapper `posedge gmii_clk` |
| `0x2C` | W3 | FE | `rx_stat_crc_err` (FCS 错帧数) | `mac_rx_64` |
| `0x30` | W4 | FE | `rx_stat_drop` (MAC 丢弃) | `mac_rx_64` |
| `0x34` | W5 | FE | `gmii_free` (**前端域自由计数** = 前端时钟活性) | wrapper `posedge gmii_clk` |
| `0x38` | W6 | DP | `srx_stat_commit` (提交给 HLS 慢路径的帧: ARP/ICMP 会涨) | `slow_rx_adp u_slow_rx` |
| `0x3C` | W7 | DP | `stx_stat_frames` (**HLS 慢路径发出去的帧**; ⚠️ 不是 TCP fast path) | `slow_tx_adp u_slow_tx` |
| `0x40` | W8 | DP | `udpapp_tx_frames` (**图案 app 发出帧**) | `app_udp_pattern u_app_udp` |
| `0x44` | W9 | DP | `udpapp_tx_bytes` (图案 app 发出字节) | `app_udp_pattern` |
| `0x48` | W10 | DP | `udpapp_rx_frames` (图案 app 收到帧) | `app_udp_pattern` |
| `0x4C` | W11 | DP | `udpapp_rx_bytes` (图案 app 收到字节) | `app_udp_pattern` |
| `0x50` | W12 | DP | `udpapp_rx_null` (空/坏帧) | `app_udp_pattern` |
| `0x54` | W13 | DP | `udpapp_mismatch` (**图案失配: 必须恒 0**) | `app_udp_pattern` |
| `0x58` | W14 | DP | `tx_stat_frames` (**TCP fast path** 发帧; ⚠️ **不是 MAC**) | `tcp_tx_frame` |
| `0x5C` | W15 | DP | `tx_stat_bytes` (**TCP fast path** 发字节) | `tcp_tx_frame` |
| `0x60` | W16 | DP | `srx_hls_bytes` (**HLS 真读走的字节**, 消费侧: HLS rx_stream 的 `tvalid&&tready` 字节拍数, 含每帧 8B 前导) | wrapper `posedge dp_clk` |
| `0x64` | W17 | DP | `hr_cnt` (`hls_rst_n` 低电平拍数; **÷80** ≈ 饥饿看门狗复位次数 —— P6b 起 `slow_rx_adp.RST_CNT` 由 64 拍改 80 拍，同一墙钟 512 ns；**125MHz 域仍是 ÷64**) | wrapper `posedge dp_clk` |
| `0x68` | W18 | DP | `stx_stat_purge` (slow_tx_adp 整帧回卷数) | `slow_tx_adp` |
| `0x6C` | W19 | DP | `srx_stat_drop` (slow_rx_adp 丢帧) —— ⚠️ **不再恒 0**: F4 修复后它与 **MAC 丢帧有向耦合**（见下"判据变更"） | `slow_rx_adp` |
| `0x70` | W20 | FE | `mac_tx_frames` (**MAC 级**发帧数 —— 原悬空, 24 字版接出) | `mac_tx_64 u_u_mac_tx` |
| `0x74` | W21 | FE | `tx_stat_abort` (MAC 帧内中止 = 源流断供的 runt) | `mac_tx_64` |
| `0x78` | W22 | DP | `rx_stat_pass` (TCP fast path 接受帧) | `tcp_rx u_tcp_rx` |
| `0x7C` | W23 | DP | `rx_stat_nonmatch` (TCP fast path 最大丢帧桶) | `tcp_rx` |
| `0x80` | **W24** | DP | `dp_free` —— **数据面域 32 位自由计数** ⭐ "数据面真在 156.25MHz 跑"的唯一正证据（32 位 @156.25MHz 每 **27.49 s** 绕一圈 ⇒ 窗口必须 < 20 s） | wrapper `posedge dp_clk` |
| `0x84` | **W25** | DP | `{31'd0, mmcm_locked_sr_dp[1]}` MMCM locked（DP 域 2FF 同步版）。⚠️ **同时镜像到 `SNAP_STATUS[6]`**（axi 域）—— DP 时钟停摆时只有那一份可读 | wrapper `posedge dp_clk` / `posedge pcie_axi_aclk` |
| `0x88` | W26 | FE | `rxcdc_full_cycles` —— `u_rxcdc.full` 高电平**拍数**（RX 方向"DP 跟不上"的直接量） | wrapper `posedge gmii_clk`（源 = `u_rxcdc.full`） |
| `0x8C` | W27 | FE | `{16'd0, rxcdc_occ_max}` —— `u_rxcdc` 历史最大占用（字） | wrapper `posedge gmii_clk`（源 = `u_rxcdc.dbg_occ_w`，**写域**探针） |
| `0x90` | W28 | DP | `{16'd0, txcdc_occ_max}` —— `u_txcdc` 历史最大占用（字） | wrapper `posedge dp_clk`（源 = `u_txcdc.dbg_occ_w`，**写域** = dp_clk） |
| `0x94` | W29 | DP | `txwire_stall_cycles` —— DP 侧"有字要发但下游不收"的拍数 | wrapper `posedge dp_clk` |
| `0x98` | **W30** | DP | `rxcdc_out_frames` —— RX FIFO **读侧** TLAST 数 ⭐ 跨域完整性锚点 | wrapper `posedge dp_clk`（源 = `u_rxcdc` 读侧 AXIS） |
| `0x9C` | **W31** | DP | `rxcdc_out_bytes` —— RX FIFO 读侧 `Σpopc(tkeep)` ⭐ 与 W1 对账（**不含** 4×帧数，见守恒律） | 同上 |
| `0xA0` | **W32** | FE | `rx_stat_drop_partial` —— **已推过字**的丢帧数（F4 新增；孤儿字的帧数） | `mac_rx_64` |
| `0xA4` | **W33** | FE | `rx_stat_orphan_bytes` —— 这些帧已进 FIFO 的字节数（F4 新增） | `mac_rx_64` |
| `0xA8` | **W34** | FE | `rx_stat_drop_full` —— 因 FIFO 空间不足丢的帧数（F4 新增） | `mac_rx_64` |
| `0xAC` | **W35** | FE | `rx_stat_fifo_ovf` —— `fifo_sync` 拒写次数（F4 新增；**结构上恒 0**，非 0 = 修复失效） | `mac_rx_64` |
| 其它 | — | — | 读回 `0xFFFFFFFF`、写被拒 (SLVERR) —— 见下"用法坑"。**36 字版的第一个未实现地址 = `0xB0`**（word 44 = `SNAP_NW_P6E`） | — |

> ⚠️ **`rxcdc_occ_max`(W27/W28) 是**上界**、`dbg_occ_r` 才是下界**（`P6B_REVIEW.md` F13）——
> 所以"W27/W28 没贴 256"**不能**证明"从没贴过"。要证深度不够请看 W26（full 拍数）。
> ⚠️ **F-1 的板级缺口仍在**：`rtl/fifo_async.v` 现在**有** `ovf_pulse/ovf_cnt` 拒写探针（F-1 修复），
> 但 `board/wrapper_p4.v` 的两个 `u_rxcdc`/`u_txcdc` 例化**没有把它们接出来**（`.ovf_cnt()` 悬空），
> 快照字里也**没有**对应的字 ⇒ **板级仍无法归因 CDC FIFO 自身的丢字**。
> 板上的 `W35` 是 `mac_rx_64` **内部 8 深 `fifo_sync`** 的拒写数，是**另一个 FIFO**，别混。

> **36 字 = 2026-09-29 P6b 期从 24 字扩上来的**（同批并入 F4 的 4 个守恒计数器 W32..W35，全部属 FE 束；
> 动机: 让"丢帧"这条路径**有账可查**，把 F4 的两个静默缺陷变成可判读数）。
> **24 字是更早从 16 字扩上来的**（动机: 钉死"**慢路径失聪**"现象的机理 —— 原先 `W6`/`W7`
> 两条计数都不足以分开"HLS 没读 / 读了没产出 / 产出了被回卷", 见下"判读"一节）。
> **16 字是更早从 8 字扩上来的**（动机: 图案/吞吐测试要 app 层计数, 光靠 MAC 层反推不出来）。
>
> ⚠️ **扩窗必须逐处同改**（P6b 起这份清单是 **7 处**，见 `P6B_SPEC §7.4`；下面是"血的教训"版）:
> ① wrapper 的 `SNAP_NW_P6E`（单一来源，位宽全靠它推导；36 字版起拆成 `SNAP_FE_NW=14` / `SNAP_DP_NW=22`）
> ② 两束 `snap_src` → `fe_src`/`dp_src` 的**拼接项数**（各 14 / 22，必须精确）
> ③ ⭐ `axi_regs` 里读侧 `snap_base` 的**位宽** —— 装不下就**静默回绕**:
>   24 字版扩窗前它是 `[8:0]`, 实测 `0x60..0x7C` 这 8 个字**读回 W0..W7 的值**, 而 xvlog 全程沉默
>   (lint 里 `10-3091` 计数 0)。⇒ **36 字版必须同时加宽 `snap_idx`（5→6 位）与 `snap_base`（10→11 位）**,
>   且**逐字读回的门必须覆盖到最后一个字**（`P6B_REVIEW.md` 附录 R.5 预先算出了这条硬顶：
>   只加宽一处 ⇒ `0xA0..0xAC` 读回 W0..W3 = **假 PASS** 而不是 FAIL）。
> ④ `axi_regs.SNAP_NW` ⑤ **验收/采样脚本里"未实现地址"的取值** (0x18 → 0x44 → 0x60 → 0x84 → **0xB0**),
>   否则会把"新功能上线"判成回归。⚠️ ⑤ 绝不能挑 **≥0x100**: `ar_word = araddr[7:2]` 只有 6 位
>   ⇒ **地址每 256 字节回绕** (挑 0x100 ⇒ 别名到 MAGIC ⇒ 假 FAIL; 挑 0x160 ⇒ 别名到已实现字 ⇒ 假 PASS)。
> ⚠️ **第 ⑥ 处最容易漏**: 三道门自己的**参数** —— `tb_axi_regs` 的 `.SNAP_NW`/`snap_din` 位宽/`w8` 长度、
> `tb_snap_cdc` 的 `NW`、wrapper 门的 force 清单与 BUILD_ID 期望。16 字版当年就是漏了这层,
> 才让 `snap_base` 的位宽截断一路潜伏到下一次扩窗 (门自己没扩 ⇒ 它"看不见"新字)。
> ⚠️ **第 ⑦ 处 = 两束的索引表**（`rtl/snap_seq.v` 的 `fe_idx_of`/`dp_idx_of`，P6b 新增的风险点）——
> 必须**由单一来源派生**并与两束拼接逐项一致；抄错只会读出"另一个字的正确值"，单测一遍看不出来。
> 规格书 `P6B_SPEC §7.2` 的 `localparam` 例子**当年就写错了**（详见该文件新增的"勘误"节）。
> 历史上这一轮 (8→16) 被全链门抓到 **3 个 lint 看不见的真 bug** (字号索引回绕 / 去程与回程两条线各
> 截断 256 位 / 这次的回绕读错字) —— xvlog 的位宽检查**不覆盖端口连接, 也不报窄左端赋值**,
> 所以只能靠例化真 wrapper 的门 + 逐字读回。36 字版的全链门 = `sim/p6e_pcie/run_tb_p6e_pcie.bat`
> （逐字读回 36 字）；审查方另写了独立的 36 字读回门 `int_scratch/tb_int_axr36.v` 并配了**两条**
> 回绕负对照（`snap_idx` 改 5 位 / `snap_base` 改 10 位 —— **两条都 FAIL**，证明判据有牙）。

### 主机读快照的协议 (三步)

```sh
reg_rw /dev/xdma0_user 0x18 w 0x1          # ① 触发
# ② 轮询 0x1C 直到 bit1(done)=1
reg_rw /dev/xdma0_user 0x20 w              # ③ 读 36 个字 (0x20..0xAC)
```

⚠️ **读第 ③ 步必须逐字判"空读"**（`reg_rw` 的输出要 `tail -1` + 校验 `0x` 前缀；空读 ≠ 真 0），
并且**每轮都要自证"这一轮确实是我触发的"**：`SNAP_STATUS.gen` 必须**恰好 +1**。
没有这道守卫时，"读失败被 `$(( ))` 当成 0"会一路静默地伪造出"计数冻结"的结论 —— 本仓
2026-09-29 实测踩过（真凶是脚本自己的变量名撞车，见 `PORT_NOTES.md` 的"失聪"小结）。
**成品脚本**：`_proj_pcie/p6b_accept.sh`（`rd()` / `rd_new()` / `snap()` / `round()` 四层守卫，
`round()` = MAGIC 在 + gen 恰好 +1 + 36 字无空读，任一失败 ⇒ 整轮读数作废）。

⚠️ **为什么是"显式触发"而不是自动刷新** (改之前先读这段): 主机读 N 个字要走 N 笔独立 PCIe
事务 (几十 µs), 只要刷新周期短于这个窗口, 读出来的字就**跨越两代快照** (CDC 再相干也
救不了 —— 撕裂发生在寄存器文件这一层)。显式触发让这些字**冻结到下一次触发**, 读窗口天然原子,
主机不需要 seqlock/重试。代价: 快照是"上次触发时刻"的值 (读计数完全够用)。
`done` 是 sticky 的 ⇒ 即使快照在第一次轮询前就完成也不会漏。详见 `_proj_pcie/rtl/axi_regs.v` 头注释。

## 二、判读: ping 不通时按这个顺序看

```
W5 (gmii_free) 不走 ⇒ PHY 回送的 RXC 根本没来 (网线/PHY/前端) —— 后面都不用看了
W5 在走, W0 不涨 ⇒ 线上没有帧到达 FPGA (对端没发/线没通/接错口)
W0 涨, W3 涨      ⇒ 帧到了但 FCS 错 ⇒ 物理层/时序 (PHY 绑带/IDELAY 配方)
W0 涨, W6 不涨    ⇒ 帧没进慢路径 ⇒ ARP/ICMP 收不到 ⇒ 查 rx_classify 过滤/端口/IP 配置
W6 涨, W7 不涨    ⇒ HLS 收到了但没回 ⇒ 问题在慢路径/HLS, 不在前端
W7 涨但 PC 收不到 ⇒ 回包发出去了, 查对端 (ARP 表/防火墙/接线)
```

### 二·补、慢路径失聪时看这四对 (24 字版专为它加的 W16-W20)

```
W6 涨 而 W16 不涨 ⇒ **HLS 真不读了** (W6 只在适配器输入侧帧尾自增, 不代表 HLS 读过;
                     W16 在消费侧 = HLS rx_stream 上真吃走的字节) ⇒ 问题在 HLS 内部
W17 在涨          ⇒ **饥饿看门狗在反复复位 HLS** (hls_rst_n 低电平累计拍数 ÷ 复位拍数 = 复位次数;
                     P6b 起复位拍数 = 80, 125MHz 域仍是 64 ⇒ **先看构建档再定除数**)
                     ⇒ 与 W16 停涨同时出现 = "HLS 卡住 ⇒ 看门狗踢它" 的闭环
W7 不涨 而 W18 涨 ⇒ HLS **产出了**帧但被 slow_tx_adp 整帧回卷 (别再怪 HLS; 查 wf FIFO 消费侧)
W20 vs W7         ⇒ **MAC 级发帧 vs HLS 慢路径发帧** —— 分开"没产生"与"没上线"
                    ⚠️ W7 = `stx_stat_frames` 是**慢路径**的 (不是 TCP fast path —— 本文件曾标错);
                    W20 是**全部 TX 源的超集** ⇒ 只有"HLS 是唯一 TX 源"时两者才相等 (板上基线 W20≡W7)
```

`W2` (线上帧长) 是现成的判别器: **≈1518 是整帧, ≈66 是短帧** (历史上正是用它分开了
"PC 真的只发 66 字节" vs "FPGA 侧吞了帧中段字节")。

### 二·补2、**判据变更** (P6b 36 字版；照旧文档判会假 FAIL 或漏判)

| 判据 | **正确形式** | 依据 / 为什么改 |
|---|---|---|
| `W20 − W7` | `0 ≤ W20 − W7 ≤ 1` **且必须同时 `W21 == 0`** | `P6B_REVIEW.md` **F11**：`mac_tx` 帧内中止后回 `S_IDLE`，会把中止帧的剩余字当成**一帧新的重发**并 `stat_frames++` ⇒ W20 多计"帧"。所以这个判据**不是结构性的**，只在"本轮无中止"时成立。板上实测（`P6B_ACCEPT.md` E3）：`W20=41 W7=41 差=0`、`W21=0`（前置成立）。⚠️ F-2 修复（`S_FLUSH`）已把"残字成新帧"从**线上**消除，但 W20 的计数语义没变 ⇒ 判据**仍要带 `W21==0` 这个前提**。 |
| `W0 vs W6` | **`0 ≤ W0 − W6 ≤ 1`**（等价 `W6 − W0 ∈ {−1,0}`） | ⚠️ **方向与任务书原文相反**：任务书原文写的是 `W6 − W0 ∈ {0,1}`。`rtl/slow_rx_adp.v:195-216` 的 `stat_commit` 在**帧尾**、`frame_bad=0` 时自增 ⇒ 它是 W0 的**下游**，天然滞后 ≤1 帧、**不可能超过 W0**。独立数据：冒烟轮 `_proj_pcie/smoke_scratch/p6b_smoke_account.log` 实测 `W0=270 / W6=269` ⇒ `W6−W0 = −1`。**按任务书字面判会因一个在飞帧假 FAIL**；按校正后的形式实测 `0`（`P6B_ACCEPT.md` §4.1 / E4）。 |
| `W17`（饥饿看门狗） | 读数 **÷ 复位拍数**（P6b/DP 域 = **80**；125MHz 域 = 64） | `rtl/slow_rx_adp.v` 的 `RST_CNT` 由 64 改 80（`P6B_SPEC §5.1`：156.25 MHz × 80 拍 = 512 ns = 125 MHz × 64 拍，**同一墙钟**）。见 `P6B_REVIEW.md` **F7**：§7.7 的逐处清单**漏了 5 处**，其中 `p6e_snap_check.sh:143` 与 `p6b_accept.sh:278` 是**活算式** ⇒ 会把复位次数打印错（板上实测 W17=0，`P6B_ACCEPT.md` E5a）。 |
| `W19`（slow_rx_adp 丢帧） | **不再恒 0**：与 MAC 丢帧有**有向耦合** | `P6B_REVIEW.md` 附录 R.7 ②(ii)：F4 修复后 `mac_rx_64` 会补 **TERM 收尾字**（`tkeep=0/tlast=1/tcrs=0`）给"已推过字又被丢"的帧 ⇒ 下游按 `tcrs=0` 判坏帧 ⇒ 计入 `srx_stat_drop`（W19）。**"W19 恒 0"这条旧判据必须改成**"`W19` 与 W32/W34 同向、且 W19 ≤ W32+W34"这类耦合式；`p6b_accept.sh` 判据 5 已按此改。⚠️ 板上本轮 `W19=0`（E6）—— **耦合分支根本没被激励过**，所以"W19 恒 0"在本轮读数里**仍然成立**，但那是"没触发"，不是"结构性恒 0"（`P6B_ACCEPT.md` §6.5 已把它列为未覆盖项）。 |
| `W30/W31`（跨域守恒） | **`W30 == W0 + W32`** 与 **`W31 == W1 − 4·W0 + W33`**（结构式，停机态**逐字成立**） | `rtl/mac_rx_64.v:50` 明文写出这两条（F4 修复的"可独立复算的正证据"）。⚠️ **旧形式 `W1 == W31` 在 `W0>0` 时数学上不可能成立**（`W31` 是 Σpopc 口径 = 内容字节，不含每帧 4B FCS）⇒ 必须用等价式（`P6B_ACCEPT.md` §4.2 / E1a / E1b：`147 == 147`、`21235 == 21235`）。 |
| `W24`（数据面频率） | 窗口 **< 20 s**，且**两端都必须走 `round()`**（触发+锁存+读全） | `W24` 是 32 位 @156.25MHz ⇒ **每 27.49 s 回绕**；而 `W24` 是**快照字**，**直读两次 `0x80` 得到的是同一个锁存值** ⇒ 首跑实测 `Δ=0 ⇒ 0.0000 MHz` 的**假 FAIL**（`P6B_ACCEPT.md` B2 的正确读法）。 |
| `W25` bit0（MMCM locked） | 1；停机态**必须与 `SNAP_STATUS[6]` 一起看** | DP 时钟停摆时 DP 束读不到 ⇒ axi 域的镜像位才是可读的那份（`P6B_SPEC §7.5`/§6.4）。 |

> ⚠️ **两条纪律（本轮实测逼出来的）**：
> ① **判据的期望值必须能"独立复算"**——不要用"上次读到的值"当期望（"空读=0 不可区分"是本工程的老坑）；
> ② **判据要么有区分能力、要么明确说明为什么它的字面形式不可达**，**绝不因为"改一下就能过"而放宽**
>    （`P6B_ACCEPT.md` §4 的两处校正都附了原始反例读数）。

## 三、跨时钟域 (这里唯一的技术难点)

**P6b 之后有三个域**（`P6B_SPEC §8.4`）：`gmii_clk` = PHY 回送的 RXC 125MHz（前端）·
`dp_clk` = 核心板 Y1 100MHz 经 MMCM ×1.5625 = **156.25MHz**（数据面）· `axi_aclk` = XDMA 内部
（≈250MHz, 实测 257–259.5）。寄存器块在 `axi_aclk`。

**多比特计数不能用两级同步器直接跨** —— 各比特到达时刻不同 ⇒ 读出来是"位混"的假值, 而且
看起来像"数据面疯了"。走 `rtl/snap_cdc.v` 的 toggle 握手: b 域一次性锁存整束 ⇒ 快照内的各位
来自同一个 b 域沿。

36 字版**两束各挂一个 `snap_cdc`**（FE 14 字 / DP 22 字），由 `rtl/snap_seq.v` 做**链式触发**：
**FE 先 → DP 后**，装配后一次性交给 `axi_regs`。为什么必须定序（而不是让主机那一个写脉冲同时
打到两个 `snap_cdc`）：后者两次锁存的相对次序由两个域的相位**随机**决定 ⇒ 跨域对账的判据全部
退化成对称容差 `|Δ| ≤ 1`，**失去方向性**；定序后 `W6(DP) − W0(FE) ∈ {0,1}`、`W30(DP) − W0(FE) ≥ 0`
这类判据是**结构性**成立的。偏斜上界 ≈ **43.2 ns**（`P6B_REVIEW.md` §3.2 重推；规格书原写的
59.2 ns 是两个错误相互抵消的产物 —— **数字不能用，结论不变**）；帧尾间距实为 ≥672 ns ⇒ 15 倍余量。

## 四、验证 (已经跑过的门)

| 门 | 内容 | 结果 |
|---|---|---|
| `sim/snapcdc/run_tb_snap_cdc.bat` | snap_cdc 单元门: 相干性(飞行中换束扫 16 相位)/busy/背靠背/复位回收/**时钟停摆恢复** + **撕裂负对照**(证明检查器有判别力)<br>⭐ 2026-09-29 修: **覆盖 5 个束宽 `14/22/24/32/36`** (14/22 = P6b 两束真实宽度, 36 = 整窗), 每遍由 **TB 自己打印**尺寸声明 (`TB_NW_SEL: NW=%d NB=%d MACRO=%s`, 取值来自 `` `TB_NW `` 宏本身) 并由 bat `findstr` **断言"声明==实际"** —— 修前它印 `NW=36` 却编译 `TB_NW_32`(TB 根本没有 36 分支), 且两个宽度都不是真实束宽。变异 `nwbug`(删掉 36 分支)⇒ **只有 NW=36 那一遍 FAIL, 其余 4 遍连 TB 自己都打 PASS_ALL** = "没有新断言的静默通过" | **PASS_ALL ×5**（`sim/snapcdc/gate_nw*.txt`） |
| `_proj_pcie/run_tb_axi_regs.bat` | 寄存器块单元门 17 项 (含快照窗口/触发脉冲/冻结/中途换代的 gen 守卫负对照) | **PASS_ALL** |
| `sim/p6e_pcie/run_tb_p6e_pcie.bat` | ⭐ **真 wrapper 全链门**（P6b 起 **36 字全覆盖**）：其中 **34 个字**（W0..W23 + W26..W35）的计数源 force 成互不相同的常数、从 AXI 侧逐字读回比对；**W24/W25 不能用 force**（自由计数 / MMCM locked）⇒ 改用动态判据 `ΔW24/ΔW5 = 1.2501 ∈ [1.24,1.26]` 与 `locked==1`。门内另查 `0xB0 → SLVERR` 与 `gen 恰好 +1`<br>⚠️ force 必须打**生产者节点**(子模块端口): 打 wrapper 线会**掩盖"生产者↔线断开"** —— 实测把 `mac_tx_frames` 改回悬空, 打线版照样 PASS_ALL, 打生产者节点版当场 FAIL | **PASS_ALL**（读数 `board/p6b_verify/p6e_pcie_wrapper.pass.log`） |
| `sim/p6e_pcie/run_tb_p6e_pcie_counters.bat` | ⭐ **新计数器增量门** (2026-09-29 加): 200 拍握手 ⇒ `W16` **恰好 +200**; 150 拍 `hls_rst_n` 低 ⇒ `W17` **恰好 +150**; 含 tvalid-only / tready-only 负向 —— 全链门把这两路 force 成常数, 掩盖了增量条件, 这道补动态那一段 | **PASS_ALL** |
| `int_scratch/tb_int_axr36.v` (审查方独立写) | ⭐ **36 字读回 + 两条回绕负对照**: `snap_idx` 改回 5 位 / `snap_base` 改回 10 位 ⇒ 都必须 FAIL（实测 W32..W35 读回 W0..W3，**5 条 FAIL**）；两条变异的 xvlog `10-3091` 与 `implicitly` 计数**都是 0** ⇒ 这类错只有"例化真 DUT + 逐字读回"抓得到 | **PASS_ALL (reads=44)** / 负对照 **FAIL** |
| `int_scratch/tb_int_snapseq.v` (审查方独立写) | ⭐ **链式触发顺序门**（映射表由审查方按 wrapper 拼接**手工写死**，不复用 DUT 的 `fe_idx_of`）：41 代快照顺序成立 41/41、偏斜 **+36..+41 ns**；负对照把 FSM 改成 **DP 先** ⇒ 成立 **0/41**、偏斜 −46..−39 ns | **PASS_ALL (样本=41)** / 负对照 **FAIL** |
| `sim/fifoasync/run_all.bat` (+ `run_mut_*.bat` 7 个变异) | `rtl/fifo_async.v` 单元门（12 个基础门 + 7 变异）。**F-1 修复的判据归属**：`run_mut_noovf.bat`（把 `ovf_pulse` 钉 0 = 撤回 F-1 修复）必须 FAIL —— 实测 `FAIL (3 条判据不成立)`，含"写域占用探针峰值 >= 金标准"与"探针非空"两条 | 正例 **PASS** / `mut_noovf` **FAIL**（有牙） |
| `sim/snapcdc/negctrl/run_negctrl_2rst.bat` | 负对照: "两域各自复位会不会死锁" —— **实测不会** (见下) | 结论已改文档 |
| `_proj_pcie/run_tb_axi_regs.bat` (变异体) | ⭐ **自证判别力**: 把 `snap_base` 临时改回 `[8:0]` ⇒ 单元门必须 FAIL | **实测 FAIL** (13d=8 字错 / 15b=0x320), 改回 `[9:0]` ⇒ PASS_ALL |

⚠️ **记一笔被实测纠正的判断**: `snap_cdc` 最初按"两个域各用各的复位 ⇒ 握手永久死锁"来设计
(并把这条写进了注释)。后来专门写了个负对照跑 —— **不死锁**: 同步器把 toggle 当**电平**连续
采样, b 域复位后会把"仍然是 1 的电平"重新识别成一次沿, 握手自动补完。**推理错了, 是测量纠正的**。
同源复位仍然保留 (理由是"复位后必然空闲/一致"这种确定性, 不是躲死锁), 注释已按实测改写。

## 五、已知边界 (别当成缺陷)

- **XDMA 的 DMA 通道没用**: `m_axi` 全 tie "永不应答", 只有寄存器窗口。要搬大数据再加。
- **未实现地址读回 `0xFFFFFFFF` 是 XDMA 主机的行为**, 不是 `axi_regs` 的行为 (后者给 0 + SLVERR)。
  仿真替身不模仿 XDMA 这一段, 所以单元门验 `rresp`、主机脚本验读数 —— 两边各验自己那半。
- **快照是 36 个字 (1152 位)**, 想加计数请按上面"**扩窗必须逐处同改**"那张 7 处清单来 (旧的
  "五处/六处"说法漏了索引表与 `snap_base`/`snap_idx` 的位宽, 正是 24 字与 36 字两次扩窗时踩到的坑)。
  读侧选字的**位宽上限见 `axi_regs` 的注释**（36 字版已把 `snap_idx` 加宽到 6 位、`snap_base` 到 11 位；
  再扩必须先加宽它们，否则 **`0xA0..` 会静默回绕成 `W0..` = 假 PASS**）。
- **`fe_src`/`dp_src` 拼接必须恰好 `NW*32` 位**: 多一项会被静默截断 (门里 `findstr 10-3091` 当硬失败)。
- ⚠️ **`u_rxcdc`/`u_txcdc` 的 `ovf_cnt` 没接进快照**（见上 W27/W28 那条注）—— 这是 F-1 修复留下的
  **板级可观测缺口**：模块里已有拒写探针与单元门（`sim/fifoasync/run_mut_noovf.bat`），
  但 wrapper 例化处 `.ovf_cnt()` 悬空、快照无对应字。若要闭环，只需在 wrapper 里接出来并占用
  下一批扩容的字号（**别复用已有字**）。
- **不新增端口给 PCIe 复位**: 板上 `reset_n` 就接在 PCIe 槽的 PERST# (J9) 上, 同一个信号直连
  `xdma.sys_rst_n` (厂商 BD 也是这么接的)。

## 六、板级首测结果 (2026-09-29 00:44, **合体版第一次上板: 通过**)

`run_build_p6e_ku5p.bat` → 时序 WNS **+0.401** / 0 失败端点 (@8ns, 186,947 端点) → JTAG 烧录
(`End of startup status: HIGH`) → **重启主机** → `sudo bash p6e_snap_check.sh`:

| 项 | 读数 | 意义 |
|---|---|---|
| 0.3 / 1.1 | `MAGIC = 0x50360001` | 观测通道在应答 |
| **1.2** | **`BUILD_ID = 0x00000002`** | **前置闸**: 板上确实是刚烧的合体版 (最小版是 1) |
| 1.4 | `HW_STATUS = 0x18` | bit3 `user_lnk_up`=1 / bit4 `msi_enable`=1 ⇒ 链路起, 字段布局与文档一致 |
| 2.1 / 2.2 | `done` 置起, `gen` 恰好 +1 | 显式触发协议端到端通 |
| 3.1 | 不触发时 8 字逐位不变 | 读窗口原子性成立 |
| **4.2** | **GMII 时钟 ≈ 124.47 MHz** | ⭐ **PHY 回送的 RXC 在跑** —— 15 根 RGMII 引脚第一次拿到板级证据 (RXC=D11) |
| W0 / W1 | 43 帧 / 6870 字节 (≈160B/帧) | 数据面在收帧 |
| **W3** | **FCS 错帧 = 0** | ⭐ **零 IDELAY 前端配方成立** (收到的帧 CRC 全干净) |
| W6 | 43 = W0 | 每一帧都进了 HLS 慢路径 |
| **W7** | **7 帧** | ⭐ **HLS 慢路径在回发** —— 慢路径活着 |

**这一轮的真正意义**: 没有 UART 的板子上, 我们**第一次**把数据面的活体与计数看到眼里 ——
而且看的是"数据面自己报的数", 不是别人的结论。

**⚠️ 烧录纪律的实测修正 (重要)**: 上一轮我在烧完**未重启**时就跑验收, 得到的是
**两个 BAR 全 `0xffffffff`** ⇒ 整条 AXI 通路没起来。原因 = 板子原本跑着 pcie_min, 端点是
**上一次 POST 时**枚举的, 烧录发生在那之后 ⇒ 端点没走完初始化。
⇒ 纪律细化: **"烧完必重启"针对的是"本次 POST 之前 FPGA 里是不是已经跑着带 PCIe 的设计"**;
若上一版也带 PCIe 且链路没断, 重启才可能不是必须的 —— 但**判据只能是"BAR 打得动"**,
`lspci`/config 空间读得出都**不算** (可能是主机侧缓存状态)。
判别器: `p6e_precheck.sh` (两个 BAR 一起看, 直接分出"该重启"还是"设计侧没应答")。

**下一步 (P6a 板级首测的正题)**: 从 PC (192.168.100.1/24) ping 板子 (192.168.100.2),
用 `p6e_watch.sh` 采样: `ΔW0` 涨 ⇒ 帧到 FPGA; `ΔW7` 跟着涨 ⇒ 慢路径在应答 ⇒ **ping 通**。

## 七、板级正题: **真实 ping 通了** (2026-09-29 01:2x)

从直连板子的 Linux 网卡 (`enp3s0`, RTL8111E, 加 `192.168.100.1/24`) 打 `ping 192.168.100.2`:

```
5 packets transmitted, 5 received, 0% packet loss, time 4100ms
rtt min/avg/max/mdev = 0.100/0.128/0.180/0.027 ms
```

数据面自己的计数与它严格对得上: **ΔW0=21 帧 / ΔW6=21 (全部进慢路径) / ΔW7=7 回发**
(5 个 ICMP 应答 + ARP 应答 ≈ 7 ✓)。

⇒ **P6a 的板级正题成立**: RGMII 前端 (零 IDELAY 配方) + 64bit 数据面 + HLS 慢路径
在 KU5P 上端到端跑通, **且 FCS 错帧恒 0** (`W3=0`) ⇒ 物理层配方正确。
`XCKU5PMini/CLAUDE.md` 里"15 根 RGMII 引脚只有 MDIO 三根经过硬件验证"那条可以划掉了。

**⚠️ 未结项: 慢路径出现过一次"不响应窗口"**。同样的 ping 操作在 5 分钟前是 **100% 丢包**
(`ΔW6=8` 但 `ΔW7=0`: 帧进了慢路径但 HLS 一个包没回), 中间**没有任何重建/复位动作**就自愈了。
可能是配置后的热身, 也可能是饥饿看门狗把卡住的 HLS 复位了 (K7 时代吃过 HLS 卡死的亏)。
`p6e_capture.sh` 第 5 段 (10 轮 × 3 包) 就是为这条加的: 全通 ⇒ 一次性热身; 有丢包 ⇒ 间歇失效,
下一步把 `hls_rst_n` / `srx_dbg_starv` / `stx_stat_purge` 加进快照 (扩到 NW=16) 再上板。
（**2026-09-29 已做**: 这一档改成 **W16-W23 / BUILD_ID=4 / 24 字** —— 其中 `stx_stat_purge`=W18,
`hls_rst_n` 的复位**拍数**=W17 (`hr_cnt`; 不用 `srx_dbg_starv`, 因为它与 `hr_cnt` 同源同涨,
省一路), 另加"HLS 真读走字节" W16。配套的决定性上板脚本 = `_proj_pcie/p6e_slowpath_probe.sh`。）

### 七·补、抓包地面真相 (2026-09-29 01:02, 成功那一轮的 pcap)

对端机直连网卡 `enp3s0` 上抓到的完整往返 (`tcpdump -r /tmp/p6e_ping.pcap -n -e`):

```
192.168.100.1 > 192.168.100.2: ICMP echo request, id 5827, seq 1  (98B)
192.168.100.2 > 192.168.100.1: ICMP echo reply,   id 5827, seq 1  (98B)
   ... seq 2..5 同样一一对应 ...
d4:3d:7e:de:28:f4 > 00:0a:35:01:fe:c0  Request who-has 192.168.100.2  (42B)
00:0a:35:01:fe:c0 > d4:3d:7e:de:28:f4  Reply 192.168.100.2 is-at ...   (60B)
```

- **5 个 echo request → 5 个 echo reply**, id/seq 全对, 帧长 98B (= 56 载荷 + 8 ICMP + 20 IP + 14 Eth)
  分毫不差 ⇒ 不是"能通就行", 而是**逐字段正确**;
- **ARP 请求也被正确应答** ⇒ 慢路径的 ARP 处理成立 (板子 MAC `00:0a:35:01:fe:c0` 与之相符);
- 往返延迟 **~90–110 µs** (慢路径 = HLS 软件栈, 这个量级合理);
- 对端 ARP 表里出现板子条目 (`arp -n` ⇒ `192.168.100.2 ether 00:0a:35:01:fe:c0`) ——
  **主机侧独立证据**, 不依赖 FPGA 自己的计数。

### 七·补2、稳定性 + 双向对账 (2026-09-29 01:06, **P6a 收口**)

| 项 | 读数 | 意义 |
|---|---|---|
| **稳定性 10 轮 × 3 包** | **10/10 轮通, 30/30 包, 0 丢** | 那次"不响应窗口"是**一次性热身**, 不是间歇失效 |
| **起点双向对账** | 网卡 TX=308 / **FPGA W0=308**; 网卡 RX=98 / **FPGA W7=98** | ⭐ 点对点链路上**逐帧对齐**: 主机发的每一帧 FPGA 都收到, 慢路径发的每一帧主机都收到 |
| 窗口增量 | ΔW0=5 / ΔW6=5 / ΔW7=5; 网卡 ΔTX=5 / ΔRX=5 | 5 个 echo 进、5 个 reply 出, 1:1 |
| 抓包 | 10 帧全是 ICMP request/reply 对, 间隔 1.024s | 干净 |

⚠️ **本脚本自己也踩了一次"打印与检查脱节"**: 第 4 段的判读原来是**固定文案** ⇒ 在 5/5 全通的
那一轮里照样打印"⇒ 慢路径没回 ARP, 去查 HLS", 与事实相反。已改成**按抓包内容分支**
(有 ICMP ⇒ PASS; 有 who-has 无板子帧 ⇒ 查 HLS; 什么都没有 ⇒ 查主机侧)。
与审查 agent 在单元门里抓到的 F2 是同一类错: **判据的打印必须由判据自己的结果决定**。

### 八、图案/吞吐测试结果 (2026-09-29 02:0x, **1G 线速达成**)

从对端机 (直连板子) 发**一个图案正确的 UDP 教学包**到 `192.168.100.2:8081` 教会板子 peer
(learn-on-RX) ⇒ 板子立即开始**全速**发图案帧 (`TX_GAP=0`, `i_paylen=1472`)。

| 判据 | 读数 | 来源 |
|---|---|---|
| **图案 TX 速率** | **931 Mbps** (79,069 帧/s × 1472B) | **板子自报** `W9`(udpapp_tx_bytes) —— 独立于我的接收侧 ✓ |
| **独立复核** | 网卡 **78,917 帧/s** 收 | Linux `/sys/.../statistics` 硬件计数 ✓ 与板子自报吻合 **0.2%** |
| **逐字节图案校验** | 收到的帧**全部**等于图案流连续前缀 | C++ 对端 memcmp ✓ (含"掉包后重对齐") |
| **板子自己的 RX 校验器** | `W13 图案失配 = 0` | 我发的教学包被它按图案校验**通过** (W10 收帧 = 1) |
| `gmii_free` 反解 | 627,020,671 / 5s = **125.4 MHz** | 与前一次 124.5 MHz 一致 ✓ |

⚠️ **两个"看走眼"的更正 (都写在文档里以防重犯)**:
1. **"6.4 Mbps / 50% 丢包"是我的接收侧到顶, 不是板子慢** —— Python/C++ 单 socket 在 ~80k pps
   下内核缓冲必然溢出; 我一度推断成"背靠背两帧没有 IFG" ✗, 查 `mac_tx_64` FSM 后**否掉**:
   `S_IFG` 只有数满 12 拍一条出口 ⇒ 每帧都有完整 IFG, 而且网卡 99.8% 收全了 ✓。
   ⇒ **判"板子能跑多快"只能看板子自报 (W8/W9) 或网卡硬件计数**, 不能看用户态 socket 的收包数。
2. **`W14/W15` 不是 MAC 计数** —— 它们接的是 `tcp_tx_frame` (TCP fast path);
   `mac_tx_64.stat_frames` 当时在本 wrapper 里**悬空**。图案走 UDP 通路 ⇒ W14/W15 正确读 0。
   ✅ **2026-09-29 已接出 = `W20`** (见寄存器表 §一 与 §八) —— 本段是当时的历史记录, 别按它当现状。

## 九、P6b 板级验收读数 (2026-09-29, **36 字窗口 + 双时钟域**; 归档物 = `P6B_ACCEPT.md`)

> 这一节只放**读数与索引**，判据的推导、未覆盖项、复现步骤全在 `P6B_ACCEPT.md`（本文件不重复、也不替代它）。

| 项 | 读数 | 来源 |
|---|---|---|
| 位流身份 | `c17700868b08170865f4a4ae0292ebb636aed03070e2875f6dbb005123a948ca`（15,431,261 B，`BUILD_ID=6`） | `P6B_ACCEPT.md` §1.1（烧前自算 sha256；另有**过期位流** `03f9c6d0…` 的对照表） |
| 时序基线 | `WNS +0.168 / WHS +0.010 / WPWS 0.000`，**失败端点 0** | 同上 §1.2（`wrapper_p4_timing_summary_routed.rpt`） |
| **数据面频率** | **156.2585 MHz**（`W24` 自由计数 / 真实墙钟；12.188566 s 窗口，已补偿 1 次回绕） | 同上 **B2b** |
| **前端对照** | **125.0061 MHz**（`W5`，同窗口）⇒ **两个域确实不同频** | 同上 **B3** |
| **图案/吞吐** | **956.0 Mbps = 1G 线速上限 957.1 的 99.9%**；三个独立口径互相吻合（板子自报 / 网卡硬件计数偏差 **0.03%** / tcpdump 离线代数 1999/1999 帧逐字节） | 同上 **D1/D2/D3** |
| ping | **5/5**（rtt avg 0.091 ms）与 **20/20**（`-i 0.05` 密集包） | 同上 **C1/C2** |
| 停机态守恒 | `W30 == W0 + W32`（147==147）、`W31 == W1 − 4·W0 + W33`（21235==21235） | 同上 **E1a/E1b/E8** |
| 未实现地址 | `0xB0` 回 `0xffffffff`；**负对照**：同趟读已实现字 `0x14` 回 `0xdeadbeef` | 同上 **A5** |
| 验收总计 | **35 条判据全 PASS**（42 条 PASS 记录 / 0 FAIL / 0 SKIP / 0 NOTE） | 同上 §0 |
| 冒烟轮（**不同位流**） | 956.9 Mbps，逐字节判据 FAIL（工具天花板）—— ⚠️ 它的位流是 `03f9c6d0…`（不含 F-1/F-2） | 同上 §5（**引用冒烟数字必须注明这一点**） |
