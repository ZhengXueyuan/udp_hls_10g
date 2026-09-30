#=============================================================================
# build_p7b_lat_ku5p.tcl -- P7b + **分段延迟探针** (P7B_LATENCY 专项)
#
#   基线 = board/build_p7b_ku5p.tcl **逐项同构** (同 part / 同 IP 参数 /
#          同文件清单 / 同 XDC / 同策略), 增量只有四类:
#     ① `CONFIG.ADD_GT_CNTRL_STS_PORTS 1` —— 让 IP 暴露每通道的 GT DRP 用户口
#        (端口名/位宽来自本目录 scripts/probe_drp_ports.tcl 的**实测**产物)
#     ② 导入 _proj_10g/p7b_lat/rtl/{p7b_lat_top,p7b_lat_drp}.v
#     ③ 创建 `vio_lat` (5 入 6 出) 并把 .ltx 交给主机
#     ④ verilog_define 加 P7B_LAT=1
#
#   工程名 = `p7b_lat_prj`(**独立于 `p7b_ku5p_prj`**) —— 纪律: 构建期间绝不得
#     从被构建的工程烧位流; 独立目录让两者互不干扰。
#
# 产物: vivado_prj/p7b_lat_prj.runs/impl_1/wrapper_p4.bit
#       + vivado_prj/p7b_lat_prj.runs/impl_1/wrapper_p4.ltx   (VIO 探针文件)
#
# ⚠️ 本脚本**不烧板** (没有 program_hw_devices), 也不写 QSPI。
# ⚠️ Vivado batch 出错不一定返回非零 ⇒ 成功判据 = 位流文件存在 (bat 里检查)。
#=============================================================================
set project_name p7b_lat_prj
set top_module   wrapper_p4
set part_name    xcku5p-ffvb676-1-e
set gquad        Quad_X0Y1        ;# quad 225 = channels X0Y4..X0Y7 (SFP A / SFP B)

set script_dir [file dirname [file normalize [info script]]]
set lat_dir    [file dirname $script_dir]
set root_dir   [file dirname [file dirname $lat_dir]]
set hls_dir    ${root_dir}/hls/slowstack_prj/solution1/syn/verilog
set mac_dir    ${root_dir}/_proj_10g/p7b_mac/rtl

proc sec {s} { puts "\nLAT >>>>>>>>>> $s" }
catch {set_param general.maxThreads 8}

sec "LAT_ENV"
puts "LAT_VIVADO = [version -short]"
puts "LAT_ROOT   = $root_dir"
puts "LAT_PART_N = [llength [get_parts $part_name -quiet]]"

sec "LAT_CREATE $project_name"
create_project -force $project_name ${root_dir}/vivado_prj -part $part_name
set_property target_language Verilog [current_project]

# ---- 官方 PCS/PMA 64-bit (闸 1 的 s1_prepare.tcl 逐字 + ADD_GT_CNTRL_STS_PORTS) --
sec "LAT_IP_CREATE"
create_ip -name xxv_ethernet -vendor xilinx.com -library ip -version 5.0 -module_name pcs64
set ip [get_ips pcs64]
puts "LAT_IS_LOCKED_AT_CREATE = [get_property IS_LOCKED $ip]"
set DESIRED [list \
    CONFIG.LINE_RATE                  {10} \
    CONFIG.CLOCKING                   {Asynchronous} \
    CONFIG.BASE_R_KR                  {BASE-R} \
    CONFIG.GT_REF_CLK_FREQ            {156.25} \
    CONFIG.GT_TYPE                    {GTY} \
    CONFIG.INCLUDE_SHARED_LOGIC       {1} \
    CONFIG.GT_GROUP_SELECT            $gquad \
    CONFIG.NUM_OF_CORES               {2} \
    CONFIG.LANE1_GT_LOC               {X0Y4} \
    CONFIG.LANE2_GT_LOC               {X0Y5} \
    CONFIG.CORE                       {Ethernet PCS/PMA 64-bit} ]
