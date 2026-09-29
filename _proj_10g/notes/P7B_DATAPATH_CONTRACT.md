# P7b 冻结文档：要被替换的 MAC 与必须保住的合同

- 日期：2026-09-29
- 性质：**只读侦察**产物。本文只陈述**已核实的 as-built 事实**（每条带 `file:line`）；
  任何推断/未核实项一律在文中显式标注 `【未核实】` / `【推断】`。
- 侦察范围：`D:\repo\XCKU5PMini\udp_hls_10g`（git 根 = 本目录）。
  未触碰硬件、未跑 Vivado、未做任何 git 写操作、未修改除本文件外的任何文件。
- 现役构建（事实）：top = `wrapper_p4`，宏
  `APP_MODE=1 DEV_USP=1 PCIE_OBS=1 DP_156MHZ=1`，器件 `xcku5p-ffvb676-1-e`
  （`board/build_p6b_final_ku5p.tcl:24, 68, 110`）。

---

## 0. 一句话结论（先读这个）

| 问题 | 结论 |
|---|---|
| 下游是不是已经是 64 位？ | **是。数据面上每一个模块的入口都是 `[63:0] tdata + [7:0] tkeep + tvalid/tready/tlast/tuser/tcrs/terr`，并且是"每拍一个字"。** ⇒ **P7b 的下游接口完全不用动**，新 10G MAC 只要产出**同样的帧流合同**即可。 |
| 那还有没有 8 位的东西？ | 有，但**只有三处**，且都不是"下游接口宽度"问题：① MAC 内部的 `rtl/crc32_8b.v`（8 位/拍 CRC，随 MAC 一起重写）；② 演示 app `rtl/app_udp_pattern.v` 的 **RX 图案校验器**（接口 64 位，内部 8 拍/字，自报天花板 = 1G 线速 ⇒ **10G 差 8 倍**）；③ 慢路径适配器 `rtl/slow_rx_adp.v` / `slow_tx_adp.v`（64 位字 ⇄ 9 位字节给 HLS，1 字节/拍 ⇒ 封顶 ~1.25 Gbps，是 HLS 慢路径的既有上限，非本次引入）。 |
| 谁真的会被替换？ | `rtl/mac_rx_64.v` + `rtl/mac_tx_64.v`（两个模块整体），以及它们内部引用的 `rtl/crc32_8b.v` 的**用法**。 |
| 最大的隐性成本 | 这两个模块的**内部**全是"1 字节/拍"（前导 8 拍、pad 最多 60 拍、FCS 4 拍、IFG 12 拍、CRC 1 字节/拍）。10G 版必须把这些改成"1 拍 8 字节"，否则**小帧帧率**会成为瓶颈（见 §A.6、§D.4）。 |

---

## A. 两个 MAC 模块的完整接口合同

### A.1 `mac_rx_64`（`rtl/mac_rx_64.v`，module 在 :60）

**职责**：1G GMII 字节流 → 64 位左对齐 AXIS 字流；**在本层完成 FCS 校验与剥离**、前导/SFD 剥离。

#### A.1.1 端口合同表

| 端口 | 方向/位宽 | 时钟域 | 精确语义（含证据行号） |
|---|---|---|---|
| `clk` | in 1 | — | 125 MHz GMII 域（`mac_rx_64.v:61`；现役接 `gmii_clk`，`board/wrapper_p4.v:392`） |
| `rst_n` | in 1 | — | 低有效，异步。**注意**：这里接的是**板级 `reset_n`**，不是 `dp_rst_n`（`wrapper_p4.v:393`） |
| `gmii_rxd[7:0]` | in 8 | gmii | GMII 接收字节；现役接**再寄存一拍**的 `rx_d1`（`wrapper_p4.v:354-359, 394`） |
| `gmii_rx_dv` | in 1 | gmii | GMII RX_DV；现役接 `rx_dv_d1`（同上） |
| `gmii_rx_er` | in 1 | gmii | GMII RX_ER；帧内任何一拍为 1 ⇒ 本帧 `ferr=1`（`mac_rx_64.v:286`） |
| `m_axis_tdata[63:0]` | out 64 | gmii | **`tdata[63:56]` = 帧内第一个被交付的字节**，字内字节从高到低连续（`mac_rx_64.v:2-8` 头注释；左对齐由 `ljust64` :138-153 保证） |
| `m_axis_tkeep[7:0]` | out 8 | gmii | 高位有效（MSB-first）。中间字恒 `8'hFF`（:237, :306 注释「hwkeep 恒 8'hFF」）；末字由 `ljust8` 生成（:155-170） |
| `m_axis_tvalid` | out 1 | gmii | **组合**：`= !fempty`（`mac_rx_64.v:376`），FWFT 语义 ⇒ 同拍 `tdata` 就是头字 |
| `m_axis_tready` | in 1 | gmii | 消费 = `tvalid && tready`（:359 `rd`） |
| `m_axis_tlast` | out 1 | gmii | 帧末字。**中止帧的 TLAST 由一个 TERM 字承担**（见 §A.3） |
| `m_axis_tuser` | out 1 | gmii | **SOP**：本帧**第一个被推入 FIFO 的字**为 1（:235 `push_sop <= !first_done`；:272/:304/:325 同式）。TERM 字恒 0（:204） |
| `m_axis_terr` | out 1 | gmii | **仅 TLAST 有效**：帧内 `rx_er`，或本字就是 TERM 字（:239, :273, :326, :206） |
| `m_axis_tcrs` | out 1 | gmii | **仅 TLAST 有效**：FCS 正确。判据 = 全帧（含 FCS 4 字节）流过 CRC 后残留 `== 32'hDEBB20E3`（:96 `CRC_RESIDUE`；:238, :273, :326） |
| `stat_frames[31:0]` | out 32 | gmii | 只统计**末字真的进了 FIFO** 的帧（:242, :275, :329） |
| `stat_crc_err[31:0]` | out 32 | gmii | FCS 残差 ≠ `0xDEBB20E3` 的帧（:243, :276, :330） |
| `stat_drop[31:0]` | out 32 | gmii | 丢帧总数（各原因之和，:257, :266, :281, :294, :337） |
| `stat_bytes[31:0]` | out 32 | gmii | 已交付帧的**线上**字节总数（含 FCS 4 字节，含前导？——**不含**前导：`fbytes` 只在 `S_DATA` 且 `gmii_rx_dv` 时 +1，:287） |
| `stat_drop_full[31:0]` | out 32 | gmii | 因 FIFO **空间不足**丢的帧（:258, :282, :295, :338）—— F4 新增 |
| `stat_drop_partial[31:0]` | out 32 | gmii | 其中"**已经推过字**"的帧（孤儿帧，:261, :298, :340）—— F4 新增 |
| `stat_orphan_bytes[31:0]` | out 32 | gmii | 这些帧已进 FIFO 的**字节数**（`Σpopc(tkeep)`，:262, :299, :341）—— F4 新增 |
| `stat_fifo_ovf[31:0]` | out 32 | gmii | `fifo_sync` 拒写次数。**结构上恒 0**，非 0 = 修复失效 = 有字被静默丢（:83, :189-190） |
| `dbg_stat_words_out[31:0]` | out 32 | gmii | 发出字数（`tvalid && tready`，:186-187）。三站词计数第 1 站（MW） |

#### A.1.2 交付给下游的**帧流合同**（这是 P7b 必须逐条保住的东西）

来源：`rtl/mac_rx_64.v:2-58` 头注释（F4 修复后重写的那一段，**它就是接口语义的权威文本**）。

