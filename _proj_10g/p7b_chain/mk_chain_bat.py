# -*- coding: utf-8 -*-
"""Generate _proj_10g/p7b_chain/sim/run_tb_p7b_chain.bat (ASCII + CRLF)."""
import io

BODY = r'''@echo off
REM run_tb_p7b_chain.bat - P7b REAL-wrapper full-chain gate (project trap 8).
REM   Compile defines MUST match the real build: PCIE_OBS + DEV_USP + APP_MODE
REM   + DP_156MHZ + P7B_10G, plus the two simulation-only ones:
REM     P6B_SIM_CLKGEN  - clk_gen_p6b uses its behavioural clock model
REM     P7B_SIM_NOPCS   - the official xxv_ethernet PCS socket holds
REM                       board/p7b_pcs_stub.v (same port list) instead of the
REM                       encrypted GT IP (which was never simulated).
REM   from Git Bash: cmd //c '_proj_10g\p7b_chain\sim\run_tb_p7b_chain.bat'
setlocal
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
if exist xsim.dir rmdir /s /q xsim.dir
if exist xsim_p7bchain.log del /q xsim_p7bchain.log
dir /b /s "%ROOT%\rtl\*.v"                                    > files.f
dir /b /s "%ROOT%\hls\slowstack_prj\solution1\syn\verilog\*.v" >> files.f
echo %ROOT%\board\wrapper_p4.v                                >> files.f
echo %ROOT%\board\util_gmii_to_rgmii_us.v                     >> files.f
echo %ROOT%\board\uart_dbg.v                                  >> files.f
echo %ROOT%\board\p7b_pcs_stub.v                              >> files.f
echo %ROOT%\_proj_pcie\rtl\axi_regs.v                         >> files.f
echo %ROOT%\_proj_10g\p7b_mac\rtl\crc32_64.v                  >> files.f
echo %ROOT%\_proj_10g\p7b_mac\rtl\mac_rx_10g.v                >> files.f
echo %ROOT%\_proj_10g\p7b_mac\rtl\mac_tx_10g.v                >> files.f
echo %ROOT%\sim\p6e_pcie\xdma_0_sim_stub.v                    >> files.f
echo %~dp0tb_p7b_chain.v                                      >> files.f
call %XV%\xvlog.bat -work xil_defaultlib -d P7B_10G -d P7B_SIM_NOPCS -d PCIE_OBS -d DEV_USP -d APP_MODE -d DP_156MHZ -d P6B_SIM_CLKGEN -i %ROOT%\rtl -i %ROOT%\board -f files.f > xvlog_p7bchain.log 2>&1 || (type xvlog_p7bchain.log & exit /b 1)
call %XV%\xvlog.bat -d P7B_10G -d P7B_SIM_NOPCS -d PCIE_OBS -d DEV_USP -d APP_MODE -d DP_156MHZ -d P6B_SIM_CLKGEN -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_p7bchain.log 2>&1 || (type xvlog_p7bchain.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_p7bchain.log >NUL && (echo IMPLICIT-DECL-FAIL & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_p7bchain.log & exit /b 1)
findstr /I /C:"ERROR" xvlog_p7bchain.log >NUL && (echo XVLOG-ERROR-FAIL & findstr /I /C:"ERROR" xvlog_p7bchain.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_p7b_chain xil_defaultlib.glbl -s tb_p7b_chain -log xelab_p7bchain.log > NUL 2>&1 || (type xelab_p7bchain.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_p7bchain.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_p7bchain.log & exit /b 1)
call %XV%\xsim.bat tb_p7b_chain -runall -log xsim_p7bchain.log > NUL 2>&1
findstr /C:"PASS" /C:"FAIL" /C:"VERDICT" /C:"TIMEOUT" xsim_p7bchain.log
findstr /C:"VERDICT = PASS" xsim_p7bchain.log >NUL || exit /b 1
exit /b 0
'''

s = BODY.replace('\n', '\r\n')
assert all(ord(c) < 128 for c in s), 'non-ASCII in bat'
io.open('D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/p7b_chain/sim/run_tb_p7b_chain.bat', 'wb').write(s.encode('ascii'))
print('wrote run_tb_p7b_chain.bat')
