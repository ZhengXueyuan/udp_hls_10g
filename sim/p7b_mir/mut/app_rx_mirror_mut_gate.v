`timescale 1ns/1ps
//=============================================================================
// app_rx_mirror.v — M1「载荷镜像」: snoop tap + 逐字节 ^XORC + 打包 32 位字 +
//                   跨域 FIFO (dp_clk → pcie axi) 的采集侧全链
//=============================================================================
// 设计件 = `_proj_10g/notes/P7B_PCIE_DATAPATH_DESIGN.md` (v1 §3.2/§3.7 + v2 §V1.1/§V1.3/§V1.4)。
// 用途: 把板上 app 收口 (现役接线 = UDP app RX 口 `app_udp_rx_*`) 的**载荷字节流**镜像出来,
//   → 逐字节变换 `^XORC` (默认 0xA5) → 压成 32 位字 → 异步 FIFO → `axi_regs` 的 MIR 读口
//   (MIR_STATUS/MIR_DATA 读=弹出) → 主机侧工具落盘并与图案变换**逐字节对账**。
//
// ★ **snoop 合同 (第一优先级)**: 只采样 `s_tvalid && s_tready`, **永不驱动**任何握手信号
//   (s_tready 在本模块里是**只读**输入) ⇒ 对既有数据面逐位零影响。
//
// ⭐ 冻结语义 (v2; 偏离处就地登记):
//   · 字节序: `s_tdata[63:56]` = 该拍**首字节** (与 MAC/app 字流合同一致);
//     keep 合同 = **顶 n 字节有效** (0xFF<<(8-n); 与 `app_*.v` 的 kmask8/pop8 同款)。
//     ⛔ 非连续 keep (洞) **不在本合同内** (全仓两个生产者的 keep 都按此约定生成)。
//   · 变换: 只对有效字节做 `^XORC` (load 时整字异或即可 —— 无效字节的值永不进入字节流)。
//   · 打包: **跨拍/跨段续用累加器** (不在 tlast flush, v2 §V1.2) ⇒ 输出 = 纯字节流。
//     前置条件 (判据层) = 发端总字节数 K % 4 == 0; 尾部 1–3 字节会停在累加器里
//     (无读出通路) —— 这是 (a) 方案的**已知语义**, 不是缺陷。
//   · 写门 = **组合** `wr_en = have && !full` (v2 §V2-S6-④): 写使能是组合量时,
//     空间门必须用**本拍** `full` (用 full_next 才是错的) ⇒ 与 fifo_async 硬规则①一致。
//   · 丢字节 `drop_bytes` (+1 bit sticky): 两类**都按字节计**、都进同一计数器
//     (与 PC 的字节账同量纲), 满足"不静默丢":
//       ① 暂存忙 —— 源一拍最多 8B, 而 FIFO 写口 = 32 位 ⇒ 持续采集上限 = **4B/拍**
//          (156.25MHz ⇒ 625MB/s); 源平均速率 > 4B/拍时, 多出的拍被拒收;
//       ② FIFO 满 (排空不够快)。
//     ⚠️ 边界登记: v2 的措辞只点名了"full 时拒写" —— ① 类是**结构吞吐上限**的产物,
//        本实现把它**按同一口径**计进同一字段 (offered == captured + dropped + 尾部残余)。
//   · 使能 `cap_en`: 0 = 采集侧**整段冻结** (不暂存/不打包/不写/不计丢); FIFO 里已有
//     的字照常可读; `clr` 的冲刷/清零不受 cap_en 影响。
//     ⚠️ 中途关/开 cap_en 会让累加器残余**跨过暂停**拼进新流 ⇒ 正确用法 = `clr` → `cap_en=1`
//        后**不再动**; 要重启就重走 `clr` (v2 §V1.3 的协议)。
//   · `clr` (toggle): 写一次 ⇒ 跨到本域**恰好 1 个脉冲** (2FF + 沿检测) ⇒ 清 打包状态
//     (暂存寄存器 + 累加器) + `any_drop` sticky; rd 域同步同一 toggle ⇒ 启动一次
//     **排空式冲刷** (读到空为止 —— 不碰 FIFO 复位, 遵守 fifo_async "两侧复位必须
//     同源同时断言"的硬契约)。`drop_bytes` (W70) **不归零** (v2 §V1.3 冻结清单未列它;
//     判据用 ΔW70, 不受影响 —— 登记口径)。
//   · 复位: 两侧都接板级 `reset_n` (P6B_SPEC §4.4 硬规则; 同 u_rxcdc/u_txcdc);
//     释放时刻不同步是允许的 (v2 §V2-S6-①)。空态哨兵由消费者按 `empty` 选路。
//   · `level` = `fifo_async.dbg_occ_r` 直引 (读域已 2FF 同步、**悲观少报**) ⇒
//     "按 level 读若干字"不可能下溢 (v2 §V2-S6-③), 且不需要自造多比特 CDC。
//
// ⚠️ 本模块**没有**自己的参数化宏开关: 例化与否由 wrapper 的三层 ifdef
//   (`APP_MODE` ∧ `PCIE_OBS` ∧ `DP_156MHZ`, v2 §V1.4) 决定。
//=============================================================================
module app_rx_mirror #(
    parameter [7:0] XORC = 8'hA5        // 逐字节变换常量 (可逆; PC 侧做同一个)
)(
    // ---- 采集侧 (dp_clk = 写域) ----
    input  wire        clk,             // dp_clk (156.25MHz 数据面)
    input  wire        rst_n,           // 采集侧复位 (板级 reset_n; 与 rd 侧**同源**)
    input  wire [63:0] s_tdata,         // snoop: 只读
    input  wire [7:0]  s_tkeep,         // snoop: 只读 (合同: 顶 n 字节有效)
    input  wire        s_tvalid,        // snoop: 只读
    input  wire        s_tready,        // snoop: **只读** (本模块从不驱动它)
    input  wire        s_tlast,         // snoop: 只读 (诊断保留; 打包**不**消费它)
    // ---- 控制 (pcie 域异步 → 本模块内部同步) ----
    input  wire        ctrl_cap_en,     // 电平 (2FF)
    input  wire        ctrl_clr_tgl,    // toggle (2FF + 沿检测 ⇒ 恰好 1 个 dp 脉冲)
    // ---- 读出侧 (rd_clk = pcie_axi_aclk ≈250MHz) ----
    input  wire        rd_clk,
    input  wire        rd_rst_n,        // 与采集侧同源 (板级 reset_n)
    input  wire        rd_en,           // 弹出 1 字 (读=弹出; 由 axi_regs 与 !empty 同门给出)
    output wire [31:0] dout,            // FWFT 头字 (empty 时不定 —— 消费者按 empty 选哨兵)
    output wire        empty,
    output wire [8:0]  level,           // = fifo_async.dbg_occ_r (读域悲观占用)
    // ---- 观测 (dp 域寄存器输出 ⇒ 满足 snap_cdc 的 din_b 前提) ----
    output reg  [31:0] drop_bytes,      // 未进 FIFO 的字节数 (两类合一口径; 见头注释)
    output reg         any_drop,        // sticky (dp 域; clr 清)
    output wire        any_drop_rd      // any_drop 的 rd 域 2FF 电平同步版 (→ MIR_STATUS)
);

    // ---------------- 线网声明先行 (xvlog 先声明后用; 防隐式 1 位网 —— 工程坑 24) ----------------
    // ⚠️ 这几个**必须**在下面任何逻辑块之前声明: FIFO 的 full/empty/dout 被"写门"与
    //    读口引用, rd_go 被 FIFO 例化引用 —— 反过来写就是"引用后声明的标识符" ⇒
    //    xvlog 静默出隐式 1 位网 (multi/driv/unconnected 都不报), 写门直接失效。
    wire        fifo_full;
    wire        fifo_empty;
    wire [31:0] fifo_dout;
    wire [8:0]  fifo_occ_r;
    wire        rd_go;                  // FIFO 读使能 (冲刷优先于主机读; assign 在本文件末尾)

    // ---------------- 控制同步: pcie → dp ----------------
    (* ASYNC_REG = "TRUE" *) reg [1:0] cap_sr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) cap_sr <= 2'b00;
        else        cap_sr <= {cap_sr[0], ctrl_cap_en};
    end
    wire cap_on = cap_sr[1];

    // toggle → 沿检测 (3 级链: 2 级同步 + 1 级做沿比较) ⇒ 一次写恰好一个脉冲
    (* ASYNC_REG = "TRUE" *) reg [2:0] clrt_sr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) clrt_sr <= 3'd0;
        else        clrt_sr <= {clrt_sr[1:0], ctrl_clr_tgl};
    end
    wire clr_pulse = clrt_sr[2] ^ clrt_sr[1];

    // ---------------- 采集侧状态 (dp 域) ----------------
    reg        pend_valid;
    reg [63:0] pend_data;        // 已 ^XORC 的源字 (无效字节的值永不使用)
    reg [7:0]  pend_keep;
    reg [31:0] acc_r;            // 累加器: acc_r[7:0] = 本字**首字节**
    reg [3:0]  acc_cnt_r;        // 0..4 (4 = 整字待写/等空间)

    // popcount(keep) —— 与 app_*.v 的 pop8 同款
    function [3:0] pop8; input [7:0] k; integer i; begin
        pop8 = 4'd0;
        for (i = 0; i < 8; i = i + 1) pop8 = pop8 + k[i];
    end endfunction

    wire [3:0] n_cur     = pend_valid ? pop8(pend_keep) : 4'd0;   // 暂存里的有效字节数
    wire [3:0] room      = 4'd4 - acc_cnt_r;                      // 累加器还能吃几个字节
    wire [3:0] kk        = (n_cur < room) ? n_cur : room;         // 本拍搬 kk 个字节
    wire       drain_all = (kk == n_cur);                         // 本拍把暂存整块取走
    wire       pend_after = pend_valid && !drain_all;
    wire       src_beat  = s_tvalid && s_tready && cap_on;        // 被接受的拍 (snoop)
    wire       load      = src_beat && !pend_after;               // 收进暂存
    wire       drop_now  = src_beat && pend_after;                // 拒收 (按字节计)
    wire [3:0] acc_have  = acc_cnt_r + kk;
    wire       have      = (acc_have == 4'd4);                    // 本拍凑满一字
    wire       wr_en     = have;                                   // MUTANT mut_gate: 丢掉 !full (写满也写)

    // 源字顶 4 字节 (b0 = 首字节)
    wire [7:0]  b0 = pend_data[63:56];
    wire [7:0]  b1 = pend_data[55:48];
    wire [7:0]  b2 = pend_data[47:40];
    wire [7:0]  b3 = pend_data[39:32];

    // mv = 本拍搬走的 kk 个字节 (b0 在 LSB, 即"首字节落在低位") —— 显式 case, 不用变量移位
    reg [31:0] mv;
    always @* begin
        case (kk)
            4'd0:    mv = 32'd0;
            4'd1:    mv = {24'd0, b0};
            4'd2:    mv = {16'd0, b1, b0};
            4'd3:    mv = {8'd0,  b2, b1, b0};
            default: mv = {b3, b2, b1, b0};
        endcase
    end
    // acc_sh = mv 上移到累加器当前顶端 (acc_cnt_r ∈ 0..3; ==4 时无空位 ⇒ 0)
    reg [31:0] acc_sh;
    always @* begin
        case (acc_cnt_r)
            4'd0:    acc_sh = mv;
            4'd1:    acc_sh = {mv[23:0], 8'd0};
            4'd2:    acc_sh = {mv[15:0], 16'd0};
            4'd3:    acc_sh = {mv[7:0],  24'd0};
            default: acc_sh = 32'd0;
        endcase
    end
    wire [31:0] acc_next = acc_r | acc_sh;

    // 暂存移位 (搬走 kk 个字节) —— 显式 case
    reg [63:0] pend_sh;
    reg [7:0]  keep_sh;
    always @* begin
        case (kk)
            4'd0:    begin pend_sh = pend_data;                 keep_sh = pend_keep;               end
            4'd1:    begin pend_sh = {pend_data[55:0], 8'd0};   keep_sh = {pend_keep[6:0], 1'b0};  end
            4'd2:    begin pend_sh = {pend_data[47:0], 16'd0};  keep_sh = {pend_keep[5:0], 2'b0};  end
            4'd3:    begin pend_sh = {pend_data[39:0], 24'd0};  keep_sh = {pend_keep[4:0], 3'b0};  end
            default: begin pend_sh = {pend_data[31:0], 32'd0};  keep_sh = {pend_keep[3:0], 4'b0};  end
        endcase
    end

    // ---- 打包状态推进 (单驱动块; clr 优先于一切) ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pend_valid <= 1'b0; pend_data <= 64'd0; pend_keep <= 8'd0;
            acc_r <= 32'd0; acc_cnt_r <= 4'd0;
        end else if (clr_pulse) begin
            pend_valid <= 1'b0; pend_data <= 64'd0; pend_keep <= 8'd0;
            acc_r <= 32'd0; acc_cnt_r <= 4'd0;
        end else if (cap_on) begin
            if (load) begin
                pend_valid <= 1'b1;
                pend_data  <= s_tdata ^ {8{XORC}};
                pend_keep  <= s_tkeep;
            end else if (pend_valid) begin
                if (drain_all) pend_valid <= 1'b0;
                else begin pend_data <= pend_sh; pend_keep <= keep_sh; end
            end
            if (wr_en) begin
                acc_r <= 32'd0; acc_cnt_r <= 4'd0;          // 整字被 FIFO 收下
            end else if (kk != 4'd0) begin
                acc_r <= acc_next; acc_cnt_r <= acc_have;   // (含 have=1 但 full=1 的"握字等空间")
            end
        end
    end

    // ---- 丢字节计数 + sticky (dp 域; 单驱动块) ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            drop_bytes <= 32'd0; any_drop <= 1'b0;
        end else if (clr_pulse) begin
            any_drop <= 1'b0;                    // 只清 sticky; drop_bytes 不归零 (登记口径)
        end else if (drop_now) begin
            drop_bytes <= drop_bytes + {28'd0, pop8(s_tkeep)};
            any_drop   <= 1'b1;
        end
    end

    // ---------------- 跨域 FIFO (32 位 × 256, FWFT) ----------------
    // 例化样板 = wrapper 的 u_txcdc (WIDTH/DEPTH/FWFT/AW 逐字同形);
    // 两侧复位都接板级 reset_n (硬规则)。
    fifo_async #(.WIDTH(32), .DEPTH(256), .FWFT(1), .AW(8)) u_fifo (
        .wr_clk   (clk),
        .wr_rst_n (rst_n),
        .wr_en    (wr_en),
        .din      (acc_next),
        .full     (fifo_full),
        .rd_clk   (rd_clk),
        .rd_rst_n (rd_rst_n),
        .rd_en    (rd_go),
        .dout     (fifo_dout),
        .empty    (fifo_empty),
        .dbg_wbin (), .dbg_rbin (), .dbg_wgray (), .dbg_rgray (),
        .dbg_occ_w(), .dbg_occ_r(fifo_occ_r),
        .ovf_pulse(), .ovf_cnt()      // v2 §V2-S6-⑤: 不接 ovf (自算 drop_bytes; 拒写不再静默)
    );
    assign dout  = fifo_dout;
    assign empty = fifo_empty;
    assign level = fifo_occ_r;

    // ---------------- rd 域: 冲刷 + any_drop 电平同步 ----------------
    // clr → 排空式冲刷: 把 FIFO 里已有的字全部读出丢弃 (到空为止)。
    // ⚠️ 不碰 FIFO 复位 (单侧复位 = 禁止用法); 冲刷期间若写侧还在灌, 冲刷会持续到
    //    追上空 (协议上 clr 之后才开 cap_en, 正常不会)。
    (* ASYNC_REG = "TRUE" *) reg [2:0] clrt_sr_r;
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) clrt_sr_r <= 3'd0;
        else           clrt_sr_r <= {clrt_sr_r[1:0], ctrl_clr_tgl};
    end
    wire clr_pulse_r = clrt_sr_r[2] ^ clrt_sr_r[1];

    reg flush_r;
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n)                       flush_r <= 1'b0;
        else if (clr_pulse_r)                flush_r <= 1'b1;
        else if (flush_r && fifo_empty)      flush_r <= 1'b0;
    end
    assign rd_go = flush_r ? !fifo_empty : rd_en;   // 冲刷优先于主机读

    (* ASYNC_REG = "TRUE" *) reg [1:0] adrop_sr;
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) adrop_sr <= 2'd0;
        else           adrop_sr <= {adrop_sr[0], any_drop};   // any_drop 是 sticky 电平 ⇒ 不会漏
    end
    assign any_drop_rd = adrop_sr[1];

endmodule
