#=============================================================================
# build_p7b_ku5p.tcl -- P7b: **10G 前端** 与既有 64 位数据面合体 (KU5P)
#
#   基线 = build_p6b_final_ku5p.tcl 的文件清单 + 策略 (PCIE_OBS + DP_156MHZ + APP_MODE),
#   增量 = ① 官方 `xxv_ethernet` PCS/PMA 64-bit (2 通道, X0Y4+X0Y5, 156.25MHz 参考钟)
#          ② 自写 64 位 XGMII MAC (`_proj_10g/p7b_mac/rtl/`)
#          ③ wrapper 的 `ifdef P7B_10G` 分支 (前端整体换掉, 数据面一字未动)
#          ④ 两份新 XDC (引脚 + 四域 set_clock_groups)
#
# 产物: vivado_prj/p7b_ku5p_prj.runs/impl_1/wrapper_p4.bit
#       + p7b_ku5p_{timing,util,drc}.rpt
#
# ⚠️ 纪律 (逐条):
#   ① 默认构建 (无 P7B_10G) 的端口表/逻辑**逐位不变** —— 新增的一切都在 `ifdef P7B_10G` 内。
#   ② **本脚本不烧板** (没有 program_hw_devices), 也不写 QSPI。
#   ③ Vivado batch 出错不一定返回非零 ⇒ 成功判据 = 位流文件存在 (bat 里检查)。
#   ④ 硬门: 日志 grep `12-4739` (约束被静默丢弃) / 隐式网五键 / 扩展键 (见 bat)。
#   ⑤ `p7b_pcs_stub.v` **不导入** (它只给仿真用; P7B_SIM_NOPCS 不定义 ⇒ 不被引用)。
#=============================================================================
set project_name p7b_ku5p_prj
set top_module   wrapper_p4
set part_name    xcku5p-ffvb676-1-e
set gquad        Quad_X0Y1        ;# quad 225 = channels X0Y4..X0Y7 (SFP A / SFP B)

set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file dirname $script_dir]
set hls_dir    ${root_dir}/hls/slowstack_prj/solution1/syn/verilog
set mac_dir    ${root_dir}/_proj_10g/p7b_mac/rtl

proc sec {s} { puts "\nP7B >>>>>>>>>> $s" }
catch {set_param general.maxThreads 8}

sec "P7B_ENV"
puts "P7B_VIVADO = [version -short]"
puts "P7B_PART_N = [llength [get_parts $part_name -quiet]]"

sec "P7B_CREATE $project_name"
create_project -force $project_name ${root_dir}/vivado_prj -part $part_name
set_property target_language Verilog [current_project]

# ---- 官方 PCS/PMA 64-bit (参数逐字照抄闸 1 的 s1_prepare.tcl, 那份已板级验收) -----
#   ⚠️ 设 CONFIG.CORE 会**静默重置**它的从属参数 (闸 1 侦察期实测) ⇒ 用不动点迭代:
#      每轮重设全部参数 + 全量回读比对, 直到零失配。
sec "P7B_IP_CREATE"
create_ip -name xxv_ethernet -vendor xilinx.com -library ip -version 5.0 -module_name pcs64
set ip [get_ips pcs64]
puts "P7B_IS_LOCKED_AT_CREATE = [get_property IS_LOCKED $ip]"
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
        if {[string trim $gv] ne [string trim $v]} { incr bad ; puts "P7B_RB_MISMATCH $k want=<$v> got=<$gv>" }
    }
    puts "P7B_ROUND #$rnd MISMATCH_N = $bad"
    if {$bad == 0} { set conv $rnd ; break }
}
puts "P7B_CONVERGED_AT_ROUND = $conv"
if {$conv < 0} { puts "P7B_VERDICT = IP_NOT_CONVERGED" ; exit 1 }
generate_target all $ip
puts "P7B_IS_LOCKED_POSTGEN = [get_property IS_LOCKED $ip]"
catch {puts "P7B_LOCK_DETAILS = [get_property LOCK_DETAILS $ip]"}
catch {puts "P7B_USED_LICENSE_KEYS = [get_property USED_LICENSE_KEYS $ip]"}
puts "P7B_GT_REF_CLK_FREQ = [get_property CONFIG.GT_REF_CLK_FREQ $ip]"
puts "P7B_LINE_RATE       = [get_property CONFIG.LINE_RATE $ip]"
puts "P7B_CORE            = [get_property CONFIG.CORE $ip]"
puts "P7B_NUM_OF_CORES    = [get_property CONFIG.NUM_OF_CORES $ip]"

