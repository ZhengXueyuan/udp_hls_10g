set REPO_ROOT [file normalize [file join [file dirname [info script]] ..]]
if {![file exists [file join $REPO_ROOT CLAUDE.md]]} {
  error "PATHGUARD FAIL: cannot locate this checkout from [info script] -- derived REPO_ROOT = $REPO_ROOT"
}
open_checkpoint %REPO_ROOT%/vivado_prj/p5_prj.runs/impl_1/wrapper_p4_routed.dcp
foreach n {u_udp_split u_udp_tx u_udp_tx_cfg u_app_udp u_tx_udp_arb u_tx_arb u_udp_split/u_udp_rx} {
    set c [get_cells -hier -quiet -filter "NAME =~ *$n*"]
    set l [get_cells -hier -quiet -filter "NAME =~ *$n*" -filter {PRIMITIVE_GROUP == "LUT"}]
    puts "INSTCHECK $n : total_cells=[llength $c] lut_cells=[llength $l] exists=[expr {[llength $c]>0}]"
}
exit
