# Gap #9 设计研究：TCP 演示 app（`rtl/app_pattern.v`）拿 8 路并行 —— **设计与代价估计**

- 日期：**2026-10-07**　性质：**纯设计 + 代价估计**。
  ⛔ 本 agent **未改任何 RTL/TB/脚本**：`git status --porcelain rtl/ tb/` = **空**（独立核过；`board/` 下只有 5 份**构建产物**报告
  `*.rpt`/`*.txt` 是上一次构建改写的，非本 agent 所写）；**未烧板**（板子保持受控停流态）；未提交 git。
- 唯一写出的仓内文件 = **本文件**。另在 `%TEMP%\gap9_meas\`（仓外）跑了一次**只读测量**（§1.3），未进仓。
- 依据物：`rtl/app_pattern.v`（工作树 = HEAD `09d2189`，实测 `sha256 b6a9fa0e…b928`，逐行读过）/ `rtl/app_udp_pattern.v`（1094 行）/
  `_proj_10g/notes/P7B_RATE_8WAY.md` · `P7B_WU_TIMING_DELTA.md` · `P7B_WU_BUILD.md` ·
  `P7B_RATE_BUILD.md` · `P7B_RATE_DATAPATH.md` · `P7B_BIZ_{S1,S2}.md` · `P7B_WU_PACE_AUDIT_VERIFY.md` · `P7B_WU_REGRESSION.md`。

---

## 0. 判决（先给要点）

1. ⛔ **订正一条已入库口径**：`app_pattern` 的 TX **不是 "1 B/拍"**，实测是 **0.8 B/拍（8 B / 10 拍）**，
   一帧 **1828 拍/1460 B**（xsim 直接量到，§1.3）。`P7B_BIZ_S1.md:99` / `P7B_BIZ_PLAN.md:139` 的
   "2003 拍/帧 ≈ 1460(生成) + 380(帧器)"**两项都不准**：真分解 = **1828(app) + ~175(帧器非重叠段)**。
   ⇒ app 单独的上界是 **998 Mbps**（不是 1.24 Gbps），板级 911 Mbps 是它与帧器叠加后的结果。
2. RX 侧口径**确认无误**：`8/9 B/拍 = 0.8889 B/拍` ⇒ **1,111.1 Mbps**（实测 1,110.8 = 99.97%）。
3. **两个方向的最优方案不对称**：
   - **RX 便宜且收益大**：1.111 Gbps → **≈9.8 Gbps**（8.8×），**0 新 FF**（R1），且是 `J6-ladder` 的堵点。
   - **TX 收益被帧器锁死**：`tcp_tx_frame` 是**整帧存转发、没做乒乓** ⇒ 天花板 **4.803 Gbps**（380 拍/帧）。
     A1（2 拍/字）≈ **3.25 Gbps**；A2（1 拍/字）≈ **4.80 Gbps**（正好撞帧器）。
4. **建议：先只做 RX，TX 缓；不建议一次做完两个方向**（§6）。
5. **代价（估计）**：≈**0.6–1.1 k LUT**，**0 BRAM / 0 DSP**，FF **+0（R1/A1）或 +77（R2）**；
   时序**结构性风险低**（新锥 ≤4–5 级 LUT，与当前最差族不同源），但**必须由一次构建收口**
   —— DP 域现在只有 **+0.147 ns = 2.3%** 余量，且本流程的重排幅度 **±0.4~1.3 ns**（§4.1）（⛔ 2026-10-09 口径订正：该幅度 = **两个不同网表之间**的位移、样本全落 pcs64/PCIe-GT/pipe_clk 域、**非 DP 域**（推到 DP 是外推）；**同输入重跑 = 位级复现、方差 0**；"必须由一次构建收口"不变；见 `P7B_WU_TIMING_DELTA.md` §8）。

---

## 1. 现状定量（逐行核，两个方向分开写）

域 = `g_hw.clk_out0` = `dp_clk` = **156.25 MHz（6.400 ns）**（`board/wrapper_p4.v:1170-1171`）。
基准记号：`1 B/拍 × 156.25 MHz = 156.25 MB/s = 1.25 Gbps`。

### 1.1 TX 路径（`rtl/app_pattern.v`）——**0.8 B/拍**

逐行：

| 行 | 代码 | 语义 |
|---|---|---|
| `:267` | `gen_byte = bad_frm ? 8'hA5 : tx_lfsr[31:24]` | **每拍只产 1 个字节** |
| `:268` | `gen_en = asm_go && (bcnt < need)` | 每拍最多推进 1 字节 |
| `:269-270` | `stg_n = {stg[55:0], gen_byte}`；`asm_full = asm_go && (bcnt==need)` | 顺序装进 64 位移位寄存器 |
| `:223` | `need = (left>=8) ? 8 : left[3:0]` | 一个字最多 8 字节 |
| `:263-264` | `asm_go = active && **!pw_valid** && !closing && !frm_wait && !op_pend && (…)` | **呈交寄存器 `pw_valid` 期间装配停摆** |
| `:500-508` | `asm_full` ⇒ 装载 `pw_data/pw_keep/pw_n/pw_last`、`pw_valid<=1` | **1 拍** |
| `:511-521` | `pw_valid && m_tready` ⇒ 消费、`seg_sent += pw_n`、`remain -= pw_n` | **1 拍**（消费拍 `asm_go` 仍为 0） |
| `:307-311` | `m_*` = `op_beat / pw_data / close_send` 三选一的**纯组合输出** | （头注释明确禁止寄存器化） |
| `:195` | `tx_ok = app_tx_ready[act_id]` | 只挡"起新帧"（`:450/:479`），不挡帧内续传 |

