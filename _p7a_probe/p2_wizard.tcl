# p2_wizard.tcl -- P7a gate 0, round 2.
#
# Round 1 (p1_wizard.tcl) established, from raw tool output:
#   * gtwizard_ultrascale 1.7 supports xcku5p-ffvb676-1-e
#   * there is NO 'CONFIG.TX_PROTOCOL' parameter  ([Vivado 12-4371])
#   * CONFIG.LOCATE_* take CORE|EXAMPLE_DESIGN, not 0|1
#
# So the 10GBASE-R preset is a GUI-only convenience: in Tcl the equivalent is
# to set the GT primitive parameters directly, exactly as the bundled
# xxv_ethernet IP does internally (verified against its generated ip_0/*_gt.xci).
# This round applies that and measures the result.
#
# Run: vivado -mode batch -source p2_wizard.tcl -nojournal -nolog

set outroot "D:/repo/XCKU5PMini/udp_hls_10g/_p7a_probe"
set part    "xcku5p-ffvb676-1-e"

proc sec {s} { puts "\nP2 >>>>>>>>>> $s" }
catch {set_param general.maxThreads 4}

sec "ENV"
puts "VIVADO = [version -short]"

file delete -force "$outroot/pj_wiz2"
create_project -force p2_wiz "$outroot/pj_wiz2" -part $part
set_property target_language Verilog [current_project]

# ==================================================================== CONTROL
# Same-session positive control for the license readout: xxv_ethernet is the
# IP that the project already determined to be license-gated, so if the
# readout below cannot see THAT, it has no power to clear gtwizard.
sec "CONTROL_XXV_ETHERNET"
create_ip -name xxv_ethernet -vendor xilinx.com -library ip -version 5.0 -module_name p2_ctl
set ctl [get_ips p2_ctl]
set_property -dict [list \
    CONFIG.LINE_RATE {10} CONFIG.CLOCKING {Asynchronous} CONFIG.BASE_R_KR {BASE-R} \
    CONFIG.GT_TYPE {GTY} CONFIG.GT_REF_CLK_FREQ {156.25} CONFIG.INCLUDE_SHARED_LOGIC {1} ] $ctl
set_property CONFIG.CORE {Ethernet PCS/PMA 64-bit} $ctl
puts "CTL_LINE_RATE   = <[get_property CONFIG.LINE_RATE $ctl]>"
puts "CTL_IS_LOCKED   = [get_property IS_LOCKED $ctl]"
catch {puts "CTL_USED_LICENSE_KEYS = [get_property USED_LICENSE_KEYS $ctl]"}
catch {puts "CTL_LOCK_DETAILS      = [get_property LOCK_DETAILS $ctl]"}
catch {puts "CTL_USED_LIC_KEYS_ATTR= [get_property USED_LICENSE_KEYS $ctl]"}
catch {generate_target all $ctl}
puts "CTL_IS_LOCKED_AFTER_GEN = [get_property IS_LOCKED $ctl]"

# ==================================================================== SUBJECT
sec "SUBJECT_GTWIZARD_10GBASE-R"
create_ip -name gtwizard_ultrascale -vendor xilinx.com -library ip -module_name p2_gt
set gt [get_ips p2_gt]

# Allowed-value readout straight from the tool, for the params that carry the
# protocol semantics.
foreach p {CONFIG.TX_DATA_ENCODING CONFIG.RX_DATA_DECODING CONFIG.TX_PLL_TYPE \
           CONFIG.TX_BUFFER_MODE CONFIG.TX_USER_CLOCKING_SOURCE \
           CONFIG.RX_USER_CLOCKING_SOURCE CONFIG.TX_OUTCLK_SOURCE CONFIG.RX_OUTCLK_SOURCE \
           CONFIG.LOCATE_COMMON CONFIG.LOCATE_RESET_CONTROLLER \
           CONFIG.INCLUDE_CPLL_CAL CONFIG.RX_SLIDE_MODE} {
    set r [catch {set v [list_property_value $p $gt]} e]
    if {$r} { puts "ALLOWED $p = <(not an enum / err)>" } else { puts "ALLOWED $p = <$v>" }
}

