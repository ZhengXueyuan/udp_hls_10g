# p6_readback.tcl -- P7a gate 0, round 6: prove the gearbox configuration is
#                    readable back out of a real netlist, not just out of the
#                    GUI/xci.  This is the "static evidence" leg of the gearbox
#                    proof, so it has to run on a synthesised design object.
#
# Run: vivado -mode batch -source p6_readback.tcl -nojournal -nolog

set outroot "D:/repo/XCKU5PMini/udp_hls_10g/_p7a_probe"
set part    "xcku5p-ffvb676-1-e"
proc sec {s} { puts "\nP6 >>>>>>>>>> $s" }
catch {set_param general.maxThreads 4}

file delete -force "$outroot/pj_rb"
create_project -force p6_rb "$outroot/pj_rb" -part $part
set_property target_language Verilog [current_project]
create_ip -name gtwizard_ultrascale -vendor xilinx.com -library ip -module_name gt_rb
set gt [get_ips gt_rb]
set_property -dict [dict create \
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
] $gt
generate_target all $gt

sec "CLOCK_PARAMS"
foreach k {CONFIG.TXPROGDIV_FREQ_ENABLE CONFIG.TXPROGDIV_FREQ_SOURCE \
           CONFIG.TXPROGDIV_FREQ_VAL CONFIG.TX_OUTCLK_BUFG_GT_DIV \
           CONFIG.TX_USER_CLOCKING_RATIO_FUSRCLK_FUSRCLK2 \
           CONFIG.RX_USER_CLOCKING_RATIO_FUSRCLK_FUSRCLK2 \
           CONFIG.FREERUN_FREQUENCY CONFIG.CPLL_VCO_FREQUENCY} {
    catch {puts "CLK $k = <[get_property $k $gt]>"}
}

sec "OOC_SYNTH"
set sr [catch {synth_ip $gt} e]
puts "SYNTH_IP rc = $sr"
if {$sr} { puts "SYNTH_ERR = $e" }

sec "READBACK_FROM_SYNTH_DCP"
set dcp [glob -nocomplain "$outroot/pj_rb/*.runs/*/gt_rb.dcp"]
puts "DCP = <$dcp>"
if {[llength $dcp] > 0} {
    open_checkpoint [lindex $dcp 0]
    set cells [get_cells -hier -quiet -filter {REF_NAME =~ GTYE4_CHANNEL*}]
    puts "GT_CELLS = <$cells>"
    foreach c $cells {
        puts "CELL $c"
        foreach p {GEARBOX_MODE TXGEARBOX_EN RXGEARBOX_EN TX_DATA_WIDTH RX_DATA_WIDTH \
                   TX_INT_DATAWIDTH RX_INT_DATAWIDTH TXBUF_EN RXBUF_EN RXSLIDE_MODE \
                   TX_DATA_ENCODING} {
            catch {puts "   PROP $p = <[get_property $p $c]>"}
        }
        puts "   ALLPROPS = [lsort [list_property $c]]"
    }
    write_verilog -force "$outroot/rb_netlist.v"
    puts "NETLIST_WRITTEN"
}

sec "DONE"
close_project -quiet
