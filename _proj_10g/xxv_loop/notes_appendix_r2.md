
---
---

# 第二轮补充（2026-09-29 晚）—— 闭合自报缺口 + 给 64 位 XGMII MAC 的接口合同

> 本节是**追加**，不重写第 1 部分。第 1 部分里被本轮实测**订正**的结论集中在 §10.14。
> 本轮新增位流：sha256 **`2acafb1f4c48c2ff22fcf78ce6fca079f5c3aae98695a49a8206427c7b767f0a`**，
> `WNS +1.870 / WHS +0.006`，`write_bitstream Complete!`（`logs/s2d_run_output.txt`）。
> 板级两个会话：`logs/s7_probe2_FINAL.txt`（48 探针全量）与 `logs/s11_probe3_FINAL.txt`（环回 + 60 s 频率）。

## 10.1 A1——**闸 1a（GT 内部环回）已补测，PASS**

做法：把 `gt_loopback_in_0`（通道 0 的 GT 环回选择）接到 VIO 输出 `vio_gt_loopback[2:0]`，
发生器开着连续流，逐档切换模式，看**通道 0 自己的接收器**是否收到"自己发的帧"（判据 = 我自己的
`xgmii_rx_chk` 在 ch0 上的 `c0_frames` 增长 + 内容判据全 0）。

```
# logs/s11_probe3_FINAL.txt（每档先读 t0、2 s 后再读，差值为窗口内增量）
153:S11_A mode=0 t0: ch0 blk=1 status=1 los=0 frames=0 …            ← 000 = 无环回（负对照基线）
155:S11_A mode=0 WIN: d_c0_frames 0 …                              ← 负对照：不发不收
157:S11_A mode=1 t0: ch0 blk=1 status=1 los=0 frames=4055525 e=9 e_pre0=9 sw_lo=1431655931
159:S11_A mode=1 WIN: d_c0_frames 17572669 d_c0_e 0 d_c1_frames 17572669 d_c1_e 0
163:S11_A mode=2 WIN: d_c0_frames 11945493 …
167:S11_A mode=4 WIN: d_c0_frames 0 …
171:S11_A mode=6 WIN: d_c0_frames 0 …
183:S11_A_RESTORED ch0 blk=1 c0_frames=43716385 c1_frames=128401099
```

| 模式 `gt_loopback_in_0[2:0]` | 窗口内 ch0 收到的帧 | 窗口内 ch1 收到的帧 | 结论 |
|---|---|---|---|
| `000`（无环回，**负对照**） | **0** | 12,316,524 | 判据**不是恒真** ✅ |
| `001` | **17,572,669** | **17,572,669** | ✅ **PASS** |
| `010` | **11,945,493** | 11,945,493 | ✅ **PASS** |
| `100` | 0 | 11,969,325 | ❌ 不成立 |
| `110` | 0 | 11,935,831 | ❌ 不成立 |
| `000`（再关，负对照） | **0** | 11,942,156 | ✅ 判据可重复 |

- **闸 1a 判据成立**：模式 `001`/`010` 下 ch0 收到自己发的帧，且
  **内容判据全 0**（`d_c0_e = 0`，起帧字低 32 位 `sw_lo = 0x555555FB` = 期望常量 `W_START` 的低半 ✓）。
- ⭐ **两个方向的计数逐数相等**（17,572,669 == 17,572,669）——环回把 TX 数据复制给 ch0 的 RX，
  **同时光纤仍把同一份数据送到 ch1** ⇒ 两个接收器同步推进。这条**独立佐证**了环回确实在
  "发端数据"那一点接入，而不是别的地方。
- **负对照（`P7B_SPEC.md` §5.1a 要求"关掉环回必须 FAIL"）**：`000` 三次窗口都是 0 帧 ✓。
- ⚠️ **U6 仍未核实**：我只知道**哪些**编码可用（001/010），**不知道它们的语义**
  （PCS 级/PMA 级、环路点在哪）——本地没有 UG578。若要精确，需查文档或做更细的 A/B。

## 10.2 A2——起动瞬态 `/E/` 的归因（**能给的都给了；机理仍未确证**）

新仪器：`xgmii_rx_chk` 的 `/E/` 计数按"**是否已收到过第一帧**"分成两桶
（`o_e_pre` / `o_e_post`，`rtl/xgmii_rx_chk.v`）。

| 观测 | 值 | 出处 |
|---|---|---|
| ch0（纯 IDLE 方向）本轮的 `/E/` 总数 | **9** | `:157`（`e=9 e_pre0=9`） |
| 其中"**首帧之前**"的 | **9**（= 全部） | 同上：`e_pre0 == e_total` |
| ch0 在环回窗口内的 `/E/` 增量 | **0**（共 6 个窗口） | `:159,163,167,171` 的 `d_c0_e` |
| ch1（判据方向）本轮上电后的 `/E/` 总数 | **199** | `:132` |
| **各次上电的同一读数** | **0**（第三轮 s7 会话）、**9**（ch0，s11）、**47 / 81**（第一轮） | `logs/s7_probe2_FINAL.txt:170`（`e=0`）等 |

⇒ **归因**：所有测到的 `/E/` 都落在 **"上电 → 首帧被收到"** 这个窗口里（ch0 是**严格等于**：
`e_pre0 == e_total`），**且次数不可复现**（0 / 9 / 47 / 81 / 199 五次上电）⇒ 它是**接收链锁定瞬态的
产物，不是链路质量的指示**。
**排除掉的**（有证据）：① 稳态行为（所有健康长窗 Δ`/E/` = 0，本轮 1.41 G 个 rx 周期零增量，`:332` 系）；
② 物理链路质量（同一块板、同一根 AOC，重锁之后 30 M 帧零 `/E/`）；
③ "必然发生"（第三轮 s7 会话 `c1_e` 全程 **0**，`:170`）。
**没有确证的**：到底是环回 FIFO 的时钟校正、`align_status` 未建立期间的解码、还是别的路径产生的 `/E/`
——需要 ILA/`mark_debug` 抓 RX 侧头 100 µs（未做）。
⚠️ **给下一轮的工程结论**：`/E/` 计数**必须在块锁建立之后再开始计**（或块锁建立时清零），
否则厂商那种"粘滞错误位"会把起动瞬态记成链路错误——**第一轮的 `completion_status = 14` 就是这么来的**
（`P7B_GATE1.md` §5.2）。

## 10.3 A3——`dclk` 绝对频率：比值精度提到 6×10⁻⁶，绝对值锚定仍是 ~1%

