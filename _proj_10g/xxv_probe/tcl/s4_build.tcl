# ============================================================================
# s4_build.tcl -- P7b stage 4: THE LICENSE ANSWER.
#
#   Open each probe project (xxv_ethernet already configured + generated),
#   add the probe RTL + probe XDC, set the probe top, then run the FULL
#   project flow:  synth_1 -> impl_1 -> write_bitstream.
#
#   Nothing is programmed.  No QSPI.  No git.
#
#   The deliverable is the tool's own verdict lines; licgrep() prints every
#   line of every runme.log that carries a licence word or a licence path.
# ============================================================================

set root "D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/xxv_probe"
set LICKEY {license check failed secure ip xxv_eth_mac_pcs internal_bitstream
            evaluation timeout will stop working expire flexlm
            requires one or more mandatory licenses not licensed
            cannot change read-only property}

proc sec {s} { puts "\nS4 >>>>>>>>>> $s" }
catch {set_param general.maxThreads 4}

proc licgrep {tag logfile} {
    if {![file exists $logfile]} { puts "S4_LOG_MISSING $tag $logfile"; return 0 }
    global LICKEY
    set fh [open $logfile r]
    set n 0 ; set hits 0
    while {[gets $fh line] >= 0} {
        incr n
        set low [string tolower $line]
        set hit 0
        foreach k $LICKEY { if {[string first $k $low] >= 0} { set hit 1 ; break } }
        # any line that literally names a .lic file is licence-path evidence
        if {[string first ".lic" $low] >= 0} { set hit 1 }
        if {$hit} {
            puts "S4_LICLINE $tag [file tail $logfile]:$n : [string trim $line]"
            incr hits
        }
    }
    close $fh
    puts "S4_LICLINE_N $tag [file tail $logfile] = $hits  (scanned $n lines)"
    return $hits
}

proc dumputil {rpt} {
    if {![file exists $rpt]} { puts "S4_UTIL_MISSING $rpt"; return }
    set fh [open $rpt r]
    while {[gets $fh line] >= 0} {
        set t [string trim $line]
        foreach k {"CLB LUTs" "CLB Registers" "CARRY8" "Block RAM Tile" "RAMB36" \
                   "RAMB18" "URAM" "DSPs" "Bonded IOB" "GTYE4_CHANNEL" \
                   "Slice LUTs" "Slice Registers" "BUFGCE" "MMCM" "PLL"} {
            if {[string first $k $t] == 0} { puts "S4_UTIL $t" ; break }
        }
        if {[string match "*| Site Type*" $t]} { puts "S4_UTIL_HDR $t" }
    }
    close $fh
}

proc dumptiming {rpt} {
    if {![file exists $rpt]} { puts "S4_TIMING_MISSING $rpt"; return }
    set fh [open $rpt r]
    set grab 0 ; set left 0
    while {[gets $fh line] >= 0} {
        if {[string first "Design Timing Summary" $line] >= 0} { set grab 1 ; set left 10 }
        if {$grab && $left > 0} {
            if {[string trim $line] ne ""} { puts "S4_TIMING $line" }
            incr left
            if {$left > 9} { set grab 0 }
        }
    }
    close $fh
}

proc build {tag topname} {
    global root
    set pdir "$root/$tag"
    sec "S4_BEGIN $tag top=$topname"
    if {[catch {open_project "$pdir/$tag.xpr"} e]} { puts "S4_OPEN_FAIL = $e"; return 0 }

    catch {puts "S4_PART = [get_property part [current_project]]"}
    catch {puts "S4_IP_IS_LOCKED = [get_property IS_LOCKED [get_ips $tag]]"}

    catch {add_files -norecurse "$root/rtl/$topname.v"}
    catch {add_files -fileset constrs_1 -norecurse "$root/xdc/probe_$tag.xdc"}
    set_property top $topname [current_fileset]
    catch {update_compile_order -fileset sources_1}
    puts "S4_TOP = [get_property top [current_fileset]]"

    sec "S4_SYNTH $tag"
    catch {reset_run synth_1}
    set rc [catch {launch_runs synth_1 -jobs 4} e]
    puts "S4_SYNTH_LAUNCH rc = $rc  ($e)"
    catch {wait_on_run synth_1}
    catch {puts "S4_SYNTH_STATUS = [get_property STATUS [get_runs synth_1]]"}
    catch {puts "S4_SYNTH_PROGRESS = [get_property PROGRESS [get_runs synth_1]]"}
    foreach lf [glob -nocomplain "$pdir/$tag.runs/*/runme.log"] { licgrep "S_$tag" $lf }

    if {![string match "100%*" [get_property PROGRESS [get_runs synth_1]]]} {
        puts "S4_VERDICT $tag = SYNTH_FAIL"
        close_project -quiet
        return 0
    }

    sec "S4_IMPL $tag"
    catch {reset_run impl_1}
    set rc2 [catch {launch_runs impl_1 -to_step write_bitstream -jobs 4} e2]
    puts "S4_IMPL_LAUNCH rc = $rc2  ($e2)"
    catch {wait_on_run impl_1}
    catch {puts "S4_IMPL_STATUS = [get_property STATUS [get_runs impl_1]]"}
    catch {puts "S4_IMPL_PROGRESS = [get_property PROGRESS [get_runs impl_1]]"}
    foreach lf [glob -nocomplain "$pdir/$tag.runs/*/runme.log"] { licgrep "I_$tag" $lf }

    set idir "$pdir/$tag.runs/impl_1"
    dumptiming "$idir/${topname}_timing_summary_routed.rpt"
    dumputil   "$idir/${topname}_utilization_placed.rpt"

    set bs [glob -nocomplain "$idir/*.bit"]
    foreach b $bs { puts "S4_BIT $b size=[file size $b]" }
    if {[llength $bs] > 0} { puts "S4_VERDICT $tag = PASS_BITSTREAM" } \
    else                   { puts "S4_VERDICT $tag = NO_BITSTREAM" }

    close_project -quiet
    puts "S4_END $tag"
    return 1
}

build pcs64    probe_pcs64_top
build macpcs64 probe_macpcs64_top

sec "S4 DONE"