1. **满/空契约**：FWFT。`m_axis_tvalid = !empty` 组合有效；消费 = `tvalid && tready`（:13-14, :359, :376）。
2. **SOP**：`tuser=1` 落在帧首字；帧首字**总是满对齐**（`tkeep[7]=1`）。
3. **TLAST**：帧末字 `tlast=1`，`tkeep` 高位有效，`tcrs` = FCS 正确，`terr` = 帧内 `rx_er`。
4. **FCS 被剥离**：由于 4 字节前瞻延迟线（`dline`，:103, :288, :308, :313），打包落后 CRC 输入 4 字节 ⇒ 线上帧尾 4 字节 FCS **天然不被打包**。⇒ **好帧的 `Σpopc(tkeep)` = 线上帧长 − 4**（:53）。
5. **绝不留裸尾巴字**：一旦某帧有字已进 FIFO 而该帧被中止 ⇒ 立刻置 `term_pend`，此后**任何帧字都不得先落笔**（:129-133），TERM 字必然排在下一个 SOP 之前。
6. **TERM 字定义**（中止帧的收尾）：`tdata=0, tkeep=8'h00, tlast=1, tuser=0, tcrs=0, terr=1`（:39-40, :199-208）。⇒ 0 字节，不污染字节计数；`tcrs=0` ⇒ 下游按坏帧丢。
7. **条件式保证（实测边界，勿读成无条件）**：只要消费者在该 SOP 之后**还接受过至少 1 个字**，该 SOP 与下一个 SOP 之间就**恰好一个** TLAST。**唯一例外**：消费者自该 SOP 起**永久不再排空**（FIFO 长期满）⇒ 最后一个已开始的帧会停在"无 TLAST"状态。该例外有界、有计数（`stat_drop_partial`）、非静默、不死锁（:41-47）。
8. **守恒律（可用计数器判，:48-53）**：
   - `#(TLAST 且 tkeep!=0 的交付帧) == stat_frames`
   - `Σpopc(tkeep)(全部交付字) == stat_bytes - 4*stat_frames + stat_orphan_bytes`
   - `#(TLAST 且 tkeep==0 的交付帧) == stat_drop_partial`
   - `stat_drop_partial <= stat_drop_full <= stat_drop`；`stat_fifo_ovf == 0`
9. **无溢出路径逐位不变**（:54-56）：不触发空间不足时，`push_ok` 与旧 `!fifo_full` 判据同值。

#### A.1.3 F4 修复的当前实现（逐行，带行号）

**F4(a)：空间门用 `full_next`，不用寄存化的 `full`**

```
:121   wire        fifo_full, fifo_full_next, fifo_ovf_pulse;      // 三个线网
:126-127 // 注释：push 是寄存器（本轮决定、下拍落笔）⇒ 下拍的满判据才是真判据
:128   wire        push_ok  = !fifo_full_next;                     // ★ 空间门
```
根因（:15-23）：`push` 在 T 拍决定、T+1 拍才在 `fifo_sync` 落笔；若 T 拍还有**另一次在飞写**，
`fifo_sync.wr && !full` 里的 `full`（T+1 拍值）可能已为 1 ⇒ 该笔写被 `fifo_sync`
**静默丢弃**。`full_next` 是"下一拍 `full` 的精确值"（含在飞写与本拍读），
由 `rtl/fifo_sync.v:53-57` 组合推导：`rptr_n` / `wptr_n` / `full_next`。
⇒ `push_ok ⇔ "本轮决定的这次推入下拍一定落笔"`。**多字 push 只需 1 个空位**，
但该空位必须在下拍仍存在（:22-23）。

**F4(b)/F4-2：TERM 优先 + 整帧丢弃归因**

```
:129-132 // 注释：帧字推入必须让 TERM 优先，否则 TERM 会落在那帧的字之后 = 帧边界错位
:133   wire        push_frame_ok = push_ok && !term_pend;           // ★ 帧推入门
:135   wire        term_fire     = term_pend && push_ok;            // ★ TERM 门（优先级更高）

:191-195  push/push_last/push_sop/push_crs/push_err <= 0;          // 脉冲型每拍默认清零（工程坑 6）
:196-208  // TERM 收尾字：**全局优先**，任何状态（含 S_DROP/S_DATA 中途）只要有 1 个空位就先送
:199      if (term_fire) begin
:200-206      push<=1; push_data<=64'd0; push_keep<=8'h00;
              push_last<=1; push_sop<=0; push_crs<=0; push_err<=1;  // ← TERM 字五元组
:207          term_pend <= 1'b0;
```
**置 `term_pend` 的四个入口**（都必须同时记 `stat_drop_partial` + `stat_orphan_bytes`）：
- `:248-263`（帧尾拍，有保持字但推不进去）：`:256` 回 `S_IDLE`，`:257` `stat_drop++`，
  `:258` 若 `!push_ok` 记 `stat_drop_full`，`:259-263` 若 `first_done` 则
  `term_pend<=1` + `stat_drop_partial++` + `stat_orphan_bytes += fpushed`。
  ⚠️ 这里**必须区分两种原因**：① `!push_ok`（没空间）② `term_pend`（空间有但帧字让路，
  该帧必然零推入）—— 旧实现（F4-2 缺陷）在此**无条件进 S_TERM**，会白吞一个本来有空间的好帧（:253-255）。
- `:292-300`（帧内，`bcnt==7` 整字完成时旧保持字推不进去）：`:293` 进 `S_DROP`，同式记账。
- `:332-342`（`S_FLUSH` 末字推不进去）：**该态必已有字进 FIFO**（`first_done` 恒 1），
  故这里必然 `!push_ok`；`:338` 无条件 `stat_drop_full++`，`:339-341` 置 TERM + 记账。
- 反例（**不置 TERM** 的三个丢弃点，因为该帧**零推入**）：
  `:264-266`（零字节净荷帧）、`:278-283`（单字 TLAST 也进不去）、`:248-263` 里 `!first_done` 的情形。

**F4 的自检回读**：`:83` `stat_fifo_ovf` ← `:189-190` 累计 `fifo_ovf_pulse`；
`fifo_ovf_pulse` 来自 `:367` 的 `fifo_sync.ovf_pulse`（`= wr && full`，`rtl/fifo_sync.v:59`）。
⇒ 恒 0 才叫"无静默丢失"。

**F4 的边界条件（必须一起搬走）**：
- 收帧**不需要空间**（字节先进 `hwv`/`wreg`），只有**推字**才要 FIFO 空位（:33-34, :131-132）。
- 短帧（<8 字节净荷，无保持字）单字 TLAST 交付（:267-277）。
- `hwkeep` 恒 `8'hFF` ⇒ `fpushed += 8`（:237, :306）；`S_FLUSH` 态的尾字字节数用
  `{13'd0, bcnt}`（:327），`fpushed` 在 S_DATA 只累加整字。

#### A.1.4 `mac_rx_64` 内部 FIFO（关系到替换时的宽度）

```
:355   localparam FW = 76;   // {tdata[75:12], tkeep[11:4], sop[3], last[2], crs[1], err[0]}
:361-368 fifo_sync #(.W(FW), .D(8), .AW(3)) u_fifo (...)   // 8 深, 单时钟
:370-376 输出位段映射
```
⚠️ 深度只有 **8**；`rx_classify` 的 DRAIN 期 `s_tready=0`（≤6 拍/帧）就靠它吸收
（`rtl/rx_classify.v:9-11`）。**10G 小帧洪泛**这条已经被记进 P6 清单
（`rtl/rx_classify.v:10-11`：`mac 层计数丢帧 — P6 复审 (skid 改真 FIFO 已记入 P6 清单)`）。

---

### A.2 `mac_tx_64` 的输入/输出合同（`rtl/mac_tx_64.v`，module 在 :34）

