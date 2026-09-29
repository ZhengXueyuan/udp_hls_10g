#=============================================================================
# probe_p7a_board.tcl -- P7a BOARD acceptance run over JTAG (VIO).
#
#   *** THIS SCRIPT PROGRAMS THE FPGA ***  (volatile only; QSPI is never touched)
#
#  Run (Git Bash):
#     cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\board_scratch\run_probe_p7a_board.bat'
#
#  Environment:
#     P7A_BIT     bitstream (default: the project's impl_1 output)
#     P7A_SECS    acceptance BER window, seconds (default 600)
#     P7A_SHORT   short sanity BER window, seconds (default 30; 0 skips the stage)
#     P7A_HWURL   hw_server URL (default 192.168.0.38:3121)
#     P7A_ALLOW_SHORT_ERR  1 = continue to the long window even if the short one
#                          shows errors (default 0 = stop and report)
#
#  Stages
#     A  preflight / connect / SAFETY GATE / program / DONE / VIO probe resolve
#     B  RX_LOS readback + leg 3: PRBS31 lock + rxheader stability
#     C  negative control A: forced rxgearboxslip -> error burst + link-down
#                            latched, then a clean interval = re-locked
#     D  short BER sanity window (aborts before E if any word errored)
#     E  acceptance BER window (P7A_SECS = 600 s ~= 6e12 bit per channel)
#
#  The rate evidence is the DIFFERENTIAL method from obs/probe_p7a.tcl (see the
#  note at stage D): the absolute bits/fr_cyc ratio is squeezed by the snapshot
#  skew (sim: abs=0.974091 vs differential=1.000000), so it is NOT used as a
#  criterion.  Stage E additionally states the required wall-clock positive
#  evidence  bits_cnt / real seconds ~ 1.0e10 +- 0.1%, taken with the SAME read
#  procedure at both endpoints so the constant JTAG-acquisition offset cancels.
#
#  Method notes carried over from _proj_mdio/probe_phy.tcl (five API traps):
#     1  the .ltx probes file must be attached to the hw_device;
#     2  probes are named after the CONNECTED NETS;
#     3  refresh_hw_vio / commit_hw_vio take the CORE, not a probe;
#     4  INPUT_VALUE is a STRING in the probe's own radix (HEX);
#     5  OUTPUT_VALUE must be zero-padded to the probe's radix width.
#     plus: a pulse-style control MUST be edge-detected in the FPGA (it is, in
#     p7a_vio_ctrl.v -- a JTAG commit is tens of ms wide, a clock is 6.4 ns).
#=============================================================================

set here [file normalize [file dirname [info script]]]
set p10  [file normalize [file join $here ..]]
set bit  $p10/vivado_prj/p7a_prj.runs/impl_1/p7a_top.bit
if {[info exists ::env(P7A_BIT)]}    { set bit $::env(P7A_BIT) }
set secs 600
if {[info exists ::env(P7A_SECS)]}   { set secs $::env(P7A_SECS) }
set short 30
if {[info exists ::env(P7A_SHORT)]}  { set short $::env(P7A_SHORT) }
set url  192.168.0.38:3121
if {[info exists ::env(P7A_HWURL)]}  { set url $::env(P7A_HWURL) }
set allow_short_err 0
if {[info exists ::env(P7A_ALLOW_SHORT_ERR)]} { set allow_short_err $::env(P7A_ALLOW_SHORT_ERR) }

proc sec {s} { puts "\n@@@@@@ P7A >>> $s" ; flush stdout }
proc pget {o n} { if {[catch {set v [get_property $n $o]} e]} { return "<ERR:$e>" } ; return $v }
proc bit  {v n} { expr {($v >> $n) & 1} }
proc usec {} { if {[catch {set t [clock microseconds]} e]} { return [expr {[clock milliseconds]*1000}] } ; return $t }

#------------------------------------------------------------------ hex -> int
proc hexint {s} {
    set s [string trim $s]
    if {$s eq ""} { error "empty probe value" }
    if {[catch {expr "0x$s"} v]} { error "bad hex '$s'" }
    return $v
}

#=============================================================================
sec "STAGE A0 -- PREFLIGHT"
puts "BIT   = $bit"
puts "SECS  = $secs   SHORT = $short   URL = $url"
puts "host  = [info hostname]   vivado = [version -short]"
puts "tcl   = [info patchlevel]   wordSize = [expr {$tcl_platform(wordSize)}] (informational only: every large value below is printed by string interpolation, never through format %d/%X, so it is correct on a 32-bit Tcl too -- found via the dry-run harness)"
if {![file exists $bit]} { puts "P7A-ABORT: bitstream not found"; exit 1 }
set ltx [file rootname $bit].ltx
puts "LTX   = $ltx exists=[file exists $ltx]"
if {![file exists $ltx]} { puts "P7A-ABORT: .ltx missing (VIO cannot be enumerated)"; exit 1 }
foreach f [list $bit $ltx] {
    puts [format "  %s  size=%d  mtime=%s" [file tail $f] [file size $f] \
          [clock format [file mtime $f] -format "%Y-%m-%d %H:%M:%S"]]
}
puts "  sha256 of both artifacts + all 11 RTL files: board_scratch/logs/hashes.txt"
puts "  expected bit f88d019f...8651d / ltx 5dd5fa69...5455db (verified on disk before this run)"

