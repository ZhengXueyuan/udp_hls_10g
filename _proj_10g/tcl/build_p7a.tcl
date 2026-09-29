#=============================================================================
# build_p7a.tcl -- P7a main bitstream: 10GBASE-R (64b/66b gearbox) on XCKU5P
#=============================================================================
#
#  Run:  vivado -mode batch -source build_p7a.tcl -nojournal -nolog
#        (or via tcl/run_build_p7a.bat, which is what was actually used)
#
#  What it builds (P7A_SPEC.md section 2.1, route 1):
#    * gtwizard_ultrascale 1.7, 2 channels X0Y4/X0Y5 (SFP A / SFP B, quad 225),
#      64B66B_ASYNC encoding, 64-bit internal + user data width, 10.3125 Gbps.
#      The four ordering/form traps from P7A_SPEC.md section 1.4 are honoured:
#        (a) user data width before internal data width,
#        (b) TX and RX reference-clock frequencies in ONE atomic set_property,
#        (c) TX and RX REFCLK_SOURCE both set to clk0 (only MGTREFCLK0 is fitted),
#        (d) LOCATE_* use CORE/EXAMPLE_DESIGN, never 0/1.
#    * a hand-written top (rtl/p7a_top.v) that borrows ONLY the PRBS parts from
#      the wizard example -- prbs_any, the 64b66b stimulus and the 64b66b checker
#      are COPIED VERBATIM into rtl/ and their sha256 is checked against what
#      this very build generates (so "verbatim" is verified, not asserted).
#      The example's leaky-bucket link FSM is NOT used as the criterion; the
#      verdict comes from rtl/p7a_counters.v.
#    * a VIO (probe_in 7, probe_out 4) as the observation channel over JTAG.
#
#  The whole flow is launch_runs (synth_1 then impl_1 -to_step write_bitstream)
#  with the same strategy as the P6a KU5P baseline, so the WNS/WHS numbers are
#  comparable with p6a_ku5p_verify/.
#=============================================================================

set here      [file normalize [file dirname [info script]]]
set root      [file normalize [file join $here ..]]
set proj_dir  [file join $root vivado_prj]
set part_name xcku5p-ffvb676-1-e
set top       p7a_top

proc sec {s} { puts "\n===== P7A >>>>>>>> $s" }

if {[info exists ::env(P7A_STRATEGY)]} { set strategy $::env(P7A_STRATEGY) } else { set strategy Performance_ExtraTimingOpt }

sec "ENV"
puts "VIVADO = [version -short]"
puts "PART   = $part_name"
puts "TOP    = $top"
puts "STRATEGY = $strategy"
catch {set_param general.maxThreads 8}

file mkdir [file join $root reports]
file delete -force $proj_dir
create_project -force p7a_prj $proj_dir -part $part_name
set_property target_language Verilog [current_project]

sec "RTL"
add_files -norecurse [list \
    [file join $root rtl p7a_top.v] \
    [file join $root rtl p7a_counters.v] \
    [file join $root rtl p7a_tgl_sync.v] \
    [file join $root rtl p7a_bit_sync.v] \
    [file join $root rtl p7a_vio_ctrl.v] \
    [file join $root rtl p7a_ref_bucket.v] \
    [file join $root rtl clk_gen_p6b.v] \
    [file join $root rtl gt_10gbr_prbs_any.v] \
    [file join $root rtl gt_10gbr_example_stimulus_64b66b_async.v] \
    [file join $root rtl gt_10gbr_example_checking_64b66b_async.v] \
    [file join $root rtl gt_10gbr_example_reset_sync.v] ]
add_files -fileset constrs_1 -norecurse [file join $root xdc ku5p_p7a.xdc]
add_files -fileset constrs_1 -norecurse [file join $root xdc ku5p_p7a_impl.xdc]

# The impl-only constraint file needs an ELABORATED design: its lookups (debug
# hub, clock groups by name, sync flops by cell name) are empty during the
# synthesis pass, and an empty lookup makes Vivado drop the constraint with a
# single [Vivado 12-4739] CRITICAL WARNING while the build still succeeds.
# P6b hit exactly that and split its clock groups into a file marked
# used_in_synthesis false -- same pattern here.
set_property used_in_synthesis false [get_files [file join $root xdc ku5p_p7a_impl.xdc]]

sec "GT IP"
create_ip -name gtwizard_ultrascale -vendor xilinx.com -library ip -module_name gt_10gbr
set gt [get_ips gt_10gbr]