**算式（下游 `m_tready` 恒 1）**：

```
满字   = 8(填充) + 1(asm_full 装载) + 1(呈交并消费)   = 10 拍 / 8 B  ⇒ 0.8 B/拍
尾字   = k(填充) + 1 + 1                            （k<8）
一帧   = 1(opener) + 182×10 + (4+1+1) + 1(收帧)      = 1828 拍 / 1460 B
```

（`1460 = 182×8 + 4`；opener/收帧见 `:227`、`:436-443`。）

⇒ **app 单独上界 = 1460/1828 = 0.7987 B/拍 × 156.25 MHz = 124.8 MB/s = 998.4 Mbps**。

**与板级读数的合成**（这是"现状"真正的那一格）：
`tcp_tx_frame` 是整帧存转发，`s_axis_tready` 只在 `S_IDLE/S_RECV` 有效 ⇒ 帧周期 ≈ **app 生成 + 帧器非重叠段**：

```
P(c) ≈ 197 + 182·c          （c = app 每字拍数；197 = S_WAIT5+S_HDR6+S_PAY183+S_TAIL1+S_DONE1+arb1）
   锚1: c=1  ⇒ 380 拍/帧  ← RATE_DATAPATH 仿真实测（tcp_tx_frame 本体，4.803 Gbps）
   锚2: c=10 ⇒ 2017 拍/帧 ← 板级实测 2003（差 +0.7%），即 Stage 1 的 78,001 fps
```

⇒ 板级 2003 拍/帧 → `1460 B / 2003 拍 = 0.729 B/拍 = 113.9 MB/s` = **911 Mbps（板侧）/ 903.7 Mbps（socket）** ✓ 与 `P7B_BIZ_S1.md` 逐数吻合。
⇒ **帧器只吃掉 8.7%**：app 生成占 1828/2003 = **91.3%**。⇒ 抬 TX 的收益上限 = 抬掉这 91.3%。

### 1.2 RX 路径（`rtl/app_pattern.v`）——**8/9 B/拍**

| 行 | 代码 | 语义 |
|---|---|---|
| `:280` | `assign rx_tready = (rxs == 2'd0);` | **只在"取值态"收字**（与比较态结构性互斥） |
| `:524-536` | `rxs==0 && rx_tvalid` ⇒ 锁存 `rw_data/rw_keep/rw_n=pop8(rx_tkeep)` | **1 拍/字** |
| `:537-544` | `rxs==1` ⇒ 每拍比 **1** 字节（`byte_at(rw_data,rw_i)` vs `rx_lfsr[31:24]`），推进 `rx_lfsr`/`stat_rx_bytes` | **N 拍/字** |

```
满字 = 1(取值) + 8(逐字节比) = 9 拍 / 8 B ⇒ 0.8889 B/拍
```

⇒ **结构上界 = 8/9 × 156.25 MHz = 138.889 MB/s = 1,111.1 Mbps**。
⇒ 实测：Stage 1 稳态 **1,110.8 Mbps = 99.97%**（`P7B_WU_PACE_AUDIT_VERIFY.md` §2.4）⇒ **TCP 上行确实被本校验器钉死**。
（残段口径：1460 B 段 = 182 满字 + 1 个 4 B 尾字 = 182×9 + (1+4) = 1643 拍 ⇒ 同 0.8889 B/拍。）

### 1.3 ⭐ 本节两个数字的**直接测量**（仓外 scratch，xsim 156.25 MHz，可复现）

```bash
# 只读：把 rtl/app_pattern.v 复制到 %TEMP%\gap9_meas\（仓内一字未改），另写一个 scratch TB
# cwd = C:\Users\zhxue\AppData\Local\Temp\gap9_meas\   {app_pattern.v, tb_meas.v}
cmd //c 'C:\AMDDesignTools\2025.2\Vivado\bin\xvlog.bat -work xil_defaultlib app_pattern.v tb_meas.v'
cmd //c 'C:\AMDDesignTools\2025.2\Vivado\bin\xelab.bat xil_defaultlib.tb_meas -s tb_meas'
cmd //c 'C:\AMDDesignTools\2025.2\Vivado\bin\xsim.bat  tb_meas -runall'
# TB 本体：rst → 恒 rx_tvalid/rx_tkeep=FF 喂 1000 个满字 → 量 dcyc/dbytes；
#          再 ev_up 一次会话（TX_BYTES=1MB, TX_SEGSZ=1460, m_tready≡1）→ 量帧 2→22 的 dcyc/dbeats/dbytes
```

