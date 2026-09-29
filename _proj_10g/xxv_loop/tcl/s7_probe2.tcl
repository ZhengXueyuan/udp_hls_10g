# ============================================================================
# s7_probe2.tcl -- P7b gate 1, ROUND 2 board session.
#
#   Closes the four gaps that round 1 declared, on the SAME bitstream:
#     A1  gate 1a: GT internal loopback (ch0) -- self-sent frames收回 + its own
#         negative control (mode 000 must NOT deliver frames)
#     A2  the startup /E/ transient: the /E/ counter is now split into
#         "before the first completed frame" vs "after"
#     A3  dclk absolute frequency: 5 snapshots over ~60 s with the wall-clock
#         timestamps taken IMMEDIATELY next to each snapshot, 32-bit counters
#         unwrapped explicitly (the project's <20 s rule exists to dodge wrap;
#         here the wrap is detected and counted instead)
#     A4  non-trivial payload: the parameterised traffic copy can send an
#         all-ONES payload instead of the vendor's all-zero one
#     U8  stat_* clock domain: the same stat_* signals are counted in dclk and
#         in the ch1 recovered domain at the same time (in34..in47)
#
#   Every reading is preceded by a snapshot request whose counter must advance
#   by exactly 1.  Volatile JTAG programming only -- never the on-board QSPI.
# ============================================================================

set here [file normalize [file dirname [info script]]]
set root [file normalize [file join $here ..]]
set bit  [lindex $argv 0]
if {$bit eq ""} { set bit [file join $root pcs64_2ch pcs64_2ch.runs impl_1 xxv_loop_top.bit] }
if {![file exists $bit]} { error "bitstream not found: $bit" }
set ltx [file rootname $bit].ltx

proc sec {s} { puts "\nS7 >>>>>>>>>> $s" }
proc say {s} { puts $s }

sec "S7_ENV"
say "S7_BIT $bit"
say "S7_BIT_BYTES [file size $bit]"
if {[catch {exec sha256sum $bit} sha]} { set sha "<sha256sum unavailable>" }
say "S7_BIT_SHA256 $sha"

open_hw_manager
connect_hw_server -url 192.168.0.38:3121
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
set_property PROGRAM.FILE $bit $dev
if {[file exists $ltx]} {
    set_property PROBES.FILE $ltx $dev
    set_property FULL_PROBES.FILE $ltx $dev
}
program_hw_devices $dev
refresh_hw_device $dev
say "S7_PROGRAMMED 1"

set vio [lindex [get_hw_vios -of_objects $dev] 0]
if {$vio eq ""} { error "no VIO in the programmed design" }
say "S7_ALLPROBES [get_hw_probes -of_objects $vio]"

proc findprobe {vio names} {
    set all [get_hw_probes -of_objects $vio]
    foreach n $names { foreach p $all { if {$p eq $n} { return $p } } }
    return ""
}
set NPROBE 48
set IN_NAMES {}
for {set i 0} {$i < $NPROBE} {incr i} { lappend IN_NAMES [format "oi%02d" $i] }
# 48 labels, in the RTL's own probe order.  oi32/oi33 and oi34/oi35 are
# deliberate DUPLICATES (err_w / dclk_snap are wired to two VIO pins each).
# The first version of this list had 46 entries, which silently shifted every
# label from 34 upwards and made the stat-domain counters read as the wrong nets.
set IN_LABEL {st0 st1 cnt0 cnt1 dclk_free tx0_free rx0_free rx1_free \
              c0_words c0_ctrl c0_idle c0_e c0_frames \
              c1_words c1_frames c1_ctrl c1_e c1_pay c1_badpay c1_badstart \
              c1_badhdr c1_badterm c1_badlen c1_abort c1_lastw c1_idle c1_misc \
              snap_gen c1_sword_lo c1_sword_hi c0_sword_lo flags err_w dclk_snap \
              err_w2 dclk_snap2 vcc_d vcc_r ferr_d ferr_r bcd_d bcd_r ffe_d ffe_r \
              errv_r e_pre1 e_post1 e_pre0}
if {[llength $IN_LABEL] != $NPROBE} { error "IN_LABEL/NPROBE mismatch" }
set OUT_NAMES {send_cont cmd_restart cmd_sysreset cmd_sfp1_tx_dis cmd_sfp2_tx_dis \
               cmd_snap gt_loopback pay_sel}
