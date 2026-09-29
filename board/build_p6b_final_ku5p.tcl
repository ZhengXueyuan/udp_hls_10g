#=============================================================================
# build_p6b_ku5p.tcl — P6b: **数据面 125MHz → 156.25MHz** (KU5P, xcku5p-ffvb676-1-e)
#   基线 = build_p6e_ku5p.tcl (同器件 / 同宏 / 同策略 / 同文件清单),
#   增量 = `rtl/clk_gen_p6b.v` + `rtl/fifo_async.v` + `rtl/snap_seq.v`
#          + `board/ku5p_p6b_sysclk.xdc` (Y1 100MHz 输入) + `board/ku5p_p6b_cdc.xdc` (impl-only)。
#   产物 = **一个比特流里同时有**: 前端 125MHz (RGMII + mac_rx_64/mac_tx_64) /
#          数据面 156.25MHz (vlan_strip 及其后全部, 含 HLS) / PCIe 寄存器窗口。
#   产物: vivado_prj/p6b_ku5p_prj.runs/impl_1/wrapper_p4.bit
#         + p6b_ku5p_{timing,util,drc}.rpt
# ⚠️ 纪律:
#   ① **默认构建 (K7 各档 / P6a) 的端口表/逻辑逐位不变** —— wrapper 里的双域与所有新硬件
#      都包在 `ifdef PCIE_OBS 内 (新端口 sys_clk_p/n 也在里面); 各 rtl 模块里 §5.1 的
#      频率常数用 `ifdef PCIE_OBS 选值, 默认仍是 125MHz 域的值。
#   ② XDMA IP 参数必须与 `_proj_pcie/build_pcie_min.tcl` **逐字一致** (那份已在板上实测
#      枚举成功 + user BAR 可用); 校验脚本 _proj_pcie/check_xci.py 可核 .xci 持久化。
#   ③ hls_dir 指向**本目录下的副本** (不是 D:/repo/ECO/...)。
#   ④ Vivado batch 出错**不一定**返回非零 ⇒ 成功判据 = 位流文件存在 (bat 里检查)。
#   ⑤ ⭐ 上板前**必须**跑 `python board/check_p6b_timing.py board/p6b_ku5p_timing.rpt
#      --expect dual` 且退出码 0 (双域报告 + 0 失败端点 + 闸 G 那 16 条 HDIO Min-Period
#      违例必须消失)。判据与正/负对照入库 board/p6b_verify/。
#   ⑥ 构建日志里必须 **无** `Vivado 12-4739` (set_clock_groups 真生效)。
#=============================================================================
set project_name p6b_final_ku5p_prj
set top_module   wrapper_p4
set part_name    xcku5p-ffvb676-1-e

set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file dirname $script_dir]
set hls_dir    ${root_dir}/hls/slowstack_prj/solution1/syn/verilog

puts "===== P6b KU5P build: 数据面 156.25MHz 双域 + PCIe 观测通道 ====="

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
# P6e 新增: 观测通道 (相干快照 CDC) + 寄存器块
import_files -norecurse ${root_dir}/rtl/snap_cdc.v ${root_dir}/_proj_pcie/rtl/axi_regs.v
# ★ P6b 新增: 数据面时钟发生器 + 两条异步 FIFO + 链式快照序列器
import_files -norecurse ${root_dir}/rtl/clk_gen_p6b.v \
                         ${root_dir}/rtl/fifo_async.v \
                         ${root_dir}/rtl/snap_seq.v
# 前端: 按 DEV_USP 选 util_gmii_to_rgmii_us (零 IDELAY); 两个文件都导入, wrapper 内 ifdef 选
import_files -norecurse ${script_dir}/wrapper_p4.v ${script_dir}/util_gmii_to_rgmii_us.v \
                         ${script_dir}/util_gmii_to_rgmii.v ${script_dir}/uart_dbg.v
