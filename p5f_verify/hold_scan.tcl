set REPO_ROOT [file normalize [file join [file dirname [info script]] ..]]
if {![file exists [file join $REPO_ROOT CLAUDE.md]]} {
  error "PATHGUARD FAIL: cannot locate this checkout from [info script] -- derived REPO_ROOT = $REPO_ROOT"
}
set out_dir %REPO_ROOT%/p5f_verify
open_checkpoint %REPO_ROOT%/vivado_prj/p5_prj.runs/impl_1/wrapper_p4_routed.dcp
report_timing -max_paths 200 -delay_type min -sort_by slack -nworst 200 -file ${out_dir}/hold200.rpt
report_timing -max_paths 200 -delay_type max -sort_by slack -nworst 200 -file ${out_dir}/setup200.rpt
puts "HOLDSCAN DONE"
exit
