//======================================================================
// p7a_tgl_sync.v -- P7a: toggle in, one-cycle pulse out, across clock domains
//======================================================================
//
//  Why a toggle and not a pulse
//  ----------------------------
//  A one-cycle pulse generated in the observation domain (156.25 MHz from the
//  MMCM) can be MISSED by the payload domain (156.25 MHz recovered clock from
//  the GT): the two clocks are asynchronous and of the same nominal period, so
//  the receiving flop's setup window can land anywhere inside the pulse. A
//  toggle changes level and stays there until the receiver has certainly seen
//  it, which is the textbook single-bit CDC for an event.
//
//  This is the "自加边沿检测" required for every pulse-style VIO control: a JTAG
//  commit is tens of milliseconds while one transaction here is ~6 ns, so the
//  host always writes a level (0 -> 1 -> 0) and the level change is what is
//  turned into a pulse, exactly once.
//
//  Structure: 3-flop synchronizer (ASYNC_REG, for placement clustering) plus
//  one more flop; pulse_out = sr[2] ^ sr[2]_delayed -> exactly one clk per
//  input toggle.
//
//  Limits (documented, not hidden)
//  -------------------------------
//  * Two toggles closer together than ~3 clk cycles are merged into one pulse.
//    The host side is milliseconds apart, so this never binds in P7a.
//  * rst is synchronous and active high. A toggle in flight while rst is
//    asserted is dropped; callers must (re)start from a known state before
//    relying on the next toggle (P7a clears the whole measurement on restart).
//  * INIT sets the power-up value of every stage. If tgl_in already differs from
//    INIT at release, ONE spurious pulse is produced at startup. Harmless for
//    snapshot/clear/slip (all idempotent), stated so nobody has to guess.
//======================================================================

`timescale 1ns / 1ps

module p7a_tgl_sync #(
    parameter integer INIT = 1'b0
)(
    input  wire clk,
    input  wire rst,
    input  wire tgl_in,
    output wire pulse_out
);

    (* ASYNC_REG = "TRUE" *) reg [2:0] sr    = {3{INIT}};
                             reg       tgl_r = INIT;

    always @(posedge clk) begin
        if (rst) begin
            sr    <= {3{INIT}};
            tgl_r <= INIT;
        end else begin
            sr[0] <= tgl_in;
            sr[1] <= sr[0];
            sr[2] <= sr[1];
            tgl_r <= sr[2];
        end
    end

    assign pulse_out = sr[2] ^ tgl_r;

endmodule
