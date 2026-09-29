# ============================================================================
# s5_domain_query.tcl -- READ-ONLY: which clock domain does each core output
#   actually live in, as routed?  (P7B_SPEC U8/U9/U10, asked by the coordinator)
#
#   Method (no notes, no inference from names alone):
#     * take the TOP-LEVEL net with that name (my wrapper declares exactly one);
#     * find its source pin (DIRECTION == OUT) and that pin's clock pin;
#     * for the IP-internal synchronisers, also print the clock of the
#       destination flop (s_out_d2_cdc_to_reg/C) -- that IS the output domain.
#   Nothing is generated; the routed checkpoint is only read.
# ============================================================================

set root "D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/xxv_loop"
set pdir "$root/pcs64_2ch"

proc sec {s} { puts "\nS5 >>>>>>>>>> $s" }
catch {set_param general.maxThreads 8}
open_project "$pdir/pcs64_2ch.xpr"
open_run impl_1

proc clkofcell {cell pinname} {
    set p [get_pins -quiet -of_objects $cell -filter "REF_PIN_NAME == $pinname"]
    if {[llength $p] == 0} { return "<no $pinname>" }
    set n [get_nets -quiet -of_objects [lindex $p 0]]
    return [get_clocks -quiet -of_objects $n]
}

proc report_net {nm} {
    set nets [get_nets -quiet -hier -filter "NAME =~ $nm"]
    if {[llength $nets] == 0} { puts "S5_NET $nm <absent>"; return }
    foreach n $nets {
        set outs [get_pins -quiet -of_objects $n -filter {DIRECTION == OUT}]
        set src  "<none>"
        set sclk "<none>"
        foreach o $outs {
            set c [get_cells -quiet -of_objects $o]
            if {$c eq ""} { continue }
            set cn [get_property NAME $c]
            set cp [get_property REF_NAME $c]
            if {[get_property IS_SEQUENTIAL $c]} {
                set sclk [clkofcell $c C]
            } else {
                set sclk "<comb: $cp>"
            }
            set src "$cn ($cp)"
            break
        }
        set loads [get_pins -quiet -of_objects $n -filter {DIRECTION == IN}]
        set lclks {}
        foreach l $loads {
            set c [get_cells -quiet -of_objects $l]
            if {$c eq "" || ![get_property IS_SEQUENTIAL $c]} { continue }
            foreach k [clkofcell $c C] { if {[lsearch $lclks $k] < 0} { lappend lclks $k } }
        }
        puts "S5_NET $n src=$src srccLK=$sclk loadclks=$lclks nloads=[llength $loads]"
    }
}

sec "S5_STAT_OUTPUTS"
foreach s {stat_rx_block_lock_0 stat_rx_block_lock_1 stat_rx_status_0 stat_rx_status_1 \
           stat_rx_hi_ber_0 stat_rx_hi_ber_1 stat_rx_local_fault_0 stat_rx_local_fault_1 \
           stat_rx_framing_err_0 stat_rx_framing_err_valid_0 stat_rx_valid_ctrl_code_0 \
           stat_rx_bad_code_0 stat_rx_bad_code_valid_0 stat_rx_error_0 stat_rx_error_valid_0 \
           stat_rx_fifo_error_0 stat_tx_local_fault_0 stat_rx_error_1 stat_rx_error_valid_1} {
    report_net $s
}

sec "S5_RESET_OUTPUTS"
foreach s {user_rx_reset_0 user_tx_reset_0 user_rx_reset_1 user_tx_reset_1} {
    report_net $s
}

sec "S5_RESET_INPUTS"
foreach s {rx_reset_0 tx_reset_0 rx_reset_1 tx_reset_1} {
    report_net $s
}

sec "S5_CDC_DEST_CLOCKS"
foreach c [get_cells -hier -quiet -filter {NAME =~ *core_cdc_sync_stat*}] {
    set cn [get_property NAME $c]
    if {![get_property IS_SEQUENTIAL $c]} { continue }
    puts "S5_CDC $cn destclk=[clkofcell $c C]"
}
foreach c [get_cells -hier -quiet -filter {NAME =~ *core_cdc_sync_gt_tx_resetdone*}] {
    set cn [get_property NAME $c]
    if {[string match "*user_tx_reset*" $cn]} {
        puts "S5_CDC_USER_TX_RST $cn destclk=[clkofcell $c C]"
    }
}

sec "S5_XGMII_CLK_NETS"
foreach s {tx_mii_clk_0 tx_mii_clk_1 rx_clk_out_0 rx_clk_out_1 rx_core_clk_0 rx_core_clk_1} {
    report_net $s
}

sec "S5_COUNTER_CLOCKS"
# my own counters: confirm which clock each one is on (the answer to "can the
# next MAC put them in one snapshot?")
foreach pfx {u_chk0 o_words_reg u_chk1 o_words_reg} { }
foreach c [get_cells -hier -quiet -filter {NAME =~ *u_chk0/o_frames_reg*}] {
    puts "S5_OURS $c clk=[clkofcell $c C]"
    break
}
foreach c [get_cells -hier -quiet -filter {NAME =~ *u_snap_rx1/hold_reg*}] {
    puts "S5_OURS $c clk=[clkofcell $c C]"
    break
}
foreach c [get_cells -hier -quiet -filter {NAME =~ *u_snap_dclk/hold_reg*}] {
    puts "S5_OURS $c clk=[clkofcell $c C]"
    break
}
foreach c [get_cells -hier -quiet -filter {NAME =~ *tx0_free_reg*} ] {
    puts "S5_OURS $c clk=[clkofcell $c C]"
    break
}
foreach c [get_cells -hier -quiet -filter {NAME =~ *rx1_free_reg*} ] {
    puts "S5_OURS $c clk=[clkofcell $c C]"
    break
}
foreach c [get_cells -hier -quiet -filter {NAME =~ *dclk_free_reg*} ] {
    puts "S5_OURS $c clk=[clkofcell $c C]"
    break
}

sec "S5 DONE"
close_project -quiet
