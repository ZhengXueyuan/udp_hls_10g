#=============================================================================
# dryrun_stub.tcl -- EXECUTE probe_p7a_board.tcl against a fake hw_server.
#
#   Purpose: catch Tcl faults (bad subscripts, unbalanced quoting, wrong proc
#   arity, format strings) BEFORE spending a 13-minute Vivado session and a
#   JTAG program cycle on the real board.
#
#   Run:  C:/AMDDesignTools/2025.2/Vivado/bin/unwrapped/win64.o/tclsh86t.exe dryrun_stub.tcl
#
#   It is NOT a functional test: the fake VIO invents counters that advance with
#   real elapsed time at exactly 1e10 bit/s and 156.25e6 obs cycles/s, so the
#   rate arithmetic is exercised -- but nothing here says anything about the
#   board.  The only verdict it can give is "the script ran to the end".
#=============================================================================

set ::env(P7A_SECS) 3
set ::env(P7A_SHORT) 2
set ::here [file dirname [info script]]

#------------------------------------------------------------------ exit capture
rename exit real_exit
proc exit {code} { error "SCRIPT_EXIT code=$code" }

#------------------------------------------------------------------ fake state
set ::PROBES {}
unset -nocomplain ::fake
proc mkprobe {name props} { dict set ::PROBES $name $props }

foreach {n w} {vio_err_snap 64 vio_bits_snap 96 vio_hdrs_snap 96 vio_hdre_snap 64 \
               vio_rxcyc_snap 96 vio_rxdvcyc_snap 96 vio_status 96 \
               raw_snap 1 raw_clear 1 raw_slip 1 raw_gt_reset 1} {
    mkprobe $n [dict create NAME $n WIDTH $w _KIND in]
}
dict set ::PROBES raw_snap _KIND out
dict set ::PROBES raw_clear _KIND out
dict set ::PROBES raw_slip _KIND out
dict set ::PROBES raw_gt_reset _KIND out
dict set ::PROBES fake_dev [dict create PART xcku5p-ffvb676-1-e IDCODE_HEX 04A62093 \
                             REGISTER.CONFIG_STATUS.BIT\[14\]_DONE_PIN 1]

proc fake_init {} {
    set ::fake(bits0) 0 ;  set ::fake(bits1) 0
    set ::fake(err0) 0  ;  set ::fake(err1) 0
    set ::fake(hdrs0) 0 ;  set ::fake(hdrs1) 0
    set ::fake(hdre0) 0 ;  set ::fake(hdre1) 0
    set ::fake(rxcyc0) 0 ; set ::fake(rxcyc1) 0
    set ::fake(rxdvc0) 0 ; set ::fake(rxdvc1) 0
    set ::fake(fr) 0 ; set ::fake(ack) 0 ; set ::fake(acq) 0 ; set ::fake(slip) 0
    set ::fake(last) [clock microseconds]
}
fake_init

proc fake_refresh {} {
    set now [clock microseconds]
    set dt [expr {$now - $::fake(last)}]
    set ::fake(last) $now
    if {$dt < 0} { set dt 0 }
    if {$::fake(acq)} {
        # 1e10 payload bit/s and 156.25e6 obs cycles/s, scaled by REAL elapsed time
        set db [expr {$dt * 10000}]
        incr ::fake(bits0) $db ; incr ::fake(bits1) $db
        set df [expr {int($dt * 156.25)}]
        set ::fake(fr) [expr {$::fake(fr) + $df}]
        set dh [expr {int($dt * 15)}]
        incr ::fake(hdrs0) $dh ; incr ::fake(hdrs1) $dh
        incr ::fake(rxcyc0) $df ; incr ::fake(rxcyc1) $df
        incr ::fake(rxdvc0) $df ; incr ::fake(rxdvc1) $df
    }
    if {$::fake(slip)} {
        # one-time burst, then the sticky link-down latch stays set
        if {![info exists ::fake(burst)]} {
            set ::fake(burst) 1
            incr ::fake(err0) 20000 ; incr ::fake(err1) 20000
        }
    }
}

# bignum-safe hex: this tclsh may be a 32-bit build, where format %X silently
# yields zeros for any value above 2^31 (that is how this harness was found to
# be wrong -- and it is why the real script never formats a large value).
proc tohex {v} {
    set digits "0123456789ABCDEF"
    if {$v < 0}  { error "tohex: negative" }
    if {$v == 0} { return "0" }
    set s ""
    while {$v > 0} {
        set s "[string index $digits [expr {$v % 16}]]$s"
        set v [expr {$v / 16}]
    }
    return $s
}
proc padhex {v n} {
    set h [tohex $v]
    while {[string length $h] < $n} { set h "0$h" }
    return $h
}

