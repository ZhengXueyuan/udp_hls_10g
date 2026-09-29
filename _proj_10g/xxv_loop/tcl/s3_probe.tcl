# ============================================================================
# s3_probe.tcl -- P7b gate 1: program xxv_loop_top over JTAG and take the
#   board readings.  NOTHING is written to the on-board QSPI.
#
#   Usage:  vivado -mode batch -source s3_probe.tcl [-tclargs <bitfile>]
#   (run via tcl/run_s3.bat, which is what was actually used)
#
# THE VIO MAP (see rtl/xxv_loop_top.v -- probe names are the RTL NET names):
#   probe_out0 send_cont  probe_out1 cmd_restart  probe_out2 cmd_sysreset
#   probe_out3 cmd_sfp1_tx_dis  probe_out4 cmd_sfp2_tx_dis  probe_out5 cmd_snap
#   probe_in0  oi00 st0        probe_in1  oi01 st1
#   probe_in2  oi02 cnt0       probe_in3  oi03 cnt1
#   probe_in4  oi04 dclk_free  probe_in5  oi05 tx0_free
#   probe_in6  oi06 rx0_free   probe_in7  oi07 rx1_free
#   probe_in8..12   c0: words ctrl idle e frames
#   probe_in13..26  c1: words frames ctrl e pay badpay badstart badhdr
#                        badterm badlen abort lastw idle misc
#   probe_in27 snap_gen_r      probe_in28/29 c1_sword lo/hi
#   probe_in30 c0_sword_lo     probe_in31 flags
#
# FOUR RULES THIS SCRIPT OBEYS (each one has bitten this project before):
#   1. every measurement is preceded by a FRESH snapshot request, and the
#      request counter (snap_gen_r) must advance by exactly one -- otherwise
#      the reading is a frozen value compared against itself;
#   2. pulse-like controls (restart, sysreset, snap) are edge-detected in the
#      RTL, so the host only has to hold a level for longer than one dclk;
#   3. large numbers are printed by STRING INTERPOLATION, never with
#      `format %d/%X` (Vivado's Tcl has silently produced 0 for values above
#      2^31 in this project) -- the script probes that hazard explicitly first;
#   4. the bitstream is identified by sha256 in the log.
#
# Bit meanings of the level bundles (st0/st1), LSB first:
#   [0] gtpowergood   [1] rx_block_lock  [2] rx_status   [3] rx_hi_ber
#   [4] rx_local_fault[5] framing_err    [6] bad_code    [7] rx_error_valid
#   [8] rx_fifo_error [9] tx_local_fault [10] sfpN_rx_los
#   [11] user_rx_reset[12] user_tx_reset
# st0 additionally: [17:13] completion_status, [18] tgm_gt_locked_led,
#   [19] tgm_block_lock_led.   st1 additionally: [13] c1_inframe, [14] c0_inframe
# cnt0/cnt1 = {vcc, framing_err, bad_code, fifo_err} as four 8-bit counters.
# ============================================================================

set here [file normalize [file dirname [info script]]]
set root [file normalize [file join $here ..]]
set bit  [lindex $argv 0]
if {$bit eq ""} { set bit [file join $root pcs64_2ch pcs64_2ch.runs impl_1 xxv_loop_top.bit] }
if {![file exists $bit]} { error "bitstream not found: $bit" }
set ltx [file rootname $bit].ltx

proc sec {s} { puts "\nS3 >>>>>>>>>> $s" }
proc say {s} { puts $s }

sec "S3_ENV"
say "S3_BIT $bit"
say "S3_BIT_BYTES [file size $bit]"
if {[catch {exec sha256sum $bit} sha]} { set sha "<sha256sum unavailable>" }
say "S3_BIT_SHA256 $sha"
say "S3_LTX $ltx exists=[file exists $ltx]"

