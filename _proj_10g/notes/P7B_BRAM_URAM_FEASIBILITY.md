# P7B-BRAM-URAM —— 把大块 BRAM 迁到 URAM 的可行性评估

- 轮次：**BRAM 调查 A3 路**（用户问："**能否把大块的占用换成 UltraRAM**"）。
- 器件：`xcku5p-ffvb676-1-e`（**速度等级 −1**）。
- 本文件**只读调查**，**不实施**。所有"实验"只写方案。
- ⚠️ **本轮有一份 Vivado 全实现构建在跑** ⇒ 全程**未启动任何 Vivado**（无 `vivado`/`xvlog`/`xsim`/`synth_design`），`vivado_prj/` 只读 `.rpt` / `.log`。
- 写法约定：**每条硬约束都给"绝对路径 + 行号 + 原文"**；**【读得】**=机读原始件 · **【解析】**=由 RTL/报告推出（给了算式）· **【待实验】**=没有直接证据。
- ⚠️ **凡与原始件冲突，以原始件为准。**

---

## 0. 一句话结论

> ### ① **能换，而且只有一块值得换：`retx_ram`（TCP 重传环）= 256 tile = 全部 348 tile 的 73.6%。**
> ### ② **换完 Block RAM Tile 从 348 → 92（72.50% → 19.17%），代价 32/64 个 URAM288（50%）+ 读延迟 +1~3 拍（上界 +19.2 ns，只落在重传路径）。**
> ### ③ Vivado **自己已经试过**把这块映到 URAM 并**拒绝了** —— 理由机读得到（`Synth 8-6793`），
> ### 因此这条路的"能不能"不是猜的，是工具的原话："`Available pipeline stages = 0, Minimum required pipeline stages = 3`"。
> ### ④ **其余每一块都换不了**，而且理由**不是"麻烦"而是"硬约束"**（手写原语 / 双时钟 / 依赖 WRITE_FIRST 碰撞 / 太浅太窄）。
> ### ⑤ ⚠️ **不能只加一行 `ram_style="ultra"` 了事** —— retx_ram 现在被综合成 **8 个字节 lane × 16 深度片 = 128 片/阵列**，
> ### 直接套 `ultra` 会让每 lane 独占 16 个 URAM ⇒ **128 URAM/阵列 = 2 倍全器件**。**必须同时改推断形态**（见 §3.1 前置项 P-1）。

---

## 1. 基线读数（**本轮实测口径**）

### 1.1 现役实现的 BRAM/URAM

出【读得】`vivado_prj/p7b_ku5p_prj.runs/impl_1/wrapper_p4_utilization_placed.rpt:107-114`
（与 `p7b_lat_prj.runs/impl_1/wrapper_p4_utilization_placed.rpt:107-114` **逐数相同**）：

| Site Type | Used | Available | Util% |
|---|---|---|---|
| **Block RAM Tile** | **348** | 480 | **72.50** |
| RAMB36/FIFO | 317 | 480 | 66.04 |
| RAMB18 | 62 | 960 | 6.46 |
| **URAM** | **0** | **64** | **0.00** |

⭐ **交叉校验（两条独立算术都对上 348）**：

- **算术 1（按 tile）**：317 RAMB36 + 62 RAMB18/2 = 317 + 31 = **348** ✓
- **算术 2（按 clock region，独立来源）**：`p7b_lat_prj.runs/impl_1/wrapper_p4_clock_utilization_routed.rpt` 的
  "6. Clock Regions : Load Primitives" 表（`Block RAM (18K)` 列，16 个 region 逐区相加）：
  16+22+50+32+64+48+72+32+57+44+68+32+48+39+58+14 = **696** 个 18K 单元 = **348 tile** ✓

### 1.2 ⭐ URAM 在 KU5P 上的**物理分布**（这条以前没人查过，是本轮最重要的新事实）

同一份 `wrapper_p4_clock_utilization_routed.rpt` 的 `URAM` 列的 **Avail**（= 器件事实，与设计无关）：

| | X0 | X1 | **X2** | X3 |
|---|---|---|---|---|
| Y3 | 0 | 0 | **16** | 0 |
| Y2 | 0 | 0 | **16** | 0 |
| Y1 | 0 | 0 | **16** | 0 |
| Y0 | 0 | 0 | **16** | 0 |

⇒ **64 个 URAM288 全部在 X2 这一列时钟区域内（每区 16 个）**，X0/X1/X3 **一个都没有**。

**这条有三个直接后果**（后面 §3.4 展开）：
1. 任何 URAM 存储**必须**落在 X2 列；
2. 与它通信的逻辑要么搬进 X2、要么**跨列布线**；
3. 反过来看是好事：**X2Y1 现在是 72/72 满的**（`Block RAM (18K)` Used=72，Avail=72），
   把 X2 的 BRAM 让出来正好解这一区的拥塞。

### 1.3 内存预算的**归属**（【解析】，算式给出，可复核）

⭐ **关键一层**：`wrapper_p4` 顶层（`synth_1`）与两个 OOC IP 是**分开报的**，必须相加：

| 来源 | Block RAM Tile | RAMB36 | RAMB18 | 出处 |
|---|---|---|---|---|
| `wrapper_p4` 顶层（**含全部自写 RTL**） | **312** | **281** | **62** | `runs/synth_1/wrapper_p4_utilization_synth.rpt` |
| `xdma_0`（PCIe 观测通道，OOC） | **38** | **38** | 0 | `runs/xdma_0_synth_1/xdma_0_utilization_synth.rpt` |
| `pcs64`（xxv_ethernet PCS/PMA，OOC） | **0** | 0 | 0 | `runs/pcs64_synth_1/pcs64_utilization_synth.rpt` |
| 合计（opt 前） | 350 | 319 | 62 | — |
| **placed 实测** | **348** | **317** | **62** | §1.1 |

⇒ **自写 RTL 只有 281 个 RAMB36，其余 38 个在 XDMA IP 里（不可改）。**

#### 281 个 RAMB36 的分解

| 块 | 算式 | RAMB36 | 依据 |
|---|---|---|---|
| **`retx_ram`**（`rtl/retx_ram.v:119-120`，2 个阵列） | 每阵列 65536 字 × 64 b = 4 Mbit；被综合成 **8 个字节 lane × 16 深度片**（见下），每片 RAMB36 ⇒ 128/阵列 ⇒ **256** | **256** | 【解析】+ 旁证 |
| **`frame_fifo` 主存**（5 个实例） | 每片 RAMB36E2 = 512 字 ×72 SDP，**NB = D/512**（`rtl/frame_fifo.v:93`）；tcp_echo D=8192 ⇒ 16；udp_echo D=2048 ⇒ 4；slow_rx_adp/slow_tx_adp/udp_split 各 D=512 ⇒ 1×3 | **23** | 【解析】`rtl/frame_fifo.v:93,121-147` + 各调用点 |
| 余量 | 281 − 256 − 23 | **2** | 未逐一定位（见 §6-U1） |

#### 62 个 RAMB18 的分解（全部是**小块**，单个 ≤ 1 tile）

| 来源 | 估算 | 依据 |
|---|---|---|
| `fifo_sync` (W=73, D=256) × 5 | 每实例 256×73 = 18,688 b > RAMB18 的 18,432 b ⇒ 拆 2~3 片 RAMB18 | `rtl/fifo_sync.v:43` 推断数组；调用点 5 处 |
| `fifo_sync` (W=9, D=2048) × 2 | 2048×9 = 18,432 b = 恰好 1 RAMB18 | `slow_rx_adp.v:115` / `slow_tx_adp.v:40` |
| HLS `udp_echo` 的 `RAM_2P_BRAM_*` 微型表 | 约 20 个（每个 DataWidth 8~48 / AddressRange 3~1728），综合 **1 片 RAMB18~RAMB36** | `imports/verilog/udp_echo_*_RAM_2P_BRAM_1R1W_ram.v`（19 个文件） |

