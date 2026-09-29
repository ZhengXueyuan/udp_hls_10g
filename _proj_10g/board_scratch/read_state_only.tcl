#=============================================================================
# read_state_only.tcl -- READ-ONLY diagnostic of the P7a design that is already
#                        configured in the FPGA.
#
#   *** THIS SCRIPT NEVER PROGRAMS.  It only opens the target, attaches the
#   *** probes file and reads the VIO.  (Verified by construction: the string
#   *** "program_hw_devices" does not appear in this file.)
#
#   Why it exists: the P7a acceptance run stopped at STAGE B2 with no PRBS lock.
#   The task's instruction is to stop and report, NOT to burn repeatedly -- but
#   the counters/indexes that the stop-path did not print are still readable, and
#   two of them are genuinely diagnostic:
#     * rxcyc_cnt / rxdvcyc_cnt  -> the duty cycle of rxdatavalid, which is the
#       design's own answer to "is the RX producing words at all" (spec 9.12
#       says the duty cycle is undocumented, which is why the counter exists);
#     * the RX_LOS bits re-read minutes apart -> is the loss-of-signal reading
#       stable (a real dark cage) or a floating pin?
#   It is read-only, so it cannot disturb whatever the board is doing.
#=============================================================================

set here [file normalize [file dirname [info script]]]
set p10  [file normalize [file join $here ..]]
set bit  $p10/vivado_prj/p7a_prj.runs/impl_1/p7a_top.bit
set ltx  [file rootname $bit].ltx
set url  192.168.0.38:3121
if {[info exists ::env(P7A_HWURL)]} { set url $::env(P7A_HWURL) }

proc sec {s} { puts "\n@@@@@@ READ-ONLY >>> $s" ; flush stdout }
proc pget {o n} { if {[catch {set v [get_property $n $o]} e]} { return "<ERR:$e>" } ; return $v }
proc bit  {v n} { expr {($v >> $n) & 1} }
proc hexint {s} { set s [string trim $s] ; return [expr "0x$s"] }

puts "READ-ONLY DIAGNOSTIC -- no programming, no reset, no VIO writes"
puts "bit (context only, NOT loaded here) = $bit"

open_hw_manager
connect_hw_server -url $url
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
set dlist [get_hw_devices]
puts "device count = [llength $dlist]"
foreach d $dlist { puts "DEVICE $d PART=[pget $d PART] IDCODE=[pget $d IDCODE_HEX]" }
set tdev [lindex $dlist 0]
if {[pget $tdev IDCODE_HEX] ne "04A62093" || [llength $dlist] != 1} {
    puts "READONLY-ABORT: not the expected single xcku5p target"; exit 1
}
current_hw_device $tdev
set_property PROBES.FILE $ltx $tdev
set_property FULL_PROBES.FILE $ltx $tdev
refresh_hw_device $tdev
puts "DONE_PIN = [pget $tdev REGISTER.CONFIG_STATUS.BIT\[14\]_DONE_PIN]"

set vio [lindex [get_hw_vios -of_objects $tdev] 0]
if {$vio eq ""} { puts "READONLY-ABORT: no VIO enumerated"; exit 1 }
puts "VIO = $vio"
array set W {}
foreach p [get_hw_probes -of_objects $vio] {
    set nm [pget $p NAME]
    set W($nm) $p
    puts "  PROBE name=$nm width=[pget $p WIDTH]"
}
# the host's own writes are irrelevant here, but the probe echoes say what the
# last run left behind
proc rd {p} { return [hexint [get_property INPUT_VALUE $p]] }

foreach {tag} {SAMPLE-1 SAMPLE-2 SAMPLE-3} {
    refresh_hw_vio $vio
    set st   [rd $W(vio_status)]
    set err  [rd $W(vio_err_snap)]
    set bits [rd $W(vio_bits_snap)]
    set hdrs [rd $W(vio_hdrs_snap)]
    set hdre [rd $W(vio_hdre_snap)]
    set rxc  [rd $W(vio_rxcyc_snap)]
    set rdc  [rd $W(vio_rxdvcyc_snap)]
    set rx0  [expr {$rxc & 0xFFFFFFFFFFFF}]
    set rd0  [expr {$rdc & 0xFFFFFFFFFFFF}]
    set rx1  [expr {($rxc >> 48) & 0xFFFFFFFFFFFF}]
    set rd1  [expr {($rdc >> 48) & 0xFFFFFFFFFFFF}]
    puts ""
    puts "@@@@ $tag"
    puts "  status            = $st"
    puts "  mmcm_locked=[bit $st 49] gtpowergood=[bit $st 50][bit $st 51] tx_reset_done=[bit $st 52] rx_reset_done=[bit $st 53] cdr_stable(ch0)=[bit $st 54]"
    puts "  sfp1_rx_los=[bit $st 55]  sfp2_rx_los=[bit $st 56]"
    puts "  acq=[bit $st 57][bit $st 58]  ref_link=[bit $st 59][bit $st 60]  ref_down_latched=[bit $st 61][bit $st 62]"
    puts "  hdr_ref_valid=[bit $st 63][bit $st 64]  hdr_ref ch0=[expr {($st>>71)&63}] ch1=[expr {($st>>77)&63}]"
    puts "  rxdv live (ch0,ch1) = [expr {($st>>85)&3}],[expr {($st>>87)&3}]"
    puts "  echo snap/clr/slip/gtrst = [bit $st 65][bit $st 66][bit $st 67][bit $st 68]   rst_obs=[bit $st 69] fingerprint=[bit $st 70]"
    puts "  err_snap   ch0=[expr {$err & 0xFFFFFFFF}] ch1=[expr {($err>>32)&0xFFFFFFFF}]"
    puts "  bits_snap  ch0=[expr {$bits & 0xFFFFFFFFFFFF}] ch1=[expr {($bits>>48)&0xFFFFFFFFFFFF}]"
    puts "  hdrs_snap  ch0=[expr {$hdrs & 0xFFFFFFFFFFFF}] ch1=[expr {($hdrs>>48)&0xFFFFFFFFFFFF}]"
    puts "  hdre_snap  ch0=[expr {$hdre & 0xFFFFFFFF}] ch1=[expr {($hdre>>32)&0xFFFFFFFF}]"
    puts "  rxcyc_cnt  ch0=$rx0 ch1=$rx1"
    puts "  rxdvcyc_cnt ch0=$rd0 ch1=$rd1"
    if {$rx0 > 0} { puts "  rxdv duty ch0 = [format %.6f [expr {double($rd0)/double($rx0)}]]" }
    if {$rx1 > 0} { puts "  rxdv duty ch1 = [format %.6f [expr {double($rd1)/double($rx1)}]]" }
    if {$rx0 > 0} { puts "  rxcyc_cnt ch0 ($rx0 clk of 6.4 ns) = [format %.3f [expr {double($rx0)*6.4/1000.0}]] us since the last clear/rst" }
    after 3000
}
puts ""
puts "READ-ONLY DIAGNOSTIC COMPLETE (nothing was programmed, no VIO output was written)"
disconnect_hw_server
puts "DONE"
