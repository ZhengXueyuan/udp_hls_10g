`timescale 1ns/1ps
// ===========================================================================
// tb_app_a2_equiv.v —— Stage C / A2 (TCP app `app_pattern` 的 **TX 1 拍/字**)
//                      的**逐字节等价 + 拍/帧**门 (自检式, 无 Python 依赖)
// ---------------------------------------------------------------------------
// 同一份 TB 用两种宏编译 (bat 里切), 两次的 dump/stats 文件逐字节 diff:
//   A) 无宏        = 改造前 (8 填 + 1 装载 + 1 消费 = 10 拍/字 ≈ 1828 拍/帧)
//   B) -d P7B_10G  = A2 (整字 1 拍装载 + 消费拍同拍预取 ⇒ 1 拍/字 ≈ 190 拍/帧)
// ⇒ 判据是**文件对比** (fc /b), 不是"我说等价"。
//
// ⚠️ 事件必须按 **DUT 可见的 beat** 对齐, 不能按绝对拍号 —— 两个构建吞吐差 ~10×,
//    按拍号驱动事件会让两次跑落在完全不同的帧相位上, dump 根本不可比 (而按 beat
//    对齐 ⇒ 两个构建在"同一逻辑点"经历同一事件)。每条事件都是
//    `(计数器 == K) && m_tvalid && m_tready ...` 的组合脉冲。
//
// 实例表 (NALL=14, 共享 clk/rst_n, 各自独立):
//   idx0..7  u_s*  段长扫描 {1,4,7,8,9,63,1472,1500} × TX_BYTES 非段整数倍
//   idx8     u_tx0 恒 ready 主会话 (33,000 B / 1460): 帧 2->22 差分测拍/帧
//   idx9     u_bad i_bad_frame=3 (2000B 超长: RTL 丢弃 + LFSR 冻结 + 图案流连续)
//   idx10    u_bp  伪随机背压 (寄存器化消费者) + AXIS 保持合同
//   idx11    u_evd ev_down 落在第 EVD_K 个 payload beat 的那一拍 (W3 收尾)
//   idx12    u_evr ev_down 落在 frame2 的 opener 拍 + ev_up 落在收尾拍 (rst_close)
//   idx13    u_tok app_tx_ready 掉 (第 TOK_K 个 payload beat 之后) -> 静默 TOK_Q 拍
//                  -> 恢复 (frm_wait 暂停再续)
// 每个实例都做: ①交付字节流 dump ②每帧字节数 dump ③TB 自己的 xorshift 模型逐字节
// oracle ④AXIS 保持合同 (tvalid && !tready 期间数据必须不变) ⑤stat_* 与 TB 逐 beat
// 记账对账。A/B 必须逐字节相同; 拍/帧读数单独落 rate.txt (**唯一允许两构建不同的读数**)。
// ⚠️ 打印字符串一律 ASCII (xsim 写中文会变 0xFF)。
// ===========================================================================
module tb_app_a2_equiv;
    reg clk, rst_n;
    initial clk = 1'b0;
    always #3.2 clk = ~clk;                       // 6.4 ns = 156.25 MHz

    localparam [63:0] SEED = 64'h9E3779B97F4A7C15;
    localparam integer NALL   = 14;
    localparam integer CY_TOT = 44000;
    localparam integer TOK_K  = 50;
    localparam integer TOK_Q  = 40;
    localparam integer EVD_K  = 100;

    // ---- 每实例 参数表 (最左 = idx13, 最右 = idx0; 用 [gi*W +: W] 取) ----
    localparam [NALL*12-1:0] SEGTAB = {
        12'd1460, 12'd1460, 12'd1460, 12'd1460, 12'd1460, 12'd1460,   // 13..8
        12'd1500, 12'd1472, 12'd63,   12'd9,    12'd8,    12'd7,
        12'd4,    12'd1 };                                            // 7..0
    localparam [NALL*32-1:0] BYTTAB = {
        32'd6000,  32'd6000,  32'd6000,  32'd6000,  32'd6000,   // 13..9
        32'd33000,                                             // 8  u_tx0
        32'd6000,  32'd6000,  32'd6000,                        // 7..5
        32'd64,    32'd64,    32'd64,    32'd64,    32'd64 };  // 4..0
    localparam [NALL*16-1:0] BADTAB = {
        16'd0, 16'd0, 16'd0, 16'd0,                            // 13..10
        16'd3,                                                 // 9  u_bad
        16'd0, 16'd0, 16'd0, 16'd0, 16'd0,
        16'd0, 16'd0, 16'd0, 16'd0 };                          // 8..0

    // ---------------- TB 侧图案模型 (与 app / peer 同一递推) ----------------
    function [63:0] xs_next;
        input [63:0] s;  reg [63:0] t;
        begin t = s ^ (s << 13); t = t ^ (t >> 7); t = t ^ (t << 17); xs_next = t; end
    endfunction

    // ---------------- 实例端口阵列 ----------------
    wire [63:0] w_d [0:NALL-1];
    wire [7:0]  w_k [0:NALL-1];
    wire        w_v [0:NALL-1];
    wire        w_l [0:NALL-1];
    wire [3:0]  w_tid [0:NALL-1];
    wire [31:0] w_txb [0:NALL-1], w_txf [0:NALL-1], w_badf [0:NALL-1];
    wire [31:0] w_rxb [0:NALL-1], w_mm [0:NALL-1];
    wire        w_done [0:NALL-1], w_act [0:NALL-1];

    wire [NALL-1:0] rdy;         // m_tready (每实例)
    wire [NALL-1:0] tkr;         // app_tx_ready[0] (每实例)

    // ---------------- 全局起始脉冲 (所有实例同一拍) ----------------
    reg [1:0] est;
    always @(posedge clk) if (!rst_n) est <= 2'd0;
    else est <= (est == 2'd3) ? 2'd3 : (est + 2'd1);
    wire up_glob = (est == 2'd1);

    // ---------------- m_tready: 默认全 1; u_bp(idx10) 伪随机拉低 ~6% ----------------
    // (寄存器化消费者 ⇒ "装载与消费同拍那一拍, 消费者必须采到旧值" 由它覆盖)
    reg [15:0] bp;
    reg [NALL-1:0] rdy_r;
    always @(posedge clk) if (!rst_n) bp <= 16'hACE1;
    else bp <= {bp[14:0], bp[15] ^ bp[13] ^ bp[12] ^ bp[10]};
    always @(posedge clk) if (!rst_n) rdy_r <= {NALL{1'b1}};
    else begin
        rdy_r <= {NALL{1'b1}};
        rdy_r[10] <= (bp[3:0] != 4'h0);
    end
    assign rdy = rdy_r;

    // ---------------- app_tx_ready[0]: 默认 1; u_tok(idx13) 由 tk 驱动 ----------------
    reg        tk, tok_dropped;
    reg [15:0] tok_n, tok_q;
    reg [NALL-1:0] tkr_r;
    wire hv13 = w_v[13] && rdy[13] && (w_k[13] != 8'h00);   // 第 13 号的 payload beat
    wire tok_drop_i = (tok_n == TOK_K);                     // 第 K 个 beat 之后的下一拍
    wire tok_rest_i = (tok_q == TOK_Q) && !tk;
    always @(posedge clk) if (!rst_n) begin
        tok_n <= 16'd0; tok_q <= 16'd0; tk <= 1'b1; tok_dropped <= 1'b0;
    end else begin
        if (hv13) tok_n <= tok_n + 16'd1;
        if (w_v[13]) tok_q <= 16'd0;                        // 不安静就清零
        else if (tok_q != TOK_Q) tok_q <= tok_q + 16'd1;
        if (tok_drop_i && !tok_dropped) begin tk <= 1'b0; tok_dropped <= 1'b1; end
        else if (tok_rest_i) tk <= 1'b1;
    end
    always @(posedge clk) if (!rst_n) tkr_r <= {NALL{1'b1}};
    else begin tkr_r <= {NALL{1'b1}}; tkr_r[13] <= tk; end
    assign tkr = tkr_r;

    // ---------------- u_evd (idx11): ev_down 落在第 EVD_K 个 payload beat 那拍 ----------------
    reg [15:0] evd_n;
    wire hv11 = w_v[11] && rdy[11] && (w_k[11] != 8'h00);
    always @(posedge clk) if (!rst_n) evd_n <= 16'd0;
    else if (hv11) evd_n <= evd_n + 16'd1;
    wire dn11 = (evd_n == (EVD_K - 1)) && hv11;             // 与第 K 个 beat 同拍 (组合)

    // ---------------- u_evr (idx12): opener 拍拉 ev_down; 收尾拍拉 ev_up ----------------
    reg [15:0] evr_nf;
    reg        evr_cp;
    wire hv12  = w_v[12] && rdy[12];
    wire opn12 = hv12 && (w_k[12] == 8'h00) && !w_l[12];    // 0 载荷 + 非 tlast = opener
    wire cls12 = hv12 && (w_k[12] == 8'h00) &&  w_l[12];    // 0 载荷 + tlast = 收尾字
    wire dn12 = (evr_nf == 16'd1) && opn12 && !evr_cp;
    wire up12 = evr_cp && cls12;
    always @(posedge clk) if (!rst_n) begin evr_nf <= 16'd0; evr_cp <= 1'b0; end
    else begin
        if (hv12 && w_l[12]) evr_nf <= evr_nf + 16'd1;
        if (dn12) evr_cp <= 1'b1; else if (up12) evr_cp <= 1'b0;
    end

    // 每实例事件向量 (只有 idx11/idx12 非零)
    wire [NALL-1:0] up_x = {{(NALL-1){1'b0}}, up12} << 12;
    wire [NALL-1:0] dn_x = ({{(NALL-1){1'b0}}, dn11} << 11) |
                           ({{(NALL-1){1'b0}}, dn12} << 12);
    wire [NALL-1:0] up_w = {NALL{up_glob}} | up_x;
    wire [NALL-1:0] dn_w = dn_x;

    // ---------------- DUT 阵列 ----------------
    genvar gi;
    generate
    for (gi = 0; gi < NALL; gi = gi + 1) begin : G
        app_pattern #(.TX_BYTES(BYTTAB[gi*32 +: 32]),
                      .TX_SEGSZ(SEGTAB[gi*12 +: 12]),
                      .BAD_LEN(12'd2000), .SEED(SEED), .AUTO_CLOSE(1'b1))
        u_dut (
            .clk(clk), .rst_n(rst_n),
            .ev_up(up_w[gi]), .ev_down(dn_w[gi]), .ev_slot(4'd0),
            .m_tdata(w_d[gi]), .m_tkeep(w_k[gi]), .m_tvalid(w_v[gi]),
            .m_tready(rdy[gi]), .m_tlast(w_l[gi]), .m_tid(w_tid[gi]),
            .app_tx_ready({15'b0, tkr[gi]}),
            .close_req(), .close_id(),
            .rx_tdata(64'd0), .rx_tkeep(8'h00), .rx_tvalid(1'b0), .rx_tready(),
            .rx_tlast(1'b0), .rx_tid(4'd0),
            .i_bad_frame(BADTAB[gi*16 +: 16]),
            .stat_tx_bytes(w_txb[gi]), .stat_tx_frames(w_txf[gi]),
            .stat_bad_frames(w_badf[gi]),
            .stat_rx_bytes(w_rxb[gi]), .stat_mismatch(w_mm[gi]),
            .active(w_act[gi]), .act_id(), .done(w_done[gi]), .dbg_lfsr(), .led()
        );
    end
    endgenerate

    // ================= 全局时钟计数 =================
    reg [31:0] cyc;
    always @(posedge clk) if (!rst_n) cyc <= 32'd0; else cyc <= cyc + 32'd1;

    // ---- u_tx0 (idx8) 拍/帧测量: 帧 2->22 差分 (两个口径: opener 拍 / tlast 拍) ----
    reg [31:0] M_cf2, M_cf22, M_ce2, M_ce22;
    reg [31:0] m8_nfr;  reg m8_in;
    always @(posedge clk) if (!rst_n) begin
        M_cf2 <= 0; M_cf22 <= 0; M_ce2 <= 0; M_ce22 <= 0; m8_nfr <= 0; m8_in <= 0;
    end else if (w_v[8] && rdy[8]) begin
        if (!m8_in) begin                              // 本帧首拍 (opener)
            m8_in <= 1'b1;
            if ((m8_nfr + 1) == 32'd2)  M_cf2  <= cyc;
            if ((m8_nfr + 1) == 32'd22) M_cf22 <= cyc;
        end
        if (w_l[8]) begin                              // 本帧末拍
            m8_in  <= 1'b0;
            m8_nfr <= m8_nfr + 32'd1;
            if ((m8_nfr + 1) == 32'd2)  M_ce2  <= cyc;
            if ((m8_nfr + 1) == 32'd22) M_ce22 <= cyc;
        end
    end

    // ================= 每实例: dump + oracle + AXIS + 记账 =================
    integer fd_b [0:NALL-1];        // 交付字节流 (hex)
    integer fd_f [0:NALL-1];        // 每帧字节数
    reg [63:0] M_mdl [0:NALL-1];    // 图案模型
    reg [31:0] M_nby [0:NALL-1];    // TB 记账字节 (不含坏帧字节)
    reg [31:0] M_nall[0:NALL-1];    // 全部字节 (含坏帧字节)
    reg [31:0] M_nfr [0:NALL-1];    // 已完成帧数
    reg [31:0] M_nn  [0:NALL-1];    // 本帧字节
    reg        M_in  [0:NALL-1];    // 帧内标志
    reg [31:0] M_orc [0:NALL-1];    // oracle 失配
    reg [31:0] M_ax  [0:NALL-1];    // AXIS 保持违约
    reg [31:0] M_nb  [0:NALL-1];    // 接受的 beat 数

    generate
    for (gi = 0; gi < NALL; gi = gi + 1) begin : GB
        localparam integer BADI = BADTAB[gi*16 +: 16];
        reg [63:0] shd;  reg [7:0] shk;  reg shl;  reg stall;
        integer li;  reg [7:0] bb;  reg badnow;
        always @(posedge clk) begin
            if (!rst_n) begin
                M_mdl[gi] <= SEED; M_nby[gi] <= 0; M_nall[gi] <= 0; M_nfr[gi] <= 0;
                M_nn[gi] <= 0; M_in[gi] <= 0; M_orc[gi] <= 0; M_ax[gi] <= 0;
                M_nb[gi] <= 0; shd <= 0; shk <= 0; shl <= 0; stall <= 0;
            end else begin
                // ---- AXIS 保持合同: 连续两拍都 (tvalid && !tready) 时数据必须不变 ----
                if (stall && w_v[gi] && !rdy[gi] &&
                    ((w_d[gi] !== shd) || (w_k[gi] !== shk) || (w_l[gi] !== shl))) begin
                    M_ax[gi] <= M_ax[gi] + 32'd1;
                    $display("  [FAIL] AXIS hold violation idx=%0d cyc=%0d", gi, cyc);
                end
                stall <= w_v[gi] && !rdy[gi];
                shd <= w_d[gi]; shk <= w_k[gi]; shl <= w_l[gi];

                // ---- 接受一个 beat ----
                if (w_v[gi] && rdy[gi]) begin
                    M_nb[gi] = M_nb[gi] + 1;
                    if (!M_in[gi]) M_in[gi] = 1'b1;    // 本帧首拍 (opener)
                    // RTL semantic (verified by tb_tr3 per-cycle trace, and identical
                    // in the default build): with i_bad_frame=N the bad frame is the
                    // (N+1)-th one -- bad_frm is loaded at the close of frame N and
                    // applies to the NEXT frame. Model must mirror that exactly.
                    badnow = (BADI != 0) && (M_nfr[gi] == BADI);
                    for (li = 0; li < 8; li = li + 1) begin
                        // ⚠️ lane li = 字节 d[63-8li -: 8] ⇔ keep 的 bit (7-li) 有效
                        // (MAC 字流约定: tkeep[7] 对应 tdata[63:56]; 反了会整体错位一字)
                        if (w_k[gi][7 - li]) begin
                            case (li)
                                0: bb = w_d[gi][63:56];  1: bb = w_d[gi][55:48];
                                2: bb = w_d[gi][47:40];  3: bb = w_d[gi][39:32];
                                4: bb = w_d[gi][31:24];  5: bb = w_d[gi][23:16];
                                6: bb = w_d[gi][15:8];   default: bb = w_d[gi][7:0];
                            endcase
                            $fwrite(fd_b[gi], "%02x", bb);
                            M_nall[gi] = M_nall[gi] + 1;
                            if ((M_nall[gi] % 32) == 0) $fwrite(fd_b[gi], "\n");
                            if (badnow) begin
                                // 坏帧: 载荷常数 0xA5 + 图案流**冻结** (不推进模型)
                                if (bb !== 8'hA5) begin
                                    M_orc[gi] = M_orc[gi] + 1;
                                    $display("  [FAIL] bad-frame byte idx=%0d cyc=%0d got=%02x",
                                             gi, cyc, bb);
                                end
                            end else begin
                                if (bb !== M_mdl[gi][31:24]) begin
                                    M_orc[gi] = M_orc[gi] + 1;
                                    $display("  [FAIL] pattern mismatch idx=%0d cyc=%0d got=%02x exp=%02x",
                                             gi, cyc, bb, M_mdl[gi][31:24]);
                                end
                                M_mdl[gi] = xs_next(M_mdl[gi]);
                                M_nby[gi] = M_nby[gi] + 1;
                                M_nn[gi]  = M_nn[gi] + 1;
                            end
                        end
                    end
                    if (w_l[gi]) begin
                        $fwrite(fd_f[gi], "%0d\n", M_nn[gi]);
                        M_nfr[gi] = M_nfr[gi] + 1;
                        M_in[gi]  = 1'b0;
                        M_nn[gi]  = 0;
                    end
                end
                // 换流 (rst_close): 新会话图案从 SEED 重开 ⇒ 模型同步重开
                if (up_x[gi]) M_mdl[gi] = SEED;
            end
        end
    end
    endgenerate

    // ================= 判据累加 =================
    integer errs;
    task chk;
        input cond;  input [1023:0] msg;
        begin
            if (!cond) begin errs = errs + 1; $display("  [FAIL] %0s", msg); end
            else         $display("  [ ok ] %0s", msg);
        end
    endtask

    integer ii, kk, rem, nf, expf;
    reg [255:0] fname;
    integer f_stats, f_rate;

    initial begin
        errs = 0; rst_n = 1'b0;
        est = 2'd0; bp = 16'hACE1; tk = 1'b1; tok_dropped = 1'b0;
        tok_n = 0; tok_q = 0; evd_n = 0; evr_nf = 0; evr_cp = 0;
        cyc = 0;
        for (ii = 0; ii < NALL; ii = ii + 1) begin
            M_mdl[ii] = SEED; M_nby[ii] = 0; M_nall[ii] = 0; M_nfr[ii] = 0;
            M_nn[ii] = 0; M_in[ii] = 0; M_orc[ii] = 0; M_ax[ii] = 0; M_nb[ii] = 0;
            $sformat(fname, "d%0d.hex", ii);  fd_b[ii] = $fopen(fname, "w");
            $sformat(fname, "f%0d.txt", ii);  fd_f[ii] = $fopen(fname, "w");
        end
        f_stats = $fopen("stats.txt", "w");
        f_rate  = $fopen("rate.txt", "w");

        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (CY_TOT) @(posedge clk);

        // ================= 收口 =================
        for (ii = 0; ii < NALL; ii = ii + 1) begin
            $fclose(fd_b[ii]);  $fclose(fd_f[ii]);
        end

        $display("  TX0: frames=%0d bytes=%0d done=%0d | tb_bytes=%0d tb_frames=%0d beats=%0d",
                 w_txf[8], w_txb[8], w_done[8], M_nby[8], M_nfr[8], M_nb[8]);
        $display("  BAD: frames=%0d bytes=%0d bad=%0d | tb_bytes=%0d tb_frames=%0d",
                 w_txf[9], w_txb[9], w_badf[9], M_nby[9], M_nfr[9]);
        $display("  BP : frames=%0d bytes=%0d | tb_bytes=%0d tb_frames=%0d beats=%0d",
                 w_txf[10], w_txb[10], M_nby[10], M_nfr[10], M_nb[10]);
        $display("  EVD: frames=%0d bytes=%0d active=%0d | tb_bytes=%0d tb_frames=%0d",
                 w_txf[11], w_txb[11], w_act[11], M_nby[11], M_nfr[11]);
        $display("  EVR: frames=%0d bytes=%0d done=%0d | tb_bytes=%0d tb_frames=%0d",
                 w_txf[12], w_txb[12], w_done[12], M_nby[12], M_nfr[12]);
        $display("  TOK: frames=%0d bytes=%0d done=%0d | tb_bytes=%0d tb_frames=%0d",
                 w_txf[13], w_txb[13], w_done[13], M_nby[13], M_nfr[13]);
        $display("  SEG sweep (idx seglen bytes dut_frames tb_bytes):");
        for (ii = 0; ii < 8; ii = ii + 1)
            $display("    %0d: seg=%0d bytes=%0d frames=%0d tbb=%0d",
                     ii, SEGTAB[ii*12 +: 12], BYTTAB[ii*32 +: 32], w_txf[ii], M_nby[ii]);
        $display("  RATE: dcyc_open(f2->f22)=%0d dcyc_tlast(f2->f22)=%0d",
                 (M_cf22 - M_cf2), (M_ce22 - M_ce2));

        $fwrite(f_stats, "TX0 frames=%0d bytes=%0d done=%0d tb_bytes=%0d tb_frames=%0d beats=%0d\n",
                w_txf[8], w_txb[8], w_done[8], M_nby[8], M_nfr[8], M_nb[8]);
        $fwrite(f_stats, "BAD frames=%0d bytes=%0d bad=%0d tb_bytes=%0d tb_frames=%0d\n",
                w_txf[9], w_txb[9], w_badf[9], M_nby[9], M_nfr[9]);
        $fwrite(f_stats, "BP frames=%0d bytes=%0d tb_bytes=%0d tb_frames=%0d beats=%0d\n",
                w_txf[10], w_txb[10], M_nby[10], M_nfr[10], M_nb[10]);
        $fwrite(f_stats, "EVD frames=%0d bytes=%0d active=%0d tb_bytes=%0d tb_frames=%0d\n",
                w_txf[11], w_txb[11], w_act[11], M_nby[11], M_nfr[11]);
        $fwrite(f_stats, "EVR frames=%0d bytes=%0d done=%0d tb_bytes=%0d tb_frames=%0d\n",
                w_txf[12], w_txb[12], w_done[12], M_nby[12], M_nfr[12]);
        $fwrite(f_stats, "TOK frames=%0d bytes=%0d done=%0d tb_bytes=%0d tb_frames=%0d\n",
                w_txf[13], w_txb[13], w_done[13], M_nby[13], M_nfr[13]);
        for (ii = 0; ii < NALL; ii = ii + 1)
            $fwrite(f_stats, "S%0d seg=%0d bytes=%0d frames=%0d bad=%0d tb_bytes=%0d tb_frames=%0d orc=%0d ax=%0d beats=%0d\n",
                    ii, SEGTAB[ii*12 +: 12], BYTTAB[ii*32 +: 32], w_txf[ii], w_badf[ii],
                    M_nby[ii], M_nfr[ii], M_orc[ii], M_ax[ii], M_nb[ii]);
        $fclose(f_stats);

        // 拍/帧读数 (唯一允许两构建不同的量): 帧 2->22 差分 (20 个间隔)
        $fwrite(f_rate, "cf2=%0d cf22=%0d dcyc_open=%0d per_frame=%0d rem=%0d\n",
                M_cf2, M_cf22, (M_cf22 - M_cf2), ((M_cf22 - M_cf2) / 20),
                ((M_cf22 - M_cf2) % 20));
        $fwrite(f_rate, "ce2=%0d ce22=%0d dcyc_tlast=%0d per_frame=%0d rem=%0d\n",
                M_ce2, M_ce22, (M_ce22 - M_ce2), ((M_ce22 - M_ce2) / 20),
                ((M_ce22 - M_ce2) % 20));
        $fclose(f_rate);

        // ================= 判据 =================
        // 1) 每实例: oracle / AXIS / 记账
        for (ii = 0; ii < NALL; ii = ii + 1) begin
            chk(M_orc[ii] == 0, "oracle: payload stream byte-exact vs TB xorshift model");
            chk(M_ax[ii]  == 0, "AXIS hold contract: stable while tvalid && !tready");
            chk(w_txf[ii] == M_nfr[ii], "stat_tx_frames == TB frame count (all 14)");
            chk(w_txb[ii] == M_nby[ii], "stat_tx_bytes == TB byte count (all 14)");
        end
        // 2) 无事件实例 (idx0..10): 帧数/字节数 = 独立算术模型
        for (ii = 0; ii < 11; ii = ii + 1) begin
            rem = BYTTAB[ii*32 +: 32];
            nf = 0; kk = 0;
            while (rem > 0) begin
                kk = kk + 1;  nf = nf + 1;
                if ((BADTAB[ii*16 +: 16] != 0) && (kk == ((BADTAB[ii*16 +: 16]) + 1))) begin
                    // 坏帧: 不消耗 remain (RTL 语义: 被丢弃的帧不计入 TX_BYTES 计划)
                end else if (rem > (SEGTAB[ii*12 +: 12])) rem = rem - (SEGTAB[ii*12 +: 12]);
                else rem = 0;
            end
            expf = nf;
            chk(w_txf[ii] == expf, "frame count == arithmetic model (idx0..10)");
            chk(w_txb[ii] == (BYTTAB[ii*32 +: 32]), "stat_tx_bytes == TX_BYTES (idx0..10)");
        end
        // 3) 具体读数 (两个构建都必须成立)
        chk(w_done[8] == 1'b1,            "u_tx0 done=1");
        chk(w_txf[8] == 32'd23,           "u_tx0 23 frames (22x1460 + 880)");
        chk(w_txb[8] == 32'd33000,        "u_tx0 33000 bytes");
        chk(M_nfr[8] >= 32'd22,           "u_tx0 reached frame 22 (measurement window)");
        chk(w_badf[9] == 32'd1,           "u_bad injected 1 bad frame");
        chk(w_txf[9] == 32'd6,            "u_bad 6 frames (3x1460 + bad2000 + 1460 + 160)");
        chk(w_txb[9] == 32'd6000,         "u_bad 6000 counted bytes (bad frame not counted)");
        chk(M_nall[9] == 32'd8000,        "u_bad dumped 8000 bytes (incl. 2000 bad)");
        chk(M_nfr[10] > 32'd0,            "u_bp produced frames under backpressure");
        chk(w_txb[10] == 32'd6000,        "u_bp 6000 bytes under backpressure");
        chk(w_act[11] == 1'b0,            "u_evd session closed by ev_down");
        chk(w_txf[11] == 32'd1,           "u_evd 1 frame closed (W3)");
        chk(M_nby[11] == 32'd800,         "u_evd 100 payload words = 800 bytes");
        chk(w_txf[12] == 32'd7,           "u_evr 7 frames (1 truncated + 6 restarted session)");
        chk(w_txb[12] == 32'd7460,        "u_evr 1460 + 6000 bytes (restart re-sends TX_BYTES)");
        chk(w_done[12] == 1'b1,           "u_evr restarted session ran to completion");
        chk(w_done[13] == 1'b1,           "u_tok resumed after frm_wait and finished");
        chk(tok_dropped == 1'b1,          "u_tok tx_ok really dropped");
        chk(M_nfr[13] == 32'd5,           "u_tok 5 frames (post-pause resume, same as no-pause)");
        // 4) **拍/帧判据** (唯一随构建变、且被"判"的读数; 帧 2->22 差分 / 20)
`ifdef P7B_10G
        chk((M_ce22 - M_ce2) == (20 * 190), "cycles/frame (A2) == 190 (tlast to tlast)");
        chk((M_cf22 - M_cf2) == (20 * 190), "cycles/frame (A2) == 190 (opener to opener)");
`else
        chk((M_ce22 - M_ce2) == (20 * 1828), "cycles/frame (default) == 1828 (tlast to tlast)");
        chk((M_cf22 - M_cf2) == (20 * 1828), "cycles/frame (default) == 1828 (opener to opener)");
`endif

        if (errs == 0) $display("TB_APP_A2_EQUIV: OK");
        else           $display("TB_APP_A2_EQUIV: FAIL errs=%0d", errs);
        $display("TB_A2 DONE");
        $finish;
    end
endmodule
