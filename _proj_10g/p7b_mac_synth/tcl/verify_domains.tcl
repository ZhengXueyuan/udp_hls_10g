# ============================================================================
# verify_domains.tcl -- PART 3: read the clock domains back out of the ROUTED
#   PCS+MAC design instead of assuming them.
#
#   Questions:
#     1. which clock do the MAC's own registers run on?
#     2. which clock does the PCS use to CAPTURE tx_mii_d_1 / tx_mii_c_1
#        (the MAC's XGMII output) -- is it the same one the MAC transmits on?
#     3. which clock DRIVES rx_mii_d_1 / rx_mii_c_1 (the MAC's XGMII input) --
#        is it the same one the MAC receives on?
#     4. is `user_tx_reset_1` / `user_rx_reset_1` in the domain the MAC assumes
#        when it wires rst_n = ~user_*_reset_1 ?
#   A mismatch in 2/3 would be a real defect: the XGMII would be crossing a
#   clock boundary that the MAC's design assumes does not exist.
# ============================================================================

set B "D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/p7b_mac_synth"
catch {set_param general.maxThreads 8}

open_checkpoint "$B/xxv_mac/pcs64_2ch/pcs64_2ch.runs/impl_1/xxv_mac_top_routed.dcp"
puts "TOP = [get_property top [current_design]]"
puts "PART = [get_property PART [current_design]]"

proc clkof {label cellpath} {
    set c [get_cells -quiet $cellpath]
    if {[llength $c] == 0} { puts "DOM_${label} = <cell not found: $cellpath>" ; return }
    set p [get_pins -quiet "$cellpath/C"]
    if {[llength $p] == 0} { set p [get_pins -quiet "$cellpath/CLK"] }
    if {[llength $p] == 0} { puts "DOM_${label} = <no clock pin on $cellpath>" ; return }
    set clk [get_clocks -quiet -of_objects $p]
    puts "DOM_${label} = $clk    (cell $cellpath pin [get_property REF_PIN_NAME [lindex $p 0]])"
}

# ---- 1. the MAC's own flops -------------------------------------------------
proc anyreg {inst} {
    set cs [get_cells -quiet -hier -filter "NAME =~ ${inst}/* && IS_SEQUENTIAL"]
    if {[llength $cs] == 0} { return "<none>" }
    return [lindex $cs 0]
}

foreach inst {u_mac_tx u_mac_rx} {
    set c [anyreg $inst]
    puts "MACREG_$inst = $c"
    set p [get_pins -quiet "$c/CLK"]
    if {[llength $p] == 0} { set p [get_pins -quiet "$c/C"] }
    puts "MACCLK_$inst = [get_clocks -quiet -of_objects $p]"
}
puts "MACREG_u_mac_tx_crc = [anyreg u_mac_tx/u_crc]"
puts "MACREG_u_mac_rx_crc = [anyreg u_mac_rx/u_crc]"

# ---- 2. who captures tx_mii_d_1 / tx_mii_c_1 ? ------------------------------
# the MAC drives tx_mii_d_1; the PCS must capture it in the SAME domain.
set txd_loads [get_pins -quiet -of_objects [get_nets -quiet tx_mii_d_1]]
puts "TXD_NET_LOADS_N = [llength $txd_loads]"
set seen {}
foreach p $txd_loads {
    set cc [get_clocks -quiet -of_objects $p]
    if {[llength $cc]} { lappend seen [list $cc $p] }
}
puts "TXD_CAPTURE_CLOCKS:"
foreach e $seen { puts "  TXD_LOAD clk=[lindex $e 0] pin=[lindex $e 1]" }
set txc_loads [get_pins -quiet -of_objects [get_nets -quiet tx_mii_c_1]]
foreach p $txc_loads {
    set cc [get_clocks -quiet -of_objects $p]
    if {[llength $cc]} { puts "  TXC_LOAD clk=$cc pin=$p" }
}

# ---- 3. who drives rx_mii_d_1 / rx_mii_c_1 ? --------------------------------
set rxd_drv [get_pins -quiet -of_objects [get_nets -quiet rx_mii_d_1]]
puts "RXD_NET_DRIVERS_N = [llength $rxd_drv]"
foreach p $rxd_drv {
    set cc [get_clocks -quiet -of_objects $p]
    if {[llength $cc]} { puts "  RXD_DRIVER clk=$cc pin=$p" }
}
set rxc_drv [get_pins -quiet -of_objects [get_nets -quiet rx_mii_c_1]]
foreach p $rxc_drv {
    set cc [get_clocks -quiet -of_objects $p]
    if {[llength $cc]} { puts "  RXC_DRIVER clk=$cc pin=$p" }
}

# ---- 4. the reset signals the MAC uses as rst_n -----------------------------
foreach n {user_tx_reset_1 user_rx_reset_1} {
    set d [get_pins -quiet -of_objects [get_nets -quiet $n]]
    puts "RSTNET_$n loads=[llength $d]"
    foreach p $d {
        set cc [get_clocks -quiet -of_objects $p]
        if {[llength $cc]} { puts "  RSTLOAD $n clk=$cc pin=$p" }
    }
}

# ---- 5. all clocks and the async groups in force ----------------------------
puts "ALLCLOCKS = [get_clocks]"
foreach c [get_clocks] { puts "CLK $c period=[get_property PERIOD $c]" }

puts "DOMAIN_VERIFY_DONE"
