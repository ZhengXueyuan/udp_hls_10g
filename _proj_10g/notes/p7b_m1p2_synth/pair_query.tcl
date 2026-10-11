# pair_query.tcl -- 两臂查**同一对 pin** (rx_state_reg[0]/C -> u_app/stg_reg[0]/CE)
#   目的: 判"同一对端点"的映射级数/延迟在两臂是否不同 (即位移在综合映射层, 还是 M1 逻辑串进了该锥)
set arm "m1"
if {[llength $argv] >= 1} { set arm [lindex $argv 0] }
set d [file dirname [file normalize [info script]]]
open_project ${d}/prj_${arm}/p7b_m1_synth_${arm}.xpr
open_run synth_1
set fs [get_pins -quiet u_tcp_tx/FSM_sequential_rx_state_reg[0]/C]
set fd [get_pins -quiet u_app/stg_reg[0]/CE]
puts "M1Q2_PINS fs=[llength $fs] fd=[llength $fd]"
if {[llength $fs] > 0 && [llength $fd] > 0} {
    report_timing -delay_type max -from $fs -to $fd -max_paths 1 -file ${d}/pair_${arm}.rpt
    set p [get_timing_paths -delay_type max -from $fs -to $fd -max_paths 1]
    puts "M1Q2_SLACK_${arm} = [get_property SLACK $p]"
    puts "M1Q2_LOGICLVL_${arm} = [get_property LOGIC_LEVELS $p]"
    puts "M1Q2_DATADELAY_${arm} = [get_property DATAPATH_DELAY $p]"
}
puts "M1Q2_DONE"
exit
