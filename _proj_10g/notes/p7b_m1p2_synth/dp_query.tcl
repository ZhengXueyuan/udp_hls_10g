# dp_query.tcl -- M1 综合检查点的**定向查**: DP 域 (g_hw.clk_out0) 最差路径到底是谁
#   用法: vivado -mode batch -source dp_query.tcl -nojournal -nolog
set arm "m1"
if {[llength $argv] >= 1} { set arm [lindex $argv 0] }
set d [file dirname [file normalize [info script]]]
open_project ${d}/prj_${arm}/p7b_m1_synth_${arm}.xpr
open_run synth_1
puts "M1Q_CLOCKS = [get_clocks -quiet]"
# DP 域内最差 20 条 (setup)
report_timing -delay_type max -from [get_clocks -quiet g_hw.clk_out0] -to [get_clocks -quiet g_hw.clk_out0] \
              -max_paths 20 -file ${d}/dp_worst_${arm}.rpt
# 镜像锥: 进/出 u_mir 的最差路径
set mp [get_pins -quiet -hierarchical -filter {NAME =~ *u_mir*}]
puts "M1Q_MIR_PINS = [llength $mp]"
if {[llength $mp] > 0} {
    catch { report_timing -delay_type max -max_paths 20 -from $mp -file ${d}/dp_mir_from_${arm}.rpt }
    catch { report_timing -delay_type max -max_paths 20 -to   $mp -file ${d}/dp_mir_to_${arm}.rpt }
}
# 快照束 (p7bdp) 的 din 锥 (新增 W70 项落在这里)
catch { report_timing -delay_type max -max_paths 20 -to [get_pins -quiet -hierarchical -filter {NAME =~ *u_snap_p7bdp/hold_b_reg*}] -file ${d}/dp_snapbdp_${arm}.rpt }
puts "M1Q_DONE"
exit