set OUT_CANDS {
    {vio_send_cont probe_out0}
    {vio_cmd_restart probe_out1}
    {vio_cmd_sysreset probe_out2}
    {sfp1_tx_dis_OBUF vio_cmd_sfp1_tx_dis probe_out3}
    {sfp2_tx_dis_OBUF vio_cmd_sfp2_tx_dis probe_out4}
    {vio_cmd_snap probe_out5}
    {vio_gt_loopback probe_out6}
    {vio_pay_sel probe_out7}
}
array set PIN {}
for {set i 0} {$i < $NPROBE} {incr i} {
    set p [findprobe $vio [list [lindex $IN_NAMES $i] "probe_in$i"]]
    if {$p eq ""} { error "probe_in$i not found" }
    set PIN(in,$i) $p
}
for {set i 0} {$i < 8} {incr i} {
    set p [findprobe $vio [lindex $OUT_CANDS $i]]
    if {$p eq ""} { error "probe_out$i ([lindex $OUT_NAMES $i]) not found" }
    set PIN(out,$i) $p
}
say "S7_PROBE_MAP_OK $NPROBE in / 8 out"

proc vset {vio p val} {
    set w 1 ; catch {set w [get_property WIDTH $p]}
    set n [expr {int(ceil($w / 4.0))}]
    set s [format "%0${n}X" [expr {$val & ((1 << $w) - 1)}]]
    set_property OUTPUT_VALUE $s $p
    commit_hw_vio $vio
}
proc vget {vio p} {
    refresh_hw_vio $vio
    set s [get_property INPUT_VALUE $p]
    set r "HEX" ; catch {set r [get_property INPUT_VALUE_RADIX $p]}
    switch -- $r {
        HEX { return [expr "0x$s"] } BIN { return [expr "0b$s"] }
        OCT { return [expr "0o$s"] } default { return [expr {$s}] }
    }
}
set GEN 0
proc snap {vio} {
    global PIN GEN
    set g0 [expr {([vget $vio $PIN(in,27)] >> 16) & 0xFFFF}]
    vset $vio $PIN(out,5) 1
    vset $vio $PIN(out,5) 0
    set g1 $g0
    for {set i 0} {$i < 50} {incr i} {
        after 20
        set g1 [expr {([vget $vio $PIN(in,27)] >> 16) & 0xFFFF}]
        if {$g1 != $g0} break
    }
    set GEN $g1
    set d [expr {($g1 - $g0) & 0xFFFF}]
    if {$d != 1} { say "S7_SNAP_FAIL gen $g0 -> $g1" }
    return $d
}
proc readall {vio arrname} {
    upvar 1 $arrname A
    global PIN IN_LABEL NPROBE
    snap $vio
    for {set i 0} {$i < $NPROBE} {incr i} {
        set A([lindex $IN_LABEL $i]) [vget $vio $PIN(in,$i)]
    }
    set sg $A(snap_gen)
    set A(ack_dclk) [expr {($sg >> 3) & 1}]
    set A(ack_tx0)  [expr {($sg >> 2) & 1}]
    set A(ack_rx0)  [expr {($sg >> 1) & 1}]
    set A(ack_rx1)  [expr {($sg >> 0) & 1}]
    set A(st0_hex)  [get_property INPUT_VALUE $PIN(in,0)]
}
proc cs {v} { return [expr {($v >> 13) & 0x1F}] }
proc st {tag v} {
    say "S7_ST $tag gtpg=[expr {($v>>0)&1}] blk=[expr {($v>>1)&1}] status=[expr {($v>>2)&1}] hiber=[expr {($v>>3)&1}] rxlf=[expr {($v>>4)&1}] frerr=[expr {($v>>5)&1}] badc=[expr {($v>>6)&1}] errv=[expr {($v>>7)&1}] fifo=[expr {($v>>8)&1}] txlf=[expr {($v>>9)&1}] los=[expr {($v>>10)&1}] urrst=[expr {($v>>11)&1}] utrst=[expr {($v>>12)&1}] cs=[expr {($v>>13)&0x1F}]"
}
proc restart {vio pinarr} {
    upvar 1 $pinarr PIN
    vset $vio $PIN(out,1) 1
    vset $vio $PIN(out,1) 0
}
proc set_level {vio p v} { vset $vio $p $v }