# 10GBASE-R == 64B66B_ASYNC (encoding 4) with a 64-bit internal datapath and
# the TX/RX buffer enabled.  Numbers taken from the DEFINE block that the
# wizard itself emits in *_gtwizard_gtye4.v, not from memory.
set cfg [list \
    CONFIG.CHANNEL_ENABLE           {X0Y4 X0Y5} \
    CONFIG.TX_LINE_RATE             {10.3125} \
    CONFIG.RX_LINE_RATE             {10.3125} \
    CONFIG.TX_REFCLK_FREQUENCY      {156.25} \
    CONFIG.RX_REFCLK_FREQUENCY      {156.25} \
    CONFIG.TX_DATA_ENCODING         {4} \
    CONFIG.RX_DATA_DECODING         {4} \
    CONFIG.TX_INT_DATA_WIDTH        {64} \
    CONFIG.RX_INT_DATA_WIDTH        {64} \
    CONFIG.TX_USER_DATA_WIDTH       {64} \
    CONFIG.RX_USER_DATA_WIDTH       {64} \
    CONFIG.TX_BUFFER_MODE           {1} \
    CONFIG.RX_BUFFER_MODE           {1} \
    CONFIG.TX_PLL_TYPE              {0} \
    CONFIG.RX_PLL_TYPE              {0} \
    CONFIG.TX_USER_CLOCKING_SOURCE  {2} \
    CONFIG.RX_USER_CLOCKING_SOURCE  {0} \
    CONFIG.TX_OUTCLK_SOURCE         {2} \
    CONFIG.RX_OUTCLK_SOURCE         {0} \
    CONFIG.LOCATE_RESET_CONTROLLER  {CORE} \
    CONFIG.LOCATE_TX_USER_CLOCKING  {CORE} \
    CONFIG.LOCATE_RX_USER_CLOCKING  {CORE} \
    CONFIG.LOCATE_COMMON            {CORE} \
    CONFIG.LOCATE_USER_DATA_WIDTH_SIZING {CORE} \
]
foreach {k v} $cfg {
    set rc [catch {set_property $k $v $gt} e]
    if {$rc} { puts "SET $k = <$v> => FAIL : $e" } else { puts "SET $k = <$v> => OK" }
}

foreach k {CONFIG.TX_DATA_ENCODING CONFIG.RX_DATA_DECODING CONFIG.TX_INT_DATA_WIDTH \
           CONFIG.RX_INT_DATA_WIDTH CONFIG.TX_USER_DATA_WIDTH CONFIG.RX_USER_DATA_WIDTH \
           CONFIG.TX_BUFFER_MODE CONFIG.RX_BUFFER_MODE CONFIG.TX_PLL_TYPE CONFIG.RX_PLL_TYPE \
           CONFIG.TX_LINE_RATE CONFIG.RX_LINE_RATE \
           CONFIG.TX_REFCLK_FREQUENCY CONFIG.RX_REFCLK_FREQUENCY \
           CONFIG.TX_OUTCLK_FREQUENCY CONFIG.RX_OUTCLK_FREQUENCY \
           CONFIG.TX_USRCLK_FREQUENCY CONFIG.TX_USRCLK2_FREQUENCY \
           CONFIG.RX_USRCLK_FREQUENCY CONFIG.RX_USRCLK2_FREQUENCY \
           CONFIG.CPLL_VCO_FREQUENCY CONFIG.TXPROGDIV_FREQ_VAL} {
    catch {puts "EFF $k = <[get_property $k $gt]>"}
}

sec "GENERATE"
set gr [catch {generate_target all $gt} e]
puts "GENERATE_TARGET_ALL rc = $gr"
if {$gr} { puts "GENERATE_ERR = $e" }
puts "GT_IS_LOCKED_AFTER_GENERATE = [get_property IS_LOCKED $gt]"
catch {puts "GT_LOCK_DETAILS      = [get_property LOCK_DETAILS $gt]"}
catch {puts "GT_USED_LICENSE_KEYS = [get_property USED_LICENSE_KEYS $gt]"}

sec "TARGET_NAMES"
foreach t {example_design testbench synthesis simulation} {
    set r [catch {generate_target $t $gt} e]
    puts "TARGET $t rc = $r"
    if {$r} { puts "   ERR: $e" }
}

sec "DONE"
close_project -quiet
