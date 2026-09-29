set REPO_ROOT [file normalize [file join [file dirname [info script]] ..]]
if {![file exists [file join $REPO_ROOT CLAUDE.md]]} {
  error "PATHGUARD FAIL: cannot locate this checkout from [info script] -- derived REPO_ROOT = $REPO_ROOT"
}
open_checkpoint %REPO_ROOT%/vivado_prj/p5_prj.runs/impl_1/wrapper_p4_routed.dcp
report_utilization -hierarchical -hierarchical_depth 2 -file %REPO_ROOT%/p5e_verify/p5e_util_hier.rpt
exit
