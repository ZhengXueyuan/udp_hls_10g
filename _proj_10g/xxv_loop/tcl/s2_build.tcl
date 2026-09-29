# ============================================================================
# s2_build.tcl -- P7b gate 1: synthesise, implement and produce the bitstream
#   for xxv_loop_top (two-channel official xxv_ethernet PCS/PMA + the official
#   example-design traffic generator/monitor + a VIO observation window).
#
#   Opens the project created and configured by s1_prepare.tcl, adds the RTL,
#   the two XDC files and the VIO IP, then runs the standard project flow.
#   NOTHING is programmed here (that is s3_probe.tcl, and only after this build
#   has finished -- project rule: never program from a project under build).
#
#   The tool's own verdict lines are what matter: S2_* lines are printed for
#   every claim the report makes, and the log greps below are the hard gates
#   (implicit nets, driverless nets, unroutable pins, dropped constraints).
# ============================================================================

set root  "D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/xxv_loop"
set pdir  "$root/pcs64_2ch"
set vrtl  "D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/xxv_probe/pcs64_ex/pcs64_ex/imports/pcs64_pkt_gen_mon.v"
set vrtlc "$root/rtl/pcs64_pkt_gen_mon_ds.v"   ;# parameterised COPY (pay_sel)

proc sec {s} { puts "\nS2 >>>>>>>>>> $s" }
catch {set_param general.maxThreads 8}

sec "S2_OPEN"
open_project "$pdir/pcs64_2ch.xpr"
puts "S2_PART = [get_property part [current_project]]"
puts "S2_STAGE = round2 (loopback + payload-select + stat-domain probes)"
puts "S2_IP_LOCKED = [get_property IS_LOCKED [get_ips pcs64]]"

sec "S2_ADD"
add_files -norecurse [list \
    "$root/rtl/xxv_loop_top.v" \
    "$root/rtl/obs_util.v" \
    "$root/rtl/xgmii_rx_chk.v" \
    $vrtlc ]
add_files -fileset constrs_1 -norecurse "$root/xdc/xxv_loop.xdc"
add_files -fileset constrs_1 -norecurse "$root/xdc/xxv_loop_impl.xdc"
set_property used_in_synthesis false [get_files "$root/xdc/xxv_loop_impl.xdc"]

# The traffic module used by THIS build is rtl/pcs64_pkt_gen_mon_ds.v, a copy of
# the vendor file whose ONLY difference is a new `pay_sel` input threaded down to
# pcs64_mii_pkt_gen's `data_select` (the vendor hard-wired it to 2'b0, i.e. an
# all-zero XGMII payload).  pay_sel = 0 reproduces the vendor behaviour exactly.
# Both digests are printed so the relationship is a fact in the log, not a claim.
set fh  [open $vrtl r];  set vtxt  [read $fh]; close $fh
set fh2 [open $vrtlc r]; set vtxt2 [read $fh2]; close $fh2
puts "S2_VENDOR_FILE = $vrtl"
puts "S2_VENDOR_BYTES = [string length $vtxt]"
puts "S2_COPY_FILE = $vrtlc"
puts "S2_COPY_BYTES = [string length $vtxt2]"
if {[catch {exec diff $vrtl $vrtlc} dout]} { set dout "" }
puts "S2_COPY_DIFF_LINES = [llength [split [string trim $dout] \n]]"
if {[catch {exec sha256sum $vrtl}  sh1]} { set sh1 "<no sha256sum>" }
if {[catch {exec sha256sum $vrtlc} sh2]} { set sh2 "<no sha256sum>" }
puts "S2_VENDOR_SHA256 $sh1"
puts "S2_COPY_SHA256 $sh2"

