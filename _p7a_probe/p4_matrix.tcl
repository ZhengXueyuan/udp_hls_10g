# p4_matrix.tcl -- P7a gate 0, round 4: find the parameter ORDER/FORM that the
#                  standalone gtwizard_ultrascale 1.7 accepts for a 10GBASE-R
#                  (64b/66b gearbox) channel on xcku5p-ffvb676-1-e.
#
# Round 3 established the enum spellings but two params would not take:
#   TX_INT_DATA_WIDTH = 64 -> [IP_Flow 19-3461] "Valid values are - 32"
#   TX/RX_REFCLK_FREQUENCY -> RX_REFCLK_SOURCE would not leave its clk1 default
# So this round brute-forces order and spelling and reports what actually sticks.
#
# Run: vivado -mode batch -source p4_matrix.tcl -nojournal -nolog

set outroot "D:/repo/XCKU5PMini/udp_hls_10g/_p7a_probe"
set part    "xcku5p-ffvb676-1-e"
proc sec {s} { puts "\nP4 >>>>>>>>>> $s" }
catch {set_param general.maxThreads 4}

proc try_variant {tag cfg} {
    sec "VARIANT $tag"
    file delete -force "$::outroot/v_$tag"
    if {[catch {create_project -force "v_$tag" "$::outroot/v_$tag" -part $::part} e]} {
        puts "$tag CREATE_PROJECT_FAIL = $e"; return
    }
    set_property target_language Verilog [current_project]
    if {[catch {create_ip -name gtwizard_ultrascale -vendor xilinx.com -library ip \
                     -module_name "g_$tag"} e]} {
        puts "$tag CREATE_IP_FAIL = $e"; close_project -quiet; return
    }
    set ip [get_ips "g_$tag"]
    foreach {k v} $cfg {
        set rc [catch {set_property $k $v $ip} e]
        if {$rc} { puts "$tag SET $k <$v> FAIL" } else { puts "$tag SET $k <$v> OK" }
    }
    foreach k {CONFIG.TX_DATA_ENCODING CONFIG.RX_DATA_DECODING CONFIG.TX_INT_DATA_WIDTH \
               CONFIG.RX_INT_DATA_WIDTH CONFIG.TX_USER_DATA_WIDTH CONFIG.RX_USER_DATA_WIDTH \
               CONFIG.TX_BUFFER_MODE CONFIG.RX_BUFFER_MODE CONFIG.TX_LINE_RATE \
               CONFIG.TX_REFCLK_FREQUENCY CONFIG.RX_REFCLK_FREQUENCY} {
        catch {puts "$tag EFF $k = <[get_property $k $ip]>"}
    }
    set gr [catch {generate_target all $ip} e]
    puts "$tag GENERATE rc = $gr"
    puts "$tag IS_LOCKED = [get_property IS_LOCKED $ip]"
    catch {puts "$tag USED_LICENSE_KEYS = <[get_property USED_LICENSE_KEYS $ip]>"}
    close_project -quiet
}

# ---------------------------------------------------------------- variant A
# encoding first, then USER width, then INT width; refclk source per channel,
# TX and RX both spelled out as a flat key/value list.
try_variant A [list \
    CONFIG.CHANNEL_ENABLE     {X0Y4 X0Y5} \
    CONFIG.TX_DATA_ENCODING   {64B66B_ASYNC} \
    CONFIG.RX_DATA_DECODING   {64B66B_ASYNC} \
    CONFIG.TX_USER_DATA_WIDTH {64} \
    CONFIG.RX_USER_DATA_WIDTH {64} \
    CONFIG.TX_INT_DATA_WIDTH  {64} \
    CONFIG.RX_INT_DATA_WIDTH  {64} \
    CONFIG.TX_BUFFER_MODE     {1} \
    CONFIG.RX_BUFFER_MODE     {1} \
    CONFIG.TX_LINE_RATE       {10.3125} \
    CONFIG.RX_LINE_RATE       {10.3125} \
    CONFIG.TX_REFCLK_SOURCE   {X0Y4 clk0 X0Y5 clk0} \
    CONFIG.RX_REFCLK_SOURCE   {X0Y4 clk0 X0Y5 clk0} \
    CONFIG.TX_REFCLK_FREQUENCY {156.25} \
    CONFIG.RX_REFCLK_FREQUENCY {156.25} \
]

# ---------------------------------------------------------------- variant B
# same but refclk source given as a LIST OF PAIRS, one per channel.
try_variant B [list \
    CONFIG.CHANNEL_ENABLE     {X0Y4 X0Y5} \
    CONFIG.TX_DATA_ENCODING   {64B66B_ASYNC} \
    CONFIG.RX_DATA_DECODING   {64B66B_ASYNC} \
    CONFIG.TX_USER_DATA_WIDTH {64} \
    CONFIG.RX_USER_DATA_WIDTH {64} \
    CONFIG.TX_INT_DATA_WIDTH  {64} \
    CONFIG.RX_INT_DATA_WIDTH  {64} \
    CONFIG.TX_BUFFER_MODE     {1} \
    CONFIG.RX_BUFFER_MODE     {1} \
    CONFIG.TX_LINE_RATE       {10.3125} \
    CONFIG.RX_LINE_RATE       {10.3125} \
    CONFIG.TX_REFCLK_SOURCE   {X0Y4 clk0} \
    CONFIG.RX_REFCLK_SOURCE   {X0Y4 clk0} \
    CONFIG.TX_REFCLK_FREQUENCY {156.25} \
    CONFIG.RX_REFCLK_FREQUENCY {156.25} \
]

# ---------------------------------------------------------------- variant C
# no REFCLK_SOURCE at all -- only the frequency.  Does the wizard pick a legal
# source by itself?
try_variant C [list \
    CONFIG.CHANNEL_ENABLE     {X0Y4 X0Y5} \
    CONFIG.TX_DATA_ENCODING   {64B66B_ASYNC} \
    CONFIG.RX_DATA_DECODING   {64B66B_ASYNC} \
    CONFIG.TX_USER_DATA_WIDTH {64} \
    CONFIG.RX_USER_DATA_WIDTH {64} \
    CONFIG.TX_INT_DATA_WIDTH  {64} \
    CONFIG.RX_INT_DATA_WIDTH  {64} \
    CONFIG.TX_BUFFER_MODE     {1} \
    CONFIG.RX_BUFFER_MODE     {1} \
    CONFIG.TX_REFCLK_FREQUENCY {156.25} \
    CONFIG.RX_REFCLK_FREQUENCY {156.25} \
]

# ---------------------------------------------------------------- variant D
# INT width left at 32 while USER width is 64 (= the "32-bit internal 64b66b"
# shape that the bundled 32-bit MAC+PCS/PMA core uses).  If THIS is the only
# shape the standalone wizard allows, that is an important design constraint.
try_variant D [list \
    CONFIG.CHANNEL_ENABLE     {X0Y4 X0Y5} \
    CONFIG.TX_DATA_ENCODING   {64B66B_ASYNC} \
    CONFIG.RX_DATA_DECODING   {64B66B_ASYNC} \
    CONFIG.TX_USER_DATA_WIDTH {64} \
    CONFIG.RX_USER_DATA_WIDTH {64} \
    CONFIG.TX_BUFFER_MODE     {1} \
    CONFIG.RX_BUFFER_MODE     {1} \
    CONFIG.TX_REFCLK_FREQUENCY {156.25} \
    CONFIG.RX_REFCLK_FREQUENCY {156.25} \
]

sec "DONE"
