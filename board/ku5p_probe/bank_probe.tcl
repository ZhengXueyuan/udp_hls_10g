# bank_probe.tcl - KU5P 关键引脚所属 bank + IDELAY 可用性 (只读, 无工程)
set part_name xcku5p-ffvb676-1-e
link_design -part $part_name
set pins {B10 E11 E10 D10 A10 D11 F9 F10 K9 K10 G9 J10 G10 B9 A9 T25 U25 AB7 J9}
puts "PIN  FUNC            BANK  IOSTANDARD-CAP"
foreach p $pins {
    set pp [get_package_pins $p]
    if {[llength $pp] == 0} { puts "$p  <NOT FOUND>"; continue }
    puts [format "%-4s %-15s %-5s" $p [get_property PIN_FUNC $pp] [get_property BANK $pp]]
}
puts "=== IOBANK 列表 (USED_PINS 可能为空) ==="
foreach b [get_iobanks] {
    set t "-"; catch { set t [get_property BANK_TYPE $b] }
    puts "bank [get_property NAME $b] type=$t"
}
puts "=== IDELAY/ODELAY site ==="
set dly [get_sites -quiet -filter {SITE_TYPE =~ "*IDELAY*"}]
set odly [get_sites -quiet -filter {SITE_TYPE =~ "*ODELAY*"}]
puts "IDELAY sites = [llength $dly]  (前 3: [lrange $dly 0 2])"
puts "ODELAY sites = [llength $odly] (前 3: [lrange $odly 0 2])"
puts "=== IOB33 site 数 ==="
puts "IOB33 = [llength [get_sites -quiet -filter {SITE_TYPE == IOB33}]]"
