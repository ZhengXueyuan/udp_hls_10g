set B "D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/p7b_mac_synth"
open_checkpoint "$B/xxv_mac/pcs64_2ch/pcs64_2ch.runs/impl_1/xxv_mac_top_routed.dcp"
proc cellclk {cp} {
    set c [get_cells -quiet $cp]
    if {[llength $c]==0} { return "<missing>" }
    foreach pn {C CLK} {
        set p [get_pins -quiet "$cp/$pn"]
        if {[llength $p]} { return [get_clocks -quiet -of_objects $p] }
    }
    return "<no clk pin>"
}
puts "ENDPOINT_TXENC  = [cellclk DUT/inst/i_pcs64_top_1/i_pcs64_CORE/i_TX_TOP/i_TX_STRIPER/i_TX_ENCODER/is_valid_ctrl_reg[0]]"
puts "SRC_MACTX       = [cellclk u_mac_tx/cw_keep_reg[1]]"
puts "SRC_PCSRX       = [cellclk DUT/inst/i_pcs64_top_1/i_pcs64_CORE/i_RX_TOP/i_RX_DESTRIPER/i_CLK_COMP/dataout_reg[10]]"
puts "DST_MACRX       = [cellclk u_mac_rx/stat_crc_err_reg[28]]"
# the PCS-side XGMII rx output register feeding the MAC
set n [get_nets -hier -quiet -filter {NAME =~ *rx_mii_d_1*}]
puts "RX_MII_D_1_NETS = [llength $n]"
set drv {}
foreach nn $n {
    foreach p [get_pins -quiet -of_objects $nn -filter {DIRECTION == OUT}] {
        set cc [get_clocks -quiet -of_objects [get_pins -quiet "[get_property PARENT_CELL $p]/C"]]
        puts "   RXD1 driver cell=[get_property PARENT_CELL $p] clk=[cellclk [get_property PARENT_CELL $p]]"
        break
    }
    break
}
set n2 [get_nets -hier -quiet -filter {NAME =~ *tx_mii_d_1*}]
puts "TX_MII_D_1_NETS = [llength $n2]"
foreach nn $n2 {
    foreach p [get_pins -quiet -of_objects $nn -filter {DIRECTION == IN}] {
        set pc [get_property PARENT_CELL $p]
        if {[string match "*MULT_DRIVEN*" $pc]} { continue }
        puts "   TXD1 load cell=$pc clk=[cellclk $pc]"
        break
    }
    break
}
puts "VD4_DONE"
