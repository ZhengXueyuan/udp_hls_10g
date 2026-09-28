#=============================================================================
# build_p6a_ku5p.tcl — P6a: **KU5P (xcku5p-ffvb676-1-e)** 上的 1G RGMII 前端 + 64bit 数据面
#   基线构造 = 与 K7 的 build_p6_t6p4.tcl **逐项同构**（同文件清单 / 同 APP_MODE /
#   同 Performance_ExtraTimingOpt + launch_runs 全流程），只换器件、XDC 与前端模块。
# 用法: 由 run_build_p6a_ku5p.bat 调用; 时钟周期用环境变量 P6A_TAG 选
#         t8p0 = 8.000ns (真实 1G)   t6p4 = 6.400ns (闸 G 尖峰, 对照 K7 闸 B)
#       ⚠️ 不用 -tclargs: 本机已验证 Vivado 的 -tclargs 会贪婪吞掉后面的 -log
#          (见工程坑记录), 故走环境变量。
# 产物: vivado_prj/p6a_ku5p_<tag>_prj.runs/impl_1/wrapper_p4.bit
#       + p6a_ku5p_<tag>_timing_summary.rpt / _utilization.rpt / _failing_endpoints.txt
# ⚠️ hls_dir 指向**本目录下的副本**（不是 D:/repo/ECO/...）—— XCKU5PMini/CLAUDE.md
#    明确"以本目录下的副本为准"; K7 的旧 tcl 仍指 ECO 路径, 那是历史。
#=============================================================================
set tag [expr {[info exists ::env(P6A_TAG)] ? $::env(P6A_TAG) : "t8p0"}]
set project_name p6a_ku5p_${tag}_prj
set top_module   wrapper_p4
set part_name    xcku5p-ffvb676-1-e

set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file dirname $script_dir]
set hls_dir    ${root_dir}/hls/slowstack_prj/solution1/syn/verilog

puts "===== P6a KU5P build: tag=${tag} part=${part_name} ====="

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
# 前端: 按 DEV_USP 选 util_gmii_to_rgmii_us (零 IDELAY); 两个文件都导入, wrapper 内 ifdef 选
import_files -norecurse ${script_dir}/wrapper_p4.v ${script_dir}/util_gmii_to_rgmii_us.v \
                         ${script_dir}/util_gmii_to_rgmii.v ${script_dir}/uart_dbg.v
import_files -norecurse [glob -nocomplain ${hls_dir}/*.v]
# HLS $readmemh 系数文件必须拷到导入后的 verilog 同目录 (综合按相对路径找)
set src_dir [file dirname [lindex [glob -nocomplain ${root_dir}/vivado_prj/${project_name}.srcs/sources_1/imports/verilog/udp_echo.v] 0]]
if {$src_dir eq ""} {
    set src_dir [file dirname [lindex [glob -nocomplain ${root_dir}/vivado_prj/${project_name}.srcs/sources_1/imports/*/udp_echo.v] 0]]
}
foreach dat [glob -nocomplain ${hls_dir}/*.dat] { file copy -force $dat $src_dir/ }

add_files -fileset constrs_1 ${script_dir}/ku5p_p6a_${tag}.xdc
set_property verilog_define {APP_MODE=1 DEV_USP=1} [current_fileset]
set_property top $top_module [current_fileset]
update_compile_order -fileset sources_1

launch_runs synth_1 -jobs 8
wait_on_run synth_1
set_property strategy Performance_ExtraTimingOpt [get_runs impl_1]
launch_runs impl_1 -jobs 8
wait_on_run impl_1

# ---- 读数走独立脚本 (与 K7 的 build/verify 分离同构): p6a_ku5p_verify/p6a_verify.tcl ----
#      (读 p6a_ku5p_<tag>_prj.runs/impl_1/wrapper_p4_routed.dcp, 不改工程)

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
puts "\n===== BITSTREAM DONE: ${root_dir}/vivado_prj/${project_name}.runs/impl_1/${top_module}.bit ====="
exit
