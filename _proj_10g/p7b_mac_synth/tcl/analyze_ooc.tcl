# ============================================================================
# analyze_ooc.tcl -- classify the hold failures of the two MAC-only OOC runs
#
#   The question this answers: are the failing hold endpoints REAL
#   register-to-register violations, or artefacts of the out-of-context port
#   model (an input port has Source Clock Delay = 0 by construction, while the
#   destination register's clock has the full BUFG + net insertion delay, so
#   every input-port-to-register hold check fails by roughly that insertion
#   delay no matter what the logic looks like)?
#
#   Method: open each routed checkpoint and classify every FAILING hold path by
#   whether its start point is a top-level PORT or an internal register.
#   A real defect shows up as a path whose start point is a register.
# ============================================================================

set B "D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/p7b_mac_synth"
catch {set_param general.maxThreads 8}

proc analyze {name dcp top} {
    puts "\n>>>>>>>>>> ANALYZE $name"
    open_checkpoint $dcp
    puts "${name}_OPENED top=[get_property top [current_design]]"

    set clks [get_clocks]
    puts "${name}_CLOCKS = $clks"
    foreach c $clks { puts "${name}_CLK $c period=[get_property PERIOD $c]" }

    set tsr "$::B/reports/${name}_ooc_timing_summary.rpt"
    report_timing_summary -file $tsr -warn_on_violation
    puts "${name}_TSR = $tsr"

    set ps [get_timing_paths -delay_type min -max_paths 400 -nworst 1 -sort_by slack]
    set nfail 0 ; set nport 0 ; set nreg 0 ; set worst_reg "NONE"
    set worst_port "NONE"
    foreach p $ps {
        if {[get_property SLACK $p] >= 0} { continue }
        incr nfail
        set sp [get_property STARTPOINT_PIN $p]
        if {[llength [get_ports -quiet $sp]] > 0} {
            incr nport
            if {$worst_port eq "NONE"} {
                set worst_port [format "slack=%.3f sp=%s ep=%s levels=%s logic=%.3f net=%.3f" \
                    [get_property SLACK $p] $sp [get_property ENDPOINT_PIN $p] \
                    [get_property LOGIC_LEVELS $p] [get_property DATAPATH_LOGIC_DELAY $p] \
                    [get_property DATAPATH_NET_DELAY $p]]
                set worst_port $worst_port
            }
        } else {
            incr nreg
            if {$worst_reg eq "NONE"} {
                set worst_reg [format "slack=%.3f sp=%s ep=%s levels=%s logic=%.3f net=%.3f" \
                    [get_property SLACK $p] $sp [get_property ENDPOINT_PIN $p] \
                    [get_property LOGIC_LEVELS $p] [get_property DATAPATH_LOGIC_DELAY $p] \
                    [get_property DATAPATH_NET_DELAY $p]]
            }
        }
    }
    puts "${name}_HOLD_FAIL_N          = $nfail"
    puts "${name}_HOLD_FAIL_FROM_PORT_N = $nport"
    puts "${name}_HOLD_FAIL_FROM_REG_N  = $nreg"
    puts "${name}_WORST_PORT_HOLD = $worst_port"
    puts "${name}_WORST_REG_HOLD  = $worst_reg"

    # the same classification for SETUP (should be all internal already)
    set ps2 [get_timing_paths -delay_type max -max_paths 400 -nworst 1 -sort_by slack]
    set sfail 0 ; set sport 0 ; set sreg 0
    foreach p $ps2 {
        if {[get_property SLACK $p] >= 0} { continue }
        incr sfail
        set sp [get_property STARTPOINT_PIN $p]
        if {[llength [get_ports -quiet $sp]] > 0} { incr sport } else { incr sreg }
    }
    puts "${name}_SETUP_FAIL_N          = $sfail"
    puts "${name}_SETUP_FAIL_FROM_PORT_N = $sport"
    puts "${name}_SETUP_FAIL_FROM_REG_N  = $sreg"

    # worst register-to-register hold margin that actually exists
    set allp [get_timing_paths -delay_type min -max_paths 400 -nworst 1 -sort_by slack]
    set best 999.0 ; set bests "NONE"
    foreach p $allp {
        set sp [get_property STARTPOINT_PIN $p]
        if {[llength [get_ports -quiet $sp]] > 0} { continue }
        set s [get_property SLACK $p]
        if {$s < $best} {
            set best $s
            set bests [format "slack=%.3f sp=%s ep=%s" $s $sp [get_property ENDPOINT_PIN $p]]
        }
    }
    puts "${name}_BEST_REG_TO_REG_HOLD = $bests"
    close_design
}

analyze mac_tx_ooc "$B/mac_only/mac_tx_ooc/mac_tx_ooc.runs/impl_1/mac_tx_min_top_routed.dcp" mac_tx_min_top
analyze mac_rx_ooc "$B/mac_only/mac_rx_ooc/mac_rx_ooc.runs/impl_1/mac_rx_min_top_routed.dcp" mac_rx_min_top

puts "\nANALYZE_DONE"
