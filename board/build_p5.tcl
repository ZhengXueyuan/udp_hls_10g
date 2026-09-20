#=============================================================================
# build_p5.tcl — udp_hls_10g 板上 P5a 工程构建 (APP_MODE: app AXIS + 控制面):
#                create_project -force + synth/impl/bitstream
# 用法: 由 run_build_p5.bat 全路径调用 (vivado -mode batch -source board/build_p5.tcl)
# 产物: vivado_prj/p5_prj.runs/impl_1/wrapper_p4.bit
#       (工程名 P5 = p5_prj, 顶层仍是 wrapper_p4 — 不覆盖 P4 的 wrapper_p4.bit)
# 与 build_p4.tcl 的差异 (逐项):
#   ① project_name p4_prj -> p5_prj (独立工程, 不覆盖默认口径)
#   ② 文件清单 += rtl/app_ctrl.v / rtl/app_pattern.v / rtl/app_status_uart.v
#      (P5e-T3 再 += rtl/app_udp_pattern.v / rtl/udp_tx_cfg.v / rtl/udp_tx_frame.v)
#   ③ verilog_define APP_MODE=1 (wrapper 的 APP_MODE 分支: app 数据面 +
#      cfg_suppress_data_ack=0 + LED/状态行走 app 口径)
#   build_p4.tcl 不动 (默认构建 = echo 数据面, 零风险)
#=============================================================================
set project_name  p5_prj
set top_module    wrapper_p4
set part_name     xc7k325tffg676-2

set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file dirname $script_dir]
set hls_dir    D:/repo/ECO/udp_hls_10g/hls/slowstack_prj/solution1/syn/verilog

create_project -force $project_name ${root_dir}/vivado_prj -part $part_name
import_files -norecurse ${root_dir}/rtl/crc32_8b.v \
                         ${root_dir}/rtl/fifo_sync.v \
                         ${root_dir}/rtl/checksum16.v \
                         ${root_dir}/rtl/frame_fifo.v \
                         ${root_dir}/rtl/mac_rx_64.v \
                         ${root_dir}/rtl/mac_tx_64.v \
                         ${root_dir}/rtl/tcp_cam.v \
                         ${root_dir}/rtl/tcb.v \
                         ${root_dir}/rtl/tcp_rx.v \
                         ${root_dir}/rtl/tcp_tx_frame.v \
                         ${root_dir}/rtl/retx_ram.v \
                         ${root_dir}/rtl/tcp_echo.v \
                         ${root_dir}/rtl/axis_pipe.v \
                         ${root_dir}/rtl/rx_classify.v \
                         ${root_dir}/rtl/vlan_strip.v \
                         ${root_dir}/rtl/slow_rx_adp.v \
                         ${root_dir}/rtl/slow_cfg_adp.v \
                         ${root_dir}/rtl/slow_tx_adp.v \
                         ${root_dir}/rtl/udp_rx.v \
                         ${root_dir}/rtl/udp_split.v \
                         ${root_dir}/rtl/udp_tx_cfg.v \
                         ${root_dir}/rtl/udp_tx_frame.v \
                         ${root_dir}/rtl/tx_arb.v \
                         ${root_dir}/rtl/app_ctrl.v \
                         ${root_dir}/rtl/app_pattern.v \
                         ${root_dir}/rtl/app_udp_pattern.v \
                         ${root_dir}/rtl/app_status_uart.v
import_files -norecurse ${script_dir}/wrapper_p4.v ${script_dir}/util_gmii_to_rgmii.v \
                         ${script_dir}/uart_dbg.v
import_files -norecurse [glob -nocomplain ${hls_dir}/*.v]
# HLS $readmemh 系数文件必须拷到导入后的 verilog 同目录 (综合按相对路径找)
set src_dir [file dirname [lindex [glob -nocomplain ${root_dir}/vivado_prj/${project_name}.srcs/sources_1/imports/verilog/udp_echo.v] 0]]
if {$src_dir eq ""} {
    set src_dir [file dirname [lindex [glob -nocomplain ${root_dir}/vivado_prj/${project_name}.srcs/sources_1/imports/*/udp_echo.v] 0]]
}
foreach dat [glob -nocomplain ${hls_dir}/*.dat] { file copy -force $dat $src_dir/ }
add_files -fileset constrs_1 ${script_dir}/eco_rgmii_phy1.xdc
set_property verilog_define APP_MODE=1 [current_fileset]
set_property top $top_module [current_fileset]
update_compile_order -fileset sources_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
# P6 时序: 残余 ~78ps 违例 (retx_ram 读出 -> checksum16 累加器) 用
# Performance_ExtraTimingOpt 布局收口
set_property strategy Performance_ExtraTimingOpt [get_runs impl_1]
launch_runs impl_1 -jobs 8
wait_on_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
puts "\n===== BITSTREAM DONE: ${root_dir}/vivado_prj/${project_name}.runs/impl_1/${top_module}.bit ====="
exit