```
RX: bytes 0 -> 8000  dcyc=9002  B/cyc=0.888691  cyc/word=9.002        （恒 rx_tvalid=1、满字 tkeep）
TX: frames 2 -> 22   dcyc=36560 dbeats=3680 dbytes=29200
    cyc/frame=1828.000  beats/frame=184.000  B/cyc=0.798687          （m_tready ≡ 1、TX_SEGSZ=1460）
```
⇒ TX/RX 两条算式被**独立复现到小数点后三位**（1828.000 / 0.798687；8/9 精确）。
⇒ 顺带：旧门 `sim/p5sim/run_tb_p5_pattern.bat` 的留存日志
`sim/p5wu_regress/p5_pattern_stdout.log` 里 `W3 case1: beats 40`（≈400 拍后 40 个 beat）**同款吻合 10 拍/字**。

---

## 2. 对照组解剖：RATE 轮对 UDP 版**具体改了什么**，哪些能照抄

对照件 = `rtl/app_udp_pattern.v`（8 路包在**既有宏 `P7B_10G`** 内；`grep -c P7B_10G` = 21）。
原件 = `P7B_RATE_8WAY.md` §1.2 的 9 处改动表（行号为**改动后**；本文件行号按**现役 1094 行**重核）。

| # | UDP 版改动的落点（现役行号） | 内容 | **TCP 版能不能照抄** |
|---|---|---|---|
| 1 | `:235`–`:394`（`ifdef` 块内） | 新增函数 `xs_next8`（M^8·s，`:249-317`）+ `xs_word8`（8 个连续输出字节，`:319-394`），**常量 XOR 网**（平均 21.8 项/最多 34 项 ⇒ ≤3 级 LUT6；级联写法要 24 级） | ✅ **逐字可搬**。两文件的图案语义同源（同 SEED、`byte_at(lane0)=[63:56]`、先取后推进），生成器 `p7b_rate8/gen_mat8.py` 自带三条自校验。**唯一要求**：`ifdef P7B_10G` 包住 |
| 2 | `:559-563` | TX 线网 `tx_lfsr_8 = xs_next8(tx_lfsr)` / `gen_word = pay_ok ? xs_word8(tx_lfsr) : 64'hA5…` / `wide_ok = gen_ok && (left>=8)` | ⚠️ **半照抄**。`left>=8`、常数 0xA5 填充同款；但门是 UDP 的 `gen_ok`（`txs==T_FRM && !txf_full_n && !nul_pend && seg_sent<seg_len`），TCP 的对应门是 `asm_go`（含 `!op_pend/!frm_wait/!closing`），**必须换锚**；冻结条件 UDP 是 `pay_ok`、TCP 是 `!bad_frm` |
| 3 | `:566` | `frm_close = (push_now \|\| wide_ok) ? last_b : nul_push`——帧收尾判据加 `wide_ok` | ❌ **不能照抄**。TCP 版**没有推送侧**：帧收尾在 `:436-443` 的 `need==0` 分支，判据是 `seg_sent == seg_len`，由**消费**推进（`:513`），不是"推入 FIFO 那拍" |
| 4 | `:813-828` | `T_FRM` 里新增第一条分支 `if (wide_ok) …`（同期推 8 B + 推进 `seg_sent/stat_tx_bytes/remain`） | ❌ **不能照抄**（见 §2.1-a）。UDP 是"字节→stg→**同拍推 FIFO**（零气泡）"；TCP 是"字节→stg→**呈交寄存器**→下一拍消费"，**多 1 拍结构性气泡**，这正是 TCP 现状 0.8 B/拍而 UDP 现状 1 B/拍的根源 |
| 5 | `:626-658` | RX 宽路径：`rx_exp_word=xs_word8(rx_lfsr)` / `rx_lfsr_8` / `wide_cmp = cmp_busy && cmp_n==8 && cmp_i==0` / `rx_bad_v[8]` / `rx_bad_n=pop8(…)` / `cmp_ld_w` / `rx_tready = !nx_v \|\| cmp_ld_w` | ⚠️ **半照抄**：期望序列 + 8 lane 比较 + popcount **可照抄**（同约定）；`cmp_ld_w` 与 `!nx_v` 那半**不能照抄**（TCP 版**根本没有 nx 前瞻寄存器**，见 §2.1-b） |
| 6 | `:889/:908/:934` | 三处消费分支 `nx_v <= rx_ld`（**本轮唯一结构性缺陷的修法**：放宽 `rx_tready` 打破"同拍互斥"后，新装进 nx 的字会被 `nx_v<=0` 静默丢弃） | ❌ **不适用**（无 nx）。⚠️ 但**同型陷阱存在**：TCP 版若把 `rx_tready` 放宽成"消费拍也收字"，必须保证当拍锁存的 `rw_*` 不被同拍覆写（§3-R1 的设计里它天然成立） |
| 7 | `:936 / :944 / :950` | `rx_lfsr <= rx_lfsr_8` / `stat_rx_bytes += 8` / `stat_mismatch += {28'b0,rx_bad_n}` | ✅ **可照抄**（同口径：都是"每字节"账，不是"每拍"） |
| 8 | `:632-635` | `RXP_DIAG` 并存时宽 RX **主动关闭**（仪器是逐字节量） | ❌ **不适用**（TCP 版无 diag 仪器、无 `RXP_DIAG`） |
| 9 | `:611-612 / :658` | `rx_tready` 的定义位置搬进宽块（因要用 `cmp_ld_w`；坑 22：xvlog 先声明后用） | ⚠️ **形态可照抄**（TCP 版也要把 `:280` 那行搬进宽块/或就地扩项） |

