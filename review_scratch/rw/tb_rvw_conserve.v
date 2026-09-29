`timescale 1ns/1ps
//=============================================================================
// tb_rvw_conserve.v -- REVIEW-SCRATCH.  Independent check of the F4-fix
// conservation laws with MY OWN stimulus (not tools/gen_f4_stim.py).
// Frame sizes deliberately include SUB-MINIMUM runts (content 8..15) which the
// fix's own gate never generates (its minimum is 60), plus 20/60/64/72/200/1000,
// back-to-back spacing, a corrupt-FCS frame, and a hard tready stall followed by
// a full drain.
// Laws under test (P6B fix claim #5):
//   L1 #(TLAST & tkeep!=0) == stat_frames
//   L2 Sum popc(all words) == stat_bytes - 4*stat_frames + stat_orphan_bytes
//   L3 #(TLAST & tkeep==0) == stat_drop_partial
//   L4 stat_drop_partial <= stat_drop_full <= stat_drop ; stat_fifo_ovf == 0
//   L5 every SOP is closed by exactly one TLAST before the next SOP (after drain)
//   L6 no write was silently dropped (stat_fifo_ovf == 0) -- the F4(b) root cause
//=============================================================================
module tb_rvw_conserve;
    reg clk = 0, rst_n = 0;
    reg [7:0] rx_d; reg rx_dv, rx_er; reg tready;
    integer k, ci;
    wire [63:0] td; wire [7:0] tk;
    wire tv,tl,tu,tc,te;
    wire [31:0] s_frames,s_crc,s_drop,s_bytes,s_df,s_dp,s_ob,s_ovf,s_words;

    always #4 clk = ~clk;

    mac_rx_64 dut (
        .clk(clk), .rst_n(rst_n),
        .gmii_rxd(rx_d), .gmii_rx_dv(rx_dv), .gmii_rx_er(rx_er),
        .m_axis_tdata(td), .m_axis_tkeep(tk), .m_axis_tvalid(tv),
        .m_axis_tready(tready), .m_axis_tlast(tl), .m_axis_tuser(tu),
        .m_axis_terr(te), .m_axis_tcrs(tc),
        .stat_frames(s_frames), .stat_crc_err(s_crc), .stat_drop(s_drop), .stat_bytes(s_bytes),
        .stat_drop_full(s_df), .stat_drop_partial(s_dp),
        .stat_orphan_bytes(s_ob), .stat_fifo_ovf(s_ovf),
        .dbg_stat_words_out(s_words));

    integer nwords, n_popc, n_tl, n_tl_nz, n_tl_z, n_sop, n_open, n_baresop;
    function integer pc; input [7:0] kk; integer j; begin
        pc = 0; for (j=0;j<8;j=j+1) pc = pc + kk[j];
    end endfunction

    always @(posedge clk) begin
        if (tv && tready) begin
            if (nwords < 6)
                $display("   [word#%0d] keep=%02x popc=%0d SOP=%b TLAST=%b crs=%b err=%b", nwords, tk, pc(tk), tu, tl, tc, te);
            nwords = nwords + 1; n_popc = n_popc + pc(tk);
            if (tl) begin
                n_tl = n_tl + 1;
                if (pc(tk)==0) n_tl_z = n_tl_z + 1; else n_tl_nz = n_tl_nz + 1;
                n_open = 0;
            end
            // A SOP word that also carries TLAST is a legal single-word frame: it opens
            // AND closes. Correct bookkeeping: bare SOF only when a frame is already open;
            // n_open afterwards = (SOP || was-open) && !TLAST.
            // (my first two versions got this wrong -> false positives; retracted.)
            if (tu && n_open) begin
                n_baresop = n_baresop + 1;
                $display("   [BARE-SOP] word#%0d t=%0t : SOP while a frame is still OPEN keep=%02x | FE frames=%0d drop=%0d partial=%0d",
                         nwords, $time, tk, s_frames, s_drop, s_dp);
            end
            if (tu) n_sop = n_sop + 1;
            n_open = ((tu || n_open) && !tl) ? 1 : 0;
        end
    end

    task send_frame; input integer content; input integer badcrc; begin
        @(posedge clk); rx_d <= 8'h55; rx_dv <= 1; rx_er <= 0;
        for (k=0;k<7;k=k+1) begin @(posedge clk); rx_d <= 8'h55; rx_dv <= 1; end
        @(posedge clk); rx_d <= 8'hD5; rx_dv <= 1;
        for (k=0;k<content;k=k+1) begin @(posedge clk); rx_d <= k[7:0]; rx_dv <= 1; end
        for (k=0;k<4;k=k+1) begin @(posedge clk); rx_d <= badcrc ? 8'h11 : 8'hEE; rx_dv <= 1; end
        @(posedge clk); rx_dv <= 0; rx_d <= 8'h07;
    end endtask

    integer sizes [0:11];
    integer errs;
    task check_laws; input [255:0] tag; begin
        if (n_tl_nz !== s_frames) begin
            errs=errs+1; $display("  L1 FAIL %0s: TLAST&keep!=0=%0d vs stat_frames=%0d", tag, n_tl_nz, s_frames); end
        if (n_popc !== s_bytes - 4*s_frames + s_ob) begin
            errs=errs+1; $display("  L2 FAIL %0s: popc=%0d vs bytes-4F+orph=%0d (%0d-%0d+%0d)",
                                  tag, n_popc, s_bytes-4*s_frames+s_ob, s_bytes, 4*s_frames, s_ob); end
        if (n_tl_z !== s_dp) begin
            errs=errs+1; $display("  L3 FAIL %0s: TERM frames=%0d vs stat_drop_partial=%0d", tag, n_tl_z, s_dp); end
        if (!(s_dp <= s_df && s_df <= s_drop)) begin
            errs=errs+1; $display("  L4a FAIL %0s: %0d<=%0d<=%0d violated", tag, s_dp, s_df, s_drop); end
        if (s_ovf !== 0) begin
            errs=errs+1; $display("  L4b FAIL %0s: stat_fifo_ovf=%0d (silent write loss!)", tag, s_ovf); end
        if (n_baresop !== 0) begin
            errs=errs+1; $display("  L5 FAIL %0s: bare SOP (frame not closed by TLAST) x%0d", tag, n_baresop); end
    end endtask

    initial begin
        sizes[0]=8; sizes[1]=14; sizes[2]=15; sizes[3]=20;
        sizes[4]=60; sizes[5]=64; sizes[6]=65; sizes[7]=72;
        sizes[8]=200; sizes[9]=1000; sizes[10]=63; sizes[11]=9;
        nwords=0;n_popc=0;n_tl=0;n_tl_nz=0;n_tl_z=0;n_sop=0;n_open=0;n_baresop=0; errs=0;
        rx_d=8'h07; rx_dv=0; rx_er=0; tready=1;
        repeat (20) @(posedge clk); rst_n=1; repeat (5) @(posedge clk);

        // ---- Phase 1: open with a full drain, no stall, mixed sizes (incl. runts) ----
        $display("== P1: mixed sizes incl. runts (content 8,9,14,15,20,60..72,200,1000), no stall ==");
        for (ci=0; ci<12; ci=ci+1) begin
            $display("   >> sending frame ci=%0d content=%0d", ci, sizes[ci]);
            send_frame(sizes[ci], (ci==8));
            repeat (4) @(posedge clk);
        end
        repeat (300) @(posedge clk);
        check_laws("P1");

        // ---- Phase 2: hard stall -> force drops, then full drain ----
        $display("== P2: tready hard-stalled during long frames, then released ==");
        tready = 0;
        for (ci=0; ci<6; ci=ci+1) begin
            send_frame(300, 0);
            repeat (10) @(posedge clk);
        end
        send_frame(64, 0);      // exactly 8 words -> fills the FIFO if not already
        repeat (10) @(posedge clk);
        send_frame(14, 0);      // runt at frame end while full: the term_pend=0 corner
        repeat (10) @(posedge clk);
        $display("   after stall: state=%0d term_pend=%b first_done=%b drop=%0d dropFull=%0d partial=%0d orphB=%0d ovf=%0d",
                 dut.state, dut.term_pend, dut.first_done, s_drop, s_df, s_dp, s_ob, s_ovf);
        tready = 1;
        repeat (600) @(posedge clk);       // full drain
        check_laws("P2");
        if (n_open) begin errs=errs+1; $display("  L5 FAIL P2: a frame is still open after the full drain"); end
        if (s_ovf !== 0) begin errs=errs+1; $display("  L6 FAIL P2: stat_fifo_ovf=%0d", s_ovf); end

        // ---- Phase 3: back-to-back minimum frames, no idle ----
        $display("== P3: back-to-back 64-byte content frames ==");
        for (ci=0; ci<20; ci=ci+1) send_frame(64,0);
        repeat (300) @(posedge clk);
        check_laws("P3");

        $display("--- totals: words=%0d popc=%0d SOP=%0d TLAST=%0d (nz=%0d term=%0d) baresop=%0d",
                 nwords,n_popc,n_sop,n_tl,n_tl_nz,n_tl_z,n_baresop);
        $display("--- FE: frames=%0d crc=%0d drop=%0d bytes=%0d dropFull=%0d partial=%0d orphanB=%0d ovf=%0d words_out=%0d",
                 s_frames,s_crc,s_drop,s_bytes,s_df,s_dp,s_ob,s_ovf,s_words);
        if (errs==0) $display("REVIEW_CONSERVE_RESULT: PASS_ALL");
        else         $display("REVIEW_CONSERVE_RESULT: FAIL (%0d)", errs);
        $display("REVIEW_CONSERVE_DONE");
        $finish;
    end
endmodule
