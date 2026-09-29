#=============================================================================
# ctrl_ibert_v3.tcl -- P7a CONTROL EXPERIMENT (known-good reference design)
#
#   Question: is the P7a "no PRBS31 lock, sfp1_rx_los=1" failure a BOARD/CABLE
#             problem or a problem in OUR design?
#
#   Method (user global rule #1: same board, same cable, burn the reference
#   bitstream): program the iBERT v3 image that measured BER < 2.4e-12 on
#   2026-09-27 23:12 (_ibert/m8_vivado.log) over the SAME AOC and read the SAME
#   two pins (B11 = SFP A RX_LOS, C9 = SFP B RX_LOS) with the SAME semantics
#   (LVCMOS33 + PULLTYPE PULLUP) and the SAME VIO core.
#
#   Order of operations:
#     STAGE 0  preflight + report the sha256 of what we are about to burn
#     STAGE 1  connect 192.168.0.38:3121 + safety gate (IDCODE 04A62093, n=1)
#     STAGE 2  read the P7a design that is STILL loaded -> in-session "before"
#     STAGE 3  program iBERT v3 (volatile JTAG only; QSPI is never touched)
#     STAGE 4  VIO: LOS x6 samples + heartbeat (positive evidence the design runs)
#     STAGE 5  PLL status + per-GT RX_BER / bit counts
#     STAGE 6  60 s differential BER, exactly the M8 protocol
#     STAGE 7  final LOS
#
#   32-bit Tcl trap: this Vivado's Tcl is 32-bit (wordSize=4) and
#   format %d / %X silently emits 0 for values > 2^31.  Every large value below
#   is printed by string interpolation or with %s, never %d/%X.
#=============================================================================

set here [file normalize [file dirname [info script]]]
set bit  $here/ibert_top_v3_corrected_map.bit
set ltx  $here/ibert_top_v3_corrected_map.ltx

# the P7a image that is (probably) still configured in the FPGA right now
set p7a_bit "D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/vivado_prj/p7a_prj.runs/impl_1/p7a_top.bit"
set p7a_ltx [file rootname $p7a_bit].ltx

set url 192.168.0.38:3121
if {[info exists ::env(CTRL_HWURL)]} { set url $::env(CTRL_HWURL) }

proc sec {s} { puts "\n@@@@@@ CTRL >>> $s" ; flush stdout }
proc pget {o n} { if {[catch {set v [get_property $n $o]} e]} { return "<ERR:$e>" } ; return $v }
proc bit  {v n} { expr {($v >> $n) & 1} }
# wide-int safe hex->int : expr's 0x literal is Tcl_WideInt, unlike "scan %x"
proc hexint {s} { set s [string trim $s] ; return [expr "0x$s"] }

sec "STAGE 0 -- PREFLIGHT"
puts "ctrl image  (to be burned) = $bit"
puts "              exists=[file exists $bit] size=[file size $bit]"
puts "ctrl probes                 = $ltx"
puts "              exists=[file exists $ltx] size=[file size $ltx]"
puts "p7a image   (loaded now?)   = $p7a_bit exists=[file exists $p7a_bit]"
puts "tcl = [info patchlevel] wordSize=$tcl_platform(wordSize)  (large values printed by interpolation, never format %d)"
foreach f [list $bit $ltx] {
    puts "  [file tail $f]  mtime=[clock format [file mtime $f] -format {%Y-%m-%d %H:%M:%S}]"
}
puts "EXPECTED sha256 (from _ibert/archive_v3, verified byte-identical to _ibert/ibert_ku5p/ibert_ku5p.runs/impl_1/):"
puts "  bit d5566b93b89f0a7b80a7901949e059464f2822f1d60f91e53170b1532b0f1ae0"
puts "  ltx 48ddc17ebe6e60f8590a0035619cccf529529173681900236102097971f131a4"

sec "STAGE 1 -- CONNECT + SAFETY GATE"
open_hw_manager
connect_hw_server -url $url
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
set dlist [get_hw_devices]
puts "device count = [llength $dlist]"
foreach d $dlist { puts "DEVICE $d PART=[pget $d PART] IDCODE=[pget $d IDCODE_HEX]" }
set tdev ""
foreach d $dlist { if {[pget $d IDCODE_HEX] eq "04A62093"} { set tdev $d } }
if {$tdev eq "" || [llength $dlist] != 1} {
    puts "CTRL-SAFETY_ABORT: target='$tdev' count=[llength $dlist] -- NOT PROGRAMMING"
    exit 1
}
puts "SAFETY_GATE = PASS -> $tdev"
current_hw_device $tdev