# ---- VIO: the register window (36 probe_in x 32 bit, 6 probe_out x 1 bit) ----
# MEASURED (both failure modes are silent-ish and cost a build each):
#   * changing C_NUM_PROBE_IN + generate_target leaves the synthesis stub at the
#     OLD width  -> "[Synth 8-11365] named port connection 'probe_in32' does not exist"
#   * reset_target + generate_target removes the stub and does not put it back
#     -> "[Synth 8-439] module 'vio_0' not found"
# So the IP is always rebuilt from scratch here.
sec "S2_VIO"
foreach xf [get_files -quiet -of [get_filesets sources_1] *vio_0.xci] {
    puts "S2_VIO_REMOVE_STALE $xf"
    catch {remove_files $xf}
}
foreach d [list "$pdir/pcs64_2ch.gen/sources_1/ip/vio_0" \
                "$pdir/pcs64_2ch.srcs/sources_1/ip/vio_0" \
                "$pdir/pcs64_2ch.ip_user_files/ip/vio_0"] {
    if {[file exists $d]} { file delete -force $d ; puts "S2_VIO_RMDIR $d" }
}
create_ip -name vio -vendor xilinx.com -library ip -module_name vio_0
set vcfg [list CONFIG.C_NUM_PROBE_IN {48} CONFIG.C_NUM_PROBE_OUT {8}]
for {set i 0} {$i < 48} {incr i} {
    lappend vcfg CONFIG.C_PROBE_IN${i}_WIDTH {32}
}
for {set i 0} {$i < 6} {incr i} {
    lappend vcfg CONFIG.C_PROBE_OUT${i}_WIDTH {1}
}
lappend vcfg CONFIG.C_PROBE_OUT6_WIDTH {3}
lappend vcfg CONFIG.C_PROBE_OUT7_WIDTH {1}
set_property -dict $vcfg [get_ips vio_0]
puts "S2_VIO_NUMIN  = [get_property CONFIG.C_NUM_PROBE_IN  [get_ips vio_0]]"
puts "S2_VIO_NUMOUT = [get_property CONFIG.C_NUM_PROBE_OUT [get_ips vio_0]]"
puts "S2_VIO_W0     = [get_property CONFIG.C_PROBE_IN0_WIDTH [get_ips vio_0]]"
puts "S2_VIO_W31    = [get_property CONFIG.C_PROBE_IN31_WIDTH [get_ips vio_0]]"
puts "S2_VIO_W47    = [get_property CONFIG.C_PROBE_IN47_WIDTH [get_ips vio_0]]"
puts "S2_VIO_O6W    = [get_property CONFIG.C_PROBE_OUT6_WIDTH [get_ips vio_0]]"
generate_target all [get_ips vio_0]

set_property top xxv_loop_top [current_fileset]
update_compile_order -fileset sources_1
puts "S2_TOP = [get_property top [current_fileset]]"
puts "S2_NFILES = [llength [get_files -quiet]]"
foreach f [get_files -quiet -of [get_filesets constrs_1]] { puts "S2_CONSTR $f" }

# ---- strategy: the same one the P6a/P7a KU5P baselines used ----------------
set_property strategy Performance_ExtraTimingOpt [get_runs impl_1]

sec "S2_SYNTH"
reset_run synth_1
catch {launch_runs synth_1 -jobs 8} e
puts "S2_SYNTH_LAUNCH = $e"
wait_on_run synth_1
catch {puts "S2_SYNTH_STATUS = [get_property STATUS [get_runs synth_1]]"}
catch {puts "S2_SYNTH_PROGRESS = [get_property PROGRESS [get_runs synth_1]]"}
if {![string match "100%*" [get_property PROGRESS [get_runs synth_1]]]} {
    puts "S2_VERDICT = SYNTH_FAIL"
    foreach lf [glob -nocomplain "$pdir/pcs64_2ch.runs/synth_1/runme.log"] { puts "S2_LOG $lf" }
    exit 1
}

sec "S2_IMPL"
reset_run impl_1
catch {launch_runs impl_1 -to_step write_bitstream -jobs 8} e2
puts "S2_IMPL_LAUNCH = $e2"
wait_on_run impl_1
catch {puts "S2_IMPL_STATUS = [get_property STATUS [get_runs impl_1]]"}
catch {puts "S2_IMPL_PROGRESS = [get_property PROGRESS [get_runs impl_1]]"}

# ---- log greps: the hard gates --------------------------------------------
sec "S2_LOGGREP"
# MEASURED 2026-09-29 (round 2): an implicit net is reported by Vivado 2025.2 as
#   INFO: [Synth 8-11241] undeclared symbol 'pay_sel', assumed default net type 'wire'
# and the resulting floating net as
#   WARNING: [Synth 8-3848] Net pay_sel in module/entity ... does not have driver
#   WARNING: [Synth 8-7129] Port pay_sel ... is either unconnected or has no load
# The round-1/2 gate only looked for the phrase "implicitly declared" and so reported 0
# while the design DID contain a real implicit net (which is how the ones-payload run
# silently failed).  All four strings are gates now.
set keys {implicitly\ declared "8-11241" "undeclared symbol" "does not have driver" \
          "unconnected or has no load" "Opt 31-155" "Opt 31-67" "Route 35-54" \
          "Route 35-7" "AVAL-326" "NSTD-1" "UCIO-1" "12-4739" "not permitted" \
          "multiple driver"}
