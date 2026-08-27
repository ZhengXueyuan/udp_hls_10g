#=============================================================================
# program_tcp.tcl — ECO 板 JTAG 1MHz 烧录 wrapper_tcp.bit
# 用法: vivado -mode batch -source program_tcp.tcl -tclargs <bitfile>
# 参照: board/program_echo.tcl (同模式: JTAG 1MHz + PROGRAM.FILE 必设,
#       program_hw_devices 成功 = DONE=HIGH)
#=============================================================================
set bitfile [lindex $argv 0]
if {$bitfile eq ""} { set bitfile "D:/repo/ECO/udp_hls_10g/vivado_prj/tcp_echo_prj.runs/impl_1/wrapper_tcp.bit" }

open_hw_manager
if {[catch {connect_hw_server -url localhost:3121} msg]} { puts "HW_CONNECT_FAILED: $msg"; exit 1 }
set targets [get_hw_targets *]
if {[llength $targets] == 0} { puts "NO_TARGETS_FOUND"; exit 1 }
puts "TARGETS: $targets"
open_hw_target [lindex $targets 0]
set_property PARAM.FREQUENCY 1000000 [current_hw_target]
set dev [lindex [get_hw_devices] 0]
if {$dev eq ""} { puts "NO_DEVICES_FOUND"; exit 1 }
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
puts "=== PROGRAMMING $dev with $bitfile ==="
set_property PROGRAM.FILE $bitfile $dev
if {[catch {program_hw_devices $dev} msg]} { puts "PROGRAM_FAILED: $msg"; exit 1 }
puts "PROGRAM_OK"
close_hw_manager
exit 0
