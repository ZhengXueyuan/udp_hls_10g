#=============================================================================
# mac_tx_min.xdc -- constraints for mac_tx_min_top (P7b MAC timing probe)
#
# THE PERIOD IS THE REAL ONE: 6.400 ns = 156.25 MHz, the tx_mii_clk rate the
# official xxv_ethernet PCS/PMA runs at on this board (the core's own OOC XDC
# says `create_clock -period 6.40 [get_ports rx_core_clk_0]`; the same QPLL
# divider feeds txoutclk).  No relaxed/"fake" period is used anywhere.
#
# EXTERNAL DELAY = 0 on every data port.  That is not an approximation of the
# real system, it IS the real system: in the integrated design the MAC's input
# FIFO is written by upstream logic on the same clock, and its XGMII output is
# captured by a register inside the PCS on the same clock.  Both boundaries are
# therefore on-chip, same-edge, zero-external-delay paths.
#
# This file is read at BOTH synthesis and implementation (OOC flow).
#=============================================================================

create_clock -period 6.400 -name clk [get_ports clk]
set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports clk]

set_input_delay -clock clk 0.0 [get_ports {s_axis_tdata[*] s_axis_tkeep[*]}]
set_input_delay -clock clk 0.0 [get_ports {s_axis_tvalid s_axis_tlast}]

set_output_delay -clock clk 0.0 [get_ports {xgmii_txd[*] xgmii_txc[*]}]
set_output_delay -clock clk 0.0 [get_ports {s_axis_tready}]
set_output_delay -clock clk 0.0 [get_ports {stat_frames[*] stat_abort[*]}]
set_output_delay -clock clk 0.0 [get_ports {stat_flush_words[*] stat_flush_done[*]}]
set_output_delay -clock clk 0.0 [get_ports {stat_tx_words[*] stat_tx_ctrl_char[*]}]
set_output_delay -clock clk 0.0 [get_ports {stat_tx_short[*] dbg_tx_last_clen[*] dbg_tx_state[*]}]
