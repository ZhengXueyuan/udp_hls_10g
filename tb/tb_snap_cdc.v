`timescale 1ns/1ps
//=============================================================================
// tb_snap_cdc.v — snap_cdc 单元门 (数据面 + 观测通道合体用的跨时钟域相干快照)
//   六组正判据 + 两条负对照:
//     1. 基本: 请求 → 结果 == 请求时刻的 b 域位束 (NW 字 × 32 位; NW 与集成同值)
//     2. **相干性 (核心)**: 请求**飞行途中**换掉整个 b 域位束 ⇒ 结果必须是"全旧"或"全新",
//        **绝不出现位混** (判据 = 所有字的高 24 位 tag 必须完全相同)。
//        扫 16 个相位, 并统计落在旧值/新值各几次 —— 两边都非零才证明扫进了竞争窗口。
//     3. busy 语义: 忙时连发 3 拍只产生 1 次 valid (不丢不重)
//     4. 背靠背: 上一拍 valid 后立刻再请求 → 连续 8 次全部正确
//     5. **负对照 A (证明检查器有判别力)**: 故意把源位束**撕裂一拍** (只推第 3 个字的 tag)
//        ⇒ 检查器**必须**报混。若一次都没抓到, 说明判据 2 是空判据 —— 本 TB 自己会报 FAIL。
//     6. **复位回收**: 请求**飞行途中**复位 ⇒ 释放后必须回到空闲 (不许 busy 挂死), 且不许
//        冒假 valid; 随后一次正常快照必须成立。
//     7. **b 时钟停摆 (跑一阵再停)**: 停 clk_b ⇒ busy 挂高 (预期, 不是故障) 且无 valid;
//        恢复 ⇒ 握手自动补完, 数据正确。
//     8. ⭐ **真实工况: 源每拍都在变 + 时钟非整比 + 位束带偏斜** —— 数据面计数就是
//        "每个 gmii 沿都变", 而 PHY 的 25MHz 晶振与 PCIe 的 100MHz 晶振**不同源** ⇒
//        采样沿相对源变化的相位是**持续滑动的**。本判据让源每个 clk_b 沿都更新、8 条
//        通道各带 SKEW_NS 延迟、clk_b 用非整比周期, 跑 200 次快照 ⇒ 真 RTL 必须 0 位混。
//        **负对照 B**: 同一激励喂给"不锁存直通"的对照模型 (`naive_q <= din_b`, 即本模块
//        存在的唯一理由要防的那个错) ⇒ 它**必须**出现位混, 否则说明这段激励没有判别力。
//        ⚠️ 这条是本门第一版**缺的**、也是最要命的一条: 原判据 2 的源在 negedge 整代原子
//        写入、两时钟精确 2:1 ⇒ "直通"变体在原门上照样 PASS_ALL (评审 agent 用变异体实测
//        抓到这个假通过路径)。零延迟仿真里, 不引入偏斜与非整比就测不出"没锁存"。
//     9. **上电顺序: 复位释放时 clk_b 还没起** (板上 PHY 时钟晚到的真实情形) ⇒ 不许冒假
//        valid/busy; 等 clk_b 起来后, 第一次快照必须正常。
//   位束格式: 每字 = {tag[23:0], idx[7:0]} (tag 逐代单调增, 便于判别"哪一代")
//=============================================================================
module tb_snap_cdc;
    parameter W = 32, NW = 24, NB = NW*W;  // NW 与 P6e 集成**同值** (2026-09-29 起 24 字 = 768 位;
    //   ⚠️ 与 wrapper 的 SNAP_NW_P6E / axi_regs.SNAP_NW 三处必须同值 —— 单元门与集成跑两个配置
    //   就是"门绿而板红"的经典来源 (工程坑 11)。位束/通道/检查器全部由 NW 推导, 无手写常数。
    // ⚠️ 每条通道的**延迟必须互不相同** —— 第一版给所有通道同一个延迟, 结果位束依然是
    //    "原子变化"(只是整体晚 0.6ns) ⇒ 负对照 B 一次都没混, 判据 8a 等于没测 (自证无判别力)。
    //    值取 0.15..1.2ns: 远小于 clk_b 半周期 (4.55ns) ⇒ 真 RTL 的锁存沿看到的仍是稳定值;
    //    但位束在 b 沿之后有约 1ns 的"撕裂窗", 采样沿落进去就会读出混值。
    parameter real SKEW_STEP_NS = 0.15;

    reg clk_a = 0, clk_b = 0, rst_n = 0;
    reg clk_b_en = 1;                        // 判据 7/9 用: 停摆/恢复 b 时钟
    // ⚠️ 必须声明成 **real**: 写成 integer 时 `hb = 4.55` 会被截断成 4 ⇒ "非整比时钟"根本没生效
    //    (这个坑是负对照 B 抓出来的: 它逼我去算"采样沿到底落在 b 沿之后多少 ns")
    real hb = 4.0;                           // clk_b 半周期 (ns); 判据 8 会扫它
    always #2 clk_a = ~clk_a;                // 250 MHz (4ns)
    always begin
        #hb clk_b = 1'b1;
        #hb clk_b = 1'b0;
    end
    wire clk_b_g = clk_b & clk_b_en;         // DUT 实际看到的 b 时钟

    // ---- b 域位束: 8 条通道**各自带延迟** (整代原子更新, 但到达时刻有偏斜) ----
    reg  [W-1:0] lane_q [0:NW-1];
    wire [W-1:0] lane_d [0:NW-1];
    wire [NB-1:0] din_b;
    genvar gj;
    generate
        for (gj = 0; gj < NW; gj = gj + 1) begin : g_lane
            assign #(SKEW_STEP_NS * (gj + 1)) lane_d[gj] = lane_q[gj];
            assign din_b[gj*W +: W] = lane_d[gj];      // 拼装用循环 ⇒ 字数改了不用手改拼接
        end
    endgenerate

    reg           req_a;
    wire          busy_a, valid_a;
    wire [NB-1:0] dout_a;

    snap_cdc #(.W(W), .NW(NW)) u_dut (
        .clk_a(clk_a), .rst_n(rst_n), .req_a(req_a),
        .busy_a(busy_a), .dout_a(dout_a), .valid_a(valid_a),
        .clk_b(clk_b_g), .din_b(din_b)
    );

    reg [23:0] g24;
    integer    wi;
    // 整代写入 (只在 clk_b 沿附近调用 ⇒ 满足"位束只在 b 沿变化"的前提)
    task set_bundle(input integer g);
        begin
            g24 = g[23:0];
            for (wi = 0; wi < NW; wi = wi + 1) lane_q[wi] = {g24, wi[7:0]};
        end
    endtask
    task put_word(input integer idx, input integer g);
        begin
            g24 = g[23:0];
            lane_q[idx] = {g24, idx[7:0]};
        end
    endtask

    // ---- 判据 8 的自由运行源: **每个 clk_b 沿都更新** (真实计数就是这样) ----
    reg     src_run = 0;
    integer src_gen = 0;
    always @(posedge clk_b) begin
        if (src_run) begin
            src_gen = src_gen + 1;
            for (wi = 0; wi < NW; wi = wi + 1)
                lane_q[wi] <= {src_gen[23:0], wi[7:0]};
        end
    end

    // ---- 负对照 B: "不锁存直通" 模型 (本模块要防的那个错; 与 DUT 同一时刻采样) ----
    reg [NB-1:0] naive_q = 0;
    always @(posedge clk_a)
        if (u_dut.done_a && !u_dut.done_r) naive_q <= din_b;

    // ---- a 域捕获 (独立监控进程, 不依赖测试进程的等待时机) ----
    reg [NB-1:0] cap_dout;
    integer      n_valid = 0;
    always @(posedge clk_a) begin
        if (valid_a) begin
            cap_dout <= dout_a;
            n_valid   = n_valid + 1;        // 阻塞: 让测试进程的轮询立刻能看到
        end
    end

    // ---- 判定 ----
    integer fails = 0, neg_fired = 0, neg_mode = 0;
    integer k0 = 0, n4 = 0, n6 = 0, n7 = 0, n8 = 0, n9 = 0;
    integer phase = 0, exp_tag = 0, chk_tag = 0, try = 0, lo = 0;
    integer tag_a = 0, tag_b = 0;
    integer hits_p0 = 0, hits_p1 = 0, mix_n = 0, naive_mix = 0, ext_naive = 0;
    reg [23:0] gtag;
    reg        mixed;

    // 位混计数 (0 = 相干). 不判"哪一代", 只判"6 个字是否同代 + 序号是否错位"
    function integer mix_count(input [NB-1:0] b);
        integer     j;
        reg [W-1:0] w32;
        reg [23:0]  t;
        begin
            mix_count = 0;
            w32 = b[0 +: W];
            gtag = w32[31:8];
            for (j = 1; j < NW; j = j + 1) begin
                w32 = b[j*W +: W];
                t = w32[31:8];
                if (t !== gtag)        mix_count = mix_count + 1;
                if (w32[7:0] !== j[7:0]) mix_count = mix_count + 1;
            end
        end
    endfunction

    // 检查最近一次捕获 (供判据 1/2/4 用, 会计入 fails; neg_mode 时记为负对照命中)
    task verify_capture;
        begin
            mixed = (mix_count(cap_dout) != 0);
            if (mixed) begin
                if (neg_mode) begin
                    neg_fired = neg_fired + 1;
                    $display("  [NEG-OK] 相位 %0d: 检查器抓到撕裂", phase);
                end else begin
                    $display("  [FAIL] 相位 %0d: 位混/错位! (各字 tag 不一致见下)", phase);
                    fails = fails + 1;
                end
            end
            else if (!neg_mode && chk_tag && (gtag !== exp_tag[23:0])) begin
                $display("  [FAIL] 相位 %0d: tag=%h 期望 %h", phase, gtag, exp_tag[23:0]);
                fails = fails + 1;
            end
        end
    endtask

    task wait_next_valid;
        begin while (n_valid == k0) @(negedge clk_a); end
    endtask

    task request_snap;
        begin
            k0 = n_valid;
            @(negedge clk_a); req_a = 1;
            @(negedge clk_a); req_a = 0;
        end
    endtask

    initial begin
        $display("=== tb_snap_cdc: 相干快照 CDC 单元门 ===");
        req_a = 0;
        set_bundle(0);
        repeat (4) @(posedge clk_b);
        rst_n = 1;
        repeat (4) @(posedge clk_a);

        // ---- 判据 1 ----
        set_bundle(100); @(negedge clk_b);
        request_snap;  wait_next_valid;
        phase = 1; exp_tag = 100; chk_tag = 1;
        n9 = fails; verify_capture;
        if (fails == n9) $display("  [PASS] 1 基本: 结果 = 请求时刻的位束 (tag=100, 全部 %0d 字全对)", NW);

        // ---- 判据 2: 飞行途中换整束, 扫 16 相位 ----
        $display("  --- 判据 2: 飞行途中换位束, 扫 16 个相位 (核心) ---");
        chk_tag = 0; hits_p0 = 0; hits_p1 = 0;
        n8 = fails;                                  // ⚠️ 判据起点快照: PASS 必须看"这一段没新增失败"
        for (try = 0; try < 16; try = try + 1) begin
            tag_a = 200 + try*2;      tag_b = 200 + try*2 + 1;
            set_bundle(tag_a); @(negedge clk_b);
            request_snap;
            repeat (try) @(negedge clk_b);
            set_bundle(tag_b); @(negedge clk_b);
            wait_next_valid;
            phase = 200 + try;
            verify_capture;
            if      (gtag === tag_a[23:0]) hits_p0 = hits_p0 + 1;
            else if (gtag === tag_b[23:0]) hits_p1 = hits_p1 + 1;
            else begin
                $display("  [FAIL] 相位 %0d: tag=%h 不属于任何一代", phase, gtag);
                fails = fails + 1;
            end
            while (busy_a) @(negedge clk_a);
        end
        $display("  [INFO] 2 相位统计: 旧值 %0d 次 / 新值 %0d 次", hits_p0, hits_p1);
        // ⚠️ 打印条件必须包含"这一段没有新增失败" —— 否则判据 2 打印 PASS 的同时上面可能刚打过 FAIL
        if ((fails == n8) && hits_p0 > 0 && hits_p1 > 0)
            $display("  [PASS] 2 相干性: 16 相位全部相干, 且新旧两侧都扫到 (判据非空)");
        else begin
            $display("  [FAIL] 2 相干性: 失败 %0d 项 / 旧 %0d 新 %0d (相位统计偏一侧 = 判据是空的)",
                     fails - n8, hits_p0, hits_p1);
            if (fails == n8) fails = fails + 1;
        end

        // ---- 判据 3: busy 期间再请求 ----
        set_bundle(300); @(negedge clk_b);
        chk_tag = 0; k0 = n_valid;
        @(negedge clk_a); req_a = 1;
        repeat (3) @(negedge clk_a);
        req_a = 0;
        wait_next_valid;
        while (busy_a) @(negedge clk_a);
        repeat (4) @(negedge clk_a);
        if (n_valid == k0 + 1) $display("  [PASS] 3 busy: 连发 3 拍只产生 1 次 valid");
        else begin
            $display("  [FAIL] 3 busy: valid 增了 %0d 次 (期望 1)", n_valid - k0);
            fails = fails + 1;
        end

        // ---- 判据 4: 背靠背 8 次 ----
        chk_tag = 1;
        n4 = n_valid;  n8 = fails;
        for (try = 0; try < 8; try = try + 1) begin
            set_bundle(400 + try); @(negedge clk_b);
            request_snap;  wait_next_valid;
            phase = 400 + try; exp_tag = 400 + try;
            verify_capture;
        end
        if ((n_valid == n4 + 8) && (fails == n8))
            $display("  [PASS] 4 背靠背: 8 次请求 = 8 次 valid, 数据全对");
        else begin
            $display("  [FAIL] 4 背靠背: valid %0d 次 / 失败 %0d 项 (期望 8 / 0)", n_valid - n4, fails - n8);
            if (fails == n8) fails = fails + 1;
        end

        // ---- 判据 5: 负对照 A (撕裂源位束) ----
        $display("  --- 判据 5 负对照 A: 飞行中只推第 3 个字 (源位束被撕裂) ---");
        neg_mode = 1; chk_tag = 0; neg_fired = 0;
        for (try = 0; try < 16; try = try + 1) begin
            set_bundle(2000 + try*2); @(negedge clk_b);
            request_snap;
            repeat (try) @(negedge clk_b);
            put_word(3, 2000 + try*2 + 1);
            @(negedge clk_b);
            set_bundle(2000 + try*2 + 1);
            wait_next_valid;
            phase = 2000 + try;
            verify_capture;
            while (busy_a) @(negedge clk_a);
        end
        neg_mode = 0;
        if (neg_fired > 0)
            $display("  [PASS] 5 负对照 A: 撕裂被抓到 %0d 次 ⇒ 相干性检查确有判别力", neg_fired);
        else begin
            $display("  [FAIL] 5 负对照 A: 一次都没抓到撕裂 ⇒ 相干性判据是空判据");
            fails = fails + 1;
        end

        // ---- 判据 6: 飞行途中复位 ----
        set_bundle(600); @(negedge clk_b);
        request_snap;
        repeat (2) @(negedge clk_a);
        if (!busy_a) begin
            $display("  [FAIL] 6 复位回收: 请求发出 2 拍后 busy 竟然没拉高"); fails = fails + 1;
        end
        rst_n = 0;
        repeat (4) @(posedge clk_b);
        repeat (4) @(posedge clk_a);
        rst_n = 1;
        repeat (6) @(posedge clk_b);
        repeat (8) @(negedge clk_a);
        if (busy_a) begin
            $display("  [FAIL] 6 复位回收: 复位释放后 busy 挂死"); fails = fails + 1;
        end
        else if (n_valid != k0) begin
            $display("  [FAIL] 6 复位回收: 复位过程冒出 %0d 次假 valid", n_valid - k0); fails = fails + 1;
        end
        else $display("  [PASS] 6 复位回收: 飞行中复位 → 释放后回空闲, 无假 valid");

        set_bundle(601); @(negedge clk_b);
        n6 = fails;
        request_snap;  wait_next_valid;
        phase = 6; exp_tag = 601; chk_tag = 1;
        verify_capture;
        if (fails == n6) $display("  [PASS] 6b 复位后恢复正常快照 (tag=601)");

        // ---- 判据 7: b 时钟停摆 (跑一阵再停) ----
        set_bundle(700); @(negedge clk_b);
        clk_b_en = 0;
        request_snap;
        repeat (20) @(negedge clk_a);
        if (!busy_a) begin
            $display("  [FAIL] 7 时钟停摆: b 时钟停着 busy 却没挂高"); fails = fails + 1;
        end
        else if (n_valid != k0) begin
            $display("  [FAIL] 7 时钟停摆: b 时钟停着却冒出了 valid"); fails = fails + 1;
        end
        else $display("  [INFO] 7 b 时钟停摆: busy 挂高且无 valid (预期行为, 不是故障)");
        clk_b_en = 1;
        n7 = fails;
        wait_next_valid;
        phase = 7; exp_tag = 700; chk_tag = 1;
        verify_capture;
        if (fails == n7) $display("  [PASS] 7 时钟停摆: 恢复后握手自动补完, 数据正确 (tag=700)");

        // ---- 判据 8: ⭐ 真实工况 (源每拍都变 + 非整比时钟 + 偏斜) ----
        $display("  --- 判据 8: 源每拍都变 + clk_b 周期 9.1..12.0ns 扫描 + 通道偏斜 0.15..1.2ns, 200 次 ---");
        // ⚠️ 相位必须靠**扫 b 周期**来覆盖 (而不是 repeat(try%8) 挪 a 沿):
        //    采样沿相对 b 沿的偏移 = (δ + 固定同步链延迟) mod T_b, 而 δ 是 "b 沿之后第一个 a 沿"
        //    ⇒ 把整串 a 域事件平移整数个 a 拍对 δ **毫无影响** (第一版就是这么白扫的)。
        //    扫 T_b 才能让那个偏移带扫过 [0, 撕裂窗] ⇒ 直通模型才有机会被抓住。
        repeat (4) @(posedge clk_b);
        src_gen = 8000; src_run = 1;
        n8 = fails; mix_n = 0; naive_mix = 0; ext_naive = 0;
        for (try = 0; try < 200; try = try + 1) begin
            hb = 4.55 + (try % 50) * 0.03;               // T_b = 9.1 .. 12.04 ns (覆盖 12ns/16ns 两种可能链长)
            repeat (2) @(posedge clk_b);
            request_snap;  wait_next_valid;
            if (mix_count(cap_dout) != 0) mix_n = mix_n + 1;       // 真 RTL: 必须 0
            if (mix_count(naive_q)    != 0) begin                  // 负对照 B: 直通模型必须混
                naive_mix = naive_mix + 1;
                if (ext_naive == 0) begin
                    ext_naive = 1;
                    $display("  [INFO] 负对照 B 首次位混: naive tag=%h (该代 src_gen=%0d)", gtag, src_gen);
                end
            end
            while (busy_a) @(negedge clk_a);
        end
        src_run = 0; hb = 4.0;
        if (mix_n == 0) $display("  [PASS] 8a 真 RTL 在 200 次快照中 0 次位混 (源每拍都变)");
        else begin $display("  [FAIL] 8a 真 RTL 出现 %0d/200 次位混!", mix_n); fails = fails + 1; end
        if (naive_mix > 0)
            $display("  [PASS] 8b 负对照 B: 直通模型在**同一激励**下混了 %0d/200 次 ⇒ 判据 8a 有判别力", naive_mix);
        else begin
            $display("  [FAIL] 8b 负对照 B: 直通模型一次都没混 ⇒ 这段激励打不中'采样-变化同拍', 判据 8a 没判别力");
            fails = fails + 1;
        end

        // ---- 判据 9: 复位释放时 clk_b 还没起 (板上 PHY 时钟晚到的真实情形) ----
        $display("  --- 判据 9: 复位释放时 clk_b 停着 ---");
        rst_n = 0;
        clk_b_en = 0;
        k0 = n_valid;                                // ⚠️ 基数要在这里取, 不能沿用上一判据的陈旧 k0
        repeat (4) @(negedge clk_a);
        rst_n = 1;                                   // b 时钟还没起就放复位
        repeat (10) @(negedge clk_a);
        if (busy_a) begin
            $display("  [FAIL] 9 复位释放时 clk_b 没起 ⇒ busy 竟然挂高"); fails = fails + 1;
        end
        else if (n_valid != k0) begin
            $display("  [FAIL] 9 复位释放时 clk_b 没起 ⇒ 冒了假 valid"); fails = fails + 1;
        end
        else $display("  [PASS] 9a 复位释放 (clk_b 未起) ⇒ 空闲, 无假 valid/busy");
        clk_b_en = 1;                                // PHY 时钟晚到
        repeat (10) @(posedge clk_b);
        set_bundle(900); @(negedge clk_b);
        n9 = fails;
        request_snap;  wait_next_valid;
        phase = 9; exp_tag = 900; chk_tag = 1;
        verify_capture;
        if (fails == n9) $display("  [PASS] 9b clk_b 起来后第一次快照正常 (tag=900)");

        if (fails == 0) $display("PASS_ALL  tb_snap_cdc: 6 组正判据 + 2 条负对照 全过");
        else            $display("FAIL      tb_snap_cdc: %0d 项失败", fails);
        $display("=== done ===");
        $finish;
    end

    initial begin #2000000; $display("TIMEOUT"); $finish; end
endmodule
