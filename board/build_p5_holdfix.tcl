# build_p5_holdfix.tcl -- P5f hold-margin hardened rebuild (reuses existing p5_prj)
set root_dir D:/repo/ECO/udp_hls_10g
set out_dir  ${root_dir}/p5f_verify
open_project ${root_dir}/vivado_prj/p5_prj.xpr
add_files -fileset constrs_1 -norecurse ${root_dir}/board/eco_holdfix.xdc
set_property target_constrs_file ${root_dir}/board/eco_holdfix.xdc [get_filesets constrs_1]
reset_run impl_1
set_property strategy Performance_ExtraTimingOpt [get_runs impl_1]
launch_runs impl_1 -jobs 8
wait_on_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
open_run impl_1
report_timing_summary -max_paths 5 -file ${out_dir}/holdfix_timing.rpt
report_timing -delay_type min -max_paths 20 -nworst 20 -sort_by slack -file ${out_dir}/holdfix_hold.rpt
puts "HOLDFIX BUILD DONE"
exit
