# ============================================================================
# s1_prepare.tcl -- P7b stage 1: build TWO independent xxv_ethernet probe
# projects on xcku5p-ffvb676-1-e, WITH the licence in place, and dump every
# piece of interface metadata we can get out of them.
#
#   pcs64    CORE = Ethernet PCS/PMA 64-bit      (expected: XGMII out)
#   macpcs64 CORE = Ethernet MAC+PCS/PMA 64-bit  (expected: AXIS out)
#
# Parameter ORDER copies _lic/tcl_a_prepare.tcl (CONFIG.CORE LAST).
# Directory layout follows that script too: <root>/<tag>/<tag>.xpr .
#
# NOTHING is programmed onto the board here.  No QSPI.  No git.
# ============================================================================

set root "D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/xxv_probe"
set part "xcku5p-ffvb676-1-e"

proc sec {s} { puts "\nS1 >>>>>>>>>> $s" }
catch {set_param general.maxThreads 4}

sec "ENV"
puts "S1_VIVADO          = [version -short]"
puts "S1_PART_N          = [llength [get_parts $part -quiet]]"
puts "S1_LIC_MAIN_EXISTS = [file exists C:/AMDDesignTools/2025.2/data/ip/core_licenses/Xilinx.lic]"
puts "S1_LIC_FREE_EXISTS = [file exists C:/AMDDesignTools/2025.2/data/ip/core_licenses/XilinxFree.lic]"
puts "S1_LIC_HIDDEN      = [file exists C:/AMDDesignTools/2025.2/data/ip/core_licenses/Xilinx.lic.HIDDEN]"
proc envp {n} { if {[info exists ::env($n)]} { return $::env($n) } ; return "<unset>" }
puts "S1_ENV_XILINXD_LICENSE_FILE = [envp XILINXD_LICENSE_FILE]"
puts "S1_ENV_XILINX_LICENSE_FILE  = [envp XILINX_LICENSE_FILE]"
puts "S1_ENV_LM_LICENSE_FILE      = [envp LM_LICENSE_FILE]"

sec "S1_LICPARAMS"
if {[catch {set allp [list_param]} e]} { puts "S1_LISTPARAM_FAIL = $e"; set allp {} }
puts "S1_LISTPARAM_N = [llength $allp]"
foreach p [lsort $allp] {
    if {[string match -nocase "*lic*" $p] || [string match -nocase "*xilinx*" $p]} {
        set v "<err>"; catch {set v [get_param $p]}
        puts "S1_LICPARAM $p = $v"
    }
}

proc dump_ip {mn} {
    set ip [get_ips $mn]
    puts "DUMP_${mn}_IS_LOCKED      = [get_property IS_LOCKED $ip]"
    catch {puts "DUMP_${mn}_LOCK_DETAILS  = [get_property LOCK_DETAILS $ip]"}
    catch {puts "DUMP_${mn}_USED_LIC_KEYS = [get_property USED_LICENSE_KEYS $ip]"}
    set pl {}
    catch {set pl [list_property $ip]}
    foreach p [lsort $pl] {
        if {[string match "CONFIG.*" $p]} {
            set v "<err>"
            catch {set v [get_property $p $ip]}
            puts "CFG_${mn} $p = $v"
        }
    }
}

proc mk {tag core basrkr} {
    global root part
    set pdir "$root/$tag"
    set mn   "$tag"

    sec "S1_BEGIN $tag core=<$core> base_r_kr=<$basrkr>"
    if {[file exists "$pdir/$mn.xpr"]} { file delete -force $pdir }
    if {[catch {create_project -force $mn $pdir -part $part} e]} {
        puts "S1_CREATE_PROJECT_FAIL = $e"; return
    }
    set_property target_language Verilog [current_project]

    # GT selection: try the known spellings, record which one is accepted.
    foreach p {CONFIG.GT_LOCATION CONFIG.LOCATE_GT CONFIG.CHANNEL_ENABLE} {
        catch {puts "S1_GT_PARAM_AVAIL $p = [get_property $p [get_ips -quiet $mn]]"}
    }

    if {[catch {create_ip -name xxv_ethernet -vendor xilinx.com -library ip \
                     -version 5.0 -module_name $mn} e]} {
        puts "S1_CREATE_IP_FAIL = $e"; close_project -quiet; return
    }
    puts "S1_CREATE_IP = OK"
    set ip [get_ips $mn]
    puts "S1_IS_LOCKED_AT_CREATE = [get_property IS_LOCKED $ip]"

    foreach {k v} [list \
        CONFIG.LINE_RATE            {10} \
        CONFIG.CLOCKING             {Asynchronous} \
        CONFIG.BASE_R_KR            $basrkr \
        CONFIG.GT_REF_CLK_FREQ      {156.25} \
        CONFIG.GT_TYPE              {GTY} \
        CONFIG.INCLUDE_SHARED_LOGIC {1} \
        CONFIG.CORE                 $core] {
        if {[catch {set_property $k $v $ip} e]} {
            puts "S1_SETPARAM_FAIL $k = $e"
        } else {
            set gv "<rb-err>"; catch {set gv [get_property $k $ip]}
            puts "S1_SETPARAM_OK $k = <$v> readback=<$gv>"
        }
    }

    # GT channel X0Y4 (SFP A).  Try each spelling, keep whichever works.
    foreach p {CONFIG.GT_LOCATION CONFIG.LOCATE_GT CONFIG.CHANNEL_ENABLE} {
        if {[catch {set_property $p {X0Y4} $ip} e]} {
            puts "S1_GT_SET_FAIL $p = $e"
        } else {
            catch {puts "S1_GT_SET_OK $p readback=<[get_property $p $ip]>"}
        }
    }

    puts "S1_IS_LOCKED_POSTCFG = [get_property IS_LOCKED $ip]"
    catch {puts "S1_LOCK_DETAILS_POSTCFG = [get_property LOCK_DETAILS $ip]"}

    set gr [catch {generate_target all $ip} e]
    puts "S1_GENERATE rc = $gr"
    if {$gr} { puts "S1_GENERATE_ERR = $e" }
    catch {puts "S1_IS_LOCKED_POSTGEN = [get_property IS_LOCKED $ip]"}
    catch {puts "S1_LOCK_DETAILS_POSTGEN = [get_property LOCK_DETAILS $ip]"}
    catch {puts "S1_USED_LICENSE_KEYS = [get_property USED_LICENSE_KEYS $ip]"}

    set gd "$pdir/$mn.gen/sources_1/ip/$mn"
    foreach pat {*.v *.veo *.vho *.xci hdl/*.sv hdl/*.v synth/*.xdc *.xdc doc/* sim/*.v} {
        set fl [glob -nocomplain -directory $gd $pat]
        puts "S1_ART $pat n=[llength $fl]"
        foreach f $fl { puts "S1_ARTF $pat [file tail $f] size=[file size $f]" }
    }
    set sdir "$pdir/$mn.srcs/sources_1/ip/$mn"
    puts "S1_XCI_DIR = $sdir"
    foreach f [glob -nocomplain -directory $sdir *] { puts "S1_SRCF [file tail $f] size=[file size $f]" }

    dump_ip $mn

    close_project -quiet
    puts "S1_END $tag"
}

mk pcs64    {Ethernet PCS/PMA 64-bit}     {BASE-R}
mk macpcs64 {Ethernet MAC+PCS/PMA 64-bit} {BASE-R}

sec "S1 DONE"
