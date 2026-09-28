#=============================================================================
# p6_worst_ep.tcl -- P6 gate-B follow-up, read-only.
#   (a) per-ENDPOINT worst-400 setup report (-nworst 1: one path per endpoint,
#       unlike p6_verify.tcl's -nworst 400 which repeats one endpoint)
#   (b) design-wide top fanout nets (answers "is the fo=498 family still worst")
#   ASCII only. Writes into p6_verify/.
#=============================================================================
set root_dir D:/repo/ECO/udp_hls_10g
set out_dir  ${root_dir}/p6_verify

foreach tag {t8p0 t6p4} {
    set dcp ${root_dir}/vivado_prj/p6_${tag}_prj.runs/impl_1/wrapper_p4_routed.dcp
    if {![file exists $dcp]} { puts "P6EP MISSING $dcp"; continue }
    open_checkpoint $dcp

    # (a) one worst setup path per endpoint, worst 400 endpoints
    report_timing -max_paths 400 -nworst 1 -sort_by slack -delay_type max \
        -file ${out_dir}/p6_${tag}_setup_ep400.rpt
    report_timing -max_paths 400 -nworst 1 -sort_by slack -delay_type min \
        -file ${out_dir}/p6_${tag}_hold_ep400.rpt

    # (b) top fanout nets in the routed design
    set fh [open ${out_dir}/p6_${tag}_fanout.txt w]
    puts $fh "# tag=$tag  routed netlist, nets with FLAT_PIN_COUNT >= 64, sorted desc"
    set nets [get_nets -hier -quiet -filter {FLAT_PIN_COUNT >= 64}]
    set rows {}
    foreach n $nets {
        lappend rows [list [get_property -quiet FLAT_PIN_COUNT $n] $n]
    }
    set rows [lsort -integer -decreasing -index 0 $rows]
    puts "P6FANOUT ${tag}: nets_with_fanout_ge64=[llength $rows]"
    foreach r $rows {
        puts $fh "[lindex $r 0]  [lindex $r 1]"
    }
    close $fh
    foreach r [lrange $rows 0 14] {
        puts "  P6FANOUT ${tag}  fo=[lindex $r 0]  [lindex $r 1]"
    }
    # the historical worst family (P4c/P5e): u_retx read-address nets
    foreach pat {rpe r_tap_seq ring_rem nbeats rb_snd_nxt} {
        set fn [get_nets -hier -quiet -filter "NAME =~ *u_retx/${pat}*"]
        set mx 0
        set mn ""
        foreach n $fn {
            set c [get_property -quiet FLAT_PIN_COUNT $n]
            if {$c > $mx} { set mx $c; set mn $n }
        }
        puts "  P6RETX ${tag}  u_retx/${pat}*  nets=[llength $fn]  max_fo=$mx  $mn"
    }
}

puts "\n===== P6 WORST-EP DONE ====="
exit
