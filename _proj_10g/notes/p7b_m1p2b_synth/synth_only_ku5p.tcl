#=============================================================================
# synth_only_ku5p.tcl -- M1 综合检查点 (synth-only, 不出位流, 不碰 vivado_prj/)
#
#   机制: 与 board/build_p7b_ku5p.tcl **同一份文件表 + 同一组 define + 同一组 XDC**,
#         但 ① 项目落在本目录 prj_<arm>/ (**绝不用 vivado_prj/p7b_ku5p_prj** ——
#             `create_project -force` 会清掉现役 0x1E 构建的取证, 全局 #54),
#         ② 只跑 synth_1 (launch_runs synth_1), 不跑 impl / 不写位流。
#
#   arm = pre     : M1 之前的树 (现役 = 构建 0x1E 的源) —— 同流程对照臂
#   arm = m1      : M1 阶段一之后的树
#   arm = m1p2    : M1 期 A (src_sel) 之后的树
#   arm = m1p2b   : ⭐ M1 期 B (C2H 环 + 两从机接线, 2026-10-11) 之后的树
#   同流程合成的差值 = 该刀的 synth 面代价 (utilization / pre-place WNS)。
#   ⚠️ 四个 arm 的**树是同一个工作树的历史态** ⇒ 只有 arm 名区别工程目录;
#      要复算历史 arm 必须 checkout 到那时的源 (本目录只保证 m1p2b 臂可现算)。
#
#   ⚠️ synth 面读数是 **pre-place**, 与后布线读数**不可直接比大小** (只做 A/B 同流程比)。
#   用法: run_synth.bat <arm>   (经 cmd //c 调用; -tclargs 必须放最后)
#=============================================================================
set arm "m1p2b"
if {[llength $argv] >= 1} { set arm [lindex $argv 0] }
set project_name p7b_m1_synth_${arm}
set top_module   wrapper_p4
set part_name    xcku5p-ffvb676-1-e
set gquad        Quad_X0Y1

set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file dirname [file dirname [file dirname $script_dir]]]
set hls_dir    ${root_dir}/hls/slowstack_prj/solution1/syn/verilog
set mac_dir    ${root_dir}/_proj_10g/p7b_mac/rtl
set prj_dir    ${script_dir}/prj_${arm}

proc sec {s} { puts "\nM1SYNTH >>>>>>>>>> $s" }
catch {set_param general.maxThreads 8}

sec "M1SYNTH_ENV"
puts "M1SYNTH_ARM = $arm"
puts "M1SYNTH_ROOT = $root_dir"
puts "M1SYNTH_VIVADO = [version -short]"

sec "M1SYNTH_CREATE $project_name"
create_project -force $project_name $prj_dir -part $part_name
set_property target_language Verilog [current_project]

sec "M1SYNTH_IP_CREATE"
create_ip -name xxv_ethernet -vendor xilinx.com -library ip -version 5.0 -module_name pcs64
set ip [get_ips pcs64]
set DESIRED [list \
    CONFIG.LINE_RATE            {10} \
    CONFIG.CLOCKING             {Asynchronous} \
    CONFIG.BASE_R_KR            {BASE-R} \
    CONFIG.GT_REF_CLK_FREQ      {156.25} \
    CONFIG.GT_TYPE              {GTY} \
    CONFIG.INCLUDE_SHARED_LOGIC {1} \
    CONFIG.GT_GROUP_SELECT      $gquad \
    CONFIG.NUM_OF_CORES         {2} \
    CONFIG.LANE1_GT_LOC         {X0Y4} \
    CONFIG.LANE2_GT_LOC         {X0Y5} \
    CONFIG.CORE                 {Ethernet PCS/PMA 64-bit} ]
set conv -1
for {set rnd 1} {$rnd <= 8} {incr rnd} {
    foreach {k v} $DESIRED { catch {set_property $k $v $ip} e }
    set bad 0
    foreach {k v} $DESIRED {
        set gv "<err>"; catch {set gv [get_property $k $ip]}
        if {[string trim $gv] ne [string trim $v]} { incr bad ; puts "M1SYNTH_RB_MISMATCH $k want=<$v> got=<$gv>" }
    }
    puts "M1SYNTH_ROUND #$rnd MISMATCH_N = $bad"
    if {$bad == 0} { set conv $rnd ; break }
}
puts "M1SYNTH_CONVERGED_AT_ROUND = $conv"
if {$conv < 0} { puts "M1SYNTH_VERDICT = IP_NOT_CONVERGED" ; exit 1 }
generate_target all $ip

