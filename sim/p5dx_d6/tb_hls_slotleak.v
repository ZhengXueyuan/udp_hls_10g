`timescale 1ns/1ps
//=============================================================================
// P5d exp2: HLS slot-leak reproduction (P5d pre-experiment, sim/p5dx/exp2).
//
// Drives the REAL HLS netlist (hls/slowstack_prj/solution1/syn/verilog) at its
// own byte-stream boundary -- no fast path, no wrapper, no routing. That makes
// the HLS's slot bookkeeping directly observable, which is what the leak is
// about: the fast path's locally-initiated teardown (abort -> RST, close
// timeout -> RST) never crosses into HLS, so whatever HLS state the slot is in
// when that happens is what a same-4-tuple re-SYN has to get past.
//
// Stimulus comes from frames_b.memh / frames_meta.memh (gen_frames.py).
// Outputs: exp2_tx.log (accepted tx bytes w/ last flag), exp2_cfg.log (accepted
// cfg_stream words), exp2_marks.log (frame start/end cycle and index).
// Analysis: check_exp2.py
//=============================================================================
module tb_hls_slotleak;
    localparam GAP  = 20000;   // idle cycles between frames (HLS slow path)
    localparam NMAX = 64;

    reg clk = 0, rst_n = 0;
    always #4 clk = ~clk;      // 125 MHz

    reg  [7:0]  FB [0:16383];
    integer     NFR;
    integer     FO [0:NMAX-1];
    integer     FL [0:NMAX-1];

    reg  [15:0] rx_tdata  = 0;
    wire        rx_tvalid;
    wire        rx_tready;
    wire [15:0] tx_tdata;
    wire        tx_tvalid;
    wire [31:0] cfg_tdata;
    wire        cfg_tvalid;

    udp_echo dut (
        .ap_clk(clk), .ap_rst_n(rst_n), .reset_n(rst_n),
        .rx_stream_TDATA(rx_tdata), .rx_stream_TVALID(rx_tvalid),
        .rx_stream_TREADY(rx_tready),
        .tx_stream_TDATA(tx_tdata), .tx_stream_TVALID(tx_tvalid),
        .tx_stream_TREADY(1'b1),
        .msg_stream_TDATA(), .msg_stream_TVALID(), .msg_stream_TREADY(1'b1),
        .cfg_stream_TDATA(cfg_tdata), .cfg_stream_TVALID(cfg_tvalid),
        .cfg_stream_TREADY(1'b1),
        .led_d0(), .led_d1(), .led_d2(), .led_d3()
    );

    integer ftx, fcfg, fmark;
    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    // TDATA[7:0] = byte, TDATA[8] = last (verified in udp_echo_mac_rx_process.v
    // line 1219/1221 and mirrored on tx).
    always @(posedge clk) begin
        if (rst_n) begin
            if (tx_tvalid)  $fwrite(ftx,  "TX %0d %0d %02x\n", cyc, tx_tdata[8], tx_tdata[7:0]);
            if (cfg_tvalid) $fwrite(fcfg, "CFG %0d %08x\n", cyc, cfg_tdata);
        end
    end

    // ---- cfg-path probes (diagnose a silent cfg_stream) ----
    integer n_vld_int = 0, n_vld_grp = 0, n_st19 = 0, n_st48 = 0, n_st51 = 0;
    integer n_ackint = 0, n_rdy_grp = 0;
    always @(posedge clk) begin
        if (rst_n) begin
            if (dut.cfg_stream_TVALID_int_regslice)                  n_vld_int <= n_vld_int + 1;
            if (dut.grp_tcp_rx_process_fu_1827_cfg_stream_TVALID)    n_vld_grp <= n_vld_grp + 1;
            if (dut.ap_CS_fsm == 19)                             n_st19 <= n_st19 + 1;
            if (dut.ap_CS_fsm == 48)                             n_st48 <= n_st48 + 1;
            if (dut.ap_CS_fsm == 51)                             n_st51 <= n_st51 + 1;
            if (dut.cfg_stream_TREADY_int_regslice)                  n_ackint <= n_ackint + 1;
            if (dut.grp_tcp_rx_process_fu_1827_cfg_stream_TREADY)    n_rdy_grp <= n_rdy_grp + 1;
        end
    end

    // ---- frame sequencer: one frame, then GAP idle cycles ----
    integer fi    = 0;
    integer bp    = 0;
    reg     snd_act = 0;
    integer gap   = 0;
    reg     all_done = 0;

    assign rx_tvalid = snd_act;

    always @(posedge clk) begin
        if (!rst_n) begin
            fi <= 0; bp <= 0; snd_act <= 0; gap <= 0; all_done <= 0;
            rx_tdata <= 0;
        end else if (!all_done) begin
            if (snd_act) begin
                if (rx_tready) begin
                    if (bp + 1 >= FL[fi]) begin
                        snd_act <= 0;
                        gap     <= GAP;
                        fi      <= fi + 1;
                        $fwrite(fmark, "FEND %0d %0d\n", cyc, fi);
                    end else begin
                        bp       <= bp + 1;
                        rx_tdata <= {7'b0, ((bp + 1) == FL[fi] - 1), FB[FO[fi] + bp + 1]};
                    end
                end
            end else if (gap > 0) begin
                gap <= gap - 1;
            end else if (fi >= NFR) begin
                all_done <= 1;
            end else begin
                bp       <= 0;
                snd_act  <= 1;
                rx_tdata <= {7'b0, (FL[fi] == 1), FB[FO[fi]]};
                $fwrite(fmark, "FSTART %0d %0d\n", cyc, fi);
            end
        end
    end

    integer k, r;
    initial begin
        ftx   = $fopen("exp2_tx.log",   "w");
        fcfg  = $fopen("exp2_cfg.log",  "w");
        fmark = $fopen("exp2_marks.log","w");
        $readmemh("frames_b.memh", FB);
        k = $fopen("frames_meta.memh", "r");
        r = $fscanf(k, "%d", NFR);
        for (fi = 0; fi < NFR; fi = fi + 1) begin
            r = $fscanf(k, "%d %d", FO[fi], FL[fi]);
        end
        $fclose(k);
        fi = 0;
        $display("EXP2 frames=%0d", NFR);

        #200; rst_n = 1;
        wait (all_done);
        repeat (GAP) @(posedge clk);   // let the slow path drain
        $fwrite(fmark, "DONE %0d\n", cyc);
        $display("EXP2 DONE cyc=%0d", cyc);
        $display("EXP2PROBE vld_int=%0d vld_grp=%0d ackint=%0d rdygrp=%0d st19=%0d st48=%0d st51=%0d",
                 n_vld_int, n_vld_grp, n_ackint, n_rdy_grp, n_st19, n_st48, n_st51);
        $fclose(ftx); $fclose(fcfg); $fclose(fmark);
        $finish;
    end
endmodule
