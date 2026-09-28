# probe_xdma.tcl -- 在 2025.2 下生成一份 XDMA IP, 读出 (a) 持久化参数 (b) 端口表 (c) 版本
#   目的: 为 P6e 最小版确定可用的 create_ip 参数名与端口, 不碰任何既有工程。
#   用法: cmd //c run_probe_xdma.bat    (产物 _proj_pcie/probe/)
set root [file dirname [file normalize [info script]]]
set part xcku5p-ffvb676-1-e
create_project -force xdma_probe ${root}/probe -part $part

puts "==== XDMA IP 目录 ===="
foreach d [get_ipdefs -filter {NAME == xdma}] { puts "  $d" }
foreach d [get_ipdefs -filter {NAME =~ xdma*}] { puts "  (like) $d" }

create_ip -name xdma -vendor xilinx.com -library ip -module_name xdma_probe
set ip [get_ips xdma_probe]
puts "==== IP: $ip  version=[get_property -quiet IPDEF $ip] ===="

# 厂商实测配置 (那份在这块板上跑通过的) + 我们要改的一处: 打开 AXI-Lite master (user BAR)
set_property -dict [list \
    CONFIG.pcie_blk_locn        {X0Y0} \
    CONFIG.pf0_device_id        {9034} \
    CONFIG.pf0_subsystem_id     {0007} \
    CONFIG.ref_clk_freq         {100_MHz} \
    CONFIG.mode_selection       {Basic} \
    CONFIG.axi_data_width       {128_bit} \
    CONFIG.num_queues           {1} \
    CONFIG.axilite_master_en    {true} \
    CONFIG.axilite_master_scale {Megabytes} \
    CONFIG.axilite_master_size  {1} \
    CONFIG.pl_link_cap_max_link_speed {8.0_GT/s} \
    CONFIG.pl_link_cap_max_link_width {X4} \
] $ip
puts "==== 设置完成, 生成 (generate_target all) ===="
generate_target all $ip
puts "==== 生成完成 ===="
