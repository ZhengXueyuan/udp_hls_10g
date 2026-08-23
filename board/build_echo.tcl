#=============================================================================
# build_echo.tcl — udp_hls_10g 板上 UDP echo 工程构建:
#                  create_project -force + synth/impl/bitstream
# 用法: 由 run_build_echo.bat 全路径调用 (vivado -mode batch -source board/build_echo.tcl)
# 参照: board/build.tcl (同模式, create_project -force 重建最稳; 部件 xc7k325tffg676-2)
# 产物: vivado_prj/udp_echo_prj.runs/impl_1/wrapper_echo.bit
#=============================================================================
# 与 build.tcl 的差异: 仅数据面换为 wrapper_echo.v (mac_rx_64→udp_rx→udp_echo→
# udp_tx_frame→mac_tx_64), 源文件集 = wrapper_echo.v + rtl 全部 9 个 .v +
# util_gmii_to_rgmii.v (纯 RTL, 无任何 xci/dcp IP — 与 build.tcl 相同的处理方式,
# import_files 直加即可)。
#=============================================================================
set project_name  udp_echo_prj
set top_module    wrapper_echo
set part_name     xc7k325tffg676-2

# 以本脚本所在目录 (board/) 上溯一层 = 工程根, 不依赖调用时 cwd
set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file dirname $script_dir]

create_project -force $project_name ${root_dir}/vivado_prj -part $part_name
import_files -norecurse ${root_dir}/rtl/crc32_8b.v \
                         ${root_dir}/rtl/fifo_sync.v \
                         ${root_dir}/rtl/checksum16.v \
                         ${root_dir}/rtl/frame_fifo.v \
                         ${root_dir}/rtl/mac_rx_64.v \
                         ${root_dir}/rtl/mac_tx_64.v \
                         ${root_dir}/rtl/udp_rx.v \
                         ${root_dir}/rtl/udp_echo.v \
                         ${root_dir}/rtl/udp_tx_frame.v
import_files -norecurse ${script_dir}/wrapper_echo.v ${script_dir}/util_gmii_to_rgmii.v
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