⚠️ **`retx_ram = 256` 的证据链（三层独立）**：
1. **【解析】** 2 × 65536 × 64 b = 8 Mbit；÷ 36 Kbit/RAMB36 = 227.6 → 上取整受 8-lane 拆分限制 → **256**；
2. **【机读】** 综合日志 `runs/synth_1/runme.log:2494` 一带：
   `WARNING: [Synth 8-6841] Block RAM (g_byte[1].mem_o_reg) ... Byte Wide Write Enable RAM cannot take advantage of ByteWide feature ... (address width (16) is more than optimal threshold of 12)` ⇒ 确实按 **byte lane 拆片**；
3. **【前人记录】** `PORT_NOTES.md:1988`：`FSM 状态 → 256 片 RAMB36 ADDRBWRADDR 的布线拥塞`。

---

## 2. ⭐ URAM288 硬约束表（**逐条带出处，本轮全部机读核实**）

主源：**unisim 原语模型** `C:/AMDDesignTools/2025.2/Vivado/data/verilog/src/unisims/URAM288.v`（**一手**）；
**XPM 源** `C:/AMDDesignTools/2025.2/Vivado/data/ip/xpm/xpm_memory/hdl/xpm_memory.sv`、`.../xpm_fifo/hdl/xpm_fifo.sv`（**工具自己的 DRC 就是判据**）。

> ### ⭐ 这 **43 条（C1…C33，含 a/b/c 子条）** 里**最容易误判的 3 条**（先看这三条）
> 1. **"URAM 不能初始化"**（**C5/C5b/C5c**）—— 网上/Docs 里能查到的 `INIT_000…INIT_3FF` + `INIT_FILE` 是 **Versal 的 `URAM288E5`**，
>    **KU5P 的 `URAM288` 一个都没有**。**按 Versal 推断 = 必错。**
> 2. **"URAM 只有一个时钟"**（**C17/C18**）—— 原语端口表里**唯一一个 `CLK`**。这一条把**所有跨时钟 FIFO 一次性排除**，
>    而本设计的两个 `fifo_async` 正好是跨时钟的。**"URAM 能当异步 FIFO"= 硬否决。**
> 3. **"URAM 不是'设了个 write mode 就完事'的存储器"**（**C8/C8b/C10/C11**）—— 原语层**没有** `WRITE_MODE`；
>    XPM 层虽有 `WRITE_MODE_A/B`，但对 URAM 是 **TDP 必须 `no_change`、SDP 必须 read-first/write-first 且 write-first 要读延迟 ≥3**。
>    ⇒ **"同址同拍写读"没有 BRAM 那种三选一，只能靠端口规模/时序去规避。**

### 2.1 容量 / 几何 / 位宽

| # | 结论 | 出处（原文） |
|---|---|---|
| C1 | **URAM288 = 288 Kbit = 4096 字 × 72 位**（= 36 KB，**8 倍**于 RAMB36 的 36 Kbit） | `URAM288.v:10` `Description : Xilinx Unified Simulation Library Component / 288K-bit High-Density Memory Building Block`；`URAM288.v:2009-2010` `localparam mem_width = 72;` / `localparam mem_depth = 4 * 1024;`；`URAM288.v:2018` `reg [mem_width-1:0] mem [0:mem_depth-1];`；`URAM288.v:3300` `ram_addr_a <= ADDR_A_int[11:0];` |
| C1b | ⚠️ **地址端口是 23 位 `ADDR_A[22:0]`，不是 12 位**：低 12 位片内地址，**高 11 位 `[22:12]` 给级联** | `URAM288.v:95-96` `input [22:0] ADDR_A, ADDR_B`；`:2237` `ADDR_A_reg[22:12] <= ADDR_A_in[22:12];`；`:2240` `ADDR_A_reg[11:0] <= ADDR_A_in[11:0];` |
| C2 | 数据口 **72 位**，配 **9 个字节写使能**（8 数据字节 + 1 奇偶字节） | `URAM288.v:88` `output [71:0] DOUT_A`；`:97` `input [8:0] BWE_A` |
| C3 | **位宽模式 = 72（64 数据 + 8 ECC）或 64（数据）**。**没有 48/36/32/24/18/16/9 这些"窄模式"** —— 要窄，只能用 BWE 少写几个字节，**深度与宽度配额照样占满** | `URAM288.v:118` `input [71:0] DIN_A`（端口就是 72 位）；`xpm_memory.sv:695,699`：`symmetric port widths are required for UltraRAM configurations` |
| C4 | ⚠️ **推论（对本设计致命）**：**URAM 是"4096 深"起步的存储器**。本设计里 D=256/512/2048 的 FIFO 放进去，**深度只用掉 1/16 ~ 1/2** ⇒ **省不了任何东西，只是把浪费从 BRAM 挪到 URAM** | 由 C1 直接推出 |

### 2.2 初值（★ 硬否决项）

| # | 结论 | 出处 |
|---|---|---|
| C5 | ⛔ **URAM 不能预置初值**。参数表里**根本没有** `INIT_A`/`INIT_B`/`INIT_FILE` | `URAM288.v:25-68` 全参数表**逐字**：`AUTO_SLEEP_LATENCY, AVG_CONS_INACTIVE_CYCLES, BWE_MODE_A/B, CASCADE_ORDER_A/B, EN_AUTO_SLEEP_MODE, EN_ECC_RD_A/B, EN_ECC_WR_A/B, IREG_PRE_A/B, IS_*_INVERTED, MATRIX_ID, NUM_UNIQUE_SELF_ADDR_A/B, NUM_URAM_IN_MATRIX, OREG_A/B, OREG_ECC_A/B, REG_CAS_A/B, RST_MODE_A/B, SELF_ADDR_A/B, SELF_MASK_A/B, USE_EXT_CE_A/B` —— **无 INIT 系列** |
| C6 | 唯一"初值"是**复位值**：`RST_A/RST_B` 把输出寄存器清成 `D_INIT = 0`（**全 0，且只作用于输出寄存器，不是存储内容**） | `URAM288.v:2015-2016` `localparam [mem_width-1:0] D_INIT = {mem_width{1'b0}};` / `D_UNDEF = ...`；`:3451-3455` `always @ (posedge INIT_RAM) for (wa=0;wa<mem_depth;...) mem[wa] <= D_INIT;`（**上电即 100% 清零，无任何"从文件/参数加载"的路径**） |
| **C5b** | ⭐⭐ **最容易误判的一条**：**Versal 的 `URAM288E5` 有初值，UltraScale+ 的 `URAM288` 没有。** 拿 Versal 文档/源码来推断 KU5P ⇒ **必错** | `URAM288E5_BASE.sv:38-1061`：**1024 个** `parameter [71:0] INIT_000 … INIT_3FF`，`:1062` `parameter INIT_FILE = "NONE"`；**而** `URAM288.v` 参数表（`:25-66`）**一个 INIT 都没有**。器件侧旁证：`data/parts/xilinx/kintexuplus/devint/.../kintexuplus.lib` 里 `grep -o "URAM288[A-Z0-9_]*"` **只得到 `URAM288` 与 `URAM288_BASE`，无 E5** |
| C5c | ⚠️ 陷阱的**第二层**：`xpm_memory.sv` 里**确实有** URAM 的 `$readmemh(MEMORY_INIT_FILE, ...)` 代码，**但它对 UltraScale+ 目标不成立** | `xpm_memory.sv:8256-8276`（`init_datafile_uram` 分支的 `$readmemh`）；默认 `MEMORY_INIT_FILE = "none"`（`:65`）且要求 **≤4K 深**（`:8256`）⇒ **别据此认为 KU5P 的 URAM 能加载初值** |
| C7 | XPM 侧同一条的另一种说法：**输出寄存器复位值必须是 0** | `xpm_memory.sv:703` `READ_RESET_VALUE_A is nonzero ... but UltraRAM configurations require a zero-valued output register reset.` |

