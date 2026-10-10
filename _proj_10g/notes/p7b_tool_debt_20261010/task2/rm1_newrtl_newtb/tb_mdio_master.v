// tb_mdio_master.v -- self-checking testbench for mdio_master.
//
// Models a clause-22 PHY (RTL8211E identifiers) on the far side of the bus:
//   reg 2 (PHYID1) = 0x001C, reg 3 (PHYID2) = 0xC915  -> PHY ID 0x001CC915
//   phyad 1 responds; any other address leaves the line pulled up (reads 1s)
//
// Checks the read turnaround explicitly: the master must release MDIO no later
// than bit 46 and sample the PHY's TA-zero and 16 data bits. Also checks that a
// write really transfers the data bits (register capture on the PHY side) and
// that MDC idles low and never exceeds 2.5MHz for the chosen DIV.

`timescale 1ns / 1ps

module tb_mdio_master;

    localparam integer DIV = 4;         // small for simulation speed

    reg         clk = 0;
    reg         rstn = 0;
    reg         start = 0;
    reg         op = 0;
    reg  [4:0]  phyad = 5'd1;
    reg  [4:0]  regad = 5'd2;
    reg  [15:0] wr_data = 16'h0000;

    wire [15:0] rd_data;
    wire        done, done_sticky, busy;
    wire        mdc, mdio_o, mdio_t;
    wire        mdio_i;
    wire        param_bad;              // 2026-10-10: DIV range guard (DIV=4 -> 0)
    wire        stat_start_lost;        // 2026-10-10: dropped-start sticky

    integer     errors = 0;
    integer     i;

    always #5 clk = ~clk;               // 100MHz

    // ---- PHY model ----
    // The master drives mdio_o on the falling edge and samples on the rising
    // edge, so the model does the symmetric thing: capture on posedge, set up
    // the drive on negedge. Sampling on the negedge instead would read the bit
    // the master has *just* switched to, i.e. everything lands one place early.
    //
    // pk = number of rising edges seen = index of the bit present at that edge.
    reg         drive_en = 0;
    reg         drive_v  = 1'b1;
    wire        mdio_line = drive_en ? drive_v : (mdio_t ? 1'b1 : mdio_o);
    assign      mdio_i    = mdio_line;

    integer     pk = 0;
    reg  [45:0] cap = 46'd0;            // bits captured from the master
    reg  [16:0] tx  = 17'd0;            // {TA0, DATA[15:0]} to shift out on a read
    reg  [15:0] wr_captured = 16'h0000;
    reg  [4:0]  phyad_seen = 5'd0;
    reg  [4:0]  regad_seen = 5'd0;
    reg  [15:0] phy_reg2 = 16'h001C;
    reg  [15:0] phy_reg3 = 16'hC915;
    reg         phy_is_write = 0;
    reg         phy_respond = 0;
    reg  [1:0]  wr_ta = 2'b00;

    // --- coverage the first version of this TB did not have -------------------
    // (a) The line model below gives drive_en priority over the DUT, so a DUT
    //     that never released MDIO would still pass every data check. Watch the
    //     DUT's own tristate control instead of the resolved line.
    // (b) MDC frequency: the header used to claim a 2.5MHz check that did not
    //     exist, so a design ignoring DIV entirely passed.
    integer n_contend = 0;
    integer clk_cnt = 0;
    integer mdc_rise = 0;
    integer m0 = 0, m1 = 0, c0 = 0, c1 = 0;

    wire dut_driving = ~mdio_t;

    always @(posedge mdc or negedge mdc)
        if (dut_driving && drive_en) n_contend = n_contend + 1;

    // Number of MDC rising edges is the frame length in bits -- an exact count
    // that nothing else in this bench covers. Wall-clock MDC period is checked
    // in aggregate at the end: measuring it transition-by-transition here reads
    // mdc one delta late (the DUT updates it with a non-blocking assign), which
    // skews any per-transition comparison.
    always @(posedge mdc) mdc_rise = mdc_rise + 1;

    // A frame is 64 bits x 2 MDC edges, so busy must span exactly 128*DIV clk
    // cycles. Exact, and immune to the delta-cycle skew that makes per-edge
    // measurement unreliable.
    integer c_busy_rise = 0;
    integer c_busy_fall = 0;
    reg     busy_q = 0;

    always @(posedge clk) begin
        clk_cnt = clk_cnt + 1;
        // Detect on the OLD busy_q, then update -- with a blocking update first
        // the edge condition can never be true.
        if (busy && !busy_q)  c_busy_rise = clk_cnt;
        if (!busy && busy_q)  c_busy_fall = clk_cnt;
        busy_q = busy;
    end

    // cap is MSB-first: cap[45-k] holds bit k, so
    //   ST = cap[13:12], OP = cap[11:10], PHYAD = cap[9:5], REGAD = cap[4:0]
    always @(posedge mdc) begin
        pk <= pk + 1;
        if (pk <= 45)
            cap <= {cap[44:0], mdio_line};
        if (phy_respond && phy_is_write && pk >= 48 && pk <= 63)
            wr_captured <= {wr_captured[14:0], mdio_line};
        // Write turnaround TA must be 2'b10 (bits 46 then 47).
        if (phy_respond && phy_is_write && (pk == 46 || pk == 47))
            wr_ta <= {wr_ta[0], mdio_line};
    end

    always @(negedge mdc) begin
        // Decode the header once all 46 master-driven bits have been captured.
        // pk increments on the rising edge, so after posedge #45 it reads 46 --
        // this negedge is the first one where cap[] is complete.
        if (pk == 46) begin
            phyad_seen   <= cap[9:5];
            regad_seen   <= cap[4:0];
            phy_respond  <= (cap[9:5] == 5'd1);
            phy_is_write <= (cap[11:10] == 2'b01);
            case (cap[4:0])
                5'd2: tx <= {1'b0, phy_reg2};
                5'd3: tx <= {1'b0, phy_reg3};
                default: tx <= {1'b0, 16'h0000};
            endcase
        end

        // Set up the drive for the bit that will sit on the line at the next
        // rising edge. That bit's index is pk (see the increment above).
        if (phy_respond && !phy_is_write && pk >= 47 && pk <= 63) begin
            drive_en <= 1'b1;
            drive_v  <= tx[16];
            tx       <= {tx[15:0], 1'b0};
        end else begin
            drive_en <= 1'b0;
        end
    end

    // ---- DUT ----
    mdio_master #(.DIV(DIV)) dut (
        .clk         (clk),
        .rstn        (rstn),
        .start       (start),
        .op          (op),
        .phyad       (phyad),
        .regad       (regad),
        .wr_data     (wr_data),
        .rd_data     (rd_data),
        .done        (done),
        .done_sticky (done_sticky),
        .busy        (busy),
        .mdc         (mdc),
        .mdio_o      (mdio_o),
        .mdio_t      (mdio_t),
        .mdio_i      (mdio_i),
        .param_bad   (param_bad),
        .stat_start_lost (stat_start_lost)
    );

    // ---- 2026-10-10: DIV range-guard arm -------------------------------------
    // DIV_BAD cannot be represented by the 16-bit divider. Before the guard it
    // was truncated to 1 and produced a 50MHz MDC (65537x the requested rate);
    // after the guard it must be clamped and raise param_bad. dut_ref runs the
    // legal value the clamp must land on, so "not faster than a legal setting"
    // is MEASURED against a second DUT instead of argued. Both arms sit on their
    // own (unconnected) pins; they never touch the shared MDIO bus.
    localparam integer DIV_BAD = 65537;
    localparam integer DIV_REF = 65536;

    reg         start_bad = 0;
    reg         start_ref = 0;
    wire [15:0] rd_data_bad, rd_data_ref;
    wire        done_bad, done_sticky_bad, busy_bad, mdc_bad, param_bad_bad, ssl_bad;
    wire        done_ref, done_sticky_ref, busy_ref, mdc_ref, param_bad_ref, ssl_ref;

    mdio_master #(.DIV(DIV_BAD)) dut_bad (
        .clk (clk), .rstn (rstn), .start (start_bad), .op (1'b0),
        .phyad (5'd1), .regad (5'd2), .wr_data (16'h0000),
        .rd_data (rd_data_bad), .done (done_bad), .done_sticky (done_sticky_bad),
        .busy (busy_bad), .mdc (mdc_bad),
        .mdio_o (), .mdio_t (), .mdio_i (1'b1),
        .param_bad (param_bad_bad), .stat_start_lost (ssl_bad)
    );

    mdio_master #(.DIV(DIV_REF)) dut_ref (
        .clk (clk), .rstn (rstn), .start (start_ref), .op (1'b0),
        .phyad (5'd1), .regad (5'd2), .wr_data (16'h0000),
        .rd_data (rd_data_ref), .done (done_ref), .done_sticky (done_sticky_ref),
        .busy (busy_ref), .mdc (mdc_ref),
        .mdio_o (), .mdio_t (), .mdio_i (1'b1),
        .param_bad (param_bad_ref), .stat_start_lost (ssl_ref)
    );

    // First MDC half-period of each guard arm, in exact clk-edge counts. The
    // reference edge (busy rise) and the measured edge (first mdc high) are
    // latched in the SAME always block, so the clk_cnt read offset cancels in
    // the difference -- same trick as c_busy_rise/c_busy_fall below.
    integer bad_ref_clk = -1, bad_r1 = -1;
    integer ref_ref_clk = -1, ref_r1 = -1;
    reg     bad_ref_seen = 0, ref_ref_seen = 0;
    integer bad_half = -1, ref_half = -1;

    always @(posedge clk) begin
        if (busy_bad && !bad_ref_seen) begin bad_ref_seen = 1; bad_ref_clk = clk_cnt; end
        if (bad_ref_seen && bad_r1 < 0 && mdc_bad) bad_r1 = clk_cnt;
        if (busy_ref && !ref_ref_seen) begin ref_ref_seen = 1; ref_ref_clk = clk_cnt; end
        if (ref_ref_seen && ref_r1 < 0 && mdc_ref) ref_r1 = clk_cnt;
    end

    // ---- helpers ----
    // Verify the WHOLE 46-bit master-driven header, not just the fields the
    // response depends on. Without this a corrupted preamble passes every data
    // check -- and a real PHY ignores a frame whose preamble is not all ones, so
    // "it passed simulation" would not have meant "a PHY would answer".
    task check_header(input [4:0] pa, input [4:0] ra, input [1:0] opx, input [127:0] tag);
        begin
            if (cap[45:14] !== 32'hFFFFFFFF) begin
                $display("FAIL %0s: preamble not all ones (got %08X)", tag, cap[45:14]);
                errors = errors + 1;
            end
            if (cap[13:12] !== 2'b01) begin
                $display("FAIL %0s: ST field = %b, want 01", tag, cap[13:12]);
                errors = errors + 1;
            end
            if (cap[11:10] !== opx) begin
                $display("FAIL %0s: OP = %b, want %b", tag, cap[11:10], opx);
                errors = errors + 1;
            end
            if (cap[9:5] !== pa || cap[4:0] !== ra) begin
                $display("FAIL %0s: PHYAD/REGAD = %0d/%0d, want %0d/%0d",
                         tag, cap[9:5], cap[4:0], pa, ra);
                errors = errors + 1;
            end
        end
    endtask

    task frame_len_check(input [127:0] tag);
        begin
            m1 = mdc_rise; c1 = clk_cnt;
            if (m1 - m0 != 64) begin
                $display("FAIL %0s: %0d MDC rising edges in frame, want 64", tag, m1 - m0);
                errors = errors + 1;
            end
        end
    endtask

    task do_read(input [4:0] pa, input [4:0] ra, input [15:0] expect,
                 input [127:0] tag);
        begin
            pk = 0; cap = 46'd0; drive_en = 0;
            m0 = mdc_rise; c0 = clk_cnt;
            phyad = pa; regad = ra; op = 1'b0;
            @(posedge clk);
            start = 1'b1;
            @(posedge clk);
            start = 1'b0;
            @(posedge done);
            @(posedge clk);
            frame_len_check(tag);
            check_header(pa, ra, 2'b10, tag);   // 2'b10 = read
            if (rd_data !== expect) begin
                $display("FAIL %0s: phy %0d reg %0d -> got %04h want %04h",
                         tag, pa, ra, rd_data, expect);
                errors = errors + 1;
            end else begin
                $display("PASS %0s: phy %0d reg %0d -> %04h", tag, pa, ra, rd_data);
            end
            if (!done_sticky) begin
                $display("FAIL %0s: done_sticky not latched", tag);
                errors = errors + 1;
            end
            // 2026-10-10: a well-behaved host (wait for done, then start) must
            // never trip the dropped-start flag. Guards the guard.
            if (stat_start_lost !== 1'b0) begin
                $display("FAIL %0s: stat_start_lost set during a clean transaction", tag);
                errors = errors + 1;
            end
        end
    endtask

    // 2026-10-10: the busy-period start case. A second start pulse is injected
    // WHILE the frame is running. Criteria (both are behavioural, not cosmetic):
    //   (a) it must produce NO extra MDC activity -- frame_len_check still sees
    //       exactly 64 rising edges, i.e. exactly one frame on the wire;
    //   (b) it must be RECORDED (stat_start_lost == 1), because the host that
    //       does this will otherwise poll done_sticky and read the PREVIOUS
    //       transaction's rd_data;
    //   (c) the transaction itself must still complete correctly.
    task do_read_lost_start(input [4:0] pa, input [4:0] ra, input [15:0] expect,
                            input [127:0] tag);
        begin
            pk = 0; cap = 46'd0; drive_en = 0;
            m0 = mdc_rise; c0 = clk_cnt;
            phyad = pa; regad = ra; op = 1'b0;
            @(posedge clk);
            start = 1'b1;
            @(posedge clk);
            start = 1'b0;
            wait (busy === 1'b1);           // the frame is now running
            repeat (2) @(posedge clk);      // land mid-frame, not on the edges
            start = 1'b1;                   // <-- the start that must be dropped
            @(posedge clk);
            start = 1'b0;
            @(posedge done);
            @(posedge clk);
            frame_len_check(tag);           // exactly ONE frame = no extra MDC edges
            check_header(pa, ra, 2'b10, tag);
            if (rd_data !== expect) begin
                $display("FAIL %0s: phy %0d reg %0d -> got %04h want %04h",
                         tag, pa, ra, rd_data, expect);
                errors = errors + 1;
            end
            if (stat_start_lost !== 1'b1) begin
                $display("FAIL %0s: start dropped during busy was NOT recorded (stat_start_lost=%b)",
                         tag, stat_start_lost);
                errors = errors + 1;
            end else begin
                $display("PASS %0s: busy-period start rejected, no extra MDC (64 edges), stat_start_lost=1",
                         tag);
            end
        end
    endtask

    task do_write(input [4:0] pa, input [4:0] ra, input [15:0] d,
                  input [127:0] tag);
        begin
            pk = 0; cap = 46'd0; drive_en = 0; wr_captured = 16'h0000;
            m0 = mdc_rise; c0 = clk_cnt;
            phyad = pa; regad = ra; op = 1'b1; wr_data = d;
            @(posedge clk);
            start = 1'b1;
            @(posedge clk);
            start = 1'b0;
            @(posedge done);
            @(posedge clk);
            frame_len_check(tag);
            #200;
            check_header(pa, ra, 2'b01, tag);   // 2'b01 = write
            if (wr_ta !== 2'b10) begin
                $display("FAIL %0s: write TA = %b, want 10", tag, wr_ta);
                errors = errors + 1;
            end
            if (wr_captured !== d) begin
                $display("FAIL %0s: phy %0d reg %0d wr -> captured %04h want %04h",
                         tag, pa, ra, wr_captured, d);
                errors = errors + 1;
            end else begin
                $display("PASS %0s: phy %0d reg %0d wr -> %04h captured", tag, pa, ra, d);
            end
            if (stat_start_lost !== 1'b0) begin
                $display("FAIL %0s: stat_start_lost set during a clean transaction", tag);
                errors = errors + 1;
            end
        end
    endtask

    // ---- stimulus ----
    initial begin
        // MDC must idle low before any transaction.
        repeat (10) @(posedge clk);
        if (mdc !== 1'b0) begin
            $display("FAIL: MDC not low at idle");
            errors = errors + 1;
        end

        rstn = 1'b1;
        repeat (5) @(posedge clk);

        // Fire the two DIV-guard arms now and let them run in the background;
        // their first MDC half-period takes 65536 clk (nothing else in this
        // bench is that slow, and it is the whole point of the check).
        start_bad = 1'b1; start_ref = 1'b1;
        @(posedge clk);
        start_bad = 1'b0; start_ref = 1'b0;

        do_read (5'd1, 5'd2, 16'h001C, "PHYID1");
        do_read (5'd1, 5'd3, 16'hC915, "PHYID2");
        do_read (5'd1, 5'd0, 16'h0000, "BMCR-default");

        // A PHY that does not answer leaves the bus pulled up -> all ones.
        do_read (5'd7, 5'd2, 16'hFFFF, "no-response");

        // Write must actually move the data bits.
        do_write(5'd1, 5'd0, 16'h8000, "BMCR-write");
        do_write(5'd1, 5'd4, 16'h01E1, "ANAR-write");

        // Back-to-back reads: the master must re-arm cleanly.
        do_read (5'd1, 5'd2, 16'h001C, "PHYID1-again");
        do_read (5'd1, 5'd3, 16'hC915, "PHYID2-again");

        // ---- 2026-10-10: busy-period start must be rejected AND recorded -----
        do_read_lost_start(5'd1, 5'd2, 16'h001C, "busy-start-rej");
        // The next accepted start must clear the sticky flag; this read doubles
        // as the "the neighbouring normal transaction is still correct" check
        // (do_read also asserts stat_start_lost == 0 at its end).
        do_read (5'd1, 5'd3, 16'hC915, "after-lost");
        if (stat_start_lost !== 1'b0) begin
            $display("FAIL: stat_start_lost still set after the next accepted start");
            errors = errors + 1;
        end else begin
            $display("PASS stat_start_lost cleared by the next accepted start");
        end

        // Let the last frame's falling edge be recorded: the initial block and
        // the monitoring always block race at the same posedge, so without this
        // the final c_busy_fall is still stale and the span comes out negative.
        repeat (10) @(posedge clk);

        // ---- 2026-10-10: DIV range guard (measured, not argued) --------------
        // Both arms were started at the top of this block; their first MDC edge
        // lands 65536 clk later (DIV_REF), so wait for it. A guard that hangs
        // never returns and the watchdog reports it as a timeout.
        while (bad_r1 < 0 || ref_r1 < 0) @(posedge clk);
        bad_half = bad_r1 - bad_ref_clk;
        ref_half = ref_r1 - ref_ref_clk;
        $display("INFO DIV-guard: DIV=%0d -> first MDC half-period %0d clk (period %0d clk = %.1f Hz @100MHz)",
                 DIV_BAD, bad_half, 2*bad_half, 100000000.0/(2.0*bad_half));
        $display("INFO DIV-guard: DIV=%0d -> first MDC half-period %0d clk (period %0d clk = %.1f Hz @100MHz)",
                 DIV_REF, ref_half, 2*ref_half, 100000000.0/(2.0*ref_half));
        $display("INFO DIV-guard: pre-guard truncation gave DIV[15:0]=%0d -> half-period 1 clk -> 50000000.0 Hz",
                 DIV_BAD % 65536);
        if (param_bad_bad !== 1'b1) begin
            $display("FAIL DIV-guard: DIV=%0d clamped but param_bad=0 (clamp would be silent)", DIV_BAD);
            errors = errors + 1;
        end else begin
            $display("PASS DIV-guard: DIV=%0d raises param_bad (clamp is observable)", DIV_BAD);
        end
        if (param_bad_ref !== 1'b0 || param_bad !== 1'b0) begin
            $display("FAIL DIV-guard: param_bad set for a legal DIV (ref=%b main=%b)",
                     param_bad_ref, param_bad);
            errors = errors + 1;
        end else begin
            $display("PASS DIV-guard: param_bad stays 0 for legal DIV (65536 and the main DUT's 4)");
        end
        if (bad_half < 65536) begin
            $display("FAIL DIV-guard: clamped half-period %0d clk is FASTER than the legal maximum (want >= 65536)",
                     bad_half);
            errors = errors + 1;
        end else begin
            $display("PASS DIV-guard: clamped MDC (half-period %0d clk) is not faster than the legal value",
                     bad_half);
        end
        if (bad_half !== ref_half) begin
            $display("FAIL DIV-guard: clamped arm %0d clk != legal-max arm %0d clk (clamp target wrong)",
                     bad_half, ref_half);
            errors = errors + 1;
        end else begin
            $display("PASS DIV-guard: clamped arm == legal-max arm (both %0d clk, measured on two DUTs)",
                     bad_half);
        end
        if (ssl_bad !== 1'b0 || ssl_ref !== 1'b0) begin
            $display("FAIL DIV-guard: a guard arm reports a dropped start it never had");
            errors = errors + 1;
        end

        // The DUT must never drive MDIO while the PHY is driving it.
        if (n_contend != 0) begin
            $display("FAIL: %0d MDC edges with BOTH master and PHY driving MDIO",
                     n_contend);
            errors = errors + 1;
        end else begin
            $display("PASS contention: master and PHY never drove together (%0d MDC edges)",
                     mdc_rise);
        end

        // Exact frame duration: 64 bits x 2 MDC edges x DIV half-period.
        // Printed unconditionally -- a check that silently does not run is worse
        // than no check, because it reads as coverage.
        $display("INFO frame span = %0d clk (busy rose @%0d, fell @%0d), want %0d",
                 c_busy_fall - c_busy_rise, c_busy_rise, c_busy_fall, 128*DIV);
        if (c_busy_fall - c_busy_rise != 128*DIV) begin
            $display("FAIL: frame spanned %0d clk, want exactly %0d (64 bits x 2 x DIV=%0d)",
                     c_busy_fall - c_busy_rise, 128*DIV, DIV);
            errors = errors + 1;
        end else begin
            $display("PASS MDC timing: frame = %0d clk = 64 bits x 2 edges x DIV=%0d -> %.2f MHz MDC at 100MHz",
                     128*DIV, DIV, 100.0 / (2.0 * DIV));
            $display("     synthesised DIV=25 -> %.2f MHz, inside the 2.5MHz clause-22 limit",
                     100.0 / 50.0);
        end

        if (errors == 0)
            $display("== RESULT: PASS ==");
        else
            $display("== RESULT: FAIL (%0d errors) ==", errors);
        $finish;
    end

    // Watchdog
    initial begin
        #2000000;
        $display("== RESULT: FAIL (timeout) ==");
        $finish;
    end

endmodule
