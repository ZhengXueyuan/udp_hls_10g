`timescale 1ns/1ps
//=============================================================================
// tb_cdc_bits.v -- P6b 跨域 FIFO **位级 / 字段级** 走位门 (width & field span audit)
//=============================================================================
// 审计对象 = board/wrapper_p4.v 里两个跨域 FIFO 的**实际位宽与字段接线**:
//   RX: u_rxcdc WIDTH=76 .din({tdata[63:0], tkeep[7:0], tuser, tlast, tcrs, terr})
//       => tdata 在 [W-1 -: 64] = [75:12], tkeep [11:4], tuser[3] tlast[2] tcrs[1] terr[0]
//   TX: u_txcdc WIDTH=73 .din({tdata[63:0], tkeep[7:0], tlast})
//       => tdata [72:9], tkeep [8:1], tlast[0]
// 本 TB 逐位打 walking-1 / walking-0, 再做"打包→跨域→解包→重打包"的**恒等检查**
// (该恒等同时验 数据完整 与 字段映射 两件事), 并核对守恒律。
//
// 判据 (每个实例独立; 报告行 "SPAN<tag> RESULT ..."):
//   J1 数据完整 : 收到的 raw 字 == 发出的 raw 字 (walking-1/0 覆盖每一位)   -> bad_raw
//   J2 字段映射 : 解包再打包 == 原字 (字段对调/错位/截位都在这里现形)        -> bad_map
//   J3 守恒律   : 接受写 == 弹出 == 收到字数; 且 wr_en 拍数 == 接受 + 被拒
//                 (被拒 = wr_en && full, 本 TB 一律重试 ⇒ 拒写不丢字, 但它必须可计)
//   J4 正证据   : 检查次数 > 0 且必须真的跨过 256 深度 (写指针绕回)
//
// 变异 (编译期宏; 负对照必须 FAIL):
//   MUT_W75  : FIFO 端口 /= 逻辑字宽 少 1 位 (F6 的"WIDTH 算错"反方向) ⇒ MSB 静默截断
//   MUT_SWAP : 读侧解包字段顺序对调 (编译干净, 只有 J2 能抓)
//=============================================================================
module cdc_span_chk #(
    parameter W    = 76,
    parameter TAGC = 0
)(
    input  wire        wr_clk,
    input  wire        rd_clk,
    input  wire        rst_n,
    output reg  [31:0] o_words,
    output reg  [31:0] o_bad_raw,
    output reg  [31:0] o_bad_map,
    output reg  [31:0] o_checks,
    output reg  [31:0] o_accw,
    output reg  [31:0] o_refw,
    output reg  [31:0] o_pop,
    output reg  [31:0] o_rcv
);
`ifdef MUT_W75
    localparam FWW = W - 1;          // 端口少 1 位 (变异)
`else
    localparam FWW = W;
`endif
    localparam SHD = W - 64;         // tdata 左移量 (W=76->12, W=73->9)
    localparam SHK = W - 72;         // tkeep 左移量 (W=76-> 4, W=73->1)
    localparam integer NPAT = 4*W + 16;   // > 256 ⇒ 写指针必绕回

    reg  [W-1:0]      pat_w [0:NPAT-1];
    reg  [63:0]       exp_td [0:NPAT-1];
    reg  [7:0]        exp_tk [0:NPAT-1];
    reg  [3:0]        exp_ax [0:NPAT-1];
    reg               exp_fd [0:NPAT-1];  // 1 = 字段组装的条目
    integer           i, j, k;

    // ---------------- DUT ----------------
    // 声明纪律 (本工程坑 24): 所有 reg/wire 必须先声明, 后使用
    reg  [W-1:0]      w_word;
    reg               w_v;
    wire              w_ready;
    wire [FWW-1:0]    fifo_dout;
    wire              fifo_empty, fifo_full;
    // 写域记账
    reg [31:0] idx, wacc, wref, wtry;
    // 读域消费者 + 记账
    reg  [31:0] rpop, rrcv, rbad_raw, rbad_map, rchk;
    reg         r_v;
    reg  [15:0] rc;
    reg  [31:0] seen;

    fifo_async #(.WIDTH(FWW), .DEPTH(256), .FWFT(1), .AW(8)) u_fifo (
        .wr_clk(wr_clk), .wr_rst_n(rst_n), .wr_en(w_v), .din(w_word),
        .full(fifo_full),
        .rd_clk(rd_clk), .rd_rst_n(rst_n), .rd_en(r_v && !fifo_empty),
        .dout(fifo_dout), .empty(fifo_empty),
        .dbg_wbin(), .dbg_rbin(), .dbg_wgray(), .dbg_rgray(),
        .dbg_occ_w(), .dbg_occ_r()
    );
    assign w_ready = ~fifo_full;

    // ---------------- 读侧解包 (镜像 wrapper 的 dout 拼接) ----------------
    wire [W-1:0] r_word = fifo_dout;              // 窄 dout -> 宽拼接 = 高位补 0
