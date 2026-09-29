#=============================================================================
# ku5p_p7a_impl.xdc -- P7a constraints that need an ELABORATED design
#=============================================================================
#
#  Marked `used_in_synthesis false` by build_p7a.tcl, so it is read at
#  implementation time -- when the GT's clocks, the debug hub and the
#  synthesised cell names all exist. That ordering matters: the P6b work already
#  hit the failure mode where an XDC is parsed before synthesis, the object
#  lookups return nothing, and Vivado answers with a single
#  [Vivado 12-4739] set_clock_groups: No valid object(s) found
#  and then SILENTLY DROPS the constraint. grep the impl log for 12-4739: a hit
#  means the constraint below is NOT in force.
#
#  ⚠ No if / foreach / puts in this file. The first P7a build used them and
#    every guarded block was rejected with [Designutils 20-1307] "Command 'if'
#    is not supported in the xdc constraint file" -- silently. Everything here
#    is a plain constraint command, and each object lookup was dry-run against
#    the routed design first (reports/p7a_readback.txt section P8 records the
#    counts: tgl syncs 4 pins each, bit syncs 4/4/8/28, obs syncs 4/4/3,
#    snapshot sources 501, VIO destinations 5586).
#=============================================================================

# ---------------------------------------------------------------- debug hub
# The VIO core is clocked by clk_obs = 156.25 MHz, so the debug hub must be told
# that frequency: it sets the JTAG:broadcast clock ratio used for every probe
# access. Leaving it at the default while clocking it at 156.25 MHz is the kind
# of defect that shows up as intermittent VIO failures rather than an error.
set_property C_CLK_INPUT_FREQ_HZ 156250000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER true     [get_debug_cores dbg_hub]

# ---------------------------------------------------------------- clock domains
# Two unrelated physical sources:
#   sys_clk   -> MMCM -> g_hw.clk_out0  = clk_obs  (observation domain, VIO)
#   gtrefclk0 -> QPLL/CDR -> clk_tx / clk_rx (payload domains)
# clk_rx is RECOVERED FROM THE INCOMING DATA, so it is asynchronous to the
# crystal-derived clock even though both are nominally 156.25 MHz. Every
# crossing between them is either a 2/3-flop synchroniser or a static snapshot
# value, so both domains belong out of timing analysis entirely.
# Dry run on the routed design: sys_clk group = {sys_clk, g_hw.clk_out0},
# gtrefclk0 group = 7 clocks (qpll0outclk/qpll0outrefclk/userclk srcclks) --
# non-overlapping, set_clock_groups rc=0.
set_clock_groups -asynchronous -group [get_clocks -include_generated_clocks sys_clk] -group [get_clocks -include_generated_clocks gtrefclk0]

# ---------------------------------------------------------------- CDC false paths
# Belt and braces for the crossings, anchored to CELLS rather than to clock
# names, and only on the first flop of each synchroniser:
#   observation -> payload : the toggle synchronisers (p7a_tgl_sync)
#   payload -> observation : p7a_bit_sync level synchronisers, and the frozen
#                            snapshot registers read by the VIO's input flops
set_false_path -to [get_pins -quiet -hierarchical -filter {REF_PIN_NAME == D && NAME =~ *u_snap_sync*}]
set_false_path -to [get_pins -quiet -hierarchical -filter {REF_PIN_NAME == D && NAME =~ *u_clear_sync*}]
set_false_path -to [get_pins -quiet -hierarchical -filter {REF_PIN_NAME == D && NAME =~ *u_slip_sync*}]
set_false_path -to [get_pins -quiet -hierarchical -filter {REF_PIN_NAME == D && NAME =~ *u_sync_match*}]
set_false_path -to [get_pins -quiet -hierarchical -filter {REF_PIN_NAME == D && NAME =~ *u_sync_acq*}]
set_false_path -to [get_pins -quiet -hierarchical -filter {REF_PIN_NAME == D && NAME =~ *u_sync_rxdv*}]
set_false_path -to [get_pins -quiet -hierarchical -filter {REF_PIN_NAME == D && NAME =~ *u_sync_href*}]
set_false_path -to [get_pins -quiet -hierarchical -filter {REF_PIN_NAME == D && NAME =~ *clr_sr*}]
set_false_path -to [get_pins -quiet -hierarchical -filter {REF_PIN_NAME == D && NAME =~ *snap_sr*}]
set_false_path -to [get_pins -quiet -hierarchical -filter {REF_PIN_NAME == D && NAME =~ *ack_sr*}]
set_false_path -from [get_cells -quiet -hierarchical -filter {NAME =~ *u_counters/*_snap*_r_reg*}] -to [get_cells -quiet -hierarchical -filter {NAME =~ *u_vio*/*}]
