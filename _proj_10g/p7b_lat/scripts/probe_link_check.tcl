#=============================================================================
# probe_link_check.tcl -- 侦察: 把**现役 P7b 位流**烧上去, 看网卡侧的链路是否
#   恢复 (对端 enp1s0f1np1 现在**一个地址都没有** ⇒ 内核根本不发包)。
#
#   ⚠️ 用的是 `p7b_ku5p_prj` 的位流 —— 它**不是**正在被构建的那个工程
#      (正在构建的是 `p7b_lat_prj`) ⇒ 不违反"构建期间不得从被构建的工程烧位流"。
#   ⚠️ JTAG 易失烧录; 绝不写 QSPI。
#=============================================================================
set here [file normalize [file dirname [info script]]]
set root [file normalize [file join $here .. .. ..]]
set bit  [file join $root vivado_prj p7b_ku5p_prj.runs impl_1 wrapper_p4.bit]
set ltx  [file join $root vivado_prj p7b_ku5p_prj.runs impl_1 wrapper_p4.ltx]
if {[info exists ::env(LAT_BIT)]} { set bit $::env(LAT_BIT) }
set url 192.168.0.38:3121
if {[info exists ::env(LAT_HWURL)]} { set url $::env(LAT_HWURL) }

proc sec {s} { puts "\n@@@@@@ LNK >>> $s" ; flush stdout }
puts "LNK_BIT = $bit exists=[file exists $bit]"

sec "CONNECT"
open_hw_manager
connect_hw_server -url $url
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
set dlist [get_hw_devices]
puts "LNK_DEVC = [llength $dlist]"
set tdev ""
foreach d $dlist { if {[get_property IDCODE_HEX $d] eq "04A62093"} { set tdev $d } }
if {$tdev eq "" || [llength $dlist] != 1} { puts "LNK_SAFETY_ABORT" ; exit 1 }

sec "PROGRAM"
current_hw_device $tdev
set_property PROGRAM.FILE $bit $tdev
if {[file exists $ltx]} {
    set_property PROBES.FILE $ltx $tdev
    set_property FULL_PROBES.FILE $ltx $tdev
}
if {[catch {program_hw_devices $tdev} em]} { puts "LNK_PROGRAM_FAIL: $em" ; exit 1 }
puts "LNK_DONE = [get_property REGISTER.CONFIG_STATUS.BIT\[14\]_DONE_PIN $tdev]"
puts "LNK OK"
exit
