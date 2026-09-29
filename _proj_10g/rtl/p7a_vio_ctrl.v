//======================================================================
// p7a_vio_ctrl.v -- P7a: VIO level outputs -> one-shot events
//======================================================================
//
//  Everything here is in the OBSERVATION domain (the MMCM 156.25 MHz clock that
//  also clocks the VIO core), so there is no CDC inside this module.
//
//  Why it exists (spec 5.3 / the _proj_mdio lesson)
//  -----------------------------------------------
//  A JTAG commit takes tens of milliseconds while one transaction inside the
//  FPGA takes ~6 ns. If a VIO output drove a pulse-style input directly, the
//  "pulse" would be a level that stays high for milliseconds -- every downstream
//  clock would see it thousands of times. So each control bit is edge-detected
//  HERE, once, and converted into
//    * a one-cycle pulse in this domain (used by the unit gate to count that the
//      host's command happened exactly once), and
//    * a TOGGLE for the payload domain, which is the CDC-safe form (see
//      p7a_tgl_sync.v for why a pulse would be unsafe there).
//
//  `gt_reset` is deliberately NOT edge-detected: the GT reset controller wants a
//  reset they can hold and release as a level, and the host controls how long.
//  A forgotten high level simply keeps the GT in reset -- visible as
//  gt_tx/rx_reset_done = 0 in the status word, not a silent failure.
//======================================================================

`timescale 1ns / 1ps

module p7a_vio_ctrl (
    input  wire clk,
    input  wire rst,

    input  wire raw_snap,
    input  wire raw_clear,
    input  wire raw_slip,
    input  wire raw_gt_reset,

    output reg  snap_tgl,
    output reg  clear_tgl,
    output reg  slip_tgl,
    output wire gt_reset_level,

    output wire snap_pls,
    output wire clear_pls,
    output wire slip_pls,

    output wire raw_snap_r,
    output wire raw_clear_r,
    output wire raw_slip_r,
    output wire raw_gt_reset_r
);

    // ---- registered echoes (also the status-word readback of what we wrote) --
    reg q_snap = 1'b0, q_clear = 1'b0, q_slip = 1'b0, q_gtrst = 1'b0;

    always @(posedge clk) begin
        if (rst) begin
            q_snap <= 1'b0; q_clear <= 1'b0; q_slip <= 1'b0; q_gtrst <= 1'b0;
        end else begin
            q_snap  <= raw_snap;
            q_clear <= raw_clear;
            q_slip  <= raw_slip;
            q_gtrst <= raw_gt_reset;
        end
    end

    assign raw_snap_r    = q_snap;
    assign raw_clear_r   = q_clear;
    assign raw_slip_r    = q_slip;
    assign raw_gt_reset_r= q_gtrst;
    assign gt_reset_level= q_gtrst;

    // ---- one-cycle pulses on the rising edge of each control bit -------------
    reg p_snap = 1'b0, p_clear = 1'b0, p_slip = 1'b0;

    always @(posedge clk) begin
        if (rst) begin p_snap <= 1'b0; p_clear <= 1'b0; p_slip <= 1'b0; end
        else     begin p_snap <= q_snap; p_clear <= q_clear; p_slip <= q_slip; end
    end

    assign snap_pls  = q_snap  & ~p_snap;
    assign clear_pls = q_clear & ~p_clear;
    assign slip_pls  = q_slip  & ~p_slip;

    // ---- toggles for the payload domain -------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            snap_tgl  <= 1'b0;
            clear_tgl <= 1'b0;
            slip_tgl  <= 1'b0;
        end else begin
            if (snap_pls)  snap_tgl  <= ~snap_tgl;
            if (clear_pls) clear_tgl <= ~clear_tgl;
            if (slip_pls)  slip_tgl  <= ~slip_tgl;
        end
    end

endmodule
