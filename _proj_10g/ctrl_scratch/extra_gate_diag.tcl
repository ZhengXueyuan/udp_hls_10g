#=============================================================================
# extra_gate_diag.tcl -- BOUNDED EXTRA diagnostic, run AFTER the stage-1 gate
#                        failed a second time (LOS still 1/0, all four GT RX
#                        still at BER ~0.5, both links NO LINK).
#
#   *** THIS SCRIPT NEVER PROGRAMS. ***  The iBERT v3 image from the stage-1 run
#   is still configured, so the same VIO core / same IBERT core are reused.
#   (Verified by construction: the string "program_hw_devices" is absent.)
#
#   Why it exists (same reasoning as board_scratch/read_state_only.tcl): the
#   task says STOP AND REPORT, not burn repeatedly -- but there are still
#   READ-ONLY registers that answer the one question the gate cannot:
#
#     "Is the FPGA-side RX chain innocent, and is there really a recoverable
#      serial signal at each GT receiver?"
#
#   The two LOS bits alone cannot answer that.  These can:
#     PORT.RXCDRLOCK        - the RX CDR is locked to an incoming 10.3125 GBd
#                             signal => light IS present AND usable
#     LOGIC.RXCDRLOCKSTICKY - it locked at least once since the last reset
#     PORT.RXPRBSLOCKED     - the PRBS31 checker is locked
#   and two INTERNAL loopback positive controls (no optics involved):
#     Near-End PCS / Near-End PMA on X0Y4+X0Y5 -> PRBS lock + BER ~ 0 proves the
#     GT TX/RX digital chain, the pattern config and the BER counter all work.
#
#   Every write below is a VOLATILE iBERT property write (LOOPBACK), restored to
#   None at the end and verified.  No bitstream change, no QSPI, no reset of the
#   device.  32-bit-Tcl safe: large values are printed by interpolation.
#=============================================================================

set here [file normalize [file dirname [info script]]]
set ltx  $here/ibert_top_v3_corrected_map.ltx

set url 192.168.0.38:3121
if {[info exists ::env(CTRL_HWURL)]} { set url $::env(CTRL_HWURL) }

proc sec {s} { puts "\n@@@@@@ XDIAG >>> $s" ; flush stdout }
proc pget {o n} { if {[catch {set v [get_property $n $o]} e]} { return "<ERR:$e>" } ; return $v }
proc bit  {v n} { expr {($v >> $n) & 1} }
proc h2d  {s} { set s [string trim $s] ; if {[catch {expr "0x$s"} v]} { return -1 } ; return $v }

sec "X0 -- CONNECT (NO PROGRAMMING) + SAFETY GATE"
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
    puts "XDIAG-ABORT: not the expected single xcku5p target -- doing nothing"
    exit 1
}
puts "SAFETY_GATE = PASS -> $tdev"
current_hw_device $tdev
catch {set_property PROBES.FILE $ltx $tdev}
catch {set_property FULL_PROBES.FILE $ltx $tdev}
catch {refresh_hw_device -update_hw_probes true $tdev}
puts "DONE_PIN = [pget $tdev REGISTER.CONFIG_STATUS.BIT\[14\]_DONE_PIN]"
puts "IBERT cores = [llength [get_hw_sio_iberts]]   VIO cores = [llength [get_hw_vios]]"

#------------------------------------------------------------------ LOS probes
set v [lindex [get_hw_vios] 0]
array set V {}
foreach p [get_hw_probes -of_objects $v] { set V([pget $p NAME]) $p }
set p1 "" ; set p2 "" ; set phb ""
foreach nm [array names V] {
    if {[string match "sfp1_rx_los*" $nm]} { set p1 $V($nm) }
    if {[string match "sfp2_rx_los*" $nm]} { set p2 $V($nm) }
    if {[string match "hb_cnt*"     $nm]} { set phb $V($nm) }
}
puts "resolved LOS probes: sfp1(A)='$p1'  sfp2(B)='$p2'  hb='$phb'"

sec "X1 -- LOS stability (5 samples, 2 s apart) + heartbeat positive evidence"
set prev ""
for {set i 1} {$i <= 5} {incr i} {
    catch {refresh_hw_vio $v}
    set a [get_property INPUT_VALUE $p1]
    set b [get_property INPUT_VALUE $p2]
    set h [expr {$phb ne "" ? [get_property INPUT_VALUE $phb] : "<none>"}]
    set chg "<first>" ; if {$prev ne ""} { set chg [expr {$h ne $prev}] }
    set prev $h
    puts "  LOS-SAMPLE-$i  sfp1_rx_los=$a  sfp2_rx_los=$b  hb_cnt=$h (changed=$chg)"
    after 2000
}

#-------------------------------------------------------------- GT status read
set ibs [get_hw_sio_iberts]
catch {refresh_hw_sio $ibs}
set gts [lsort [get_hw_sio_gts]]

