#=============================================================================
# diag_slip.tcl -- P7a POST-NEGCTRL-A DIAGNOSTIC (VIO only; DOES NOT PROGRAM)
#
#   Why: probe_p7a_board.tcl stage C read the snapshot registers with rdall
#   WITHOUT taking a new snapshot.  rdall only re-reads the registers latched at
#   the LAST snap event, so "err before slip" and "err after slip" were the SAME
#   frozen values (latched way back in stage B3) => every delta came out 0 and
#   the re-lock check compared a value with itself.  Delta==0 there was an
#   artifact, not a measurement (the file's own header warns about exactly this
#   class: an empty reading is not a zero).
#
#   This script answers two questions on the image that is STILL loaded:
#     D1  is the link locked right now, and are the counters MOVING?  (positive
#         evidence: two real snapshots, deltas over 5 s, plus the gearbox ratio
#         dWords/dFr which is 1.000000 for a 66/64 gearbox and 1.031250 for raw)
#     D2  a PROPERLY instrumented negative control A: snapshot -> pulse
#         rxgearboxslip -> snapshot -> 6 s clean -> snapshot.
#
#   No programming, no QSPI, no bitstream change.
#=============================================================================

set here [file normalize [file dirname [info script]]]
set p10  [file normalize [file join $here ..]]
set bit  $p10/vivado_prj/p7a_prj.runs/impl_1/p7a_top.bit
set ltx  [file rootname $bit].ltx
set url  192.168.0.38:3121
if {[info exists ::env(P7A_HWURL)]} { set url $::env(P7A_HWURL) }

proc sec {s} { puts "\n@@@@@@ DIAG >>> $s" ; flush stdout }
proc pget {o n} { if {[catch {set v [get_property $n $o]} e]} { return "<ERR:$e>" } ; return $v }
proc bit  {v n} { expr {($v >> $n) & 1} }
proc hexint {s} {
    set s [string trim $s]
    if {$s eq ""} { error "empty probe value" }
    if {[catch {expr "0x$s"} v]} { error "bad hex '$s'" }
    return $v
}

sec "D0 -- CONNECT (no programming) + attach the P7a probes"
open_hw_manager
connect_hw_server -url $url
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
set dlist [get_hw_devices]
puts "device count = [llength $dlist]"
set tdev ""
foreach d $dlist { if {[pget $d IDCODE_HEX] eq "04A62093"} { set tdev $d } }
if {$tdev eq "" || [llength $dlist] != 1} { puts "DIAG-ABORT: bad target"; exit 1 }
current_hw_device $tdev
puts "DONE_PIN (image in the FPGA right now) = [pget $tdev REGISTER.CONFIG_STATUS.BIT\[14\]_DONE_PIN]"
set_property PROBES.FILE $ltx $tdev
set_property FULL_PROBES.FILE $ltx $tdev
refresh_hw_device -update_hw_probes true $tdev

set vio [lindex [get_hw_vios -of_objects $tdev] 0]
if {$vio eq ""} { puts "DIAG-ABORT: no VIO"; exit 1 }
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
foreach k {err bits hdrs hdre rxcyc rxdvcyc stat snap clear slip gtrst} {
    if {$P($k) eq ""} { puts "DIAG-ABORT: probe '$k' not found"; exit 1 }
}
puts "probes resolved; status width = [wof $P(stat)]"

proc vset {vio p val} {
    set w [wof $p]
    set n [expr {int(ceil($w / 4.0))}]
    set s [format "%0${n}X" [expr {$val & ((1 << $w) - 1)}]]
    set_property OUTPUT_VALUE $s $p
    commit_hw_vio $vio
}
proc pulse {vio p} { vset $vio $p 1 ; vset $vio $p 0 }
proc rd1 {vio p} { refresh_hw_vio $vio ; return [hexint [get_property INPUT_VALUE $p]] }

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