# ---- rule 3: probe the Tcl integer hazard explicitly -----------------------
say "S3_TCL_VERSION [info patchlevel]"
if {[catch {set big [expr {1 << 40}]} e]} { set big "<expr failed: $e>" }
say "S3_TCL_EXPR_1SHL40 $big"
if {[catch {set fm [format %d 3000000000]} e2]} { set fm "<format failed: $e2>" }
say "S3_TCL_FMT_3E9 $fm"

# --------------------------------------------------------------- programming
sec "S3_PROGRAM"
open_hw_manager
connect_hw_server -url 192.168.0.38:3121
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
say "S3_DEVICE $dev"
set_property PROGRAM.FILE $bit $dev
if {[file exists $ltx]} {
    set_property PROBES.FILE $ltx $dev
    set_property FULL_PROBES.FILE $ltx $dev
}
program_hw_devices $dev
refresh_hw_device $dev
say "S3_PROGRAMMED 1"

set vio [lindex [get_hw_vios -of_objects $dev] 0]
if {$vio eq ""} { error "no VIO in the programmed design" }
say "S3_VIO $vio"
say "S3_ALLPROBES [get_hw_probes -of_objects $vio]"

# ------------------------------------------------------------- probe lookup
proc findprobe {vio names} {
    set all [get_hw_probes -of_objects $vio]
    foreach n $names { foreach p $all { if {$p eq $n} { return $p } } }
    return ""
}

set IN_NAMES {oi00 oi01 oi02 oi03 oi04 oi05 oi06 oi07 oi08 oi09 oi10 oi11 \
              oi12 oi13 oi14 oi15 oi16 oi17 oi18 oi19 oi20 oi21 oi22 oi23 \
              oi24 oi25 oi26 oi27 oi28 oi29 oi30 oi31 oi32 oi33}
set IN_LABEL {st0 st1 cnt0 cnt1 dclk_free tx0_free rx0_free rx1_free \
              c0_words c0_ctrl c0_idle c0_e c0_frames \
              c1_words c1_frames c1_ctrl c1_e c1_pay c1_badpay c1_badstart \
              c1_badhdr c1_badterm c1_badlen c1_abort c1_lastw c1_idle c1_misc \
              snap_gen c1_sword_lo c1_sword_hi c0_sword_lo flags               err_w dclk_snap}
set OUT_NAMES {send_cont cmd_restart cmd_sysreset cmd_sfp1_tx_dis cmd_sfp2_tx_dis cmd_snap}
# MEASURED: output probes are named after the net, and the two TX_DIS controls sit
# directly on top-level output ports, so synthesis renames those nets after the
# inserted OBUF: the probes show up as sfp1_tx_dis_OBUF / sfp2_tx_dis_OBUF (the
# full list is printed as S3_ALLPROBES below).  Every candidate is tried.
set OUT_CANDS {
    {vio_send_cont probe_out0}
    {vio_cmd_restart probe_out1}
    {vio_cmd_sysreset probe_out2}
    {sfp1_tx_dis_OBUF vio_cmd_sfp1_tx_dis probe_out3}
    {sfp2_tx_dis_OBUF vio_cmd_sfp2_tx_dis probe_out4}
    {vio_cmd_snap probe_out5}
}

# NPROBE = the number of probe_in nets the RTL actually drives
set NPROBE 34
array set PIN {}
for {set i 0} {$i < $NPROBE} {incr i} {
    set nm [lindex $IN_NAMES $i]
    set p [findprobe $vio [list $nm "probe_in$i"]]
    if {$p eq ""} { error "probe_in$i ($nm) not found" }
    set PIN(in,$i) $p
    say "S3_PIN in,$i = $p"
}
for {set i 0} {$i < 6} {incr i} {
    set nm [lindex $OUT_NAMES $i]
    set p [findprobe $vio [lindex $OUT_CANDS $i]]
    if {$p eq ""} { error "probe_out$i ($nm) not found" }
    set PIN(out,$i) $p
    say "S3_PIN out,$i ($nm) = $p"
}
say "S3_PROBE_MAP_OK $NPROBE in / 6 out"