# ---- 数据面 (与 P6b 最终构建同一份清单) -------------------------------------
sec "P7B_ADD_DATAPATH"
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
sec "P7B_ADD_OBS"
import_files -norecurse ${root_dir}/rtl/snap_cdc.v ${root_dir}/_proj_pcie/rtl/axi_regs.v \
                         ${root_dir}/rtl/clk_gen_p6b.v ${root_dir}/rtl/fifo_async.v \
                         ${root_dir}/rtl/snap_seq.v \
                         ${root_dir}/rtl/app_rx_mirror.v \
                         ${root_dir}/rtl/aximm_c2h_win.v ${root_dir}/rtl/mir_dma_ring.v \
                         ${root_dir}/rtl/aximm_h2c_discard.v
sec "P7B_ADD_MAC"
import_files -norecurse ${mac_dir}/crc32_64.v ${mac_dir}/mac_rx_10g.v ${mac_dir}/mac_tx_10g.v
sec "P7B_ADD_BOARD"
import_files -norecurse ${script_dir}/wrapper_p4.v ${script_dir}/util_gmii_to_rgmii_us.v \
                         ${script_dir}/util_gmii_to_rgmii.v ${script_dir}/uart_dbg.v
import_files -norecurse [glob -nocomplain ${hls_dir}/*.v]
# HLS $readmemh 系数文件必须与导入后的 verilog 同目录 (综合按相对路径找)
set src_dir [file dirname [lindex [glob -nocomplain ${root_dir}/vivado_prj/${project_name}.srcs/sources_1/imports/verilog/udp_echo.v] 0]]
if {$src_dir eq ""} {
    set src_dir [file dirname [lindex [glob -nocomplain ${root_dir}/vivado_prj/${project_name}.srcs/sources_1/imports/*/udp_echo.v] 0]]
}
foreach dat [glob -nocomplain ${hls_dir}/*.dat] { file copy -force $dat $src_dir/ }

# ---- XDMA (参数逐字复制 build_p6e_ku5p.tcl 那份已实测枚举通过的) --------------
sec "P7B_ADD_XDMA"
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

# ---- 约束 -------------------------------------------------------------------
sec "P7B_CONSTR"
add_files -fileset constrs_1 ${script_dir}/ku5p_p7b_gt.xdc
add_files -fileset constrs_1 ${script_dir}/ku5p_p6e_pcie.xdc
add_files -fileset constrs_1 ${script_dir}/ku5p_p6b_sysclk.xdc
add_files -fileset constrs_1 ${script_dir}/ku5p_p7b_cdc.xdc
set_property used_in_synthesis false [get_files ${script_dir}/ku5p_p7b_cdc.xdc]

# ⚠️ 这一版是为了**线速测量**而打开 `UDP_TX_OVL`（组帧器乒乓重叠）：
#   `rtl/udp_tx_frame.v` 的 body 一分为二，`ifdef UDP_TX_OVL` = 乒乓双 bank 版（343 insertion / 0 deletion），
#   `else` = HEAD 帧器**逐字保留**（默认分支）。关掉这个 define 就回到 HEAD 的帧器行为（帧器 378 拍/帧 → 191 拍/帧）。
#   同时 `P7B_10G` 内的 8 路并行图案发生器（`rtl/app_udp_pattern.v`）一并生效。
#   两者叠加 = 本次线速测量构建；既有四个宏（APP_MODE/DEV_USP/PCIE_OBS/DP_156MHZ）与 `P7B_10G` 一字未动。
#
# ⚠️ 2026-10-07 Stage C 追加 `TCP_TX_OVL`（本刀**唯一的开关**）：
#   `rtl/tcp_tx_frame.v` 的 body 一分为二，`ifdef TCP_TX_OVL` = **乒乓双 bank / 收发重叠**版,
#   `else` = 串行版。⇒ 组帧器从"串行"换成"乒乓", TCP app TX 与 RX 并行。
#   ⛔ **宏关 ≠ HEAD**：F1 的 8 行修复（`retx_ovf` + `ring_start` 追加 `!retx_ovf`）落在
#      **默认分支**里, 逐行 diff = 恰那 8 行（`_proj_10g/notes/P7B_STAGEC_TX_REGRESSION.md` §环境事实 2）
#      ⇒ "关掉宏就回到 HEAD 的逐字行为"这句**对 `tcp_tx_frame.v` 已作废**。
#   `TIMING`/面积读数由本次构建收口（设计件 §5-2 的估计 = 无实测背书）。
set_property verilog_define {APP_MODE=1 DEV_USP=1 PCIE_OBS=1 DP_156MHZ=1 P7B_10G=1 UDP_TX_OVL=1 TCP_TX_OVL=1} [current_fileset]
puts "P7B_VERILOG_DEFINE = [get_property verilog_define [current_fileset]]"
set_property top $top_module [current_fileset]
update_compile_order -fileset sources_1
puts "P7B_TOP = [get_property top [current_fileset]]"
puts "P7B_NFILES = [llength [get_files -quiet]]"
foreach f [get_files -quiet -of [get_filesets constrs_1]] { puts "P7B_CONSTR_FILE $f" }

sec "P7B_SYNTH"
reset_run synth_1
catch {launch_runs synth_1 -jobs 8} e
puts "P7B_SYNTH_LAUNCH = $e"
wait_on_run synth_1
catch {puts "P7B_SYNTH_STATUS = [get_property STATUS [get_runs synth_1]]"}
if {![string match "100%*" [get_property PROGRESS [get_runs synth_1]]]} {
    puts "P7B_VERDICT = SYNTH_FAIL"
    exit 1
}

sec "P7B_IMPL"
set_property strategy Performance_ExtraTimingOpt [get_runs impl_1]
reset_run impl_1
catch {launch_runs impl_1 -to_step write_bitstream -jobs 8} e2
puts "P7B_IMPL_LAUNCH = $e2"
wait_on_run impl_1
catch {puts "P7B_IMPL_STATUS = [get_property STATUS [get_runs impl_1]]"}

sec "P7B_REPORTS"
open_run impl_1
report_timing_summary -file ${script_dir}/p7b_ku5p_timing.rpt
report_utilization    -file ${script_dir}/p7b_ku5p_util.rpt
report_drc            -file ${script_dir}/p7b_ku5p_drc.rpt
report_clock_interaction -file ${script_dir}/p7b_ku5p_clkinteract.rpt
# 关键读数显式打印 (bat 里 grep) —— 不让"报告存在"冒充"读数已看"
set wns   [get_property SLACK [get_timing_paths -delay_type max]]
set whs   [get_property SLACK [get_timing_paths -delay_type min]]
puts "P7B_WNS = $wns"
puts "P7B_WHS = $whs"
puts "P7B_WPWS = [get_property SLACK [get_timing_paths -delay_type min_max -max_paths 1 -sort_by group]]"
puts "P7B_BIT = ${root_dir}/vivado_prj/${project_name}.runs/impl_1/${top_module}.bit"
puts "P7B_BIT_EXISTS = [file exists ${root_dir}/vivado_prj/${project_name}.runs/impl_1/${top_module}.bit]"
puts "P7B DONE"
exit
