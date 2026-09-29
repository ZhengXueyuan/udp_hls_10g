#=============================================================================
# xxv_loop_impl.xdc -- constraints that need an ELABORATED design.
# Marked `used_in_synthesis false` by tcl/s2_build.tcl, so it is read at
# implementation time, when the debug hub and the derived GT clocks exist.
#
# WHY THE ORDERING MATTERS (project history, P6b/P7a): an XDC parsed before
# synthesis finds no objects, and Vivado answers with a single
#   [Vivado 12-4739] set_clock_groups: No valid object(s) found
# and then SILENTLY DROPS the constraint while the build still succeeds.
# The build script greps its runme.log for 12-4739 and reports the hit count --
# a hit means the constraint below is NOT in force.
#
# No if / foreach / puts in this file: the XDC parser rejects them with
# [Designutils 20-1307] and skips the whole block, silently (P7a incident).
#=============================================================================

# ---------------------------------------------------------------- debug hub
# The VIO (and therefore the debug hub) is clocked by dclk = 100 MHz.  Leaving
# the hub's assumed frequency at its default is the kind of defect that shows up
# as intermittent probe failures rather than as an error.
set_property C_CLK_INPUT_FREQ_HZ 100000000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER true     [get_debug_cores dbg_hub]

# ---------------------------------------------------------------- clock domains
# Two physically unrelated sources:
#   dclk      <- core board Y1 100 MHz -> IBUFDS/BUFG   (control + observation)
#   gtrefclk0 <- core board Y2 156.25 MHz -> QPLL0 -> {txoutclk, rxoutclk,
#                txoutclkpcs}.  rxoutclk_out is CDR-RECOVERED FROM THE INCOMING
#                DATA, so it is asynchronous to everything even though it is
#                nominally 156.25 MHz.  Vivado nevertheless derives it from the
#                same QPLL and would treat it as synchronous -- which is wrong.
# Every crossing between these two groups is either a 2-flop synchroniser
# (cdc_sync2), a toggle-handshake snapshot (snap_hold), or a value that is
# stable by construction; both groups belong out of timing analysis entirely.
# Dry run on the routed design prints the group membership and the endpoint
# counts (see S2_CG_* lines in the build log).
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks dclk] \
    -group [get_clocks -include_generated_clocks gtrefclk0]
