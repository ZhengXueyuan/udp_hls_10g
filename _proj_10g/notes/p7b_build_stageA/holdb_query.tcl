# holdb_query.tcl -- Stage A 构建后定向查询 (只读 dcp, 不烧板)
#   目标 = 对抗审查指名的必查项: u_snap_p7bdp/hold_b_reg[*] 这一族 (W62 组合派生的宿端)
#   输出 = 全族逐端点 (每端点取最差一条) hold/setup slack + 最差 20 条带逻辑级数
set dcp D:/repo/XCKU5PMini/udp_hls_10g/vivado_prj/p7b_ku5p_prj.runs/impl_1/wrapper_p4_routed.dcp
open_checkpoint $dcp

set pins [get_pins -hier -quiet -filter {NAME =~ "*u_snap_p7bdp/hold_b_reg*" && REF_PIN_NAME == "D"}]
puts "FAMILY_PIN_COUNT = [llength $pins]"

foreach t {min max} {
    set paths [get_timing_paths -quiet -delay_type $t -to $pins -max_paths 800 -nworst 1 -sort_by slack]
    puts "=== PATHS_$t COUNT = [llength $paths] ==="
    set i 0
    foreach p $paths {
        incr i
        set sl [get_property SLACK $p]
        set dp [get_property NAME [get_property DESTINATION_PIN $p]]
        set sp [get_property NAME [get_property STARTPOINT_PIN $p]]
        if {$i <= 20} {
            set ll [get_property -quiet LOGIC_LEVELS $p]
            puts "WORST_$t #$i SLACK=$sl LL=$ll DST=$dp SRC=$sp"
        }
        puts "PERBIT_$t $dp $sl"
    }
}
puts "QUERY_DONE"
exit