方法改进：五个快照、**墙钟时间戳紧贴快照之后**（不是读完 48 个探针之后）、
32 位计数器**显式展开回绕**（每次变小 = 一次 wrap），窗口 63.8 s。

```
# logs/s11_probe3_FINAL.txt
214:S11_B k=0 wall_ms=1790687310344 dclk_snap=3422831317 rx1_free=1051476058 tot_d=0 tot_r=0
218:S11_B k=4 wall_ms=1790687373576 dclk_snap=1155131428 rx1_free=2339977741 tot_d=6322234703 tot_r=9878436275 wraps_d=2 wraps_r=2
222:S11_B_WALL_SECONDS 63.767 TOT_D 6322234703 TOT_R 9878436275
224:S11_B_RX_OVER_DCLK 1.5624912296141942
226:S11_B_DCLK_MHZ_IF_RX_IS_156250000 100.00056130784222
230:S11_B_DCLK_MHZ_FROM_WALLCLOCK 99.14587016795521
```

| 量 | 读数 | 精度/含义 |
|---|---|---|
| `f(rx1)/f(dclk)`（**同一次快照锁存**，回绕已展开） | **1.5624912296** | 标称 1.5625 ⇒ **−6×10⁻⁶**；这是**比值**的精度 |
| 若 `dclk` = 100.000 MHz（Y1 晶振，P6b 交叉印证 +5 ppm） | `f(rx1)` = **156.2491 MHz** | ⇒ 线速 9,999.94 Mbps |
| 只用我自己的墙钟（63.767 s）反推 `dclk` | 99.146 MHz（**−0.85%**） | ⚠️ 与上面**差 0.85%**，未消解 |

⚠️ **诚实结论**：**比值**已经是 6×10⁻⁶ 级（两个计数器由同一次请求锁存，窗口 63.8 s、展开 2 次回绕）；
**绝对刻度**只到 **±0.85%**——我的墙钟口径自己与"Y1 = 100 MHz"这条硬件事实差 0.85%，
差异来源未定位（最可能是 JTAG commit/读数在时间戳两侧的系统性偏移），**列为未核实**。
⇒ 因此"`dclk` = 100 MHz ±1%"这条（§5.6 / §6.3 C9）**维持不变**，只是比值那一半从 ±1% 提到了 6×10⁻⁶。
**对下游 CDC 余量估算的含义**：下一轮 MAC 的两个跨界点（DP↔TX-MII、RX↔DP）要用到的量是
**频率比**；本设计里 TX 与 RX 两个 156.25 MHz 都来自**同一个 QPLL0** ⇒ 本地比值 = 1（实测 6×10⁻⁶ 内）。
但这**不能**当成"余量足够"：与**第三方对端**对接时 10GBASE-R 允许每端 ±100 ppm ⇒ 跨界结构仍必须按
**±200 ppm** 设计（`P7B_SPEC.md` §3.4 的硬规则不变）。本读数只排除了"本地时钟标称值有 1% 级错误"。

## 10.4 A4——非平凡载荷：**已跑通**（0xFFFFFFFF 载荷，10,033,916 帧零失配）；并揭出一个真缺陷

官方 example 的载荷在 as-instantiated 下是**全 0**（`assign data_select = 2'b0`，硬编码，无运行时开关）。
本轮做了**参数化副本** `rtl/pcs64_pkt_gen_mon_ds.v`（与厂商原文的**完整 diff 只有 6 处**，见下），
把 `data_select` 接成 `{1'b0, pay_sel}`，`pay_sel` 由 VIO 选 **0x00 / 0xFF** 两档载荷。

```
# logs/s7_probe2_FINAL.txt
294:S7_S5_WIN frames=10033916 paywords=290983586 badpay=0
296:S7_S5_PAYWORDS_PER_FRAME 29.000002192563702 (expect 29.0)
302:S7_S5_CS 1 (0x1F = never ran, 2 = no block lock, 1 = SUCCESSFUL)
321:S7_S6_CS 1
```

| 载荷档 | 判据 | 实测 | 结论 |
|---|---|---|---|
| **全 1（0xFFFFFFFF）** | `o_bad_pay`（与全 1 不符的载荷字数）恒 0 | **0 / 290,983,586 字 / 10,033,916 帧** | ✅ **逐字通过** |
| 同上 | 头字判据 `o_bad_hdr`（含 word2 的两个载荷 lane） | **0** | ✅ |
| 同上 | 载荷字数/帧 | **29.000002** | ✅ 几何不变 |
| 同上 | 官方 FSM 判决 | `completion_status = 1` | ✅ |
| 回切全 0 | `badpay/badstart/badhdr` | **全 0**（`:321` 的 S7_S6 行） | ✅ 可逆 |

⚠️ **本轮揭出的真缺陷（值得单列）**：第一次参数化时我漏了**中间层** `pcs64_mii_traffic_gen_mon`
的端口声明 ⇒ 那一层的 `pay_sel` 成了**隐式 1 位线（悬空）** ⇒ 发生器侧的 `data_select` 恒为常量、
**载荷根本没换**（板上表现为：`pay_sel=1` 时"每一个载荷字都失配"，而 `pay_sel=0` 时零失配）。
- **发现手段 = 仿真**：`sim/tb_pay_sel.v` 直接探 `pkt_gen` 内部，读到 `data_select = 2'b0z`
  （悬空）与 `d_sel = 0z` ⇒ `case` 落到 `default` 分支 ⇒ 载荷走 PRBS。**5 分钟定位**（板上查这个要几轮）。
- **更值得记的是门漏了它**：Vivado 2025.2 对隐式网打的是
  `INFO: [Synth 8-11241] undeclared symbol 'pay_sel', assumed default net type 'wire'`
  —— 而我的硬门关键字是 **"implicitly declared"**（本仓旧措辞）⇒ **门报 0，设计里却真有一个隐式网**。
  这正是本工程最忌讳的"真空门"形态。**已修**（`tcl/s2_build.tcl` 的门现在同时匹配
  `8-11241` / `undeclared symbol` / `does not have driver` / `unconnected or has no load`）；
  修好后重跑：`pay_sel` 相关消息 **0 命中**，剩下 10 条 `undeclared symbol` **全部来自厂商文件自身**
  （`ctl_tx_enable`/`clear_count`/`rx_mii_clk`/`stat_rx_status` 等，写多读少），我的 RTL 贡献 0。

