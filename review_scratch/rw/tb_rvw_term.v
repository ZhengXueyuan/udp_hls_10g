`timescale 1ns/1ps
//=============================================================================
// tb_rvw_term.v -- REVIEW-SCRATCH.  Attacks the NEW TERM path of the F4 fix.
// Scenario (identical stimulus + identical tready schedule to BOTH DUTs):
//   Phase A (tready=0, consumer stalled):
//     A1: a C=64 content frame -> delivers exactly 8 words = the FIFO (D=8) becomes
//         exactly full, the frame COMPLETES, so term_pend stays 0 and no orphan exists.
//     A2: a C=14 content frame (G=1 => 0 pushes so far, first_done=0) -> at its frame
//         end push_ok=0, so mac_rx_64 takes the `hwv && !push_ok` branch.
//         ⚠ NEW code goes to S_TERM even though first_done==0 => term_pend stays 0,
//           and S_TERM can never fire (term_fire=0).
//   Phase B (tready=1, space becomes available):
//     B1: a perfectly good C=200 frame. If the DUT is parked in S_TERM with
//         term_pend==0 it must SACRIFICE this frame (`else if (gmii_rx_dv)` branch)
//         even though there is plenty of space.
// Judgement: the NEW DUT must deliver B1 (stat_frames includes it) and must NOT
// have counted it as a drop.  The OLD DUT (pre-fix) is the control: it CANNOT go to
// S_TERM at all, so it delivers B1.
//=============================================================================
module tb_rvw_term;
    reg clk = 0, rst_n = 0;
    reg [7:0] rx_d;
    reg       rx_dv, rx_er;
    reg       tready_new, tready_old;
    integer   k;

    // NEW DUT
    wire [63:0] n_tdata; wire [7:0] n_tkeep;
    wire n_tvalid,n_tlast,n_tuser,n_terr,n_tcrs;
    wire [31:0] n_frames,n_crc,n_drop,n_bytes,n_dropfull,n_droppart,n_orphan,n_ovf,n_words;
    // OLD DUT
    wire [63:0] o_tdata; wire [7:0] o_tkeep;
    wire o_tvalid,o_tlast,o_tuser,o_terr,o_tcrs;
    wire [31:0] o_frames,o_crc,o_drop,o_bytes,o_words;

    always #4 clk = ~clk;

    mac_rx_64 u_new (
        .clk(clk), .rst_n(rst_n),
        .gmii_rxd(rx_d), .gmii_rx_dv(rx_dv), .gmii_rx_er(rx_er),
        .m_axis_tdata(n_tdata), .m_axis_tkeep(n_tkeep), .m_axis_tvalid(n_tvalid),
        .m_axis_tready(tready_new), .m_axis_tlast(n_tlast), .m_axis_tuser(n_tuser),
        .m_axis_terr(n_terr), .m_axis_tcrs(n_tcrs),
        .stat_frames(n_frames), .stat_crc_err(n_crc), .stat_drop(n_drop), .stat_bytes(n_bytes),
        .stat_drop_full(n_dropfull), .stat_drop_partial(n_droppart),
        .stat_orphan_bytes(n_orphan), .stat_fifo_ovf(n_ovf),
        .dbg_stat_words_out(n_words));

    mac_rx_64_old u_old (
        .clk(clk), .rst_n(rst_n),
        .gmii_rxd(rx_d), .gmii_rx_dv(rx_dv), .gmii_rx_er(rx_er),
        .m_axis_tdata(o_tdata), .m_axis_tkeep(o_tkeep), .m_axis_tvalid(o_tvalid),
        .m_axis_tready(tready_old), .m_axis_tlast(o_tlast), .m_axis_tuser(o_tuser),
        .m_axis_terr(o_terr), .m_axis_tcrs(o_tcrs),
        .stat_frames(o_frames), .stat_crc_err(o_crc), .stat_drop(o_drop), .stat_bytes(o_bytes),
        .dbg_stat_words_out(o_words));

    // ---- output stream monitors (per DUT) ----
    integer nw, n_popc, n_tl, n_sop, n_term, n_baresop;
    integer ow, o_popc, o_tl, o_sop;
    function integer pc; input [7:0] kk; integer j; begin
        pc = 0; for (j=0;j<8;j=j+1) pc = pc + kk[j];
    end endfunction

    // "open frame" tracker: SOP seen, next SOP before TLAST => protocol violation
    reg n_open, o_open;
    always @(posedge clk) begin
        if (n_tvalid && tready_new) begin
            nw = nw + 1; n_popc = n_popc + pc(n_tkeep);
            if (n_tlast) begin n_tl = n_tl + 1;
                if (pc(n_tkeep)==0) n_term = n_term + 1;
                n_open = 1'b0; end
            if (n_tuser) begin
                if (n_open) n_baresop = n_baresop + 1;   // SOP while a frame is still open
                n_sop = n_sop + 1; n_open = 1'b1; end
        end
        if (o_tvalid && tready_old) begin
            ow = ow + 1; o_popc = o_popc + pc(o_tkeep);
            if (o_tlast) begin o_tl = o_tl + 1; o_open = 1'b0; end
            if (o_tuser) begin o_sop = o_sop + 1; o_open = 1'b1; end
        end
    end

    task send_frame; input integer content; begin
        @(posedge clk); rx_d <= 8'h55; rx_dv <= 1; rx_er <= 0;
        for (k=0;k<7;k=k+1) begin @(posedge clk); rx_d <= 8'h55; rx_dv <= 1; end
        @(posedge clk); rx_d <= 8'hD5; rx_dv <= 1;
        for (k=0;k<content;k=k+1) begin @(posedge clk); rx_d <= k[7:0]; rx_dv <= 1; end
        for (k=0;k<4;k=k+1) begin @(posedge clk); rx_d <= 8'hEE; rx_dv <= 1; end
        @(posedge clk); rx_dv <= 0; rx_d <= 8'h07;
    end endtask

    // ---- BUG MARKER: a frame starts while the NEW dut sits in S_TERM with term_pend==0 ----
    integer marker;
    always @(posedge clk) begin
        if (rx_dv && rx_d != 8'h55 && u_new.state == 3'd5 && u_new.term_pend === 1'b0) begin
            if (marker < 4)
              $display("   [MARKER] t=%0t NEW dut is in S_TERM with term_pend=0 while a frame is on the wire (fifo_full=%b push_ok=%b)",
                       $time, u_new.fifo_full, u_new.push_ok);
            marker = marker + 1;
        end
    end

    integer drop_rescue;   // frames dropped while space WAS available
    reg     saw_space;
    always @(posedge clk) begin
        // detect: DUT leaves S_TERM into S_DROP (sacrifice) while !fifo_full
        if (u_new.state == 3'd5 && !u_new.fifo_full) saw_space = 1'b1;
    end

    initial begin
        rx_d=8'h07; rx_dv=0; rx_er=0; tready_new=1; tready_old=1;
        nw=0;n_popc=0;n_tl=0;n_sop=0;n_term=0;n_baresop=0;n_open=0;
        ow=0;o_popc=0;o_tl=0;o_sop=0;o_open=0; marker=0; drop_rescue=0; saw_space=0;
        repeat (20) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        // ============ Phase A: consumer stalled ============
        $display("=== Phase A: tready=0 (consumer stalled) ===");
        tready_new = 0; tready_old = 0;
        $display("  A1: C=64 frame (delivers exactly 8 words => FIFO exactly full)");
        send_frame(64); repeat (10) @(posedge clk);
        $display("   after A1: NEW frames=%0d drops=%0d dropFull=%0d partial=%0d orphanB=%0d ovf=%0d | OLD frames=%0d drops=%0d",
                 n_frames,n_drop,n_dropfull,n_droppart,n_orphan,n_ovf,o_frames,o_drop);
        $display("  A2: C=14 frame (G=1 => 0 pushes, first_done=0)");
        send_frame(14); repeat (10) @(posedge clk);
        $display("   after A2: NEW state=%0d term_pend=%b | NEW frames=%0d drops=%0d dropFull=%0d partial=%0d orphanB=%0d ovf=%0d | OLD frames=%0d drops=%0d",
                 u_new.state, u_new.term_pend, n_frames,n_drop,n_dropfull,n_droppart,n_orphan,n_ovf,o_frames,o_drop);

        // ============ Phase B: consumer released, good frame arrives ============
        $display("=== Phase B: tready=1 (space available), send a good C=200 frame ===");
        tready_new = 1; tready_old = 1;
        send_frame(200);
        repeat (200) @(posedge clk);      // long drain

        $display("--- FINAL ---");
        $display("NEW: frames=%0d crc=%0d drop=%0d bytes=%0d dropFull=%0d partial=%0d orphanB=%0d ovf=%0d | words=%0d/%0d popc=%0d tlast=%0d term=%0d sop=%0d baresop=%0d open=%b",
                 n_frames,n_crc,n_drop,n_bytes,n_dropfull,n_droppart,n_orphan,n_ovf,
                 nw,n_words,n_popc,n_tl,n_term,n_sop,n_baresop,n_open);
        $display("OLD: frames=%0d crc=%0d drop=%0d bytes=%0d | words=%0d/%0d popc=%0d tlast=%0d sop=%0d open=%b",
                 o_frames,o_crc,o_drop,o_bytes,ow,o_words,o_popc,o_tl,o_sop,o_open);
        $display("DELTA frames (NEW-OLD) = %0d   DELTA drops = %0d",
                 n_frames-o_frames, n_drop-o_drop);
        if (n_frames < o_frames) begin
            $display("REVIEW_TERM_RESULT: FAIL -- NEW sacrificed a good frame the OLD delivered");
        end else if (n_frames == o_frames) begin
            $display("REVIEW_TERM_RESULT: PASS (no gratuitous sacrifice)");
        end else begin
            $display("REVIEW_TERM_RESULT: ? (NEW delivered MORE)");
        end
        $display("REVIEW_TERM_DONE");
        $finish;
    end
endmodule
