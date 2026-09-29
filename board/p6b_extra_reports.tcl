# P6b 补充读数 (只读): 时钟表 + hold 三族 + 利用率/FIFO 推断确认
set script_dir [file dirname [file normalize [info script]]]
open_project ${script_dir}/../vivado_prj/p6b_ku5p_prj.xpr
open_run impl_1
report_clocks -file ${script_dir}/p6b_ku5p_clocks.rpt
report_timing -delay_type min -max_paths 400 -nworst 1 -file ${script_dir}/p6b_ku5p_hold_400.rpt
report_utilization -file ${script_dir}/p6b_ku5p_util.rpt
exit
