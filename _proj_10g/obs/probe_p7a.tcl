#=============================================================================
# probe_p7a.tcl -- P7a observation over JTAG (VIO), for the BOARD phase
#=============================================================================
#
#  Run (from the Windows box, Git Bash):
#     P7A_SECS=30  vivado -mode batch -source probe_p7a.tcl -nojournal -nolog
#     cmd //c '..._proj_10g\obs\run_probe_p7a.bat'
#
#  ⚠ This script PROGRAMS THE FPGA. It is the tool for the NEXT phase, not for
#    the build/readback phase -- do not run it while the board is meant to be
#    holding a frozen reference bitstream.
#
#  Environment:
#     P7A_BIT   bitstream to program (default: this project's impl_1 output)
#     P7A_SECS  measurement window in seconds (default 30; acceptance uses 600)
#     P7A_HWURL hw_server URL (default 192.168.0.38:3121)
#
#  VIO packing it expects (must match rtl/p7a_top.v section 8 -- the widths are
#  asserted below, so a mismatch is an abort and not a silent wrong reading):
#     probe_in0 [64] = {err_word_cnt ch1, ch0}      (snapshot)
#     probe_in1 [96] = {bits_cnt ch1, ch0}          (snapshot)
#     probe_in2 [96] = {hdrs_cnt ch1, ch0}          (snapshot)
#     probe_in3 [64] = {hdre_cnt ch1, ch0}          (snapshot)
#     probe_in4 [96] = {rxcyc_cnt ch1, ch0}         (snapshot)
#     probe_in5 [96] = {rxdvcyc_cnt ch1, ch0}       (snapshot)
#     probe_in6 [96] = status word (bit map below)  (mix of snapshot + live)
#     probe_out0 [1] = snapshot request      (level; edge-detected in the FPGA)
#     probe_out1 [1] = counter clear / restart measurement window
#     probe_out2 [1] = force one rxgearboxslip on both channels
#     probe_out3 [1] = GT reset_all (level, active high)
#
#  status word bit map (rtl/p7a_top.v section 8):
#     [47:0] fr_cyc_snap (obs-domain 156.25 MHz cycles at that snapshot)
#     [48]   snap_ack (toggle: flips once per snapshot)
#     [49]   mmcm_locked            [50] gtpowergood ch0   [51] ch1
#     [52]   gt_tx_reset_done      [53] gt_rx_reset_done
#     [54]   gt_rx_cdr_stable      [55] sfp1_rx_los       [56] sfp2_rx_los
#     [57]   acq ch0               [58] acq ch1
#     [59]   ref_link ch0          [60] ref_link ch1      (example leaky bucket)
#     [61]   ref_down_latched ch0  [62] ch1
#     [63]   hdr_ref_valid ch0     [64] ch1
#     [65]   vio_snap_req echo     [66] vio_cnt_clear echo
#     [67]   vio_slip_force echo   [68] vio_gt_reset echo  [69] rst_obs
#     [70]   build fingerprint (=1)  [76:71] hdr_ref ch0  [82:77] hdr_ref ch1
#     [86:85] rxdatavalid ch0 live   [88:87] ch1 live     [95:89] 0
#
#  Five API traps this script was written around (they cost real time in the
#  _proj_mdio bring-up and all of them look like "the VIO is not there"):
#    1. the .ltx probes file MUST be attached to the hw_device, or
#       get_hw_probes returns nothing and [Labtools 27-1974] is the only clue;
#    2. probes are named after the CONNECTED NETS, not after probe_inN;
#    3. refresh_hw_vio / commit_hw_vio take the CORE, not a probe;
#    4. INPUT_VALUE comes back as a STRING in the probe's own radix (HEX);
#    5. OUTPUT_VALUE must be zero-padded to the probe's radix width.
#=============================================================================

set here [file normalize [file dirname [info script]]]
set root [file normalize [file join $here ..]]
set bit  $root/vivado_prj/p7a_prj.runs/impl_1/p7a_top.bit
if {[info exists ::env(P7A_BIT)]}   { set bit $::env(P7A_BIT) }
set secs 30
if {[info exists ::env(P7A_SECS)]}  { set secs $::env(P7A_SECS) }
set url 192.168.0.38:3121
if {[info exists ::env(P7A_HWURL)]} { set url $::env(P7A_HWURL) }

