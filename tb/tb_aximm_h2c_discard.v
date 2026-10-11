`timescale 1ns/1ps
//=============================================================================
// tb_aximm_h2c_discard.v — M1 期 B 单元门: `aximm_h2c_discard` (永远应答并丢弃的写从机)
//=============================================================================
// 被测合同 (逐条对应判据):
//   A 基本序 (AW → W*N → B): 每条握手都要成立; B 只在 WLAST 那拍之后出现;
//     bvalid 保持到 bready; B 被收走后两条通道**同时**重开 (one-outstanding)
//   B 到达顺序无关: W 先到 / AW 先到 都能完成 (不假设引擎发法)
//   C 同拍完成: AW 与 WLAST **同拍**握手 ⇒ 当拍就要发 B (id 用新 awid)
//   D 背靠背两笔 (两个不同 id): 第二笔在第一笔 B 被接收后立刻能开始
//   E 背压: bready 低 ⇒ bvalid 保持 1 且等; WLAST 后 wready 必须落下 (不许再吞数据)
//   F 单拍突发 (1 拍 wlast) 与长突发 (256 拍) 都完成
//   G 丢弃见证: nbeat (内部计数) == TB 发出的 W 拍总数
//   H 数据无关性: 任意 wdata/wstrb/addr 不改行为 (只抽样判"不因数据卡住")
// 激励纪律: 全部驱动在 negedge 落笔、DUT 在 posedge 采样 (工程坑 3/17) ⇒ 零竞争。
// ⛔ 所有等待都有界; 越界 ⇒ [FAIL] + dead ⇒ 主序列尽快收尾 (不许挂死 TB)。
//=============================================================================
module tb_aximm_h2c_discard;

    reg clk = 1'b0;
    always #2 clk = ~clk;                 // 250 MHz (4 ns)
    reg rst_n = 1'b0;

    reg  [3:0]   awid_r    = 4'd0;
    reg  [63:0]  awaddr_r  = 64'd0;
    reg  [7:0]   awlen_r   = 8'd0;
    reg  [2:0]   awsize_r  = 3'd4;
    reg  [1:0]   awburst_r = 2'b01;
    reg          awvalid_r = 1'b0;
    reg  [127:0] wdata_r   = 128'd0;
    reg  [15:0]  wstrb_r   = 16'hFFFF;
    reg          wlast_r   = 1'b0;
    reg          wvalid_r  = 1'b0;
    reg          bready_r  = 1'b0;

    wire         awready, wready, bvalid;
    wire [3:0]   bid;
    wire [1:0]   bresp;

    aximm_h2c_discard u_dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .awid    (awid_r),
        .awaddr  (awaddr_r),
        .awlen   (awlen_r),
        .awsize  (awsize_r),
        .awburst (awburst_r),
        .awvalid (awvalid_r),
        .awready (awready),
        .wdata   (wdata_r),
        .wstrb   (wstrb_r),
        .wlast   (wlast_r),
        .wvalid  (wvalid_r),
        .wready  (wready),
        .bid     (bid),
        .bresp   (bresp),
        .bvalid  (bvalid),
        .bready  (bready_r)
    );

    integer fails = 0, checks = 0;
    integer dead  = 0;
    task chk(input [255:0] name, input [63:0] got, input [63:0] exp);
        begin
            checks = checks + 1;
            if (got === exp) $display("  [PASS] %0s = %0d", name, got);
            else begin $display("  [FAIL] %0s = %0d (期望 %0d)", name, got, exp); fails = fails + 1; end
        end
    endtask

    task bail;
        begin
            if (dead) begin
                $display("H2C_DISC_GATE FAIL (dead: 等待越界, 提前收尾)");
                $display("=== done ===");
                $finish;
            end
        end
    endtask

    // ---- 发 AW (等握手; 越界 ⇒ dead) ----
    integer tmo;
    task aw_send(input [3:0] id, input [63:0] addr, input [7:0] len);
        begin
            @(negedge clk);
            awid_r <= id; awaddr_r <= addr; awlen_r <= len;
            awsize_r <= 3'd4; awburst_r <= 2'b01; awvalid_r <= 1'b1;
            tmo = 0;
            while (!awready && !dead) begin @(posedge clk); tmo = tmo + 1;
                if (tmo > 200) begin $display("  [FAIL] AW 等待越界 (awready 未起)"); fails = fails + 1; dead = 1; end
            end
            @(negedge clk); awvalid_r <= 1'b0;
        end
    endtask

    // ---- 发 1 拍 W ----
    task w_send(input [127:0] d, input last);
        begin
            @(negedge clk);
            wdata_r <= d; wstrb_r <= 16'hFFFF; wlast_r <= last; wvalid_r <= 1'b1;
            tmo = 0;
            while (!wready && !dead) begin @(posedge clk); tmo = tmo + 1;
                if (tmo > 200) begin $display("  [FAIL] W 等待越界 (wready 未起)"); fails = fails + 1; dead = 1; end
            end
            @(negedge clk); wvalid_r <= 1'b0; wlast_r <= 1'b0;
        end
    endtask

    // ---- 等 B (有界); 返回等待拍数 ----
    integer bwait;
    task wait_b;
        begin
            tmo = 0; bwait = 0;
            while (!bvalid && !dead) begin @(posedge clk); tmo = tmo + 1; bwait = bwait + 1;
                if (tmo > 200) begin $display("  [FAIL] B 等待越界 (bvalid 未起 = 挂死形态)"); fails = fails + 1; dead = 1; end
            end
        end
    endtask

    // ---- 收 B 并让通道重开 ----
    task b_accept;
        begin
            @(negedge clk); bready_r <= 1'b1;
            @(posedge clk);                       // B 握手在此时刻
            @(negedge clk); bready_r <= 1'b0;
        end
    endtask

    // ---- 一笔完整突发 (标准序: AW → W×N(last 在末拍) → B) ----
    //   hold_cycles: >0 ⇒ 收 B 前先让 bready=0 保持这么多拍, 并断言 bvalid 保持
    task run_burst(input [3:0] id, input integer nbeats, input integer hold_cycles,
                   input integer check_id);
        integer i;
        begin
            aw_send(id, 64'h1000_0000 + id, nbeats[7:0] - 8'd1);
            bail;
            // ⛔ 判据 (2026-10-11 补; mut_bearly 就是靠它抓的): B **只许**在 WLAST
            //    那拍握手之后出现 —— AW 收到 ≠ 可以发 B (AXI4: 写应答必须在最后一拍
            //    写数据被接收之后)。少了这条, "AW 一到就发 B" 的突变**逃过全门** (实测)。
            chk("P1 AW 后 B 仍未起 (B 只锚 WLAST, 不锚 AW)", {63'd0, bvalid}, 64'd0);
            for (i = 0; i < nbeats; i = i + 1) begin
                w_send({92'd0, id, i[31:0]}, (i == nbeats - 1));   // last 只在末拍 (128 位)
                bail;
                if (i < nbeats - 1)   // 非末拍之后: 仍不许有 B
                    chk("P2 WLAST 前 B 仍未起", {63'd0, bvalid}, 64'd0);
            end
            // WLAST 之后 (B 被收走之前) wready 必须落下 (不许再吞数据)
            @(negedge clk);
            if (nbeats > 0) chk("wready 在 WLAST 后落下 (B 前不许再吞)", wready, 0);
            wait_b;
            bail;
            if (check_id) chk("B 的 bid == 本笔 awid", {60'd0, bid}, {60'd0, id});
            chk("B 的 bresp == OKAY", {62'd0, bresp}, 64'd0);
            if (hold_cycles > 0) begin
                @(negedge clk); bready_r <= 1'b0;
                repeat (hold_cycles) @(posedge clk);
                chk("bready 低时 bvalid 保持 1", {63'd0, bvalid}, 64'd1);
            end
            b_accept;
            repeat (2) @(posedge clk);
            chk("B 收走后 awready 重开", {63'd0, awready}, 64'd1);
            chk("B 收走后 wready 重开",  {63'd0, wready},  64'd1);
        end
    endtask

    integer wb_total_sw = 0;   // TB 侧统计的发出的 W 拍数 (与 nbeat 对账)

    initial begin
        $display("=== tb_aximm_h2c_discard: always-respond discard write slave ===");
        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        // ---------- 复位态 ----------
        chk("R1 复位后 awready=1", {63'd0, awready}, 64'd1);
        chk("R2 复位后 wready=1",  {63'd0, wready},  64'd1);
        chk("R3 复位后 bvalid=0",  {63'd0, bvalid},  64'd0);

        // ---------- A: 基本序 (AW → 3 拍 W → B), 且背压保持 ----------
        $display("  --- A: 基本序 (AW -> 3 拍 W(last) -> B) + B 保持 ---");
        run_burst(4'hA, 3, 5, 1);
        bail;
        chk("A1 nbeat == 3 (丢弃见证)", {32'd0, u_dut.nbeat}, 64'd3);
        wb_total_sw = 3;

        // ---------- C: 同拍完成 (AW 与 WLAST 同拍) ----------
        $display("  --- C: AW 与 WLAST 同拍 ⇒ 当拍发 B ---");
        @(negedge clk);                            // 同时举起两条通道
        awid_r <= 4'hC; awaddr_r <= 64'h2000; awlen_r <= 8'd0;
        awsize_r <= 3'd4; awburst_r <= 2'b01; awvalid_r <= 1'b1;
        wdata_r <= 128'hDEAD_BEEF_0BAD_F00D_0BAD_F00D_1234_5678; wstrb_r <= 16'hFFFF;
        wlast_r <= 1'b1; wvalid_r <= 1'b1;
        @(posedge clk);                            // 这一拍两条握手都成立 ⇒ bvalid 下拍起
        @(negedge clk); awvalid_r <= 1'b0; wvalid_r <= 1'b0; wlast_r <= 1'b0;
        @(posedge clk);
        chk("C1 同拍完成 ⇒ bvalid 当拍即起", {63'd0, bvalid}, 64'd1);
        chk("C2 同拍完成的 bid == 新 awid", {60'd0, bid}, 64'hC);
        b_accept;
        repeat (2) @(posedge clk);
        chk("C3 nbeat == 4", {32'd0, u_dut.nbeat}, 64'd4);
        wb_total_sw = wb_total_sw + 1;

        // ---------- B: 到达顺序无关 (W 先 / AW 先) ----------
        $display("  --- B: W 先到 (wlast) 再 AW ⇒ 仍完成 ---");
        w_send(128'h1111, 1'b1);                   // W 先 (wready 本来就 1)
        bail;
        chk("B1 W 先到: bvalid 仍未起 (等 AW)", {63'd0, bvalid}, 64'd0);
        chk("B2 W 先到: wready 已落下", {63'd0, wready}, 64'd0);
        aw_send(4'hB, 64'h3000, 8'd0);
        bail;
        wait_b; bail;
        chk("B3 W 先到 ⇒ AW 到后 B 才起", {63'd0, bvalid}, 64'd1);
        chk("B4 id 回填 == B", {60'd0, bid}, 64'hB);
        b_accept;
        repeat (2) @(posedge clk);
        wb_total_sw = wb_total_sw + 1;

        // ---------- D: 背靠背两笔 (不同 id), 第二笔在 B 被收走后立刻开始 ----------
        $display("  --- D: 背靠背两笔 (id=5 后 id=6) ---");
        run_burst(4'h5, 2, 0, 1);
        bail;
        run_burst(4'h6, 1, 0, 1);
        bail;
        wb_total_sw = wb_total_sw + 2 + 1;

        // ---------- E: 长突发 256 拍 (永远应答: 不许在任何拍数上挂) ----------
        $display("  --- E: 长突发 256 拍 ---");
        run_burst(4'hE, 256, 1, 1);
        bail;
        wb_total_sw = wb_total_sw + 256;

        // ---------- G: nbeat 与 TB 统计对账 ----------
        $display("  --- G: 丢弃见证对账 (nbeat vs TB 计数) ---");
        chk("G1 nbeat == TB 发出的 W 拍总数", {32'd0, u_dut.nbeat}, {32'd0, wb_total_sw});

        // ---------- H: 通道空闲且从机无残留状态 (可以在任意时刻再来一笔) ----------
        $display("  --- H: 收尾态洁净 + 再来一笔 ---");
        chk("H1 awready=1", {63'd0, awready}, 64'd1);
        chk("H2 wready=1",  {63'd0, wready},  64'd1);
        chk("H3 bvalid=0",  {63'd0, bvalid},  64'd0);
        run_burst(4'hF, 1, 0, 1);
        bail;

        if (fails == 0) $display("H2C_DISC_GATE PASS_ALL tb_aximm_h2c_discard (checks=%0d)", checks);
        else            $display("H2C_DISC_GATE FAIL %0d 项失败 (checks=%0d)", fails, checks);
        $display("=== done ===");
        $finish;
    end

    initial begin #2000000; $display("TIMEOUT"); $finish; end

endmodule