### 2.1 三个方向**结构性不能照抄**的地方（这是本节的要点）

**a. 呈交寄存器 `pw_valid`（TCP 独有）**
`m_*` 是"`op_beat` / `pw_data` / `close_send` 三选一"的纯组合输出（`:307-311`），而 `pw_data` 是**已在呈交的字**；
`asm_go` 因此被 `!pw_valid` 挡住 ⇒ **每字恒定 2 拍开销**（装载 + 消费）。UDP 版没有这层：
它把字节装在 `stg`，凑齐**同拍**送 FIFO（`push_now`），所以"1 拍 1 字"是免费的。
⇒ TCP 版要达到 1 拍/字，必须先解决这个气泡（§3 的 A1/A2），**不能靠照抄**。
⚠️ 这层寄存器挂着**整套已收口的语义**：`drop_pw`（`:242`）/`close_send`（`:243-245`）/`ev_restart` 撞车（`:253-256`）/
`rst_close`（`:255-256`）。**动它 = 动这些判据的前提**。

**b. RX 侧没有前瞻寄存器**
UDP 的宽 RX 之所以要 `cmp_ld_w` + `nx_v <= rx_ld`，是因为它的管线是 `rx → nx(前瞻) → cmp(比较)`。
TCP 版是 `rx → rw_*(取值态锁存) → 逐字节比`，**只有一级**；`rx_tready = (rxs==0)` 的"同拍互斥"是另一条线。
⇒ TCP 版**不需要**自增一级流水，但也**不能**把 UDP 的 `cmp_*` 判据搬过来（没有 `cmp_*`）。

**c. 帧边界语义与守卫是 TCP 独有**
- **0 载荷 opener**（`:227`、`:490-498`）：每帧首字 `tkeep=0/tlast=0`，是 P5e 对"跨会话载荷泄漏"的**结构性**根除。宽路径与它共存时，"一个帧的第一拍"仍然必须是 opener，不是载荷字。
- **W3 收尾**（`:409-432`）+ `ev_restart`（`:253-256`）：`ev_down/ev_up` 落在帧中途时必须闭合帧（补 tlast）。放宽 `asm_go`（A2）时**必须重新论证 `op_beat`/`close_send` 的互斥**（`:305-306` 的注释就是靠 `!closing` 与 `pw_valid` 撑起来的）。
- **`tid` = `act_id`**（`:311`）与 **`tx_ok = app_tx_ready[act_id]`**（`:195`，16:1 mux）：宽路径**不能绕过** `asm_go` 的这层门（P5d-D2 的"帧启动门"）。
- **长度守卫 / 坏帧注入**：`seg_len` 由 `TX_SEGSZ=1460` + 末帧余数决定（`:385-386/:454-456`），
  `bad_frm`（`BAD_LEN=2000 > PLEN_MAX`）期间 **LFSR 冻结 + 载荷常数 0xA5**（`:267`、`:473`），
  保证"被丢弃的帧不留图案空洞"（坑 23）。宽路径必须逐条保持（UDP 版对应物是 `pay_ok` + `0xA5` 填充）。

---

## 3. 设计：TCP 版的 8 路并行

共同前提：所有新逻辑包在**既有宏 `P7B_10G`** 内；未定义时**逐字节等于今天**（预处理器机器证明，见 §4.3）。

### 3.1 TX —— 方案 A1（**2 拍/字**，改动最小）

**改哪一块**：`:470-474` 的填充分支（`else if (bcnt < need)`）**前面**接一条单拍装载分支：

```verilog
wire [63:0] tx_lfsr_8 = xs_next8(tx_lfsr);
wire [63:0] gen_word  = bad_frm ? 64'hA5A5A5A5A5A5A5A5 : xs_word8(tx_lfsr);
// …在原 `if (asm_go)` 里（`asm_go` 的六项门一字不动，含 !pw_valid/!op_pend/!closing/!frm_wait）：
if (asm_go) begin
    if (need == 4'd8) begin              // 新增首分支: 1 拍装载整个满字
        pw_data  <= gen_word;  pw_keep <= 8'hFF;  pw_n <= 4'd8;
        pw_last  <= ((seg_sent + 12'd8) >= seg_len);
        pw_valid <= 1'b1;    bcnt <= 4'd0;  stg <= 64'd0;
        if (!bad_frm) tx_lfsr <= tx_lfsr_8;   // 坏帧冻结（同逐字节路径）
    end else if (need == 4'd0) begin … 原收帧分支 … end
      else if (bcnt < need)     begin … 原逐字节分支（尾字专用）… end
end
```