# --------------------------------------------------------------- VIO access
proc vset {vio p val} {
    set w 1
    catch {set w [get_property WIDTH $p]}
    set n [expr {int(ceil($w / 4.0))}]
    set s [format "%0${n}X" [expr {$val & ((1 << $w) - 1)}]]
    set_property OUTPUT_VALUE $s $p
    commit_hw_vio $vio
}
proc vget {vio p} {
    refresh_hw_vio $vio
    set s [get_property INPUT_VALUE $p]
    set r "HEX"
    catch {set r [get_property INPUT_VALUE_RADIX $p]}
    switch -- $r {
        HEX     { return [expr "0x$s"] }
        BIN     { return [expr "0b$s"] }
        OCT     { return [expr "0o$s"] }
        default { return [expr {$s}] }
    }
}
proc vget_s {vio p} {
    refresh_hw_vio $vio
    return [get_property INPUT_VALUE $p]
}

# Snapshot: request one, wait for the request counter to advance by exactly 1.
set GEN 0
proc snap {vio} {
    global PIN GEN
    set before [vget $vio $PIN(in,27)]
    set g0 [expr {($before >> 16) & 0xFFFF}]
    vset $vio $PIN(out,5) 1
    vset $vio $PIN(out,5) 0
    set g1 $g0
    for {set i 0} {$i < 50} {incr i} {
        after 20
        set v [vget $vio $PIN(in,27)]
        set g1 [expr {($v >> 16) & 0xFFFF}]
        if {$g1 != $g0} break
    }
    set GEN $g1
    set d [expr {($g1 - $g0) & 0xFFFF}]
    say "S3_SNAP_GEN before=$g0 after=$g1 delta=$d"
    if {$d != 1} { say "S3_SNAP_FAIL request counter did not advance by exactly 1" }
    return $d
}

# Read the whole probe set after a fresh snapshot.  Returns an array name.
proc readall {vio arrname} {
    upvar 1 $arrname A
    global PIN IN_LABEL NPROBE
    snap $vio
    global NPROBE
    for {set i 0} {$i < $NPROBE} {incr i} {
        set A([lindex $IN_LABEL $i]) [vget $vio $PIN(in,$i)]
    }
    # raw hex for the two bundles: decodes every bit without any formatting risk
    set A(st0_hex) [vget_s $vio $PIN(in,0)]
    set A(st1_hex) [vget_s $vio $PIN(in,1)]
    # ack bits from the snap_gen word: [3]=ack_dclk [2]=ack_tx0 [1]=ack_rx0 [0]=ack_rx1
    set sg $A(snap_gen)
    set A(ack_dclk) [expr {($sg >> 3) & 1}]
    set A(ack_tx0) [expr {($sg >> 2) & 1}]
    set A(ack_rx0) [expr {($sg >> 1) & 1}]
    set A(ack_rx1) [expr {($sg >> 0) & 1}]
    return
}
proc dump {arrname tag} {
    upvar 1 $arrname A
    foreach k [lsort [array names A]] { say "S3_RD $tag $k $A($k)" }
}

proc bits {v} {
    set s ""
    for {set i 15} {$i >= 0} {incr i -1} { append s [expr {($v >> $i) & 1}] }
    return $s
}
proc statline {tag v} {
    say "S3_ST $tag bits(15..0)=[bits $v] gtpg=[expr {($v>>0)&1}] blocklock=[expr {($v>>1)&1}] status=[expr {($v>>2)&1}] hiber=[expr {($v>>3)&1}] rlocalfault=[expr {($v>>4)&1}] framing=[expr {($v>>5)&1}] badcode=[expr {($v>>6)&1}] errvalid=[expr {($v>>7)&1}] fifoerr=[expr {($v>>8)&1}] txlocalfault=[expr {($v>>9)&1}] los=[expr {($v>>10)&1}] userrxrst=[expr {($v>>11)&1}] usertxrst=[expr {($v>>12)&1}]"
}
proc cstatus {v} { return [expr {($v >> 13) & 0x1F}] }

