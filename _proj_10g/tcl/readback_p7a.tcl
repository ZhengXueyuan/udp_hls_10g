#=============================================================================
# readback_p7a.tcl -- P7a static criteria 1 / 2 / 3, read from the ROUTED design
#=============================================================================
#
#  Run:  vivado -mode batch -source readback_p7a.tcl -nojournal -nolog
#        (or via tcl/run_readback_p7a.bat)
#
#  Reads the implemented checkpoint produced by build_p7a.tcl. Nothing is
#  rebuilt here -- this is a read-only pass, and it is deliberately a SEPARATE
#  script so the numbers can be re-read without another build.
#
#  What it produces (all printed AND written to reports/p7a_readback.txt):
#    [1] every GTYE4_CHANNEL's GEARBOX_MODE / TXGEARBOX_EN / RXGEARBOX_EN /
#        TX_DATA_WIDTH / RX_DATA_WIDTH   <- criterion 1 (gearbox in the path)
#    [2] every property of that cell whose name mentions FREQ / PROGDIV /
#        GEARBOX / WIDTH, plus the raw lines from the written netlist that
#        mention PROGDIV or GEARBOX -- so the TXPROGDIV_FREQ_VAL question is
#        answered from the tool, not from expectation
#    [3] the tool-computed clock list with periods (the GT usrclk2 and the MMCM
#        output must both read 6.400 ns) <- criterion 2, tool-computed
#    [4] MMCM parameters (multiply/divide/period) -- the reference counter's
#        frequency is only usable as a ratio reference if these are what the
#        design claims, so they are read back rather than assumed
#    [5] timing: WNS / WHS / WPWS, failing-endpoint counts, and the summary
#        report <- criterion 3
#    [6] utilization + DRC
#=============================================================================

set here [file normalize [file dirname [info script]]]
set root [file normalize [file join $here ..]]
set dcp  [file join $root vivado_prj p7a_prj.runs impl_1 p7a_top_routed.dcp]
set rpt  [file join $root reports p7a_readback.txt]

if {![file exists $dcp]} { error "routed checkpoint not found: $dcp" }

set fp [open $rpt w]
proc out {s} { puts $s ; global fp ; puts $fp $s }

out "P7a static readback -- source: $dcp"
out "VIVADO = [version -short]"

open_checkpoint $dcp

# ------------------------------------------------------------------ criterion 1
out "\n===== [1] GTYE4_CHANNEL gearbox attributes (POST_ROUTE) ====="
set gtcells [get_cells -hier -quiet -filter {REF_NAME =~ GTYE4_CHANNEL*}]
out "GT_CELL_COUNT = [llength $gtcells]"
foreach c $gtcells {
    out "CELL $c"
    foreach p {GEARBOX_MODE TXGEARBOX_EN RXGEARBOX_EN TX_DATA_WIDTH RX_DATA_WIDTH \
               TX_INT_DATA_WIDTH RX_INT_DATA_WIDTH TX_DATA_ENCODING RX_DATA_DECODING} {
        if {[llength [get_property -quiet $p $c]] > 0} {
            out "  $p = [get_property $p $c]"
        }
    }
}

out "\n===== [1b] every FREQ/PROGDIV/GEARBOX/WIDTH property on those cells ====="
foreach c $gtcells {
    foreach p [lsort [list_property $c]] {
        if {[regexp -nocase {freq|progdiv|gearbox|width|encoding|decoding} $p]} {
            catch { out "  $c : $p = [get_property $p $c]" }
        }
    }
}
foreach c [get_cells -hier -quiet -filter {REF_NAME =~ GTYE4_COMMON*}] {
    foreach p [lsort [list_property $c]] {
        if {[regexp -nocase {freq|progdiv|qpll} $p]} {
            catch { out "  $c : $p = [get_property $p $c]" }
        }
    }
}

out "\n===== [1c] netlist text: PROGDIV / GEARBOX assignments ====="
set nl [file join $root reports p7a_post_route_netlist.v]
write_verilog -force -mode design $nl
set fh [open $nl r]
set n 0
while {[gets $fh line] >= 0} {
    if {[regexp -nocase {progdiv|gearbox} $line]} { out "NL: [string trim $line]" ; incr n }
    if {$n > 40} { out "NL: ... (truncated)"; break }
}
close $fh

