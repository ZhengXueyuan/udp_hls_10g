# P7B-BIZ 观测面扩充 —— 快照窗口 51 → 61 字 (施工与证据)

- 轮次：**P7B-BIZ**（观测面扩充 agent）。**未上板、未跑 Vivado 全实现**（构建下轮统一做）。
- 交付：`board/wrapper_p4.v` + `_proj_pcie/rtl/axi_regs.v` + 5 个现役脚本 + 1 个 RTL 端口
  （`rtl/app_udp_pattern.v`，**只加端口**）+ 2 个新门 + 本文件。
- 一句话：**窗口 51 → 61 字**（新增 **W51..W60**，全部落在向量 MSB 端 ⇒ 旧字逐项不动），
  并**顺带修掉 3 个"判据结构性无牙"的隐患**（下 §5 的 R1/R2/R3）。
- ⚠️ **本文件是"观测量接线"的记录，不含任何板级读数** —— 新字的读数要等下一轮的位流。

---

## 1. 新槽位表（**完整**；地址 = `0x20 + 4*W`）

| 字 | 地址 | 槽 | 信号（真值源） | 域 | 用途 / 判据 |
|---|---|---|---|---|---|
| **W51** | `0xEC` | dp[12] | `app_pattern.stat_tx_bytes` | dp_clk | TCP 演示 app **下行**载荷字节 |
| **W52** | `0xF0` | dp[13] | `app_pattern.stat_tx_frames` | dp_clk | TCP 下行载荷帧数（几何账） |
| **W53** | `0xF4` | dp[14] | `app_pattern.stat_rx_bytes` | dp_clk | TCP **上行**载荷字节 → J13 |
| **W54** | `0xF8` | dp[15] | `app_pattern.stat_mismatch` | dp_clk | **上行载荷逐字节**失配 → **J12 / `F1-E4b`（R3）** |
| **W55** | `0xFC` | dp[16] | `tcp_tx_frame.stat_retx` | dp_clk | 重传/RTO 回卷**次数** → **`F5b`** |
| **W56** | `0x100` | dp[17] | `app_udp_pattern.stat_tx_ovf` | dp_clk | TX 字 FIFO 拒写（"每帧静默丢 1 整字"的**唯一见证者**） |
| **W57** | `0x104` | dp[18] | `tcp_tx_frame.o_retx_hi` | dp_clk | 回卷重放**上界**（`=1` 会话中有效） |
| **W58** | `0x108` | dp[19] | `tcp_tx_frame.o_retx_active` | dp_clk | 重传/回卷重放会话**进行中**（低 1 位） |
| **W59** | `0x10C` | dp[20] | `slow_tx_adp.stat_fifo_ovf` | dp_clk | u_wf 拒写（恒 0；写门回归守卫） |
| **W60** | `0x110` | dp[21] | `slow_rx_adp.stat_fifo_ovf` | dp_clk | o_ovf 拒写（恒 0；写门回归守卫） |

- **未实现地址 = `0x114`**（= `0x20 + 4*61`，word 69）⇒ 读回 `0xffffffff`（SLVERR 负对照）。
- **W0..W50 的映射与地址逐项未变**（见 §4 的机械核对）。
- ⚠️ **非 `APP_MODE` 构建**：W51..W54 / W56 **恒 0**（源模块不存在）；**W55/W57/W58/W59/W60 仍是真值**
  （源在 `tcp_tx_frame` / `slow_*_adp`，任何构建里都例化）⇒ 读到 0 先确认构建宏。
- ⚠️ **追加 B/C 的口径**：`retx_hi` 只在 `retx_active=1` 时有效；两个 `stat_fifo_ovf` **应当恒 0**，
  非 0 = 又出现静默丢失（与 W35/W56 同族）。

---

## 2. 五处同改 —— 逐处行号（照抄即可核）

