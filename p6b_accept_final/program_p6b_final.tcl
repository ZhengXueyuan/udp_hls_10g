# program_p6b_final.tcl — 把 P6b **最终冻结位流**经 JTAG 烧到 KU5P (TCK 1MHz)
#   由 P6b 最终验收 agent 新增 (不改任何既有脚本)。
#   ⚠️ 只走 JTAG 易失烧录, **绝不写板载 QSPI** (那里是厂商 XDMA+DDR4 设计)。
#   ⚠️ 构建期间不许跑 (本工程纪律: 别从正在被构建的工程里烧位流)。
#   ⚠️ 烧完必须**重启主机** (PCIe 端点只认"FPGA 配置先于主机 POST"; 事后补救实测全无效)。
#   位流身份: 烧的是本目录的**冻结副本** (不是 build 树里的路径) —— 免得别的进程重建时把它覆盖,
#             副本 sha256 = c17700868b08170865f4a4ae0292ebb636aed03070e2875f6dbb005123a948ca
#             (原始 = vivado_prj/p6b_final_ku5p_prj.runs/impl_1/wrapper_p4.bit, 同一 sha256)
set bit D:/repo/XCKU5PMini/udp_hls_10g/p6b_accept_final/frozen_p6b_final.bit

open_hw_manager
connect_hw_server -url 192.168.0.38:3121
set tgt [lindex [get_hw_targets] 0]
open_hw_target $tgt
set dev [lindex [get_hw_devices xcku5p*] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
set_property PARAM.FREQUENCY 1000000 [get_hw_targets $tgt]
if {![file exists $bit]} { puts "PROG ERROR: bitstream missing: $bit"; exit 1 }
puts "PROG device=$dev freq=1MHz file=$bit size=[file size $bit]"
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
refresh_hw_device -update_hw_probes false $dev
puts "PROG DONE (判据: 上方出现 'End of startup status: HIGH')"
close_hw_target
disconnect_hw_server
close_hw_manager
