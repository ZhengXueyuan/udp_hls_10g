# s6_stat_cells.tcl -- READ-ONLY: find the leaf cells that PRODUCE each stat_*
# net inside the core, and read the clock of the sequential ones.
set root "D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/xxv_loop"
open_project "$root/pcs64_2ch/pcs64_2ch.xpr"
open_run impl_1
proc sec {s} { puts "\nS6 >>>>>>>>>> $s" }
proc clkofpin {p} { return [get_clocks -quiet -of_objects [get_nets -quiet -of_objects $p]] }
sec "S6_STAT_LEAF"
foreach s {stat_rx_status_0 stat_rx_hi_ber_0 stat_rx_local_fault_0 stat_rx_framing_err_0 \
           stat_rx_framing_err_valid_0 stat_rx_valid_ctrl_code_0 stat_rx_bad_code_0 \
           stat_rx_bad_code_valid_0 stat_rx_error_valid_0 stat_rx_fifo_error_0 \
           stat_tx_local_fault_0 stat_rx_block_lock_0} {
    set cs [get_cells -hier -quiet -filter "NAME =~ *${s}*"]
    set seq {}
    foreach c $cs {
        if {[get_property IS_SEQUENTIAL $c]} { lappend seq "$c([get_property REF_NAME $c],clk=[clkofpin $c/C])" }
    }
    puts "S6_STAT $s ncells=[llength $cs] seq=$seq"
}
sec "S6_RESET_CELLS"
foreach s {user_rx_reset_0 user_tx_reset_0 user_rx_reset_1 user_tx_reset_1} {
    set cs [get_cells -hier -quiet -filter "NAME =~ *${s}*"]
    set info {}
    foreach c $cs {
        set r [get_property REF_NAME $c]
        if {[get_property IS_SEQUENTIAL $c]} { lappend info "$c($r,clk=[clkofpin $c/C])" } else { lappend info "$c($r)" }
    }
    puts "S6_RST $s n=[llength $cs] $info"
}
sec "S6_TXRESETDONE_BLOCK"
foreach c [get_cells -hier -quiet -filter {NAME =~ *i_pcs64_core_cdc_sync_gt_tx_resetdone_0*}] {
    if {[get_property IS_SEQUENTIAL $c]} { puts "S6_TRD $c ([get_property REF_NAME $c]) clk=[clkofpin $c/C]" }
}
foreach c [get_cells -hier -quiet -filter {NAME =~ *i_pcs64_core_cdc_sync_gt_rx_resetdone_0*}] {
    if {[get_property IS_SEQUENTIAL $c]} { puts "S6_RRD $c ([get_property REF_NAME $c]) clk=[clkofpin $c/C]" }
}
sec "S6_RXRESET_BLOCK"
foreach c [get_cells -hier -quiet -filter {NAME =~ *i_pcs64_core_cdc_sync_gt_rxreset_0*}] {
    if {[get_property IS_SEQUENTIAL $c]} { puts "S6_RXR $c ([get_property REF_NAME $c]) clk=[clkofpin $c/C]" }
}
sec "S6 XCI_XDC_CDC"
close_project -quiet
