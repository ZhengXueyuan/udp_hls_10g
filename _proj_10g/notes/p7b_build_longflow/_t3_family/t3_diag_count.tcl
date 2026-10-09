# t3_diag_count.tcl — 只读诊断: 澄清 "worst2000 dump 计数" 与 "slack_lesser_than 计数" 的差
# 用法: vivado -mode batch -nojournal -nolog -source t3_diag_count.tcl -tclargs <tag> <dcp>
set tag  [lindex $argv 0]
set dcpp [lindex $argv 1]
open_checkpoint $dcpp
set big [get_timing_paths -delay_type max -max_paths 2000 -nworst 1]
puts "DIAG|$tag|n_big=[llength $big]|last_slack=[get_property SLACK [lindex $big end]]|first_slack=[get_property SLACK [lindex $big 0]]"
set n05 0; set n10 0; set n20 0
foreach p $big {
  set s [get_property SLACK $p]
  if {$s < 0.05} { incr n05 }
  if {$s < 0.10} { incr n10 }
  if {$s < 0.20} { incr n20 }
}
puts "DIAG|$tag|internal_from_big|n05=$n05|n10=$n10|n20=$n20"
foreach thr {0.05 0.10 0.20} {
  set c [get_timing_paths -quiet -delay_type max -slack_lesser_than $thr -max_paths 10000 -nworst 1]
  puts "DIAG|$tag|cnt_$thr=[llength $c]"
}
# 差集: 在 cnt20 里但不在 big 里的端点对
set c20 [get_timing_paths -quiet -delay_type max -slack_lesser_than 0.20 -max_paths 10000 -nworst 1]
set bigset {}
foreach p $big { lappend bigset "[get_property STARTPOINT_PIN $p]|[get_property ENDPOINT_PIN $p]" }
set d 0
foreach p $c20 {
  set k "[get_property STARTPOINT_PIN $p]|[get_property ENDPOINT_PIN $p]"
  if {[lsearch -exact $bigset $k] < 0} {
    incr d
    puts "DIAG|$tag|ONLY_IN_CNT|slack=[get_property SLACK $p]|$k"
    if {$d > 12} { break }
  }
}
puts "DIAG|$tag|only_in_cnt_total=$d"
# 反向: big 里 slack<0.2 但不在 c20 里
set cset {}
foreach p $c20 { lappend cset "[get_property STARTPOINT_PIN $p]|[get_property ENDPOINT_PIN $p]" }
set d2 0
foreach p $big {
  set s [get_property SLACK $p]
  if {$s < 0.20} {
    set k "[get_property STARTPOINT_PIN $p]|[get_property ENDPOINT_PIN $p]"
    if {[lsearch -exact $cset $k] < 0} { incr d2 }
  }
}
puts "DIAG|$tag|only_in_big_total=$d2"
# 重复键普查: cnt 列表里是否有同一 (src,dst) 出现多次
array set seen {}
set dups 0
foreach p $c20 {
  set k "[get_property STARTPOINT_PIN $p]|[get_property ENDPOINT_PIN $p]"
  if {[info exists seen($k)]} {
    incr seen($k)
    if {$dups < 8} { puts "DIAG|$tag|DUPKEY|$k|n=[expr {$seen($k)}]|slack=[get_property SLACK $p]|ptype=[get_property PATH_TYPE $p]|pgrp=[get_property PATH_GROUP $p]" }
    incr dups
  } else {
    set seen($k) 1
  }
}
puts "DIAG|$tag|dup_keys_extra=$dups|distinct=[array size seen]|total=[llength $c20]"
puts "DIAG|$tag|done"
