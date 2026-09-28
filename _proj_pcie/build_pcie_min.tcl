#=============================================================================
# build_pcie_min.tcl — P6e 最小版: 我们自己的 XDMA 观测通道 (无数据面)
#   产物: vivado_prj/pcie_min_prj.runs/impl_1/pcie_min_top.bit
#         + _proj_pcie/pcie_min_{timing,drc,util}.rpt
#   XDMA 配置 = **厂商那份在板上实测跑通的值的复制**, 唯一改动 = 打开 AXI-Lite master
#   (axilite_master_en) ⇒ 引出 user BAR ⇒ 主机侧 /dev/xdma0_user 可读写我们的寄存器。
#   ⚠️ 纪律 (KU5P 特有): create_ip 的参数**必须从持久化 .xci 核对** —— 该校验在
#      run_build_pcie_min.bat 里用 check_xci.py 做 (Tcl 的 regexp 花括号不好写)。
#   ⚠️ Vivado batch 出错时**不一定返回非零** ⇒ 成功判据 = 位流文件存在 (bat 里检查)。
#=============================================================================
set project_name pcie_min_prj
set top_module   pcie_min_top
set part_name    xcku5p-ffvb676-1-e
set script_dir [file dirname [file normalize [info script]]]
set root_dir   $script_dir

create_project -force $project_name ${root_dir}/vivado_prj -part $part_name
import_files -norecurse ${root_dir}/rtl/axi_regs.v ${root_dir}/rtl/pcie_min_top.v

puts "==== 生成 XDMA IP ===="
create_ip -name xdma -vendor xilinx.com -library ip -module_name xdma_0
set ip [get_ips xdma_0]
puts "XDMA IP = $ip"
set_property -dict [list \
    CONFIG.pcie_blk_locn              {X0Y0} \
    CONFIG.pf0_device_id              {9034} \
    CONFIG.pf0_subsystem_id           {0007} \
    CONFIG.ref_clk_freq               {100_MHz} \
    CONFIG.mode_selection             {Basic} \
    CONFIG.axi_data_width             {128_bit} \
    CONFIG.num_queues                 {1} \
    CONFIG.axilite_master_en          {true} \
    CONFIG.axilite_master_scale       {Megabytes} \
    CONFIG.axilite_master_size        {1} \
    CONFIG.pl_link_cap_max_link_speed {8.0_GT/s} \
    CONFIG.pl_link_cap_max_link_width {X4} \
] $ip
generate_target all $ip

add_files -fileset constrs_1 ${root_dir}/ku5p_pcie_min.xdc
set_property top $top_module [current_fileset]
update_compile_order -fileset sources_1

launch_runs synth_1 -jobs 8
wait_on_run synth_1
set_property strategy Performance_ExtraTimingOpt [get_runs impl_1]
launch_runs impl_1 -jobs 8
wait_on_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

open_run impl_1
report_timing_summary -file ${root_dir}/pcie_min_timing.rpt
report_drc            -file ${root_dir}/pcie_min_drc.rpt
report_utilization    -file ${root_dir}/pcie_min_util.rpt
puts "===== BUILD SCRIPT DONE (成功判据另见 bat 的位流检查) ====="
exit
