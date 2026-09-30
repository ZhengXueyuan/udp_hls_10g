# ============================================================================
# run_xxv_mac.tcl -- P7b MAC timing/area probe, PART 2
#
#   Works on a COPY of the already-working two-channel official xxv_ethernet
#   PCS/PMA project (xxv_loop).  The original is not touched.
#
#   TWO builds, same project, same flow, same strategy, back to back:
#     A = top xxv_loop_top   -> the PCS-only BASELINE, re-measured here so the
#                              comparison to build B is same-flow (project
#                              lesson: absolute timing numbers are flow
#                              dependent, so never compare across flows).
#     B = top xxv_mac_top    -> the same design with the P7b 64-bit XGMII MAC
#                              integrated (mac_tx_10g drives the X0Y5
#                              transmitter, mac_rx_10g decodes the X0Y5
#                              receiver's real XGMII bus).
#
#   NOTHING is programmed.  No QSPI.  No git.  No licence file touched.
# ============================================================================

set B    "D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/p7b_mac_synth"
set root "$B/xxv_mac"
set pdir "$root/pcs64_2ch"
set part "xcku5p-ffvb676-1-e"
catch {set_param general.maxThreads 8}

# ---------------------------------------------------------------------------
# ⚠️ MAC 核从哪一份取 —— 2026-09-30 订正 (本 tcl 曾指向**修复前快照**)
#
#   `$B/rtl/` = **修复前快照** (`_STALE.md` 有身份说明): 它的 `mac_tx_10g.v` 是
#   pad/FCS 修前的旧语义, `mac_rx_10g.v` 是 P7B_LANEFIX 修前的。它**只**留给
#   A/B 对照当输入件 —— 照它量出来的时序**不是现行 MAC 的时序**。
#   ⇒ 三个 MAC 核 (`crc32_64` / `mac_tx_10g` / `mac_rx_10g`) 一律从 **canonical**
#      副本 `_proj_10g/p7b_mac/rtl/` 取, 与 `board/build_p7b_ku5p.tcl:28,100` 同源。
#   `fifo_sync.v` 是**只此一份**的脚手架 (不在 `_STALE.md` 的 stale 名单里)
#   ⇒ 仍从 `$B/rtl/` 取, 那不是"旧件"。
# ---------------------------------------------------------------------------
set MACRTL "D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/p7b_mac/rtl"

