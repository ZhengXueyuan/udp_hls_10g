#=============================================================================
# timing_p5.tcl — P5b 时序快速迭代用 (P0 修复期间的近似时序门)
#   synth_design -> opt_design -> place_design -> report_timing_summary
#   (不跑 route/bitgen: place 后 WNS 与 route 后通常差 ±0.3ns, 迭代快 ~3 倍)
# 与 board/build_p5.tcl 的差异: ① 工程名 p5t_prj (不覆盖 p5_prj 产物)
#   ② 不写位流 ③ 结束后打印 WNS/TNS 摘要行
# ⚠️ 文件清单与 build_p5.tcl 保持**逐项一致** (改 RTL 后两者都要重跑 tcl:
#    create_project 会把源文件复制进工程, 改文件不改 tcl 不会重新读入)。
# 用法: from Git Bash:
#   cmd //c 'D:\repo\ECO\udp_hls_10g\board\run_timing_p5.bat'
#=============================================================================
set project_name  p5t_prj
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
set src_dir [file dirname [lindex [glob -nocomplain ${root_dir}/vivado_prj/${project_name}.srcs/sources_1/imports/verilog/udp_echo.v] 0]]
if {$src_dir eq ""} {
    set src_dir [file dirname [lindex [glob -nocomplain ${root_dir}/vivado_prj/${project_name}.srcs/sources_1/imports/*/udp_echo.v] 0]]
}
foreach dat [glob -nocomplain ${hls_dir}/*.dat] { file copy -force $dat $src_dir/ }
add_files -fileset constrs_1 ${script_dir}/eco_rgmii_phy1.xdc
set_property verilog_define APP_MODE=1 [current_fileset]
set_property top $top_module [current_fileset]
update_compile_order -fileset sources_1
set_property strategy Performance_ExtraTimingOpt [get_runs impl_1]
launch_runs synth_1 -jobs 8
wait_on_run synth_1
open_run synth_1 -name synth_1
opt_design
place_design
report_timing_summary -max_paths 10 -routable_nets -file ${root_dir}/vivado_prj/timing_p5_placed.rpt
puts "\n===== P5b PLACE-ONLY TIMING SUMMARY (wrapper_p4_timing_summary_placed) ====="
puts "\n===== PLACE DONE: ${root_dir}/vivado_prj/timing_p5_placed.rpt ====="
exit
