set out_dir D:/repo/ECO/udp_hls_10g/p5f_verify
open_checkpoint D:/repo/ECO/udp_hls_10g/vivado_prj/p5_prj.runs/impl_1/wrapper_p4_routed.dcp
set pats {
  u_app_udp/cmp_d_reg u_app_udp/nx_d_reg u_app_udp/rx_lfsr_reg u_app_udp/cmp_i_reg
  u_app_udp/cmp_n_reg u_app_udp/cmp_busy_reg u_app_udp/stat_mismatch_reg
  u_app_udp/stat_rx_bytes_reg u_app_udp/nx_v_reg u_app_udp/cmp_k_reg
  u_udp_split/rstate_reg u_udp_split/hold_rem_u_reg u_udp_split/len_r_reg
  u_udp_split/any_r_reg u_udp_split/sip_r_reg u_udp_split/u_open_r_reg
  u_udp_split/u_udp_rx/emit_d_reg u_udp_split/u_udp_rx/emit_k_reg
  u_udp_split/u_udp_rx/hold_reg u_udp_split/u_udp_rx/pcount_reg
  u_udp_split/u_udp_rx/wcnt_reg u_udp_split/u_udp_rx/state_reg
  u_udp_split/u_udp_rx/tail_d_reg u_udp_split/u_udp_rx/meta_len_r_reg
  u_udp_split/pw_cnt_reg u_udp_split/ip4_45_r_reg u_udp_split/swallow_r_reg
  u_udp_split/u_pb u_udp_split/u_pre u_udp_split/u_desc
  u_udp_split/u_uf/side_dout_r_reg u_udp_split/u_uf/bypass_r_reg
  u_mac_rx/hwreg_reg u_mac_rx/wreg_reg u_mac_rx/dline_reg u_mac_rx/fbytes_reg
  u_cls/sk_d_reg u_cls/sk_k_reg u_cls/n_reg u_cls/state_reg
}
foreach p $pats {
  set c [get_cells -hier -quiet -filter "NAME =~ *$p*"]
  set worst 99.0
  set wcell ""
  foreach cc $c {
    set tp [get_timing_paths -quiet -delay_type min -to $cc -max_paths 1]
    if {[llength $tp] > 0} {
      set s [get_property SLACK $tp]
      if {$s < $worst} { set worst $s; set wcell $cc }
    }
  }
  puts "RXHOLD $p : cells=[llength $c] worst_hold_slack=$worst @ $wcell"
}
puts "RXHOLD DONE"
exit
