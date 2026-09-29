set REPO_ROOT [file normalize [file join [file dirname [info script]] ..]]
if {![file exists [file join $REPO_ROOT CLAUDE.md]]} {
  error "PATHGUARD FAIL: cannot locate this checkout from [info script] -- derived REPO_ROOT = $REPO_ROOT"
}
set out_dir %REPO_ROOT%/p5f_verify
open_checkpoint %REPO_ROOT%/vivado_prj/p5_prj.runs/impl_1/wrapper_p4_routed.dcp

proc scan_ramb {tag pat} {
  set cells [get_cells -hier -quiet -filter "NAME =~ *$pat* && PRIMITIVE_TYPE =~ BMEM.*"]
  set n [llength $cells]
  set smin 99.0; set cmin ""
  set smax 99.0; set cmax ""
  foreach cc $cells {
    set tp [get_timing_paths -quiet -delay_type min -to $cc -max_paths 1]
    if {[llength $tp] > 0} {
      set s [get_property SLACK $tp]
      if {$s < $smin} { set smin $s; set cmin $cc }
    }
    set tp2 [get_timing_paths -quiet -delay_type max -to $cc -max_paths 1]
    if {[llength $tp2] > 0} {
      set s2 [get_property SLACK $tp2]
      if {$s2 < $smax} { set smax $s2; set cmax $cc }
    }
  }
  puts "BRAMSCAN $tag : brams=$n worst_hold=$smin @ $cmin | worst_setup=$smax @ $cmax"
}

puts "=== BRAMSCAN start ==="
# 目标: UDP app 帧缓冲 (u_uf, D=512) vs TCP app 帧缓冲 (u_tcp_echo/u_fifo, D=8192)
scan_ramb "UDP_UF"    "u_udp_split/u_uf/"
scan_ramb "TCP_ECHO"  "u_tcp_echo/u_fifo/"
scan_ramb "SLOW_RX"   "u_slow_rx/"
scan_ramb "SLOW_TX"   "u_slow_tx/"
scan_ramb "RETX"      "u_tcp_tx/u_retx/"
scan_ramb "MAC_RX"    "u_mac_rx/"
scan_ramb "HLS"       "u_hls/"

puts "=== BRAMSCAN: design-wide worst hold paths that END on a BRAM pin ==="
set n0 0
foreach c [get_cells -hier -quiet -filter {PRIMITIVE_TYPE =~ BMEM.*}] {
  incr n0
}
puts "BRAMSCAN total_bram_cells=$n0"

# 全局最差 hold 的 400 条, 报告目的地是不是 BRAM
report_timing -delay_type min -max_paths 400 -nworst 400 -sort_by slack -file ${out_dir}/bramhold400.rpt
report_timing -delay_type max -max_paths 400 -nworst 400 -sort_by slack -file ${out_dir}/bramsetup400.rpt
puts "BRAMSCAN DONE"
exit