**边界/对齐**：新分支只在 `need==8`（⇔ `left>=8`）成立 ⇒ **尾字（<8 B）自动回落原逐字节路径**，非 8 倍数载荷结构性正确
（UDP 轮的 T1–T6 门已证明该配方的正确性）；`opener/W3 收尾/close_send` 全部不动（新分支在 `if (asm_go)` 之内，
而 `asm_go` 的六项门一字未改）。
**`tid`/长度守卫**：不新增任何判据，`seg_sent/remain/stat_tx_bytes` 仍在**消费拍**推进（口径不变）。

拍/帧：`1 + 182×2 + 6 + 1 = **372** 拍/帧` ⇒ app 单独 4.90 Gbps；**端到端 P ≈ 197+182×2 = 561 拍 ⇒ 3.25 Gbps**。

### 3.2 TX —— 方案 A2（**1 拍/字**，撞帧器天花板）

在 A1 基础上再消掉"消费拍不能装载"的气泡：`asm_go` 的 `!pw_valid` 放宽为 `(!pw_valid || m_tready)`，
并把本字的 `need/left/pw_last` 判据改用**前瞻量** `seg_sent + pw_n`（同拍消费的字节数先计入），
装载块写作后置（同拍双写时"装载"赢）。

拍/帧：`1 + 182×1 + 6 + 1 = **190**` 拍（app 单独 9.8 Gbps）；**端到端 P ≈ 379 拍 ⇒ 4.80 Gbps = 帧器天花板**。
⚠️ **风险高于 A1**：它改的是"帧边界算账"的基准（`seg_sent`），而 opener/W3/`ev_restart`/`frm_wait` 都建立在该基准上。
⇒ 必须补一组"帧边界"专项负对照（§4.3-3）。

### 3.3 RX —— 方案 R1（**1 拍/字，0 新 FF**，推荐）

**改哪一块**：`:524-536` 的取值分支加一条"满字当拍比完"：

```verilog
wire [63:0] rx_exp_word = xs_word8(rx_lfsr);
wire [63:0] rx_lfsr_8   = xs_next8(rx_lfsr);
wire [7:0]  rx_bad_v;                       // 逐 lane 失配
assign rx_bad_v[0] = (rx_tdata[63:56] !== rx_exp_word[63:56]);   // …8 条同款
wire [3:0]  rx_bad_n = pop8(rx_bad_v);
wire        rx_wide  = (rxs == 2'd0) && rx_tvalid && (pop8(rx_tkeep) == 4'd8);
// …在 always 里（rxs==0 分支内，rx_wide 时；原 `rxs <= 1` 被旁路）：
    stat_mismatch <= stat_mismatch + {28'b0, rx_bad_n};
    stat_rx_bytes <= stat_rx_bytes + 32'd8;
    rx_lfsr       <= rx_lfsr_8;
// rxs 保持 0、rx_tready 保持 1 ⇒ 背靠背 1 拍/字；rw_* 照旧锁存（回落路径要用）
```

**边界/对齐**：`pop8(rx_tkeep)==8` 才走宽路径；**尾字/0 长字自动回落** `1 + N` 逐字节路径（LFSR 按字节推进，
与现有语义一致）。**`tid`**：`rx_tid` 本来就没被消费（`:558-559`），无需处理。
**per-connection 复位**（`:341-343` 的 `ev_up ⇒ rx_lfsr<=SEED, rxs<=0`）一字不动。
**代价**：**0 新 FF**；新增组合锥 `rx_tdata/rx_lfsr → xs_word8/比较 → popcount → stat_mismatch`（~5–7 级）。
拍/帧（1460 B 段）：`182 + (1+4) = 187` 拍 ⇒ **7.81 B/拍 = 1.22 GB/s = 9.76 Gbps**（8 倍数载荷时 8 B/拍 = 10 Gbps）。

### 3.4 RX —— 方案 R2（照搬 UDP 结构，+1 级流水）

加 `nx_d/nx_k/nx_n/nx_v`（77 FF）+ `cmp_d/cmp_n/cmp_i`，`rx_tready = !nx_v || cmp_ld_w`，三处 `nx_v <= rx_ld`。
拍/帧与 R1 相同（**8 B/拍**），差别只在**时序形态**：新逻辑全是寄存器→寄存器，`rx_tdata` 的接收路径与
`rx_lfsr` 的比较锥**解耦**。**优点**：与已板级验证过的 UDP 版**逐字同构**（有先例、可对拍）；
**缺点**：+77 FF、多一级延迟（对本 app 无功能影响），且 `nx_v <= rx_ld` 那个坑必须一并搬对。

> **第三档（只列不推）**：RX 做成 4 B/拍（`rxs==1` 里一次比 4 lane）⇒ 1460 B 段 369 拍 = 3.96 B/拍 = 4.94 Gbps。
> 收益只有 R1 的一半，复杂度不低 ⇒ **不推荐**：RX 侧没有"中间档有用"的场景（它不是流水线瓶颈，是纯吞吐）。