# ===========================================================================
sec "S7_STEP1_LINK"
after 400
array set A {}
readall $vio A
st ch0 $A(st0)
st ch1 $A(st1)
say "S7_S1 st0_hex $A(st0_hex)"
say "S7_S1 c1 e=$A(c1_e) e_pre1=$A(e_pre1) e_post1=$A(e_post1) frames=$A(c1_frames)"
say "S7_S1 c0 e=$A(c0_e) e_pre0=$A(e_pre0) frames=$A(c0_frames)"
say "S7_S1 statdom vcc_d=$A(vcc_d) vcc_r=$A(vcc_r) ferr_d=$A(ferr_d) ferr_r=$A(ferr_r) bcd_d=$A(bcd_d) bcd_r=$A(bcd_r) ffe_d=$A(ffe_d) ffe_r=$A(ffe_r) errv_r=$A(errv_r)"

# ===========================================================================
sec "S7_STEP2_VENDOR_20PKT_RUN"
after 400
array set B {}
readall $vio B
say "S7_S2 cs [cs $B(st0)] cpl_hex $B(st0_hex)"
say "S7_S2 c1 frames=$B(c1_frames) pay=$B(c1_pay) e=$B(c1_e) badpay=$B(c1_badpay) badstart=$B(c1_badstart) badhdr=$B(c1_badhdr) badterm=$B(c1_badterm) badlen=$B(c1_badlen) lastw=$B(c1_lastw)"
say "S7_S2 sword_hi $B(c1_sword_hi) sword_lo $B(c1_sword_lo)"

# ===========================================================================
sec "S7_STEP3_STAT_DOMAIN_WINDOW"
# Streaming window: this is simultaneously the U8 experiment (dclk count vs rx
# count of the same stat_* signals) and a zero-error window.
vset $vio $PIN(out,0) 1
restart $vio PIN
after 1500
array set C {}
readall $vio C
say "S7_S3_T0 c1_words $C(c1_words) frames $C(c1_frames) e $C(c1_e) vcc_d $C(vcc_d) vcc_r $C(vcc_r) ferr_d $C(ferr_d) ferr_r $C(ferr_r) bcd_d $C(bcd_d) bcd_r $C(bcd_r) ffe_d $C(ffe_d) ffe_r $C(ffe_r) errv_r $C(errv_r) dclk_snap $C(dclk_snap)"
after 8000
array set D {}
readall $vio D
say "S7_S3_T1 c1_words $D(c1_words) frames $D(c1_frames) e $D(c1_e) vcc_d $D(vcc_d) vcc_r $D(vcc_r) ferr_d $D(ferr_d) ferr_r $D(ferr_r) bcd_d $D(bcd_d) bcd_r $D(bcd_r) ffe_d $D(ffe_d) ffe_r $D(ffe_r) errv_r $D(errv_r) dclk_snap $D(dclk_snap)"
foreach k {c1_words c1_frames c1_pay c1_e c1_badpay c1_badstart c1_badhdr c1_badterm c1_badlen c1_abort vcc_d vcc_r ferr_d ferr_r bcd_d bcd_r ffe_d ffe_r errv_r c0_frames c0_e} {
    say "S7_S3_D $k [expr {([set D($k)] - [set C($k)]) & 0xFFFFFFFF}]"
}
set dd [expr {($D(dclk_snap) - $C(dclk_snap)) & 0xFFFFFFFF}]
say "S7_S3_DD $dd"
foreach pair {c1_words c1_frames c1_pay} {
    set dv [expr {([set D($pair)] - [set C($pair)]) & 0xFFFFFFFF}]
    say "S7_S3_RATE $pair per_dclk [expr {$dv / double($dd)}]"
}
# U8 verdict lines, computed here so the log carries the arithmetic
foreach k {vcc ferr bcd ffe} {
    set dv [expr {([set D(${k}_d)] - [set C(${k}_d)]) & 0xFFFFFFFF}]
    set dr [expr {([set D(${k}_r)] - [set C(${k}_r)]) & 0xFFFFFFFF}]
    if {$dr > 0} {
        say "S7_U8 $k dclk=$dv rx=$dr ratio_rx_over_dclk [expr {$dr / double($dv)}] (1.00 => dclk-domain pulses; ~1.56 => rx-domain pulses)"
    } else {
        say "S7_U8 $k dclk=$dv rx=$dr (rx counter never advanced)"
    }
}

