`timescale 1ns/1ps
// tb_retx_ram: retx_ram 单元测试。
// 字节级参考模型 ref[conn][ring byte] 随每拍 wr_en 更新 (byte k = w_data[63-8k -: 8])。
// 读校验: r_seq 处读 8 字节 (跨字/跨 ring 末端回卷) 与 ref 全等。
// 组 A: seq 偏移 0..7 x n 1..8 (偶/奇 ring 字); B: LFSR 伪随机 2000 写后回读;
// C: ring 末端回卷; D: 双连接交错; E: 读延迟恰 1 拍 (+ 空闲保持); F: 复位后一致性。
// 任一处失配 $fatal(conn, seq, exp, got); 每组通过仅打一行 PASS。
// 驱动纪律: 全部在 @(posedge clk) 后 #1 变更输入 (阻塞赋值与 DUT 同拍竞争会丢写,
// 见 CLAUDE.md 教训 #3)。DUT 信号采样发生在 posedge, #1 保证值已稳定。
module tb_retx_ram;

    reg        clk = 0, rst_n = 0;
    reg        wr_en = 0, rd_en = 0;
    reg  [3:0] w_conn = 0, r_conn = 0;
    reg  [13:0] w_seq = 0, r_seq = 0;
    reg  [63:0] w_data = 0;
    reg  [3:0] w_n = 0;
    wire [63:0] r_data;

    retx_ram dut (
        .clk(clk), .rst_n(rst_n), .wr_en(wr_en), .w_conn(w_conn), .w_seq(w_seq),
        .w_data(w_data), .w_n(w_n), .rd_en(rd_en), .r_conn(r_conn), .r_seq(r_seq),
        .r_data(r_data)
    );

    always #5 clk = ~clk;

    // ---- 参考模型与轨迹 ----
    reg [7:0] ref [0:15][0:16383];
    integer   i;
    reg [31:0] lfsr = 32'h8F3E_9C71;         // 确定性 LFSR (无 $random)
    reg [3:0]  tc [0:4095];
    reg [13:0] ts [0:4095];
    reg [3:0]  tn [0:4095];
    integer    nt;

    function [31:0] nxt(input [31:0] s);
        nxt = {s[30:0], s[31] ^ s[21] ^ s[1] ^ s[0]};
    endfunction

    // ---- 写: 1 拍使能并更新参考模型 ----
    task t_write(input [3:0] c, input [13:0] s, input [3:0] n, input [63:0] d);
        integer k;
    begin
        @(posedge clk); #1;
        wr_en = 1; w_conn = c; w_seq = s; w_n = n; w_data = d;
        for (k = 0; k < n; k = k + 1)
            ref[c][(s + k) & 14'h3FFF] = (d >> (8 * (7 - k))) & 8'hFF;
        @(posedge clk); #1;
        wr_en = 0;
    end
    endtask

    // ---- 读: rd_en 1 拍, 在下一 posedge 后采样 r_data (延迟 1 拍) ----
    task t_read(input [3:0] c, input [13:0] s, output [63:0] v);
    begin
        @(posedge clk); #1;
        rd_en = 1; r_conn = c; r_seq = s;
        @(posedge clk); #1;
        v = r_data;
        rd_en = 0;
    end
    endtask

    // ---- 期望 8 字节 (自 r_seq 起, ring 回卷) ----
    task t_exp(input [3:0] c, input [13:0] s, output [63:0] e);
        integer k;
    begin
        e = 64'h0;
        for (k = 0; k < 8; k = k + 1) e = (e << 8) | ref[c][(s + k) & 14'h3FFF];
    end
    endtask

    // ---- 校验读 == ref, 失配即 $fatal ----
    task t_verify(input integer gid, input [3:0] c, input [13:0] s);
        reg [63:0] v, e;
    begin
        t_read(c, s, v);
        t_exp(c, s, e);
        if (v !== e)
            $fatal(1, "GRP%0d FAIL: conn=%0d seq=%0d exp=%016h got=%016h",
                   gid, c, s, e, v);
    end
    endtask

    integer o, n, wb, it, k;
    reg [63:0] dat, exp, v1;

    initial begin
        // ref 不预清零: 未写字节 = X, 与真实 reg array 初值一致 (X===X 判定相等)
        repeat (4) @(posedge clk);
        #1 rst_n = 1;
        @(posedge clk); #1;

        // ================= 组 A: 偏移 0..7 x n 1..8, 偶/奇 ring 字 =================
        for (wb = 0; wb < 2; wb = wb + 1) begin
            for (o = 0; o < 8; o = o + 1) begin
                for (n = 1; n <= 8; n = n + 1) begin
                    dat = 64'h0;
                    for (i = 0; i < n; i = i + 1)
                        dat = (dat << 8) | ((8 * (4 * wb + o) + 8 * n + i + 1) & 8'hFF);
                    t_write(0, 8 * wb + o, n, dat);
                    t_verify(0, 0, 8 * wb + o);            // 同偏移回读
                    if (o + n < 16) t_verify(0, 0, 8 * wb + o + n);  // 溢出字节采样
                end
            end
        end
        $display("GRP A (exhaustive o x n)           : PASS");

        // ================= 组 B: LFSR 随机 2000 写 + 回读 =================
        nt = 0;
        for (it = 0; it < 2000; it = it + 1) begin
            lfsr = nxt(lfsr);
            w_conn = lfsr[17:14];
            w_seq  = ((it % 40) == 0) ? (14'h3FF0 | lfsr[3:0]) : lfsr[13:0];
            w_n    = 1 + lfsr[22:20];
            lfsr = nxt(lfsr);              // 数据 = 下一状态, 与地址位解相关
            t_write(w_conn, w_seq, w_n, lfsr);
            tc[nt] = w_conn; ts[nt] = w_seq; tn[nt] = w_n;
            if (nt < 4095) nt = nt + 1;
        end
        for (i = 0; i < nt; i = i + 1)
            t_verify(1, tc[i], ts[i]);
        $display("GRP B (LFSR 2000 random write/read): PASS");

        // ================= 组 C: ring 末端回卷 =================
        dat = 64'h11_22_33_44_55_66_77_88; t_write(0, 14'h3FF8, 8, dat);   // 字 2047 整字
        dat = 64'hAA_BB_CC_DD_EE_FF_01_02; t_write(0, 14'h3FFC, 8, dat);   // 跨末端溢出
        dat = 64'h0F_1E_2D_3C_4B_5A_69_78; t_write(0, 14'h3FFF, 5, dat);   // o=7 溢到 0..3
        t_verify(2, 0, 14'h3FF8);
        t_verify(2, 0, 14'h3FFC);
        t_verify(2, 0, 14'h3FFF);
        t_verify(2, 0, 14'h3FFD);
        t_verify(2, 0, 0);               // 溢出落点 (字 0 已被 5B 写覆盖低 4 字节)
        dat = 64'hDE_AD_BE_EF_CA_FE_BA_BE; t_write(1, 14'h3FFF, 8, dat);   // 他 conn
        t_verify(2, 1, 14'h3FFF);
        $display("GRP C (ring wrap 16383)            : PASS");

        // ================= 组 D: 双连接交错 =================
        dat = 64'h01_23_45_67_89_AB_CD_EF; t_write(3, 9, 4, dat);
        dat = 64'hFE_DC_BA_98_76_54_32_10; t_write(11, 16380, 8, dat);
        t_verify(3, 3, 9);
        t_verify(3, 11, 16380);
        dat = 64'h12_34_56_78_9A_BC_DE_F0; t_write(3, 16383, 6, dat);
        dat = 64'h0F_ED_CB_A9_87_65_43_21; t_write(11, 0, 7, dat);
        t_verify(3, 11, 0);
        t_verify(3, 3, 16383);
        t_verify(3, 3, 9);               // 旧数据未受他 conn 干扰
        t_verify(3, 11, 16380);
        $display("GRP D (two-conn interleave)        : PASS");

        // ================= 组 E: 读延迟恰 1 拍 + 空闲保持 =================
        // 语义: rd_en + 稳定 r_seq 于拍内保持, 下一 posedge 后 1 拍 r_data 有效;
        // 未到该沿前不得提前出数 (非 0 延迟), 撤销 rd_en 后保持读数 (非每拍重读)。
        t_write(0, 300, 8, 64'hA0_A1_A2_A3_A4_A5_A6_A7);
        t_write(0, 400, 8, 64'hB0_B1_B2_B3_B4_B5_B6_B7);
        t_verify(4, 0, 300);                    // 预热读 A
        t_exp(0, 400, exp);                     // exp = B0..B7
        @(posedge clk); #1;
        rd_en = 1; r_conn = 0; r_seq = 400;
        #2 v1 = r_data;                         // 采样沿前: 不得已是 B (0 延迟违例)
        if (v1 === exp)
            $fatal(1, "GRP4 FAIL: latency<1 (early=%016h)", v1);
        @(posedge clk); #1;
        v1 = r_data;                            // 恰 1 拍后有效
        if (v1 !== exp)
            $fatal(1, "GRP4 FAIL: latency!=1 conn=0 seq=400 exp=%016h got=%016h", exp, v1);
        rd_en = 0; r_seq = 0;
        @(posedge clk); #1;
        v1 = r_data;                            // rd 已撤: 保持上一读数 (无重读/漂移)
        if (v1 !== exp)
            $fatal(1, "GRP4 FAIL: no-hold exp=%016h got=%016h", exp, v1);
        @(posedge clk); #1;
        v1 = r_data;                            // 再 1 拍仍保持
        if (v1 !== exp)
            $fatal(1, "GRP4 FAIL: drift exp=%016h got=%016h", exp, v1);
        $display("GRP E (latency exactly 1 cyc)      : PASS");

        // ================= 组 F: 复位后一致性 =================
        dat = 64'hC0_C1_C2_C3_C4_C5_C6_C7; t_write(7, 123, 8, dat);
        dat = 64'hD0_D1_D2_D3_D4_D5_D6_D7; t_write(7, 16380, 8, dat);
        t_verify(5, 7, 123);                    // 复位前可读
        @(posedge clk); #1;
        rd_en = 1;                              // 复位期间读口保持使能
        rst_n = 0;
        repeat (3) @(posedge clk);
        #1 rst_n = 1;
        rd_en = 0;
        @(posedge clk); #1;
        t_verify(5, 7, 123);                    // mem 不清零: 复位后仍一致
        t_verify(5, 7, 16380);
        t_verify(5, 7, 16383);
        dat = 64'hE0_E1_E2_E3_E4_E5_E6_E7; t_write(7, 124, 8, dat);   // 复位后继续写读
        t_verify(5, 7, 124);
        $display("GRP F (reset consistency)          : PASS");

        // ================= 组 G: 流式连续读 (S_RING 用法) =================
        // 写 8 个模式于 conn2 seq=8k (k=0..7), 然后连续 8 拍读 (rd_en 恒 1,
        // r_seq 每拍推进 8, 无空闲) — 正是 retx 回放 (S_RING) 的读模式:
        // S_RING 每拍发 rd_en+新地址 (预读), 同拍消费上拍地址的字。
        // r_data 延迟恰 1 拍 (q 与选择 r_sel 同拍寄存器化)。每拍两采样:
        // (a) 拍起点 (地址未动): 输出 = 上拍地址的字 — 延迟语义;
        // (b) 同拍地址已推进到下一字: 输出必须仍保持上拍地址的字 — 组合
        //     r_sel 时选择超前 q 1 拍 → 此处全错位 (组 F 前静态读测不到)。
        for (k = 0; k < 8; k = k + 1) begin
            dat = 64'h0;
            for (i = 0; i < 8; i = i + 1)
                dat = (dat << 8) | ((k * 16 + i + 1) & 8'hFF);
            t_write(2, 8 * k, 8, dat);
        end
        @(posedge clk); #1;
        rd_en = 1; r_conn = 2; r_seq = 0;   // 拍 0 保持地址 0
        for (k = 0; k < 8; k = k + 1) begin
            @(posedge clk); #1;             // 拍 k+1 起点: q 已锁存拍 k 地址 (8k)
            v1 = r_data;
            t_exp(2, 8 * k, exp);
            if (v1 !== exp)
                $fatal(1, "GRP6 FAIL: stream k=%0d addr=%0d exp=%016h got=%016h",
                       k, 8 * k, exp, v1);
            r_seq = 8 * (k + 1);            // 同拍推进: 输出必须仍为 8k 的字
            #1;
            v1 = r_data;
            if (v1 !== exp)
                $fatal(1, "GRP6 FAIL: select-race k=%0d addr=%0d exp=%016h got=%016h",
                       k, 8 * k, exp, v1);
        end
        rd_en = 0; r_seq = 0;               // 撤读: 末读数 (addr 56) 须保持
        repeat (2) begin
            @(posedge clk); #1;
            v1 = r_data;
            t_exp(2, 8 * 7, exp);
            if (v1 !== exp)
                $fatal(1, "GRP6 FAIL: post-stream hold exp=%016h got=%016h", exp, v1);
        end
        $display("GRP G (streaming back-to-back reads): PASS");

        $display("ALL 7 GROUPS PASS");
        $finish;
    end
endmodule
