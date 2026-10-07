set dcp "D:/repo/XCKU5PMini/udp_hls_10g/vivado_prj/p7b_ku5p_prj.runs/impl_1/wrapper_p4_routed.dcp"
open_checkpoint $dcp
puts "QD_OPENED = 1"
foreach pin {u_app/stat_mismatch_reg[31]/D u_app/rx_lfsr_reg[57]/D} {
    set pth [get_timing_paths -delay_type max -to $pin -max_paths 1 -quiet]
    if {[llength $pth] == 0} { puts "QD $pin NOPATH"; continue }
    puts "QD $pin slack=[get_property SLACK $pth] LL=[get_property LOGIC_LEVELS $pth] delay=[get_property DATAPATH_DELAY $pth] logic=[get_property DATAPATH_LOGIC_DELAY $pth] route=[get_property DATAPATH_NET_DELAY $pth] src=[get_property STARTPOINT_PIN $pth]"
}
puts "QD_DONE"
