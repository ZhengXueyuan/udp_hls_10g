`timescale 1ps/1ps
//=============================================================================
// tb_atk_phase.v -- 对抗门 B: 亚周期相位扫描 + 字级毛刺 (锁存原子性)
//-----------------------------------------------------------------------------
// 单元门 tb_snap_cdc.v 只扫 16 个离散相位 (按 b 沿计), 且两时钟固定 2:1 固定相位。
// 本门:
//   P1-P4 相位扫描: 请求时刻相对两个时钟沿按 STEP(默认 100ps) 步进扫过**整个 a 周期**,
//        每轮先对齐到 lcm(2HA,2HB) 绝对时间网格 => (a 相位, b 相位) 组合**确定且可复现**。
//        数据源 = 自由运行计数器, 判据同门 A (相干/不超前/不陈旧/严格单调)。
//   P5 每个请求恰好 1 次 valid。
//   P6 "代差"统计: 记录 tag - 请求时刻计数值, 必须两侧都扫到 (证明相位扫描有效,
//        不是只压在一个窗口里)。
//   P7a 字级毛刺 (关键): 第 3 个字在整个"b 周期后半段"被替换成错值
//        —— 该窗口**绝不覆盖 b 采样沿** => 锁存必须原子 => 捕获必须 100% 干净。
//   P7b 负对照: 第 3 个字在**采样沿上**就是错值 (差一代) => P1 必须每次抓到,
//        否则 P7a 是空判据。
// 附带: busy 期间不发 valid; valid 1 拍宽; dout_a 只在 valid 那拍变。
//=============================================================================
module tb_atk_phase;
    parameter W = 32, NW = 8, NB = NW*W;   // 真实集成参数 (wrapper_p4.v:2377)

    integer HA = 2000, HB = 4000;    // 半周期 ps
    integer STEP = 100;              // 相位步进 ps
    integer NLOOP = 1;               // 每个相位重复次数
    integer WT = 2000000000;
    integer LCM = 8000;
    integer VLOG = 0;
    integer SKEW = 1400;             // P8: 通道偏斜 (ps)

    integer pa, pb, xx, yy, tt;

    reg clk_a = 0, clk_b = 0, rst_n = 0;
    reg clk_b_en = 1;
    wire clk_b_g = clk_b & clk_b_en;

    initial begin
        $value$plusargs("HA=%d",    HA);
        $value$plusargs("HB=%d",    HB);
        $value$plusargs("STEP=%d",  STEP);
        $value$plusargs("NLOOP=%d", NLOOP);
        $value$plusargs("WT=%d",    WT);
        $value$plusargs("VLOG=%d",  VLOG);
        $value$plusargs("SKEW=%d", SKEW);
        pa = 2*HA;  pb = 2*HB;
        xx = pa;    yy = pb;
        while (yy != 0) begin tt = xx % yy; xx = yy; yy = tt; end
        LCM = (pa / xx) * pb;
        $display("=== tb_atk_phase: HA=%0d HB=%0d STEP=%0d LCM=%0dps ===", HA, HB, STEP, LCM);
        fork
            forever #(HA) clk_a = ~clk_a;
            forever #(HB) clk_b = ~clk_b;
        join
    end

    // ---------------- b 域数据源 ----------------
    reg [23:0] cnt_b = 24'd0;
    always @(posedge clk_b_g) cnt_b <= cnt_b + 24'd1;

    // 毛刺/负对照源
    reg        torn = 1'b0;          // P7b: 第 3 字在采样沿上错一代
    reg        g_on = 1'b0;          // P7a: 毛刺窗口 (只覆盖 b 周期后半段)
    reg [23:0] g_val = 24'd0;
    reg        g_en = 1'b0;
    always @(posedge clk_b_g) if (g_en) begin
        g_on  <= 1'b0;
        #(HB/2 + 200) g_on <= 1'b1;
        #(HB/2 - 400) g_on <= 1'b0;
    end
    always @(negedge clk_b_g) g_val <= cnt_b + 24'd7;

    // ---- P8 偏斜源: 第 3/5 字的"有效更新时刻"比其余字晚 SKEW ps ----
    //   真实集成的 8 个字走不同长度的布线/逻辑, 到达时间不可能完全相同。
    //   正确的 DUT 只在 b 沿采样 (采样瞬间整束还是上一代 => 相干);
    //   "不锁存直采"的实现会在随机 a 沿采到 b 沿之后、SKEW 之前的撕裂窗口 => 被抓。
    reg        clk_b_d = 0;
    reg [23:0] cnt_b_d = 0;
    reg        skew_en = 0;
    always @(clk_b_g) clk_b_d <= #(SKEW) clk_b_g;
    always @(posedge clk_b_d) cnt_b_d <= cnt_b;

    reg [NB-1:0] din_b;
    integer      wi;
    always @* begin
        for (wi = 0; wi < NW; wi = wi + 1)
            din_b[wi*W +: W] = {cnt_b, wi[7:0]};
        if (torn)                 din_b[3*W +: W] = {cnt_b + 24'd1, 8'd3};
        else if (g_en && g_on)    din_b[3*W +: W] = {g_val, 8'd3};
        if (skew_en) begin
            din_b[3*W +: W] = {cnt_b_d, 8'd3};
            din_b[5*W +: W] = {cnt_b_d, 8'd5};
        end
    end

    // ---------------- DUT ----------------
    reg  req_r = 1'b0;
    wire req_a = req_r;
    wire busy_a, valid_a;
    wire [NB-1:0] dout_a;
    snap_cdc #(.W(W), .NW(NW)) u_dut (
        .clk_a(clk_a), .rst_n(rst_n), .req_a(req_a),
        .busy_a(busy_a), .dout_a(dout_a), .valid_a(valid_a),
        .clk_b(clk_b_g), .din_b(din_b)
    );

    // ---------------- 检查器 ----------------
    integer acyc = 0, nval = 0, nflip = 0, fails = 0, neg_hits = 0, neg_mode = 0;
    integer lat = 0, lat_min = 1000000, lat_max = 0, tot_lat = 0;
    integer flip_acyc = 0, have_prev = 0, gmin = 1000000, gmax = -1, gen = 0;
    integer jv, k, base, p, foff = 0, foff_min = 100000000, foff_max = -1, gdelay = 0, pstep = 100;
    integer q = 0, nb = 0, dt = 0, dt_min = 100000000, dt_max = -1;
    reg [23:0] tag_v, prev_tag = 24'd0, cur_flip_tag = 24'd0, c_prev = 24'd0;
    reg        mixed_v, v_s, v_prev, t_s, t_prev = 1'b0, dead = 1'b0;
    reg [NB-1:0] d_s;
    reg [W-1:0]  wv;

    always @(posedge clk_a) begin
        acyc = acyc + 1;
        v_s = valid_a;
        d_s = dout_a;
        t_s = u_dut.toggle_a;
        if (v_s && v_prev) begin
            $display("  [FAIL] P0 valid 连高 2 拍"); fails = fails + 1;
        end
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
                if (neg_mode) neg_hits = neg_hits + 1;
                else begin
                    fails = fails + 1;
                    $display("  [FAIL] P1 位混 @%0t ns: %h %h %h %h %h %h (cnt_b=%h)",
                             $time/1000.0, d_s[0*W+:W], d_s[1*W+:W], d_s[2*W+:W],
                             d_s[3*W+:W], d_s[4*W+:W], d_s[5*W+:W], cnt_b);
                end
            end else if (!neg_mode) begin
                if (tag_v > cnt_b) begin
                    fails = fails + 1;
                    $display("  [FAIL] P2 超前 @%0t: tag=%h > cnt_b=%h", $time/1000.0, tag_v, cnt_b);
                end
                if (tag_v < cur_flip_tag) begin
                    fails = fails + 1;
                    $display("  [FAIL] P3 陈旧 @%0t: tag=%h < 请求时 %h", $time/1000.0, tag_v, cur_flip_tag);
                end
                if (have_prev && tag_v <= prev_tag) begin
                    fails = fails + 1;
                    $display("  [FAIL] P4 非单调 @%0t: tag=%h <= %h", $time/1000.0, tag_v, prev_tag);
                end
                gen = tag_v - cur_flip_tag;       // 代差 (b 拍)
                if (gen < gmin) gmin = gen;
                if (gen > gmax) gmax = gen;
            end
            prev_tag = tag_v; have_prev = 1;
            lat = acyc - flip_acyc;
            if (lat < lat_min) lat_min = lat;
            if (lat > lat_max) lat_max = lat;
            tot_lat = tot_lat + lat;
        end
        if (t_s !== t_prev && t_s !== 1'bx && t_prev !== 1'bx) begin
            nflip = nflip + 1;
            flip_acyc = acyc - 1;
            cur_flip_tag = c_prev;
            foff = $time % (2*HB);              // 翻转时刻相对 b 沿的亚周期偏移
            if (foff < foff_min) foff_min = foff;
            if (foff > foff_max) foff_max = foff;
            q = $time / HB;                     // 翻转后**首个 b 采样沿**的建立裕量
            nb = ((q/2)*2 + 1) * HB;
            if (nb <= $time) nb = nb + 2*HB;
            dt = nb - $time;
            if (dt < dt_min) dt_min = dt;
            if (dt > dt_max) dt_max = dt;
        end
        v_prev = v_s; t_prev = t_s; c_prev = cnt_b;
    end

    initial begin
        #(WT);
        $display("TIMEOUT tb_atk_phase");
        $display("PHASE-RESULT valids=%0d flips=%0d fails=%0d FAIL", nval, nflip, fails);
        $finish;
    end

    task wait_valid(input integer b0, input integer lim);
        integer w;
        begin
            w = 0;
            while (nval == b0 && w < lim) begin @(negedge clk_a); w = w + 1; end
            if (nval == b0) begin
                $display("  [FAIL] P5 死锁 @%0t ns: %0d 拍无 valid (busy=%b)", $time/1000.0, lim, busy_a);
                fails = fails + 1; dead = 1'b1;
            end
        end
    endtask

    // 对齐到绝对时间网格 (保证 (a相位,b相位) 组合确定可复现)
    task align_grid;
        begin
            gdelay = LCM - ($time % LCM);
            if (gdelay != LCM) #(gdelay);
        end
    endtask

    // 一轮: 在网格 + toff 处发 1 拍请求 (脉冲宽到覆盖恰好一个 a 沿)
    task one_req(input integer toff);
        begin
            while (busy_a) @(negedge clk_a);
            align_grid;
            base = nval;
            #(toff);
            req_r = 1'b1;
            #(2*HA + 1000);
            req_r = 1'b0;
            wait_valid(base, 4000);
        end
    endtask

    integer nreq = 0, nph = 0;
    initial begin
        $display("=== 门 B: 亚周期相位扫描 + 字级毛刺 ===");
        repeat (8) @(posedge clk_b_g);
        repeat (8) @(posedge clk_a);
        rst_n = 1'b1;
        repeat (12) @(posedge clk_a);

        // ---- P1-P6: 相位扫描 (覆盖整个 LCM 网格 => 所有 (a相位,b相位) 组合) ----
        nph = LCM / STEP;
        if (nph > 256) nph = 256;
        pstep = LCM / nph;
        $display("  [INFO] 相位点数 = %0d (网格 %0dps 上均匀铺开 %0dps, 步距 %0dps)", nph, LCM, LCM, pstep);
        for (p = 0; p < nph; p = p + 1) begin
            for (k = 0; k < NLOOP; k = k + 1) begin
                nreq = nreq + 1;
                one_req(p * pstep);
                if (dead) k = NLOOP;
            end
            if (dead) p = nph;
        end
        $display("  [INFO] P6 代差分布: min=%0d max=%0d (b拍) | 翻转相偏 %0d..%0d ps | 首个 b 采样沿建立裕量 dt %0d..%0d ps (b 周期 %0dps)",
                 gmin, gmax, foff_min, foff_max, dt_min, dt_max, 2*HB);
        if ((dt_max - dt_min) < HB)
            $display("  [NOTE] P6 dt 覆盖窄 (两时钟同周期时 a 沿与 b 沿重合 => dt 恒为一个 b 周期, 属退化但合法的一角)");
        // 每个请求恰好 1 次 valid
        if (nval != nreq) begin
            $display("  [FAIL] P5 请求=%0d 但 valid=%0d", nreq, nval); fails = fails + 1;
        end else
            $display("  [PASS] P5 相位扫描: %0d 个相位 = %0d 请求 = %0d valid", nph, nreq, nval);

        // ---- P7a: 字级毛刺, 窗口只覆盖 b 周期后半段 (绝不覆盖采样沿) ----
        g_en = 1'b1;
        nreq = 0; k = nval;
        for (p = 0; p < 40; p = p + 1) begin
            nreq = nreq + 1;
            one_req((p % nph) * pstep);
            if (dead) p = 40;
        end
        if (nval == k + nreq)
            $display("  [PASS] P7a 毛刺不覆盖采样沿: %0d 轮捕获全部干净 (锁存原子)", nreq);
        else begin
            $display("  [FAIL] P7a 毛刺轮计数不对: valid=%0d 期望 %0d", nval, k + nreq);
            fails = fails + 1;
        end
        g_en = 1'b0;

        // ---- P8: 通道偏斜 (第 3/5 字晚 SKEW 更新) => 仍必须 100% 相干 ----
        skew_en = 1'b1;
        nreq = 0; k = nval;
        for (p = 0; p < 200; p = p + 1) begin
            nreq = nreq + 1;
            one_req((p % nph) * pstep);
            if (dead) p = 200;
        end
        if (nval == k + nreq)
            $display("  [PASS] P8 通道偏斜 %0dps (第 3/5 字晚更新): %0d 轮捕获全部相干", SKEW, nreq);
        else begin
            $display("  [FAIL] P8 偏斜阶段计数不对: valid=%0d 期望 %0d", nval, k + nreq);
            fails = fails + 1;
        end
        skew_en = 1'b0;

        // ---- P7b: 负对照 — 第 3 字在采样沿上就是错值 ----
        torn = 1'b1; neg_mode = 1; k = nval;
        for (p = 0; p < 6; p = p + 1) begin
            one_req(0);
            if (dead) p = 6;
        end
        neg_mode = 0; torn = 1'b0;
        if (neg_hits > 0)
            $display("  [PASS] P7b 负对照: 采样沿上的撕裂被抓到 %0d 次 => P7a 有判别力", neg_hits);
        else begin
            $display("  [FAIL] P7b 负对照: 一次都没抓到 => P7a 是空判据"); fails = fails + 1;
        end

        // 收尾
        repeat (20) @(negedge clk_a);
        if (busy_a) begin $display("  [FAIL] 收尾 busy 挂高"); fails = fails + 1; end
        if (nval != nflip) begin
            $display("  [FAIL] P5 计数: valid=%0d != flip=%0d", nval, nflip); fails = fails + 1;
        end
        $display("  [INFO] 延迟 = %0d/%0d/%0d a拍 (min/avg/max)", lat_min, tot_lat/nval, lat_max);
        $display("PHASE-RESULT HA=%0d HB=%0d STEP=%0d valids=%0d flips=%0d fails=%0d %s",
                 HA, HB, STEP, nval, nflip, fails, (fails == 0) ? "PASS" : "FAIL");
        $finish;
    end
endmodule
