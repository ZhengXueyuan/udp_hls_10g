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
#   TCP_RTO_MIN=2000         P1-2: min RTO in passes (board 10000000 = ~80ms).
#                            The PCACTIVE slow-peer gate (run_tb_p4_chain_
#                            active_slow.bat, pcslow.memh=1) withholds the
#                            SYN+ACK so the board must retransmit the SYN --
#                            this scales that RTO into the TB tail window so the
#                            T_SYN_SENT retransmit path is really exercised
#                            (previously zero coverage).
#                            Calibration (measured in xsim, NOT 1 pass/cycle):
#                            TB window = 250k cycles; 1st SYN captured at
#                            k_syn ~= 70k; with the P1-2 idle tick (udp_echo.cpp,
#                            ACTIVE-guarded) 3000 passes -> 2nd SYN at k_syn2 =
#                            225994 (52 cycles/pass) -- only ~10% margin. 2000
#                            passes -> ~104k -> retransmit ~174k (~30% margin).
#                            The 2nd RTO (+4000 passes) falls outside the window,
#                            so exactly ONE retransmit is exercised -- hence
#                            check_active asserts syn_cnt>=2 (retransmit >= 1);
#                            the TCP_MAX_RETRY release path (4 timeouts) is left
#                            to board-level test.
#=============================================================================

open_project -reset slowstack_prj
add_files src/udp_echo.cpp -cflags "-DACTIVE_CONNECT=1 -DACTIVE_IP=0xC0A86463 -DACTIVE_DELAY=2000 -DACTIVE_ARP_INTERVAL=100 -DTCP_RTO_MIN=2000"
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
