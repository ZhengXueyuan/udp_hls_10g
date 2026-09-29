# ============================================================================
# s1_prepare.tcl -- P7b gate-1 (xxv_loop): create the TWO-CHANNEL
#   xxv_ethernet 5.0 project, CORE = "Ethernet PCS/PMA 64-bit", and nail the
#   configuration down with a FIXED-POINT iteration, then dump every piece of
#   interface metadata (ports, sub-core readback, OOC constraints).
#
#   WHY TWO CHANNELS:  J7 = SFP A = GTY X0Y4, J8 = SFP B = GTY X0Y5, and the
#   board AOC loops J7<->J8.  A single-channel core can transmit on SFP A but
#   has no receiver on SFP B, so the "ch0 TX -> fibre -> ch1 RX" self-loop that
#   gate 1 needs is impossible with CHANNEL_ENABLE = X0Y4 alone.
#
#   WHY THE LOOP:  setting CONFIG.CORE silently RESETS its dependent parameters
#   (measured in xxv_probe stage 1: LINE_RATE went back to 25, BASE_R_KR to
#   BASE-KR, GT_REF_CLK_FREQ to 161.1328125, while every individual set_property
#   read back correctly).  We therefore re-apply ALL parameters each round and
#   compare a full readback, stopping when nothing mismatches.
#
#   NOTHING is programmed.  No QSPI.  No git writes.  licence files untouched.
# ============================================================================

set root "D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/xxv_loop"
set part "xcku5p-ffvb676-1-e"
set gquad "Quad_X0Y1"        ;# quad 225 == channels X0Y4..X0Y7 (SFP A / SFP B)

proc sec {s} { puts "\nS1 >>>>>>>>>> $s" }
catch {set_param general.maxThreads 8}

sec "ENV"
puts "S1_VIVADO          = [version -short]"
puts "S1_PART_N          = [llength [get_parts $part -quiet]]"

# Pull one JSON scalar out of an .xci (same parser as xxv_probe/s2_config.tcl).
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