| 端口 | 方向/位宽 | 时钟域 | 精确语义 |
|---|---|---|---|
| `clk` / `rst_n` | in | — | 125 MHz；现役接 `gmii_clk` / **板级 `reset_n`**（`wrapper_p4.v:2227-2228`） |
| `s_axis_tdata[63:0]` | in 64 | gmii | 帧字流（输入侧来源在 DP 域，经 `u_txcdc`） |
| `s_axis_tkeep[7:0]` | in 8 | gmii | **源约定：每词 `tkeep != 0`**（高位有效，与 `mac_rx_64` 输出一致，头注释 :7） |
| `s_axis_tvalid` / `s_axis_tready` | in/out | gmii | `s_axis_tready = !ffull`（**组合**，:69）；写 = `tvalid && tready`（:67） |
| `s_axis_tlast` | in 1 | gmii | 帧末字标记。**TX 字流不带 `tuser`/SOP** ⇒ 帧边界**只**靠 TLAST（:21） |
| `gmii_txd[7:0]` / `gmii_tx_en` | out | gmii | **组合输出**（状态 mux，:96-109）；`tx_en = S_PRE|S_DATA|S_PAD|S_FCS`（:107-108） |
| `gmii_tx_er` | out 1 | gmii | 预留，恒 0（:109） |
| `stat_frames[31:0]` | out 32 | gmii | 完整发完的帧数，在 `S_IFG` 收尾拍 +1（:219） |
| `stat_abort[31:0]` | out 32 | gmii | 帧内断供中止次数（:188） |
| `stat_flush_words[31:0]` | out 32 | gmii | 冲刷期被丢弃的输入字数（:235）—— **F-2 新增** |
| `stat_flush_done[31:0]` | out 32 | gmii | 冲刷完成次数 = 重新对齐到帧边界的次数（:242）—— **F-2 新增** |

**线上帧格式（事实）**：`前导 55×7 + D5 | dst..payload (含 pad) | FCS 4B`。
- FCS = `crc ^ 32'hFFFFFFFF`，**小端（LSB-first）上线**（:4-5, :170, :102, :213）。
- 内容 < 60 字节时补 0 到 60（`MIN_CLEN = 60`，:58；判据 :168-173）⇒ 线上帧 ≥ 64B 含 FCS。
  ⚠️ 曾经用 46（payload 基准）⇒ `content∈[46,60)` 的帧（如 TCP 纯 ACK 54B）不补 pad
  上线成 runt（:55-57）。
- IFG ≥ 12 字节（`S_IFG` 直到 `ifg_cnt==4'd11`，:216-223）。
- CRC 初值/使能必须与发送字节**同拍组合**（:8, :111-112）：`crc_init = S_PRE && pre_cnt==7`（即 D5 拍）、
  `crc_en = S_DATA || S_PAD`。

### A.3 F-2 修复的当前实现（`S_FLUSH`，逐行，带行号）

**缺陷（修复前，:13-20）**：帧内中止只做 `state <= S_IDLE`。上游在"我们中止"之后才把本帧
**余下的字**送来（它并不知道我们中止了）⇒ 残字压在本模块 16 深 FIFO 里，被下一个
`S_IDLE -> S_PRE` 当**新帧首字**取走，一路按正常帧发送：补 pad、算 CRC、
发一个 **FCS 完全正确的"幽灵帧"**，载荷 = 被中止帧的中段残字。
实测：FCS 残留 == `0xDEBB20E3`，载荷 = 被中止帧的字节 `[320..960)`
（`:17-18`，原件 `P6B_CDC_AUDIT.md` F-2 / `audit_scratch/t3_txcdc`）。

**修复（as-built 逐行）**：

```
:52-54  localparam ... S_IFG = 3'd5, S_FLUSH = 3'd6;      // 新增第 6 个状态
:92-93  reg [3:0] flush_cnt;   // 线空闲计时 (保证 runt 与新帧之间的 IFG >= 12 字节)
        reg       flush_tl;    // 本帧的 TLAST 字已被吞掉 (帧边界已到)
:224-231 // 注释：⚠️ 时序要点（第一版在这里差了一拍）
:232-244 S_FLUSH: begin
:233        if (flush_cnt != 4'd12) flush_cnt <= flush_cnt + 4'd1;   // 饱和计数到 12
:234-235    if (frd && !fempty)   stat_flush_words <= ... + 32'd1;   // 本拍确实弹出了一个字
:236-237    if ((frd && !fempty && fdout[0]) || flush_tl)  flush_tl <= 1'b1;  // 帧边界已到
:239        frd <= (!flush_tl) && !(frd && !fempty && fdout[0]) && !fempty;
            // 下一拍是否继续请求弹出：只在"边界未到且本拍弹的不是边界字"时继续
:240-243    if (flush_tl && (flush_cnt == 4'd12)) begin
                state <= S_IDLE;  stat_flush_done <= stat_flush_done + 32'd1; end
```
**判据本身**（:236、:239）：`frd && !fempty && fdout[0]`——`frd` 是**寄存的弹出请求**（:138 每拍默认清零），
本拍 `frd=1` 弹出的是**本拍的头字** `fdout`。所以"本拍弹的正好是 TLAST"时必须**同拍停止再请求**，
否则下一拍会把 TLAST 之后的第一个字也弹掉（吃掉下一帧首字；实测幽灵帧 = 帧 C 的 `[1..24]` 字，:227-231）。
`fdout[0]` 是 `tlast`（FIFO 字格式 `{tdata, tkeep, tlast}`，:64）。

**进入 `S_FLUSH` 的唯一入口**（:23）：
```
:163-193 S_DATA:
:175-181    else if (!fempty) begin  frd<=1; cw_data<=fdout[72:9]; ... end   // 正常取下一字
:182-189    else begin                                          // 断供：中止 (runt)
:185            state <= S_FLUSH; flush_cnt <= 4'd0; flush_tl <= 1'b0;
:187            cw_v <= 1'b0;
:188            stat_abort <= stat_abort + 1;
            end
```
冲刷期**一个字都不发**：`gmii_tx_en` 的表达式不含 `S_FLUSH`（:107-108），
`txd_c` 走 `default: 8'h07`（:103）。

**覆盖性论证（:22-32，原文四条）**：
① 只在一处中止，其余状态不产生残字；
② 上游帧契约（`tx_arb: busy` 锁到 TLAST 被消费为止）⇒ 每个被中止的帧必然还有 TLAST 在路上 ⇒ 冲刷一定终止；
③ 唯一"没有 TLAST 会到来"的情形 = DP 被复位/放弃该帧 ⇒ 冲刷会把下一帧整帧也吃掉，
   代价 = 丢 1 帧（有界、自愈、**有计数**）—— 安全的那个方向；
④ 不触发中止的流量：`S_FLUSH` 不可达 ⇒ 数据通路/字节流**逐位不变**（`audit_scratch/run_t3.bat` 的 nostall A/B 指纹）。

**⚠️ 板上不可观测（本次侦察新发现，未在任何文档里见过）**：
`board/wrapper_p4.v:2226-2239` 的 `mac_tx_64` 例化**只接了 `stat_frames` 与 `stat_abort`**，
`stat_flush_words` / `stat_flush_done` **未连接**，且 36 字快照窗口里**没有对应字**
（`wrapper_p4.v:2738-2765` 的 `fe_src`/`dp_src` 拼接里没有它们）。
⇒ **F-2 修复的观测证据在板级拿不到**（只能靠仿真门）。这与 F-1 的 `ovf_cnt` 缺口是**同一类**，
见 §D.2。

---

### A.4 两个模块里**可复用**的设计思路 vs **必须重写**的部分

