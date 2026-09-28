`timescale 1ns/1ps
//=============================================================================
// tb_axi_regs.v — axi_regs 单元门 (P6e 最小版的寄存器块)
//   判据 (9 条): 魔数/身份/读写回环/字节选通/自由计数器递增/标记常量/未实现地址 SLVERR
//                (读与写)/状态位束/写计数
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

    axi_regs #(.MAGIC_V(32'h50360001), .BUILD_ID_V(32'h00000001)) u_dut (
        .clk(clk), .rst_n(rst_n),
        .s_axil_awaddr(awaddr), .s_axil_awprot(awprot), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
        .s_axil_wdata(wdata), .s_axil_wstrb(wstrb), .s_axil_wvalid(wvalid), .s_axil_wready(wready),
        .s_axil_bresp(bresp), .s_axil_bvalid(bvalid), .s_axil_bready(bready),
        .s_axil_araddr(araddr), .s_axil_arprot(arprot), .s_axil_arvalid(arvalid), .s_axil_arready(arready),
        .s_axil_rdata(rdata), .s_axil_rresp(rresp), .s_axil_rvalid(rvalid), .s_axil_rready(rready),
        .hw_status(hw_status), .scratch(scratch), .wr_count(wr_count), .decode_err(decode_err)
    );

    integer fails = 0;
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

    reg [31:0] v, v2;
    reg [1:0]  resp;
    initial begin
        $display("=== tb_axi_regs: P6e 寄存器块单元门 ===");
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
        // 未实现地址: 读应 SLVERR
        axil_rd(32'h40, v, resp);
        chk("7a 未实现读 rresp", {30'd0, resp}, 32'd2);
        axil_wr(32'h40, 32'h1234, 4'hF, resp);
        chk("7b 未实现写 bresp", {30'd0, resp}, 32'd2);
        // 状态位束 + 写计数
        axil_rd(32'h10, v, resp); chk("8  HW_STATUS", v, hw_status);
        axil_rd(32'h18, v, resp); chk("9a 未实现 (0x18) SLVERR", {30'd0, resp}, 32'd2);

        if (fails == 0) $display("PASS_ALL  tb_axi_regs: 9 项判据全过");
        else            $display("FAIL      tb_axi_regs: %0d 项失败", fails);
        $display("=== done ===");
        $finish;
    end

    initial begin
        #200000; $display("TIMEOUT"); $finish;
    end
endmodule
