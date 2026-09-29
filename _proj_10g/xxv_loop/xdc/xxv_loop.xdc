#=============================================================================
# xxv_loop.xdc -- P7b gate 1: pins and clocks for xxv_loop_top
#
# Pin provenance: every pin below is either MEASURED on this board or comes from
# the P7a recipe (ku5p_p7a.xdc), which is hardware-verified.  Nothing is copied
# from a vendor XDC: both vendor XDCs swap the SFP control pair (settled by the
# 2026-09-27 three-state experiment), so:
#     SFP1_TX_DIS = C11   SFP1_RX_LOS = B11
#     SFP2_TX_DIS = D9    SFP2_RX_LOS = C9
#
# GT serial pins are deliberately NOT constrained here.  The IP's own XDC
# carries   set_property LOC GTYE4_CHANNEL_X0Y4 / _X0Y5   for the two channels
# (verified in the generated ip_0/synth/pcs64_gt.xdc:57 and ip_1/...:57) and the
# serial ball assignment follows from the channel site:
#     X0Y4 = SFP A = J7      X0Y5 = SFP B = J8     (iBERT loopback measurement)
#
# XDC accepts only a Tcl SUBSET (no if/foreach/proc): everything here is a plain
# constraint command.  Anything that needs an elaborated design lives in
# xxv_loop_impl.xdc, which is marked used_in_synthesis false.
#=============================================================================

# ---- 100 MHz fabrication clock: core board Y1 -> SYS_CLK_P/N = T25/U25 -------
# Bank 65, VCCO 1.2 V.  IOSTANDARD DIFF_SSTL12: the oscillator is AC coupled and
# biased 1k/1k to VDD1.2, so VICM = 0.600 V = VCCO/2 -- the DIFF_SSTL12 typical
# point, and the option the frozen P6b bitstream already runs on this board.
# The clock is named dclk because that is the name the core knows it by
# (the IP's OOC XDC carries create_clock -period 10.000 [get_ports dclk]).
create_clock -period 10.000 -name dclk [get_ports sys_clk_p]
set_property PACKAGE_PIN T25 [get_ports sys_clk_p]
set_property PACKAGE_PIN U25 [get_ports sys_clk_n]
set_property IOSTANDARD DIFF_SSTL12 [get_ports {sys_clk_p sys_clk_n}]

# ---- GT reference clock: core board Y2 = 156.25 MHz -> MGTREFCLK0_225 --------
# balls V7/V6.  156.25 * 66 = 10.3125 GHz exactly, which is what makes
# 10GBASE-R possible on this board at all.  The IP's own XDC also declares this
# clock on the port of the same name; redeclaring it here REPLACES that one with
# a named copy (measured on the reconnaissance probe:
# "[runme.log:45] New: create_clock -period 6.400 -name gtrefclk [get_ports
#  gt_refclk_p] ... Previous: ... pcs64.xdc:65"), so there is exactly one clock
# on the port.
create_clock -period 6.400 -name gtrefclk0 [get_ports gt_refclk_p]
set_property PACKAGE_PIN V7 [get_ports gt_refclk_p]
set_property PACKAGE_PIN V6 [get_ports gt_refclk_n]

# ---- SFP control ------------------------------------------------------------
# TX_DIS is active-high disable with a 10k pull-up: floating = transmitter off =
# a dark link that looks exactly like "this board cannot do 10G".  The RTL
# drives both low unless the VIO raises one (negative control).
set_property -dict {PACKAGE_PIN C11 IOSTANDARD LVCMOS33} [get_ports sfp1_tx_dis]
set_property -dict {PACKAGE_PIN D9  IOSTANDARD LVCMOS33} [get_ports sfp2_tx_dis]
# RX_LOS is an open-collector module output: pull up so an empty cage reads
# "loss of signal" instead of floating.
set_property -dict {PACKAGE_PIN B11 IOSTANDARD LVCMOS33 PULLTYPE PULLUP} [get_ports sfp1_rx_los]
set_property -dict {PACKAGE_PIN C9  IOSTANDARD LVCMOS33 PULLTYPE PULLUP} [get_ports sfp2_rx_los]

# ---- LEDs -------------------------------------------------------------------
# led[0] = H9 is the vendor's Aurora_LED (free pin, no other function).
# led[1..3] = F9/F10/K9 are the RTL8211E RGMII TXD pins.  This design does not
# instantiate the 1G Ethernet stack, does not drive eth_txc, and leaves eth_rstn
# alone, so the PHY's RGMII transmit interface is never clocked and ignores
# these lines.  They are used only because a hardware-side indicator is worth
# having on a first bring-up; the VIO is the real observation channel.
set_property -dict {PACKAGE_PIN H9  IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN F9  IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN F10 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN K9  IOSTANDARD LVCMOS33} [get_ports {led[3]}]