⇒ **任何 ROM / 预载 FIFO / 有初值的查找表 = 硬否决**。本设计与这条**无冲突**（`retx_ram` 无复位写块、无初值，见 `rtl/retx_ram.v:119-120` 注释"无复位块"）。

### 2.3 读写同址行为（★ 决定"简单双口 FIFO 能不能直接换"）

| # | 结论 | 出处 |
|---|---|---|
| C8 | ⛔ **URAM 原语层没有 `WRITE_MODE` / `READ_FIRST` / `WRITE_FIRST` / `NO_CHANGE` 参数可选** | `URAM288.v:25-66` 参数表**无** `WRITE_MODE`（对照 `RAMB36E2.v` 有）；`grep -i "WRITE_MODE" URAM288.v` **零命中** |
| C8b | ⚠️ 但 **XPM 层有** `WRITE_MODE_A/B`（整型 0/1/2 = write_first/read_first/no_change）—— 只是**对 URAM 被约束到几乎没得选**：TDP 必须 `no_change`，SDP 禁 `no_change`（见 C10/C11）。⇒ **"URAM 有 write mode 可调"是错觉** | `xpm_memory.sv:87,97` `parameter integer WRITE_MODE_A = 2, WRITE_MODE_B = WRITE_MODE_A`；`:167-169,183-185`（0=WF,1=RF,2=NC） |
| C9 | 端口语义是**"写 XOR 读"**：**只要该口在写（`RDB_WR` 指向写），读输出就被压掉** | `URAM288.v:3488-3492`：`if (ram_we_a && ...) mem[ram_addr_a] = (ram_data_a & ram_bwe_a) | (mem[ram_addr_a] & ~ram_bwe_a);` 紧接 `if (ram_ce_a && ~ram_we_a && ...) ram_data_a_out = mem[ram_addr_a];` ← **读门里带 `~ram_we_a`** |
| C10 | XPM 用**端口宽度**把它补成"类 BRAM"行为：**简单双口（SDP）只能*模仿* read-first 或 write-first**，且 **写口用 write-first 时读延迟必须 ≥ 3**（read-first 且开 auto-sleep 时也 ≥3；write-first + auto-sleep 时 ≥4） | `xpm_memory.sv:615` `simple dual port RAM configurations targeting UltraRAM can only mimic read-first mode or write-first mode behaviour for port B`；`:619` `... using write-first mode for port B must use a read latency of at least 3 for port B`；`:382,387` |
| C11 | **真双口（TDP）URAM 必须用 no-change**（A/B 两个读口各自受限） | `xpm_memory.sv:639,643` `true dual port UltraRAM configurations must use no-change mode for port A/B` |
| C12 | ⭐ **官方明确：同一时钟下，A 口的操作先于 B 口**（这是"同址写读"唯一拿得到的官方口径） | `xpm_memory.sv:526` `XPM_MEMORY behaviorally models the port operation ordering of true dual port UltraRAM configurations by slightly delaying the common clock for port B operations only`；`:1588-1592` 原文注释 `although both ports share a common clock, port B operations occur after port A operations` + `assign clkb_int = clka;` |
| C12b | **FIFO 里 URAM 实际用的写模式**：`WR_MODE_B = 1`（read_first）、`WR_MODE_A = 2`（no_change）⇒ **URAM FIFO 走的是 read-first**，这就是它"能当 FIFO 用"的原因 | `xpm_fifo.sv:571-572` `localparam WR_MODE_B = (FIFO_MEMORY_TYPE == 1 \|\| FIFO_MEMORY_TYPE == 3 \|\| FIFO_MEMORY_TYPE == 4) ? 1 : 2;` / `localparam WR_MODE_A = (FIFO_MEMORY_TYPE == 4) ? 0 : 2;` |

### 2.4 延迟 / 流水

| # | 结论 | 出处 |
|---|---|---|
| C13 | ⛔ **禁止组合读**：至少 1 级寄存器 | `xpm_memory.sv:607,611` `READ_LATENCY_A specifies a combinatorial read output ... but at least one register stage is required for block memory or UltraRAM configurations` |
| C14 | ⭐ **原语自带的可选流水级 = 3 档，所以"URAM 最少几拍"是有明确答案的**：<br>**`DOUT` 相对 `EN` 默认 = 1 拍**（`IREG_PRE=FALSE, OREG=FALSE`）；`OREG_A=TRUE` ⇒ **2 拍**；`IREG_PRE_A=TRUE` ⇒ **再 +1 拍（= 3）** | 端口/参数：`URAM288.v:40-41`（`IREG_PRE_A/B`）、`:53-54`（`OREG_A/B`）、`:126-127`（`OREG_CE_A/B`，需 `USE_EXT_CE_A/B` 才引入）、`:57-58`（`REG_CAS_A/B`）；延迟路径：`:2255-2263`（`ADDR_A_int = ADDR_A_reg`（IREG_PRE）**或** `ADDR_A_in`）、`:3299-3300`（采入 `ram_addr_a`）、`:3463-3468`（组合读出 `ram_data_a_lat`）、`:2966-2969`（`OREG_A_TRUE ? ram_data_a_reg : ram_data_a_lat`） |
| C15 | ⭐⭐⭐ **Vivado 的综合层要求 ≥3 级读流水**：本设计里 Vivado **亲口拒了 retx_ram** | `runs/synth_1/runme.log`（`Synth 8-6793`）`RAM ("i_53_5/u_tcp_tx/u_retx/g_byte[1].mem_o_reg") is implemented using BRAM instead of URAM due to insufficient pipeline registers.` **`Available pipeline stages = 0, Minimum required pipeline stages = 3`** |
| C16 | 同一条消息里给了**解法**（原文） | `Synth 8-6792` `Large memory block (...) is implemented using BRAM instead of URAM ... Use of ram_style="ultra" and/or providing sufficient pipeline registers is recommended` |

### 2.5 时钟（★ 写死）

| # | 结论 | 出处 |
|---|---|---|
| C17 | ⛔⛔ **URAM288 的两个端口共用唯一一个 `CLK`** —— `URAM288.v` 的端口表里**有且只有一个时钟输入** | `URAM288.v:117` `input CLK,`（全文 `input` 里没有 `CLK_A`/`CLK_B`/`CLKA`/`CLKB`） |
| C18 | ⇒ **任何跨时钟 FIFO 用 URAM = 硬否决**，工具在 DRC 里直接 `$error` | `xpm_fifo.sv:322` `UltraRAM cannot be used as asynchronous FIFO because it has only one clock support`（条件 `COMMON_CLOCK == 0 && FIFO_MEM_TYPE == 3`） |
| C19 | XPM 侧同一句 | `xpm_memory.sv:603` `CLOCKING_MODE specifies independent clocks, but UltraRAM configurations require a common clock.` |

### 2.6 级联

