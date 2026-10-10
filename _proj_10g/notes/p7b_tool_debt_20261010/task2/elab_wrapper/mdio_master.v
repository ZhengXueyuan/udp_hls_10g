// mdio_master.v -- IEEE 802.3 clause 22 MDIO master, one transaction per start.
//
// The frame is 64 bits, MSB first:
//
//   [63:32] preamble  32'hFFFFFFFF
//   [31:30] ST        2'b01
//   [29:28] OP        2'b10 read / 2'b01 write
//   [27:23] PHYAD
//   [22:18] REGAD
//   [17:16] TA        2'b10 write / released (Z) for read
//   [15:0]  DATA      write: driven by us; read: driven by the PHY
//
// Read turnaround: we drive bits 0..45, release MDIO from bit 46. The PHY then
// drives 0 on the first TA bit and the 16 data bits after it, so sampling bits
// 47..63 yields 17 samples of which the first is the TA zero -- shifting them
// into a 64-bit register and taking the low 16 leaves exactly DATA[15:0].
//
// MDC idles low. MDIO changes on the falling edge and is sampled on the rising
// edge, which is what the half-period phase machine below implements.
//
// 2026-10-10 -- two latent traps made observable (both are ADD-ONLY: no existing
// output changes value, and the frame timing is bit-identical):
//   (1) `start` while busy is still ignored, but no longer silently: the sticky
//       flag `stat_start_lost` records it. Without that flag a host that pulses
//       start mid-frame and then polls `done_sticky` reads the PREVIOUS
//       transaction's result (done_sticky is only cleared by an accepted start).
//   (2) the DIV parameter must be 1..65536; anything else used to be silently
//       truncated by `DIV[15:0]` (DIV=65537 -> 1 -> MDC 50MHz). It is now
//       clamped to the slow end and signalled on `param_bad`.

`timescale 1ns / 1ps

module mdio_master #(
    parameter integer DIV = 25          // MDC half-period in clk cycles (100MHz/25 -> 2MHz)
)(
    input  wire        clk,
    input  wire        rstn,
    // control
    input  wire        start,           // 1-cycle pulse; ignored while busy
    input  wire        op,              // 0 = read, 1 = write
    input  wire [4:0]  phyad,
    input  wire [4:0]  regad,
    input  wire [15:0] wr_data,
    output reg  [15:0] rd_data,
    output reg         done,            // 1-cycle pulse at end of frame
    output reg         done_sticky,     // held until the next start (for VIO polling)
    output reg         busy,
    // PHY side
    output reg         mdc,
    output reg         mdio_o,
    output reg         mdio_t,          // 1 = release (high-Z)
    input  wire        mdio_i,
    // ---- appended 2026-10-10 (pure additions; nothing above changed value) ----
    output wire        param_bad,       // 1 = DIV out of range, clamped (static)
    output reg         stat_start_lost  // sticky: a start arrived while busy (dropped)
);

    // ---- DIV range guard (2026-10-10) ---------------------------------------
    // div_cnt is 16 bits wide, so the representable MDC half-periods are
    // 1..65536 clk. A DIV outside that range used to be truncated SILENTLY by
    // `DIV[15:0]`: DIV=65537 became 1, i.e. MDC = 50MHz at a 100MHz clk --
    // 65537x the rate that was asked for, and 20x the 2.5MHz clause-22 limit.
    // Choose the clamp direction deliberately: an over-SLOW MDC is harmless,
    // an over-fast one is not, so an illegal DIV saturates to the *slow* end.
    // For any legal DIV (1..65536) DIV_SAFE == DIV, so the tick expression
    // below is bit-identical to the pre-guard one; the only difference for an
    // illegal DIV is that it now runs slow AND raises param_bad (visible)
    // instead of running fast in silence. param_bad is a static (constant)
    // signal and is consumed by tb_mdio_master.v's DIV-guard arm.
    localparam integer DIV_MAX  = 65536;
    localparam integer DIV_SAFE = (DIV < 1) ? DIV_MAX
                                            : ((DIV > DIV_MAX) ? DIV_MAX : DIV);
    localparam        PARAM_BAD = (DIV < 1) || (DIV > DIV_MAX);

    assign param_bad = PARAM_BAD;

    reg [63:0] sh;
    reg [63:0] rd_sh;
    reg [5:0]  bit_idx;
    reg        phase;                   // 0 = MDC low, 1 = MDC high
    reg [15:0] div_cnt;
    reg        is_read;

    wire       tick = (div_cnt == DIV_SAFE[15:0] - 16'd1);

    always @(posedge clk) begin
        done <= 1'b0;

        if (!rstn) begin
            busy        <= 1'b0;
            mdc         <= 1'b0;
            mdio_o      <= 1'b1;
            mdio_t      <= 1'b1;
            bit_idx     <= 6'd0;
            phase       <= 1'b0;
            div_cnt     <= 16'd0;
            sh          <= 64'd0;
            rd_sh       <= 64'd0;
            rd_data     <= 16'd0;
            done_sticky <= 1'b0;
            is_read     <= 1'b0;
        end else if (!busy) begin
            mdc    <= 1'b0;
            mdio_t <= 1'b1;
            if (start) begin
                busy        <= 1'b1;
                is_read     <= ~op;
                sh          <= {32'hFFFFFFFF, 2'b01,
                                op ? 2'b01 : 2'b10, phyad, regad,
                                op ? 2'b10 : 2'b00, wr_data};
                rd_sh       <= 64'd0;
                bit_idx     <= 6'd0;
                phase       <= 1'b0;
                div_cnt     <= 16'd0;
                mdio_o      <= 1'b1;    // first preamble bit
                mdio_t      <= 1'b0;
                done_sticky <= 1'b0;
                rd_data     <= 16'd0;
            end
        end else if (tick) begin
            div_cnt <= 16'd0;

            if (!phase) begin
                // rising edge: the PHY samples our bit; we sample the PHY's
                mdc   <= 1'b1;
                phase <= 1'b1;
                if (is_read && bit_idx >= 6'd47)
                    rd_sh <= {rd_sh[62:0], mdio_i};
            end else begin
                // falling edge: change data for the next bit time
                mdc   <= 1'b0;
                phase <= 1'b0;
                if (bit_idx == 6'd63) begin
                    busy        <= 1'b0;
                    done        <= 1'b1;
                    done_sticky <= 1'b1;
                    mdio_t      <= 1'b1;
                    rd_data     <= rd_sh[15:0];
                end else begin
                    bit_idx <= bit_idx + 6'd1;
                    sh      <= {sh[62:0], 1'b0};
                    mdio_o  <= sh[62];
                    mdio_t  <= is_read && (bit_idx >= 6'd45);
                end
            end
        end else begin
            div_cnt <= div_cnt + 16'd1;
        end
    end

    // 2026-10-10: make the dropped start observable. The FSM above really does
    // ignore `start` while busy -- that contract is unchanged -- but before this
    // flag the ignore was invisible, and a host that pulses start mid-frame and
    // then reads done_sticky gets the PREVIOUS transaction's result. Semantics:
    // 1 = at least one start has been dropped since the last ACCEPTED start;
    // cleared by the next accepted start (same instant done_sticky is cleared).
    // Deliberately a separate always block: it cannot shift the frame timing by
    // even one clk (a branch inside the FSM above would have).
    always @(posedge clk) begin
        if (!rstn)               stat_start_lost <= 1'b0;
        else if (!busy && start) stat_start_lost <= 1'b0;   // accepted -> clear
        else if (busy && start)  stat_start_lost <= 1'b1;   // dropped  -> sticky
    end

endmodule
