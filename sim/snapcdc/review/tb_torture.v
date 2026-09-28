`timescale 1ns/1ps
//=============================================================================
// tb_torture.v — snap_cdc 审查用独立复核 TB (scratch, 不改 rtl/ tb/)
//   要点 (相对 tb/tb_snap_cdc.v 的增量):
//     ① 探针内部协议量, 断言跨域不变量: hold_b 只在 update 沿变, dout_a 只在 valid 沿变,
//        pending(已发未回) ∈ {0,1}; 计数一致性只在**静置**(停请求+排空)后比
//     ② 源位束**每拍都变** (cnt 自增) —— 真实集成里 din_b 是自增计数器
//     ③ 撕裂负对照是持续性的 ⇒ 命中确定
//     ④ 极端时钟比 (b 慢 20 倍 / b 快 8 倍 / a 慢 25 倍) + 掉电式启动 (rst 释放时 clk_b 没跑)
//   ⚠️ 写这个 TB 时踩到的两个自身坑 (留档, 与 DUT 无关):
//      - 用 `while (busy_a) @(negedge clk_a)` 等空闲会**错过**只有 2 拍宽的低窗 ⇒ 烧满守卫
//      - 在"飞行中"的瞬时比较 flips/updates/valids ⇒ 假失败 (必须静置后比)
//=============================================================================
`define CHK(cond, msg) begin \
        if (!(cond)) begin $display("  [FAIL] %s  (t=%0t)", msg, $time); n_phase_fail = n_phase_fail + 1; end \
        else $display("  [ok]   %s", msg); \
    end

