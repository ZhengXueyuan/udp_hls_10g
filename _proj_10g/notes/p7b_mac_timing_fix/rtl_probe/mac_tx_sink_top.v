`timescale 1ns/1ps
// ===========================================================================
// mac_tx_sink_top.v -- P7b timing-fix probe: mac_tx_10g + XGMII CAPTURE STAGE
// ===========================================================================
// WHY THIS EXISTS (and why mac_tx_min_top alone is NOT a faithful oracle):
//   mac_tx_min_top's timing-critical destination is the OUTPUT PORT xgmii_txd.
//   An output port has ZERO destination clock delay (DCD=0) while the source
//   register carries the full clock insertion (~2.0 ns) => every reg->port path
//   gets a fake -2.003 ns budget hit, and the reported OOC WNS is dominated by
//   "cw_keep_reg -> xgmii_txd[*]" (a path that is NOT the one that fails in the
//   real design).
//
//   In the REAL design (board/wrapper_p4.v -> u_pcs) the XGMII word is captured
//   by a plain register INSIDE the official PCS, on the SAME clock net
//   (txoutclk_out[0]_1) with NO combinational logic in front of it.  The failing
//   P7b path is exactly `u_mac_tx/plen_reg[*] -> ... -> PCS capture register`.
//
//   So this probe adds ONE register stage on the XGMII outputs that models that
//   capture register.  It changes NOTHING about the MAC RTL (mac_tx_10g.v is
//   imported byte-for-byte); it only gives the timing engine a register endpoint
//   of the right kind.  Sources/targets are then comparable to the real design.
//
// THIS FILE IS A PROBE ONLY.  No MAC logic is touched.  Nothing is programmed.
// ===========================================================================
module mac_tx_sink_top (
    input  wire        clk,               // 156.25 MHz, 6.400 ns
    input  wire        rst_n,
    // ---- upstream contract (identical to the 1G mac_tx_64 port list) ----
    input  wire [63:0] s_axis_tdata,
    input  wire [7:0]  s_axis_tkeep,
    input  wire        s_axis_tvalid,
    input  wire        s_axis_tlast,
    output wire        s_axis_tready,
    // ---- XGMII (now driven from the capture registers) ----
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
    output wire [1:0]  dbg_tx_state,
    // ---- signature of the captured stream (keeps the capture regs alive and
    //      gives a cheap way to see they are not optimised into the port) ----
    output wire [31:0] cap_sig
);

    wire [63:0] xd_w;
    wire [7:0]  xc_w;

    mac_tx_10g u_dut (
        .clk               (clk),
        .rst_n             (rst_n),
        .s_axis_tdata      (s_axis_tdata),
        .s_axis_tkeep      (s_axis_tkeep),
        .s_axis_tvalid     (s_axis_tvalid),
        .s_axis_tready     (s_axis_tready),
        .s_axis_tlast      (s_axis_tlast),
        .xgmii_txd         (xd_w),
        .xgmii_txc         (xc_w),
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

    // ---- PCS-side capture register model (same clock, no logic in front) ----
    reg [63:0] cap_d;
    reg [7:0]  cap_c;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin cap_d <= 64'd0; cap_c <= 8'h00; end
        else        begin cap_d <= xd_w;  cap_c <= xc_w;  end
    end
    assign xgmii_txd = cap_d;
    assign xgmii_txc = cap_c;
    assign cap_sig   = cap_d[63:56] ^ cap_d[31:24] ^ {24'd0, cap_c};

endmodule
