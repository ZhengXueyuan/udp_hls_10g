#=============================================================================
# lic_deny_p7a.tcl -- P7a: licence negative control for gtwizard_ultrascale
#=============================================================================
#
#  RUN ONLY VIA run_lic_deny_p7a.bat, which renames Xilinx.lic away, calls this
#  script, and restores the file unconditionally afterwards.
#
#  Why this exists (P7A_SPEC.md section 1.2 / 9.1)
#  -----------------------------------------------
#  The gate-0 evidence showed IS_LOCKED=0 and an EMPTY USED_LICENSE_KEYS for
#  gtwizard, but the licence file was present the whole time -- so all that was
#  proven is "the IP is clean when the licence happens to be available".
#  Claiming "needs no licence" additionally requires the same measurement with
#  the licence ABSENT. This script does exactly that, and pairs it with a
#  CONTROL that must be locked in the same session: if the control comes back
#  clean too, the readout has no discriminating power and the run proves nothing
#  (iron rule 2: a criterion must be able to tell the two cases apart).
#
#  Subject : gtwizard_ultrascale 1.7 with the P7a 10GBASE-R configuration
#            (the exact atomic parameter set build_p7a.tcl uses)
#  Control : xxv_ethernet's internally generated 64-bit BASE-R GT instance
#            (imported from a pre-configured .xci made in _lic/ phase A2, which
#            was measured LOCKED in the licence-absent session of 2026-09-29)
#=============================================================================

set outroot "D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g"
set lic     "C:/AMDDesignTools/2025.2/data/ip/core_licenses/Xilinx.lic"
set part    "xcku5p-ffvb676-1-e"

proc sec {s} { puts "\nLIC_DENY >>>>>>>>>> $s" }
catch {set_param general.maxThreads 4}

sec "ENVIRONMENT"
puts "VIVADO = [version -short]"
puts "LIC_PRESENT  = [file exists $lic]"
puts "HIDDEN_PRESENT = [file exists ${lic}.HIDDEN]"
if {[file exists $lic]} { puts "WARNING: the licence file is STILL PRESENT -- this run does not test what it claims" }

#---------------------------------------------------------------------------
# SUBJECT: the P7a GT wizard configuration
#---------------------------------------------------------------------------
sec "SUBJECT gtwizard_ultrascale"
set pdir "$outroot/lic_deny_prj"
file delete -force $pdir
if {[catch {create_project -force lic_deny $pdir -part $part} e]} {
    puts "SUBJ_PROJECT_FAIL = $e"
} else {
    set_property target_language Verilog [current_project]
    if {[catch {create_ip -name gtwizard_ultrascale -vendor xilinx.com -library ip \
                     -module_name subj_gt} e]} {
        puts "SUBJ_CREATE_IP_FAIL = $e"
    } else {
        set ip [get_ips subj_gt]
        catch {puts "SUBJ_AT_CREATE_IS_LOCKED = [get_property IS_LOCKED $ip]"}
        catch {puts "SUBJ_AT_CREATE_USED_LICENSE_KEYS = <[get_property USED_LICENSE_KEYS $ip]>"}
        set rc [catch {set_property -dict [dict create \
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
        ] $ip} e2]
        puts "SUBJ_CONFIG rc = $rc"
        if {$rc} { puts "SUBJ_CONFIG_ERR = $e2" }
        catch {puts "SUBJ_EFF_ENCODING = [get_property CONFIG.TX_DATA_ENCODING $ip]"}
        catch {puts "SUBJ_EFF_PROGDIV = [get_property CONFIG.TXPROGDIV_FREQ_VAL $ip]"}

        set gr [catch {generate_target all $ip} e3]
        puts "SUBJ_GENERATE_TARGET_ALL rc = $gr"
        if {$gr} { puts "SUBJ_GENERATE_ERR = $e3" }
        catch {puts "SUBJ_POSTGEN_IS_LOCKED = [get_property IS_LOCKED $ip]"}
        catch {puts "SUBJ_POSTGEN_LOCK_DETAILS = [get_property LOCK_DETAILS $ip]"}
        catch {puts "SUBJ_POSTGEN_USED_LICENSE_KEYS = <[get_property USED_LICENSE_KEYS $ip]>"}
        set gd "$pdir/lic_deny.gen/sources_1/ip/subj_gt"
        puts "SUBJ_GENDIR_EXISTS = [file exists $gd]"
        foreach pat {*.v synth/*.v} {
            puts "SUBJ_ART $pat n=[llength [glob -nocomplain -directory $gd $pat]]"
        }
    }
    close_project -quiet
}

#---------------------------------------------------------------------------
# CONTROL: must be LOCKED in this same session, otherwise the run proves nothing
#---------------------------------------------------------------------------
sec "CONTROL xxv_ethernet pcs64_baser (must be locked)"
set cxci "D:/repo/XCKU5PMini/_lic/w2_pcs64_baser/w2_pcs64_baser.srcs/sources_1/ip/w2_pcs64_baser/w2_pcs64_baser.xci"
puts "CTRL_XCI_EXISTS = [file exists $cxci]"
set cdir "$outroot/lic_deny_ctrl_prj"
file delete -force $cdir
if {![file exists $cxci]} {
    puts "CTRL_ABORT = XCI_MISSING"
} elseif {[catch {create_project -force lic_deny_ctrl $cdir -part $part} e]} {
    puts "CTRL_PROJECT_FAIL = $e"
} else {
    set_property target_language Verilog [current_project]
    if {[catch {import_ip $cxci} e]} {
        puts "CTRL_IMPORT_IP_FAIL = $e"
    } else {
        set cip [get_ips w2_pcs64_baser]
        catch {puts "CTRL_IS_LOCKED = [get_property IS_LOCKED $cip]"}
        catch {puts "CTRL_LOCK_DETAILS = [get_property LOCK_DETAILS $cip]"}
        catch {puts "CTRL_USED_LICENSE_KEYS = <[get_property USED_LICENSE_KEYS $cip]>"}
        catch {reset_target all $cip}
        catch {puts "CTRL_AFTER_RESET_IS_LOCKED = [get_property IS_LOCKED $cip]"}
    }
    close_project -quiet
}

sec "LIC_DENY DONE"
