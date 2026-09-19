#=============================================================================
# build_p5a0.tcl — P5a-0 前置实验工程: 与 P4 位流唯一差别 = APP_MODE 宏定义
#
# !! 历史实验脚本 (2026-09-19 一次性) — 不要重跑 !!
# 本次运行时的 wrapper_p4.v 只有 APP_EN 一处 ifdef (无 app 模块实例), 实验结论
# (suppress=0 稳态 857Mbps) 见 PORT_NOTES「P5a-0 破案」。此后 RTL 已加入
# app_ctrl/app_pattern/app_status_uart, 本 tcl 的文件清单**不含**它们 ⇒ 重跑会
# 得到"实例化了不存在模块"的不一致位流。当前 app 构建用 board/build_p5.tcl。
# 实验位流已存于 vivado_prj/p5a0_prj.runs/impl_1/wrapper_p4.bit (保留作对照)。
#                 (强制 cfg_suppress_data_ack=0 = 逐段纯 ACK, app 模式的 ACK 契约)
# 目的: 用合成对端 (tools/cpp_peer) 复测"逐段纯 ACK"板级吞吐 — P4c 的 28.4Mbps
#       数据在 w6a (纯 ACK 窗口右沿接受) 修复之前, 已过时; 该数值决定 P5 app
#       模式的 ACK 策略是否可行 (若不可行须先做延迟 ACK 批处理)。
# 独立工程名 => 不覆盖已验证的 p4_prj 位流 (vivado_prj/p5a0_prj.runs/impl_1/)。
#=============================================================================
set project_name  p5a0_prj
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
                         ${root_dir}/rtl/tx_arb.v
import_files -norecurse ${script_dir}/wrapper_p4.v ${script_dir}/util_gmii_to_rgmii.v \
                         ${script_dir}/uart_dbg.v
import_files -norecurse [glob -nocomplain ${hls_dir}/*.v]
set src_dir [file dirname [lindex [glob -nocomplain ${root_dir}/vivado_prj/${project_name}.srcs/sources_1/imports/verilog/udp_echo.v] 0]]
if {$src_dir eq ""} {
    set src_dir [file dirname [lindex [glob -nocomplain ${root_dir}/vivado_prj/${project_name}.srcs/sources_1/imports/*/udp_echo.v] 0]]
}
foreach dat [glob -nocomplain ${hls_dir}/*.dat] { file copy -force $dat $src_dir/ }
add_files -fileset constrs_1 ${script_dir}/eco_rgmii_phy1.xdc
set_property top $top_module [current_fileset]
set_property verilog_define {APP_MODE=1} [current_fileset]
update_compile_order -fileset sources_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
set_property strategy Performance_ExtraTimingOpt [get_runs impl_1]
launch_runs impl_1 -jobs 8
wait_on_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
puts "\n===== BITSTREAM DONE: ${root_dir}/vivado_prj/${project_name}.runs/impl_1/${top_module}.bit ====="
exit
