`timescale 1ns/1ps
// ===========================================================================
// mac_tx_min_top.v -- P7b MAC timing probe: MINIMAL TOP for mac_tx_10g
// ===========================================================================
// PURPOSE: measure the 64-bit XGMII TX MAC's timing and area on
//   xcku5p-ffvb676-1-e, ALONE (no PCS), with the REAL clock period (6.400 ns =
//   156.25 MHz).  Built with `synth_design -mode out_of_context`, so no
//   IBUF/OBUF is inserted and the port-to-register / register-to-port paths are
//   analysed with ZERO external delay -- which is exactly what the real design
//   looks like (the MAC's upstream FIFO and the PCS's tx_mii_d capture register
//   are both on-chip and on the SAME clock).
//
// THIS FILE IS A PROBE ONLY.  It changes no MAC logic, it only exposes ports.
// The MAC RTL itself (mac_tx_10g.v / crc32_64.v / fifo_sync.v) is a byte-exact
// copy of _proj_10g/p7b_mac/rtl -- see the sha256 provenance in the report.
// ===========================================================================
module mac_tx_min_top (
    input  wire        clk,               // 156.25 MHz, 6.400 ns
    input  wire        rst_n,
    // ---- upstream contract (identical to the 1G mac_tx_64 port list) ----
    input  wire [63:0] s_axis_tdata,
    input  wire [7:0]  s_axis_tkeep,
    input  wire        s_axis_tvalid,
    input  wire        s_axis_tlast,
    output wire        s_axis_tready,
    // ---- XGMII to the PCS ----
    output wire [63:0] xgmii_txd,
    output wire [7:0]  xgmii_txc,
    // ---- counters (kept as ports so nothing is trimmed away) ----
    output wire [31:0] stat_frames,
    output wire [31:0] stat_abort,
    output wire [31:0] stat_flush_words,
    output wire [31:0] stat_flush_done,
    output wire [31:0] stat_tx_words,
    output wire [31:0] stat_tx_ctrl_char,
    output wire [31:0] stat_tx_short,
    output wire [15:0] dbg_tx_last_clen,
    output wire [1:0]  dbg_tx_state
);

    mac_tx_10g u_dut (
        .clk               (clk),
        .rst_n             (rst_n),
        .s_axis_tdata      (s_axis_tdata),
        .s_axis_tkeep      (s_axis_tkeep),
        .s_axis_tvalid     (s_axis_tvalid),
        .s_axis_tready     (s_axis_tready),
        .s_axis_tlast      (s_axis_tlast),
        .xgmii_txd         (xgmii_txd),
        .xgmii_txc         (xgmii_txc),
        .stat_frames       (stat_frames),
        .stat_abort        (stat_abort),
        .stat_flush_words  (stat_flush_words),
        .stat_flush_done   (stat_flush_done),
        .stat_tx_words     (stat_tx_words),
        .stat_tx_ctrl_char (stat_tx_ctrl_char),
        .stat_tx_short     (stat_tx_short),
        .dbg_tx_last_clen  (dbg_tx_last_clen),
        .dbg_tx_state      (dbg_tx_state)
    );

endmodule
