run 4000ns
foreach cmd {
  {get_objects}
  {get_objects *}
  {get_objects /tb_p5_wrapper/u_dut/*}
  {get_objects -filter {type == net}}
  {get_objects -filter {type == signal}}
  {get_objects -filter {type == "net"}}
} {
    if {[catch {set r [eval $cmd]} e]} {
        puts "TRY '$cmd' -> ERR $e"
    } else {
        puts "TRY '$cmd' -> n=[llength $r] first=[lrange $r 0 3]"
    }
}
puts "--- direct value tests ---"
foreach pn {/tb_p5_wrapper/u_dut/txsrc_tready /tb_p5_wrapper/u_dut/m_tx_tvalid /tb_p5_wrapper/u_dut/u_tcp_tx/state} {
    if {[catch {set v [get_value -radix hex $pn]} e]} {
        puts "VAL $pn -> ERR $e"
    } else {
        puts "VAL $pn = $v"
    }
}
exit 0
