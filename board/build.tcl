#=============================================================================
# build.tcl — udp_hls_10g 板上工程构建: create_project -force + synth/impl/bitstream
# 用法: 由 run_build.bat 全路径调用 (vivado -mode batch -source board/build.tcl)
# 参照: D:\repo\ECO\udp_hls_eco\run_vivado_phy1g2.tcl (同模式, create_project
#       -force 重建最稳; 部件 xc7k325tffg676-2)
# 产物: vivado_prj/udp_loop_phy1.runs/impl_1/wrapper_1g.bit
#=============================================================================
# util_gmii_to_rgmii 的形态与处理方式 (重要, 已核对):
#   - 它是 k720 demo 的**纯 RTL 模块** (非 Xilinx IP/xci) — 内部只有原语
#     实例: BUFG / IDELAYE2 / IDDR / ODDR (顶层 MMCME2_BASE / BUFG /
#     IDELAYCTRL 在 wrapper_1g.v 内, 同为原语)。
#   - 已核对 udp_hls_eco/vivado_prj/udp_dual_phy1g2.srcs/sources_1/ 下只有
#     imports/*.v (无任何 .xci / .dcp) — 参考工程就是 import_files 直加 RTL。
#   - 因此本脚本**无 IP 生成/升级步骤**: import_files 直接加入
#     board/util_gmii_to_rgmii.v 即可, Vivado 综合时当普通 RTL 处理。
#=============================================================================
set project_name  udp_loop_phy1
set top_module    wrapper_1g
set part_name     xc7k325tffg676-2

# 以本脚本所在目录 (board/) 上溯一层 = 工程根, 不依赖调用时 cwd
set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file dirname $script_dir]

create_project -force $project_name ${root_dir}/vivado_prj -part $part_name
import_files -norecurse [glob ${root_dir}/rtl/*.v]
import_files -norecurse ${script_dir}/wrapper_1g.v ${script_dir}/util_gmii_to_rgmii.v
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