| 项 | 判断 | 依据 |
|---|---|---|
| **CRC32-8 校验器**（`rtl/crc32_8b.v`） | ❌ **必须重写为 8 字节/拍**（或 4 字节/拍 + 流水） | 它是**字节串行** `step8`（`crc32_8b.v:14-32`，8 次移位循环/字节）。10G 需要 64 位/拍 ⇒ 8 字节并行。**但**它的三条语义必须逐条保住：反射多项式 `0xEDB88320`、初值 `0xFFFFFFFF`、**无终值取反**（:2-4）；残留魔数 `0xDEBB20E3`（不是 `0xC704DD7B`，:3-4）；`en` 与 `d` 必须同拍（:5）。 |
| **FCS 的字节序** | ❌ 必须重写但要逐条对齐 | 线上 FCS = `crc ^ 0xFFFFFFFF`，**LSB-first 上线**（`mac_tx_64.v:170, :213, :102`）。⇒ 64 位版里"末 4 字节"在字内的落位、以及"算出来的 32 位值怎么写进那 4 个字节"必须与 1G 版**逐位一致**（跨版本对拍靠这个）。 |
| **残差校验法（rx 侧）** | ✅ 可复用（思路） | 全帧（含 FCS）流过 CRC 后残留 == `0xDEBB20E3`（`mac_rx_64.v:96`）。64 位版照搬这个判据即可（含 4 字节未对齐的尾字）。 |
| **4 字节前瞻延迟线剥 FCS** | ⚠️ 思路可复用但实现要重做 | 1G 版用 `dline` 32 位移位（`mac_rx_64.v:103, 288, 308, 313`），**1 字节/拍**；64 位版应是"末字里去掉最后 4 字节"（`tkeep` 调整）+ 逐字比较。 |
| **前导/SFD 检测（rx）** | ✅ 思路可复用 | `S_IDLE` 找 `0x55` → `S_PRE` 计 `pre_cnt` → `0xD5 && pre_cnt>=6` 进 `S_DATA`（`mac_rx_64.v:210-228`）。64 位版要么在 XGMII 控制字符里判，要么保留同款计数。 |
| **前导/SFD 生成（tx）** | ✅ 可复用（但要重写为多字节/拍） | `txd_c = (pre_cnt==6'd7) ? 8'hD5 : 8'h55`（`mac_tx_64.v:99`）。 |
| **IFG 计数** | ✅ 可复用 | `ifg_cnt==4'd11`（12 字节）→ `S_IDLE`（`mac_tx_64.v:216-223`）。⚠️ 但它是**字节**计数 ⇒ 64 位版应按字计（12 字节 = 1.5 字，需取整策略——【未核实】该取整在 10G 下的等价口径）。 |
| **帧内中止 → runt 语义** | ✅ 必须保住 | `stat_abort`（`mac_tx_64.v:188`）+ 线上留 runt 由接收方按 FCS/长度丢（`mac_tx_64.v:32` §⑤）。 |
| **`S_FLUSH` 语义（中止后冲刷到本帧 TLAST）** | ✅ **思路必须保住，实现要重做** | 判据 `frd && !fempty && fdout[0]` 依赖"`frd` 是寄存的、且 `fdout[0]` 是同拍头字"这条**FWFT 语义**。64 位版只要 FIFO 仍是 FWFT，这套判据可以逐行照搬（`mac_tx_64.v:232-244`）。 |
| **丢帧补 TERM 的整帧原子性 + 守恒律** | ✅ **合同必须保住，实现要重做** | `push_ok = !full_next` / `push_frame_ok = push_ok && !term_pend` / `term_fire = term_pend && push_ok` 这三条门是**逻辑等价**的，与位宽无关（`mac_rx_64.v:128, 133, 135`）。但 `fpushed`（孤儿字节计数）在 64 位版应按 `Σpopc(tkeep)` 计，不能再用 `+= 16'd8` 的定值（`mac_rx_64.v:237, 306`）。 |
| **8 位逐字节 vs 一拍 8 字节的 `tkeep` 处理** | ❌ **必须重写** | `wreg/wkeep` 累积 + `ljust64`/`ljust8`（`mac_rx_64.v:100-102, 137-170`）是**逐字节**拼字；64 位版每个源字进来就是 8 字节有效，`tkeep` 要按 SOP/TLAST 与**FCS 剥离后的有效字节数**重算。 |
| **`fifo_sync` 的接口** | ✅ 可直接复用 | `W/D/AW` 全是参数（`rtl/fifo_sync.v:20-24`），`full_next`/`ovf_pulse` 也是通用探针（:39-40, :53-59）。新 MAC 若继续用 FWFT 同步 FIFO，读侧零改动。 |
| **计数器口径与命名** | ✅ 建议**逐字保留** | `stat_frames/stat_crc_err/stat_drop/stat_bytes` 与 W0-W4、W20/W21 的判据与验收脚本绑定（`wrapper_p4.v:2738-2751`）。改名会让板级验收脚本静默读错。 |

---

## B. 替换点清单

### B.1 `mac_rx_64` / `mac_tx_64` 的**全部**例化点

**（a）现役构建路径（活件）**

| 文件:行 | 实例名 | 说明 |
|---|---|---|
| `board/wrapper_p4.v:391` | `u_mac_rx` | **P6b/P6e 现役 top 的 RX MAC**；接 `gmii_clk` / 板级 `reset_n` / `rx_d1,rx_dv_d1,rx_er_d1`；输出 `rxsrc_*`（进入 `u_rxcdc`） |
| `board/wrapper_p4.v:2226` | `u_mac_tx` | **现役 top 的 TX MAC**；接 `m_tx_*`（来自 `u_txcdc`）；输出 `e_txd/e_txen/e_txer`；只接 `stat_frames`/`stat_abort` |

其余三个顶层**不是现役构建**（各自的历史顶层，`board/build_*.tcl` 里 top 是 `wrapper_p4`，
`board/build_p6b_final_ku5p.tcl:24`）：

| 文件:行 | 实例 | 说明 |
|---|---|---|
| `board/wrapper_1g.v:154` / `:174` | `u_mac_rx` / `u_mac_tx` | 1G 环回顶层（历史） |
| `board/wrapper_echo.v:176` / `:290` | `u_mac_rx` / `u_mac_tx` | UDP echo 顶层（历史） |
| `board/wrapper_tcp.v:257` / `:567` | `u_mac_rx` / `u_mac_tx` | TCP echo 顶层（历史） |
| `vivado_prj/*_prj.srcs/sources_1/imports/board/wrapper_p4.v` | 2 处/工程 | Vivado 工程内的**导入副本**（20 个工程目录各一份，是历史构建产物，**不是源码**） |

**（b）仿真门（活门矩阵会编译到的）**

| 文件:行 | 实例 | 备注 |
|---|---|---|
| `tb/tb_p4_chain.v:618` / `:940` | `u_mac` / `u_mactx` | **12/16 个活门共用**：`sim/p4gates/run_matrix_p4dfix.bat:161-172`（gate `chain`/`burst200`/`trunc50`/`trunc100`/`halfdrop`/`txdrop50`/`gate4096`/`dupstorm`/`pcackoob`/`vlanchain`/`vlanburst`/`stallgate`）都编译 `chain_src.f`，而 `sim/p4gates/chain_src.f:10-11` 明列 `rtl/mac_rx_64.v`、`rtl/mac_tx_64.v` |
| `tb/tb_p5_app.v:311/525`、`tb/tb_p5_adv.v:285/492`、`tb/tb_p5_multi.v:426/633` | `u_mac`/`u_mactx` | P5 app/对抗/多连接门 |
| `tb/tb_tcp_chain.v:159/267`、`tb/tb_tcp_echo.v:158/285`、`tb/tb_tcp_rx.v:91`、`tb/tb_tcp_tx.v:125` | | TCP 链单元/全链门 |
| `tb/tb_udp_echo.v:42/95`、`tb/tb_udp_rx.v:45`、`tb/tb_udp_tx.v:43`、`tb/tb_udprx_chain.v:201` | | UDP 单元/全链门 |
| `tb/tb_mac_rx_f4.v:53/67`、`tb/tb_f4_chain.v:40/51`、`tb/tb_app_udp_rate.v:119` | | F4/F-2 专项门 |
| `sim/**`（`sim/p4gates/evidence/**`、`sim/fffix/**`、`sim/snapcdc/review24/**` 等） | 若干 | **历史副本/对抗变体**（`*_orig.v`、`*_mut.v`、`foreign/**`），不进现役构建 |