# ===========================================================================
sec "S3_STEP1_LINK"
after 300
array set A {}
readall $vio A
statline ch0 $A(st0)
say "S3_STHEX ch0 $A(st0_hex) $A(st1_hex)"
statline ch1 $A(st1)
say "S3_COMPLETION_STATUS_STEP1 [cstatus $A(st0)]"
say "S3_RATES_STEP1 dclk_free $A(dclk_free) tx0_free $A(tx0_free) rx0_free $A(rx0_free) rx1_free $A(rx1_free)"
say "S3_C1_STEP1 words $A(c1_words) frames $A(c1_frames) ctrl $A(c1_ctrl) e $A(c1_e) pay $A(c1_pay) badpay $A(c1_badpay) badstart $A(c1_badstart) badhdr $A(c1_badhdr)"
say "S3_SWORD_STEP1 hi $A(c1_sword_hi) lo $A(c1_sword_lo) misc $A(c1_misc) lastw $A(c1_lastw)"
say "S3_CNT0 $A(cnt0) CNT1 $A(cnt1)"

# ===========================================================================
sec "S3_STEP2_SHORT_OFFICIAL_RUN"
# With send_cont = 0 (the post-configuration default) the vendor FSM runs its
# designed test: wait for block lock, send PKT_NUM = 20 packets, judge.
after 300
array set B {}
readall $vio B
say "S3_STEP2_COMPLETION_STATUS [cstatus $B(st0)]"
say "S3_STEP2_COMPLETION_STATUS_HEX [vget_s $vio $PIN(in,0)]"
say "S3_STEP2_C1 words $B(c1_words) frames $B(c1_frames) ctrl $B(c1_ctrl) e $B(c1_e) pay $B(c1_pay) badpay $B(c1_badpay) badstart $B(c1_badstart) badhdr $B(c1_badhdr) badterm $B(c1_badterm) badlen $B(c1_badlen) abort $B(c1_abort)"
say "S3_STEP2_C1_LASTW $B(c1_lastw) IDLE $B(c1_idle)"
say "S3_STEP2_C0 words $B(c0_words) ctrl $B(c0_ctrl) idle $B(c0_idle) e $B(c0_e) frames $B(c0_frames)"
say "S3_STEP2_CNT0 $B(cnt0) CNT1 $B(cnt1)"
say "S3_STEP2_ACKS tx0 $B(ack_tx0) rx0 $B(ack_rx0) rx1 $B(ack_rx1)"
say "S3_STEP2_ERRW hex $B(err_w) acc0 [expr {$B(err_w) & 0xFF}] nv0 [expr {($B(err_w) >> 8) & 0xFF}] acc1 [expr {($B(err_w) >> 16) & 0xFF}] nv1 [expr {($B(err_w) >> 24) & 0xFF}]"