# ===========================================================================
sec "S7_STEP4_STOP_AND_JUDGE"
vset $vio $PIN(out,0) 0
after 250
array set E {}
readall $vio E
say "S7_S4 cs [cs $E(st0)] cpl_hex $E(st0_hex)"
say "S7_S4 c1 frames=$E(c1_frames) e=$E(c1_e) e_pre1=$E(e_pre1) e_post1=$E(e_post1)"
st ch0 $E(st0)
st ch1 $E(st1)

# ===========================================================================
sec "S7_STEP5_ONES_PAYLOAD"
vset $vio $PIN(out,7) 1
vset $vio $PIN(out,0) 1
restart $vio PIN
after 600
array set F {}
readall $vio F
say "S7_S5A c1 frames=$F(c1_frames) pay=$F(c1_pay) badpay=$F(c1_badpay) badstart=$F(c1_badstart) badhdr=$F(c1_badhdr) badterm=$F(c1_badterm) badlen=$F(c1_badlen) e=$F(c1_e) lastw=$F(c1_lastw)"
after 1500
array set G {}
readall $vio G
say "S7_S5B c1 frames=$G(c1_frames) pay=$G(c1_pay) badpay=$G(c1_badpay) badstart=$G(c1_badstart) badhdr=$G(c1_badhdr) badterm=$G(c1_badterm) badlen=$G(c1_badlen) e=$G(c1_e)"
set s5f [expr {([set G(c1_frames)] - [set F(c1_frames)]) & 0xFFFFFFFF}]
set s5p [expr {([set G(c1_pay)] - [set F(c1_pay)]) & 0xFFFFFFFF}]
set s5b [expr {([set G(c1_badpay)] - [set F(c1_badpay)]) & 0xFFFFFFFF}]
say "S7_S5_WIN frames=$s5f paywords=$s5p badpay=$s5b"
if {$s5f > 0} { say "S7_S5_PAYWORDS_PER_FRAME [expr {$s5p / double($s5f)}] (expect 29.0)" }
vset $vio $PIN(out,0) 0
after 250
array set H {}
readall $vio H
say "S7_S5_CS [cs $H(st0)] (0x1F = never ran, 2 = no block lock, 1 = SUCCESSFUL)"
say "S7_S5_C1FINAL frames=$H(c1_frames) e=$H(c1_e)"

# ===========================================================================
sec "S7_STEP6_BACK_TO_ZERO_PAYLOAD"
vset $vio $PIN(out,7) 0
vset $vio $PIN(out,0) 1
restart $vio PIN
after 600
array set I {}
readall $vio I
say "S7_S6 frames=$I(c1_frames) badpay=$I(c1_badpay) badstart=$I(c1_badstart) badhdr=$I(c1_badhdr)"
vset $vio $PIN(out,0) 0
after 250
array set J {}
readall $vio J
say "S7_S6_CS [cs $J(st0)]"

