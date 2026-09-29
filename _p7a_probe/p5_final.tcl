# p5_final.tcl -- P7a gate 0, round 5: the recipe that actually works.
#
# Round 4 found that a param-by-param set of TX_REFCLK_FREQUENCY can NEVER
# succeed: while TX is being moved to 156.25 the RX side is still at the
# 64.453125 default, so the "RX and TX frequencies do not allow for PLL sharing"
# validation fires and the set is rolled back; setting RX afterwards then fails
# for the mirror reason.  Both must go in one atomic set_property -dict call.
#
# Also confirmed in round 4: TX_INT_DATA_WIDTH=64 is only accepted AFTER
# TX_USER_DATA_WIDTH=64.
#
# Run: vivado -mode batch -source p5_final.tcl -nojournal -nolog

set outroot "D:/repo/XCKU5PMini/udp_hls_10g/_p7a_probe"
set part    "xcku5p-ffvb676-1-e"
proc sec {s} { puts "\nP5 >>>>>>>>>> $s" }
catch {set_param general.maxThreads 4}

sec "ENV"
puts "VIVADO = [version -short]"
file delete -force "$outroot/pj_fin"
create_project -force p5_fin "$outroot/pj_fin" -part $part
set_property target_language Verilog [current_project]

create_ip -name gtwizard_ultrascale -vendor xilinx.com -library ip -module_name gt_10gbr
set gt [get_ips gt_10gbr]

sec "ATOMIC_DICT_SET"
# Everything in ONE call.  Ordering inside the dict still matters for the
# dependents (encoding -> user width -> int width), and refclk frequency for TX
# and RX must move together or neither moves at all.
set cfg [dict create \
    CONFIG.CHANNEL_ENABLE        {X0Y4 X0Y5} \
    CONFIG.TX_DATA_ENCODING      {64B66B_ASYNC} \
    CONFIG.RX_DATA_DECODING      {64B66B_ASYNC} \
    CONFIG.TX_USER_DATA_WIDTH    {64} \
    CONFIG.RX_USER_DATA_WIDTH    {64} \
    CONFIG.TX_INT_DATA_WIDTH     {64} \
    CONFIG.RX_INT_DATA_WIDTH     {64} \
    CONFIG.TX_BUFFER_MODE        {1} \
    CONFIG.RX_BUFFER_MODE        {1} \
    CONFIG.TX_LINE_RATE          {10.3125} \
    CONFIG.RX_LINE_RATE          {10.3125} \
    CONFIG.TX_PLL_TYPE           {QPLL0} \
    CONFIG.RX_PLL_TYPE           {QPLL0} \
    CONFIG.TX_REFCLK_SOURCE      {X0Y4 clk0 X0Y5 clk0} \
    CONFIG.RX_REFCLK_SOURCE      {X0Y4 clk0 X0Y5 clk0} \
    CONFIG.TX_REFCLK_FREQUENCY   {156.25} \
    CONFIG.RX_REFCLK_FREQUENCY   {156.25} \
    CONFIG.TX_OUTCLK_SOURCE      {TXPROGDIVCLK} \
    CONFIG.RX_OUTCLK_SOURCE      {RXPROGDIVCLK} \
    CONFIG.LOCATE_RESET_CONTROLLER       {CORE} \
    CONFIG.LOCATE_TX_USER_CLOCKING       {CORE} \
    CONFIG.LOCATE_RX_USER_CLOCKING       {CORE} \
    CONFIG.LOCATE_COMMON                 {CORE} \
    CONFIG.LOCATE_USER_DATA_WIDTH_SIZING {CORE} \
]
set rc [catch {set_property -dict $cfg $gt} e]
puts "ATOMIC_SET rc = $rc"
if {$rc} { puts "ATOMIC_SET ERR = $e" }

sec "EFFECTIVE_FINAL"
foreach k {CONFIG.TX_DATA_ENCODING CONFIG.RX_DATA_DECODING CONFIG.TX_INT_DATA_WIDTH \
           CONFIG.RX_INT_DATA_WIDTH CONFIG.TX_USER_DATA_WIDTH CONFIG.RX_USER_DATA_WIDTH \
           CONFIG.TX_BUFFER_MODE CONFIG.RX_BUFFER_MODE CONFIG.TX_PLL_TYPE CONFIG.RX_PLL_TYPE \
           CONFIG.TX_LINE_RATE CONFIG.RX_LINE_RATE \
           CONFIG.TX_REFCLK_FREQUENCY CONFIG.RX_REFCLK_FREQUENCY \
           CONFIG.TX_OUTCLK_SOURCE CONFIG.RX_OUTCLK_SOURCE} {
    catch {puts "EFF $k = <[get_property $k $gt]>"}
}

sec "GENERATE"
puts "GENERATE_ALL rc = [catch {generate_target all $gt} e]"
puts "IS_LOCKED = [get_property IS_LOCKED $gt]"
catch {puts "LOCK_DETAILS = [get_property LOCK_DETAILS $gt]"}
catch {puts "USED_LICENSE_KEYS = <[get_property USED_LICENSE_KEYS $gt]>"
}
puts "EXAMPLE_TARGET rc = [catch {generate_target example $gt} e2]"

sec "DONE"
close_project -quiet
