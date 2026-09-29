# ============================================================================
# s2_config.tcl -- P7b stage 2: create the two xxv_ethernet probe projects and
# NAIL the configuration, then verify the readback at THREE points:
#   (t0) right after each set_property
#   (t1) after the fixed-point loop settles  (BEFORE generate_target)
#   (t2) after generate_target
#   (t3) from the persisted .xci JSON on disk
#
# WHY THE LOOP:  stage 1 revealed that setting CONFIG.CORE LAST silently
# REVERTS the other parameters (the saved .xci had LINE_RATE=25 / BASE_R_KR=
# BASE-KR / GT_REF_CLK_FREQ=161.1328125 even though every individual set had
# read back correctly).  So we iterate to a fixed point instead of trusting
# a single pass, and we report the FIRST round in which everything matches.
#
# No synthesis here.  No board access.  No git.
# ============================================================================

set root "D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/xxv_probe"
set part "xcku5p-ffvb676-1-e"
set gquad "Quad_X0Y1"   ;# candidate: quad 225 == channels X0Y4..X0Y7

proc sec {s} { puts "\nS2 >>>>>>>>>> $s" }
catch {set_param general.maxThreads 4}

# Pull one JSON scalar out of an .xci (no regexp: keeps the parser happy).
proc jval {txt key} {
    set needle "\"$key\""
    set i [string first $needle $txt]
    if {$i < 0} { return "<absent>" }
    set needle2 "\"value\": \""
    set j [string first $needle2 $txt $i]
    if {$j < 0} { return "<novalue>" }
    set s [expr {$j + [string length $needle2]}]
    set e [string first "\"" $txt $s]
    if {$e < 0} { return "<unterminated>" }
    return [string range $txt $s [expr {$e - 1}]]
}

# desired settings, APPLIED IN THIS ORDER each round
set DESIRED [list \
    CONFIG.CORE                 {Ethernet PCS/PMA 64-bit} \
    CONFIG.LINE_RATE            {10} \
    CONFIG.CLOCKING             {Asynchronous} \
    CONFIG.BASE_R_KR            {BASE-R} \
    CONFIG.GT_REF_CLK_FREQ      {156.25} \
    CONFIG.GT_TYPE              {GTY} \
    CONFIG.INCLUDE_SHARED_LOGIC {1} \
    CONFIG.GT_GROUP_SELECT      $gquad ]

proc apply_round {ip keysvals} {
    foreach {k v} $keysvals {
        if {[catch {set_property $k $v $ip} e]} {
            puts "  SET_FAIL $k <- <$v> : $e"
        }
    }
}

proc readback {ip keysvals} {
    set bad 0
    foreach {k v} $keysvals {
        set gv "<err>"; catch {set gv [get_property $k $ip]}
        set mark OK
        if {[string trim $gv] ne [string trim $v]} { set mark MISMATCH; incr bad }
        puts "  RB $k want=<$v> got=<$gv> $mark"
    }
    return $bad
}

proc mk {tag core} {
    global root part DESIRED
    set pdir "$root/$tag"
    set mn   "$tag"
    set dlist $DESIRED
    # per-tag core override (element index 1)
    set dlist [lreplace $dlist 1 1 $core]

    sec "S2_BEGIN $tag core=<$core>"
    if {[file exists $pdir]} { file delete -force $pdir }
    if {[catch {create_project -force $mn $pdir -part $part} e]} {
        puts "S2_CREATE_PROJECT_FAIL = $e"; return 0
    }
    set_property target_language Verilog [current_project]
    if {[catch {create_ip -name xxv_ethernet -vendor xilinx.com -library ip \
                     -version 5.0 -module_name $mn} e]} {
        puts "S2_CREATE_IP_FAIL = $e"; close_project -quiet; return 0
    }
    set ip [get_ips $mn]
    puts "S2_IS_LOCKED_AT_CREATE = [get_property IS_LOCKED $ip]"

    sec "S2_ENUMS $tag"
    foreach p {CONFIG.GT_GROUP_SELECT CONFIG.GT_REF_CLK_FREQ CONFIG.LINE_RATE} {
        set vv {}
        catch {set vv [list_property_value $p $ip]}
        puts "ENUM $p = $vv"
    }

    set conv -1
    for {set rnd 1} {$rnd <= 6} {incr rnd} {
        sec "S2_ROUND $tag #$rnd"
        apply_round $ip $dlist
        set bad [readback $ip $dlist]
        puts "S2_ROUND $tag #$rnd MISMATCH_N = $bad"
        if {$bad == 0} { set conv $rnd ; break }
    }
    puts "S2_CONVERGED_AT_ROUND $tag = $conv"
    puts "S2_IS_LOCKED_POSTCFG = [get_property IS_LOCKED $ip]"

    sec "S2_GENERATE $tag"
    set gr [catch {generate_target all $ip} e]
    puts "S2_GENERATE rc = $gr"
    if {$gr} { puts "S2_GENERATE_ERR = $e" }
    catch {puts "S2_IS_LOCKED_POSTGEN = [get_property IS_LOCKED $ip]"}
    catch {puts "S2_LOCK_DETAILS_POSTGEN = [get_property LOCK_DETAILS $ip]"}
    catch {puts "S2_USED_LICENSE_KEYS = [get_property USED_LICENSE_KEYS $ip]"}
    puts "S2_RB_AFTER_GENERATE:"
    set bad2 [readback $ip $dlist]
    puts "S2_POSTGEN_MISMATCH_N = $bad2"

    # what the sub-gtwizard actually got
    set gd  "$pdir/$mn.gen/sources_1/ip/$mn"
    set gt  [glob -nocomplain -directory $gd ip_0/*_gt.xci]
    puts "S2_GT_XCI = $gt"
    foreach f $gt {
        set fh [open $f r]; set txt [read $fh]; close $fh
        foreach key {CHANNEL_ENABLE TX_REFCLK_SOURCE RX_REFCLK_SOURCE GT_TYPE \
                     TX_LINE_RATE RX_LINE_RATE TX_USER_DATA_WIDTH RX_USER_DATA_WIDTH \
                     TX_DATA_WIDTH RX_DATA_WIDTH FREERUN_FREQUENCY INS_LOSS_NYQ \
                     TX_BUFFER RX_BUFFER LOCATE_COMMON TXGEARBOX_EN RXGEARBOX_EN \
                     TX_INT_DATA_WIDTH RX_INT_DATA_WIDTH TXPROGDIV_FREQ_VAL \
                     RXPROGDIV_FREQ_VAL} {
            set val [jval $txt $key]
            if {$val ne "<absent>"} { puts "  GT $key = $val" }
        }
    }
    # XDC produced by the ip
    foreach f [glob -nocomplain -directory $gd synth/*.xdc] {
        puts "S2_XDC $f size=[file size $f]"
    }
    foreach f [glob -nocomplain -directory $gd ip_0/synth/*.xdc] {
        puts "S2_XDC $f size=[file size $f]"
    }

    # persist the ports for later stages
    puts "S2_XCI $pdir/$mn.srcs/sources_1/ip/$mn/$mn.xci"
    close_project -quiet
    puts "S2_END $tag"
    return 1
}

mk pcs64    {Ethernet PCS/PMA 64-bit}
mk macpcs64 {Ethernet MAC+PCS/PMA 64-bit}

sec "S2 DONE"
