# q_0x1D_extra.tcl - 补充: 列 *probe* / *ps_stage* / *ps_rd* 全部 cell (解释 v2 里 ctrl_probe NOCELL)
set dcp [lindex $argv 0]
set out [lindex $argv 1]
open_checkpoint $dcp
foreach pat {*probe* *ps_stage* *ps_rd_d*} {
  set cells [get_cells -hier -quiet -filter "NAME =~ $pat"]
  puts "E pat=$pat ncell=[llength $cells]"
  set k 0
  foreach c $cells {
    incr k
    if {$k <= 25} { puts "E   cell=[get_property NAME $c] ref=[get_property REF_NAME $c]" }
  }
}
set ps [get_cells -hier -quiet -filter {NAME =~ *ps_timer_reg*}]
puts "E ps_timer ncell=[llength $ps]"
set ph [get_cells -hier -quiet -filter {NAME =~ *ps_phase_reg*}]
puts "E ps_phase ncell=[llength $ph]"
puts "N_DONE"
