`timescale 1ps/1ps
//=============================================================================
// tb_atk_reset.v -- 对抗门 C: 复位
//-----------------------------------------------------------------------------
// 单元门判据 6 只做了"飞行中复位, 宽脉冲, req=0"这一个点。本门打:
//   C1 复位脉冲**极窄** (1ps / 1 个 a 周期), 相位按 STEP 扫过整个 LCM 网格
//   C2 复位**恰在飞行中** (发请求后等 N 拍再复位), N 也扫
//   C3 复位期间 **req 恒高**, 释放后仍恒高 (集成真实用法)
//   C4 clk_b **停摆期间**复位, 且释放时 clk_b 仍在停 => 恢复后握手必须补完
//   C5 **上电不复位** (rst_n 常高) => 契约边界 (X 会不会自愈)
// 判据:
//   R1 释放后 busy 必须在有界时间内落下 (不许死锁)
//   R2 释放到"下一次显式请求"之间不许冒出 valid (幻影 valid)
//   R3 恢复后第一次快照的 tag 必须 >= 释放时刻的计数值 (不许给复位前的陈旧值/全 0)
//   R4 valid 数 == toggle 翻转数 (不丢不重)
//   附带: 复位期间 valid 必须为 0
//=============================================================================
module tb_atk_reset;
    parameter W = 32, NW = 8, NB = NW*W;   // 真实集成参数 (wrapper_p4.v:2377)

    integer HA = 2000, HB = 4000, STEP = 100, MODE = 0, WT = 2000000000, NPULSE = 40, VLOG = 0;
    integer LCM = 8000, pstep = 100, nph = 80;

    integer pa, pb, xx, yy, tt, q, nb, dt;

    reg clk_a = 0, clk_b = 0, rst_n = 1;   // MODE9 = 上电不复位; 其余模式在 initial 里拉低
    reg clk_b_en = 1;
    wire clk_b_g = clk_b & clk_b_en;
    reg clk_a_en = 1;                      // MODE5: a 域停摆
    wire clk_a_g = clk_a & clk_a_en;

    initial begin
        $value$plusargs("HA=%d",     HA);
        $value$plusargs("HB=%d",     HB);
        $value$plusargs("STEP=%d",   STEP);
        $value$plusargs("MODE=%d",   MODE);
        $value$plusargs("WT=%d",     WT);
        $value$plusargs("NPULSE=%d", NPULSE);
        $value$plusargs("VLOG=%d",   VLOG);
        pa = 2*HA; pb = 2*HB; xx = pa; yy = pb;
        while (yy != 0) begin tt = xx % yy; xx = yy; yy = tt; end
        LCM = (pa / xx) * pb;
        nph = LCM / STEP;
        if (nph > 256) nph = 256;
        pstep = LCM / nph;
        $display("=== tb_atk_reset: HA=%0d HB=%0d MODE=%0d LCM=%0d nph=%0d ===",
                 HA, HB, MODE, LCM, nph);
        fork
            forever #(HA) clk_a = ~clk_a;
            forever #(HB) clk_b = ~clk_b;
        join
    end

    // ---------------- b 域数据源: 自由运行计数器 ----------------
    reg [23:0] cnt_b = 24'd0;
    always @(posedge clk_b_g) cnt_b <= cnt_b + 24'd1;

    reg [NB-1:0] din_b;
    integer      wi;
    always @* begin
        for (wi = 0; wi < NW; wi = wi + 1)
            din_b[wi*W +: W] = {cnt_b, wi[7:0]};
    end

    // ---------------- DUT ----------------
    reg  req_r = 1'b0;
    wire req_a = req_r;
    wire busy_a, valid_a;
    wire [NB-1:0] dout_a;
    snap_cdc #(.W(W), .NW(NW)) u_dut (
        .clk_a(clk_a_g), .rst_n(rst_n), .req_a(req_a),
        .busy_a(busy_a), .dout_a(dout_a), .valid_a(valid_a),
        .clk_b(clk_b_g), .din_b(din_b)
    );

    // ---------------- 检查器 ----------------
    integer acyc = 0, nval = 0, nflip = 0, nchg = 0, nabort = 0, fails = 0, phantom = 0, val_during_rst = 0;
    integer jv, k, base, p, gen = 0;
    reg [23:0] tag_v, prev_tag = 24'd0, cur_flip_tag = 24'd0, c_prev = 24'd0;
    reg        mixed_v, v_s, v_prev, t_s, t_prev = 1'b0, dead = 1'b0;
    reg        gate_open = 1'b0;     // 0 = 复位恢复窗口: 禁止任何 valid
    reg        rst_p = 1'b1;
    reg        req_p = 1'b0, busy_p = 1'b0;   // 上一个 a 沿采到的 req_a / busy_a
    reg        rst_win = 1'b0;           // 激励驱动的复位窗口 (亚周期脉冲监视器看不见)
    reg        chk_on = 1'b0;
    reg [NB-1:0] d_s;
    reg [W-1:0]  wv;
    integer      lat = 0, lat_max = 0, hmin = 0, hmax = 0;

    always @(posedge clk_a) begin
        acyc = acyc + 1;
        v_s = valid_a;
        d_s = dout_a;
        t_s = u_dut.toggle_a;
        if (!rst_n && v_s) begin
            val_during_rst = val_during_rst + 1;
            $display("  [FAIL] R0 复位期间 valid 为高 @%0t ns", $time/1000.0);
            fails = fails + 1;
        end
        if (chk_on && !gate_open && v_s) begin
            phantom = phantom + 1;
            $display("  [FAIL] R2 幻影 valid @%0t ns (复位释放后、显式请求前): tag=%h cnt_b=%h",
                     $time/1000.0, d_s[W-1:8], cnt_b);
            fails = fails + 1;
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
                fails = fails + 1;
                $display("  [FAIL] R-coh 位混 @%0t ns: %h %h %h %h %h %h (cnt_b=%h)",
                         $time/1000.0, d_s[0*W+:W], d_s[1*W+:W], d_s[2*W+:W],
                         d_s[3*W+:W], d_s[4*W+:W], d_s[5*W+:W], cnt_b);
            end else begin
                if (tag_v > cnt_b) begin
                    fails = fails + 1;
                    $display("  [FAIL] R-fut 超前 @%0t: tag=%h > cnt_b=%h", $time/1000.0, tag_v, cnt_b);
                end
                if (tag_v < cur_flip_tag) begin
                    fails = fails + 1;
                    $display("  [FAIL] R-stale 陈旧 @%0t: tag=%h < 请求时 %h", $time/1000.0, tag_v, cur_flip_tag);
                end
            end
            prev_tag = tag_v;
            lat = acyc - hmax;
            if (lat > lat_max) lat_max = lat;
        end
        // ---- 受理计数: 条件与 DUT 的 toggle 翻转条件逐字相同 ----
        //   注意不能数"观察到的 toggle 变化": 复位会把 toggle_a 异步清 0,
        //   那是复位事件不是请求 (第一版就栽在这条算术上, 见报告)。
        if (chk_on && req_p && !busy_p) nflip = nflip + 1;
        if (t_s !== t_prev && t_s !== 1'bx && t_prev !== 1'bx) begin
            nchg = nchg + 1;
            cur_flip_tag = c_prev;
            // 观察到的变化必须能被解释: 受理 (req&!busy) 或复位
            if (chk_on && !(req_p && !busy_p) && !rst_win && rst_n && rst_p) begin
                fails = fails + 1;
                $display("  [FAIL] R4b 无请求且非复位时 toggle 变化 @%0t ns", $time/1000.0);
            end
            q = $time / HB;
            nb = ((q/2)*2 + 1) * HB;
            if (nb <= $time) nb = nb + 2*HB;
            dt = nb - $time;
            if (nchg == 1 || dt < hmin) hmin = dt;
            if (dt > hmax) hmax = dt;
        end
        rst_p = rst_n;
        req_p = req_a; busy_p = busy_a;
        v_prev = v_s; t_prev = t_s; c_prev = cnt_b;
    end

    initial begin
        #(WT);
        $display("TIMEOUT tb_atk_reset MODE=%0d", MODE);
        $display("RESET-RESULT MODE=%0d valids=%0d flips=%0d phantom=%0d fails=%0d FAIL",
                 MODE, nval, nflip, phantom, fails);
        $finish;
    end

    task wait_valid(input integer b0, input integer lim);
        integer w;
        begin
            w = 0;
            while (nval == b0 && w < lim) begin @(negedge clk_a); w = w + 1; end
            if (nval == b0) begin
                $display("  [FAIL] 死锁 @%0t ns: %0d 拍无 valid (busy=%b)", $time/1000.0, lim, busy_a);
                fails = fails + 1; dead = 1'b1;
            end
        end
    endtask

    task one_req(input integer lim);
        begin
            base = nval;
            @(negedge clk_a); req_r = 1'b1;
            @(negedge clk_a); req_r = 1'b0;
            wait_valid(base, lim);
        end
    endtask

    // 一次复位: 拉低 width 后释放, 释放后等 busy 落
    task do_reset(input integer width, input integer expect_idle);
        begin
            rst_win   = 1'b1;
            gate_open = 1'b0;
            rst_n = 1'b0;
            #(width);
            rst_n = 1'b1;
            // 等 b 域复位同步释放 + 握手静止
            k = 0;
            while (busy_a && k < 2000) begin @(negedge clk_a); k = k + 1; end
            if (busy_a && expect_idle) begin
                $display("  [FAIL] R1 复位释放后 busy 挂死 (%0d 拍)", k);
                fails = fails + 1; dead = 1'b1;
            end
            repeat (10) @(negedge clk_a);
            rst_win = 1'b0;
        end
    endtask

    integer rel_cnt;
    initial begin
        $display("=== 门 C: 复位 ===");
        if (MODE != 9) begin
            rst_n = 1'b0;                       // 1->0 negedge => DUT 异步复位
            repeat (8) @(posedge clk_b_g);
            repeat (8) @(posedge clk_a);
            rst_n = 1'b1;
            repeat (12) @(posedge clk_a);
            chk_on = 1'b1;
        end

        if (MODE == 9) begin
            // C5: 上电不复位 (rst_n 从 time 0 起就是 1, 从未有 negedge)
            $display("  [INFO] C5 上电不复位: rst_n 常高 (DUT 从未收到复位)");
            #(20000);
            $display("  [INFO] C5 上电 20us 后: busy=%b valid=%b dout=%h (X=未定义)", busy_a, valid_a, dout_a);
            if (busy_a === 1'bx || valid_a === 1'bx || dout_a === {NB{1'bx}})
                $display("  [NOTE] C5 上电不复位 => 状态停在 X (契约: 必须给复位; 非缺陷)");
            else
                $display("  [NOTE] C5 上电不复位 => 状态非 X (巧合)");
            // 补一次复位, 看能否自愈
            do_reset(10000, 1);
            chk_on = 1'b1; gate_open = 1'b1;
            one_req(4000);
            $display("  [INFO] C5 补复位后恢复正常: valids=%0d", nval);
        end else if (MODE == 5) begin
            // C6: a 域时钟停摆 (对称于单元门只测过的 b 停摆) —— 飞行中冻 a 时钟再解冻
            gate_open = 1'b1;
            for (p = 0; p < 8; p = p + 1) begin
                while (busy_a) @(negedge clk_a_g);
                base = nval;
                @(negedge clk_a_g); req_r = 1'b1;
                @(negedge clk_a_g); req_r = 1'b0;
                repeat (2) @(negedge clk_a_g);
                if (!busy_a) begin
                    $display("  [FAIL] C6 受理后 busy 没高"); fails = fails + 1;
                end
                clk_a_en = 0;                       // 冻 a 时钟 (请求在飞)
                repeat (30) @(posedge clk_b_g);     // b 域继续跑
                if (nval != base) begin
                    $display("  [FAIL] C6 a 停摆期间冒出 valid (a 域都没有时钟)"); fails = fails + 1;
                end
                clk_a_en = 1;                       // 解冻
                wait_valid(base, 4000);
                k = 0;
                while (busy_a && k < 4000) begin @(negedge clk_a_g); k = k + 1; end
                if (busy_a) begin
                    $display("  [FAIL] R1 C6 解冻后 busy 挂死"); fails = fails + 1; dead = 1'b1;
                end
                if (dead) p = 8;
            end
        end else if (MODE == 4) begin
            // C4: clk_b 停摆期间复位 + 释放时仍停摆, 恢复后必须能重新工作
            for (p = 0; p < 8; p = p + 1) begin
                base = nval;
                @(negedge clk_a); req_r = 1'b1;
                @(negedge clk_a); req_r = 1'b0;
                repeat (3) @(negedge clk_a);
                if (!busy_a) begin
                    $display("  [FAIL] C4 受理后 busy 竟没拉高"); fails = fails + 1;
                end
                clk_b_en = 0;                    // 停 b 时钟 (请求在飞)
                repeat (8) @(negedge clk_a);
                if (!busy_a) begin
                    $display("  [FAIL] C4 clk_b 停摆但 busy 没挂高 (握手空转)"); fails = fails + 1;
                end
                if (nval != base) begin
                    $display("  [FAIL] R2 clk_b 停摆期间冒出 valid"); fails = fails + 1;
                end
                rst_win   = 1'b1;
                gate_open = 1'b0;
                rst_n = 1'b0;
                #(1000); rst_n = 1'b1;           // 极窄复位, b 时钟停着
                repeat (20) @(negedge clk_a);
                rst_win = 1'b0;
                if (nval != base) begin
                    $display("  [FAIL] R2 复位期间 (b 停摆) 冒出 valid"); fails = fails + 1;
                end
                clk_b_en = 1;                    // 恢复 b 时钟
                repeat (6) @(posedge clk_b_g);
                k = 0;
                while (busy_a && k < 2000) begin @(negedge clk_a); k = k + 1; end
                if (busy_a) begin
                    $display("  [FAIL] R1 C4 恢复后 busy 挂死"); fails = fails + 1; dead = 1'b1;
                end
                gate_open = 1'b1;
                one_req(4000);                   // 恢复后重新请求必须成功
                if (dead) p = 8;
            end
        end else if (MODE == 3) begin
            // C3: 复位期间 req 恒高, 释放后仍恒高
            gate_open = 1'b1;
            for (p = 0; p < 8; p = p + 1) begin
                req_r = 1'b1;
                repeat (6) @(negedge clk_a);
                rst_win   = 1'b1;
                gate_open = 1'b0;
                rst_n = 1'b0;
                #(3*HA);
                rel_cnt = cnt_b;
                rst_n = 1'b1;
                k = 0;
                while (busy_a && k < 3000) begin @(negedge clk_a); k = k + 1; end
                rst_win = 1'b0;
                if (busy_a) begin
                    $display("  [FAIL] R1 C3 req 恒高时释放, busy 挂死"); fails = fails + 1; dead = 1'b1;
                end
                gate_open = 1'b1;
                // req 仍恒高 => 立刻会有 valid; 检查它的数据 >= 释放时刻的计数值
                base = nval;
                wait_valid(base, 4000);
                if (nval > base && cur_flip_tag < rel_cnt) begin
                    $display("  [FAIL] R3 C3 首个 valid 的请求时刻计数值 %0h < 释放时刻 %0h",
                             cur_flip_tag, rel_cnt);
                    fails = fails + 1;
                end
                req_r = 1'b0;
                repeat (20) @(negedge clk_a);
                if (dead) p = 8;
            end
        end else begin
            // C1/C2: 窄复位脉冲相位扫描 (飞行中)
            gate_open = 1'b1;
            for (p = 0; p < nph; p = p + 1) begin
                // 先做一次正常快照, 确认基线
                one_req(4000);
                if (dead) p = nph;
                // 再发一次请求, 飞行中在扫描相位处复位
                base = nval; @(negedge clk_a); req_r = 1'b1;
                @(negedge clk_a); req_r = 1'b0;
                repeat (2) @(negedge clk_a);
                // 对齐网格 + 相位偏移
                k = LCM - ($time % LCM); if (k != LCM) #(k);
                #(p * pstep);
                rel_cnt = cnt_b;
                if (MODE == 1) do_reset(1, 1);           // 1ps 极窄
                else           do_reset(2*HA, 1);        // 一个 a 周期宽
                gate_open = 1'b1;
                // 恢复后第一次快照: 数据必须 >= 释放时刻计数值
                base = nval;
                one_req(4000);
                if (!dead && nval == base + 1 && prev_tag < rel_cnt) begin
                    $display("  [FAIL] R3 恢复后首个 valid tag=%h < 释放时刻 %h", prev_tag, rel_cnt);
                    fails = fails + 1;
                end
                if (dead) p = nph;
            end
        end

        // R4 计数: 按模式核算"受理请求数 vs 完成快照数"
        //   MODE0/1: 每轮 3 受理 (基线 / 被复位打断 / 恢复后), 完成 2 => nflip=3*nph, nval=2*nph
        //   MODE3/4/9: 只要求 完成 <= 受理 (被复位打断的请求不给 valid 是设计选择)
        if (MODE == 0 || MODE == 1) begin
            $display("  [INFO] R4 核算: 受理 %0d (期望 %0d), 完成 %0d (期望 %0d)",
                     nflip, 3*nph, nval, 2*nph);
            if (nflip != 3*nph || nval != 2*nph) begin
                $display("  [FAIL] R4 受理/完成计数与逐轮结构不符"); fails = fails + 1;
            end else
                $display("  [PASS] R4 %0d 次复位各打断 1 个在飞请求: 受理 %0d = 完成 %0d + 打断 %0d",
                         nph, nflip, nval, nph);
        end else if (nval > nflip) begin
            $display("  [FAIL] R4 完成数 %0d > 受理数 %0d", nval, nflip); fails = fails + 1;
        end
        $display("  [INFO] 复位释放->首次 b 采样裕量 dt=%0d..%0d ps | 观察到的 toggle 变化 %0d 次",
                 hmin, hmax, nchg);
        $display("RESET-RESULT MODE=%0d valids=%0d flips=%0d phantom=%0d valdurrst=%0d fails=%0d %s",
                 MODE, nval, nflip, phantom, val_during_rst, fails, (fails == 0) ? "PASS" : "FAIL");
        $finish;
    end
endmodule
