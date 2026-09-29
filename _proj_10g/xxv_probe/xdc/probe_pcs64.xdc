#=============================================================================
# probe_pcs64.xdc -- P7b probe: board pins for probe_pcs64_top
#
# Pin provenance: identical to the P7a recipe (ku5p_p7a.xdc), which is
# hardware-verified on this board.
#   - Y1 = 100 MHz differential oscillator -> SYS_CLK_P/N = T25/U25 (bank 65)
#   - Y2 = 156.25 MHz differential oscillator -> MGT225_CLK0_P/N = V7/V6
#     (= MGTREFCLK0_225, the refclk of the quad holding both SFPs)
#   - GT serial pins are NOT constrained: the IP's own XDC carries
#     set_property LOC GTYE4_CHANNEL_X0Y4 <...>  and the ball assignment
#     follows from the channel site (X0Y4 = SFP A).
#   - SFP1_TX_DIS must be driven LOW; the measured pin is C11.
#
# XDC accepts only a Tcl SUBSET (no if/foreach/proc) -- everything here is a
# plain constraint command.  See ku5p_p7a.xdc's header for the incident.
#=============================================================================

# ---- system clock (100 MHz, core board Y1) --------------------------------
create_clock -period 10.000 -name sys_clk [get_ports sys_clk_p]
set_property PACKAGE_PIN T25 [get_ports sys_clk_p]
set_property PACKAGE_PIN U25 [get_ports sys_clk_n]
set_property IOSTANDARD DIFF_SSTL12 [get_ports {sys_clk_p sys_clk_n}]

# ---- GT reference clock (156.25 MHz, core board Y2) -----------------------
# 156.25 * 66 = 10.3125 GHz exactly.
create_clock -period 6.400 -name gtrefclk [get_ports gt_refclk_p]
set_property PACKAGE_PIN V7 [get_ports gt_refclk_p]
set_property PACKAGE_PIN V6 [get_ports gt_refclk_n]

# ---- misc board IO --------------------------------------------------------
set_property -dict {PACKAGE_PIN B11 IOSTANDARD LVCMOS33 PULLTYPE PULLDOWN} [get_ports sys_reset]
set_property -dict {PACKAGE_PIN C11 IOSTANDARD LVCMOS33} [get_ports sfp1_tx_dis]
set_property -dict {PACKAGE_PIN H9  IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN F9  IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN F10 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN K9  IOSTANDARD LVCMOS33} [get_ports {led[3]}]

# ---- GT pins: NOT constrained (see header) --------------------------------
