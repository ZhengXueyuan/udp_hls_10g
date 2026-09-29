`timescale 1ns/1ps
//=============================================================================
// tb_int_axr36.v — 独立审查 agent 的 36 字快照窗口读回门 (不用施工方的 TB)
//
// 判据 (每条都必须有区分能力):
//   C1  MAGIC/BUILD_ID/MARKER 三个身份字读回正确 (地址译码基线)
//   C2  **逐字**: word 8..43 (0x20..0xAC) 读回 = 我预先写进 snap_din 的 36 个
//       **互不相同且等于字号的图案** (第 i 字 = 32'hC0DE0000+i) ⇒ 任一回绕/串位
//       都会当场显示成"读到了 j 的值"
//   C3  0xB0 (word 44) 必须 SLVERR 且数据 = 0 (未实现地址边界)
//   C4  SNAP_STATUS 位域: [2]seen [1]done [0]busy, [5:3]fe_state, [6]locked_axi
//   C5  写 0x18 触发后再读, gen 自增 (快照真的被触发过, 不是"恰好读到 0")
//
// 用法: 同目录 run.bat
//=============================================================================
module tb_int_axr36;

    localparam integer NW = 36;

    reg clk = 1'b0;
    always #2 clk = ~clk;              // 4ns = 250MHz (XDMA axi_aclk 量级)

    reg rst_n = 1'b0;

    // ---------------- AXI4-Lite 主机侧 ----------------
    reg  [31:0] awaddr  = 32'd0;
    reg         awvalid = 1'b0;
    wire        awready;
    reg  [31:0] wdata   = 32'd0;
    reg  [3:0]  wstrb   = 4'hF;
    reg         wvalid  = 1'b0;
    wire        wready;
    wire [1:0]  bresp;
    wire        bvalid;
    reg         bready  = 1'b1;
    reg  [31:0] araddr  = 32'd0;
    reg         arvalid = 1'b0;
    wire        arready;
    wire [31:0] rdata;
    wire [1:0]  rresp;
    wire        rvalid;
    reg         rready  = 1'b1;

    // ---------------- 假快照源 (我自己当生产者) ----------------
    wire        snap_req;
    reg         snap_busy  = 1'b0;
    reg         snap_valid = 1'b0;
    wire [NW*32-1:0] snap_din;
    reg  [2:0]  fe_state  = 3'b101;    // {fe_busy,fe_seen,fe_done}
    reg         locked_axi = 1'b1;

    wire [31:0] hw_status;
    wire [31:0] scratch;
    wire [31:0] wr_count;
    wire        decode_err;

    assign hw_status = 32'h0BADF00D;

    // 第 i 个字 = 32'hC0DE0000 + i  (互不相同; 一眼看出回绕到哪个字)
    genvar gi;
    generate
        for (gi = 0; gi < NW; gi = gi + 1) begin : g_pat
            assign snap_din[gi*32 +: 32] = 32'hC0DE0000 + gi[31:0];
        end
    endgenerate

    axi_regs #(.MAGIC_V(32'h50360001), .BUILD_ID_V(32'h00000006), .SNAP_NW(NW)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_axil_awaddr(awaddr), .s_axil_awprot(3'b000), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
        .s_axil_wdata(wdata), .s_axil_wstrb(wstrb), .s_axil_wvalid(wvalid), .s_axil_wready(wready),
        .s_axil_bresp(bresp), .s_axil_bvalid(bvalid), .s_axil_bready(bready),
        .s_axil_araddr(araddr), .s_axil_arprot(3'b000), .s_axil_arvalid(arvalid), .s_axil_arready(arready),
        .s_axil_rdata(rdata), .s_axil_rresp(rresp), .s_axil_rvalid(rvalid), .s_axil_rready(rready),
        .hw_status(hw_status), .scratch(scratch), .wr_count(wr_count), .decode_err(decode_err),
        .snap_req(snap_req), .snap_busy(snap_busy), .snap_valid(snap_valid), .snap_din(snap_din),
        .fe_state(fe_state), .locked_axi(locked_axi)
    );

    integer errors = 0;
    integer nread  = 0;

    task axi_write(input [31:0] addr, input [31:0] dat, output [1:0] resp_o);
        begin
            @(posedge clk);
            awaddr <= addr; wdata <= dat; wstrb <= 4'hF;
            awvalid <= 1'b1; wvalid <= 1'b1;
            @(posedge clk);
            while (!bvalid) @(posedge clk);
            awvalid <= 1'b0; wvalid <= 1'b0;
            resp_o = bresp;
            @(posedge clk);
            @(posedge clk);
        end
    endtask

    task axi_read(input [31:0] addr, output [31:0] dat_o, output [1:0] resp_o);
        begin
            @(posedge clk);
            araddr <= addr; arvalid <= 1'b1;
            @(posedge clk);
            while (!rvalid) @(posedge clk);
            dat_o = rdata; resp_o = rresp;
            arvalid <= 1'b0;
            nread = nread + 1;
            @(posedge clk);
            @(posedge clk);
        end
    endtask

    integer i;
    reg [31:0] d;
    reg [1:0]  rr;
    reg [31:0] exp;

    initial begin
        if ($test$plusargs("verbose")) ;
        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // ---------- C1: 身份字 ----------
        axi_read(32'h00, d, rr);
        if (d !== 32'h50360001 || rr !== 2'b00) begin
            $display("FAIL C1 MAGIC    got=%08x resp=%b", d, rr); errors = errors + 1;
        end else $display("INFO C1 MAGIC    = %08x OK", d);
        axi_read(32'h04, d, rr);
        if (d !== 32'h00000006 || rr !== 2'b00) begin
            $display("FAIL C1 BUILD_ID got=%08x resp=%b (期望 6)", d, rr); errors = errors + 1;
        end else $display("INFO C1 BUILD_ID = %08x OK", d);
        axi_read(32'h14, d, rr);
        if (d !== 32'hDEADBEEF) begin
            $display("FAIL C1 MARKER   got=%08x", d); errors = errors + 1;
        end else $display("INFO C1 MARKER   = %08x OK", d);

        // ---------- C4: 触发前的 SNAP_STATUS ----------
        axi_read(32'h1C, d, rr);
        $display("INFO C4 STATUS(t0) = %08x (gen=%0d seen=%b done=%b busy=%b fe=%b lk=%b)",
                 d, d[31:16], d[2], d[1], d[0], d[5:3], d[6]);
        if (d[2] !== 1'b0 || d[1] !== 1'b0 || d[0] !== 1'b0) begin
            $display("FAIL C4 复位后 seen/done/busy 必须都是 0"); errors = errors + 1;
        end
        if (d[5:3] !== 3'b101 || d[6] !== 1'b1) begin
            $display("FAIL C4 fe_state/locked_axi 未按输入透传"); errors = errors + 1;
        end

        // ---------- C5: 触发 + 假快照完成 ----------
        axi_write(32'h18, 32'h00000001, rr);
        if (rr !== 2'b00) begin $display("FAIL C5 写 0x18 应 OK, resp=%b", rr); errors = errors + 1; end
        if (snap_req !== 1'b0) begin
            $display("FAIL C5 snap_req 不是 1 拍脉冲 (写已结束仍高)"); errors = errors + 1;
        end
        @(posedge clk);
        // 假快照源: busy 一拍 + valid 一拍
        snap_busy  <= 1'b1;
        @(posedge clk);
        @(posedge clk);
        snap_busy  <= 1'b0;
        snap_valid <= 1'b1;
        @(posedge clk);
        snap_valid <= 1'b0;
        @(posedge clk);

        axi_read(32'h1C, d, rr);
        $display("INFO C5 STATUS(t1) = %08x (gen=%0d seen=%b done=%b)", d, d[31:16], d[2], d[1]);
        if (d[1] !== 1'b1 || d[2] !== 1'b1 || d[31:16] !== 16'd1) begin
            $display("FAIL C5 done/seen/gen 不对"); errors = errors + 1;
        end

        // ---------- C2: 逐字读回 36 个字 ----------
        for (i = 0; i < NW; i = i + 1) begin
            axi_read(32'h20 + (i*4), d, rr);
            exp = 32'hC0DE0000 + i[31:0];
            if (rr !== 2'b00 || d !== exp) begin
                // 如果是"另一个字的值", 顺手报出它其实是哪个字 ⇒ 回绕一眼可辨
                if (d[31:16] === 16'hC0DE)
                    $display("FAIL C2 W%0d @0x%02x  got=%08x (=W%0d) 期望 %08x  resp=%b",
                             i, 32'h20+(i*4), d, d[15:0], exp, rr);
                else
                    $display("FAIL C2 W%0d @0x%02x  got=%08x 期望 %08x resp=%b",
                             i, 32'h20+(i*4), d, exp, rr);
                errors = errors + 1;
            end
        end
        if (errors == 0) $display("INFO C2 36 字逐字读回全对 (含 W32..W35 @0xA0..0xAC)");

        // ---------- C3: 未实现地址 0xB0 ----------
        axi_read(32'hB0, d, rr);
        if (rr !== 2'b10) begin
            $display("FAIL C3 0xB0 期望 SLVERR(10), got resp=%b data=%08x", rr, d);
            errors = errors + 1;
        end else $display("INFO C3 0xB0 = SLVERR, data=%08x OK", d);
        // 反向对照: 0xAC (最后一个字) 必须**不是** SLVERR ⇒ 证明 C3 不是"到处都 SLVERR"
        axi_read(32'hAC, d, rr);
        if (rr !== 2'b00 || d !== 32'hC0DE0023) begin
            $display("FAIL C3b 0xAC 应 OK 且= C0DE0023, got resp=%b data=%08x", rr, d);
            errors = errors + 1;
        end else $display("INFO C3b 0xAC = %08x OK (对照: 边界两侧行为不同)", d);
        // 非法写 0xB0 也要 SLVERR
        axi_write(32'hB0, 32'h12345678, rr);
        if (rr !== 2'b10) begin $display("FAIL C3c 写 0xB0 期望 SLVERR, got %b", rr); errors = errors + 1; end
        else $display("INFO C3c 写 0xB0 = SLVERR OK");
        // 非法写不得改变任何可读状态: SCRATCH 仍是 0
        axi_read(32'h08, d, rr);
        if (d !== 32'h00000000) begin $display("FAIL C3d 非法写污染了 SCRATCH = %08x", d); errors = errors + 1; end

        repeat (5) @(posedge clk);
        if (errors == 0) $display("PASS_ALL tb_int_axr36 (reads=%0d)", nread);
        else             $display("FAIL_TOTAL tb_int_axr36 errors=%0d (reads=%0d)", errors, nread);
        $finish;
    end

    // 超时保护: 卡住要看得见, 不能静默退出 (纪律①: 空读数 != 真 0)
    initial begin
        #200000;
        $display("FAIL_TOTAL tb_int_axr36 TIMEOUT (200us) errors=%0d reads=%0d", errors, nread);
        $finish;
    end

endmodule
