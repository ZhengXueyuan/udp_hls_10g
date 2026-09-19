#=============================================================================
# udp_hls_10g/hls/run_hls_active.tcl -- P5 PCACTIVE sim netlist build
#=============================================================================
# Same csynth flow as run_hls.tcl, with the P5 TCP active-connect (client)
# code compiled in and the power-on timers scaled down for simulation.
#
# NB: this OVERWRITES slowstack_prj/solution1/syn/verilog (the sim reads that
#     dir). Re-run run_hls.bat afterwards to restore the default
#     (ACTIVE_CONNECT=0) netlist for the chain/burst regression gates.
#
# Macros overridden here (defaults live in src/layer_tcp.cpp):
#   ACTIVE_CONNECT=1     enable the active-connect state machine
#   ACTIVE_IP=0xC0A86463 sim-only target 192.168.100.99 -- an address the
#                        static stimulus never advertises, which forces the
#                        ARP who-has query path before the SYN (the default
#                        192.168.100.1 is pre-learned from the stimulus' first
#                        ARP request, leaving that path unexercised). The
#                        testbench PCA_ACT_IP constant must match.
#   ACTIVE_DELAY=2000    power-on wait, in top-level passes (~2 s on board =
#                        250000000); sim needs the SYN inside the TB window
#   ACTIVE_ARP_INTERVAL=100  who-has retry interval (passes; board 5000000)
#=============================================================================

open_project -reset slowstack_prj
add_files src/udp_echo.cpp -cflags "-DACTIVE_CONNECT=1 -DACTIVE_IP=0xC0A86463 -DACTIVE_DELAY=2000 -DACTIVE_ARP_INTERVAL=100"
set_top udp_echo

open_solution -reset solution1
set_part {xc7k325tffg676-2}
create_clock -period 8 -name default

# Reset: async, active low
config_rtl -reset all -reset_async -reset_level low

puts "\n===== C SYNTHESIS (ACTIVE_CONNECT=1) ====="
csynth_design

puts "\n===== CSYNTH DONE ====="
exit
