set out_dir D:/repo/ECO/udp_hls_10g/p5f_verify
open_checkpoint D:/repo/ECO/udp_hls_10g/vivado_prj/p5_prj.runs/impl_1/wrapper_p4_routed.dcp

set pats {
  u_mac_rx/wreg_reg u_mac_rx/hwreg_reg u_mac_rx/dline_reg u_mac_rx/fbytes_reg
  u_mac_rx/rx_keep_reg u_mac_rx/rx_len_reg
  u_udp_split/u_udp_rx/emit_d_reg u_udp_split/u_udp_rx/emit_k_reg
  u_udp_split/u_udp_rx/hold_reg u_udp_split/u_udp_rx/tail_d_reg
  u_app_udp/cmp_d_reg u_app_udp/nx_d_reg u_app_udp/rx_lfsr_reg
}

puts "=== RXSETUP: per-cell worst setup (max) and hold (min) ==="
foreach p $pats {
  set c [get_cells -hier -quiet -filter "NAME =~ *$p*"]
  if {[llength $c] == 0} {
    puts "RXSETUP $p : NO CELLS"
    continue
  }
  set smin 99.0; set cmin ""
  set smax 99.0; set cmax ""
  foreach cc $c {
    set tp [get_timing_paths -quiet -delay_type max -to $cc -max_paths 1]
    if {[llength $tp] > 0} {
      set s [get_property SLACK $tp]
      if {$s < $smax} { set smax $s; set cmax $cc }
    }
    set tp2 [get_timing_paths -quiet -delay_type min -to $cc -max_paths 1]
    if {[llength $tp2] > 0} {
      set s2 [get_property SLACK $tp2]
      if {$s2 < $smin} { set smin $s2; set cmin $cc }
    }
  }
  puts "RXSETUP $p : cells=[llength $c] worst_setup=$smax @ $cmax | worst_hold=$smin @ $cmin"
}

puts "=== RXSETUP: full worst setup path INTO the byte-carrying regs ==="
foreach p {u_mac_rx/wreg_reg u_mac_rx/hwreg_reg u_mac_rx/dline_reg} {
  set c [get_cells -hier -quiet -filter "NAME =~ *$p*"]
  if {[llength $c] == 0} { continue }
  set worst 99.0; set wcell ""
  foreach cc $c {
    set tp [get_timing_paths -quiet -delay_type max -to $cc -max_paths 1]
    if {[llength $tp] > 0} {
      set s [get_property SLACK $tp]
      if {$s < $worst} { set worst $s; set wcell $cc }
    }
  }
  if {$wcell ne ""} {
    report_timing -delay_type max -to $wcell -max_paths 1 -file ${out_dir}/rxsetup_${p}.rpt
    puts "RXSETUP dumped $p (slack $worst) @ $wcell"
  }
}

puts "=== RXSETUP: clock definitions touching these paths ==="
foreach clk [get_clocks] {
  puts "CLK $clk period=[get_property PERIOD $clk] src=[get_property SOURCE_PINS $clk]"
}

puts "RXSETUP DONE"
exit