**副本 vs 厂商原文的完整 diff（6 处，逐处必要）**：模块改名 `pcs64_pkt_gen_mon_ds`；顶层加
`input pay_sel`；顶层向 traffic_gen_mon 传 `.pay_sel`；traffic_gen_mon 加 `input pay_sel`（**这一处第一次漏了**）；
traffic_gen_mon 向 pkt_gen 传 `.pay_sel`；pkt_gen 加 `input pay_sel` 并把
`assign data_select = 2'b0` 改成 `{1'b0, pay_sel}`。⇒ **`pay_sel = 0` 时与厂商行为逐位相同**
（已由板上"全 0 载荷 30 M 帧零失配"与第一轮读数一致佐证）。

## 10.5 A1b——C7 复闭合：framing/bad_code/fifo 现在是**精确 0**；`rx_error` 仍未测

新仪器：**同一组 `stat_*` 信号在 dclk 与 ch1 恢复域各计一遍**（32 位、不回绕、不清零；
`rtl/xxv_loop_top.v` 的 `s_*_d`/`s_*_r`），读数在 `in36..in47`。

```
# logs/s7_probe2_FINAL.txt（8.79 s 窗口；`:225/:226` 是本行里的两个域计数）
225:S7_S3_D vcc_d 885011279
226:S7_S3_D vcc_r 1412908411
227:S7_S3_D ferr_d 0        228:S7_S3_D ferr_r 0
229:S7_S3_D bcd_d 0         230:S7_S3_D bcd_r 0
231:S7_S3_D ffe_d 0         232:S7_S3_D ffe_r 0
233:S7_S3_D errv_r 0
238:S7_S3_DD 904266410
```

| 判据（§6.1 C6/C7） | 观测周期数 | dclk 域 | ch1 恢复域 | 结论 |
|---|---|---|---|---|
| `stat_rx_framing_err`（+`_valid`） | 0.90 G dclk + 1.41 G rx | **0** | **0** | ✅ **精确 0**（不回绕计数器，任一脉冲都会被记到） |
| `stat_rx_bad_code`（+`_valid`） | 同上 | **0** | **0** | ✅ 精确 0 |
| `stat_rx_fifo_error` | 同上 | **0** | **0** | ✅ 精确 0 |
| `stat_rx_error_valid` | 同上 | —（未在 dclk 计） | **0** | ⚠️ **仍未触发** ⇒ `stat_rx_error[7:0]` 依旧是"没话说"，**C7 这一条按未测登记** |
| `stat_rx_valid_ctrl_code` | 同上 | 885,011,279 | 1,412,908,411 | ⚠️ **它是电平不是脉冲**（见下） |

⭐ **顺带纠正一个语义**：`stat_rx_valid_ctrl_code` 在两个域里都**几乎每拍为 1**
（rx 域计数 1,412,908,411 ≈ Δrx 时钟数 1,412,908,411 **逐数相等**）⇒ 它是
**"当前收块是合法控制块"的电平**，不是"每收到一个控制码脉冲一次"。
⇒ 第 1 部分 §5.1 里"`valid_ctrl_code` 8 位计数器饱和 ⇒ 非 0 且持续增长"要**改口径**：
它是**电平**，只能当"链路活着时该状态线为高"用；**"控制块真的在收"的精确证据仍然是
我自己的 `c1_ctrl`/`c0_ctrl`**（§5.1 那段的后半句）✓。
**对下一轮的忠告**：`valid_ctrl_code` **不能计事件数**（会等于时钟数）；要么当电平采，要么不用。

## 10.6 B 节——六个接口未知项的直接答案（全部出自**本周期的工程与生成物**）

### B1（= `P7B_SPEC.md` U1）端口 `_0`/`_1` 的语义：**是通道索引**，2 通道时两套齐全

`artifacts/pcs64_2ch.veo:58-157`（本次生成的实例化模板，逐行可核）+ 我工程的例化：
`tx_mii_d_0[63:0]`/`rx_mii_d_0[63:0]` 与 `tx_mii_d_1[63:0]`/`rx_mii_d_1[63:0]`
是**两个独立通道**（`_0` = X0Y4 = SFP A = J7；`_1` = X0Y5 = SFP B = J8）。
**不是位宽拼接**。共享端口**只有一个副本、且不带 `_1`**：`sys_reset` / `dclk` /
`gt_refclk_p,n` / `gt_refclk_out` / `qpllreset_in_0`。
每通道各自一套的：`gt_rxp/rxn_in_N`、`gt_txp/txn_out_N`、`tx_mii_clk_N`、`tx_mii_d/c_N`、
`rx_clk_out_N`、`rx_core_clk_N`、`rx_mii_d/c_N`、`gtpowergood_out_N`、`rxrecclkout_N`、
`rx_reset_N`/`tx_reset_N`、`user_rx_reset_N`/`user_tx_reset_N`、全套 `stat_*_N`、
`ctl_tx_*_N`、`ctl_rx_*_N`、`txoutclksel_in_N`/`rxoutclksel_in_N`、
`gtwiz_reset_{tx,rx}_datapath_N`、`gt_loopback_in_N`、`ctl_rx_wdt_disable_N`。
**证据等级**：`.veo` 明文 + 我工程里 48 个探针在 2 通道上的**实测差异**（两个方向的计数独立推进）。
⚠️ 通道**号**与**球号**的对应由核内 XDC 的 LOC 决定：`artifacts/ip_0_pcs64_gt.xdc:57` =
`LOC GTYE4_CHANNEL_X0Y4`，`artifacts/ip_1_pcs64_gt_1.xdc:57` = `X0Y5`。

### B2（= U4）`sys_reset` 配方：**我给的就是这段，逐行抄回**

`rtl/xxv_loop_top.v:110-137`（**顶层自己产生**，与厂商 example 把 `sys_reset` 当外部输入一致）：

```verilog
    reg [19:0] por_cnt = 20'd0;                 // :110
    wire       por_n   = &por_cnt;              // :111
    always @(posedge dclk) if (!por_n) por_cnt <= por_cnt + 20'd1;   // :112  ~10.5 ms POR

    reg  cmd_restart_d = 1'b0;                  // :122
    reg  cmd_sysrst_d  = 1'b0;                  // :123
    reg [15:0] restart_cnt = 16'd0;             // :124  ~10 us
    reg [19:0] sysrst_cnt  = 20'd0;             // :125  ~10 ms
    always @(posedge dclk) begin                // :127
        cmd_restart_d <= vio_cmd_restart;       // :128
        if (vio_cmd_restart && !cmd_restart_d) restart_cnt <= 16'd1000;   // :129 边沿→脉冲
        else if (restart_cnt != 16'd0)         restart_cnt <= restart_cnt - 16'd1;
        cmd_sysrst_d <= vio_cmd_sysreset;       // :132
        if (vio_cmd_sysreset && !cmd_sysrst_d) sysrst_cnt <= 20'hFFFFF;
        else if (sysrst_cnt != 20'd0)          sysrst_cnt <= sysrst_cnt - 20'd1;
    end
    wire sys_reset     = ~por_n | (sysrst_cnt != 20'd0);   // :136 高有效
    wire restart_tx_rx = (restart_cnt != 16'd0);           // :137
```

