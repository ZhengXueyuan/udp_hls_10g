`timescale 1ns/1ps
//=============================================================================
// axi_regs.v — P6e 最小版: 挂在 XDMA **user BAR (AXI4-Lite master)** 上的寄存器块
//=============================================================================
// 这是"PCIe 观测通道"的第一块自己的 RTL: 主机侧用 `reg_rw /dev/xdma0_user <addr> w`
// 即可读/写这张表, 用来做 (a) 前置闸: 读回**位流身份**确认烧的就是这一版;
// (b) 状态读出; (c) 活体探针 (自由计数器)。
//
// 寄存器表 (字节地址; 32 位字; 只实现的地址返回 SLVERR):
//   0x00 RO  MAGIC     = 0x50360001  ("P6" + 版本 1) —— 用于区分"读的是我们的逻辑"
//   0x04 RO  BUILD_ID  = MAGIC 之外的**每次构建可自增**的身份号 (前置闸用)
//   0x08 RW  SCRATCH   = 读写回环 (通道功能判据; 默认 0)
//   0x0C RO  FREECNT   = 自由计数器 (axi_aclk 域) ⇒ 读两次可反解 AXI 时钟频率 + 证明活着
//   0x10 RO  HW_STATUS = 设计侧状态位束 (本最小版 = {link_up, msi_enable, 0...})
//   0x14 RO  MARKER    = 0xDEADBEEF  (地址译码正确性检查: 读错地址不会恰好是它)
//
//   ---- P6e 合体新增: 数据面快照窗口 (跨 gmii_clk → axi_aclk 的相干快照) ----
//   0x18 WO  SNAP_CTRL  = 写 bit0=1 ⇒ **触发一次**新快照 (同时清 done); 读回 0
//   0x1C RO  SNAP_STATUS= bit0 busy (CDC/序列器还在飞) / bit1 done (sticky, 触发时清)
//                         bit2 seen (复位后完成过至少一次) / [31:16] gen (完成次数)
//                         ---- P6b 新增 (加位; **已有位逐位不变** ⇒ 既有脚本的取位不受影响) ----
//                         [5:3] = {fe_busy, fe_seen, fe_done}: FE 束 (gmii_clk) 的握手状态
//                                 ⇒ "卡在哪个域"可自动判定 (P6b 是双域链式触发: FE 先 → DP 后,
//                                  见 rtl/snap_seq.v 与 P6B_SPEC §6.4)
//                         [6]   = MMCM locked 的 **axi 域同步版** —— DP 束在 DP 时钟停摆时
//                                 根本读不到, 所以 locked 必须在这里也有一份 (§6.4)
//                         [15:7]= 0 (保持)
//   0x20 RO  SNAP_W0    = 快照字 0 (FE 束 = 前端 gmii_clk 域)
//   0x24 RO  SNAP_W1    ... 一直到 **W(SNAP_NW-1)** —— ⛔ 字数/末地址**不在这里写死**
//                         (本行曾硬写过 63 字/0x118 而落后四代, 是一个反复复发的文档缺陷):
//                         权威 = 参数 SNAP_NW (由 wrapper 的 `SNAP_NW_P6E` 传入)。
//                         演进 8→16→24→32→36→51→61→63→65→66→67→70→**71 (M1)**。
//                         **P7B-BIZ 新增 W51..W60** (业务观测面):
//                           W51 app_pattern TX 载荷字节 / W52 TX 载荷帧数 /
//                           W53 RX 载荷字节 / W54 **载荷失配数**(R3/F1-E4b) /
//                           W55 **tcp_tx_frame.stat_retx** (F5b) /
//                           W56 **app_udp_pattern.stat_tx_ovf** (静的丢字类回归守卫)
//                           W57 **tcp_tx_frame.o_retx_hi** (回卷重放上界; 会话中有效)
//                           W58 **tcp_tx_frame.o_retx_active** (重传会话进行中; 低 1 位)
//                           W59 **slow_tx_adp.stat_fifo_ovf** (u_wf 拒写; 守卫, 恒 0)
//                           W60 **slow_rx_adp.stat_fifo_ovf** (o_ovf 拒写; 守卫, 恒 0)
//                         **P7B-WU 二轮新增 W61..W62** (加在 MSB 端 ⇒ 旧字逐项未动):
//                           W61 **app_ctrl.stat_wu** (窗口重开通告入 ackq 的次数; 不是"已上线")
//                           W62 **app_ctrl.rx_occ_bytes** (app RX 可读字节; 17 位 ⇒ 高位恒 0)
//                         旧字 W0..W60 的语义与地址**逐位未变**。
//                         未实现地址 = **末字之后第一格** = 0x20 + 4*SNAP_NW + 12 (M1 起;
//                         因为 MIR 三个字插在快照末尾与它之间) ⇒ 读回 0xffffffff。
//                         (如 SNAP_NW=71 ⇒ 快照 0x20..0x138, MIR 0x13C/0x140/0x144,
//                          未实现 = 0x148; ⛔ 本文件里这些数字一律由 localparam 推导。)
//
//   ---- ⭐ M1 (2026-10-11): 载荷镜像窗 (设计件 P7B_PCIE_DATAPATH_DESIGN v2 §V1.1/§V1.3) ----
//   ⭐ M1 期 A (2026-10-11): `src_sel` —— 镜像的**源选择位** (0 = UDP app 口 /
//      1 = TCP app 口; 电平; 复位默认 0 = 阶段一行为). 同一时刻只镜像一路 (同时双路 = 范围外)。
//      ⚠️ 切换源的协议 = 与 cap_en 同款: **在 cap_en=0 下切, 切完走 clr → cap_en=1**
//         (cap_en=1 中途切换会让字节流跨源拼接 —— 登记边界, 见 wrapper 的 M1 块注释)。
//   0x13C RO     MIR_STATUS = 载荷镜像状态 (恰好 32 位):
//                  [15:0] level    (= fifo_async.dbg_occ_r; 读域悲观少报 ⇒ 读 level 个字不下溢)
//                  [16]   unf_sticky  (空读 MIR_DATA 的 sticky; 权威证据 = 它; clr 写清)
//                  [17]   any_drop_sticky (镜像侧丢字节 sticky 的读域版; clr 写清)
//                  [18]   capture_on (= MIR_CTRL[0], 主机写的同一域)
//                  [22:19] ver = 4'd2 ([31:24] = 0; ver 1→2: 期 A 加 src_sel)
//                  [23]   src_sel 读回 (= MIR_CTRL[2] 的同一域直引 ⇒ 零新增 CDC)
//   0x140 RO     MIR_DATA  = **读=弹出**: 返回一个 32 位载荷字 (4 字节, 小端顺序:
//                  w[7:0] = 该 4 字节里最先收到的那个字节)。
//                  ⚠️ 空态读: 返回 `MIR_SENT` (32'h5A5A_5A5A) + unf_sticky 置位 + level 不变。
//                  ⚠️ **只许 32 位单笔访问** (宽读会被拆成多笔 ⇒ 多弹; PC 侧必须 volatile uint32_t)。
//                  ⚠️ 本机制成立的前提 = XDMA 的 `axil_master_prefetchable=false` (非预取 ⇒
//                     不应投机读); 将来把它标成 prefetchable 会**静默摧毁**本机制。
//   0x144 RW     MIR_CTRL  = [0] cap_en (复位默认 0=关; 采集侧 2FF 电平同步)
//                            [1] clr   (**toggle**: 写 1 翻转一次 ⇒ 跨域侧恰好 1 个清除脉冲:
//                                       清 FIFO (排空式冲刷) + 字节累加器 + 两个 sticky)
//                            [2] src_sel (⭐ 期 A: 0=UDP app 口 / 1=TCP app 口; 默认 0;
//                                       采集侧 2FF 电平同步 (同 cap_en 风格))
//                            其余位 0; 读回 = 当前值。起测协议: ① 写 clr → ② 写 cap_en=1 → ③ 发包。
//                            切源协议: cap_en=0 下写 src_sel, 然后重走 ①→②。
//   ⚠️ 未实现地址 (SLVERR) = `MIR_LAST_IDX+1` = 0x148 (word 82; 7 位译码红线: 绝不 ≥0x200)。
//   ⚠️ 扩窗要**七处同改** (P6b 起; 前五处是 24 字版定的, ⑥⑦ 是双域之后新增的):
//      ① `SNAP_NW` (单一来源: wrapper 的 `SNAP_NW_P6E`) ② 两束的拼接项数
//         (`fe_src`/`dp_src`; 项数必须 = wrapper 的 SNAP_FE_NW / SNAP_DP_NW)
//      ③ **读侧 `snap_base` 的位宽** (装不下就静默回绕, 见读侧译码处注释)
//      ④ 本文件的读 mux 与 SLVERR 边界 (`r_word <= SNAP_LAST_IDX`)
//      ⑤ **验收脚本里"未实现地址"的取值** (每扩一次都要跟着挪, 见下)
//      ⑥ 三个门自己的参数 (tb_axi_regs / tb_snap_cdc / tb_p6e_pcie_*)
//      ⑦ **两束的索引表** (rtl/snap_seq.v 的 fe_idx_of / dp_idx_of)
//      漏一处的表现各不相同 (截断/回绕读错字/读到 SLVERR/读到**别人的**值) ⇒ 七处都要被覆盖。
//   ⚠️ 扩窗会把"未实现地址"的边界推后 ⇒ 验收脚本里那个"读未实现地址应得 SLVERR"的**地址也得跟着挪**
//      (0x18→0x44→0x60→0x84→0xA0 都是这么挪的; **36 字版 ⇒ 0xB0** = word 44)。
//      ⚠️ 别以为 0xB0 是笔误: 36 字把 0x20..0xAC 全占了 (word 8..43) ⇒ 第一个空地址就是
//         word 44 = 0xB0 (36 字时代的红线是"< 0x100 不触发 ar_word 的 256B 回绕")。
//      ⚠️ ⭐ **2026-09-30 (P7B-BIZ) 这条红线被解除了**: 窗口跨过 0xFF 需要字 64 (= 0x100) 可寻址,
//         于是把 `ar_word/w_word/r_word` **从 6 位加宽到 7 位** (`araddr[8:2]`) ⇒
//           · < 0x100 的全部既有地址**逐位等价** (仍映射到字 0..63) ⇒ 零回归;
//           · 未实现地址的可行域从 {word 64} 扩到 {word 65..127} = 0x104..0x1FC ⇒
//             窗口上限从 56 字抬到 **119 字** (字 8..126); 现役 = 63 字, 未实现 = 0x11C;
//           · **顺带修掉一个既存隐患**: 旧 6 位译码下, 写 `0x108` 会别名到 word 2 = SCRATCH
//             (写 `0x118` 会别名到 SNAP_CTRL ⇒ **一次误写就能触发快照**) —— 现在 ≥0x100 一律
//             SLVERR。改前若有人依赖过这个别名, 那是依赖了一个缺陷。
//      ⚠️ 挪的时候**绝不能挑 ≥0x200**: 7 位译码下地址每 512 字节回绕 (`0x200` → word 0 = MAGIC)。
//
// ⚠️ **为什么用"显式触发"而不是"自动周期刷新" (设计取舍, 别改成自动的)**:
//   主机读 N 个字要走 N 笔独立 PCIe 事务 (几十 µs), 而自动刷新的周期只要短于这个窗口,
//   读出来的字就会**跨越两代快照** (CDC 再相干也没用 —— 撕裂发生在寄存器文件这一层)。
//   显式触发把"快照"与"读"解耦: 触发后整束**冻结**到下一次触发为止 ⇒ 读窗口天然原子,
//   主机不需要 seqlock/重试, 也不需要在主机侧维护任何状态。
//   ⚠️ 代价: 快照是"上次触发时刻"的值, 不是"此刻"的值 —— 读计数类信号完全够用。
//   主机协议: 写 SNAP_CTRL.bit0=1 → 轮询 SNAP_STATUS.done==1 (带上限超时) → 读 8 个字。
//   ⚠️ done 是 sticky 的: 即使快照在第一次轮询之前就完成了也不会漏 (busy 只可能被漏看)。
//   ⚠️ busy 一直不落 = gmii 时钟没在跑 (snap_cdc 的行为, 见其头注释) ⇒ 这本身就是诊断信息:
//      计数不动是"数据面死了"还是"观测通道没时钟", 用这个位分开。
//
// 写法要点 (AXI4-Lite 最小正确实现):
//   - AW/W 两通道**独立**握手 (AXI-Lite 允许任意到达顺序), 两者都到才落寄存器并回 B;
//     B 被接收后才重新拉高 awready/wready (每笔一笔, 不复用握手中的地址)。
//   - 读通道 1 拍延迟 (锁存地址 -> 下一拍给数据), rvalid 保持到 rready。
//   - 只写 SCRATCH / SNAP_CTRL: 按字节选通 wstrb 合并, 其余地址写返回 SLVERR (不静默丢写)。
//   - 无复位寄存器数组; 计数器复位清 0 (便于"刚上电"判断)。
//   - **快照字只有一个驱动块** (触发清零与 valid 捕获在同一 always 里, 靠 snap_clr 选路),
//     避免"两个 always 块写同一个寄存器" ⇒ 综合报多驱动/仿真出 X。
//=============================================================================
module axi_regs #(
    parameter [31:0]  MAGIC_V    = 32'h50360001,
    parameter [31:0]  BUILD_ID_V = 32'h00000001,
    // 快照字数: 必须与 wrapper 的 `snap_cdc #(.NW())` 和 `snap_src` 项数**同值**。
    // 位宽由它推导 ⇒ 扩窗时端口宽度自动跟着走 (手写 256 位的话, 扩到 16 字就是静默截断)。
    // ⚠️ 历次"上限"说法全部作废 (它们各自只对当时那个位宽成立)。**现役上限 = 119 字**,
    //   由 ① `ar_word` 7 位 (字 0..127) ② 快照从字 8 起 ③ 负对照需要留 1 个空字 共同决定:
    //   字 8..126 = 119 字, 未实现地址 = word 127 = 0x1FC。
    //   (另一条更松的界: `snap_base` 12 位 ⇒ {snap_idx,5'b0} ≤ 4095 ⇒ NW ≤ 129。)
    //   ⇒ ⚠️ 想再扩窗**先看这两处位宽**, 再看验收脚本的未实现地址 (第 ⑤ 处)。
    parameter integer SNAP_NW    = 8
) (
    input  wire        clk,
    input  wire        rst_n,
    // ---- AXI4-Lite 从口 (来自 XDMA 的 m_axil_*) ----
    input  wire [31:0] s_axil_awaddr,
    input  wire [2:0]  s_axil_awprot,
    input  wire        s_axil_awvalid,
    output reg         s_axil_awready,
    input  wire [31:0] s_axil_wdata,
    input  wire [3:0]  s_axil_wstrb,
    input  wire        s_axil_wvalid,
    output reg         s_axil_wready,
    output reg  [1:0]  s_axil_bresp,
    output reg         s_axil_bvalid,
    input  wire        s_axil_bready,
    input  wire [31:0] s_axil_araddr,
    input  wire [2:0]  s_axil_arprot,
    input  wire        s_axil_arvalid,
    output reg         s_axil_arready,
    output reg  [31:0] s_axil_rdata,
    output reg  [1:0]  s_axil_rresp,
    output reg         s_axil_rvalid,
    input  wire        s_axil_rready,
    // ---- 设计侧 ----
    input  wire [31:0] hw_status,      // 只读状态 (0x10)
    output reg  [31:0] scratch,        // 读写寄存器 (0x08)
    output reg  [31:0] wr_count,       // 成功写入笔数 (调试/活体)
    output wire        decode_err,     // 命中未实现地址 (读或写) 的脉冲
    // ---- 数据面快照接口 (接 snap_cdc: b 域 = 数据面 gmii_clk) ----
    output wire        snap_req,       // 1 拍脉冲: 请求一次快照
    input  wire        snap_busy,      // 来自 snap_cdc.busy_a (高 = 上一次还在飞)
    input  wire        snap_valid,     // 1 拍脉冲: 快照完成 (随 dout 有效)
    input  wire [SNAP_NW*32-1:0] snap_din,  // 来自 snap_seq.dout (SNAP_NW 字 × 32 位)
    // ---- P6b 新增 (加端口, 不改既有语义): 链式序列器的两路状态 ----
    input  wire [2:0] fe_state,   // {fe_busy, fe_seen, fe_done} → SNAP_STATUS[5:3]
    input  wire       locked_axi, // MMCM locked 的 axi 域同步版    → SNAP_STATUS[6]
    // ---- M1: 载荷镜像窗的读侧接口 (¬(APP_MODE∧DP_156MHZ) 构建由 wrapper 接常量:
    //      level=0 / empty=1 / dout=0 / any_drop=0 —— v2 §V1.4 的 tie-off 常量表) ----
    input  wire [8:0]  mir_level,     // fifo_async.dbg_occ_r (读域已 2FF 同步; **悲观少报**)
    input  wire        mir_empty,     // fifo_async.empty (读域)
    input  wire [31:0] mir_dout,      // fifo_async.dout (FWFT: !empty 时 = 头字)
    input  wire        mir_any_drop,  // drop sticky 的读域 2FF 电平版
    output wire        mir_pop,       // 1 拍: 读=弹出 (与"装载 rdata"同拍、每笔恰好一次)
    output wire [31:0] mir_ctrl       // RW: [0]=cap_en, [1]=clr toggle (读回 = 当前值)
);

    localparam integer SNAP_W0_IDX   = 8;                   // 快照字起始 word 号 (= 0x20)
    localparam integer SNAP_LAST_IDX = 8 + SNAP_NW - 1;      // 最后一个快照字的 word 号

    // ---------------- M1 (2026-10-11): 载荷镜像窗 (设计件 v2 §V1.1/§V1.3) ----------------
    //   主机侧对齐: W70 = mir_drop_bytes (快照末字, dp 域) · MIR_STATUS · MIR_DATA (读=弹出)
    //   · MIR_CTRL (RW)。⛔ **本文件一律用"地址字号"**, 且全部由 SNAP_LAST_IDX 推导 ——
    //   不写裸字面量 (S1 的根因就是"W 编号 / 字号 / 字节地址"三把尺子混用:
    //   W70 ↔ 字号 78 ↔ 0x138)。未实现地址 = MIR_LAST_IDX+1 = 0x148 (word 82)。
    localparam integer MIR_STATUS_IDX = SNAP_LAST_IDX + 1;   // 0x13C = "W71" (文档口径)
    localparam integer MIR_DATA_IDX   = SNAP_LAST_IDX + 2;   // 0x140 = "W72"
    localparam integer MIR_CTRL_IDX   = SNAP_LAST_IDX + 3;   // 0x144 = "W73"
    localparam integer MIR_LAST_IDX   = MIR_CTRL_IDX;        // 实现边界 (SLVERR 判据改用它)
    // 空读哨兵: **响亮值**, 不是"唯一性"保证 (数据可以是任何值) —— 权威证据 = unf_sticky。
    localparam [31:0]  MIR_SENT       = 32'h5A5A_5A5A;

    // ---------------- 自由计数器 (0x0C) ----------------
    reg [31:0] freecnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) freecnt <= 32'd0;
        else        freecnt <= freecnt + 32'd1;
    end

    // ---------------- 写通道 ----------------
    reg        aw_hit, w_hit;
    reg [31:0] awaddr_r, wdata_r;
    reg [3:0]  wstrb_r;
    wire       wr_go   = aw_hit && w_hit && !s_axil_bvalid;
    // ⚠️ P7B-BIZ: **6 位 → 7 位** (awaddr[8:2]) —— 理由见本文件头部与
    //   `snap_base` 处的长注释: 57 字窗口需要字 64 (= 0x100) 可寻址,
    //   同时把旧译码下的一个隐患一并修掉 (**旧译码写 0x108 会别名到 SCRATCH**)。
    //   对 < 0x100 的全部既有地址**逐位等价** (仍映射到字 0..63)。
    wire [6:0] w_word  = awaddr_r[8:2];

    // ---------------- M1: 载荷镜像窗的寄存器 (声明必须在写通道块之前 —— xvlog 先声明后用) ----
    reg [31:0] mir_ctrl_r;         // [0]=cap_en (电平; 复位默认 0 = 关) [1]=clr toggle (写 1 翻转)
                                   // [2]=src_sel (⭐ 期 A: 0=UDP / 1=TCP; 电平; 复位默认 0)
    reg        mir_unf_sticky;     // 空读 MIR_DATA 的 sticky (权威证据; clr 写清)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axil_awready <= 1'b1; s_axil_wready <= 1'b1;
            s_axil_bvalid  <= 1'b0; s_axil_bresp  <= 2'b00;
            aw_hit <= 1'b0; w_hit <= 1'b0;
            awaddr_r <= 32'd0; wdata_r <= 32'd0; wstrb_r <= 4'd0;
            scratch <= 32'd0; wr_count <= 32'd0;
            mir_ctrl_r <= 32'd0;                            // M1: cap_en=0 / clr toggle=0 (复位即回退态)
        end else begin
            if (s_axil_awready && s_axil_awvalid) begin
                awaddr_r <= s_axil_awaddr; aw_hit <= 1'b1; s_axil_awready <= 1'b0;
            end
            if (s_axil_wready && s_axil_wvalid) begin
                wdata_r <= s_axil_wdata; wstrb_r <= s_axil_wstrb; w_hit <= 1'b1; s_axil_wready <= 1'b0;
            end
            if (wr_go) begin
                s_axil_bvalid <= 1'b1;
                wr_count <= wr_count + 32'd1;
                if (w_word == 7'd2) begin                       // 0x08 SCRATCH (RW)
                    if (wstrb_r[0]) scratch[7:0]   <= wdata_r[7:0];
                    if (wstrb_r[1]) scratch[15:8]  <= wdata_r[15:8];
                    if (wstrb_r[2]) scratch[23:16] <= wdata_r[23:16];
                    if (wstrb_r[3]) scratch[31:24] <= wdata_r[31:24];
                    s_axil_bresp <= 2'b00;
                end else if (w_word == 7'd6) begin               // 0x18 SNAP_CTRL (写侧触发)
                    s_axil_bresp <= 2'b00;                       // 数据位在 snap_clr 里用掉
                end else if (w_word == MIR_CTRL_IDX) begin       // 0x144 MIR_CTRL (RW; M1 §V1.3)
                    // [0] cap_en : 电平 (照 SCRATCH 的 wstrb 写法)
                    // [1] clr    : **toggle** —— 写 1 翻转一次, 跨域侧 (2FF + 沿检测)
                    //              把它变成 dp/rd 域**恰好 1 个脉冲** (写 0 = 不动, 不产生脉冲)
                    // [2] src_sel: ⭐ 期 A 电平 (0=UDP / 1=TCP; 采集侧 2FF)
                    if (wstrb_r[0]) begin
                        mir_ctrl_r[0] <= wdata_r[0];
                        mir_ctrl_r[2] <= wdata_r[2];
                        if (wdata_r[1]) mir_ctrl_r[1] <= ~mir_ctrl_r[1];
                    end
                    s_axil_bresp <= 2'b00;
                end else begin                                   // 其余地址: 非法写
                    s_axil_bresp <= 2'b10;                       // SLVERR
                end
            end
            if (s_axil_bvalid && s_axil_bready) begin
                s_axil_bvalid <= 1'b0; aw_hit <= 1'b0; w_hit <= 1'b0;
                s_axil_awready <= 1'b1; s_axil_wready <= 1'b1;
            end
        end
    end

    // ---------------- 读通道 ----------------
    reg [31:0] araddr_r;
    reg [6:0]  r_word;                                      // P7B-BIZ: 6 → 7 位 (0x100 不再回绕)
    wire [6:0] ar_word = s_axil_araddr[8:2];
    reg        decode_err_r;

    // ---------------- M1: 读=弹出 + 空读哨兵 + underflow sticky (v2 §V1.1) ----------------
    // ⚠️ 弹出必须挂在**装载 rdata 的那一拍** (与 rdata_mux 采样同拍 ⇒ 读到的一定是刚被
    //    弹走的那个字, 每笔恰好弹一次); 那一刻 AR 已握手完成 ⇒ "主机是否取用返回值"在
    //    AXI 层不可见 (v2 §V1.5-⑨: 白弹**结构性存在**, 由字节账以 4 的倍数差暴露)。
    wire mir_rd_sel  = (!s_axil_arready && !s_axil_rvalid) && (r_word == MIR_DATA_IDX);
    assign mir_pop   = mir_rd_sel && !mir_empty;   // TL 硬要求: rd_pop 与 !empty **同门**
    wire mir_unf_evt = mir_rd_sel &&  mir_empty;   // 空读: 出哨兵 + sticky
    wire mir_clr_wr  = wr_go && (w_word == MIR_CTRL_IDX) && wstrb_r[0] && wdata_r[1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) mir_unf_sticky <= 1'b0;
        else if (mir_clr_wr)  mir_unf_sticky <= 1'b0;      // clr 写清 (与 toggle 翻转同刻)
        else if (mir_unf_evt) mir_unf_sticky <= 1'b1;
    end

    // MIR_STATUS = {8'd0, src_sel, ver[3:0], capture_on, any_drop_sticky, unf_sticky, level[15:0]}
    //   = 8+1+4+1+1+1+16 = **恰好 32 位** (v2 §V2-S7-③; v1 的 38 位示例作废)
    //   · src_sel (bit23) = ⭐ 期 A: MIR_CTRL[2] 的读回 (同一域直引 ⇒ 零新增 CDC)
    //   · ver = 4'd2 (期 A: 1→2, 因为 MIR 寄存区块的位语义变了)
    //   · capture_on = 控制寄存器位 (主机写入的同一域 ⇒ 零新增 CDC)
    //   · any_drop_sticky = 镜像内 dp sticky 的读域 2FF 电平版
    //   · level = fifo_async.dbg_occ_r 直引 (读域 2FF 同步、**悲观少报** ⇒ 读 level 个字不可能下溢)
    wire [31:0] mir_status = {8'd0, mir_ctrl_r[2], 4'd2, mir_ctrl_r[0], mir_any_drop, mir_unf_sticky,
                              {7'd0, mir_level}};

    // ---------------- 数据面快照寄存器 (0x18-0x3C) ----------------
    // ⚠️ 本块必须放在**写/读通道的 wire 声明之后** (wr_go / w_word / r_word): xvlog 先声明后用 (工程坑 22)
    // 单驱动块: "触发清零" 与 "valid 捕获" 都在同一个 always 里 (避免两个 always 写同一寄存器)
    reg [SNAP_NW*32-1:0] snap_words_r;
    reg         snap_done_r, snap_seen_r;
    reg [15:0]  snap_gen_r;

    wire        snap_clr = wr_go && (w_word == 7'd6);      // 对 0x18 的一次成功写
    assign      snap_req = snap_clr;                       // wr_go 恰好 1 拍宽 ⇒ 天然是脉冲

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            snap_words_r <= {SNAP_NW*32{1'b0}}; snap_done_r <= 1'b0;
            snap_seen_r  <= 1'b0;               snap_gen_r  <= 16'd0;
        end else if (snap_valid) begin
            snap_words_r <= snap_din;
            snap_done_r  <= 1'b1;
            snap_seen_r  <= 1'b1;
            snap_gen_r   <= snap_gen_r + 16'd1;
        end else if (snap_clr) begin
            snap_done_r  <= 1'b0;
        end
    end

    // 读侧译码: SNAP_NW 个字 = word 8..(8+SNAP_NW-1) = 0x20..
    //   NW=24 时是 0x20..0x7C (未实现 = 0x84); NW=32 时 0x20..0x9C (=0xA0);
    //   NW=36 时 0x20..0xAC (未实现 = 0xB0); NW=51 时 0x20..0xE8 (=0xEC);
    //   NW=55 时 0x20..0xF8 (未实现 = 0xFC) —— ⚠️ 这行是 BIZ 轮**中间稿**的残留 (55 字从未出厂);
    //     该轮实际出厂 61 字 (见下面 ★ 的两行), 现役 63 字。
    // ⚠️⚠️ 下标必须是 `r_word - 8`, **不能**直接截 r_word 的低位 —— 这里连踩两次:
    //   8 字版写 `r_word[2:0]`, 恰好 8..15 → 0..7 正确 (纯属巧合);
    //   扩到 16 字时换 `r_word[3:0]` ⇒ word 16..23 回绕到 0..7, **且** 0x20 也被当成 W8
    //   (读出来是重复的另一路数据 —— 静默错, 单看某一遍读不出问题)。
    //   是单元门判据 15b (同代 + 字号逐一核对) 当场抓到的。
    // ⚠️⚠️ **P6b-F4: 36 字之后这一行必须 6 位** —— 32 字时 `r_word[4:0]` 恰好卡在边界内
    //   (r_word=39 → [4:0]=7 → 7-8 mod 32 = 31 ✓, **纯属算术巧合**); 36 字立刻错
    //   (r_word=43 → [4:0]=11 → 11-8 = 3, 正确值是 35) ⇒ 高 4 个字**静默串到低地址**。
    //   ⇒ 位宽必须与 SNAP_NW 一起走: NW=36 需要 6 位索引 + 11 位字节偏移。lint 全程沉默。
    wire [6:0]  snap_idx    = r_word[6:0] - SNAP_W0_IDX[6:0];   // P7B-BIZ: 同宽 7 位
    // ⚠️⚠️ **这一行必须装得下 {snap_idx, 5'b0}** (36 字 ⇒ **11 位**) —— 写窄了最高位被
    //   **静默截断**, symptom 精确且隐蔽: 字数 ≥ 9+8=17 起, 高地址的字会回绕读到低地址的字
    //   (NW=24 时 `0x60..0x7C` 这 8 个读回 W0..W7 的值; NW=32 时 16 个错)。
    //   xvlog 对"赋值右端比左端宽"**完全沉默** (lint 里 `10-3091` 计数 0) ⇒ 只有例化真 DUT
    //   并逐字读回的门能抓 (tb_axi_regs 判据 13d/15b 逐字核对就是为它准备的)。
    //   历史: 8 字/16 字两版都在 `[8:0]` 下工作 —— 因为 {snap_idx(0..15), 5'b0} 最高只到 480,
    //   9 位 (max 511) 恰好够; 是扩到 24 字才越界。**扩窗第一步就是这一行**。
    //   ★ **P6b 定案: 10 位就是本设计的硬上限** —— NW=32 时最大 {31,5'b0} = 992 < 1024 ✓,
    //     但 NW≥33 立刻越界 ⇒ **下次扩窗必须**同时把这一行加宽 (否则是静默回绕, xvlog 不报)。
    //   ★ **P7b (2026-09-29) 照做**: NW 36 → **51** ⇒ 最大 {50,5'b0} = 1600 > 1023
    //     ⇒ 本行从 `[10:0]` 加宽到 **`[11:0]`** (12 位, max 4095 ⇒ **NW 上限 63**)。
    //     ⚠️ 12 位同时把本设计的**绝对上限**钉死: 字偏移 = (NW-1)<<5 ≤ 4095 ⇒ NW ≤ 129;
    //        但真正先撞到的是 `ar_word = araddr[7:2]` (6 位) 与 `SNAP_W0_IDX=8`
    //        ⇒ **NW ≤ 56**。两个界里 56 更紧 ⇒ 56 才是硬上限 (见 wrapper 的预算注释)。
    //   ★ **P7B-BIZ (2026-09-30) 收口: NW 51 → 61** (W51..W60 十个业务字)。
    //     ⚠️ 过程留档 (下次扩窗会再遇到同一道题): 6 个新字 = 57 > 旧的 56 字上限, 而当时
    //        "未实现地址"必须存在的约束把上限钉在 56 —— 且末字 (word 63 = 0xFC) 一旦被占,
    //        读侧 SLVERR 负对照 (`(r_word <= SNAP_LAST_IDX) ? OKAY : SLVERR`) 就**恒为 OKAY**
    //        ⇒ 判据静默无牙 (闸 4 的 B5/G4 正是这条)。而"下一个空地址" `0x20+4*56 = 0x100`
    //        在 6 位译码下回绕到 word 0 = MAGIC ⇒ 假 FAIL。
    //     ⇒ 解法不是砍字, 而是**把译码加宽 1 位** (上面 `ar_word`/`w_word`/`r_word` → 7 位):
    //        < 0x100 逐位等价 (零回归), 未实现地址域扩到 0x104..0x1FC ⇒ **上限抬到 119 字**。
    //        本行的 12 位**不需要再动** (max {56,5'b0} = 1792 < 4096 ✓, 真正会更早撞上的是
    //        7 位的 `ar_word`)。
    //   ★ **P7B-WU 二轮 (2026-10-07) 收口: NW 61 → 63** —— W61 = `app_ctrl.stat_wu` /
    //     W62 = `app_ctrl.rx_occ_bytes`, 加在 **MSB 端** (旧字逐项未动) ⇒
    //     未实现地址 `0x114` → **`0x11C`** (word 71); 本行 12 位仍不需要动
    //     (max {62,5'b0} = 1984 < 4096 ✓, 上限仍是 7 位 `ar_word` 给的 119 字)。
    //   ★ **后续四代 (2026-10-10) 逐代复核, 本行一律不需要动**:
    //     NW 63 → 65 (构建 C: W63/W64) → 66 (构建 D: W65) → 67 (构建 E: W66) → **70 (构建 F: W67/W68/W69)**;
    //     现役 `max {(70-1),5'b0} = 2208 < 4096` ✓ ⇒ 12 位仍够; 真正先撞上的仍是 7 位 `ar_word` 的 **119 字**上限
    //     (未实现地址 `0x138` ⇒ word 78 < 128 ✓)。⚠️ 本条是**纯注释** (本行取值逐代未变)。
    wire [11:0] snap_base   = {snap_idx, 5'b0};
    // SNAP_STATUS 位域 (**必须恰好 32 位**):
    //   [31:16] gen | [15:7] 0 (9 位) | [6] locked_axi | [5:3] fe_state | [2] seen | [1] done | [0] busy
    // ⚠️ 15:7 是 **9** 位 —— 加了 [6] 与 [5:3] 之后零填充区被压缩了; 照抄旧的 13'd0 会拼出 36 位
    //    ⇒ 高 4 位被静默截掉 (低 32 位有可能仍然对, 但那是"靠截断碰巧对", 不留这种账)。
    wire [31:0] snap_status = {snap_gen_r, 9'd0, locked_axi, fe_state,
                               snap_seen_r, snap_done_r, snap_busy};

    reg [31:0] rdata_mux;
    always @* begin
        case (r_word)
            7'd0:    rdata_mux = MAGIC_V;
            7'd1:    rdata_mux = BUILD_ID_V;
            7'd2:    rdata_mux = scratch;
            7'd3:    rdata_mux = freecnt;
            7'd4:    rdata_mux = hw_status;
            7'd5:    rdata_mux = 32'hDEADBEEF;
            7'd6:    rdata_mux = 32'd0;                        // 0x18 写口, 读回 0
            7'd7:    rdata_mux = snap_status;                  // 0x1C
            // ---- M1: 载荷镜像窗 (字号由 SNAP_LAST_IDX 推导 ⇒ 扩窗时不用改这里) ----
            MIR_STATUS_IDX: rdata_mux = mir_status;            // 0x13C RO
            MIR_DATA_IDX:   rdata_mux = mir_empty ? MIR_SENT : mir_dout;  // 0x140 读=弹出 (空态出哨兵)
            MIR_CTRL_IDX:   rdata_mux = mir_ctrl_r;            // 0x144 RW (读回 = 当前值)
            // 快照字: word 8..(8+SNAP_NW-1) —— 用 if 按参数判范围 (case 的标签没法由参数生成),
            // 这样扩窗时只需要改 SNAP_NW 一个数, 不会漏掉某个标签 ⇒ 也就不会回绕读错字。
            default: rdata_mux = ((r_word >= SNAP_W0_IDX) && (r_word <= SNAP_LAST_IDX))
                                 ? snap_words_r[snap_base +: 32] : 32'h00000000;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axil_arready <= 1'b1; s_axil_rvalid <= 1'b0;
            s_axil_rdata <= 32'd0; s_axil_rresp <= 2'b00;
            araddr_r <= 32'd0; r_word <= 7'd0; decode_err_r <= 1'b0;
        end else begin
            if (s_axil_arready && s_axil_arvalid) begin
                araddr_r <= s_axil_araddr; r_word <= ar_word;
                s_axil_arready <= 1'b0;
            end
            if (!s_axil_arready && !s_axil_rvalid) begin
                s_axil_rdata <= rdata_mux;
                // M1: 边界改 `MIR_LAST_IDX` (= SNAP_LAST_IDX+3) —— 未实现地址 = 0x148 (word 82);
                //     原判据 `<= SNAP_LAST_IDX` 会把 MIR 三个字判成 SLVERR (v2 §V1.1)。
                s_axil_rresp <= (r_word <= MIR_LAST_IDX) ? 2'b00 : 2'b10;   // 未实现 -> SLVERR
                decode_err_r <= (r_word >  MIR_LAST_IDX);
                s_axil_rvalid <= 1'b1;
            end
            if (s_axil_rvalid && s_axil_rready) begin
                s_axil_rvalid <= 1'b0; s_axil_arready <= 1'b1; decode_err_r <= 1'b0;
            end
        end
    end

    assign decode_err = decode_err_r;
    assign mir_ctrl   = mir_ctrl_r;        // M1: [0]=cap_en, [1]=clr toggle (读回 = 当前值)

endmodule