#=============================================================================
sec "STAGE A1 -- CONNECT / SAFETY GATE (IDCODE 04A62093, device count 1)"
open_hw_manager
connect_hw_server -url $url
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
set dlist [get_hw_devices]
puts "device count = [llength $dlist]"
foreach d $dlist { puts "DEVICE $d PART=[pget $d PART] IDCODE=[pget $d IDCODE_HEX]" }
set tdev ""
foreach d $dlist { if {[pget $d IDCODE_HEX] eq "04A62093"} { set tdev $d } }
if {$tdev eq "" || [llength $dlist] != 1} {
    puts "P7A-SAFETY_ABORT: target='$tdev' count=[llength $dlist] -- NOT PROGRAMMING"
    exit 1
}
puts "SAFETY_GATE = PASS -> $tdev"
puts "PRE-PROGRAM DONE_PIN = [pget $tdev REGISTER.CONFIG_STATUS.BIT\[14\]_DONE_PIN]"

#=============================================================================
sec "STAGE A2 -- PROGRAM (volatile, JTAG) + DONE"
current_hw_device $tdev
refresh_hw_device -update_hw_probes false $tdev
set_property PROGRAM.FILE $bit $tdev
set_property PROBES.FILE $ltx $tdev
set_property FULL_PROBES.FILE $ltx $tdev
if {[catch {program_hw_devices $tdev} em]} { puts "P7A-ABORT: program failed: $em"; exit 1 }
set done [pget $tdev REGISTER.CONFIG_STATUS.BIT\[14\]_DONE_PIN]
puts "DONE_PIN = $done"
if {$done != 1} { puts "P7A-ABORT: DONE != 1"; exit 1 }
refresh_hw_device $tdev
puts "programming OK, DONE=HIGH"

#=============================================================================
sec "STAGE A3 -- VIO PROBE RESOLUTION (names + width assertions)"
set vio [lindex [get_hw_vios -of_objects $tdev] 0]
if {$vio eq ""} { puts "P7A-ABORT: no VIO in this design"; exit 1 }
puts "VIO = $vio"
foreach p [get_hw_probes -of_objects $vio] {
    puts "  PROBE name=[pget $p NAME] width=[pget $p WIDTH]"
}

proc findprobe {vio names} {
    set all [get_hw_probes -of_objects $vio]
    foreach n $names { foreach p $all { if {$p eq $n} { return $p } } }
    foreach n $names { foreach p $all { if {[string match $n $p]} { return $p } } }
    return ""
}
proc wof {p} { set w 1 ; catch {set w [get_property WIDTH $p]} ; return $w }

array set P {}
set P(err)     [findprobe $vio {vio_err_snap probe_in0}]
set P(bits)    [findprobe $vio {vio_bits_snap probe_in1}]
set P(hdrs)    [findprobe $vio {vio_hdrs_snap probe_in2}]
set P(hdre)    [findprobe $vio {vio_hdre_snap probe_in3}]
set P(rxcyc)   [findprobe $vio {vio_rxcyc_snap probe_in4}]
set P(rxdvcyc) [findprobe $vio {vio_rxdvcyc_snap probe_in5}]
set P(stat)    [findprobe $vio {vio_status probe_in6}]
set P(snap)    [findprobe $vio {raw_snap probe_out0}]
set P(clear)   [findprobe $vio {raw_clear probe_out1}]
set P(slip)    [findprobe $vio {raw_slip probe_out2}]
set P(gtrst)   [findprobe $vio {raw_gt_reset probe_out3}]
foreach {nm key w} {err err 64 bits bits 96 hdrs hdrs 96 hdre hdre 64 \
                    rxcyc rxcyc 96 rxdvcyc rxdvcyc 96 status stat 96 \
                    snap snap 1 clear clear 1 slip slip 1 gt_reset gtrst 1} {
    if {$P($key) eq ""} { puts "P7A-ABORT: probe '$nm' not found"; exit 1 }
    if {[wof $P($key)] != $w} {
        puts "P7A-ABORT: probe '$nm' width=[wof $P($key)] expected $w -- packing changed"
        exit 1
    }
}
puts "PROBES RESOLVED -- all 11 present, all widths match the RTL packing"

