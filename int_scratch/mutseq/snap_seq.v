`timescale 1ns/1ps
//=============================================================================
// snap_seq.v — P6b 链式触发快照序列器 (axi 域)
//=============================================================================
// 为什么需要它 (P6B_SPEC §2.5):
//   数据面搬域之后, **36 个**快照字分别来自**两个互异步的域**:
//     · FE 束 (14 字) = gmii_clk 125MHz   —— MAC RX/TX 计数器、wl_last、rxcdc 探针、
//                                           F4 的 4 个丢帧守恒计数器 (W32..W35)
//     · DP 束 (22 字) = dp_clk  156.25MHz —— 慢路径/TCP/app/HLS 与两个 FIFO 的读侧
//   两束各挂一个 snap_cdc (toggle 握手)。若让主机那一个写脉冲**同时**打到两个 snap_cdc,
//   两次锁存的相对次序就由两个域的相位随机决定 (异步) ⇒ 跨域对账的判据全部退化成
//   `|Δ| ≤ 1` 的对称容差, 失去方向性。
//   本模块把它变成**确定序**: **FE 先 → DP 后**, 于是
//     W6(DP) - W0(FE) ∈ {0,1}     帧进了 RX FIFO 但还没提交给慢路径的帧数
//     W30(DP) - W0(FE) ≥ 0        还滞留在 RX FIFO 里的帧数
//   这类有向判据是**结构性**成立的, 而不是统计性的。
//   ⚠️ 偏斜上界 (对抗审查 F10 修): 规格书 §2.5 的 **59.2 ns 是两个错误相互抵消的产物**
//   (漏算 2 个 axi 拍); 正确值 ≈ **43.2 ns**。而 `∈{0,1}` 的真实依据比"最小 IFG 96ns"更强:
//   帧尾间距实为 **≥672 ns** ⇒ 43.2ns 有 15 倍余量。**结论不变, 数字按 43.2ns 用**。
//
// 时序 (逐拍语义):
//   S_IDLE  --req(1 拍脉冲)-->  置 req_fe, 进 S_WFE
//   S_WFE   --valid_fe------->  记下 FE 束, 置 req_dp, 进 S_WDP
//   S_WDP   --valid_dp------->  记下 DP 束, 装配 32 字 → dout, 拉 valid (1 拍), 回 S_IDLE
//
// ⚠️ **硬契约 (继承 rtl/snap_cdc.v 头注释, 不许改)**:
//   ① `req_fe`/`req_dp` 必须是**恰好 1 拍宽**的脉冲 —— 本模块把两个 req 都**寄存器化**
//      并在下一状态的首拍清零 ⇒ 天然满足。snap_cdc 对"宽过一拍"的 req 会**反复受理**
//      (实测: 常高 200 拍 ⇒ 25 次请求), 那不是"一次触发"。
//   ② 完成信号用 `valid_fe`/`valid_dp`, **不许**用"busy 落下" —— 那会读到**上一代**
//      数据 (snap_cdc 头注释实测过 535 次采样全部落在 busy 已落而 valid 未到的那拍)。
//   ③ `req` 在忙时到达 = **丢一次请求** (不排队), 与改造前 axi_regs→snap_cdc 的语义一致
//      (那时 snap_cdc 也是这么丢的)。
//
// ⚠️ **b 域时钟停摆时的行为 (故意如此, 是诊断而不是故障)**:
//   · FE 时钟停 ⇒ 卡在 S_WFE ⇒ busy 恒高, `fe_state[2]`(fe_busy) 恒高。
//   · DP 时钟停 ⇒ 卡在 S_WDP ⇒ busy 恒高, `fe_state` 显示"FE 已完成"。
//   ⇒ 主机看到 `SNAP_STATUS.busy=1` 时可以**分开**"没触发/卡在 FE/卡在 DP"
//     (这正是 P6B_SPEC §6.4 要求可自动判定的那一句)。
//
// ⚠️ **32 字映射表是单一来源**: 表由下面两个 function (`fe_idx_of`/`dp_idx_of`) 定义,
//   `assemble` 与 `ifndef SYNTHESIS` 里的自检**都调它** ⇒ 抄错下标时自检当场
//   $finish (工程铁律③: lint 看不见的位宽/下标错, 只能靠"同一来源 + 逐字读回")。
//   映射逐项对照 (与 P6B_SPEC §7.2 的 32 行表逐字一致):
//     fe[0..5] = W0..W5    fe[6] = W21   fe[7] = W20   fe[8] = W27   fe[9] = W26
//     fe[10] = W32  fe[11] = W33  fe[12] = W34  fe[13] = W35   (F4 的 4 个新计数器)
//     dp[0..13] = W6..W19  dp[14] = W22  dp[15] = W23  dp[16] = W24  dp[17] = W25
//     dp[18] = W28         dp[19] = W29  dp[20] = W30  dp[21] = W31
//   (项数: FE 14 + DP 22 = **36** ⇒ 未实现地址 = word 44 = 0xB0)
//   ⚠️ 注意 W20/W21 与 W26/W27 的槽号是"反的" (两束的拼接字符串从右往左读) ——
//   P6B_SPEC §7.2 的 localparam 例子里 FE_IDX 把 fe[8]/fe[9] 写在了下标 24/25 上,
//   与它自己那张 32 行对照表 (W24/W25 属于 DP) 矛盾; **以对照表为准** (见施工汇报)。
//=============================================================================
module snap_seq #(
    parameter integer FW = 14,      // FE 束字数 (b 域 = gmii_clk)
    parameter integer DW = 22,      // DP 束字数 (b 域 = dp_clk)
    // 总字数 = 两束之和。**必须是 parameter 而不是 localparam** —— 端口表 (dout) 引用了它,
    // 而 Verilog-2001 的端口表看不到 body 里的 localparam (rtl/fifo_async.v 的 AW 同款坑,
    // 实测: `identifier 'NW' is used before its declaration`)。
    parameter integer NW = FW + DW
) (
    input  wire             clk,        // axi 域 (pcie_axi_aclk)
    input  wire             rst_n,      // axi 域复位 (pcie_axi_aresetn)
    input  wire             req,        // 1 拍脉冲: 来自 axi_regs 的 SNAP_CTRL 写
    output wire             busy,       // 高 = 序列器在工作 (喂 axi_regs.snap_busy)
    output reg  [NW*32-1:0] dout,       // 装配好的 NW 字 (valid 同拍有效)
    output reg              valid,      // 1 拍脉冲: NW 字可以采了
    output wire [2:0]       fe_state,   // {fe_busy, fe_seen, fe_done} → SNAP_STATUS[5:3]
    output wire [1:0]       dbg_state,  // 0=IDLE 1=WAIT_FE 2=WAIT_DP (诊断/门)
    // ---- FE 束 (b 域 = gmii_clk) ----
    output reg              req_fe,
    input  wire             busy_fe,
    input  wire             valid_fe,
    input  wire [FW*32-1:0] dout_fe,
    // ---- DP 束 (b 域 = dp_clk) ----
    output reg              req_dp,
    input  wire             busy_dp,
    input  wire             valid_dp,
    input  wire [DW*32-1:0] dout_dp
);

    //=========================================================================
    // 1. 映射表 (单一来源) —— 快照字编号 W0..W(NW-1) → 束内槽号; -1 = 不属于本束
    //=========================================================================
    // 返回类型用 integer (可带 -1); 调用点**必须先钳成合法下标**再用 +: 选择。
    function integer fe_idx_of;
        input integer w;
        begin
            case (w)
                0, 1, 2, 3, 4, 5: fe_idx_of = w;        // W0..W5  → fe[0..5]
                20:               fe_idx_of = 7;        // W20      → fe[7]
                21:               fe_idx_of = 6;        // W21      → fe[6]
                26:               fe_idx_of = 9;        // W26      → fe[9]
                27:               fe_idx_of = 8;        // W27      → fe[8]
                32:               fe_idx_of = 10;       // W32      → fe[10] (F4: stat_drop_partial)
                33:               fe_idx_of = 11;       // W33      → fe[11] (F4: stat_orphan_bytes)
                34:               fe_idx_of = 12;       // W34      → fe[12] (F4: stat_drop_full)
                35:               fe_idx_of = 13;       // W35      → fe[13] (F4: stat_fifo_ovf)
                default:          fe_idx_of = -1;
            endcase
        end
    endfunction

    function integer dp_idx_of;
        input integer w;
        begin
            case (w)
                6, 7, 8, 9, 10, 11, 12, 13,
                14, 15, 16, 17, 18, 19: dp_idx_of = w - 6;   // W6..W19  → dp[0..13]
                22:                     dp_idx_of = 14;       // W22      → dp[14]
                23:                     dp_idx_of = 15;       // W23      → dp[15]
                24:                     dp_idx_of = 16;       // W24      → dp[16]
                25:                     dp_idx_of = 17;       // W25      → dp[17]
                28:                     dp_idx_of = 18;       // W28      → dp[18]
                29:                     dp_idx_of = 19;       // W29      → dp[19]
                30:                     dp_idx_of = 20;       // W30      → dp[20]
                31:                     dp_idx_of = 21;       // W31      → dp[21]
                default:                dp_idx_of = -1;
            endcase
        end
    endfunction

    // 装配: 32 个字, 每字按表取自 FE 或 DP 束。**表错一个字就会串位** ⇒ 门里逐字读回。
    function [NW*32-1:0] assemble;
        input [FW*32-1:0] f;
        input [DW*32-1:0] d;
        integer w, fi, di;
        begin
            assemble = {(NW*32){1'b0}};
            for (w = 0; w < NW; w = w + 1) begin
                fi = fe_idx_of(w);
                di = dp_idx_of(w);
                if (fi >= 0) assemble[w*32 +: 32] = f[fi*32 +: 32];
                else         assemble[w*32 +: 32] = d[di*32 +: 32];
            end
        end
    endfunction

`ifndef SYNTHESIS
    // 自检 (仿真里表抄错就**响亮地死**, 而不是静默串位 —— 本工程"空读数 != 真 0"纪律):
    //   ① 每个 W 必须**属于且仅属于**一个束 ② 两束的项数必须恰好 = FW / DW
    //   (项数与 wrapper 的 fe_src/dp_src 拼接项数、snap_cdc.NW 同源 ⇒ 这一条把
    //    "§7.2 的四处同改"真正耦合在一起)
    integer k, n_fe, n_dp, hit;
    initial begin
        n_fe = 0; n_dp = 0;
        for (k = 0; k < NW; k = k + 1) begin
            hit = 0;
            if (fe_idx_of(k) >= 0) begin n_fe = n_fe + 1; hit = hit + 1; end
            if (dp_idx_of(k) >= 0) begin n_dp = n_dp + 1; hit = hit + 1; end
            if (hit != 1) begin
                $display("FATAL snap_seq: W%0d 不在**恰好一个**束里 (fe=%0d dp=%0d)",
                         k, fe_idx_of(k), dp_idx_of(k));
                $finish;
            end
        end
        if (n_fe != FW || n_dp != DW) begin
            $display("FATAL snap_seq: 束项数不符 n_fe=%0d(期望%0d) n_dp=%0d(期望%0d)",
                     n_fe, FW, n_dp, DW);
            $finish;
        end
    end
