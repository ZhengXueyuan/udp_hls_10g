proc scan {tag pat} {
    set objs [get_objects $pat]
    set n 0
    set hits 0
    foreach o $objs {
        incr n
        if {[catch {set v [get_value -radix hex $o]} e]} { continue }
        if {[string match "*x*" $v] || [string match "*z*" $v]} {
            incr hits
            puts "ZSCAN $tag $o = $v"
        }
    }
    puts "ZSCAN-COUNT $tag pat=$pat total=$n hits=$hits"
}
puts "ZSCAN-DEPTH2-COUNT = [llength [get_objects /tb_p5_wrapper/u_dut/*/*]]"
run 4000ns
scan pre_preset /tb_p5_wrapper/u_dut/*
run 36000ns
scan mid /tb_p5_wrapper/u_dut/*
run 20000ns
scan hang /tb_p5_wrapper/u_dut/*
scan hang_txarb /tb_p5_wrapper/u_dut/u_tx_arb/*
scan hang_mactx /tb_p5_wrapper/u_dut/u_mac_tx/*
scan hang_tcptx /tb_p5_wrapper/u_dut/u_tcp_tx/*
exit 0
