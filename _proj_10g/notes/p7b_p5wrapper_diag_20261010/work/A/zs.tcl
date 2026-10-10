run 4000ns
puts "TCLPROBE time=[current_time]"
if {[catch {set objs [get_objects -filter {type == net}]} e]} {
    puts "TCLPROBE get_objects FAILED: $e"
    exit 0
}
set n 0
set nz 0
foreach o $objs {
    incr n
    if {[catch {set v [get_value -radix hex $o]} e2]} { continue }
    if {[string match "*z*" $v] || [string match "*x*" $v]} {
        incr nz
        if {$nz <= 40} { puts "TCLZ obj=$o val=$v" }
    }
}
puts "TCLPROBE nets=$n zx=$nz"
exit 0
