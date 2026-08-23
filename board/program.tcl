#=============================================================================
# program.tcl — ECO 板 JTAG 1MHz 烧录 (PROGRAM.FILE 必设)
# 用法: vivado -mode batch -source program.tcl -tclargs <bitfile>
#       (run_program.bat 已带默认位流路径)
# 参照: udp_hls_eco/program_eco.tcl + k701_led_stream/program_hw.tcl 模式:
#       - JTAG 降频 1MHz (PARAM.FREQUENCY 1000000)
#       - PROGRAM.FILE 必设; 2025.2 下 program_hw_devices 成功即打印
#         "End of startup status: HIGH" (DONE), 无独立 DONE 属性可查,
#         以日志为准。
#=============================================================================
set bitfile [lindex $argv 0]
if {$bitfile eq ""} { set bitfile "D:/repo/ECO/udp_hls_10g/vivado_prj/udp_loop_phy1.runs/impl_1/wrapper_1g.bit" }

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
