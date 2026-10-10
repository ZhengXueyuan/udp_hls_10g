@echo off
call "%~dp0run_arm.bat" D2S "D:/repo/XCKU5PMini/udp_hls_10g/rtl/tcp_tx_frame.v" "-d TCP_TX_OVL -d ARM_PERSIST -d PE_HOLD_5200"