proc apply_round {ip keysvals} {
    foreach {k v} $keysvals {
        if {[catch {set_property $k $v $ip} e]} { puts "  SET_FAIL $k <- <$v> : $e" }
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

# ---------------------------------------------------------------------------
#  DESIRED configuration.  Two channels, X0Y4 + X0Y5, 156.25 MHz refclk, GTY,
#  BASE-R, 10 Gbps, asynchronous clocking, shared logic (GT common + reset
#  controller) INSIDE the core.
# ---------------------------------------------------------------------------
set DESIRED [list \
    CONFIG.LINE_RATE            {10} \
    CONFIG.CLOCKING             {Asynchronous} \
    CONFIG.BASE_R_KR            {BASE-R} \
    CONFIG.GT_REF_CLK_FREQ      {156.25} \
    CONFIG.GT_TYPE              {GTY} \
    CONFIG.INCLUDE_SHARED_LOGIC {1} \
    CONFIG.GT_GROUP_SELECT      $gquad \
    CONFIG.NUM_OF_CORES         {2} \
    CONFIG.LANE1_GT_LOC         {X0Y4} \
    CONFIG.LANE2_GT_LOC         {X0Y5} \
    CONFIG.CORE                 {Ethernet PCS/PMA 64-bit} ]

set pdir "$root/pcs64_2ch"
sec "S1_CREATE $pdir"
if {[file exists $pdir]} { file delete -force $pdir }
if {[catch {create_project -force pcs64_2ch $pdir -part $part} e]} {
    puts "S1_CREATE_PROJECT_FAIL = $e"; exit 1
}
set_property target_language Verilog [current_project]

if {[catch {create_ip -name xxv_ethernet -vendor xilinx.com -library ip \
                 -version 5.0 -module_name pcs64} e]} {
    puts "S1_CREATE_IP_FAIL = $e"; exit 1
}
set ip [get_ips pcs64]
puts "S1_IS_LOCKED_AT_CREATE = [get_property IS_LOCKED $ip]"

# ---- enumerate the properties that matter, BEFORE they are overwritten ----
sec "S1_ENUMS"
foreach p {CONFIG.GT_GROUP_SELECT CONFIG.CORE CONFIG.NUM_OF_CORES \
           CONFIG.LANE1_GT_LOC CONFIG.LANE2_GT_LOC CONFIG.LANE3_GT_LOC \
           CONFIG.GT_REF_CLK_FREQ CONFIG.GT_DRP_CLK CONFIG.LINE_RATE \
           CONFIG.GT_LOCATION CONFIG.GT_TYPE CONFIG.INS_LOSS_NYQ} {
    set vv {}
    catch {set vv [list_property_value $p $ip]}
    puts "ENUM $p = $vv"
}
puts "S1_PROPLIST_N = [llength [list_property $ip]]"

# ---- fixed-point iteration -------------------------------------------------
set conv -1
for {set rnd 1} {$rnd <= 8} {incr rnd} {
    sec "S1_ROUND #$rnd"
    apply_round $ip $DESIRED
    set bad [readback $ip $DESIRED]
    puts "S1_ROUND #$rnd MISMATCH_N = $bad"
    if {$bad == 0} { set conv $rnd ; break }
}
puts "S1_CONVERGED_AT_ROUND = $conv"
puts "S1_IS_LOCKED_POSTCFG = [get_property IS_LOCKED $ip]"

# ---- generate --------------------------------------------------------------
sec "S1_GENERATE"
set gr [catch {generate_target all $ip} e]
puts "S1_GENERATE rc = $gr"
if {$gr} { puts "S1_GENERATE_ERR = $e" }
catch {puts "S1_IS_LOCKED_POSTGEN = [get_property IS_LOCKED $ip]"}
catch {puts "S1_LOCK_DETAILS_POSTGEN = [get_property LOCK_DETAILS $ip]"}
catch {puts "S1_USED_LICENSE_KEYS = [get_property USED_LICENSE_KEYS $ip]"}
puts "S1_RB_AFTER_GENERATE:"
set bad2 [readback $ip $DESIRED]
puts "S1_POSTGEN_MISMATCH_N = $bad2"

# ---- dump the artefact tree ------------------------------------------------
sec "S1_ARTEFACTS"
# NOTE: the .gen directory is named after the PROJECT, not after the IP module
# (measured: project pcs64_2ch + module pcs64 -> pcs64_2ch/pcs64_2ch.gen/...).
set gd "$pdir/pcs64_2ch.gen/sources_1/ip/pcs64"
puts "S1_GENDIR = $gd"
proc dumptree {d} {
    set fl [glob -nocomplain -directory $d *]
    foreach f $fl {
        if {[file isdirectory $f]} { dumptree $f } else {
            puts "S1_FILE [file tail $f] size=[file size $f] path=$f"
        }
    }
}
dumptree $gd
puts "S1_XCI = $pdir/pcs64.srcs/sources_1/ip/pcs64/pcs64.xci"

# ---- the whole port table (this is what the wrapper is written against) ----
sec "S1_VEO_PORTS"
set veos [glob -nocomplain "$gd/*.veo"]
puts "S1_VEO_FILES = $veos"
foreach f $veos {
    set fh [open $f r]; set txt [read $fh]; close $fh
    puts "S1_VEO_BEGIN [file tail $f]"
    set n 0
    foreach line [split $txt "\n"] {
        incr n
        set t [string trim $line]
        if {[string match ".*_0*" $t] || [string match ".*_1*" $t]} {
            puts "VEO $n : $t"
        }
    }
    puts "S1_VEO_END [file tail $f] lines=$n"
}

# ---- sub-core (gtwizard) readback ------------------------------------------
sec "S1_GT_SUBCORE"
foreach f [glob -nocomplain "$gd/ip_0/*_gt.xci"] {
    puts "S1_GT_XCI = $f"
    set fh [open $f r]; set txt [read $fh]; close $fh
    foreach key {CHANNEL_ENABLE TX_REFCLK_SOURCE RX_REFCLK_SOURCE GT_TYPE \
                 TX_LINE_RATE RX_LINE_RATE TX_USER_DATA_WIDTH RX_USER_DATA_WIDTH \
                 TX_DATA_WIDTH RX_DATA_WIDTH TX_INT_DATA_WIDTH RX_INT_DATA_WIDTH \
                 FREERUN_FREQUENCY FREERUN_FREQ_VAL GT_DRP_CLK INS_LOSS_NYQ \
                 TX_BUFFER_MODE RX_BUFFER_MODE LOCATE_COMMON TX_GEARBOX_EN \
                 RX_GEARBOX_EN TX_PLL_TYPE RX_PLL_TYPE TXPROGDIV_FREQ_VAL \
                 RXPROGDIV_FREQ_VAL TX_OUTCLK_SOURCE RX_OUTCLK_SOURCE \
                 RX_TERMINATION RX_TERMINATION_PROG_VALUE \
                 C_CHANNEL_ENABLE C_FREERUN_FREQUENCY C_LOCATE_COMMON} {
        set val [jval $txt $key]
        if {$val ne "<absent>"} { puts "  GT $key = $val" }
    }
}

# ---- top-level xci (the 8 CONFIG knobs, as persisted) ----------------------
sec "S1_TOP_XCI"
set f "$pdir/pcs64.srcs/sources_1/ip/pcs64/pcs64.xci"
set fh [open $f r]; set txt [read $fh]; close $fh
foreach key {CORE LINE_RATE CLOCKING BASE_R_KR GT_REF_CLK_FREQ GT_TYPE \
             INCLUDE_SHARED_LOGIC GT_GROUP_SELECT NUM_OF_CORES \
             LANE1_GT_LOC LANE2_GT_LOC LANE3_GT_LOC LANE4_GT_LOC GT_DRP_CLK \
             C_NUM_OF_CORES C_GT_GROUP_SELECT} {
    set val [jval $txt $key]
    if {$val ne "<absent>"} { puts "XCI $key = $val" }
}

# ---- the XDC the IP ships (clocks + waivers) -------------------------------
sec "S1_IP_XDC"
foreach f [concat [glob -nocomplain "$gd/synth/*.xdc"] [glob -nocomplain "$gd/ip_0/synth/*.xdc"]] {
    puts "S1_XDCF $f size=[file size $f]"
}
foreach f {synth/pcs64_ooc.xdc synth/pcs64.xdc ip_0/synth/pcs64_gt.xdc} {
    set ff "$gd/$f"
    if {![file exists $ff]} { continue }
    set fh [open $ff r]
    puts "S1_XDC_BEGIN $f"
    set n 0
    while {[gets $fh line] >= 0} {
        incr n
        set t [string trim $line]
        if {$t eq "" || [string index $t 0] eq "#"} { continue }
        puts "XDC $f:$n : $t"
    }
    close $fh
    puts "S1_XDC_END $f"
}

sec "S1 DONE"
close_project -quiet
