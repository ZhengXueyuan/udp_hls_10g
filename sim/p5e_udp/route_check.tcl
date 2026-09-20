#=============================================================================
# route_check.tcl — P5e-T3 私有门: 把 board/timing_p5.tcl (synth+place) 延长到
#   route_design, 取**布线后** WNS/WHS, 并统计 UDP app 侧实例的 cell 数
#   (判据: app 侧锥这次**真的被综合进去了**, 不再是"无消费者被裁剪")。
# 与 board/timing_p5.tcl 的差异: ① 工程名 p5r3_prj (不覆盖 p5t_prj/p5r_prj)
#   ② 追加 route_design ③ 报告落 vivado_prj/timing_p5_routed_t3.rpt
#   ④ 打印 u_udp_split / u_udp_tx / u_udp_tx_cfg / u_app_udp / u_tx_udp_arb 的
#      cell 数 (T1/T2 都因"无消费者被裁剪"而无法覆盖输入侧关键路径)
# 文件清单与 build_p5.tcl/timing_p5.tcl 逐项一致 (含 P5e-T3 的
# app_udp_pattern.v; 漏一项这里就会报缺模块)。
# 用法: cmd //c 'D:\repo\ECO\udp_hls_10g\sim\p5e_udp\run_route_check.bat'
#=============================================================================
set project_name  p5r3_prj
set top_module    wrapper_p4
set part_name     xc7k325tffg676-2

set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file dirname [file dirname $script_dir]]
set board_dir  ${root_dir}/board
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
import_files -norecurse ${board_dir}/wrapper_p4.v ${board_dir}/util_gmii_to_rgmii.v \
                         ${board_dir}/uart_dbg.v
import_files -norecurse [glob -nocomplain ${hls_dir}/*.v]
set src_dir [file dirname [lindex [glob -nocomplain ${root_dir}/vivado_prj/${project_name}.srcs/sources_1/imports/verilog/udp_echo.v] 0]]
if {$src_dir eq ""} {
    set src_dir [file dirname [lindex [glob -nocomplain ${root_dir}/vivado_prj/${project_name}.srcs/sources_1/imports/*/udp_echo.v] 0]]
}
foreach dat [glob -nocomplain ${hls_dir}/*.dat] { file copy -force $dat $src_dir/ }
add_files -fileset constrs_1 ${board_dir}/eco_rgmii_phy1.xdc
set_property verilog_define APP_MODE=1 [current_fileset]
set_property top $top_module [current_fileset]
update_compile_order -fileset sources_1
set_property strategy Performance_ExtraTimingOpt [get_runs impl_1]
launch_runs synth_1 -jobs 8
wait_on_run synth_1
open_run synth_1 -name synth_1
# ---- app 侧锥覆盖证据 (T1/T2 的缺口: 无消费者 ⇒ 被裁 ⇒ 时序不覆盖输入侧) ----
set n_split [llength [get_cells -hier -quiet -filter {NAME =~ "*u_udp_split*"}]]
set n_utx   [llength [get_cells -hier -quiet -filter {NAME =~ "*u_udp_tx*"}]]
set n_cfg   [llength [get_cells -hier -quiet -filter {NAME =~ "*u_udp_tx_cfg*"}]]
set n_app   [llength [get_cells -hier -quiet -filter {NAME =~ "*u_app_udp*"}]]
set n_uarb  [llength [get_cells -hier -quiet -filter {NAME =~ "*u_tx_udp_arb*"}]]
puts "===== P5e-T3 UDP APP CELLS: u_udp_split=$n_split u_udp_tx=$n_utx u_udp_tx_cfg=$n_cfg u_app_udp=$n_app u_tx_udp_arb=$n_uarb ====="
opt_design
place_design
route_design
report_timing_summary -max_paths 20 -routable_nets -file ${root_dir}/vivado_prj/timing_p5_routed_t3.rpt
puts "\n===== P5e-T3 ROUTED TIMING SUMMARY: ${root_dir}/vivado_prj/timing_p5_routed_t3.rpt ====="
exit
