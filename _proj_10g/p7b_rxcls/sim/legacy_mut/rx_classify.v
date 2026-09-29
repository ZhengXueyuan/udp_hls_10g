`timescale 1ns/1ps
// ===========================================================================
// rx_classify_v2 —— P7B 吞吐修复: 路由决策与字流**解耦**
// ===========================================================================
// as-built v1 (rtl/rx_classify.v) 的结构病 (审计 P7B_RXCLASSIFY_AUDIT.md §4.2):
//   FILL 与 DRAIN 挤在同一个 3 态 FSM 里、**不重叠**, 且 **FILL 期不输出**
//   ⇒ 每帧死 3 拍 (非 TCP) / 6 拍 (TCP) ⇒ 通道硬上限 N/(N+停顿)
//   ⇒ 最小帧只剩 57.1%; 加深上游 FIFO 修不了 (死的是整链拍, 不是缓冲容量)。
//
// v2 = 输入字流与"分类流水"**并排跑**, 只有两处耦合:
//   · 写侧 (组合): 逐字判 w1[31:16] / w2[7:0] / w5[7:0] (+ tlast 优先), 每帧定案时
//     推 1 个路由项进"路由队列"; 字本体进 76bit x 16 的 FWFT 字 FIFO。**收字不看决策**。
//   · 读侧 (组合): 头字可发 ⇔ 字 FIFO 非空 ∧ 路由队列非空 ∧ 所选路由 tready;
//     本帧末字 (tlast) 发出那一拍路由项出队。
//   ⇒ 决策窗 (3/6 字) 只是**流水延迟**, 不再是通道空闲 ⇒ 稳态 1 字/拍, 零死拍。
//
// 分类判据 / 路由 / 侧带透传 / 三站计数 与 v1 **逐条等价** (保真表见
// notes/P7B_RXCLASSIFY_DESIGN.md §4); 唯一变化 = "何时可发" (v1 先憋后倒空, v2 边收边发)。
// 逐帧首字延迟与 v1 **相同** (非 TCP 决策点 = w2 拍, TCP = w5 拍)。
//
// ⚠️ 与 v1 的背压语义差异 (有意, 记入设计文档): v1 在 PASS 期把下游 tready **组合**
//    传到上游; v2 的上游 tready = !字FIFO满 (与下游解耦), 下游停顿先吃 16 字弹性,
//    吃完才向上游传播。丢帧仍在上游 mac_rx (F4: 整帧丢 + TERM 收尾 + 计数)。
// ===========================================================================

module rx_classify (
    input  wire        clk,
    input  wire        rst_n,
    // 来自 mac_rx
    input  wire [63:0] s_axis_tdata,
    input  wire [7:0]  s_axis_tkeep,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tuser,   // SOP
    input  wire        s_axis_tcrs,    // TLAST: FCS 正确
    input  wire        s_axis_terr,    // TLAST: 帧内 rx_er
    // fast 路由 (TCP 数据面)
    output wire [63:0] m_fast_tdata,
    output wire [7:0]  m_fast_tkeep,
    output wire        m_fast_tvalid,
    input  wire        m_fast_tready,
    output wire        m_fast_tlast,
    output wire        m_fast_tuser,
    output wire        m_fast_tcrs,
    output wire        m_fast_terr,
    // slow 路由 (慢路径 HLS)
    output wire [63:0] m_slow_tdata,
    output wire [7:0]  m_slow_tkeep,
    output wire        m_slow_tvalid,
    input  wire        m_slow_tready,
    output wire        m_slow_tlast,
    output wire        m_slow_tuser,
    output wire        m_slow_tcrs,
    output wire        m_slow_terr,
    output reg  [31:0] stat_fast,
    output reg  [31:0] stat_slow,
    // P4b-7-P6 三站词计数 (中间站; 语义与 v1 **逐字相同**)
    output wire [31:0] dbg_stat_words_in,
    output wire [31:0] dbg_stat_words_out,
    // ---- P7b 新增观测 (落地时接出即可; 悬空不影响功能) ----
    output reg  [31:0] dbg_stat_ovf,        // 字 FIFO 拒写拍数 (自检; 结构上恒 0)
    output reg  [31:0] dbg_stat_route_ovf,  // 路由队列拒写拍数 (自检; 结构上恒 0)
    output reg  [31:0] dbg_stat_stall_in,   // 输入停等拍数 (s_tvalid && !s_tready)
    output wire [4:0]  dbg_occ              // 字 FIFO 当前占用 (0..16)
);
    localparam RT_FAST = 1'b0, RT_SLOW = 1'b1;

    // ---- 字 FIFO: 76 bit x 16 (FWFT) -------------------------------------
    localparam FW  = 76;
    localparam FD  = 16;
    localparam FAW = 4;
    localparam RQ   = 16;    // 路由队列深度 == 字 FIFO 深度 (见设计文档 §6.2 的不变式)
    localparam RQAW = 4;     // 地址位宽 (指针 = RQAW+1 位: 低 RQAW 位是地址, 最高位是绕回)

    wire [FW-1:0] w_din = {s_axis_tdata, s_axis_tkeep, s_axis_tlast,
                           s_axis_tuser, s_axis_tcrs, s_axis_terr};
    wire [FW-1:0] w_dout;
    wire          w_empty, w_full, w_ovf;
    wire [FAW:0]  w_wptr, w_rptr;
    wire          w_rd;                       // 读侧消费 ( = 发射 )
    // ⭐ 空间门: tready 与 wr **同拍组合** ⇒ 落到 fifo_sync 的 `wr && !full` 上恒成立,
    //    不存在"本拍满 + 下拍有在飞写"的错位 (F4 那一课只在 wr 是寄存器时成立)。
    assign s_axis_tready = !w_full;
    wire          s_acc = s_axis_tvalid && s_axis_tready;
    wire          w_wr  = s_acc;

    fifo_sync #(.W(FW), .D(FD), .AW(FAW)) u_wf (
        .clk(clk), .rst_n(rst_n),
        .wr(w_wr), .din(w_din), .rd(w_rd), .dout(w_dout),
        .empty(w_empty), .full(w_full),
        .dbg_wptr(w_wptr), .dbg_rptr(w_rptr), .dbg_full(), .dbg_empty(),
        .full_next(), .ovf_pulse(w_ovf)   // full_next 本版不用 (wr 是组合写, 见上)
    );
    assign dbg_occ = w_wptr - w_rptr;

    // ---- 写侧: 帧内字索引 + 每帧路由决策 (判据与 v1:129-149 逐条等价) ----
    reg  [3:0] widx;        // 帧内字数索引 (0 起, 0..15 饱和; 判据只看 1/2/5)
    reg        f_ipv4;      // w1[31:16]==0x0800 (在 widx==1 那一拍锁存)
    reg        dec_done;    // 本帧路由已定案 (v1 的 wait_w5 的等价物)
    wire       cur_is_tcp  = f_ipv4 && (s_axis_tdata[7:0] == 8'd6);  // 仅 widx==2 有意义
    wire       cur_tcp_ctl = |s_axis_tdata[2:0];                     // 仅 widx==5 有意义
    wire       dec_w2 = (widx == 4'd2) && !s_axis_tlast && !cur_is_tcp; // 非 TCP: 定案 SLOW
    wire       dec_w5 = (widx == 4'd5);                // TCP: 看 w5 flags
    // ⭐ tlast 优先于 w5 flags (v1:129 `if (s_axis_tlast)` 在 `else if (n==5)` 之前)
    wire       dec_fire = w_wr && !dec_done && (s_axis_tlast || dec_w2 || dec_w5);
    wire       dec_val  = dec_w5 ? (cur_tcp_ctl ? RT_SLOW : RT_FAST) : RT_SLOW;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            widx <= 4'd0; f_ipv4 <= 1'b0; dec_done <= 1'b0;
        end else if (w_wr) begin
            if (s_axis_tlast) begin
                // 帧末: 下一字起是新帧 (路由定案由 dec_fire 同拍完成)
                widx <= 4'd0; f_ipv4 <= 1'b0; dec_done <= 1'b0;
            end else begin
                widx <= (widx == 4'd15) ? 4'd15 : (widx + 4'd1);
                if (widx == 4'd1) f_ipv4 <= (s_axis_tdata[31:16] == 16'h0800);
                if (dec_fire) dec_done <= 1'b1;
            end
        end
    end

    // ---- 路由队列: 每帧 1 项, 帧序入队; 头帧末字发出那一拍出队 ------------
    // 不变式: 入队严格与字入 FIFO 同拍, 出队严格与"本帧末字被下游收下"同拍
    //   ⇒ 队首恒 = 字 FIFO 队首所属帧的路由 (证明见设计文档 §2.3)
    reg  [RQ-1:0] rq_mem;
    reg  [RQAW:0] rq_wp, rq_rp;                          // ⚠️ 地址字段必须窄到 RQAW 位
    wire          rq_empty  = (rq_wp == rq_rp);
    wire          rq_full   = (rq_wp[RQAW-1:0] == rq_rp[RQAW-1:0]) && (rq_wp[RQAW] != rq_rp[RQAW]);
    wire          rq_wr_ok  = dec_fire && !rq_full;
    wire          rq_rej    = dec_fire && rq_full;       // 自检: 结构上不可能 (计数不静默)
    wire          rq_head   = rq_mem[rq_rp[RQAW-1:0]];   // 头帧路由 (组合读; rq_empty 时无意义)

    // ---- 读侧: 头字可发 ⇔ 有字 ∧ 路由已知 -------------------------------
    wire          out_fast    = (rq_head == RT_FAST);
    wire          m_tready_sel = out_fast ? m_fast_tready : m_slow_tready;
    wire          rd_ok       = !w_empty && !rq_empty;
    wire          rq_pop      = w_rd && w_dout[3];       // 本帧末字发出那一拍

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rq_wp <= 0; rq_rp <= 0; rq_mem <= 0;
        end else begin
            if (rq_wr_ok) rq_mem[rq_wp[RQAW-1:0]] <= dec_val;
            if (rq_wr_ok) rq_wp <= rq_wp + 1'b1;
            if (rq_pop)   rq_rp <= rq_rp + 1'b1;
        end
    end

    // ---- 输出: FWFT (dout 寄存器, valid 组合) ----------------------------
    wire [63:0] o_d = w_dout[75:12];
    wire [7:0]  o_k = w_dout[11:4];
    wire        o_l = w_dout[3];
    wire        o_u = w_dout[2];
    wire        o_c = w_dout[1];
    wire        o_e = w_dout[0];

    assign m_fast_tdata  = o_d;
    assign m_fast_tkeep  = o_k;
    assign m_fast_tlast  = o_l;
    assign m_fast_tuser  = o_u;
    assign m_fast_tcrs   = o_c;
    assign m_fast_terr   = o_e;
    assign m_fast_tvalid = rd_ok &&  out_fast;
    assign m_slow_tdata  = o_d;
    assign m_slow_tkeep  = o_k;
    assign m_slow_tlast  = o_l;
    assign m_slow_tuser  = o_u;
    assign m_slow_tcrs   = o_c;
    assign m_slow_terr   = o_e;
    assign m_slow_tvalid = rd_ok && !out_fast;
    assign w_rd = rd_ok && m_tready_sel;

    // ---- 计数 (与 v1 同口径) --------------------------------------------
    wire last_emit = w_rd && o_l;                        // 本帧末字被下游收下
    wire f_acc     = m_fast_tvalid && m_fast_tready;     // fast 路发出字
    reg  [31:0] words_in, words_out;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stat_fast <= 0; stat_slow <= 0;
            words_in <= 32'd0; words_out <= 32'd0;
            dbg_stat_ovf <= 0; dbg_stat_route_ovf <= 0; dbg_stat_stall_in <= 0;
        end else begin
            if (w_wr)   words_in  <= words_in  + 32'd1;
            if (f_acc)  words_out <= words_out + 32'd1;
            if (last_emit) begin
                if (out_fast) stat_fast <= stat_fast + 32'd1;
                else          stat_slow <= stat_slow + 32'd1;
            end
            // 自检计数 (结构上恒 0; 一旦非 0 = 有字/有路由被静默丢弃)
            if (w_ovf)   dbg_stat_ovf       <= dbg_stat_ovf       + 32'd1;
            if (rq_rej)  dbg_stat_route_ovf <= dbg_stat_route_ovf + 32'd1;
            if (s_axis_tvalid && !s_axis_tready)
                dbg_stat_stall_in <= dbg_stat_stall_in + 32'd1;
        end
    end

    assign dbg_stat_words_in  = words_in;
    assign dbg_stat_words_out = words_out;
endmodule
