# pa_query.tcl -- M1 期 A 的**新锥**定向查 (src_sel 2FF + snoop mux + 到 u_mir 的入口)
#   目的 (派单 §③ "DP 域定向锥 + -from/-to 新锥"):
#     ① 期 A 新增的 2 级同步器 (mir_src_sr) 出锥的最差路径 + 它的 slack (是否落进全局失败锥)
#     ② 进 u_mir 的 snoop 数据端 (s_tdata/s_tkeep/s_tvalid/s_tlast) 的最差路径 (mux 组合在其中)
#     ③ 进 u_mir 的控制端 (ctrl_cap_en / ctrl_clr_tgl) —— 与阶段一同结构, 作对照
#   用法: vivado -mode batch -source pa_query.tcl -nojournal -nolog -tclargs <arm>
set arm "m1p2"
if {[llength $argv] >= 1} { set arm [lindex $argv 0] }
set d [file dirname [file normalize [info script]]]
open_project ${d}/prj_${arm}/p7b_m1_synth_${arm}.xpr
open_run synth_1

set sr [get_pins -quiet -hierarchical -filter {NAME =~ *mir_src_sr*}]
set mu [get_pins -quiet -hierarchical -filter {NAME =~ u_mir/s_*}]
set mc [get_pins -quiet -hierarchical -filter {NAME =~ u_mir/ctrl_*}]
puts "M1Q3_SRC_PINS = [llength $sr]"
puts "M1Q3_MIR_S_PINS = [llength $mu]"
puts "M1Q3_MIR_CTRL_PINS = [llength $mc]"
if {[llength $sr] > 0} {
    catch { report_timing -delay_type max -max_paths 20 -from $sr -file ${d}/pa_src_from_${arm}.rpt }
    set ps [get_timing_paths -delay_type max -from $sr -max_paths 1]
    if {[llength $ps] > 0} {
        puts "M1Q3_SRC_WORST_SLACK = [get_property SLACK $ps]"
        puts "M1Q3_SRC_WORST_LVL   = [get_property LOGIC_LEVELS $ps]"
        puts "M1Q3_SRC_WORST_SRC   = [get_property STARTPOINT_PIN $ps]"
        puts "M1Q3_SRC_WORST_DST   = [get_property ENDPOINT_PIN $ps]"
    }
}
if {[llength $mu] > 0} {
    catch { report_timing -delay_type max -max_paths 20 -to $mu -file ${d}/pa_mir_s_to_${arm}.rpt }
    set pm [get_timing_paths -delay_type max -to $mu -max_paths 1]
    if {[llength $pm] > 0} {
        puts "M1Q3_MIR_S_WORST_SLACK = [get_property SLACK $pm]"
        puts "M1Q3_MIR_S_WORST_LVL   = [get_property LOGIC_LEVELS $pm]"
        puts "M1Q3_MIR_S_WORST_SRC   = [get_property STARTPOINT_PIN $pm]"
        puts "M1Q3_MIR_S_WORST_DST   = [get_property ENDPOINT_PIN $pm]"
    }
    catch { report_timing -delay_type max -max_paths 20 -from $mu -file ${d}/pa_mir_s_from_${arm}.rpt }
}
if {[llength $mc] > 0} {
    set pc [get_timing_paths -delay_type max -to $mc -max_paths 1]
    if {[llength $pc] > 0} {
        puts "M1Q3_MIR_CTRL_WORST_SLACK = [get_property SLACK $pc]"
        puts "M1Q3_MIR_CTRL_WORST_DST   = [get_property ENDPOINT_PIN $pc]"
    }
}
puts "M1Q3_DONE"
exit
