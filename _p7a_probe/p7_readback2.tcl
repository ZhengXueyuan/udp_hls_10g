# p7_readback2.tcl -- P7a gate 0, round 7: the decisive static evidence.
#
# Build TWO out-of-context GT wizard instances that differ ONLY in the data
# encoding (64B66B_ASYNC = 10GBASE-R vs RAW), synthesise and PLACE both, and
# read the gearbox attributes back off the placed netlist.
#
#   positive : TXGEARBOX_EN/RXGEARBOX_EN = TRUE, GEARBOX_MODE = 5'b10001
#   control  : TXGEARBOX_EN/RXGEARBOX_EN = FALSE
#
# If the control reads the same as the positive, the criterion has no power and
# the whole "prove the gearbox is in the path" plan has to be rebuilt.
#
# Run: vivado -mode batch -source p7_readback2.tcl -nojournal -nolog

set outroot "D:/repo/XCKU5PMini/udp_hls_10g/_p7a_probe"
set part    "xcku5p-ffvb676-1-e"
proc sec {s} { puts "\nP7 >>>>>>>>>> $s" }
catch {set_param general.maxThreads 4}

proc build_one {tag enc} {
    sec "BUILD_$tag encoding=$enc"
    file delete -force "$::outroot/rb_$tag"
    create_project -force "rb_$tag" "$::outroot/rb_$tag" -part $::part
    set_property target_language Verilog [current_project]
    create_ip -name gtwizard_ultrascale -vendor xilinx.com -library ip -module_name "gt_$tag"
    set ip [get_ips "gt_$tag"]
    set rc [catch {set_property -dict [dict create \
        CONFIG.CHANNEL_ENABLE        {X0Y4 X0Y5} \
        CONFIG.TX_DATA_ENCODING      $enc \
        CONFIG.RX_DATA_DECODING      $enc \
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
    ] $ip} e]
    puts "$tag CONFIG rc = $rc"
    if {$rc} { puts "$tag CONFIG_ERR = $e" }
    catch {puts "$tag TXPROGDIV_FREQ_VAL = <[get_property CONFIG.TXPROGDIV_FREQ_VAL $ip]>"}
    catch {puts "$tag TX_INT_DATA_WIDTH = <[get_property CONFIG.TX_INT_DATA_WIDTH $ip]>"}

    set sr [catch {synth_ip $ip} e]
    puts "$tag SYNTH rc = $sr"
    if {$sr} { puts "$tag SYNTH_ERR = $e"; close_project -quiet; return }

    set dcp "$::outroot/rb_$tag/rb_$tag.gen/sources_1/ip/gt_$tag/gt_$tag.dcp"
    puts "$tag DCP = <$dcp> exists=[file exists $dcp]"
    if {![file exists $dcp]} { close_project -quiet; return }

    close_project -quiet
    open_checkpoint $dcp
    set cells [get_cells -hier -quiet -filter {REF_NAME =~ GTYE4_CHANNEL*}]
    puts "$tag POST_SYNTH GT_CELLS = <$cells>"
    foreach c $cells {
        puts "$tag POST_SYNTH $c GEARBOX_MODE = <[get_property GEARBOX_MODE $c]>"
        puts "$tag POST_SYNTH $c TXGEARBOX_EN = <[get_property TXGEARBOX_EN $c]>"
        puts "$tag POST_SYNTH $c RXGEARBOX_EN = <[get_property RXGEARBOX_EN $c]>"
        puts "$tag POST_SYNTH $c TX_DATA_WIDTH = <[get_property TX_DATA_WIDTH $c]>"
        puts "$tag POST_SYNTH $c RX_DATA_WIDTH = <[get_property RX_DATA_WIDTH $c]>"
    }

    set pr [catch {place_design} e2]
    puts "$tag PLACE rc = $pr"
    if {$pr} { puts "$tag PLACE_ERR = $e2" }
    set cells2 [get_cells -hier -quiet -filter {REF_NAME =~ GTYE4_CHANNEL*}]
    puts "$tag POST_PLACE GT_CELLS = <$cells2>"
    foreach c $cells2 {
        puts "$tag POST_PLACE $c GEARBOX_MODE = <[get_property GEARBOX_MODE $c]>"
        puts "$tag POST_PLACE $c TXGEARBOX_EN = <[get_property TXGEARBOX_EN $c]>"
        puts "$tag POST_PLACE $c RXGEARBOX_EN = <[get_property RXGEARBOX_EN $c]>"
    }
    write_verilog -force "$::outroot/nl_$tag.v"
    puts "$tag NETLIST = $::outroot/nl_$tag.v"
}

build_one pos 64B66B_ASYNC
build_one raw RAW

sec "DONE"
