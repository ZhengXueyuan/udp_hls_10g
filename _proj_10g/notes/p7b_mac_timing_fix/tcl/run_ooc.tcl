# ============================================================================
# run_ooc.tcl -- P7b MAC timing probe (FIX AGENT, 2026-09-30)
#
#   Out-of-context place+route of mac_tx_min_top (and optionally mac_rx_min_top)
#   with a PARAMETERISED RTL directory + impl strategy, so the same flow can be
#   pointed at
#       OLD = _proj_10g/p7b_mac_synth/rtl   (pre-pad/FCS-fix snapshot)
#       NEW = _proj_10g/p7b_mac/rtl         (current, pad/FCS fix applied)
#       FIX = same as NEW after the timing fix
#   and so placement/route variance (strategy sweep) can be measured.
#
#   This mirrors tcl/run_mac_only.tcl of p7b_mac_synth EXACTLY in flow terms
#   (OOC synth, real 6.400 ns clock, Performance_ExtraTimingOpt by default,
#    same gates) so the numbers are comparable to the archived
#   +0.285 (TX) / +0.051 (RX) baseline in reports/mac_{tx,rx}_ooc_*.rpt
#
#   NOTHING is programmed.  No QSPI.  No licence file touched.  No git.
#
#   usage (from a bat):
#     vivado -mode batch -nojournal -nolog -source run_ooc.tcl \
#            -tclargs <rtl_dir> <tag> <strategy> <which: tx|rx|both>
# ============================================================================

set B     "D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/notes/p7b_mac_timing_fix"
set part  "xcku5p-ffvb676-1-e"
catch {set_param general.maxThreads 8}

if {[llength $argv] >= 4} {
    set rtl_dir  [lindex $argv 0]
    set tag      [lindex $argv 1]
    set strategy [lindex $argv 2]
    set which    [lindex $argv 3]
} else {
    puts "ARGV_BAD = <$argv>"
    exit 1
}
puts "OOC_ARGV rtl_dir=<$rtl_dir> tag=<$tag> strategy=<$strategy> which=<$which>"

proc sec {s} { puts "\n>>>>>>>>>> $s" }

proc dump_paths {tag dtype n} {
    set ps [get_timing_paths -delay_type $dtype -max_paths $n -nworst 1 -sort_by slack]
    set i 0
    foreach p $ps {
        incr i
        set sp "<none>" ; set ep "<none>"
        catch {set sp [get_property STARTPOINT_PIN $p]}
        catch {set ep [get_property ENDPOINT_PIN   $p]}
        puts [format "%s_%s_P%d slack=%.3f levels=%s logic=%.3f net=%.3f sp=%s ep=%s" \
              $tag $dtype $i [get_property SLACK $p] [get_property LOGIC_LEVELS $p] \
              [get_property DATAPATH_LOGIC_DELAY $p] [get_property DATAPATH_NET_DELAY $p] \
              $sp $ep]
    }
}

proc ts_block {tag f} {
    if {![file exists $f]} { puts "${tag}_MISSING $f" ; return }
    set fh [open $f r] ; set grab 0 ; set left 0
    while {[gets $fh line] >= 0} {
        if {[string first "Design Timing Summary" $line] >= 0} { set grab 1 ; set left 20 }
        if {$grab && $left > 0} {
            if {[string trim $line] ne ""} { puts "${tag}_TS $line" }
            incr left ; if {$left > 19} { set grab 0 }
        }
    }
    close $fh
}

proc ic_block {tag f} {
    if {![file exists $f]} { return }
    set fh [open $f r] ; set grab 0
    while {[gets $fh line] >= 0} {
        if {[string first "Intra Clock Table" $line] >= 0} { set grab 1 }
        if {[string first "Inter Clock Table" $line] >= 0} { set grab 0 }
        if {$grab && [string trim $line] ne ""} { puts "${tag}_IC $line" }
    }
    close $fh
}

