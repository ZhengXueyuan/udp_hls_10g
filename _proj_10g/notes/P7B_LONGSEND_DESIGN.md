# P7B_LONGSEND_DESIGN —— 长时间不停发送的 TCP app（单连接持续下行）+ 在飞窗口上限提升 + 台架长流支持

> **本件 = 设计件（施工规格）**。撰写时不改任何 RTL / TB / 构建脚本，不烧板，不跑构建，不做 git 写操作。
> 所有 `文件:行` 触点均由撰写者**读源码逐条核过**（核过/没核过见 §6）。凡引自文档而非源码的数字，一律标注
> "**来自文档**"；凡标注"**未确定**"的不许在施工时按猜测填。
> 仓库 = `D:\repo\XCKU5PMini\udp_hls_10g`（git 仓库根就是它自己）。

---

## §R 事实核对（背景 1–13 逐条；**这里是订正表，先读**）

| 背景条 | 核对结论 | 证据（文件:行） |
|---|---|---|
| 1 `remain` 单装载/单递减/读取点 | ✅ **全部成立** | 装载 `rtl/app_pattern.v:599`；递减 `:770-771`（被 `:769 if(!bad_frm)` 包）；`asm_go` 读点 `:451`（`P7B_10G` 支）/ `:456`（默认支）；终结判据 `:676`；下一帧长 `:688-690` / `:736-738` |
| 2 终结分支 `:670-683`、`AUTO_CLOSE` 只门控 `close_req` | ✅ **成立** | `:670` `if (need == 4'd0)` … `:680-682` `if (AUTO_CLOSE) begin close_req <= 1'b1; close_id <= act_id; end`；`:677-679` 的 `active<=0/done<=1/op_*<=0` **不受** `AUTO_CLOSE` 门控 ⇒ "把 `AUTO_CLOSE` 置 0 就能连续"**不成立** |
| 3 FIN 全链 | ✅ **成立**（行号微调） | `:681-682` → `board/wrapper_p4.v:1190-1191`（`.close_req/.close_id`）→ `rtl/app_ctrl.v:1363-1366`（`if (close_req) begin fin_req[close_id] <= 1'b1; stat_cmd_close++; end`，**无 state 门控**，块尾在 `:1366`）→ `wrapper_p4.v:2067`（`tx_fin_req = app_fin_req`）→ `:2116`（`.fin_req(tx_fin_req)`）→ `rtl/tcp_tx_frame.v:56`（端口）→ 排队门 `:656-658`（要求 `rb_state==1 && rb_snd_nxt == rb_snd_una && !ackq_full && !fin_sent_r[scan_id]`） |
| 4 `TX_BYTES=0` = 静默停滞 | ✅ **成立**（我独立复核了链条） | `:619-620` 第二支 `TX_BYTES[11:0]=0` ⇒ `seg_len=0`；`:403` `op_beat` 含 `(seg_len != 12'd0)` ⇒ 恒 0 ⇒ `:748-751` 不可达 ⇒ `op_pend` 恒 1 ⇒ `asm_go`（`:449-451`/`:455-456`）被 `!op_pend` 挡住 ⇒ `:670-683` 与 `:732-742` 全不可达 ⇒ `active` 恒 1、线上零帧、`done` 不置、`close_req` 不发，直到 `ev_down`（`:634-636`）或复位 |
| 5 回归面（4 处判据 + 6 处 `TX_BYTES=0` 实例） | ✅ **全部成立** | `tb/tb_app_rx8_equiv.v:506-508`（`t_txb==30000` / `t_txf==21` / `t_done==1`）· `tb/tb_app_a2_equiv.v:384`（`chk(w_txb[ii]==BYTTAB[...])`）与 `:401`（`w_txb[12]==32'd7460`）· `tb/tb_integ_app_tx.v:15`（J5 守恒）· `tools/gen_stim_p5_app.py:361-365`（`pat_tx_bytes != tx_bytes_cfg` / `pat_done==0` 两条 errs）；6 个纯 RX 实例 = `tb_app_rx8_equiv.v:144/154/164/174/184/256`（均 `.TX_BYTES(32'd0)`） |
| 6 常驻矩阵对这三门命中 0 | ✅ **成立**（实测 `grep -c` = **0**） | `sim/p4gates/run_matrix_p4dfix.bat` 里 `app_rx8`/`app_a2`/`integ_app_tx` 命中 0；⚠️ **且我核出矩阵根本不编译 `rtl/app_pattern.v` 与 `board/wrapper_p4.v`** —— 见背景订正 ⑥ |
| 7 `sim/` 下 21 个 `app_pattern #(` 镜像件（禁全局替换） | ⛔ **数字错**：实测 **71 个文件**含 `app_pattern #(`（其中 19 个 `tb_*.v`、19 个 `rtl/app_pattern.v` 镜像、其余为 `wrapper_p4.v`/`tb_p5_app.v` 等） | `grep -rl "app_pattern #(" sim/ \| wc -l` = 71；含 `sim/p5bfix/`、`sim/p5c_t4neg/neg_*/rtl/`、`sim/p5d_d1neg/*/rtl/`、`sim/p5e_win/`、`sim/p7b_stage*/…`；**"刻意外来夹具"在 `sim/p4gates/evidence/negctl/foreign/tb/` 确实存在** ⇒ **禁止任何全局 grep 替换**这条纪律不变（且现在有 71 处而不是 21 处，风险面更大） |
| 8 wrapper 的 app 例化只传 2 个参数 | ✅ **成立** | `board/wrapper_p4.v:1177-1208`：`.TX_BYTES(32'h0FFFFFFF), .TX_SEGSZ(12'd1460)`；`:1198` `.i_bad_frame(16'd0)`；`:1203-1206` `.active()/.act_id()/.done()/.dbg_lfsr()` 悬空 |
| 9 观测面 | ✅ **成立** | `W51..W62` 归属见 `_proj_pcie/p7b_biz/p7b_snap.sh:102-106`（真值源 = `wrapper_p4.v` 装配段）；速率 `P = ΔW43/ΔW20`（W43=`mac_tx_10g.stat_tx_words`、W20=MAC 帧数）、时基 W5；**`active/act_id/done` 不在快照**（`:1203-1206` 悬空） |
| 10 `--maxbytes` 默认 4 MiB = 每连接唯一终止条件 | ✅ **成立，并订正一处** | 循环 `while (got < a->maxbytes)`：`_proj_pcie/p7b_biz/p7b_tcp_sink.cpp:126`（双线程 I/O 线程）/ `:335`（单线程路径）；默认 `:210` `long maxbytes = 4L << 20;`；解析 `:224`；`got` 是 `long long` `:122`。⛔ **订正 ④（重要）**：`--seconds` **不终止正在跑的连接** —— `secs` 只在外层连接循环入口判一次（`:287` `if (p7b_io_now_s() - t_start > secs) break;`），一条已建立的连接只可能被 `maxbytes` / 对端 FIN(`:154` `if (n == 0) break;`) / STALL(`:129-137`，默认 3×5000 ms)/ 外部 `timeout` 终止 |
| 11 板上无 ≥33 位计数器 | ✅ **成立**（我复算） | 回卷周期 = 2³²/速率：`W51/W15/W53/W54` @9.3–9.4 Gbps ⇒ **3.65–3.70 s**（题面写 3.6 s ✓）；`W5/W24/W43/W29` @156.25 MHz ⇒ **27.487 s**；`W20/W8/W10/W52` @≈813.8 kfps ⇒ **5277 s ≈ 88 min**（题面写 88 min ✓）。**全部为算术，非源码读数** |
| 12 现役构建宏与常量 | ✅ **成立** | `board/build_p7b_ku5p.tcl:153`（`verilog_define {APP_MODE=1 DEV_USP=1 PCIE_OBS=1 DP_156MHZ=1 P7B_10G=1 UDP_TX_OVL=1 TCP_TX_OVL=1}`）；`wrapper_p4.v:1177`（`TX_BYTES=32'h0FFFFFFF`）/ `:3911`（`BUILD_ID_V (32'h00000015)`）；构建入口 = `board/run_build_p7b_ku5p.bat`（自带 #54 的 pre-build 归档块） |
| 13 #64 纪律与现役 WNS | ✅ **成立**（数值出自文档） | `WNS +0.052 / 0/0/0` 与"2²⁰→2³¹ 把 `+0.014` 吃到 `−0.035`"来自文档 `_proj_10g/notes/P7B_LONGFLOW_DESIGN.md:590-607`（**未回时序报告原件逐字核**）；#64 机制（`.TX_BYTES` 装载进 `remain`、`remain==32'd0` 在 `asm_go` 使能锥上）我已在源码里对照 `:451/:456/:599/:676` |

### 背景之外、**本刀必须知道的 5 条新发现**（都是我读源码/脚本得到的）

**① `tcp_tx_frame.RING_CAP` 在 body 里没有任何功能使用。**
`grep -n "RING_CAP" rtl/tcp_tx_frame.v | grep -v "//"` 只剩 `:196` 的参数声明本身；`:187-196`、`:1219-1225` 全是注释。
真正的门控是 `rtl/tcb.v:143-145` 的注册输出 `win_open = ((snd_nxt - snd_una) < min(snd_wnd, WIN_CAP))`（`tcp_tx_frame.v:1227`
`wire wnd_open = win_open;`）。⇒ **`WIN_CAP_5` 的功能面只有两处**：`tcb.WIN_CAP` 与 `app_ctrl.WIN_CAP`（`:568`
`eff = (wnd < WIN_CAP) ? wnd : WIN_CAP;`）。`tcp_tx_frame #(.RING_CAP(...))` 那一处**必须跟着改**（单一来源契约 + 注释里的
不变量），但它**不产生网表差异**（§2.2-(9)）。

**② 板上 `app_ctrl` 的寄存器总线是静止的 ⇒ 主机侧没有"命令停发/关闭"通路。**
`board/wrapper_p4.v:1286-1289`：`assign app_reg_addr = 8'h00; assign app_reg_wr = 1'b0; assign app_reg_wdata = 32'd0;`
（注释逐字："P5 寄存器总线默认静止 (板级无 CPU/AXI; 将来接 AXI-Lite 桥)"），且全文件仅此一处驱动 ⇒ **CMD(0x06) 的
close/abort、配额(0x0C) 在板上都写不进去**（`app_ctrl.v:1352-1360` 的 CMD 块与 `:1372` 只对 TB 有效）。
⇒ 直接决定 §1.6：**停止手段只有两条**。

**③ `sim/p7b_stagec_tx_regress/run_arm.bat` 与 `run_extra_head.bat` 都**不**跑本 tree。**
- `run_arm.bat:5` = `mirror\sim\p4gates\run_matrix_p4dfix.bat -only chain` ⇒ 跑的是 **mirror 快照树**
  （`sim/p7b_stagec_tx_regress/mirror/rtl/app_pattern.v` sha256 = `0e804099…ce06` = 与**改动前**的现役文件逐字节相同，见 ⑤）；
- `run_extra_head.bat:5` 调 `extra_head/{p5_wrapper,p5_pattern}/run.bat`，而两者都写死
  `set RTL=…\sim\p7b_stagec_tx_regress\head_rtl`（**绝对路径 + 快照**，`head_rtl/app_pattern.v` sha256 `da7a2c7c…99e1`
  ≠ 现役 `0e804099…ce06`；`grep -c P7B_10G`：head_rtl=5 / 现役=10 ⇒ 那是 **Stage B 期的 app_pattern**），
  而 `BD=%REPO_ROOT%\board`、`TB=%REPO_ROOT%\tb` 是**活件** ⇒ **混合编译（旧 rtl + 活 wrapper）**；
- ⛔ `run_extra_head.bat:9` 是**无条件 `exit /b 0`**（哑门，#53 同族）⇒ **它的 RC 永远不是判据**，只能读
  `head_log_p5_wrapper.txt` / `head_log_p5_pattern.txt` 的内容。
⇒ 结论：本刀可用的**活门**只有 `sim/p7b_stageb_rx8/run_rx8_gate.bat`（`set "RTL=%ROOT%\rtl"`，`:30/:38-40`，跑活
`rtl/app_pattern.v` + 活 TB）与 `sim/p7b_stagec_tx_regress/author_gate/run_tx_ovl_gate.bat`（跑活
`rtl/tcp_tx_frame.v`，突变件由 `mk_mut_tx.py` 从活文件生成）。详见 §4.1。

**④ `--maxbytes 0` 不可能是"无限"。**
`p7b_tcp_sink.cpp:126` 的 `while (got < a->maxbytes)` 在 `maxbytes == 0` 时**循环体一次都不执行** ⇒ 立刻走到收尾
⇒ 末行 `:405` `return (bad_conns == 0 && fail_conns == 0 && tot_bytes > 0) ? 0 : 1;` 因为 `tot_bytes == 0` ⇒ **RC = 1（假红）**。
⇒ §3.1 的判决据此。

**⑤ 现成的"改动前锚"已经在仓里。**
`sim/p7b_stagec_tx_regress/frozen/app_pattern_rev0e804099.v` 与**现役** `rtl/app_pattern.v` **sha256 逐字节相同**
（`0e804099400c2e2b800ef66bbf49d0d26892bb977e4523de208581ef0d81ce06`，15,431,261 B 是位流的事、此处是源码）
⇒ 它就是本刀的**默认关等价锚**（§4.3）。⚠️ `frozen/tcp_tx_frame_rev1a1f0439.v` 是**另一份**快照（本刀不改它的消费者）。

---

## §0 判决（要点）

1. **§1 = 新增参数 `TX_CONTINUOUS`（默认 `1'b0`）+ 一处重装载**，共 **6 个改动点**、净增 ~12 行；`TX_CONTINUOUS=0`
   时**每一个被改的表达式都按常量传播逐字退化**（§1.4 有逐条论证，§4.3 要求用冻结件做**实证**）。
2. **判决：不把 `AUTO_CLOSE` 置 0 当实现手段**。它只门控 `close_req`（背景 2）；置 0 的结果是"数据停、`active` 落 0、
   `done=1`、连接悬挂不发 FIN" —— 比现在更坏，且**不满足"不停发送"**。
3. **`TX_BYTES=0 && TX_CONTINUOUS=1` 判为非法配置，结构性退化为今天的"静默停滞"行为**（用编译期常量
   `CONT_OK = TX_CONTINUOUS && (TX_BYTES != 32'd0)` 保证是**结构性**而不是巧合）。
4. **§2 = `WIN_CAP_5` `16'hBFFE → 16'hF000`（49150 → 61440 B，+25%）**，功能面只有两个 16 位比较常量
   （`tcb.WIN_CAP` / `app_ctrl.WIN_CAP`）。不变量在"真实帧长上界 1508 B"下**单帧与双帧两种口径都成立**（余 2589 / 1081 B）；
   **4095 那一档只有单帧口径成立**（余 2 B），复合口径不成立 ⇒ 裁决口径必须写"≤1508 B/帧"（§2.2）。
5. **§3 = 台架只改一处**：`p7b_tcp_sink.cpp` **新增一行自证**（`SINK_LIMITS`），**不改任何既有字段/语义**；
   长流的每连接终止条件改由**命令行显式大 `--maxbytes`** 承担（判决与理由见 §3.1）。
6. **§4 = 三条硬纪律**：① 只跑**活门**（`run_rx8_gate` + 新门 + `run_tx_ovl_gate` 对照），矩阵全绿对本刀是**空证据**；
   ② 一次构建收口（两处改动同批）+ 三类失败端点必须 `0/0/0`；③ 板级两臂：**连续臂 vs S3 位流负对照臂**，
   判据 = **对端 `bytes` 封顶在 `TX_BYTES` 还是继续涨**（判别力 128×）。
7. **本刀不动 `rtl/tx_arb.v`**（慢路径有界等待 aging）—— 登记在 §5.2，只写形状与代价。

---

## §1 TCP 连续发送模式（构建 A 的主体）

### 1.1 新参数与两个新线网（逐字）

**改点 1 —— 参数表**（`rtl/app_pattern.v:26-32`，把 `AUTO_CLOSE` 那行加逗号并追加一行）：

```verilog
module app_pattern #(
    parameter [31:0] TX_BYTES   = 32'd1048576,  // 1MB
    parameter [11:0] TX_SEGSZ   = 12'd1460,
    parameter [11:0] BAD_LEN    = 12'd2000,     // 注入坏帧长度 (> PLEN_MAX=1500)
    parameter [63:0] SEED       = 64'h9E3779B97F4A7C15,
    parameter        AUTO_CLOSE = 1'b1,         // 发完自动 close_req
    // ⭐ P7B-LONGSEND: 1 = 连续发送模式 (永不结束会话; 见 _proj_10g/notes/P7B_LONGSEND_DESIGN.md)
    //   默认 1'b0 ⇒ 全部既有例化 (含 sim/ 下 71 个镜像件) 行为逐位不变。
    parameter        TX_CONTINUOUS = 1'b0
) (
```

> ⚠️ 全仓例化都是**具名**参数（`grep "app_pattern #("` 71 处，抽查无位置式），但**仍不要**把新参数插在中间——
> 追加在末尾是对"位置式例化"也安全的唯一位置。

**改点 2 —— 编译期常量 + 两个线网**（插在 `wire tx_ok = app_tx_ready[act_id];`（`:352`）**之前**；
注意 xvlog 先声明后用，工程坑 22）：

