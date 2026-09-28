#=============================================================================
# p6a_verify.tcl -- P6a KU5P 移植的只读校验 (与 K7 的 p6_verify.tcl 同构,
#   以便逐项对照: 闸 G(KU5P) vs 闸 B(K7 @6.400ns: WNS -0.948 / 647 失败端点)).
#   For each of the two projects (t8p0 = 8.000ns control, t6p4 = 6.400ns):
#     open_checkpoint routed.dcp
#     report_clocks            -> constraint-effectiveness evidence
#     report_timing_summary    -> WNS/TNS/WHS/THS/WPWS table
#     report_timing 400 setup/hold -> worst-400 slack distribution
#     report_utilization (+hier)-> LUT/FF/BRAM/DSP
#     report_route_status
#     failing-endpoint census  -> per-hierarchy grouping (R2 input)
#   Usage: vivado -mode batch -source p6_verify/p6_verify.tcl -log ... -nojournal
#   Does NOT modify any project or RTL. ASCII only.
#=============================================================================
set root_dir D:/repo/XCKU5PMini/udp_hls_10g
set out_dir  ${root_dir}/p6a_ku5p_verify

foreach tag {t8p0 t6p4} {
    set dcp ${root_dir}/vivado_prj/p6a_ku5p_${tag}_prj.runs/impl_1/wrapper_p4_routed.dcp
    puts "\n########## P6a VERIFY (KU5P): ${tag}  (${dcp}) ##########"
    if {![file exists $dcp]} {
        puts "P6AVERIFY MISSING DCP: $dcp"
        continue
    }
    open_checkpoint $dcp

    report_clocks -file ${out_dir}/p6a_${tag}_clocks.rpt
    report_timing_summary -max_paths 20 -routable_nets -report_unconstrained \
        -file ${out_dir}/p6a_${tag}_timing_summary_routed.rpt
    report_timing -max_paths 400 -delay_type max -sort_by slack -nworst 400 \
        -file ${out_dir}/p6a_${tag}_setup_400.rpt
    report_timing -max_paths 400 -delay_type min -sort_by slack -nworst 400 \
        -file ${out_dir}/p6a_${tag}_hold_400.rpt
    report_utilization -file ${out_dir}/p6a_${tag}_utilization_routed.rpt
    report_utilization -hierarchical -hierarchical_depth 2 \
        -file ${out_dir}/p6a_${tag}_util_hier.rpt
    report_route_status -file ${out_dir}/p6a_${tag}_route_status.rpt

    # ---- clock period evidence (printed inline, so it lands in the log too) ----
    puts "P6ACLOCKS ${tag}:"
    foreach clk [lsort [get_clocks -quiet]] {
        set per [get_property -quiet PERIOD $clk]
        set wav [get_property -quiet WAVEFORM $clk]
        set gen [get_property -quiet IS_GENERATED $clk]
        set src [get_property -quiet SOURCE_PINS $clk]
        puts "P6ACLOCK ${tag}  $clk  period=${per}  generated=${gen}  waveform=${wav}  src=${src}"
    }

    # ---- failing-endpoint census (setup) ----
    set fh [open ${out_dir}/p6a_${tag}_failing_endpoints.txt w]
    puts $fh "# tag=$tag delay_type=max slack_lesser_than=0 nworst=1"
    puts $fh "# columns: slack  logic_levels  startpoint_pin  endpoint_pin  path_group"
    # cap 20000 worst endpoints -- the exact failing-endpoint total comes from
    # the WNS/TNS summary table (TNS Failing Endpoints); this census only feeds
    # the per-hierarchy distribution.
    set feps [get_timing_paths -quiet -delay_type max -slack_lesser_than 0 \
                  -nworst 1 -max_paths 20000]
    puts "P6AFEP ${tag} setup_failing_endpoint_paths=[llength $feps]"
    foreach p $feps {
        set s  [get_property -quiet SLACK $p]
        set lv [get_property -quiet LOGIC_LEVELS $p]
        set sp [get_property -quiet STARTPOINT_PIN $p]
        set ep [get_property -quiet ENDPOINT_PIN $p]
        set pg [get_property -quiet PATH_GROUP $p]
        puts $fh "$s  $lv  $sp  $ep  $pg"
    }
    close $fh

    # per-2-level-hierarchy failing endpoint histogram (Tcl-side, no python needed)
    set hist [dict create]
    foreach p $feps {
        set ep [get_property -quiet ENDPOINT_PIN $p]
        set s  [get_property -quiet SLACK $p]
        set leaf [get_property -quiet NAME [get_cells -quiet -of_objects $ep]]
        set parts [split $leaf /]
        set key [join [lrange $parts 0 1] /]
        if {$key eq ""} { set key "?" }
        if {[dict exists $hist $key]} {
            set cur [dict get $hist $key]
            set w [lindex $cur 0]
            if {$s < $w} { set w $s }
            dict set hist $key [list $w [expr {[lindex $cur 1] + 1}]]
        } else {
            dict set hist $key [list $s 1]
        }
    }
    puts "P6AFEPHIST ${tag} (endpoint 2-level hierarchy: worst_slack count)"
    set sorted [lsort -real -index 0 [lmap k [dict keys $hist] {list [lindex [dict get $hist $k] 0] $k [lindex [dict get $hist $k] 1]}]]
    foreach e $sorted {
        puts "  P6AFEPHIST ${tag}  [lindex $e 1]  worst=[lindex $e 0]  count=[lindex $e 2]"
    }
}

puts "\n===== P6a VERIFY DONE: reports in ${out_dir} ====="
exit