module tb_torture;
    parameter W = 32, NW = 6, NB = NW*W;

    reg clk_a = 0, clk_b = 0;
    reg clk_b_en = 1;
    wire clk_b_g = clk_b & clk_b_en;
    integer pa = 4, pb = 8;
    always #(pa/2.0) clk_a = ~clk_a;
    always #(pb/2.0) clk_b = ~clk_b;

    reg  rst_n = 0;
    reg  [NB-1:0] din_b = 0;
    wire busy_a, valid_a;
    wire [NB-1:0] dout_a;
    reg  req_a;
    integer req_mode = 3;      // 0=auto 1=req_drv 2=恒定高 3=不发
    reg     req_drv = 0;

    snap_cdc #(.W(W), .NW(NW)) u_dut (
        .clk_a(clk_a), .rst_n(rst_n), .req_a(req_a),
        .busy_a(busy_a), .dout_a(dout_a), .valid_a(valid_a),
        .clk_b(clk_b_g), .din_b(din_b)
    );
    always @(posedge clk_a or negedge rst_n) begin
        if (!rst_n)             req_a <= 1'b0;
        else if (req_mode == 0) req_a <= !busy_a;
        else if (req_mode == 1) req_a <= req_drv;
        else if (req_mode == 2) req_a <= 1'b1;
        else                    req_a <= 1'b0;
    end

    wire          dbg_tog   = u_dut.toggle_a;
    wire          dbg_upd   = u_dut.update_b;
    wire          dbg_done  = u_dut.done_a;
    wire          dbg_ack   = u_dut.ack_b;
    wire [NB-1:0] dbg_hold  = u_dut.hold_b;
    wire          dbg_rstb  = u_dut.rst_b_n;

    // ---------------- b 域源: 每拍自增 (真实集成里 din_b 是自增计数器) ----------------
    integer cnt_b = 0;
    reg     tear  = 0;
    always @(negedge clk_b_g) begin
        cnt_b = cnt_b + 1;
        set_bundle(cnt_b);
    end
    task set_bundle(input integer g);
        integer i;
        begin
            for (i = 0; i < NW; i = i + 1)
                din_b[i*W +: W] = {g[23:0], i[7:0]};
            if (tear) din_b[3*W +: W] = {(g[23:0] ^ 24'h00FFFF), 8'd3};
        end
    endtask

    // ---------------- 统计 ----------------
    integer n_flip = 0, n_upd = 0, n_valid = 0, n_valid_g = 0;
    integer n_mixed_clean = 0, n_mixed_tear = 0;
    integer n_dout_chg = 0, n_hold_bad = 0, n_pend_bad = 0;
    integer n_busy_bad = 0, n_busy_ok = 0, n_idx_bad = 0;
    integer n_dead = 0, n_phase_fail = 0;
    integer pending = 0;
    reg     tog_prev = 0;
    reg [NB-1:0] cap = 0, last_cap = 0;
    integer i_ph, s_valid, s_mixed, s_flip, s_upd, s_novalid, s_cnt;
    reg [NB-1:0] last_hold = 0;
    reg          upd_prev  = 0;

    always @(posedge clk_a or negedge rst_n) begin
        if (!rst_n) begin
            // 复位 = 纪元边界: 三个纪元计数清零 (跨复位比较无意义); 全局 valid 计数不动
            tog_prev = 1'b0;  pending = 0;  last_cap = {NB{1'b0}};
            n_flip = 0;  n_valid = 0;
        end else begin
            if (dbg_tog !== tog_prev) begin
                n_flip  = n_flip + 1;
                pending = pending + 1;
                tog_prev <= dbg_tog;
            end
            if (valid_a) begin
                n_valid = n_valid + 1;
                n_valid_g = n_valid_g + 1;
                pending = pending - 1;
                cap = dout_a;
                chk_capture;
                last_cap <= dout_a;
            end else begin
                if (dout_a !== last_cap) n_dout_chg = n_dout_chg + 1;
            end
            if (pending < 0 || pending > 1) n_pend_bad = n_pend_bad + 1;
            // busy 落下必须恰好是"回送已到"那一刻 (done_a), 结果在下一拍才出
            if (pending == 1 && !busy_a) begin
                if (dbg_done) n_busy_ok = n_busy_ok + 1;
                else          n_busy_bad = n_busy_bad + 1;
            end
        end
    end
    always @(posedge clk_b_g or negedge dbg_rstb) begin
        if (!dbg_rstb) begin
            last_hold = {NB{1'b0}};  upd_prev = 1'b0;
            n_upd = 0;                       // 纪元边界 (与 a 域清零同步)
        end else begin
            if (dbg_upd) n_upd = n_upd + 1;
            if (dbg_hold !== last_hold && !upd_prev) begin
                n_hold_bad = n_hold_bad + 1;
                $display("  [FAIL] hold_b 在非 update 沿变化 t=%0t", $time);
            end
            last_hold <= dbg_hold;
            upd_prev  <= dbg_upd;
        end
    end

    task chk_capture;
        integer k;
        reg [23:0] t0, tk;
        reg [7:0]  ik;
        reg        bad;
        begin
            bad = 0; t0 = cap[8 +: 24];
            for (k = 0; k < NW; k = k + 1) begin
                tk = cap[k*W + 8 +: 24];
                ik = cap[k*W +: 8];
                if (tk !== t0) bad = 1;
                if (ik !== k[7:0]) begin bad = 1; n_idx_bad = n_idx_bad + 1; end
            end
            if (bad) begin
                if (tear) n_mixed_tear = n_mixed_tear + 1;
                else begin
                    n_mixed_clean = n_mixed_clean + 1;
                    $display("  [FAIL] t=%0t 位混! tags=%h %h %h %h %h %h", $time,
                        cap[0*W+:W], cap[1*W+:W], cap[2*W+:W],
                        cap[3*W+:W], cap[4*W+:W], cap[5*W+:W]);
                end
            end
        end
    endtask

    // 等 N 次新 valid
    task run_valids(input integer n);
        integer start, guard;
        begin
            start = n_valid; guard = 0;
            while ((n_valid < start + n) && (guard < 200000)) begin
                @(negedge clk_a); guard = guard + 1;
            end
            if (n_valid < start + n) begin
                $display("  [FAIL] run_valids(%0d): 只等到 %0d 次 (死等) t=%0t", n, n_valid - start, $time);
                n_dead = n_dead + 1; n_phase_fail = n_phase_fail + 1;
            end
        end
    endtask

    // 静置: 停请求 → 排空在飞 → 等计数自然对齐
    task settle;
        integer guard;
        begin
            req_mode = 3;
            // ⚠️ req_a 是**寄存器**, 停请求要 1 拍才落地; 那一拍里 DUT 仍可能采到 req_a=1 并
            //    合法地翻一次 toggle (本 TB 第一版就栽在这里: 立刻查 pending ⇒ 假"死锁")
            repeat (4) @(negedge clk_a);
            guard = 0;
            while ((pending != 0) && (guard < 200000)) begin @(negedge clk_a); guard = guard + 1; end
            repeat (6) @(negedge clk_a);
            if (pending != 0) begin
                $display("  [FAIL] settle: 在飞请求永不回 (busy=%b t=%0t)", busy_a, $time);
                n_dead = n_dead + 1; n_phase_fail = n_phase_fail + 1;
            end
        end
    endtask

    task phase_begin(input [255:0] name);
        begin
            s_valid = n_valid_g; s_mixed = n_mixed_clean; s_flip = n_flip;
            s_upd = n_upd; s_novalid = n_valid;
            $display("--- 相位: %0s (pa=%0d pb=%0d t=%0t) ---", name, pa, pb, $time);
        end
    endtask

    task summary;
        begin
            $display("=== 汇总 ===");
            $display("  flips=%0d updates=%0d valids=%0d pending=%0d", n_flip, n_upd, n_valid, pending);
            $display("  位混(干净)=%0d 位混(撕裂)=%0d 字序号错=%0d", n_mixed_clean, n_mixed_tear, n_idx_bad);
            $display("  dout 非valid沿变化=%0d  hold 非update沿变化=%0d", n_dout_chg, n_hold_bad);
            $display("  pending 越界=%0d  busy 早落(非done)=%0d  busy 早落(是done)=%0d",
                     n_pend_bad, n_busy_bad, n_busy_ok);
            $display("  死等=%0d  相位失败=%0d", n_dead, n_phase_fail);
            if (n_mixed_clean == 0 && n_mixed_tear > 0 && n_idx_bad == 0 &&
                n_dout_chg == 0 && n_hold_bad == 0 && n_pend_bad == 0 && n_busy_bad == 0 &&
                n_dead == 0 && n_phase_fail == 0 && n_flip == n_upd && n_upd == n_valid)
                $display("TOR_PASS  tb_torture: 全部不变量成立 (含撕裂负对照命中)");
            else
                $display("TOR_FAIL  tb_torture: 见上");
            $display("=== done ===");
            $finish;
        end
    endtask

    initial begin
        $display("=== tb_torture: snap_cdc 独立复核 ===");

        // ================= P0: 250M/125M, 源自增, 自动请求 =================
        pa = 4; pb = 8; req_mode = 3;
        repeat (4) @(posedge clk_b);
        rst_n = 1;
        repeat (4) @(posedge clk_a);
        phase_begin("P0 自增源 250M/125M");
        req_mode = 0;
        run_valids(200);
        settle;
        `CHK(n_mixed_clean == s_mixed, "P0 200 次快照零位混 (源每拍都变)")
        `CHK(n_flip == n_upd && n_upd == n_valid, "P0 静置后 flips == updates == valids")

        // ================= P1: b 慢 20 倍 =================
        pa = 4; pb = 80;
        repeat (40) @(posedge clk_a);
        phase_begin("P1 b 慢 20 倍 (12.5MHz)");
        req_mode = 0;
        run_valids(60);
        settle;
        `CHK(n_mixed_clean == s_mixed, "P1 零位混")
        `CHK(n_flip == n_upd && n_upd == n_valid, "P1 静置后计数对齐")

        // ================= P2: b 快 8 倍 =================
        pa = 4; pb = 1;
        repeat (40) @(posedge clk_a);
        phase_begin("P2 b 快 8 倍 (1GHz)");
        req_mode = 0;
        run_valids(60);
        settle;
        `CHK(n_mixed_clean == s_mixed, "P2 零位混")
        `CHK(n_flip == n_upd && n_upd == n_valid, "P2 静置后计数对齐")

        // ================= P3: a 慢 25 倍 =================
        pa = 100; pb = 8;
        repeat (20) @(posedge clk_a);
        phase_begin("P3 a 慢 25 倍 (10MHz)");
        req_mode = 0;
        run_valids(30);
        settle;
        `CHK(n_mixed_clean == s_mixed, "P3 零位混")
        `CHK(n_flip == n_upd && n_upd == n_valid, "P3 静置后计数对齐")
        pa = 4; pb = 8;

        // ================= P4: 手动请求 + busy 期间脉冲被忽略 =================
        phase_begin("P4 手动请求语义");
        req_mode = 3;
        repeat (8) @(posedge clk_a);
        // 第一拍脉冲 (空闲时发出)
        @(negedge clk_a); req_drv = 1; req_mode = 1;
        @(negedge clk_a); req_drv = 0; req_mode = 3;
        // 立刻再发一拍 (此时必然在飞)
        @(negedge clk_a); req_drv = 1; req_mode = 1;
        @(negedge clk_a); req_drv = 0; req_mode = 3;
        repeat (3) @(negedge clk_a);
        `CHK(busy_a == 1'b1, "P4 第二拍时确实在飞 (busy=1)")
        s_valid = n_valid_g;
        req_drv = 1; req_mode = 1;               // 飞行中再插一拍
        @(negedge clk_a); req_drv = 0; req_mode = 3;
        run_valids(1);
        settle;
        `CHK(n_valid_g == s_valid + 1, "P4 飞行中插入的脉冲被忽略 (只补 1 次 valid)")
        `CHK(n_flip == n_upd && n_upd == n_valid, "P4 静置后计数对齐")

        // ================= P5: b 时钟停摆 → 恢复 =================
        phase_begin("P5 b 时钟停摆/恢复 (在飞时停)");
        req_mode = 0;
        run_valids(5);
        settle;
        req_mode = 0;
        begin : wait_flight
            integer g2; g2 = 0;
            while (!(pending == 1 && busy_a) && g2 < 100000) begin @(negedge clk_a); g2 = g2 + 1; end
        end
        `CHK(pending == 1 && busy_a, "P5 场景成立 (请求在飞)")
        req_mode = 3;
        repeat (2) @(negedge clk_a);
        clk_b_en = 0;                             // 在飞时停 b 时钟
        repeat (10) @(negedge clk_a);             // 已同步到 a 域的部分允许走完
        s_valid = n_valid_g; s_cnt = cnt_b;
        repeat (50) @(negedge clk_a);
        `CHK(busy_a == 1'b1, "P5 停摆期间 busy 挂高")
        `CHK(n_valid_g == s_valid, "P5 停摆期间零新 valid")
        clk_b_en = 1;
        run_valids(1);
        `CHK(cap[23:0] >= s_cnt, "P5 恢复后数据来自恢复后的 b 域源")
        settle;
        `CHK(n_flip == n_upd && n_upd == n_valid, "P5 静置后计数对齐")

        // ================= P6: 掉电式启动 (rst 释放时 clk_b 根本没跑) =================
        phase_begin("P6 掉电式启动 (PHY 时钟没起来)");
        req_mode = 0;
        clk_b_en = 0;
        rst_n = 0;
        repeat (20) @(posedge clk_a);
        s_valid = n_valid_g;
        rst_n = 1;                                 // 释放复位, clk_b 仍没跑
        repeat (40) @(posedge clk_a);
        `CHK(n_valid_g == s_valid, "P6 clk_b 不存在时零 valid (不误报)")
        `CHK(busy_a == 1'b1, "P6 clk_b 不存在时 busy 挂高")
        clk_b_en = 1;                              // PHY 时钟终于起来
        s_cnt = cnt_b;
        run_valids(1);
        `CHK(cap[23:0] >= s_cnt, "P6 上电后首份快照的数据来自 clk_b 起来之后")
        settle;
        s_mixed = n_mixed_clean;
        req_mode = 0;
        run_valids(40);
        settle;
        `CHK(n_mixed_clean == s_mixed, "P6 恢复后零位混")
        `CHK(n_flip == n_upd && n_upd == n_valid, "P6 静置后计数对齐")

        // ================= P7a: 空闲复位抖动 x8 =================
        phase_begin("P7a 空闲复位抖动");
        settle;
        repeat (8) @(negedge clk_a);
        s_valid = n_valid_g;
        for (i_ph = 0; i_ph < 8; i_ph = i_ph + 1) begin
            rst_n = 0;
            repeat (1 + i_ph) @(negedge clk_a);
            rst_n = 1;
            repeat (2 + i_ph) @(negedge clk_a);
            `CHK(busy_a == 1'b0, "P7a 空闲复位后 busy 为 0")
            `CHK(n_valid_g == s_valid, "P7a 空闲复位零假 valid")
        end
        settle;
        `CHK(n_flip == n_upd && n_upd == n_valid, "P7a 静置后计数对齐")

        // ================= P7b: 飞行中复位 (单次, 量残余) =================
        phase_begin("P7b 飞行中复位");
        req_mode = 0;
        run_valids(5);
        settle;
        req_mode = 0;
        begin : wait_pend
            integer guard; guard = 0;
            while (pending != 1 && guard < 100000) begin @(negedge clk_a); guard = guard + 1; end
        end
        `CHK(pending == 1, "P7b 场景成立 (请求在飞)")
        s_valid = n_valid_g;                  // 纪元计数在复位时清零 ⇒ 只用全局 valid 判吞帧
        rst_n = 0;
        repeat (8) @(negedge clk_a);
        rst_n = 1;
        repeat (20) @(negedge clk_a);
        `CHK(n_valid_g - s_valid <= 1, "P7b 复位最多吞掉 1 次 valid (不冒连发)")
        `CHK((n_flip - n_valid) <= 1 && (n_upd - n_valid) <= 1,
             "P7b 复位后纪元正常重开 (瞬时在飞 <= 1)")
        $display("  [INFO] P7b 复位后新纪元: flips=%0d upd=%0d valid=%0d", n_flip, n_upd, n_valid);
        s_mixed = n_mixed_clean;
        run_valids(40);
        settle;
        `CHK(n_mixed_clean == s_mixed, "P7b 复位后零位混")
        `CHK(n_flip == n_upd && n_upd == n_valid, "P7b 复位后协议重新对齐")

        // ================= P8: 撕裂负对照 =================
        phase_begin("P8 撕裂负对照 (持续性撕裂)");
        tear = 1;
        req_mode = 0;
        run_valids(40);
        `CHK(n_mixed_tear > 0, "P8 撕裂被抓到 (检查器有判别力)")
        tear = 0;
        settle;
        s_mixed = n_mixed_clean;
        req_mode = 0;
        run_valids(40);
        settle;
        `CHK(n_mixed_clean == s_mixed, "P8 停止撕裂后零位混")
        `CHK(n_flip == n_upd && n_upd == n_valid, "P8 静置后计数对齐")

        summary;
    end

    initial begin #5000000; $display("TIMEOUT"); $finish; end
endmodule
