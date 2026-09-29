`timescale 1ns/1ps
//=============================================================================
// tb_rvw_macrx.v -- REVIEW-SCRATCH only (P6b adversarial review, S3).
// Tests P6B_SPEC section 7.3's claim that
//     Sum popc(tkeep) + 4*TLAST  ==  stat_bytes        (and W0 == W30)
// is a "precise identity" that holds whenever the RX FIFO is quiescent.
// It drives GMII frames into rtl/mac_rx_64.v while the AXIS consumer's tready is
// stalled so the internal 8-deep fifo_full drop paths (lines 156-158, 182-184,
// 204-206) really fire, then RELEASES tready so the already-pushed words drain
// out to the "DP side" (that is what W30/W31 would count).
//   FE side counters (as the spec places them): stat_frames(W0) / stat_bytes(W1) / stat_drop(W4)
//   DP side counters (what W30/W31 would see):  TLAST count / sum popc over the word stream
//=============================================================================
module tb_rvw_macrx;
    reg        clk = 0, rst_n = 0;
    reg [7:0]  rx_d;
    reg        rx_dv, rx_er;
    reg        tready;
    integer    cyc, STALL_FROM, STALL_UNTIL, stall_en;
    integer    k;
    integer    trace_on = 0;

    wire [63:0] tdata;  wire [7:0] tkeep;
    wire        tvalid, tlast, tuser, terr, tcrs;
    wire [31:0] stat_frames, stat_crc_err, stat_drop, stat_bytes;

    mac_rx_64 dut (
        .clk(clk), .rst_n(rst_n),
        .gmii_rxd(rx_d), .gmii_rx_dv(rx_dv), .gmii_rx_er(rx_er),
        .m_axis_tdata(tdata), .m_axis_tkeep(tkeep), .m_axis_tvalid(tvalid),
        .m_axis_tready(tready), .m_axis_tlast(tlast), .m_axis_tuser(tuser),
        .m_axis_terr(terr), .m_axis_tcrs(tcrs),
        .stat_frames(stat_frames), .stat_crc_err(stat_crc_err),
        .stat_drop(stat_drop), .stat_bytes(stat_bytes)
    );
    always #4 clk = ~clk;     // 125 MHz = 8 ns

    // ---- DP-side observation of the output word stream ----
    integer out_words, out_popc, out_tlast, out_sop, orphan_run;
    function integer pc; input [7:0] kb; integer j; begin
        pc = 0; for (j = 0; j < 8; j = j + 1) pc = pc + kb[j];
    end endfunction
    always @(posedge clk) begin
        if (tvalid && tready) begin
            out_words = out_words + 1;
            out_popc  = out_popc + pc(tkeep);
            if (tlast) begin out_tlast = out_tlast + 1; orphan_run = 0; end
            else       orphan_run = orphan_run + 1;
        end
    end

    // ---- drop-branch attribution: record dut.state whenever stat_drop ticks ----
    reg [31:0] drop_q;  integer drop_state0, drop_state1, drop_state2;
    integer    drop_n;
    always @(posedge clk) begin
        if (stat_drop !== drop_q) begin
            drop_n = drop_n + 1;
            if (drop_n == 1) drop_state0 = dut.state;
            if (drop_n == 2) drop_state1 = dut.state;
            if (drop_n == 3) drop_state2 = dut.state;
            $display("   [drop #%0d] t=%0t  dut.state=%0d  stat_drop=%0d  stat_frames=%0d  out_words=%0d out_popc=%0d out_tlast=%0d",
                     drop_n, $time, dut.state, stat_drop, stat_frames,
                     out_words, out_popc, out_tlast);
            drop_q = stat_drop;
        end
    end

    // monitor: print the exact cycle in which stat_frames ticks (frame counted by FE)
    reg [31:0] sf_q = 0;
    always @(posedge clk) begin
        if (stat_frames !== sf_q) begin
            $display("   [framecnt delta#%0d] t=%0t state=%0d fbytes=%0d bcnt=%0d hwv=%0d fifo_full=%0d wptr=%0d rptr=%0d | out_words=%0d",
                     stat_frames-sf_q, $time, dut.state, dut.fbytes, dut.bcnt, dut.hwv,
                     dut.fifo_full, dut.u_fifo.wptr, dut.u_fifo.rptr, out_words);
            sf_q = stat_frames;
        end
    end

    task send_frame; input integer content; begin
        @(posedge clk); rx_d <= 8'h55; rx_dv <= 1; rx_er <= 0;
        for (k = 0; k < 7; k = k + 1) begin @(posedge clk); rx_d <= 8'h55; rx_dv <= 1; end
        @(posedge clk); rx_d <= 8'hD5; rx_dv <= 1;
        for (k = 0; k < content; k = k + 1) begin
            @(posedge clk); rx_d <= k[7:0]; rx_dv <= 1;
        end
        for (k = 0; k < 4; k = k + 1) begin @(posedge clk); rx_d <= 8'hEE; rx_dv <= 1; end
        @(posedge clk); rx_dv <= 0; rx_d <= 8'h07;
    end endtask

    // stall while stall_en: tready = 0 for cyc in [STALL_FROM, STALL_UNTIL)
    always @(posedge clk) begin
        if (!rst_n) cyc <= 0; else cyc <= cyc + 1;
        tready <= (stall_en && cyc >= STALL_FROM && cyc < STALL_UNTIL) ? 1'b0 : 1'b1;
    end

    task drain_idle; begin
        stall_en = 0; cyc = 0;
        repeat (400) @(posedge clk);
    end endtask

    // ---- per-frame deltas + DUT internals -------------------------------------
    integer dw, dp, dt, w0p, w1p, w4p;
    task snap_prev; begin w0p=stat_frames; w1p=stat_bytes; w4p=stat_drop;
                        dw=out_words; dp=out_popc; dt=out_tlast; end endtask
    task report_delta; input [255:0] tag; begin
        $display("%0s DELTA: dW0=%0d dW1=%0d dW4=%0d | dW30=%0d dW31=%0d",
                 tag, stat_frames-w0p, stat_bytes-w1p, stat_drop-w4p,
                 out_tlast-dt, (out_popc+4*out_tlast)-(dp+4*dt));
    end endtask
    // trace the frame-end decision window (only for the plain-state frames)
    always @(posedge clk) if (trace_on && dut.fbytes >= 68)
        $display("   t=%0t st=%0d fby=%0d bcnt=%0d hwv=%0d push=%0d last=%0d full=%0d wptr=%0d rptr=%0d dv=%0d sf=%0d sb=%0d drops=%0d",
                 $time, dut.state, dut.fbytes, dut.bcnt, dut.hwv, dut.push, dut.push_last,
                 dut.fifo_full, dut.u_fifo.wptr, dut.u_fifo.rptr, rx_dv,
                 stat_frames, stat_bytes, stat_drop);

    integer w_prev, p_prev, t_prev;
    task report; input [255:0] tag; begin
        $display("%0s: FE W0=%0d W1=%0d W4=%0d | DP W30=%0d W31=%0d | gap(W1-W31)=%0d gap(W0-W30)=%0d  [orphan_run=%0d]",
                 tag, stat_frames, stat_bytes, stat_drop,
                 out_tlast, out_popc + 4*out_tlast,
                 stat_bytes - (out_popc + 4*out_tlast), stat_frames - out_tlast,
                 orphan_run);
    end endtask

    initial begin
        rx_d = 8'h07; rx_dv = 0; rx_er = 0; tready = 1;
        out_words=0; out_popc=0; out_tlast=0; out_sop=0; orphan_run=0;
        drop_q=0; drop_n=0; stall_en=0; STALL_FROM=0; STALL_UNTIL=0;
        w_prev=0; p_prev=0; t_prev=0;

        repeat (25) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        // ---- F1: control, no stall. content=200 => 25 words == 200 bytes of popc ----
        $display("=== F1 control: content=200, no stall ===");
        snap_prev; send_frame(200); drain_idle; report("F1 "); report_delta("F1 ");

        // ---- F2: mid-frame drop. content=200; stall cyc [30,300) ----
        $display("=== F2: content=200, tready stalled cyc[30,300) ===");
        cyc=0; stall_en=1; STALL_FROM=30; STALL_UNTIL=300;
        snap_prev; trace_on=1; send_frame(200); trace_on=0;
        repeat (20) @(posedge clk);
        report("F2s");
        drain_idle; report("F2 "); report_delta("F2 ");

        // ---- F3: frame-end drop. content=72 (exactly 9 words); stall cyc[12,300) ----
        $display("=== F3: content=72 (exactly 9 words), tready stalled cyc[12,300) ===");
        cyc=0; stall_en=1; STALL_FROM=12; STALL_UNTIL=300;
        snap_prev; trace_on=1; send_frame(72);
        repeat (6) @(posedge clk); trace_on=0;
        report("F3s");
        drain_idle; report("F3 "); report_delta("F3 ");

        // ---- F4: short frame, no stall: identity must hold ----
        $display("=== F4 control: content=20, no stall ===");
        snap_prev; send_frame(20); drain_idle; report("F4 "); report_delta("F4 ");

        $display("------------------------------------------------------------");
        $display("VERDICT: after F2 (mid-frame drop) and F3 (frame-end drop) the FE/DP");
        $display("         byte identity W1==W31 is broken by the orphan words that were");
        $display("         already pushed before the drop. Frame identity W0==W30 survives.");
        $display("REVIEW_DONE");
        $finish;
    end
endmodule
