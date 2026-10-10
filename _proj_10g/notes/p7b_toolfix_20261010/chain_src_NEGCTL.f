# chain_src.f -- DECLARED compile file list for the P4 full-chain gates:
#   chain, burst200, trunc50, trunc100, halfdrop, txdrop50, gate4096,
#   dupstorm, pcackoob, vlanchain, vlanburst, stallgate
# TB: tb/tb_p4_chain.v  (xelab top xil_defaultlib.tb_p4_chain)
# Entries are repo-relative; the gate .bat carries the same list expanded as
# %REPO_ROOT%\...  -- sim/p4gates/p4gate.py manifestcheck asserts the two agree.
rtl/crc32_8b.v
rtl/fifo_sync.v
rtl/checksum16.v
rtl/frame_fifo.v
rtl/mac_rx_64.v
rtl/mac_tx_64.v
rtl/tcp_cam.v
rtl/tcb.v
rtl/tcp_rx.v
rtl/tcp_tx_frame.v
rtl/retx_ram.v
rtl/tcp_echo.v
rtl/axis_pipe.v
rtl/rx_classify.v
rtl/vlan_strip.v
rtl/slow_cfg_adp.v
rtl/slow_rx_adp.v
rtl/slow_tx_adp.v
rtl/tx_arb.v
tb/tb_p4_chain.v
board/wrapper_p4.v
rtl/app_pattern.v