import_files -norecurse [glob -nocomplain ${hls_dir}/*.v]
# HLS $readmemh 系数文件必须拷到导入后的 verilog 同目录 (综合按相对路径找)
set src_dir [file dirname [lindex [glob -nocomplain ${root_dir}/vivado_prj/${project_name}.srcs/sources_1/imports/verilog/udp_echo.v] 0]]
if {$src_dir eq ""} {
    set src_dir [file dirname [lindex [glob -nocomplain ${root_dir}/vivado_prj/${project_name}.srcs/sources_1/imports/*/udp_echo.v] 0]]
}
foreach dat [glob -nocomplain ${hls_dir}/*.dat] { file copy -force $dat $src_dir/ }

# ---- XDMA IP: 参数逐字复制 _proj_pcie/build_pcie_min.tcl (板上实测枚举通过) ----
#      ⚠️ 会在工程里生成 IP 产物 (跑一次 ~1-2 min); 之后综合用持久化的 .xci
create_ip -name xdma -vendor xilinx.com -library ip -module_name xdma_0
set ip [get_ips xdma_0]
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

# ---- 约束: P6a 基线 (原样复用) + PCIe 增量 + P6b 新时钟 (分开文件, 避免分叉) ----
add_files -fileset constrs_1 ${script_dir}/ku5p_p6a_t8p0.xdc
add_files -fileset constrs_1 ${script_dir}/ku5p_p6e_pcie.xdc
add_files -fileset constrs_1 ${script_dir}/ku5p_p6b_sysclk.xdc
# 跨时钟域约束单独一个文件, **且只在实现阶段应用**: 综合前解析时 create_clock 还没生效
# (XDMA / MMCM 也还是黑盒) ⇒ 里面的 get_clocks 拿到空对象 ⇒ Vivado 会报
# `CRITICAL WARNING [Vivado 12-4739]` 并**静默丢弃** (P6e BUILD_ID=2 那版实测踩过)。
add_files -fileset constrs_1 ${script_dir}/ku5p_p6e_cdc.xdc
set_property used_in_synthesis false [get_files ${script_dir}/ku5p_p6e_cdc.xdc]
add_files -fileset constrs_1 ${script_dir}/ku5p_p6b_cdc.xdc
set_property used_in_synthesis false [get_files ${script_dir}/ku5p_p6b_cdc.xdc]

set_property verilog_define {APP_MODE=1 DEV_USP=1 PCIE_OBS=1 DP_156MHZ=1} [current_fileset]
# ⚠️ `DP_156MHZ` = 「数据面跑在 156.25MHz 独立域」—— 它守卫**时钟拓扑 / 两个异步 FIFO /
#    wrapper 的 LED-UART 时间常数 / 6 个 rtl 模块的 8 个时间常数**。与 `PCIE_OBS`
#    (「例化 PCIe 观测通道」) **语义无关**, 必须分别给 (对抗审查 F1: 绑成一个宏的后果是
#    有人"要 PCIe 窗口但数据面仍 125MHz"时会静默拿到 8 个错常数)。
set_property top $top_module [current_fileset]
update_compile_order -fileset sources_1

launch_runs synth_1 -jobs 8
wait_on_run synth_1
set_property strategy Performance_ExtraTimingOpt [get_runs impl_1]
launch_runs impl_1 -jobs 8
wait_on_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

# ---- 读数 (只读; 判定在 bat 里做) ----
open_run impl_1
report_timing_summary -file ${script_dir}/p6b_final_ku5p_timing.rpt
report_utilization    -file ${script_dir}/p6b_final_ku5p_util.rpt
report_drc            -file ${script_dir}/p6b_final_ku5p_drc.rpt
# 时钟网络: 核 MMCM 是否为**自动推导**出 6.400ns (P6B_SPEC §8.3: 手写 create_generated_clock
# 反而会冲突)。失败端点清单单独落盘, 便于与闸 G 的 16 条逐条对照。
report_clocks -file ${script_dir}/p6b_final_ku5p_clocks.rpt
set fep [open ${script_dir}/p6b_final_ku5p_failing_endpoints.txt w]
foreach path [get_timing_paths -delay_type max -max_paths 400 -nworst 1] {
    if {[get_property SLACK $path] < 0} { puts $fep $path }
}
close $fep

# =============================================================================
# ★ 本次(最终重建)新增的三项**从未做过**的工具侧读数 —— 全部在 **routed design** 上做
#   (a) report_cdc     : 覆盖功能仿真测不到的亚稳态风险; 清单逐条对 P6B_SPEC §3
#   (b) ASYNC_REG 普查 : 布局/布线后 ASYNC_REG==TRUE 的 cell 是否真贴在同步器链上
#   (c) hold 三族专核  : report_timing -delay_type min -max_paths 400 (闸 G 同款口径)
# =============================================================================
report_timing -delay_type min -max_paths 400 -nworst 1 -file ${script_dir}/p6b_final_ku5p_hold_400.rpt

# ---- (a) report_cdc ----
#   ⚠️ report_cdc 不写 -file 时会把结果塞进 stdout; 用 -file 落盘 + 同时 puts 一份到 log。
#   `-details` 给出每条穿越的源/目的 cell 与同步方式 (判"真穿越 vs 工具误报"必需)。
report_cdc -details -file ${script_dir}/p6b_final_ku5p_cdc.rpt

# ---- (b) ASYNC_REG 普查 (routed) ----
set fp [open ${script_dir}/p6b_final_ku5p_async_reg.txt w]
set ar_cells [get_cells -hier -filter {ASYNC_REG == TRUE}]
puts $fp "# ASYNC_REG==TRUE cells in ROUTED design: [llength $ar_cells]"
puts $fp "# (design state: [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]] WNS probe)"
foreach c $ar_cells { puts $fp "CELL\t$c" }
# 这些 cell 各自的上游驱动 (证明它们真在同步链上, 且源在另一个域)
puts $fp "# ---- per-cell REF_NAME / 时钟 ----"
foreach c $ar_cells {
    puts $fp "REF\t$c\t[get_property REF_NAME [get_cells $c]]\t[get_property CLK [get_cells $c]]"
}
close $fp
puts "ASYNC_REG cell count = [llength $ar_cells]"

# ---- (c) LUTRAM 明细 (FWFT FIFO 是否真落 LUTRAM) ----
set fl [open ${script_dir}/p6b_final_ku5p_lutram.txt w]
puts $fl "# ---- RAMB/RAM32 等原语实例普查 (routed) ----"
foreach t {RAM32X1S RAM32X1D RAM32M RAM64X1S RAM64X1D RAM64M RAM128X1D RAM256X1S RAMB18E2 RAMB36E2 URAM288} {
    puts $fl "$t\t[llength [get_cells -hier -filter "REF_NAME == $t"]]"
}
close $fl
exit