# ⚠️ 本轮**没有**开 `CONFIG.ADD_GT_CNTRL_STS_PORTS` (=1 才会暴露 GT DRP 用户口)。
#    实测结论 (2026-09-30, 硬证据见 notes/P7B_LATENCY.md §1.5):
#    置 1 会让**每通道 45 个** GT 控制/状态端口变成必须显式驱动的输入
#    (txprecursor/txdiffctrl/txmaincursor/txpostcursor/txpolarity/rxpolarity/
#     txpmareset/rxpmareset/...)。不驱动就在 `opt_design` **硬失败**:
#       WARNING: [Opt 31-155] Driverless net .../txpmareset_in[0] is driving LUT input pin I1
#       ERROR:   [Opt 31-67] ... GTYE4_CHANNEL_PRIM_INST_i_3  (两次构建都复现)
#    而这些端口在 ADD_GT_CNTRL_STS_PORTS=0 的那版里是核内**参数**驱动的 (不在
#    顶层), 其取值 (TX 均衡/摆幅) 本仓没有权威来源 ⇒ 强行接 0 有改坏 TX 眼图
#    (进而污染本轮主判据) 的风险 ⇒ **本轮放弃 DRP, 保住"IP 配置与已验收的
#    闸 1/闸 2 逐位相同"**。要读 DRP 的正确做法见报告 §1.5。
set conv -1
for {set rnd 1} {$rnd <= 8} {incr rnd} {
    foreach {k v} $DESIRED { catch {set_property $k $v $ip} e }
    set bad 0
    foreach {k v} $DESIRED {
        set gv "<err>"; catch {set gv [get_property $k $ip]}
        if {[string trim $gv] ne [string trim $v]} { incr bad ; puts "LAT_RB_MISMATCH $k want=<$v> got=<$gv>" }
    }
    puts "LAT_ROUND #$rnd MISMATCH_N = $bad"
    if {$bad == 0} { set conv $rnd ; break }
}
puts "LAT_CONVERGED_AT_ROUND = $conv"
if {$conv < 0} { puts "LAT_VERDICT = IP_NOT_CONVERGED" ; exit 1 }
generate_target all $ip
puts "LAT_IS_LOCKED_POSTGEN = [get_property IS_LOCKED $ip]"

# ---- 数据面 (与 P6b/P7b 最终构建同一份清单) ---------------------------------
sec "LAT_ADD_DATAPATH"
import_files -norecurse \
    ${root_dir}/rtl/crc32_8b.v ${root_dir}/rtl/fifo_sync.v ${root_dir}/rtl/checksum16.v \
    ${root_dir}/rtl/frame_fifo.v ${root_dir}/rtl/mac_rx_64.v ${root_dir}/rtl/mac_tx_64.v \
    ${root_dir}/rtl/tcp_cam.v ${root_dir}/rtl/tcb.v ${root_dir}/rtl/tcp_rx.v \
    ${root_dir}/rtl/tcp_tx_frame.v ${root_dir}/rtl/retx_ram.v ${root_dir}/rtl/tcp_echo.v \
    ${root_dir}/rtl/axis_pipe.v ${root_dir}/rtl/rx_classify.v ${root_dir}/rtl/vlan_strip.v \
    ${root_dir}/rtl/slow_rx_adp.v ${root_dir}/rtl/slow_cfg_adp.v ${root_dir}/rtl/slow_tx_adp.v \
    ${root_dir}/rtl/udp_rx.v ${root_dir}/rtl/udp_split.v ${root_dir}/rtl/udp_tx_cfg.v \
    ${root_dir}/rtl/udp_tx_frame.v ${root_dir}/rtl/tx_arb.v ${root_dir}/rtl/app_ctrl.v \
    ${root_dir}/rtl/app_pattern.v ${root_dir}/rtl/app_udp_pattern.v \
    ${root_dir}/rtl/app_status_uart.v
sec "LAT_ADD_OBS"
import_files -norecurse ${root_dir}/rtl/snap_cdc.v ${root_dir}/_proj_pcie/rtl/axi_regs.v \
                         ${root_dir}/rtl/clk_gen_p6b.v ${root_dir}/rtl/fifo_async.v \
                         ${root_dir}/rtl/snap_seq.v
sec "LAT_ADD_MAC"
import_files -norecurse ${mac_dir}/crc32_64.v ${mac_dir}/mac_rx_10g.v ${mac_dir}/mac_tx_10g.v
sec "LAT_ADD_LAT"
import_files -norecurse ${lat_dir}/rtl/p7b_lat_top.v ${lat_dir}/rtl/p7b_lat_drp.v
sec "LAT_ADD_BOARD"
import_files -norecurse ${root_dir}/board/wrapper_p4.v ${root_dir}/board/util_gmii_to_rgmii_us.v \
                         ${root_dir}/board/util_gmii_to_rgmii.v ${root_dir}/board/uart_dbg.v