---

## 4. 代价估计

### 4.1 时序（**关键**）

**现状（`P7B_WU_TIMING_DELTA.md` §1/§5，逐字核过）**：
- 数据面域 `g_hw.clk_out0` **现在就是全局最差**：**WNS +0.147 ns = 周期 6.400 的 2.30%**；`WHS +0.010`；三类失败端点 **0/0/0**。
- 该域**前 10 条里有 6 条同源**（`u_app_udp/u_txf/dout_reg[68]/C` → `u_udp_tx/ip_csum_r_reg[..]/D`，**0.147–0.229**）；
  这条 20 级逻辑（CARRY8×6）/ route 55.5% 的路径**不是孤点，是簇**。
- 域内历史：RATE **+0.295** → BIZ **+0.192** → WU **+0.147**（−0.103 / −0.045）。

**新增逻辑落在哪**：`tx_lfsr → xs_next8/xs_word8 → pw_data`（A1/A2）、
`rw_data|rx_tdata + rx_lfsr → xs_word8 → 8 比较 → popcount → stat_mismatch`（R1/R2）、
`tx_lfsr → xs_word8 → m_tdata → axis_pipe(寄存器)`（A2 可选形态）。
**全部 ≤4–5 级 LUT、终点都是寄存器**。

**有没有结构性理由说"它进不了最差族"——有，但只能说"不直接"**：
① 当前最差族的**源**是 `app_udp_pattern` 的 TX 字 FIFO `dout`，**终点**是 `udp_tx_frame` 的 `plen/ip_csum` 锥；
新逻辑既不读那条 FIFO、也不驱动那个锥，两个模块之间除共享时钟外**无共享逻辑** ⇒ 不构成同一族。
② **同源先例（同类逻辑的实际读数）**：RATE 轮把 **2,283 项 XOR + 8 lane 比较**加进 `app_udp_pattern`，
数据面域 WNS **+0.128 → +0.295（变好 +0.167）**，全局 WNS **+0.128 → +0.136**；
代价落在**别的域**（`txoutclk_out[0]_3` −0.624，归因 = "DP 域 +3,783 端点/+1,632 LUT 改布局压力"）。
⚠️ 但要如实说：**"结构无关"不等于"不会进最差族"** —— WU 轮已实测本流程的**重排幅度**：
同一物理路径两轮之间移动 **−0.591…+1.302 ns**，同一条时钟网（两端 SITE 固定）延迟 **+0.424 ns**，
`async_default` 两族在"窗口没动"的情况下自己动 **+0.419**。（⛔ 口径订正见 `P7B_WU_TIMING_DELTA.md` §8：该幅度 = **两个不同网表之间**的位移、样本全落 pcs64/PCIe-GT/pipe_clk 域；**同输入重跑 = 位级复现、方差 0**。）
⇒ **估计（不是结论）**：新增逻辑**自身**不会成为数据面最差（深度差 4–5 倍）；
风险在**重排**，量级 ±0.1 ns 级（历史两次域内变动 −0.103 / −0.045 都不是新逻辑族）。
**收口判据（必须由一次构建给）**：三类失败端点 `0/0/0` + WNS>0 + **新 `u_app` 锥不进数据面域前 10**。
- 附：本改动**不碰快照窗**，所以**不叠加**那两条已知薄处（`async_default` pcie 0.496 / DP 0.743）。
- 附：hold 侧 `WHS +0.010` 本来就薄 —— 新逻辑**没有新增时钟域**、没有新跨域路径 ⇒ 不新增 hold 风险源。

### 4.2 面积（**估计**，依据 = UDP 版同类改动的实测增量）

| 项 | 估计 | 依据 |
|---|---|---|
| `xs_next8` + `xs_word8` 常量 XOR 网 | **≈550–650 LUT6** | 2,283 项 XOR（M^8 1,392 + 字节行 891），每输出 ≤34 项/≤3 级；UDP 版估"~1 K LUT"（`P7B_RATE_8WAY.md` §4.2） |
| RX 8 lane 比较 + popcount + 加法 | **≈80–120 LUT6** | 64 个 XOR 对 + 8 输入 OR + 32 位加 |
| **合计 CLB LUT** | **≈0.6–1.1 k** | 同量级锚：RATE 轮**合并**增量 +1,632 LUT，其中乒乓第二份 FIFO ≈+579 ⇒ **8 路部分 ≈+1,050**（我做的减法，报告本身没分解，故按上界读） |
| FF | **+0**（A1/R1）· **+77**（R2：nx_d64+nx_k8+nx_n4+nx_v1）· A2 +0 | 8 路本身是纯组合；UDP 版也没加 FF |
| BRAM / URAM / DSP | **+0 / +0 / +0** | 纯组合 + 少量 FF；对照 RATE 轮 BRAM 三类**逐数不变** |
| 占全局（现役构建 `P7B_WU_BUILD.md` §4） | LUT 71,238/216,960 = **32.83%** ⇒ +1 k ≈ **+0.5 个百分点**；BRAM **348/480 = 72.50%**（最紧资源，本改动**不碰**） | —— |

