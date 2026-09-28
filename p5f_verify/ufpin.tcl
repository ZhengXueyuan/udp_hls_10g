set out_dir D:/repo/ECO/udp_hls_10g/p5f_verify
open_checkpoint D:/repo/ECO/udp_hls_10g/vivado_prj/p5_prj.runs/impl_1/wrapper_p4_routed.dcp

# u_udp_split/u_uf 内部: BRAM 主存 (gen_mem[0].u_main) 与 边存 LUTRAM (gen_side.mem_s*)
# 目的: 比较 "BRAM 读地址/写地址/写数据" 与 "边存 LUTRAM 读地址" 的 hold 余量
#   => 若 BRAM 端口显著更紧, 则 "读到错址 => 数据错而 tkeep/tlast 对" 的机制成立

proc worst_to {tag pinpat dtyp} {
  set pins [get_pins -hier -quiet -filter "NAME =~ *$pinpat*"]
  set n [llength $pins]
  set w 99.0; set wp ""
  foreach p $pins {
    set tp [get_timing_paths -quiet -delay_type $dtyp -to $p -max_paths 1]
    if {[llength $tp] > 0} {
      set s [get_property SLACK $tp]
      if {$s < $w} { set w $s; set wp $p }
    }
  }
  puts "UFPIN $tag ($dtyp) : pins=$n worst=$w @ $wp"
  if {$wp ne ""} {
    set tp [get_timing_paths -quiet -delay_type $dtyp -to $wp -max_paths 1]
    if {[llength $tp] > 0} {
      puts "UFPIN    src=[get_property STARTPOINT_PIN $tp]"
    }
  }
}

puts "=== UFPIN start ==="
worst_to "BRAM_ADDRARDADDR" "u_udp_split/u_uf/gen_mem\[0\].u_main/ADDRARDADDR" "min"
worst_to "BRAM_ADDRBWRADDR" "u_udp_split/u_uf/gen_mem\[0\].u_main/ADDRBWRADDR" "min"
worst_to "BRAM_DIADI"       "u_udp_split/u_uf/gen_mem\[0\].u_main/DIADI"       "min"
worst_to "BRAM_DIBDI"       "u_udp_split/u_uf/gen_mem\[0\].u_main/DIBDI"       "min"
worst_to "BRAM_WEBWE"       "u_udp_split/u_uf/gen_mem\[0\].u_main/WEBWE"       "min"
worst_to "SIDE_ADDR"        "u_udp_split/u_uf/gen_side.mem_s"                 "min"
worst_to "SIDE_ADDR_setup"  "u_udp_split/u_uf/gen_side.mem_s"                 "max"

worst_to "BRAM_ADDRARDADDR_setup" "u_udp_split/u_uf/gen_mem\[0\].u_main/ADDRARDADDR" "max"
worst_to "BRAM_ADDRBWRADDR_setup" "u_udp_split/u_uf/gen_mem\[0\].u_main/ADDRBWRADDR" "max"
worst_to "BRAM_DIBDI_setup"       "u_udp_split/u_uf/gen_mem\[0\].u_main/DIBDI"       "max"

puts "=== UFPIN: side_dout_r 的完整最差 hold 路径 ==="
set c [get_cells -hier -quiet -filter "NAME =~ *u_udp_split/u_uf*side_dout_r_reg*"]
puts "UFPIN side_dout_r cells=[llength $c]"
if {[llength $c] > 0} {
  report_timing -delay_type min -to [get_cells {*u_udp_split/u_uf*side_dout_r_reg*}] -max_paths 1 -file ${out_dir}/ufp_side.rpt
}
puts "UFPIN DONE"
exit