# ONE atomic set_property -dict. Setting TX_REFCLK_FREQUENCY on its own can never
# succeed: while TX moves to 156.25 the RX side is still at the 64.453125 default,
# so "RX and TX frequencies do not allow for PLL sharing" fires and the whole set
# is rolled back; setting RX afterwards then fails the mirrored way.
set cfg [dict create \
    CONFIG.CHANNEL_ENABLE        {X0Y4 X0Y5} \
    CONFIG.TX_DATA_ENCODING      {64B66B_ASYNC} \
    CONFIG.RX_DATA_DECODING      {64B66B_ASYNC} \
    CONFIG.TX_USER_DATA_WIDTH    {64} \
    CONFIG.RX_USER_DATA_WIDTH    {64} \
    CONFIG.TX_INT_DATA_WIDTH     {64} \
    CONFIG.RX_INT_DATA_WIDTH     {64} \
    CONFIG.TX_BUFFER_MODE        {1} \
    CONFIG.RX_BUFFER_MODE        {1} \
    CONFIG.TX_LINE_RATE          {10.3125} \
    CONFIG.RX_LINE_RATE          {10.3125} \
    CONFIG.TX_PLL_TYPE           {QPLL0} \
    CONFIG.RX_PLL_TYPE           {QPLL0} \
    CONFIG.TX_REFCLK_SOURCE      {X0Y4 clk0 X0Y5 clk0} \
    CONFIG.RX_REFCLK_SOURCE      {X0Y4 clk0 X0Y5 clk0} \
    CONFIG.TX_REFCLK_FREQUENCY   {156.25} \
    CONFIG.RX_REFCLK_FREQUENCY   {156.25} \
    CONFIG.TX_OUTCLK_SOURCE      {TXPROGDIVCLK} \
    CONFIG.RX_OUTCLK_SOURCE      {RXPROGDIVCLK} \
    CONFIG.LOCATE_RESET_CONTROLLER       {CORE} \
    CONFIG.LOCATE_TX_USER_CLOCKING       {CORE} \
    CONFIG.LOCATE_RX_USER_CLOCKING       {CORE} \
    CONFIG.LOCATE_COMMON                 {CORE} \
    CONFIG.LOCATE_USER_DATA_WIDTH_SIZING {CORE} ]

set rc [catch {set_property -dict $cfg $gt} e]
puts "ATOMIC_SET rc = $rc"
if {$rc} { error "GT atomic config failed: $e" }

# --- read back every effective parameter and ASSERT it (spec risk R6) --------
set expect {
    CONFIG.TX_DATA_ENCODING    64B66B_ASYNC
    CONFIG.RX_DATA_DECODING    64B66B_ASYNC
    CONFIG.TX_INT_DATA_WIDTH   64
    CONFIG.RX_INT_DATA_WIDTH   64
    CONFIG.TX_USER_DATA_WIDTH  64
    CONFIG.RX_USER_DATA_WIDTH  64
    CONFIG.TX_BUFFER_MODE      1
    CONFIG.RX_BUFFER_MODE      1
    CONFIG.TX_PLL_TYPE         QPLL0
    CONFIG.RX_PLL_TYPE         QPLL0
    CONFIG.TX_LINE_RATE        10.3125
    CONFIG.RX_LINE_RATE        10.3125
    CONFIG.TX_REFCLK_FREQUENCY 156.25
    CONFIG.RX_REFCLK_FREQUENCY 156.25
    CONFIG.TX_OUTCLK_SOURCE    TXPROGDIVCLK
    CONFIG.RX_OUTCLK_SOURCE    RXPROGDIVCLK
    CONFIG.TXPROGDIV_FREQ_VAL  156.25
}
set cfglog [open [file join $root reports p7a_ip_config.txt] w]
puts $cfglog "GT wizard effective configuration read back after the atomic set"
set bad 0
foreach {k v} $expect {
    set got [get_property $k $gt]
    set ok [expr {$got eq $v}]
    if {!$ok} { incr bad }
    puts "EFF $k = <$got> expect=<$v> [expr {$ok ? {OK} : {MISMATCH}}]"
    puts $cfglog "EFF $k = <$got> expect=<$v> [expr {$ok ? {OK} : {MISMATCH}}]"
}
foreach k {CONFIG.CHANNEL_ENABLE CONFIG.TX_REFCLK_SOURCE CONFIG.RX_REFCLK_SOURCE \
           CONFIG.LOCATE_RESET_CONTROLLER CONFIG.FREERUN_FREQUENCY} {
    catch { puts "EFF $k = <[get_property $k $gt]>" ; puts $cfglog "EFF $k = <[get_property $k $gt]>" }
}
puts $cfglog "MISMATCHES = $bad"
close $cfglog
if {$bad != 0} { error "GT configuration readback mismatch count = $bad" }