proc sec {s} { puts "\n@@@@@@ P7A >>> $s" }
proc pget {o n} { if {[catch {set v [get_property $n $o]} e]} { return "<ERR:$e>" }; return $v }

sec "PREFLIGHT"
puts "BIT  = $bit"
puts "SECS = $secs"
puts "URL  = $url"
if {![file exists $bit]} { puts "P7A-ABORT: bitstream not found"; exit 1 }
set ltx [file rootname $bit].ltx
puts "LTX  = $ltx exists=[file exists $ltx]"
if {![file exists $ltx]} { puts "P7A-ABORT: .ltx missing -- VIO probes cannot be enumerated"; exit 1 }

sec "CONNECT / SAFETY GATE"
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

sec "PROGRAM"
current_hw_device $tdev
set_property PROGRAM.FILE $bit $tdev
set_property PROBES.FILE $ltx $tdev
set_property FULL_PROBES.FILE $ltx $tdev
if {[catch {program_hw_devices $tdev} em]} { puts "PROGRAM FAILED: $em"; exit 1 }
puts "DONE_PIN = [pget $tdev REGISTER.CONFIG_STATUS.BIT\[14\]_DONE_PIN]"
refresh_hw_device $tdev

sec "VIO / PROBES"
set vio [lindex [get_hw_vios -of_objects $tdev] 0]
if {$vio eq ""} { puts "P7A-ABORT: no VIO in this design"; exit 1 }
puts "VIO = $vio"
foreach p [get_hw_probes -of_objects $vio] {
    puts "  PROBE [pget $p NAME] width=[pget $p WIDTH]"
}

proc findprobe {vio names} {
    set all [get_hw_probes -of_objects $vio]
    foreach n $names {
        foreach p $all { if {$p eq $n} { return $p } }
    }
    foreach n $names {
        foreach p $all { if {[string match $n $p]} { return $p } }
    }
    return ""
}
proc wof {p} { set w 1 ; catch {set w [get_property WIDTH $p]} ; return $w }

# resolve by NAME first, then by probe_inN/probe_outN, and ASSERT the width --
# a wrong width means the packing changed and every reading below would be
# plausible-looking nonsense.
set P_ERR  [findprobe $vio {vio_err_snap probe_in0}]
set P_BITS [findprobe $vio {vio_bits_snap probe_in1}]
set P_HDRS [findprobe $vio {vio_hdrs_snap probe_in2}]
set P_HDRE [findprobe $vio {vio_hdre_snap probe_in3}]
set P_RXC  [findprobe $vio {vio_rxcyc_snap probe_in4}]
set P_RDVC [findprobe $vio {vio_rxdvcyc_snap probe_in5}]
set P_STAT [findprobe $vio {vio_status probe_in6}]
set P_SNAP [findprobe $vio {raw_snap probe_out0}]
set P_CLR  [findprobe $vio {raw_clear probe_out1}]
set P_SLIP [findprobe $vio {raw_slip probe_out2}]
set P_GRST [findprobe $vio {raw_gt_reset probe_out3}]
foreach {nm p w} [list err $P_ERR 64 bits $P_BITS 96 hdrs $P_HDRS 96 hdre $P_HDRE 64 \
                       rxcyc $P_RXC 96 rxdvcyc $P_RDVC 96 status $P_STAT 96 \
                       snap $P_SNAP 1 clear $P_CLR 1 slip $P_SLIP 1 gt_reset $P_GRST 1] {
    if {$p eq ""} { puts "P7A-ABORT: probe '$nm' not found"; exit 1 }
    if {[wof $p] != $w} { puts "P7A-ABORT: probe '$nm' width=[wof $p] expected $w -- packing changed"; exit 1 }
}
puts "PROBES RESOLVED (names and widths verified)"

