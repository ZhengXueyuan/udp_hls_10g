`timescale 1ps/1ps
//=============================================================================
// tb_atk_ratio.v -- 对抗门 A: 极端频率比 + 真实用法 (b 域自由运行计数器) 长跑
//-----------------------------------------------------------------------------
// 背景: 单元门 tb_snap_cdc.v 只跑 a=4ns/b=8ns (2:1) 固定相位。
// 本门打的是频率比与"集成时真实用法"这一面:
//   b 域 din_b = 每个 b 沿都变的自由运行计数器 (集成的真实场景), a 域按 4 种模式发 req。
//
// 判据 (全部来自"外部可观测"量 + 一个层次引用探针 u_dut.toggle_a):
//   A1 相干: 每次 valid 的 NW 个字 tag 必须全同, 且第 i 字序号 == i
//            (计数器每 b 沿都变 => 任一处位混/错位必然表现为 tag 不一致)
//   A2 不超前: 捕获 tag 必须 <= 当前 cnt_b (快照只能是"某个真实 b 沿"的值)
//   A3 不陈旧: 捕获 tag 必须 >= 该次请求发起时刻 (toggle 翻转那一拍) 的 cnt_b
//            -- 这一条是"陈旧快照"(拿上一代 hold_b 冒充本次结果)的唯一判据
//   A4 严格单调: 相邻两次 valid 的 tag 必须严格递增
//            (计数器每 b 沿变 + 一次请求只锁存一次 => 相等就意味着重复锁存/重复 valid)
//   A5 不丢不重: 捕获数 == toggle 翻转数 (翻转无对应 valid = 握手丢失/死锁;
//            valid 无对应翻转 = 幻影 valid); MODE1 下另有一条"请求后有限拍内必回"
//   A6 负对照: 故意把第 3 个字撕裂 (用 negedge 寄存的错代值) => A1 必须抓到
//   附带: valid 必须是 1 拍脉冲 (不许连高); dout_a 只许在 valid 那一拍变
//=============================================================================
module tb_atk_ratio;
    // 真实集成参数: W=32, NW=8, 256 位 (board/wrapper_p4.v:2377)
    parameter W = 32, NW = 8, NB = NW*W;

    integer HA   = 2000;        // clk_a 半周期 (ps)
    integer HB   = 4000;        // clk_b 半周期 (ps)
    integer MODE = 1;           // 0=req 恒高 1=脉冲+等 valid 2=狂发 3=req=!busy
    integer NVAL = 200;         // 目标 valid 数
    integer WT   = 2000000000;  // 看门狗 (ps)
    integer KA   = 7;           // MODE2: 每 KA 个 a 沿发一次 req
    integer VLOG = 0;

    reg clk_a = 0, clk_b = 0, rst_n = 0;
    reg clk_b_en = 1;
    wire clk_b_g = clk_b & clk_b_en;

    // ---------------- 参数 + 时钟 ----------------
    initial begin
        $value$plusargs("HA=%d",   HA);
        $value$plusargs("HB=%d",   HB);
        $value$plusargs("MODE=%d", MODE);
        $value$plusargs("NVAL=%d", NVAL);
        $value$plusargs("WT=%d",   WT);
        $value$plusargs("KA=%d",   KA);
        $value$plusargs("VLOG=%d", VLOG);
        if (W != 32) $display("[WARN] this TB assumes W=32");
        fork
            forever #(HA) clk_a = ~clk_a;
            forever #(HB) clk_b = ~clk_b;
        join
    end

    // ---------------- b 域数据源: 每个 b 沿都变的计数器 ----------------
    reg [23:0] cnt_b = 24'd0;
    always @(posedge clk_b_g) cnt_b <= cnt_b + 24'd1;

    // 负对照用的"错一代"值: 在 negedge 采, 与 posedge 值差 2
    reg [23:0] cnt_tear = 24'd0;
    always @(negedge clk_b_g) cnt_tear <= cnt_b + 24'd2;

    reg          torn = 1'b0;
    reg [NB-1:0] din_b;
    integer      wi;
    always @* begin
        for (wi = 0; wi < NW; wi = wi + 1)
            din_b[wi*W +: W] = {cnt_b, wi[7:0]};
        if (torn) din_b[3*W +: W] = {cnt_tear, 8'd3};   // 只有第 3 字被撕裂
    end

    // ---------------- DUT ----------------
    reg           req_r = 1'b0;
    reg           req_c;
    reg           stop = 1'b0;     // 强制停止 (MODE3 是组合 req, 光清 req_r 停不下来)
    reg           neg_phase = 1'b0;// A6 负对照阶段: 一律由激励驱动 req_r
    wire          req_a = stop ? 1'b0 : ((MODE == 3 && !neg_phase) ? req_c : req_r);
    wire          busy_a, valid_a;
    wire [NB-1:0] dout_a;
    always @* req_c = ~busy_a;

    snap_cdc #(.W(W), .NW(NW)) u_dut (
        .clk_a(clk_a), .rst_n(rst_n), .req_a(req_a),
        .busy_a(busy_a), .dout_a(dout_a), .valid_a(valid_a),
        .clk_b(clk_b_g), .din_b(din_b)
    );

    // ---------------- 检查器 (a 域, 沿前值采样 = 上一拍注册值) ----------------
    integer acyc = 0, nval = 0, nflip = 0, nreq = 0, fails = 0;
    integer neg_hits = 0, neg_mode = 0;
    integer lat = 0, lat_min = 1000000, lat_max = 0, tot_lat = 0;
    integer flip_acyc = 0, have_prev = 0;
    integer jv, k;
    reg [23:0] tag_v, prev_tag = 24'd0, cur_flip_tag = 24'd0, c_prev = 24'd0;
    reg        mixed_v, v_s, v_prev, t_s, dchk = 1'b0, dead = 1'b0;
    reg        t_prev = 1'b0;      // 必须与 DUT 复位值一致, 否则首个 a 沿把 X->0 误判成翻转
    reg [NB-1:0] d_s, dout_prev;
    reg [W-1:0]  wv;
    integer      i;

    always @(posedge clk_a) begin
        acyc = acyc + 1;
        v_s = valid_a;
        d_s = dout_a;
        t_s = u_dut.toggle_a;      // 层次引用探针: 请求 toggle (a 域)
        // ---- valid 必须 1 拍宽 ----
        if (v_s && v_prev) begin
            $display("  [FAIL] valid 连高 2 拍 @%0t ns", $time/1000.0);
            fails = fails + 1;
        end
        // ---- dout_a 只许在 valid 那一拍变 ----
        if (dchk && !v_s && (d_s !== dout_prev)) begin
            $display("  [FAIL] dout_a 在无 valid 时变化 @%0t ns: %h -> %h",
                     $time/1000.0, dout_prev, d_s);
            fails = fails + 1;
        end
        // ---- valid 检查 ----
        if (v_s) begin
            nval = nval + 1;
            mixed_v = 1'b0;
            tag_v = 24'hxxxxxx;
            for (jv = 0; jv < NW; jv = jv + 1) begin
                wv = d_s[jv*W +: W];
                if (jv == 0)                 tag_v = wv[W-1:8];
                else if (wv[W-1:8] !== tag_v) mixed_v = 1'b1;
                if (wv[7:0] !== jv[7:0])      mixed_v = 1'b1;
            end
            if (mixed_v) begin
                if (neg_mode) begin
                    neg_hits = neg_hits + 1;
                    if (neg_hits <= 2)
                        $display("  [NEG-OK] A6 负对照抓到撕裂 #%0d: tags=%h %h %h %h %h %h (cnt_b=%h)",
                                 neg_hits, d_s[0*W+:W], d_s[1*W+:W], d_s[2*W+:W],
                                 d_s[3*W+:W], d_s[4*W+:W], d_s[5*W+:W], cnt_b);
                end else begin
                    fails = fails + 1;
                    $display("  [FAIL] A1 位混 @%0t ns: %h %h %h %h %h %h (cnt_b=%h)",
                             $time/1000.0, d_s[0*W+:W], d_s[1*W+:W], d_s[2*W+:W],
                             d_s[3*W+:W], d_s[4*W+:W], d_s[5*W+:W], cnt_b);
                end
            end else if (!neg_mode) begin
                if (tag_v > cnt_b) begin
                    fails = fails + 1;
                    $display("  [FAIL] A2 超前 @%0t ns: tag=%h > cnt_b=%h", $time/1000.0, tag_v, cnt_b);
                end
                if (tag_v < cur_flip_tag) begin
                    fails = fails + 1;
                    $display("  [FAIL] A3 陈旧 @%0t ns: tag=%h < 请求时 cnt=%h (拿上一代冒充本次)",
                             $time/1000.0, tag_v, cur_flip_tag);
                end
                if (have_prev && tag_v <= prev_tag) begin
                    fails = fails + 1;
                    $display("  [FAIL] A4 非单调 @%0t ns: tag=%h <= 上一个 %h", $time/1000.0, tag_v, prev_tag);
                end
            end
            prev_tag  = tag_v;
            have_prev = 1;
            lat = acyc - flip_acyc;
            if (lat < lat_min) lat_min = lat;
            if (lat > lat_max) lat_max = lat;
            tot_lat = tot_lat + lat;
            if (VLOG && nval <= 6)
                $display("  [LOG] valid#%0d tag=%h cnt_b=%h lat=%0d a拍 busy=%b", nval, tag_v, cnt_b, lat, busy_a);
        end
        // ---- toggle 翻转 = 一次请求被真正受理 ----
        if (t_s !== t_prev && t_s !== 1'bx && t_prev !== 1'bx) begin
            nflip       = nflip + 1;
            flip_acyc   = acyc - 1;
            cur_flip_tag = c_prev;     // 翻转前一刻的 cnt_b (<= 锁存值 的下界)
            if (VLOG >= 2) $display("  [FLIP] #%0d @%0t ns acyc=%0d nval=%0d req=%b busy=%b",
                                    nflip, $time/1000.0, acyc, nval, req_a, busy_a);
        end
        v_prev    = v_s;
        t_prev    = t_s;
        c_prev    = cnt_b;
        dout_prev = d_s;
    end

    // ---------------- 看门狗 ----------------
    initial begin
        #(WT);
        $display("TIMEOUT  tb_atk_ratio (HA=%0d HB=%0d MODE=%0d) after %0t ns", HA, HB, MODE, $time/1000.0);
        $display("RATIO-RESULT HA=%0d HB=%0d MODE=%0d valids=%0d flips=%0d fails=%0d FAIL", HA, HB, MODE, nval, nflip, fails);
        $finish;
    end

    // ---------------- 超时等待 valid ----------------
    task wait_valid(input integer base, input integer lim);
        integer w;
        begin
            w = 0;
            while (nval == base && w < lim) begin @(negedge clk_a); w = w + 1; end
            if (nval == base) begin
                $display("  [FAIL] A5 死锁 @%0t ns: 请求后 %0d 个 a 拍无 valid (busy=%b)", $time/1000.0, lim, busy_a);
                fails = fails + 1;
                dead  = 1'b1;
            end
        end
    endtask

    // ---------------- 激励 ----------------
    integer base;
    initial begin
        $display("=== tb_atk_ratio: 极端频率比 / 真实用法 (HA=%0dps HB=%0dps MODE=%0d NW=%0d) ===", HA, HB, MODE, NW);
        repeat (8) @(posedge clk_b_g);
        repeat (8) @(posedge clk_a);
        rst_n = 1'b1;
        repeat (12) @(posedge clk_a);
        dchk = 1'b1;

        if (MODE == 0) req_r = 1'b1;

        while (nval < NVAL && !dead) begin
            if (MODE == 1) begin
                k = 0;
                while (busy_a && k < 4000) begin @(negedge clk_a); k = k + 1; end
                base = nval;
                @(negedge clk_a); req_r = 1'b1; nreq = nreq + 1;
                @(negedge clk_a); req_r = 1'b0;
                wait_valid(base, 4000);
            end else if (MODE == 2) begin
                base = nval;
                @(negedge clk_a); req_r = 1'b1; nreq = nreq + 1;
                @(negedge clk_a); req_r = 1'b0;
                for (k = 0; k < KA; k = k + 1) @(negedge clk_a);
            end else begin
                @(negedge clk_a);        // MODE 0/3: 自由跑, 只等计数
            end
            if (MODE == 1 && k >= 4000) dead = 1'b1;   // 等不到空闲
        end

        if (VLOG >= 2) $display("  [LOOPEXIT] @%0t ns nval=%0d nflip=%0d nreq=%0d",
                                $time/1000.0, nval, nflip, nreq);
        // ---- 收尾: 停 req, 等握手静止, 核对 翻转数 == valid 数 ----
        req_r = 1'b0;
        stop  = 1'b1;
        k = 0;
        while (busy_a && k < 4000) begin @(negedge clk_a); k = k + 1; end
        repeat (20) @(negedge clk_a);
        if (busy_a) begin
            $display("  [FAIL] A5 收尾: 停 req 后 busy 仍挂高 (死锁)"); fails = fails + 1;
        end
        if (nval != nflip) begin
            $display("  [FAIL] A5 计数: valid=%0d != toggle 翻转=%0d (丢失或幻影)", nval, nflip);
            fails = fails + 1;
        end

        // ---- A6 负对照: 撕裂第 3 字, 检查器必须抓到 ----
        stop = 1'b0; neg_phase = 1'b1; req_r = 1'b0;
        repeat (4) @(negedge clk_a);
        torn = 1'b1; neg_mode = 1;
        for (k = 0; k < 4; k = k + 1) begin
            base = nval;
            while (busy_a) @(negedge clk_a);
            @(negedge clk_a); req_r = 1'b1;
            @(negedge clk_a); req_r = 1'b0;
            wait_valid(base, 4000);
        end
        neg_mode = 0; torn = 1'b0;
        if (neg_hits == 0) begin
            $display("  [FAIL] A6 负对照: 撕裂一次都没抓到 => A1 是空判据"); fails = fails + 1;
        end else
            $display("  [NEG-OK] A6 负对照: 撕裂被抓到 %0d 次 => A1 有判别力", neg_hits);

        if (nval > 0) $display("  [INFO] 延迟(请求 toggle 翻转 -> valid 捕获) = %0d/%0d/%0d a拍 (min/avg/max)",
                               lat_min, tot_lat/nval, lat_max);
        $display("RATIO-RESULT HA=%0d HB=%0d MODE=%0d valids=%0d flips=%0d fails=%0d %s",
                 HA, HB, MODE, nval, nflip, fails, (fails == 0) ? "PASS" : "FAIL");
        $finish;
    end
endmodule