#------------------------------------------------------------------ primitives
proc vset {vio p val} {
    set w [wof $p]
    set n [expr {int(ceil($w / 4.0))}]
    set s [format "%0${n}X" [expr {$val & ((1 << $w) - 1)}]]
    set_property OUTPUT_VALUE $s $p
    commit_hw_vio $vio
}
proc pulse {vio p} { vset $vio $p 1 ; vset $vio $p 0 }

# one refresh, read every probe -> one coherent readout (see method note)
proc rdall {vio} {
    global P
    refresh_hw_vio $vio
    set o [dict create]
    foreach k {err bits hdrs hdre rxcyc rxdvcyc stat} {
        set s [get_property INPUT_VALUE $P($k)]
        set r HEX
        catch { set r [get_property INPUT_VALUE_RADIX $P($k)] }
        switch -- $r {
            HEX     { dict set o $k [hexint $s] }
            BIN     { dict set o $k [expr "0b$s"] }
            OCT     { dict set o $k [expr "0o$s"] }
            default { dict set o $k [hexint $s] }
        }
    }
    # --- split the packed probes into per-channel scalars, ONCE, here. -------
    # The packing is {ch1, ch0} but the two groups have DIFFERENT widths:
    #   err  [64] = {err1[31:0],  err0[31:0]}   -> ch1 at bits [63:32]
    #   hdre [64] = {hdre1[31:0], hdre0[31:0]}  -> ch1 at bits [63:32]
    #   bits/hdrs/rxcyc/rxdvcyc [96] = {ch1[47:0], ch0[47:0]} -> ch1 at [95:48]
    # A single "shift by 48" accessor is therefore WRONG for err/hdre; the
    # dry-run harness caught exactly that. No call site shifts anything now.
    dict set o err0  [expr {[dict get $o err] & 0xFFFFFFFF}]
    dict set o err1  [expr {([dict get $o err] >> 32) & 0xFFFFFFFF}]
    dict set o hdre0 [expr {[dict get $o hdre] & 0xFFFFFFFF}]
    dict set o hdre1 [expr {([dict get $o hdre] >> 32) & 0xFFFFFFFF}]
    foreach k {bits hdrs rxcyc rxdvcyc} {
        dict set o ${k}0 [expr {[dict get $o $k] & 0xFFFFFFFFFFFF}]
        dict set o ${k}1 [expr {([dict get $o $k] >> 48) & 0xFFFFFFFFFFFF}]
    }
    return $o
}
proc rd1 {vio p} {
    refresh_hw_vio $vio
    return [hexint [get_property INPUT_VALUE $p]]
}

# atomic snapshot; returns the status word, guarantees the ack flipped
proc snapwait {vio} {
    global P
    set before [bit [rd1 $vio $P(stat)] 48]
    pulse $vio $P(snap)
    set t0 [clock milliseconds]
    while {1} {
        set st [rd1 $vio $P(stat)]
        if {[bit $st 48] != $before} { return $st }
        if {[clock milliseconds] - $t0 > 4000} { error "snapshot ack timeout" }
    }
}

proc dec_status {st} {
    set s {}
    lappend s "mmcm_locked=[bit $st 49]"
    lappend s "gtpowergood(ch1,ch0)=[bit $st 51][bit $st 50]"
    lappend s "tx_reset_done=[bit $st 52]"
    lappend s "rx_reset_done=[bit $st 53]"
    lappend s "rx_cdr_stable=[bit $st 54]"
    lappend s "sfp1_rx_los=[bit $st 55]"
    lappend s "sfp2_rx_los=[bit $st 56]"
    lappend s "acq(ch0,ch1)=[bit $st 57][bit $st 58]"
    lappend s "ref_link(ch0,ch1)=[bit $st 59][bit $st 60]"
    lappend s "ref_down_latched(ch0,ch1)=[bit $st 61][bit $st 62]"
    lappend s "hdr_ref_valid(ch0,ch1)=[bit $st 63][bit $st 64]"
    lappend s "echo(snap,clr,slip,gtrst)=[bit $st 65][bit $st 66][bit $st 67][bit $st 68]"
    lappend s "rst_obs=[bit $st 69]"
    lappend s "fingerprint=[bit $st 70]"
    lappend s "hdr_ref(ch0)=0x[format %02X [expr {($st>>71)&63}]]"
    lappend s "hdr_ref(ch1)=0x[format %02X [expr {($st>>77)&63}]]"
    lappend s "rxdv(ch0,ch1)=[expr {($st>>85)&3}][expr {($st>>87)&3}]"
    return [join $s " "]
}
proc field {v lo hi} { expr {($v >> $lo) & ((1 << ($hi - $lo + 1)) - 1)} }

