set out_dir D:/repo/ECO/udp_hls_10g/p5f_verify
open_checkpoint D:/repo/ECO/udp_hls_10g/vivado_prj/p5_prj.runs/impl_1/wrapper_p4_routed.dcp
report_timing -delay_type min -max_paths 300 -nworst 300 -unique_paths_to_endpoint -sort_by slack -file ${out_dir}/hold_uniq.rpt
puts "HOLDUNIQ DONE"
exit
