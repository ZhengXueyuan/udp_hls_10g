# program_p7b_ku5p.tcl — 把 P7b 闸 4 位流经 JTAG 烧到 KU5P (1MHz; 只走 JTAG, 绝不写 QSPI)
#   模板来源: _proj_pcie/program_p6e.tcl (逐处保留其两条纪律注释与 1MHz 降频)
#   ⚠️ 烧完必须**重启对端机**才能在 PCIe 上读到板侧计数 (PCIe 端点只认"FPGA 配置先于主机 POST")
#   ⚠️ **构建期间不许跑本脚本**: 判据 = 构建已结束 且 位流文件存在。
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
puts "G4_BIT = $bit"
puts "G4_BIT_MTIME = [file mtime $bit]"
puts "G4_PROG device=$dev freq=1MHz"
if {![file exists $bit]} { puts "G4-ABORT: bitstream missing"; exit 1 }
set_property PROGRAM.FILE $bit $dev
if {[catch {program_hw_devices $dev} em]} { puts "G4-ABORT PROGRAM FAILED: $em"; exit 1 }
refresh_hw_device -update_hw_probes false $dev
puts "G4_PROG_DONE (检查上方 'End of startup status: HIGH')"
close_hw_target
disconnect_hw_server
close_hw_manager
exit 0
