# pin_probe.tcl - P6b: T25/U25 clock capability / bank / VCCO / MMCM reachability
# READ-ONLY device-model queries. No project, no bitstream.
set part_name xcku5p-ffvb676-1-e
link_design -part $part_name

proc dump_props {obj title} {
    puts "=== $title ==="
    if {[llength $obj] == 0} { puts "  <EMPTY OBJECT>"; return }
    foreach prop [lsort [list_property $obj]] {
        set v "-"
        catch { set v [get_property $prop $obj] }
        puts [format "  %-32s = %s" $prop $v]
    }
}

foreach p {T25 U25} {
    set pp [get_package_pins $p]
    puts "################ PACKAGE PIN $p ################"
    puts "PIN_FUNC = [get_property PIN_FUNC $pp]"
    puts "BANK     = [get_property BANK $pp]"
    puts "IS_GLOBAL_CLK / IS_CLOCK_CAPABLE (raw prop dump follows)"
    dump_props $pp "ALL PROPS of package pin $p"

    set st [get_sites -quiet -of_objects $pp]
    puts "--- site of $p = $st"
    if {[llength $st]} {
        puts "SITE_TYPE = [get_property SITE_TYPE $st]"
        dump_props $st "ALL PROPS of site [get_property NAME $st]"
    }
}

puts "################ IO BANKS ################"
foreach b [get_iobanks] {
    set nm [get_property NAME $b]
    set ty "-"; catch { set ty [get_property BANK_TYPE $b] }
    puts "--- bank $nm type=$ty"
    foreach prop [lsort [list_property $b]] {
        set v "-"; catch { set v [get_property $prop $b] }
        if {$v ne ""} { puts [format "      %-24s = %s" $prop $v] }
    }
}

puts "################ CLOCK-CAPABLE PINS in bank 65 ################"
set b65pins [get_package_pins -quiet -of_objects [get_iobanks 65]]
puts "bank65 pin count = [llength $b65pins]"
foreach pp [lsort $b65pins] {
    set f [get_property PIN_FUNC $pp]
    if {[string match "*GC*" $f]} { puts "  GC: [get_property NAME $pp]  $f" }
}
puts "--- pins of bank 65 (all) ---"
foreach pp [lsort $b65pins] { puts "  [get_property NAME $pp]  [get_property PIN_FUNC $pp]" }

puts "################ MMCM / PLL / BUFG SITES ################"
foreach t {MMCME4_ADV MMCME4_BASE PLLE4_ADV BUFGCTRL BUFG_GT} {
    set s [get_sites -quiet -filter "SITE_TYPE == $t"]
    puts "  $t sites = [llength $s]   first: [lrange $s 0 3]"
}
puts "--- all unique SITE_TYPE containing MMCM/PLL/BUFG ---"
foreach t [lsort -unique [get_property SITE_TYPE [get_sites]]] {
    if {[string match "*MMCM*" $t] || [string match "*PLL*" $t] || [string match "*BUFG*" $t]} {
        puts "  $t : [llength [get_sites -quiet -filter "SITE_TYPE == $t"]]"
    }
}

puts "################ CLOCK REGION of T25 site / MMCM sites ################"
set st25 [get_sites -quiet -of_objects [get_package_pins T25]]
if {[llength $st25]} {
    set cr "-"; catch { set cr [get_property CLOCK_REGION $st25] }
    puts "T25 site=[get_property NAME $st25] CLOCK_REGION=[get_property NAME $cr]"
}
foreach s [get_sites -quiet -filter {SITE_TYPE =~ "MMCM*"}] {
    set cr "-"; catch { set cr [get_property CLOCK_REGION $s] }
    puts "MMCM [get_property NAME $s] CLOCK_REGION=[get_property NAME $cr]"
}
puts "################ BUFG sites near T25 ################"
foreach s [get_sites -quiet -filter {SITE_TYPE == BUFGCTRL}] {
    set cr "-"; catch { set cr [get_property CLOCK_REGION $s] }
    puts "BUFGCTRL [get_property NAME $s] CLOCK_REGION=[get_property NAME $cr]"
}
puts "### PIN_PROBE_DONE"
