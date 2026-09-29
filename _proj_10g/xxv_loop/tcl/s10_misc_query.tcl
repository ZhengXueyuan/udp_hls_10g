# s10_misc_query.tcl -- READ-ONLY: (a) where the placer put IBUFDS_GTE4 (the
#   [DRC AVAL-326] question), (b) whether the top-level IP exposes any FREERUN /
#   DRP knob at all, (c) the fanout of the pay_sel control net.
set root "D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/xxv_loop"
open_project "$root/pcs64_2ch/pcs64_2ch.xpr"
proc sec {s} { puts "\nS10 >>>>>>>>>> $s" }
sec "S10_IBUFDS"
set n 0
foreach c [get_cells -hier -quiet -filter {REF_NAME =~ IBUFDS_GTE4*}] {
    incr n
    set loc "<none>" ; catch {set loc [get_property LOC $c]}
    set p [get_property NAME $c]
    puts "S10_IBUFDS $p LOC=$loc"
}
puts "S10_IBUFDS_N $n"
foreach c [get_cells -hier -quiet -filter {REF_NAME =~ GTYE4_COMMON*}] {
    set loc "<none>" ; catch {set loc [get_property LOC $c]}
    puts "S10_COMMON $c LOC=$loc"
}
sec "S10_PROPS"
open_run impl_1
set ip [get_ips pcs64]
set hits 0
foreach p [lsort [list_property $ip]] {
    foreach pat {*FREERUN* *DRP* *REFCLK*} {
        if {[string match -nocase $pat $p]} {
            set v "<err>" ; catch {set v [get_property $p $ip]}
            puts "S10_PROP $p = $v"
            incr hits
            break
        }
    }
}
puts "S10_PROP_HITS $hits"
# can FREERUN_FREQUENCY be set at the top level at all?
foreach cand {CONFIG.FREERUN_FREQUENCY CONFIG.GT_DRP_CLK CONFIG.GT_REF_CLK_FREQ} {
    set rc [catch {get_property $cand $ip} v]
    puts "S10_TRY $cand rc=$rc val=<$v>"
}
sec "S10_PAYSEL_FANOUT"
foreach n {vio_pay_sel vio_gt_loopback} {
    foreach nt [get_nets -quiet -hier -filter "NAME =~ *$n"] {
        set loads [get_pins -quiet -of_objects $nt -filter {DIRECTION == IN}]
        puts "S10_NET $nt nloads=[llength $loads]"
        foreach l $loads { puts "S10_LOAD $nt -> $l" }
    }
}
sec "S10 DONE"
close_project -quiet