> ⚠️ 计数口径：`tools/` 与 `_tmp_*.py` 里的清单脚本可能也 grep 这些名字；本次未逐个核对它们的选择器。

### B.2 例化点上挂着的跨域结构

**RX 方向**（`board/wrapper_p4.v:419-454`）：
```
:430-439  fifo_async #(.WIDTH(76), .DEPTH(256), .FWFT(1), .AW(8)) u_rxcdc (
              .wr_clk(gmii_clk), .wr_rst_n(reset_n), .wr_en(rxsrc_tvalid),
              .din({rxsrc_tdata, rxsrc_tkeep, rxsrc_tuser, rxsrc_tlast, rxsrc_tcrs, rxsrc_terr}),
              .full(rx_fifo_full),
              .rd_clk(dp_clk),  .rd_rst_n(reset_n), .rd_en(rx_tvalid && rx_tready),
              .dout({rx_tdata, rx_tkeep, rx_tuser, rx_tlast, rx_tcrs, rx_terr}),
              .empty(rx_fifo_empty),
              .dbg_wbin(), .dbg_rbin(), .dbg_wgray(), .dbg_rgray(),
              .dbg_occ_w(rxcdc_occ_w), .dbg_occ_r());
:440      assign rxsrc_tready = ~rx_fifo_full;      // FE 侧反压 (本地组合, 不跨域)
:441      assign rx_tvalid    = ~rx_fifo_empty;     // FWFT: dout 就是头字
```
- **WIDTH=76**（= 64+8+1+1+1+1）。⚠️ 规格书曾写 77，是**算术错**（`wrapper_p4.v:420-423`；
  `P6B_SPEC.md` §0.4.3 记为 as-built 偏离）。接成 77 位端口会**静默截掉最高位 = `tdata[63]` = 每字首字节**。
- **DEPTH=256**：下界 = 一个 1518B 最大帧 = 190 字（`wrapper_p4.v:425-427`）；
  FWFT=1 的组合读口 ⇒ **综合只落 LUTRAM**（`rtl/fifo_async.v:98-99`）⇒ 深度翻倍 = LUTRAM 翻倍。
- 默认构建（无 `DP_156MHZ`）走 `:442-454` 的**纯线名别名**分支（逐位不变契约）。

**TX 方向**（`board/wrapper_p4.v:2199-2224`）：
```
:2205-2212 fifo_async #(.WIDTH(73), .DEPTH(256), .FWFT(1), .AW(8)) u_txcdc (
               .wr_clk(dp_clk),   .wr_rst_n(reset_n), .wr_en(txsrc_tvalid),
               .din({txsrc_tdata, txsrc_tkeep, txsrc_tlast}), .full(tx_fifo_full),
               .rd_clk(gmii_clk), .rd_rst_n(reset_n), .rd_en(m_tx_tvalid && m_tx_tready),
               .dout({m_tx_tdata, m_tx_tkeep, m_tx_tlast}),   .empty(tx_fifo_empty),
               .dbg_wbin(), .dbg_rbin(), .dbg_wgray(), .dbg_rgray(),
               .dbg_occ_w(txcdc_occ_w), .dbg_occ_r());
```
- **WIDTH=73** = 64 data + 8 keep + 1 tlast —— `mac_tx_64` 的输入只有这三个字段（`wrapper_p4.v:2160`）。

**`rtl/fifo_async.v` 的握手/复位语义（事实，`rtl/fifo_async.v` 头注释 + 实现）**：
| 项 | 事实 | 行号 |
|---|---|---|
| 结构 | 灰码指针 + 两级同步（Cummings） | :80-97, :178-181 |
| 满/空 2 拍同步延迟 | **是契约的一部分**：`full` 可能**提前**拉高、可能**滞后**拉低（最坏 2 rd + 2 wr + 1 拍）。硬规则①：**只在 `full==0` 时置 `wr_en`**；硬规则②：**不许**拿 full/empty 做精确定量；硬规则③：上游不得因 full 高就断定下游没消费 | :26-46 |
| 数据可见性延迟 | 写侧被接受后**最快 2 个 rd_clk** 才能被读侧看见（`!empty` 最早出现在写入沿后第 3 个 rd 沿，外部按"采样到 empty 变 0"数则是第 4 个沿）—— 单元门 case `lat` 逐实例断言 | :47-50 |
| `full_r` **复位值 = 1（满，保守）** | F-1 修复：复位本域同步释放比原始 `rst_n` 晚 2 拍，修前 `full=0`（乐观）⇒ 尊重 full 的生产者也会丢字且不可观测 | :36-39, :198-202 |
| `empty_r` **复位值 = 1（空）** | 读侧本来就保守 ⇒ 窗口内不会误弹，两侧对称 | :42, :229 |
| `ovf_pulse = wr_en && full`；`ovf_cnt` 累计 | F-1 新增。⚠️ 统计的是**所有**被拒的写（正常运行时的满反压 + 复位释放窗口 + 违契硬写）⇒ 正确用法是**差分**，不是要求恒 0 | :136-143, :190-191, :212 |
| 复位硬契约 | **两侧复位必须同时给**（同源分两路即可）；释放时刻不同步没关系。**只复位一侧 = 未定义行为（静默脏数据）**（只复位读侧 ⇒ 多弹；只复位写侧 ⇒ 覆盖未读槽） | :52-70 |
| 占用探针 | `dbg_occ_w = wbin_r - gray2bin(rgray_s2_w)`（写域，**上界**）；`dbg_occ_r = gray2bin(wgray_s2_r) - rbin_r`（读域，**下界**）。两根都必须用**已同步**的对方指针算（用原始灰码 = 多比特 CDC） | :128-135, :282-285 |
| 不做的事 | 不做溢出/下溢保护；`mem` 不带复位（LUTRAM/BRAM 推断前提）；空态 `dout` 不定 | :72-77 |

**现役 wrapper 的接法（事实）**：`u_rxcdc` 与 `u_txcdc` 的**两侧复位都接板级 `reset_n`**
（`wrapper_p4.v:431, 434, 2206, 2208`；`ku5p_p6b_cdc.xdc` 头注释也点名这条硬规则），
`mmcm_locked` **绝不进 FIFO 复位路径**（`wrapper_p4.v:291-293`）。

**跨域约束**：`board/ku5p_p6b_cdc.xdc:30-33` 用 `set_clock_groups -asynchronous` 把三个域
（`phy1_rxc` / `sys_clk_100` / `pcie_axi_aclk`）整体摘出时序分析。
⚠️ 该文件必须 `used_in_synthesis false`（:4-10），否则 `get_clocks` 拿到空对象 ⇒
Vivado 报 `12-4739` 后**静默丢弃**该约束。施工时必须在 impl 日志里 grep `12-4739`。

---

## C. **最关键的一条：下游到底是不是已经是 64 位？**

