set REPO_ROOT [file normalize [file join [file dirname [info script]] ..]]
if {![file exists [file join $REPO_ROOT CLAUDE.md]]} {
  error "PATHGUARD FAIL: cannot locate this checkout from [info script] -- derived REPO_ROOT = $REPO_ROOT"
}
set out_dir %REPO_ROOT%/p5f_verify
open_checkpoint %REPO_ROOT%/vivado_prj/p5_prj.runs/impl_1/wrapper_p4_routed.dcp
report_timing -delay_type min -max_paths 300 -nworst 300 -unique_paths_to_endpoint -sort_by slack -file ${out_dir}/hold_uniq.rpt
puts "HOLDUNIQ DONE"
exit