proc fake_status {} {
    set v 0
    set v [expr {$v | ($::fake(fr) & 0xFFFFFFFFFFFF)}]
    set v [expr {$v | ($::fake(ack) << 48)}]
    set v [expr {$v | (1 << 49)}]            ;# mmcm_locked
    set v [expr {$v | (1 << 50)}]            ;# gtpowergood ch0
    set v [expr {$v | (1 << 51)}]            ;# gtpowergood ch1
    set v [expr {$v | (1 << 52)}]            ;# tx_reset_done
    set v [expr {$v | (1 << 53)}]            ;# rx_reset_done
    set v [expr {$v | (1 << 54)}]            ;# cdr_stable
    # 55/56 los = 0
    set v [expr {$v | ($::fake(acq) << 57)}]
    set v [expr {$v | ($::fake(acq) << 58)}]
    set v [expr {$v | (1 << 59)}]            ;# ref_link ch0
    set v [expr {$v | (1 << 60)}]            ;# ref_link ch1
    set v [expr {$v | ($::fake(slip) << 61)}]
    set v [expr {$v | ($::fake(slip) << 62)}]
    set v [expr {$v | (1 << 63)}]            ;# hdr_ref_valid ch0
    set v [expr {$v | (1 << 64)}]            ;# hdr_ref_valid ch1
    set v [expr {$v | (1 << 70)}]            ;# build fingerprint
    set v [expr {$v | (0x21 << 71)}]         ;# hdr_ref ch0
    set v [expr {$v | (0x21 << 77)}]         ;# hdr_ref ch1
    set v [expr {$v | (3 << 85)}]
    set v [expr {$v | (3 << 87)}]
    return [padhex $v 24]
}
proc fake_value {name} {
    switch -- $name {
        vio_err_snap  { return [padhex [expr {$::fake(err0) | ($::fake(err1) << 32)}] 16] }
        vio_bits_snap { return [padhex [expr {$::fake(bits0) | ($::fake(bits1) << 48)}] 24] }
        vio_hdrs_snap { return [padhex [expr {$::fake(hdrs0) | ($::fake(hdrs1) << 48)}] 24] }
        vio_hdre_snap { return [padhex [expr {$::fake(hdre0) | ($::fake(hdre1) << 32)}] 16] }
        vio_rxcyc_snap { return [padhex [expr {$::fake(rxcyc0) | ($::fake(rxcyc1) << 48)}] 24] }
        vio_rxdvcyc_snap { return [padhex [expr {$::fake(rxdvc0) | ($::fake(rxdvc1) << 48)}] 24] }
        vio_status    { return [fake_status] }
        raw_snap      { return $::raw_snap }
        raw_clear     { return $::raw_clear }
        raw_slip      { return $::raw_slip }
        raw_gt_reset  { return $::raw_gt_reset }
    }
    return 0
}

#------------------------------------------------------------------ API stubs
proc get_property {name obj args} {
    if {[dict exists $::PROBES $obj]} {
        set d [dict get $::PROBES $obj]
        if {$name eq "INPUT_VALUE"}       { return [fake_value $obj] }
        if {$name eq "INPUT_VALUE_RADIX"} { return "HEX" }
        if {[dict exists $d $name]}       { return [dict get $d $name] }
    }
    return "<MISSING:$name>"
}
proc set_property {args} {
    if {[llength $args] == 3} {
        set name [lindex $args 0] ; set val [lindex $args 1] ; set obj [lindex $args 2]
    } elseif {[llength $args] == 2} {
        set d [lindex $args 0] ; set o [lindex $args 1]
        set name [lindex $d 0] ; set val [lindex $d 1] ; set obj $o
    } else { return }
    if {$name eq "OUTPUT_VALUE"} {
        set n [expr {int("0x$val")}]
        switch -- $obj {
            raw_snap  { set ::raw_snap $n ; if {$n==1} { set ::fake(ack) [expr {!$::fake(ack)}] } }
            raw_clear { set ::raw_clear $n ; if {$n==1} { set ::fake(acq) 1 } }
            raw_slip  { set ::raw_slip $n ; if {$n==1} { set ::fake(slip) 1 } }
            raw_gt_reset { set ::raw_gt_reset $n }
        }
    }
    return
}
set ::raw_snap 0 ; set ::raw_clear 0 ; set ::raw_slip 0 ; set ::raw_gt_reset 0
proc open_hw_manager {} {}
proc connect_hw_server {args} {}
proc get_hw_targets {} { return {fake_target} }
proc current_hw_target {args} { return fake_target }
proc open_hw_target {args} {}
proc get_hw_devices {} { return {fake_dev} }
proc current_hw_device {args} { return fake_dev }
proc refresh_hw_device {args} {}
proc program_hw_devices {args} {}
proc get_hw_vios {args} { return {fake_vio} }
proc get_hw_probes {args} { return {vio_err_snap vio_bits_snap vio_hdrs_snap vio_hdre_snap vio_rxcyc_snap vio_rxdvcyc_snap vio_status raw_snap raw_clear raw_slip raw_gt_reset} }
proc refresh_hw_vio {args} { fake_refresh }
proc commit_hw_vio {args} {}
proc disconnect_hw_server {} {}
proc version {args} { return "dry-run-stub" }

#------------------------------------------------------------------ run it
puts "==== DRY RUN: asserting the script runs end to end (no board involved) ===="
set rc [catch { source [file join $::here probe_p7a_board.tcl] } emsg]
puts ""
puts "==== DRY RUN RESULT ===="
puts "catch rc = $rc"
puts "DBG fake_status        = [fake_status]"
puts "DBG fake_value         = [fake_value vio_status]"
puts "DBG get_property(IV)   = [get_property INPUT_VALUE vio_status]"
puts "DBG probe dict         = [dict get $::PROBES vio_status]"
if {$rc} {
    puts "ERROR   = $emsg"
    puts "INFO    = $::errorInfo"
    puts "DRYRUN  = FAIL (the script faulted; fix before touching the board)"
} else {
    puts "DRYRUN  = PASS (no Tcl fault; hardware behaviour still unproven)"
}