#------------------------------------------------------------------ status now
sec "STAGE B1 -- STATUS BEFORE ANY CLEAR (live readback)"
set st [rd1 $vio $P(stat)]
puts "STATUS $st"
puts "  [dec_status $st]"
puts "  fingerprint bit [bit $st 70] must be 1 (proves the probe maps to THIS build)"
if {[bit $st 70] != 1} { puts "P7A-ABORT: build fingerprint bit is 0 -- wrong bitstream/probes"; exit 1 }
set sfp1_los [bit $st 55]
set sfp2_los [bit $st 56]
puts ""
puts "RX_LOS READBACK:  sfp1_rx_los=$sfp1_los  sfp2_rx_los=$sfp2_los"
puts "  (SFP RX_LOS is an open-collector module OUTPUT, active HIGH on loss of"
puts "   signal; XDC sets PULLTYPE PULLUP so an empty cage reads 1.)"
puts "  => AOC present and emitting on BOTH cages requires 0/0. Got $sfp1_los/$sfp2_los"
if {$sfp1_los != 0 || $sfp2_los != 0} {
    puts "P7A-WARN: at least one cage reports LOSS OF SIGNAL."
}
puts ""
puts "TX_DIS: RTL drives both sfp*_tx_dis = 1'b0 unconditionally (p7a_top.v s.9)."
puts "  Board-level consequence of that being wrong is a DARK link: with TX_DIS"
puts "  high both modules stop emitting => RX_LOS would be 1/1 and no PRBS lock."
puts "  So the lock + LOS=0/0 below is the board evidence that TX_DIS really is low."
if {[bit $st 49] != 1} { puts "P7A-WARN: mmcm_locked=0" }
if {[bit $st 50] != 1 || [bit $st 51] != 1} { puts "P7A-WARN: gtpowergood != 11" }
if {[bit $st 52] != 1 || [bit $st 53] != 1} {
    puts "P7A-WARN: tx/rx reset not done ([bit $st 52]/[bit $st 53]) -- will retry after clear"
}

#=============================================================================
sec "STAGE B2 -- RESTART MEASUREMENT WINDOW (VIO clear) AND WAIT FOR PRBS31 LOCK"
pulse $vio $P(clear)
after 100
set st [rd1 $vio $P(stat)]
puts "after clear: [dec_status $st]"
puts "  (clear resets counters AND acq; acq re-arms after 64 consecutive matched words)"
puts "waiting for acq on BOTH channels ..."
set t0 [clock milliseconds]
set acqu 0
while {[clock milliseconds] - $t0 < 20000} {
    set st [rd1 $vio $P(stat)]
    set acqu [expr {[bit $st 57] && [bit $st 58]}]
    if {$acqu} break
    after 250
}
puts "acq(both) = $acqu after [expr {[clock milliseconds]-$t0}] ms"
puts "  [dec_status $st]"
if {!$acqu} {
    puts "P7A-STOP: NO PRBS LOCK. Diagnostic readouts, nothing else was attempted:"
    puts "  hdr_ref ch0=0x[format %02X [expr {($st>>71)&63}]] ch1=0x[format %02X [expr {($st>>77)&63}]] (0 = no header ever seen)"
    puts "  hdr_ref_valid=[bit $st 63][bit $st 64]  ref_link=[bit $st 59][bit $st 60]  ref_down_latched=[bit $st 61][bit $st 62]"
    puts "  rx_cdr_stable=[bit $st 54]  tx_reset_done=[bit $st 52]  rx_reset_done=[bit $st 53]"
    puts "  rxdv live=[expr {($st>>85)&3}][expr {($st>>87)&3}]  (0 = no rxdatavalid at all)"
    puts "  P7A_BOARD_VERDICT = STOP_NO_PRBS_LOCK"
    disconnect_hw_server
    exit 2
}

#=============================================================================
sec "STAGE B3 -- LEG 3: rxheader STABILITY (the criterion is STABILITY, not a value)"
set D [rdall $vio]
set nbad 0
set samples {}
for {set i 0} {$i < 5} {incr i} {
    set st [snapwait $vio]
    set D [rdall $vio]
    set hr0 [expr {($st>>71)&63}]
    set hr1 [expr {($st>>77)&63}]
    set v0 [bit $st 63]
    set v1 [bit $st 64]
    set hd  [dict get $D hdrs0]
    set he  [dict get $D hdre0]
    set hd1 [dict get $D hdrs1]
    set he1 [dict get $D hdre1]
    lappend samples "$hr0/$hr1"
    puts "  sample $i: hdr_ref ch0=0x[format %02X $hr0] ch1=0x[format %02X $hr1]  valid=$v0$v1  hdrs_cnt ch0=$hd ch1=$hd1  hdr_err_cnt ch0=$he ch1=$he1"
    if {$v0 != 1 || $v1 != 1} { incr nbad }
    if {$he != 0 || $he1 != 0} { incr nbad }
    after 400
}
set st [rd1 $vio $P(stat)]
set hdr_ref0 [expr {($st>>71)&63}]
set hdr_ref1 [expr {($st>>77)&63}]
set D [rdall $vio]
puts ""
puts "LEG3_ACQ              = [bit $st 57][bit $st 58]"
puts "LEG3_HDR_REF          = ch0=0x[format %02X $hdr_ref0] ([format %d $hdr_ref0])   ch1=0x[format %02X $hdr_ref1] ([format %d $hdr_ref1])"
puts "LEG3_HDR_REF_VALID    = [bit $st 63][bit $st 64]"
puts "LEG3_HDRS_CNT         = ch0=[dict get $D hdrs0]  ch1=[dict get $D hdrs1]"
puts "LEG3_HDR_ERR_CNT      = ch0=[dict get $D hdre0]  ch1=[dict get $D hdre1]   <-- must be 0 (header never deviates)"
puts "LEG3_SAMPLES          = $samples"
if {$nbad > 0} { puts "P7A-STOP: leg 3 failed (bad samples=$nbad)"; puts "P7A_BOARD_VERDICT = STOP_LEG3"; disconnect_hw_server; exit 2 }
puts "LEG3 = PASS (PRBS31 locked; 6-bit rxheader stable at the same constant while rxheadervalid)"

