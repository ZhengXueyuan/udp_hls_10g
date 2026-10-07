# newcone_query.tcl -- Stage B build: measure the NEW app_pattern RX-8way cone.
# Read-only on the routed checkpoint. No programming, no writes to rtl/.
# Q1: independent worst-N DP-domain (g_hw.clk_out0 -> g_hw.clk_out0) setup list,
#     to answer "did the new cone enter the DP top 10".
# Q2: targeted per-endpoint worst setup slack at the new registers:
#     u_app/stat_mismatch_reg[*]/D, u_app/stat_rx_bytes_reg[*]/D, u_app/rx_lfsr_reg[*]/D
set dcp "D:/repo/XCKU5PMini/udp_hls_10g/vivado_prj/p7b_ku5p_prj.runs/impl_1/wrapper_p4_routed.dcp"
open_checkpoint $dcp
puts "QC_OPENED = 1"

puts "QC_SECTION = Q1_WORST_DP_SETUP"
set paths [get_timing_paths -delay_type max -from [get_clocks g_hw.clk_out0] -to [get_clocks g_hw.clk_out0] -max_paths 40 -quiet]
set i 0
foreach p $paths {
    incr i
    set sl  [get_property SLACK $p]
    set src [get_property STARTPOINT_PIN $p]
    set dst [get_property ENDPOINT_PIN $p]
    set lv  [get_property LOGIC_LEVELS $p]
    puts "QC_DPTOP $i slack=$sl LL=$lv SRC=$src DST=$dst"
}

puts "QC_SECTION = Q2_NEWCONE_ENDPOINTS"
set fams {stat_mismatch_reg stat_rx_bytes_reg rx_lfsr_reg}
foreach fam $fams {
    set pins [get_pins -quiet u_app/${fam}\[*\]/D]
    set worst 999.0
    set worst_dbg ""
    set n 0
    foreach p $pins {
        incr n
        set pth [get_timing_paths -delay_type max -to $p -max_paths 1 -quiet]
        if {[llength $pth] == 0} { continue }
        set sl [get_property SLACK $pth]
        set src [get_property STARTPOINT_PIN $pth]
        set lv [get_property LOGIC_LEVELS $pth]
        if {$sl < $worst} { set worst $sl ; set worst_dbg "pin=$p slack=$sl LL=$lv src=$src" }
    }
    puts "QC_FAM $fam ndpins=$n worst_ns=$worst  | $worst_dbg"
}
puts "QC_DONE"