### C.1 结论（明确回答）

> **是。数据面上所有下游模块的入口都是 64 位字流，且是"每拍一个字"（II=1）的接口。**
> ⇒ **P7b 的下游完全不用动接口**；新的 10G MAC 只要产出**同样的帧流合同**（§A.1.2 那 9 条），
> `vlan_strip → rx_classify → udp_split/slow_rx_adp/tcp_rx → …` 与 TX 侧的
> `tx_arb → udp_tx_frame/tcp_tx_frame → …` 一律**零改动**。

### C.2 逐模块核对表（入口宽度 + 是否"每拍一个字"）

| 模块 | 入口数据宽度 | 每拍一个字？ | 证据 |
|---|---|---|---|
| `rtl/vlan_strip.v` | `s_axis_tdata[63:0]` + `tkeep[7:0]` | ✅ 是（非 VLAN 帧 1 拍寄存直通 II=1，无气泡；VLAN 帧在 tag 字处 1 拍气泡 + 尾字 ≤1 拍 `S_TAIL`） | 端口 :51-58；`od_free`/`acc` :89-90；tready :105；状态机 :169-203；头注释 :32-37 |
| `rtl/rx_classify.v` | `s_axis_tdata[63:0]` | ✅ 是（`S_PASS` 直通；前 6 字在 skid 里，`DRAIN` 期 `s_tready=0` ≤6 拍/帧） | 端口 :16-23；skid :60-65；tready :102-103；⚠️ 小帧洪泛的 10G 风险已自记在 :9-11 |
| `rtl/udp_rx.v` | `s_axis_tdata[63:0]` | ✅ 是（头吸收 w0..w4 每拍 1 字；载荷 **cut-through**，`s_axis_tready = m_axis_tready \|\| !emit_v` ⇒ II=1） | 端口 :19-27；`S_HDR..S_TAIL` :107；tready :193；载荷输出字 = `{上一源字低 48 位, 当前源字高 2 字节}`（头注释 :6，**字粒度 2 字节偏移**，不是逐字节） |
| `rtl/frame_fifo.v` | `din[W-1:0]`，现役各例化 `W=73`（= 64 data + 8 tkeep + 1 tlast） | ✅ 是（每拍 1 字；BWFT 组合读 + 1 拍 BRAM 捕获，消费端零等待） | `module frame_fifo #(W=73, D=2048, AW=11)` :53-59；`rd_ok/wr_ok` :93-94；例化：`slow_rx_adp.v:89` (D=512)、`slow_tx_adp.v:68` (512)、`tcp_echo.v:93` (8192)、`udp_echo.v:76` (2048)、`udp_split.v:464` (512) |
| `rtl/crc32_8b.v` | `d[7:0]`（**8 位！**） | ❌ **不是**（1 字节/拍，`step8` 8 次移位循环 :14-32） | 只被两个 MAC 用（`mac_rx_64.v:123`、`mac_tx_64.v:114`）⇒ **随 MAC 一起重写**，不是"下游"问题。**全仓无 `crc32_64`/`crc32_8x8`**（本次已 grep 确认） |
| `rtl/app_udp_pattern.v`（演示 app） | `rx_tdata[63:0]` + `tkeep[7:0]`（接口是 64 位） | ❌ **不是**：**1 字节/拍，8 拍/字**（`rx_tready = !nx_v`，装载与比对并行 ⇒ 8 字节恰好 8 拍） | 端口 :102-114；`rx_tready` :389；RX 校验器 :352-355, :389, :455；**自报天花板 = 1G 线速**（头注释 :46-49）且**自报 10G 必须改**（:62-64：「10G 构建必须改成 8 路并行 (8 步/拍 = 1 GB/s)…本模块的参数化只留了 TX 侧，RX 侧是本次 1G 口径的定版」） |
| `rtl/slow_rx_adp.v` / `slow_tx_adp.v`（HLS 慢路径适配器） | `s_axis_tdata[63:0]`（>64 位字流） | ⚠️ 入口是 64 位字，但**输出给 HLS 的是 9 位字节流、1 字节/拍**（`hls_rx_tdata = {7'b0, o_dout}`） | 端口/头注释 `slow_rx_adp.v:3-13`、`assign hls_rx_tdata` :109、字节播放器 :150；⇒ 慢路径吞吐封顶 ≈ 1 字节 × 数据面时钟 |
| `rtl/udp_split.v` | `s_axis_tdata[63:0]` | ✅ 是 | 头注释 `udp_split.v:14`：「结构三段，**全 64bit 字流**，每级 II=1」；例化 `wrapper_p4.v:1754-1760` |
| `rtl/tcp_rx.v`（fast path） | `s_axis_tdata[63:0]` | ✅ 是（逐字解析，`wcnt` 按字推进） | 头注释 :40「来自 mac_rx_64」；:159 三站词计数口径 |
| `rtl/udp_tx_frame.v` / `rtl/tcp_tx_frame.v` | `s_axis_tdata[63:0]` | ✅ 是（输出字 = `{上一字低 N 字节, 当前字高 8-N 字节}` 的字粒度拼接） | `udp_tx_frame.v:2-18`；`tcp_tx_frame.v:8-18`（「载荷相对帧头 6 字节偏移」） |
| `rtl/tx_arb.v` / `wrapper_p4.v` 数据面 | 64 位 | ✅ 是 | `wrapper_p4.v:2179-2197`（`tx_arb` 出入均 64 位）；`s_tdata`/`f_tdata` 声明 :383-388 均 `[63:0]` |

### C.3 如果有模块还是 8 位/32 位 —— 逐个点名

**（i）`rtl/crc32_8b.v`（8 位/拍）** —— `rtl/crc32_8b.v:6-39`。
→ 不是"下游接口"问题（它只在两个 MAC 内部），但**必须换成 8 字节/拍的版本**，
并保留 `0xEDB88320` / `0xFFFFFFFF` / 无终值取反 / `0xDEBB20E3` 残留 四条语义（§A.4）。

**（ii）`rtl/app_udp_pattern.v` 的 RX 图案校验器（接口 64 位、吞吐 1 字节/拍）** ——
`rtl/app_udp_pattern.v:352, 389, 455`。
→ 这是**唯一一个"下游模块"需要在 10G 前改造的对象**（它是演示 app，但它挂在
`udp_split.app_rx_*` 上，是 RX 通路的**末端消费者**）：
- 现状：8 拍/字 ⇒ 在 156.25 MHz 下 **156.25 MB/s = 1.25 GB/s 的 1/8**。
- 模块自己写明"10G 必须改成 8 路并行"（:62-64），并给了三条候选路线
  （8 步/拍、两级流水 + 4 lane、`s_8 = M^8·s_0` 的矩阵异或树）。
- **会不会成为瓶颈**：板上默认 `i_en=1` 且它接 `udp_split.app_rx_*`（`wrapper_p4.v:2012-2029`）。
  但它是**真反压**（`rx_tready = !nx_v`，`app_udp_pattern.v:389`），反压被 `udp_split` 的帧缓冲吸收，
  不会回压到 MAC（`wrapper_p4.v:1739-1741` 的合同）。⇒ 10G 下它不会"卡死"设计，
  但会**把 app 通路限速在 ~1.25 Gbps**（并让 `udp_split` 的 app 帧缓冲长期贴满）。
  ⚠️ 【未核实】`udp_split` 帧缓冲在"10G 线速灌入 + 1/8 消费"下的长期行为（是否走 `stat_drop_ovf`），
  本次未读 `udp_split.v` 的缓冲深度与丢弃策略。

