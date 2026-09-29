//======================================================================
// tb_clk_gen_p6b.v -- P6b 时钟发生器门 (clk_gen_p6b)
//======================================================================
// 判据 (gate) 一览 —— 每条都有正例 + 判别力说明:
//
//  G1 ratio_byp    : 行为级路径, 1600 个参考钟周期内 clk_dp 上升沿 **恰好 2500**
//                    (= 比值 25/16, 误差 0)。整数计数, 不用实数除法。
//  G2 ratio_mmcm   : 同上, 但走真 MMCME4_BASE UNISIM (锁后窗口)。
//  G3 lock_order_a : 行为级: locked 拉高**之前** rst_dp 必须一直是 1;
//                    释放必须滞后 locked >= 3 个 clk_dp 沿 (同步释放), 且 <= 5 个。
//  G4 lock_order_b : 同上, UNISIM 路径 (窗口放宽到 <= 8 个 clk_dp 沿)。
//  G5 ext_rst      : rst_ext 置起 -> rst_dp 在 1 个 clk_dp 周期内置起 (异步置位);
//                    释放滞后 >= 3 个 clk_dp 沿 (同步释放)。
//  G6 loss_of_lock : 参考钟停 -> (行为级模型报失锁) rst_dp 必须重新置起。
//  G7 neg_mult     : **负对照** 把 CLKFBOUT_MULT_F 改成 12.000 ⇒ G1 的
//                    "== 2500" 判据必须**不成立** (实测 2400) —— 证明判据有区分力。
//  G8 neg_outdiv   : **负对照** 把 CLKOUT0_DIVIDE_F 改成 6.000 ⇒ 同上 (实测 3333)。
//
// 测量法 (为什么误差能是 0 而不是 ±1):
//   ratio_meter 在参考钟第 K1 与第 K2=K1+1600 个上升沿各抓一次 clk_dp 计数,
//   两次抓取都读**沿前值** (所有计数更新都是非阻塞赋值 ⇒ 与"是否恰有 clk_dp 沿
//   落在同一时刻"无关)。窗口长度 = 1600*T_in = 2500*T_dp **精确**,
//   而长度为 2500 个输出周期的半开区间内**恒有** 2500 个上升沿 (与相位无关)
//   ⇒ 正确配置下 dndp 必须**恰好** 2500。
//======================================================================

