#=============================================================================
# ku5p_p7a.xdc -- XCKU5P Mini, P7a pin/clock constraints (SYNTHESIS + IMPL)
#=============================================================================
#
#  Pin provenance: every pin here is MEASURED or schematic-derived, not copied
#  from a vendor XDC. The two vendor files disagree with the hardware on the SFP
#  control pins; the iBERT three-state experiment settled it (P7A_SPEC.md s.6).
#
#  ⚠ XDC files accept only a SUBSET of Tcl. The first P7a build put guarded
#    blocks (if / foreach / puts) in this file and Vivado answered
#      [Designutils 20-1307] Command 'if' is not supported in the xdc
#                            constraint file
#    for each one -- the blocks were SKIPPED and the build still reported
#    success. Everything that needs a lookup against the elaborated design now
#    lives in ku5p_p7a_impl.xdc (implementation only) and contains nothing but
#    plain constraint commands. This file is pure create_clock/set_property.
#=============================================================================

# ---------------------------------------------------------------- fabrication clock
# Core-board Y1 = SG7050VAN-100.000000M differential oscillator, SYS_CLK_P/N =
# T25/U25 (bank 65, VCCO 1.2 V). IOSTANDARD DIFF_SSTL12: the board AC-couples
# the oscillator and biases it with 1k/1k to VDD1.2 => VICM = 0.600 V = VCCO/2,
# the DIFF_SSTL12 typical point and BELOW the DIFF_POD12 range the vendor XDC
# names. Adjudicated and probed during P6b
# (board/ku5p_probe/clkgen_p6b/README.md) and used by the frozen P6b bitstream,
# so it is the one hardware-verified option.
create_clock -period 10.000 -name sys_clk [get_ports sys_clk_p]
set_property PACKAGE_PIN T25 [get_ports sys_clk_p]
set_property PACKAGE_PIN U25 [get_ports sys_clk_n]
set_property IOSTANDARD DIFF_SSTL12 [get_ports {sys_clk_p sys_clk_n}]

# clk_gen_p6b's MMCM (100 MHz in, VCO 1250 MHz, /8) produces clk_obs =
# 156.25 MHz; Vivado derives that clock automatically from CLKIN1_PERIOD and the
# MMCM parameters, so NO create_generated_clock is written here (writing one as
# well produced "two clocks with the same period" warnings in P6b -- see
# board/ku5p_p6b_sysclk.xdc). Readback confirms: g_hw.clk_out0 period = 6.400 ns.

# ---------------------------------------------------------------- GT reference clock
# Y2 (silkscreen) = 156.25 MHz differential oscillator on the core board, net
# MGT225_CLK0_P/N -> balls V7/V6 = MGTREFCLK0_225.
# 156.25 * 66 = 10.3125 GHz exactly; the factory 100 MHz part cannot reach
# 10GBASE-R at all (100 * 103 = 10.3 GHz is not a standard rate).
# Naming trap: "Y2" inside a vendor XDC is ball Y2 = SFP A RX+, a different
# thing entirely. The port name is the wizard's own -- mgtrefclk0_x0y1_p, where
# x0y1 is the COMMON site number, not a channel number.
create_clock -period 6.400 -name gtrefclk0 [get_ports mgtrefclk0_x0y1_p]
set_property PACKAGE_PIN V7 [get_ports mgtrefclk0_x0y1_p]
set_property PACKAGE_PIN V6 [get_ports mgtrefclk0_x0y1_n]

# GT serial pins are deliberately NOT constrained here: the wizard's own XDC
# carries
#   set_property LOC GTYE4_CHANNEL_X0Y4 <...gen_gtye4_channel_inst[0]...>
#   set_property LOC GTYE4_CHANNEL_X0Y5 <...gen_gtye4_channel_inst[1]...>
# and the serial ball assignment follows from the channel site.
#   X0Y4 = SFP A, X0Y5 = SFP B  (iBERT loopback measurement, m2_loopback.tcl)

# ---------------------------------------------------------------- SFP control
# TX_DIS is active-high disable and must be driven LOW: a 10k pull-up otherwise
# keeps it asserted and BOTH modules never emit -- a dark link that looks
# exactly like "this board cannot do 10G". Pin map is the MEASURED one:
#   v1 B11/C9 low only -> all four GT lanes dark (RX_BER 0.50)
#   v2 all four low    -> link up, unterminated lanes still 0.49 (control)
#   v3 C11/D9 low only -> link up
#   => TX_DIS on C11 (SFP1) / D9 (SFP2); RX_LOS on B11 / C9.
# Both vendor XDCs swap each pair.
set_property -dict {PACKAGE_PIN C11 IOSTANDARD LVCMOS33} [get_ports sfp1_tx_dis]
set_property -dict {PACKAGE_PIN D9  IOSTANDARD LVCMOS33} [get_ports sfp2_tx_dis]
# RX_LOS is an open-collector module output: pull up so an empty cage reads
# "loss of signal" instead of floating.
set_property -dict {PACKAGE_PIN B11 IOSTANDARD LVCMOS33 PULLTYPE PULLUP} [get_ports sfp1_rx_los]
set_property -dict {PACKAGE_PIN C9  IOSTANDARD LVCMOS33 PULLTYPE PULLUP} [get_ports sfp2_rx_los]