# 硬闸: MAC 核一旦被指回 stale 快照 / 或内容缺修复标记, 就地 **error 停** ——
# 否则会**静默**量到旧件的时序 (本 tcl 原样就是这个下场)。
# 有意的 A/B 对照: 复制本 tcl、删掉这次 guard 调用即可 (不要改这里的路径)。
proc mac_src_guard {} {
    foreach spec [list [list "$::MACRTL/crc32_64.v"   ""] \
                       [list "$::MACRTL/mac_tx_10g.v" "cmask64"] \
                       [list "$::MACRTL/mac_rx_10g.v" "ra_merge"]] {
        set n [string map [list "\\" "/"] [file normalize [lindex $spec 0]]]
        set mark [lindex $spec 1]
        if {![file exists $n]} { puts "MAC_SRC_MISSING $n" ; error "MAC source missing: $n" }
        if {[string first "/p7b_mac_synth/rtl/" $n] >= 0} {
            puts "MAC_SRC_STALE $n"
            error "MAC core resolved to the PRE-FIX snapshot dir: $n -- see $::B/rtl/_STALE.md; use \$MACRTL"
        }
        set fh [open $n r] ; set txt [read $fh] ; close $fh
        if {$mark ne "" && [string first $mark $txt] < 0} {
            puts "MAC_SRC_NO_FIX_MARK $n mark=$mark"
            error "MAC core $n lacks the '$mark' fix marker (pre-fix content?) -- if this is an intended rename/refactor, update the marker in mac_src_guard"
        }
        set sha "<unavailable>"
        catch { set sha [string trim [lindex [split [exec cmd /c certutil -hashfile $n SHA256] "\n"] 1]] }
        puts "MAC_SRC $n mark=$mark sha256=$sha"
    }
}

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
    if {![file exists $f]} { puts "${tag}_TSR_MISSING $f" ; return }
    set fh [open $f r] ; set grab 0 ; set left 0
    while {[gets $fh line] >= 0} {
        if {[string first "Design Timing Summary" $line] >= 0} { set grab 1 ; set left 12 }
        if {$grab && $left > 0} {
            if {[string trim $line] ne ""} { puts "${tag}_TS $line" }
            incr left ; if {$left > 11} { set grab 0 }
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

proc util_block {tag f} {
    if {![file exists $f]} { puts "${tag}_UTIL_MISSING $f" ; return }
    set fh [open $f r]
    while {[gets $fh line] >= 0} {
        set t [string trim $line]
        foreach k {"CLB LUTs" "CLB Registers" "CARRY8" "Block RAM Tile" "RAMB36" \
                   "RAMB18" "URAM" "DSPs" "Bonded IOB" "GTYE4_CHANNEL" "BUFGCE" \
                   "Slice LUTs" "Slice Registers"} {
            if {[string first $k $t] == 0} { puts "${tag}_UTIL $t" ; break }
        }
    }
    close $fh
}

# ---------------------------------------------------------------------------
proc build_top {tag top} {
    # MEASURED: without this, `$pdir` inside the proc is an empty local and the
    # build dies at the first report glob AFTER synthesis -- i.e. after the
    # expensive part, and with a "can't read pdir" that looks like a tool error.
    global B pdir
    sec "BUILD $tag  top=$top"
    # a design left open in memory blocks the next launch_runs
    catch {close_design}
    update_compile_order -fileset sources_1
    set_property top $top [current_fileset]
    update_compile_order -fileset sources_1
    puts "${tag}_TOP = [get_property top [current_fileset]]"
    # HARD GUARD: the MAC-only build was once silently sent at the wrong module
    # because `set_property top` can be overridden by automatic hierarchy
    # update; never trust it without reading it back.
    if {[get_property top [current_fileset]] ne $top} {
        puts "${tag}_TOP_MISMATCH asked=<$top> got=<[get_property top [current_fileset]]>"
        puts "${tag}_VERDICT = TOP_NOT_SET"
        return 0
    }

    reset_run synth_1
    catch {launch_runs synth_1 -jobs 8} e
    puts "${tag}_SYNTH_LAUNCH = $e"
    wait_on_run synth_1
    puts "${tag}_SYNTH_STATUS   = [get_property STATUS   [get_runs synth_1]]"
    puts "${tag}_SYNTH_PROGRESS = [get_property PROGRESS [get_runs synth_1]]"
    if {![string match "100%*" [get_property PROGRESS [get_runs synth_1]]]} {
        puts "${tag}_VERDICT = SYNTH_FAIL"
        return 0
    }
    catch {
        foreach f [glob -nocomplain "$pdir/pcs64_2ch.runs/synth_1/*_utilization_synth.rpt"] {
            puts "${tag}_SYNTH_UTIL_FILE $f"
        }
        foreach f [glob -nocomplain "$pdir/pcs64_2ch.runs/synth_1/*_timing_summary_synth.rpt"] {
            ts_block "${tag}_SYN" $f
        }
    }

    reset_run impl_1
    catch {launch_runs impl_1 -to_step route_design -jobs 8} e2
    puts "${tag}_IMPL_LAUNCH = $e2"
    wait_on_run impl_1
    puts "${tag}_IMPL_STATUS   = [get_property STATUS   [get_runs impl_1]]"
    puts "${tag}_IMPL_PROGRESS = [get_property PROGRESS [get_runs impl_1]]"

    open_run impl_1
    puts "${tag}_WNS  = [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]"
    puts "${tag}_WHS  = [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]"
    puts "${tag}_WPWS = [get_property SLACK [get_timing_paths -delay_type min_max -max_paths 1]]"

    set idir "$pdir/pcs64_2ch.runs/impl_1"
    foreach f [glob -nocomplain "$idir/*_timing_summary_routed.rpt"] {
        puts "${tag}_TSR = $f"
        ts_block "${tag}" $f
        ic_block "${tag}" $f
        catch {file copy -force $f "$::B/reports/${tag}_timing_summary_routed.rpt"}
    }
    foreach f [glob -nocomplain "$idir/*_utilization_placed.rpt"] {
        puts "${tag}_UTIL_FILE $f"
        util_block "${tag}" $f
        catch {file copy -force $f "$::B/reports/${tag}_utilization_placed.rpt"}
    }
    foreach f [glob -nocomplain "$idir/*_drc_routed.rpt"] {
        catch {file copy -force $f "$::B/reports/${tag}_drc_routed.rpt"}
    }
    foreach f [glob -nocomplain "$idir/*_methodology_drc_routed.rpt"] {
        catch {file copy -force $f "$::B/reports/${tag}_methodology_drc_routed.rpt"}
    }

    dump_paths $tag max 10
    dump_paths $tag min 6

    # ---- the CRC chains, named explicitly -----------------------------------
    foreach inst {u_mac_tx u_mac_rx} {
        set cn [llength [get_cells -hier -quiet -filter "NAME =~ *${inst}/u_crc*"]]
        set cf [llength [get_cells -hier -quiet -filter "NAME =~ *${inst}/u_crc* && IS_SEQUENTIAL"]]
        puts "${tag}_CRC_${inst}_CELL_N = $cn"
        puts "${tag}_CRC_${inst}_FF_N   = $cf"
        catch {
            report_timing -from [get_cells -hier -quiet -filter "NAME =~ *${inst}/u_crc/crc_reg*"] \
                          -to   [get_cells -hier -quiet -filter "NAME =~ *${inst}/u_crc/crc_reg*"] \
                          -max_paths 4 -delay_type max \
                          -file "$::B/reports/${tag}_${inst}_crc_reg2reg.rpt"
            puts "${tag}_CRC_${inst}_R2R = written"
        }
    }
    puts "${tag}_TOTAL_FF_N = [llength [get_cells -hier -quiet -filter {IS_SEQUENTIAL}]]"
    puts "${tag}_TOTAL_CELL_N = [llength [get_cells -hier -quiet]]"

    catch {
        report_timing -max_paths 60 -delay_type max -nworst 4 -file "$::B/reports/${tag}_setup_paths.rpt"
        report_timing -max_paths 30 -delay_type min -nworst 4 -file "$::B/reports/${tag}_hold_paths.rpt"
        puts "${tag}_PATHREPORTS = written"
    }
    puts "${tag}_VERDICT = BUILT"
    return 1
}

# ===========================================================================
sec "OPEN"
open_project "$pdir/pcs64_2ch.xpr"
puts "PART = [get_property part [current_project]]"
puts "OPEN_OK"

sec "ADD"
# MAC 核 = canonical ($MACRTL); $root/rtl/xxv_mac_top.v = 本项目自己的接线壳;
# fifo_sync.v = 只此一份的脚手架。只换 MAC 三个核的来源目录。
puts "MACRTL = $MACRTL"
mac_src_guard
add_files -norecurse [list \
    "$root/rtl/xxv_mac_top.v" \
    "$MACRTL/crc32_64.v" \
    "$B/rtl/fifo_sync.v" \
    "$MACRTL/mac_tx_10g.v" \
    "$MACRTL/mac_rx_10g.v" ]
update_compile_order -fileset sources_1
foreach f [get_files -quiet -of [get_filesets sources_1]] { puts "SRC $f" }
puts "IPLIST = [get_ips]"
foreach f [get_files -quiet -of [get_filesets constrs_1]] { puts "CONSTR $f" }

# ---- VIO: reused as-is from the copied project -----------------------------
# MEASURED (first attempt at this very build): the s2_build.tcl recipe of
# "delete the IP directories, then create_ip" FAILS on a project that already
# has the IP registered:
#   ERROR: [Common 17-69] Command failed: IP name 'vio_0' is already in use in
#   this project.  Please choose a different name.
# (remove_files drops the file but the project's IP catalog entry survives.)
# The copied project already carries the correct vio_0 (48 x 32-bit probe_in,
# 8 probe_out with #6 = 3 bits), so it is REUSED, not recreated -- which also
# keeps this build's VIO identical to the baseline's.
sec "VIO"
puts "VIO_NUMIN  = [get_property CONFIG.C_NUM_PROBE_IN  [get_ips vio_0]]"
puts "VIO_NUMOUT = [get_property CONFIG.C_NUM_PROBE_OUT [get_ips vio_0]]"
puts "VIO_W0     = [get_property CONFIG.C_PROBE_IN0_WIDTH  [get_ips vio_0]]"
puts "VIO_W47    = [get_property CONFIG.C_PROBE_IN47_WIDTH [get_ips vio_0]]"
puts "VIO_O6W    = [get_property CONFIG.C_PROBE_OUT6_WIDTH [get_ips vio_0]]"

set_property strategy Performance_ExtraTimingOpt [get_runs impl_1]

# A_Base (PCS only) already ran in this session and reproduced the stored
# xxv_loop baseline EXACTLY (WNS 1.870 / WHS 0.006 / 0 failing endpoints /
# 29061 + 29045 + 18613 endpoints, and 9040 LUT / 18362 FF).  RESULT A is the
# copy in reports/A_Base_*.  It is skipped on the clean re-run only because the
# MAC-side defect that the implicit gate caught lives in build B.
set RUN_BASE 0
if {$RUN_BASE} { build_top A_Base xxv_loop_top }
build_top B_WithMac xxv_mac_top

sec "LOGGREP"
# The canonical detector is sim/p4gates/implicit_gate.bat (a separate call from
# the shell); the keys below are printed here too so the log is self-contained.
set keys [list "Synth 8-11241" "undeclared symbol" \
               "VRFC 10-3091] actual bit length 1 differs from formal bit length" \
               "VRFC 10-2989" "implicitly declared" \
               "NSTD-1" "UCIO-1" "AVAL-326" "Opt 31-155" "Opt 31-67" "Route 35-7" \
               "12-4739" "multiple driver" "does not have driver"]
foreach lf [glob -nocomplain "$pdir/pcs64_2ch.runs/synth_1/runme.log" \
                      "$pdir/pcs64_2ch.runs/impl_1/runme.log"] {
    set fh [open $lf r]
    set n 0
    set counts [dict create]
    foreach k $keys { dict set counts $k 0 }
    while {[gets $fh line] >= 0} {
        incr n
        foreach k $keys { if {[string first $k $line] >= 0} { dict incr counts $k } }
    }
    close $fh
    puts "LOGFILE $lf lines=$n"
    foreach k $keys { puts "GREP [file tail $lf] <$k> = [dict get $counts $k]" }
}

sec "DONE"
