# p5wrapper_src.f -- DECLARED compile file list for the p5_wrapper gate.
#   gate bat : sim\p5sim\run_tb_p5_wrapper.bat   (registered 2026-10-10, #19)
#   config   : -d APP_MODE ONLY.  No DP_156MHZ / PCIE_OBS / P7B_10G /
#              UDP_TX_OVL / TCP_TX_OVL -- this is the wrapper's single-domain
#              legacy branch, NOT the board build.
#   COVERAGE WARNING (read before quoting this gate):
#     * it is the only standing gate that compiles board/wrapper_p4.v AND
#       rtl/app_pattern.v through a real wrapper instance;
#     * it does NOT cover the board (DP_156MHZ) wrapper configuration, and
#       with TCP_TX_OVL off the r6 tcp_tx_frame `ack_seen` start gate is not
#       in it either -- it cannot stand in for a board-config wrapper gate;
#     * it therefore also cannot see anything that only exists inside an
#       `ifdef DP_156MHZ` / `ifdef P7B_10G` branch.
#   Entries are repo-relative; the gate .bat carries the same list expanded as
#   %REPO_ROOT%\...  -- sim/p4gates/p4gate.py manifestcheck asserts the two agree.
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
rtl/slow_rx_adp.v
rtl/slow_cfg_adp.v
rtl/slow_tx_adp.v
rtl/udp_rx.v
rtl/udp_split.v
rtl/tx_arb.v
rtl/udp_tx_cfg.v
rtl/udp_tx_frame.v
rtl/app_ctrl.v
rtl/app_pattern.v
rtl/app_udp_pattern.v
rtl/app_status_uart.v
board/wrapper_p4.v
board/util_gmii_to_rgmii.v
board/uart_dbg.v
tb/tb_p5_wrapper.v