#=============================================================================
sec "STAGE C -- NEGATIVE CONTROL A: forced rxgearboxslip must DROP and RE-LOCK"
puts "Rationale: rxgearboxslip moves the 64b/66b receiver block boundary. In a RAW"
puts "datapath there is no gearbox to slip, so this action has no effect at all."
puts "While the link is locked the example checker emits NO slips of its own"
puts "(_checking_64b66b_async.v: rxgearboxslip_ctr only advances while !match),"
puts "so any error burst after this pulse is attributable to the pulse."
puts ""
pulse $vio $P(clear)
after 100
set t0 [clock milliseconds]
while {[clock milliseconds] - $t0 < 20000} {
    set st [rd1 $vio $P(stat)]
    if {[bit $st 57] && [bit $st 58]} { break }
    after 250
}
after 2000
# *** HARNESS FIX 2026-09-29 (found by the run-2 result: NEGCTRL_A reported
# dErr=0 / "bits advanced=0") : this line used to be rd1+rdall with NO snapshot
# request.  rdall only re-reads the registers latched at the LAST snap event, so
# this "before" read and the "after" read further down returned the SAME frozen
# values (latched back in stage B3) => every delta was 0 BY CONSTRUCTION and the
# re-lock check compared a value with itself.  snapwait() forces a real atomic
# snapshot; its ack flip is also the positive evidence that the payload-domain
# (rx_usrclk2) clock is running.  The CRITERIA ARE UNCHANGED.
set st [snapwait $vio]
set D  [rdall $vio]
set e0c0 [dict get $D err0] ; set e0c1 [dict get $D err1]
set b0  [dict get $D bits0]
set rl_before [list [bit $st 59] [bit $st 60]]
set dl_before [list [bit $st 61] [bit $st 62]]
set SLIP_ECHO_BEFORE [list [bit $st 67]]
puts "BEFORE SLIP: err ch0=$e0c0 ch1=$e0c1  ref_link=[lindex $rl_before 0][lindex $rl_before 1]  ref_down_latched=[lindex $dl_before 0][lindex $dl_before 1]  slip_echo=[lindex $SLIP_ECHO_BEFORE 0]"

puts ">>> pulsing raw_slip (one rising edge -> one gearbox slip on each channel)"
pulse $vio $P(slip)
after 2000
set st [snapwait $vio]
set D  [rdall $vio]
set e1c0 [dict get $D err0] ; set e1c1 [dict get $D err1]
set b1  [dict get $D bits0]
set de0 [expr {$e1c0 - $e0c0}] ; set de1 [expr {$e1c1 - $e0c1}]
set dbits_after [expr {$b1 - $b0}]
set rl_after  [list [bit $st 59] [bit $st 60]]
set dl_after  [list [bit $st 61] [bit $st 62]]
set SLIP_ECHO_AFTER [list [bit $st 67]]
puts "AFTER SLIP +2 s: err ch0=$e1c0 ch1=$e1c1  (delta ch0=$de0 ch1=$de1)"
puts "  ref_link=[lindex $rl_after 0][lindex $rl_after 1]  ref_down_latched=[lindex $dl_after 0][lindex $dl_after 1]"
puts "  slip_echo=[lindex $SLIP_ECHO_AFTER 0]   bits advanced since before-slip = $dbits_after"
puts "  ref_down_latched BEFORE=[lindex $dl_before 0][lindex $dl_before 1] -> AFTER=[lindex $dl_after 0][lindex $dl_after 1]   (sticky: 1 = the example bucket saw the link go down)"
puts "  -> ref_down_latched latched 0->1 : [expr {[lindex $dl_before 0]==0 && [lindex $dl_before 1]==0 && [lindex $dl_after 0]==1 && [lindex $dl_after 1]==1}]"

