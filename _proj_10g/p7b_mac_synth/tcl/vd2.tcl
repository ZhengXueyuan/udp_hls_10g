set B "D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/p7b_mac_synth"
open_checkpoint "$B/xxv_mac/pcs64_2ch/pcs64_2ch.runs/impl_1/xxv_mac_top_routed.dcp"
proc netclk {n} {
    set nets [get_nets -hier -quiet -filter "NAME =~ *${n}"]
    puts "NET $n found=[llength $nets]"
    foreach nn $nets {
        foreach p [get_pins -quiet -of_objects $nn] {
            set cc [get_clocks -quiet -of_objects $p]
            if {[llength $cc]} { puts "   $nn  pin=$p  clk=$cc" }
        }
    }
}
netclk tx_mii_d_1
netclk tx_mii_c_1
netclk rx_mii_d_1
netclk rx_mii_c_1
netclk user_tx_reset_1
netclk user_rx_reset_1
netclk tx_mii_clk_1
netclk rx_clk_out_1
puts "VD2_DONE"
