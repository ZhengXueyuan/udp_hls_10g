# program_s2_ku5p.tcl — P7B-BIZ Stage 2: 烧修复位流 (BNIZ, sha256 d20c08c9…) 经 JTAG 到 KU5P
#   模板来源: _proj_10g/notes/p7b_rate_result/program_rate_ku5p.tcl (逐处保留其纪律)
#   只走 JTAG / 1MHz; 绝不写 QSPI。
#   烧完的 PCIe 恢复: remove+rescan (P7B_PCIE_RESCAN_RECOVERY.md §3, 不必重启对端机)
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
puts "S2_BIT = $bit"
puts "S2_BIT_MTIME = [file mtime $bit]"
puts "S2_PROG device=$dev freq=1MHz"
if {![file exists $bit]} { puts "S2-ABORT: bitstream missing"; exit 1 }
set_property PROGRAM.FILE $bit $dev
if {[catch {program_hw_devices $dev} em]} { puts "S2-ABORT PROGRAM FAILED: $em"; exit 1 }
refresh_hw_device -update_hw_probes false $dev
puts "S2_PROG_DONE (检查上方 'End of startup status: HIGH')"
close_hw_target
disconnect_hw_server
close_hw_manager
exit 0
