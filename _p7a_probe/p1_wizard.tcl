# p1_wizard.tcl -- P7a gate 0: is gtwizard_ultrascale usable, free, and does it
#                  expose a 10GBASE-R (64b/66b gearbox) configuration for
#                  xcku5p-ffvb676-1-e?
#
# Run:  vivado -mode batch -source p1_wizard.tcl -nojournal -nolog
# Output is entirely on stdout so it can be pasted as raw evidence.

set outroot "D:/repo/XCKU5PMini/udp_hls_10g/_p7a_probe"
set part    "xcku5p-ffvb676-1-e"

proc sec {s} { puts "\nP1 >>>>>>>>>> $s" }
catch {set_param general.maxThreads 4}

sec "ENV"
puts "VIVADO = [version -short]"
puts "LIC_XILINX = [file exists C:/AMDDesignTools/2025.2/data/ip/core_licenses/Xilinx.lic]"
puts "LIC_FREE   = [file exists C:/AMDDesignTools/2025.2/data/ip/core_licenses/XilinxFree.lic]"

# ------------------------------------------------------------------ create project first
# get_ipdefs needs an open project ([Common 17-53] otherwise).
sec "CREATE_PROJECT"
file delete -force "$outroot/pj_wiz"
create_project -force p1_wiz "$outroot/pj_wiz" -part $part
set_property target_language Verilog [current_project]

# ------------------------------------------------------------------ ipdef lookup
sec "IPDEF_LOOKUP"
puts "CMD: get_ipdefs -filter {NAME == gtwizard_ultrascale}"
set rc [catch {set defs [get_ipdefs -filter {NAME == gtwizard_ultrascale}]} e]
puts "RC = $rc"
puts "IPDEFS = <$defs>"
puts "COUNT = [llength $defs]"
foreach d $defs {
    puts "IPDEF_VLN = [get_property VLNV $d]"
    catch {puts "IPDEF_NAME = [get_property NAME $d]"}
    catch {puts "IPDEF_VER  = [get_property VERSION $d]"}
    catch {puts "IPDEF_LIC  = [get_property LICENSE $d]"}
    catch {puts "IPDEF_LICKEYS = [get_property LICENSE_KEYS $d]"}
    catch {puts "IPDEF_SUPPORTED_PARTS = [get_property SUPPORTED_PARTS $d]"}
    catch {puts "IPDEF_PRODUCT = [get_property PRODUCT $d]"}
    catch {puts "IPDEF_PRODUCT_CATEGORY = [get_property PRODUCT_CATEGORY $d]"}
    # is this part in the supported family list?
    set fam [get_property SUPPORTED_FAMILIES $d]
    puts "IPDEF_SUPPORTED_FAMILIES = <$fam>"
}

# ------------------------------------------------------------------ create ip
sec "CREATE_IP"
create_ip -name gtwizard_ultrascale -vendor xilinx.com -library ip -module_name p1_gt
set ip [get_ips p1_gt]
puts "IP = $ip"
puts "IS_LOCKED_AT_CREATE = [get_property IS_LOCKED $ip]"
catch {puts "USED_LICENSE_KEYS_AT_CREATE = [get_property USED_LICENSE_KEYS $ip]"}
catch {puts "CORE_CONTAINER = [get_property CORE_CONTAINER $ip]"}

# ------------------------------------------------------------------ protocol options
sec "PROTOCOL_OPTIONS"
foreach p {CONFIG.TX_PROTOCOL CONFIG.RX_PROTOCOL CONFIG.TX_DATA_ENCODING CONFIG.RX_DATA_DECODING \
           CONFIG.TX_USER_DATA_WIDTH CONFIG.TX_INT_DATA_WIDTH CONFIG.TX_BUFFER_MODE \
           CONFIG.TX_LINE_RATE CONFIG.TX_REFCLK_FREQUENCY CONFIG.CHANNEL_ENABLE \
           CONFIG.TX_PLL_TYPE CONFIG.TX_OUTCLK_SOURCE} {
    set r [catch {set vals [list_property_value $p $ip]} e]
    if {$r} { puts "ALLOWED $p = <ERR: $e>" } else { puts "ALLOWED $p = <$vals>" }
}

# ------------------------------------------------------------------ configure 10GBASE-R
sec "CONFIGURE_10GBASE-R"
set cfg [list \
    CONFIG.CHANNEL_ENABLE            {X0Y4} \
    CONFIG.TX_LINE_RATE              {10.3125} \
    CONFIG.RX_LINE_RATE              {10.3125} \
    CONFIG.TX_REFCLK_FREQUENCY       {156.25} \
    CONFIG.RX_REFCLK_FREQUENCY       {156.25} \
    CONFIG.TX_REFCLK_SOURCE          {MGTREFCLK0_Q225} \
    CONFIG.RX_REFCLK_SOURCE          {MGTREFCLK0_Q225} \
    CONFIG.TX_PROTOCOL               {10GBASE-R} \
    CONFIG.RX_PROTOCOL               {10GBASE-R} \
    CONFIG.TX_USER_DATA_WIDTH        {64} \
    CONFIG.RX_USER_DATA_WIDTH        {64} \
    CONFIG.TX_BUFFER_MODE            {1} \
    CONFIG.RX_BUFFER_MODE            {1} \
    CONFIG.LOCATE_RESET_CONTROLLER   {0} \
    CONFIG.LOCATE_TX_USER_CLOCKING   {0} \
    CONFIG.LOCATE_RX_USER_CLOCKING   {0} \
    CONFIG.LOCATE_COMMON             {0} \
    CONFIG.LOCATE_USER_DATA_WIDTH_SIZING {0} \
]
foreach {k v} $cfg {
    set rc [catch {set_property $k $v $ip} e]
    if {$rc} { puts "SET $k = <$v> => FAIL : $e" } else { puts "SET $k = <$v> => OK" }
}
foreach k {CONFIG.TX_PROTOCOL CONFIG.RX_PROTOCOL CONFIG.TX_DATA_ENCODING CONFIG.RX_DATA_DECODING \
           CONFIG.TX_USER_DATA_WIDTH CONFIG.TX_INT_DATA_WIDTH CONFIG.RX_USER_DATA_WIDTH \
           CONFIG.RX_INT_DATA_WIDTH CONFIG.TX_USRCLK2_FREQUENCY CONFIG.RX_USRCLK2_FREQUENCY \
           CONFIG.TX_OUTCLK_FREQUENCY CONFIG.RX_OUTCLK_FREQUENCY} {
    catch {puts "EFF $k = <[get_property $k $ip]>"}
}

# ------------------------------------------------------------------ generate
sec "GENERATE"
set gr [catch {generate_target all $ip} e]
puts "GENERATE_TARGET_ALL rc = $gr"
if {$gr} { puts "GENERATE_ERR = $e" }
puts "IS_LOCKED_AFTER_GENERATE = [get_property IS_LOCKED $ip]"
catch {puts "LOCK_DETAILS = [get_property LOCK_DETAILS $ip]"}
catch {puts "USED_LICENSE_KEYS = [get_property USED_LICENSE_KEYS $ip]"}

# ------------------------------------------------------------------ targets available
sec "TARGETS"
foreach t {{synthesis Synthesis} {simulation Simulation} {example_design Example_Design}} {
    lassign $t tn tl
    set r [catch {generate_target $tn $ip} e]
    puts "TARGET $tl rc = $r"
    if {$r} { puts "  ERR: $e" }
}

sec "DONE"
close_project -quiet
