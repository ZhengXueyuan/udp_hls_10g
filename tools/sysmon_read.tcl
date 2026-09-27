# sysmon_read.tcl -- read the 7-series on-chip System Monitor (XADC) over JTAG.
#
# WHY: the RX-corruption rate drifts ~24x between rounds (0.035%..0.29%) and the
# doc's droop/IR exclusion was explicitly "pure inference - no XADC channel available".
# This closes both: it gives die temperature AND the three core rails, and -- the useful
# part -- the XADC's MIN/MAX latches RESET ON RECONFIGURATION (verified 2026-09-27), so
# because every measurement round begins with a reprogram, current+min+max bracket
# exactly that round. No polling, no design change, no bitstream change, no extra FFs
# (so it cannot perturb the phenomenon being measured).
#
# Usage:
#   vivado.bat -mode batch -log vivado_sysmon.log -nojournal -source tools/sysmon_read.tcl
# Emits ONE machine-parseable ASCII line between the SYSMON_* markers.
# ASCII only: Vivado's console mis-decodes CJK through GBK (seen 2026-09-27).

open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices] 0]
if {$dev eq ""} { puts "SYSMON_ERR no_hw_device"; close_hw_manager; exit 1 }
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

# NOTE: refresh_hw_sysmon takes a POSITIONAL object, not -hw_sysmon
# (2025.2 rejects "-hw_sysmon": ERROR [Common 17-170] Unknown option).
set sm [get_hw_sysmons]
if {$sm eq ""} { puts "SYSMON_ERR no_sysmon_object"; close_hw_manager; exit 1 }
refresh_hw_sysmon $sm

proc g {obj prop} {
    if {[catch {get_property $prop $obj} v]} { return "NA" }
    return $v
}

puts "SYSMON_BEGIN"
puts "SYSMON T=[g $sm TEMPERATURE] TMIN=[g $sm MIN_TEMPERATURE] TMAX=[g $sm MAX_TEMPERATURE] VINT=[g $sm VCCINT] VINTMIN=[g $sm MIN_VCCINT] VINTMAX=[g $sm MAX_VCCINT] VAUX=[g $sm VCCAUX] VAUXMIN=[g $sm MIN_VCCAUX] VAUXMAX=[g $sm MAX_VCCAUX] VBRAM=[g $sm VCCBRAM] VBRAMMIN=[g $sm MIN_VCCBRAM] VBRAMMAX=[g $sm MAX_VCCBRAM]"
puts "SYSMON_END"
close_hw_manager
