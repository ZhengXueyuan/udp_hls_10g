`timescale 1ns/1ps
// ===========================================================================
// tb_app_rx8_equiv.v —— Stage B / R1 (TCP app `app_pattern` 的 **RX 8 路并行**)
//                       的**逐字节等价门** (自检式, 无 Python 依赖)
// ---------------------------------------------------------------------------
// 同一个 TB 用两种宏编译 (bat 里切), 两次的 dump/stats 文件逐字节 diff:
//     A) 无宏        = 改造前的 RTL (RX 逐字节比对: 1 取值 + 8 比对 = 9 拍/满字)
//     B) -d P7B_10G  = 8 路 RX (满字 1 拍比完 8 lane)
// ⇒ 判据是**文件对比**, 不是"我说等价"。
//
// 本门看住的东西 (R1 只动 RX; TX 一字未动 ⇒ 顺带对照 TX 逐字节不变):
//   1) TX 侧: 同一会话 (ev_up -> 21 帧 / 30000 B) 的**载荷字节流 + 每帧字节数** dump
//      ⇒ A/B 必须逐字节相同 (证 ifdef 块的函数/线网没有扰动 TX 路径)。
//   2) RX 侧: 每个实例被**接受**的字流 (tdata/tkeep, 按握手拍记录) dump
//      ⇒ A/B 必须逐字节相同 (只有真握手才推进队列 ⇒ 丢字/重字/乱序都会显形)。
//   3) RX 侧计数: stat_rx_bytes / stat_mismatch —— 与 TB 自己的**顺序模型**对账,
//      并写进 stats.txt 让 A/B 逐字节比。
//   4) 边界: 段长 0/1/5/8/9/1460/1472/2000 (>PLEN_MAX 的"超长"尺度) 同一条队列。
//   5) 注入: 满字 lane 翻位必须恰计 1; 尾字**无效 lane**翻位必须不抓; 同一字两 lane
//      翻位记 2; 整字取反记 8; 尾字有效 lane 翻位记 1; 0 长字记 0。
//   6) 拍/段: 连续 1460B 段流 (零间隙) 的**每段拍数** —— 预期 wide 187 / 默认 1643
//      (= 182 满字 + 1 个 4B 尾字; 宽路径把那级"取值气泡"吸收掉)。
// 反例 (由 bat 驱动, 见 make_negctl_rx8.py): 三个 RX 侧变异件必须让本门变红。
// ⚠️ 打印出来的字符串一律 ASCII (xsim 把中文写成 0xFF 填充, 日志不可读)。
// ===========================================================================
module tb_app_rx8_equiv;
    reg clk, rst_n;
    initial clk = 1'b0;
    always #3.2 clk = ~clk;                 // 6.4 ns = 156.25 MHz

    localparam [63:0]  SEED = 64'h9E3779B97F4A7C15;
    localparam integer QCAP = 2048;         // 每实例队列上限 (最长队列 989 字)
    localparam integer CY_TOT = 70000;      // 总预算 (默认构建的 TX 会话 + 测速都要够)
    localparam integer CAP_TX = 12000;      // TX 载荷 dump 上限 (字节)
    localparam integer RSEG  = 20;          // 测速段数
    localparam integer SEGL  = 1460;        // 段长 (字节)
    localparam integer SEGW  = 183;         // 每段字数 (182 满字 + 1 个 4B 尾字)
    localparam integer M1W   = SEGW + 1;            // 段 2 首字 (1-based): 184
    localparam integer M2W   = SEGW * (RSEG + 1) + 1; // 段 22 首字: 3844

    // -----------------------------------------------------------------------
    // 顺序模型 (先取后推进; 与 peer.cpp / 实机同一递推) —— TB 的独立参照
    // -----------------------------------------------------------------------
    function [63:0] xs_next;
        input [63:0] s;  reg [63:0] t;
        begin t = s ^ (s << 13); t = t ^ (t >> 7); t = t ^ (t << 17); xs_next = t; end
    endfunction
    function [3:0] pop8;
        input [7:0] v;  integer i;  reg [3:0] c;
        begin c = 4'd0; for (i = 0; i < 8; i = i + 1) c = c + {3'b0, v[i]}; pop8 = c; end
    endfunction
    function [7:0] kmask;
        input [3:0] n;
        begin
            case (n)
                4'd0: kmask = 8'h00;  4'd1: kmask = 8'h80;  4'd2: kmask = 8'hC0;
                4'd3: kmask = 8'hE0;  4'd4: kmask = 8'hF0;  4'd5: kmask = 8'hF8;
                4'd6: kmask = 8'hFC;  4'd7: kmask = 8'hFE;  default: kmask = 8'hFF;
            endcase
        end
    endfunction
    function [63:0] ljust8;
        input [63:0] s; input [3:0] n;
        begin
            case (n)
                4'd1: ljust8 = {s[7:0],   56'b0};
                4'd2: ljust8 = {s[15:0],  48'b0};
                4'd3: ljust8 = {s[23:0],  40'b0};
                4'd4: ljust8 = {s[31:0],  32'b0};
                4'd5: ljust8 = {s[39:0],  24'b0};
                4'd6: ljust8 = {s[47:0],  16'b0};
                4'd7: ljust8 = {s[55:0],   8'b0};
                default: ljust8 = s;
            endcase
        end
    endfunction

    // =======================================================================
    // 实例 1: TX 会话 (只发不收) —— 对照 TX 逐字节不变
    // =======================================================================
    reg         t_ev_up;
    reg         t_rdy_r;
    wire [15:0] t_bpr = {15'b0, t_rdy_r};         // app_tx_ready[0]
    wire [63:0] t_d;  wire [7:0] t_k;  wire t_v, t_l;
    wire [31:0] t_txb, t_txf, t_badf;
    wire        t_done;
    wire        t_tr = t_v && t_rdy_r;

    reg [15:0] bp;
    reg [1:0]  est;
    always @(posedge clk) begin
        if (!rst_n) begin bp <= 16'hACE1; est <= 2'd0; t_ev_up <= 1'b0; end
        else begin
            bp <= {bp[14:0], bp[15] ^ bp[13] ^ bp[12] ^ bp[10]};   // ~6% 拉低
            est <= (est == 2'd3) ? 2'd3 : (est + 2'd1);            // 饱和 ⇒ 单脉冲
            t_ev_up <= (est == 2'd1);          // 复位后第 2 拍的单脉冲 (NBA, 无竞争)
        end
    end
    always @(posedge clk) if (!rst_n) t_rdy_r <= 1'b1; else t_rdy_r <= (bp[3:0] != 4'h0);

    app_pattern #(.TX_BYTES(32'd30000), .TX_SEGSZ(12'd1460), .BAD_LEN(12'd2000),
                  .SEED(SEED), .AUTO_CLOSE(1'b1)) u_tx (
        .clk(clk), .rst_n(rst_n),
        .ev_up(t_ev_up), .ev_down(1'b0), .ev_slot(4'd0),
        .m_tdata(t_d), .m_tkeep(t_k), .m_tvalid(t_v), .m_tready(t_rdy_r),
        .m_tlast(t_l), .m_tid(),
        .app_tx_ready(t_bpr), .close_req(), .close_id(),
        .rx_tdata(64'd0), .rx_tkeep(8'h00), .rx_tvalid(1'b0), .rx_tready(),
        .rx_tlast(1'b0), .rx_tid(4'd0),
        .i_bad_frame(16'd0),
        .stat_tx_bytes(t_txb), .stat_tx_frames(t_txf), .stat_bad_frames(t_badf),
        .stat_rx_bytes(), .stat_mismatch(),
        .active(), .act_id(), .done(t_done), .dbg_lfsr(), .led()
    );

    // =======================================================================
    // 实例 2..5: RX 只收 (队列驱动; 队列由 TB 的顺序模型造)
    //   u_rx0 = 边界扫描队列 (字间 ~4 拍间隙)
    //   u_rx1 = **同一条队列**, 零间隙 (两种节奏下都必须等价)
    //   u_i0  = 满字 lane 注入
    //   u_i1  = 尾字有效/无效 lane 注入 + 整字取反
    //   u_ev  = **每连接复位 (ev_up) 撞车**: ev_up 恰好压在第 4 次握手那一拍
    //           (前 3 个字 = 旧流 A, 第 4 个字起 = 从 SEED 重开的新流 B)
    //           ⇒ 判据 rxb=36 / mm=0 要求"复位拍真的生效且与串行路径同行为"。
    // =======================================================================
    reg [63:0] q0_d [0:QCAP-1];  reg [7:0] q0_k [0:QCAP-1];  integer q0_n, q0_p;
    reg [63:0] q1_d [0:QCAP-1];  reg [7:0] q1_k [0:QCAP-1];  integer q1_n, q1_p;
    reg [63:0] q2_d [0:QCAP-1];  reg [7:0] q2_k [0:QCAP-1];  integer q2_n, q2_p;
    reg [63:0] q3_d [0:QCAP-1];  reg [7:0] q3_k [0:QCAP-1];  integer q3_n, q3_p;
    reg [63:0] q4_d [0:QCAP-1];  reg [7:0] q4_k [0:QCAP-1];  integer q4_n, q4_p;
    reg d0_dr, d1_dr, d2_dr, d3_dr, d4_dr;
    reg [3:0] g0, g2, g3, g4;
    reg [3:0] ev_n;
    wire r0_tr, r1_tr, r2_tr, r3_tr, r4_tr;
    wire [31:0] r0_rxb, r0_mm, r1_rxb, r1_mm, r2_rxb, r2_mm, r3_rxb, r3_mm, r4_rxb, r4_mm;
    wire h0 = d0_dr & r0_tr, h1 = d1_dr & r1_tr, h2 = d2_dr & r2_tr, h3 = d3_dr & r3_tr;
    wire h4 = d4_dr & r4_tr;
    wire ev4_up = (ev_n == 4'd3) && h4;      // 组合脉冲: 与"第 4 次握手"同拍
    always @(posedge clk) begin
        if (!rst_n) ev_n <= 4'd0;
        else if (h4) ev_n <= ev_n + 4'd1;
    end

    app_pattern #(.TX_BYTES(32'd0), .TX_SEGSZ(12'd1460), .SEED(SEED), .AUTO_CLOSE(1'b1))
    u_rx0 (.clk(clk), .rst_n(rst_n), .ev_up(1'b0), .ev_down(1'b0), .ev_slot(4'd0),
        .m_tdata(), .m_tkeep(), .m_tvalid(), .m_tready(1'b1), .m_tlast(), .m_tid(),
        .app_tx_ready(16'd0), .close_req(), .close_id(),
        .rx_tdata(q0_d[q0_p]), .rx_tkeep(q0_k[q0_p]), .rx_tvalid(d0_dr), .rx_tready(r0_tr),
        .rx_tlast(1'b0), .rx_tid(4'd0), .i_bad_frame(16'd0),
        .stat_tx_bytes(), .stat_tx_frames(), .stat_bad_frames(),
        .stat_rx_bytes(r0_rxb), .stat_mismatch(r0_mm),
        .active(), .act_id(), .done(), .dbg_lfsr(), .led());

    app_pattern #(.TX_BYTES(32'd0), .TX_SEGSZ(12'd1460), .SEED(SEED), .AUTO_CLOSE(1'b1))
    u_rx1 (.clk(clk), .rst_n(rst_n), .ev_up(1'b0), .ev_down(1'b0), .ev_slot(4'd0),
        .m_tdata(), .m_tkeep(), .m_tvalid(), .m_tready(1'b1), .m_tlast(), .m_tid(),
        .app_tx_ready(16'd0), .close_req(), .close_id(),
        .rx_tdata(q1_d[q1_p]), .rx_tkeep(q1_k[q1_p]), .rx_tvalid(d1_dr), .rx_tready(r1_tr),
        .rx_tlast(1'b0), .rx_tid(4'd0), .i_bad_frame(16'd0),
        .stat_tx_bytes(), .stat_tx_frames(), .stat_bad_frames(),
        .stat_rx_bytes(r1_rxb), .stat_mismatch(r1_mm),
        .active(), .act_id(), .done(), .dbg_lfsr(), .led());

    app_pattern #(.TX_BYTES(32'd0), .TX_SEGSZ(12'd1460), .SEED(SEED), .AUTO_CLOSE(1'b1))
    u_i0 (.clk(clk), .rst_n(rst_n), .ev_up(1'b0), .ev_down(1'b0), .ev_slot(4'd0),
        .m_tdata(), .m_tkeep(), .m_tvalid(), .m_tready(1'b1), .m_tlast(), .m_tid(),
        .app_tx_ready(16'd0), .close_req(), .close_id(),
        .rx_tdata(q2_d[q2_p]), .rx_tkeep(q2_k[q2_p]), .rx_tvalid(d2_dr), .rx_tready(r2_tr),
        .rx_tlast(1'b0), .rx_tid(4'd0), .i_bad_frame(16'd0),
        .stat_tx_bytes(), .stat_tx_frames(), .stat_bad_frames(),
        .stat_rx_bytes(r2_rxb), .stat_mismatch(r2_mm),
        .active(), .act_id(), .done(), .dbg_lfsr(), .led());

    app_pattern #(.TX_BYTES(32'd0), .TX_SEGSZ(12'd1460), .SEED(SEED), .AUTO_CLOSE(1'b1))
    u_i1 (.clk(clk), .rst_n(rst_n), .ev_up(1'b0), .ev_down(1'b0), .ev_slot(4'd0),
        .m_tdata(), .m_tkeep(), .m_tvalid(), .m_tready(1'b1), .m_tlast(), .m_tid(),
        .app_tx_ready(16'd0), .close_req(), .close_id(),
        .rx_tdata(q3_d[q3_p]), .rx_tkeep(q3_k[q3_p]), .rx_tvalid(d3_dr), .rx_tready(r3_tr),
        .rx_tlast(1'b0), .rx_tid(4'd0), .i_bad_frame(16'd0),
        .stat_tx_bytes(), .stat_tx_frames(), .stat_bad_frames(),
        .stat_rx_bytes(r3_rxb), .stat_mismatch(r3_mm),
        .active(), .act_id(), .done(), .dbg_lfsr(), .led());

    app_pattern #(.TX_BYTES(32'd0), .TX_SEGSZ(12'd1460), .SEED(SEED), .AUTO_CLOSE(1'b1))
    u_ev (.clk(clk), .rst_n(rst_n), .ev_up(ev4_up), .ev_down(1'b0), .ev_slot(4'd0),
        .m_tdata(), .m_tkeep(), .m_tvalid(), .m_tready(1'b1), .m_tlast(), .m_tid(),
        .app_tx_ready(16'd0), .close_req(), .close_id(),
        .rx_tdata(q4_d[q4_p]), .rx_tkeep(q4_k[q4_p]), .rx_tvalid(d4_dr), .rx_tready(r4_tr),
        .rx_tlast(1'b0), .rx_tid(4'd0), .i_bad_frame(16'd0),
        .stat_tx_bytes(), .stat_tx_frames(), .stat_bad_frames(),
        .stat_rx_bytes(r4_rxb), .stat_mismatch(r4_mm),
        .active(), .act_id(), .done(), .dbg_lfsr(), .led());

    // 队列驱动: 只有**真握手**才推进 (tvalid 期间数据保持不动 = AXIS 合同; 全部 NBA)
    always @(posedge clk) begin
        if (!rst_n) begin d0_dr <= 1'b0; g0 <= 4'd0; q0_p <= 0; end
        else if (q0_p < q0_n) begin
            if (d0_dr) begin
                if (r0_tr) begin q0_p <= q0_p + 1; d0_dr <= 1'b0; end
            end else if (g0 != 4'd0) g0 <= g0 - 4'd1;
            else d0_dr <= 1'b1;
        end else d0_dr <= 1'b0;
    end
    always @(posedge clk) begin                    // 零间隙
        if (!rst_n) begin d1_dr <= 1'b0; q1_p <= 0; end
        else if (q1_p < q1_n) begin
            if (d1_dr) begin if (r1_tr) begin q1_p <= q1_p + 1;
                d1_dr <= ((q1_p + 1) < q1_n); end end     // 队尾不得多推一个字
            else d1_dr <= 1'b1;
        end else d1_dr <= 1'b0;
    end
    always @(posedge clk) begin
        if (!rst_n) begin d2_dr <= 1'b0; g2 <= 4'd0; q2_p <= 0; end
        else if (q2_p < q2_n) begin
            if (d2_dr) begin
                if (r2_tr) begin q2_p <= q2_p + 1; d2_dr <= 1'b0; g2 <= 4'd2; end
            end else if (g2 != 4'd0) g2 <= g2 - 4'd1;
            else d2_dr <= 1'b1;
        end else d2_dr <= 1'b0;
    end
    always @(posedge clk) begin
        if (!rst_n) begin d3_dr <= 1'b0; g3 <= 4'd0; q3_p <= 0; end
        else if (q3_p < q3_n) begin
            if (d3_dr) begin
                if (r3_tr) begin q3_p <= q3_p + 1; d3_dr <= 1'b0; g3 <= 4'd1; end
            end else if (g3 != 4'd0) g3 <= g3 - 4'd1;
            else d3_dr <= 1'b1;
        end else d3_dr <= 1'b0;
    end
    always @(posedge clk) begin                    // u_ev (有间隙 ⇒ 握手拍唯一)
        if (!rst_n) begin d4_dr <= 1'b0; g4 <= 4'd0; q4_p <= 0; end
        else if (q4_p < q4_n) begin
            if (d4_dr) begin
                if (r4_tr) begin q4_p <= q4_p + 1; d4_dr <= 1'b0; g4 <= 4'd1; end
            end else if (g4 != 4'd0) g4 <= g4 - 4'd1;
            else d4_dr <= 1'b1;
        end else d4_dr <= 1'b0;
    end

    // =======================================================================
    // 实例 6: 测速 (连续 1460B 段流, 零间隙; 字在握手拍现生成)
    // =======================================================================
    wire rt_rate;                                  // DUT 的 rx_tready
    reg [63:0] rs;                                 // 生成器/模型状态
    reg [63:0] gw_d;  reg [7:0] gw_k;              // gen_word 的暂存 (非 DUT-facing)
    integer    rl_n;                               // 本字取完后本段剩余
    integer    r_left;                             // 本段剩余字节
    integer    r_widx, r_bytes;
    reg [63:0] r_d;  reg [7:0] r_k;  reg r_dr;
    reg        r_stop;
    reg [31:0] cyc;
    integer    m1_cyc, m2_cyc;
    wire       r_rate_tr = r_dr & rt_rate;
    wire [31:0] rate_rxb, rate_mm;

    app_pattern #(.TX_BYTES(32'd0), .TX_SEGSZ(12'd1460), .SEED(SEED), .AUTO_CLOSE(1'b1))
    u_rate (.clk(clk), .rst_n(rst_n), .ev_up(1'b0), .ev_down(1'b0), .ev_slot(4'd0),
        .m_tdata(), .m_tkeep(), .m_tvalid(), .m_tready(1'b1), .m_tlast(), .m_tid(),
        .app_tx_ready(16'd0), .close_req(), .close_id(),
        .rx_tdata(r_d), .rx_tkeep(r_k), .rx_tvalid(r_dr), .rx_tready(rt_rate),
        .rx_tlast(1'b0), .rx_tid(4'd0), .i_bad_frame(16'd0),
        .stat_tx_bytes(), .stat_tx_frames(), .stat_bad_frames(),
        .stat_rx_bytes(rate_rxb), .stat_mismatch(rate_mm),
        .active(), .act_id(), .done(), .dbg_lfsr(), .led());

    task gen_word;                                 // 从 rs 取 n 字节并推进 rs
        input [3:0] n;  output [63:0] d;  output [7:0] k;
        integer i;  reg [63:0] t;
        begin
            t = 64'd0;
            for (i = 0; i < 8; i = i + 1)
                if (i < n) begin t = {t[55:0], rs[31:24]}; rs = xs_next(rs); end
            d = ljust8(t, n);
            k = kmask(n);
        end
    endtask

    always @(posedge clk) begin
        cyc <= cyc + 32'd1;
        if (!rst_n) begin
            r_dr <= 1'b0; r_left <= SEGL; r_widx <= 0; r_bytes <= 0; r_stop <= 1'b0;
            rs <= SEED;
        end else if (!r_stop) begin
            if (!r_dr) begin
                gen_word((r_left >= 8) ? 4'd8 : r_left[3:0], gw_d, gw_k);
                r_d <= gw_d;  r_k <= gw_k;  r_dr <= 1'b1;      // NBA -> 无竞争
            end else if (r_rate_tr) begin
                r_widx  <= r_widx + 1;
                r_bytes <= r_bytes + pop8(r_k);
                // 测速标记: 段 2 首字 与 段 (RSEG+2) 首字 (1-based 字数)
                if ((r_widx + 1) == M1W) m1_cyc <= cyc;
                if ((r_widx + 1) == M2W) begin
                    m2_cyc <= cyc;
                    r_stop <= 1'b1;  r_dr <= 1'b0;   // 立即停: 不再呈现下一个字
                end else begin
                    rl_n = r_left - pop8(r_k);
                    if (rl_n == 0) begin                        // 本字 = 段尾字
                        r_left <= SEGL;
                        gen_word(4'd8, gw_d, gw_k);
                    end else begin
                        r_left <= rl_n;
                        gen_word((rl_n >= 8) ? 4'd8 : rl_n[3:0], gw_d, gw_k);
                    end
                    r_d <= gw_d;  r_k <= gw_k;
                end
            end
        end else r_dr <= 1'b0;
    end

    // =======================================================================
    // dump: TX 载荷字节 + 每帧字节数; 每个 RX 实例的**接受字流**
    // =======================================================================
    integer f_txd, f_txf, f_w0, f_w1, f_w2, f_w3, f_w4, f_stats, f_rate;
    integer tx_cnt, tx_frm_cur, tx_frm_rec;
    reg     tx_full;
    integer w0_cnt, w1_cnt, w2_cnt, w3_cnt, w4_cnt;

    task tx_dump;
        input [63:0] d;  input [7:0] k;  input last;
        integer i, n;  reg [7:0] b;
        begin
            n = pop8(k);
            for (i = 0; i < n; i = i + 1)
                if (tx_cnt < CAP_TX) begin
                    case (i[2:0])
                        3'd0: b = d[63:56];  3'd1: b = d[55:48];
                        3'd2: b = d[47:40];  3'd3: b = d[39:32];
                        3'd4: b = d[31:24];  3'd5: b = d[23:16];
                        3'd6: b = d[15:8];   default: b = d[7:0];
                    endcase
                    $fwrite(f_txd, "%02x", b);
                    tx_cnt = tx_cnt + 1;
                    if ((tx_cnt % 32) == 0) $fwrite(f_txd, "\n");
                end
            tx_frm_cur = tx_frm_cur + n;
            if (last) begin
                if (!tx_full) begin
                    $fwrite(f_txf, "%0d\n", tx_frm_cur);
                    tx_frm_rec = tx_frm_rec + 1;
                    if (tx_cnt >= CAP_TX) tx_full = 1'b1;
                end
                tx_frm_cur = 0;
            end
        end
    endtask

    always @(posedge clk) begin
        if (rst_n) begin
            if (t_tr) tx_dump(t_d, t_k, t_l);
            if (h0) begin $fwrite(f_w0, "%08x_%08x %02x\n", q0_d[q0_p][63:32], q0_d[q0_p][31:0], q0_k[q0_p]); w0_cnt = w0_cnt + 1; end
            if (h1) begin $fwrite(f_w1, "%08x_%08x %02x\n", q1_d[q1_p][63:32], q1_d[q1_p][31:0], q1_k[q1_p]); w1_cnt = w1_cnt + 1; end
            if (h2) begin $fwrite(f_w2, "%08x_%08x %02x\n", q2_d[q2_p][63:32], q2_d[q2_p][31:0], q2_k[q2_p]); w2_cnt = w2_cnt + 1; end
            if (h3) begin $fwrite(f_w3, "%08x_%08x %02x\n", q3_d[q3_p][63:32], q3_d[q3_p][31:0], q3_k[q3_p]); w3_cnt = w3_cnt + 1; end
            if (h4) begin $fwrite(f_w4, "%08x_%08x %02x\n", q4_d[q4_p][63:32], q4_d[q4_p][31:0], q4_k[q4_p]); w4_cnt = w4_cnt + 1; end
        end
    end

    // =======================================================================
    // 造队列 (顺序模型; 全在 time 0 之内完成)
    // =======================================================================
    reg [63:0] m_lfsr;

    task put_word;
        input integer w;  input [63:0] d;  input [7:0] k;
        begin
            case (w)
                0: begin q0_d[q0_n] = d; q0_k[q0_n] = k; q0_n = q0_n + 1; end
                1: begin q1_d[q1_n] = d; q1_k[q1_n] = k; q1_n = q1_n + 1; end
                2: begin q2_d[q2_n] = d; q2_k[q2_n] = k; q2_n = q2_n + 1; end
                3: begin q3_d[q3_n] = d; q3_k[q3_n] = k; q3_n = q3_n + 1; end
                default: begin q4_d[q4_n] = d; q4_k[q4_n] = k; q4_n = q4_n + 1; end
            endcase
        end
    endtask

    task mk_seg;                                   // len 字节 -> 若干字 (len=0 -> tkeep=0 字)
        input integer w;  input integer len;
        integer l, i;  reg [63:0] d;  reg [3:0] n;
        begin
            l = len;
            if (l == 0) put_word(w, 64'd0, 8'h00);
            else while (l > 0) begin
                n = (l >= 8) ? 4'd8 : l[3:0];
                d = 64'd0;
                for (i = 0; i < 8; i = i + 1)
                    if (i < n) begin d = {d[55:0], m_lfsr[31:24]}; m_lfsr = xs_next(m_lfsr); end
                if (n != 4'd8) d = ljust8(d, n);
                put_word(w, d, kmask(n));
                l = l - n;
            end
        end
    endtask

    // =======================================================================
    // 判据累加
    // =======================================================================
    integer errs;
    task chk;
        input cond;  input [1023:0] msg;
        begin
            if (!cond) begin errs = errs + 1; $display("  [FAIL] %0s", msg); end
            else         $display("  [ ok ] %0s", msg);
        end
    endtask

    integer i;
    integer dcyc;

    initial begin
        errs = 0; rst_n = 1'b0;
        t_rdy_r = 1'b1; bp = 16'hACE1; est = 2'd0; t_ev_up = 1'b0;
        q0_n = 0; q0_p = 0; q1_n = 0; q1_p = 0; q2_n = 0; q2_p = 0; q3_n = 0; q3_p = 0;
        q4_n = 0; q4_p = 0;
        d0_dr = 0; d1_dr = 0; d2_dr = 0; d3_dr = 0; d4_dr = 0;
        g0 = 0; g2 = 0; g3 = 0; g4 = 0; ev_n = 0;
        tx_cnt = 0; tx_frm_cur = 0; tx_frm_rec = 0; tx_full = 0;
        w0_cnt = 0; w1_cnt = 0; w2_cnt = 0; w3_cnt = 0; w4_cnt = 0;
        cyc = 0; r_widx = 0; r_bytes = 0; r_left = SEGL; r_stop = 0; r_dr = 0;
        rs = SEED; m1_cyc = 0; m2_cyc = 0;

        // ---- 1) 边界扫描队列 (u_rx0 与 u_rx1 用同一条) ----
        m_lfsr = SEED;
        mk_seg(0, 1460);  mk_seg(0, 1460);  mk_seg(0, 1460);   // 板级同构
        mk_seg(0,    8);                                       // 恰一个满字
        mk_seg(0,    9);                                       // 满字 + 1B 尾字
        mk_seg(0,    1);                                       // 全尾字
        mk_seg(0,    5);                                       // 尾字 5B
        mk_seg(0, 1472);                                       // 8 的倍数
        mk_seg(0, 2000);                                       // 超长尺度
        mk_seg(0,    0);                                       // 0 长字
        $display("  [info] boundary queue: %0d words / 7875 bytes (u_rx0/u_rx1 shared)", q0_n);
        for (i = 0; i < q0_n; i = i + 1) begin q1_d[i] = q0_d[i]; q1_k[i] = q0_k[i]; end
        q1_n = q0_n;

        // ---- 2) 满字 lane 注入 (u_i0) ----
        m_lfsr = SEED;
        mk_seg(2, 8);                                          // w0 clean
        mk_seg(2, 8);  q2_d[1] = q2_d[1] ^ 64'h0000_0100_0000_0000;   // w1 lane1 (bit48) -> 1
        mk_seg(2, 8);                                          // w2 clean
        mk_seg(2, 8);  q2_d[3] = q2_d[3] ^ 64'h0000_0000_0000_0010;   // w3 lane7 (bit1)  -> 1
        mk_seg(2, 8);  q2_d[4] = q2_d[4] ^ 64'h0000_0001_0000_0001;   // w4 lane3+lane7  -> 2
        mk_seg(2, 8);                                          // w5 clean
        $display("  [info] u_i0: %0d words, expect bytes=48 mm=4", q2_n);

        // ---- 3) 尾字/无效 lane/整字取反 (u_i1) ----
        m_lfsr = SEED;
        mk_seg(3, 3);  q3_d[0] = q3_d[0] ^ 64'h0000_0100_0000_0000;   // w0 3B lane2 有效 -> 1
        mk_seg(3, 3);  q3_d[1] = q3_d[1] ^ 64'h0000_0000_0010_0000;   // w1 3B lane5 无效 -> 0
        mk_seg(3, 3);  q3_d[2] = q3_d[2] ^ 64'h0000_0000_0000_0001;   // w2 3B lane7 无效 -> 0
        mk_seg(3, 1);  q3_d[3] = q3_d[3] ^ 64'h0100_0000_0000_0000;   // w3 1B lane0 有效 -> 1
        mk_seg(3, 8);  q3_d[4] = q3_d[4] ^ 64'h0000_0000_1000_0000;   // w4 满字 lane4     -> 1
        mk_seg(3, 0);                                                 // w5 0 长字         -> 0
        mk_seg(3, 8);  q3_d[6] = ~q3_d[6];                            // w6 整字取反       -> 8
        $display("  [info] u_i1: %0d words, expect bytes=26 mm=11", q3_n);

        // ---- 4) ev_up 撞车 (u_ev): 前 3 字 = 流 A, 第 4 字起 = 从 SEED 重开的流 B ----
        m_lfsr = SEED;
        mk_seg(4, 8);  mk_seg(4, 8);  mk_seg(4, 8);        // 流 A (旧会话)
        m_lfsr = SEED;                                     // 模型重开 (新会话起点)
        mk_seg(4, 8);  mk_seg(4, 4);                       // 流 B (第 4 次握手那一字起)
        $display("  [info] u_ev: %0d words, expect bytes=36 mm=0 (ev_up on 4th handshake)", q4_n);

        f_txd = $fopen("dump_tx.hex", "w");   f_txf = $fopen("dump_tx.frm", "w");
        f_w0  = $fopen("acc_w0.txt", "w");    f_w1  = $fopen("acc_w1.txt", "w");
        f_w2  = $fopen("acc_w2.txt", "w");    f_w3  = $fopen("acc_w3.txt", "w");
        f_w4  = $fopen("acc_w4.txt", "w");
        f_stats = $fopen("stats.txt", "w");   f_rate = $fopen("rate.txt", "w");

        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (CY_TOT) @(posedge clk);

        // ================= 收口 =================
        $fclose(f_txd);  $fclose(f_txf);
        $fclose(f_w0);   $fclose(f_w1);   $fclose(f_w2);   $fclose(f_w3);  $fclose(f_w4);
        dcyc = m2_cyc - m1_cyc;

        $display("  TX : frames=%0d bytes=%0d done=%0d | dump=%0d frm_rec=%0d",
                 t_txf, t_txb, t_done, tx_cnt, tx_frm_rec);
        $display("  RX0: rxb=%0d mm=%0d acc=%0d/%0d", r0_rxb, r0_mm, w0_cnt, q0_n);
        $display("  RX1: rxb=%0d mm=%0d acc=%0d/%0d", r1_rxb, r1_mm, w1_cnt, q1_n);
        $display("  I0 : rxb=%0d mm=%0d acc=%0d/%0d", r2_rxb, r2_mm, w2_cnt, q2_n);
        $display("  I1 : rxb=%0d mm=%0d acc=%0d/%0d", r3_rxb, r3_mm, w3_cnt, q3_n);
        $display("  EV : rxb=%0d mm=%0d acc=%0d/%0d ev_n=%0d", r4_rxb, r4_mm, w4_cnt, q4_n, ev_n);
        $display("  RATE: words=%0d bytes=%0d rxb=%0d mm=%0d | dcyc=%0d over %0d segs = %0d.%03d cyc/seg",
                 r_widx, r_bytes, rate_rxb, rate_mm, dcyc, RSEG,
                 dcyc * 100 / RSEG / 100, (dcyc * 100 / RSEG) % 100 * 10);

        $fwrite(f_stats, "TX frames=%0d bytes=%0d done=%0d dump=%0d frm_rec=%0d\n",
                t_txf, t_txb, t_done, tx_cnt, tx_frm_rec);
        $fwrite(f_stats, "RX0 rxb=%0d mm=%0d acc=%0d\n", r0_rxb, r0_mm, w0_cnt);
        $fwrite(f_stats, "RX1 rxb=%0d mm=%0d acc=%0d\n", r1_rxb, r1_mm, w1_cnt);
        $fwrite(f_stats, "I0 rxb=%0d mm=%0d acc=%0d\n", r2_rxb, r2_mm, w2_cnt);
        $fwrite(f_stats, "I1 rxb=%0d mm=%0d acc=%0d\n", r3_rxb, r3_mm, w3_cnt);
        $fwrite(f_stats, "EV rxb=%0d mm=%0d acc=%0d\n", r4_rxb, r4_mm, w4_cnt);
        $fwrite(f_stats, "RATE words=%0d bytes=%0d rxb=%0d mm=%0d segs=%0d\n",
                r_widx, r_bytes, rate_rxb, rate_mm, RSEG);
        $fclose(f_stats);
        // 拍数是**唯一**该随构建而变的读数 (wide 187 / 默认 1643 cyc/段)
        // ⇒ 单独落盘, 不进 stats.txt (stats.txt 保持"两构建必须逐字节相同")
        $fwrite(f_rate, "RATE dcyc=%0d segs=%0d cyc_per_seg=%0d\n",
                dcyc, RSEG, dcyc / RSEG);
        $fclose(f_rate);

        // ================= 判据 =================
        chk(t_txb == 32'd30000,  "TX session 30000 bytes");
        chk(t_txf == 32'd21,     "TX 21 frames (20x1460 + 800)");
        chk(t_done == 1'b1,      "TX done=1");
        chk(tx_cnt == CAP_TX,    "TX dump reached 12000 bytes");
        chk(tx_frm_rec >= 9,     "TX frame-length list >= 9 frames");
        chk(q0_p == q0_n,        "RX0 queue fully accepted (no stall)");
        chk(r0_rxb == 32'd7875,  "RX0 rx bytes 7875 (0/1/5/8/9/1460/1472/2000 boundaries)");
        chk(r0_mm  == 32'd0,     "RX0 zero mismatch");
        chk(q1_p == q1_n,        "RX1 queue fully accepted (zero gap)");
        chk(r1_rxb == 32'd7875,  "RX1 rx bytes 7875 (zero-gap)");
        chk(r1_mm  == 32'd0,     "RX1 zero mismatch");
        chk(r2_rxb == 32'd48,    "I0 rx bytes 48");
        chk(r2_mm  == 32'd4,     "I0 mismatch exactly 4 (lane1 + lane7 + two lanes)");
        chk(r3_rxb == 32'd26,    "I1 rx bytes 26 (3+3+3+1+8+0+8)");
        chk(r3_mm  == 32'd11,    "I1 mismatch exactly 11 (valid lanes caught, invalid lanes not)");
        chk(q4_p == q4_n,        "EV queue fully accepted");
        chk(r4_rxb == 32'd36,    "EV rx bytes 36 (ev_up reset did take effect at the 4th word)");
        chk(r4_mm  == 32'd0,     "EV zero mismatch (reset beat behaves same as serial path)");
        chk(rate_mm == 32'd0,    "RATE zero mismatch (continuous segments)");
        chk(rate_rxb == r_bytes, "RATE stat_rx_bytes == TB byte count");
        chk(r_widx >= M2W,       "RATE reached the measurement window");
`ifdef P7B_10G
        chk(dcyc == RSEG * 187,  "cycles/segment: wide 187 (182 full x1 + 4B tail 5)");
`else
        chk(dcyc == RSEG * 1643, "cycles/segment: default 1643 (182 full x9 + 4B tail 5)");
`endif

        if (errs == 0) $display("TB_APP_RX8_EQUIV: OK");
        else           $display("TB_APP_RX8_EQUIV: FAIL errs=%0d", errs);
        $display("TB8RX DONE");
        $finish;
    end
endmodule
