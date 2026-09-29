# ============================================================================
# s11_probe3.tcl -- P7b gate 1, ROUND 3 (part 2): the two steps that the round-3
#   session did not reach, run in their own session against the SAME bitstream
#   (sha256 printed below; the board is re-programmed first, as always).
#
#     STEP A  gate 1a: GT internal loopback on channel 0, five modes, with the
#             mode-000 baseline as the built-in negative control
#     STEP B  dclk absolute frequency over ~60 s: five snapshots, wall-clock
#             timestamps taken right next to each snapshot, 32-bit counters
#             unwrapped explicitly (each decrease = one wrap)
#
#   Volatile JTAG programming only; never the on-board QSPI.
# ============================================================================

set here [file normalize [file dirname [info script]]]
set root [file normalize [file join $here ..]]
set bit  [file join $root pcs64_2ch pcs64_2ch.runs impl_1 xxv_loop_top.bit]
set ltx  [file rootname $bit].ltx
proc sec {s} { puts "\nS11 >>>>>>>>>> $s" }
proc say {s} { puts $s }

if {[catch {exec sha256sum $bit} sha]} { set sha "<none>" }
say "S11_BIT_SHA256 $sha"

open_hw_manager
connect_hw_server -url 192.168.0.38:3121
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
set_property PROGRAM.FILE $bit $dev
set_property PROBES.FILE $ltx $dev
set_property FULL_PROBES.FILE $ltx $dev
program_hw_devices $dev
refresh_hw_device $dev
say "S11_PROGRAMMED 1"

set vio [lindex [get_hw_vios -of_objects $dev] 0]
proc findprobe {vio names} {
    set all [get_hw_probes -of_objects $vio]
    foreach n $names { foreach p $all { if {$p eq $n} { return $p } } }
    return ""
}
set NPROBE 48
set IN_LABEL {st0 st1 cnt0 cnt1 dclk_free tx0_free rx0_free rx1_free \
              c0_words c0_ctrl c0_idle c0_e c0_frames \
              c1_words c1_frames c1_ctrl c1_e c1_pay c1_badpay c1_badstart \
              c1_badhdr c1_badterm c1_badlen c1_abort c1_lastw c1_idle c1_misc \
              snap_gen c1_sword_lo c1_sword_hi c0_sword_lo flags err_w dclk_snap \
              err_w2 dclk_snap2 vcc_d vcc_r ferr_d ferr_r bcd_d bcd_r ffe_d ffe_r \
              errv_r e_pre1 e_post1 e_pre0}
set OUT_CANDS {
    {vio_send_cont probe_out0} {vio_cmd_restart probe_out1} {vio_cmd_sysreset probe_out2}
    {sfp1_tx_dis_OBUF vio_cmd_sfp1_tx_dis probe_out3}
    {sfp2_tx_dis_OBUF vio_cmd_sfp2_tx_dis probe_out4}
    {vio_cmd_snap probe_out5} {vio_gt_loopback probe_out6} {vio_pay_sel probe_out7}
}
array set PIN {}
for {set i 0} {$i < $NPROBE} {incr i} {
    set p [findprobe $vio [list [format "oi%02d" $i] "probe_in$i"]]
    if {$p eq ""} { error "probe_in$i not found" }
    set PIN(in,$i) $p
}
for {set i 0} {$i < 8} {incr i} {
    set p [findprobe $vio [lindex $OUT_CANDS $i]]
    if {$p eq ""} { error "probe_out$i not found" }
    set PIN(out,$i) $p
}
proc vset {vio p val} {
    set w 1 ; catch {set w [get_property WIDTH $p]}
    set n [expr {int(ceil($w / 4.0))}]
    set_property OUTPUT_VALUE [format "%0${n}X" [expr {$val & ((1 << $w) - 1)}]] $p
    commit_hw_vio $vio
}
proc vget {vio p} {
    refresh_hw_vio $vio
    set s [get_property INPUT_VALUE $p]
    set r "HEX" ; catch {set r [get_property INPUT_VALUE_RADIX $p]}
    switch -- $r { HEX { return [expr "0x$s"] } BIN { return [expr "0b$s"] } default { return [expr {$s}] } }
}
proc snap {vio} {
    global PIN
    set g0 [expr {([vget $vio $PIN(in,27)] >> 16) & 0xFFFF}]
    vset $vio $PIN(out,5) 1 ; vset $vio $PIN(out,5) 0
    for {set i 0} {$i < 50} {incr i} {
        after 20
        set g1 [expr {([vget $vio $PIN(in,27)] >> 16) & 0xFFFF}]
        if {$g1 != $g0} break
    }
    if {[expr {($g1 - $g0) & 0xFFFF}] != 1} { say "S11_SNAP_FAIL $g0 -> $g1" }
    return $g1
}
proc readall {vio arrname} {
    upvar 1 $arrname A
    global PIN IN_LABEL NPROBE
    snap $vio
    for {set i 0} {$i < $NPROBE} {incr i} { set A([lindex $IN_LABEL $i]) [vget $vio $PIN(in,$i)] }
    set A(st0_hex) [get_property INPUT_VALUE $PIN(in,0)]
}
proc restart {vio} { global PIN ; vset $vio $PIN(out,1) 1 ; vset $vio $PIN(out,1) 0 }
proc readvals {vio arrname} {          ;# no snapshot: read whatever is latched
    upvar 1 $arrname A
    global PIN IN_LABEL NPROBE
    for {set i 0} {$i < $NPROBE} {incr i} { set A([lindex $IN_LABEL $i]) [vget $vio $PIN(in,$i)] }
}

