# jtag_probe_readonly.tcl -- read-only JTAG probe of the KU5P via the peer hw_server.
# DISCIPLINE: connect + open target + refresh ONLY.
#   * NO program_hw_devices   (burning is decided by the controller, not by this script)
#   * NEVER writes the on-board QSPI
set url 192.168.0.38:3121

open_hw_manager
connect_hw_server -url $url
puts "HW_SERVER_CONNECTED url=$url"
puts "HW_TARGETS = [get_hw_targets]"
set tgt [lindex [get_hw_targets] 0]
open_hw_target $tgt
puts "HW_TARGET_OPENED = $tgt"
set_property PARAM.FREQUENCY 1000000 [get_hw_targets $tgt]
puts "JTAG_FREQ_SET = 1000000"
puts "HW_DEVICES = [get_hw_devices]"
set dev [lindex [get_hw_devices xcku5p*] 0]
current_hw_device $dev
puts "CURRENT_DEVICE = $dev"
if {[catch {get_property PART $dev} v]} { puts "DEVICE_PART = <err: $v>" } else { puts "DEVICE_PART = $v" }
if {[catch {get_property IDCODE $dev} v]} { puts "DEVICE_IDCODE = <err: $v>" } else { puts "DEVICE_IDCODE = $v" }
if {[catch {get_property IR_LENGTH $dev} v]} { puts "DEVICE_IR_LENGTH = <err: $v>" } else { puts "DEVICE_IR_LENGTH = $v" }
if {[catch {get_property PROGRAM.IS_PROGRAMMED $dev} v]} { puts "DEVICE_IS_PROGRAMMED = <err: $v>" } else { puts "DEVICE_IS_PROGRAMMED = $v" }
if {[catch {refresh_hw_device -update_hw_probes false $dev} v]} { puts "REFRESH_ERR = $v" } else { puts "REFRESH_DONE" }
puts "READONLY_PROBE_DONE (no program_hw_devices was called)"
close_hw_target
disconnect_hw_server
close_hw_manager
exit 0
