`timescale 1ns/1ps
// ===========================================================================
// mac_tx_10g —— 64 位帧流合同 → 64 位 XGMII 发送 MAC
// ===========================================================================
// 输出帧 (线上, XGMII 一拍 8 个字符):
//   [lane0:/S/(c=1) + lane1..6:0x55 + lane7:0xD5] [内容 DA..payload] [pad 到 60] [FCS 4B]
//   [/T/ 落在最后一个有效字节之后的那个 lane] [/I/ 补满 IFG (>= 12 个 /I/)]
// 前导/IFG 常量与出处见 rtl/mac_10g_defs.vh §2/§3; FCS 见 §4。
// 源约定 (与 1G 版逐字相同): 每词 tkeep != 0 (高位有效, = mac_rx_10g 的输出约定);
//   帧边界**只**靠 tlast (TX 字流不带 tuser/SOP) —— rtl/mac_tx_64.v:21
//
// ⭐ 真流水的 64 位结构 (不是"把 1G 的字节机加宽"; 对照 1G 的 8+4+12=24 拍固定开销):
//   前导只占**帧首那一拍**的 lane 里 (没有 S_PRE 的 8 拍);
//   FCS 在**末内容字那一拍**用 8 字节并行 CRC 结清 (crc_nxt 组合), 并与该字**同拍**落位
//   (末字 = "内容残余 + pad + FCS + /T/ + /I/" 的**合并字**, 不额外占拍);
//   pad / FCS / /T/ / /I/ 由"尾向量 t16"的变长字节拼接一次成形, 不逐字节播放。
//   ⇒ 每帧拍数 = 1(前导) + ceil(L/8)(内容, 末字与尾合并) + 1(尾字) + IFG(1~2)
//      L=60 → 11 拍 (线侧预算 84B/88B = 95.5%); L=1514 → 99.6%  (算数见 notes §7)
//
// 尾向量 t16 (12 字节, 逻辑索引; lane 与索引之差 = t_start = 本字内容字节数 + 本字 pad 数):
//   [0..3] = FCS (小端: 低字节先上线)   [4] = /T/   [>=5] = /I/
//
// ===========================================================================
// §F-2 (逐字保住 rtl/mac_tx_64.v:224-244 的语义): 帧内中止后必须冲刷到本帧 TLAST
// ===========================================================================
// 中止 ⇒ **立即补一个 /T/ 把帧结掉** (802.3 46.2.1: <inter-frame> 以 Terminate 开头;
//   缺 /T/ 会让对端一直等不到帧尾 ⇒ 线上不能出现"永不终止的数据流"。1G GMII 没有 /T/
//   概念, 这是 XGMII 的必要补充, 已登记为"与 1G 实现的必要偏离"), 然后进 S_FLUSH:
//   **一个字都不发**, 逐字弹掉输入 FIFO 直到吞掉本帧 TLAST (判据 `frd && fdout[0]`),
//   再等够 IFG 才回 S_IDLE ⇒ 残字绝不被当成下一帧 (否则会发出 FCS 完全正确的"幽灵帧")。
// ===========================================================================

module mac_tx_10g (
    input  wire        clk,          // tx_mii_clk (官方核 tx_mii_clk_N)
    input  wire        rst_n,        // 低有效; 建议 = ~user_tx_reset_N (同域)
    input  wire [63:0] s_axis_tdata,
    input  wire [7:0]  s_axis_tkeep,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    output wire [63:0] xgmii_txd,    // lane l = [8l +: 8]
    output wire [7:0]  xgmii_txc,    // c[l] ↔ lane l
    output reg  [31:0] stat_frames,
    output reg  [31:0] stat_abort,        // 帧内中止次数 (线上留 runt + /T/ 结帧)
    output reg  [31:0] stat_flush_words,  // 冲刷期被丢弃的输入字数 (F-2)
    output reg  [31:0] stat_flush_done,   // 冲刷完成次数 (= 重新对齐到帧边界的次数)
    // P7b 新增
    output reg  [31:0] stat_tx_words,     // 发出的 XGMII 字数 (速率正证据: ×64bit = 线速)
    output reg  [31:0] stat_tx_ctrl_char, // 发出的控制字符数 (含 /S/ /T/ /I/; IFG 证据)
    output reg  [31:0] stat_tx_short,     // 中止帧数 (= 线上 runt 数)
    output reg  [15:0] dbg_tx_last_clen,  // 最近一帧的**线上内容长度** (含 pad, 不含 FCS)
    output reg  [1:0]  dbg_tx_state       // 0=空闲 1=发帧 2=中止 3=冲刷
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

    localparam [2:0] S_IDLE = 3'd0, S_PRE = 3'd1, S_DATA = 3'd2,
                     S_TAIL0 = 3'd3, S_TAIL1 = 3'd4, S_IFG = 3'd5,
                     S_ABORT = 3'd6, S_FLUSH = 3'd7;

    reg [2:0] state;

    // ---- 字 FIFO (73b = tdata+tkeep+tlast; 与 1G 版同构, 深度 16) ----
    localparam FW = 73;
    wire [FW-1:0] fdin = {s_axis_tdata, s_axis_tkeep, s_axis_tlast};
    wire [FW-1:0] fdout;
    wire          fempty, ffull;
    wire          frd;
    reg           flush_tl;      // F-2: 本帧 TLAST 已被吞掉 (停止再弹)
    wire          fwr = s_axis_tvalid && s_axis_tready;
    assign s_axis_tready = !ffull;

    fifo_sync #(.W(FW), .D(16), .AW(4)) u_fifo (
        .clk(clk), .rst_n(rst_n),
        .wr(fwr), .din(fdin),
        .rd(frd), .dout(fdout),
        .empty(fempty), .full(ffull),
        .dbg_wptr(), .dbg_rptr(), .dbg_full(), .dbg_empty(), .full_next(), .ovf_pulse()
    );

    // ---- 当前字 cw (= 本拍要发射的内容字) ----
    reg [63:0] cw_data;
    reg [7:0]  cw_keep;
    reg        cw_last;
    reg [3:0]  cw_len;
    reg [15:0] plen;          // 已发内容字节数 (不含本拍 cw)

    // ⭐ 弹出请求必须是**组合**的: fifo_sync 的 dout 恒等于"本拍的头字"
    //   (dout(T+1)=mem[rptr(T+1)]), 而 rd 在 T 拍为 1 时头字才在 T 沿被消费
    //   ⇒ 只有"同拍捕获 + 同拍弹出"才能一个字/拍推进。
    //   (寄存器版 frd 会晚一拍: 首字被捕获两次、整帧多一拍并丢掉 TLAST —— 实测踩过)
    assign frd = (state == S_PRE)   ? !fempty :
                 (state == S_DATA)  ? (!cw_last && (cw_len != 4'd0) && !fempty) :
                 (state == S_FLUSH) ? (!fempty && !flush_tl) : 1'b0;

    // ---- 尾部寄存器 ----
    reg [31:0] m_fcs;         // 本帧 FCS (末内容字那一拍锁存)
    reg [5:0]  m_pad_left;    // 尚需补的 pad 字节数
    reg [4:0]  m_dhere;       // S_TAIL0 本字承载的内容字节数 (只可能是 0)
    reg [4:0]  m_tptr;        // S_TAIL1 本字的尾向量起始索引
    reg [4:0]  m_idle;        // /T/ 之后已发出的 /I/ 字节数
    reg [15:0] m_clen;        // 本帧内容字节数 (含 pad)
    reg [3:0]  flush_cnt;
    wire [4:0] t1_idle = (m_tptr >= 5'd5) ? 5'd8 : (m_tptr + 5'd3);

    function [3:0] popc8;
        input [7:0] x;
        reg [3:0] c;
        integer i;
        begin
            c = 4'd0;
            for (i = 0; i < 8; i = i + 1) c = c + x[i];
            popc8 = c;
        end
    endfunction

    // ---- 纯 8 字节镜像 (无位序翻转) ----
    function [63:0] bswap64;
        input [63:0] d;
        integer i;
        begin
            for (i = 0; i < 8; i = i + 1) bswap64[i*8 +: 8] = d[(7-i)*8 +: 8];
        end
    endfunction

    // ---- 尾向量取值: idx 0..3 = FCS(小端先出), 4 = /T/, >=5 = /I/ ----
    function [7:0] tl;
        input [31:0] f;
        input [4:0]  idx;
        begin
            case (idx)
                5'd0:    tl = f[7:0];
                5'd1:    tl = f[15:8];
                5'd2:    tl = f[23:16];
                5'd3:    tl = f[31:24];
                5'd4:    tl = XGMII_T;
                default: tl = XGMII_I;
            endcase
        end
    endfunction

    // ---- 合并字 (XGMII lane 序): [内容 0..dhere-1][pad 0][尾 t16] ----
    function [63:0] merge_d;
        input [63:0] content;   // 合同序 (tdata[63:56] = 首字节)
        input [4:0]  dhere;
        input [4:0]  tstart0;   // 尾部起始 lane (0..8)
        input [31:0] f;
        integer l;
        reg [7:0] b;
        begin
            merge_d = 64'd0;
            for (l = 0; l < 8; l = l + 1) begin
                if (l < dhere)             b = content[63 - 8*l -: 8];
                else if (l < tstart0)      b = 8'h00;              // pad
                else                       b = tl(f, {1'b0, l} - tstart0);
                merge_d[8*l +: 8] = b;
            end
        end
    endfunction
    function [7:0] merge_c;
        input [4:0] tstart0;
        integer l;
        begin
            merge_c = 8'h00;
            for (l = 0; l < 8; l = l + 1)
                if (l >= tstart0 + 5'd4) merge_c[l] = 1'b1;   // /T/ 及其后 = 控制字符
        end
    endfunction
    // ---- S_TAIL1 尾字: 第 l lane = tl(m_tptr + l) ----
    function [63:0] tail_d;
        input [31:0] f;
        input [4:0]  lane0;
        integer l;
        begin
            tail_d = 64'd0;
            for (l = 0; l < 8; l = l + 1) tail_d[8*l +: 8] = tl(f, lane0 + l);
        end
    endfunction
    function [7:0] tail_c;
        input [4:0] lane0;
        integer l;
        begin
            tail_c = 8'h00;
            for (l = 0; l < 8; l = l + 1) tail_c[l] = ((lane0 + l) >= 5'd4);
        end
    endfunction

    // ---- CRC 挂在"本拍发射的 cw"上 (en/d/keep 与发射同拍) ----
    wire [31:0] crc, crc_nxt;
    wire        crc_init = (state == S_PRE);
    wire        crc_en   = (state == S_DATA) && (cw_len != 4'd0);
    crc32_64 u_crc (
        .clk(clk), .rst_n(rst_n),
        .init(crc_init), .en(crc_en),
        .d(cw_data), .keep(cw_keep),
        .crc(crc), .crc_nxt(crc_nxt)
    );

    // ---- 末内容字那一拍的组合量 (合并字就用它算出来的 t_start 与 fcs) ----
    wire [15:0] lw_L    = plen + {12'd0, cw_len};
    wire [5:0]  lw_pad  = (lw_L >= ETH_MIN_CLEN) ? 6'd0 : (ETH_MIN_CLEN - lw_L);
    wire [5:0]  lw_room = 6'd8 - {2'd0, cw_len};
    wire [4:0]  lw_ph   = (lw_pad > lw_room) ? lw_room[4:0] : lw_pad[4:0];   // 本字 pad 数
    wire [5:0]  lw_pr   = lw_pad - {1'b0, lw_ph};                           // 剩余 pad
    wire [4:0]  lw_ts   = {1'b0, cw_len} + lw_ph;                           // 尾起始 lane
    wire [31:0] lw_fcs  = crc_nxt ^ 32'hFFFFFFFF;   // 终值取反 (小端上线)

    // ---- S_TAIL0 (纯 pad 续字) 的组合量 ----
    wire [4:0]  p0_ph  = (m_pad_left > 6'd8) ? 5'd8 : m_pad_left[4:0];
    wire [4:0]  p0_room= 5'd8 - m_dhere;
    wire [4:0]  p0_use = (p0_ph > p0_room) ? p0_room : p0_ph;
    wire [4:0]  p0_ts  = m_dhere + p0_use;
    wire [5:0]  p0_rst = m_pad_left - {1'b0, p0_use};

    // ---- 发射 mux (组合) ----
    reg [63:0] tx_d;
    reg [7:0]  tx_c;
    always @* begin
        case (state)
            S_PRE:   begin tx_d = {ETH_SFD, ETH_PRE_OCT, ETH_PRE_OCT, ETH_PRE_OCT,
                                   ETH_PRE_OCT, ETH_PRE_OCT, ETH_PRE_OCT, XGMII_S};
                           tx_c = 8'h01; end            // 只有 lane0 是控制字符
            S_DATA:  if (cw_len == 4'd0) begin
                         tx_d = 64'h0707070707070707; tx_c = 8'hFF; end
                     else if (cw_last) begin
                         // ⭐ 末内容字 = 合并字 (内容残余 + pad + FCS + /T/ + /I/), 不额外占拍
                         tx_d = merge_d(cw_data, {1'b0, cw_len}, lw_ts, lw_fcs);
                         tx_c = merge_c(lw_ts); end
                     else begin
                         tx_d = bswap64(cw_data); tx_c = 8'h00; end
            S_TAIL0: begin tx_d = merge_d(cw_data, m_dhere, p0_ts, m_fcs);
                           tx_c = merge_c(p0_ts); end
            S_TAIL1: begin tx_d = tail_d(m_fcs, m_tptr); tx_c = tail_c(m_tptr); end
            S_ABORT: begin tx_d = {56'h07070707070707, XGMII_T}; tx_c = 8'hFF; end
            default: begin tx_d = 64'h0707070707070707; tx_c = 8'hFF; end   // IDLE/IFG/FLUSH
        endcase
    end
    assign xgmii_txd = tx_d;
    assign xgmii_txc = tx_c;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            cw_data <= 64'd0; cw_keep <= 8'd0; cw_last <= 1'b0; cw_len <= 4'd0; plen <= 16'd0;
            m_fcs <= 32'd0; m_pad_left <= 6'd0; m_dhere <= 4'd0; m_tptr <= 4'd0;
            m_idle <= 5'd0; m_clen <= 16'd0; flush_cnt <= 4'd0; flush_tl <= 1'b0;
            stat_frames <= 0; stat_abort <= 0; stat_flush_words <= 0; stat_flush_done <= 0;
            stat_tx_words <= 0; stat_tx_ctrl_char <= 0; stat_tx_short <= 0;
            dbg_tx_last_clen <= 16'd0; dbg_tx_state <= 2'd0;
        end else begin
            // ---- 观测: 每个时钟发一个 XGMII 字; 控制字符数按 c 的 popcount ----
            stat_tx_words     <= stat_tx_words + 32'd1;
            stat_tx_ctrl_char <= stat_tx_ctrl_char + {28'd0, popc8(tx_c)};

            case (state)
                // ---------------------------------------------------
                S_IDLE: if (!fempty) state <= S_PRE;
                // ---------------------------------------------------
                S_PRE: begin
                    // 本拍发前导字; 同拍"捕获 + 弹出"首字 (下一拍发)
                    if (!fempty) begin
                        cw_data <= fdout[72:9];
                        cw_keep <= fdout[8:1];
                        cw_last <= fdout[0];
                        cw_len  <= popc8(fdout[8:1]);
                        plen    <= 16'd0;
                        state   <= S_DATA;
                    end else begin
                        state <= S_IDLE;          // 保险 (S_IDLE 已查非空)
                    end
                end
                // ---------------------------------------------------
                S_DATA: begin
                    if ((cw_len == 4'd0) || (!cw_last && (cw_keep != 8'hFF))) begin
                        // 防御: 违反源约定 (tkeep=0, 或非末字却非满对齐) ⇒ 按中止处理, 绝不发垃圾
                        state <= S_ABORT;
                        stat_abort    <= stat_abort + 32'd1;
                        stat_tx_short <= stat_tx_short + 32'd1;
                    end else if (cw_last) begin
                        // 末内容字: FCS 本拍结清 (crc_nxt 含本字), 与内容/pad 合并成同一拍发出
                        m_fcs  <= lw_fcs;
                        m_clen <= (lw_L >= ETH_MIN_CLEN) ? lw_L : ETH_MIN_CLEN;
                        if (lw_pr != 6'd0) begin
                            m_dhere    <= 4'd0;
                            m_pad_left <= lw_pr;
                            state      <= S_TAIL0;
                        end else if (lw_ts <= 5'd3) begin
                            m_idle <= 5'd3 - lw_ts;      // /T/ 已在本字里
                            state  <= S_IFG;
                        end else begin
                            m_tptr <= 5'd8 - lw_ts;      // 尾字接着发
                            m_idle <= 5'd0;
                            state  <= S_TAIL1;
                        end
                    end else if (!fempty) begin
                        // 还有下一字: 同拍捕获 + 弹出 (dout 就是本拍的头字)
                        cw_data <= fdout[72:9];
                        cw_keep <= fdout[8:1];
                        cw_last <= fdout[0];
                        cw_len  <= popc8(fdout[8:1]);
                        plen    <= plen + {12'd0, cw_len};
                    end else begin
                        // 断供 ⇒ 中止 (runt): 下一拍补一个 /T/ 把帧结掉
                        state <= S_ABORT;
                        stat_abort    <= stat_abort + 32'd1;
                        stat_tx_short <= stat_tx_short + 32'd1;
                    end
                end
                // ---------------------------------------------------
                // 纯 pad 续字 (只在 pad 超过末内容字容量时进入)
                S_TAIL0: begin
                    if (p0_rst != 6'd0) begin
                        m_dhere    <= 4'd0;
                        m_pad_left <= p0_rst;
                    end else if (p0_ts <= 5'd3) begin
                        m_idle <= 5'd3 - p0_ts;
                        state  <= S_IFG;
                    end else begin
                        m_tptr <= 5'd8 - p0_ts;
                        m_idle <= 5'd0;
                        state  <= S_TAIL1;
                    end
                end
                // ---------------------------------------------------
                // 尾字: FCS 尾 + /T/ + /I/ (一次 8 字符)
                S_TAIL1: begin
                    m_idle <= t1_idle;
                    m_tptr <= m_tptr + 4'd8;
                    state  <= S_IFG;
                end
                // ---------------------------------------------------
                // IFG: 发 idle 字直到 /T/ 之后 >= 12 个 /I/
                S_IFG: begin
                    if (m_idle + 5'd8 >= ETH_IFG_IDLE) begin
                        stat_frames      <= stat_frames + 32'd1;
                        dbg_tx_last_clen <= m_clen;
                        state <= fempty ? S_IDLE : S_PRE;   // 够 IFG 了: 可立刻发下一帧前导
                    end else begin
                        m_idle <= m_idle + 5'd8;
                    end
                end
                // ---------------------------------------------------
                // 中止结帧: 一个 [T][I]x7 字 (一个字都不再带数据)
                S_ABORT: begin
                    state <= S_FLUSH; flush_cnt <= 4'd0; flush_tl <= 1'b0;
                end
                // ---------------------------------------------------
                // F-2 冲刷 (判据与 1G 版同构: 本拍弹的正是 TLAST 字 ⇒ 同拍停请求)
                S_FLUSH: begin
                    if (flush_cnt != 4'd12) flush_cnt <= flush_cnt + 4'd1;
                    if (frd) stat_flush_words <= stat_flush_words + 32'd1;
                    if (frd && fdout[0]) flush_tl <= 1'b1;
                    if (flush_tl && (flush_cnt == 4'd12)) begin
                        state <= S_IDLE;
                        stat_flush_done <= stat_flush_done + 32'd1;
                    end
                end
                default: state <= S_IDLE;
            endcase

            dbg_tx_state <= (state == S_FLUSH) ? 2'd3 :
                            (state == S_ABORT) ? 2'd2 :
                            (state == S_IDLE)  ? 2'd0 : 2'd1;
        end
    end

endmodule
