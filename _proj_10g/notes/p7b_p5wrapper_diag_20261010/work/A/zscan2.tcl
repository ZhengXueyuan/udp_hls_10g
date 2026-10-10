run 60000ns
puts "--- positive control (direct) ---"
foreach pn {/tb_p5_wrapper/u_dut/txsrc_tready /tb_p5_wrapper/u_dut/m_tx_tvalid /tb_p5_wrapper/u_dut/txsrc_tvalid /tb_p5_wrapper/u_dut/u_tcp_tx/state /tb_p5_wrapper/u_dut/gmii_clk} {
    if {[catch {set v [get_value -radix hex $pn]} e]} { puts "PC $pn ERR $e" } else { puts "PC $pn = $v" }
}
puts "--- enumeration forms ---"
foreach pat {/tb_p5_wrapper/u_dut/* /tb_p5_wrapper/u_dut/*/ /tb_p5_wrapper/u_dut/*txsrc* /tb_p5_wrapper/u_dut/*tx_*} {
    if {[catch {set r [get_objects $pat]} e]} { puts "ENUM '$pat' ERR $e" } else { puts "ENUM '$pat' n=[llength $r] first5=[lrange $r 0 4]" }
}
set all [get_objects /tb_p5_wrapper/u_dut/*]
set have 0
foreach o $all { if {[string match "*txsrc_tready*" $o]} { incr have } }
puts "txsrc_tready in enumeration: $have"
puts "sample names: [lrange $all 0 12]"
puts "names w/ z or x value:"
set n 0
foreach o $all {
    if {[catch {set v [get_value -radix hex $o]} e]} { continue }
    incr n
    if {$n <= 3} { puts "  VALTRY $o = $v" }
}
puts "addressable objects: $n / [llength $all]"
exit 0