#------------------------------------------------------------------ helpers
proc vset {vio p val} {
    set w [wof $p]
    set n [expr {int(ceil($w / 4.0))}]
    set s [format "%0${n}X" [expr {$val & ((1 << $w) - 1)}]]
    set_property OUTPUT_VALUE $s $p
    commit_hw_vio $vio
}
proc vget {vio p} {
    refresh_hw_vio $vio
    set s [get_property INPUT_VALUE $p]
    set r "HEX"
    catch { set r [get_property INPUT_VALUE_RADIX $p] }
    switch -- $r {
        HEX     { return [expr "0x$s"] }
        BIN     { return [expr "0b$s"] }
        OCT     { return [expr "0o$s"] }
        default { return [expr {$s}] }
    }
}
# one level pulse: the FPGA edge-detects the RISE, and a JTAG commit is tens of
# ms wide while one transaction inside the FPGA is ~6 ns, so a bare write would
# be "high" for a million cycles.
proc pulse {vio p} { vset $vio $p 1 ; vset $vio $p 0 }

set nsnap 0
proc snap {vio} {
    global P_SNAP P_STAT nsnap
    set before [expr {([vget $vio $P_STAT] >> 48) & 1}]
    pulse $vio $P_SNAP
    set t0 [clock milliseconds]
    while {1} {
        set st [vget $vio $P_STAT]
        if {((($st >> 48) & 1) != $before)} { break }
        if {[clock milliseconds] - $t0 > 2000} { puts "  [WARN] snapshot ack timeout"; break }
    }
    incr nsnap
    return $st
}
proc rd {vio p} { set v [vget $vio $p] ; return $v }

proc decode_status {st} {
    set s {}
    lappend s "mmcm_locked=[expr {($st>>49)&1}]"
    lappend s "gtpowergood=[expr {($st>>51)&1}][expr {($st>>50)&1}]"
    lappend s "tx_done=[expr {($st>>52)&1}]"
    lappend s "rx_done=[expr {($st>>53)&1}]"
    lappend s "cdr_stable=[expr {($st>>54)&1}]"
    lappend s "sfp_rx_los=[expr {($st>>55)&1}][expr {($st>>56)&1}]"
    lappend s "acq=[expr {($st>>57)&1}][expr {($st>>58)&1}]"
    lappend s "ref_link=[expr {($st>>59)&1}][expr {($st>>60)&1}]"
    lappend s "hdr_ref=[format %02X [expr {($st>>71)&63}]]/[format %02X [expr {($st>>77)&63}]]"
    lappend s "hdr_ref_valid=[expr {($st>>63)&1}][expr {($st>>64)&1}]"
    lappend s "rxdv=[expr {($st>>85)&3}][expr {($st>>87)&3}]"
    lappend s "fingerprint=[expr {($st>>70)&1}]"
    return [join $s " "]
}

#------------------------------------------------------------------ run
sec "STATUS BEFORE"
set st [vget $vio $P_STAT]
puts "STATUS $st"
puts "  [decode_status $st]"

sec "RESTART MEASUREMENT WINDOW"
pulse $vio $P_CLR
after 50
set st [vget $vio $P_STAT]
puts "after clear: [decode_status $st]"

puts "\nwaiting for PRBS acquisition (acq on both channels)..."
set t0 [clock milliseconds]
set acqu [expr {((($st>>57)&1) && (($st>>58)&1))}]
while {!$acqu && ([clock milliseconds] - $t0) < 20000} {
    after 500
    set st [vget $vio $P_STAT]
    set acqu [expr {((($st>>57)&1) && (($st>>58)&1))}]
}
puts "acq = $acqu after [expr {[clock milliseconds]-$t0}] ms :: [decode_status $st]"
if {!$acqu} {
    puts "P7A: NO ACQUISITION -- bring-up diagnostic follows"
    puts "  hdr_ref ch0=[format %02X [expr {($st>>71)&63}]] ch1=[format %02X [expr {($st>>77)&63}]] (0 means no header was ever seen)"
    puts "  try: gt_reset pulse, then the forced gearbox slip, then re-read"
    puts "P7A_VERDICT = NO_LINK"
    exit 2
}

