# attr_fail.tcl -- READ ONLY attribution of the failing setup endpoints.
# Opens the routed checkpoint produced by board/build_p7b_ku5p.tcl and classifies
# every timing path with slack < 0.  Writes NOTHING back to the project.
# Does NOT program the board, does NOT touch QSPI, does NOT modify any RTL/XDC.
set here [file dirname [file normalize [info script]]]
set root [file normalize ${here}/../../../../]
set dcp  ${root}/vivado_prj/p7b_ku5p_prj.runs/impl_1/wrapper_p4_routed.dcp
puts "ATTR_DCP = $dcp"
open_checkpoint $dcp

set pi [get_pins -quiet -hier -filter {IS_SEQUENTIAL}]
puts "ATTR_SEQ_PINS = [llength $pi]"

# every violating setup path in the whole design
set paths [get_timing_paths -delay_type max -max_paths 400 -slack_lesser_than 0 -nworst 400]
puts "ATTR_NEG_PATHS_RETURNED = [llength $paths]"

array set bysrc {}
array set bygrp {}
array set bypair {}
set i 0
foreach p $paths {
    incr i
    set sp [get_property STARTPOINT_PIN $p]
    set ep [get_property ENDPOINT_PIN  $p]
    set sl [get_property SLACK $p]
    set tg [get_property PATH_GROUP $p]
    set sc [get_property STARTPOINT_CLOCK $p]
    set ec [get_property ENDPOINT_CLOCK   $p]
    if {$i <= 45} {
        puts "ATTR_PATH $i slack=$sl group=$tg"
        puts "ATTR_PATH $i   sp=$sp"
        puts "ATTR_PATH $i   ep=$ep"
        puts "ATTR_PATH $i   sclk=[get_property NAME $sc]  eclk=[get_property NAME $ec]"
    }
    # attribute to top-level instance / clock group
    set top "OTHER"
    foreach pref {u_mac_tx u_mac_rx u_pcs pcs64 u_pcie_xdma u_pcie_regs u_pcs/inst} {
        if {[string match "${pref}*" $sp]} { set top $pref ; break }
    }
    if {![info exists bysrc($top)]} { set bysrc($top) 0 }
    incr bysrc($top)
    if {![info exists bygrp($tg)]} { set bygrp($tg) 0 }
    incr bygrp($tg)
    set pair "[get_property NAME $sc] -> [get_property NAME $ec]"
    if {![info exists bypair($pair)]} { set bypair($pair) 0 }
    incr bypair($pair)
}
puts "ATTR_--- by START instance ---"
foreach k [lsort [array names bysrc]] { puts "ATTR_SRC $k = $bysrc($k)" }
puts "ATTR_--- by PATH_GROUP (clock pair as reported) ---"
foreach k [lsort [array names bygrp]] { puts "ATTR_GRP $k = $bygrp($k)" }
puts "ATTR_--- by clock pair ---"
foreach k [lsort [array names bypair]] { puts "ATTR_PAIR $k = $bypair($k)" }

# how many endpoints fail in each clock group, straight from the report engine
puts "ATTR_--- per-clock-group negative endpoints ---"
foreach clk [get_clocks] {
    set n {}
    catch {set n [get_timing_paths -delay_type max -max_paths 5000 -slack_lesser_than 0 -from $clk -to $clk]}
    if {[llength $n] > 0} { puts "ATTR_GROUPFAIL [get_property NAME $clk] = [llength $n]" }
}
puts "ATTR DONE"
