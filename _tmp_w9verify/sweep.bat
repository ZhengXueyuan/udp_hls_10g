@echo off
set W=D:\repo\XCKU5PMini\udp_hls_10g\_tmp_w9verify
call %W%\run_chain2.bat 1472 p41    1200 41  x head_rtl
call %W%\run_chain2.bat 1472 p1000  1200 1000 x head_rtl
call %W%\run_chain2.bat 1464 base   1200 40  x head_rtl
call %W%\run_chain2.bat 1480 base   1200 40  x head_rtl
call %W%\run_chain2.bat 1470 base   1200 40  x head_rtl
call %W%\run_chain2.bat 1472 fix    1200 40  x wt_rtl