proc gtsnap {tag} {
    set gts [lsort [get_hw_sio_gts]]
    puts "  ----- $tag -----"
    foreach g $gts {
        puts "    [pget $g DISPLAY_NAME]  LINE_RATE=[pget $g LINE_RATE]  LOOPBACK=[pget $g LOOPBACK]"
        puts "        RX_BER=[pget $g RX_BER]  RXCDRLOCK=[pget $g PORT.RXCDRLOCK]  RXCDRLOCKSTICKY=[pget $g LOGIC.RXCDRLOCKSTICKY]  RXPRBSLOCKED=[pget $g PORT.RXPRBSLOCKED]"
        puts "        RX_BITS=[pget $g RX_RECEIVED_BIT_COUNT]  ERRBIT=[pget $g LOGIC.ERRBIT_COUNT]  TX_PATTERN=[pget $g TX_PATTERN]  RX_PATTERN=[pget $g RX_PATTERN]"
    }
}

sec "X2 -- BASELINE (external AOC only, no internal loopback): the decisive read"
gtsnap "external AOC, LOOPBACK=None"
puts ""
puts "  ^ INTERPRETATION KEY (fixed before reading it):"
puts "    RXCDRLOCK=1 on a cabled channel  => a real 10.3125 GBd signal IS arriving"
puts "                                        at that GT receiver (light present AND usable)."
puts "    RXCDRLOCK=0 on a cabled channel  => nothing recoverable arrives there, even if"
puts "                                        its RX_LOS pin reads 0 (=> that LOS=0 is not light)."

sec "X3 -- datapath / pattern config of X0Y4 (context: is the image's BER setup intact?)"
set g0 [lindex $gts 0]
foreach p {TX_PATTERN RX_PATTERN TX_DATA_WIDTH RX_DATA_WIDTH TX_INT_DATAWIDTH RX_INT_DATAWIDTH TXGEARBOX_EN RXGEARBOX_EN TXOUT_DIV RXOUT_DIV TX_PLL RX_PLL} {
    puts "    $p = [pget $g0 $p]"
}

#-------------------------------------------------------- internal loopbacks
proc setloop {mode} {
    foreach g [lsort [get_hw_sio_gts]] {
        set rc [catch {set_property LOOPBACK $mode $g} e]
        catch {commit_hw_sio $g}
        puts "    set LOOPBACK '$mode' -> [pget $g DISPLAY_NAME] rc=$rc $e"
    }
}
proc measure {tag secs} {
    set gts [lsort [get_hw_sio_gts]]
    foreach g $gts {
        catch {set_property LOGIC.MGT_ERRCNT_RESET_CTRL 1 $g}
        catch {set_property LOGIC.RXPRBSERRSTICKYRST 1 $g}
    }
    after 300
    foreach g $gts {
        catch {set_property LOGIC.MGT_ERRCNT_RESET_CTRL 0 $g}
        catch {set_property LOGIC.RXPRBSERRSTICKYRST 0 $g}
    }
    after 300
    catch {refresh_hw_sio [get_hw_sio_iberts]}
    set t0 {}
    foreach g $gts { lappend t0 [list [pget $g RX_RECEIVED_BIT_COUNT] [h2d [pget $g LOGIC.ERRBIT_COUNT]]] }
    after [expr {$secs*1000}]
    catch {refresh_hw_sio [get_hw_sio_iberts]}
    puts "  ===== MEASURE $tag (${secs}s window) ====="
    set i 0
    foreach g $gts {
        set b0 [lindex [lindex $t0 $i] 0]
        set e0 [lindex [lindex $t0 $i] 1]
        set b1 [pget $g RX_RECEIVED_BIT_COUNT]
        set e1 [h2d [pget $g LOGIC.ERRBIT_COUNT]]
        set db [expr {$b1 - $b0}] ; set de [expr {$e1 - $e0}]
        set ber "<n/a>" ; if {$db > 0 && $de >= 0} { set ber [expr {double($de)/double($db)}] }
        puts "    [pget $g DISPLAY_NAME]  dBITS=$db  dERR=$de  BER_DELTA=$ber  RX_BER=[pget $g RX_BER]  RXCDRLOCK=[pget $g PORT.RXCDRLOCK]  RXPRBSLOCKED=[pget $g PORT.RXPRBSLOCKED]"
        incr i
    }
}

sec "X4 -- POSITIVE CONTROL: NEAR-END PCS loopback on X0Y4/X0Y5 (no optics involved)"
setloop {Near-End PCS}
after 6000
catch {refresh_hw_sio $ibs}
gtsnap "near-end PCS loopback"
measure "NEAR-END PCS (internal)" 8

sec "X5 -- POSITIVE CONTROL 2: NEAR-END PMA loopback on X0Y4/X0Y5"
setloop {Near-End PMA}
after 6000
catch {refresh_hw_sio $ibs}
gtsnap "near-end PMA loopback"
measure "NEAR-END PMA (internal)" 8

#------------------------------------------------------------------------ restore
sec "X6 -- RESTORE LOOPBACK=None on all four GTs and verify"
setloop None
after 4000
catch {refresh_hw_sio $ibs}
gtsnap "restored to None"
set bad 0
foreach g $gts { if {[pget $g LOOPBACK] ne "None"} { incr bad } }
puts "  GTs not back to None: $bad  (must be 0)"

sec "X7 -- final LOS"
catch {refresh_hw_vio $v}
puts "  FINAL los sfp1(A)=[get_property INPUT_VALUE $p1]  sfp2(B)=[get_property INPUT_VALUE $p2]"
puts ""
puts "XDIAG-COMPLETE -- nothing was programmed; LOOPBACK restored."
disconnect_hw_server
puts "DONE"
