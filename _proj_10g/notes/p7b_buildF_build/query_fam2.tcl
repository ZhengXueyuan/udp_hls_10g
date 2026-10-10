# query_fam2.tcl - one extra directed query on the F routed dcp:
# worst path FROM the E-档 WNS source family (u_tcp_tx/FSM_sequential_rx_state_reg[*]).
# usage: vivado -mode batch -nojournal -nolog -source query_fam2.tcl -tclargs <dcp> <tag> <outdir>
set dcp [lindex $argv 0]
set tag [lindex $argv 1]
set out [lindex $argv 2]
open_checkpoint $dcp
set cells [get_cells -hier -quiet -filter {NAME =~ *FSM_sequential_rx_state_reg*}]
puts "FAM2 $tag $dcp rx_state_family_cells=[llength $cells]"
set p [get_timing_paths -from $cells -max_paths 1 -delay_type max]
if {[llength $p]} {
  puts "FAM2 $tag rx_state_family slack=[get_property SLACK $p] lvl=[get_property LOGIC_LEVELS $p] src=[get_property STARTPOINT_PIN $p] dst=[get_property ENDPOINT_PIN $p]"
} else { puts "FAM2 $tag rx_state_family NOPATH" }
report_timing -from $cells -max_paths 8 -delay_type max -file $out/${tag}_rxstate_family.rpt
# the global-WNS family (pcie async recovery, snapshot CLR pins)
set clr [get_pins -quiet -of [get_cells -hier -quiet -filter {NAME =~ *snap_words_r_reg*}] -filter {REF_PIN_NAME =~ CLR}]
puts "FAM2 $tag snap_words_clr_pins=[llength $clr]"
set q [get_timing_paths -to $clr -max_paths 1 -delay_type max]
if {[llength $q]} {
  puts "FAM2 $tag snap_clr slack=[get_property SLACK $q] lvl=[get_property LOGIC_LEVELS $q] src=[get_property STARTPOINT_PIN $q] dst=[get_property ENDPOINT_PIN $q]"
} else { puts "FAM2 $tag snap_clr NOPATH" }
report_timing -to $clr -max_paths 8 -delay_type max -file $out/${tag}_snap_clr.rpt
puts "FAM2_DONE $tag"