- **极性/语义**：`sys_reset` **高有效**；`restart_tx_rx` 是**用户级重启**（它进厂商模块，
  `mii_reset = user_*_reset | restart_tx_rx`，会清发生器/监视器计数并让 FSM 重跑）。
- **`gtpowergood`/QPLL lock/tx,rx active 的先后**：**不在用户侧**——核只有 `sys_reset` 一个总复位入口，
  `gtpowergood_out_N` 只是**状态输出**（我接进观测）；GT 的复位序列（powergood → QPLL lock →
  tx/rx resetdone）由**核内 reset controller** 自己走（`INCLUDE_SHARED_LOGIC=1`）。
  **实测证据**：POR 释放后 ~10.5 ms 内两个通道都起（第一轮 §5.1），
  且 FSM 的 45 ms 起始窗内块锁已建立（θ `completion_status=1`）。
- **厂商 example 的对照**：`pcs64_exdes_tb.v` 在仿真里把 `sys_reset` 拉高 20 个 dclk 后释放
  （我这里是 2²⁰ 个 dclk，因为板上还要等 GT/PLL）。
- ⚠️ **未核实**：`sys_reset` 的**最小宽度**要求（我只知道 10.5 ms 一定够）。

### B3（= U9/U10）`user_*_reset` 与 `rx,tx_reset_N` 的**域与语义**（网表实证）

用路由后网表读**同步器目的端的 FDRE 时钟脚**（`tcl/s8_rst_clk.tcl`，只读）：

```
# logs/s8_rst_stdout.txt
S8_CELL DUT/inst/i_pcs64_core_cdc_sync_gt_tx_resetdone_0/s_out_d2_cdc_to_reg REF=FDRE CLK=txoutclk_out[0]
S8_CELL DUT/inst/i_pcs64_core_cdc_sync_gt_tx_resetdone_1/s_out_d2_cdc_to_reg REF=FDRE CLK=txoutclk_out[0]_1
S8_CELL DUT/inst/i_pcs64_core_cdc_sync_gt_rx_resetdone_0/s_out_d2_cdc_to_reg REF=FDRE CLK=rxoutclk_out[0]
S8_CELL DUT/inst/i_pcs64_core_cdc_sync_gt_rx_resetdone_1/s_out_d2_cdc_to_reg REF=FDRE CLK=rxoutclk_out[0]_1
S8_CELL DUT/inst/i_pcs64_core_cdc_sync_gt_rxreset_1/s_out_d2_cdc_to_reg       REF=FDRE CLK=rxoutclk_out[0]_1
S8_USER user_tx_reset_0 DUT/inst/i_pcs64_core_cdc_sync_gt_tx_resetdone_0/user_tx_reset_0_INST_0 REF=LUT1 SEQ=0
S8_USER user_tx_reset_1 DUT/inst/…tx_resetdone_1/user_tx_reset_1_INST_0 REF=LUT1 SEQ=0
S8_STATSYNC DUT/inst/i_pcs64_core_cdc_sync_stat_rx_block_lock_dclk_1/s_out_d2_cdc_to_reg CLK=dclk
```

| 信号 | 方向 | **域（实证）** | 语义 | 能不能硬接 0 |
|---|---|---|---|---|
| `user_rx_reset_N` | **out** | **`rx_core_clk_N` = `rxoutclk_out[0]_N`**（由 `..._gt_rx_resetdone_N` / `..._gt_rxreset_N` 这两个 CDC 的目的域产生） | 核告诉用户"RX 数据通路刚复位/正在复位" | —— （是输出；**应当消费**：我把它当 chk_N 的同步复位 + 进观测 bundle。悬空会让核内读它的 LUT 悬空，侦察坑 1 实测 `opt_design` 直接失败） |
| `user_tx_reset_N` | **out** | **`tx_mii_clk_N` = `txoutclk_out[0]_N`**（由 `..._gt_tx_resetdone_N` 产生） | 同上，TX 侧 | —— |
| `rx_reset_N` | **in** | 用户侧请求（核内被 `..._gt_rx_resetdone_N`/`rxreset_N` 那块逻辑读） | "用户请求复位核的 RX 数据通路"【推定】 | **能，而且我就是这么接的**：`ch0` 的 `rx_reset_0` = 常数 `1'b0`（`:assign rx_reset_0 = 1'b0;`），`ch1` 的 `rx_reset_1` = 厂商模块的常数 0 输出 |
| `tx_reset_N` | **in** | 同上（TX 侧） | 同上 | **能**：`tx_reset_0` = 厂商模块输出的常数 0；`tx_reset_1` = 常数 `1'b0` |

⚠️ **给下一轮的用法**：**要用 `user_rx_reset_N` 当自写 MAC 的 RX 复位源**（它天然在 RX 域、
且会把 MAC 的 FSM 和核内状态对齐）；**绝不要**在用户侧"造"复位去猜核的时序。
`rx_reset_N`/`tx_reset_N` 只在你**故意**要重启核数据通路时用；默认 0。

### B4（= U8）`stat_*` 的时钟域：**block_lock 实证 = dclk；其余"域未确证"，但给出了打法**

```
# logs/s8_rst_stdout.txt
S8_STATSYNC DUT/inst/i_pcs64_core_cdc_sync_stat_rx_block_lock_dclk_0/s_out_d2_cdc_to_reg CLK=dclk
S8_STATSYNC DUT/inst/i_pcs64_core_cdc_sync_stat_rx_block_lock_dclk_1/s_out_d3_reg     CLK=dclk
```

| 状态 | 域 | 依据 |
|---|---|---|
| **`stat_rx_block_lock_N`** | **dclk** ✅ | 核内名为 `i_pcs64_core_cdc_sync_stat_rx_block_lock_dclk_N` 的四级同步器，**目的端 FDRE 的时钟脚 = `dclk`**（网表实证） |
| `stat_rx_status` / `hi_ber` / `local_fault` / `framing_err(_valid)` / `bad_code(_valid)` / `error[7:0](_valid)` / `fifo_error` / `valid_ctrl_code` / `tx_local_fault` | **未确证**（核内加密，网表里查不到生产者；`tcl/s6_stat_cells.tcl` 的 `ncells=0`） | 双域计数实验**没能判别**它们（见下） |

