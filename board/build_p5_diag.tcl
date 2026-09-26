#=============================================================================
# build_p5_diag.tcl — RXP_DIAG 诊断构建 (ISSUE_RX_BYTE_CORRUPTION 专题)
#
# 目的: 在不改变任何功能语义的前提下, 把 app UDP RX 通路的**首失配快照**做成
#       板级可读字段 (UART 状态行行尾追加 8 字段), 用来把"坏字节到底长什么样"
#       从推测变成实测。
#
# 与 build_p5.tcl 的差异 (逐项):
#   ① project_name p5_prj -> p5diag_prj  (**独立工程**, 不覆盖 P5 位流/报告)
#   ② verilog_define 追加 RXP_DIAG=1  (+ APP_MODE=1, 诊断只在 APP_MODE 下有意义)
#   ③ 追加 board/eco_holdfix.xdc —— **刻意与当前 impl_1 位流同约束**:
#      现 impl_1 的 wrapper_p4.bit 是 HOLDFIX 版 (§4.2 实验位流)。诊断位流与它
#      只差 RXP_DIAG 一项 ⇒ 板级错误率可直接对比, 隔离"仪器本身是否扰动被测现象"。
#   ④ 报告写到 p5diag_verify/ (不污染 p5f_verify/)
#
# 回归保护: RXP_DIAG 未定义时, app_udp_pattern / app_status_uart / wrapper_p4
#   的端口与逻辑**逐字不变** (app_udp_pattern 的新端口恒 0, app_status_uart 与
#   wrapper 的新端口整体包在 `ifdef 内) ⇒ 默认构建 (build_p4) 与 P5 构建
#   (build_p5) 不受影响。
#=============================================================================
set project_name  p5diag_prj
set top_module    wrapper_p4
set part_name     xc7k325tffg676-2

set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file dirname $script_dir]
set out_dir    ${root_dir}/p5diag_verify
set hls_dir    D:/repo/ECO/udp_hls_10g/hls/slowstack_prj/solution1/syn/verilog

file mkdir $out_dir

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
import_files -norecurse ${script_dir}/wrapper_p4.v ${script_dir}/util_gmii_to_rgmii.v \
                         ${script_dir}/uart_dbg.v
import_files -norecurse [glob -nocomplain ${hls_dir}/*.v]
set src_dir [file dirname [lindex [glob -nocomplain ${root_dir}/vivado_prj/${project_name}.srcs/sources_1/imports/verilog/udp_echo.v] 0]]
if {$src_dir eq ""} {
    set src_dir [file dirname [lindex [glob -nocomplain ${root_dir}/vivado_prj/${project_name}.srcs/sources_1/imports/*/udp_echo.v] 0]]
}
foreach dat [glob -nocomplain ${hls_dir}/*.dat] { file copy -force $dat $src_dir/ }
add_files -fileset constrs_1 ${script_dir}/eco_rgmii_phy1.xdc
add_files -fileset constrs_1 ${script_dir}/eco_holdfix.xdc
set_property verilog_define {APP_MODE=1 RXP_DIAG=1} [current_fileset]
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
report_timing_summary -max_paths 5 -file ${out_dir}/diag_timing.rpt
report_drc -file ${out_dir}/diag_drc_routed.rpt
puts "\n===== DIAG BITSTREAM DONE: ${root_dir}/vivado_prj/${project_name}.runs/impl_1/${top_module}.bit ====="
exit
