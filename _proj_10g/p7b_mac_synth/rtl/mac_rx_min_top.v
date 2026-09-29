`timescale 1ns/1ps
// ===========================================================================
// mac_rx_min_top.v -- P7b MAC timing probe: MINIMAL TOP for mac_rx_10g
// ===========================================================================
// PURPOSE: measure the 64-bit XGMII RX MAC's timing and area on
//   xcku5p-ffvb676-1-e, ALONE (no PCS), with the REAL clock period (6.400 ns =
//   156.25 MHz).  Built with `synth_design -mode out_of_context`; see
//   mac_tx_min_top.v for why zero external delay is the faithful model here
//   (the PCS's rx_mii_d register and the MAC's downstream FIFO are both
//   on-chip and on the SAME recovered clock).
//
// THIS FILE IS A PROBE ONLY.  It changes no MAC logic, it only exposes ports.
// ===========================================================================
module mac_rx_min_top (
    input  wire        clk,               // 156.25 MHz, 6.400 ns (rx_core_clk)
    input  wire        rst_n,
    // ---- XGMII from the PCS ----
    input  wire [63:0] xgmii_rxd,
    input  wire [7:0]  xgmii_rxc,
    // ---- downstream frozen contract (identical to 1G mac_rx_64's port list) ----
    output wire [63:0] m_axis_tdata,
    output wire [7:0]  m_axis_tkeep,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,
    output wire        m_axis_tuser,
    output wire        m_axis_tcrs,
    output wire        m_axis_terr,
    // ---- counters (kept as ports so nothing is trimmed away) ----
    output wire [31:0] stat_frames,
    output wire [31:0] stat_crc_err,
    output wire [31:0] stat_drop,
    output wire [31:0] stat_bytes,
    output wire [31:0] stat_drop_full,
    output wire [31:0] stat_drop_partial,
    output wire [31:0] stat_orphan_bytes,
    output wire [31:0] stat_fifo_ovf,
    output wire [31:0] dbg_stat_words_out,
    output wire [31:0] stat_rx_words,
    output wire [31:0] stat_rx_pay_bytes,
    output wire [31:0] stat_rx_er_words,
    output wire [31:0] stat_rx_bad_words,
    output wire [31:0] stat_rx_frag,
    output wire [31:0] stat_rx_no_s,
    output wire [31:0] stat_rx_q,
    output wire [31:0] stat_rx_short,
    output wire [31:0] stat_rx_long,
    output wire [15:0] dbg_rx_last_len,
    output wire [3:0]  dbg_rx_last_tlane,
    output wire [1:0]  dbg_rx_state
);

    mac_rx_10g u_dut (
        .clk                (clk),
        .rst_n              (rst_n),
        .xgmii_rxd          (xgmii_rxd),
        .xgmii_rxc          (xgmii_rxc),
        .m_axis_tdata       (m_axis_tdata),
        .m_axis_tkeep       (m_axis_tkeep),
        .m_axis_tvalid      (m_axis_tvalid),
        .m_axis_tready      (m_axis_tready),
        .m_axis_tlast       (m_axis_tlast),
        .m_axis_tuser       (m_axis_tuser),
        .m_axis_tcrs        (m_axis_tcrs),
        .m_axis_terr        (m_axis_terr),
        .stat_frames        (stat_frames),
        .stat_crc_err       (stat_crc_err),
        .stat_drop          (stat_drop),
        .stat_bytes         (stat_bytes),
        .stat_drop_full     (stat_drop_full),
        .stat_drop_partial  (stat_drop_partial),
        .stat_orphan_bytes  (stat_orphan_bytes),
        .stat_fifo_ovf      (stat_fifo_ovf),
        .dbg_stat_words_out (dbg_stat_words_out),
        .stat_rx_words      (stat_rx_words),
        .stat_rx_pay_bytes  (stat_rx_pay_bytes),
        .stat_rx_er_words   (stat_rx_er_words),
        .stat_rx_bad_words  (stat_rx_bad_words),
        .stat_rx_frag       (stat_rx_frag),
        .stat_rx_no_s       (stat_rx_no_s),
        .stat_rx_q          (stat_rx_q),
        .stat_rx_short      (stat_rx_short),
        .stat_rx_long       (stat_rx_long),
        .dbg_rx_last_len    (dbg_rx_last_len),
        .dbg_rx_last_tlane  (dbg_rx_last_tlane),
        .dbg_rx_state       (dbg_rx_state)
    );

endmodule