`endif

    //=========================================================================
    // 2. 状态机 (FE 先 → DP 后, 见文件头)
    //=========================================================================
    localparam [1:0] S_IDLE = 2'd0;
    localparam [1:0] S_WFE  = 2'd1;
    localparam [1:0] S_WDP  = 2'd2;

    reg [1:0] st;
    reg [FW*32-1:0] fe_r;          // FE 束锁存 (在 S_WFE 采到)
    reg             fe_seen_r;     // sticky: FE 束至少回来过一次
    reg             fe_done_r;     // sticky: 本次触发里 FE 束已回来 (S_IDLE 时清)

    assign busy      = (st != S_IDLE);
    assign dbg_state = st;
    // SNAP_STATUS[5:3] = {fe_busy, fe_seen, fe_done} —— "卡在哪个域"的可判定读数
    assign fe_state  = {busy_fe, fe_seen_r, fe_done_r};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= S_IDLE;
            req_fe    <= 1'b0;
            req_dp    <= 1'b0;
            fe_r      <= {(FW*32){1'b0}};
            dout      <= {(NW*32){1'b0}};
            valid     <= 1'b0;
            fe_seen_r <= 1'b0;
            fe_done_r <= 1'b0;
        end else begin
            valid  <= 1'b0;                 // 默认每拍清零 (脉冲铁律)
            req_fe <= 1'b0;                 // 同上: req 必须是恰好 1 拍
            req_dp <= 1'b0;
            case (st)
                S_IDLE: begin
                    fe_done_r <= 1'b0;
                    if (req) begin
                        req_dp <= 1'b1;     // MUTANT: DP 先
                        st     <= S_WDP;
                    end
                end
                S_WDP: begin
                    if (valid_dp) begin
                        fe_seen_r <= 1'b1;
                        req_fe    <= 1'b1;  // MUTANT: 再发 FE
                        st        <= S_WFE;
                    end
                end
                S_WFE: begin
                    if (valid_fe) begin
                        dout  <= assemble(dout_fe, dout_dp);
                        valid <= 1'b1;
                        st    <= S_IDLE;
                    end
                end
                default: st <= S_IDLE;
            endcase
        end
    end

    // ⚠️ `busy_dp` 这一路输入目前**只作诊断**(DP 域忙不忙对状态机没有额外约束 —— req_dp
    //   只在 S_WFE 且 valid_fe 之后发一次, 那时 DP 束必然空闲, 因为上一次触发已经等到
    //   了它的 valid_dp)。将来若把"两个束并行触发"改回来, 这里就是必须加固的点。

endmodule