| # | 结论 | 出处 |
|---|---|---|
| C20 | 深/宽扩展靠 **CAS 链**：`CASCADE_ORDER_A/B` + `CAS_IN_*`/`CAS_OUT_*` 全套（ADDR/BWE/DIN/DOUT/EN/RDB_WR/SBITERR/DBITERR 都级联）+ `REG_CAS_A/B` 给级联段插寄存器 | `URAM288.v:37-38,75-86,95-131,60-61` |
| C20b | **`CASCADE_ORDER_A/B` 的合法值 = `NONE` / `FIRST` / `LAST` / `MIDDLE`**；⚠️ **没有 `CASCADE_AUTO`**（unisim 与 xpm 全文零命中） | `URAM288.v:33-34`；`:1475,1484` `Legal values for this attribute are NONE, FIRST, LAST or MIDDLE` |
| C21 | 级联的**位置是硬编码的**：`SELF_ADDR_A/B[10:0]` / `SELF_MASK_A/B` / `NUM_URAM_IN_MATRIX` / `MATRIX_ID` —— 链上每一级的"自认地址"必须匹配，**不能任意跨列拼**；`USE_EXT_CE_A/B` **不可用于级联** | `URAM288.v:55-59,51-52`；`:1951,1958` `EXT_CE_A can not be used in cascaded URAM applications` |
| C22 | 地址总线是 **23 位 = 低 12 位真地址 + 高 11 位给级联** | `URAM288.v:95` `input [22:0] ADDR_A`；`:3300` `ram_addr_a <= ADDR_A_int[11:0];` |
| **C22b** | ✅ **级联深度上限（本项原本是未知，现已查明）**：<br>• **XPM 层：`CASCADE_HEIGHT ≤ 64`**（URAM）<br>• **原语层：`NUM_URAM_IN_MATRIX` 合法 1…2048**<br>• 级联是**竖向（地址方向）**的；`mem` 只有**一个**阵列，宽度恒 72 位，**没有横向位宽级联参数** | `xpm_memory.sv:341-342` `XPM_MEMORY does not support CASCADE_HEIGHT (%0d) greater than 64 for Ultra RAM configurations`；`URAM288.v:1551` `NUM_URAM_IN_MATRIX ... Legal values ... are 1 to 2048`；`:2018` 单个 `mem` + A/B 口共访（`:3488,3498`） |
| **C22c** | ⇒ **本设计需要的 16 深级联（65536/4096）远在限内**（64 与 2048 两个上限都过得去） ⇒ §6-U2 **关闭** | 由 C22b 推 |

### 2.7 ECC

| # | 结论 | 出处 |
|---|---|---|
| C23 | **URAM288 内置 SECDED ECC**（这就是 72 = 64 数据 + 8 ECC 的由来），按端口独立使能：`EN_ECC_WR_A/B`（写入时算校验）、`EN_ECC_RD_A/B`（读出时纠错）、`OREG_ECC_A/B`（纠错结果打拍）；状态口 `SBITERR_A/B`（可纠）、`DBITERR_A/B`（不可纠）、`RDACCESS_A/B`；还有注入口 `INJECT_SBITERR_A/B`/`INJECT_DBITERR_A/B` | `URAM288.v:48-50,64-65,80-81,90-93,132-136,3521-3540`（`ecc_cor` 任务 + `synd_rd/synd_ecc/sbiterr/dbiterr`） |
| C24 | **开 ECC 会吃数据位**：`EN_ECC_RD_A` 打开时数据只有 `data[63:0]` 有效（`[71:64]` 是校验） | `URAM288.v:3529` `synd_rd = fn_ecc(decode, data[63:0], data[71:64]);` |
| C25 | **BRAM 的对比**：RAMB36E2 也支持 ECC，但**必须先级联成 64 位以上**，且**要额外 tile**；URAM 的 ECC 是"免费内置"的 | 结论性对比；BRAM 侧未在本轮逐条取证 ⇒ 引用时只当"URAM 内置、BRAM 要拼"这一层 |
| C25b | ⚠️ **URAM 的 ECC 只在简单双口（SDP）下可用** —— 真双口不能用 ECC | `xpm_memory.sv:800` `the MEMORY_TYPE specified is other than Simple Dual port RAM, but ECC feature is supported only when the MEMORY_TYPE is set to simple Dual port RAM`；`:790` ECC 仅 BRAM/URAM 支持 |

### 2.8 推断路径（Verilog / XPM / FIFO）

