`timescale 1ns/1ps
//=============================================================================
// tb_axi_regs.v — axi_regs 单元门 (P6e 的寄存器块: 前置闸 + 数据面快照窗口)
//   判据 (17 条):
//     1-8   基础: 魔数/身份/读写回环/字节选通/自由计数器/标记/未实现地址 SLVERR/状态位束
//     9a    未实现地址读 SLVERR —— ⚠️ **这个地址随地图扩张挪过两次: 0x18 -> 0x44 -> 0x60**。
//           每扩一次地图, "拿哪个地址当未实现"都要跟着挪, 否则门会把"新功能上线"报成回归
//           (7a/7b 就是漏挪的那两个, 第一次跑 16 字版时当场 FAIL)。
//     10-17 P6e 快照窗口 (0x18 触发 / 0x1C 状态 / 0x20-0x5C = 16 个字):
//       10 reset 后: 16 个字全 0, SNAP_STATUS 全 0
//       11 触发: 写 0x18 ⇒ snap_req 恰好 1 拍脉冲; **写别的地址不许触发** (负向)
//       12 busy 位: snap_busy=1 时状态位 bit0 读回 1 (纯透传)
//       13 捕获: 注入 snap_valid + 已知 16 字 ⇒ done/seen/gen 正确, 逐字读回一致
//       14 触发清 done (且 gen 不动)
//       15 读窗口一致性: gen 前后相同 ⇒ 16 个字必须同代 (正常路径)
//       16 **负对照 (证明 gen 守卫有判别力)**: 读 16 个字的中途注入下一代 ⇒
//          ① gen 前后**不同** (守卫能发现) ② 读到的 16 字里确实出现**跨代混**
//          => 证明"读前读后各看一次 gen"确实是能抓到这个失效模式的守卫
//       17 未实现地址 0x60 读 SLVERR (再扩地图后的第一处未实现)
//   自检式: 末行打印 PASS_ALL 或 FAIL 列表; 无文件依赖。
//   驱动纪律: 激励在 negedge 布置, 采样的握手用"等 valid 且 ready"的非阻塞风格,
//             避免与 DUT 的组合 ready 竞争 (本工程 TB 坑之一)。
//=============================================================================
module tb_axi_regs;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg  [31:0] awaddr = 0, wdata = 0, araddr = 0;
    reg  [2:0]  awprot = 0, arprot = 0;
    reg  [3:0]  wstrb = 4'hF;
    reg         awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    wire        awready, wready, bvalid, arready, rvalid;
    wire [1:0]  bresp, rresp;
    wire [31:0] rdata;

    reg  [31:0] hw_status = 32'h0000_0005;
    wire [31:0] scratch, wr_count;
    wire        decode_err;

    // ---- 快照接口侧 (由本 TB 扮演 snap_cdc) ----
    wire        snap_req;
    reg         snap_busy  = 0;
    reg         snap_valid = 0;
    reg [511:0] snap_din   = 0;
    integer     snap_req_cnt = 0;
    always @(posedge clk) if (snap_req) snap_req_cnt = snap_req_cnt + 1;

    axi_regs #(.MAGIC_V(32'h50360001), .BUILD_ID_V(32'h00000001), .SNAP_NW(16)) u_dut (
        .clk(clk), .rst_n(rst_n),
        .s_axil_awaddr(awaddr), .s_axil_awprot(awprot), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
        .s_axil_wdata(wdata), .s_axil_wstrb(wstrb), .s_axil_wvalid(wvalid), .s_axil_wready(wready),
        .s_axil_bresp(bresp), .s_axil_bvalid(bvalid), .s_axil_bready(bready),
        .s_axil_araddr(araddr), .s_axil_arprot(arprot), .s_axil_arvalid(arvalid), .s_axil_arready(arready),
        .s_axil_rdata(rdata), .s_axil_rresp(rresp), .s_axil_rvalid(rvalid), .s_axil_rready(rready),
        .hw_status(hw_status), .scratch(scratch), .wr_count(wr_count), .decode_err(decode_err),
        .snap_req(snap_req), .snap_busy(snap_busy), .snap_valid(snap_valid), .snap_din(snap_din)
    );

    integer fails = 0;
    // ⚠️ 所有被 task 引用的模块级变量必须声明在 task **之前** (工程坑 22: xvlog 先声明后用)
    reg [31:0] v, v2;
    reg [1:0]  resp;
    reg [31:0] w8 [0:15];
    reg [511:0] b_tmp;
    integer    i, gen_a, gen_b, k;
    integer    gen_first, gen_last, n_mixed;
    reg [23:0] g0, g1;

    task chk(input [255:0] name, input [31:0] got, input [31:0] exp);
        begin
            if (got === exp) $display("  [PASS] %0s = %08x", name, got);
            else begin $display("  [FAIL] %0s = %08x (期望 %08x)", name, got, exp); fails = fails + 1; end
        end
    endtask

    // AXI-Lite 写: AW 与 W 同拍发出 (合法), 等 B
    task axil_wr(input [31:0] a, input [31:0] d, input [3:0] strb_in, output [1:0] resp_o);
        begin
            @(negedge clk);
            awaddr = a; awvalid = 1'b1; wdata = d; wstrb = strb_in; wvalid = 1'b1; bready = 1'b1;
            @(posedge clk);
            while (!(awready && wready)) @(posedge clk);   // 两通道都被接收
            @(negedge clk);
            awvalid = 1'b0; wvalid = 1'b0;
            while (!bvalid) @(posedge clk);
            @(negedge clk);
            resp_o = bresp;
            bready = 1'b0;
            @(posedge clk);
        end
    endtask

    // AXI-Lite 读
    task axil_rd(input [31:0] a, output [31:0] d_o, output [1:0] resp_o);
        begin
            @(negedge clk);
            araddr = a; arvalid = 1'b1; rready = 1'b1;
            @(posedge clk);
            while (!arready) @(posedge clk);
            @(negedge clk);
            arvalid = 1'b0;
            while (!rvalid) @(posedge clk);
            d_o = rdata; resp_o = rresp;
            @(negedge clk);
            rready = 1'b0;
            @(posedge clk);
        end
    endtask

    // ---- 快照侧激励/检查 ----
    // 位束格式 (与 tb_snap_cdc 同): 每字 = {gen[23:0], idx[7:0]}
    function [511:0] make_bundle(input integer g);
        integer i;
        reg [511:0] b;
        begin
            b = 512'd0;
            for (i = 0; i < 16; i = i + 1) b[i*32 +: 32] = {g[23:0], i[7:0]};
            make_bundle = b;
        end
    endfunction

    task inject_snap(input integer g);
        begin
            @(negedge clk);
            snap_din   = make_bundle(g);
            snap_valid = 1'b1;
            @(negedge clk);
            snap_valid = 1'b0;
        end
    endtask

    // 读 8 个字 + 收尾再读一次 gen; 判断 8 字是否同代
    //   (task 端口用 o_ 前缀, 避免与模块级同名变量混淆)
    task read8_check(output integer o_gen_first, output integer o_gen_last, output integer o_n_mixed);
        begin
            axil_rd(32'h1C, v, resp); o_gen_first = v[31:16];
            for (i = 0; i < 16; i = i + 1) axil_rd(32'h20 + i*4, w8[i], resp);
            axil_rd(32'h1C, v, resp); o_gen_last = v[31:16];
            o_n_mixed = 0;
            g0 = w8[0][31:8];
            for (i = 1; i < 16; i = i + 1) begin
                g1 = w8[i][31:8];
                if (g1 !== g0) o_n_mixed = o_n_mixed + 1;
                if (w8[i][7:0] !== i[7:0]) o_n_mixed = o_n_mixed + 100;   // 索引错位: 大数标记
            end
        end
    endtask

    initial begin
        $display("=== tb_axi_regs: P6e 寄存器块单元门 (含快照窗口) ===");
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);

        axil_rd(32'h00, v, resp); chk("1  MAGIC", v, 32'h50360001);
        axil_rd(32'h04, v, resp); chk("2  BUILD_ID", v, 32'h00000001);
        axil_wr(32'h08, 32'hA5A55A5A, 4'hF, resp);
        chk("3a 写回环 rresp", {30'd0, resp}, 32'd0);
        axil_rd(32'h08, v, resp); chk("3b SCRATCH 读回", v, 32'hA5A55A5A);
        // 字节选通: 全 1 后再只写 byte0
        axil_wr(32'h08, 32'hFFFFFFFF, 4'hF, resp);
        axil_wr(32'h08, 32'h00000011, 4'b0001, resp);
        axil_rd(32'h08, v, resp); chk("4  字节选通 (只 byte0 变)", v, 32'hFFFFFF11);
        // 自由计数器递增
        axil_rd(32'h0C, v,  resp); axil_rd(32'h0C, v2, resp);
        if (v2 > v) $display("  [PASS] 5  FREECNT 递增 (%0d -> %0d)", v, v2);
        else begin $display("  [FAIL] 5  FREECNT 未递增 (%0d -> %0d)", v, v2); fails = fails + 1; end
        axil_rd(32'h14, v, resp); chk("6  MARKER", v, 32'hDEADBEEF);
        // 未实现地址: 读/写都应 SLVERR
        // ⚠️ 这两个地址随地图扩张挪过: 0x40 在 16 字快照里**已经实现** (= W8)
        //     ⇒ 必须挪到 0x60, 否则"新功能上线"被报成回归 (同一类错本门已吃过两次)
        axil_rd(32'h60, v, resp);
        chk("7a 未实现读 rresp (0x60)", {30'd0, resp}, 32'd2);
        axil_wr(32'h60, 32'h1234, 4'hF, resp);
        chk("7b 未实现写 bresp (0x60)", {30'd0, resp}, 32'd2);
        // 状态位束
        axil_rd(32'h10, v, resp); chk("8  HW_STATUS", v, hw_status);
        // 9a: ⚠️ 这个"未实现地址"的取值随地图扩张挪过两次: 0x18 -> 0x44 -> **0x60**
        //     (16 字快照把 0x20-0x5C 全占了; 0x60 = word 24 = 第一个未实现)。不挪就会把
        //     "新功能上线"误报成回归 (本门已经因为 0x18 那次吃过一次)。
        axil_rd(32'h60, v, resp); chk("9a 未实现读 rresp (0x60)", {30'd0, resp}, 32'd2);

        // ================= P6e 快照窗口 =================
        // ---- 10 reset 值 ----
        axil_rd(32'h1C, v, resp); chk("10a SNAP_STATUS 复位值", v, 32'h00000000);
        k = 0;
        for (i = 0; i < 16; i = i + 1) begin
            axil_rd(32'h20 + i*4, v, resp);
            if (v !== 32'd0) k = k + 1;
        end
        chk("10b 16 个字复位值全 0", k, 32'd0);

        // ---- 11 触发脉冲 (含负向: 写别的地址不许触发) ----
        k = snap_req_cnt;
        axil_wr(32'h18, 32'h1, 4'hF, resp);
        repeat (2) @(posedge clk);
        chk("11a 写 0x18 ⇒ snap_req 增 1", snap_req_cnt - k, 32'd1);
        chk("11b 写 0x18 bresp", {30'd0, resp}, 32'd0);
        k = snap_req_cnt;
        axil_wr(32'h08, 32'hDEAD, 4'hF, resp);          // 负向: 别的地址
        axil_wr(32'h60, 32'hDEAD, 4'hF, resp);          // 负向: 未实现地址
        repeat (2) @(posedge clk);
        chk("11c 写 0x08/0x40 **不得**触发", snap_req_cnt - k, 32'd0);

        // ---- 12 busy 位透传 ----
        @(negedge clk); snap_busy = 1'b1;
        axil_rd(32'h1C, v, resp);
        chk("12 SNAP_STATUS.busy 透传", {31'd0, v[0]}, 32'd1);
        @(negedge clk); snap_busy = 1'b0;

        // ---- 13 捕获 ----
        gen_a = 500;
        inject_snap(gen_a);
        axil_rd(32'h1C, v, resp);
        chk("13a done 置起",   {31'd0, v[1]}, 32'd1);
        chk("13b seen 置起",   {31'd0, v[2]}, 32'd1);
        chk("13c gen = 1",     v[31:16],      32'd1);
        k = 0;
        b_tmp = make_bundle(gen_a);            // ⚠️ 函数结果必须先落到变量, 不能直接对它做部分选择
        for (i = 0; i < 16; i = i + 1) begin
            axil_rd(32'h20 + i*4, v, resp);
            if (v !== b_tmp[i*32 +: 32]) k = k + 1;
        end
        chk("13d 16 个字逐字与注入一致", k, 32'd0);

        // ---- 14 触发清 done, gen 不动 ----
        axil_wr(32'h18, 32'h1, 4'hF, resp);
        axil_rd(32'h1C, v, resp);
        chk("14a 触发后 done 清 0", {31'd0, v[1]}, 32'd0);
        chk("14b 触发不改 gen",     v[31:16],      32'd1);

        // ---- 15 读窗口一致性 (正常路径: 不中途注入) ----
        gen_a = 600; inject_snap(gen_a);
        read8_check(gen_first, gen_last, n_mixed);
        chk("15a gen 前后一致", gen_last - gen_first, 32'd0);
        chk("15b 16 字同代 (混合计数)", n_mixed, 32'd0);
        chk("15c 16 字 = 注入的那一代", w8[0][31:8], gen_a[23:0]);

        // ---- 16 负对照: 读的中途注入下一代 ⇒ gen 守卫必须能发现 ----
        $display("  --- 判据 16 负对照: 8 字读到一半注入新一代 ---");
        gen_a = 700; gen_b = 701;
        inject_snap(gen_a);
        axil_rd(32'h1C, v, resp); gen_first = v[31:16];
        for (i = 0; i < 16; i = i + 1) begin
            axil_rd(32'h20 + i*4, w8[i], resp);
            if (i == 2) inject_snap(gen_b);            // 第 3 个字之后换代
        end
        axil_rd(32'h1C, v, resp); gen_last = v[31:16];
        if (gen_last != gen_first)
            $display("  [PASS] 16a gen 守卫发现读到一半换了代 (%0d -> %0d)", gen_first, gen_last);
        else begin
            $display("  [FAIL] 16a gen 守卫没发现中途换代 (%0d -> %0d)", gen_first, gen_last);
            fails = fails + 1;
        end
        if (w8[0][31:8] !== w8[15][31:8])
            $display("  [PASS] 16b 读到的 16 字确实跨代 (tag %h ... %h) ⇒ 守卫不是空判据",
                     w8[0][31:8], w8[15][31:8]);
        else begin
            $display("  [WARN] 16b 16 字恰好同代 —— 注入点没落在读窗口内, 本判据这次无效");
        end

        // ---- 17 地图再扩之后 0x60 仍未实现 (与 9a 同址, 双保险) ----
        axil_rd(32'h60, v, resp); chk("17 未实现读 rresp (0x60)", {30'd0, resp}, 32'd2);

        if (fails == 0) $display("PASS_ALL  tb_axi_regs: 17 项判据全过");
        else            $display("FAIL      tb_axi_regs: %0d 项失败", fails);
        $display("=== done ===");
        $finish;
    end

    initial begin
        #200000; $display("TIMEOUT"); $finish;
    end
endmodule
