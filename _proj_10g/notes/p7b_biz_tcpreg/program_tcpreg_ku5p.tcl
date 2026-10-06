# program_tcpreg_ku5p.tcl — P7B-BIZ TCP 退化归因轮: 经 JTAG 烧指定位流到 KU5P
#   位流路径来自环境变量 TCPREG_BIT (A/B 两臂共用本脚本 ⇒ 烧录路径唯一, 无手抄)。
#   模板逐处继承 p7b_biz_s2/program_s2_ku5p.tcl 的纪律: 只走 JTAG / 1MHz; 绝不写 QSPI。
set bit $::env(TCPREG_BIT)
set url 192.168.0.38:3121

open_hw_manager
connect_hw_server -url $url
set tgt [lindex [get_hw_targets] 0]
open_hw_target $tgt
set dev [lindex [get_hw_devices xcku5p*] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
set_property PARAM.FREQUENCY 1000000 [get_hw_targets $tgt]
puts "TCPREG_BIT = $bit"
puts "TCPREG_BIT_EXISTS = [file exists $bit]"
puts "TCPREG_BIT_MTIME = [file mtime $bit]"
puts "TCPREG_PROG device=$dev freq=1MHz"
if {![file exists $bit]} { puts "TCPREG-ABORT: bitstream missing"; exit 1 }
set_property PROGRAM.FILE $bit $dev
if {[catch {program_hw_devices $dev} em]} { puts "TCPREG-ABORT PROGRAM FAILED: $em"; exit 1 }
refresh_hw_device -update_hw_probes false $dev
puts "TCPREG_PROG_DONE (检查上方 'End of startup status: HIGH')"
close_hw_target
disconnect_hw_server
close_hw_manager
exit 0