### 4.3 验证成本（本工程口径：UDP 轮用"逐字节等价五重证据"）

**必须新写**：
1. **逐字节等价门（核心）**——仿 `_proj_10g/notes/p7b_rate8/sim/{tb_app8_equiv.v,run_app8_gate.bat}`（同 TB 两宏各跑一次，
   dump TX 载荷字节流 + **每帧字节数** → `fc /b`）。配置至少覆盖：`1460`（182×8+4，**非 8 倍数**）、`1472`（8 的倍数）、
   `len<8`（全尾字）、`1501`（>PLEN_MAX ⇒ 冻结+0xA5）、`TX_BYTES` 非 8 倍数（末帧余数）、带伪随机背压。
   **RX 侧注入式**：满字 lane1/lane7 翻位**必须恰好计 1**；尾字**无效 lane** 翻位**必须不抓**；0 长字。
2. **独立复算**：`peer.exe --pat-selftest` oracle + Python 重写递推 + 两构建 dump 三方互证（脚本先例 `check_dump.py`）。
3. **变异负对照（必须变红）**：C = `xs_next8` 退化成 `xs_next`（dump 必须不同）；D = RX 只比 lane0（注入门必须抓）。
   **A2 追加**：E = 前瞻量写错一格（`seg_sent` vs `seg_sent+pw_n`）⇒ "每帧字节数"判据必须抓到帧边界错位。
4. **拍/帧门**：仿 `run_rate8.bat`，量"下游恒 ready"的拍/帧（预期 TX 372(A1)/190(A2)、RX 187）——
   这是把 §5 的预测变成读数的那一格。
5. **默认构建等价证明**：预处理器断言"无 `P7B_10G` ⇒ 与改动前源码逐字节相同"（`apply_wide.py` 的机器证明形态；
   ⚠️ **不能沿用 UDP 的 `.orig`**，要为本文件重新取基线）。
6. **真 wrapper 门**：`sim/p5sim/run_tb_p5_wrapper.bat`（宏两态各跑；⚠️ 既存红 1 项）。

**必须重跑（有判别力的既有门）**：`sim/p5sim/run_tb_p5_app.bat`(+`close`)、`run_tb_p5_adv.bat`(5 档)、`run_tb_p5_fc.bat`、
`run_tb_p5_flow.bat`、`sim/p5d_multi/run_tb_p5_multi.bat main`(122 检查)、`sim/p5d_d1/`、`sim/p5e_win/`、`sim/p5close/`。
⚠️ **四条既存红**（`p5_wrapper` / `p5e_t2_wrapper` errs=117 / `p5e_udp_wrapper` errs=1489 / `p5_app close` 两项常量陈旧）
必须**逐数**与基线对照后才允许登记"新红"（`P7B_WU_REGRESSION.md` §3）。
⚠️ `sim/p5sim/run_tb_p5_pattern.bat` 是**哑门**（findstr-only、恒 exit 0，TB 自报 `keep_bad=1` 是 P5e opener 之后的**陈旧判据**）
⇒ 要拿它当判据**先修门**。
⚠️ **P4 矩阵 16 门对本改动没有判别力**：5 个 manifest 都不含本文件（**我实测** `grep -c app_pattern sim/p4gates/*_src.f` = `0/0/0/0/0`）⇒ 跑了不等于证了。

---

## 5. 收益与边界

| 方向 | 现状（实测） | 现状结构上界 | **A1 / R1** | **A2 / R1** |
|---|---|---|---|---|
| TCP **下行**（板→对端） | **903.7 Mbps/连接**（板侧 78,001 fps / 2003 拍/帧） | 998.4 Mbps（app 单独）· 911 Mbps（板侧端到端） | **≈3.25 Gbps**（P=561 拍） | **≈4.80 Gbps**（P=379 拍，**= 帧器天花板**） |
| TCP **上行**（对端→板） | **1,110.8 Mbps**（= 结构值 99.97%） | **1,111.1 Mbps**（8/9 B/拍） | **≈9.76 Gbps**（1460 B 段，7.81 B/拍） | 同左（8 倍数载荷 10 Gbps） |

（下行端到端用 §1.1 的 `P(c) = 197 + 182·c`；上限锚 = `tcp_tx_frame` 自报 380 拍/帧 = 4.803 Gbps。）

**边界三条（必须一起读）**：
1. ⚠️ **这只是演示 app 的天花板**。真实业务的上限由**用户自己的 app** 决定 —— 板内数据面已能跑
   **8.4 Gbps 上行**（Stage 2 四进程洪泛：板侧 `ΔW0 = 1,769,731`、线上 8.38 Gbps、板侧丢帧计数全 0）。
   ⚠️ **精度**：那次打的是 **9999 非 app 口**、`ΔW19 = 1,762,431`（99.4% 被慢路径按设计丢弃）
   ⇒ 它证的是**前端/MAC 的接收能力**，**不是** app 通路的消费能力；**app 通路 >1.11 Gbps 从未测过**。
