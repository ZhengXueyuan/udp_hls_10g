# program_soak.tcl -- JTAG-program the P6b FINAL bitstream onto the KU5P (TCK 1 MHz).
#   NEW file added by the P6b long-soak probe agent; modifies NO existing script.
#   JTAG volatile programming only -- NEVER touch the on-board QSPI.
#   Do NOT run while a Vivado build is in progress (board-measurement precondition).
#   After programming, the HOST MUST BE REBOOTED (PCIe endpoint only enumerates when
#   FPGA configuration precedes host POST).
#
#   Bitstream identity (frozen copy, sha256 verified by the caller):
#     soak_scratch/soak_frozen.bit
#       sha256 = c17700868b08170865f4a4ae0292ebb636aed03070e2875f6dbb005123a948ca
#     (origin = vivado_prj/p6b_final_ku5p_prj.runs/impl_1/wrapper_p4.bit, same sha256;
#      the stale p6b_ku5p_prj tree copy 03f9c6d0... must NOT be used)
set bit D:/repo/XCKU5PMini/udp_hls_10g/_proj_pcie/soak_scratch/soak_frozen.bit

open_hw_manager
connect_hw_server -url 192.168.0.38:3121
set tgt [lindex [get_hw_targets] 0]
open_hw_target $tgt
set dev [lindex [get_hw_devices xcku5p*] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
set_property PARAM.FREQUENCY 1000000 [get_hw_targets $tgt]
if {![file exists $bit]} { puts "PROG ERROR: bitstream missing: $bit"; exit 1 }
puts "PROG device=$dev freq=1MHz file=$bit size=[file size $bit]"
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
refresh_hw_device -update_hw_probes false $dev
puts "PROG DONE (acceptance: 'End of startup status: HIGH' must appear above)"
close_hw_target
disconnect_hw_server
close_hw_manager
