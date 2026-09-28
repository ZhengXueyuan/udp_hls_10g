# idly_probe.tcl - 综合+布局+布线 实证 IDELAYE3 在 bank86(HDIOB) 是否合法
set part_name xcku5p-ffvb676-1-e
read_verilog idly_probe.v
read_xdc idly_probe.xdc
synth_design -top idly_probe -part $part_name -flatten_hierarchy none
puts "### SYNTH OK"
opt_design
puts "### OPT OK"
place_design
puts "### PLACE OK"
phys_opt_design
route_design
puts "### ROUTE OK"
report_utilization -file idly_probe_util.rpt
report_drc -file idly_probe_drc.rpt
report_timing_summary -file idly_probe_timing.rpt
puts "### PROBE_RESULT: IDELAYE3_in_HDIO_BANK86_ACCEPTED"
