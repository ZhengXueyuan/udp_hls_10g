# diag2 重烧脚本 (自建; 不改任何既有脚本). 只走 JTAG, 绝不写 QSPI.
set bit D:/repo/XCKU5PMini/udp_hls_10g/vivado_prj/p7b_ku5p_prj.runs/impl_1/wrapper_p4.bit
set url 192.168.0.38:3121
open_hw_manager
connect_hw_server -url $url
set tgt [lindex [get_hw_targets] 0]
open_hw_target $tgt
set dev [lindex [get_hw_devices xcku5p*] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
set_property PARAM.FREQUENCY 1000000 [get_hw_targets $tgt]
puts "DIAG2_BIT = $bit"
if {![file exists $bit]} { puts "DIAG2-ABORT: bitstream missing"; exit 1 }
set_property PROGRAM.FILE $bit $dev
if {[catch {program_hw_devices $dev} em]} { puts "DIAG2-ABORT PROGRAM FAILED: $em"; exit 1 }
refresh_hw_device -update_hw_probes false $dev
puts "DIAG2_PROG_DONE"
close_hw_target
disconnect_hw_server
close_hw_manager
exit 0
