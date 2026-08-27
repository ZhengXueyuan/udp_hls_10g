#=============================================================================
# build_tcp.tcl — udp_hls_10g 板上 TCP echo 工程构建:
#                 create_project -force + synth/impl/bitstream
# 用法: 由 run_build_tcp.bat 全路径调用 (vivado -mode batch -source board/build_tcp.tcl)
# 参照: board/build_echo.tcl (同模式, create_project -force 重建最稳)
# 产物: vivado_prj/tcp_echo_prj.runs/impl_1/wrapper_tcp.bit
# 数据面: wrapper_tcp.v (mac_rx_64→tcp_rx→tcp_echo→tcp_tx_frame→mac_tx_64
#          + tcp_cam/tcb/tcp_synp), 源 = wrapper_tcp.v + rtl 12 个 .v +
#         util_gmii_to_rgmii.v (纯 RTL, 无 xci/dcp IP)
#=============================================================================
set project_name  tcp_echo_prj
set top_module    wrapper_tcp
set part_name     xc7k325tffg676-2

set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file dirname $script_dir]

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
                         ${root_dir}/rtl/tcp_synp.v
import_files -norecurse ${script_dir}/wrapper_tcp.v ${script_dir}/util_gmii_to_rgmii.v
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
