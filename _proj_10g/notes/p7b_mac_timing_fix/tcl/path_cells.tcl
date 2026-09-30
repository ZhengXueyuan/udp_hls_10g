set B "D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/notes/p7b_mac_timing_fix"
open_checkpoint "$B/ooc/E_fix_eto_sink/E_fix_eto_sink.runs/impl_1/mac_tx_sink_top_routed.dcp"
set p [get_timing_paths -delay_type max -max_paths 1]
puts "PATH_SLACK = [get_property SLACK $p]  LEVELS = [get_property LOGIC_LEVELS $p]"
report_timing -max_paths 1 -delay_type max -input_pins -file "$B/reports/E_fix_eto_sink_worst_path.rpt"
close_project
puts "DONE"