`ifdef MUT_SWAP
    // 变异: 字段顺序对调 (tdata <-> tkeep) —— 编译干净, 只有 J2 恒等检查能抓
    wire [63:0]  r_td_u = r_word >> SHK;
    wire [7:0]   r_tk_u = r_word >> SHD;
`else
    wire [63:0]  r_td_u = r_word >> SHD;
    wire [7:0]   r_tk_u = r_word >> SHK;
`endif
    wire [3:0]   r_ax_u = (W == 76) ? r_word[3:0] : {3'b000, r_word[0]};
    // 解包再打包 = 恒等 (正确接线时); 字段对调/错位/截位都破坏它
    wire [W-1:0] repack = (r_td_u << SHD) | (r_tk_u << SHK) | r_ax_u;

    // ---------------- 激励表 ----------------
    initial begin
        for (j = 0; j < NPAT; j = j + 1) begin
            exp_fd[j] = 1'b0; exp_td[j] = 64'd0; exp_tk[j] = 8'd0; exp_ax[j] = 4'd0;
        end
        for (k = 0; k < 2; k = k + 1) begin
            for (i = 0; i < W; i = i + 1) begin
                pat_w[k*2*W + i]       = {{(W-1){1'b0}}, 1'b1} << i;             // walking-1
                pat_w[k*2*W + W + i]   = ~({{(W-1){1'b0}}, 1'b1} << i);          // walking-0
            end
        end
        for (j = 0; j < 16; j = j + 1) begin
            exp_fd[4*W + j] = 1'b1;
            exp_td[4*W + j] = 64'h0123456789ABCDEF ^ (64'h9E3779B97F4A7C15 * j);
            exp_tk[4*W + j] = (8'h5A ^ (j * 17));
            exp_ax[4*W + j] = 4'b1010 ^ j[3:0];
            pat_w[4*W + j]  = (exp_td[4*W+j] << SHD) | (exp_tk[4*W+j] << SHK) | exp_ax[4*W+j];
        end
    end

    // ---------------- 写域驱动 ----------------
    // ⚠️ 复位释放门 (本 TB 自己先踩到的坑, 见 P6B_CDC_AUDIT F-1): fifo_async 的写域
    //    复位由**本域两级同步器**释放 ⇒ rst_n 拉高后还要 **3 个 wr_clk** 写才被承认;
    //    这期间 `full` 读 0 (复位值) 但写被**静默丢弃** ⇒ 生产者若只看 full 就会丢字。
    //    本门是**刻意**等 6 拍后再开始写 (否则测的就是那个窗口, 不是跨域功能)。
    reg  [3:0] wen_dly;
    wire       w_go = (wen_dly == 4'hF);
    always @(posedge wr_clk or negedge rst_n) begin
        if (!rst_n) wen_dly <= 4'h0;
        else if (!w_go) wen_dly <= wen_dly + 4'h1;
    end
    always @(posedge wr_clk or negedge rst_n) begin
        if (!rst_n) begin
            w_v <= 1'b0; w_word <= 0; idx <= 0; wacc <= 0; wref <= 0; wtry <= 0;
        end else begin
            if (w_v) begin
                wtry <= wtry + 32'd1;
                if (!w_ready) wref <= wref + 32'd1;      // 被拒 (本 TB 重试 ⇒ 不丢)
                else begin
                    wacc <= wacc + 32'd1;
                    idx  <= idx + 32'd1;
                    if (idx + 32'd1 < NPAT) w_word <= pat_w[idx+1];
                    else                    w_v    <= 1'b0;
                end
            end else if (w_go && (idx < NPAT)) begin
                w_word <= pat_w[idx];
                w_v    <= 1'b1;
            end else if (!w_go) begin
                w_v <= 1'b0;
            end
        end
    end

    // ---------------- 读域: 停摆/恢复型消费者 ----------------
    always @(posedge rd_clk or negedge rst_n) begin
        if (!rst_n) begin
            r_v <= 1'b0; rc <= 0; rpop <= 0; rrcv <= 0; rbad_raw <= 0; rbad_map <= 0;
            rchk <= 0; seen <= 0;
        end else begin
            rc <= rc + 16'd1;
            // 波形: 0..19 全速; 20..2499 全停 (写侧必被 256 深灌满 ⇒ 触发 full);
            //       之后 24 拍停 4 拍 (慢排空, 让 full/empty 边界被反复捶打)
            if (rc < 16'd20)        r_v <= 1'b1;
            else if (rc < 16'd2500) r_v <= 1'b0;
            else                    r_v <= ((rc % 16'd28) < 16'd4);
            if (r_v && !fifo_empty) begin
                rpop <= rpop + 32'd1;
                rrcv <= rrcv + 32'd1;
                if (seen < NPAT) begin
                    rchk <= rchk + 32'd1;
                    if (r_word !== pat_w[seen]) begin
                        rbad_raw <= rbad_raw + 32'd1;
                        if (rbad_raw < 32'd4)
                            $display("SPAN%0d BAD-RAW idx=%0d got=%0x exp=%0x xor=%0x",
                                     TAGC, seen, r_word, pat_w[seen], r_word ^ pat_w[seen]);
                    end else if (repack !== pat_w[seen]) begin
                        rbad_map <= rbad_map + 32'd1;
                        if (rbad_map < 32'd4)
                            $display("SPAN%0d BAD-MAP idx=%0d raw=%0x repack=%0x exp=%0x",
                                     TAGC, seen, r_word, repack, pat_w[seen]);
                    end
                    seen <= seen + 32'd1;
                end
            end
        end
    end

    // ---------------- 终判 ----------------
    integer guard;
    initial begin
        wait (rst_n === 1'b1);
        guard = 0;
        while ((seen < NPAT) && (guard < 4000000)) begin
            @(posedge rd_clk);
            guard = guard + 1;
        end
        repeat (400) @(posedge rd_clk);
        o_words   = seen;
        o_bad_raw = rbad_raw;
        o_bad_map = rbad_map;
        o_checks  = rchk;
        o_accw    = wacc;
        o_refw    = wref;
        o_pop     = rpop;
        o_rcv     = rrcv;
        if (wacc !== rpop) begin
            $display("SPAN%0d CONS-FAIL accw=%0d pop=%0d", TAGC, wacc, rpop);
            o_bad_raw = o_bad_raw + 32'd1;
        end
        if (wtry !== wacc + wref) begin
            $display("SPAN%0d CONS-FAIL wtry=%0d accw=%0d refw=%0d", TAGC, wtry, wacc, wref);
            o_bad_raw = o_bad_raw + 32'd1;
        end
        if (rrcv !== rpop) begin
            $display("SPAN%0d CONS-FAIL rrcv=%0d pop=%0d", TAGC, rrcv, rpop);
            o_bad_raw = o_bad_raw + 32'd1;
        end
        if (seen !== NPAT) begin
            $display("SPAN%0d INCOMPLETE seen=%0d/%0d", TAGC, seen, NPAT);
            o_bad_raw = o_bad_raw + 32'd1;
        end
        if (rchk == 0) begin
            $display("SPAN%0d NO-EVIDENCE checks=0", TAGC);
            o_bad_raw = o_bad_raw + 32'd1;
        end
        $display("SPAN%0d RESULT W=%0d FWW=%0d NPAT=%0d words=%0d bad_raw=%0d bad_map=%0d checks=%0d acc=%0d refw=%0d pop=%0d rcv=%0d",
                 TAGC, W, FWW, NPAT, seen, o_bad_raw, o_bad_map, rchk, wacc, wref, rpop, rrcv);
    end
endmodule

module tb_cdc_bits;
    reg wr_clk = 0, rd_clk = 0, rst_n = 0;
    always #4.0 wr_clk = ~wr_clk;      // 125.00 MHz
    always #3.2 rd_clk = ~rd_clk;      // 156.25 MHz

    wire [31:0] w76,b76r,b76m,c76,a76,f76,p76,r76;
    wire [31:0] w73,b73r,b73m,c73,a73,f73,p73,r73;

    cdc_span_chk #(.W(76), .TAGC(76)) u_span76 (
        .wr_clk(wr_clk), .rd_clk(rd_clk), .rst_n(rst_n),
        .o_words(w76), .o_bad_raw(b76r), .o_bad_map(b76m), .o_checks(c76),
        .o_accw(a76), .o_refw(f76), .o_pop(p76), .o_rcv(r76)
    );
    cdc_span_chk #(.W(73), .TAGC(73)) u_span73 (
        .wr_clk(wr_clk), .rd_clk(rd_clk), .rst_n(rst_n),
        .o_words(w73), .o_bad_raw(b73r), .o_bad_map(b73m), .o_checks(c73),
        .o_accw(a73), .o_refw(f73), .o_pop(p73), .o_rcv(r73)
    );

    integer g;
    initial begin
        rst_n = 0;
        repeat (20) @(posedge wr_clk);
        rst_n = 1;
        g = 0;
        while (((b76r === 32'bx) || (b73r === 32'bx)) && (g < 4000000)) begin
            @(posedge rd_clk); g = g + 1;
        end
        $display("CDC_SPAN_TOTAL W76 words=%0d bad_raw=%0d bad_map=%0d checks=%0d acc=%0d refw=%0d pop=%0d | W73 words=%0d bad_raw=%0d bad_map=%0d checks=%0d acc=%0d refw=%0d pop=%0d",
                 w76, b76r, b76m, c76, a76, f76, p76, w73, b73r, b73m, c73, a73, f73, p73);
        if ((b76r === 0) && (b76m === 0) && (b73r === 0) && (b73m === 0) &&
            (c76 > 0) && (c73 > 0)) begin
            $display("CDC_BITS: PASS_ALL");
        end else begin
            $display("CDC_BITS: FAIL");
        end
        $finish;
    end
    initial begin
        #2000000;
        $display("CDC_BITS: TIMEOUT b76r=%0d b73r=%0d seen76=%0d seen73=%0d",
                 b76r, b73r, u_span76.seen, u_span73.seen);
        $finish;
    end
endmodule
