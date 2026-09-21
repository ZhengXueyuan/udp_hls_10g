set out_dir D:/repo/ECO/udp_hls_10g/p5f_verify
open_checkpoint D:/repo/ECO/udp_hls_10g/vivado_prj/p5_prj.runs/impl_1/wrapper_p4_routed.dcp
report_timing -max_paths 200 -delay_type min -sort_by slack -nworst 200 -file ${out_dir}/hold200.rpt
report_timing -max_paths 200 -delay_type max -sort_by slack -nworst 200 -file ${out_dir}/setup200.rpt
puts "HOLDSCAN DONE"
exit