# ------------------------------------------------------------------ criterion 2
out "\n===== [2] clocks (tool-computed periods) ====="
set clks [get_clocks -quiet]
out "CLOCK_COUNT = [llength $clks]"
foreach c $clks {
    set p "?"
    catch { set p [get_property PERIOD $c] }
    set src "?"
    catch { set src [get_property SOURCE $c] }
    out [format "CLK %-55s period=%s ns  src=%s" $c $p $src]
}

out "\n===== [2b] MMCM parameters (the ratio reference's frequency) ====="
foreach c [get_cells -hier -quiet -filter {REF_NAME =~ MMCME4*}] {
    out "CELL $c"
    foreach p {CLKFBOUT_MULT_F DIVCLK_DIVIDE CLKOUT0_DIVIDE_F CLKIN1_PERIOD CLKOUT0_PHASE BANDWIDTH} {
        catch { out "  $p = [get_property $p $c]" }
    }
}

# ------------------------------------------------------------------ criterion 3
out "\n===== [3] timing ====="
set wns "?"
set whs "?"
catch { set wns [get_property SLACK [get_timing_paths -quiet -delay_type max -max_paths 1]] }
catch { set whs [get_property SLACK [get_timing_paths -quiet -delay_type min -max_paths 1]] }
out "WNS = $wns ns"
out "WHS = $whs ns"
set sfail [llength [get_timing_paths -quiet -delay_type max -slack_lesser_than 0 -max_paths 20000]]
set hfail [llength [get_timing_paths -quiet -delay_type min -slack_lesser_than 0 -max_paths 20000]]
out "SETUP_FAILING_ENDPOINTS = $sfail   (max_paths capped at 20000)"
out "HOLD_FAILING_ENDPOINTS  = $hfail"
set tsrpt [file join $root reports p7a_timing_summary.rpt]
report_timing_summary -file $tsrpt -warn_on_violation
out "TIMING_SUMMARY_RPT = $tsrpt"
if {[file exists $tsrpt]} {
    set fh [open $tsrpt r]
    while {[gets $fh line] >= 0} {
        if {[regexp {WNS|WHS|WPWS|Failing Endpoints|Timing constraints are} $line]} {
            out "TS: [string trim $line]"
        }
    }
    close $fh
}

out "\n===== [4] clocks interaction summary (are the domains declared async?) ====="
set cirpt [file join $root reports p7a_clock_interaction.rpt]
catch { report_clock_interaction -file $cirpt -delay_type min_max -significant_digits 3 }
if {[file exists $cirpt]} {
    set fh [open $cirpt r]
    while {[gets $fh line] >= 0} {
        if {[regexp {Timed \(unsafe\)|Async|clock pair|Inter-Clock} $line]} { out "CI: [string trim $line]" }
    }
    close $fh
}

out "\n===== [5] utilization ====="
set urpt [file join $root reports p7a_utilization.rpt]
report_utilization -file $urpt
if {[file exists $urpt]} {
    set fh [open $urpt r]
    while {[gets $fh line] >= 0} {
        if {[regexp {\| (CLB LUTs|CLB Registers|Block RAM Tile|URAM|DSPs|Bonded IOB|GTYE4_CHANNEL|BUFGCTRL|MMCME4) } $line]} {
            out "UT: $line"
        }
    }
    close $fh
}

out "\n===== [6] DRC + debug cores ====="
set drpt [file join $root reports p7a_drc.rpt]
catch { report_drc -file $drpt }
if {[file exists $drpt]} {
    set fh [open $drpt r]
    while {[gets $fh line] >= 0} {
        if {[regexp {Violations found|Number of violations|^ERROR|^CRITICAL} $line]} { out "DRC: [string trim $line]" }
    }
    close $fh
}
foreach dc [get_debug_cores -quiet] { out "DEBUGCORE $dc" }
out "VIO_CELLS = [llength [get_cells -hier -quiet -filter {REF_NAME =~ vio_*}] ]"
foreach c [get_cells -hier -quiet -filter {NAME =~ *u_vio*}] { out "VIO $c" }