#-----------------------------------------------------------------------------
sec "STAGE 2 -- IN-SESSION 'BEFORE': the P7a image still in the FPGA"
# This is the tightest possible control: the SAME session, minutes apart, reads
# the SAME two balls through the P7a design's own VIO, then through iBERT's.
if {[file exists $p7a_ltx]} {
    catch {set_property PROBES.FILE $p7a_ltx $tdev}
    catch {set_property FULL_PROBES.FILE $p7a_ltx $tdev}
    catch {refresh_hw_device -update_hw_probes true $tdev}
    puts "P7a DONE_PIN = [pget $tdev REGISTER.CONFIG_STATUS.BIT\[14\]_DONE_PIN]"
    set pvio [lindex [get_hw_vios -of_objects $tdev] 0]
    if {$pvio eq ""} {
        puts "P7a VIO not enumerated (image may already be gone)"
    } else {
        array set PW {}
        foreach p [get_hw_probes -of_objects $pvio] { set PW([pget $p NAME]) $p }
        if {[info exists PW(vio_status)]} {
            foreach tag {BEFORE-1 BEFORE-2} {
                catch {refresh_hw_vio $pvio}
                set st [hexint [get_property INPUT_VALUE $PW(vio_status)]]
                puts "@@@@ P7a $tag  status=$st"
                puts "     sfp1_rx_los=[bit $st 55]  sfp2_rx_los=[bit $st 56]  (SFP A LOS, SFP B LOS)"
                puts "     acq=[bit $st 57][bit $st 58] ref_link=[bit $st 59][bit $st 60] ref_down_latched=[bit $st 61][bit $st 62]"
                puts "     rx_cdr_stable=[bit $st 54] tx_reset_done=[bit $st 52] rx_reset_done=[bit $st 53]"
                after 2500
            }
        } else {
            puts "P7a VIO has no vio_status probe -- printing raw probe list"
            foreach p [get_hw_probes -of_objects $pvio] { puts "   [pget $p NAME] = [pget $p INPUT_VALUE]" }
        }
    }
} else {
    puts "P7a .ltx not found at $p7a_ltx -- skipping the before-read"
}

#-----------------------------------------------------------------------------
sec "STAGE 3 -- PROGRAM iBERT v3 (volatile, JTAG; QSPI untouched)"
set_property PROGRAM.FILE $bit $tdev
catch {set_property PROBES.FILE $ltx $tdev}
catch {set_property FULL_PROBES.FILE $ltx $tdev}
if {[catch {program_hw_devices $tdev} em]} {
    puts "CTRL-ABORT: program failed: $em"
    exit 1
}
set done [pget $tdev REGISTER.CONFIG_STATUS.BIT\[14\]_DONE_PIN]
puts "DONE_PIN = $done"
if {$done != 1} { puts "CTRL-ABORT: DONE != 1"; exit 1 }
catch {refresh_hw_device -update_hw_probes true $tdev}
set ibs [get_hw_sio_iberts]
puts "ibert count = [llength $ibs]"
puts "vio   count = [llength [get_hw_vios]]"

#-----------------------------------------------------------------------------
sec "STAGE 4 -- iBERT VIO: SFP RX_LOS x6 + heartbeat"
set vios [get_hw_vios]
if {[llength $vios] == 0} { puts "CTRL-ABORT: no VIO"; exit 1 }
set v [lindex $vios 0]
array set V {}
foreach p [get_hw_probes -of_objects $v] {
    set nm [pget $p NAME]
    set V($nm) $p
    puts "  PROBE name=$nm width=[pget $p WIDTH] value=[pget $p INPUT_VALUE]"
}
# resolve the two LOS probes by NAME (probe name = RTL net name)
set p1 ""
set p2 ""
foreach nm [array names V] {
    if {[string match "sfp1_rx_los*" $nm]} { set p1 $V($nm) }
    if {[string match "sfp2_rx_los*" $nm]} { set p2 $V($nm) }
}
set phb ""
foreach nm [array names V] { if {[string match "hb_cnt*" $nm]} { set phb $V($nm) } }
puts ""
puts "resolved: sfp1(A)_probe='[expr {$p1 ne "" ? [pget $p1 NAME] : {<none>}}]' sfp2(B)_probe='[expr {$p2 ne "" ? [pget $p2 NAME] : {<none>}}]' hb='[expr {$phb ne "" ? [pget $phb NAME] : {<none>}}]'"
set hb_prev ""
for {set i 1} {$i <= 6} {incr i} {
    catch {refresh_hw_vio $v}
    set a "<n/a>" ; set b "<n/a>" ; set h "<n/a>"
    if {$p1 ne ""} { set a [get_property INPUT_VALUE $p1] }
    if {$p2 ne ""} { set b [get_property INPUT_VALUE $p2] }
    if {$phb ne ""} { set h [get_property INPUT_VALUE $phb] }
    set chg "<first>"
    if {$hb_prev ne ""} { set chg [expr {$h ne $hb_prev}] }
    set hb_prev $h
    puts "  SAMPLE-$i  sfp1_rx_los(SFP A)=$a  sfp2_rx_los(SFP B)=$b  hb_cnt=$h (changed=$chg)"
    after 1500
}
puts "  ^ heartbeat MUST change between samples: that is the positive evidence that"
puts "    the design is clocked and the VIO is not returning a stale/empty read."

