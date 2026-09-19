#=============================================================================
# udp_hls_10g/hls/run_hls_active_board.tcl -- P4d board netlist (ACTIVE_CONNECT=1)
#=============================================================================
# Same csynth flow as run_hls.tcl, with the TCP active-connect (client) code
# compiled in at BOARD parameters (all defaults from src/layer_tcp.cpp):
#   ACTIVE_IP   = 192.168.100.1  (the PC -- board is .2)
#   ACTIVE_PORT = 9090
#   ACTIVE_ISS  = 0x89ABCDEF
#   ACTIVE_DELAY= 250000000 passes (~2 s after reset)
#   ARP who-has retry x3, interval 5000000 passes; after the retry budget the
#   state machine returns to ACT_WAIT and re-arms (self-retrying every few s).
#   TCP_RTO_MIN = 10000000 (default ~80 ms) -- real SYN retransmit on board.
#
# NB: this OVERWRITES slowstack_prj/solution1/syn/verilog (sim gates read that
#     dir). Re-run run_hls.bat afterwards to restore the default
#     (ACTIVE_CONNECT=0) netlist for the chain/burst regression gates.
#=============================================================================

open_project -reset slowstack_prj
add_files src/udp_echo.cpp -cflags "-DACTIVE_CONNECT=1"
set_top udp_echo

open_solution -reset solution1
set_part {xc7k325tffg676-2}
create_clock -period 8 -name default

# Reset: async, active low
config_rtl -reset all -reset_async -reset_level low

puts "\n===== C SYNTHESIS (ACTIVE_CONNECT=1, board params) ====="
csynth_design

puts "\n===== CSYNTH DONE ====="
exit