out "\n===== [7] per-module cost (answers spec 9.11: what the counters cost) ====="
# A first attempt filtered cells by module REF_NAME after implementation, which
# returns 0 because the hierarchy is flattened into primitives -- an EMPTY
# read-out that looks like "costs nothing". Hierarchical utilization is the
# measurement that actually answers the question.
set hurpt [file join $root reports p7a_utilization_hier.rpt]
report_utilization -hierarchical -file $hurpt
if {[file exists $hurpt]} {
    set fh [open $hurpt r]
    while {[gets $fh line] >= 0} {
        if {[regexp {u_counters|u_vio_ctrl|u_clk_gen_p6b|u_gt|u_vio\b|u_sync_|u_slip_sync|u_ref[01]|p7a_top} $line]} {
            out "HU: [string trim $line]"
        }
    }
    close $fh
}

# ------------------------------------------------------------------ [8]
# Constraint-command support probe. XDC files accept only a SUBSET of Tcl:
# the first P7a build reported [Designutils 20-1307] "Command 'if'/'foreach'/
# 'puts' is not supported in the xdc constraint file", so every guarded block
# in ku5p_p7a.xdc was SKIPPED -- silently, with the build still reporting
# success. This section applies the candidate replacements to the OPEN design
# and prints, for each, whether it errors and how many objects it matched, so
# the rewritten XDC is verified before it is used for the rebuild.
out "P8 ===== constraint-command support probe (open design, in memory) ====="
set dbg [get_debug_cores -quiet dbg_hub]
out "P8 dbg_hub count = [llength $dbg]"
# read BEFORE anything is applied below: this is what the checkpoint actually
# carries. (The first P7a build had these properties silently skipped, so this
# line is the evidence that the rewritten XDC landed.)
if {[llength $dbg] > 0} {
    catch { out "P8 dbg_hub freq AS DELIVERED = [get_property C_CLK_INPUT_FREQ_HZ $dbg]" }
    catch { out "P8 dbg_hub divider AS DELIVERED = [get_property C_ENABLE_CLK_DIVIDER $dbg]" }
}
if {[llength $dbg] > 0} {
    out "P8 set_property freq rc = [catch {set_property C_CLK_INPUT_FREQ_HZ 156250000 $dbg} e1] msg=$e1"
    out "P8 set_property divider rc = [catch {set_property C_ENABLE_CLK_DIVIDER true $dbg} e1b] msg=$e1b"
    catch { out "P8 dbg_hub freq readback = [get_property C_CLK_INPUT_FREQ_HZ $dbg]" }
}
set p8_fab [get_clocks -quiet -include_generated_clocks sys_clk]
set p8_gt  [get_clocks -quiet -include_generated_clocks gtrefclk0]
out "P8 sys_clk group n=[llength $p8_fab] :: $p8_fab"
out "P8 gtrefclk0 group n=[llength $p8_gt] :: $p8_gt"
if {[llength $p8_fab] > 0 && [llength $p8_gt] > 0} {
    out "P8 set_clock_groups rc = [catch {set_clock_groups -asynchronous -group $p8_fab -group $p8_gt} e2] msg=$e2"
}
foreach {nm inst} [list tgl_snap u_snap_sync tgl_clear u_clear_sync tgl_slip u_slip_sync \
                        bitsync_match u_sync_match bitsync_acq u_sync_acq \
                        bitsync_rxdv u_sync_rxdv bitsync_href u_sync_href \
                        clkobs_clr clr_sr clkobs_snap snap_sr clkobs_ack ack_sr] {
    set pp [get_pins -quiet -hierarchical -filter "REF_PIN_NAME == D && NAME =~ *$inst*"]
    out "P8 falsepath $nm inst=$inst n=[llength $pp] :: [lrange $pp 0 1]"
    if {[llength $pp] > 0} {
        out "P8   set_false_path rc = [catch {set_false_path -to $pp} ef] msg=$ef"
    }
}
set p8src [get_cells -quiet -hierarchical -filter {NAME =~ *u_counters/*_snap*_r_reg*}]
set p8dst [get_cells -quiet -hierarchical -filter {NAME =~ *u_vio*/*}]
out "P8 snaptovio src=[llength $p8src] dst=[llength $p8dst]"
if {[llength $p8src] > 0 && [llength $p8dst] > 0} {
    out "P8 set_false_path snap->vio rc = [catch {set_false_path -from $p8src -to $p8dst} es] msg=$es"
}

out "\nREADBACK_DONE"
close $fp
puts "REPORT = $rpt"
exit
