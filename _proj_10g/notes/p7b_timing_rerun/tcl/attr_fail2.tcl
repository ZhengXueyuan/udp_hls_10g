# attr_fail2.tcl -- READ ONLY attribution of the failing setup endpoints.
# Opens the routed checkpoint produced by board/build_p7b_ku5p.tcl and classifies
# every timing path with slack < 0, clock-pair by clock-pair.
# Writes NOTHING back to the project; does NOT program the board; does NOT touch
# QSPI; does NOT modify any RTL/XDC/build script.
set here [file dirname [file normalize [info script]]]
set root [file normalize ${here}/../../../../]
set dcp  ${root}/vivado_prj/p7b_ku5p_prj.runs/impl_1/wrapper_p4_routed.dcp
set out  ${here}/../attr_paths.txt
puts "ATTR_DCP = $dcp"
open_checkpoint $dcp

set clocks [get_clocks]
puts "ATTR_NCLOCKS = [llength $clocks]"

set fd [open $out w]
set total 0
puts "ATTR_--- per ordered clock pair: count of paths with slack<0 ---"
foreach ca $clocks {
    set na [get_property NAME $ca]
    foreach cb $clocks {
        set nb [get_property NAME $cb]
        set n 0
        catch {set n [llength [get_timing_paths -delay_type max -from $ca -to $cb -slack_lesser_than 0 -max_paths 200 -nworst 1]]}
        if {$n > 0} {
            puts "ATTR_PAIRFAIL $na -> $nb = $n"
            incr total $n
        }
    }
}
puts "ATTR_PAIRFAIL_TOTAL = $total"
puts "ATTR_--- every path with slack<0 (no clock-pair filter) ---"
set all {}
catch {set all [get_timing_paths -delay_type max -slack_lesser_than 0 -max_paths 200 -nworst 1]}
puts "ATTR_ALL_NEG_N = [llength $all]"
set i 0
foreach p $all {
    incr i
    set sl [get_property SLACK $p]
    set sp [get_property STARTPOINT_PIN $p]
    set ep [get_property ENDPOINT_PIN  $p]
    set sc [get_property STARTPOINT_CLOCK $p]
    set ec [get_property ENDPOINT_CLOCK   $p]
    set ln [get_property LOGIC_LEVELS $p]
    set msg "ATTR $i slack=$sl levels=$ln sp=$sp ep=$ep sclk=[get_property NAME $sc] eclk=[get_property NAME $ec]"
    puts $fd $msg
    if {$i <= 6} { puts $msg }
}
close $fd
puts "ATTR_PATHS_FILE = $out"
puts "ATTR DONE"