**（iii）`rtl/slow_rx_adp.v` / `rtl/slow_tx_adp.v`（64 位字 ⇄ 9 位字节）** ——
`slow_rx_adp.v:11, 109, 150`。
→ **不是本次替换引入的**：HLS 慢路径的入口本来就是"1 字节/拍 + 8 字节前导"。
它封顶 ≈ 1.25 Gbps（数据面时钟 156.25 MHz × 1 字节）。10G 下慢路径（ARP/ICMP/握手）
会被这条卡住；**P7b 是否需要动它 = 取决于 P7b 是否要 10G 下跑慢路径**，本次不做设计决定。

**（iv）HLS 本身（`udp_echo`）** —— `wrapper_p4.v:1905-1925`（`ap_clk(dp_clk)`，即 HLS 也跑在
156.25 MHz 数据面域，与 DP **无 CDC**）。它的吞吐上限是既有问题（`P6B_SUMMARY.md` 记录过
"HLS 慢路径天花板 ~25 Mbps"的旧标定），与 MAC 替换正交。

---

## D. 时钟域方案的事实基础（只给事实，不做设计决定）

### D.1 现状（as-built 事实）

| 域 | 来源 | 频率 | 谁在上面 |
|---|---|---|---|
| `gmii_clk` | 底板 RTL8211E 回送的 RXC | 125 MHz | `u_rgmii` / `u_mac_rx` / `u_mac_tx` / `vlan_strip`? **否** —— 只有前端三件（`wrapper_p4.v:280-282`） |
| `dp_clk` | 核心板 Y1 100 MHz → `clk_gen_p6b`（MMCM VCO 1250 MHz / 8） | 156.25 MHz | `vlan_strip` 及其后**全部**（`wrapper_p4.v:304-314`） |
| `pcie_axi_aclk` | 金手指 PCIe 参考钟（XDMA 内部生成 ≈250 MHz） | — | XDMA + `axi_regs` + 快照回程（`wrapper_p4.v:2504ff`） |

**两个异步边界**：`u_rxcdc`（FE→DP，W=76/D=256）与 `u_txcdc`（DP→FE，W=73/D=256），
见 §B.2。**这是"只有两个"的准确含义**：`rtl/` 数据面里再没有别的 `fifo_async` 例化
（本次全仓 grep 确认：`fifo_async` 的**非副本**例化只有 `board/wrapper_p4.v:430, 2205`，
其余在 `tb/`、`sim/**` 与 `audit_scratch/**` 的历史/对抗文件里）。

### D.2 `rtl/fifo_async.v` 的参数化程度与可复用性（事实）

| 问题 | 事实 |
|---|---|
| WIDTH/DEPTH 是参数吗？ | **是**。`parameter WIDTH=72, DEPTH=16, FWFT=1, AW=$clog2(DEPTH)`（`rtl/fifo_async.v:101-109`）。`AW` 必须是 `parameter`（不是 `localparam`），因为 `dbg_*` 端口宽度要引用它（:105-108） |
| 参数自检 | 仿真里 `DEPTH != 2**AW || DEPTH < 4 || WIDTH < 2` ⇒ `$display` + `$finish`（:146-155） |
| 能否直接复用做第三/第四个跨界？ | **结构上可以**：端口是通用 AXIS 风格（`wr_clk/wr_en/din/full/rd_clk/rd_en/dout/empty`），宽度与深度都是参数，FWFT 默认与 `fifo_sync`/`frame_fifo` 同语义（:8-17）。⚠️ 但有三条**必须一起保住**：① 两侧复位同时给的硬契约（:52-70）；② `full` 是**悲观**的、2 拍同步延迟是契约（:26-46）；③ 复用 FWFT=1 会落 **LUTRAM**（:98-99），深度 × 宽度直接吃 LUTRAM ⇒ 若新跨界要 BRAM，得用 FWFT=0（:99）。 |
| `ovf_cnt` 现在有没有被接到快照窗口？ | **没有，悬空。** `rtl/fifo_async.v:143` 声明 `ovf_cnt`，:212 单驱动累加；`board/wrapper_p4.v:430-439, 2205-2212` 两个例化**都没有接 `.ovf_pulse`，也没有接 `.ovf_cnt`**（本次 grep 确认：`stat_fifo_ovf` 只来自 `mac_rx_64` 内部的 `fifo_sync.ovf_pulse`，`wrapper_p4.v:2738` 的 W35）。 |
| 这条悬空有没有被文档记过？ | **有**：`P6E_OBS.md:86-87` 与 `:232-234` 明确写了"`u_rxcdc`/`u_txcdc` 的 `ovf_cnt` 没接进快照……这是 F-1 修复留下的板级缺口"；`P6B_SUMMARY.md:80` 同。⇒ **已知缺口，不是新发现**。 |

### D.3 `PCIE_OBS` 是不是"数据面跑 156.25MHz"的守卫？——**as-built 事实：不是**

项目 `CLAUDE.md` 里写着「`PCIE_OBS` 现在**同时**是"数据面跑 156.25MHz"的守卫（潜伏设计债）」。
**本次核实：这句在 as-built 上不成立**（更可能是 P6B 规格书时代的旧描述）。

| 宏 | 实际守卫的东西（`file:line`） |
|---|---|
| **`DP_156MHZ`** | ① 时钟拓扑本身（`wrapper_p4.v:295`，`ifdef DP_156MHZ` 里才是真 IBUFDS+MMCM）；② 两个异步 FIFO 例化（`:429, :2204`）；③ LED/UART 时间常数（`:2299` BOOT_HALF、`:2332` BLK_HALF、`:2399` UART_SW）；④ 8 个 rtl 模块里的时间常数：`rtl/app_ctrl.v:227, 240`、`rtl/app_pattern.v:291`、`rtl/app_status_uart.v:55`、`rtl/slow_rx_adp.v:27, 34`、`rtl/tcp_tx_frame.v:170`、`board/uart_dbg.v:146, 204` |
| **`PCIE_OBS`** | ① 新增端口 `pcie_sys_clk_p/n`、`pcie_txp/n`、`pcie_rxp/n`（`wrapper_p4.v:159`）；② 单域构建下 `mmcm_locked` 恒真的占位（`:324-328`）；③ **整块** XDMA `xdma_0` + `axi_regs` + `snap_cdc`/`snap_seq` 快照通道（`:2504` 起，注释见 :2505-2524） |

两个宏**已经解耦**：`DP_156MHZ` 的引入与注释就是为了修掉"用无关宏守卫时间常数"这个债
（`rtl/slow_rx_adp.v:22-26`：「为什么不用 PCIE_OBS 当守卫（对抗审查 F1）：那个宏的语义是
"例化 PCIe 观测通道"，与时钟域**无关**」；`P6B_SPEC.md:170` 记录的正是这个债；
`P6B_REVIEW.md` F1 是它）。现役构建**两个宏一起定义**
（`board/build_p6b_final_ku5p.tcl:110`：`{APP_MODE=1 DEV_USP=1 PCIE_OBS=1 DP_156MHZ=1}`）。

**⇒ 10G 版本会受什么影响（只报事实与风险）**：
1. **`DP_156MHZ` 的名字与语义都不够用了**。10G 进来后数据面会有**新的域**：
   P7a 的 as-built 已经把它们建出来并跑通了 —— `gtwiz_userclk_tx_usrclk2_out`（TX 载荷域）
   与 `gtwiz_userclk_rx_usrclk2_out`（RX 恢复域），两者**都标称 156.25 MHz 但彼此独立**
   （`_proj_10g/rtl/p7a_top.v:21-27, 146-149`；P7a 用 `clk_tx`/`clk_rx` 两个 wire 区分）。
   ⚠️ 它们与 `dp_clk`（Y1→MMCM）是**第三个、第四个**独立时钟，有 ppm 偏差。
   ⇒ 任何"数据面跑 156.25MHz"的**时间常数**在 10G 下必须重新回答"跑在哪个 156.25MHz 上"。
