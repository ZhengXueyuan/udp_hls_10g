# q_0x1C.tcl v3 - resolve the 3 ring_restore* nets (driver / loads) + DP top-50 breadth.
set dcp [lindex $argv 0]
set out [lindex $argv 1]
file mkdir $out
open_checkpoint $dcp

set n1 [get_nets -hier -quiet -filter {NAME =~ *ring_restore1}]
set n2 [get_nets -hier -quiet -filter {NAME =~ *ring_restore2}]
set n3 [get_nets -hier -quiet -filter {NAME =~ *ring_restore11*}]
set tag n1
foreach nl [list $n1 $n2 $n3] {
  foreach n $nl {
    set full [get_property NAME $n]
    set drv [get_pins -quiet -of $n -filter {DIRECTION == OUT}]
    set loads [get_pins -quiet -of $n -filter {DIRECTION == IN}]
    puts "N $tag net=$full drivers=[llength $drv] loads=[llength $loads]"
    foreach d $drv { puts "N $tag   driver=[get_property NAME $d] ref=[get_property REF_NAME [get_cells -quiet -of $d]]" }
    set k 0
    foreach l $loads {
      incr k
      if {$k <= 6} { puts "N $tag   load$k=[get_property NAME $l] ref=[get_property REF_NAME [get_cells -quiet -of $l]]" }
    }
  }
  set tag n2b
}

# DP top-50 breadth
catch {report_timing -group g_hw.clk_out0 -delay_type max -max_paths 50 -sort_by slack -file $out/dp_top50.rpt}
puts "N dp_top50 written"
set p50 [get_timing_paths -max_paths 50 -delay_type max -sort_by slack -quiet -from [get_cells -hier -quiet u_tcp_tx/*]]
puts "N misc_probe=[llength $p50]"
puts "N_DONE"
