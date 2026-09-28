`timescale 1ps/1ps
//=============================================================================
// tb_atk_req.v -- 对抗门 D: req 的极端用法
//-----------------------------------------------------------------------------
// 单元门只测了"忙时连发 3 拍"和"valid 后立刻再发"。本门打:
//   D1 请求脉冲相位扫描 (亚周期, 覆盖恰好 1 个 a 沿) => 每请求恰好 1 valid
//   D2 **不覆盖任何 a 沿的脉冲** (1ps 毛刺 / 两个沿之间的窄脉冲) => 必须被静默丢弃,
//      不许冒 valid, 且随后正常请求仍必须工作 (状态未被污染)
//   D3 req 常高 (busy 期间一直高) 然后释放 => 只算一次请求
//   D4 **契约判据**: 每一个 a 沿上 "req=1 且 busy=0 却没翻转" 或 "翻转了却没有合法请求"
//      都必须报错 (用层次探针 u_dut.toggle_a 判定翻转)
//   D5 最小间隔背靠背 (valid 后立刻发) x 200 => 全相干 + 严格单调 (重复/陈旧必现形)
//=============================================================================
module tb_atk_req;
    parameter W = 32, NW = 8, NB = NW*W;   // 真实集成参数 (wrapper_p4.v:2377)

    integer HA = 2000, HB = 4000, STEP = 100, WT = 2000000000, NB2B = 200;
    integer LCM = 8000, pstep = 100, nph = 80, pa, pb, xx, yy, tt;

    reg clk_a = 0, clk_b = 0, rst_n = 1;
    wire clk_b_g = clk_b;

    initial begin
        $value$plusargs("HA=%d",   HA);
        $value$plusargs("HB=%d",   HB);
        $value$plusargs("STEP=%d", STEP);
        $value$plusargs("WT=%d",   WT);
        $value$plusargs("NB2B=%d", NB2B);
        pa = 2*HA; pb = 2*HB; xx = pa; yy = pb;
        while (yy != 0) begin tt = xx % yy; xx = yy; yy = tt; end
        LCM = (pa / xx) * pb;
        nph = LCM / STEP; if (nph > 256) nph = 256;
        pstep = LCM / nph;
        $display("=== tb_atk_req: HA=%0d HB=%0d LCM=%0d nph=%0d ===", HA, HB, LCM, nph);
        fork
            forever #(HA) clk_a = ~clk_a;
            forever #(HB) clk_b = ~clk_b;
        join
    end

    reg [23:0] cnt_b = 24'd0;
    always @(posedge clk_b_g) cnt_b <= cnt_b + 24'd1;

    reg [NB-1:0] din_b;
    integer      wi;
    always @* begin
        for (wi = 0; wi < NW; wi = wi + 1)
            din_b[wi*W +: W] = {cnt_b, wi[7:0]};
    end

    reg  req_r = 1'b0;
    wire req_a = req_r;
    wire busy_a, valid_a;
    wire [NB-1:0] dout_a;
    snap_cdc #(.W(W), .NW(NW)) u_dut (
        .clk_a(clk_a), .rst_n(rst_n), .req_a(req_a),
        .busy_a(busy_a), .dout_a(dout_a), .valid_a(valid_a),
        .clk_b(clk_b_g), .din_b(din_b)
    );

    integer acyc = 0, nval = 0, nflip = 0, nreq = 0, fails = 0;
    integer jv, k, base, p, dead = 0;
    reg [23:0] tag_v, prev_tag = 24'd0, cur_flip_tag = 24'd0, c_prev = 24'd0;
    reg        mixed_v, v_s, v_prev, t_s, t_prev = 1'b0, dchk = 1'b0;
    reg        req_p = 0, busy_p = 0, t_p = 0, flip_ok = 1;
    reg        busy_s = 0;                  // 本沿读到的 busy (与 v_s 同拍, 同为上一沿后的值)
    reg [NB-1:0] last_v_dout = 0;
    integer    bdrop = 0, bdrop_valid = 0, bdrop_old = 0;
    reg [NB-1:0] d_s, dout_prev;
    reg [W-1:0]  wv;

    always @(posedge clk_a) begin
        acyc = acyc + 1;
        v_s = valid_a; d_s = dout_a; t_s = u_dut.toggle_a; busy_s = busy_a;
        // ---- D4 契约: 上一个沿的 req/busy/toggle 必须自洽 ----
        if (dchk) begin
            if (req_p && !busy_p && !(t_s !== t_prev)) begin
                fails = fails + 1;
                $display("  [FAIL] D4 空闲期请求被吞 @%0t ns (req=1 busy=0 但 toggle 没翻)", $time/1000.0);
            end
            if ((t_s !== t_prev) && t_s !== 1'bx && t_prev !== 1'bx && !(req_p && !busy_p)) begin
                fails = fails + 1;
                $display("  [FAIL] D4 无请求却翻转 @%0t ns", $time/1000.0);
            end
        end
        if (dchk && !v_s && (d_s !== dout_prev)) begin
            fails = fails + 1;
            $display("  [FAIL] D0 dout 无 valid 时变化 @%0t", $time/1000.0);
        end
        if (v_s && v_prev) begin fails = fails + 1; $display("  [FAIL] D0 valid 连高 @%0t", $time/1000.0); end
        if (v_s) begin
            nval = nval + 1;
            mixed_v = 0; tag_v = 24'hxxxxxx;
            for (jv = 0; jv < NW; jv = jv + 1) begin
                wv = d_s[jv*W +: W];
                if (jv == 0)                 tag_v = wv[W-1:8];
                else if (wv[W-1:8] !== tag_v) mixed_v = 1'b1;
                if (wv[7:0] !== jv[7:0])      mixed_v = 1'b1;
            end
            if (mixed_v) begin
                fails = fails + 1;
                $display("  [FAIL] D1 位混 @%0t ns: %h %h %h %h %h %h", $time/1000.0,
                         d_s[0*W+:W], d_s[1*W+:W], d_s[2*W+:W], d_s[3*W+:W], d_s[4*W+:W], d_s[5*W+:W]);
            end else begin
                if (tag_v > cnt_b)          begin fails = fails + 1; $display("  [FAIL] D1 超前 @%0t tag=%h cnt=%h", $time/1000.0, tag_v, cnt_b); end
                if (tag_v < cur_flip_tag)   begin fails = fails + 1; $display("  [FAIL] D1 陈旧 @%0t tag=%h req_cnt=%h", $time/1000.0, tag_v, cur_flip_tag); end
                if (jv >= 0 && nval > 1 && tag_v <= prev_tag) begin
                    fails = fails + 1; $display("  [FAIL] D1 非单调 @%0t tag=%h <= %h", $time/1000.0, tag_v, prev_tag);
                end
            end
            prev_tag = tag_v;
            last_v_dout = d_s;              // D6: 记住"当前这一代"的数据
        end
        // ---- D6: busy 落下那一拍不许被当成完成信号 ----
        //   观测到 busy 由 1->0 (发生在上一沿) 时: valid 必须还是 0, 且 dout 仍是上一代
        if (dchk && busy_p && !busy_s) begin
            bdrop = bdrop + 1;
            if (v_s) begin
                bdrop_valid = bdrop_valid + 1;
                $display("  [FAIL] D6 busy 落下同拍 valid 竟已为高 @%0t", $time/1000.0);
                fails = fails + 1;
            end
            if (d_s !== last_v_dout) begin
                bdrop_old = bdrop_old + 1;
                $display("  [FAIL] D6 busy 落下同拍 dout 已更新 (应仍是上一代) @%0t", $time/1000.0);
                fails = fails + 1;
            end
        end
        if (t_s !== t_prev && t_s !== 1'bx && t_prev !== 1'bx) cur_flip_tag = c_prev;
        if (t_s !== t_prev && t_s !== 1'bx && t_prev !== 1'bx) nflip = nflip + 1;
        v_prev = v_s; t_prev = t_s; c_prev = cnt_b; dout_prev = d_s;
        req_p = req_a; busy_p = busy_a; t_p = t_s;
    end

    initial begin
        #(WT);
        $display("REQ-RESULT HA=%0d HB=%0d valids=%0d flips=%0d reqs=%0d fails=%0d FAIL", HA, HB, nval, nflip, nreq, fails);
        $finish;
    end

    task wait_valid(input integer b0, input integer lim);
        integer w;
        begin
            w = 0;
            while (nval == b0 && w < lim) begin @(negedge clk_a); w = w + 1; end
            if (nval == b0) begin
                $display("  [FAIL] 死锁 @%0t: %0d 拍无 valid (busy=%b)", $time/1000.0, lim, busy_a);
                fails = fails + 1; dead = 1;
            end
        end
    endtask

    integer v0, v0f, n_ok;
    initial begin
        $display("=== 门 D: req 极端用法 ===");
        rst_n = 1'b0;
        repeat (8) @(posedge clk_b_g);
        repeat (8) @(posedge clk_a);
        rst_n = 1'b1;
        repeat (12) @(posedge clk_a);
        dchk = 1'b1;

        // ---- D1: 亚周期相位扫描 ----
        n_ok = 0;
        for (p = 0; p < nph; p = p + 1) begin
            while (busy_a) @(negedge clk_a);
            k = LCM - ($time % LCM); if (k != LCM) #(k);
            v0 = nval; nreq = nreq + 1;
            #(p * pstep);
            req_r = 1'b1;
            #(2*HA + 1000);
            req_r = 1'b0;
            wait_valid(v0, 4000);
            if (dead) p = nph;
        end
        $display("  [INFO] D1 相位扫描 %0d 个相位: 请求 %0d / valid %0d", nph, nreq, nval);
        if (nval != nreq) begin
            $display("  [FAIL] D1 相位扫描: valid=%0d != 请求=%0d (丢/重)", nval, nreq); fails = fails + 1;
        end else
            $display("  [PASS] D1 相位扫描: %0d 个亚周期相位, 每请求恰好 1 valid, 数据全相干", nph);

        // ---- D2: 不覆盖任何 a 沿的脉冲 => 必须被静默丢弃 ----
        //   a 沿在 HA 的奇数倍; 网格对齐后 $time 是 2*HA 的整数倍 (即 a 的 negedge)。
        //   glitch 时刻 = 网格 + p*pstep + 50ps => mod 2*HA 永远不是奇数倍 (pstep 是 100 的倍数)
        v0 = nval; n_ok = nval;
        for (p = 0; p < 40; p = p + 1) begin
            while (busy_a) @(negedge clk_a);
            k = LCM - ($time % LCM); if (k != LCM) #(k);
            #(p * pstep % (2*HA));
            #(50);
            req_r = 1'b1; #(1); req_r = 1'b0;    // 1ps 毛刺, 必不覆盖 a 沿
            nreq = nreq + 1;
            repeat (6) @(negedge clk_a);
        end
        // 再补一类: 完全落在**两个 posedge 之间**的宽脉冲 (宽 HA, 仍然不覆盖任何沿)
        //   锚在 posedge 上: [沿 + HA/2 + off, 沿 + 3HA/2 + off], off < HA/2 => 不碰两侧沿
        for (p = 0; p < 10; p = p + 1) begin
            while (busy_a) @(negedge clk_a);
            @(posedge clk_a);
            #(HA/2 + (p % 4) * (HA/8));
            req_r = 1'b1; #(HA); req_r = 1'b0;
            nreq = nreq + 1;
            repeat (6) @(negedge clk_a);
        end
        repeat (20) @(negedge clk_a);
        if (nval != n_ok) begin
            $display("  [FAIL] D2 毛刺请求冒出了 %0d 次 valid (应被静默丢弃)", nval - n_ok);
            fails = fails + 1;
        end else
            $display("  [PASS] D2 50 个不覆盖 a 沿的窄脉冲 (含 1500ps 宽): 全部静默丢弃, 无 valid");
        // 毛刺后必须仍能正常工作
        base = nval; @(negedge clk_a); req_r = 1; @(negedge clk_a); req_r = 0;
        nreq = nreq + 1;
        wait_valid(base, 4000);
        if (nval == base + 1) $display("  [PASS] D2b 毛刺后正常请求仍工作");
        else begin $display("  [FAIL] D2b 毛刺后请求失效"); fails = fails + 1; end

        // ---- D3: req 常高 (含 busy 期间) 再释放 ----
        while (busy_a) @(negedge clk_a);
        v0 = nval; v0f = nflip;
        req_r = 1'b1;
        repeat (200) @(negedge clk_a);      // 一直高: 期间只受理 1 次 (busy 挡住后面)
        req_r = 1'b0;
        while (busy_a) @(negedge clk_a);
        repeat (20) @(negedge clk_a);
        $display("  [INFO] D3 req 常高 200 拍: valid 增 %0d, 翻转增 %0d", nval - v0, nflip - v0f);
        if (nval - v0 != nflip - v0f) begin
            $display("  [FAIL] D3 req 常高期间 valid 与翻转数不等 (丢/重)"); fails = fails + 1;
        end else if (nval - v0 < 2) begin
            $display("  [FAIL] D3 req 常高 200 拍只出了 %0d 次 valid (连续用法被饿死)", nval - v0);
            fails = fails + 1;
        end else
            $display("  [PASS] D3 req 恒高 = 连续重触发 (%0d 次, 与翻转 1:1); 注意这与'1 拍脉冲'契约不同", nval - v0);

        // ---- D5: 最小间隔背靠背 x NB2B ----
        v0 = nval;
        for (p = 0; p < NB2B; p = p + 1) begin
            // valid 后立刻 (下一拍) 再发
            base = nval;
            @(negedge clk_a); req_r = 1'b1;
            @(negedge clk_a); req_r = 1'b0;
            nreq = nreq + 1;
            wait_valid(base, 4000);
            if (dead) p = NB2B;
        end
        $display("  [INFO] D5 最小间隔背靠背: valid 增 %0d (期望 %0d)", nval - v0, NB2B);
        if (nval - v0 != NB2B) begin $display("  [FAIL] D5 次数不对"); fails = fails + 1; end

        while (busy_a) @(negedge clk_a);
        repeat (20) @(negedge clk_a);
        if (nval != nflip) begin
            $display("  [FAIL] 计数: valid=%0d != flip=%0d", nval, nflip); fails = fails + 1;
        end
        $display("  [INFO] D6 busy 落下拍数=%0d (其中 valid 已高 %0d / dout 已换 %0d) => busy 落下比 valid 早一拍", bdrop, bdrop_valid, bdrop_old);
        $display("REQ-RESULT HA=%0d HB=%0d valids=%0d flips=%0d reqs=%0d fails=%0d %s",
                 HA, HB, nval, nflip, nreq, fails, (fails == 0) ? "PASS" : "FAIL");
        $finish;
    end
endmodule