| # | 结论 | 出处 |
|---|---|---|
| C26 | **`xpm_memory` 支持 URAM**：`MEMORY_PRIMITIVE` 合法值 `auto(0)/distributed(1)/block(2)/ultra(3)/mixed(4)`，字符串别名 `"ultra"`/`"ULTRA"`/`"ultraram"`/`"ULTRARAM"`。⚠️ **URAM 映射到的综合属性字符串是 `"ultra"`，不是 `"uram"`** —— 手写 RTL 属性时别写错 | `xpm_memory.sv:156-160`；`:8893`；`:443` 越界 `$error`；`:251-254` `localparam P_MEMORY_PRIMITIVE = ... (`MEM_PRIM_ULTRA ? "ultra" : ...)` ⇒ `:1077-1078` `(* ram_style = P_MEMORY_PRIMITIVE, rom_style = P_MEMORY_PRIMITIVE *)` |
| C27 | Verilog 数组推断靠属性 **`(* ram_style = "ultra" *)`**（Vivado 自己的建议，C16） | `Synth 8-6792` 原文 |
| C28 | ✅ **`xpm_fifo_sync` 可以用 URAM**。`FIFO_MEMORY_TYPE` **完整合法表**：`auto`(0，默认) / `lutram`\|`distributed`(1) / `bram`\|`block`(2) / **`uram`\|`ultra`(3)** / `mixedram`\|`mixed`(4) / `builtin`(5，不进 `base`) | `xpm_fifo.sv:2078-2082`（三处 —— `sync`/`async`/`axis` —— 逐字相同）；默认值 `:1979` `FIFO_MEMORY_TYPE = "auto"`；⚠️ 整数接口上限是 **4**：`:382-383` `FIFO_MEMORY_TYPE > 4` ⇒ `$error` |
| C28b | ⭐ **`xpm_fifo_sync` 是"真允许"而不是"忘了拦"**：它把 `P_FIFO_MEMORY_TYPE` **无守卫**透传给 `xpm_fifo_base`；**对比** `xpm_fifo_async` 有 `!= 3` 守卫、URAM 时整块实例化被 `generate` 掉 | `xpm_fifo.sv:2112-2114`（sync，无守卫）；`:2310`（async，`generate if (P_FIFO_MEMORY_TYPE != 3) begin : gnuram_async_fifo`)；`:2365` |
| C29 | ⛔ **`xpm_fifo_async` 不可以用 URAM**（同上 C18） | `xpm_fifo.sv:322`（`$error`）+ `:2310`（根本不会例化） |
| C30 | ⛔ **低延迟 FWFT（`READ_MODE=2`）只准 LUTRAM** ⇒ URAM FIFO **必须付读延迟** | `xpm_fifo.sv:435-436` `XPM_FIFO does not support Read Mode (Low Latency FWFT) for FIFO_MEMORY_TYPE other than lutram/distributed` |
| C31 | URAM + **非对称端口 + BWE + sleep** 不支持；URAM + `write_first`/`no_change` 且**写保护关**不支持 | `xpm_memory.sv:367`、`:422,426` |

### 2.9 布局 / 拥塞

| # | 结论 | 出处 |
|---|---|---|
| C32 | ⭐ **KU5P 的 64 个 URAM288 全在 X2 一个时钟区域列，每区 16 个**；X0/X1/X3 为 0 | §1.2（`wrapper_p4_clock_utilization_routed.rpt` "6. Clock Regions : Load Primitives" 的 URAM `Avail` 列） |
| C33 | ⇒ URAM 与 BRAM **不同列**：BRAM 四列都有（X0/X2 各 72/区、X1/X3 各 48/区，`Available` 列），URAM 只有一列 | 同上（`Block RAM (18K)` 的 `Avail` 列） |

---

## 3. 逐候选评估（**门槛 = ≥8 tile**）

### 3.0 汇总表

| # | 块（模块:行） | 当前原语 / 几何 | **tile** | **URAM 兼容性** | 需改什么 | **预期省 tile** | 风险 |
|---|---|---|---|---|---|---|---|
| **A** | **`retx_ram`**<br>`rtl/retx_ram.v:119-120`；实例 `rtl/tcp_tx_frame.v:580` | 2 个推断数组 `[63:0] mem_e/o [0:65535]`；**无初值、单时钟、SDP** | **256** | ✅ **符合**（唯一违反的是 C15 流水级，可修） | ① 修 8-lane 拆分（前置项 P-1）；② 加读流水到 ≥3（C15）；③ 按新读延迟重算 `tcp_tx_frame` S_RING 拍表 | **−256**（348 → **92**） | 中（时序/延迟，见 §4） |
| **B** | **`frame_fifo` 主存 ×5**<br>`rtl/frame_fifo.v:121-147`（tcp_echo 8192 / udp_echo 2048 / ×3 D=512） | **手写 `RAMB36E2` 原语**，512 字 ×72 SDP，`DOA_REG=0` ⇒ **读 1 拍** | **23** | ❌ **违反 C8/C10/C12/C13**：① 依赖 **WRITE_FIRST 同址写读碰撞**（`rtl/frame_fifo.v:44-48` 明确写了"主存 WRITE_FIRST 碰撞"）；② 要 **1 拍读延迟**；③ 是**原语**不是推断数组，属性改不动；④ 即便改写，URAM 的 **A 口先于 B 口**（C12）与 WRITE_FIRST 不是同一件事 | 整块重写（换 XPM 或手写 URAM288 级联 + 自己补 bypass/碰撞语义 + 补 2 拍流水） | −23（理论） | **高**：P6a 板级 WNS 就出在这条 64bit 宽路径（`rtl/frame_fifo.v:7-9`） |
| **C** | `fifo_sync` 全部（最大 D=2048×9 / D=256×73） | 推断数组 `rtl/fifo_sync.v:43` | ~14（RAMB18 为主） | ❌ **违反 C4**：最大 18,432 b = **1/16 个 URAM**；且要组合读语义（`fifo_sync` 是 FWFT）⇒ 再违 C13 | 换 XPM 并付读延迟 | ~0（**负收益**：占 URAM 不省 tile） | 低（但没意义） |
| **D** | `fifo_async` (`u_rxcdc` 76×256 / `u_txcdc` 73×256)<br>`rtl/fifo_async.v:245` | 手写灰码双时钟 FIFO | **0 tile**（组合读 ⇒ **LUTRAM**，不吃 BRAM） | ⛔ **违反 C17/C18**：双时钟 = 硬否决 | 不可能 | 0 | — |
| **E** | HLS `udp_echo` 的 `RAM_2P_BRAM_*` 微型表（约 19 个文件） | Vitis HLS 生成，`(* ram_style="block" *)`，最大 768×32 | ~15（RAMB18 为主） | ❌ **违反 C4**：32×3 / 256×48 这类表放 URAM = 用 36 KB 存 96 bit；且要回 **HLS 源码**加 `bind_storage` 重生成核 | 重跑 HLS + 改 pragma | ~0（**负收益**） | 高（重建 HLS 核有回归风险） |
| **F** | `xdma_0` IP | 官方 OOC 网表 | **38** | ⛔ **不可改**（第三方 IP 内部） | — | 0 | — |
| **G** | `frame_fifo` 边存 / `udp_split_fifo` / `tcp_cam` / `tcb` / `app_ctrl` 数组 | `(* ram_style="distributed" *)` / 小数组 | 0（LUTRAM） | 不适用 | — | 0 | — |

### 3.1 ⭐ 换得了的：**只有 A（`retx_ram`）**，且**有一个必须先做的前置项**

#### 前置项 **P-1：必须先修掉 "8 个字节 lane" 的推断形态**（否则 URAM 方案直接爆器件）

Vivado 自己的话【读得】`runs/synth_1/runme.log`（`Synth 8-6841`）：

> `Block RAM (g_byte[1].mem_o_reg) originally specified as a Byte Wide Write Enable RAM cannot take advantage of ByteWide feature and is implemented with single write enable per RAM due to following reason. (address width (16) is more than optimal threshold of 12. Implementing using BWWE will require more logic and timing would be suboptimal. Please use attribute ram_decomp = power if BWWE is desired.)`

含义（【解析】，与实例名 `u_tcp_tx/u_retx/g_byte[1].mem_o_reg_7_bram_6` 一致）：
- 因为 `rtl/retx_ram.v:126-135` 的 `generate for (bj=0..7)` 里**每个字节单独写**，而 16 位地址超过了 BWWE 的阈值 12，
- ⇒ Vivado **放弃了 BWWE，把 64 位字拆成 8 个独立的 8 位宽 RAM**，每个再按深度切 16 片 ⇒ **128 片/阵列**。

⚠️ **如果直接加 `(* ram_style="ultra" *)`**：每个 8 位宽 × 65536 深的 lane 要 **16 个 URAM288**（用 8/72 的位宽）⇒ 8 lane × 16 = **128 URAM/阵列**，两个阵列 **256 URAM** —— **器件只有 64 个**。**方案直接不成立。**

⇒ **P-1 是硬前提**，两条路选一（都**未实施**）：
- **P-1a（推荐，改动最小）**：照 Vivado 的建议加 **`(* ram_decomp = "power" *)`**，让工具把 8 个 lane 合回**一个带 BWE 的 64 位 RAM** ⇒ 65536×64 = 16 URAM/阵列 ⇒ **32 URAM 总计**（50%）。
- **P-1b**：把 `rtl/retx_ram.v:126-135` 的 generate 循环改成**单块 `mem_e`/`mem_o` + 一个 64 位写 + 8 位 `we`** 的写法（URAM 原生 `BWE_A[8:0]` 正好 9 个字节使能，C2）。

#### 换完的账

| 项 | 换前 | 换后 |
|---|---|---|
| `retx_ram` Block RAM tile | 256 | **0** |
| `retx_ram` URAM288 | 0 | **32**（2 阵列 × (65536/4096 = **16**)） |
| **全设计 Block RAM Tile** | **348**（72.50%） | **92**（**19.17%**） |
| **全设计 URAM** | 0（0%） | **32**（**50%**） |
| 全设计 URAM 最大可再腾 | — | 还剩 32 个（可再来一块同规模的） |

---

## 4. 迁移代价（**明码标价，不虚报收益**）

⚠️ **本设计的终局目标是低延时行情** ⇒ 下面每条延迟都换算成 **ns**。
**统一换算**：数据面时钟 `dp_clk` = **156.25 MHz**（P6b 验收读数 `156.2585 MHz`）⇒ **1 拍 = 6.400 ns**。

| 代价项 | 具体 | 数值 | 说明 |
|---|---|---|---|
| **读延迟** | **2 拍 → ≥5 拍**（+3 拍）⚠️ **区间待实验收窄** | **+19.2 ns**（上界） | 现值 2 拍 = 地址入口寄存 1 拍（`rtl/retx_ram.v:99-107`）+ BRAM 输出 1 拍（`rtl/retx_ram.v:139-143`）。URAM 侧：<br>• **硬件下限 = 1 拍**（C14：`IREG_PRE=F/OREG=F`），**加满 = 3 拍**；<br>• 但 **Vivado 综合层的推断门槛是 ≥3**（C15，retx_ram 被判"0 级可用"）；<br>• xpm 的 SDP+write-first 口径也是 **`READ_LATENCY_B ≥ 3`**（C10，宏 `MEM_PORTB_URAM_LAT = (READ_LATENCY_B > 2)` 在 `:195`）。<br>⇒ **落在 1~3 拍的额外延迟**（+6.4 ~ +19.2 ns），**实际值由实验 A/B 决定**（见 U3）。<br>⚠️ **明码标价：按最坏 3 拍报 +19.2 ns。** |
| **这条延迟落在哪** | **重传读路径（TX 侧）**，**不在** P7b_lat 测的 `(a)→app` RX 口径里 | 不进 `217.57 ns` | `P7B_LATENCY.md` §0 的 158 B 帧 `217.57 ns` 是 **RX** 分段（PCS `/S/` → 应用适配器入口）。`retx_ram` 只在 **TCP 重传**时被读（`rtl/tcp_tx_frame.v:573` `rd_tap = ring_start \|\| (ring_act && (beat_cnt < nbeats))`）。 |
| **单帧代价** | S_RING 状态机长度 **`nbeats+2` → `nbeats+5`** | **+3 拍 = +19.2 ns / 重传帧** | `rtl/tcp_tx_frame.v:558-560` 明确写着"**读延迟 1 拍变 2 拍；上表已按 2 拍重算**"（`ring_end = nbeats + 8'd2`，`:566`）⇒ 延迟一变，**这张拍表必须重算**。相对 1460 B 帧的线上串行化 ~1180 ns ⇒ **+1.6%**（且只在重传发生）。 |
| **吞吐 / II** | **不变** | 0 | 仍是 1 字/拍读、1 字/拍写、SDP；URAM 的 `EN_A`/`EN_B` 每拍可各做一次访问。 |
| **✅ 反而变好的** | **字节写使能** | −逻辑 | 现在因地址 16 > 阈值 12 而**丢掉 BWWE、拆 8 lane**（`Synth 8-6841`）；URAM **原生 `BWE_A[8:0]`**（C2）⇒ 这块拆分逻辑与读 mux 消失。**LUT 会减少**（量未测，【待实验】）。 |
| **时序风险 ①** | **跨列布线** | 中 | URAM **全在 X2**（C32）。`retx_ram` 的 256 个 BRAM 现在**四列都有**（§1.2 表）；迁完**读写口 + 地址全挤到 X2**。好的一面：**X2Y1 现在 72/72 满**，腾出来正好。 |
| **时序风险 ②** | **16 深级联的 CAS 链** | 中 | 65536 深 = **16 深级联**（每个 4096）。CAS 链的输入→输出延迟要靠 `REG_CAS_A/B` 打拍（C20/C21）。⚠️ **级联深度上限未核实**（§6-U2）。 |
| **时序风险 ③** | **`retx_ram` 本来就在时序红区** | 中 | `PORT_NOTES.md:1988` / `rtl/retx_ram.v:53-70`：写地址曾 **WNS −0.848 / 912 端点**。加流水**可能更糟也可能更好**（`max_fanout=64/32` 的复制目前是给 256 个 BRAM 地址脚做的，换成 32 个 URAM 后**扇出大降**）⇒ **这是一个净收益方向**，但必须实测。 |
| **功耗 / 面积** | 定性 | — | URAM288 单块 36 KB 比 8 片 RAMB36 的静态功耗低；且**省掉 8-lane 拆分与 16 选 1 读出 mux 的 LUT/布线**。URAM 有 auto-sleep（`EN_AUTO_SLEEP_MODE`/`AUTO_SLEEP_LATENCY`，C14）可再省，但**开 auto-sleep 会把读延迟门槛抬到 ≥4**（C10）⇒ **本设计不要开**。 |
| **⚠️ 最贵的一条** | **S_RING 拍表重算 + 全链回归** | **不是几行代码** | `rtl/tcp_tx_frame.v:558-570` 那张拍表是**逐拍对齐**的（读序列/写序列/`ring_end`/`ring_wr`/`ring_tkeep`/`ring_w` 的 mask 全靠 `beat_cnt` 的相位）。延迟 2→5 会把**写序列整体再后移 3 拍**，牵动 `rm_mask` 的 `ring_rem` 相位与 `ring_fin`。**必须重跑 retx 单元 TB + 四门矩阵**。 |

