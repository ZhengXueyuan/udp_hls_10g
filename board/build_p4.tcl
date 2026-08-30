#=============================================================================
# build_p4.tcl — udp_hls_10g 板上 P4a 工程构建 (TCP fast + HLS 慢路径):
#                create_project -force + synth/impl/bitstream
# 用法: 由 run_build_p4.bat 全路径调用 (vivado -mode batch -source board/build_p4.tcl)
# 产物: vivado_prj/p4_prj.runs/impl_1/wrapper_p4.bit
# 源: wrapper_p4.v + rtl 16 个 .v + util_gmii_to_rgmii.v
#     + udp_hls_eco HLS 慢路径综合产物 (161 个 .v, import + .dat 拷贝,
#       模式照抄 udp_hls_eco/run_vivado_phy1g2.tcl)
#=============================================================================
set project_name  p4_prj
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
                         ${root_dir}/rtl/tcp_echo.v \
                         ${root_dir}/rtl/rx_classify.v \
                         ${root_dir}/rtl/slow_rx_adp.v \
                         ${root_dir}/rtl/slow_cfg_adp.v \
                         ${root_dir}/rtl/slow_tx_adp.v \
                         ${root_dir}/rtl/tx_arb.v
import_files -norecurse ${script_dir}/wrapper_p4.v ${script_dir}/util_gmii_to_rgmii.v
import_files -norecurse [glob -nocomplain ${hls_dir}/*.v]
# HLS $readmemh 系数文件必须拷到导入后的 verilog 同目录 (综合按相对路径找)
set src_dir [file dirname [lindex [glob -nocomplain ${root_dir}/vivado_prj/${project_name}.srcs/sources_1/imports/verilog/udp_echo.v] 0]]
if {$src_dir eq ""} {
    set src_dir [file dirname [lindex [glob -nocomplain ${root_dir}/vivado_prj/${project_name}.srcs/sources_1/imports/*/udp_echo.v] 0]]
}
foreach dat [glob -nocomplain ${hls_dir}/*.dat] { file copy -force $dat $src_dir/ }
add_files -fileset constrs_1 ${script_dir}/eco_rgmii_phy1.xdc
set_property top $top_module [current_fileset]
update_compile_order -fileset sources_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
launch_runs impl_1 -jobs 8
wait_on_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
puts "\n===== BITSTREAM DONE: ${root_dir}/vivado_prj/${project_name}.runs/impl_1/${top_module}.bit ====="
exit