# atomic snapshot: returns the status word and GUARANTEES the ack flipped.
# A failure here is itself the reading: it means the payload-domain clock is not
# running (the snapshot registers live in rx_usrclk2).
proc snapwait {vio} {
    global P
    set before [bit [rd1 $vio $P(stat)] 48]
    pulse $vio $P(snap)
    set t0 [clock milliseconds]
    while {1} {
        set st [rd1 $vio $P(stat)]
        if {[bit $st 48] != $before} { return [list $st [expr {[clock milliseconds]-$t0}]] }
        if {[clock milliseconds] - $t0 > 4000} { error "snapshot ack timeout (payload clock dead?)" }
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
    lappend s "snap_ack=[bit $st 48]"
    lappend s "slip_echo=[bit $st 67]"
    lappend s "hdr_ref(ch0)=0x[format %02X [expr {($st>>71)&63}]]"
    lappend s "hdr_ref(ch1)=0x[format %02X [expr {($st>>77)&63}]]"
    lappend s "rxdv(ch0,ch1)=[expr {($st>>85)&3}][expr {($st>>87)&3}]"
    return [join $s " "]
}

#=============================================================================
sec "D1 -- IS IT LOCKED AND ARE THE COUNTERS MOVING? (two REAL snapshots, 5 s apart)"
set st [rd1 $vio $P(stat)]
puts "live status: $st"
puts "  [dec_status $st]"
foreach tag {D1-a D1-b D1-c} {
    if {[catch {set r [snapwait $vio]} e]} { puts "SNAPSHOT FAILED ($tag): $e" ; puts "DIAG_VERDICT = PAYLOAD_DOMAIN_FROZEN"; disconnect_hw_server ; exit 2 }
    set st [lindex $r 0] ; set ack_ms [lindex $r 1]
    set D [rdall $vio]
    puts "  $tag ack_flip_after=${ack_ms}ms  bits(ch0,ch1)=[dict get $D bits0],[dict get $D bits1] err=[dict get $D err0],[dict get $D err1] hdrs=[dict get $D hdrs0],[dict get $D hdrs1] hdre=[dict get $D hdre0],[dict get $D hdre1] rxcyc=[dict get $D rxcyc0] rxdvcyc=[dict get $D rxdvcyc0] fr_cyc=[expr {$st & 0xFFFFFFFFFFFF}]"
    set SNAP($tag) $D
    after 5000
}
foreach c {0 1} {
    set b0 [dict get $SNAP(D1-a) bits$c] ; set b1 [dict get $SNAP(D1-c) bits$c]
    set e0 [dict get $SNAP(D1-a) err$c]  ; set e1 [dict get $SNAP(D1-c) err$c]
    set h0 [dict get $SNAP(D1-a) hdrs$c] ; set h1 [dict get $SNAP(D1-c) hdrs$c]
    set rc0 [dict get $SNAP(D1-a) rxcyc$c] ; set rc1 [dict get $SNAP(D1-c) rxcyc$c]
    set f0 [expr {[lindex $SNAP(D1-a) stat] & 0xFFFFFFFFFFFF}]
    set f1 [expr {[lindex $SNAP(D1-c) stat] & 0xFFFFFFFFFFFF}]
    puts "  ch$c DELTA over ~10 s: bits=$b1-$b0=[expr {$b1-$b0}]  err=[expr {$e1-$e0}]  hdrs=[expr {$h1-$h0}]  rxcyc=[expr {$rc1-$rc0}]"
    if {$f1 > $f0} { puts "     ratio dWords/dFr = [format %.6f [expr {double(($b1-$b0)/64.0)/double($f1-$f0)}]]  (1.000000 = 66/64 gearbox in datapath, 1.031250 = raw)" }
}
puts "  => payload clock alive proof: snap ack flipped on all three snapshots AND rxcyc advanced."
puts "     bits advanced > 0 is the positive control that the counters were running."

#=============================================================================
sec "D2 -- NEGATIVE CONTROL A, PROPERLY INSTRUMENTED (snapshots around the slip)"
set r [snapwait $vio] ; set st0 [lindex $r 0] ; set A [rdall $vio]
set dl0 [list [bit $st0 61] [bit $st0 62]]
set rl0 [list [bit $st0 59] [bit $st0 60]]
puts "BEFORE: bits(ch0,ch1)=[dict get $A bits0],[dict get $A bits1] err=[dict get $A err0],[dict get $A err1] ref_link=[lindex $rl0 0][lindex $rl0 1] ref_down_latched=[lindex $dl0 0][lindex $dl0 1]"
set p0_b [dict get $A bits0] ; set p0_e [dict get $A err0]
puts ">>> pulsing raw_slip (one rising edge -> one rxgearboxslip on each channel)"
pulse $vio $P(slip)
after 2000
set r [snapwait $vio] ; set st1 [lindex $r 0] ; set B [rdall $vio]
set dl1 [list [bit $st1 61] [bit $st1 62]]
set rl1 [list [bit $st1 59] [bit $st1 60]]
puts "AFTER +2 s: bits(ch0,ch1)=[dict get $B bits0],[dict get $B bits1] err=[dict get $B err0],[dict get $B err1]"
puts "  dBits ch0=[expr {[dict get $B bits0]-$p0_b}] ch1=[expr {[dict get $B bits1]-[dict get $A bits1]}]  dErr ch0=[expr {[dict get $B err0]-$p0_e}] ch1=[expr {[dict get $B err1]-[dict get $A err1]}]"
puts "  ref_link=[lindex $rl1 0][lindex $rl1 1]  ref_down_latched=[lindex $dl1 0][lindex $dl1 1]  acq=[bit $st1 57][bit $st1 58]  rxdv=[expr {($st1>>85)&3}][expr {($st1>>87)&3}]"

puts ">>> clean interval, 6 s, no further slip"
set p2_b [dict get $B bits0] ; set p2_e [dict get $B err0]
after 6000
set r [snapwait $vio] ; set st2 [lindex $r 0] ; set C [rdall $vio]
set rl2 [list [bit $st2 59] [bit $st2 60]]
puts "AFTER +8 s total: bits(ch0,ch1)=[dict get $C bits0],[dict get $C bits1] err=[dict get $C err0],[dict get $C err1]"
puts "  dBits(clean 6 s) ch0=[expr {[dict get $C bits0]-$p2_b}] ch1=[expr {[dict get $C bits1]-[dict get $B bits1]}]  dErr ch0=[expr {[dict get $C err0]-$p2_e}] ch1=[expr {[dict get $C err1]-[dict get $B err1]}]"
puts "  ref_link=[lindex $rl2 0][lindex $rl2 1]  acq=[bit $st2 57][bit $st2 58]"
puts "  [dec_status $st2]"
puts ""
puts "NEGCTRL_A_ERR_BURST = [expr {([dict get $B err0]-$p0_e) > 0 && ([dict get $B err1]-[dict get $A err1]) > 0}]  (ch0 d=[expr {[dict get $B err0]-$p0_e}] ch1 d=[expr {[dict get $B err1]-[dict get $A err1]}])"
puts "NEGCTRL_A_LINK_DROP = [expr {[lindex $dl0 0]==0 && [lindex $dl0 1]==0 && [lindex $dl1 0]==1 && [lindex $dl1 1]==1}]  (before=[lindex $dl0 0][lindex $dl0 1] after=[lindex $dl1 0][lindex $dl1 1])"
puts "NEGCTRL_A_RELOCK    = [expr {([dict get $C err0]-$p2_e)==0 && ([dict get $C err1]-[dict get $B err1])==0 && ([dict get $C bits0]-$p2_b)>0 && [lindex $rl2 0]==1 && [lindex $rl2 1]==1}]  (clean-interval dErr/traffic/ref_link)"
disconnect_hw_server
puts "DIAG-DONE (FPGA still holds the P7a image; nothing was reprogrammed)"