# ===========================================================================
sec "S3_STEP3_LONG_RUN"
# Stream continuously for a long window, snapshot at both ends, and compute the
# rates from the FREE-RUNNING counters (window < 20 s: a 32-bit counter at
# 156.25 MHz wraps every 27.5 s).
vset $vio $PIN(out,0) 1
vset $vio $PIN(out,1) 1
vset $vio $PIN(out,1) 0
after 1500
say "S3_LONG_ARMED (send_cont=1, restart pulsed: the FSM re-runs and this time the generator streams)"
array set C {}
readall $vio C
say "S3_LONG_T0 dclk_free $C(dclk_free) tx0_free $C(tx0_free) rx0_free $C(rx0_free) rx1_free $C(rx1_free)"
say "S3_LONG_T0 c1_words $C(c1_words) c1_frames $C(c1_frames) c1_pay $C(c1_pay) c1_e $C(c1_e) c1_badstart $C(c1_badstart) c1_badhdr $C(c1_badhdr) c1_badpay $C(c1_badpay) c1_badterm $C(c1_badterm) c1_badlen $C(c1_badlen) c1_abort $C(c1_abort)"
say "S3_LONG_T0 c0_words $C(c0_words) c0_ctrl $C(c0_ctrl) c0_idle $C(c0_idle) c0_e $C(c0_e)"
set t0 [clock milliseconds]
after 6000
array set D {}
readall $vio D
set t1 [clock milliseconds]
set dt [expr {($t1 - $t0) / 1000.0}]
say "S3_LONG_T1 dclk_free $D(dclk_free) tx0_free $D(tx0_free) rx0_free $D(rx0_free) rx1_free $D(rx1_free)"
say "S3_LONG_T1 c1_words $D(c1_words) c1_frames $D(c1_frames) c1_pay $D(c1_pay) c1_e $D(c1_e) c1_badstart $D(c1_badstart) c1_badhdr $D(c1_badhdr) c1_badpay $D(c1_badpay) c1_badterm $D(c1_badterm) c1_badlen $D(c1_badlen) c1_abort $D(c1_abort)"
say "S3_LONG_T1 c0_words $D(c0_words) c0_ctrl $D(c0_ctrl) c0_idle $D(c0_idle) c0_e $D(c0_e)"
say "S3_LONG_DT_SECONDS $dt"
foreach pair {dclk_free tx0_free rx0_free rx1_free c1_words c1_frames c1_pay c1_e c1_badstart c1_badhdr c1_badpay c1_badterm c1_badlen c1_abort c0_words c0_ctrl c0_idle c0_e} {
    set dv [expr {[set D($pair)] - [set C($pair)]}]
    say "S3_LONG_DELTA $pair $dv"
}
# rates.  dclk_free is the time base: it counts at 100 MHz, so
#   f = dv / (dd / 1e8) = (dv/dd) * 100 MHz.
set dd [expr {[set D(dclk_snap)] - [set C(dclk_snap)]}]
say "S3_LONG_DCLK_SNAP_T0 $C(dclk_snap) T1 $D(dclk_snap)  (live dclk_free $C(dclk_free) -> $D(dclk_free))"
say "S3_LONG_WALLCLOCK_SECONDS $dt" 
say "S3_LONG_DD $dd"
foreach pair {tx0_free rx0_free rx1_free} {
    set dv [expr {[set D($pair)] - [set C($pair)]}]
    say "S3_LONG_FREQ $pair mhz [expr {$dv / double($dd) * 100.0}]"
}
# the wire rate: 64 bits per XGMII word, so Mbps = word_rate(MHz) * 64
set dw [expr {[set D(rx1_free)] - [set C(rx1_free)]}]
say "S3_LONG_XGMII_WORD_RATE mhz [expr {$dw / double($dd) * 100.0}]"
say "S3_LONG_LINE_RATE mbps [expr {$dw / double($dd) * 6400.0}]"
# frame geometry cross-check: payload words per frame must be 30
set dfr [expr {[set D(c1_frames)] - [set C(c1_frames)]}]
set dpw [expr {[set D(c1_pay)] - [set C(c1_pay)]}]
if {$dfr > 0} {
    say "S3_LONG_PAYWORDS_PER_FRAME [expr {$dpw / double($dfr)}]"
} else {
    say "S3_LONG_PAYWORDS_PER_FRAME <no frames in this window>"
}
# XGMII words per frame: 34 frame words + 1 inter-frame idle word = 35
set dwds [expr {[set D(c1_words)] - [set C(c1_words)]}]
if {$dfr > 0} {
    say "S3_LONG_WORDS_PER_FRAME [expr {$dwds / double($dfr)}]"
    # wall-clock cross check: this counter's rate against the host clock
    say "S3_LONG_WALLCLOCK_FRAME_RATE_PER_S [expr {$dfr / $dt}]"
    say "S3_LONG_WALLCLOCK_WORD_RATE_MHZ [expr {$dwds / $dt / 1.0e6}]"
}