puts ">>> now measuring a CLEAN interval (re-lock check): 6 s with NO further slip"
set e2c0 [dict get $D err0] ; set e2c1 [dict get $D err1]
set b2  [dict get $D bits0]
after 6000
set st [snapwait $vio]
set D  [rdall $vio]
set e3c0 [dict get $D err0] ; set e3c1 [dict get $D err1]
set de2 [expr {$e3c0 - $e2c0}] ; set de3 [expr {$e3c1 - $e2c1}]
set dbits_clean [expr {[dict get $D bits0] - $b2}]
set rl_final [list [bit $st 59] [bit $st 60]]
puts "CLEAN 6 s AFTER SLIP: err delta ch0=$de2 ch1=$de3   bits advanced=$dbits_clean"
puts "  ref_link=[lindex $rl_final 0][lindex $rl_final 1]  acq=[bit $st 57][bit $st 58]"
puts "  [dec_status $st]"

set negA_burst [expr {($de0 > 0) && ($de1 > 0)}]
set negA_drop  [expr {[lindex $dl_before 0]==0 && [lindex $dl_before 1]==0 && [lindex $dl_after 0]==1 && [lindex $dl_after 1]==1}]
set negA_relock [expr {($de2 == 0) && ($de3 == 0) && ($dbits_clean > 0) && [lindex $rl_final 0]==1 && [lindex $rl_final 1]==1}]
puts ""
puts "NEGCTRL_A_ERR_BURST   = $negA_burst   (ch0 delta=$de0, ch1 delta=$de1, both must be >0)"
puts "NEGCTRL_A_LINK_DROP   = $negA_drop   (ref_down_latched 0/0 -> 1/1)"
puts "NEGCTRL_A_RELOCK      = $negA_relock   (next 6 s: 0 further errors, bits still advancing, ref_link back to 1/1)"
if {!($negA_burst && $negA_drop && $negA_relock)} {
    puts "P7A-STOP: negative control A did not show drop+relock; the gearbox-slip"
    puts "          discriminator is not demonstrated on this board. Reporting raw"
    puts "          readings above instead of proceeding to BER."
    puts "P7A_BOARD_VERDICT = STOP_NEGCTRL_A"
    disconnect_hw_server
    exit 2
}
puts "NEGCTRL_A = PASS (slip -> errors on BOTH channels + link-down latched, then clean re-lock)"

