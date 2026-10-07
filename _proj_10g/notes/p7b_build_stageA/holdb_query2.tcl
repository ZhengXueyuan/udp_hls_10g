# holdb_query2.tcl -- Stage A: u_snap_p7bdp/hold_b_reg[*] 全族逐端点查询 (只读 dcp)
#   修正 v1 的错误: timing_path 没有 DESTINATION_PIN 属性 ⇒ 用 catch 兜底 + 逐位循环 (无需终点名)
set dcp D:/repo/XCKU5PMini/udp_hls_10g/vivado_prj/p7b_ku5p_prj.runs/impl_1/wrapper_p4_routed.dcp
open_checkpoint $dcp

set cells [get_cells -hier -quiet -filter {NAME =~ "*u_snap_p7bdp/hold_b_reg*"}]
puts "CELL_COUNT=[llength $cells]"
set dpins [get_pins -hier -quiet -filter {NAME =~ "*u_snap_p7bdp/hold_b_reg*" && REF_PIN_NAME == "D"}]
puts "DPIN_COUNT=[llength $dpins]"

set idx {}
foreach c $cells {
  if {[regexp {hold_b_reg\[(\d+)\]} [get_property NAME $c] -> n]} { lappend idx $n }
}
set idx [lsort -integer -unique $idx]
puts "BIT_N=[llength $idx] MIN=[lindex $idx 0] MAX=[lindex $idx end]"
set ranges {}
set s [lindex $idx 0]; set p $s
foreach n [lrange $idx 1 end] {
  if {$n == $p+1} { set p $n } else { lappend ranges "$s-$p"; set s $n; set p $n }
}
lappend ranges "$s-$p"
puts "BIT_RANGES=[join $ranges {,}]"

set p0 [get_timing_paths -quiet -delay_type min -to [lindex $dpins 0] -max_paths 1]
if {[llength $p0]} {
  foreach pr {SLACK STARTPOINT_PIN ENDPOINT_PIN DESTINATION_PIN LOGIC_LEVELS PATH_GROUP REQUIREMENT DATAPATH_DELAY} {
    if {[catch {set v [get_property $pr [lindex $p0 0]]} e]} { puts "PROPFAIL $pr" } else { puts "PROPOK $pr = $v" }
  }
}

foreach t {min max} {
  puts "=== PERBIT_$t BEGIN ==="
  foreach pin $dpins {
    set nm [get_property NAME $pin]
    set p [get_timing_paths -quiet -delay_type $t -to $pin -max_paths 1]
    if {[llength $p]} {
      set pp [lindex $p 0]
      set sl [get_property SLACK $pp]
      set ll "?"; catch {set ll [get_property LOGIC_LEVELS $pp]}
      set sp "?"; catch {set spp [get_property STARTPOINT_PIN $pp]; set sp [get_property NAME $spp]}
      puts "PB_$t $nm SLACK=$sl LL=$ll SRC=$sp"
    } else {
      puts "PB_$t $nm NOPATH"
    }
  }
  puts "=== PERBIT_$t END ==="
}
puts "QUERY2_DONE"
exit
