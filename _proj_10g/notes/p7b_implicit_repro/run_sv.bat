@echo off
setlocal
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
call "%XV%\xvlog.bat" -sv "D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/notes/p7b_implicit_repro/B1_clean.v" > sv_probe_clean.log 2>&1
echo SV_RC=%errorlevel%
endlocal
