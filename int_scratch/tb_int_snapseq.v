`timescale 1ns/1ps
//=============================================================================
// tb_int_snapseq.v — 独立审查 agent 的 snap_seq 链式顺序门 (**独立于 rtl/snap_seq.v 自带
//   的 tb_snap_seq.v**: 自带 TB 复用它自己的 fe_idx_of/dp_idx_of 当期望值 ⇒ 表抄错时它
//   跟 DUT 一起错。本门把 36 行映射**手工写死** (来源 = board/wrapper_p4.v 的 fe_src/dp_src
//   拼接逐项读出, 见 int_scratch/NOTES 的推导), 且顺序判据用**墙钟时间戳**, 不是它自己的量)。
//
// 判据:
//   M1 逐字映射: 36 个字里每一个都必须来自我写死的那张表的 (束, 槽)
//   M2 链式顺序 (**核心**): FE 束的捕获时刻 < DP 束的捕获时刻, 在**大量样本**上 100% 成立
//   M3 硬契约①: req_fe/req_dp 恰好 1 拍宽 (>=2 拍即 FAIL)
//   M4 valid 恰好 1 拍宽; dout 只在 valid 那拍有意义 (序号自洽)
//   M5 忙时来 req = 丢一次 (不排队, 不重复) —— 触发次数 = 完成次数
//
// 负对照 (run_neg: +define+NEG_DP_FIRST, 在**副本**里把链序改成 DP 先 → M2 必须 FAIL)
//=============================================================================
module fake_cdc #(
    parameter integer W  = 32
) (
    input  wire             clk_a, rst_n_a,
    input  wire             req_a,
    output wire             busy_a,
    output reg  [W*32-1:0]  dout_a,
    output reg              valid_a,
    input  wire             clk_b, rst_n_b,
    input  wire [W*32-1:0]  din_b,
    output reg  [31:0]      t_cap_b,
    output reg  [31:0]      gen_b
);
    // 忠实模型: **toggle 握手** (与 rtl/snap_cdc.v 逐条同构)
    //   ⚠️ 我第一版模型用"脉冲 + b 域边沿检测" ⇒ 4ns 的 req 脉冲会被 8ns 的 b 时钟漏掉
    //      (req_fe 高过但 valid_fe 永不来, 假失败)。真 snap_cdc 用 **toggle 电平** ⇒ 不会漏。
    reg toggle_a;
    always @(posedge clk_a or negedge rst_n_a)
        if (!rst_n_a)              toggle_a <= 1'b0;
        else if (req_a && !busy_a) toggle_a <= ~toggle_a;

    reg [2:0] tog_sync_b;
    always @(posedge clk_b or negedge rst_n_b)
        if (!rst_n_b) tog_sync_b <= 3'd0;
        else          tog_sync_b <= {tog_sync_b[1:0], toggle_a};
    wire update_b = (tog_sync_b[2] ^ tog_sync_b[1]);

    reg [W*32-1:0] hold_b;
    reg            ack_b;
    reg [63:0]     tnow64;
    always @(posedge clk_b or negedge rst_n_b) begin
        if (!rst_n_b) begin
            hold_b <= {(W*32){1'b0}}; ack_b <= 1'b0; t_cap_b <= 32'd0; gen_b <= 32'd0;
        end else if (update_b) begin
            hold_b  <= din_b;
            tnow64 = $time; t_cap_b <= tnow64[31:0];   // 捕获时刻 (b 域墙钟)
            gen_b   <= gen_b + 32'd1;
            ack_b   <= ~ack_b;
        end
    end

    reg [2:0] ack_sync_a;
    always @(posedge clk_a or negedge rst_n_a)
        if (!rst_n_a) ack_sync_a <= 3'd0;
        else          ack_sync_a <= {ack_sync_a[1:0], ack_b};
    wire done_a = (ack_sync_a[2] == toggle_a);
    assign busy_a = (ack_sync_a[2] != toggle_a);

    reg done_r;
    always @(posedge clk_a or negedge rst_n_a) begin
        if (!rst_n_a) begin
            done_r <= 1'b1; dout_a <= {(W*32){1'b0}}; valid_a <= 1'b0;
        end else begin
            done_r  <= done_a;
            valid_a <= done_a && !done_r;
            if (done_a && !done_r) dout_a <= hold_b;
        end
    end
endmodule

module tb_int_snapseq;

    localparam integer FW = 14;
    localparam integer DW = 22;
    localparam integer NW = FW + DW;   // 36

    // ---- 三个时钟: axi 4ns / gmii 8ns / dp 6.4ns ----
    reg clk_axi = 1'b0, clk_gmii = 1'b0, clk_dp = 1'b0;
    always #2.0   clk_axi  = ~clk_axi;
    always #4.0   clk_gmii = ~clk_gmii;
    always #3.2   clk_dp   = ~clk_dp;
    reg rst_n = 1'b0;

    reg             req;
    wire            busy, valid;
    wire [NW*32-1:0] dout;
    wire [2:0]      fe_state;
    wire [1:0]      dbg_state;
    wire            req_fe, req_dp, busy_fe, busy_dp, valid_fe, valid_dp;
    wire [FW*32-1:0] fe_dout;
    wire [DW*32-1:0] dp_dout;

    // FE 束: 每槽 = 0xFE00_0000 + 槽号
    wire [FW*32-1:0] fe_src;
    wire [DW*32-1:0] dp_src;
    genvar g;
    generate
        for (g = 0; g < FW; g = g + 1) assign fe_src[g*32 +: 32] = 32'hFE000000 + g[31:0];
        for (g = 0; g < DW; g = g + 1) assign dp_src[g*32 +: 32] = 32'hD0000000 + g[31:0];
    endgenerate

    // ---- 假 CDC: FE 域故意比 DP 域慢/慢受理, 制造可观偏斜 ----
    wire [31:0] t_fe, t_dp, gen_fe, gen_dp;
    fake_cdc #(.W(FW)) u_fake_fe (
        .clk_a(clk_axi), .rst_n_a(rst_n), .req_a(req_fe), .busy_a(busy_fe),
        .dout_a(fe_dout), .valid_a(valid_fe),
        .clk_b(clk_gmii), .rst_n_b(rst_n), .din_b(fe_src),
        .t_cap_b(t_fe), .gen_b(gen_fe)
    );
    fake_cdc #(.W(DW)) u_fake_dp (
        .clk_a(clk_axi), .rst_n_a(rst_n), .req_a(req_dp), .busy_a(busy_dp),
        .dout_a(dp_dout), .valid_a(valid_dp),
        .clk_b(clk_dp), .rst_n_b(rst_n), .din_b(dp_src),
        .t_cap_b(t_dp), .gen_b(gen_dp)
    );

    snap_seq #(.FW(FW), .DW(DW)) dut (
        .clk(clk_axi), .rst_n(rst_n),
        .req(req), .busy(busy), .dout(dout), .valid(valid), .fe_state(fe_state),
        .dbg_state(dbg_state),
        .req_fe(req_fe), .busy_fe(busy_fe), .valid_fe(valid_fe), .dout_fe(fe_dout),
        .req_dp(req_dp), .busy_dp(busy_dp), .valid_dp(valid_dp), .dout_dp(dp_dout)
    );

    //=========================================================================
    // 我手工写死的 36 行映射 —— 来源: board/wrapper_p4.v 的 fe_src/dp_src 拼接
    //   (拼接最右项 = fe[0]/dp[0]; 逐项往上读 ⇒ 见 int_scratch/NOTES_map.md)
    //   src: 0 = FE 束, 1 = DP 束
    //=========================================================================
    integer exp_src [0:35];
    integer exp_idx [0:35];
    initial begin
        // W0..W5  → fe[0..5]
        exp_src[0]=0; exp_idx[0]=0; exp_src[1]=0; exp_idx[1]=1; exp_src[2]=0; exp_idx[2]=2;
        exp_src[3]=0; exp_idx[3]=3; exp_src[4]=0; exp_idx[4]=4; exp_src[5]=0; exp_idx[5]=5;
        // W6..W19 → dp[0..13]
        exp_src[6]=1;  exp_idx[6]=0;  exp_src[7]=1;  exp_idx[7]=1;
        exp_src[8]=1;  exp_idx[8]=2;  exp_src[9]=1;  exp_idx[9]=3;
        exp_src[10]=1; exp_idx[10]=4; exp_src[11]=1; exp_idx[11]=5;
        exp_src[12]=1; exp_idx[12]=6; exp_src[13]=1; exp_idx[13]=7;
        exp_src[14]=1; exp_idx[14]=8; exp_src[15]=1; exp_idx[15]=9;
        exp_src[16]=1; exp_idx[16]=10; exp_src[17]=1; exp_idx[17]=11;
        exp_src[18]=1; exp_idx[18]=12; exp_src[19]=1; exp_idx[19]=13;
        // W20 → fe[7] ; W21 → fe[6]   (**槽号是反的**, 出题点)
        exp_src[20]=0; exp_idx[20]=7;  exp_src[21]=0; exp_idx[21]=6;
        // W22..W25 → dp[14..17]
        exp_src[22]=1; exp_idx[22]=14; exp_src[23]=1; exp_idx[23]=15;
        exp_src[24]=1; exp_idx[24]=16; exp_src[25]=1; exp_idx[25]=17;
        // W26 → fe[9] ; W27 → fe[8]   (**槽号是反的**)
        exp_src[26]=0; exp_idx[26]=9;  exp_src[27]=0; exp_idx[27]=8;
        // W28..W31 → dp[18..21]
        exp_src[28]=1; exp_idx[28]=18; exp_src[29]=1; exp_idx[29]=19;
        exp_src[30]=1; exp_idx[30]=20; exp_src[31]=1; exp_idx[31]=21;
        // W32..W35 → fe[10..13]
        exp_src[32]=0; exp_idx[32]=10; exp_src[33]=0; exp_idx[33]=11;
        exp_src[34]=0; exp_idx[34]=12; exp_src[35]=0; exp_idx[35]=13;
    end

    integer errors = 0;
    integer nsamples = 0;
    integer n_order_ok = 0, n_order_bad = 0;
    integer min_skew = 1000000000, max_skew = -1000000000;
    integer ns_req_fe_too_long = 0, ns_req_dp_too_long = 0;
    integer ns_valid_fe_multi = 0, ns_valid_dp_multi = 0;
    integer ns_map_bad = 0;
    integer ntrig = 0, ndone = 0;

    // ---- 硬契约① 监视: req 连续 2 拍高 ----
    reg req_fe_d, req_dp_d, valid_fe_d, valid_dp_d;
    always @(posedge clk_axi) begin
        req_fe_d   <= req_fe;
        req_dp_d   <= req_dp;
        valid_fe_d <= valid_fe;
        valid_dp_d <= valid_dp;
        if (req_fe   && req_fe_d)   ns_req_fe_too_long = ns_req_fe_too_long + 1;
        if (req_dp   && req_dp_d)   ns_req_dp_too_long = ns_req_dp_too_long + 1;
        if (valid_fe && valid_fe_d) ns_valid_fe_multi  = ns_valid_fe_multi  + 1;
        if (valid_dp && valid_dp_d) ns_valid_dp_multi  = ns_valid_dp_multi  + 1;
    end

    integer i, k;
    integer skew;
    reg [31:0] w;
    reg [31:0] t_fe_snap, t_dp_snap;

    // 每次 valid 上升沿: 采时间戳 + 逐字核对 + 顺序判据
    always @(posedge clk_axi) begin
        if (rst_n && valid) begin
            ndone = ndone + 1;
            t_fe_snap = t_fe;
            t_dp_snap = t_dp;
            // ---- M1 逐字映射 ----
            for (i = 0; i < NW; i = i + 1) begin
                w = dout[i*32 +: 32];
                if (exp_src[i] == 0) begin
                    if (w !== (32'hFE000000 + exp_idx[i])) begin
                        $display("FAIL M1 W%0d got=%08x 期望 FE 束 fe[%0d] (=%08x)", i, w, exp_idx[i], 32'hFE000000+exp_idx[i]);
                        ns_map_bad = ns_map_bad + 1;
                    end
                end else begin
                    if (w !== (32'hD0000000 + exp_idx[i])) begin
                        $display("FAIL M1 W%0d got=%08x 期望 DP 束 dp[%0d] (=%08x)", i, w, exp_idx[i], 32'hD0000000+exp_idx[i]);
                        ns_map_bad = ns_map_bad + 1;
                    end
                end
            end
            // ---- M2 链式顺序: FE 捕获必须先于 DP 捕获 ----
            skew = t_dp_snap - t_fe_snap;
            nsamples = nsamples + 1;
            if (skew > 0) n_order_ok = n_order_ok + 1;
            else          n_order_bad = n_order_bad + 1;
            if (skew < min_skew) min_skew = skew;
            if (skew > max_skew) max_skew = skew;
        end
    end

    initial begin
        req = 1'b0;
        repeat (8) @(posedge clk_axi);
        rst_n = 1'b1;
        repeat (8) @(posedge clk_axi);

        // 40 代快照, 间隔带抖动 (触发被丢也无所谓 —— 计数靠 ntrig/ndone 对账)
        for (k = 0; k < 40; k = k + 1) begin
            @(posedge clk_axi);
            req <= 1'b1;
            ntrig = ntrig + 1;
            @(posedge clk_axi);
            req <= 1'b0;
            // 等这一代**真正完成**再发下一次 ⇒ 每触发必有 1 次完成 (M5 的背靠背那发才该被丢)
            repeat (4) @(posedge clk_axi);
            while (busy) @(posedge clk_axi);
            repeat (2 + (k % 5)) @(posedge clk_axi);
        end
        // 等最后一个完成
        repeat (60) @(posedge clk_axi);

        // ---- M5 忙时丢请求: 连续背靠背触发 (第 2 个必然落在 busy 里) ----
        @(posedge clk_axi); req <= 1'b1; ntrig = ntrig + 1;
        @(posedge clk_axi); req <= 1'b0;
        @(posedge clk_axi); req <= 1'b1; ntrig = ntrig + 1;   // 忙中触发
        @(posedge clk_axi); req <= 1'b0;
        repeat (80) @(posedge clk_axi);

        $display("INFO M1 映射错字数 = %0d", ns_map_bad);
        $display("INFO M2 样本 %0d 代: 顺序成立 %0d / 违反 %0d ; 偏斜(ps) min=%0d max=%0d",
                 nsamples, n_order_ok, n_order_bad, min_skew, max_skew);
        $display("INFO M3 req 连续高: fe=%0d dp=%0d (必须 0)", ns_req_fe_too_long, ns_req_dp_too_long);
        $display("INFO M4 valid 连续高: fe=%0d dp=%0d (必须 0)", ns_valid_fe_multi, ns_valid_dp_multi);
        $display("INFO M5 触发 %0d 次 / 完成 %0d 次 (背靠背那一发应被丢 ⇒ 完成 <= 触发)", ntrig, ndone);

        if (ns_map_bad != 0)          errors = errors + 1;
        if (n_order_bad != 0)         errors = errors + 1;
        if (nsamples < 20) begin $display("FAIL M2 样本太少 (%0d)", nsamples); errors = errors + 1; end
        if (ns_req_fe_too_long != 0 || ns_req_dp_too_long != 0) errors = errors + 1;
        if (ns_valid_fe_multi != 0 || ns_valid_dp_multi != 0)   errors = errors + 1;

        if (errors == 0) $display("PASS_ALL tb_int_snapseq (样本=%0d)", nsamples);
        else             $display("FAIL_TOTAL tb_int_snapseq errors=%0d", errors);
        $finish;
    end

    initial begin
        #400000;
        $display("FAIL_TOTAL tb_int_snapseq TIMEOUT samples=%0d", nsamples);
        $finish;
    end

endmodule
