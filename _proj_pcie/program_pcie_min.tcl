# program_pcie_min.tcl — 把 P6e 最小版位流经 JTAG 烧到 KU5P (1MHz; 只走 JTAG, 绝不写 QSPI)
#   烧完必须**重启主机**才能在 lspci 里看到端点 (PCIe 端点只认"FPGA 配置先于主机 POST")
#   —— 依据: _pcie/README.md 第二节的四组对照实验。
set bit D:/repo/XCKU5PMini/udp_hls_10g/_proj_pcie/vivado_prj/pcie_min_prj.runs/impl_1/pcie_min_top.bit

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