sec "MEASURE ($secs s, snapshots every ~10 s)"
snap $vio
set e0 [rd $vio $P_ERR] ; set b0 [rd $vio $P_BITS] ; set f0 [expr {[vget $vio $P_STAT] & 0xFFFFFFFFFFFF}]
set err_acc 0 ; set word_acc 0 ; set ratio_min 1e9 ; set ratio_max 0.0 ; set nwin 0
set t0 [clock milliseconds]
set last [clock milliseconds]
while {[clock milliseconds] - $t0 < ($secs * 1000)} {
    after 200
    if {[clock milliseconds] - $last < 10000 && [clock milliseconds] - $t0 < ($secs*1000)} { continue }
    set last [clock milliseconds]
    set st [snap $vio]
    set e1 [rd $vio $P_ERR] ; set b1 [rd $vio $P_BITS] ; set f1 [expr {$st & 0xFFFFFFFFFFFF}]
    set de [expr {($e1 & 0xFFFFFFFF) - ($e0 & 0xFFFFFFFF)}]
    set db [expr {($b1 & 0xFFFFFFFFFFFF) - ($b0 & 0xFFFFFFFFFFFF)}]
    set df [expr {($f1 & 0xFFFFFFFFFFFF) - ($f0 & 0xFFFFFFFFFFFF)}]
    if {$de < 0} { puts "  [WARN] err delta negative -- counter wrap?" }
    set ws [expr {$db / 64}]
    incr err_acc $de
    incr word_acc $ws
    if {$df > 0 && $ws > 0} {
        set r [expr {double($ws) / double($df)}]
        if {$r < $ratio_min} { set ratio_min $r }
        if {$r > $ratio_max} { set ratio_max $r }
        incr nwin
        puts [format "  win %2d: dWords=%d dErr=%d dFr=%d ratio=%.6f  elapsed=%ds  (ch0 err=%d ch1 err=%d)" \
              $nwin $ws $de $df $r [expr {([clock milliseconds]-$t0)/1000}] [expr {$e1 & 0xFFFFFFFF}] [expr {($e1>>32) & 0xFFFFFFFF}]]
    } else {
        puts "  win $nwin: no rx activity (dWords=$ws dFr=$df) -- is the link up?"
    }
    set e0 $e1 ; set b0 $b1 ; set f0 $f1
}

sec "VERDICT"
set st [vget $vio $P_STAT]
puts "STATUS $st"
puts "  [decode_status $st]"
puts "WINDOWS      = $nwin"
puts "TOTAL_WORDS  = $word_acc   (each = 64 payload bits)"
puts "TOTAL_BITS   = [expr {$word_acc * 64}]"
puts "TOTAL_ERRW   = $err_acc"
puts "RATIO_RANGE  = [format %.6f %.6f] [expr {$nwin>0 ? $ratio_min : 0}] [expr {$nwin>0 ? $ratio_max : 0}]"
if {$word_acc > 0} {
    if {$err_acc == 0} {
        puts "BER_UPPER_95CL < [format %.3e [expr {3.0/($word_acc*64.0)}]]  (0 errors in $word_acc words)"
    } else {
        puts "BER_MEASURED   = [format %.3e [expr {double($err_acc)/($word_acc*64.0)}]]"
    }
} else {
    puts "BER = UNDEFINED (no words counted -- an empty reading is not a zero)"
}
# the ratio is the RUN-TIME gearbox discriminator: 1.0 = 66/64 gearbox,
# 1.03125 = raw 64/64 (10.3125e9/64 / 156.25e6)
if {$nwin > 0} {
    if {$ratio_min > 0.999 && $ratio_max < 1.001} {
        puts "GEARBOX_RATIO_VERDICT = 1.000 => the fabric interface carries 64 payload bits per 66 baud => GEARBOX IN PATH"
    } elseif {$ratio_min > 1.030 && $ratio_max < 1.033} {
        puts "GEARBOX_RATIO_VERDICT = 1.03125 => RAW 64/64 datapath => NO GEARBOX IN PATH"
    } else {
        puts "GEARBOX_RATIO_VERDICT = inconclusive (ratio range [format %.6f $ratio_min],[format %.6f $ratio_max])"
    }
}
puts "P7A_VERDICT_END"
disconnect_hw_server
puts "DONE"
