# synth_one.tcl -- single minimal synth_design over one case file.
# usage: vivado -mode batch -source synth_one.tcl -tclargs <case_name> <top_module>
# (caller redirects the whole vivado stdout to the case log)
set case [lindex $argv 0]
set top  [lindex $argv 1]
set root "D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/notes/p7b_implicit_repro"
puts "SYNTH_CASE_BEGIN $case top=$top"
read_verilog [file join $root "$case.v"]
if {[catch {synth_design -top $top -part xcku5p-ffvb676-1-e -mode default} msg]} {
    puts "SYNTH_CAUGHT $msg"
    puts "SYNTH_RC=1"
    exit 1
}
puts "SYNTH_RC=0"
puts "SYNTH_CASE_END $case"
