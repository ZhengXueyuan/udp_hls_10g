link_design -part xcku5p-ffvb676-1-e
set all [get_sites]
puts "SITE 总数 = [llength $all]"
puts "=== 唯一 SITE_TYPE ==="
foreach t [lsort -unique [get_property SITE_TYPE $all]] { puts "  $t : [llength [get_sites -quiet -filter "SITE_TYPE == $t"]]" }
puts "=== 名字里含 DELAY 的 site ==="
puts [lrange [get_sites -quiet -filter {NAME =~ "*DELAY*"}] 0 5]
puts "含 DELAY 的 site 数 = [llength [get_sites -quiet -filter {NAME =~ "*DELAY*"}]]"
puts "=== bank 86 里的 site (前 8) ==="
set b86 [get_sites -quiet -of_objects [get_iobanks 86]]
puts "bank86 site 数 = [llength $b86]"
puts [lrange $b86 0 7]
if {[llength $b86]} { puts "类型: [lsort -unique [get_property SITE_TYPE $b86]]" }