`timescale 1ns / 1ps

//----------------------------------------------------------------------
// 无竞争周期比测量器
//   arm 之后第 1 个 clk_ref 上升沿 = K1, 第 (K1+N_IN) 个 = K2
//   done=1 时 dnin = N_IN, dndp = clk_dut 上升沿数 in [t_K1, t_K2)
//----------------------------------------------------------------------
module ratio_meter #(
    parameter integer N_IN = 1600
)(
    input  wire        clk_ref,
    input  wire        clk_dut,
    input  wire        arm,
    output reg         done,
    output reg [31:0]  dnin,
    output reg [31:0]  dndp
);
    reg [31:0] nin, ndp;
    reg [31:0] nin_k1, ndp_k1;
    reg [1:0]  st;

    initial begin
        nin = 32'd0; ndp = 32'd0; st = 2'd0;
        done = 1'b0; dnin = 32'd0; dndp = 32'd0;
        nin_k1 = 32'd0; ndp_k1 = 32'd0;
    end

    always @(posedge clk_dut) ndp <= ndp + 32'd1;

    always @(posedge clk_ref) begin
        nin <= nin + 32'd1;                       // 非阻塞 ⇒ 下面的读取拿到"沿前值"
        case (st)
            2'd0: if (arm) begin
                      nin_k1 <= nin + 32'd1;      // K1 的序号
                      ndp_k1 <= ndp;              // K1 之前 (不含) 的 clk_dut 沿数
                      st     <= 2'd1;
                  end
            2'd1: if (((nin + 32'd1) - nin_k1) >= N_IN) begin
                      dnin <= (nin + 32'd1) - nin_k1;
                      dndp <= ndp - ndp_k1;       // [t_K1, t_K2) 内的 clk_dut 沿数
                      done <= 1'b1;
                      st   <= 2'd2;
                  end
            default: ;
        endcase
    end
endmodule


module tb_clk_gen_p6b;

    //------------------------------------------------------------------
    // 参考钟 (100 MHz 差分), ref_en=0 时停摆
    //------------------------------------------------------------------
    reg clk_p = 1'b0;
    reg clk_n = 1'b1;
    reg ref_en = 1'b1;

    always begin
        if (ref_en) begin
            #5 clk_p = 1'b1; clk_n = 1'b0;
            #5 clk_p = 1'b0; clk_n = 1'b1;
        end else begin
            #5 ;                    // 停摆: 保持电平
        end
    end

    //------------------------------------------------------------------
    // DUT 阵列
    //   A = 行为级, 正确参数        (G1/G3/G5/G6)
    //   B = UNISIM MMCM, 正确参数   (G2/G4)
    //   C = 行为级, MULT_F 错       (G7 负对照)
    //   D = 行为级, CLKOUT0 分频错  (G8 负对照)
    //------------------------------------------------------------------
    reg rst_ext_a = 1'b0;
    reg rst_ext_b = 1'b0;

    wire dp_a, ref_a, lock_a, rst_a;
    wire dp_b, ref_b, lock_b, rst_b;
    wire dp_c, ref_c, lock_c, rst_c;
    wire dp_d, ref_d, lock_d, rst_d_d;

    clk_gen_p6b #(
        .SIM_BYPASS       (1),
        .CLKIN1_PERIOD_NS (10.000),
        .CLKFBOUT_MULT_F  (12.500),
        .DIVCLK_DIVIDE    (1),
        .CLKOUT0_DIVIDE_F (8.000)
    ) dut_a (
        .clk_p (clk_p), .clk_n (clk_n), .rst_ext (rst_ext_a),
        .clk_dp (dp_a), .clk_in_100 (ref_a), .locked (lock_a), .rst_dp (rst_a)
    );

    clk_gen_p6b #(
        .SIM_BYPASS       (0),
        .CLKIN1_PERIOD_NS (10.000),
        .CLKFBOUT_MULT_F  (12.500),
        .DIVCLK_DIVIDE    (1),
        .CLKOUT0_DIVIDE_F (8.000)
    ) dut_b (
        .clk_p (clk_p), .clk_n (clk_n), .rst_ext (rst_ext_b),
        .clk_dp (dp_b), .clk_in_100 (ref_b), .locked (lock_b), .rst_dp (rst_b)
    );

    // 负对照 1: 倍频写错 (12.000 而不是 12.500) => 输出 150 MHz
    clk_gen_p6b #(
        .SIM_BYPASS       (1),
        .CLKIN1_PERIOD_NS (10.000),
        .CLKFBOUT_MULT_F  (12.000),
        .DIVCLK_DIVIDE    (1),
        .CLKOUT0_DIVIDE_F (8.000)
    ) dut_c (
        .clk_p (clk_p), .clk_n (clk_n), .rst_ext (1'b0),
        .clk_dp (dp_c), .clk_in_100 (ref_c), .locked (lock_c), .rst_dp (rst_c)
    );

    // 负对照 2: 输出分频写错 (6.000 而不是 8.000) => 输出 208.33 MHz
    clk_gen_p6b #(
        .SIM_BYPASS       (1),
        .CLKIN1_PERIOD_NS (10.000),
        .CLKFBOUT_MULT_F  (12.500),
        .DIVCLK_DIVIDE    (1),
        .CLKOUT0_DIVIDE_F (6.000)
    ) dut_d (
        .clk_p (clk_p), .clk_n (clk_n), .rst_ext (1'b0),
        .clk_dp (dp_d), .clk_in_100 (ref_d), .locked (lock_d), .rst_dp (rst_d_d)
    );

    //------------------------------------------------------------------
    // 测量器
    //------------------------------------------------------------------
    reg arm_a = 1'b0, arm_b = 1'b0, arm_c = 1'b0, arm_d = 1'b0;
    wire done_a, done_b, done_c, done_d;
    wire [31:0] dnin_a, dndp_a, dnin_b, dndp_b, dnin_c, dndp_c, dnin_d, dndp_d;

    ratio_meter #(.N_IN(1600)) m_a (.clk_ref(clk_p), .clk_dut(dp_a), .arm(arm_a),
                                     .done(done_a), .dnin(dnin_a), .dndp(dndp_a));
    ratio_meter #(.N_IN(1600)) m_b (.clk_ref(clk_p), .clk_dut(dp_b), .arm(arm_b),
                                     .done(done_b), .dnin(dnin_b), .dndp(dndp_b));
    ratio_meter #(.N_IN(1600)) m_c (.clk_ref(clk_p), .clk_dut(dp_c), .arm(arm_c),
                                     .done(done_c), .dnin(dnin_c), .dndp(dndp_c));
    ratio_meter #(.N_IN(1600)) m_d (.clk_ref(clk_p), .clk_dut(dp_d), .arm(arm_d),
                                     .done(done_d), .dnin(dnin_d), .dndp(dndp_d));

    //------------------------------------------------------------------
    // 判据记账
    //------------------------------------------------------------------
    integer n_chk = 0;
    integer n_fail = 0;

    task chk;
        input        ok;
        input [8*64-1:0] nm;
        begin
            n_chk = n_chk + 1;
            if (ok) begin
                $display("CLKGEN CHECK %0s : PASS", nm);
            end else begin
                n_fail = n_fail + 1;
                $display("CLKGEN CHECK %0s : FAIL", nm);
            end
        end
    endtask

    //------------------------------------------------------------------
    // 沿序观测: locked 上升之后数 clk_dp 沿, 看 rst_dp 何时释放
    //------------------------------------------------------------------
    integer t_lock_a, t_rel_a, t_lock_b, t_rel_b;
    integer dp_edges_since_lock_a, dp_edges_since_lock_b;
    reg     saw_lock_a, saw_lock_b;
    reg     rel_early_a, rel_early_b;      // rst_dp 在 locked 之前就为 0 => 违规
    // 失锁: locked 掉沿 / rst_dp 重新置起沿 (验"异步置位"是否立即生效)
    integer t_lof_a, t_lof_b, t_rst_as_a, t_rst_as_b;

    initial begin
        t_lock_a = -1; t_rel_a = -1; saw_lock_a = 1'b0; rel_early_a = 1'b0;
        t_lock_b = -1; t_rel_b = -1; saw_lock_b = 1'b0; rel_early_b = 1'b0;
        dp_edges_since_lock_a = 0; dp_edges_since_lock_b = 0;
        t_lof_a = -1; t_lof_b = -1; t_rst_as_a = -1; t_rst_as_b = -1;
    end

    always @(posedge lock_a) begin
        saw_lock_a <= 1'b1;
        t_lock_a   <= $time;
    end
    always @(posedge dp_a) begin
        if (saw_lock_a && rst_a === 1'b1) dp_edges_since_lock_a <= dp_edges_since_lock_a + 1;
    end
    always @(negedge rst_a) begin
        if (!saw_lock_a) rel_early_a <= 1'b1;
        if (t_rel_a < 0) t_rel_a <= $time;
    end
    // 失锁沿: 只在"锁已建立之后"才有意义; 记录 locked 掉 + rst_dp 重新置起的时间
    always @(negedge lock_a) if (saw_lock_a && (t_lof_a < 0)) t_lof_a <= $time;
    always @(posedge rst_a)  if ((t_lof_a >= 0) && (t_rst_as_a < 0)) t_rst_as_a <= $time;

    always @(posedge lock_b) begin
        saw_lock_b <= 1'b1;
        t_lock_b   <= $time;
    end
    always @(posedge dp_b) begin
        if (saw_lock_b && rst_b === 1'b1) dp_edges_since_lock_b <= dp_edges_since_lock_b + 1;
    end
    always @(negedge rst_b) begin
        if (!saw_lock_b) rel_early_b <= 1'b1;
        if (t_rel_b < 0) t_rel_b <= $time;
    end
    always @(negedge lock_b) if (saw_lock_b && (t_lof_b < 0)) t_lof_b <= $time;
    always @(posedge rst_b)  if ((t_lof_b >= 0) && (t_rst_as_b < 0)) t_rst_as_b <= $time;

    //------------------------------------------------------------------
    // 主激励
    //------------------------------------------------------------------
    integer t0;
    integer dp_edges_hold_a;   // locked 之前 rst_dp 是否一直为 1

    initial begin
        $display("=== tb_clk_gen_p6b start ===");

        //--- 等所有 DUT 锁定 (看门狗 300 us) ---
        t0 = $time;
        while (((lock_a !== 1'b1) || (lock_b !== 1'b1)) && (($time - t0) < 300000)) #10;

        chk(lock_a === 1'b1, "lock_a_asserts");
        chk(lock_b === 1'b1, "lock_b_asserts_mmcm");

        //--- G3/G4: locked 之前 rst_dp 必须一直为 1 ---
        // (locked 已经拉高, 靠 rel_early_* 记录"过早释放")
        repeat (20) @(posedge clk_p);
        chk(rel_early_a === 1'b0, "G3a_rst_dp_held_until_locked");
        chk(rel_early_b === 1'b0, "G4a_rst_dp_held_until_locked_mmcm");

        //--- G3/G4: 释放滞后 >= 3 个 clk_dp 沿 (同步释放), 且有上界 ---
        $display("INFO lock_order_a: lock@%0t rel@%0t edges_while_reset=%0d",
                 t_lock_a, t_rel_a, dp_edges_since_lock_a);
        $display("INFO lock_order_b: lock@%0t rel@%0t edges_while_reset=%0d",
                 t_lock_b, t_rel_b, dp_edges_since_lock_b);
        chk((t_rel_a > t_lock_a) && (dp_edges_since_lock_a >= 3) && (dp_edges_since_lock_a <= 5),
            "G3b_rst_dp_sync_release_3to5_dp_edges");
        chk((t_rel_b > t_lock_b) && (dp_edges_since_lock_b >= 3) && (dp_edges_since_lock_b <= 8),
            "G4b_rst_dp_sync_release_3to8_dp_edges");

        //--- rst_dp 最终必须已释放 ---
        chk(rst_a === 1'b0, "rst_a_released");
        chk(rst_b === 1'b0, "rst_b_released");

        //--- G1/G2 + G7/G8: 周期比测量 (参考钟负沿置 arm, 避开采样竞争) ---
        @(negedge clk_p); arm_a = 1'b1; arm_b = 1'b1; arm_c = 1'b1; arm_d = 1'b1;

        t0 = $time;
        while ((!done_a || !done_b || !done_c || !done_d) && (($time - t0) < 500000))
            repeat (100) @(posedge clk_p);

        chk(done_a === 1'b1, "meter_a_done");
        chk(done_b === 1'b1, "meter_b_done");
        chk(done_c === 1'b1, "meter_c_done");
        chk(done_d === 1'b1, "meter_d_done");

        $display("INFO ratio_byp  : dnin=%0d dndp=%0d  (expect 1600 / 2500)", dnin_a, dndp_a);
        $display("INFO ratio_mmcm : dnin=%0d dndp=%0d  (expect 1600 / 2500)", dnin_b, dndp_b);
        $display("INFO ratio_neg_mult  : dnin=%0d dndp=%0d  (expect != 2500)", dnin_c, dndp_c);
        $display("INFO ratio_neg_outdiv: dnin=%0d dndp=%0d  (expect != 2500)", dnin_d, dndp_d);

        // G1: 行为级 —— 整数判据, 误差 0
        chk((dnin_a == 32'd1600) && (dndp_a == 32'd2500), "G1_ratio_25_16_bypass_exact");
        // 等价形式: dndp*16 == dnin*25  (25/16)
        chk((dndp_a * 32'd16) == (dnin_a * 32'd25), "G1b_ratio_cross_multiply_bypass");

        // G2: UNISIM MMCM —— 同一判据
        chk((dnin_b == 32'd1600) && (dndp_b == 32'd2500), "G2_ratio_25_16_mmcm_exact");
        chk((dndp_b * 32'd16) == (dnin_b * 32'd25), "G2b_ratio_cross_multiply_mmcm");

        // G7/G8: 负对照 —— 判据必须**不成立** (若这两条 PASS, 说明 G1 的判据没有区分力)
        chk(!((dnin_c == 32'd1600) && (dndp_c == 32'd2500)), "G7_negctl_wrong_mult_must_fail_ratio");
        chk(!((dnin_d == 32'd1600) && (dndp_d == 32'd2500)), "G8_negctl_wrong_outdiv_must_fail_ratio");
        // 负对照的实际值必须落在**预期频率算出来的**区间里, 否则"失败"可能是别的原因
        //   (空读数 != 真 0: 判据失败必须能归因到我们改的那个旋钮)
        // MULT_F=12.000 => 150.0 MHz  => 1600 个输入周期 (16000ns) 内 ~2400 个沿
        //   行为级模型半周期被截断到 3333 ps (6.666ns), 相位相关 => 2400 或 2401
        chk((dndp_c >= 32'd2395) && (dndp_c <= 32'd2405), "G7b_negctl_wrong_mult_value_near_2400");
        // CLKOUT0_DIVIDE_F=6.000 => 208.33 MHz => ~3333 个沿 (半周期 2400 ps 精确)
        chk((dndp_d >= 32'd3328) && (dndp_d <= 32'd3338), "G8b_negctl_wrong_outdiv_value_near_3333");

        //--- G5: rst_ext 语义 (只测 DUT A, 行为级) ---
        @(negedge clk_p); rst_ext_a = 1'b1;
        // 异步置位: 下一个 clk_dp 沿之前就该是 1
        @(posedge clk_p);
        chk(rst_a === 1'b1, "G5a_ext_rst_asserts_fast");
        repeat (20) @(posedge clk_p);
        chk(rst_a === 1'b1, "G5b_ext_rst_holds");
        @(negedge clk_p); rst_ext_a = 1'b0;
        // 同步释放: >=3 个 clk_dp 沿之后才掉
        repeat (2) @(posedge clk_p);
        chk(rst_a === 1'b1, "G5c_ext_rst_release_is_not_immediate");
        repeat (40) @(posedge clk_p);
        chk(rst_a === 1'b0, "G5d_ext_rst_released");

        //--- G6: 失锁语义 —— 停参考钟 ---
        // 行为级 LOCKED 模型: 参考钟停 >16 个 clk_dp 周期 ⇒ 失锁 ⇒ rst_dp 重新置起
        @(negedge clk_p); ref_en = 1'b0;
        repeat (400) @(posedge dp_a);    // 400 个 clk_dp 周期 (2.56 us) —— 给 UNISIM 模型留余量
        $display("INFO loss_of_lock: locked_a=%b rst_a=%b (lof@%0t assert@%0t)",
                 lock_a, rst_a, t_lof_a, t_rst_as_a);
        $display("INFO loss_of_lock_mmcm: locked_b=%b rst_b=%b (lof@%0t assert@%0t)",
                 lock_b, rst_b, t_lof_b, t_rst_as_b);
        chk(lock_a === 1'b0, "G6a_bypass_locked_drops_when_ref_stops");
        chk(rst_a  === 1'b1, "G6b_bypass_rst_dp_reasserts_on_loss_of_lock");
        // "异步置位"必须**立即**生效: rst_dp 置起不得晚于 locked 掉沿后 1 个 clk_dp 周期
        chk((t_rst_as_a >= 0) && ((t_rst_as_a - t_lof_a) <= 7),
            "G6c_loss_of_lock_rst_dp_assert_is_immediate");
        // UNISIM 真 MMCM 路径: 同一判据 (Xilinx 模型在输入停摆时也会拉低 LOCKED)
        chk(lock_b === 1'b0, "G6d_mmcm_locked_drops_when_ref_stops");
        chk(rst_b  === 1'b1, "G6e_mmcm_rst_dp_reasserts_on_loss_of_lock");
        chk((t_rst_as_b >= 0) && ((t_rst_as_b - t_lof_b) <= 7),
            "G6f_mmcm_loss_of_lock_rst_dp_assert_is_immediate");

        //--- 汇总 ---
        $display("CLKGEN SUMMARY n_checks=%0d n_fail=%0d", n_chk, n_fail);
        if (n_fail == 0) $display("PASS_ALL");
        else             $display("FAIL");
        $display("=== tb_clk_gen_p6b end ===");
        $finish;
    end

    // 全局看门狗
    initial begin
        #2000000;
        $display("CLKGEN TIMEOUT at %0t", $time);
        $display("FAIL");
        $finish;
    end

endmodule