#-----------------------------------------------------------------------------
sec "STAGE 5 -- PLL / per-GT status (RX_BER ~0.5 = no light or no lock)"
set gts [lsort [get_hw_sio_gts]]
foreach p [get_hw_sio_plls] {
    puts "  PLL [pget $p DISPLAY_NAME] QPLL0LOCK=[pget $p PORT.QPLL0LOCK] QPLL0REFCLKLOST=[pget $p PORT.QPLL0REFCLKLOST]"
    foreach q {PLL0_FBDIV PLL1_FBDIV QPLL0_FBDIV QPLL1_FBDIV} {
        set r [pget $p $q] ; if {$r ne "<ERR:invalid property>" } { puts "      $q = $r" }
    }
}
foreach g $gts {
    puts "  [pget $g DISPLAY_NAME] LINE_RATE=[pget $g LINE_RATE] LOOPBACK=[pget $g LOOPBACK] RX_BER=[pget $g RX_BER]"
    puts "      RX_RECEIVED_BIT_COUNT(t0) = [pget $g RX_RECEIVED_BIT_COUNT]"
}

sec "STAGE 5b -- create links X0Y4<->X0Y5 (host-side only) and settle 12 s"
foreach l [get_hw_sio_links] { catch {remove_hw_sio_link $l} }
set gtA [lindex $gts 0]
set gtB [lindex $gts 1]
puts "gtA = [pget $gtA DISPLAY_NAME] (SFP A, X0Y4)   gtB = [pget $gtB DISPLAY_NAME] (SFP B, X0Y5)"
create_hw_sio_link -description {A_to_B} [get_hw_sio_txs -of_objects $gtA] [get_hw_sio_rxs -of_objects $gtB]
create_hw_sio_link -description {B_to_A} [get_hw_sio_txs -of_objects $gtB] [get_hw_sio_rxs -of_objects $gtA]
after 12000
catch {refresh_hw_sio $ibs}
foreach g $gts {
    puts "  [pget $g DISPLAY_NAME] RX_BER=[pget $g RX_BER]  LOCK-hint=(BER<<0.5 means locked)"
}
foreach l [get_hw_sio_links] { puts "  LINK [pget $l DESCRIPTION] STATUS=[pget $l STATUS] RX_BER=[pget $l RX_BER]" }

#-----------------------------------------------------------------------------
sec "STAGE 6 -- 60 s differential BER (identical protocol to M8)"
foreach g $gts { catch {set_property LOGIC.MGT_ERRCNT_RESET_CTRL 1 $g} ; catch {set_property LOGIC.RXPRBSERRSTICKYRST 1 $g} }
after 300
foreach g $gts { catch {set_property LOGIC.MGT_ERRCNT_RESET_CTRL 0 $g} ; catch {set_property LOGIC.RXPRBSERRSTICKYRST 0 $g} }
after 300
catch {refresh_hw_sio $ibs}
set t0 {}
foreach g $gts { lappend t0 [list [pget $g RX_RECEIVED_BIT_COUNT] [hexint [pget $g LOGIC.ERRBIT_COUNT]]] }
after 60000
catch {refresh_hw_sio $ibs}
set i 0
foreach g $gts {
    set b0 [lindex [lindex $t0 $i] 0] ; set e0 [lindex [lindex $t0 $i] 1]
    set b1 [pget $g RX_RECEIVED_BIT_COUNT] ; set e1 [hexint [pget $g LOGIC.ERRBIT_COUNT]]
    set db [expr {$b1 - $b0}] ; set de [expr {$e1 - $e0}]
    set ber "<n/a>" ; if {$db > 0 && $de >= 0} { set ber [expr {double($de)/double($db)}] }
    puts "    [pget $g DISPLAY_NAME]  dBITS=$db  dERR=$de  BER=$ber   (RX_BER now = [pget $g RX_BER])"
    incr i
}
puts "  NOTE: dERR=0 on X0Y6/X0Y7 (nothing cabled) is an ARTIFACT -- an unlocked"
puts "        PRBS checker does not count.  Only X0Y4/X0Y5 carry information."

sec "STAGE 7 -- final LOS"
catch {refresh_hw_vio $v}
set a "<n/a>" ; set b "<n/a>"
if {$p1 ne ""} { set a [get_property INPUT_VALUE $p1] }
if {$p2 ne ""} { set b [get_property INPUT_VALUE $p2] }
puts "  FINAL  sfp1_rx_los(SFP A)=$a   sfp2_rx_los(SFP B)=$b"
puts ""
puts "CTRL-COMPLETE -- board now runs the iBERT v3 reference image (volatile)."
puts "Reflash to return to P7a: $p7a_bit"
disconnect_hw_server
puts "DONE"
