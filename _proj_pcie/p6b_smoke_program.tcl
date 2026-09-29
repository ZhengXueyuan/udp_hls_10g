# p6b_smoke_program.tcl — 冒烟测试专用: 把 P6b 位流经 JTAG 烧到 KU5P (1MHz; 只走 JTAG, 绝不写 QSPI)
#   作者: P6b 冒烟测试 agent (新增文件, 不改任何既有脚本)
#   ⚠️ 用 smoke_scratch/p6b_smoke.bit = 冻结副本 (sha256 已记录), 免得别的 agent 重建把它覆盖掉。
#   ⚠️ 烧完必须**重启主机**才能在 lspci/观测通道里看到端点 (PCIe 端点只认"FPGA 配置先于主机 POST")。
#   ⚠️ 构建期间不许跑 (板级测量前置闸: 别从正在被构建的工程里烧位流)。
set bit D:/repo/XCKU5PMini/udp_hls_10g/_proj_pcie/smoke_scratch/p6b_smoke.bit

open_hw_manager
connect_hw_server -url 192.168.0.38:3121
set tgt [lindex [get_hw_targets] 0]
open_hw_target $tgt
set dev [lindex [get_hw_devices xcku5p*] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
set_property PARAM.FREQUENCY 1000000 [get_hw_targets $tgt]
puts "PROG device=$dev freq=1MHz file=$bit"
if {![file exists $bit]} { puts "PROG ERROR: bitstream missing"; exit 1 }
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
refresh_hw_device -update_hw_probes false $dev
puts "PROG DONE (检查上方 'End of startup status: HIGH')"
close_hw_target
disconnect_hw_server
close_hw_manager
