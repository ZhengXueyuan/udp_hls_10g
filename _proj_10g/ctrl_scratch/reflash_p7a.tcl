#=============================================================================
# reflash_p7a.tcl -- put the board back the way the P7a agent left it.
#
#   The control experiment (ctrl_ibert_v3.tcl) overwrote the FPGA with the
#   iBERT v3 reference image.  This script restores the P7a acceptance image so
#   that no later session finds a stale image under a P7a probes file.
#   Volatile JTAG only; QSPI is never touched.
#   It then re-reads the two RX_LOS bits through the P7a VIO, which also
#   answers "did loading iBERT change the optical state?".
#=============================================================================
set here [file normalize [file dirname [info script]]]
set p10  [file normalize [file join $here ..]]
set bit  $p10/vivado_prj/p7a_prj.runs/impl_1/p7a_top.bit
set ltx  [file rootname $bit].ltx
set url  192.168.0.38:3121
if {[info exists ::env(CTRL_HWURL)]} { set url $::env(CTRL_HWURL) }

proc sec {s} { puts "\n@@@@@@ REFLASH >>> $s" ; flush stdout }
proc pget {o n} { if {[catch {set v [get_property $n $o]} e]} { return "<ERR:$e>" } ; return $v }
proc bit  {v n} { expr {($v >> $n) & 1} }
proc hexint {s} { set s [string trim $s] ; return [expr "0x$s"] }

sec "PREFLIGHT"
puts "restoring bit = $bit  exists=[file exists $bit] size=[file size $bit]"
puts "          ltx = $ltx  exists=[file exists $ltx]"
puts "EXPECTED sha256 bit f88d019fc53a8d07d04d14670188f8148d36e09bb9ba8d1b0df366cbf9f8651d"
puts "EXPECTED sha256 ltx 5dd5fa692c315c51fa72d7283e67a8b97c235b9b0a63dd78f5137ab1045455db"

sec "CONNECT + SAFETY GATE"
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
    puts "REFLASH-SAFETY_ABORT: target='$tdev' count=[llength $dlist] -- NOT PROGRAMMING"
    exit 1
}
puts "SAFETY_GATE = PASS -> $tdev"
current_hw_device $tdev

sec "PROGRAM P7a (volatile, JTAG)"
set_property PROGRAM.FILE $bit $tdev
catch {set_property PROBES.FILE $ltx $tdev}
catch {set_property FULL_PROBES.FILE $ltx $tdev}
if {[catch {program_hw_devices $tdev} em]} { puts "REFLASH-ABORT: $em" ; exit 1 }
set done [pget $tdev REGISTER.CONFIG_STATUS.BIT\[14\]_DONE_PIN]
puts "DONE_PIN = $done"
if {$done != 1} { puts "REFLASH-ABORT: DONE != 1"; exit 1 }
catch {refresh_hw_device -update_hw_probes true $tdev}

sec "VERIFY: P7a VIO alive, LOS re-read"
set vio [lindex [get_hw_vios -of_objects $tdev] 0]
if {$vio eq ""} { puts "REFLASH-WARN: no VIO enumerated"; disconnect_hw_server ; exit 0 }
array set W {}
foreach p [get_hw_probes -of_objects $vio] { set W([pget $p NAME]) $p }
puts "probe count = [array size W]  fingerprint probe 'vio_status' present = [expr {[info exists W(vio_status)] ? 1 : 0}]"
foreach tag {AFTER-1 AFTER-2} {
    catch {refresh_hw_vio $vio}
    set st [hexint [get_property INPUT_VALUE $W(vio_status)]]
    puts "@@@@ $tag status=$st"
    puts "     fingerprint=[bit $st 70] (must be 1 = this is the P7a build)"
    puts "     sfp1_rx_los=[bit $st 55]  sfp2_rx_los=[bit $st 56]"
    puts "     acq=[bit $st 57][bit $st 58] ref_link=[bit $st 59][bit $st 60] ref_down_latched=[bit $st 61][bit $st 62]"
    puts "     gtpowergood=[bit $st 50][bit $st 51] tx_reset_done=[bit $st 52] rx_cdr_stable=[bit $st 54]"
    after 2500
}
puts ""
puts "REFLASH-COMPLETE -- board is back on the P7a image."
disconnect_hw_server
puts "DONE"