**为什么没判别出来**（如实登记）：判别需要一个**脉冲**信号——rx 域 6.4 ns 脉冲会被 dclk 采样漏掉约 1/3，
dclk 域 10 ns 脉冲则两个域都 100% 收到。但本轮窗口里**这些信号一个脉冲都没有**
（framing/bad_code/fifo/error_valid 全 0，见 §10.5），而唯一非零的 `valid_ctrl_code` 是**电平**
⇒ 电平在两个域里都"每拍为 1"，比值只会告诉你时钟比（实测 1.596 ≈ 1.5625，被实时读的偏斜抬高），
**判别不了域**。
**给下一轮的可操作结论**（不依赖"域确证"）：
1. **`block_lock` 可以直接在 dclk 采**（实证）；
2. 其余状态位**一律按"可能异步"处理**：每位一个 2FF 同步器（电平）/ 或**快照+握手**（多比特如 `rx_error[7:0]`），
   **绝不做多比特直接两级同步**（`P7B_SPEC.md` §3.2 硬规则）；
3. **`valid_ctrl_code` 按电平采**，不要计事件（§10.5 的语义纠正）；
4. 想**真的**确证域：造一个已知脉冲源（例如故意在链路里打一个坏块）再跑同一条双域计数实验——
   本轮没做。
**实测反证"按 dclk 采它们不会出事"**：第一轮 30 M 帧 + 本轮 41.5 M 帧的健康窗口里，
这些信号在 dclk 域的读数与我在 rx 域的独立检查器（`c1_*`）**处处自洽**，没有出现位混值/抖动。

### B5（`FREERUN_FREQUENCY = 100.00`）它对运行**无影响**；**顶层不可改**

- **对运行无影响（实测）**：链路正常、块锁 = 1、`completion_status = 1`，
  线速 **9,999.94 Mbps**（§5.5/§5.6），环回/图案/负对照全部按预期 ⇒ 这个参数在**有参考钟**的
  工作模式下不参与数据通路。它是"**不依赖参考钟的自由运行**"模式（GT 用自由运行时钟来复位/校准）
  才用到的频率标称值。
- **可不可改**：**顶层 IP 上根本没有这个属性**——`tcl/s10_misc_query.tcl` 直接回读：
  ```
  S10_PROP CONFIG.GT_DRP_CLK = 100.00
  S10_TRY CONFIG.FREERUN_FREQUENCY rc=1   ← get_property 失败：属性不存在
  S10_TRY CONFIG.GT_DRP_CLK       rc=0 val=<100.00>
  S10_TRY CONFIG.GT_REF_CLK_FREQ  rc=0 val=<156.25>
  ```
  ⇒ **用户能设的是 `CONFIG.GT_DRP_CLK`（= 100.00）**，子核的 `FREERUN_FREQUENCY` 是**派生**出来的
  （它与 `dclk` 的 OOC 约束 `create_clock -period 10.000 [get_ports dclk]` 一致，§3.2 专项）。
  ⇒ 结论：**不需要也无法单独把它改成 156.25**；只要 `dclk` 真的是 100 MHz（本轮实测支持，±1%），
  它就是对的。**不要把 156.25 喂给 `dclk`**（那会让复位/DRP 定时器快 1.56×，`P7B_SPEC.md` §3.6）。

### B6（`[DRC AVAL-326]`）是什么规则；本轮 0 次是否预期

- **规则本体**（原文，来自侦察期日志，`P7B_XXV_OFFICIAL.md` §5.4 坑 3）：
  ```
  CRITICAL WARNING: [DRC AVAL-326] Hard_block_must_have_LOC: The hard block IBUFDS_GTE4 cell
  DUT/inst/IBUFDS_GTE4_GTREFCLK0_INST is missing a valid LOC constraint …
  ```
  ⇒ **规则名 `Hard_block_must_have_LOC`**：硬块（GT 相关原语）**必须有有效的 LOC 约束**。
  它在 `AVAL` 这个 DRC 族里，级别是 **Critical Warning**（实测**不拦位流**：侦察期 PCS 变体带着它
  `Bitgen Completed Successfully`）。
- **本轮 0 次**：`logs/s2_build_stdout.txt` 的 `S2_GREP <AVAL-326> = 0`（synth 与 impl 两份 runme.log），
  且 `xxv_loop_top_drc_routed.rpt` 里也 0 命中。
- **是否预期**：**现象是 0，但机理未核实**——`tcl/s10_misc_query.tcl` 查询显示**路由后网表里
  根本没有 `IBUFDS_GTE4` 这个名字的 cell**（`S10_IBUFDS_N = 0`；参考钟缓冲在核内的
  `*_common_wrapper` 里，加密区不可见）⇒ 规则"找不到 IBUFDS_GTE4"自然不报。
  为什么侦察期能看到而本轮不能，**没有查清**（可能与 1 通道 vs 2 通道下 common/IBUFDS 的层次命名有关）。
  ⚠️ 因此本报告**不把"0 次"当成"IBUFDS 有 LOC 了"**——只能说**位流生产全程没有这条告警**，
  且**两次（侦察 + 本轮）都没有拦住位流**。

## 10.7 C 节——**给 64 位 XGMII MAC 的接口合同**

### C.1 我工程实际用到的端口（名/位宽/方向/域/语义/证据）

