`timescale 1ns/1ps
//=============================================================================
// tb_rvw_fullnext.v -- REVIEW-SCRATCH (P6b adversarial re-review of the F4 fix).
// Independently attacks fifo_sync.full_next in BOTH directions:
//   TEST-1 EXHAUSTIVE (force sweep): for EVERY (wptr,rptr) pair over the whole
//          2^(AW+1) x 2^(AW+1) space x {wr,rd} in {0,1}^2, force the pointers,
//          read full_next, then RELEASE and let one REAL clock edge pass, and
//          compare against the ACTUAL `full` that appears.  It is therefore NOT a
//          restatement of the formula: the reference is the DUT's own next-cycle
//          output.  Also checks ovf_pulse === (wr && full) on every combination.
//   TEST-2 FREE-RUNNING lag equality: assert full_next@t === full@(t+1) every
//          cycle of a 60k-cycle random run (wr/rd duty cycles chosen to saturate
//          AND drain), on three depths (D=4/AW=2, D=8/AW=3, D=16/AW=4).
//          Plus a reachable-occupancy COVERAGE report so the claim is auditable.
//=============================================================================
module tb_rvw_fullnext;
    reg clk = 0;
    always #4 clk = ~clk;      // 125 MHz

    reg  d_rst_n = 0;
    reg  a_wr=0, a_rd=0, b_wr=0, b_rd=0, c_wr=0, c_rd=0;
    wire a_full,a_empty,a_fn,a_ovf, b_full,b_empty,b_fn,b_ovf, c_full,c_empty,c_fn,c_ovf;
    wire [63:0] a_do,b_do,c_do;

    fifo_sync #(.W(72), .D(4),  .AW(2)) uA (
        .clk(clk), .rst_n(d_rst_n), .wr(a_wr), .din(72'h0), .rd(a_rd),
        .dout(a_do), .empty(a_empty), .full(a_full),
        .dbg_wptr(), .dbg_rptr(), .dbg_full(), .dbg_empty(),
        .full_next(a_fn), .ovf_pulse(a_ovf));

    fifo_sync #(.W(72), .D(8),  .AW(3)) uB (
        .clk(clk), .rst_n(d_rst_n), .wr(b_wr), .din(72'h0), .rd(b_rd),
        .dout(b_do), .empty(b_empty), .full(b_full),
        .dbg_wptr(), .dbg_rptr(), .dbg_full(), .dbg_empty(),
        .full_next(b_fn), .ovf_pulse(b_ovf));

    fifo_sync #(.W(72), .D(16), .AW(4)) uC (
        .clk(clk), .rst_n(d_rst_n), .wr(c_wr), .din(72'h0), .rd(c_rd),
        .dout(c_do), .empty(c_empty), .full(c_full),
        .dbg_wptr(), .dbg_rptr(), .dbg_full(), .dbg_empty(),
        .full_next(c_fn), .ovf_pulse(c_ovf));

    function integer pc32; input integer v; integer i; begin
        pc32 = 0; for (i=0;i<32;i=i+1) pc32 = pc32 + v[i];
    end endfunction
    integer errors, checks, ncombos, err_t1, err_t2;
    integer W_id, R_id, A_id, k;
    reg fn_smp, full_act;

    // TEST-2 bookkeeping
    reg fq_a, fq_b, fq_c;
    integer occ_a, occ_b, occ_c;      // bitmask of occupancy values seen
    integer wp_a, wp_b, wp_c;

    task run_combo; input [4:0] wp; input [4:0] rp; input aa; input bb;
                    input integer which;
    begin
        @(negedge clk);
        case (which)
          0: begin force uA.wptr = wp[2:0]; force uA.rptr = rp[2:0]; a_wr = aa; a_rd = bb; end
          1: begin force uB.wptr = wp[3:0]; force uB.rptr = rp[3:0]; b_wr = aa; b_rd = bb; end
          2: begin force uC.wptr = wp[4:0]; force uC.rptr = rp[4:0]; c_wr = aa; c_rd = bb; end
        endcase
        #0.5;
        case (which)
          0: begin fn_smp = a_fn; if (a_ovf !== (a_wr && a_full)) begin
                 errors=errors+1;
                 $display("  ERR ovf cfg0 W=%0d R=%0d wr=%0d rd=%0d ovf=%b full=%b", wp,rp,aa,bb,a_ovf,a_full);
             end end
          1: begin fn_smp = b_fn; if (b_ovf !== (b_wr && b_full)) begin
                 errors=errors+1;
                 $display("  ERR ovf cfg1 W=%0d R=%0d wr=%0d rd=%0d ovf=%b full=%b", wp,rp,aa,bb,b_ovf,b_full);
             end end
          2: begin fn_smp = c_fn; if (c_ovf !== (c_wr && c_full)) begin
                 errors=errors+1;
                 $display("  ERR ovf cfg2 W=%0d R=%0d wr=%0d rd=%0d ovf=%b full=%b", wp,rp,aa,bb,c_ovf,c_full);
             end end
        endcase
        checks = checks + 1;
        ncombos = ncombos + 1;
        case (which)
          0: begin release uA.wptr; release uA.rptr; end
          1: begin release uB.wptr; release uB.rptr; end
          2: begin release uC.wptr; release uC.rptr; end
        endcase
        @(posedge clk);
        #0.5;
        case (which)
          0: full_act = a_full;
          1: full_act = b_full;
          2: full_act = c_full;
        endcase
        checks = checks + 1;
        if (full_act !== fn_smp) begin
            errors = errors + 1; err_t1 = err_t1 + 1;
            if (err_t1 <= 25)
              $display("  ERR fn-mismatch cfg%0d W=%0d R=%0d wr=%0d rd=%0d : full_next=%b actual_next_full=%b",
                       which, wp, rp, aa, bb, fn_smp, full_act);
        end
        case (which)
          0: begin a_wr=0; a_rd=0; end
          1: begin b_wr=0; b_rd=0; end
          2: begin c_wr=0; c_rd=0; end
        endcase
    end
    endtask

    initial begin
        errors=0; checks=0; ncombos=0; fn_smp=0; full_act=0; err_t1=0; err_t2=0;
        fq_a=0; fq_b=0; fq_c=0; occ_a=0; occ_b=0; occ_c=0;
        repeat (8) @(posedge clk);
        d_rst_n = 1;
        repeat (4) @(posedge clk);

        //=====================================================================
        // TEST-1: exhaustive force sweep
        //=====================================================================
        $display("== TEST-1 exhaustive force sweep: (wptr,rptr) x {wr,rd} ==");
        // cfg0: AW=2 -> pointers 3 bits -> 8x8x4 = 256
        for (W_id=0; W_id<8; W_id=W_id+1)
          for (R_id=0; R_id<8; R_id=R_id+1)
            for (A_id=0; A_id<4; A_id=A_id+1)
              run_combo(W_id[4:0], R_id[4:0], A_id[0], A_id[1], 0);
        $display("  cfg0 (D=4 , AW=2) exhaustive: 8x8x4 = 256 combos done (err so far %0d)", err_t1);
        // cfg1: AW=3 -> 16x16x4 = 1024
        for (W_id=0; W_id<16; W_id=W_id+1)
          for (R_id=0; R_id<16; R_id=R_id+1)
            for (A_id=0; A_id<4; A_id=A_id+1)
              run_combo(W_id[4:0], R_id[4:0], A_id[0], A_id[1], 1);
        $display("  cfg1 (D=8 , AW=3) exhaustive: 16x16x4 = 1024 combos done (err so far %0d)", err_t1);
        // cfg2: AW=4 -> 32x32x4 = 4096
        for (W_id=0; W_id<32; W_id=W_id+1)
          for (R_id=0; R_id<32; R_id=R_id+1)
            for (A_id=0; A_id<4; A_id=A_id+1)
              run_combo(W_id[4:0], R_id[4:0], A_id[0], A_id[1], 2);
        $display("  cfg2 (D=16, AW=4) exhaustive: 32x32x4 = 4096 combos done (err so far %0d)", err_t1);

        //=====================================================================
        // TEST-2: free-running lag equality, 60k cycles
        //=====================================================================
        $display("== TEST-2 free-running: full_next@t === full@(t+1), 60000 cycles ==");
        // NOTE: wr/rd are written BLOCKING at negedge and full_next is sampled AFTER
        // that (settled, mid-cycle) -- otherwise the sample would use a different
        // wr/rd than the edge consumes it with (project pitfall 17).
        for (k=0; k<60000; k=k+1) begin
            @(negedge clk);
            a_wr = (($random % 8) >= 1);   // 7/8
            a_rd = (($random % 8) >= 4);   // 4/8  -> saturates
            b_wr = (($random % 8) >= 2);   // 6/8
            b_rd = (($random % 8) >= 3);   // 5/8  -> balanced-ish
            c_wr = (($random % 8) >= 1);
            c_rd = (($random % 8) >= 5);   // 3/8  -> saturates hard
            #0.1;
            fq_a = a_fn; fq_b = b_fn; fq_c = c_fn;   // full_next with THIS cycle's wr/rd
            @(posedge clk);
            #0.1;
            checks = checks + 1;
            if (fq_a !== a_full) begin errors=errors+1; err_t2=err_t2+1;
                if (err_t2<=15) $display("  ERR lag cfg0 t=%0t fn@prev=%b full=%b", $time, fq_a, a_full); end
            if (fq_b !== b_full) begin errors=errors+1; err_t2=err_t2+1;
                if (err_t2<=15) $display("  ERR lag cfg1 t=%0t fn@prev=%b full=%b", $time, fq_b, b_full); end
            if (fq_c !== c_full) begin errors=errors+1; err_t2=err_t2+1;
                if (err_t2<=15) $display("  ERR lag cfg2 t=%0t fn@prev=%b full=%b", $time, fq_c, c_full); end
            occ_a = occ_a | (1 << ((16 + uA.wptr - uA.rptr) % 16));
            occ_b = occ_b | (1 << ((32 + uB.wptr - uB.rptr) % 32));
            occ_c = occ_c | (1 << ((64 + uC.wptr - uC.rptr) % 64));
        end

        $display("REVIEW_FN: combos=%0d checks=%0d errors=%0d (TEST-1=%0d TEST-2=%0d)", ncombos, checks, errors, err_t1, err_t2);
        $display("  reachable-occupancy coverage: cfg0(D=4)=%0d/5  cfg1(D=8)=%0d/9  cfg2(D=16)=%0d/17",
                 pc32(occ_a), pc32(occ_b), pc32(occ_c));
        if (errors == 0) $display("REVIEW_FN_RESULT: PASS_ALL");
        else             $display("REVIEW_FN_RESULT: FAIL (%0d)", errors);
        $display("REVIEW_FN_DONE");
        $finish;
    end

endmodule
