# p3_wizard.tcl -- P7a gate 0, round 3.
#
# Round 2 findings (raw tool output in p2_vivado.log):
#   * enum params take STRINGS, not indices:
#       [IP_Flow 19-3461] ... Valid values are - 8B10B, 64B66B_ASYNC, ...
#       [IP_Flow 19-3461] ... (TX_PLL_TYPE) Valid values are - QPLL0, QPLL1
#       [IP_Flow 19-3461] ... (TX_OUTCLK_SOURCE) Valid values are - TXOUTCLKPMA,
#                                                        TXOUTCLKPCS, TXPROGDIVCLK
#   * the correct target name is 'example', not 'example_design':
#       [Vivado 12-1773] Supported targets for this IP are: all elaborate_boundary
#       block_model instantiation_template synthesis simulation example changelog
#   * TX/RX_REFCLK_SOURCE must agree per quad; RX defaults to clk1 on this device
#     but the board only has MGTREFCLK0 populated.
#
# Run: vivado -mode batch -source p3_wizard.tcl -nojournal -nolog

set outroot "D:/repo/XCKU5PMini/udp_hls_10g/_p7a_probe"
set part    "xcku5p-ffvb676-1-e"

proc sec {s} { puts "\nP3 >>>>>>>>>> $s" }
catch {set_param general.maxThreads 4}

sec "ENV"
puts "VIVADO = [version -short]"
file delete -force "$outroot/pj_wiz3"
create_project -force p3_wiz "$outroot/pj_wiz3" -part $part
set_property target_language Verilog [current_project]

create_ip -name gtwizard_ultrascale -vendor xilinx.com -library ip -module_name p3_gt
set gt [get_ips p3_gt]
puts "GT = $gt"

sec "CONFIGURE_ORDERED"
# order matters: channel -> refclk source -> refclk freq -> line rate -> encoding -> widths
set cfg [list \
    CONFIG.CHANNEL_ENABLE        {X0Y4 X0Y5} \
    CONFIG.TX_REFCLK_SOURCE      {X0Y4 clk0 X0Y5 clk0} \
    CONFIG.RX_REFCLK_SOURCE      {X0Y4 clk0 X0Y5 clk0} \
    CONFIG.TX_REFCLK_FREQUENCY   {156.25} \
    CONFIG.RX_REFCLK_FREQUENCY   {156.25} \
    CONFIG.TX_LINE_RATE          {10.3125} \
    CONFIG.RX_LINE_RATE          {10.3125} \
    CONFIG.TX_DATA_ENCODING      {64B66B_ASYNC} \
    CONFIG.RX_DATA_DECODING      {64B66B_ASYNC} \
    CONFIG.TX_INT_DATA_WIDTH     {64} \
    CONFIG.RX_INT_DATA_WIDTH     {64} \
    CONFIG.TX_USER_DATA_WIDTH    {64} \
    CONFIG.RX_USER_DATA_WIDTH    {64} \
    CONFIG.TX_BUFFER_MODE        {1} \
    CONFIG.RX_BUFFER_MODE        {1} \
    CONFIG.TX_PLL_TYPE           {QPLL0} \
    CONFIG.RX_PLL_TYPE           {QPLL0} \
    CONFIG.TX_OUTCLK_SOURCE      {TXPROGDIVCLK} \
    CONFIG.RX_OUTCLK_SOURCE      {RXPROGDIVCLK} \
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

sec "EFFECTIVE"
foreach k {CONFIG.TX_DATA_ENCODING CONFIG.RX_DATA_DECODING CONFIG.TX_INT_DATA_WIDTH \
           CONFIG.RX_INT_DATA_WIDTH CONFIG.TX_USER_DATA_WIDTH CONFIG.RX_USER_DATA_WIDTH \
           CONFIG.TX_BUFFER_MODE CONFIG.RX_BUFFER_MODE CONFIG.TX_PLL_TYPE CONFIG.RX_PLL_TYPE \
           CONFIG.TX_LINE_RATE CONFIG.RX_LINE_RATE \
           CONFIG.TX_REFCLK_FREQUENCY CONFIG.RX_REFCLK_FREQUENCY} {
    catch {puts "EFF $k = <[get_property $k $gt]>"}
}

sec "GENERATE_ALL"
set gr [catch {generate_target all $gt} e]
puts "GENERATE_TARGET_ALL rc = $gr"
if {$gr} { puts "ERR = $e" }
puts "IS_LOCKED = [get_property IS_LOCKED $gt]"
catch {puts "LOCK_DETAILS = [get_property LOCK_DETAILS $gt]"}
catch {puts "USED_LICENSE_KEYS = <[get_property USED_LICENSE_KEYS $gt]>"}
catch {puts "LICENSE_KEYS = <[get_property LICENSE_KEYS $gt]>"}

sec "EXAMPLE_TARGET"
set er [catch {generate_target example $gt} e]
puts "GENERATE_TARGET_EXAMPLE rc = $er"
if {$er} { puts "ERR = $e" }

sec "DONE"
close_project -quiet