| 端口 | 位宽 | 方向 | 时钟域 | 语义（下一轮直接用） | 证据 |
|---|---|---|---|---|---|
| `gt_refclk_p/n` | 1 | in | — | 156.25 MHz 差分参考钟（V7/V6） | `.veo:84-85`；`artifacts/pcs64_ooc.xdc:80` |
| `gt_refclk_out` | 1 | out | — | **不要消费** | `.veo:86`；侦察坑 2 |
| `dclk` | 1 | in | — | 100 MHz DRP/控制域（我喂 Y1） | `.veo:79`；`pcs64_ooc.xdc:76` |
| `sys_reset` | 1 | in | 异步 | 高有效总复位（§B2） | `.veo:78` |
| `qpllreset_in_0` | 1 | in | — | 恒 0 | `.veo:155` |
| `txoutclksel_in_N` / `rxoutclksel_in_N` | 3 | in | — | 恒 `3'b101`（厂商注释"不可改"） | `.veo:68-71` |
| `gtwiz_reset_{tx,rx}_datapath_N` | 1 | in | — | 恒 0 | `.veo:72-75` |
| `gt_loopback_in_N` | 3 | in | — | GT 环回（闸 1a 用；`001`/`010` 实测可用） | `.veo:153-154`；§10.1 |
| `ctl_rx_wdt_disable_N` | 1 | in | — | 恒 0 | `.veo:156-157` |
| `gt_rxp_in_N`/`gt_rxn_in_N` | 1 | in | — | GT 串行入（球号由通道 LOC 推导） | `.veo:58-61` |
| `gt_txp_out_N`/`gt_txn_out_N` | 1 | out | — | GT 串行出 | `.veo:62-65` |
| **`tx_mii_clk_N`** | 1 | **out** | — | **XGMII TX 时钟 = `txoutclk_out[0]{,_1}` = 156.25 MHz（实测 156.2491）** | `.veo:80-81`；`timing_summary_routed.rpt` 时钟树；§10.3 |
| **`tx_mii_d_N`** | **64** | **in** | `tx_mii_clk_N` | XGMII TX 数据，**lane0 = 帧内首字节 = `d[7:0]`** | `.veo:133-134`；§C.2 的板级反推 |
| **`tx_mii_c_N`** | **8** | **in** | `tx_mii_clk_N` | XGMII TX 控制位，**`c[l]` 对应 lane l = `d[8l+7:8l]`**（1 = 控制字符） | `.veo:135-136`；§C.3 |
| **`rx_clk_out_N`** | 1 | **out** | — | **恢复时钟 = `rxoutclk_out[0]{,_1}` = 156.25 MHz（CDR）** | `.veo:82-83`；时钟树 |
| **`rx_core_clk_N`** | 1 | **in** | — | **必须由用户供 156.25**；厂商 example 用 `rx_clk_out_N` 自环（我照做，`:156-157`） | `.veo:66-67`；`pcs64_exdes.v:98` |
| **`rx_mii_d_N`** | **64** | **out** | `rx_core_clk_N` | XGMII RX 数据，lane0 = 首字节 | `.veo:93-94` |
| **`rx_mii_c_N`** | **8** | **out** | `rx_core_clk_N` | XGMII RX 控制位 | `.veo:95-96` |
| `gtpowergood_out_N` | 1 | out | — | GT 就绪（=1） | `.veo:87-88` |
| `rxrecclkout_N` | 1 | out | — | **不要消费** | `.veo:76-77` |
| `user_rx_reset_N` / `user_tx_reset_N` | 1 | **out** | **RX / TX-MII 域**（§B3 实证） | **当自写 MAC 的复位源** | `.veo:91-92,131-132`；§B3 |
| `rx_reset_N` / `tx_reset_N` | 1 | **in** | （核内） | 默认**硬接 0**（§B3） | `.veo:89-90,129-130` |
| `stat_rx_block_lock_N` | 1 | out | **dclk**（实证） | 块锁 = 1 | `.veo:111-112`；§B4 |
| `stat_rx_status_N` | 1 | out | 未确证（按 dclk 采 + 2FF） | RX 链路健康 = 1 | `.veo:115-116` |
| `stat_rx_hi_ber_N` | 1 | out | 同上 | 高误码 = 0（**不当零误码证据**） | `.veo:117-118` |
| `stat_rx_local_fault_N` / `stat_tx_local_fault_N` | 1 | out | 同上 | = 0（对端没在发 `/Q/`） | `.veo:109-110,137-138` |
| `stat_rx_framing_err_N` + `_valid_N` | 1+1 | out | 同上 | `_valid` 限定那拍计数；**恒 0**（精确，§10.5） | `.veo:105-108` |
| `stat_rx_valid_ctrl_code_N` | 1 | out | 同上 | ⚠️ **电平**（§10.5） | `.veo:113-114` |
| `stat_rx_bad_code_N` + `_valid_N` | 1+1 | out | 同上 | **恒 0**（精确） | `.veo:119-122` |
| `stat_rx_error_N` + `_valid_N` | **8**+1 | out | 同上 | ⚠️ **`_valid` 从未触发 ⇒ 无观测面** | `.veo:123-126` |
| `stat_rx_fifo_error_N` | 1 | out | 同上 | **恒 0**（精确） | `.veo:127-128` |
| `ctl_tx_*_N`（7 根：`test_pattern`/`_enable`/`_select`/`data_pattern_select`/`seed_a[57:0]`/`seed_b[57:0]`/`prbs31_enable`） | 1/58 | in | — | 测试图案控制；**我全接常数 0** | `.veo:139-152` |
| `ctl_rx_*_N`（4 根：`test_pattern`/`data_pattern_select`/`test_pattern_enable`/`prbs31_enable`） | 1 | in | — | 同上 | `.veo:97-104` |

> ⚠️ **`tx_mii_clk_N` 的边沿关系**：核输出的是**与数据同域的时钟**，用于对 `tx_mii_d/c` 采样；
> 下一轮 MAC 里**必须**用它（或它的派生）驱动 TX 侧，**不要**用 dclk 或自造时钟。
> ⚠️ `tx_mii_clk_N` / `rx_clk_out_N` 都是核的输出 ⇒ **用户侧只能 BUFG 后使用**（我这样做，
> 时钟树里以 `txoutclk_out[0]`/`rxoutclk_out[0]_N` 出现）。

### C.2 ⭐ XGMII 字 → 我们帧流合同的**逐字节镜像表**（并用板级读数反推验证）

**两侧事实**：官方 XGMII = **lane0 首发**（`mii_d[7:0]` = 帧首字节，证据见 §5.3 与
`pcs64_pkt_gen_mon.v` 的 `swapn`）⇔ 本仓冻结合同 = **`tdata[63:56]` = 帧首字节**
（`rtl/mac_rx_64.v:2-8`）。⇒ **8 字节镜像（`bswap64`），纯连线 0 逻辑**：

| 合同位（左对齐） | ← XGMII 位（lane0 在最低位） | 帧内字节号 |
|---|---|---|
| `tdata[63:56]` | `mii_d[7:0]` | byte0（首发） |
| `tdata[55:48]` | `mii_d[15:8]` | byte1 |
| `tdata[47:40]` | `mii_d[23:16]` | byte2 |
| `tdata[39:32]` | `mii_d[31:24]` | byte3 |
| `tdata[31:24]` | `mii_d[39:32]` | byte4 |
| `tdata[23:16]` | `mii_d[47:40]` | byte5 |
| `tdata[15:8]`  | `mii_d[55:48]` | byte6 |
| `tdata[7:0]`   | `mii_d[63:56]` | byte7 |