sec "M1SYNTH_ADD_DATAPATH"
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
# M1: 载荷镜像模块 (新文件; pre 臂若文件不存在则跳过 —— 由脚本自身判)
set mir_file ${root_dir}/rtl/app_rx_mirror.v
if {[file exists $mir_file]} {
    import_files -norecurse $mir_file
    puts "M1SYNTH_MIR_IMPORTED 1"
} else {
    puts "M1SYNTH_MIR_IMPORTED 0"
}
# ⭐ 期 B (2026-10-11): C2H 环 + 两从机 (wrapper 的三层宏真支引用它们 ⇒ 必须导入)
foreach f [list ${root_dir}/rtl/aximm_c2h_win.v ${root_dir}/rtl/mir_dma_ring.v \
                ${root_dir}/rtl/aximm_h2c_discard.v] {
    if {[file exists $f]} {
        import_files -norecurse $f
        puts "M1SYNTH_PB_IMPORTED [file tail $f] 1"
    } else {
        puts "M1SYNTH_PB_IMPORTED [file tail $f] 0"
    }
}
sec "M1SYNTH_ADD_OBS"
import_files -norecurse ${root_dir}/rtl/snap_cdc.v ${root_dir}/_proj_pcie/rtl/axi_regs.v \
                         ${root_dir}/rtl/clk_gen_p6b.v ${root_dir}/rtl/fifo_async.v \
                         ${root_dir}/rtl/snap_seq.v
sec "M1SYNTH_ADD_MAC"
import_files -norecurse ${mac_dir}/crc32_64.v ${mac_dir}/mac_rx_10g.v ${mac_dir}/mac_tx_10g.v
sec "M1SYNTH_ADD_BOARD"
import_files -norecurse ${root_dir}/board/wrapper_p4.v ${root_dir}/board/util_gmii_to_rgmii_us.v \
                         ${root_dir}/board/util_gmii_to_rgmii.v ${root_dir}/board/uart_dbg.v
import_files -norecurse [glob -nocomplain ${hls_dir}/*.v]
set src_dir [file dirname [lindex [glob -nocomplain ${prj_dir}/${project_name}.srcs/sources_1/imports/verilog/udp_echo.v] 0]]
if {$src_dir eq ""} {
    set src_dir [file dirname [lindex [glob -nocomplain ${prj_dir}/${project_name}.srcs/sources_1/imports/*/udp_echo.v] 0]]
}
foreach dat [glob -nocomplain ${hls_dir}/*.dat] { file copy -force $dat $src_dir/ }

sec "M1SYNTH_ADD_XDMA"
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
# V2-V1.5-⑪: 对 xdma 也打一行 license 键 (M1 构建搭车项的预演)
catch {puts "M1SYNTH_XDMA_LICENSE_KEYS = [get_property USED_LICENSE_KEYS $xip]"}

sec "M1SYNTH_CONSTR"
add_files -fileset constrs_1 ${root_dir}/board/ku5p_p7b_gt.xdc
add_files -fileset constrs_1 ${root_dir}/board/ku5p_p6e_pcie.xdc
add_files -fileset constrs_1 ${root_dir}/board/ku5p_p6b_sysclk.xdc
add_files -fileset constrs_1 ${root_dir}/board/ku5p_p7b_cdc.xdc
set_property used_in_synthesis false [get_files ${root_dir}/board/ku5p_p7b_cdc.xdc]

set_property verilog_define {APP_MODE=1 DEV_USP=1 PCIE_OBS=1 DP_156MHZ=1 P7B_10G=1 UDP_TX_OVL=1 TCP_TX_OVL=1} [current_fileset]
set_property top $top_module [current_fileset]
update_compile_order -fileset sources_1
puts "M1SYNTH_NFILES = [llength [get_files -quiet]]"

sec "M1SYNTH_SYNTH"
reset_run synth_1
catch {launch_runs synth_1 -jobs 8} e
puts "M1SYNTH_LAUNCH = $e"
wait_on_run synth_1
catch {puts "M1SYNTH_STATUS = [get_property STATUS [get_runs synth_1]]"}
if {![string match "100%*" [get_property PROGRESS [get_runs synth_1]]]} {
    puts "M1SYNTH_VERDICT = SYNTH_FAIL"
    exit 1
}

sec "M1SYNTH_REPORTS"
open_run synth_1
report_timing_summary -file ${script_dir}/synth_${arm}_timing_summary.rpt
report_utilization    -file ${script_dir}/synth_${arm}_util.rpt
report_timing -delay_type max -max_paths 200 -file ${script_dir}/synth_${arm}_top200.rpt
set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
puts "M1SYNTH_WNS = $wns"
puts "M1SYNTH_WHS = $whs"
# DP 域定向: MMCM 输出钟 (后布线叫 g_hw.clk_out0) 的 setup 行 + 镜像锥的定向查询
catch { puts "M1SYNTH_CLOCKS = [get_clocks -quiet]" }
set mirpins [get_pins -quiet -hierarchical -filter {NAME =~ *u_mir*}]
puts "M1SYNTH_MIR_PINS = [llength $mirpins]"
if {[llength $mirpins] > 0} {
    catch { report_timing -delay_type max -max_paths 40 -from $mirpins -file ${script_dir}/synth_${arm}_mir_from.rpt }
    catch { report_timing -delay_type max -max_paths 40 -to   $mirpins -file ${script_dir}/synth_${arm}_mir_to.rpt }
}
puts "M1SYNTH_DONE"
exit