| # | 处 | 文件:行 | 本轮值 |
|---|---|---|---|
| ① | 总字数（单一来源） | `board/wrapper_p4.v:3115` | `SNAP_NW_P6E = 61` |
| ② | dp 束槽数（拼接项数） | `board/wrapper_p4.v:3122` | `SNAP_P7BDP_NW = 22` |
| ③ | 读侧选字位宽 | `_proj_pcie/rtl/axi_regs.v:258` | `snap_base [11:0]`（**本轮未动**；max {60,5'b0}=1920 < 4096） |
| ④ | 块内参数 | `board/wrapper_p4.v:3843` | `.SNAP_NW(SNAP_NW_P6E)` |
| ⑤ | **验收脚本的未实现地址** | 见下 4 个脚本 | **`0x114`** |

⑤ 展开（全部**由 `SNAP_WORDS` 派生**，本轮的改动只是把默认字数改掉）：

- `_proj_pcie/p7b_gate4_accept.sh:109` `SNAP_WORDS=${SNAP_WORDS:-61}`
- `_proj_pcie/p6e_snap_check.sh:53` `SNAP_WORDS=${SNAP_WORDS:-61}`
- `_proj_pcie/p7b_gate4_selftest.sh:31` `SW=${SNAP_WORDS:-61}`
- `_proj_pcie/p7b_biz/p7b_snap.sh:33` `NW=${NW:-61}`
- `_proj_10g/notes/p7b_gate4_3/final_state.sh` 的 `rd 0x114` + 新增 `W59/W60` 两读

**读旧位流**（51 字 / 36 字）时用环境覆盖，公式自动跟着走：
`SNAP_WORDS=51 UNIMPL_ADDR=0xEC …` / `SNAP_WORDS=36 UNIMPL_ADDR=0xB0 …`

⚠️ **另加两处"本工程特有"的守卫**（不是"五处"定义的一部分，但扩窗时必须一起跑）：
`_proj_10g/notes/p7b_biz_win/check_window.py`（静态装配核对）与
`…/tb_biz_win.v`（逐字读回）。见 §4。

---

## 3. 拼接项数 / 字数核对（**这里有一个概念陷阱**）

> ⚠️⚠️ **"项数 = 字数" 是错的**。`snap_dout_all` 里 **`snap_dout` 一项就是 36 个字**
> （snap_seq 的 FE14+DP22 两束合成一根线），而 `p7bdp_dout[k*32 +: 32]` 这类**切片**一项才是 1 个字。
> 真正的约束是 **总位数 == `SNAP_NW_P6E × 32`**：少一位 ⇒ 高位悬空（X），多一位 ⇒ 被截断。
> 本轮核对时当场撞上这个陷阱（我先按"项数"写判据，得 22 ≠ 61）⇒ 已把 wrapper 里那条
> **旧注释（"拼接项数必须恰好 SNAP_NW_P6E"）订正为"总字数"口径**。

实测（`check_window.py` 判据 1，逐项字数求和）：

```
项数 = 26        （14 个 p7bdp 切片 + 4 个 txsnap + 3 个 p7bfe + 1 个 snap_dout + 4 个 p7bdp 切片）
逐项字数之和 = 61 = SNAP_NW_P6E ✓
束宽等式: FE14 + DP22 + P7BFE3 + (P7BDP22 − 4 占位) + TX4 = 61 ✓
```

- `p7bdp_din` 的驱动项数：`generate` 12 项（槽 0/1/6..11）+ **显式 assign 10 项**（槽 12..21）= **22** = `SNAP_P7BDP_NW` ✓
- dp 束的槽 2..5 是**占位**（`32'd0`），装配时由 **tx 束**的 4 个字插到 W41..W44 ⇒ 不重复计数。

---

## 4. 验证（**只跑编译面 + 静态面**；本轮不跑全实现）

### 4.1 逐字读回（`tb_biz_win.v`，`SNAP_NW=61`）

- 每个字一个**互不相同**的常数 `32'hB17B_0000 + i` ⇒ 任何错位/回绕/截断都会变成
  "读到了另一个字的正确值"而立刻红。
- **读数：`PASS_ALL tb_biz_win: 26 项判据全过 (窗口 61 字)`**（`xsim_biz.log`）
- 覆盖：57/59/61 字逐字一一对应、相邻字互不相同（证明判据 3 不是"全同值"假门）、
  末字读得到 + **下一个地址恰好 SLVERR**（两侧都判 ⇒ 边界差 1 必被抓）、
  `0x200` 回绕红线的**实测位置**、写 `0x108`/`0x118` **不再别名**到 SCRATCH/SNAP_CTRL（正反对照）。
- **门的牙**（`run_neg.bat`，3 个变异体）：`NEG_GATE_PASS 4/4`
  —— 真文件 PASS；`snap_base` 位宽回退 → **FAIL**（高字静默回绕，症状 `W2 读到 W0 的值`）；
  `ar_word`/`r_word` 回退 6 位 → **FAIL**；`SNAP_LAST_IDX` 差 1 → **FAIL**（末字 + 边界）。

### 4.2 静态装配核对（`check_window.py`，40 项判据）

- **`PASS=40 FAIL=0`**（`CHECK_WINDOW_PASS`）。核的是**装配映射**这一半：
  总字数、最右项 = `snap_dout`(36 字)、束宽等式、**新增项落在 MSB 端且槽号 ↔ 字号一致**、
  `p7bdp_din` 驱动项数、**装配里每个标识符都"先声明后用"**、译码位宽 vs 回绕红线、
  **跨文件一致性**（`app_udp_pattern` 的端口 ↔ wrapper 接线 ↔ `udpapp_tx_ovf` ↔ `biz_w56`；
  两个 `slow_*_adp.stat_fifo_ovf` **没有接反**）。
- **门的牙**（`--mutate`）：`drop`（少一项）/`swap`（新字错位）/`declpatho`（装配里换成未声明网名）
  三种**全部 FAIL**，基线全过 ⇒ 判据不是真空门。
- ⚠️ 这一面**xvlog 抓不到**：实测把装配里的 `biz_w56` 换成不存在的名字，
  **xvlog rc=0、日志一个字都不打印**（未声明的名字是**合法隐式网**）⇒ 只有静态扫描能守。

### 4.3 编译面

- `run_xvlog_wrapper.bat`：`board/wrapper_p4.v` 在 **4 种宏组合**下 **rc=0**
  （`(无)` / `P7B_10G` / `APP_MODE` / `APP_MODE+P7B_10G+PCIE_OBS+DEV_USP+DP_156MHZ+UDP_TX_OVL`），
  xvlog 面判据（`VRFC 10-2989` / `not declared` / `ERROR:`）零命中 ⇒ `XVLOG_WRAPPER_PASS 4/4`。
- `rtl/app_udp_pattern.v`（`-d APP_MODE -d P7B_10G`）**rc=0**、0 条 error（加了 `stat_tx_ovf` 端口后）。
- **未做**：wrapper 级的 `xelab`/`synth_design`（需要 `xdma_0`/`pcs64` 两个 IP 产物；
  `xelab` 只能覆盖到"全部 rtl + 真 wrapper"的那一步，本轮不做构建 ⇒ 留给下轮统一构建）。
  ⇒ 因此**"端口连接形式的静默截断（`VRFC 10-3091`）"这一面本轮无自动化覆盖**（见 §6-R4）。

### 4.4 假板子自证（脚本侧）

`_proj_pcie/p7b_gate4_selftest.sh`（不碰真板）：**`OK=14 BAD=0`**
—— 地址序列**恰好 61 个**（`0x20..0x110` 连续不重复）、末字被读过、未实现地址 `0x114` 被读过、
`0x114` 回真数据 ⇒ 6.1 **FAIL**（负对照：判据有牙）+ 正例整脚本 0 FAIL。
⚠️ 本轮假表里 **`0xEC` 从"未实现地址"变成了窗口内的 W51**（旧版拿它当负对照），已改。

### 4.5 旧字未移位的核对方式（机械，非目测）

`check_window.py` 判据 4：取 `git show HEAD:board/wrapper_p4.v` 的装配项列表（**逐项文本**），
断言它是新表项列表的**尾部**（长度 22 = HEAD 的项数，新增 4 项全在最上面）。
**结论：`[PASS] 4 * 旧字未移位 (HEAD 的项 == 新表的尾部)（HEAD 22 项, 新表 26 项 ⇒ 新增 4 项全在 MSB 端）`**
⇒ 旧项（含 `txsnap_dout[0..3]`、`p7bfe_dout[0..2]`、`snap_dout` 全部）**逐字符未动**。
（W0..W50 的**地址**不变另由判据 5a/1 覆盖：新增项只占槽 12..21。）

---

## 5. 三个"判据结构性无牙"的隐患（本轮顺带修掉的）

| # | 隐患 | 症状 | 修法 |
|---|---|---|---|
| **R1** | **窗口吃满 56 字上限**时读侧 `SLVERR` 负对照**恒不触发**（`SNAP_LAST_IDX` = `r_word` 满量程） | 闸 4 的 B5/G4 从 PASS 静默变"结构性无法评估" | 把 `ar_word`/`w_word`/`r_word` **6 → 7 位**（`araddr[8:2]`）⇒ 上限 56 → **119 字**；< 0x100 的既有地址**逐位等价** |
| **R2** | 旧 6 位译码下**地址每 256 B 回绕**：写 `0x108` 别名到 SCRATCH（= `TX_DIS` 门！）、写 `0x118` 别名到 SNAP_CTRL（**一次误写就触发快照**） | 潜伏；一旦有人用高地址就静默改掉别的东西 | 同上（≥0x100 一律 SLVERR）；TB 判据 8/9 用正反对照钉住 |
| **R3** | `app_pattern`/`app_udp_pattern`/`slow_*_adp` 的拒写计数**只在仿真里可读** | "修好了"只有仿真背书，板级无牙 | 接进窗口（W54/W56/W59/W60） |

---

## 6. 未做 / 风险（**不许混进验收 PASS**）

| # | 项 | 状态 | 理由 / 下一步 |
|---|---|---|---|
| **R4** | **追加 A（`W40` 加宽 + `C8` 的 `pcs_vcc_cyc`）** | **未做** | 它**改的是既有字的位宽语义**（`W40` 现在是 4×8 位饱和计数器；`pcs_vcc_cyc` 8 位 @156.25 MHz ⇒ **1.6 µs 就饱和**）。改它 ⇒ ① 违反本轮已机械验证的"旧字逐项未动"不变量；② **闸 4 的 `C1..C8` 判据表整段需要重导**（那 8 条按 8 位字段解码）⇒ **本轮已登记的 PASS/FAIL 会变**，那是 TL 的裁决，不该由接线 agent 顺手做；③ 需要板级重跑才能重新给 `C8` 定级，而本轮不建位流。**建议**：单独一轮做，做法 = `pcs_ferr_evt/pcs_bad_evt/pcs_erv_evt/pcs_vcc_cyc` 各 8 → **16 位**（`W40` 拆成 2 个字 = 4×16 位，**新增 1 个字**放在 W61），并同步改 `p7b_gate4_accept.sh` 的 C 段解码 + 重跑 C 段。 |
| **R5** | **追加 B 的"重传原因位"** | **部分做** | 已接 `retx_hi`/`retx_active`（**已有的寄存器输出**，零新增状态）。**未接**：能区分 **dup-ACK 快速重传 vs RTO 回卷** 的那个量 —— `tx_retx_req` 是**1 拍脉冲**，快照（采样）**结构性抓不到**，必须**新增一个观测计数器**（`always @(posedge dp_clk) if (tx_retx_req) cnt<=cnt+1`）。那超出本轮"只接现成信号、不新造状态"的边界 ⇒ **留给下一轮**。判据：`Δtx_stat_retx(=W55) > 0` 且 `Δreq_cnt == 0` ⇒ 重复段来自 RTO 回卷（而非快速重传）。 |
| **R6** | `BUILD_ID_V` | **未改（仍 = 7）** | 本轮三路 agent 共改 `wrapper_p4.v` ⇒ 按纪律**在合体时统一自增一次**（建议 7 → **8**）。⚠️ 合体后必须同步 `_proj_pcie/p7b_gate4_accept.sh` 等脚本的 `EXPECT_BID` 默认值（现为 `0x00000007`）。 |
| **R7** | wrapper 级 `xelab`/`synth_design` | 未跑 | 需要 `xdma_0`/`pcs64` IP 产物 ⇒ 属"下轮统一构建"。⇒ `VRFC 10-3091`（端口连接静默截断）这一面**本轮无自动化覆盖**。 |
| **R8** | `snap_dout_all` 的**内容**语义 | 未覆盖 | 本轮的判据 4 只保证**项与顺序未动**；若有人改了 `fe_src`/`dp_src` 的**内部项序**（snap_seq 的索引表），两个新门都看不见 —— 那一面归 `rtl/snap_seq.v` + `tb_snap_seq.v`（本轮未动）。 |

---

## 7. 文件清单

**改（RTL / 顶层）**
- `board/wrapper_p4.v` —— 窗口 51→61；槽 12..21；两个新 localparam；`ar_word` 段注释；装配注释订正
- `_proj_pcie/rtl/axi_regs.v` —— 译码 **6→7 位**（`w_word`/`r_word`/`ar_word`/`snap_idx` + case 标签 + 注释）
- `rtl/app_udp_pattern.v` —— **只加端口** `output reg [31:0] stat_tx_ovf`（删掉同名内部 `reg` 声明；
  修复 agent 的 4 处逻辑改动**一字未动**）

**改（现役脚本，五处同改的 ⑤）**
- `_proj_pcie/p7b_gate4_accept.sh` · `_proj_pcie/p6e_snap_check.sh` ·
  `_proj_pcie/p7b_gate4_selftest.sh` · `_proj_pcie/p7b_biz/p7b_snap.sh` ·
  `_proj_10g/notes/p7b_gate4_3/final_state.sh` · `_proj_pcie/p6b_accept.sh`（注释）

**新（验证件，都在 `_proj_10g/notes/p7b_biz_win/`）**
- **`FINAL_SWEEP.txt`** —— 六项验证的**一次跑全**的输出（本轮结论的快照，2026-09-30 19:26）
- `check_window.py`（静态装配核对，40 判据；`--mutate none|drop|swap|declpatho`）
- `tb_biz_win.v` + `run_tb_biz_win.bat`（逐字读回，26 判据）
- `mk_run_neg.py` + `run_neg.bat` + `neg/`（3 个变异体 + 日志）
- `run_xvlog_wrapper.bat`（4 种宏组合的编译面门）
- `apply_script_updates.py` / `apply_fixups.py` / `apply_b.py` / `apply_c.py`（本轮改动的可复算脚本）
- `work_xvlog/` · `neg/chk_*.log` · `neg/xvlog_patho.log` · `neg/xvlog_appudp.log`（证据）

⚠️ 跑 `p7b_gate4_selftest.sh` 会**重写**它自己的产物目录 `_proj_10g/notes/p7b_gate4_tools/selftest/`
（`addrlog_*` / `addrseq*` / `SUMMARY.txt` / `p6e_snap_check_fake.sh`）—— 那是脚本的既定行为，内容已随窗口变 61 字。
⚠️ `rtl/app_udp_pattern.v` 的 diff 里**大部分是另一位 agent 的修复**（4 处逻辑改动 + 我加的 1 个端口）；本 agent 只加端口。

---

## 8. 本轮踩到并固化的坑（给下一个扩窗的人）

1. **项数 ≠ 字数**（§3）：`snap_dout` 一项 36 字。判"少一项/多一项"必须按**总位数**。
2. **读侧负对照需要留一个空字**：窗口一旦占满 `r_word` 的满量程，SLVERR 判据**结构性失效**；
   而"下一个地址"若超出译码位宽会**回绕别名**（旧红线 ≥0x100，本轮加宽后红线是 **≥0x200**）。
3. **xvlog 对未声明的网名完全沉默**（合法隐式网，rc=0、日志全空）⇒ 静态扫描不可省。
4. **`xvlog ... > xvlog.log` 会撞 xvlog 自己的默认日志名**（`Common 17-183` 句柄冲突）⇒ 换个名字。
5. **`set VAR=value ` 的尾随空格会被 cmd 保留** ⇒ `if "%A%"=="%B%"` 永假（必须 `(set VAR=value)`）。
6. **门/脚本里 FATAL 分支必须计失败** —— 否则"什么都没跑"会被报成 **PASS**（本轮在自研门里踩到两次，
   其中一次是"变异脚本自己重新生成了 .bat，把我手修的 3 处又冲掉了"）。
7. **生成器与产物同源**：`mk_run_neg.py` 生成 `run_neg.bat` ⇒ 对 .bat 的手改必须**回填到生成器**，
   否则下次生成即失效（本轮就是这么丢了 3 处修复、并因此假 PASS 一次）。
