#=============================================================================
# mac_rx_min.xdc -- constraints for mac_rx_min_top (P7b MAC timing probe)
#
# THE PERIOD IS THE REAL ONE: 6.400 ns = 156.25 MHz.  mac_rx_10g runs on the
# official core's rx_clk_out_N (= rx_core_clk_N), the CDR-RECOVERED clock.
# Its nominal rate is 156.25 MHz, which is what the core's own OOC XDC assumes
# (`create_clock -period 6.40 [get_ports rx_core_clk_0]`).  A recovered clock
# has no fixed period in reality; 6.400 ns is the design contract the whole
# 10G datapath is written against, and it is what must hold for the fabric to
# keep up with the line rate.
#
# EXTERNAL DELAY = 0 on every data port -- see mac_tx_min.xdc for why this is
# the faithful model (both boundaries are on-chip, same-clock, same-edge).
#=============================================================================

create_clock -period 6.400 -name clk [get_ports clk]
set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports clk]

set_input_delay -clock clk 0.0 [get_ports {xgmii_rxd[*] xgmii_rxc[*]}]
set_input_delay -clock clk 0.0 [get_ports {m_axis_tready}]

set_output_delay -clock clk 0.0 [get_ports {m_axis_tdata[*] m_axis_tkeep[*]}]
set_output_delay -clock clk 0.0 [get_ports {m_axis_tvalid m_axis_tlast m_axis_tuser}]
set_output_delay -clock clk 0.0 [get_ports {m_axis_tcrs m_axis_terr}]
set_output_delay -clock clk 0.0 [get_ports {stat_frames[*] stat_crc_err[*] stat_drop[*] stat_bytes[*]}]
set_output_delay -clock clk 0.0 [get_ports {stat_drop_full[*] stat_drop_partial[*]}]
set_output_delay -clock clk 0.0 [get_ports {stat_orphan_bytes[*] stat_fifo_ovf[*] dbg_stat_words_out[*]}]
set_output_delay -clock clk 0.0 [get_ports {stat_rx_words[*] stat_rx_pay_bytes[*]}]
set_output_delay -clock clk 0.0 [get_ports {stat_rx_er_words[*] stat_rx_bad_words[*]}]
set_output_delay -clock clk 0.0 [get_ports {stat_rx_frag[*] stat_rx_no_s[*] stat_rx_q[*]}]
set_output_delay -clock clk 0.0 [get_ports {stat_rx_short[*] stat_rx_long[*]}]
set_output_delay -clock clk 0.0 [get_ports {dbg_rx_last_len[*] dbg_rx_last_tlane[*] dbg_rx_state[*]}]
