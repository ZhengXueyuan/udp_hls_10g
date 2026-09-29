# mmcm_probe.tcl - list MMCM / PLL sites and clock regions (P6b)
set part_name xcku5p-ffvb676-1-e
link_design -part $part_name
puts "################ MMCM SITES (SITE_TYPE == MMCM) ################"
foreach s [get_sites -quiet -filter {SITE_TYPE == MMCM}] {
    set cr "-"; catch { set cr [get_property CLOCK_REGION $s] }
    puts "  MMCM site [get_property NAME $s]  CLOCK_REGION=$cr"
}
puts "################ PLL SITES ################"
foreach s [get_sites -quiet -filter {SITE_TYPE == PLL}] {
    set cr "-"; catch { set cr [get_property CLOCK_REGION $s] }
    puts "  PLL site [get_property NAME $s]  CLOCK_REGION=$cr"
}
puts "################ MMCM site ALL PROPS (first one) ################"
set s0 [lindex [get_sites -quiet -filter {SITE_TYPE == MMCM}] 0]
foreach prop [lsort [list_property $s0]] {
    set v "-"; catch { set v [get_property $prop $s0] }
    puts [format "  %-28s = %s" $prop $v]
}
puts "################ BUFGCTRL sites + clock region ################"
foreach s [get_sites -quiet -filter {SITE_TYPE == BUFGCTRL}] {
    set cr "-"; catch { set cr [get_property CLOCK_REGION $s] }
    puts "  BUFGCTRL [get_property NAME $s] CR=$cr"
}
puts "################ clock regions ################"
foreach cr [get_clock_regions] { puts "  CR [get_property NAME $cr]" }
puts "### MMCM_PROBE_DONE"