---

## 5. ⭐ "换不了"的清单与理由（**说透，避免以后有人白试**）

| 块 | 一句话理由（**硬约束编号**） |
|---|---|
| **`frame_fifo` 主存（23 tile，5 个实例）** | ① 是**手写 `RAMB36E2` 原语**，属性改不动，只能整块重写；② **依赖 WRITE_FIRST 同址写读碰撞**（`rtl/frame_fifo.v:44-48`），而 **URAM 没有 WRITE_MODE 参数**（**C8**）、SDP 下"只能*模仿* read-first/write-first"（**C10**）；③ 要 **1 拍读延迟**（`DOA_REG=0` 是刻意选的，`rtl/frame_fifo.v:32-36`），URAM 至少 1 级寄存器且实用上 ≥3（**C13/C15**）；④ P6a 板级 WNS 就出在这条 64bit 宽路径上（`rtl/frame_fifo.v:7-9`）⇒ 动它风险/收益比最差。 |
| **所有 `fifo_sync`（~14 tile）** | **太浅太窄**：最大 2048×9 = 18,432 b，**恰好 1 个 RAMB18**；而 URAM 是 **4096 深 × 72 位**的整块（**C1/C4**）⇒ 换过去**一个 tile 都省不掉**，只是把浪费搬进 URAM，还要额外付读延迟（**C13**，`fifo_sync` 是组合读 FWFT）。**净负收益。** |
| **`fifo_async`（`u_rxcdc`/`u_txcdc`）** | **双时钟 = 硬否决**（**C17 只有一个 `CLK` 端口**；**C18** `$error: UltraRAM cannot be used as asynchronous FIFO because it has only one clock support`）。⚠️ 而且它们**本来就不吃 BRAM**：`rtl/fifo_async.v:253` 是 `assign dout = mem[...]` 的**组合读** ⇒ 落在 LUTRAM。**换它是双输。** |
| **HLS `udp_echo` 的 `RAM_2P_BRAM_*`** | `32×3`（`tcp_conn_cwnd`）、`8×3`、`32×256`、`48×256`、`8×1728` 这类表：**用 36 KB 存 96 bit ~ 13 Kbit**（**C4**）。另外它们是 **Vitis HLS 生成**，改它要回 HLS 源码加 `bind_storage -impl URAM` 并**重新生成核**（HLS 网表重建有既有回归风险）。**净负收益。** |
| **`xdma_0`（38 tile）** | 官方 **IP 的 OOC 网表**，不是我们的 RTL，**不可改**。 |
| **任何 ROM / 有初值的表 / 预载 FIFO** | ⛔ **URAM 的参数表里没有 `INIT_A`/`INIT_B`/`INIT_FILE`**（**C5**）⇒ **一律硬否决**。（本设计暂无此类块，但以后加 ROM 别再问这张表。） |
| **`frame_fifo` 边存 / `udp_split_fifo` / `tcp_cam` / `tcb` / `app_ctrl` 数组** | 本来就是 `ram_style="distributed"` 或小数组 ⇒ **LUTRAM，不吃 tile**，不适用。 |