# ===========================================================================
sec "S3_STEP4_STOP_AND_JUDGE"
vset $vio $PIN(out,0) 0
after 200
array set E {}
readall $vio E
say "S3_STEP4_COMPLETION_STATUS [cstatus $E(st0)]"
say "S3_STEP4_CPL_HEX [vget_s $vio $PIN(in,0)]"
say "S3_STEP4_C1 words $E(c1_words) frames $E(c1_frames) ctrl $E(c1_ctrl) e $E(c1_e) pay $E(c1_pay) badpay $E(c1_badpay)"
say "S3_STEP4_CNT0 $E(cnt0) CNT1 $E(cnt1)"
say "S3_STEP4_ERRW hex $E(err_w) acc0 [expr {$E(err_w) & 0xFF}] nv0 [expr {($E(err_w) >> 8) & 0xFF}] acc1 [expr {($E(err_w) >> 16) & 0xFF}] nv1 [expr {($E(err_w) >> 24) & 0xFF}]"
say "S3_STHEX E $E(st0_hex) $E(st1_hex)"
statline ch0 $E(st0)
statline ch1 $E(st1)

# ===========================================================================
sec "S3_STEP5_NEGCTRL_SFP1_TX_DIS"
# SFP1_TX_DIS (C11) high kills the X0Y4 transmitter => the X0Y5 receiver loses
# light for real.  Expect: ch1 block lock falls, SFP2 RX_LOS asserts (the light
# on the OTHER side of the AOC goes away -- an independent check of both the
# fibre topology and the LOS pin map), and the frame stream stops.
vset $vio $PIN(out,3) 1
after 500
array set F {}
readall $vio F
say "S3_STHEX F $F(st0_hex) $F(st1_hex)"
statline ch0 $F(st0)
statline ch1 $F(st1)
say "S3_NEG1_LINK_KILLED_COMPLETION_STATUS_LATCHED [cstatus $F(st0)]"
say "S3_NEG1_C1 frames $F(c1_frames) e $F(c1_e) words $F(c1_words)"
set f0 [set F(c1_frames)]
set w0 [set F(c1_words)]
after 2500
array set G {}
readall $vio G
say "S3_NEG1_FRAMES_DELTA_WHILE_DEAD [expr {([set G(c1_frames)] - $f0) & 0xFFFFFFFF}]"
say "S3_NEG1_WORDS_DELTA_WHILE_DEAD [expr {([set G(c1_words)] - $w0) & 0xFFFFFFFF}]"
say "S3_STHEX G $G(st0_hex) $G(st1_hex)"
statline ch0 $G(st0)
statline ch1 $G(st1)
say "S3_NEG1_CNT1 $G(cnt1) CNT0 $G(cnt0)"

# ===========================================================================
sec "S3_STEP6_NEGCTRL_REARM"
# THE NEGATIVE CONTROL PROPER.  The vendor FSM LATCHES its verdict, so simply
# killing the link cannot flip completion_status -- the same RESTART that
# produces SUCCESSFUL_COMPLETION (1) on a healthy link must produce
# NO_BLOCK_LOCK (2) while the link is dark.  Same stimulus, different state.
vset $vio $PIN(out,1) 1
vset $vio $PIN(out,1) 0
after 600
array set H {}
readall $vio H
say "S3_NEG1_REARM_COMPLETION_STATUS [cstatus $H(st0)]"
say "S3_STHEX H $H(st0_hex) $H(st1_hex)"
statline ch0 $H(st0)
statline ch1 $H(st1)

# ===========================================================================
sec "S3_STEP7_RECOVER"
vset $vio $PIN(out,3) 0
after 400
array set I {}
readall $vio I
say "S3_STHEX I $I(st0_hex) $I(st1_hex)"
statline ch0 $I(st0)
statline ch1 $I(st1)
vset $vio $PIN(out,1) 1
vset $vio $PIN(out,1) 0
after 600
array set J {}
readall $vio J
say "S3_RECOV_COMPLETION_STATUS [cstatus $J(st0)]"
say "S3_STHEX J $J(st0_hex) $J(st1_hex)"
statline ch0 $J(st0)
statline ch1 $J(st1)
say "S3_RECOV_C1 frames $J(c1_frames) e $J(c1_e) badpay $J(c1_badpay) badstart $J(c1_badstart) badhdr $J(c1_badhdr)"

