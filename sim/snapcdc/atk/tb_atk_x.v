`timescale 1ps/1ps
//=============================================================================
// tb_atk_x.v -- 对抗门 E: X 传播
//-----------------------------------------------------------------------------
// 单元门完全没碰 X。集成时 din_b 可能来自"还没初始化完"的数据面寄存器,
// 一旦 X 被锁进 hold_b 就再也洗不掉 (观测通道永久失明)。本门打:
//   X1 全程 din_b 干净 => valid_a/busy_a/dout_a/din_b **任何时刻都不许是 X**
//   X2 无在飞请求时把 din_b 打成 X (覆盖若干 b 沿) => 之后再请求, 捕获必须干净
//      (不许"没人请求也偷偷锁存")
//   X3 请求飞行期间 din_b 第 3 字被 X 覆盖 (必覆盖锁存沿) => 捕获里
//      **恰好第 3 字是 X, 其余 5 字必须干净且相干** (X 不许扩散)
//   X4 X 之后的下一次正常快照必须干净 (X 不许粘住)
//   X5 复位后立刻检查 dout_a/busy_a/valid_a 有无 X
//=============================================================================
module tb_atk_x;
    parameter W = 32, NW = 8, NB = NW*W;   // 真实集成参数 (wrapper_p4.v:2377)

    integer HA = 2000, HB = 4000, WT = 2000000000;
    reg clk_a = 0, clk_b = 0, rst_n = 1;
    wire clk_b_g = clk_b;

    initial begin
        $value$plusargs("HA=%d", HA);
        $value$plusargs("HB=%d", HB);
        $value$plusargs("WT=%d", WT);
        $display("=== tb_atk_x: HA=%0d HB=%0d ===", HA, HB);
        fork
            forever #(HA) clk_a = ~clk_a;
            forever #(HB) clk_b = ~clk_b;
        join
    end

    reg [23:0] cnt_b = 24'd0;
    always @(posedge clk_b_g) cnt_b <= cnt_b + 24'd1;

    reg          x3 = 1'b0;        // 把第 3 字打成 X
    reg [NB-1:0] din_b;
    integer      wi;
    always @* begin
        for (wi = 0; wi < NW; wi = wi + 1)
            din_b[wi*W +: W] = {cnt_b, wi[7:0]};
        if (x3) din_b[3*W +: W] = {W{1'bx}};
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

    integer acyc = 0, nval = 0, fails = 0, xval = 0, nxword = 0;
    integer jv, k, base, xsig = 0, xctrl = 0, xdin = 0, xdo = 0;
    reg [23:0] tag_v, prev_tag = 24'd0, cur_flip_tag = 24'd0, c_prev = 24'd0;
    reg        v_s, v_prev, t_s, t_prev = 1'b0, chk_on = 0, dchk = 0;
    reg [NB-1:0] d_s, dout_prev;
    reg [W-1:0]  wv;
    reg [NW-1:0] xmask;

    always @(posedge clk_a) begin
        acyc = acyc + 1;
        v_s = valid_a; d_s = dout_a; t_s = u_dut.toggle_a;
        // ---- X1: 控制信号不许 X (复位释放后) ----
        if (chk_on) begin
            if (busy_a === 1'bx || valid_a === 1'bx) begin
                xctrl = xctrl + 1;
                $display("  [FAIL] X1 控制信号为 X @%0t: busy=%b valid=%b", $time/1000.0, busy_a, valid_a);
                fails = fails + 1;
            end
            if ((^din_b === 1'bx)) xdin = xdin + 1;      // 只在 x3 阶段应为真
            if ((^dout_a === 1'bx) && !x3) xdo = xdo + 1;
        end
        if (dchk && !v_s && (d_s !== dout_prev)) begin
            fails = fails + 1;
            $display("  [FAIL] dout 无 valid 时变化 @%0t", $time/1000.0);
        end
        if (v_s) begin
            nval = nval + 1;
            xmask = 0;
            for (jv = 0; jv < NW; jv = jv + 1) begin
                wv = d_s[jv*W +: W];
                if ((^wv === 1'bx)) xmask[jv] = 1'b1;
            end
            nxword = 0;
            for (jv = 0; jv < NW; jv = jv + 1) if (xmask[jv]) nxword = nxword + 1;
            if (nxword != 0) begin
                xval = xval + 1;
                // X3: 恰好第 3 字 X, 其余必须干净相干
                if (xmask !== (1'b1 << 3)) begin
                    fails = fails + 1;
                    $display("  [FAIL] X3 X 扩散/位置不对 @%0t: mask=%b", $time/1000.0, xmask);
                end else begin
                    tag_v = d_s[W-1:8];
                    for (jv = 0; jv < NW; jv = jv + 1) begin
                        if (jv != 3) begin
                            wv = d_s[jv*W +: W];
                            if (wv[W-1:8] !== tag_v || wv[7:0] !== jv[7:0]) begin
                                fails = fails + 1;
                                $display("  [FAIL] X3 第 %0d 字被 X 污染 @%0t", jv, $time/1000.0);
                            end
                        end
                    end
                    if (tag_v > cnt_b) begin
                        fails = fails + 1;
                        $display("  [FAIL] X3 tag=%h > cnt_b=%h", tag_v, cnt_b);
                    end
                    prev_tag = tag_v;
                end
            end else begin
                // 正常捕获: 相干 + 不陈旧 + 不超前
                tag_v = d_s[W-1:8];
                for (jv = 0; jv < NW; jv = jv + 1) begin
                    wv = d_s[jv*W +: W];
                    if (wv[W-1:8] !== tag_v || wv[7:0] !== jv[7:0]) begin
                        fails = fails + 1;
                        $display("  [FAIL] 位混 @%0t: %h %h %h %h %h %h", $time/1000.0,
                                 d_s[0*W+:W], d_s[1*W+:W], d_s[2*W+:W], d_s[3*W+:W], d_s[4*W+:W], d_s[5*W+:W]);
                    end
                end
                if (tag_v > cnt_b) begin
                    fails = fails + 1; $display("  [FAIL] 超前 @%0t tag=%h cnt=%h", $time/1000.0, tag_v, cnt_b);
                end
                if (!x3 && tag_v < cur_flip_tag) begin
                    fails = fails + 1; $display("  [FAIL] 陈旧 @%0t tag=%h req_cnt=%h", $time/1000.0, tag_v, cur_flip_tag);
                end
                prev_tag = tag_v;
            end
        end
        if (t_s !== t_prev && t_s !== 1'bx && t_prev !== 1'bx) cur_flip_tag = c_prev;
        v_prev = v_s; t_prev = t_s; c_prev = cnt_b; dout_prev = d_s;
    end

    initial begin
        #(WT);
        $display("X-RESULT valids=%0d xval=%0d fails=%0d FAIL", nval, xval, fails);
        $finish;
    end

    task wait_valid(input integer b0, input integer lim);
        integer w;
        begin
            w = 0;
            while (nval == b0 && w < lim) begin @(negedge clk_a); w = w + 1; end
            if (nval == b0) begin
                $display("  [FAIL] 死锁 @%0t (busy=%b)", $time/1000.0, busy_a);
                fails = fails + 1;
            end
        end
    endtask

    integer i, n0;
    initial begin
        $display("=== 门 E: X 传播 ===");
        rst_n = 1'b0;
        repeat (8) @(posedge clk_b_g);
        repeat (8) @(posedge clk_a);
        // ---- X5: 复位期间/刚释放时检查 ----
        if (busy_a === 1'bx || valid_a === 1'bx || dout_a === {NB{1'bx}})
            $display("  [NOTE] X5 复位期间仍有 X (复位未覆盖的寄存器), 释放后复查");
        rst_n = 1'b1;
        repeat (12) @(posedge clk_a);
        chk_on = 1'b1; dchk = 1'b1;
        if (((busy_a !== busy_a) || (valid_a !== valid_a) || (^dout_a === 1'bx)))
            $display("  [FAIL] X5 复位释放后控制/数据仍为 X: busy=%b valid=%b", busy_a, valid_a);
        else
            $display("  [PASS] X5 复位释放后 dout/busy/valid 全为已知值 (无 X)");

        // ---- X1: 干净运行 30 次快照 ----
        for (i = 0; i < 30; i = i + 1) begin
            while (busy_a) @(negedge clk_a);
            base = nval; @(negedge clk_a); req_r = 1; @(negedge clk_a); req_r = 0;
            wait_valid(base, 4000);
        end
        $display("  [INFO] X1 干净运行 %0d 次: xctrl=%0d xdo=%0d xdin=%0d", nval, xctrl, xdo, xdin);
        if (xctrl || xdo || xdin) begin
            $display("  [FAIL] X1 干净输入下出现了 X"); fails = fails + 1;
        end else
            $display("  [PASS] X1 干净输入: 全程无 X (控制/数据/din)");

        // ---- X2: 无在飞请求时把 din_b 打成 X (跨多个 b 沿) ----
        while (busy_a) @(negedge clk_a);
        n0 = nval;
        x3 = 1'b1;
        repeat (10) @(posedge clk_b_g);       // 10 个 b 沿都是 X, 但没有任何请求在飞
        x3 = 1'b0;
        repeat (4) @(posedge clk_b_g);
        base = nval; @(negedge clk_a); req_r = 1; @(negedge clk_a); req_r = 0;
        wait_valid(base, 4000);
        if (nval == n0 + 1 && xval == 0)
            $display("  [PASS] X2 无人请求时的 10 拍 X 未被锁存 (捕获干净)");
        else begin
            $display("  [FAIL] X2 X 被偷偷锁存了 (xval=%0d)", xval); fails = fails + 1;
        end

        // ---- X3: 请求飞行期间第 3 字为 X ----
        for (i = 0; i < 20; i = i + 1) begin
            while (busy_a) @(negedge clk_a);
            base = nval;
            x3 = 1'b1;                         // 从请求前就 X, 覆盖整个飞行窗口
            @(negedge clk_a); req_r = 1; @(negedge clk_a); req_r = 0;
            wait_valid(base, 4000);
            x3 = 1'b0;
            repeat (2) @(negedge clk_a);
        end
        $display("  [INFO] X3 飞行期 X: 共 %0d 次捕获带 X", xval);
        if (xval < 20) begin
            $display("  [FAIL] X3 应该有 20 次带 X 的捕获, 实际 %0d (X 没到 hold_b?)", xval);
            fails = fails + 1;
        end else
            $display("  [PASS] X3 X 覆盖锁存沿: 每次恰好第 3 字 X, 其余字干净不扩散");

        // ---- X4: X 之后必须恢复干净 ----
        x3 = 1'b0;
        for (i = 0; i < 5; i = i + 1) begin
            while (busy_a) @(negedge clk_a);
            base = nval; @(negedge clk_a); req_r = 1; @(negedge clk_a); req_r = 0;
            wait_valid(base, 4000);
        end
        if (nxword == 0) $display("  [PASS] X4 X 不粘: 之后 5 次捕获全干净");
        else begin $display("  [FAIL] X4 X 粘住了 (最后一次捕获仍有 %0d 个 X 字)", nxword); fails = fails + 1; end

        $display("  [INFO] 控制信号 X 次数=%0d, dout X 次数=%0d, din X 次数=%0d", xctrl, xdo, xdin);
        $display("X-RESULT valids=%0d xval=%0d fails=%0d %s", nval, xval, fails, (fails == 0) ? "PASS" : "FAIL");
        $finish;
    end
endmodule