```verilog
    // ---- ⭐ P7B-LONGSEND: 连续发送模式 ----
    // CONT_OK = 连续模式**有效**。这是**常量表达式** (纯参数) ⇒ 综合期常量折叠:
    //   TX_CONTINUOUS=0 ⇒ CONT_OK ≡ 1'b0 ⇒ 下面所有新增逻辑整条消失 (逐位退化)。
    //   TX_BYTES=0 视为非法配置 ⇒ CONT_OK=0 ⇒ 退化为今天的"TX_BYTES=0 静默停滞"
    //   (结构性退化, 不是巧合; 见设计件 §1.3①)。
    localparam CONT_OK = TX_CONTINUOUS && (TX_BYTES != 32'd0);
    // 帧边界处 remain 耗尽 ⇒ 重装载一个量子。LFSR **不**重装载 ⇒ 线上图案流无缝。
    // ⚠️ 复用同一个 `remain == 32'd0` 表达式 (它在 :451/:456/:676 已存在) ⇒ 不新增
    //    32 输入归约 (全局 #64 的机制点)。
    wire        cont_reload = CONT_OK && (remain == 32'd0);
    wire [31:0] remain_nxt  = cont_reload ? TX_BYTES : remain;
```

### 1.2 精确改法（其余 4 个改动点，逐字 old → new）

**改点 3 —— 终结判据 `:676`**（唯一禁止"结束"的地方）：

```verilog
// 旧:
                    if (remain == 32'd0) begin
// 新:
                    if ((remain == 32'd0) && !CONT_OK) begin
```

**改点 4 —— `tx_ok` 臂的"下一帧"（`:684-694`）**：`remain` → `remain_nxt`，末尾加一行重装载：

```verilog
// 旧 (行号 :684-694):
                    end else if (tx_ok) begin
                        // 下一帧长度 (坏帧注入: 第 i_bad_frame 帧)
                        bad_frm <= (i_bad_frame != 16'd0) &&
                                   ((frm_idx + 16'd1) == i_bad_frame);
                        seg_len <= ((i_bad_frame != 16'd0) &&
                                    ((frm_idx + 16'd1) == i_bad_frame)) ? BAD_LEN :
                                   ((remain > {20'b0, TX_SEGSZ}) ? TX_SEGSZ : remain[11:0]);
                        seg_sent <= 12'd0;
                        bcnt <= 4'd0;
                        // P5e: 新帧先发 0 载荷 opener (帧首字), 载荷等它落地
                        op_pend <= 1'b1; op_sent <= 1'b0;
                    end else begin

// 新:
                    end else if (tx_ok) begin
                        // 下一帧长度 (坏帧注入: 第 i_bad_frame 帧)
                        bad_frm <= (i_bad_frame != 16'd0) &&
                                   ((frm_idx + 16'd1) == i_bad_frame);
                        seg_len <= ((i_bad_frame != 16'd0) &&
                                    ((frm_idx + 16'd1) == i_bad_frame)) ? BAD_LEN :
                                   ((remain_nxt > {20'b0, TX_SEGSZ}) ? TX_SEGSZ : remain_nxt[11:0]);
                        seg_sent <= 12'd0;
                        bcnt <= 4'd0;
                        // P5e: 新帧先发 0 载荷 opener (帧首字), 载荷等它落地
                        op_pend <= 1'b1; op_sent <= 1'b0;
                        // ⭐ 连续模式: 量子耗尽 ⇒ 重装载 (图案 LFSR 不动 ⇒ 线上无缝)
                        if (cont_reload) remain <= TX_BYTES;
                    end else begin
```

**改点 5 —— `frm_wait` 解除臂（`:736-738` +`:741`）**：同一个理由（**这个点必须一起改**，否则会踩 §1.5 的陷阱）：

```verilog
// 旧 (行号 :736-741):
                seg_len  <= ((i_bad_frame != 16'd0) &&
                             ((frm_idx + 16'd1) == i_bad_frame)) ? BAD_LEN :
                            ((remain > {20'b0, TX_SEGSZ}) ? TX_SEGSZ : remain[11:0]);
                seg_sent <= 12'd0;
                bcnt     <= 4'd0;
                op_pend  <= 1'b1; op_sent <= 1'b0;   // P5e: 同样以 opener 起帧

// 新:
                seg_len  <= ((i_bad_frame != 16'd0) &&
                             ((frm_idx + 16'd1) == i_bad_frame)) ? BAD_LEN :
                            ((remain_nxt > {20'b0, TX_SEGSZ}) ? TX_SEGSZ : remain_nxt[11:0]);
                seg_sent <= 12'd0;
                bcnt     <= 4'd0;
                op_pend  <= 1'b1; op_sent <= 1'b0;   // P5e: 同样以 opener 起帧
                // ⭐ 连续模式: 量子耗尽 ⇒ 重装载 (与 tx_ok 臂同一件事, 两处都要有)
                if (cont_reload) remain <= TX_BYTES;
```

**改点 6 —— 例化点**（`board/wrapper_p4.v:1177`）：

```verilog
// 旧:
    app_pattern #(.TX_BYTES(32'h0FFFFFFF), .TX_SEGSZ(12'd1460)) u_app (
// 新:
    app_pattern #(.TX_BYTES(32'h0FFFFFFF), .TX_SEGSZ(12'd1460),
                  .TX_CONTINUOUS(1'b1)) u_app (
```

### 1.3 边界定义（**五条，逐条给判决**）

**① `TX_CONTINUOUS=1 且 TX_BYTES=0` ⇒ 判决：非法配置，结构性退化为今天的 `TX_BYTES=0` 行为。**
- 机制：`CONT_OK` 里带 `(TX_BYTES != 32'd0)` ⇒ 该配置下 `CONT_OK ≡ 0` ⇒ `cont_reload ≡ 0`、`:676` 的 `!CONT_OK ≡ 1`
  ⇒ **模块行为与"今天用 `TX_BYTES=0`"逐位相同**：`active` 恒 1、线上零帧、不置 `done`、不发 `close_req`（背景 4 的链条）。
- **为什么不做成"0 = 无限"**（像 UDP 版 `rtl/app_udp_pattern.v:529/537/853` 那样）：
  (a) 背景 4 明确禁止把 UDP 的 0 语义照搬；
  (b) 那会要求 `seg_len` 的两处装载表达式各加一支（12 位 mux + 一个常量比较）⇒ **多两处 #64 改动面**；
  (c) 交互更坏：现在 `TX_BYTES=0` 在 6 个 TB 实例里是"纯 RX 实例"（背景 5），把 0 变成"无限发"会让**一个参数值同时
  表示两种意图**，而这正是本工程已经吃过一次亏的形态（`0x08` 既是 SCRATCH 又是 TX_DIS 门）。
- **施工要求**：连续模式构建的 `.TX_BYTES` **必须非 0**。推荐**保持 `32'h0FFFFFFF` 不动**（理由：少改一个常量，
  且 227 ms 一个量子 ⇒ 任何 ≥0.5 s 的跑都会**真的走过重装载点**，重装载路径不是死代码）。
- **判据**：TB 的 u4/u5 等价臂（§4.2-A10）。
- ⛔ **实现轮登记 (2026-10-09, 对抗审查 ②)**: **非法配置只排除了 `TX_BYTES == 0`，没排除 `TX_SEGSZ == 0`**。
  `TX_BYTES≠0 ∧ TX_SEGSZ==0` 在 `ev_up` 上装载 `seg_len = (TX_BYTES > 0) ? 0 : … = 0` ⇒ 落进 §5.1 的静默停滞
  —— **这是既存行为（任何模式都有），不是连续模式引入的**，且加不加 `CONT_OK` 的 `TX_SEGSZ` 项**行为逐位相同**
  （无帧 ⇒ `remain` 永不归零 ⇒ `cont_reload` 也不触发；`asm_go` 被 `op_pend` 恒 1 挡住）。
  ⇒ **本轮选择"明文登记"**（不改 `CONT_OK` 的表达式：不加 `TX_SEGSZ != 0` 项）—— 理由 = ① 行为零差异；
  ② 改表达式会让"六个改动点"的对抗审查文本作废（审查已逐条核对过这六处）；③ 少一处 #64 风险面。
  ⚠️ 若日后要把它变成显式非法：改 `CONT_OK = TX_CONTINUOUS && (TX_BYTES != 32'd0) && (TX_SEGSZ != 12'd0);`
  **并重跑本刀的全部门**（它只影响常量折叠面）。

**② 对端 `ev_down`（对端关连接）⇒ 判决：保持既有 W3 语义一字不动。**
`ev_down` 置 `closing`（`:634-636`）⇒ W3 收尾块（`:643-666`）把当前帧以 `tlast` 闭合（必要时用 0 载荷收尾字）
⇒ `active <= 1'b0`，**不发 `close_req`**、`done` 保持（连续模式下 = 0）⇒ app 回 idle。
⇒ **连续模式下"会话结束"只由对端驱动**（或复位/重烧）。这正是"永不结束"的正确外部含义：结束权在对端。

**③ `ev_restart`（同槽重连）⇒ 判决：既有路径不动。**
`ev_up` 块（`:575-627`）已含"换流"逻辑：`remain <= TX_BYTES`、`frm_idx <= 0`、`op_pend <= 1`、`tx_lfsr <= SEED`、
`seg_len <= min(TX_SEGSZ, TX_BYTES)`。连续模式**不加任何东西**：新会话从头（图案也从 SEED 起）。
对端关闭后的新连接能再起，靠的是 `ev_restart` 的 `!active` 臂（`:595` `if (!active || ...)`），无需新逻辑。

**④ `done` 的语义 ⇒ 判决：连续模式下永不置位（且是常量关死，不是"忘了置"）。**
`:677-678` 的 `active<=0; done<=1` 随终结分支一起被 `CONT_OK` 关死 ⇒ 综合期 `done` 变常量 0（唯一置位点没了）
⇒ 其 FF 可被优化掉。语义上这是**对的**：`done` 的原意是"app 至少跑完过一轮 `TX_BYTES`"（`:612-615` 的注释），
连续模式**没有"跑完"这个事件**。
⚠️ **副作用登记**：`led_r[3] <= done`（`:825`）在连续构建里恒 0 ⇒ 板上"done"指示灯永不亮。**本刀不改**（另接一个
活动指示要动 RTL、吃余量；登记进 §5.6）。⚠️ **TB/台架不许拿 `done` 当完成判据**（改成帧数/字节数）。

**⑤ `close_req`/`fin_req` 永不置位对 `tcp_tx_frame` 扫描逻辑的副作用 ⇒ 判决：零副作用。**
逐条核过（`rtl/tcp_tx_frame.v`）：
- `fin_push`（`:656-658`）以 `fin_req[scan_id]` 为首项 ⇒ **恒 0** ⇒ FIN 永不进 `ackq`；
- ⇒ `fin_sent_r` 恒 0 ⇒ `tx_blk = fin_req | fin_sent_r | rst_sent_r | rst_req`（`:449`）恒 0 ⇒ `tx_blk_sid`
  （`:1301` `tx_blk[start_id] | ~st_ok`）只剩 `~st_ok` ⇒ **数据启动门不因 FIN 而关**（这正是要的）；
- `retx_deny`（`:477` `blocked && fin_sent_r[svc_id]`）恒不触发 ⇒ 重传会话不受影响；
- `o_fin_sent` 恒 0 ⇒ `app_ctrl` 的 `tx_ready_calc`（`:557-572`）里 `!fs` 项恒真 ⇒ **不改变其它条件**；
- 扫描本体（`scan_now`/`scan_id`，`:656` 等）**照旧跑**（RTO/重传/状态清理都靠它）⇒ 唯一全局后果 =
  **连接不再自行关闭**（设计意图）。
⇒ **不需要为连续模式改 `tcp_tx_frame` 一个字符**。

### 1.4 `TX_CONTINUOUS=0` 时逐位退化的论证（常量传播，逐条）

| 被改处 | `TX_CONTINUOUS=0` 时 | 退化理由 |
|---|---|---|
| 参数表 | 新参数 = 默认 `1'b0`，无例化传它 | 具名参数缺省 = 默认值 |
| `localparam CONT_OK` | `1'b0 && (...)` ⇒ `1'b0` | 常量折叠 |
| `cont_reload` | `1'b0 && (...)` ⇒ `1'b0` | 同上；**不新增 `remain==0` 归约的消费者**（AND 常量） |
| `remain_nxt` | `1'b0 ? TX_BYTES : remain` ⇒ `remain` | 常量选择 ⇒ 32 位 mux 整条消失 |
| `:676` 判据 | `(remain == 32'd0) && 1'b1` ⇒ 原式 | 恒真项折叠 |
| `:688-690` / `:736-738` | `remain_nxt` ≡ `remain` ⇒ 表达式与原式**逐字符等价** | 见上 |
| 两处 `if (cont_reload) remain <= TX_BYTES;` | 条件恒假 ⇒ 语句被删除（无 D 输入） | 常量假条件 |
| wrapper 例化 | 新参数只在**本刀的构建**里传 `1'b1` | 其余所有构建/镜像件不受影响 |

⇒ 形式结论：**新网表 = 老网表**（同一份 RTL 在 `TX_CONTINUOUS=0` 下每一个环都是原环）。
⚠️ 形式论证**必须**配实证：§4.3 要求用冻结件 `frozen/app_pattern_rev0e804099.v`（背景订正 ⑤：与改动前现役文件
sha256 逐字节相同）编译同一份 TB，dump/stats **`fc /b` 逐字节相同**。

### 1.5 每一轮首帧的 `seg_len`（逐条论证，含一个必须一起改的陷阱）

- 重装载点的判据是 `remain == 32'd0`，它**只在帧边界拍（`need == 4'd0`）成立**：`remain` 的递减点是
  `:770-771`（每次消费一个字，按 `pw_n` 饱和减），而帧长恒等于"由 `min(TX_SEGSZ, remain_at_frame_start)` 算出的
  值" ⇒ 一帧正好把 `remain` 推到 0 时，那一拍就是该帧的边界拍。⇒ **不会出现"帧中途 remain 到 0"**。
- 在该拍，`seg_len` 的三目以 `remain_nxt` 求值 = `TX_BYTES`（非 0）⇒
  `(TX_BYTES > TX_SEGSZ) ? TX_SEGSZ : TX_BYTES[11:0]` = **`TX_SEGSZ` = `12'd1460`**（规范配置下）。
  ⇒ **每一轮首帧 = 满段 1460 B**（第三轮之后同理，逐轮相同）。
- 末帧：`TX_BYTES mod TX_SEGSZ`。对推荐值 `32'h0FFFFFFF = 268,435,455`：`1460 × 183,859 = 268,434,140`
  ⇒ 末帧 **1315 B**；一个量子 = **183,859 个满段 + 1 个 1315 B 帧**（这个算术是本件复算，和 S3 的实测
  `ΔW51 = TX_BYTES` 相容）。
- ⚠️ **必须一起改 `:736-738` 的那个陷阱**：如果**只**改 `:688-690` 而漏掉 `frm_wait` 解除臂，则在
  "量子末边界拍上 `tx_ok == 0`"（窗口关/对端 ACK 未回流）时会走进 `:702 frm_wait <= 1'b1`，`remain` 停在 0；
  等 `tx_ok` 回来时 `:736-738` 会用 `remain = 0` 算出 `seg_len = 0` ⇒ **进入背景 4 的静默停滞**（线上零帧、`done` 不置、
  `close_req` 不发）——一个**只在长流下、只在特定窗口时序下**才出现的死锁。**两个点必须同批改 + 必须有一个 TB 臂
  覆盖它**（§4.2-A-side 的 `tx_ok` 掉臂）。

### 1.6 停止手段（板上现况 + 测试收尾协议）

板上**只有两条**停发通路（背景订正 ②：`app_ctrl` 寄存器总线静止 ⇒ 没有"主机命令停发"这条）：

| 通路 | 机制 | 语义 | 收尾代价 |
|---|---|---|---|
| **(a) 物理层停发** | 主机写 `0x08 = 0x2` ⇒ `pcie_scratch[1]` ⇒ `sfp2_tx_dis`（`wrapper_p4.v:3902`，J8 那条线） | **不是逻辑停发**：TX 引擎仍在跑、仍在排队/重传，只是光口不发；释放后恢复发（对端已 RTO/RST 与否不可控）。**同板所有通道一起静默** | 对端 sink 只能靠 **STALL**（默认 3×5000 ms）退出 ⇒ `status=1` ⇒ `bad_conns++` ⇒ **RC=1（假红）**。判据必须读 `SINK_CONN` 行的 `bytes/checked_bytes/first_mismatch/mism_bytes`，**不许用 RC** |
| **(b) 对端关连接** | 对端进程正常退出（sink 读满 `--maxbytes` ⇒ `:154` `n==0`(FIN) 或 close）⇒ 板 `ev_down` ⇒ W3 收尾 ⇒ `active<=0` | **逻辑收尾**（板**不发** FIN，半关闭由对端发起） | **最干净**：sink 侧 `status=0` ⇒ `clean_conns++` ⇒ **RC=0**；板侧判据 = `ΔW52` 停增 + 末两点快照不变 |
| (c) 复位/重烧 | `rst_n` / JTAG 重烧 | 硬重置 | 只用于换臂 |

⇒ **测试收尾协议（§4.5 逐步）**：**主用 (b)**（`--maxbytes` = 测量预算，读满即退出 ⇒ 双向都干净），
**备用 (a)**（紧急停/负对照；此时判据必须切换到 `SINK_CONN` 行口径）。
⚠️ 纪律细节：(a) 释放后（`0x08 = 0x0`）peer 表还在 ⇒ 立刻恢复发流（既有配方），别在停流态下做别的读数。

### 1.7 例化点改动 + `BUILD_ID_V`

- `board/wrapper_p4.v:1177-1178`：加 `.TX_CONTINUOUS(1'b1)`（逐字见 §1.2 改点 6）。**`.TX_BYTES` 不动**。
- `board/wrapper_p4.v:3911`：`BUILD_ID_V (32'h00000015)` → **`32'h00000016`**（纪律：每次构建必须 bump；BID 是
  板上身份门的唯一分辨依据）。**示例注释行也要顺带加一行**（`:3912-3914` 的注释列表）。
- ⚠️ **两个常量改动都是"改常量"**（BID 与 `WIN_CAP_5`）⇒ 按全局 #64，**两者都会确定性改变网表/时序**，
  不许写"只是数据常量所以安全"。本刀**无法避免** BID 改动（纪律要求）。

### 1.8 风险登记（时序锥 / 更省逻辑的写法 / 观测面缺口）

- **落在哪些锥上**：
  - `cont_reload` 复用**已存在**的 `(remain == 32'd0)` 表达式（`:451/:456/:676`）⇒ 综合期公共子表达式合并，
    **不新增 32 输入归约**（这一点是本设计刻意选的：`remain == 32'd0` 正好在 `asm_go` 的时钟使能锥上，
    是全局 #64 的机制点）；
  - 新增逻辑 = ① 一个 AND（`cont_reload`）② 一个 32 位 2:1 mux（`remain_nxt`，常量输入）③ 两处 `if` 的
    D-使能。②③ 落在 **`remain` / `seg_len` 的 D 路**（后置寄存器路径），**不在使能锥上**；
  - ⚠️ **但余量只有 `0.052/6.400 = 0.81%`**（来自文档，未回时序报告核）⇒ 任何改动都按 #64 处理：**一次构建收口 +
    复核三类失败端点 + 读 DP 域前 10 族是否换族**（§4.4）。
- **有没有更省逻辑的等价写法**：有，而且本设计已经用上了 ——
  **连续构建里整个终结分支被常量关死**（`(remain==0) && !CONT_OK` 恒假）⇒ 其内部逻辑（`active<=0`、`done<=1`、
  `op_pend/op_sent<=0`、`if (AUTO_CLOSE) close_req/close_id`）**整条被综合删除**：
  - `done` 失去唯一置位源 ⇒ 变常量 0（FF 可被优化）；
  - `close_req`（1 FF）+ `close_id`（4 FF）的置位锥消失（复位值仍在）；
  - `app_ctrl` 侧 `if (close_req)`（`app_ctrl.v:1363-1366`）随之恒假 ⇒ `stat_cmd_close` 的自增支路消失。
  ⇒ **连续构建的 `app_pattern` 逻辑净增 ≈ 0（甚至略减）**。⚠️ 这是**结构性推理**，不是构建读数 ⇒
  写进 §4.4 的对照项（LUT/FF/控制集），**不许当成"预期收益"对外声称**。
- **观测面缺口（必须登记）**：`active` / `done` / `close_req` / `frm_wait` **都不在 63 字快照里**
  （`wrapper_p4.v:1203-1206` 悬空）⇒ 板上**看不见"app 是否还 active"**。本刀的板级判据只能间接：
  "`W51/W52` 在涨 ⇒ 还在发"，"对端 `bytes` 在涨 ⇒ 还在发"。若要直接看，需要把 `active` 接进快照
  （吃余量；登记进 §5.6 的未来计划）。

---

## §2 在飞窗口上限提升（构建 A 的第二处，由我方主控指定）

### 2.1 单一来源与"三处跟随"（含背景订正 ①）

- 单一来源 = `board/wrapper_p4.v:222`：
```verilog
// 旧:
    localparam [15:0] WIN_CAP_5 = 16'hBFFE;
// 新:
    localparam [15:0] WIN_CAP_5 = 16'hF000;   // 61440 B (P7B-LONGSEND §2; 不变量重算见该件 §2.2)
```
- 三处跟随（`grep -n WIN_CAP_5 board/wrapper_p4.v` = 恰好 4 行：定义 + 3 处例化）：
  `:1221 app_ctrl #(.WIN_CAP(WIN_CAP_5))` · `:1934 tcb #(.WIN_CAP(WIN_CAP_5))` · `:2098 tcp_tx_frame #(.RING_CAP(WIN_CAP_5))`
  —— **无需改动**（跟随 `localparam` 自动生效）。
- ⚠️ **功能面只有两处**（背景订正 ①）：`tcb.v:143-145` 的注册门 `win_open`（真正的发送门）与
  `app_ctrl.v:568` 的 `eff`（app 侧 `app_tx_ready`）。`tcp_tx_frame` 的 `RING_CAP` 在 body 里**没有功能使用**
  （唯一非注释出现 = `:196` 声明）⇒ 这一处**只改注释、不改网表**。
- **模块默认值一律不动**（`tcb.v:13` / `app_ctrl.v:275` / `tcp_tx_frame.v:196` 的 `16'hBFFE` 保持）：
  否则所有直接例化这些模块的 TB（实测：**9 个 TB 文件共 14 处** `.WIN_CAP(16'hBFFE)` 显式传参 ——
  `tb_app_fc.v:137` · `tb_app_wu.v:104,132` · `tb_integ_app_tx.v:135` · `tb_p5_adv.v:501` · `tb_p5_app.v:947` ·
  `tb_p5_multi.v:642` · `tb_tcp_tx_ovl.v:280` · `tb_wu_f2.v:105,133,165` · `tb_wu_p1p2.v:95,123,151`）
  会连带改配置，属"门与板跑两个配置"（工程坑 11）的**反面**用法：**板走 wrapper 的 localparam，
  模块级 TB 保持自己的显式值**，两边各自自洽。
  ⚠️ 另两处**相关但不同**的引用：`tb/tb_integ_app_tx.v:251`（TB 自算模型 `eff_cap = min(c0_snd_wnd, 16'hBFFE)`，
  与它自己的 `:135` 例化自洽 ⇒ 不受本刀影响）与 `tb/tb_p4_chain.v:1168`（`pcst_thresh = 32'hBFFE` = 对端停 ACK 的
  **激励阈值**，不是 DUT 帽）⇒ 本刀**都不动**；但 §4.1-G3/G4 跑它们时要知道"阈值仍是 0xBFFE"这个构型事实。
- **必须就地订正的"说不成立了"的注释**（只改注释文字，不改任何代码行）：
  > ⛔ **实现轮范围裁定 (2026-10-09)**: 本轮的派单把可改文件**穷举**为
  > `rtl/app_pattern.v` · `board/wrapper_p4.v` · `tb/` 下新建 TB 与 runner · `_proj_pcie/p7b_biz/p7b_tcp_sink.cpp` ·
  > 本设计件 ⇒ **下面这条"必须就地订正注释"的三处（`retx_ram.v` / `tcb.v` / `tcp_tx_frame.v`）本轮**未做**，
  > 按"未做"登记**（不是漏做：是本轮被明确禁止改这三个文件）。⇒ **帽值的单一来源注释目前与 `0xF000` 不一致**，
  > 留给下一轮（改动面 = 纯注释，零网表差异）。
  `rtl/retx_ram.v:6` · `rtl/tcb.v:10-11`、`:138-141` · `rtl/tcp_tx_frame.v:187-196`、`:1219-1225`
  （都写死了 `0xBFFE`/`53244` 的算术）。建议写法：**删掉写死的数字**，改为"帽值由 `board/wrapper_p4.v` 的
  `WIN_CAP_5` 下发；不变量重算见 `_proj_10g/notes/P7B_LONGSEND_DESIGN.md` §2.2"。
  ⚠️ 安全性已核：`sim/p7b_stagec_tx_regress/author_gate/mk_mut_tx.py` 的变异锚点是**代码文本精确匹配 + 声明命中数**
  （`:111 t = t.replace(old, new, hits)`），且 `grep -n "RING_CAP\|0xBFFE\|BFFE" mk_mut_tx.py` = **0 命中**
  ⇒ **改这些注释不会打破任何变异件锚点**。
- `rtl/tcp_echo.v:89` 只是"参照引用"（echo 路径有自己的深度常数），**不改**。
- `rtl/app_ctrl.v:613-614` 的 `WIN_CAP(0xBFFE)` 引用是解释"为什么夹紧帽用 `wq_cap_r` 而不是 `win_cap`"的**历史**论证，
  结论不依赖具体值 ⇒ **不改**（若改，必须重跑 F2 的穷举证明，不值）。

### 2.2 不变量为什么成立（**完整论证**，不是照抄注释）

**(1) 物理结构。** ring = 16 conns × 8192 ring 字 × 8 B = **64 KiB/conn**（`retx_ram.v:2-10`）；
写地址 = `{conn[3:0], w_seq[15:3]}`，bank = `w_seq[3]`（`:32-33`、`:45-52`）⇒ **地址只由 `w_seq[15:0]` 决定**，
存放的是"字节流偏移 mod 2¹⁶"。⇒ 正确性要求是一条**注入性**：
**任一时刻，必须同时保存在 ring 里的字节集合的跨度 ≤ 65536。**

**(2) "必须同时保存"的集合 = 活窗 ∪ 正在写入的帧。**
- 活窗 `[snd_una, snd_nxt)`：对端未确认 ⇒ 随时可能被重传会话读取（`tcp_tx_frame.v:545-547`
  `rd_tap`/`r_tap_seq = rb_snd_nxt[15:0]`，`:639-644 retx_ram` 的读口）⇒ 必须留存；
- 正在写入的帧 `[snd_nxt, snd_nxt + len_in)`：帧是**边收边写 ring** 的（`wr_tap`，`:551/:557`
  `wr_tap = accept && (tkeep != 0) && !len_bad`），所以这部分是"物理占用"；
- 两者**不重叠**（写点从 `snd_nxt` 起）⇒ 跨度 = `(snd_nxt − snd_una) + len_in`。

**(3) 上界项一：启动门只管到 `CAP − 1`。**
新帧的启动门 = `start_data`（`:516-519`）/`s_axis_tready`（`:511-515`）里的 `wnd_open`，而
`wnd_open = win_open`（`:1227`）= `tcb.v:144-148` 的**注册**输出：
`win_open <= (win_diff < {16'b0, win_cap})`，`win_diff = snd_nxt_r[win_id] − snd_una_r[win_id]`（32 位回绕正确，
`tcb.v:142`），`win_cap = min(snd_wnd_r[win_id], WIN_CAP)`（`tcb.v:143`）。
`win_id = rb_id`（`wrapper_p4.v:1960`），而 S_IDLE 非旁路拍 `rb_id = start_id`（`:1310`）⇒ **门就是"这条连接"的**。
⇒ 启动时**看到的**在飞 ≤ `WIN_CAP − 1 = 61439`。窗门是 32 位回绕正确的（`tcb.v:134-137` 的注释与实现），
因此**不碰序列号回绕语义**（帽 `0xF000` ≪ 2¹⁶ ⇒ 任何 64K 边界的边角都不存在）。

**(4) 上界项二：一帧能交给 ring 的字节 ≤ 1508（**这是本刀的裁决口径**）。**
> ⛔ **实现轮订正 (2026-10-09, 引用面)**: 本条原引的 `:1494` / `:1490-1493` / `:1885-1889` **三处全部落在
> `ifdef TCP_TX_OVL` 的 `else`（未编译）分支**里（`ifdef` = `:236`, `else` = `:1077`, `endif` = `:2038`）
> ⇒ 复算的人会读到死代码。**现役等价式 = `:507-508`（`plen_n` / `len_over`）· `:551`/`:553` 与 `:557`
> （`wr_act` / `wr` / `wr_tap` 的 `!len_bad` 门）· `:891-893`（`len_bad` 置位与中止收尾）**。
> **数字结论（≤1508 B/帧）不变**，只改引用。

- 提交上界 = `PLEN_MAX = 12'd1500`（`:202`）：`len_over = (plen_n > PLEN_MAX)`（现役 `:508`，原引 `:1494` 为死分支）⇒ 超限帧被整帧中止、
  **不推进 `snd_nxt`**（`:891-893` 注释与实现 + `wr_tap` 的 `!len_bad` 门，现役 `:557`）⇒ **活窗里一帧最多 1500 B**；
- 物理写多一点点：检出的那一拍**已经写进 ring**（`:1491-1493` 注释逐字："len_bad 是寄存器 (检出拍的下拍起屏蔽写口),
  检出拍本身已写进 FIFO/ring 的字节由 S_IDLE 的 flush 与 ring 覆盖语义兜掉"；⚠️ 该注释与 `:1494` 同在未编译分支，
  现役等价物 = `:551`/`:553` 的 `wr_act`/`wr` 与 `:557` 的 `wr_tap`）⇒ 该拍 `plen_n ≤ 1500 + 8` =
  **1508** 是"一帧可能写进 ring 的字节上界"（它**不会**活下来：中止帧不推进 seq，写到的位置随后续帧覆盖）；
- 应用契约更小：`TX_SEGSZ = 1460` ⇒ 实际每帧 ≤ 1460（连续模式不改变这一点）。

**(5) 上界项三（**未确定**）：注册门的 1 拍陈旧是否与新帧复合。**
`tcp_tx_frame.v:189-191` 逐字登记了"帧完成写 `snd_nxt` 的当拍, 下一 S_IDLE 决策读到的仍是旧值, 可误开 1 拍
(OPEN 方向, **每次最多多放 1 帧**)"。RTL 在 `:192` 的算式是 **(CAP−1) + plen_max**（**只含一帧**）。
若这"多放 1 帧"与"新开的这一帧"**可以复合**，则上界要多一项：`(CAP−1) + 2×plen`。
⇒ **未确定**：判"能否复合"需要读 `S_DONE → RX_IDLE` 与 `upd_wr` 的逐拍相位（或一条 TB 断言），**本件没做**；
**但两种口径都作数**（见下），所以**不阻断施工**。

**(6) 数值裁决（0xF000 = 61440，CAP−1 = 61439）：**

| 口径 | 算式 | 结果 | ≤ 65536？ | 余量 |
|---|---|---|---|---|
| 单帧 + 真实帧长上界 1508 | 61439 + 1508 | 62947 | ✅ | **2589 B** |
| 双帧复合 + 1508 | 61439 + 3016 | 64455 | ✅ | **1081 B** |
| 单帧 + 4095（RTL 注释的保守值） | 61439 + 4095 | 65534 | ✅ | **2 B** |
| **双帧复合 + 4095** | 61439 + 8190 | **69629** | ⛔ **不成立** | −4093 |

⇒ **裁决口径必须写"每帧交给 ring ≤ 1508 B"**（不是 4095）。⇒ 0xF000 安全，**且安全性与"1 拍陈旧能否复合"
无关**（因为真实帧长比 4095 小得多）。
⚠️ **条件**：**若日后放宽 `PLEN_MAX` 或允许 >1508 B 的帧，这个安全性必须重算**（`4095` 的复合口径会破）。
⚠️ **这不是"照抄注释"**：RTL 的 `53244`（`:192`）用的是 `plen_max=4095` 且只算单帧；本刀把它换成
"真实上界 + 两种口径并列"，并给出**不成立的那一格**。

**(7) `retx_ram` 的 `w_seq[15:0]` mod 2¹⁶ 为什么不会溢出（正面回答题面这一问）。**
由 (2)(3)(5)(6)：任一时刻必须共存的跨度 ≤ **64455 < 65536** ⇒ `mod 2¹⁶` 映射在该集合上是**单射**
⇒ **不会出现"新帧覆盖掉还没被确认的旧字节"**（那才是溢出的实体形态）。
补充三条"为什么它不会再被别的路径突破"：
- **重放会话不写 ring**：`wr_tap` 只看 `accept`（`:557`），而 replay 期（`RX_RING`）`s_axis_tready` 不为 1
  （`:511-519` 只在 `RX_IDLE`/`S_RECV` 支路），且 `start_data` 要求 `!svc && !ring_eval && !scan_now`
  ⇒ **重放期间在飞不增长、ring 只被读**；
- **重放读区落在活窗内**：`ring_start`/`r_tap_seq` 从 `rb_snd_nxt` 起读 `ring_delta = retx_hi − rb_snd_nxt`
  个字节（`:538-547`），而 `ring_delta` 的上界就是 `retx_hi − snd_nxt ≤ 在飞`（`:775` 的 `retx_hi` 更新语义）
  ⇒ 读区 ⊆ `[snd_una, retx_hi)` ⇒ 不越界；
- **硬界与帽的关系**：64 KiB 是**物理**容量，`WIN_CAP` 是**收紧版**的软帽（`tcp_tx_frame.v:196` 的注释语义）
  ⇒ 本刀抬帽**不是**抬物理容量，抬到 0xF000 之后 `1 − 64455/65536 = 1.65%` 的物理余量仍在。
- ⚠️ **`retx_ram` 没有任何硬件溢出守卫**（纯存储）⇒ **上面这套论证就是唯一的守卫** ⇒ 它必须写进施工件与验收件
  （不许只写在注释里）。

**(8) 与 RX 方向无关（可复核的不变项）。**
`WIN_CAP_5` 只出现在 `:222/:1221/:1934/:2098`（本件实测），**`app_ctrl.WIN_POOL`（`:276` = `16'hC000`）与
`WIN_Q_MAX`（`:296`）一字未动** ⇒ 本刀**不改我方通告窗**（RX 方向），也**不改** `WIN_POOL = 49152` 那条
单路双向 10G 的已知硬约束（`RTT ≤ ~39.3 µs`）。

**(9) `tcp_tx_frame.RING_CAP` 那一处传参不改网表**（背景订正 ①）⇒ 本刀的**功能面** = 两个 16 位常量比较
（`tcb.v:143` 与 `app_ctrl.v:568`），而 `0xF000` 对比较器实现是"看 bit[15:12] 是否全 1"（比 `0xBFFE` 的前缀比较更省）
⇒ **预期逻辑不增**；⛔ 但按 #64 不许声称收益，以构建读数为准。

### 2.3 0xF000 仍不够时往哪走（**只列选项与代价，不实施**）

| 选项 | 内容 | 代价 / 前提 |
|---|---|---|
| **O1 再抬常数** | `0xF800`(63488) 或 `0xFC00`(64512) | ⛔ 前提 = **先裁定 §2.2-(5) 的复合问题**：单帧 1508 口径 `0xF800` = 63487+1508 = 64995 ✅（余 541）；双帧复合 = 66503 ✗ ⇒ **只有在"陈旧不复合"被证明后才允许**。零构建成本、零风险冒进——要么改一行常数，要么数据静默损坏（`retx_ram` 无守卫） |
| **O2 少连接 × 大 ring** | 16×64 KiB ⇒ **8×128 KiB**（`retx_ram.v:32` 的 `w_seq[15:3]` 13 位 ⇒ 14 位；bank 地址 `{conn[2:0], w[12:0]}`） | **BRAM 总量不变**（仍 1 MB / 256 tile）⇒ 每连帽可到 ~120 KiB；代价 = 连接数参数（`tcb.N`、`tcp_cam`、`app_ctrl` 的 16 路数组）+ `retx_ram` 重排 + **大量 TB 镜像**（坑 11）+ 全部板级判据换口径 |
| **O3 retx_ram 迁 URAM** | 释放 256 BRAM tile（`_proj_10g/notes/P7B_BRAM_REPORT.md`：29–32/64 URAM、读流水 2→3 级） | 释放后可做"更多连接"或"更大 ring"；代价 = 时序 + 延迟复核（报告已备，未实施） |
| **O4 自适应帽** | 按实测 RTT 动态调 `win_cap` | 需要 RTT 估计器（新机制、新风险面）；**先例警告**：C8 的 `ss -ti` RTT 见证在纯接收方向不可用 ⇒ 数据来源不成立（`P7B_LONGFLOW_DESIGN.md:627-629`） |
| **O5 不抬帽，抬对端** | 无意义 —— 对端窗口不是本刀的量 | — |

⚠️ 与 O1–O3 都无关的一条物理事实：**TCP 线上载荷天花板 = `1460/1538 × 10 = 9.493 Gbps`**，
"业务 10.0 Gbps"物理不可达（`P7B_SINGLE_FLOW_10G_DESIGN.md` 的口径）⇒ 抬窗的目标是"把墙从窗挪到几何"，
不是"超过 9.493"。

### 2.4 判别臂 A/B（**同 bitstream 内**，把"窗帽是那堵墙"与别的原因分开）

**为什么必须做**：0xF000 的预期速率增益**小**。若窗帽真的是墙，`R = W/RTT` ⇒ 从 49150 抬到 61440 的增益 = ×1.25
⇒ 但会被**设计上界 9.456 Gbps** 截住 ⇒ 预期读数 9.108 → **≤9.456（+3.7%）**，**小于**已观测的跑间散布
（6.8–9.31 Gbps，n=4）⇒ **"速率涨没涨"单靠主读数没有判别力**。必须换一个**幅度大得多的旋钮**：对端的通告窗。

**做法（同一 bitstream = 构建 A，两臂只改对端一个参数）**：

| 臂 | 对端命令 | 期望的对端通告窗 | 预期板侧速率 |
|---|---|---|---|
| **W-big（主臂）** | `p7b_tcp_sink --rcvbuf 8388608`（默认） | 大（`Recv-Q ≈ 0` ⇒ 窗全开；`P7B_LONGFLOW_DESIGN.md:631` 的读数支持） | 上限 = `min(对端窗, 61440)` = 我方帽 ⇒ 主读数 |
| **W-small（判别臂）** | `p7b_tcp_sink --rcvbuf 30720`（调小） | ≈ 30 KiB（`min(对端窗, 61440)` = 对端窗） | 若"窗=墙"：≈ 主臂 × 30/61.4 ≈ **0.49×** |

**判据（写死）**：
- **W2（判别）**：若 W-small 的速率**显著下降**（落在 `0.49× ± 20%` 内）⇒ **窗机制是活的** ⇒ 主臂的上限确由
  `WIN_CAP` 决定 ⇒ 0xF000 的收益被几何上界吸收，**如实写"窗帽已不再是第一堵墙，但速率增益小到被散布淹没"**；
- 若 W-small 的速率**与主臂相同**（差 ≤ 散布）⇒ **窗不是墙**（本工况）⇒ 0xF000 对速率**无收益**，如实报，
  候选转向"对端 ACK 回流节奏 / app 残余开销"，并把 8.15 拍/帧死拍（§5.4）列为主攻方向；
- **见证（gate W3，必需）**：两臂**必须各有一段流内的通告窗见证** —— `ss -tinma` 的 `wscale`/`skmem`
  （`lf_dl.sh:98-101` 的 10 ms 采样器已有）+（可选）pcap 的 `win=` 字段 × `2^wscale`。
  ⚠️ **`_proj_pcie/p7b_biz/p7b_pcap_check.py` 目前不解析窗字段**（本件实测 grep `win` 命中 0）⇒ 要么手读
  `tcpdump -v` 文本，要么新写提取（登记为可选工具改动）。
  ⚠️ **一个已知机制风险**：sink 在 **connect 之后**才 `setsockopt(SO_RCVBUF)`（`p7b_tcp_sink.cpp:290` 先 connect、
  `:299` 才设）⇒ **wscale 已在握手定死**；Linux 的显式 `SO_RCVBUF` 会锁住 `sk_rcvbuf`（关掉 autotuning），
  所以通告窗**应当**随 `rcvbuf` 变小 —— 但**不许假定**：**必须以 W3 见证为准**。
- ⛔ **如果 A/B 做不出判别力，如实报什么**（三种情形逐条指定）：
  1. **见证缺失**（`ss`/pcap 显示两臂的通告窗没有 ~2× 差）⇒ 记 **"W2 = 未测（见证缺失）"**，
     **不许**记成"窗不是墙"；补救 = 把 `SO_RCVBUF` 前移到 connect 之前（`p7b_io.h` 加一个带 `rcvbuf` 的
     connect 变体，不改既有函数 ⇒ 下游零影响），然后重跑该臂（同 bitstream，无需重新构建）。
  2. **速率变化幅度落在散布内**（既不 ≈0.49× 也不 ≈1.0×）⇒ 记 **"判别力不足"** + 落盘原始点
     （两臂各 ≥4 跑的中位/极差），并明确"不许据此裁定窗的作用"。
  3. **板侧根本跑不满本轮窗口**（例如对端 STALL/RC 假红）⇒ 先修台架，不让该臂进判据表。
- ⚠️ 该 A/B **不改 RTL**（只是对端参数）⇒ **不冲突"改 RTL 与跑回归互斥"**（#57）。

> ### ⛔ 2026-10-10 板级轮订正（**本节的 A/B 不光没做出判别力，而且是结构性做不出** —— 读法优先于上方）
>
> **结论口径 = "窗帽抬升（49150 → 61440）是否带来收益" 本轮【未判定】**：
> **不是"无收益"，也不是"证伪"**。三条理由（每条都由板级原始件支撑）：
>
> ① **负对照臂 S3 结构性地做不出长窗口** —— S3 每连接发满 `TX_BYTES = 32'h0FFFFFFF` 就 FIN
>    ⇒ **单次流的寿命天花板 = 227 ms**；而 A 臂的价值在**长流** ⇒ 两臂只能在**短窗**上比，
>    而短窗恰恰是噪声主导的（②）。
> ② **短窗是噪声主导的、且有系统性偏差**：本会话散布 = S3 臂 9 跑内窗 **3.7513–8.6503 Gbps**（中位 **5.4988**）、
>    A 臂短跑 10 跑中位 **7.3421** Gbps；而 **A 臂长跑（236 s）加权 = 9.1377 Gbps —— 长跑读数高于短跑中位**
>    ⇒ 短窗读数很可能**被建连后的一段瞬态拉低**（与全局 **#58**「换烧/重连后头几次读数可低到 3×、单次读数不可作判据」同族）。
>    ⚠️ **候选、未分离**：本轮**没有**做"逐秒看前几秒"的分解 ⇒ 不许写成本轮已证。出处 = 板级原件 §0/§2.1/§2.2。
> ③ **同位素臂（只调对端通告窗：`--rcvbuf 8 MB → 64 KB`，见证窗 `rcv_space` 449,680 → 42,340 ≈ 旧帽 49150）
>    也缺判别力 —— 因为跑在了低档**：它读到的两跑 = **7.2390 → 7.5982 Gbps**（`P = 251.9 / 240.1`
>    ⇒ 线占空 **76.6% / 80.4%**）⇒ **该构型下流量本来就没贴在窗上**，故"压窗不掉速"**推不出**"窗不是限速源"。
>    ⚠️ 若按窗限速恒等式 `速率 = 在飞窗/RTT` 粗算：42 KB 的窗要开始咬住需 `RTT < 42 KB/(7.24 Gbps/8) ≈ 46 µs`，
>    而这个数**没有独立见证**（C8 = 未判定）⇒ **该臂既不能确认也不能排除**。
>    ⇒ 措辞必须是"**该臂在本轮工况下无判别力**"，**不是**"方向相反 ⇒ 证伪"。
> ④ 其余读数（**交错配对 A/B 3/3 对 A ≤ S3**：sink 口径 −3805.2 / −220.2 / −220.0 Mbps ·
>    **非配对秩和 `p≈0.34` 不显著**）**只支持"未观察到可判定的涨幅"**，**不支持**更强的结论。
>    出处 = 板级原件 §2.3（配对表）/ §2.4 / §5（同位素表）/ §6。
> ⑤ **两臂共同项**：`W21/W23/W41/42/W45/W59/60` 全 0 · `first_mismatch=-1`/`mismatch_bytes=0`/`bad_conns=0`
>    （板级原件 §2.4 逐字 = "**25 跑**全部"；派单口径 = **26 跑** —— 差 1 跑未逐条对齐，**照引不调和**）
>    —— **构型可比性的正证据**（但见下面 ⚠️ 绑核构型漂移登记）。
> ⑥ ⚠️ **构型登记**：非配对的 S3-vs-A 比较里 `PIN_CPU` 不一致（**5→7**，工作线程对 `4/3`、`4/7`、`7/4`），
>    **配对那 3 对 / 6 跑完全一致**（`PIN_CPU=7 / IO=4 / WORK=5`）⇒ 配对结论不受影响，非配对比较更弱；
>    跨会话比较**只比"绑没绑"、不比核号**（2026-10-09 用户口径）。
>
> ⇒ **要判它，需要一臂「连续模式开 + 旧 `WIN_CAP`（`0xBFFE`）」的 A-minus 构建**，与 A 臂做**同长度长窗** A/B。
> **本刀未做**（= 构建 B-2 候选，见 §5.4/§8.4）。
>
> **`WIN_CAP_5` 保留（不回退）**：理由 = ③ **未判定 ⇒ 不构成回退理由**；**且回退会作废已验收的 A 臂位流
> （需再构建一次）**。⛔ **不许写成"保留作 BDP 余量"**（那是收益主张，本轮没有证据）。
> **回退本身 = 改一行**（`board/wrapper_p4.v:227` 的 `16'hF000` → `16'hBFFE`）。
> ⚠️ 代价登记（**未拆刀**）：抬帽与 BID/app 改动**同批构建**，`WNS` 从 **+0.052 → +0.021**（−0.031）——
> **哪一部分吃掉的没分开**（要拆需单独构建）。

---

## §3 台架长流支持（`_proj_pcie/p7b_biz/`，本单不含 RTL）

### 3.1 `p7b_tcp_sink.cpp`：判决 + 最小改动

**判决：不引入 `--maxbytes 0 = 无限` 的新语义；长流由命令行显式传大值承担；只新增一行自证。**

理由（逐条）：
1. **"0 = 无限"在本工具里是假的**：循环是 `while (got < a->maxbytes)`（`:126`/`:335`）⇒ `maxbytes=0` 时
   **循环体一次都不执行**，随后 `tot_bytes == 0` ⇒ 末行 `:405` 的 `tot_bytes > 0` 为假 ⇒ **RC=1**。
   要做成"无限"必须改**两处**（循环条件 + 末行判据），并新增一个"0 的语义"；
2. **默认值陷阱（#53 同族）**：把"0 = 无限"做成合法值，等于给"忘传参数 / 传错"留一个**静默走向无限**的出口；
   而长流的正确默认方向应该是"**短**"（忘传 = 只测 4 MiB ≈ 3.4 ms，读数明显不合理 ⇒ 一眼可疑），
   保留现状反而是**更安全的默认**；
3. **下游字段面零风险**：`SINK_CONN`（`:379-386`）与 `SINK_SUM`（`:392-401`）的字段名/顺序是下游接口
   （`_proj_10g/notes/p7b_biz_s1/s1_3_run.sh:17` 用 `sed` 抓 `off_end`；`recompute_s1_3.py:32` 用正则抓
   `UDP_SUM ... pkts/pay_bytes/off_start/off_end`）⇒ **只能追加，不能改**。判决 = **一行都不动**。

**最小改动（唯一允许的改动）：在 `:265` 的 `SINK_CHECK` 之后，追加一行新的自证**（新行、新名，不动任何既有行）：

```c
    printf("SINK_LIMITS maxbytes=%ld poll_ms=%d stall_n=%d rcvbuf=%d conns=%d secs=%d\n",
           maxbytes, poll_ms, stall_n, rcvbuf, conns, secs);
    fflush(stdout);
```
（**建议**：放在 `SINK_CHECK`（`:265-266`）之后、槽池分配之前；`maxbytes` 是 `long` ⇒ 用 `%ld`。）
理由 = 与 `SINK_CHECK`（`:264-265` 注释逐字"开关的**正证据** —— '我传了参数' ≠ '参数生效了'"）同一条纪律：
长流的"每连接终止条件"是**判据的前提**，必须落盘可核。**下游零影响**（新行、新前缀）。

**长流跑法（逐字，§4.5 用）**：`--maxbytes` = **测量预算**（不是"无限"），例如
`--maxbytes 34359738368`（32 GiB ≈ 29 s @9.3 Gbps）⇒ 读满 ⇒ `status=0` ⇒ **RC=0 且连接正常关闭（FIN）**
⇒ 板侧走 `ev_down` 收尾（§1.3②）。⭐ **副作用是好的**：sink 主动关连接 = 一条**逻辑收尾**的板级用例。

其他判决（逐个，含"不动"的理由）：

| 件 | 判决 | 理由 |
|---|---|---|
| `p7b_snap.sh` | **不改代码**；但 §4.5 的命令行**必须显式** `EXPECT_BID=0x00000016` | ⚠️ 它的默认是 `EXPECT_BID=${EXPECT_BID:-0x0000000A}`（`:44`，Stage C 的值），**而板上现役 S3 是 `0x15`、构建 A 是 `0x16`** ⇒ 用默认值会 `ID_FAIL`（这是**正确**行为：身份门有牙）。改成 0x16 会破坏历史复跑的可比性 ⇒ **不改，用环境变量** |
| `p7b_snap.sh id/snap/pair` 的用法 | 照用 | `snap TAG W1 W2 ...` 允许**只读短表**（`:165`）——这是长流的必需形态（#67：12 字快照在流内 ~288 ms） |
| `_proj_10g/notes/p7b_longflow_board/lf_dl.sh` | **不改**（全部开关都是环境变量：`CONNS/SECS/TAG/RCVBUF/SINK_EXTRA/BID_EXPECT/MAXSNAP/SNAPGAP/KW`，`:19-34`） | 长流只要 `KW='5 51 52 20 43'`（5 字）+ `SINK_EXTRA='--check lane8 --maxbytes <大值>'` + `MAXSNAP` 调大 + `BID_EXPECT=0x16`。⚠️ **`--check lane8` 是两个参数**（#67 的仪器失效之一） |
| `_proj_10g/notes/p7b_longflow_board/nicdelta.py` | **不改** | 它是 NIC 差值解析器；**刷新量子**的规避已写在 `lf_dl.sh:141-144`（pre/pre2/post/post2 四点）⇒ 协议层面解决，不动工具 |
| `p7b_io.h` / `p7b_pattern.h` / `p7b_spsc.h` / `p7b_affinity.h` | **不改** | 只被 §2.4 的"补救 1"（connect 前设 `SO_RCVBUF`）**可能**需要一处新函数；那是**条件改动**，且是追加语义（不改既有签名）⇒ 归入 §2.4 的开放项，不进本刀 |
| `p7b_tcp_src.cpp` / `p7b_udp_src.cpp` | **不改** | 分别是上行/ UDP 侧的源工具，本刀的下行长流不用它们 |
| `p7b_rate2_bench.cpp` | **不改** | 纯速率台架（无内容判据），长流的内容 oracle 在 sink |
| `p7b_pcap_check.py` | **不改**（但 §2.4 的见证提取**尚缺**，见该节） | 它不解析窗字段（实测 0 命中） |
| `p7b_selftest.sh` / `p7b_dualthread_selftest.sh` / `p7b_lane8_selftest.sh` / `aff_selftest.sh` | **不改**，但 §4.4 前**必须各跑一次** | 它们是工具自检（含 `UDP_SUM` 字段依赖）；改工具（§3.1 那一行）后必须复跑，证明没打破既有自检 |
| `p7b_fake_board.py` | **不改** | 假板仿真器，与长流无关 |
| 部署配方 | 以 `_proj_10g/notes/p7b_affinity/BUILD.md` 为准（树里三条编译行互相打架的既有登记） | ⚠️ 关机后 `/tmp/p7b_biz/` 清空 ⇒ 每轮开工按它重部署 |

### 3.2 长窗取数协议（**逐字可执行**；板上 32 位回卷是硬约束）

**采样周期上限（先算，再定）**：
- `W51`（`app_pattern.stat_tx_bytes`，3.65–3.70 s 回卷 @9.3–9.4 Gbps）是本刀的主计数 ⇒ 周期必须 ≪ 3.65 s；
- 一次 5 字短表的墙钟成本 ≈ 触发 + 5×`reg_rw`（流内实测每字 ~24 ms，来源 = `lf_dl.sh:33-34` 对 12 字 ~288 ms 的实测）
  ⇒ **一次 ~120 ms**；
- **取值：`SNAPGAP = 0.05–0.5 s`（推荐 0.5 s）** ⇒ 回卷余量 ≥ 7×，采样占空 ≤ 25%。
  ⛔ 硬红线：**周期不许 ≥ 3 s**（那会让"漏一次采样 = 漏一个回卷"从可能性变成必然性）。

**逐字协议（每一点都自证，绝不假设）**：
```bash
# 0) 每轮开工（对端机）—— 恢复环境 + 重部署（配方 = p7b_affinity/BUILD.md）
#    关对端 RX 中断合并（#68 的第一主因；唯一变量的 A/B 已证）：
ethtool -C enp1s0f1np1 adaptive-rx off rx-usecs 0
#    路由与 NM 闸（每次现取，别信上次）：
ip route get 192.168.100.2
nmcli device set enp1s0f1np1 managed no      # /32 被 NM 冲掉的根治

# 1) 身份闸（每次烧录后、每次测量前）
EXPECT_BID=0x00000016 bash /tmp/p7b_biz/p7b_snap.sh id      # 必须 ID_OK（= MAGIC + BID + MARKER + 未实现地址 0x11C）

# 2) 流内序列（前台，短表 5 字 = 时基/帧数/发字节/MAC 帧/MAC 拍）
#    推荐直接用现成台架（它自带 10ms ss 采样 + pre/pre2/post/post2 的 NIC 四点 + 回卷规则落盘）：
TAG=LS1 KW='5 20 43 51 52' MAXSNAP=240 SNAPGAP=0.5 SECS=60 \
  BID_EXPECT=0x00000016 \
  SINK_EXTRA='--check lane8 --maxbytes 34359738368' \
  RCVBUF=8388608 \
  bash /tmp/p7b_biz/lf_dl.sh
#    （单点手取也行： bash /tmp/p7b_biz/p7b_snap.sh pair 51 0.5 LS1_p51 ）

# 3) 收尾（对端 FIN ⇒ 板 ev_down ⇒ active=0）：再取 2 点（收尾不动），然后
#    核 ΔW52 在两收尾点之间不再增长。
```
**落盘与解析规则（写进解析器，不许只在人脑里）**：
1. **每点记 `raw` 与 `gen`**（`p7b_snap.sh` 的 `SNAP_BEGIN/SNAP_END ... gen=` 已自带；`trig` 断言 `gen` **恰好 +1**，
   `:141-142`）⇒ 缺 `gen` 见证的点作废；
2. **任何 Δ 一律 `mod 2³²`，并同时记 `raw` 与回卷次数 `k`**（#55）：`Δ = (B + k·2³²) − A`，`k` 由"相邻两点差为负"
   推得；**只记余数 = 回卷本身不可见** ⇒ 判据表必须两列都有；
3. **自证没漏采样（两条硬门）**：
   - 每段 `Δ mod 2³² < 2³¹`（一次真回卷 + 本段增量 ≈ 4.29 GB − 增量，必然 ≥2³¹ ⇒ **≥2³¹ 就是"漏了回卷或计数器倒退"的签名**）；
   - 每段 `Δ mod 2³² ≤ R_max × Δt_wall × 1.5`，其中 `R_max = 1.25 GB/s`（10 Gbps 线速上界；我方设计上界 1.182 GB/s）
     —— 超限 = 该段作废；
4. **至少一条 64 位独立口径对账**（见 §3.3）；
5. **`sfc` 刷新量子**：NIC 计数是**周期刷新**的（流后 1.7 s 读到 = 旧值；`lf_dl.sh:141-144`）
   ⇒ **一律用 `pre2`/`post2`（+2.5 s 等待后的二次读）**，且 **NIC 口径的窗口必须 ≫ 1.2 s**（长流轻松满足；
   短跑必须记 "窗口 < 刷新量子 ⇒ 该口径不可用"）。

### 3.3 对端可用的 64 位 witness（清单 + 用途 + 已知缺陷）

| witness | 位宽/来源 | 用途 | 已知缺陷（引用时必带） |
|---|---|---|---|
| `p7b_tcp_sink` 的 `SINK_CONN ... bytes=` / `SINK_SUM bytes=` / `checked_bytes=` | `long long`（`:122`、`:379-386`） | **主 64 位口径**：`bytes ≥ 2×TX_BYTES` 就是"连续跨过重装载点"的**直接证据**（§4.5） | 单连接（多连需 `SINK_SUM` 聚合）；被 `--maxbytes` 截断（所以要用大值） |
| sink 的 `first_mismatch` / `mism_bytes` | `long long` | 内容 oracle | ⚠️ **lane8/seq 两臂的 `checked_bytes` 必须等于 `bytes`** 才是"逐字节全查"；`--check seq` 只做 `seq` 游标检查 ≠ 内容全查 |
| NIC `port_rx_good_bytes` / `port_rx_packets`（`ethtool -S enp1s0f1np1`） | 硬件计数（`lf_dl.sh:38` 抓取；**回卷按 32 位处理**，`:52-54`） | 独立于板内计数的**物理层**对账（`bytes/pkt` 几何、总字节） | ⚠️ **周期刷新**（见 §3.2-5）；⚠️ **位宽未回源码核**；⚠️ 与内核 `port_rx_*` **同源**（不是第二条独立仪器，见记忆 `xcku5p-mini-10g-board`） |
| `nstat` 的 `TcpInSegs/TcpOutSegs/TcpRetransSegs/TcpExtTCPOFOQueue...` | 内核 64 位 | 段数/乱序/重传形态 | ⚠️ 与 NIC/板侧口径**不同源但同栈**；`~1.2 s` 刷新（`P7B_BIZ_PLAN.md:171`） |
| `ss -tinma` 的 `bytes_acked` / `pacing_rate` / `rtt` / `wscale` | 内核 | 见证窗（§2.4）/ 判断对端限速 | ⚠️ 在**纯接收方向**的连接上 `rtt` 只有握手值（`P7B_LONGFLOW_DESIGN.md:627-629`：C8 未判定的原因）⇒ **不许**用它算窗帽 |
| 板侧 `W51/W52/W20/W43/W5` | **32 位**（本刀硬约束） | 速率与几何 | ⚠️ 回卷（§3.2-2/3）；**W20/W52 在 30 s 内结构性不回卷（88 min）** ⇒ 这两个可以当"**不用记 k**"的锚 |

---

## §4 验证计划（跑哪条命令、看哪个数、判什么）

### 4.1 门：**只用活门**（为什么常驻矩阵不够）

⛔ **常驻矩阵对本刀是空证据**（背景 6 + 背景订正 ③）：
- `sim/p4gates/chain_src.f`（矩阵的编译清单）里**没有 `rtl/app_pattern.v`、没有 `board/wrapper_p4.v`**
  ⇒ **§1 与 §2 的功能面都不在矩阵的编译面内**；
- `app_rx8`/`app_a2`/`integ_app_tx` 三个门名在 `run_matrix_p4dfix.bat` 里命中 **0** ⇒ "矩阵全绿"连"跑过它们"都不算；
- `run_arm.bat` 跑的是 **mirror 快照树**；`run_extra_head.bat` 跑的是 **`head_rtl` 快照（Stage B 期）+ 活 wrapper 的混合编译**，
  且 **无条件 `exit /b 0`（哑门）**。

⇒ **本刀的门（逐条点名，逐条给"看哪个数"）**：

| # | 命令 | 覆盖什么 | 看哪个数 | 判什么 |
|---|---|---|---|---|
| G1 | `cmd //c 'sim\p7b_stageb_rx8\run_rx8_gate.bat'` | **活** `rtl/app_pattern.v`（A/B 两构建 + 4 个变异件 + 隐式网硬失败 + python oracle） | 末行 `RX8-GATE: PASS` 与 `FAILS=n`；A/B 的 8 个 dump/stats `fc /b` 一致；C/D/E/F 的 `RC != 0` | **PASS**（本刀改的就是这个文件 ⇒ 这是主门） |
| G2 | `cmd //c 'sim\p7b_longsend\run_cont_gate.bat'`（**要新写**，§4.2） | 连续模式行为 + 默认关等价 | `CONT-GATE: PASS`；各臂 RC | **PASS** |
| G3 | `cmd //c 'sim\p7b_stagec_tx_regress\author_gate\run_tx_ovl_gate.bat'` | **活** `rtl/tcp_tx_frame.v`（A/B + 7 变异件） | `RC 0` + 变异臂全非 0 | **PASS**（§2 只改它的注释 ⇒ 认证"没碰坏"） |
| G4 | `cmd //c 'sim\p4gates\run_matrix_p4dfix.bat'` | 常驻 16 门（默认构建数据面） | `VERDICT` + 修订指纹 | **只当"没碰坏数据面"的辅助**；⚠️ **不许**当 §1/§2 的验收 |
| G5 | `cmd //c 'sim\p7b_stagec_tx_regress\author_gate\…'` 之外：**`bash -e` 级静态检查** | `.TX_CONTINUOUS(1'b1)` 与 `.TX_BYTES(` 同现且非 0（§1.3①） | `grep -n "TX_CONTINUOUS" board/wrapper_p4.v` = 1 处，且同行/邻行的 `TX_BYTES` ≠ 0 | **PASS** |

**"这个门到底编译了哪份 RTL"的判据（本刀新增纪律，防真空门）**：跑完门后
`grep -n "app_pattern.v\|wrapper_p4.v" <门目录>\xv*.log`，**必须出现本 tree 的绝对路径**（活件）；
出现 `sim\…\head_rtl\` / `…\mirror\…` 一律**不算本刀的验收**。⚠️ 先例：`extra_head/*/run.bat` 就是硬写快照路径。

### 4.2 新 TB（**要新写**）：连续模式的行为门

- **TB 名**：`tb/tb_app_cont.v`（自检式、无 Python；结构与 `tb/tb_app_a2_equiv.v` 同款：
  `chk` 任务 + `[FAIL]` 行 + 末行 `TB_APP_CONT: OK/FAIL errs=N`；时钟 `#3.2` = 156.25 MHz）。
- **runner**：`sim/p7b_longsend/run_cont_gate.bat`（照 `sim/p7b_stageb_rx8/run_rx8_gate.bat` 的形状：
  自定位 + `CLAUDE.md` 路径守卫 + 每臂独立 `runX/` 目录 + `xvlog` 的隐式网硬失败 + `xelab`/`xsim` 的
  `VRFC 10-3091 actual bit length 1` 硬失败 + `fc /b` 文件对比 + 变异件 `RC != 0` 检查 + 汇总
  `FAILS=n` ⇒ `exit /b`）。
- **实例与臂**（同一份 TB 源码，靠 `ifdef APP_CONT_ARM` 切）：

| 实例 | 配置（`TX_CONTINUOUS`, `TX_BYTES`, `TX_SEGSZ`, `AUTO_CLOSE`） | 用途 |
|---|---|---|
| `u_base` | `0`（**不写该参数**，靠默认）, `1000`, 1460, 1 | **基线臂**：量子只有 1 帧（1000<1460）⇒ 便宜地走"`remain` 到 0 ⇒ 终结" |
| `u_cont` | `1`, `1000`, 1460, 1 | **连续臂**：量子只有 1 帧（1000<1460）⇒ 便宜地走"`remain` 到 0 ⇒ 重装载" ≥3 次 |
| `u_cont_big` | `1`, `3000`, 1460, 1 | 多帧量子（1460+1460+80 = 3 帧/量子）⇒ 跨量子时图案连续 + 量子内帧长序列可对账 |
| `u_cont_one` | `1`, `1`, 1460, 1 | 边界：`seg_len = 1`（每帧 1 B）⇒ 重装载频率最高 |
| `u_zero_c` | `1`, `0`, 1460, 1 | 退化臂（§1.3①）：必须 = `u_zero_d` |
| `u_zero_d` | `0`, `0`, 1460, 1 | 今天的"纯 RX/静默停滞"参考 |
| `u_txok` | `1`, `1000`, 1460, **0** | **§1.5 陷阱臂**：在量子末边界拍把 `app_tx_ready` 拉低 ⇒ 逼 `frm_wait` 路径（`AUTO_CLOSE=0` 顺带证明它门控的是 `close_req`） |

  ⚠️ **`u_base`/`u_zero_d` 一律不写 `.TX_CONTINUOUS(...)`** ⇒ 同一份 TB 可以被**冻结件**
  `sim/p7b_stagec_tx_regress/frozen/app_pattern_rev0e804099.v` 直接编译（§4.3）。
- **激励与拍数预算（必须照算，否则 xsim 会跑飞）**：`ev_up` **单脉冲**（1 拍）→ 跑到拍数上限为止
  （`CY_TOT` 写死，**不许**用"事件计数到为止"当终止条件），全程不注入 `ev_down`（除 `u_txok` 的 `app_tx_ready` 拉低）。
  - **默认构建**（无 `P7B_10G`）拍/帧 ≈ **1828**（`P7B_GAP9_TCPAPP_8WAY_DESIGN.md` 的 xsim 直测口径，**来自文档**）；
    `P7B_10G` 下 ≈ **190**。
  - 所需拍数 ≈ `(跨量子总帧数) × 拍每帧`：`u_cont`(4 帧)/`u_cont_big`(9 帧)/`u_cont_one`(4 帧) 在默认构建下
    ≤ 16.5k 拍 ⇒ **`CY_TOT = 40_000` 对默认臂够**；`u_txok` 另加暂停窗口（+2k）。
  - ⚠️ 若把 `u_cont_big` 的 `TX_BYTES` 调大（例如 30,000 ⇒ 21 帧/量子 ⇒ 4 量子 84 帧 ⇒ 默认构建 ≈154k 拍），
    **必须同时把 `CY_TOT` 调大**（或只在 `-d P7B_10G` 臂跑它）—— 别让"跑飞"变成"门超时假红"。
- **断言清单（逐条，都可判）**：
  - **A1** 连续臂（`u_cont`/`u_cont_big`/`u_cont_one`）：`close_req` 从 `ev_up` 到仿真结束**恒 0**（脉冲计数 == 0）；
  - **A2** 同上：`done` **恒 0**；
  - **A3** 同上：`stat_tx_frames` 在 `CY_TOT` 内 ≥ **4 个量子的帧数**（`u_cont` ≥ 4；`u_cont_big` ≥ 9；
    `u_cont_one` ≥ 4）⇒ "帧**持续**产生"（不是"发完就停"）；
    ⭐ 这一条在板级有对应物 = §4.5-B5（`ΔW52 > 一个量子的帧数`），两处口径要一致；
  - **A4** 每帧长度序列 = TB 自己的算术模型 `min(TX_SEGSZ, remain_at_start)` **逐帧相等**，且**重装载点上的
    帧长 = 1460（不是 0）** —— ⛔ 这一条就是 §1.5 陷阱的判别式（漏改 `:736-738` ⇒ 帧长出现 0 ⇒ A4 红 + A3 红）；
  - **A5** `stat_tx_bytes` 在 `CY_TOT` 内 ≥ **3×`TX_BYTES`**（与 A3 的下界同一口径：`u_cont`/`u_cont_one` 实际会 ≥4×），
    且与 TB 自己数的交付字节**逐拍对账**（`stat_tx_bytes` 只在交付拍推进，`:764-774`）；
  - **A6** 交付字节流逐字节 = TB 的 xorshift64 模型（**跨重装载点不许重复/跳变** —— 重装载不动 LFSR）；
  - **A7** AXIS 保持合同（`tvalid && !tready` 期间 `m_*` 不变）+ 每个 `tlast` 恰闭合一帧；
  - **A8（负对照臂 = 门有牙，题面要求的那一条）**：**同一激励**下 `u_base`（默认关）必须
    **`close_req` 至少出现 1 次 + `done == 1` + `active` 回落 0**；
  - **A9（门有牙的第二形态）**：变异件 `negctl/app_pattern_cont0.v`（把 `CONT_OK` 钉成 `1'b0`，其余不动）
    在 `-d APP_CONT_ARM` 下 ⇒ **A1/A2/A3 必须翻红**（`close_req` 出现、`done=1`、帧数停在 1 个量子）；
  - **A10** `u_zero_c` 与 `u_zero_d` 的 dump/stats **`fc /b` 逐字节相同** ⇒ §1.3① 的"结构性退化"是实证；
  - **A11** `u_txok`：在量子末边界拍拉低 `app_tx_ready` 之后，恢复时**必须继续发**（帧数增长、无 0 长帧）
    ⇒ 覆盖 `:736-738` 分支；
  - **A12** 拍/帧（`rate.txt`，**唯一允许两构建不同的读数**）：`u_base` 与 `u_cont` 的**量子内**拍/帧逐帧相同
    ⇒ "重装载不引入气泡"。
- **变异集（→ `RC != 0` 是判据）**：`mk_mut_cont.py` 生成（形状照 `mk_mut_tx.py`：**逐条声明替换文本 + 命中数**）：
  M1 = `CONT_OK` 钉 `1'b0`（连续逻辑整条失效）· M2 = 删掉 `:688-690` 处的 `if (cont_reload) remain <= TX_BYTES;` ·
  M3 = 只改 `:688-690` 漏改 `:736-738`（**§1.5 陷阱的定向反例**）· M4 = 把 `:676` 的 `&& !CONT_OK` 删掉。
  期望：M1/M2/M3/M4 至少 M1/M3/M4 必红（M2 可能被 M3 的等价路径掩盖 ⇒ 若 M2 不红，**如实登记"M2 无判别力"**）。
- **判据汇总**：`ARM A 默认构建 RC=0` · `ARM B -d APP_CONT_ARM RC=0` · `ARM C -d P7B_10G -d APP_CONT_ARM RC=0` ·
  `ARM G 冻结件 RC=0 且与 ARM A 逐字节相同` · `M1..M4 RC != 0`（M2 例外需登记）。

### 4.3 等价锚（"默认关逐位退化"的实证）

- 臂 **G**：把 TB（`tb/tb_app_cont.v`）与**冻结件** `sim/p7b_stagec_tx_regress/frozen/app_pattern_rev0e804099.v`
  一起编译（**不带任何宏**）⇒ `dump_tx.hex`/`dump_tx.frm`/`stats.txt` 与臂 A（用改后的 `rtl/app_pattern.v`、同样不带宏）
  **`fc /b` 逐字节相同**。
  ⚠️ 该臂的 `xvlog` **只给冻结件、不给 `rtl/app_pattern.v`**（两者都声明 `module app_pattern` ⇒ 同库双定义会编译失败）；
  runner 里必须把这一臂的文件表单独列（不要复用臂 A 的文件表）。
- 依据：冻结件与**改动前**的 `rtl/app_pattern.v` **sha256 逐字节相同**
  （`0e804099400c2e2b800ef66bbf49d0d26892bb977e4523de208581ef0d81ce06`，背景订正 ⑤）。
- ⛔ 若臂 G 不逐字节相同 ⇒ **本刀作废**（说明"默认关"没有逐位退化），不许往下走。

### 4.4 构建（一次构建收口 + 记录口径）

1. **前置**：G1/G2/G3 全绿（"改 RTL 与跑回归互斥" #57 ⇒ 门跑完**再**构建；构建期间**不许**再改源文件）。
2. **一次构建收口**（两处改动同批）：`cmd //c 'board\run_build_p7b_ku5p.bat'`（⛔ **绝不**走 GUI/`vivado_prj` ——
   `imports/board/wrapper_p4.v` 是 BID 0xA 旧版，会踩"永久禁发"陷阱）。单次 ≈26 min。
3. **必录读数**（逐项落盘到新建的 `_proj_10g/notes/p7b_build_longsend/INDEX.txt`，沿用 longflow 轮的形状）：
   - `WNS / WHS / WPWS` 与 **三类失败端点（setup / hold / pulse-width）必须 `0/0/0`**（口径 = 路由后 timing summary 的
     "Timing constraints are not met" 计数 + 三个 failure 计数）；
   - **DP 域前 10 族**（与 S3 的族清单对照：S3 的族 = 来自文档 `P7B_LONGFLOW_DESIGN.md` 的板级结果块；
     ⚠️ 本件**未**回时序报告逐字核，构建时现取）；
   - **资源增量**：LUT / FF / 控制集 / BUFGCE / BRAM（用于校核 §1.8 的"终结分支被关死 ⇒ done/close_req 的 FF 消失"）；
   - 位流 `sha256` + 字节数（预期 15,431,261 B）+ `SW_CRC`；
   - `BUILD_ID_V` 回读 = `0x16`（板上身份门）。
4. **事前准则（写死，不许事后调整）**：
   - 失败端点 `0/0/0` ⇒ **进板级**；
   - 端点非 0 ⇒ **不许重跑到过为止**：#64 已证"同输入重跑 = 位级复现、方差 0"⇒ 重跑没有信息量。
     处置顺序 = ① **拆刀**（单独 §1 / 单独 §2 各建一次，定位是哪一处吃掉余量）；
     ② 若 §1 单独即失败 ⇒ 按 longflow 轮的**常量阶梯先例**降 `TX_BYTES`（2²⁸ → 2²⁶ → 2²⁴ …），
     **每档登记读数（含失败档）**；③ 若只有 §2 失败 ⇒ 先回退 §2（`0xBFFE`）保 §1。
5. ⚠️ **#54 归档**：`run_build_p7b_ku5p.bat` 自带 pre-build 归档（`p7b_build_archive\<stamp>\` + `SHA256SUMS.txt`）
   ⇒ 构建后**立刻**把本轮 timing/utilization 报告复制进 `p7b_build_longsend/`（`create_project -force` 会清 `impl_1/`）。

### 4.5 板级协议（逐步、命令级）

> **硬纪律**：① **每次测量前必重烧 + 核 `sha256` ↔ 板侧 `0x04`（BID）**；② 只 JTAG 易失烧录（**绝不写 QSPI**）；
> ③ `0x08` 既是 SCRATCH 又是 TX_DIS 门；④ 关机重启后先按 `P7B_LOOP_HANDOFF.md` §6 的清单恢复环境。

```
# ── P0. 前置（对端机；每次开工都做）───────────────────────────────
ethtool -C enp1s0f1np1 adaptive-rx off rx-usecs 0     # #68：读数低的第一主因（唯一变量 A/B 已证）
ip route get 192.168.100.2                            # 现取；没有 /32 ⇒ 先补
nmcli device set enp1s0f1np1 managed no               # 防 NM 冲掉 /32
bash /tmp/p7b_biz/p7b_selftest.sh                     # 工具自检（§3.1 改了 sink ⇒ 必跑）

# ── P1. 烧录 + 身份 ───────────────────────────────────────────────
#   （本机）TCPREG_BIT=<abs>\vivado_prj\p7b_ku5p_prj.runs\impl_1\wrapper_p4.bit
#          cmd //c '_proj_10g\notes\p7b_biz_tcpreg\run_program_tcpreg.bat'
#   读 stdout：TCPREG_BIT / TCPREG_BIT_EXISTS / TCPREG_PROG_DONE 且 "End of startup status: HIGH"
#   sha256 核对（本机）：sha256sum <bit>  ⇒ 必须等于 §4.4 落盘值
#   PCIe 恢复（如需）：设备级 remove+rescan；若开机时板跑的是厂商设计（1 BAR）⇒ 连根端口一起 remove+rescan
#   （对端机）EXPECT_BID=0x00000016 bash /tmp/p7b_biz/p7b_snap.sh id   ⇒ ID_OK + ID_UNIMPL=0xffffffff(0x11C)

# ── P2. 恢复发流（若上一轮停在受控停流态）───────────────────────────
reg_rw /dev/xdma0_user 0x08 w 0x0          # scratch[1]=0 ⇒ sfp2_tx_dis=0 ⇒ carrier 回来

# ── P3. 主臂（构建 A，连续模式）────────────────────────────────────
TAG=LS1 KW='5 20 43 51 52' MAXSNAP=240 SNAPGAP=0.5 SECS=60 BID_EXPECT=0x00000016 \
  SINK_EXTRA='--check lane8 --maxbytes 34359738368' \
  bash /tmp/p7b_biz/lf_dl.sh               # 内窗 5 字短表系列 + ss 10ms + NIC 四点，全自动落盘

# ── P4. 负对照臂（S3 位流；同会话、同工具、同参数）──────────────────
#   位流 = p7b_build_longflow/S3 的 S3 位流（BID 0x15），--maxbytes 同上
#   ⇒ 期望：sink 在 bytes ≈ 268,435,455 就 EOF（板自己 FIN）⇒ 立即停；
#           而主臂在同一墙钟内 bytes 继续涨 ⇒ 两臂 bytes 相差 ~128× ⇒ 判别力极强

# ── P5. 收尾（主臂）────────────────────────────────────────────────
#   sink 读满 maxbytes ⇒ status=0 ⇒ 退出 ⇒ 关连接 ⇒ 板 ev_down ⇒ W3 收尾 ⇒ active=0
#   再取 2 个收尾点（SNAPGAP=0.5）⇒ 判据：ΔW52 在两点之间 == 0（停住了）
#   （紧急停/备用：(a) 物理停发：reg_rw /dev/xdma0_user 0x08 w 0x2；判据切到 SINK_CONN 行口径）
```

**主判据（逐条给"看哪个数、判什么"）**：

| # | 数 | 判 |
|---|---|---|
| B1 | `ID_OK` + `ID_UNIMPL=0xffffffff`（0x11C） | **PASS**（身份/几何） |
| B2 | `SINK_SUM`: `fail_conns=0` · `mismatch_bytes=0` · `bad_conns=0` · **`bytes ≥ 2×TX_BYTES`（≥ 536,870,910）** | **PASS** ⇒ **"跨过了量子边界且继续发"= 连续模式的直接证据** |
| B3 | `SINK_CONN`: `checked_bytes == bytes`（lane8 臂） | **PASS**（逐字节全查，不是抽样） |
| B4 | 板侧内窗速率（两点**都在流内**、各点 `gen` 恰好 +1）：`ΔW51/Δt` ≥ **9.0 Gbps**，且 `P = ΔW43/ΔW20 ≤ 194`。⛔ **实现轮订正 (2026-10-09)**: `Δt` **必须 = `ΔW5/156.25e6`（板内时基）**，不许用宿主墙钟（那是另一条更弱的判据；两条口径都要留读数，但判据只认板内时基） | **PASS**（延续 longflow 轮的 C1/C2 口径） |
| B5 | `ΔW52`（mod 2³²）**> 183,860**（一个量子的帧数） | **PASS**（同上，帧口径的"跨量子"证据） |
| B6 | `ΔW54 ≡ 0`（失配字节）· NIC `Δbytes/Δpkt` 恒定 | **PASS** |
| B7 | 收尾两点 `ΔW52 == 0`。⛔ **实现轮订正 (2026-10-09)**: **单独读它是空判据** —— "收尾完成 / 卡在 `frm_wait`（窗关）/ 卡在 `closing`"三种都给它 0 ⇒ **必须绑 `SINK_SUM bad_conns=0`（且 `clean_conns` 计入）一起读**，才排除"不是收尾、是卡住" | **PASS**（对端 FIN ⇒ 逻辑收尾真的发生） |
| B8 | 负对照臂（S3）：`bytes ≈ 268,435,455` 后**停**（`ΔW52` 不再涨） | **PASS**（"有限会话"与"连续"被两臂分开） |
| B9 | §2.4 的 **W2/W3** 判别臂（同 bitstream，只改对端 `--rcvbuf`） | 按 §2.4 的三分支口径记，**不许**记成 PASS/FAIL 之外的措辞 |

⛔ **不许写"已收口"**：即便 B1–B8 全中，§5 的未定案项（离群散布、`ΔW55`、LF5 的 4 个 CRC 错帧）仍在。

### 4.6 ⛔ **不在本单范围**（明确登记，避免被读成漏做）

1. **`rtl/tx_arb.v` 的慢路径有界等待（aging）** —— 我方主控已把它登记为**独立的后续里程碑**；
   本单只在 §5.2 用一句话登记其形状与代价，**不设计、不实施**（本刀一个字都不动 `tx_arb.v`）。
2. **UDP 侧**：`app_udp_pattern` 本来就连续且已达线速（背景"UDP 侧已确认"）⇒ 本单不碰。
3. **TCP app 的 TX 8 路（A2）**：已由 Stage C 落地（`ifdef P7B_10G` 的整字预取分支，`:439-457/:704-720/:775-782`）
   ⇒ 本单不重做、不改。
4. **RFC 的窗口缩放（wscale）用于我方通告窗**：与下行无关（§2.2-(8)）⇒ 不碰。
5. **`app_ctrl` 寄存器总线接 AXI-Lite 桥**（让主机能发 CMD/分池）—— 本刀的限制（§1.6），
   登记为后续里程碑，**不实施**。
6. **双向 TCP 数据 × 数据长流** —— 结构性做不了（演示 app 单会话），另立设计件。
7. **`retx_ram` 迁 URAM**（§2.3-O3）—— 报告已备、未实施。

---

## §5 缺陷知识与未来计划（**逐条可引用**；"不许当已收口"清单）

### 5.1 TCP `TX_BYTES=0` 的**静默停滞**语义（不是"不发后关闭"）
`TX_BYTES=0` 时：`seg_len = 0`（`rtl/app_pattern.v:619-620`）⇒ `op_beat` 因 `(seg_len != 12'd0)` 恒 0（`:403`）
⇒ `op_pend` 永远清不掉（`:748-751` 不可达）⇒ `asm_go` 恒 0（`:449-451`/`:455-456` 的 `!op_pend`）
⇒ **`:670-683`（帧收尾/终结）与 `:732-742`（`frm_wait` 解除）都不可达** ⇒ 结果：`active` 恒 1、**线上零帧**、
**不置 `done`**、**不发 `close_req`**，直到 `ev_down`（`:634-636`）或复位。
⇒ **陷阱**：它在 6 个 TB 实例里被当"纯 RX 实例"用（`tb/tb_app_rx8_equiv.v:144/154/164/174/184/256`），
所以"看着没事"；而任何**希望它自动收尾**的场景都会拿到一个**永远挂着**的会话。
⇒ 本刀据此把 `TX_CONTINUOUS=1 且 TX_BYTES=0` **判为非法配置**（§1.3①），并用 `CONT_OK` 使其**结构性**退化。

### 5.2 ~~慢路径（HLS：ARP / ICMP / SYN-ACK / 建连）在严格优先仲裁下**可被永续数据源无限期饿死**~~
⇒ ⛔ **本推断已被 2026-10-09 板级实测证伪（2026-10-10 整条改写；原始证据见下 ②）**

**① 当年怎么写下的（保留为记录，但结论句已作废）**：
- **形状**：`rtl/tx_arb.v:27-51` 的仲裁 = `if (s_fast_tvalid) sel_fast <= 1; else if (s_slow_tvalid) sel_fast <= 0;`
  —— **无 aging、无配额**；帧一旦锁存只到 `tlast` 才释放（`:48-50`）。TCP app 连续发送 ⇒ `s_fast_tvalid` 几乎恒 1
  ⇒ `s_tready` 对慢路径恒 0。~~本刀把 app 变成**永不结束**的源 ⇒ 饿死从"有界（会话 N ms）"升级为"**无界**"。~~
  ⛔ **"无界饿死"这一步已被实测证伪**（见 ②）；"无 aging"这条结构事实本身没错。

**② 板级实测（2026-10-09，**UDP 泛洪已持续 300 s 期间**做慢路径活性测试）**：
- 泛洪进行中：对端 `ping -c 5` ⇒ **5/5 通**（L1 `rtt min/avg/max/mdev = 0.076/0.094/0.126/0.017 ms`；
  L2 同 **5/5 通** / `0.077/0.090/0.100/0.008 ms`）；不泛洪基线 = **0.077 ms**（L1 `:59`）/ **0.109 ms**（L2 `:122`）
  ⇒ **同量级**（泛洪期甚至不比基线差）。
- `nc -z 8080` 对板的 TCP 8080 ⇒ **建连成功**（两跑各一次，`PINGF_NC_RC=0` ⇒ 共 **2 次建连**；
  SYN-ACK 只能由 **HLS 慢路径**发出）⇒ **慢路径在 300 s 满流下仍能拿到线**。
- 两跑合计 **10 个 ICMP 应答**（5+5）+ **2 次 TCP 建连**。
- **逐字原始件**：`_proj_10g/notes/p7b_udp_longrun_20261009/tables.txt:59-61`（L1）/ `:122-124`（L2）；
  原始 stdout = `log_L1.txt:3947-3962` / `log_L2.txt:1066-1081`（`PHASE ping_while_flood`）。
- ⚠️ **本实验的"停发后"那一臂不成立**（`ping_after_stop` 跑在 `0x08 w 0x2` = 物理 TX_DIS、`carrier=0` 之后，
  `PINGS_NC_RC=1` 是**链路层结果**，不是慢路径结果 —— 见 §5.6-17）⇒ **它不能被读成"慢路径也会死"的对照**。
- ⚠️ **逐字登记的一处不齐**：两跑的"不泛洪对照" `nc -z` 只有 **L1 成功**（`CTRL0_NC_RC=0`；L2 = 1 ——
  而 L2 的泛洪期那次反而成功，同脚本同参数）。它**不削弱**上面两次泛洪期成功（同一相位、同一命令、
  两跑都中），但说明"8080 建连"本身存在**未定的间歇性** ⇒ **不许把本条升格为"慢路径活性已被完整刻画"**。

**③ 机理（**推断，未证**）**：结构读法（严格优先 + 只在帧末重仲裁）本身没错，**漏掉的是快侧本来就有每帧
≥2 拍气泡** —— 帧完成拍 `T_DONE`（`rtl/tcp_tx_frame.v:269`；UDP 侧同款 `rtl/udp_tx_frame.v:89`）1 拍 +
`tx_arb` 的帧间重仲裁 1 拍（`rtl/tx_arb.v:2-3` 逐字"帧间 1 拍重仲裁气泡"）⇒ **慢侧就是靠这个窗口拿到线的**。
⇒ **"无 aging" ⇒ "必然无界饿死"这一步推不出**。
⚠️ **未证**：本轮**没有**逐拍 RTL 级见证（没有"慢侧在第几拍拿到线"的计数器/波形）；气泡窗口的**大小与频率未量**。
⚠️ **本实验里卡慢路径的是 `u_tx_udp_arb`**（UDP app 作 fast、HLS 作 slow；优先级声明逐字见
`board/wrapper_p4.v:2449-2466`），**不是** TCP 那条 `rtl/tx_arb.v` —— 两者**同构**（帧级锁定 + 帧末 1 拍重仲裁），
故机理推断对两者同款；**但"TCP 严格优先下慢路径也只被有界延迟"这一格，本实验并没有直接测**（本轮泛洪源是 UDP app）。

**④ 顺带订正 / 相容项（**这三处不是错，别改**）**：
- `rtl/tx_arb.v:1-3` 头注释与 `board/wrapper_p4.v:2449-2466` 的设计理由（"单帧有界 ≤1500/1518 B ⇒ **互不无界阻塞**"）
  **没有被证伪** —— 被证伪的是**下游据此推出的"必然饿死"**（就是本节 ① 的那句）。
- `board/wrapper_p4.v:2096` 与 `rtl/tcp_tx_frame.v:452` 记的"SYN-ACK 被严格优先**饿死 ~14 µs**"是 r5/r6 轮的
  **板级逐帧定案**（一个有界延迟），与本轮实测**相容**（慢侧被压 → 但仍在 µs–亚 ms 量级拿到线）。
- `_proj_10g/notes/P7B_RATE_DATAPATH.md:141`（"单帧有界 ≤1518 B ⇒ **不会饿死**"）同样相容。

**⑤ 仍然成立的部分**：
- **TCP ACK 不在此列**：ACK 走的是**同一条 fast 臂**（`tcp_tx_frame` 的 `ackq`→`s_fast_*`），且在 `tcp_tx_frame` 内部
  ACK 压数据（`start_data` 要求 `!ack_pend_r`，`:516-519`；`start_ack` 优先级更高，`:1215-1216`）⇒ 本刀不制造
  "ACK 被饿死"。
- **"正确的修法形状 = 有界等待，不是严格反转"这条结论保留**：把 `s_fast` 优先级整体反转，会让控制帧在
  **193 字/帧的满流**里**打洞**（每个控制帧 = 一个整帧时隙 ≈ 190 拍 ≈ 一个帧周期 ⇒ 按控制帧到达率线性损失吞吐），
  且反转后 data 侧若没有对应的有界等待，**问题只是换了个方向**。登记的未来里程碑 = **`tx_arb` 的慢路径 aging**：
  形状 = 给慢路径一个"最长等待拍数 N（或每 M 帧让一个时隙）"，到界即强制让路；代价 = **每窗口 ≤ 1 个帧时隙的
  吞吐损失**（可算：1/193 ≈ 0.52%/次）+ 仲裁逻辑多一个计数器 + 需要一条"控制帧真的插进去了"的判据
  （用 `ΔW20` 与慢路径计数交叉）。**本单不实施**（§4.6-1）。
  ⛔ **动机已变**：它不再是"防无界饿死"（那条已被证伪），而是"**把慢路径延迟从 ~14 µs–(未量) 压到有界小值**"
  （低延迟行情/建连目标）⇒ **优先级由用户定**，不再是一个缺陷修复项。
  ⇒ ⛔ **2026-10-10 登记：该里程碑已取消**（不再列为下一步选项；见 §8.4 与 `P7B_LONGSEND_ACCEPT.md` 的"未来计划"）。

### 5.3 板上无可支撑分钟级窗口的计数器（**32 位硬约束**）
`W51/W15/W53/W54`（字节）@9.3–9.4 Gbps ≈ **3.65–3.70 s 回卷**；`W5/W24/W43/W29`（156.25 MHz 时基/拍）
= **27.487 s**；`W20/W8/W10/W52`（帧）≈ **88 min**。
⇒ 分钟级窗口**必须**：`mod 2³²` + 同时记 `raw` 与 `k`（#55）+ 采样周期 ≤ 0.5–1 s（§3.2）。
⚠️ 反例提醒：`P7B_BIZ_S2.md` 的验收已登记过"真回卷族 = `W1/W31/W37` + `W53`"，而报告曾举错例 ⇒ **引用回卷族先回读数核**。
⭐ **可复用范例（2026-10-09 UDP 300 s 长流轮）= "逐点求和 + 双序列交叉核"**：
`_proj_10g/notes/p7b_udp_longrun_20261009/udp_longrun.sh` 的 `STEP=1.0 s`（≪ 3.6 s 回卷周期 ⇒ 回卷余量 ≥3.6×），
每点 = 一次**触发锁存**且 `gen` 自证 **恰 +1**；**主口径 = 逐点差分的求和**（不是两时刻差），再用
`W9`（app 字节）与 `W20`（帧）**两条独立序列**交叉核。读数：n=301 点 / 300 段、`payload 速度集 = {9.5336}`（逐段恒定、
min=max=mean）、`P = 192.99998`（`tables.txt:3-5`）；整窗还原 = `ΔW9_raw` + `k=83`（`an_L1.txt:334-336`）。

### 5.4 `P = ΔW43/ΔW20`：S3 实测 **200.4 拍/帧** / **A 臂 ≈199.7**（长跑反推） vs 线几何 **192.25** vs 手数 **193** ⇒ **死拍仍在，本轮没缩小**
- **S3（前一轮）**：实测 `P = 200.4`（另有 203.0 / 209.0 两格）；TX 线只忙 **92.3–96.3%**；
  `P − 193 = 7.4`（对**手数预算**）/ `P − 192.25 = 8.15`（对**线几何**）。
  来源 = `P7B_LONGFLOW_DESIGN.md` 板级结果块（原始读数 = `p7b_longflow_board/ACCEPT.md`）。
- ⭐ **A 臂（2026-10-09/10 板级轮，本轮新读数）**：桶均实测 **`P = 199.06`**；由板内窗速率 **9.1377 Gbps** 反推
  **`P ≈ 199.7`**（恒等式 `P = 1460×8×156.25e6 / 9.1377e9`）⇒ 对手数 193 死拍 **≈6.1–6.7**、对线几何 192.25 死拍 **≈6.8–7.45**。
  与 S3 在同一基上差 ≤1.3 拍 ⇒ **落在两臂各自的跑间散布内 ⇒ 本轮没有缩小**。
  出处 = `_proj_10g/notes/p7b_longsend_board/ACCEPT.md` §2.2（LSLONG 行）/ §4（20 s 桶轨迹表）。
- **候选（未分离，不许指定其一为根因）**：窗/BDP · 对端 ACK 回流节奏 · app 残余开销。
  ⛔ 本刀原计划"用 §2.4 的 W-small 臂把窗当自变量"**没有做出判别力**（见 §2.4 的 2026-10-10 订正块）
  ⇒ **三个候选全部仍在**。⚠️ 有一个**未证的形态线索**（不许当结论）：ACCEPT §6-③ 记"受限档"里对端
  `TcpOutSegs`（ACK 数）在同一帧数下从 **10,313 变到 68,650** ⇒ **现象上"限速跟着对端 ACK 节奏走"**，
  但**没有做 A/B 把它钉死**。
- ⇒ **下一步要拆开它，必须先补三个计数器（构建 B-1）**：`win_open==0` / `frm_wait` / `txcdc 空拍`
  —— 设计件原话"**这是唯一能把死拍归因的手段**"。

### 5.5 已知未定案项（**引用必带"未定位"**）
1. **对端网卡 RX 中断合并（`rx-usecs 60` / `Adaptive RX on`）关掉后仍有离群跑**：`6.80 Gbps`，n=4，散布
   **6.8–9.31**（来源 = 文档；机理**未定位**）⇒ **不许写"已收口"**。
2. **`ΔW55` 的 RTO 预测被实测证伪**：设计件预测 227 ms 档 `ΔW55 ≈ 11`，实测饱和档 **1/0/0/0**，
   `>0` 只出现在**线未饱和**档（3–19）⇒ **如实报、不调和**；机理（`rto_timer` 被谁复位）**未读码复核**。
3. **LF5 窗内 4 个 CRC 错帧**（对端 NIC 累积计数 0→4，其余 9 跑 0）**未定位**（与同跑 `ΔW55=6` 的因果未证）。
4. **C8（RTT 见证）= 未判定**：纯接收方向的 `ss -ti` 只有握手 RTT ⇒ **既不许说被窗帽限住、也不许说排除**。
5. **残余散布 6.8–9.31 的机理** = 与 (1) 同族，未定位。
6. **（2026-10-10 新增）`W29`（`txwire_stall_cycles`）/ `W45`（`txcdc_ovf_cnt`）在 UDP 泛洪中单调增 ≈900/s**：
   L1 实测两计数器**各自 +268,855**（同一窗 300.0141 s ⇒ **896.0/s**），且**逐点轨迹里两数逐字相同**
   （`_proj_10g/notes/p7b_udp_longrun_20261009/tables.txt:16-17`；L2 = +54,730 / 60.03 s ⇒ 911.7/s）。
   **机理未定位**（派单事实清单原文即标"未定位"）。⚠️ 不许写成本缺陷、也不许写成"无害"。
7. **（2026-10-10 新增）`port_rx_nodesc_drops` 非 0**：L1 `+4,231,038`（对 246,624,507 帧 = **1.716%**）、
   L2 `+908,447`（对 51,463,831 = 1.765%）（`tables.txt:34`/`:97`）⇒ 口径 = **对端描述符耗尽 ⇒ 对端接收侧限速**
   （**不是板缺陷**；与全局 #68 的"对端配置是读数第一主因"同族）。
8. **（2026-10-10 新增）序列号回卷：主体安全 + 两处已知 RFC 偏离** ——
   **主体 = 相对差**（`rtl/tcb.v:142` 的 `win_diff` 逐字"32-bit wrap-correct"；`rtl/tcp_rx.v:303` 的
   `ack_ok` 也是相对差）⇒ 安全；**两处绝对比较 = 已知 RFC 偏离**：`rtl/tcp_rx.v:283-284`（`seq_lt`）与
   `:307-308`（`w6a_ok` 的尾项 `|| seq_lt`）⇒ **后果限于"回卷后重发旧段被静默忽略（不回 ACK）"，
   不是数据损坏**。⚠️ 本轮 **236 s / 62 次回卷未观测到该后果的任何痕迹**（`ΔW23` 两分组恒 0、速率两组中位差
   0.02 Gbps、`ΔW55` 按总时长归一 3.910 vs 3.642 次/s —— `p7b_longsend_board/ACCEPT.md` §4）
   ⇒ ⚠️ **"没观察到" ≠ "不存在"**（无逐包见证、板侧没有"回卷后忽略段"的专用计数器）。
   ⚠️ **RTL 注释面待订正项（登记，本轮未改）**：`rtl/tcp_rx.v:284` 的注释逐字写"**回绕安全: 无符号比较**"
   —— 该措辞**过宽**（绝对比较在 2³² 边界并不等价于 RFC 语义）；**本轮不改 RTL**，只登记（见 ACCEPT 报告）。
9. **（2026-10-10 新增·本轮发现）L1 的 `W11/W13`（app RX 字节 / 失配）在 learn_peer 窗非 0，L2 同相位为 0**：
   L1 `ΔW11 = +11,964,416`（`= p7b_udp_src` 的 `UDP_SUM pay_bytes` **逐位相同**）、`ΔW13 = +11,917,714`；
   跳变**只在 pre(gen=835) → 第一个流内点(gen=837)** 之间（= learn_peer 相位窗）；**L1 之后整段流内 `W13` 恒不动**。
   对照 **L2 同相位：`ΔW11 = +11,917,312`、`ΔW13 = 0`**。出处 = `tables.txt:14-15`（L1 守卫块）/ `:77`（L2）、
   `log_L1.txt:104-119`（`UDP_SUM … pay_bytes=11964416`）。
   ⇒ **本轮（派单事实清单）未含此条、也未归因**；形态与"校验器相位/使能晚于流起点"一类**相位错位**相容
   （推断，**未证**；已核 `board/wrapper_p4.v:2528` 的 `i_en` 板上**恒 1** ⇒ **不是简单的"使能来晚了"**）。
   ⛔ **不许读成"板子 RX 内容坏了"**，也**不许读成"无失配"** ⇒ 登记为**待核项**，下一轮先答。

### 5.6 本刀新增的"门面/工具面"缺陷知识（**都是这次回源码抓到的**）
1. **门名 ≠ 门实际编译的树**：`run_arm.bat` 跑 **mirror 快照**、`run_extra_head.bat` 跑 **`head_rtl` 快照 + 活 wrapper
   的混合编译**（且 `head_rtl` 是 Stage B 期的 `app_pattern`，`grep -c P7B_10G` = 5 vs 活件 10）。
   ⇒ **判"门有没有牙"的第一动作 = 读编译日志里的 RTL 路径**（本件 §4.1 已立为纪律）。
2. **`run_extra_head.bat` 是无条件 `exit /b 0`**（哑门，#53 同族）⇒ 它内部两个门的失败**永不进 RC**；
   判据只能读 `head_log_*.txt` 的内容。
3. **板上有一条"看不见的状态"**：`active`/`done`/`close_req`/`frm_wait` 都不在 63 字快照里
   （`wrapper_p4.v:1203-1206` 悬空）⇒ 长流的"还活着吗"只能间接（`W51/W52` 在涨）。
   未来计划 = 把 `app_pattern.active`（+ `frm_wait`）接进快照（⚠️ 吃 WNS 余量，接 `stat_wu` 已有先例）。
4. **`app_ctrl` 寄存器总线静止**（背景订正 ②）⇒ 板上**没有**"命令停发/命令关闭"通路；
   未来计划（若产品需要）= 把 `app_ctrl` 寄存器接进 `axi_regs` 的地址窗口（新里程碑，本单不做）。
5. **`p7b_tcp_sink` 的两个默认值陷阱**：`--maxbytes` 默认 4 MiB（忘传 = 只测 3.4 ms）；
   `--seconds` **不终止运行中的连接**（只挡新连接）。⇒ 长流配方必须显式传 `--maxbytes`，并由 `SINK_LIMITS` 自证。
6. **`done` 在连续模式下恒 0**（§1.3④）⇒ 板上 `led_r[3]` 永不亮、TB 不许拿它当完成判据。
7. **`i_bad_frame` 与 16 位 `frm_idx`**：连续模式下 `frm_idx` 每 65536 帧回绕（≈**80.5 ms** @813.8 kfps）
   ⛔ **实现轮订正 (2026-10-09)**: 原文写 "≈80.9 s" —— **数值错 1000×**（`65536 / 813794 fps = 80.52 ms`；
   且"秒"与"分钟级窗口"这条 §5.3 的口径自相矛盾）。**结论方向不变**（板上 `i_bad_frame=16'd0` ⇒ 只在 TB 注入时有意义）。
   ⇒ **只在 TB 注入坏帧时有意义**（板上 `i_bad_frame = 16'd0`，`:1198`）⇒ 长流 TB 若要注入，必须自带回绕口径。
8. **`asm_go` 第三项 `(remain == 32'd0)`（⛔ 实现轮升级：**已证不可达**，不是"可能"）**：
   对抗审查（2026-10-09）**穷举 `op_pend`/`op_sent`/`active` 的全部赋值点**得到结构事实
   `op_pend == 0 ⟹ (op_sent == 1 ∨ active == 0)`；而 `asm_go` 的使能条件含 `active ∧ !op_pend`
   ⇒ 在 `asm_go` 为真的每一拍都有 `op_sent == 1` ⇒ `frm_inflight ≡ 1` ⇒ **该 OR 分项永远不是决定项（死项）**。
   （原措辞"可能不可达 + 需要造一条 TB 断言"**作废**；本刀仍未动它 —— 动它 = 多一处 #64 风险面、无收益。）
   ⚠️ 但**连续模式不改变这个证明**：`CONT_OK` 只改 `:676` 的判据与两处装载值，不进 `asm_go`。
9. **（2026-10-10 新增）`cmd /c` vs `cmd //c` 是**条件式**陷阱**：Git Bash 下**未加** `MSYS_NO_PATHCONV=1` 时，
   `cmd /c '…bat'` 的 `/c` 会被 MSYS 改写成 `C:/` ⇒ **bat 根本没跑**，而 stdout 文件是**上一 session 的陈旧件**
   （"跑了却没跑"）。已加 `MSYS_NO_PATHCONV=1` 时 `cmd /c` 正确；否则用 `cmd //c`。
   **判据 = stdout 里出现本次的 `End of startup status: HIGH` 且文件 mtime = 本次时刻**（`p7b_longsend_board/ACCEPT.md` §1 全程用 `MSYS_NO_PATHCONV=1 … cmd /c`）。
10. **（2026-10-10 新增，已就地修注释）`--check lane8` 是两个参数**：写成 `--check=lane8`（一个词）⇒
   **`unknown arg` + RC=2 硬失败**（不静默）。⚠️ `_proj_10g/notes/p7b_longflow_board/lf_dl.sh` 的用法注释
   原写成一个词 —— **本轮已就地订正为注释级修正**（`lf_dl.sh:10-13`，零行为改动）。
11. **（2026-10-10 新增）`--maxbytes 0` 不是"无限"而是**立即退出**（`while (got < maxbytes)` 体不执行
   ⇒ 末行 `tot_bytes > 0` 为假 ⇒ **RC=1 假红**）；**`--seconds` 不终止正在跑的连接**（只在
   `p7b_tcp_sink.cpp:287` 的外层连接循环入口判一次）⇒ **长流用 `--maxbytes` 控时长**。
12. **（2026-10-10 新增）`run_program_tcpreg.bat` 的 `TCPREG_PROG_EXIT=0` 不在 stdout 文件里**
   （`echo … %ERRORLEVEL%` 在重定向之外，`p7b_longsend_board/ACCEPT.md` §1-(3)/§6-⑤ 实测）⇒ **拿它当判据 = 假红**。
13. **（2026-10-10 新增）`W51` 跨连接累积**（同一次烧录内不归零）⇒ **"流内点"判据的基准必须是该跑 `pre` 快照值**
   （不能用"重置后应为 0"这种假定）。
14. **（2026-10-10 新增）平台属性**：`_proj_pcie/p7b_biz/*.cpp` 在 **Windows/MinGW 下编不过**
   （POSIX socket + `sys/syscall.h`）⇒ **只能在目标机编**。
15. **（2026-10-10 新增·意外负对照，很有价值）**：`0x08 = 0x2`（物理停发）时**板侧内部计数照跑**
   （≈809,578 fps；`udp_longrun.sh:65-67` 逐字登记）而对端 **NIC 计数全 0**
   （D2 相位四点 `port_rx_packets` 恒 `17,729,801` ⇒ Δ=0，`log_D2.txt:36/73/390/427`）
   ⇒ **两条测量口径（板内计数 vs 线上 NIC）的独立性被直接证实**：**板内计数不是"线上发生了什么"的见证**。
16. **（2026-10-10 新增）UDP 的"线上载荷天花板"要用 UDP 口径**：`1472/1538 × 10 = 9.5709 Gbps`
   （L1 实测 9.5336 = **99.61%**）；**历史 TCP 口径 `1460/1538×10 = 9.4935` 对 UDP 不适用**（别混用尺子）。
17. **（2026-10-10 新增）`0x08 w 0x2` 是**物理停发**（拉 TX_DIS）⇒ `carrier = 0` 断链** ⇒
   **不能**拿它当"停流后对照"的判据臂（那一臂的 ping 0/5、`nc` RC=1 是**链路层结果**，不是慢路径结果 ——
   见 §5.2 ② 的警告）。

---

## §6 我核过什么 / 没核什么（纪律登记）

**读了源码并逐行核过（可复核）**：
`rtl/app_pattern.v`（全文 832 行）· `rtl/tcb.v`（全文）· `rtl/tx_arb.v`（全文）·
`rtl/tcp_tx_frame.v:160-240 / 495-570 / 630-690 / 1485-1532`（其余按 grep 定位）· `rtl/app_ctrl.v:275-296 / 545-585 /
1350-1378` · `rtl/retx_ram.v:1-60` · `rtl/tcp_rx.v:420-450` · `board/wrapper_p4.v:210-240 / 1100-1300 / 1928-1950 /
2045-2130 / 3890-3920` · `_proj_pcie/p7b_biz/p7b_tcp_sink.cpp:95-200 / 255-408` · `_proj_pcie/p7b_biz/p7b_snap.sh`（全文）·
`sim/p7b_stageb_rx8/run_rx8_gate.bat`（全文）· `sim/p7b_stagec_tx_regress/{run_arm.bat,run_extra_head.bat,extra_head/p5_wrapper/run.bat,
extra_head/p5_pattern/run.bat,author_gate/run_tx_ovl_gate.bat,author_gate/mk_mut_tx.py:1-45}` · `sim/p4gates/chain_src.f` ·
`_proj_10g/notes/p7b_longflow_board/lf_dl.sh`（全文）· `tb/tb_app_a2_equiv.v:1-60 / 380-420` · `tb/tb_app_rx8_equiv.v:100-200 / 500-512` ·
`_proj_10g/notes/P7B_LOOP_HANDOFF.md:1-120` · `_proj_10g/notes/P7B_LONGFLOW_DESIGN.md:560-641`。
**哈希/计数实测**：`rtl/app_pattern.v` 与 `frozen/app_pattern_rev0e804099.v` 同 sha256；`head_rtl/app_pattern.v` 为另一版本；
`grep -rl "app_pattern #(" sim/` = 71；矩阵对三门命中 0；`sim/p4gates/chain_src.f` 不含 `app_pattern.v`/`wrapper_p4.v`。

**没核（施工前必须自己补核）**：
1. **`WNS +0.052 / 2²⁰→2³¹ 的 −0.049`** —— 来自文档（`P7B_LONGFLOW_DESIGN.md:590-607`），**未**回
   `p7b_build_longflow/S3/READINGS.txt` 与时序报告逐字核；
2. **板级读数 9.108 / 9.314 / `P = 200.4` / 散布 6.8–9.31** —— 来自文档（同上 `:608-632`），**未**回
   `p7b_longflow_board/ACCEPT.md` 与 `runs/LF*.txt` 核；
3. **§2.2-(5) 的"1 拍陈旧能否与帧复合"** —— **未确定**（需要读 `S_DONE → RX_IDLE` 与 `upd_wr` 的逐拍相位，
   或写一条 TB 断言）；本件的结论对两种口径都成立，所以不阻断；
4. **`tcb.win_open` 的 1 拍陈旧在"连续 back-to-back 帧"下的**实际**相位** —— 未做逐拍推演；
5. **`SO_RCVBUF` 在 connect 后设置是否真的压低对端通告窗** —— **未确定**（机制上应当，Linux 显式设置会锁 `sk_rcvbuf`；
   但 §2.4 的 W3 见证是本条的**唯一**裁决者）；
6. **`sfc` NIC 计数的位宽** —— 未回源码/数据表核（`lf_dl.sh:52-54` 按 32 位回卷处理这点是脚本行为）；
7. **`i_bad_frame != 0` 的连续模式 TB 用法** —— 未设计（本刀板上不用，TB 若要注入需自带 `frm_idx` 回绕口径）；
8. **本件没跑任何门/构建/仿真**（按任务纪律），所以 §4 的所有命令**都是待执行规格**，不是已验读数。

---

## §7 实现轮订正块（2026-10-09，实现工程师；**施工后的实测与订正**）

> 本块由**实现轮**追加。上面 §1–§6 的施工规格已按本单执行（**唯一例外 = §5.2/§2.1 的三处注释订正，见 §7.4**）。
> 所有"通过"都有原始输出落盘：`_proj_10g/notes/p7b_longsend/CONT_GATE_stdout.txt`（本刀新门的完整 stdout）。

### 7.1 本块订正的四处（对抗审查点名的，均已就地改在原文里）

| # | 位置 | 订正 | 依据 |
|---|---|---|---|
| B1 | §2.2-(4) | 原引 `:1494` / `:1490-1493` / `:1885-1889` **三处全在 `ifdef TCP_TX_OVL` 的 `else`（未编译）分支**（`ifdef`=`:236`, `else`=`:1077`, `endif`=`:2038`）⇒ 改指**现役等价式** `:507-508` / `:551`·`:553`·`:557` / `:891-893`。**数字结论（≤1508 B/帧）不变** | 实现轮自核（`grep -n` 分支边界 + 逐行读） |
| A8 | §5.6-7 | `frm_idx` 回绕 `≈80.9 s` → **`≈80.5 ms`**（`65536 / 813794 fps`；原文差 **1000×**） | 算术 |
| C4① | §4.5 判据表 B7 | `ΔW52 == 0` **单独是空判据**（收尾完成 / 卡 `frm_wait` / 卡 `closing` 三种都给 0）⇒ 写明**必须绑 `SINK_SUM bad_conns=0` 一起读** | 对抗审查 + 实现轮自查 |
| C4② | §4.5 判据表 B4 | `Δt` 必须点名时基 = **`ΔW5/156.25e6`（板内）**，宿主墙钟是另一条更弱的判据 | 同上 |

另：`§5.6-8` 的 `asm_go` 第三项 `(remain == 32'd0)` 由"**可能**不可达（未形式化证明）"**就地改硬为"已证不可达"**
（对抗审查穷举 `op_pend`/`op_sent`/`active` 赋值点得 `op_pend==0 ⟹ (op_sent==1 ∨ active==0)`，而 `asm_go` 含 `active ∧ !op_pend`），
防止后人把它当死逻辑清理掉时没有依据。

### 7.2 实测新增（**连续模式"对端关闭 → 同槽重连"的静默形态：已复现**）

对抗审查 ① 点名的形态**在本轮 TB 里实测复现**（`tb/tb_app_cont.v` 的 u_rec1/u_rec2 臂，原始输出见 §7.3）：

- **臂**：`ev_down` 落在第 20 个 payload beat；`m_tready` 从该拍起拉低 300 拍（制造"W3 收尾被 tready 卡住"）；
  `ev_up`（同槽）在其后 **k=40**（u_rec1）/ **k=240**（u_rec2）拍发出。
- **观测**：两臂 **`starts_after_up=0`**、`frames=1`（= 卡住那一帧的收尾）、`bytes=168`（= 21 个 payload beat）、
  **`active` 最终回落 0 但再无任何帧** ⇒ **ev_up 脉冲被吞，连接静默零数据、不自愈**。
- **对照臂**（u_rec3，同 k=240 但 tready 只低 6 拍 ⇒ 收尾在 ev_up 之前就完成）：**`starts_after_up=32`、RESUMED**。
  ⇒ 判别变量是"**ev_up 到达时 app 是否仍卡在 closing**"（`ev_restart` 的 `(frm_wait || seg_sent==0)` 两项都假），
  不是 k 本身；**k ≤ 70 也照样被吞（u_rec1 实测）**。
- ⭐ **反直觉（2026-10-10 文档轮补齐此标记）**：本结果**推翻了设计件/交接件里"~70 拍窗口"的直觉** ——
  那条直觉（`udp_hls_10g/CLAUDE.md` 的 D1 注释族："背靠背 DEL→ADD (~70 拍) 采不到 `state=0`"）是把"同槽重连"
  想成**按间隔 k 判**；实测判别变量是**状态**（`ev_up` 到达时 app 是否仍卡在 closing）⇒ **k=40（≤70）也照样被吞**。
  ⇒ 引用"~70 拍"那句时**必须**同时引用本臂。
- **性质**：机制是**既存**的（非连续模式同一窗口也在，见同一轮的 ARM A 输出），**但连续模式把它从窄窗变成常驻** ——
  有限会话里 app 通常早已 idle（走 `!active` 臂），连续模式让 app **100% 时间 active**。
- **本轮不修**（会扩大改动面）。**最小修法建议**：`ev_up` 若判为不可换流（`active && !ev_restart`），
  置一个 **pending 位**（`ev_up_lost`），在 `frm_wait`/closing 结束后补做一次换流 ——
  代价 = 1 个 FF + 一处判据；**判据** = 本块的 u_rec1/u_rec2 臂（`starts_after_up ≥ 1`）。

### 7.3 本刀的门（实测读数）

- **G2（新门）`sim/p7b_longsend/run_cont_gate.bat` = PASS**（8 臂：A/B/C/G + M1..M4；原始 stdout 落盘）。
  - 等价锚 **ARM A vs ARM G（冻结件 `app_pattern_rev0e804099.v`，sha256 与改动前现役件逐字节相同）
    = 24 个 dump/stats/rate 文件 `fc /b` 全同** ⇒ "默认关 ⇒ 逐位退化"是**实证**，不是论证。
  - 变异臂 M1/M2/M3/M4 **全部 RC!=0**（**M2 有判别力**，与 §4.2 的"M2 可能无判别力"预期相反：
    它的红来自 u_cont_big 的帧长序列判据 `got=1460 exp=80`）。
  - 零臂（`TX_BYTES=0`，连续 vs 默认）计数 + 周期快照逐字节相同（A10）。
- **G1 `sim/p7b_stageb_rx8/run_rx8_gate.bat` = PASS**（活 `rtl/app_pattern.v` 为输入：A/B RC=0、4 个变异件全非 0、
  8 文件 A/B 逐字节相同、python oracle 一致）。
- ⛔ **G3 `sim/p7b_stagec_tx_regress/author_gate/run_tx_ovl_gate.bat` = 跑不通（既有缺陷，与本刀无关）**：
  它在**变异件生成**阶段就 `MUTGEN FAIL 5` 退出（`mut_s0b` · `mut_c7` · `mut_c8` 的锚点是**多行**，
  而 `rtl/tcp_tx_frame.v` 在本 checkout 是 **CRLF**（2040 个 CR；`mk_mut_tx.py` 用 `\n` 锚点 ⇒ 0 命中）；
  `mut_c2` 的两个锚点**即使归一化到 LF 也 0 命中** —— 现役 `upd_id`/`upd_val` 已长成**三级三目**
  （`replay_jump ? retx_id_r : svc_id` / `replay_jump ? retx_hi : rb_snd_una`，RETXFIX 轮引入）⇒ **锚点陈旧**）。
  ⚠️ **与本刀无关的证明**：`git hash-object rtl/tcp_tx_frame.v` = `ea1037d6…` = `git rev-parse HEAD:rtl/tcp_tx_frame.v`
  ⇒ **该文件相对 HEAD 零改动**（本刀一个字都没碰它）。⇒ 设计件 §4.1 的 G3 一栏**现役不可用**；
  修法（下一轮，不在本单）：`mk_mut_tx.py` 读入时 `newline=""` → `\r\n` 归一化 + 更新 c2 两条锚点。
- ⚠️ 常驻矩阵 `sim/p4gates/run_matrix_p4dfix.bat`：**编译清单不含 `rtl/app_pattern.v` / `board/wrapper_p4.v`**
  ⇒ 对本刀是**空证据**（跑了也不算，本刀因此**没跑**它）。

### 7.4 未做（**逐条登记，不是漏做**）

1. **`rtl/retx_ram.v` / `rtl/tcb.v` / `rtl/tcp_tx_frame.v` 的帽值注释订正**（§2.1 要求的"必须就地订正"）——
   本轮的派单把可改文件穷举为 `rtl/app_pattern.v` + `board/wrapper_p4.v` + 新 TB/runner + sink + 本件
   ⇒ **这三个文件本轮禁止改**。后果 = **帽值单一来源注释仍写死 `0xBFFE`**（与 `WIN_CAP_5 = 0xF000` 不一致，
   纯注释面，零网表差异）。⇒ 下一轮补，或由派单方解锁文件范围。
2. **板上任何操作**（烧录 / 快照 / 台架实跑）—— 本单明确禁止（另一路 agent 在用板）。
3. **`--maxbytes` 大值的长流实跑**（§3.2 协议）—— 同理属板级轮。
4. **`TX_SEGSZ==0` 的 TB 臂** —— 本轮只"明文登记"（§1.3① 末），没另造实例（它是既存行为、与本刀无关）。

---

## §8 板级轮追加块（2026-10-09/10；⛔ **本块读法优先于上方 §4.5 的板级协议**）

> 派单（用户逐字）= 「实现长时间不停发送的 app，实现线速发送，**TCP 和 UDP 各实现一个**」。
> 收口件 = **`_proj_10g/notes/P7B_LONGSEND_ACCEPT.md`**（轮级一页式 + 证据地图 + "不许当已收口"清单 + 未来计划）；
> 板级原始件 = **`_proj_10g/notes/p7b_longsend_board/ACCEPT.md`**（TCP 连续）+ **`_proj_10g/notes/p7b_udp_longrun_20261009/`**（UDP 300 s）。
> 本件（设计件）只登记与"设计与未来计划"有关的部分；**判据 PASS/FAIL 的裁定权不在本件**（全局 #51）。

### 8.1 交付两件（都已有板级读数）

- **TCP 连续发送（新实现，构建 A）**：`rtl/app_pattern.v` 新参数 `TX_CONTINUOUS`（**默认 `1'b0`**，`:34`）+
  `board/wrapper_p4.v:1186-1187` 板上传 `.TX_CONTINUOUS(1'b1)`；实现点 = `:360`（`CONT_OK`）`:364-365`（`cont_reload`/`remain_nxt`）
  `:691`（终结判据加 `&& !CONT_OK`）`:705`/`:755`（`seg_len` 用 `remain_nxt`）`:711`/`:760`（两处重装载）。
  **默认关 = 逐位退化（实证）**：ARM A vs 冻结锚 `sim/p7b_stagec_tx_regress/frozen/app_pattern_rev0e804099.v`
  在 **24 个交付文件上 `fc /b` 逐字节相同**（`p7b_longsend/CONT_GATE_stdout.txt:81`）；且退化为 **0 个新 FF / 0 个新组合锥**
  （构建读数：LUT +73 / FF +241 全是改动的**实部**，无"默认关也长逻辑"）。
  位流 **A**：sha256 `052c52006215a2c3d5f9d59f8c47e620e41eb20f271fbc09dabfff96330bc284`（15,431,261 B）·
  `SW_CRC 2c237c32` · BID **`0x16`** · `WNS +0.021 / WHS +0.010 / 三类失败端点 0/0/0` · `Slack (VIOLATED)` 路径块 **0 条**
  （`p7b_build_longsend/READINGS.txt` §2.2-2.4）。
  ⚠️ **两臂位流同为 15,431,261 B** ⇒ **只有 sha256 与 BID 能分版**；且**读身份的工具默认 `EXPECT_BID=0x0000000A`**
  （`p7b_snap.sh`）⇒ **必须显式传**，否则必假红。
- **UDP 长时间不停发送**：板上 UDP app 例化本来就把 `TX_BYTES=0`（永久连续，`board/wrapper_p4.v:2525`）
  —— 靠**三处短路**（`rtl/app_udp_pattern.v:529`/`:537`/`:853`），**不是**靠计数器回卷。本轮落成 **300 s 读数**
  （见 8.2），**未改一行 RTL**。

### 8.2 关键读数（全部有原始件；本块只抄口径与指针）

| 项 | 读数 | 口径 | 原件 |
|---|---|---|---|
| TCP 连续（A 臂长跑） | 单连接 **236.3 s** / **270,000,000,495 B**（= 1005.83 个 `TX_BYTES` 量子） | 对端 sink 计时 236.347 s；板侧时基 240.305 s | `p7b_longsend_board/ACCEPT.md` §3 |
| 速率（三口径） | 板内窗 **9.1377 Gbps** / sink 墙钟 **9139.1 Mbps** / 对端内核按套接字 **9.1709 Gbps** | **互差 ≤0.4%** | 同上 §2.2/§4 |
| 内容/记账 | `first_mismatch=-1` / `mismatch_bytes=0`（逐字节全查 270,000,000,495 B）/ 零 stall / 板 `ΔW20 = 184,949,978` **= 对端 NIC `Δport_rx_packets` 逐位相同** | lane8 全查 | 同上 §3 |
| 跨回卷 | **跨 62 次 2³² 回卷**；含/不含回卷区间速率中位差 **0.02 Gbps**、`ΔW23` 两组恒 0 | mod 2³² + k=62 | 同上 §4 |
| UDP 连续（L1） | **300.014 s** / 板内窗 **9.5336 Gbps / 809,577.8 fps** / `P = 192.99998`；**300 个逐秒段取值集合 = {9.5336}** | 板内时基（逐点求和） | `p7b_udp_longrun_20261009/tables.txt:3-5` |
| UDP 对端口径 | NIC **809,081.4 fps** / `Δbytes/Δpackets = 1517.9999`（线上字节 9.8255 Gbps） | NIC 硬件计数；**与板侧帧率差 −0.06%** | `tables.txt:33/36/50` |
| UDP 内容 | 两跑各抓 3000 帧（pcap 4,590,024 B = 24 + 3000×(16+**1514**)）逐字节校验；⚠️ **校验器 stdout 未在目录单独落盘**（pcap + 校验器源码在）⇒ 判定引用须带 `P7B_LONGSEND_ACCEPT.md` §3 的注解 | 逐字节 | `tables.txt:62/125` + `content_L1/L2.pcap` |
| UDP 天花板 | **1472/1538×10 = 9.5709 Gbps** ⇒ 实测 9.5336 = **99.61%** | UDP 口径（**不是** TCP 的 9.4935） | 本件 §5.6-16 |

⚠️ **口径纪律**：上表每一格的分子分母都不同（板内窗 / 墙钟 / NIC / 设计上界 / 线上天花板）⇒ **引用速率必须带口径**；
本工程出过一次"`98.5%` 配错对象"的错（9.108 被配了 98.5%，实际 98.5% 属 9.314）。

### 8.3 本轮的"不许当已收口"清单（**逐条**；完整版在 ACCEPT 件）

1. **死拍未缩小**（§5.4：A 臂 `P ≈ 199.7` vs S3 200.4，同一基差 ≤1.3 拍 ⇒ 落在散布内）⇒ **补三计数器 = 唯一归因手段（构建 B-1）**。
2. **窗帽抬升 = 本轮【未判定】**（§2.4 的 2026-10-10 订正块：负对照臂结构性短窗 + 短窗噪声主导 + 同位素臂落低档无判别力）⇒ **A-minus 臂（构建 B-2）**。
   `WIN_CAP_5` **保留**，理由 = 未判定不构成回退理由 + 回退会作废已验收位流；**不许写"保留作 BDP 余量"**。
3. **A7 静默形态（本轮不修）**：连续模式下"对端关闭 → 同槽重连"可能 `ev_up` 被吞 ⇒ 新连接静默零数据、无自愈；
   ⭐ 判别变量 = "`ev_up` 到达时是否仍卡在 closing"，**不是间隔 k**（k=40 ≤ 70 也照样被吞）⇒ **推翻"~70 拍窗口"的直觉**；
   机制是**既存**的（ARM A 不传 `TX_CONTINUOUS` 同样复现），连续模式只是把它从"窄窗"变"常驻"；最小修法 = pending 位（+1 FF）。
4. **`W29`/`W45` ≈900/s 单调增**（§5.5-6）· **`port_rx_nodesc_drops` 1.72%**（§5.5-7）· **两处 RFC 偏离**（§5.5-8，62 次回卷未观测到后果）
   · **L1 learn 窗 `W13 ≠ 0`（L2 = 0）**（§5.5-9，本轮发现、**未归因**）。
5. **既有工具缺陷（与本刀无关）**：G3 门 `sim/p7b_stagec_tx_regress/author_gate/run_tx_ovl_gate.bat` 跑不通 = `MUTGEN FAIL 5`
   （① `rtl/tcp_tx_frame.v` 是 CRLF（**本轮复核 = 2040 个 CR，逐字相符**）而 `mk_mut_tx.py` 用裸 `\n` 锚点 ⇒ 0 命中；
   ② `mut_c2` 锚点即使归一化也陈旧 = 现役 `upd_id`/`upd_val` 已长成三级三目）—— **无关性证明** =
   `git hash-object rtl/tcp_tx_frame.v` = `ea1037d6…` = `HEAD:rtl/tcp_tx_frame.v`（**本轮现核，逐字相符**，§7.3 原记不变）。
6. **`sim/p4gates/run_matrix_p4dfix.bat` 的编译清单不含 `app_pattern.v`/`wrapper_p4.v`** ⇒ 跑它对本类改动是**空证据**（全局 #52 同族）；
   本刀可用的活门 = `sim/p7b_stageb_rx8/run_rx8_gate.bat` 与 `sim/p7b_longsend/run_cont_gate.bat`。
   ⚠️ **`sim/` 下含 `app_pattern #(` 的镜像件实测 = 71 个**（**订正**：此前记录写 21；`§R 背景订正 ⑦` 已改对，此处再确认）；
   其中 `sim/p4gates/evidence/negctl/foreign/` 是**刻意的外来夹具**（路径守卫负对照语料）⇒ **禁全局 grep 替换**。

### 8.4 下一步的精确选项（**决策权在用户**）

- **构建 B（≈26 min，一次构建收口；两个候选可二选一或合并）**：
  - **B-1 = 补三个计数器**：`win_open==0` / `frm_wait` / `txcdc 空拍` —— **唯一能把 ~6.7 拍/帧死拍拆开的手段**（§5.4）。
  - **B-2 = A-minus 臂**：`TX_CONTINUOUS=1` + `WIN_CAP_5` 回 `0xBFFE` —— **唯一能给"窗帽"一个干净判决的构架**（§2.4 订正块）。
- **对端 ACK 时钟归因**（零构建）：ACCEPT §6-③ 的形态线索（`TcpOutSegs` 10,313→68,650）**未做 A/B** ⇒ 可先做纯台架侧 A/B。
- **慢路径 aging = 已取消**（§5.2 ⑤：其"防无界饿死"的动机已被证伪；若要保留只能按"低延迟优化"另立目标）。
- ⚠️ 构建宏表**未改**（`board/build_p7b_ku5p.tcl:153`）：`APP_MODE=1 DEV_USP=1 PCIE_OBS=1 DP_156MHZ=1 P7B_10G=1 UDP_TX_OVL=1 TCP_TX_OVL=1`。