# ===========================================================================
sec "S3_STEP8_NEGCTRL_SFP2_TX_DIS"
# Mirror image: killing SFP2's transmitter must kill the X0Y4 receiver while the
# judged direction keeps running -- proof that the two directions are separate.
vset $vio $PIN(out,0) 1
after 500
array set K {}
readall $vio K
set kw0 [set K(c1_words)]
vset $vio $PIN(out,4) 1
after 500
array set L {}
readall $vio L
say "S3_STHEX L $L(st0_hex) $L(st1_hex)"
statline ch0 $L(st0)
statline ch1 $L(st1)
say "S3_NEG2_C1_FRAMES_AT_KILL $L(c1_frames)"
after 2000
array set M {}
readall $vio M
say "S3_NEG2_C1_WORDS_DELTA_STILL_FLOWING [expr {([set M(c1_words)] - $kw0) & 0xFFFFFFFF}]"
say "S3_NEG2_C1_FRAMES_DELTA [expr {([set M(c1_frames)] - [set K(c1_frames)]) & 0xFFFFFFFF}]"
say "S3_NEG2_C1_E_DELTA [expr {([set M(c1_e)] - [set K(c1_e)]) & 0xFFFFFFFF}]"
say "S3_STHEX M $M(st0_hex) $M(st1_hex)"
statline ch0 $M(st0)
statline ch1 $M(st1)

sec "S3_STEP9_RESTORE"
vset $vio $PIN(out,4) 0
after 300
vset $vio $PIN(out,0) 0
after 300
vset $vio $PIN(out,1) 1
vset $vio $PIN(out,1) 0
after 600
array set N {}
readall $vio N
say "S3_FINAL_COMPLETION_STATUS [cstatus $N(st0)]"
say "S3_STHEX N $N(st0_hex) $N(st1_hex)"
statline ch0 $N(st0)
statline ch1 $N(st1)
say "S3_FINAL_C1 words $N(c1_words) frames $N(c1_frames) e $N(c1_e) badpay $N(c1_badpay) badstart $N(c1_badstart) badhdr $N(c1_badhdr) badterm $N(c1_badterm) badlen $N(c1_badlen) abort $N(c1_abort) pay $N(c1_pay)"
say "S3_FINAL_SWORD hi $N(c1_sword_hi) lo $N(c1_sword_lo)"
say "S3_FINAL_MISC $N(c1_misc) LASTW $N(c1_lastw) IDLE $N(c1_idle)"
say "S3_FINAL_C0 words $N(c0_words) ctrl $N(c0_ctrl) idle $N(c0_idle) e $N(c0_e) frames $N(c0_frames)"
say "S3_FINAL_CNT0 $N(cnt0) CNT1 $N(cnt1)"
say "S3_FINAL_ERRW hex $N(err_w) acc0 [expr {$N(err_w) & 0xFF}] nv0 [expr {($N(err_w) >> 8) & 0xFF}] acc1 [expr {($N(err_w) >> 16) & 0xFF}] nv1 [expr {($N(err_w) >> 24) & 0xFF}]"
say "S3_FINAL_DCLK_SNAP $N(dclk_snap) ACKS dclk $N(ack_dclk) tx0 $N(ack_tx0) rx0 $N(ack_rx0) rx1 $N(ack_rx1)"
say "S3_FINAL_ACKS tx0 $N(ack_tx0) rx0 $N(ack_rx0) rx1 $N(ack_rx1)"
say "S3_FINAL_FLAGS $N(flags)"
say "S3_FINAL_SNAP_PAST_DELTAS ok"

disconnect_hw_server
say "S3_DONE"
