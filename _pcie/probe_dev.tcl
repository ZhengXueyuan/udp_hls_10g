# probe_dev.tcl - 只读: 经 hw_server 看 KU5P 器件状态 (不改任何东西)
open_hw_manager
connect_hw_server -url 192.168.0.38:3121
puts "==== HW_SERVERS ===="
foreach s [get_hw_servers] { puts "  server: $s" }
set tgt [lindex [get_hw_targets] 0]
puts "==== TARGET: $tgt ===="
open_hw_target $tgt
foreach d [get_hw_devices] {
    puts "  device: $d"
    foreach p {PART IS_PROGRAMMED REGISTER.IR.IDCODE PROGRAM.FILE} {
        if {[catch {get_property -quiet $p $d} v]} { set v "<n/a>" }
        puts "     $p = $v"
    }
}
close_hw_target
disconnect_hw_server
close_hw_manager