#=============================================================================
# BER window.  One procedure for every window (also the acceptance one).
proc run_window {vio tag secs} {
    global P
    puts ""
    puts "@@@@@@ P7A >>> $tag: restart window, wait lock, measure ${secs} s"
    pulse $vio $P(clear)
    after 100
    set t0 [clock milliseconds]
    while {[clock milliseconds] - $t0 < 20000} {
        set st [rd1 $vio $P(stat)]
        if {[bit $st 57] && [bit $st 58]} { break }
        after 250
    }
    puts "  locked after [expr {[clock milliseconds]-$t0}] ms; [dec_status $st]"
    # ---- start endpoint: same read order as the end endpoint --------------
    set stA [snapwait $vio]
    set DA  [rdall $vio]
    set tA  [usec]
    set fA  [expr {$stA & 0xFFFFFFFFFFFF}]
    puts "  START  t=$tA  err(ch0,ch1)=[dict get $DA err0],[dict get $DA err1] bits(ch0,ch1)=[dict get $DA bits0],[dict get $DA bits1] hdrs(ch0,ch1)=[dict get $DA hdrs0],[dict get $DA hdrs1] hdre(ch0,ch1)=[dict get $DA hdre0],[dict get $DA hdre1] fr_cyc=$fA rxcyc(ch0)=[dict get $DA rxcyc0] rxdvcyc(ch0)=[dict get $DA rxdvcyc0]"
    set t_wall0 [clock milliseconds]
    set nwin 0 ; set rmin 1e9 ; set rmax 0.0 ; set err_all 0 ; set trmax 0.0 ; set trmin 1e9
    set fprev $fA ; set bprev [dict get $DA bits0] ; set eprev0 [dict get $DA err0] ; set eprev1 [dict get $DA err1]
    set lastrpt $t_wall0
    # Sub-window report interval. It must be small enough that even a short
    # window yields >=1 differential-ratio sample (a fixed 10 s interval made the
    # ratio criterion UNEVALUABLE for any window shorter than 10 s -- found by
    # the dry-run harness), and <=10 s so the 600 s run gets ~60 samples.
    set rpt_ms [expr {max(2000, min(10000, $secs * 250))}]
    while {[clock milliseconds] - $t_wall0 < ($secs * 1000)} {
        after 200
        if {[clock milliseconds] - $lastrpt < $rpt_ms} { continue }
        set lastrpt [clock milliseconds]
        set stW [snapwait $vio]
        set DW  [rdall $vio]
        set fW  [expr {$stW & 0xFFFFFFFFFFFF}]
        set bW  [dict get $DW bits0]
        set eW0 [dict get $DW err0] ; set eW1 [dict get $DW err1]
        set dw [expr {($bW - $bprev) / 64}]
        set df [expr {$fW - $fprev}]
        set de0 [expr {$eW0 - $eprev0}] ; set de1 [expr {$eW1 - $eprev1}]
        incr err_all [expr {$de0 + $de1}]
        if {$df > 0 && $dw > 0} {
            set r [expr {double($dw)/double($df)}]
            if {$r < $rmin} { set rmin $r }
            if {$r > $rmax} { set rmax $r }
            set tr [expr {double($dw)/(double($df)/156.25e6)}]
            if {$tr < $trmin} { set trmin $tr }
            if {$tr > $trmax} { set trmax $tr }
            incr nwin
            puts "  win $nwin: dWords=$dw dErr=$de0,$de1 dFr=$df ratio=[format %.6f $r]  (= [format %.6e $tr] 64-bit words/s on the obs clock)  elapsed=[expr {([clock milliseconds]-$t_wall0)/1000}]s"
        } else {
            puts "  win ??: NO RX ACTIVITY (dWords=$dw dFr=$df) -- is the link up?"
        }
        set fprev $fW ; set bprev $bW ; set eprev0 $eW0 ; set eprev1 $eW1
    }
    set stB [snapwait $vio]
    set DB  [rdall $vio]
    set tB  [usec]
    set fB  [expr {$stB & 0xFFFFFFFFFFFF}]
    puts "  END    t=$tB  err(ch0,ch1)=[dict get $DB err0],[dict get $DB err1] bits(ch0,ch1)=[dict get $DB bits0],[dict get $DB bits1] hdrs(ch0,ch1)=[dict get $DB hdrs0],[dict get $DB hdrs1] hdre(ch0,ch1)=[dict get $DB hdre0],[dict get $DB hdre1] fr_cyc=$fB"

    set wall [expr {($tB - $tA) / 1.0e6}]
    set dfr  [expr {$fB - $fA}]
    set out [dict create]
    dict set out wall $wall
    dict set out dfr $dfr
    dict set out nwin $nwin
    dict set out rmin [expr {$nwin>0 ? $rmin : 0}]
    dict set out rmax $rmax
    dict set out trmin [expr {$nwin>0 ? $trmin : 0}]
    dict set out trmax $trmax
    dict set out errall $err_all
    foreach c {0 1} {
        set bits [expr {[dict get $DB bits$c] - [dict get $DA bits$c]}]
        # whole-window differential ratio for this channel (a single number over
        # the entire run: the constant snapshot skew cancels, and even a +/-1
        # cycle residual is 6e-10 of a 600 s window)
        if {$dfr > 0 && $bits > 0} {
            dict set out ratio_all$c [expr {double($bits / 64.0) / double($dfr)}]
        } else {
            dict set out ratio_all$c 0.0
        }
        set errs [expr {[dict get $DB err$c]  - [dict get $DA err$c]}]
        set hdrs [expr {[dict get $DB hdrs$c] - [dict get $DA hdrs$c]}]
        set hdre [expr {[dict get $DB hdre$c] - [dict get $DA hdre$c]}]
        dict set out bits$c $bits
        dict set out err$c  $errs
        dict set out hdrs$c $hdrs
        dict set out hdre$c $hdre
        dict set out rate$c [expr {$wall > 0 ? double($bits)/$wall : 0}]
        dict set out wrate$c [expr {$dfr > 0 ? double($bits)/64.0/(double($dfr)/156.25e6) : 0}]
        dict set out ber$c [expr {$bits > 0 ? double($errs)/double($bits) : -1.0}]
        dict set out berup$c [expr {$bits > 0 ? 3.0/double($bits) : -1.0}]
    }
    return $out
}

if {$short > 0} {
    set RS [run_window $vio "STAGE D -- SHORT SANITY WINDOW" $short]
    puts ""
    puts "STAGE D RESULT ($short s)"
    puts "  wall = [format %.6f [dict get $RS wall]] s   dFr = [dict get $RS dfr] (obs cycles)   windows = [dict get $RS nwin]   ratio = [format %.6f [dict get $RS rmin]] .. [format %.6f [dict get $RS rmax]]"
    foreach c {0 1} {
        puts "  ch$c: bits=[dict get $RS bits$c] err=[dict get $RS err$c] hdrs=[dict get $RS hdrs$c] hdre=[dict get $RS hdre$c]  rate=[format %.6e [dict get $RS rate$c]] bit/s (bits/wall)  [format %.6e [dict get $RS wrate$c]] words/s (dWords/dFr)  BER=[format %.3e [dict get $RS ber$c]]"
    }
    set serr [expr {[dict get $RS err0] + [dict get $RS err1]}]
    if {$serr > 0 && $allow_short_err == 0} {
        puts "P7A-STOP: $serr errored words already in the $short s sanity window."
        puts "          Not spending the long window: zero errors is the criterion."
        puts "P7A_BOARD_VERDICT = STOP_ERRORS_IN_SHORT_WINDOW"
        disconnect_hw_server
        exit 2
    }
}

