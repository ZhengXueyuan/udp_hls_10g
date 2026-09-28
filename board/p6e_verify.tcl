#=============================================================================
# p6e_verify.tcl — P6e **只读**复核: 打开已布线的 DCP, 出时序 / CDC / 资源读数
#   为什么要单独一步: 构建脚本只出 3 份报告, 而 P6e 是**本工程第一条真正的跨时钟域路径**
#   (gmii_clk ↔ axi_aclk), 对抗测试 agent 明确留了一条空白 ——
#     "hold_b → dout_a 这条多比特异步采样路径靠握手保证稳定, 工具看不见它;
#      集成时必须读 Vivado 的 CDC 报告确认这条路径怎么报, 若报违例要显式豁免"。
#   ⇒ 本脚本 = 把那条空白补上 (report_cdc + report_clock_interaction)。
#   用法: cmd //c 'D:\...\board\run_p6e_verify.bat'   (只读, 不碰工程)
#=============================================================================
set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file dirname $script_dir]
set dcp   ${root_dir}/vivado_prj/p6e_ku5p_prj.runs/impl_1/wrapper_p4_routed.dcp
set outd  ${script_dir}/p6e_verify
file mkdir $outd

if {![file exists $dcp]} { puts "VERIFY ERROR: 没有已布线 DCP ($dcp) —— 构建还没跑到 route?"; exit 1 }
puts "===== P6e 复核: 打开 $dcp ====="
open_checkpoint $dcp

puts "---- 1. 时序汇总 ----"
report_timing_summary -file ${outd}/p6e_timing_summary.routed.rpt

puts "---- 2. 时钟 ----"
report_clocks -file ${outd}/p6e_clocks.rpt

puts "---- 3. 时钟交互 (哪些域之间有时序路径) ----"
report_clock_interaction -file ${outd}/p6e_clock_interaction.rpt

puts "---- 4. CDC 报告 (跨时钟域路径的分类: 同步器/多比特/未约束) ----"
#   ⚠️ 这是本轮最想看的一份: snap_cdc 的同步器链 (已打 ASYNC_REG) 应被识别为 CDC,
#      而 hold_b→dout_a 这条多比特路径靠握手保证稳定 —— 看工具把它归到哪一类。
if {[catch { report_cdc -details -file ${outd}/p6e_cdc.rpt } e]} {
    puts "report_cdc 失败: $e   (退一步用 report_cdc -file)"
    catch { report_cdc -file ${outd}/p6e_cdc.rpt }
}

puts "---- 5. 资源 ----"
report_utilization -file ${outd}/p6e_utilization.routed.rpt

puts "===== 复核读数写完: $outd ====="
close_project
exit