> 一般式：`tdata[(7-l)*8 +: 8] = mii_d[l*8 +: 8]`，`l = 0..7`（TX 方向同一张表反用）。

**用板级读数反推验证（链式三步，每一步都有文件行号）**：

1. **板级捕获的起帧字**：`S3_FINAL_SWORD hi 3579139413 lo 1431655931`
   （`logs/s3_probe_FINAL.txt:549`；第三轮同值：`logs/s7_probe2_FINAL.txt` 的 `S7_S2 sword_hi/lo`）
   ⇒ 拼接得 `mii_d = 0xD5555555_555555FB`。
2. **按字节拆开**（MSB→LSB）：`D5 | 55 | 55 | 55 | 55 | 55 | 55 | FB`
   ⇒ `mii_d[7:0] = 0xFB`；`mii_d[63:56] = 0xD5`。
   而**厂商明文**说这一帧的前 8 个字节应当是 `/S/(0xFB) + 0x55×6 + D5`
   （`preamble = 64'hFB_55_55_55_55_55_55_D5` + `swapn`）⇒ **`0xFB`（首发字节）确实落在 `mii_d[7:0]`** ✓
   ⇒ 表的第一行 `tdata[63:56] ← mii_d[7:0]` 成立 ✓（即 `/S/` 会出现在我们合同的**首字节**位置）。
3. **判据全等**：我的检查器把 `mii_d == 64'hD5555555555555FB && c == 8'h01` 当作"帧首字"
   （期望常量从厂商字面量手推、**不由 DUT 生成**），在板上**40 M 帧以上全部匹配**：
   `S7_S3_D c1_badstart 0`（`logs/s7_probe2_FINAL.txt:220`，同窗口 `Δframes = 41,556,130`，`:216`）
   ⇒ **镜像表的两端（首字节位置）都被独立验证**。
   ⚠️ 判别力声明（§5.3 同）：本方向是"官方发 → 官方收"，**对称**，
   所以它证明的是"**本轮数据的 lane 布局 = 官方约定**"，
   **不能**裁定"绝对字节序"——那一票仍归闸 2 的真网卡。

### C.3 `mii_c[7:0]` 各位 ↔ 字节 lane 的对应

- **结论**：`mii_c[l]` 是 **lane `l` = `mii_d[l*8 +: 8]` = byte `l`** 的控制位（1 = 该 lane 是控制字符）。
- **板上佐证**（三条，互相独立）：
  1. **帧首**：检查器要求 `c == 8'h01` 且 `d[7:0] == 0xFB`（即**只有 lane0 是控制位、且是 `/S/`**）
     —— 40 M+ 帧 `badstart = 0` ⇒ `c[0] ↔ lane0` ✓；
  2. **帧尾**：`/T/`（0xFD）被要求**落在 lane0**（检查器的 `o_bad_term` 为 0，
     `logs/s3_probe_FINAL.txt` 的起帧字/终止字判据同批为 0）⇒ 控制位与 lane 的绑定成立 ✓
     （⚠️ 本轮没打印 `o_t_lane` 的原始值，所以这一条是**由判据间接得到**，不是直接读到的；
     第一轮的 `o_t_lane` 读数为 0 记录在 `logs/s3_probe_FINAL.txt` 的 `S3_FINAL_MISC` 行）
  3. **空闲**：厂商发生器的空闲字是 `d = 0x0707070707070707`（全 lane `/I/`）**且 `c = 8'hFF`**
     —— 我的检查器以"`c == 8'hFF && d == 0x0707…07`"识别空闲字，ch0 方向实测
     `c0_idle ≈ c0_ctrl`（§5.1 的 idle/ctrl 计数）⇒ **8 个 lane 的控制位都在 `c` 里** ✓。
- ⚠️ **下一轮注意**：`/T/` 之后**同一个字里剩下的 lane**（厂商发生器给的是 `/I/`，而 `mii_c` 里那几位是 1）
  属于**下一帧的领地**；我们的 MAC 不能把它们算进本帧（`/T/` 是本帧最后一个有效字节）。

### C.4 帧几何（本轮实测钉死的常量，下一轮 MAC 的自检可以用）

| 量 | 值 | 证据 |
|---|---|---|
| 每帧 XGMII 字数 | **33**（32 个数据字含首字 + 1 个终止字） | `S7_S3_D`/`S3_LONG_WORDS_PER_FRAME = 34.000`（含 1 个帧间空闲字） |
| 每包周期字数 | **34** = 33 + 1 空闲 | 同上 |
| 载荷字数/帧 | **29** | `S7_S3_RATE c1_pay per_dclk` → ×(1/0.04595) ≈ 29 ✓；`S7_S5_PAYWORDS_PER_FRAME 29.000002` |
| 帧内容（全 0 载荷档） | 首字 `64'hD5555555555555FB`(c=1) → `64'hFE14FFFFFFFFFFFF` → `64'h00000006829ADDB5` → 29 个全 0 字 → 终止字(`/T/` 在 lane0, c=0xFF) | `rtl/xgmii_rx_chk.v` 的常量 + 40 M 帧零失配；**仿真独立复现**（`sim/tb_pay_sel.v` 的 `TBCASE psel=0 word 18204 d=fe14ffffffffffff`） |
| 帧内容（全 1 载荷档） | 同上，但第 3 字起为全 1：`64'hFFFF0006829ADDB5` → 29×`64'hFFFFFFFFFFFFFFFF` | §10.4（10 M 帧零失配） |
| 线速 | 156.25 M 字/s × 64 bit = **10.000 Gbps** | §5.5 |

## 10.8 下一轮（自写 64 位 XGMII MAC）的**施工要点**（从本轮实测直接得出）

1. **字节序**：MAC 与 PCS 之间**必须**做 §C.2 的 8 字节镜像（TX/RX 各一次）。
2. **RX 时钟**：`rx_core_clk_N` 是**用户输入**（核不产生），必须用 `rx_clk_out_N` 驱动（自环），
   且它是 **CDR 恢复**时钟 ⇒ 与 TX/DP 一律按**异步**处理（`set_clock_groups -asynchronous` 已验证有效，
   `logs/s2_build_FINAL.txt:1806/1808` + Inter Clock Table 为空）。
3. **复位**：RX MAC 用 `user_rx_reset_N`（RX 域）、TX MAC 用 `user_tx_reset_N`（TX-MII 域）；
   `rx_reset_N`/`tx_reset_N` 接 0；`sys_reset` 自己产生（≥10.5 ms POR 实测够）。
