# xdc_cmd_support_probe.tcl -- raw evidence for the defect found while building
# the P7a bitstream for the first time:
#
#   [Designutils 20-1307] Command 'if' is not supported in the xdc constraint file
#   [Designutils 20-1307] Command 'foreach' is not supported in the xdc constraint file
#   [Designutils 20-1307] Command 'puts' is not supported in the xdc constraint file
#
# The first ku5p_p7a.xdc guarded the debug-hub property, the clock groups and the
# CDC false paths inside if/foreach blocks. Vivado rejected every one of those
# COMMANDS, so the constraints inside them never ran -- and the build still
# reported success (0 errors, bitstream written). That is the expensive part:
# the design looked constrained and was not.
#
# This script reproduces it in isolation, in one file, so the evidence does not
# depend on a build log that a later rebuild overwrites.
#
# Run: vivado -mode batch -source xdc_cmd_support_probe.tcl -nojournal -nolog

set here [file normalize [file dirname [info script]]]
set part "xcku5p-ffvb676-1-e"
set pdir [file join $here probe_xdc_prj]
file delete -force $pdir
create_project -force probe_xdc $pdir -part $part
set_property target_language Verilog [current_project]

# one port so create_clock has something to bite on
set f [open [file join $pdir p7a_probe_top.v] w]
puts $f "module p7a_probe_top(input wire clk_p, input wire rst, output wire led);"
puts $f "  reg [3:0] c = 4'd0;"
puts $f "  always @(posedge clk_p) c <= c + 4'd1;"
puts $f "  assign led = c[3];"
puts $f "endmodule"
close $f
add_files -norecurse [file join $pdir p7a_probe_top.v]
set_property top p7a_probe_top [current_fileset]

# ---- the candidate constraint file: both flavours, side by side -------------
set x [open [file join $pdir probe.xdc] w]
puts $x "# plan command (expected to be accepted)"
puts $x "create_clock -period 10.000 -name sys_clk \[get_ports clk_p\]"
puts $x "# guarded flavour -- the one that failed in the P7a build"
puts $x "set probe_clk \[get_clocks -quiet sys_clk\]"
puts $x "if {\[llength \$probe_clk\] > 0} {"
puts $x "    set_false_path -from \[get_ports rst\]"
puts $x "    puts \"if-block RAN\""
puts $x "}"
puts $x "foreach pp \[get_ports rst\] { set_false_path -from \$pp }"
puts $x "# plain flavour -- what the rewritten XDC uses"
puts $x "set_false_path -from \[get_ports rst\] -to \[get_ports led\]"
close $x
add_files -fileset constrs_1 -norecurse [file join $pdir probe.xdc]
puts "PROBE_XDC = [file join $pdir probe.xdc]"
puts "PROBE_LOG_MARKER_BEGIN"
# synth_design is what actually READS the constraint file (a project that is only
# created never reads it, which is why the first attempt at this probe produced
# no evidence at all -- an empty log is not a clean log).
synth_design -top p7a_probe_top -part $part
puts "PROBE_SYNTH_RC = ok"
close_project -quiet
puts "PROBE_DONE"
exit