# ===========================================================================
sec "S7_STEP7_GATE1A_LOOPBACK"
# GT internal loopback on ch0 only.  Judgement: ch0's own receiver must start
# delivering the frames ch0 transmits (c0_frames grows, content checks clean).
# Negative control: mode 000 must deliver none.
vset $vio $PIN(out,0) 1
restart $vio PIN
foreach mode {0 2 1 4 6} {
    vset $vio $PIN(out,6) $mode
    after 1200
    array set L$mode {}
    set arrname "L$mode"
    upvar 0 $arrname LA
    readall $vio LA
    say "S7_1A mode=$mode ch0 blk=[expr {($LA(st0)>>1)&1}] status=[expr {($LA(st0)>>2)&1}] los=[expr {($LA(st0)>>10)&1}] frames=$LA(c0_frames) ctrl=$LA(c0_ctrl) e=$LA(c0_e) idle=$LA(c0_idle) e_pre0=$LA(e_pre0) sw_lo=$LA(c0_sword_lo) sw_hi=$LA(c0_sword_hi)"
    say "S7_1A mode=$mode ch1 blk=[expr {($LA(st1)>>1)&1}] frames=$LA(c1_frames) e=$LA(c1_e)"
    after 1500
    array set M$mode {}
    set arrname2 "M$mode"
    upvar 0 $arrname2 MA
    readall $vio MA
    say "S7_1A_WIN mode=$mode d_c0_frames [expr {([set MA(c0_frames)] - [set $arrname(c0_frames)]) & 0xFFFFFFFF}] d_c0_e [expr {([set MA(c0_e)] - [set $arrname(c0_e)]) & 0xFFFFFFFF}] d_c1_frames [expr {([set MA(c1_frames)] - [set $arrname(c1_frames)]) & 0xFFFFFFFF}]"
}
vset $vio $PIN(out,6) 0
vset $vio $PIN(out,0) 0
after 300
array set N {}
readall $vio N
say "S7_1A_RESTORED ch0 blk=[expr {($N(st0)>>1)&1}] c0_frames=$N(c0_frames) c1_frames=$N(c1_frames) c1_e=$N(c1_e)"

# ===========================================================================
sec "S7_STEP8_DCLK_FREQUENCY_60S"
# Five snapshots with the wall clock sampled right next to each snapshot; the
# 32-bit counters are unwrapped explicitly (each decrease = one wrap).
unset -nocomplain PREV DCLK0 RX1_0
set wraps_d 0 ; set wraps_r 0
set tot_d 0 ; set tot_r 0
set t0 0
for {set k 0} {$k < 5} {incr k} {
    set ta [clock milliseconds]
    array set P {}
    readall $vio P
    set tb [clock milliseconds]
    set cur_d $P(dclk_snap)
    set cur_r $P(rx1_free)
    if {$k == 0} {
        set t0 $tb
        set PREV_D $cur_d ; set PREV_R $cur_r
    } else {
        if {$cur_d < $PREV_D} { incr wraps_d }
        if {$cur_r < $PREV_R} { incr wraps_r }
        set tot_d [expr {$tot_d + ($cur_d - $PREV_D) + ($cur_d < $PREV_D ? (1 << 32) : 0)}]
        set tot_r [expr {$tot_r + ($cur_r - $PREV_R) + ($cur_r < $PREV_R ? (1 << 32) : 0)}]
        set PREV_D $cur_d ; set PREV_R $cur_r
    }
    say "S7_F k=$k wall_ms=$tb dclk_snap=$cur_d rx1_free=$cur_r wraps_d=$wraps_d wraps_r=$wraps_r tot_d=$tot_d tot_r=$tot_r"
    if {$k < 4} { after 15000 }
}
set t1 [clock milliseconds]
set wall [expr {($t1 - $t0) / 1000.0}]
say "S7_F_WALL_SECONDS $wall TOT_D $tot_d TOT_R $tot_r"
say "S7_F_DCLK_HZ_IF_WALL_TRUE [expr {$tot_d / $wall}]"
say "S7_F_RX_OVER_DCLK [expr {$tot_r / double($tot_d)}]"
say "S7_F_DCLK_HZ_IF_RX_IS_156250000 [expr {$tot_d / ($tot_r / 156250000.0)}]"
say "S7_F_RX_MHZ_IF_DCLK_IS_100000000 [expr {$tot_r / ($tot_d / 100000000.0) / 1.0e6}]"

vset $vio $PIN(out,6) 0
vset $vio $PIN(out,7) 0
vset $vio $PIN(out,0) 0
vset $vio $PIN(out,3) 0
vset $vio $PIN(out,4) 0
after 200
array set Z {}
readall $vio Z
say "S7_FINAL cs [cs $Z(st0)] st0_hex $Z(st0_hex)"
st ch0 $Z(st0)
st ch1 $Z(st1)
say "S7_FINAL c1 frames=$Z(c1_frames) e=$Z(c1_e) badpay=$Z(c1_badpay) c0_frames=$Z(c0_frames) c0_e=$Z(c0_e)"
say "S7_FINAL acks dclk=$Z(ack_dclk) tx0=$Z(ack_tx0) rx0=$Z(ack_rx0) rx1=$Z(ack_rx1)"

disconnect_hw_server
say "S7_DONE"
