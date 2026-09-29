// ============================================================================
// tb_pay_sel.v -- does the parameterised traffic copy actually change the XGMII
//   payload pattern with pay_sel?
//
//   The module under test is self-contained (all of its submodules live in the
//   same file), so no IP is needed.  We only care about the GENERATOR's output:
//   tx_mii_d/tx_mii_c are captured for pay_sel = 0 and pay_sel = 1 and the
//   payload words are printed.
//
//   Build/run:  run_sim_pay.bat  (xvlog + xelab + xsim, -d SIM_SPEED_UP)
// ============================================================================
`timescale 1ns/1ps

module tb_pay_sel;

    reg gen_clk = 0, mon_clk = 0, dclk = 0, sys_reset = 1;
    reg send_cont = 1, restart = 0;
    reg pay_sel = 0;

    wire [63:0] tx_mii_d;
    wire [7:0]  tx_mii_c;
    wire [63:0] rx_mii_d = 64'h0707070707070707;
    wire [7:0]  rx_mii_c = 8'hFF;
    wire        rx_reset, tx_reset;
    wire [4:0]  completion_status;
    wire        gt_locked_led, blk_locked_led;

    always #3.2  gen_clk = ~gen_clk;      // 156.25 MHz
    always #3.2  mon_clk = ~mon_clk;
    always #5.0  dclk    = ~dclk;         // 100 MHz

    pcs64_pkt_gen_mon_ds #(
        .PKT_NUM(20), .FIXED_PACKET_LENGTH(256), .MIN_LENGTH(64), .MAX_LENGTH(9000)
    ) dut (
        .gen_clk(gen_clk), .mon_clk(mon_clk), .dclk(dclk),
        .sys_reset(sys_reset), .restart_tx_rx(restart),
        .send_continuous_pkts(send_cont), .pay_sel(pay_sel),
        .rx_reset(rx_reset), .user_rx_reset(1'b0),
        .rx_mii_d(rx_mii_d), .rx_mii_c(rx_mii_c),
        .ctl_rx_test_pattern(), .ctl_rx_test_pattern_enable(),
        .ctl_rx_data_pattern_select(), .ctl_rx_prbs31_test_pattern_enable(),
        .stat_rx_block_lock(1'b1), .stat_rx_framing_err_valid(1'b0),
        .stat_rx_framing_err(1'b0), .stat_rx_hi_ber(1'b0),
        .stat_rx_valid_ctrl_code(1'b0), .stat_rx_bad_code(1'b0),
        .stat_rx_bad_code_valid(1'b0), .stat_rx_error_valid(1'b0),
        .stat_rx_error(8'h00), .stat_rx_fifo_error(1'b0),
        .stat_rx_local_fault(1'b0),
        .tx_reset(tx_reset), .user_tx_reset(1'b0),
        .tx_mii_d(tx_mii_d), .tx_mii_c(tx_mii_c),
        .ctl_tx_test_pattern(), .ctl_tx_test_pattern_enable(),
        .ctl_tx_test_pattern_select(), .ctl_tx_data_pattern_select(),
        .ctl_tx_test_pattern_seed_a(), .ctl_tx_test_pattern_seed_b(),
        .ctl_tx_prbs31_test_pattern_enable(),
        .stat_tx_local_fault(1'b0),
        .completion_status(completion_status),
        .rx_gt_locked_led(gt_locked_led), .rx_block_lock_led(blk_locked_led)
    );

    integer i, nword;
    integer frames_seen;
    reg [63:0] w;

    task run_case;
        input        psel;
        input integer nprint;
        begin
            pay_sel = psel;
            sys_reset = 1;
            restart   = 0;
            send_cont = 0;
            repeat (20) @(posedge dclk);
            sys_reset = 0;
            // The vendor FSM's arming window: with SIM_SPEED_UP the timers are
            // cvt_us(100)=7500 + 3 + cvt_us(5)=378 + cvt_us(5000)=375000 dclk
            // cycles, then the S6..S12 checks -- so ~600k cycles before the
            // generator is enabled.  (60000 was 10x too short: the first run
            // captured nothing, which is how this constant was found.)
            repeat (600000) @(posedge dclk);
            // start a continuous run
            send_cont = 1;
            restart = 1;
            repeat (10) @(posedge dclk);
            restart = 0;
            $display("TBCHAIN psel=%0d tb=%b dut=%b tgm=%b pkggen=%b data_select=%b",
                psel, pay_sel, dut.pay_sel, dut.i_pcs64_mii_gen_mon.pay_sel,
                dut.i_pcs64_mii_gen_mon.i_pcs64_PKT_GEN1.pay_sel,
                dut.i_pcs64_mii_gen_mon.i_pcs64_PKT_GEN1.data_select);
            // capture transmit words, printing the payload region of each frame
            nword = 0; frames_seen = 0;
            for (i = 0; i < 30000; i = i + 1) begin
                @(posedge gen_clk);
                if (tx_mii_c == 8'h01 && tx_mii_d[7:0] == 8'hFB) begin
                    frames_seen = frames_seen + 1;
                    $display("TBCASE psel=%0d FRAME %0d at word %0d", psel, frames_seen, nword);
                end
                // print the 4th data word of a frame (pure payload) and the terminator
                if (frames_seen <= nprint) begin
                    if (tx_mii_c == 8'h00 && nword > 0) begin
                        w = tx_mii_d;
                        if (nword % 4 == 0)
                            $display("TBCASE psel=%0d word %0d d=%h c=%h", psel, nword, tx_mii_d, tx_mii_c);
                    end
                    if (nword % 4 == 0)
                        $display("TBINT psel=%0d nw=%0d state=%b data_select=%b d_sel=%b op_data=%h hbc=%0d cnt=%0d",
                            psel, nword,
                            dut.i_pcs64_mii_gen_mon.i_pcs64_PKT_GEN1.state,
                            dut.i_pcs64_mii_gen_mon.i_pcs64_PKT_GEN1.data_select,
                            dut.i_pcs64_mii_gen_mon.i_pcs64_PKT_GEN1.d_sel,
                            dut.i_pcs64_mii_gen_mon.i_pcs64_PKT_GEN1.op_data,
                            dut.i_pcs64_mii_gen_mon.i_pcs64_PKT_GEN1.header_bit_count,
                            dut.i_pcs64_mii_gen_mon.i_pcs64_PKT_GEN1.counter);
                    if (tx_mii_c[0] && tx_mii_d[7:0] == 8'hFD)
                        $display("TBCASE psel=%0d TERM at word %0d", psel, nword);
                end
                nword = nword + 1;
                if (frames_seen > nprint + 1) i = 30000;
            end
            send_cont = 0;
            repeat (100) @(posedge dclk);
        end
    endtask

    initial begin
        #100;
        $display("TB START");
        run_case(0, 2);
        run_case(1, 2);
        $display("TB DONE");
        $finish;
    end

endmodule
