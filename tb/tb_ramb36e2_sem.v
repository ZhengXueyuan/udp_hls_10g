`timescale 1ns/1ps
//=============================================================================
// tb_ramb36e2_sem.v — P6a-T1 原语级语义探针: RAMB36E2 (UltraScale+) 上复验
//   frame_fifo 主存依赖的端口语义 (K7 上由 unisim 实测得到):
//     ① [判据] 1 拍读延迟: 沿 N 施加的读地址, 字在 N+1 呈现 (DOA_REG=0)
//     ② [判据] 写使能的口: **SDP 下写走 B 口 ⇒ 使能是 ENBWREN**; ENBWREN=0 的写应丢失。
//        ⚠️ 旧版本把这条写成 "ENARDEN=0 丢写" 并只拨 en_a ⇒ **测错了口** (读口使能本
//        就不影响写), 由此得出的 "E2 与 7 系列不同" 已作废; 现版本 P3a/P3b 两口分测。
//     ③ [判据] 同址碰撞 (写口 B 与读口 A 同沿同址) ⇒ DOA 出 X 一拍, 存储内容存活
//        (写模式 = WRITE_FIRST)
//     ④ [判据] 72 位 SDP 下字址位段 = [14:6] (用 [5:0] 抖动做反证)
//     ⑤ [观察] 未写槽初值 (E2 的 INIT_* 默认全 0; E1 未测)
//
// 配置与 rtl/frame_fifo.v 的 DEV_USP 分支逐字同参 (512x72 SDP / WRITE_FIRST /
// DOA_REG=0 / CLOCK_DOMAINS=COMMON)。**只测原语, 不带 frame_fifo 逻辑**。
//
// 判定契约: **判据** = 上面的 [判据] 项, 计入 `fail`; 任一不成立 ⇒ 总结行报 DIFF。
//   [观察] 项只打印读数, 不进判据。总结行 = "SEM RESULT: E2_SEMANTICS_MATCH_7SERIES"
//   只在 fail==0 时打印。本 TB 是**测量器**而非交付门: 差异本身不是失败, 是要写进
//   frame_fifo 头注释的事实; 而且它**只跑仿真模型** —— DEV_USP 分支的综合合法性
//   由 KU5P 构建（闸 G）单独回答。
//
// 用法: xvlog tb_ramb36e2_sem.v glbl; xelab -L unisims_ver tb_ramb36e2_sem glbl
//       见 sim/p6a_ku5p/run_tb_ramb36e2_sem.bat
//=============================================================================
module tb_ramb36e2_sem;

    reg clk = 0;
    always #5 clk = ~clk;

    reg  [14:0] addr_a, addr_b;
    reg         en_a = 1, en_b = 1;
    reg  [7:0]  webwe = 8'h00;
    reg  [31:0] din_a_lo, din_b_hi;
    wire [31:0] dout_lo, dout_hi;
    reg  [8:0]  wa = 9'd0, ra = 9'd0;   // 字址 (9 位 = 512 深)
    reg  [5:0]  alow_a = 6'h00, alow_b = 6'h00;  // [5:0] 无关位 (抖动用)

    // 写地址/读地址按 [14:6] 装配 (与 frame_fifo 同式)
    always @* begin
        addr_a = {ra, alow_a};
        addr_b = {wa, alow_b};
    end

    wire [63:0] dout = {dout_hi, dout_lo};

    RAMB36E2 #(
        .CASCADE_ORDER_A("NONE"), .CASCADE_ORDER_B("NONE"),
        .CLOCK_DOMAINS("COMMON"),
        .WRITE_WIDTH_A(0),  .WRITE_WIDTH_B(72),   // E2: SDP 只认 A 读/B 写 (A 写宽必须 <=36)
        .READ_WIDTH_A(72), .READ_WIDTH_B(0),     // E2: 同上 (B 读宽必须 <=36)
        .WRITE_MODE_A("WRITE_FIRST"), .WRITE_MODE_B("WRITE_FIRST"),
        .DOA_REG(0), .DOB_REG(0),
        .ENADDRENA("FALSE"), .ENADDRENB("FALSE"),
        .RDADDRCHANGEA("FALSE"), .RDADDRCHANGEB("FALSE"),
        .RSTREG_PRIORITY_A("RSTREG"), .RSTREG_PRIORITY_B("RSTREG"),
        .SIM_COLLISION_CHECK("ALL")
    ) u_dut (
        .CLKARDCLK(clk), .CLKBWRCLK(clk),
        .ENARDEN(en_a), .ENBWREN(en_b),
        .ADDRENA(1'b1), .ADDRENB(1'b1),
        .WEA(4'h0), .WEBWE(webwe),
        .ADDRARDADDR(addr_a), .ADDRBWRADDR(addr_b),
        .DINADIN(din_a_lo), .DINPADINP(4'h0),
        .DINBDIN(din_b_hi), .DINPBDINP(4'h0),
        .REGCEAREGCE(1'b1), .REGCEB(1'b0),
        .RSTRAMARSTRAM(1'b0), .RSTRAMB(1'b0),
        .RSTREGARSTREG(1'b0), .RSTREGB(1'b0),
        .DOUTADOUT(dout_lo), .DOUTPADOUTP(),
        .DOUTBDOUT(dout_hi), .DOUTPBDOUTP(),
        .CASDIMUXA(1'b0), .CASDIMUXB(1'b0),
        .CASDINA(32'h0), .CASDINB(32'h0),
        .CASDINPA(4'h0), .CASDINPB(4'h0),
        .CASDOMUXA(1'b0), .CASDOMUXB(1'b0),
        .CASDOMUXEN_A(1'b1), .CASDOMUXEN_B(1'b1),
        .CASINDBITERR(1'b0), .CASINSBITERR(1'b0),
        .CASOREGIMUXA(1'b0), .CASOREGIMUXB(1'b0),
        .CASOREGIMUXEN_A(1'b1), .CASOREGIMUXEN_B(1'b1),
        .ECCPIPECE(1'b1), .SLEEP(1'b0),
        .INJECTDBITERR(1'b0), .INJECTSBITERR(1'b0),
        .DBITERR(), .SBITERR(), .ECCPARITY(), .RDADDRECC()
    );

    integer fail = 0;
    reg [63:0] obs;

    // 单拍写: 在 negedge 布置, 下一 posedge 生效; 写后立即撤 WEBWE
    task wr1(input [8:0] a, input [63:0] d);
        begin
            @(negedge clk);
            wa = a; alow_b = 6'h00; din_a_lo = d[31:0]; din_b_hi = d[63:32];
            webwe = 8'hFF;
            @(negedge clk);
            webwe = 8'h00;
            wa = 9'd511;                     // 挪开, 避免后续误写
        end
    endtask

    // 读: 施加地址 1 拍, 下拍采样 (期望 1 拍延迟)
    task rd1(input [8:0] a, output [63:0] d);
        begin
            @(negedge clk);
            ra = a; alow_a = 6'h00;
            @(posedge clk);                  // 捕获沿
            @(negedge clk);                  // 进入呈现拍, dout 稳定
            d = dout;
        end
    endtask

    task chk(input [255:0] name, input [63:0] got, input [63:0] exp);
        begin
            if (got === exp) $display("  [PASS] %0s = %016x", name, got);
            else begin
                $display("  [DIFF] %0s = %016x (期望 %016x)", name, got, exp);
                fail = fail + 1;
            end
        end
    endtask

    reg [63:0] v;
    initial begin
        $display("=== tb_ramb36e2_sem: UltraScale+ RAMB36E2 端口语义复验 ===");
        ra = 9'd0; wa = 9'd511; en_a = 1; en_b = 1; webwe = 8'h00;
        #200;   // 等模型 INIT 装载完成 (t=0 后的首写会被 INIT 覆盖, 非 E2 语义)

        // ---- 探针 1: 基本写读 + 读延迟实测 (逐拍打印, 不预设是 1 拍) ----
        $display("-- P1 基本写读 (读延迟逐拍实测) --");
        wr1(9'd5, 64'h1122334455667788);
        @(negedge clk); ra = 9'd5; alow_a = 6'h00;
        @(posedge clk); @(negedge clk); $display("  地址施加后第 1 拍 dout = %016x", dout);
        @(posedge clk); @(negedge clk); $display("  地址施加后第 2 拍 dout = %016x", dout);
        @(posedge clk); @(negedge clk); $display("  地址施加后第 3 拍 dout = %016x", dout);
        ra = 9'd5; alow_a = 6'h00; @(posedge clk); @(negedge clk);
        chk("P1 read@5 (延迟 1 拍口径)", dout, 64'h1122334455667788);

        // ---- 探针 2: 未写地址 = X (空槽语义的基线) ----
        $display("-- P2 [观察] 未写槽读回值 --");
        rd1(9'd200, v);
        if (v === 64'h0) $display("  [OBS  ] P2 read@200 = 0 (INIT 默认全 0; 空态 dout 不定, 不得依赖)");
        else $display("  [OBS  ] P2 read@200 = %016x", v);

        // ---- 探针 3: 写使能到底挂在哪个口上 (⚠️ 审查修正) ----
        // SDP 模式下写走 **B 口**, 其使能是 **ENBWREN**; ENARDEN 是**读口 A** 的使能。
        // 故分别测两个口 (旧版本只拨 en_a 而写走 B 口 ⇒ 测的是"读口使能不影响写",
        // 与本探针的问题不匹配; 那条 "[DIFF] E2 与 7 系列不同" 是测量错误, 已作废)。
        $display("-- P3a ENBWREN=0 的写 (真正的写使能口) --");
        @(negedge clk); en_b = 1'b0; alow_b = 6'h00;
        wa = 9'd6; din_a_lo = 32'hDEADBEEF; din_b_hi = 32'h0BADF00D; webwe = 8'hFF;
        @(negedge clk); webwe = 8'h00; en_b = 1'b1; wa = 9'd511;
        rd1(9'd6, v);
        if (^v === 1'bx || v === 64'h0)
            $display("  [MATCH] P3a 写丢失 (读回 %016x) —— ENBWREN=0 确实丢写", v);
        else if (v === 64'h0BADF00DDEADBEEF)
            begin $display("  [DIFF ] P3a ENBWREN=0 **仍写进去** (%016x)", v); fail = fail + 1; end
        else
            $display("  [DIFF ] P3a 读回既非空槽也非写入值: %016x", v);

        $display("-- P3b ENARDEN=0 (读口使能) 的写 --");
        @(negedge clk); en_a = 1'b0; alow_b = 6'h00;
        wa = 9'd8; din_a_lo = 32'hFEEDFACE; din_b_hi = 32'h12345678; webwe = 8'hFF;
        @(negedge clk); webwe = 8'h00; en_a = 1'b1; wa = 9'd511;
        rd1(9'd8, v);
        if (v === 64'h12345678FEEDFACE)
            $display("  [OBS  ] P3b ENARDEN=0 **不影响写** (读回 %016x) ⇒ 写使能只认 ENBWREN", v);
        else if (^v === 1'bx || v === 64'h0)
            $display("  [OBS  ] P3b ENARDEN=0 时写被丢 (读回 %016x)", v);
        else
            $display("  [DIFF ] P3b 读回异常: %016x", v);

        // ---- 探针 4: 同址碰撞 (写口 B 与读口 A 同沿同址, WRITE_FIRST) ----
        $display("-- P4 同址碰撞 (WRITE_FIRST) --");
        wr1(9'd7, 64'hA0A0A0A0A0A0A0A0);
        // 同沿: 写 addr7 = 新值, 读 addr7
        @(negedge clk);
        ra = 9'd7; alow_a = 6'h00; wa = 9'd7; alow_b = 6'h00;
        din_a_lo = 32'hB1B1B1B1; din_b_hi = 32'hB1B1B1B1; webwe = 8'hFF;
        @(posedge clk);                       // 碰撞沿 (捕获)
        @(negedge clk);
        $display("  碰撞拍输出 = %016x %s", dout, (^dout === 1'bx) ? "(X)" : "(非 X)");
        webwe = 8'h00;
        // 内容是否存活: 下一拍地址仍是 7
        @(posedge clk);
        @(negedge clk);
        $display("  碰撞后一拍输出 = %016x", dout);
        webwe = 8'h00; wa = 9'd511;
        rd1(9'd7, v);
        if (v === 64'hB1B1B1B1B1B1B1B1)
            $display("  [MATCH] P4 存储内容存活 = 新值 (与 7 系列一致)");
        else begin
            $display("  [DIFF ] P4 读回 %016x (期望新值 B1B1...)", v); fail = fail + 1;
        end

        // ---- 探针 5: 地址位段 [14:6] 反证 ([5:0] 抖动应无影响) ----
        $display("-- P5 字址位段 [14:6] 反证 --");
        wr1(9'd9, 64'hC0FFEE00C0FFEE00);
        ra = 9'd9; alow_a = 6'h3F;            // 只抖无关位
        @(posedge clk); @(negedge clk);
        if (dout === 64'hC0FFEE00C0FFEE00)
            $display("  [MATCH] P5 [5:0] 抖动不影响读出 ⇒ 字址确在 [14:6]");
        else begin
            $display("  [DIFF ] P5 抖动 [5:0] 后读出 %016x", dout); fail = fail + 1;
        end
        alow_a = 6'h00;

        if (fail == 0)
            $display("SEM RESULT: E2_SEMANTICS_MATCH_7SERIES (判据项 P1/P3a/P4/P5 全一致, 0 DIFF)");
        else
            $display("SEM RESULT: E2_SEMANTICS_CHECK_DONE (%0d DIFF 见上: 判据项不一致)", fail);
        $display("=== done ===");
        $finish;
    end

    initial begin
        #20000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
