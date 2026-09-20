#=============================================================================
# verify_p5e.tcl — P5e 出口验证 (只读, 不改工程/不改 RTL)
#   open_checkpoint routed.dcp -> report_timing_summary / utilization / drc /
#   route_status, 全部写到 p5e_verify/
# 用法: vivado -mode batch -source p5e_verify/verify_p5e.tcl -log ...
#=============================================================================
set root_dir  D:/repo/ECO/udp_hls_10g
set out_dir   ${root_dir}/p5e_verify
set dcp       ${root_dir}/vivado_prj/p5_prj.runs/impl_1/wrapper_p4_routed.dcp

open_checkpoint $dcp

report_timing_summary -max_paths 20 -routable_nets \
    -file ${out_dir}/p5e_timing_routed.rpt
report_utilization -file ${out_dir}/p5e_utilization_routed.rpt
report_drc -file ${out_dir}/p5e_drc_routed.rpt
report_route_status -file ${out_dir}/p5e_route_status.rpt
report_clock_utilization -file ${out_dir}/p5e_clock_util.rpt

puts "\n===== P5e VERIFY DONE: reports in ${out_dir} ====="
exit
