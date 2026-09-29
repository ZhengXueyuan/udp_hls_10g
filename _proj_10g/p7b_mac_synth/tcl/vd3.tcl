set B "D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/p7b_mac_synth"
open_checkpoint "$B/xxv_mac/pcs64_2ch/pcs64_2ch.runs/impl_1/xxv_mac_top_routed.dcp"
puts "== paths FROM u_mac_tx (worst 6, setup) =="
foreach p [get_timing_paths -delay_type max -max_paths 6 -nworst 1 -sort_by slack \
              -from [get_cells -hier -quiet -filter {NAME =~ u_mac_tx/*}]] {
    set sp [get_property STARTPOINT_PIN $p] ; set ep [get_property ENDPOINT_PIN $p]
    set sc [get_clocks -quiet -of_objects [get_pins -quiet $sp]]
    set ec [get_clocks -quiet -of_objects [get_pins -quiet $ep]]
    puts [format "TXPATH slack=%.3f levels=%s sp=%s (%s) ep=%s (%s)" \
          [get_property SLACK $p] [get_property LOGIC_LEVELS $p] $sp $sc $ep $ec]
}
puts "== paths FROM u_mac_rx (worst 4, setup) =="
foreach p [get_timing_paths -delay_type max -max_paths 4 -nworst 1 -sort_by slack \
              -from [get_cells -hier -quiet -filter {NAME =~ u_mac_rx/*}]] {
    set sp [get_property STARTPOINT_PIN $p] ; set ep [get_property ENDPOINT_PIN $p]
    set sc [get_clocks -quiet -of_objects [get_pins -quiet $sp]]
    set ec [get_clocks -quiet -of_objects [get_pins -quiet $ep]]
    puts [format "RXPATH slack=%.3f levels=%s sp=%s (%s) ep=%s (%s)" \
          [get_property SLACK $p] [get_property LOGIC_LEVELS $p] $sp $sc $ep $ec]
}
puts "== the XGMII nets inside DUT =="
foreach n [get_nets -hier -quiet -filter {NAME =~ *mii_d*} ] { puts "  NET $n" }
puts "== hierarchical utilization =="
report_utilization -hierarchical -file "$B/reports/B_WithMac_util_hier_routed.rpt"
puts "VD3_DONE"
