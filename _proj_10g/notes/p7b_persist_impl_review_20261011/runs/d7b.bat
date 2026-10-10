@echo off
call "%~dp0run_arm.bat" D7B_NOUP "D:/repo/XCKU5PMini/udp_hls_10g/rtl/tcp_tx_frame.v" "-d TCP_TX_OVL -d ARM_PERSIST -d PE_E4B -d PE_E4B_NOUP"
