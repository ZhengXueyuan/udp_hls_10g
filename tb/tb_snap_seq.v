`timescale 1ns/1ps
//=============================================================================
// tb_snap_seq.v — P6b 链式触发快照序列器 (rtl/snap_seq.v) 单元门
//=============================================================================
// 判据 (逐条打印 判据/期望/实测/判定; 末行 PASS_ALL 或 FAIL 列表):
//   1  32 字映射逐字 (层 1: 两束各填互不相同的常数 ⇒ 读回必须逐字等于预期表)
//       ⭐ 这是**唯一**能抓"索引表抄错一个字"的判据 —— 抄错只会读出"另一个字的正确值",
//          lint 完全看不见 (工程铁律③)。预期表在本 TB 里**独立重写一遍**(不是从 DUT 抄),
//          所以 DUT 表与 TB 表任一处笔误都会当场 FAIL。
//   2  链式顺序 (层 2): 用**绝对仿真时间**量两次锁存的先后 ——
//       `t(FE 锁存) <= t(DP 锁存)`。这是"有向判据 W6-W0 ∈{0,1} 结构性成立"的直接证据。
//   3  ⭐ **负对照 (变异测试)**: 同一个 TB 里放一个"**DP 先、FE 后**"的对照序列器
//       (`seq_swap`, 只在 TB 内) ⇒ 它的 t(FE) **必须晚于** t(DP) ⇒ 与判据 2 结论相反。
//       若正/负两个模型的顺序量测结果相同, 说明判据 2 是**空判据** (本 TB 自己报 FAIL)。
//   4  req 恰好 1 拍宽 (snap_cdc 硬契约①): 全程监视 req_fe/req_dp 的连续高电平拍数 ≤ 1。
//   5  busy 期间来的 req 被**忽略** (不排队): busy 中再触发 ⇒ 快照次数**不增加**。
//   6  两束确实来自**两个不同频率的域**: 同一次/两次快照之间
//       ΔW5(前端自由计数)/Δt ≈ 125MHz 且 ΔW24(数据面自由计数)/Δt ≈ 156.25MHz (各 ±1%)。
//       ⇒ 只改一条 Clock Summary 是骗不过这一条的 (它是**功能**证据, 不是约束证据)。
//   7  复位: 复位期间 busy=1? 不 ——复位释放后 idle、busy=0、valid 不冒假脉冲。
//   自检式 (无文件依赖); 用真实 snap_cdc (不是替身) ⇒ 顺带覆盖两模块的接线。
//   跑法: sim/p6b_snapseq/run_tb_snap_seq.bat
//=============================================================================
module tb_snap_seq;

    // ---- 三个时钟: axi 250MHz / FE 125MHz / DP 156.25MHz ----
    reg clk_axi = 0, clk_fe = 0, clk_dp = 0, rst_n = 0;
    always #2   clk_axi = ~clk_axi;      // 250 MHz
    always #4   clk_fe  = ~clk_fe;       // 125 MHz
    always #3.2 clk_dp  = ~clk_dp;       // 156.25 MHz

    integer fails = 0;
    task chk(input [255:0] name, input [31:0] got, input [31:0] exp);
        begin
            if (got === exp) $display("  [PASS] %0s = %08x", name, got);
            else begin $display("  [FAIL] %0s = %08x (期望 %08x)", name, got, exp); fails = fails + 1; end
        end
    endtask

    //=========================================================================
    // 层 1: 映射判定 (假握手 + 常数两束)
    //=========================================================================
    reg  [31:0] fe_const [0:13];
    reg  [31:0] dp_const [0:21];
    wire [447:0] fe_c = {fe_const[13], fe_const[12], fe_const[11], fe_const[10],
                         fe_const[9], fe_const[8], fe_const[7], fe_const[6], fe_const[5],
                         fe_const[4], fe_const[3], fe_const[2], fe_const[1], fe_const[0]};
    wire [703:0] dp_c = {dp_const[21], dp_const[20], dp_const[19], dp_const[18], dp_const[17],
                         dp_const[16], dp_const[15], dp_const[14], dp_const[13], dp_const[12],
                         dp_const[11], dp_const[10], dp_const[9],  dp_const[8],  dp_const[7],
                         dp_const[6],  dp_const[5],  dp_const[4],  dp_const[3],  dp_const[2],
                         dp_const[1],  dp_const[0]};

    reg  req1 = 0;
    wire busy1, valid1;
    wire [1151:0] dout1;
    wire [2:0] fe_state1;
    wire [1:0] dbg_state1;
    wire req_fe1, req_dp1;
    reg  valid_fe1 = 0, valid_dp1 = 0;

    snap_seq #(.FW(14), .DW(22)) u_seq1 (
        .clk(clk_axi), .rst_n(rst_n), .req(req1), .busy(busy1),
        .dout(dout1), .valid(valid1), .fe_state(fe_state1), .dbg_state(dbg_state1),
        .req_fe(req_fe1), .busy_fe(1'b0), .valid_fe(valid_fe1), .dout_fe(fe_c),
        .req_dp(req_dp1), .busy_dp(1'b0), .valid_dp(valid_dp1), .dout_dp(dp_c)
    );

    // 假 b 域: req 之后下一拍给 valid (⇒ 每束 2 拍, 与真 snap_cdc 的量级同)
    always @(posedge clk_axi) begin
        valid_fe1 <= req_fe1;
        valid_dp1 <= req_dp1;
    end

    // ⚠️ req_fe/req_dp **恰好 1 拍宽** 的全程监视 (判据 4)
    integer fe_hi, dp_hi, max_fe_hi, max_dp_hi;
    always @(posedge clk_axi) begin
        if (req_fe1) fe_hi = fe_hi + 1; else begin
            if (fe_hi > max_fe_hi) max_fe_hi = fe_hi;
            fe_hi = 0;
        end
        if (req_dp1) dp_hi = dp_hi + 1; else begin
            if (dp_hi > max_dp_hi) max_dp_hi = dp_hi;
            dp_hi = 0;
        end
    end

    // ---- 独立重写的 36 行对照表 (来自 P6B_SPEC §7.2 的逐项对照表, **手抄自文档**) ----
    // exp_src[w] = 0 ⇒ 取 FE 的 fe[exp_idx[w]]; 1 ⇒ 取 DP 的 dp[exp_idx[w]]
    integer exp_is_dp [0:35];
    integer exp_idx   [0:35];
    task init_exp_map;
        integer w;
        begin
            for (w = 0; w < 36; w = w + 1) begin
                exp_is_dp[w] = 0; exp_idx[w] = -1;
            end
            // W0..W5  = fe[0..5]
            exp_is_dp[0]=0;  exp_idx[0]=0;   exp_is_dp[1]=0;  exp_idx[1]=1;
            exp_is_dp[2]=0;  exp_idx[2]=2;   exp_is_dp[3]=0;  exp_idx[3]=3;
            exp_is_dp[4]=0;  exp_idx[4]=4;   exp_is_dp[5]=0;  exp_idx[5]=5;
            // W6..W19 = dp[0..13]
            exp_is_dp[6]=1;  exp_idx[6]=0;   exp_is_dp[7]=1;  exp_idx[7]=1;
            exp_is_dp[8]=1;  exp_idx[8]=2;   exp_is_dp[9]=1;  exp_idx[9]=3;
            exp_is_dp[10]=1; exp_idx[10]=4;  exp_is_dp[11]=1; exp_idx[11]=5;
            exp_is_dp[12]=1; exp_idx[12]=6;  exp_is_dp[13]=1; exp_idx[13]=7;
            exp_is_dp[14]=1; exp_idx[14]=8;  exp_is_dp[15]=1; exp_idx[15]=9;
            exp_is_dp[16]=1; exp_idx[16]=10; exp_is_dp[17]=1; exp_idx[17]=11;
            exp_is_dp[18]=1; exp_idx[18]=12; exp_is_dp[19]=1; exp_idx[19]=13;
            // W20/W21 = fe[7]/fe[6]  (**反的** —— 拼接字符串从右往左读)
            exp_is_dp[20]=0; exp_idx[20]=7;  exp_is_dp[21]=0; exp_idx[21]=6;
            // W22/W23 = dp[14]/dp[15]
            exp_is_dp[22]=1; exp_idx[22]=14; exp_is_dp[23]=1; exp_idx[23]=15;
            // W24..W25 = dp[16]/dp[17]
            exp_is_dp[24]=1; exp_idx[24]=16; exp_is_dp[25]=1; exp_idx[25]=17;
            // W26/W27 = fe[9]/fe[8]  (**同样反的**)
            exp_is_dp[26]=0; exp_idx[26]=9;  exp_is_dp[27]=0; exp_idx[27]=8;
            // W28..W31 = dp[18..21]
            exp_is_dp[28]=1; exp_idx[28]=18; exp_is_dp[29]=1; exp_idx[29]=19;
            exp_is_dp[30]=1; exp_idx[30]=20; exp_is_dp[31]=1; exp_idx[31]=21;
            // W32..W35 = fe[10..13]  (F4 的 4 个新计数器, 全在 FE 束)
            exp_is_dp[32]=0; exp_idx[32]=10; exp_is_dp[33]=0; exp_idx[33]=11;
            exp_is_dp[34]=0; exp_idx[34]=12; exp_is_dp[35]=0; exp_idx[35]=13;
        end
    endtask

    //=========================================================================
    // 层 2: 链式顺序 (真 snap_cdc ×2 + 两域自由计数)
    //=========================================================================
    reg  [31:0] fe_free = 0, dp_free = 0;
    always @(posedge clk_fe) fe_free <= fe_free + 32'd1;
    always @(posedge clk_dp) dp_free <= dp_free + 32'd1;

    localparam [31:0] FE_MARK = 32'hFE000000;
    localparam [31:0] DP_MARK = 32'hD0000000;
    wire [447:0] fe_b = {FE_MARK+13, FE_MARK+12, FE_MARK+11, FE_MARK+10,
                         FE_MARK+9, FE_MARK+8, FE_MARK+7, FE_MARK+6, fe_free,        // fe[5] = 自由计数 (W5)
                         FE_MARK+4, FE_MARK+3, FE_MARK+2, FE_MARK+1, FE_MARK+0};
    wire [703:0] dp_b = {DP_MARK+21, DP_MARK+20, DP_MARK+19, DP_MARK+18, DP_MARK+17,
                         dp_free,                                                   // dp[16] = 自由计数 (W24)
                         DP_MARK+15, DP_MARK+14, DP_MARK+13, DP_MARK+12, DP_MARK+11,
                         DP_MARK+10, DP_MARK+9,  DP_MARK+8,  DP_MARK+7,  DP_MARK+6,
                         DP_MARK+5,  DP_MARK+4,  DP_MARK+3,  DP_MARK+2,  DP_MARK+1,
                         DP_MARK+0};

    reg         req2 = 0;
    wire        busy2, valid2;
    wire [1151:0] dout2;
    wire        req_fe2, req_dp2;
    wire        busy_fe2, busy_dp2, valid_fe2, valid_dp2;
    wire [447:0] hold_fe2;
    wire [703:0] hold_dp2;

    snap_seq #(.FW(14), .DW(22)) u_seq2 (
        .clk(clk_axi), .rst_n(rst_n), .req(req2), .busy(busy2),
        .dout(dout2), .valid(valid2), .fe_state(), .dbg_state(),
        .req_fe(req_fe2), .busy_fe(busy_fe2), .valid_fe(valid_fe2), .dout_fe(hold_fe2),
        .req_dp(req_dp2), .busy_dp(busy_dp2), .valid_dp(valid_dp2), .dout_dp(hold_dp2)
    );

    snap_cdc #(.W(32), .NW(14)) u_cdc_fe (
        .clk_a(clk_axi), .rst_n(rst_n), .req_a(req_fe2), .busy_a(busy_fe2),
        .dout_a(hold_fe2), .valid_a(valid_fe2), .clk_b(clk_fe), .din_b(fe_b)
    );
    snap_cdc #(.W(32), .NW(22)) u_cdc_dp (
        .clk_a(clk_axi), .rst_n(rst_n), .req_a(req_dp2), .busy_a(busy_dp2),
        .dout_a(hold_dp2), .valid_a(valid_dp2), .clk_b(clk_dp), .din_b(dp_b)
    );

    // ---- 锁存时刻 (绝对仿真时间): 监视 b 域 hold_b 的变化沿 ----
    real t_fe_lat, t_dp_lat;
    reg  armed;
    always @(u_cdc_fe.hold_b) if (armed) t_fe_lat = $realtime;
    always @(u_cdc_dp.hold_b) if (armed) t_dp_lat = $realtime;

    //=========================================================================
    // 负对照: "DP 先、FE 后" 的对照序列器 (只在 TB 内, 用同一对 snap_cdc 的副本)
    //=========================================================================
    // 结构与 snap_seq 同, 但**先发 DP 的 req**。用途: 证明判据 2 有判别力 ——
    // 若把它也判成"FE 先", 说明本 TB 的顺序量测根本测不到东西。
    reg         req3 = 0;
    reg         s3_st;
    wire        req_fe3, req_dp3;
    wire        valid_fe3, valid_dp3, busy_fe3, busy_dp3;
    wire [447:0] hold_fe3;
    wire [703:0] hold_dp3;
    reg  [1:0]  s3_st2;

    snap_cdc #(.W(32), .NW(14)) u_cdc_fe3 (
        .clk_a(clk_axi), .rst_n(rst_n), .req_a(req_fe3), .busy_a(busy_fe3),
        .dout_a(hold_fe3), .valid_a(valid_fe3), .clk_b(clk_fe), .din_b(fe_b)
    );
    snap_cdc #(.W(32), .NW(22)) u_cdc_dp3 (
        .clk_a(clk_axi), .rst_n(rst_n), .req_a(req_dp3), .busy_a(busy_dp3),
        .dout_a(hold_dp3), .valid_a(valid_dp3), .clk_b(clk_dp), .din_b(dp_b)
    );
    // ⚠️ 顺序刻意**反着写** (DP 先): 这是负对照的全部内容
    reg r_fe3, r_dp3;
    always @(posedge clk_axi or negedge rst_n) begin
        if (!rst_n) begin s3_st2 <= 2'd0; r_dp3 <= 1'b0; r_fe3 <= 1'b0; end
        else begin
            r_dp3 <= 1'b0; r_fe3 <= 1'b0;
            case (s3_st2)
                2'd0: if (req3) begin r_dp3 <= 1'b1; s3_st2 <= 2'd1; end
                2'd1: if (valid_dp3) begin r_fe3 <= 1'b1; s3_st2 <= 2'd2; end
                2'd2: if (valid_fe3) s3_st2 <= 2'd0;
                default: s3_st2 <= 2'd0;
            endcase
        end
    end
    assign req_dp3 = r_dp3;
    assign req_fe3 = r_fe3;
    real t_fe_lat3, t_dp_lat3;
    reg  armed3;
    always @(u_cdc_fe3.hold_b) if (armed3) t_fe_lat3 = $realtime;
    always @(u_cdc_dp3.hold_b) if (armed3) t_dp_lat3 = $realtime;

    //=========================================================================
    // 主激励
    //=========================================================================
    integer i, w, ok, n_snap_1;
    reg [31:0] v, expw;
    real dt, f_fe, f_dp;
    reg [31:0] w5_a, w5_b, w24_a, w24_b;
    real t_dp_a, t_dp_b;

    initial begin
        $display("=== tb_snap_seq: 链式触发快照序列器单元门 (含顺序负对照) ===");
        init_exp_map;
        for (i = 0; i < 14; i = i + 1) fe_const[i] = 32'hA0A00000 + i;
        for (i = 0; i < 22; i = i + 1) dp_const[i] = 32'hB0B00000 + i;
        fe_hi = 0; dp_hi = 0; max_fe_hi = 0; max_dp_hi = 0;
        n_snap_1 = 0;

        repeat (6) @(posedge clk_axi);
        rst_n = 1;
        repeat (4) @(posedge clk_axi);

        // ---------------- 判据 7: 复位后空闲 ----------------
        $display("  --- 判据 7: 复位释放后必须空闲 ---");
        if (!busy1 && !valid1) $display("  [PASS] 7  busy=0 / valid=0 (无假脉冲)");
        else begin $display("  [FAIL] 7  busy=%b valid=%b (复位后不该忙)", busy1, valid1); fails = fails + 1; end

        // ---------------- 判据 5: busy 期间 req 被忽略 ----------------
        $display("  --- 判据 5: busy 期间来的 req 必须被忽略 (不排队) ---");
        @(negedge clk_axi); req1 = 1'b1;                 // 第 1 次触发
        @(negedge clk_axi); req1 = 1'b1;                 // 立刻再触发 (此刻必然 busy)
        @(negedge clk_axi); req1 = 1'b1;                 // 再补一次
        @(negedge clk_axi); req1 = 1'b0;
        // 等两次 valid (真 snap_seq 只该给 1 次)
        ok = 0;
        for (i = 0; i < 200; i = i + 1) begin
            @(posedge clk_axi);
            if (valid1) n_snap_1 = n_snap_1 + 1;
        end
        repeat (40) @(posedge clk_axi);
        chk("5  busy 中 3 次 req 只产生 1 次快照", n_snap_1, 32'd1);

        // ---------------- 判据 4: req 恰好 1 拍宽 ----------------
        $display("  --- 判据 4: req_fe / req_dp 必须恰好 1 拍宽 ---");
        chk("4a req_fe 最长连续高电平拍数", max_fe_hi, 32'd1);
        chk("4b req_dp 最长连续高电平拍数", max_dp_hi, 32'd1);

        // ---------------- 判据 1: 32 字映射逐字 ----------------
        $display("  --- 判据 1: 32 字映射逐字 (两束=互不相同的常数) ---");
        @(negedge clk_axi); req1 = 1'b1;
        @(negedge clk_axi); req1 = 1'b0;
        ok = 0;
        for (i = 0; i < 200 && !ok; i = i + 1) begin
            @(posedge clk_axi);
            if (valid1) ok = 1;
        end
        if (!ok) begin $display("  [FAIL] 1  没等到 valid1 (序列器卡死?)"); fails = fails + 1; end
        else begin
            for (w = 0; w < 36; w = w + 1) begin
                v = dout1[w*32 +: 32];
                if (exp_is_dp[w]) expw = dp_const[exp_idx[w]];
                else              expw = fe_const[exp_idx[w]];
                if (v !== expw) begin
                    $display("  [FAIL] 1  W%0d = %08x (期望 %08x, 来自 %0s[%0d])",
                             w, v, expw, exp_is_dp[w] ? "dp" : "fe", exp_idx[w]);
                    fails = fails + 1;
                end else if (w == 20 || w == 21 || w == 26 || w == 27) begin
                    $display("  [PASS] 1  W%0d = %08x (反槽号: %0s[%0d])",
                             w, v, exp_is_dp[w] ? "dp" : "fe", exp_idx[w]);
                end
            end
            if (fails == 0) $display("  [PASS] 1  36 个字逐字与独立重写的对照表一致");
        end

        // ---------------- 判据 2: 链式顺序 (真 snap_cdc) ----------------
        $display("  --- 判据 2: 链式顺序 = FE 锁存 <= DP 锁存 (绝对时间) ---");
        armed = 1'b1;
        @(negedge clk_axi); req2 = 1'b1;
        @(negedge clk_axi); req2 = 1'b0;
        ok = 0;
        for (i = 0; i < 300 && !ok; i = i + 1) begin
            @(posedge clk_axi);
            if (valid2) ok = 1;
        end
        t_dp_a = t_dp_lat;                       // ★ 用 **DP 锁存时刻** 当时间基准
        w5_a  = dout2[5*32  +: 32];
        w24_a = dout2[24*32 +: 32];
        if (!ok) begin $display("  [FAIL] 2  没等到 valid2"); fails = fails + 1; end
        else if (t_fe_lat <= t_dp_lat)
            $display("  [PASS] 2  t(FE 锁存)=%.1fns <= t(DP 锁存)=%.1fns (链式方向成立)",
                     t_fe_lat, t_dp_lat);
        else begin
            $display("  [FAIL] 2  t(FE)=%.1fns > t(DP)=%.1fns ⇒ 链式顺序被破坏", t_fe_lat, t_dp_lat);
            fails = fails + 1;
        end
        // 逐字标记核对: 两束的每个字都带自己的域标记 (FE=0xFE000000+i / DP=0xD0000000+i)
        // ⇒ 一次就能看出"某一路被接到了另一束"(映射表的另一半证据)
        chk("2b 层2 W0  = fe[0] 标记", dout2[0*32  +: 32], 32'hFE000000);
        chk("2c 层2 W5  = fe[5] (自由计数, 小值)", w5_a & 32'hFF000000, 32'h00000000);
        chk("2d 层2 W6  = dp[0] 标记", dout2[6*32  +: 32], 32'hD0000000);
        chk("2e 层2 W20 = fe[7] 标记", dout2[20*32 +: 32], 32'hFE000007);
        chk("2f 层2 W24 = dp[16] (自由计数, 小值)", w24_a & 32'hF0000000, 32'h00000000);
        chk("2g 层2 W26 = fe[9] 标记", dout2[26*32 +: 32], 32'hFE000009);
        chk("2h 层2 W31 = dp[21] 标记", dout2[31*32 +: 32], 32'hD0000015);

        // ---------------- 判据 3: 负对照 (DP 先) ----------------
        $display("  --- 判据 3 负对照: 把顺序对调 (DP 先 FE 后) ⇒ 方向必须相反 ---");
        armed3 = 1'b1;
        @(negedge clk_axi); req3 = 1'b1;
        @(negedge clk_axi); req3 = 1'b0;
        ok = 0;
        for (i = 0; i < 300 && !ok; i = i + 1) begin
            @(posedge clk_axi);
            if (s3_st2 == 2'd0 && t_dp_lat3 > 0.0) ok = 1;
        end
        if (!ok) begin
            $display("  [FAIL] 3  负对照序列器没跑完 (t_dp=%.1f t_fe=%.1f)", t_dp_lat3, t_fe_lat3);
            fails = fails + 1;
        end else if (t_fe_lat3 > t_dp_lat3) begin
            $display("  [PASS] 3  对调后 t(FE)=%.1fns > t(DP)=%.1fns ⇒ 判据2 **有判别力** (不是空判据)",
                     t_fe_lat3, t_dp_lat3);
        end else begin
            $display("  [FAIL] 3  对调后顺序没变 (t(DP)=%.1f <= t(FE)=%.1f) ⇒ 判据2 是空判据",
                     t_dp_lat3, t_fe_lat3);
            fails = fails + 1;
        end

        // ---------------- 判据 6: 两个域的频率 ----------------
        $display("  --- 判据 6: 两束确实来自两个不同频率的域 (功能证据, 不是约束证据) ---");
        // 第二个快照 (隔 ~20us)
        repeat (2500) @(posedge clk_axi);
        @(negedge clk_axi); req2 = 1'b1;
        @(negedge clk_axi); req2 = 1'b0;
        ok = 0;
        for (i = 0; i < 300 && !ok; i = i + 1) begin
            @(posedge clk_axi);
            if (valid2) ok = 1;
        end
        t_dp_b = t_dp_lat;
        w5_b  = dout2[5*32  +: 32];
        w24_b = dout2[24*32 +: 32];
        // ⚠️ 时间基准必须取**两次 DP 锁存时刻之差** (不是两次 valid 之差): 快照代表的是
        //    "锁存那一刻"的值, 而 valid 还要再跨 3 拍 axi 回送 ⇒ 用 valid 会给频率叠加
        //    一个和 Δ 无关的固定偏差 (本工程"空读数/口径错"类坑)。
        dt = t_dp_b - t_dp_a;
        // 单位: $realtime 是 ns ⇒ 增量/ns × 1000 = MHz
        f_fe = (w5_b  - w5_a)  / dt * 1000.0;
        f_dp = (w24_b - w24_a) / dt * 1000.0;
        $display("  [INFO] 6  ΔW5=%0d ΔW24=%0d Δt=%.1fns ⇒ FE=%.3f MHz  DP=%.3f MHz",
                 w5_b - w5_a, w24_b - w24_a, dt, f_fe, f_dp);
        if (f_fe >= 123.75 && f_fe <= 126.25) $display("  [PASS] 6a 前端束 ≈125MHz (实测 %.3f)", f_fe);
        else begin $display("  [FAIL] 6a 前端束频率 %.3f MHz 不在 125±1%%", f_fe); fails = fails + 1; end
        if (f_dp >= 154.6875 && f_dp <= 157.8125) $display("  [PASS] 6b 数据面束 ≈156.25MHz (实测 %.3f)", f_dp);
        else begin $display("  [FAIL] 6b 数据面束频率 %.3f MHz 不在 156.25±1%%", f_dp); fails = fails + 1; end

        if (fails == 0) $display("PASS_ALL  tb_snap_seq: 7 组判据全过 (含顺序负对照)");
        else            $display("FAIL      tb_snap_seq: %0d 项失败", fails);
        $display("=== done ===");
        $finish;
    end

    initial begin
        #400000; $display("TIMEOUT"); $finish;
    end
endmodule