sec "VIO IP"
# packing must match rtl/p7a_top.v (see the bit map in its section 8)
create_ip -name vio -vendor xilinx.com -library ip -module_name vio_p7a
set_property -dict [list \
    CONFIG.C_NUM_PROBE_IN    {7} \
    CONFIG.C_PROBE_IN0_WIDTH {64} \
    CONFIG.C_PROBE_IN1_WIDTH {96} \
    CONFIG.C_PROBE_IN2_WIDTH {96} \
    CONFIG.C_PROBE_IN3_WIDTH {64} \
    CONFIG.C_PROBE_IN4_WIDTH {96} \
    CONFIG.C_PROBE_IN5_WIDTH {96} \
    CONFIG.C_PROBE_IN6_WIDTH {96} \
    CONFIG.C_NUM_PROBE_OUT   {4} \
    CONFIG.C_PROBE_OUT0_WIDTH {1} \
    CONFIG.C_PROBE_OUT1_WIDTH {1} \
    CONFIG.C_PROBE_OUT2_WIDTH {1} \
    CONFIG.C_PROBE_OUT3_WIDTH {1} \
] [get_ips vio_p7a]

sec "GENERATE"
puts "GT  GENERATE rc = [catch {generate_target all $gt} e1]"
if {$e1 ne ""} { puts "GT  GEN_ERR = $e1" }
puts "GT  IS_LOCKED = [get_property IS_LOCKED $gt]"
catch {puts "GT  LOCK_DETAILS = [get_property LOCK_DETAILS $gt]"}
catch {puts "GT  USED_LICENSE_KEYS = <[get_property USED_LICENSE_KEYS $gt]>"}
puts "VIO GENERATE rc = [catch {generate_target all [get_ips vio_p7a]} e2]"
if {$e2 ne ""} { puts "VIO GEN_ERR = $e2" }

# --- provenance check: the copied PRBS parts must equal what THIS build would
#     generate (spec risk R10: never edit the generated example in place, copy it)
sec "EXAMPLE_PROVENANCE"
puts "EXAMPLE rc = [catch {generate_target example $gt} e3]"
if {$e3 ne ""} { puts "EXAMPLE_ERR = $e3" }
set exdir [file join $proj_dir "p7a_prj.gen" sources_1 ip gt_10gbr gt_10gbr example_design]
# byte-for-byte comparison in pure Tcl: no external tool is assumed to exist in
# Vivado's PATH (an `exec sha256sum` here would abort the build on a machine
# without coreutils).
proc p7a_file_eq {a b} {
    if {![file exists $a] || ![file exists $b]} { return -1 }
    if {[file size $a] != [file size $b]} { return 0 }
    set fa [open $a rb] ; set d1 [read $fa] ; close $fa
    set fb [open $b rb] ; set d2 [read $fb] ; close $fb
    return [expr {$d1 eq $d2 ? 1 : 0}]
}
set prov_bad 0
foreach f {gt_10gbr_prbs_any.v gt_10gbr_example_stimulus_64b66b_async.v \
           gt_10gbr_example_checking_64b66b_async.v gt_10gbr_example_reset_sync.v} {
    set mine [file join $root rtl $f]
    set gen  [file join $exdir $f]
    set eq   [p7a_file_eq $mine $gen]
    set sz   [expr {[file exists $mine] ? [file size $mine] : -1}]
    puts "PROV $f bytes=$sz cmp=$eq [expr {$eq == 1 ? {IDENTICAL} : {DIFFERENT_OR_MISSING}}]"
    if {$eq != 1} { incr prov_bad }
}
puts "PROV_BAD = $prov_bad"

set_property top $top [current_fileset]
update_compile_order -fileset sources_1

sec "SYNTH"
launch_runs synth_1 -jobs 8
wait_on_run synth_1
set sp [get_property PROGRESS [get_runs synth_1]]
set ss [get_property STATUS   [get_runs synth_1]]
puts "SYNTH progress=$sp status=$ss"
if {$sp ne "100%"} { error "synth_1 did not complete: $ss" }

sec "IMPL"
set_property strategy $strategy [get_runs impl_1]
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
set ip_ [get_property PROGRESS [get_runs impl_1]]
set is_ [get_property STATUS   [get_runs impl_1]]
puts "IMPL progress=$ip_ status=$is_"
if {$ip_ ne "100%"} { error "impl_1 did not complete: $is_" }

set bit [file join $proj_dir p7a_prj.runs impl_1 ${top}.bit]
puts "BITSTREAM = $bit"
if {![file exists $bit]} { error "bitstream missing: $bit" }
puts "BITSTREAM_BYTES = [file size $bit]"

sec "DONE"
puts "Now run: vivado -mode batch -source readback_p7a.tcl  (static criteria 1/2/3)"
exit
