// Negative-control shim (2026-10-10): instantiate the UNMODIFIED pre-guard
// mdio_master (imported verbatim, only the module name gains a _legacy suffix),
// and model the two observables the old core does not have as constants:
// a signal that does not exist cannot report anything, so it reads 0.
module mdio_master #(
    parameter integer DIV = 25
)(
    input  wire        clk,
    input  wire        rstn,
    input  wire        start,
    input  wire        op,
    input  wire [4:0]  phyad,
    input  wire [4:0]  regad,
    input  wire [15:0] wr_data,
    output wire [15:0] rd_data,
    output wire        done,
    output wire        done_sticky,
    output wire        busy,
    output wire        mdc,
    output wire        mdio_o,
    output wire        mdio_t,
    input  wire        mdio_i,
    output wire        param_bad,
    output wire        stat_start_lost
);
    mdio_master_legacy #(.DIV(DIV)) u_legacy (
        .clk (clk), .rstn (rstn), .start (start), .op (op),
        .phyad (phyad), .regad (regad), .wr_data (wr_data),
        .rd_data (rd_data), .done (done), .done_sticky (done_sticky),
        .busy (busy), .mdc (mdc), .mdio_o (mdio_o), .mdio_t (mdio_t),
        .mdio_i (mdio_i)
    );
    assign param_bad       = 1'b0;
    assign stat_start_lost = 1'b0;
endmodule