sec "STAGE E -- ACCEPTANCE BER WINDOW ($secs s)"
set R [run_window $vio "STAGE E -- ACCEPTANCE" $secs]
puts ""
puts "=================== P7a BOARD ACCEPTANCE READOUT ==================="
puts "ELAPSED WALL     = [format %.6f [dict get $R wall]] s   (dFr = [dict get $R dfr] obs-domain 156.25 MHz cycles = [format %.6f [expr {[dict get $R dfr]/156.25e6}]] s)"
puts "SUB-WINDOWS      = [dict get $R nwin]   ratio(dWords/dFr) range = [format %.6f [dict get $R rmin]] .. [format %.6f [dict get $R rmax]]"
puts [format "                   -> expected 1.000000 for a 66/64 gearbox, 1.031250 for raw"]
set verdicts {}
foreach c {0 1} {
    set dir [expr {$c==0 ? "B->A (ch0 RX receives ch1 TX)" : "A->B (ch1 RX receives ch0 TX)"}]
    puts ""
    puts "--- channel $c  = $dir ---"
    puts "BITS_CNT (payload) = [dict get $R bits$c]   (= [expr {[dict get $R bits$c]/64}] x 64-bit words)"
    puts "ERR_WORD_CNT       = [dict get $R err$c]"
    puts "HDRS_CNT           = [dict get $R hdrs$c]   (words with rxheadervalid)"
    puts "HDR_ERR_CNT        = [dict get $R hdre$c]"
    puts "RATE (bits/wall)   = [format %.6e [dict get $R rate$c]] bit/s   target 1.0e10 +-0.1%  dev=[format %.4f [expr {100.0*([dict get $R rate$c]-1.0e10)/1.0e10}]]%"
    puts "RATE (words/dFr)   = [format %.6e [dict get $R wrate$c]] 64-bit words/s  (x64 = [format %.6e [expr {64.0*[dict get $R wrate$c]}]] bit/s; 1.5625e8 words/s is the 66/64 gearbox answer)"
    puts "RATIO whole window = [format %.6f [dict get $R ratio_all$c]]   (dWords/dFr over the WHOLE run: 1.000000 = 66/64 gearbox, 1.031250 = raw)"
    if {[dict get $R bits$c] > 0} {
        if {[dict get $R err$c] == 0} {
            puts "BER upper bound 95%CL = [format %.3e [dict get $R berup$c]]  (0 errors in [dict get $R bits$c] bit < 3/B)"
        } else {
            puts "BER MEASURED       = [format %.3e [dict get $R ber$c]]"
        }
    } else {
        puts "BER = UNDEFINED -- bits_cnt did not advance (an empty reading is not a zero)"
    }
    set ok_bits  [expr {[dict get $R bits$c] > 0}]
    set ok_err   [expr {[dict get $R err$c] == 0}]
    set ok_hdre  [expr {[dict get $R hdre$c] == 0}]
    set ok_rate  [expr {abs([dict get $R rate$c]-1.0e10)/1.0e10 <= 0.001}]
    set ok_ratio [expr {[dict get $R rmin] > 0.999 && [dict get $R rmax] < 1.001}]
    set ok_ratio_all [expr {[dict get $R ratio_all$c] > 0.999 && [dict get $R ratio_all$c] < 1.001}]
    lappend verdicts [list $c $ok_bits $ok_err $ok_hdre $ok_rate $ok_ratio $ok_ratio_all]
    puts "  criteria: bits>0=$ok_bits  err==0=$ok_err  hdre==0=$ok_hdre  rate+-0.1%=$ok_rate  subwindow-ratio==1.000=$ok_ratio  wholewindow-ratio==1.000=$ok_ratio_all  (subwindows=[dict get $R nwin])"
}
set allok 1
foreach v $verdicts { foreach f [lrange $v 1 end] { if {!$f} { set allok 0 } } }
puts ""
if {$allok} {
    puts "GEARBOX_RATIO_VERDICT = 1.000000 => the fabric interface carries 64 payload bits"
    puts "                        per 66 baud => the 64b/66b gearbox is IN THE DATAPATH"
    puts "                        (raw would read 1.031250 and ~1.0313e10 bit/s)"
    puts "P7A_BOARD_VERDICT = PASS"
} else {
    puts "P7A_BOARD_VERDICT = FAIL (see the per-channel criteria flags above)"
}
puts "P7A_VERDICT_END"
disconnect_hw_server
puts "DONE"