2. **"数据面频率正证据"这条判据会失去独立性**。`W24 = dp_free`（`wrapper_p4.v:2599-2602, 2712`）
   的判据是「ΔW24 / 墙钟间隔 = 156.25 MHz ±1%」，它是数据面真跑新时钟的**唯一正证据**。
   P7a 明确写过为什么频标必须取 `clk_obs` 而不是 GT 时钟：
   「`clk_obs` 来自核心板晶振经 MMCM，所以 1.0 的比值只有在 64/66 baud 携带 64 载荷位时才可能
   —— 即 gearbox 在数据通路里」（`_proj_10g/rtl/p7a_top.v:25-29`）。
   ⇒ **若 10G 版把数据面时钟改成 GT 的 usrclk2，这条"独立于收发器配置"的性质就没了**
   （用 GT 自己的时钟去证明 GT 自己在跑，是自证）。这是必须保住/重述的既有判据。
3. **快照窗口的"跨域完整性"负担会变重**。现在是"FE 束 + DP 束"两束、由 `snap_seq` 链式定序
   （`wrapper_p4.v:2537-2544`，`SNAP_NW_P6E=36 / SNAP_FE_NW=14 / SNAP_DP_NW=22`）。
   10G 后会多出 TX 域/RX 域 ⇒ 又一批"新时钟域的正证据"字与新的束。
   ⚠️ 扩窗是**七处同改**（`wrapper_p4.v:2531-2544`），漏一处的症状是"高位悬空 ⇒ 读回 X"
   或"读到另一个字的正确值"，**lint 全程沉默**（`P6B_SPEC.md` §0.4.3）。
4. **`DP_156MHZ` 现在同时是 `rtl/` 里 8 个模块的时间常数开关**（上表④）。
   10G 版若新增/替换数据面域，这 8 处的取值口径要**逐处重新判定**（不是"跟着新宏整体翻倍"）。

### D.4 与"1 字节/拍"有关的**新风险**（事实，供 P7b 决策）

这两条不是下游接口问题，是**被替换模块内部**的：

1. **`mac_tx_64` 的成帧开销是字节串行的**：前导 8 拍（`mac_tx_64.v:143-162`）、
   最少 0 最多 ~60 拍的 pad（:194-207）、FCS 4 拍（:208-215）、IFG 12 拍（:216-223）。
   合计**每帧最少 24 拍**（8 前导 + 4 FCS + 12 IFG）**与帧长无关**。
   64 位版若照搬这套"每拍一字节"的状态机，小帧（64B 线上 = 8 字 = 8 拍载荷）
   的帧周期会变成 ≥ 24 拍 ⇒ **帧率只有线速的 ~1/3**。
   【推断，非实测】⇒ 这条必须在 10G 版按字重排（未核实是否有现成方案）。
2. **`mac_rx_64` 的前导检测与 CRC 都是字节串行**（`mac_rx_64.v:210-228`、`:123`），
   64 位版必须把它们改成字粒度（XGMII 控制字符或 8 字节并行 CRC）。

---

## E. 开放问题 / 未核实项

| # | 问题 | 状态 |
|---|---|---|
| E1 | **【未核实】** 10G 版选 PG157 的**哪种接口**（原生 XGMII 风格 `tdata+keep+ctrl`，还是 AXIS `tkeep` 风格）—— 这决定"帧流合同 shim"要做多少。本文只核到 P7a 用的是 `gt_10gbr` 例化 + `gtwiz_*` 端口（`_proj_10g/rtl/p7a_top.v`），**没有**任何 AXIS/XGMII 数据面代码。 | 未核实 |
| E2 | **【未核实】** `udp_split.v` 的 app 帧缓冲在"10G 线速灌入 + `app_udp_pattern` 1/8 消费"下的长期行为（`stat_drop_ovf` / 帧缓冲深度）。本次只读了它的头注释与例化点，没读它的缓冲与丢弃逻辑。 | 未核实 |
| E3 | **【未核实】** 新 MAC 的 FIFO 字宽（现 RX=76 / TX=73）在新帧流合同下是否变化（若 10G MAC 不带 `terr`/`tcrs`，或 PCS 侧还要带 XGMII 控制位）。**四处同改**：`fifo_async` 的 `WIDTH`、`din`/`dout` 拼接、`wrapper_p4.v:432/435` 与 `:2207/2209`。 | 未核实 |
| E4 | **【未核实】** `sim/p4gates` 矩阵里是否还有 `tools/` 的脚本按文本 grep `mac_rx_64`/`mac_tx_64` 的字面（本次只查了 `.v` 与门 bat / `chain_src.f`）。 | 未核实 |
| E5 | **已知缺口（文档已记）**：`u_rxcdc`/`u_txcdc` 的 `ovf_cnt` 悬空（`P6E_OBS.md:86-87, 232-234`），板级无法回读"有没有字被静默拒写"。 | 已记 |
| E6 | **本次新发现缺口**：`mac_tx_64` 的 `stat_flush_words` / `stat_flush_done` 在 `board/wrapper_p4.v:2226-2239` **未连接**，快照 36 字里也没有对应字 ⇒ **F-2 修复在板级不可观测**（属 F-1 同类"修复有计数但没接出来"）。 | 本文首次记录 |
| E7 | **文档与 as-built 分叉**：项目 `CLAUDE.md`「`PCIE_OBS` 同时是数据面 156.25MHz 的守卫」与 as-built 不符（真守卫是 `DP_156MHZ`，§D.3）。`P6B_SUMMARY.md:28`「全部包在 `ifdef PCIE_OBS` 内」同属 P6b 时代的旧描述。⇒ **建议 P7b 施工前先订正文档**，否则会被误导去动错的宏。 | 本文记录 |
| E8 | **【未核实】** `rtl/rx_classify.v:10-11` 自记的"10G min-frame 洪泛 ⇒ mac 层计数丢帧（skid 改真 FIFO 已记入 P6 清单）"这条清单项是否已在 P6b 落地。本次只读到那条注释，没找到对应改动。 | 未核实 |

---

## 附：本次侦察读过的文件（全部只读）

`rtl/mac_rx_64.v`、`rtl/mac_tx_64.v`、`rtl/fifo_sync.v`、`rtl/fifo_async.v`、`rtl/crc32_8b.v`、
`rtl/vlan_strip.v`、`rtl/rx_classify.v`、`rtl/frame_fifo.v`、`rtl/udp_rx.v`(前 200 行)、
`rtl/app_udp_pattern.v`(头注释 + 端口 + RX 校验器索引)、`rtl/slow_rx_adp.v`(头注释 + 端口)、
`rtl/udp_split.v`/`udp_tx_frame.v`/`tcp_tx_frame.v`(头注释)、
`board/wrapper_p4.v`(节选 :270-530 / :1700-2030 / :2150-2280 / :2495-2780)、
`board/ku5p_p6b_cdc.xdc`、`board/build_p6b_final_ku5p.tcl`、
`_proj_10g/rtl/p7a_top.v`(头注释 + 时钟段)、`sim/p4gates/run_matrix_p4dfix.bat`、`sim/p4gates/chain_src.f`、
`tb/tb_p4_chain.v`(节选)、`P6B_SPEC.md`(节选)、`P6E_OBS.md`/`P6B_SUMMARY.md`(grep)。
**未找到** `rtl/mac_tx_frame.v`（全仓 find 无此文件；`rtl/` 下同名近亲是 `udp_tx_frame.v` / `tcp_tx_frame.v`）。
