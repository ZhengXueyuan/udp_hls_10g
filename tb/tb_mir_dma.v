`timescale 1ns/1ps
//=============================================================================
// tb_mir_dma.v — M1 期 B 单元门: `mir_dma_ring` (环+计数器) × `aximm_c2h_win` (AXI-MM 读从机)
//=============================================================================
// 被测合同 (逐条对应判据):
//   A 基本 INCR 突发: 拍数/rlast 位置/ID 回填/128 位行装配/内容 (bank0 = LSB)
//   B 跨环尾回绕: 线性地址跨过环尾 ⇒ 两段物理读, 内容按"物理位最后被写的逻辑字"对
//   C 背压: rready 低时 rvalid/data 必须**保持不动** (AXI 铁律: rvalid 不依赖 rready)
//   D 四个不合法 (窗外/未对齐/size≠4/WRAP) ⇒ **整笔 SLVERR + 发满拍 + rlast + 回 IDLE**
//     (⛔ "永远应答"是本模块的第一位合同: 任何输入都不许挂)
//   E FIXED 突发: 每拍同一行 (IP 把 burst[1] 硬接 0 ⇒ 只可能 FIXED(00)/INCR(01))
//   G 单拍突发 (arlen=0) 的收尾: rlast 恰在该拍, 且之后能立刻接下一笔
//   H 幂等只读 + clr 语义: 同址重读逐位相同; clr ⇒ 计数器与"逻辑字 0"同拍归零
//   I 空环也要应答 (从没写过字的环, 读也要发满拍) —— "永远应答"的最强形态
// 激励纪律: 所有驱动在 negedge 落笔、DUT 在 posedge 采样 (工程坑 3/17) ⇒ 零竞争。
//=============================================================================
module tb_mir_dma;
    localparam integer ROW_AW = 10;
    localparam integer RING_WORDS = 4 * (1 << ROW_AW);

    reg clk = 1'b0;
    always #2 clk = ~clk;                 // 250 MHz (4 ns)
    reg rst_n = 1'b0;

    integer fails = 0, checks = 0;
    task chk(input [255:0] name, input [63:0] got, input [63:0] exp);
        begin
            checks = checks + 1;
            if (got === exp) $display("  [PASS] %0s = %0d", name, got);
            else begin $display("  [FAIL] %0s = %0d (期望 %0d)", name, got, exp); fails = fails + 1; end
        end
    endtask

    // ---------------- ring ----------------
    reg         en = 1'b0, src_gnt = 1'b0, clr = 1'b0;
    reg  [31:0] src_data = 32'd0;
    wire        src_req;
    wire [31:0] wr_words;
    wire [ROW_AW-1:0] rr_row;
    wire [127:0] rr_dout;

    mir_dma_ring #(.ROW_AW(ROW_AW)) u_ring (
        .rd_clk   (clk),
        .rst_n    (rst_n),
        .en       (en),
        .clr_pulse(clr),
        .src_req  (src_req),
        .src_gnt  (src_gnt),
        .src_data (src_data),
        .rr_row   (rr_row),
        .rr_dout  (rr_dout),
        .wr_words (wr_words)
    );

    // ---------------- AXI 主模型 ----------------
    reg [3:0]  arid_r = 4'd0;
    reg [63:0] araddr_r = 64'd0;
    reg [7:0]  arlen_r = 8'd0;
    reg [2:0]  arsize_r = 3'd4;
    reg [1:0]  arburst_r = 2'b01;
    reg        arvalid_r = 1'b0;
    reg        rready_r = 1'b1;
    wire       arready;
    wire [3:0] rid;
    wire [127:0] rdata;
    wire [1:0] rresp;
    wire       rlast, rvalid;

    aximm_c2h_win #(.ROW_AW(ROW_AW)) u_dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .arid    (arid_r),
        .araddr  (araddr_r),
        .arlen   (arlen_r),
        .arsize  (arsize_r),
        .arburst (arburst_r),
        .arvalid (arvalid_r),
        .arready (arready),
        .rid     (rid),
        .rdata   (rdata),
        .rresp   (rresp),
        .rlast   (rlast),
        .rvalid  (rvalid),
        .rready  (rready_r),
        .rr_row  (rr_row),
        .rr_dout (rr_dout)
    );

    // ---------------- R 拍采集 ----------------
    reg [127:0] rbuf  [0:4095];
    reg [1:0]   rresp_buf [0:4095];
    reg [3:0]   rid_buf   [0:4095];
    integer     rn = 0, rlast_at = -1, rlast_cnt = 0;
    always @(posedge clk) begin
        if (rvalid && rready_r) begin
            rbuf[rn]      <= rdata;
            rresp_buf[rn] <= rresp;
            rid_buf[rn]   <= rid;
            if (rlast) begin rlast_at <= rn; rlast_cnt <= rlast_cnt + 1; end
            rn <= rn + 1;
        end
    end

    // 写入的字 (按 push 顺序) 与总数 ⇒ 期望值由"物理位最后被写的逻辑字"推
    reg [31:0] wmem [0:8191];
    integer    wcnt = 0;
    function [31:0] exp_word(input integer phys);   // 最后一个写进该物理位的逻辑字
        integer L;
        begin
            if (wcnt == 0) exp_word = 32'hDEADBEEF;   // 空环: 内容不判 (只在 case I 用)
            else begin
                L = phys + ((wcnt - 1 - phys) / RING_WORDS) * RING_WORDS;
                exp_word = (L >= 0) ? wmem[L] : 32'hDEADBEEF;
            end
        end
    endfunction
    function [127:0] exp_beat(input integer row);   // 行 = 4 个物理字 {bank3..bank0}
        integer p;
        begin
            p = row * 4;
            exp_beat = {exp_word(p + 3), exp_word(p + 2), exp_word(p + 1), exp_word(p + 0)};
        end
    endfunction

    task push_word(input [31:0] d);
        begin
            @(negedge clk);
            src_data <= d; src_gnt <= 1'b1;
            @(negedge clk);
            src_gnt <= 1'b0;
            wmem[wcnt] = d; wcnt = wcnt + 1;
        end
    endtask

    integer ar_done;
    task axi_ar(input [63:0] addr, input [7:0] len, input [3:0] id,
                input [2:0] size, input [1:0] burst);
        begin
            @(negedge clk);
            araddr_r <= addr; arlen_r <= len; arid_r <= id;
            arsize_r <= size; arburst_r <= burst; arvalid_r <= 1'b1;
            ar_done = 0;
            while (!ar_done) begin
                @(posedge clk);
                if (arready) ar_done = 1;
            end
            @(negedge clk);
            arvalid_r <= 1'b0;
        end
    endtask

    integer target_n;
    task wait_beats(input integer n);
        begin
            target_n = n;
            while (rn < target_n) @(posedge clk);
        end
    endtask

    // ---- 主序列 ----
    integer k, i, rn_c;
    reg [127:0] held_data;
    reg         held_valid;
    integer     w_before;

    initial begin
        $display("=== tb_mir_dma: ring + AXI-MM read slave unit gate ===");
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);
        chk("H0a en=0 ⇒ src_req=0 (停采靠'不请求')", src_req, 0);
        en = 1'b1;
        @(posedge clk);                 // 让组合赋值落定再采 (同一时间步里读组合输出有 delta 竞争)
        chk("H0b en=1 ⇒ src_req=1", src_req, 1);

        // ---------- I: 空环也必须应答 (永远应答的最强形态) ----------
        $display("  --- I: 空环读 (内容不判, 只判'发满拍+回 IDLE') ---");
        axi_ar(64'd0, 8'd1, 4'h5, 3'd4, 2'b01);
        wait_beats(2);
        chk("I1 空环 2 拍发满", rn - 0, 2);
        chk("I2 空环 rlast 在第 2 拍", rlast_at, 1);
        chk("I3 空环 resp = OKAY", rresp_buf[0], 2'd0);
        chk("I4 回 IDLE (arready=1)", arready, 1);
        rn = 0; rlast_at = -1; rlast_cnt = 0;

        // ---------- A: 基本 INCR (32 字, 8 拍) ----------
        $display("  --- A: 基本 INCR 8 拍 (id=0xA) ---");
        for (k = 0; k < 32; k = k + 1) push_word(32'hA5A50000 + k);
        chk("A0 wr_words == 32", wr_words, 32);
        axi_ar(64'd0, 8'd7, 4'hA, 3'd4, 2'b01);
        wait_beats(8);
        chk("A1 拍数 == 8", rn, 8);
        chk("A2 rlast 恰在末拍", rlast_at, 7);
        chk("A3 rlast 只出现 1 次", rlast_cnt, 1);
        for (i = 0; i < 8; i = i + 1) begin
            if (rresp_buf[i] !== 2'b00) begin
                $display("  [FAIL] A4 resp[%0d] = %0d (期望 0)", i, rresp_buf[i]); fails = fails + 1;
            end
            if (rid_buf[i] !== 4'hA) begin
                $display("  [FAIL] A5 rid[%0d] = %0h (期望 a)", i, rid_buf[i]); fails = fails + 1;
            end
            if (rbuf[i] !== exp_beat(i)) begin
                $display("  [FAIL] A6 beat[%0d] = %032h (期望 %032h)", i, rbuf[i], exp_beat(i));
                fails = fails + 1;
            end
        end
        checks = checks + 2;
        $display("  [INFO] A4/A5/A6 逐拍判过 (%0d 拍 × 3 项)", rn);
        chk("A7 回 IDLE", arready, 1);
        rn = 0; rlast_at = -1; rlast_cnt = 0;

        // ---------- G: 单拍突发 (arlen=0) ----------
        $display("  --- G: 单拍突发 (arlen=0) + 之后立刻接下一笔 ---");
        axi_ar(64'd16, 8'd0, 4'h3, 3'd4, 2'b01);      // addr 16 = row 1
        wait_beats(1);
        chk("G1 恰 1 拍", rn, 1);
        chk("G2 rlast 在该拍", rlast_at, 0);
        chk("G3 id 回填 == 3", rid_buf[0], 4'h3);
        chk("G4 内容 = row1", rbuf[0], {exp_word(7), exp_word(6), exp_word(5), exp_word(4)});
        chk("G5 回 IDLE (可立刻接下一笔)", arready, 1);
        axi_ar(64'd16, 8'd0, 4'h3, 3'd4, 2'b01);      // 再来一笔, 证明真的活着
        wait_beats(2);
        chk("G6 第二笔也发满", rn, 2);
        rn = 0; rlast_at = -1; rlast_cnt = 0;

        // ---------- C: rready 背压 ----------
        //   ⚠️ 拍数用**当拍快照** rn_c 作基线 (rn 是 NBA 更新 ⇒ "等到 2 拍"会晚一拍看到)
        $display("  --- C: 背压 (rready 低 ⇒ rvalid/data 保持) ---");
        axi_ar(64'd0, 8'd7, 4'h1, 3'd4, 2'b01);       // rows 0..7 (都已写过; 内容可判)
        wait_beats(2);                                 // 先吃 ~2 拍
        @(negedge clk); rready_r <= 1'b0;
        repeat (3) @(posedge clk);
        rn_c = rn; held_data = rdata; held_valid = rvalid;
        repeat (7) @(posedge clk);
        chk("C1 背压下 rvalid 保持 1", rvalid, 1);
        chk("C2 背压下 rvalid 曾是 1", held_valid, 1);
        chk("C3 背压下 rdata 不变", rdata, held_data);
        chk("C4 背压下拍数不涨", rn, rn_c);
        @(negedge clk); rready_r <= 1'b1;
        wait_beats(8);
        chk("C5 恢复后恰 8 拍", rn, 8);
        chk("C6 恢复后 rlast 在末拍", rlast_at, 7);
        chk("C7 最后一拍内容对 (行 7)", rbuf[7], {exp_word(31), exp_word(30), exp_word(29), exp_word(28)});
        rn = 0; rlast_at = -1; rlast_cnt = 0;

        // ---------- E: FIXED 突发 ----------
        $display("  --- E: FIXED 突发 (4 拍同一行) ---");
        axi_ar(64'd48, 8'd3, 4'h2, 3'd4, 2'b00);      // addr 48 = row 3
        wait_beats(4);
        for (i = 0; i < 4; i = i + 1)
            if (rbuf[i] !== {exp_word(15), exp_word(14), exp_word(13), exp_word(12)}) begin
                $display("  [FAIL] E1 FIXED beat[%0d] 内容错", i); fails = fails + 1;
            end
        checks = checks + 1;
        chk("E2 FIXED 发满 4 拍 + rlast 在末拍", rlast_at, 3);
        rn = 0; rlast_at = -1; rlast_cnt = 0;

        // ---------- D: 四个不合法 ⇒ 整笔 SLVERR (不挂) ----------
        $display("  --- D: 不合法 ⇒ SLVERR (窗外/未对齐/size/WRAP) ---");
        // D1 窗外 (0x4000 = 第一格窗外)
        axi_ar(64'd16384, 8'd3, 4'h6, 3'd4, 2'b01);
        wait_beats(4);
        chk("D1a 窗外: 发满 4 拍", rn, 4);
        chk("D1b 窗外: 全 SLVERR", {rresp_buf[0], rresp_buf[1], rresp_buf[2], rresp_buf[3]},
            {2'b10, 2'b10, 2'b10, 2'b10});
        chk("D1c 窗外: rlast 在末拍", rlast_at, 3);
        chk("D1d 窗外: 回 IDLE", arready, 1);
        rn = 0; rlast_at = -1; rlast_cnt = 0;
        // D2 未对齐
        axi_ar(64'd5, 8'd0, 4'h6, 3'd4, 2'b01);
        wait_beats(1);
        chk("D2a 未对齐: SLVERR", rresp_buf[0], 2'b10);
        chk("D2b 未对齐: rlast", rlast_at, 0);
        rn = 0; rlast_at = -1; rlast_cnt = 0;
        // D3 size != 4
        axi_ar(64'd0, 8'd0, 4'h6, 3'd2, 2'b01);
        wait_beats(1);
        chk("D3a size=2: SLVERR", rresp_buf[0], 2'b10);
        rn = 0; rlast_at = -1; rlast_cnt = 0;
        // D4 WRAP
        axi_ar(64'd0, 8'd3, 4'h6, 3'd4, 2'b10);
        wait_beats(4);
        chk("D4a WRAP: 发满 4 拍", rn, 4);
        chk("D4b WRAP: 全 SLVERR", rresp_buf[0], 2'b10);
        rn = 0; rlast_at = -1; rlast_cnt = 0;

        // ---------- B: 跨环尾回绕 ----------
        $display("  --- B: 跨环尾回绕 (读从物理 4088 起, 绕到 0) ---");
        w_before = wcnt;
        for (k = 0; k < 4096 + 64 - 32; k = k + 1) push_word(32'h5A5A0000 + k);
        chk("B0 wr_words == 4160", wr_words, 4160);
        axi_ar(64'd16352, 8'd3, 4'h7, 3'd4, 2'b01);   // 16352/16 = 1022 行 → 1022,1023,0,1
        wait_beats(4);
        chk("B1 拍数 4", rn, 4);
        for (i = 0; i < 4; i = i + 1) begin
            if (rbuf[i] !== exp_beat(1022 + i)) begin
                $display("  [FAIL] B2 wrap beat[%0d] 内容错 (行 %0d)", i, (1022 + i) % 1024);
                fails = fails + 1;
            end
        end
        checks = checks + 1;
        $display("  [INFO] B2 逐拍按'物理位最后被写的逻辑字'判过");
        rn = 0; rlast_at = -1; rlast_cnt = 0;

        // ---------- H: 幂等只读 + clr ----------
        $display("  --- H: 幂等 (同址重读) + clr (计数/逻辑 0 同拍归零) ---");
        axi_ar(64'd64, 8'd1, 4'h9, 3'd4, 2'b01);
        wait_beats(2);
        held_data = rbuf[0];
        rn = 0; rlast_at = -1; rlast_cnt = 0;
        axi_ar(64'd64, 8'd1, 4'h9, 3'd4, 2'b01);
        wait_beats(2);
        chk("H1 同址重读逐位相同 (幂等)", rbuf[0], held_data);
        rn = 0; rlast_at = -1; rlast_cnt = 0;
        // clr
        @(negedge clk); clr <= 1'b1;
        @(negedge clk); clr <= 1'b0;
        repeat (2) @(posedge clk);
        chk("H2 clr ⇒ wr_words == 0", wr_words, 0);
        push_word(32'h11AA22BB); push_word(32'h33CC44DD);
        chk("H3 clr 后计数从 0 起", wr_words, 2);
        axi_ar(64'd0, 8'd0, 4'h9, 3'd4, 2'b01);
        wait_beats(1);
        chk("H4 clr 后 逻辑字0 = 11AA22BB (在 beat[31:0])", rbuf[0][31:0], 32'h11AA22BB);
        chk("H5 逻辑字1 = 33CC44DD (在 beat[63:32])", rbuf[0][63:32], 32'h33CC44DD);
        rn = 0; rlast_at = -1; rlast_cnt = 0;

        // ---------- 汇总 ----------
        if (fails == 0) $display("MIR_DMA_GATE PASS_ALL tb_mir_dma (checks=%0d)", checks);
        else            $display("MIR_DMA_GATE FAIL %0d 项失败 (checks=%0d)", fails, checks);
        $display("=== done ===");
        $finish;
    end

    initial begin #4000000; $display("TIMEOUT"); $finish; end

endmodule