proc build_one {name top rtl xdc pdir strategy} {
    sec "BUILD $name  top=$top  strategy=$strategy"
    if {[file exists $pdir]} { file delete -force $pdir }
    create_project -force $name $pdir -part $::part
    set_property target_language Verilog [current_project]
    add_files -norecurse $rtl
    add_files -fileset constrs_1 -norecurse $xdc
    # order matters: parse hierarchy FIRST, then set top (else the top is
    # silently overridden -- see run_mac_only.tcl's measured note)
    update_compile_order -fileset sources_1
    set_property top $top [current_fileset]
    update_compile_order -fileset sources_1
    set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} -value {-mode out_of_context} \
                 -objects [get_runs synth_1]
    catch {set_property -name {STEPS.SYNTH_DESIGN.ARGS.TOP} -value $top -objects [get_runs synth_1]}
    if {$strategy ne "DEFAULT"} { set_property strategy $strategy [get_runs impl_1] }

    puts "${name}_TOP      = [get_property top [current_fileset]]"
    puts "${name}_STRATEGY = [get_property strategy [get_runs impl_1]]"
    foreach f [get_files -quiet] { puts "${name}_FILE $f" }
    if {[get_property top [current_fileset]] ne $top} {
        puts "${name}_VERDICT = TOP_NOT_SET" ; return 0
    }

    reset_run synth_1
    catch {launch_runs synth_1 -jobs 8}
    wait_on_run synth_1
    if {![string match "100%*" [get_property PROGRESS [get_runs synth_1]]]} {
        puts "${name}_VERDICT = SYNTH_FAIL" ; return 0
    }
    set srl "$pdir/${name}.runs/synth_1/runme.log"
    if {[file exists $srl]} {
        set fh [open $srl r] ; set n4739 0
        while {[gets $fh line] >= 0} {
            if {[string first "12-4739" $line] >= 0} { incr n4739 }
        }
        close $fh
        puts "${name}_SYNTH_GATE_12_4739_N = $n4739"
    }

    catch {launch_runs impl_1 -to_step route_design -jobs 8}
    wait_on_run impl_1
    puts "${name}_IMPL_STATUS = [get_property STATUS [get_runs impl_1]]"
    if {![string match "route_design Complete*" [get_property STATUS [get_runs impl_1]]]} {
        puts "${name}_VERDICT = IMPL_INCOMPLETE" ; return 0
    }

    open_run impl_1
    puts "${name}_WNS  = [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]"
    puts "${name}_WHS  = [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]"
    puts "${name}_WPWS = [get_property SLACK [get_timing_paths -delay_type min_max -max_paths 1]]"
    # failing endpoint count for this clock group (the number we must drive to 0)
    set fe 0
    foreach p [get_timing_paths -delay_type max -max_paths 5000 -nworst 5000 -slack_lesser_than 0] {
        incr fe
    }
    puts "${name}_FAILING_ENDPOINTS = $fe"

    set idir "$pdir/${name}.runs/impl_1"
    foreach f [glob -nocomplain "$idir/*_timing_summary_routed.rpt"] {
        ts_block "${name}_ROU" $f
        ic_block "${name}_ROU" $f
    }
    dump_paths $name max 6
    catch { report_timing -max_paths 20 -delay_type max -nworst 2 \
              -file "$::B/reports/${name}_setup_paths.rpt" }
    catch { report_utilization -hierarchical -file "$::B/reports/${name}_util_hier.rpt" }
    close_project
    puts "${name}_VERDICT = BUILT"
    return 1
}

# ---------------------------------------------------------------------------
# fifo_sync.v is NOT in _proj_10g/p7b_mac/rtl -- it is the shared rtl/fifo_sync.v
# (the unit gate uses %REPO_ROOT%\rtl\fifo_sync.v).  Both copies on disk are
# byte-identical (sha256 c46c52f6...), so using the shared one for every arm
# keeps the arms comparable and is what the real build imports.
set shared_fifo "D:/repo/XCKU5PMini/udp_hls_10g/rtl/fifo_sync.v"
set rtl_common [list "$rtl_dir/crc32_64.v" "$shared_fifo" \
                     "$rtl_dir/mac_tx_10g.v" "$rtl_dir/mac_rx_10g.v"]
foreach f $rtl_common {
    if {![file exists $f]} { puts "MISSING_RTL $f" ; exit 2 }
}
if {[file exists "$rtl_dir/fifo_sync.v"]} {
    puts "FIFO_SYNC_LOCAL_COPY = $rtl_dir/fifo_sync.v (unused, shared one is imported)"
}

sec "ENV"
puts "VIVADO = [version -short]"
puts "PART_N = [llength [get_parts $part -quiet]]"

if {$which eq "tx" || $which eq "both"} {
    build_one "${tag}_tx" mac_tx_min_top \
        [concat $rtl_common [list "$::B/rtl_probe/mac_tx_min_top.v"]] \
        "$::B/rtl_probe/mac_tx_min.xdc" "$::B/ooc/${tag}_tx" $strategy
}
if {$which eq "sink"} {
    # faithful endpoint model: mac_tx_10g + one register stage on the XGMII outputs
    # (models the PCS capture register -> register->register path, no DCD bias)
    build_one "${tag}_sink" mac_tx_sink_top \
        [concat $rtl_common [list "$::B/rtl_probe/mac_tx_sink_top.v"]] \
        "$::B/rtl_probe/mac_tx_sink.xdc" "$::B/ooc/${tag}_sink" $strategy
}
if {$which eq "rx" || $which eq "both"} {
    build_one "${tag}_rx" mac_rx_min_top \
        [concat $rtl_common [list "$::B/rtl_probe/mac_rx_min_top.v"]] \
        "$::B/rtl_probe/mac_rx_min.xdc" "$::B/ooc/${tag}_rx" $strategy
}

sec "DONE $tag"
