#=============================================================================
# cone_rank_p5e.tcl — P5e 锥排名 (只读): 取最差 400 条 setup / hold 路径,
#   离线按锥聚合, 回答 "5 个新模块是否上榜 / 旧族名次".
#   与 P5d 的 setup_400.rpt / hold_400.rpt 同口径.
#=============================================================================
set root_dir  D:/repo/ECO/udp_hls_10g
set out_dir   ${root_dir}/p5e_verify
open_checkpoint ${root_dir}/vivado_prj/p5_prj.runs/impl_1/wrapper_p4_routed.dcp

report_timing -max_paths 400 -delay_type max -sort_by slack -nworst 400 \
    -file ${out_dir}/p5e_setup_400.rpt
report_timing -max_paths 400 -delay_type min -sort_by slack -nworst 400 \
    -file ${out_dir}/p5e_hold_400.rpt

puts "\n===== P5E CONE RANK DONE ====="
exit