import_files -norecurse [glob -nocomplain ${hls_dir}/*.v]
# HLS $readmemh 系数文件必须与导入后的 verilog 同目录 (综合按相对路径找)
set src_dir [file dirname [lindex [glob -nocomplain ${root_dir}/vivado_prj/${project_name}.srcs/sources_1/imports/verilog/udp_echo.v] 0]]
if {$src_dir eq ""} {
    set src_dir [file dirname [lindex [glob -nocomplain ${root_dir}/vivado_prj/${project_name}.srcs/sources_1/imports/*/udp_echo.v] 0]]
}
foreach dat [glob -nocomplain ${hls_dir}/*.dat] { file copy -force $dat $src_dir/ }

# ---- XDMA (与 build_p7b_ku5p.tcl 逐字相同) ---------------------------------
sec "LAT_ADD_XDMA"
create_ip -name xdma -vendor xilinx.com -library ip -module_name xdma_0
set xip [get_ips xdma_0]
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
] $xip
generate_target all $xip

# ---- VIO: 探针读出窗口 (打包必须与 p7b_lat_top.v 头注释的位图逐字一致) ----
sec "LAT_ADD_VIO"
create_ip -name vio -vendor xilinx.com -library ip -module_name vio_lat
set_property -dict [list \
    CONFIG.C_NUM_PROBE_IN    {6} \
    CONFIG.C_PROBE_IN0_WIDTH {128} \
    CONFIG.C_PROBE_IN1_WIDTH {128} \
    CONFIG.C_PROBE_IN2_WIDTH {128} \
    CONFIG.C_PROBE_IN3_WIDTH {128} \
    CONFIG.C_PROBE_IN4_WIDTH {128} \
    CONFIG.C_PROBE_IN5_WIDTH {128} \
    CONFIG.C_NUM_PROBE_OUT   {6} \
    CONFIG.C_PROBE_OUT0_WIDTH {1} \
    CONFIG.C_PROBE_OUT1_WIDTH {1} \
    CONFIG.C_PROBE_OUT2_WIDTH {4} \
    CONFIG.C_PROBE_OUT3_WIDTH {8} \
    CONFIG.C_PROBE_OUT4_WIDTH {16} \
    CONFIG.C_PROBE_OUT5_WIDTH {2} \
] [get_ips vio_lat]
generate_target all [get_ips vio_lat]

# ---- 约束 -------------------------------------------------------------------
sec "LAT_CONSTR"
add_files -fileset constrs_1 ${root_dir}/board/ku5p_p7b_gt.xdc
add_files -fileset constrs_1 ${root_dir}/board/ku5p_p6e_pcie.xdc
add_files -fileset constrs_1 ${root_dir}/board/ku5p_p6b_sysclk.xdc
add_files -fileset constrs_1 ${root_dir}/board/ku5p_p7b_cdc.xdc
set_property used_in_synthesis false [get_files ${root_dir}/board/ku5p_p7b_cdc.xdc]

set_property verilog_define {APP_MODE=1 DEV_USP=1 PCIE_OBS=1 DP_156MHZ=1 P7B_10G=1 P7B_LAT=1} [current_fileset]
set_property top $top_module [current_fileset]
update_compile_order -fileset sources_1
puts "LAT_TOP = [get_property top [current_fileset]]"
puts "LAT_NFILES = [llength [get_files -quiet]]"
foreach f [get_files -quiet -of [get_filesets constrs_1]] { puts "LAT_CONSTR_FILE $f" }

sec "LAT_SYNTH"
reset_run synth_1
catch {launch_runs synth_1 -jobs 8} e
puts "LAT_SYNTH_LAUNCH = $e"
wait_on_run synth_1
catch {puts "LAT_SYNTH_STATUS = [get_property STATUS [get_runs synth_1]]"}
if {![string match "100%*" [get_property PROGRESS [get_runs synth_1]]]} {
    puts "LAT_VERDICT = SYNTH_FAIL"
    exit 1
}

sec "LAT_IMPL"
set_property strategy Performance_ExtraTimingOpt [get_runs impl_1]
reset_run impl_1
catch {launch_runs impl_1 -to_step write_bitstream -jobs 8} e2
puts "LAT_IMPL_LAUNCH = $e2"
wait_on_run impl_1
catch {puts "LAT_IMPL_STATUS = [get_property STATUS [get_runs impl_1]]"}

sec "LAT_REPORTS"
open_run impl_1
report_timing_summary -file ${script_dir}/p7b_lat_timing.rpt
report_utilization    -file ${script_dir}/p7b_lat_util.rpt
report_drc            -file ${script_dir}/p7b_lat_drc.rpt
set wns   [get_property SLACK [get_timing_paths -delay_type max]]
set whs   [get_property SLACK [get_timing_paths -delay_type min]]
puts "LAT_WNS = $wns"
puts "LAT_WHS = $whs"
puts "LAT_BIT = ${root_dir}/vivado_prj/${project_name}.runs/impl_1/${top_module}.bit"
puts "LAT_BIT_EXISTS = [file exists ${root_dir}/vivado_prj/${project_name}.runs/impl_1/${top_module}.bit]"
puts "LAT_LTX = ${root_dir}/vivado_prj/${project_name}.runs/impl_1/${top_module}.ltx"
puts "LAT_LTX_EXISTS = [file exists ${root_dir}/vivado_prj/${project_name}.runs/impl_1/${top_module}.ltx]"
puts "LAT DONE"
exit