---

## 6. 不确定与待实验项（**【待实验】= 本轮不实施**）

### U1. **2 个 RAMB36 未归属**
281（RTL RAMB36）− 256（retx_ram）− 23（frame_fifo）= **2** 未定位。
**判别法**：对现位流跑 `report_ram_utilization -file ...`（或 `report_utilization -hierarchical`），
**判据**：逐实例 tile 数之和 == 348，且 `retx_ram` 一行 == 256。
⚠️ 本文件的 256 是【解析 + 日志 + 前人记录】三重推出的，**不是工具导出的表** —— U1 就是把这个缺口补上。

### ~~U2. URAM 级联深度上限~~ —— ✅ **本轮已查明，关闭**
- **XPM 层 `CASCADE_HEIGHT ≤ 64`**（`xpm_memory.sv:341-342`）；**原语层 `NUM_URAM_IN_MATRIX` 合法 1…2048**（`URAM288.v:1551`）。
- ⇒ 本设计需要的 **16 深级联** 在限内（见 **C22b/C22c**）。
- ⚠️ **附带一条工具事实**：**本机 Vivado 2025.2 根本没装任何 PDF 文档** ——
  `find "C:/AMDDesignTools/2025.2/Vivado/doc" -iname "*.pdf"` 计数 **0**（`doc/` 下全是 HTML：`about_vivado*.html`/`eng`/`images`/`locale`/`oocclks.cct`/`sysgen`/`tcw`/`vitis_net_p4`），
  `find ... -iname "*573*"` **空**。⇒ **UG573 无法离线取得**，以后引用 UG573 必须标注"来自外部，本机不可复核"。
  **本轮所有 URAM 硬约束因此全部改由 unisim 原语 + XPM DRC 源码支撑（比 PDF 更硬）。**

### U3. ⭐ `ram_style="ultra"` 是否**绕过** Vivado 的 ≥3 级流水门槛（C15/C16 的"and/or"到底是哪个）
`Synth 8-6792` 原文写的是 **"`Use of ram_style="ultra"` **and/or** providing sufficient pipeline registers is recommended"** —— **"and/or" 的语义未证实**：硬压 `ultra` 之后是 (a) 真的出 URAM、只是时序差，还是 (b) 仍然退回 BRAM？
**这决定 §4 里"+3 拍"是必须付、还是可以只付 1~2 拍。**
⚠️ **两边的证据都指向"不确定"**：硬件侧 C14 说**原语 1 拍就能读**（`IREG_PRE=F/OREG=F`）；工具侧 C15 说**综合要 3 级**。二者不矛盾（工具是在为自己留时序余量），但**"硬压能不能过"只有实验能答**。见下面实验 A/B。

### U4. URAM 路径的**布线/拥塞**实测数字（跨列代价）
**实验 C**。

### U5. LUT 减少量
P-1 把 8-lane 拆并回单块后，读出 mux 与写译码会减多少 LUT —— **未测**。

---

## 7. ⭐ **下一步该做的实验清单**（本轮**不实施**，只写方案 + 预期读数 + 判别标准）

> ⚠️ **纪律**：① **不得从被构建的工程烧位流**；② 每个实验**用新的 tag / 独立 OOC 工程**，不碰 `vivado_prj/p7b_ku5p_prj`；
> ③ **跑门一律用 `sim/p4gates/run_matrix_p4dfix.bat`（自定位）**；
> ④ 每次实验**先记录基线读数**（本文件 §1）再改一行。

### 实验 A —— **OOC 单模块：只加一行属性，看能不能出 URAM**（成本最低，先做）

- **做法**：新建 OOC 工程，只读入 `rtl/retx_ram.v`（**不改主工程**）。两份配置：
  - **A1**：原样 + `(* ram_style = "ultra" *)` 加在 `mem_e`/`mem_o`（`rtl/retx_ram.v:119-120`）；
  - **A2**：同 A1，**再加 `(* ram_decomp = "power" *)`**（= §3.1 的 P-1a，Vivado 自己在 `Synth 8-6841` 里点名的属性）。
- **预期读数**：
  | 配置 | 预期 Block RAM tile | 预期 URAM288 | 预期日志 |
  |---|---|---|---|
  | 基线（无属性） | **256** | 0 | 有 `Synth 8-6793`（stages 0 vs 3） |
  | A1 | **0 或 256**（二选一） | **0（若 256）或 1024（若真的按 8 lane 展开）** | — |
  | A2 | **0** | **32** | `Synth 8-6793` 应消失或改口 |
- **判别标准（三分支，互斥）**：
  - ✅ **A2 出 32 URAM / 0 tile** ⇒ 方案成立，进实验 B。（**注意**：此时**还不能断定延迟** —— `ram_style="ultra"` 若真绕过了 C15，读延迟可能只需 +1 拍；要用实现的 `report_timing` 才能定。）
  - ⚠️ **A1/A2 出 128/256/1024 URAM** ⇒ **8-lane 展开没修干净**（§3.1 的 P-1 被证实），**必须做 P-1b**（改写 `rtl/retx_ram.v:126-135`），不要在这个形态上继续。
  - ⛔ **两份都还是 256 BRAM** ⇒ `ram_style="ultra"` **绕不过 C15**（U3 答"b"）⇒ **"+3 拍是必须付的"**，进实验 B。
- ⚠️ **A 跑通 ≠ 能用** —— OOC 综合**不含时序约束**，只证明"**映射形态**"；延迟与布线必须靠实验 C。
- ⚠️ **一个小陷阱**：`URAM288` 的地址端口是 **23 位**（C1b）。如果 A 里为了让工具高兴而手接地址，**高位 `[22:12]` 必须按级联规则接**（`CASCADE_ORDER`/`SELF_ADDR`），否则会踩 `Unisim …-13` 警告（`URAM288.v:1963-1966`）。**用推断（`ram_style`）就不用管这条**。

### 实验 B —— **补够读流水（3 级）再 OOC**

- **做法**：在 A 的基础上，把读路径改成 **3 级**（地址入口 1 级 + 中间 1 级 + 输出 1 级），**且保留"读延迟可参数化"**（用一个 `localparam RD_LAT`，便于回退）。
- **预期读数**：URAM288 = **32**、Block RAM tile = **0**、`Synth 8-6793` **消失**。
- **判别标准**：与 A2 读数一致即通过；若 URAM 数 > 32（如 64/128）⇒ 展开形态没修干净，回 P-1b。

### 实验 C —— **全实现一次（新 tag），看真实代价**