4. **`/E/` 与统计**：`/E/` 计数**在块锁建立后再开始**（否则起动瞬态污染判据，§10.2）；
   `valid_ctrl_code` 是电平不是脉冲（§10.5）；`stat_rx_error[7:0]` **没有观测面**（`_valid` 不触发），
   下一轮**不要**把它的"0"当判据。
5. **TX 空闲**：空闲必须**持续**发 `/I/`（全 lane `0x07` + `c = 8'hFF`），一拍都不能停
   （我说 10GBASE-R 需要连续块流；本轮的 ch1 方向就是这么做的，ch0 的接收器 30 M 帧零 `/E/` ✓）。
6. **GT 环回**：调试期可用 `gt_loopback_in_0 = 3'b001`（或 `010`）做**单通道自环**，
   免光纤、免第二通道（§10.1 实测可用 + 负对照）。
7. **别信"隐式网"这个词**：Vivado 2025.2 打 `[Synth 8-11241] undeclared symbol`，
   旧措辞 `implicitly declared` **不会出现**（§10.4 的坑）。新增文件后**必须**用新关键字过门。

## 10.9 未核实清单（第二轮新增）

| # | 未核实项 | 现状 | 怎么补 |
|---|---|---|---|
| U14 | `gt_loopback_in_0` 各编码的**语义**（001/010 可用，但不知是 PCS 级还是 PMA 级、环路点在哪） | 只测到"哪些可用" | 查 UG578（本地没有） |
| U15 | 起动瞬态 `/E/` 的**产生路径** | 已定位到"首帧之前"、非确定性；产生源未确证 | RX 侧 ILA/`mark_debug` 抓上电头 100 µs |
| U16 | `dclk` 的**绝对**频率 | 比值 6×10⁻⁶；绝对只到 ±0.85%（我的墙钟口径与"Y1 = 100 MHz"差 0.85%，差异未定位） | 板外频率计；或把时间戳机制换成硬件触发 |
| U17 | `stat_rx_status/hi_ber/local_fault/framing_err/bad_code/error/fifo_error/valid_ctrl_code` 的**时钟域** | `block_lock` = dclk 实证；其余无脉冲可判别 | 造一个已知脉冲（故意打坏块）重跑双域计数；或 ILA |
| U18 | `[DRC AVAL-326]` 本轮 0 次的**机理** | 规则名/语义/不拦位流 = 已知；"为什么 1 通道会报、2 通道不报"未查清 | 对比两版 netlist 里 IBUFDS_GTE4 的归属 |
| U19 | 副本与厂商原文的**行为等价性**只在 `pay_sel=0` 下验证过（全 0 载荷） | 全 0 档逐位一致（40 M 帧）；全 1 档是新增行为，无厂商对照 | 若要严格，用厂商原文件再跑一遍全 0 档做 A/B（本轮未做——原文件无法选图案） |
| U20 | `stat_rx_error[7:0]` 的**触发条件** | 两轮、两次故意打断、2.3 G 周期都未触发 | 仿真（官方 example tb）或人为造坏码 |

## 10.10 本轮新增/改动的文件（全部在 `_proj_10g/xxv_loop/`）

| 文件 | 作用 |
|---|---|
| `rtl/pcs64_pkt_gen_mon_ds.v` | 厂商明文流量源的**参数化副本**（6 处 diff，§10.4；`pay_sel=0` 等价原文） |
| `rtl/xgmii_rx_chk.v` | 加 `pay_sel` 期望载荷选择、`o_e_pre`/`o_e_post`、`LAST_DW` 订正为 32 |
| `rtl/xxv_loop_top.v` | 加 `vio_gt_loopback[2:0]`/`vio_pay_sel`、双域 `stat_*` 计数器、48 探针打包 |
| `sim/tb_pay_sel.v` + `sim/run_sim_pay.bat` | 只测流量源本身的 xsim 台（**就是它抓到了隐式网**） |
| `tcl/s4..s8,s10_*.tcl` | 只读网表/属性查询（域、通道、IBUFS、FREERUN、fanout） |
| `tcl/s7_probe2.tcl` / `s11_probe3.tcl` + `run_s7/s11.bat` | 第二轮板级会话（48 探针 / 环回 / 60 s 频率） |
| `logs/s7_probe2_FINAL.txt` / `logs/s11_probe3_FINAL.txt` / `logs/s2d_run_output.txt` / `logs/s8_rst_stdout.txt` / `logs/s10_misc_stdout.txt` | 本节引用的全部原始日志 |

## 10.11 本轮**没有**做的

- ❌ 没有写我们的 MAC（仍在做接口合同与 PCS 验证）。
- ❌ 没有动厂商文件（副本是**新文件**；原文件 sha256 未变 `2782d688…b0e03e6`）。
- ❌ 没有 git 写操作；没有碰 QSPI；没有动 license；没有碰 `D:\repo\perfv`。
- ❌ 没有做 `stat_*` 钉常量的负对照（N8），也没有造脉冲确证 `stat_*` 域（U17）。

## 10.12 对第 1 部分的三处**订正**（诚实登记）

| # | 第 1 部分的说法 | 本轮实测后的正确说法 |
|---|---|---|
| 1 | §5.11 括注"8 位计数器是**饱和型**（不回绕），所以只能证'没到 255'" | ❌ **错**。饱和计数器**读 0 = 精确零事件**（只增不减、到 255 封顶）⇒ 当时那句把判据说弱了。本轮又用**32 位不回绕**计数器 + **双域**各计一遍，把 framing/bad_code/fifo 的"0"升级成**精确 0**（§10.5） |
| 2 | §4.4/§6.2 A14"`implicitly declared` = 0 ⇒ 无隐式网" | ⚠️ **门的关键字错了**：Vivado 2025.2 用 `[Synth 8-11241] undeclared symbol`。本轮设计**真的含一个隐式网**（副本的 `pay_sel`）而旧门报 0。已修门 + 修设计；现在报的 10 条**全部来自厂商文件自身**（§10.4） |
| 3 | §5.1 C8"`valid_ctrl_code` 持续增长（控制块在收的正证据）" | ⚠️ **口径要改**：该信号是**电平**（实测两个域都≈每拍为 1，rx 域计数逐数等于时钟数）⇒ 只能当"链路活着时该线为高"。**"控制块真的在收"的精确证据**是 `c0_ctrl`/`c1_ctrl`（我自己的计数器） |