2. ⚠️ **下行 4.80 Gbps 是 `tcp_tx_frame`（整帧存转发、无乒乓）的天花板**，8 路并行**不解决**这一格
   （UDP 侧已用 `UDP_TX_OVL` 打成 191 拍；TCP 帧器没做 = `P7B_BIZ_PLAN.md` §8-f，4.803 → ~9.5 Gbps）。
   ⇒ A2 做到 1 拍/字也只是把 app 顶到帧器上。
3. ⚠️ **未核的第二道帽**：单连接在飞字节受窗口约束，`速率 ≈ W / RTT`。**RTT 我没有 10G 业务路径上的可信值**，
   两个候选差两个量级 ⇒ **只能登记为未测**：① 对端 `ss` 记的 `minrtt:0.008`（**8 µs**，Stage 2 上行日志）⇒ `49152/8 µs = 6.1 GB/s`（不成帽）；
   ② 1G ETH 通路 `ping` 的 **0.128 ms**（P6e）⇒ `49152 B/0.128 ms ≈ 3.07 Gbps`（会成为帽）。
   ⇒ 需要**现取**的 `ss -ti` 带 pace 读数才能定这一格；`wu` 缺陷本身也会压上行（见下条 4）。
4. 与 `wu` 的关系：RX 抬到 ~9.8 Gbps 后，`J6-ladder` 的顶档（`1000e6 B/s` = 8 Gbps）**才可能被评估**；
   在那之前它结构性不可达（现上界 1.111 Gbps）。⇒ RX 这一半是**判据的解锁件**，不是"美观件"。

---

## 6. 建议

**做 RX（R1），先单做；TX 缓做或与帧器乒乓打包。**

理由（RX 先）：
1. **它是判据的堵点**：`J6-ladder`（`P7B_BIZ_PLAN.md` §4.1b）的上界现在就是 app 的 1.111 Gbps
   ⇒ 不抬 RX，`wu` 修复的效果**无法在 >1.11 Gbps 上被观测**（而现在 Stage 1 已贴到 99.97%，
   "还差多少"这一格永远读不出来）。
2. **结构最简单**：TCP 的 RX 没有呈交寄存器/opener/W3/tlast 语义，宽路径配方只需在 `rxs==0` 加一处分支，
   **0 新 FF**（R1）；且 `rx_tready` 的数据无关性不变（不收窄背压合同）。
3. **收益最大**：1.111 → ≈9.76 Gbps（**8.8×**），且代价是**估计 0.6–1.1 k LUT + 0 BRAM**。

理由（TX 缓）：
- A1 的 3.25 Gbps 会被帧器的 4.80 Gbps 挡着；A2 的 4.80 Gbps 也正好是帧器**天花板** ⇒ **真正抬下行的杠杆是帧器乒乓**，
  不是 app。只做 A2（不动帧器）= 收益 <2× 且要动 `seg_sent` 基准（opener/W3/`ev_restart` 的前提）。
- ⇒ 若同批做，用 **A1**（不动互斥语义）；**A2 与 `tcp_tx_frame` 乒乓合成一个"下行批次"**，一起落地一起测。

**不建议**：TX+RX 一次做完。两个方向风险面不同（RX 纯组合、TX 动帧边界算账），同批落地会把
"哪一半引入的问题"糊在一起（本工程已有"修复会曝光既有隐患"的先例，坑 20）。
而且这一格**不阻断任何产品级判据** —— 快路径 8.4 Gbps 已达标，Gap #9 卡住的只是**演示 app 的天花板与判据值域**。

---

## 7. 我核过什么 / 没核什么（纪律登记）

**核过（可复核）**：`rtl/app_pattern.v` TX/RX 两条路径逐行；UDP 版 9 处改动的现役行号（`grep -n` 逐个定位）；
TX 1828 拍/帧 与 RX 8/9 B/拍 的**直接 xsim 复现**（仓外 scratch，§1.3）；`tcp_tx_frame` 380 拍/帧的结构分解
（`P7B_RATE_DATAPATH.md:76`）；DP 域 WNS/端点数/路径明细（`P7B_WU_TIMING_DELTA.md` + `P7B_WU_BUILD.md`）；
面积口径（`P7B_WU_BUILD.md` §4 / `P7B_RATE_BUILD.md` §4.1）；P4 manifest 不含本文件（**我实测**）；
门清单与四条既存红（`P7B_WU_REGRESSION.md` §2/§3）。

**没核（别当结论读）**：① §5 表里 A1/A2/R1 的 Gbps 全是**模型值**（`P(c)` 两端锚定、误差带 ≈±1%），
**没有**用新 RTL 实测过；② 面积是**估计**（0.6–1.1 k LUT），依据是同类改动的差分，不是综合读数；
③ 时序结论是**分析 + 先例**，不是构建读数（§4.1 已写成"必须由一次构建收口"）；
④ 下行窗口（BDP）那道帽只有算术，**没有** `ss -ti` 现取；⑤ `tcp_tx_frame` 乒乓（§8-f）的 9.5 Gbps 是**别人的预测**，非实测。
