proc scan {tag pat} {
    set objs [get_objects $pat]
    set n 0
    set hits 0
    foreach o $objs {
        if {[catch {set v [get_value -radix hex $o]} e]} { continue }
        incr n
        set lv [string tolower $v]
        if {[string match "*x*" $lv] || [string match "*z*" $lv]} {
            incr hits
            puts "ZSCAN $tag $o = $v"
        }
    }
    puts "ZSCAN-COUNT $tag pat=$pat addr=$n hits=$hits"
}
run 4000ns
scan pre_preset /tb_p5_wrapper/u_dut/*
run 36000ns
scan mid /tb_p5_wrapper/u_dut/*
run 20000ns
scan hang /tb_p5_wrapper/u_dut/*
foreach sm {u_tx_arb u_mac_tx u_tcp_tx u_app u_app_pipe u_app_ctrl u_tcb u_cam u_tx_udp_arb} {
    scan hang_$sm /tb_p5_wrapper/u_dut/$sm/*
}
puts "PC txsrc_tready = [get_value -radix hex /tb_p5_wrapper/u_dut/txsrc_tready]"
puts "PC m_tx_tvalid  = [get_value -radix hex /tb_p5_wrapper/u_dut/m_tx_tvalid]"
exit 0