- **做法**：`board/build_p7b_ku5p.tcl` 的副本 + 新 tag（如 `p7b_uram_prj`），**只改 `retx_ram` + `tcp_tx_frame` 拍表**。
- **必须同时做的**：按 §4 把 `rtl/tcp_tx_frame.v:566` 的 `ring_end = nbeats + 8'd2` 改成新延迟对应的常数（**这张拍表要按 §4 重算，不是改常数就完**）。
- **预期读数（每条都给了判据）**：

  | 读数 | 期望 | **判据（不满足就是失败）** |
  |---|---|---|
  | Block RAM Tile | **348 → 92** | ±0（92 是算出来的确定值）；**> 92 ⇒ 有块没换干净** |
  | URAM | **0 → 32** | 精确 32；**64/128 ⇒ 8-lane 展开没修** |
  | WNS / setup 失败端点 | **≥ +0.128 / 0** | 与 P7b 合并构建基线（`P7B_BUILD_FINAL.md`：WNS +0.128 / 0）比较；**变负或端点 > 0 ⇒ 停** |
  | WHS / hold 失败端点 | 与基线同量级 | 现有 hold 余量极薄（+0.008~+0.013），**任何恶化都要查 `p6b_final_ku5p_hold_400.rpt` 的三族** |
  | WPWS / 失败端点 | 0 | 同 P6a 口径 |
  | 拥塞 | 定性看 `report_design_analysis` | **X2 列的 `Block RAM (18K)` 从 72/72 掉下来**；跨列网增多的量要记 |
  | `mbufg`/时钟 | 不变 | — |

- **判别标准**：**BRAM 92 + URAM 32 + 三类失败端点全 0** 才算"迁移在时序上成立"。

### 实验 D —— **功能回归（不可省）**

- **做法**：① `rtl/retx_ram` 的单元 TB（若有）/ 新增一个；② `sim/p4gates/run_matrix_p4dfix.bat` 全矩阵；
  ③ **帧级**：`tb/` 下 TCP 重传路径的回归（对照 `P7B_LATENT_FIFO_FIX.md` 的方法：**先记基线读数再改**）。
- **预期读数**：单元门 **全 PASS**；矩阵 **16/16 EXIT=0**。
- **判别标准**：⚠️ **必须专门造"重传"用例** —— `retx_ram` 的读只在重传时发生，**常规回显通路走不到它**（这正是它能在设计里"沉默"这么久的原因）。判据 = **重传帧逐字节正确 + `ring_end` 相位不错位**。

### 实验 E（可选，**只有 A~D 全绿才做**）—— 把 `frame_fifo` 也换成 `xpm_fifo_sync` + URAM

- **收益**：再省 **23 tile**（92 → 69，14.4%）。
- **代价**：`frame_fifo` 的 **WRITE_FIRST 碰撞语义 + 1 拍读延迟 + snap/rollback** 要全部重建（**C8/C10/C13**）。
- **判别标准**：`sim/p6a_ku5p/run_tb_frame_fifo_{us,k7}.bat` **六计数逐数一致**（P6a-T1 的原判据）+ 板级冻结回归。
- ⚠️ **不建议先做这块**：风险/收益比最差（23 tile vs 256 tile）。

### 实验优先级（一句话）

> **A → B → C → D**：先用**零风险的 OOC** 回答"能不能出 URAM"（U3），再谈实现；
> **A2 出不了 32 URAM 就别往下走了** —— 那说明 P-1 或 C15 有一条堵死。

---

## 8. 出处汇总（便于复核）

| 文件 | 用途 |
|---|---|
| `C:/AMDDesignTools/2025.2/Vivado/data/verilog/src/unisims/URAM288.v` | **URAM 原语一手模型（UltraScale+，唯一权威）**：`:10` 288 Kb、`:25-66` 参数全表（**无 INIT / 无 INIT_FILE / 无 WRITE_MODE / 无 CASCADE_AUTO**）、`:68-93` 输出端口 / `:95-134` 输入端口（**`:117` 只有 1 个 `CLK`**）、`:2009-2018` `mem_width=72`/`mem_depth=4096`/单个 `mem`、`:2255-2263` `IREG_PRE`、`:2966-2969` `OREG`、`:3300` 12 位真地址、`:3451-3459` 上电清零、`:3487-3499` 写/读语义（读门含 `~ram_we_a`）、`:3521-3540` ECC、`:1475/1484` `CASCADE_ORDER` 合法值、`:1551` `NUM_URAM_IN_MATRIX` 1…2048、`:1951/1958` 级联禁 `EXT_CE` |
| ⚠️ `…/unisims/URAM288E5_BASE.sv`（**Versal，勿混用**） | `:38-1061` **1024 个 `INIT_000…INIT_3FF`** + `:1062` **`INIT_FILE`** —— **这是"URAM 能初始化"这个错觉的唯一来源**，KU5P 没有这些 |
| `C:/AMDDesignTools/2025.2/Vivado/data/ip/xpm/xpm_memory/hdl/xpm_memory.sv` | URAM 的 XPM 层 DRC：`:156-160`+`:251-254` `MEMORY_PRIMITIVE` 取值与 **`"ultra"` 属性串**、`:341-342` **`CASCADE_HEIGHT ≤ 64`**、`:526`+`:1588-1592` **A 口先于 B 口**、`:602-603` 公共时钟、`:606-611` 禁组合读、`:614-619` SDP 禁 no_change 且 write-first 要 ≥3、`:638-645` TDP 必须 no_change、`:695-703` 对称位宽 + 输出复位值 0、`:366-367` 非对称 BWE 禁 sleep、`:790`/`:800` ECC 仅 BRAM/URAM 且 URAM 仅 SDP |
| `C:/AMDDesignTools/2025.2/Vivado/data/ip/xpm/xpm_fifo/hdl/xpm_fifo.sv` | `:322` **URAM 不能做异步 FIFO**（`$error`）、`:2310` 异步路径 `generate if (… != 3)` 守卫、`:2078-2082` `FIFO_MEMORY_TYPE` **完整合法表**、`:571-572` URAM 时 `WR_MODE_B = 1`（read_first）、`:435-436` 低延迟 FWFT 只准 LUTRAM |
| `vivado_prj/p7b_ku5p_prj.runs/impl_1/wrapper_p4_utilization_placed.rpt:107-114` | 基线 348 / 317 / 62 / URAM 0 |
| `vivado_prj/p7b_ku5p_prj.runs/synth_1/wrapper_p4_utilization_synth.rpt` | RTL 部分 312 tile / 281 RAMB36 / 62 RAMB18 |
| `vivado_prj/p7b_ku5p_prj.runs/xdma_0_synth_1/xdma_0_utilization_synth.rpt` | XDMA = **38 RAMB36** |
| `vivado_prj/p7b_ku5p_prj.runs/pcs64_synth_1/pcs64_utilization_synth.rpt` | PCS = **0 BRAM** |
| `vivado_prj/p7b_lat_prj.runs/impl_1/wrapper_p4_clock_utilization_routed.rpt` §6 | ⭐ **URAM 全在 X2**（每区 16）+ 逐区 BRAM 分布（和为 696×18K = 348 tile） |
| `vivado_prj/p7b_ku5p_prj.runs/synth_1/runme.log` | ⭐ `Synth 8-6792`（解法）/ `8-6793`（**stages 0 vs 3**）/ `8-6841`（**8-lane 拆分**）/ `8-5556`（级联链） |
| `rtl/retx_ram.v:119-120,126-143` | 被评对象本体（2 阵列 + 8 lane 写 + 2 拍读） |
| `rtl/tcp_tx_frame.v:558-584` | 读延迟→拍表的耦合处（`ring_end = nbeats + 2`） |
| `rtl/frame_fifo.v:7-9,32-48,93,121-147` | frame_fifo 的手写原语 / WRITE_FIRST 碰撞 / 1 拍读 |
| `rtl/fifo_async.v:245,253` | 双时钟 + 组合读（LUTRAM） |
| `_proj_10g/notes/P7B_LATENCY.md` §0 | 延迟是产品指标：`217.57 ns`（RX 口径） |
| `PORT_NOTES.md:1988` | `retx_ram` = **256 片 RAMB36** 的前人记录 + 时序红区 |
