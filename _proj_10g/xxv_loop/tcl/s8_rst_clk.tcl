# s8_rst_clk.tcl -- READ-ONLY: clock domain of the gt reset-done CDC blocks that
#   produce user_tx_reset_N / user_rx_reset_N, and of the stat_* synchroniser.
#   (fixes the Tcl array-vs-string bug of s6: "$c($r)" parses as an array element)
set root "D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/xxv_loop"
open_project "$root/pcs64_2ch/pcs64_2ch.xpr"
open_run impl_1
proc sec {s} { puts "\nS8 >>>>>>>>>> $s" }
proc clkof {cell} {
    set p [get_pins -quiet -of_objects $cell -filter {REF_PIN_NAME == C}]
    if {[llength $p] == 0} { return "<no C pin>" }
    return [get_clocks -quiet -of_objects [get_nets -quiet -of_objects [lindex $p 0]]]
}
sec "S8_RESET_CDC"
foreach s {tx_resetdone_0 tx_resetdone_1 rx_resetdone_0 rx_resetdone_1 rxreset_0 rxreset_1 rx_serdes_resetdone_0} {
    foreach cell [get_cells -hier -quiet -filter "NAME =~ *i_pcs64_core_cdc_sync_gt_$s*"] {
        if {![get_property IS_SEQUENTIAL $cell]} { continue }
        set nm [get_property NAME $cell]
        set rn [get_property REF_NAME $cell]
        puts "S8_CELL $nm REF=$rn CLK=[clkof $cell]"
    }
}
sec "S8_USER_RST_PRODUCERS"
foreach s {user_tx_reset_0 user_tx_reset_1 user_rx_reset_0 user_rx_reset_1} {
    foreach cell [get_cells -hier -quiet -filter "NAME =~ *${s}*"] {
        set nm [get_property NAME $cell]
        set rn [get_property REF_NAME $cell]
        set seq [get_property IS_SEQUENTIAL $cell]
        if {$seq} { puts "S8_USER $s $nm REF=$rn SEQ=1 CLK=[clkof $cell]" } \
        else      { puts "S8_USER $s $nm REF=$rn SEQ=0" }
    }
}
sec "S8_STAT_SYNC"
foreach s {stat_rx_block_lock_dclk_0 stat_rx_block_lock_dclk_1} {
    foreach cell [get_cells -hier -quiet -filter "NAME =~ *${s}*"] {
        if {![get_property IS_SEQUENTIAL $cell]} { continue }
        set nm [get_property NAME $cell]
        puts "S8_STATSYNC $nm CLK=[clkof $cell]"
    }
}
sec "S8_GT_DONE_SOURCES"
# where does tx_resetdone come from?  (the GT prim pin)
foreach prim [get_cells -hier -quiet -filter {REF_NAME =~ GTYE4_CHANNEL*}] {
    puts "S8_PRIM $prim"
    foreach pn {TXDONE RXDONE} {
        set p [get_pins -quiet -of_objects $prim -filter "REF_PIN_NAME == $pn"]
        if {[llength $p] > 0} { puts "S8_PRIMPIN $prim/$pn n=[llength $p]" }
    }
}
sec "S8 DONE"
close_project -quiet