# ===========================================================================
sec "S11_A_GATE1A_LOOPBACK"
say "S11_A_BASELINE before any loopback:"
array set A0 {}
readall $vio A0
say "S11_A0 ch0 blk=[expr {($A0(st0)>>1)&1}] status=[expr {($A0(st0)>>2)&1}] los=[expr {($A0(st0)>>10)&1}] frames=$A0(c0_frames) ctrl=$A0(c0_ctrl) idle=$A0(c0_idle) e=$A0(c0_e) sw_lo=$A0(c0_sword_lo)"
say "S11_A0 ch1 blk=[expr {($A0(st1)>>1)&1}] frames=$A0(c1_frames) e=$A0(c1_e)"
# arm the generator so channel 0 has something to loop back
vset $vio $PIN(out,0) 1
restart $vio
after 1500
foreach mode {0 1 2 4 6 0} {
    vset $vio $PIN(out,6) $mode
    after 800
    array set PA$mode {}
    set an "PA$mode"
    upvar 0 $an PA
    readall $vio PA
    say "S11_A mode=$mode t0: ch0 blk=[expr {($PA(st0)>>1)&1}] status=[expr {($PA(st0)>>2)&1}] los=[expr {($PA(st0)>>10)&1}] frames=$PA(c0_frames) ctrl=$PA(c0_ctrl) idle=$PA(c0_idle) e=$PA(c0_e) e_pre0=$PA(e_pre0) sw_lo=$PA(c0_sword_lo)"
    say "S11_A mode=$mode t0: ch1 blk=[expr {($PA(st1)>>1)&1}] frames=$PA(c1_frames) e=$PA(c1_e) badpay=$PA(c1_badpay)"
    after 2000
    array set PB$mode {}
    set bn "PB$mode"
    upvar 0 $bn PB
    readall $vio PB
    say "S11_A mode=$mode WIN: d_c0_frames [expr {([set PB(c0_frames)] - [set PA(c0_frames)]) & 0xFFFFFFFF}] d_c0_e [expr {([set PB(c0_e)] - [set PA(c0_e)]) & 0xFFFFFFFF}] d_c0_ctrl [expr {([set PB(c0_ctrl)] - [set PA(c0_ctrl)]) & 0xFFFFFFFF}] d_c1_frames [expr {([set PB(c1_frames)] - [set PA(c1_frames)]) & 0xFFFFFFFF}] d_c1_e [expr {([set PB(c1_e)] - [set PA(c1_e)]) & 0xFFFFFFFF}]"
    say "S11_A mode=$mode WIN: ch0 blk=[expr {($PB(st0)>>1)&1}] frames_total=$PB(c0_frames) e_total=$PB(c0_e)"
}
vset $vio $PIN(out,6) 0
vset $vio $PIN(out,0) 0
after 300
array set Z {}
readall $vio Z
say "S11_A_RESTORED ch0 blk=[expr {($Z(st0)>>1)&1}] c0_frames=$Z(c0_frames) c1_frames=$Z(c1_frames)"

# ===========================================================================
sec "S11_B_DCLK_FREQUENCY"
set prev_d 0 ; set prev_r 0 ; set tot_d 0 ; set tot_r 0
set wraps_d 0 ; set wraps_r 0 ; set t0 0 ; set tprev 0
for {set k 0} {$k < 5} {incr k} {
    snap $vio
    set ta [clock milliseconds]      ;# RIGHT next to the snapshot (was ~2s late)
    array set F {}
    readvals $vio F
    set cur_d $F(dclk_snap)
    set cur_r $F(rx1_free)
    if {$k == 0} { set t0 $ta } else {
        if {$cur_d < $prev_d} { incr wraps_d }
        if {$cur_r < $prev_r} { incr wraps_r }
        if {$cur_d < $prev_d} { set tot_d [expr {$tot_d + $cur_d + (1 << 32) - $prev_d}] } \
        else { set tot_d [expr {$tot_d + $cur_d - $prev_d}] }
        if {$cur_r < $prev_r} { set tot_r [expr {$tot_r + $cur_r + (1 << 32) - $prev_r}] } \
        else { set tot_r [expr {$tot_r + $cur_r - $prev_r}] }
    }
    set prev_d $cur_d ; set prev_r $cur_r
    say "S11_B k=$k wall_ms=$ta dclk_snap=$cur_d rx1_free=$cur_r tot_d=$tot_d tot_r=$tot_r wraps_d=$wraps_d wraps_r=$wraps_r"
    if {$k < 4} { after 15000 }
}
set t1 [clock milliseconds]
set wall [expr {($t1 - $t0) / 1000.0}]
say "S11_B_WALL_SECONDS $wall TOT_D $tot_d TOT_R $tot_r"
say "S11_B_RX_OVER_DCLK [expr {$tot_r / double($tot_d)}]"
say "S11_B_DCLK_MHZ_IF_RX_IS_156250000 [expr {$tot_d / ($tot_r / 156250000.0) / 1.0e6}]"
say "S11_B_RX_MHZ_IF_DCLK_IS_100000000 [expr {$tot_r / ($tot_d / 100000000.0) / 1.0e6}]"
say "S11_B_DCLK_MHZ_FROM_WALLCLOCK [expr {$tot_d / $wall / 1.0e6}]"
say "S11_B_RX_MHZ_FROM_WALLCLOCK [expr {$tot_r / $wall / 1.0e6}]"

say "S11_DONE"
disconnect_hw_server
