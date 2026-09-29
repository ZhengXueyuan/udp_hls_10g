# ============================================================================
# s4_iface_query.tcl -- READ-ONLY interrogation of the routed xxv_loop design.
#
#   Answers, from THIS project's own netlist and generated files (not from any
#   note): the clock domain of the core's stat_* / reset outputs (P7B_SPEC U8,
#   U9, U10), the exact port names/widths used (U1), and whether the top-level IP
#   exposes a FREERUN / DRP knob (U5/FREERUN), plus the IBUFDS_GTE4 LOC question
#   behind [DRC AVAL-326].
#
#   It opens the project and the ROUTED checkpoint.  Nothing is generated,
#   nothing is programmed, no file is written outside the log.
# ============================================================================

set root "D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/xxv_loop"
set pdir "$root/pcs64_2ch"

proc sec {s} { puts "\nS4 >>>>>>>>>> $s" }
catch {set_param general.maxThreads 8}

open_project "$pdir/pcs64_2ch.xpr"
open_run impl_1

# ---------------------------------------------------------------- clock of a net
proc clkof {pin} {
    set c "<none>"
    catch {set c [get_clocks -quiet -of_objects [get_nets -quiet -of_objects $pin]]}
    return $c
}

sec "S4_STAT_CDC_CELLS"
# The IP synchronises its status outputs; the generated cell names carry both the
# signal name and the destination clock, which is direct evidence of the domain.
foreach pat {*core_cdc_sync_stat* *core_cdc_sync_gt_* *cdc_sync*stat*} {
    set cells [get_cells -hier -quiet -filter "NAME =~ $pat"]
    puts "S4_CDC_PAT <$pat> n=[llength $cells]"
    foreach c $cells { puts "S4_CDC_CELL $c" }
}

sec "S4_STAT_NET_DOMAINS"
# For each stat_* output of the core, print the clock of the net it drives.
foreach sig {stat_rx_block_lock_0 stat_rx_block_lock_1 stat_rx_status_0 \
             stat_rx_hi_ber_0 stat_rx_local_fault_0 stat_rx_framing_err_0 \
             stat_rx_framing_err_valid_0 stat_rx_valid_ctrl_code_0 \
             stat_rx_bad_code_0 stat_rx_bad_code_valid_0 stat_rx_error_0 \
             stat_rx_error_valid_0 stat_rx_fifo_error_0 stat_tx_local_fault_0 \
             stat_rx_block_lock_1 stat_rx_error_1 stat_rx_error_valid_1} {
    set pins [get_pins -quiet -hier -filter "NAME =~ */DUT/$sig"]
    if {[llength $pins] == 0} { puts "S4_SIG $sig <no pin found>"; continue }
    set p [lindex $pins 0]
    set net [get_nets -quiet -of_objects $p]
    puts "S4_SIG $sig pin=$p net=$net clocks=[get_clocks -quiet -of_objects $net]"
}

sec "S4_RESET_DOMAINS"
foreach sig {user_rx_reset_0 user_tx_reset_0 user_rx_reset_1 user_tx_reset_1 \
             rx_reset_0 tx_reset_0 rx_reset_1 tx_reset_1} {
    set pins [get_pins -quiet -hier -filter "NAME =~ */DUT/$sig"]
    puts "S4_RST $sig pins_n=[llength $pins]"
    foreach p $pins {
        set net [get_nets -quiet -of_objects $p]
        set drv [get_cells -quiet -of_objects $net -filter {IS_SEQUENTIAL}]
        puts "S4_RST $sig pin=$p net=$net clocks=[get_clocks -quiet -of_objects $net] drivers=$drv"
    }
    # who consumes it (in our own wrapper)
    set loads [get_pins -quiet -hier -filter "NAME =~ *$sig*"]
    puts "S4_RST $sig consumers_n=[llength $loads]"
}
# and the registers that our own wrapper clocks with those resets
foreach cell {u_chk0 u_chk1} {
    set c [get_cells -hier -quiet -filter "NAME =~ *$cell*"]
    puts "S4_OURS $cell cells=[llength $c]"
}
foreach p [get_pins -quiet -hier -filter {NAME =~ *u_chk1/o_words_reg*/C}] {
    set net [get_nets -quiet -of_objects $p]
    puts "S4_OURS u_chk1_clock pin=$p clocks=[get_clocks -quiet -of_objects $net]"
}

sec "S4_TOP_PROPS"
set ip [get_ips pcs64]
foreach p [lsort [list_property $ip]] {
    if {[string match -nocase "*FREERUN*" $p] || [string match -nocase "*DRP*" $p] ||
        [string match -nocase "*REFCLK*" $p] || [string match -nocase "*NUM_OF_CORES*" $p] ||
        [string match -nocase "*LANE*GT_LOC*" $p]} {
        set v "<err>"; catch {set v [get_property $p $ip]}
        set e "<err>"; catch {set e [get_property -quiet $p $ip]}
        puts "S4_TPROP $p = $v"
    }
}
puts "S4_TPROP_ALL_N = [llength [list_property $ip]]"

sec "S4_IBUFDS_LOC"
# Is there an IBUFDS_GTE4 LOC anywhere in the generated XDCs?  (AVAL-326)
foreach f [concat [glob -nocomplain "$pdir/pcs64_2ch.gen/sources_1/ip/pcs64/synth/*.xdc"] \
                  [glob -nocomplain "$pdir/pcs64_2ch.gen/sources_1/ip/pcs64/ip_0/synth/*.xdc"] \
                  [glob -nocomplain "$pdir/pcs64_2ch.gen/sources_1/ip/pcs64/ip_1/synth/*.xdc"]] {
    set fh [open $f r]
    set n 0
    while {[gets $fh line] >= 0} {
        incr n
        if {[string first "IBUFDS" $line] >= 0 || [string first "LOC" $line] >= 0} {
            puts "S4_XDCLINE [file tail $f]:$n $line"
        }
    }
    close $fh
}
# and what the placer actually did with the refclk buffer
foreach ref {IBUFDS_GTE4} {
    set cs [get_cells -hier -quiet -filter "REF_NAME =~ $ref*"]
    puts "S4_IBUFDS_CELLS n=[llength $cs]"
    foreach c $cs {
        set loc "<none>"; catch {set loc [get_property LOC $c]}
        puts "S4_IBUFDS_CELL $c LOC=$loc"
    }
}

sec "S4_PORT_TABLE"
# the ports our wrapper actually connects, with directions and widths, read from
# the elaborated netlist (authoritative for THIS build)
set ipc [get_cells -quiet -hier -filter {NAME =~ */DUT}]
puts "S4_DUT_CELL $ipc"
foreach p [lsort [get_pins -quiet -of_objects $ipc]] {
    set nm [get_property NAME $p]
    set dir [get_property DIRECTION $p]
    set w 1 ; catch {set w [get_property SIZE $p]}
    puts "S4_PORT $nm $dir $w"
}

sec "S4 DONE"
close_project -quiet
