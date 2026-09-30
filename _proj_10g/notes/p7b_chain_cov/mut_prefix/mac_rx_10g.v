`timescale 1ns/1ps
// ===========================================================================
// mac_rx_10g —— 64 位 XGMII 接收 MAC (官方 xxv_ethernet PCS 的 RX 侧对接层)
// ===========================================================================
// 职责: XGMII (lane0 = 首发字节) → 本仓**冻结的 64 位帧流合同** (tdata[63:56] = 帧首字节);


//       在本层完成前导//S//SFD 剥离、FCS 校验与剥离。**下游一行都不改**。
//
// 端口语义与 rtl/mac_rx_64.v 头注释的 9 条逐条对齐 (那份头注释是接口的权威文本):
//   1. FWFT: m_axis_tvalid = !empty (组合); 消费 = tvalid && tready
//   2. SOP: tuser=1 落在帧首字; 帧首字总是满对齐 (tkeep[7]=1)
//   3. TLAST: 帧末字 tlast=1, tkeep 高位有效, tcrs = FCS 正确, terr = 帧内错误
//   4. FCS 被剥离 ⇒ 好帧的 Σpopc(tkeep) = 线上帧长 − 4
//   5. 绝不留裸尾巴字: 帧被中止 ⇒ TERM 字 (见 §F4)
//   6. TERM 字 = {tdata=0, tkeep=8'h00, tlast=1, tuser=0, tcrs=0, terr=1}
//   7. 条件式保证同 1G 版 (消费者永久停摆的例外仍在: 有界/有计数/不死锁)
//   8. 守恒律: Σpopc(tkeep) == stat_bytes − 4*stat_frames + stat_orphan_bytes
//   9. 空间足够时不触发任何丢弃路径 ⇒ 与"旧判据"同值
//
// ===========================================================================
// §XGMII 成帧约定 (逐条带出处; 常量见 rtl/mac_10g_defs.vh, 推导见 notes/P7B_MAC_DESIGN.md §2)
// ===========================================================================
//  · 帧首拍 = lane0:/S/(0xFB,c=1) + lane1..6:0x55 + lane7:0xD5
//    [官方例程 pcs64_pkt_gen_mon.v:995 的 preamble 字面量 + :1148 的 swapn + :1147-1149 的 c=8'h01]
//    ⇒ **不是** 1G 的 55x7+D5 (那会少一个 /S/ ⇒ PCS 组不出块类型 0x78 ⇒ 对端静默丢帧)
//  · /S/ 只认 lane0 / lane4 (官方监视器同样只查这两条: :1374 `for(i=0;i<7;i=i+4)`)
//    /S/ 在 lane4 时前导组跨字 ⇒ 帧数据从**下一字的 lane4** 起。统一规则: 数据起始 lane = /S/ 所在 lane
//  · /T/ 可落任意 lane ⇒ 该字 lane0../T/-1 是本帧数据 (官方监视器同一约定: :1378/:1561)
//  · 一拍里可以同时"上一帧结束"与"下一帧 /S/" (背靠背) —— 两者在本模块独立处理
//  · 帧内出现控制字符 (窗内 c=1) / 保留控制码 / /E/ ⇒ 该帧 terr=1
//
// ===========================================================================
// §流水结构 (为什么是真流水的 8 字节/拍, 而不是"把 1G 的字节机加宽")
// ===========================================================================
//  级 A (组合)  : 逐 lane 解码 → 窗口 [lo,hi) → 左对齐载荷 + tkeep + k + 首/末标志
//                 ⭐ **CRC 就挂在级 A** (en/d 与输入字同拍) ⇒ 级 B 那一拍同时拿得到
//                 "含本字(B)的残差"(crc 寄存器) 与"含下一字(A)的残差"(crc_nxt 组合),
//                 FCS 跨字剥离因此**零气泡** (不需要为末字多等一拍)。
//  级 B (寄存器) : 持有"上一步进的字" (本拍要发射的字), 同时级 A 提供"下一字"信息
//  级 C (寄存器) : push 决策落笔 (F4: push_ok = !full_next)
//  ⇒ 吞吐 = 1 字/拍 (只有"整字都是 FCS"这类边界天然少推一个字; 那不是气泡, 是没字节可推)。
//  之所以必须持有 1 个字: FCS 的 4 字节可能跨字 (末字 k<=4 时要回头削前一字的低位字节)。
//
// ===========================================================================
// §F4 (逐条照搬 1G 版, 与位宽无关; 出处 rtl/mac_rx_64.v:128/133/135)
// ===========================================================================
//  push_ok       = !fifo_full_next        —— 下一拍满的**精确预测** (含在飞写与本拍读)
//  push_frame_ok = push_ok && !term_pend  —— 帧字让位给 TERM
//  term_fire     = term_pend && push_ok   —— TERM 优先
//  丢帧一律**整帧丢** + 计数: stat_drop / stat_drop_full / stat_drop_partial / stat_orphan_bytes
//  孤儿字节按 **Σpopc(tkeep)** 计 (1G 版是定值 +8; 64 位版每字 8 字节, 这里逐字算)
// ===========================================================================

module mac_rx_10g (
    input  wire        clk,          // rx_core_clk (官方核 rx_clk_out_N, CDR 恢复域)
    input  wire        rst_n,        // 低有效; 建议 = ~user_rx_reset_N (同域)
    input  wire [63:0] xgmii_rxd,    // lane l = [8l +: 8]
    input  wire [7:0]  xgmii_rxc,    // c[l] ↔ lane l (1 = 该 lane 是控制字符)
    // ---- 冻结合同输出 (FWFT AXIS) ----
    output wire [63:0] m_axis_tdata,
    output wire [7:0]  m_axis_tkeep,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,
    output wire        m_axis_tuser,
    output wire        m_axis_tcrs,
    output wire        m_axis_terr,
    // ---- 契约统计 (名称逐字保持 1G 版: 与板级验收脚本/快照窗口绑定, 改名会让脚本静默读错) ----
    output reg  [31:0] stat_frames,
    output reg  [31:0] stat_crc_err,
    output reg  [31:0] stat_drop,
    output reg  [31:0] stat_bytes,
    output reg  [31:0] stat_drop_full,
    output reg  [31:0] stat_drop_partial,
    output reg  [31:0] stat_orphan_bytes,
    output reg  [31:0] stat_fifo_ovf,
    output reg  [31:0] dbg_stat_words_out,
    // ---- P7b 新增: XGMII 层证据 (官方 PCS 的 stat_* 看不见这一层) ----
    output reg  [31:0] stat_rx_words,      // 消耗的 XGMII 字数 (速率正证据: ×64bit = 线速)
    output reg  [31:0] stat_rx_pay_bytes,  // Σpopc(tkeep) 已交付 (守恒律左端)
    output reg  [31:0] stat_rx_er_words,   // 帧活跃期间含 /E/ 的字数
    output reg  [31:0] stat_rx_bad_words,  // 帧活跃期间含保留控制码的字数
    output reg  [31:0] stat_rx_frag,       // 未闭合帧数 (帧内又见 /S/, 或在无 /T/ 情形下断流)
    output reg  [31:0] stat_rx_no_s,       // 无主 /T/ 字数 (无帧时收到 /T/)
    output reg  [31:0] stat_rx_q,          // /Q/ ordered_set 出现次数 (本轮只计不处理)
    output reg  [31:0] stat_rx_short,      // 交付帧线上长度 < 64B
    output reg  [31:0] stat_rx_long,       // 交付帧线上长度 > 1522B
    output reg  [15:0] dbg_rx_last_len,    // 最近一个交付帧的线上长度 (含 FCS)
    output reg  [3:0]  dbg_rx_last_tlane,  // 最近一个交付帧末字的 /T/ lane
    output reg  [1:0]  dbg_rx_state        // 0=空闲 1=收帧 2=丢帧
);
    // =======================================================================
    // 常量副本 —— **必须与 rtl/mac_10g_defs.vh 逐字一致** (那是带出处的溯源文本;
    // Verilog-2001 不允许 root-scope localparam, 故各 module 内自持一份)
    // =======================================================================
    localparam [7:0] XGMII_I = 8'h07;   // /I/ idle     [S1] Table 46-3
    localparam [7:0] XGMII_Q = 8'h9C;   // /Q/ sequence (仅 lane0 合法)
    localparam [7:0] XGMII_S = 8'hFB;   // /S/ start
    localparam [7:0] XGMII_T = 8'hFD;   // /T/ terminate
    localparam [7:0] XGMII_E = 8'hFE;   // /E/ error
    localparam [7:0] ETH_PRE_OCT = 8'h55;      // preamble octet
    localparam [7:0] ETH_SFD     = 8'hD5;      // <sfd> (串行位序 10101011)
    localparam [15:0] ETH_MIN_CLEN  = 16'd60;  // 内容下界 (pad 目标) [IP] mac_tx_64.v:58
    localparam [15:0] ETH_MAX_FRAME = 16'd1518;// 线上帧长上界 (含 FCS) [S1] Clause 4.4
    localparam [15:0] ETH_MAX_QTAG  = 16'd1522;// Q-tag 帧上界
    localparam [4:0]  ETH_IFG_IDLE  = 5'd12;   // /T/ 之后至少这么多个 /I/ (保守 1 字节)
    localparam [31:0] ETH_CRC_RESIDUE = 32'hDEBB20E3;  // [IP] rtl/mac_rx_64.v:96 (权威)
    // 0xC704DD7B 是 FCS 大端/非反射实现的魔数, **勿用**


    // ---------------------------------------------------------------
    // 级 A-1: 逐 lane 分类 (纯组合)
    // ---------------------------------------------------------------
    wire [63:0] ld = xgmii_rxd;
    wire [7:0]  lc = xgmii_rxc;
    wire [7:0]  lane_is_i, lane_is_s, lane_is_t, lane_is_e, lane_is_q, lane_is_bad;
    genvar gl;
    generate for (gl = 0; gl < 8; gl = gl + 1) begin : g_lane
        wire [7:0] lb = ld[gl*8 +: 8];
        assign lane_is_i[gl]   = lc[gl] && (lb == XGMII_I);
        assign lane_is_s[gl]   = lc[gl] && (lb == XGMII_S);
        assign lane_is_t[gl]   = lc[gl] && (lb == XGMII_T);
        assign lane_is_e[gl]   = lc[gl] && (lb == XGMII_E);
        assign lane_is_q[gl]   = lc[gl] && (lb == XGMII_Q);
        // 保留控制码 (含 /R/ /A/ /K/ /Fsig/ 与 0x00-0x06 等): 正常无错时不应出现
        assign lane_is_bad[gl] = lc[gl] && !(lane_is_i[gl] || lane_is_s[gl] ||
                                             lane_is_t[gl] || lane_is_e[gl] || lane_is_q[gl]);
    end endgenerate

    wire e_any   = |lane_is_e;
    wire q_any   = |lane_is_q;
    wire bad_any = |lane_is_bad;

    // ---------------------------------------------------------------
    // 级 A-2: /S/ 与 /T/ 定位
    // ---------------------------------------------------------------
    wire       s_hit0 = lane_is_s[0];
    wire       s_hit4 = lane_is_s[4];
    wire [7:0] s_other = lane_is_s & 8'hEE;      // lane 0/4 之外的 /S/ = 非法位置
    wire       s_v    = s_hit0 | s_hit4;
    wire [2:0] s_lo   = s_hit0 ? 3'd0 : 3'd4;
    // 数据起始 lane: /S/ 在 lane0 ⇒ 前导组占满本字 ⇒ 下一字 lane0 起是数据;
    //                /S/ 在 lane4 ⇒ 前导组跨字   ⇒ 下一字 lane4 起是数据。统一 = s_lo
    // (原 data_lo 组合写法已删: 见 first_lo 的锁存说明)

    // /T/: 取**最靠前**的 lane (官方监视器同一取法: 从 lane7 往 lane0 扫, 最后一次命中胜出)
    wire [3:0] t_lane_lo;
    assign t_lane_lo = lane_is_t[0] ? 4'd0 : lane_is_t[1] ? 4'd1 :
                       lane_is_t[2] ? 4'd2 : lane_is_t[3] ? 4'd3 :
                       lane_is_t[4] ? 4'd4 : lane_is_t[5] ? 4'd5 :
                       lane_is_t[6] ? 4'd6 : lane_is_t[7] ? 4'd7 : 4'd8;
    wire       t_v  = (t_lane_lo != 4'd8);
    wire [2:0] t_lo = t_lane_lo[2:0];

    // ---------------------------------------------------------------
    // 帧内状态 (输入侧)
    // ---------------------------------------------------------------
    reg        in_active;    // 正在收一个帧的数据
    reg        in_first;     // 下一个数据字是本帧首字
    reg [3:0]  f_tlane;      // 本帧 /T/ 所在 lane (锁存, 供 dbg 用)
    reg [2:0]  first_lo;     // ⭐ /S/ 所在 lane **必须锁存**: s_lo 是组合量,
                             //    /S/ 那一拍之后就没有 /S/ 了 ⇒ 直接用它会把首字窗口
                             //    当成 lane4 起 (实测: 每帧首字少 4 字节 + 内容整体偏移)
    reg [15:0] f_len;        // 本帧累计线上字节数 (含 FCS)
    reg        f_see_e, f_see_bad, f_see_ctrl;
    reg        f_first_done; // 本帧已有字进 FIFO (F4 的 first_done)
    reg [15:0] f_pushed;     // 本帧已推入 FIFO 的字节数 (孤儿字节; Σpopkc)
    reg        term_pend;    // 欠一个 TERM 收尾字 (F4)
    reg        drop_frm;     // 本帧已决定丢弃 (空间不足); 此后不再推任何字

    // ---- 级 A 视角: 本字是否携带本帧数据 ----
    wire       a_v     = in_active;
    wire       a_first = in_active && in_first;
    wire [2:0] lo      = in_first ? first_lo : 3'd0;
    wire [3:0] hi      = t_v ? {1'b0, t_lo} : 4'd8;
    wire [3:0] a_k     = (hi > {1'b0, lo}) ? (hi - {1'b0, lo}) : 4'd0;
    wire [7:0] hi_mask = (hi >= 4'd8) ? 8'h00 : (8'hFF << hi);
    wire [7:0] win_mask = (8'hFF << lo) & ~hi_mask;     // 窗 [lo, hi)
    wire       win_ctrl = |(lc & win_mask);             // 窗内出现任何控制字符 = 帧错
    wire       win_bad  = |(lane_is_bad & win_mask);
    wire       a_last   = a_v && t_v;
    wire [3:0] a_k_l    = a_k;

    // 左对齐: 窗内第一个字节 (lane lo) 放到 tdata[63:56] (合同序)
    function [63:0] align8;
        input [63:0] w;
        input [2:0]  l;
        begin
            case (l)
                3'd0: align8 = {w[7:0],   w[15:8],  w[23:16], w[31:24],
                                w[39:32], w[47:40], w[55:48], w[63:56]};
                3'd4: align8 = {w[39:32], w[47:40], w[55:48], w[63:56], 32'd0};
                default: align8 = 64'd0;
            endcase
        end
    endfunction
    wire [63:0] a_data = align8(ld, lo);
    wire [7:0]  a_keep = (a_k >= 4'd8) ? 8'hFF : (8'hFF << (4'd8 - a_k));

    // ---------------------------------------------------------------
    // 级 B: 持有"上一个字" (= 本拍要发射的字)
    // ---------------------------------------------------------------
    reg [63:0] b_data;
    reg [7:0]  b_keep;
    reg [3:0]  b_k;
    reg        b_first, b_last, b_v;

    // ---------------------------------------------------------------
    // FCS 剥离 / 发射判定 (对 B, 用 A 的信息)
    // ---------------------------------------------------------------
    // 末字 k>4 ⇒ FCS 全在自己字内, 自己剥 4 字节;
    // 末字 k<=4 ⇒ 自己那 k 字节全是 FCS (整字不可交付), 前一字要剥 (4-k) 字节。
    wire [3:0] drop_b = b_last ? ((b_k > 4) ? 4'd4 : b_k)
                               : (a_last ? ((a_k_l >= 4) ? 4'd0 : (4'd4 - a_k_l))
                                         : 4'd0);
    wire [3:0] emit_n = (b_k > drop_b) ? (b_k - drop_b) : 4'd0;
    wire       b_emit_v = b_v && (emit_n != 4'd0);
    wire [7:0] b_keep_out = (emit_n >= 4'd8) ? 8'hFF : (8'hFF << (4'd8 - emit_n));
    // tlast 落位: 帧最后一个"真的推出字节"的字
    //   ① B 自己是末字且还推得出 ⇒ tlast 在 B
    //   ② B 不是末字、下一字 A 是末字、而 A 整字都是 FCS (推不出) ⇒ tlast 落回 B
    wire       b_emit_last = b_emit_v && (b_last || (a_last && (a_k_l <= 4)));

    // ---------------------------------------------------------------
    // CRC: 8 字节/拍, 与**级 A 输入字**同拍 (⇒ 级 B 发射那一拍两条残差都拿得到)
    //   crc     寄存器 = 含 B (= 上一步进的字) 的残差
    //   crc_nxt 组合   = 含 A (= 本级输入字) 的残差
    //   ⚠️ 送 CRC 的 keep 必须是**未剥 FCS 的原始 keep** (FCS 4 字节也是 CRC 的输入)
    // ---------------------------------------------------------------
    wire [31:0] crc, crc_nxt;
    crc32_64 u_crc (
        .clk(clk), .rst_n(rst_n),
        .init(s_v),                 // /S/ 那一拍复位 ⇒ 第一数据字起初值 0xFFFFFFFF
        .en(a_v),                   // 帧数据字才参与
        .d(a_data), .keep(a_keep),
        .crc(crc), .crc_nxt(crc_nxt)
    );
    wire res_ok = b_last ? (crc == ETH_CRC_RESIDUE) : (crc_nxt == ETH_CRC_RESIDUE);

    // 帧级错误: 本帧至今 (f_see_*) + 末字若是 A 还要算上 A 本拍的错误
    wire a_err_new = a_v && (e_any | bad_any | win_ctrl | win_bad);
    wire b_err_out = f_see_e | f_see_bad | f_see_ctrl | (a_last ? a_err_new : 1'b0);

    // 帧总长 (线上, 含 FCS): 推 tlast 那一拍必须已经含末字
    wire [15:0] len_now = b_last ? f_len : (f_len + {12'd0, a_k_l});

    // ---------------------------------------------------------------
    // F4 三门 + push
    // ---------------------------------------------------------------
    reg         push, push_last, push_sop, push_crs, push_err;
    reg  [63:0] push_data;
    reg  [7:0]  push_keep;
    wire        fifo_full, fifo_full_next, fifo_ovf_pulse;
    wire        push_ok       = !fifo_full_next;
    wire        push_frame_ok = push_ok && !term_pend;
    wire        term_fire     = term_pend && push_ok;
    // ⭐ 帧内又见 /S/ = 上一帧是**未闭合碎片**: 它的在飞字 (B 与本拍的字) 一律丢弃,
    //    绝不推入 (否则会留下"无 TLAST 的裸 SOP")。已推过的字由下面的 TERM 收尾。
    wire        frag_now      = s_v && in_active;
    wire        want_push     = b_emit_v && !drop_frm && !frag_now;
    wire        frame_push_ok = want_push && push_frame_ok;
    wire        zero_len_frm  = b_v && b_first && (emit_n == 4'd0) && !f_first_done;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_active <= 1'b0; in_first <= 1'b0; first_lo <= 3'd0; f_tlane <= 4'd0; f_len <= 16'd0;
            f_see_e <= 1'b0; f_see_bad <= 1'b0; f_see_ctrl <= 1'b0;
            f_first_done <= 1'b0; f_pushed <= 16'd0; term_pend <= 1'b0; drop_frm <= 1'b0;
            b_data <= 64'd0; b_keep <= 8'd0; b_k <= 4'd0;
            b_first <= 1'b0; b_last <= 1'b0; b_v <= 1'b0;
            push <= 1'b0; push_last <= 1'b0; push_sop <= 1'b0;
            push_crs <= 1'b0; push_err <= 1'b0; push_data <= 64'd0; push_keep <= 8'd0;
            stat_frames <= 0; stat_crc_err <= 0; stat_drop <= 0; stat_bytes <= 0;
            stat_drop_full <= 0; stat_drop_partial <= 0; stat_orphan_bytes <= 0; stat_fifo_ovf <= 0;
            dbg_stat_words_out <= 32'd0;
            stat_rx_words <= 0; stat_rx_pay_bytes <= 0; stat_rx_er_words <= 0;
            stat_rx_bad_words <= 0; stat_rx_frag <= 0; stat_rx_no_s <= 0; stat_rx_q <= 0;
            stat_rx_short <= 0; stat_rx_long <= 0;
            dbg_rx_last_len <= 16'd0; dbg_rx_last_tlane <= 4'd0; dbg_rx_state <= 2'd0;
        end else begin
            // ---- 脉冲型每拍默认清零 (工程坑 6) ----
            push <= 1'b0; push_last <= 1'b0; push_sop <= 1'b0;
            push_crs <= 1'b0; push_err <= 1'b0;

            // ---- 观测计数 ----
            stat_rx_words <= stat_rx_words + 32'd1;
            if (m_axis_tvalid && m_axis_tready)
                dbg_stat_words_out <= dbg_stat_words_out + 32'd1;
            if (fifo_ovf_pulse) stat_fifo_ovf <= stat_fifo_ovf + 32'd1;
            if (a_v && e_any)   stat_rx_er_words  <= stat_rx_er_words  + 32'd1;
            if (a_v && bad_any) stat_rx_bad_words <= stat_rx_bad_words + 32'd1;
            if (q_any)          stat_rx_q        <= stat_rx_q        + 32'd1;

            // ---- TERM 收尾字: 全局优先 (与帧字推入互斥: 帧推入门含 !term_pend) ----
            if (term_fire) begin
                push      <= 1'b1;
                push_data <= 64'd0;
                push_keep <= 8'd0;
                push_last <= 1'b1;
                push_sop  <= 1'b0;
                push_crs  <= 1'b0;
                push_err  <= 1'b1;
                term_pend <= 1'b0;
            end

            // ---- 帧字推入 ----
            if (frame_push_ok) begin
                push      <= 1'b1;
                push_data <= b_data;
                push_keep <= b_keep_out;
                push_last <= b_emit_last;
                push_sop  <= b_first;
                push_crs  <= b_emit_last && res_ok;
                push_err  <= b_emit_last && b_err_out;
                if (b_first) f_first_done <= 1'b1;
                f_pushed <= f_pushed + {12'd0, emit_n};
                stat_rx_pay_bytes <= stat_rx_pay_bytes + {28'd0, emit_n};
                if (b_emit_last) begin
                    stat_frames <= stat_frames + 32'd1;
                    if (!res_ok) stat_crc_err <= stat_crc_err + 32'd1;
                    stat_bytes  <= stat_bytes + {16'd0, len_now};
                    if (len_now < 16'd64)           stat_rx_short <= stat_rx_short + 32'd1;
                    else if (len_now > ETH_MAX_QTAG) stat_rx_long  <= stat_rx_long  + 32'd1;
                    dbg_rx_last_len   <= len_now;
                    dbg_rx_last_tlane <= b_last ? f_tlane : t_lane_lo;
                end
            end else if (want_push) begin
                // 空间不足 (或欠 TERM) ⇒ 本帧整帧丢弃 (F4)。已推过的字成孤儿 ⇒ 欠 TERM。
                drop_frm <= 1'b1;
                stat_drop <= stat_drop + 32'd1;
                if (!push_ok) stat_drop_full <= stat_drop_full + 32'd1;
                if (f_first_done) begin
                    term_pend <= 1'b1;
                    stat_drop_partial <= stat_drop_partial + 32'd1;
                    stat_orphan_bytes <= stat_orphan_bytes + {16'd0, f_pushed};
                end
            end else if (zero_len_frm) begin
                // 零字节净荷帧: 整帧 0 字节交付 ⇒ 丢 (从未推过 ⇒ 无 TERM)
                stat_drop <= stat_drop + 32'd1;
            end

            // drop_frm 在末字处理完那一拍撤除 (帧边界)
            if (b_v && b_last) drop_frm <= 1'b0;

            // ---- 级 B 寄存器 ----
            b_data  <= a_data;
            b_keep  <= a_keep;
            b_k     <= a_k;
            b_first <= a_first;
            b_last  <= a_last;
            b_v     <= a_v && !frag_now;      // frag: 本拍的字属于被放弃的帧

            // ---- 输入侧状态机 (级 A) ----
            if (s_v) begin
                if (in_active) begin
                    // 帧内又见 /S/ ⇒ 上一帧是**未闭合的碎片** (无 /T/)
                    stat_rx_frag <= stat_rx_frag + 32'd1;
                    stat_drop    <= stat_drop + 32'd1;
                    if (f_first_done) begin
                        term_pend <= 1'b1;
                        stat_drop_partial <= stat_drop_partial + 32'd1;
                        stat_orphan_bytes <= stat_orphan_bytes + {16'd0, f_pushed};
                    end
                end
                if (|s_other) stat_rx_bad_words <= stat_rx_bad_words + 32'd1; // 非法位置的 /S/
                in_active <= 1'b1; in_first <= 1'b1; first_lo <= s_lo;
                f_len <= 16'd0; f_see_e <= 1'b0; f_see_bad <= 1'b0; f_see_ctrl <= 1'b0;
                f_first_done <= 1'b0; f_pushed <= 16'd0; drop_frm <= 1'b0;
            end else if (in_active) begin
                in_first <= 1'b0;
                if (t_v) f_tlane <= t_lane_lo;
                f_len <= f_len + {12'd0, a_k};
                if (e_any)    f_see_e    <= 1'b1;
                if (bad_any)  f_see_bad  <= 1'b1;
                if (win_ctrl) f_see_ctrl <= 1'b1;
                if (t_v) in_active <= 1'b0;      // 帧闭合
            end else begin
                if (t_v) stat_rx_no_s <= stat_rx_no_s + 32'd1;   // 无主 /T/
            end

            dbg_rx_state <= drop_frm ? 2'd2 : (in_active ? 2'd1 : 2'd0);
        end
    end

    // ---------------------------------------------------------------
    // 输出 FIFO + AXIS (FWFT; 结构同 1G 版, 深度 8→16 以吸收下游停顿)
    // ---------------------------------------------------------------
    localparam FW = 76;   // {tdata[75:12], tkeep[11:4], sop[3], last[2], crs[1], err[0]}
    wire [FW-1:0] fdin = {push_data, push_keep, push_sop, push_last, push_crs, push_err};
    wire [FW-1:0] fdout;
    wire          fempty;
    wire          rd = m_axis_tvalid && m_axis_tready;

    fifo_sync #(.W(FW), .D(16), .AW(4)) u_fifo (
        .clk(clk), .rst_n(rst_n),
        .wr(push), .din(fdin),
        .rd(rd), .dout(fdout),
        .empty(fempty), .full(fifo_full),
        .full_next(fifo_full_next),     // F4: 空间门用精确下一拍满
        .ovf_pulse(fifo_ovf_pulse)      // 自检; 应恒 0
    );

    assign m_axis_tdata  = fdout[75:12];
    assign m_axis_tkeep  = fdout[11:4];
    assign m_axis_tuser  = fdout[3];
    assign m_axis_tlast  = fdout[2];
    assign m_axis_tcrs   = fdout[1];
    assign m_axis_terr   = fdout[0];
    assign m_axis_tvalid = !fempty;

endmodule