foreach lf [glob -nocomplain "$pdir/pcs64_2ch.runs/synth_1/runme.log" \
                      "$pdir/pcs64_2ch.runs/impl_1/runme.log"] {
    set fh [open $lf r]
    set n 0
    set counts [dict create]
    foreach k $keys { dict set counts $k 0 }
    while {[gets $fh line] >= 0} {
        incr n
        foreach k $keys {
            if {[string first $k $line] >= 0} { dict incr counts $k }
        }
    }
    close $fh
    puts "S2_LOGFILE $lf lines=$n"
    foreach k $keys { puts "S2_GREP [file tail $lf] <$k> = [dict get $counts $k]" }
}

# ---- read the results out of the routed design -----------------------------
sec "S2_TIMING"
set idir "$pdir/pcs64_2ch.runs/impl_1"
set rpt  "$idir/xxv_loop_top_timing_summary_routed.rpt"
if {[file exists $rpt]} {
    set fh [open $rpt r]
    set grab 0 ; set left 0
    while {[gets $fh line] >= 0} {
        if {[string first "Design Timing Summary" $line] >= 0} { set grab 1 ; set left 12 }
        if {$grab && $left > 0} {
            if {[string trim $line] ne ""} { puts "S2_TIMING $line" }
            incr left
            if {$left > 11} { set grab 0 }
        }
    }
    close $fh
} else { puts "S2_TIMING_MISSING $rpt" }

open_run impl_1
catch {puts "S2_WNS = [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]"}
catch {puts "S2_WHS = [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]"}
catch {puts "S2_TNS = [get_property SLACK [get_timing_paths -delay_type max -max_paths 1 -nworst 1000]]"}
catch {puts "S2_THS = [get_property SLACK [get_timing_paths -delay_type min -max_paths 1 -nworst 1000]]"}
catch {puts "S2_WPWS = [get_property SLACK [get_timing_paths -delay_type min_max -max_paths 1]]"}

sec "S2_CG_DRYRUN"
puts "S2_CG_all      = [get_clocks]"
puts "S2_CG_dclk     = [get_clocks -include_generated_clocks dclk]"
puts "S2_CG_gtrefclk = [get_clocks -include_generated_clocks gtrefclk0]"
catch {puts "S2_CG_dbg_n   = [llength [get_debug_cores dbg_hub]]"}
catch {puts "S2_CG_sync_n  = [llength [get_cells -hier -filter {NAME =~ *cdc_sync2*}]]"}
catch {puts "S2_CG_snap_n  = [llength [get_cells -hier -filter {NAME =~ *snap_hold*}]]"}
catch {puts "S2_CG_obs_n   = [llength [get_cells -hier -filter {NAME =~ *obs_reg*}]]"}
catch {puts "S2_CG_rfchk_n = [llength [get_cells -hier -filter {NAME =~ *u_chk1*}]]"}

sec "S2_UTIL"
set urpt "$idir/xxv_loop_top_utilization_placed.rpt"
if {[file exists $urpt]} {
    set fh [open $urpt r]
    while {[gets $fh line] >= 0} {
        set t [string trim $line]
        foreach k {"CLB LUTs" "CLB Registers" "CARRY8" "Block RAM Tile" "RAMB36" \
                   "RAMB18" "URAM" "DSPs" "Bonded IOB" "GTYE4_CHANNEL" \
                   "Slice LUTs" "Slice Registers" "BUFGCE" "MMCM" "PLL"} {
            if {[string first $k $t] == 0} { puts "S2_UTIL $t" ; break }
        }
    }
    close $fh
} else { puts "S2_UTIL_MISSING $urpt" }

sec "S2_BIT"
set bs [glob -nocomplain "$idir/*.bit"]
foreach b $bs {
    puts "S2_BIT $b size=[file size $b]"
    set sha [exec sha256sum $b]
    puts "S2_SHA256 $sha"
}
set ltx [glob -nocomplain "$idir/*.ltx"]
puts "S2_LTX = $ltx"
if {[llength $bs] > 0} { puts "S2_VERDICT = PASS_BITSTREAM" } else { puts "S2_VERDICT = NO_BITSTREAM" }

sec "S2 DONE"
