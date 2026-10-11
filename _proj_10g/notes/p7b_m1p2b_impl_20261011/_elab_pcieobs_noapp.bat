@echo off
REM _elab_pcieobs_noapp.bat -- 防御性覆盖: PCIE_OBS ∧ ¬APP_MODE ∧ ¬DP_156MHZ 的 wrapper 分支
REM   为什么: run_lint_p6e.bat 编的是 PCIE_OBS+APP_MODE(¬DP_156MHZ) —— 它覆盖 M1 块的
REM   ¬DP_156MHZ 支, 但**不覆盖** ¬APP_MODE 支 (现役任何构建脚本都不产生这个组合;
REM   本轮的 tie-off 也写进了那一支 ⇒ 至少要证明它**编得过/elab 得过**)。
REM   ⛔ 只到 xelab (不出位流; 若将来真有这个构建, 由构建轮的面去收口)。
setlocal
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
cd /d %~dp0
if exist _elab_noapp rmdir /s /q _elab_noapp
mkdir _elab_noapp
cd _elab_noapp
dir /b /s "%ROOT%\rtl\*.v"                                  > files.f
dir /b /s "%ROOT%\hls\slowstack_prj\solution1\syn\verilog\*.v" >> files.f
echo %ROOT%\board\wrapper_p4.v                              >> files.f
echo %ROOT%\board\util_gmii_to_rgmii_us.v                   >> files.f
echo %ROOT%\board\util_gmii_to_rgmii.v                      >> files.f
echo %ROOT%\board\uart_dbg.v                                >> files.f
echo %ROOT%\_proj_pcie\rtl\axi_regs.v                       >> files.f
echo %ROOT%\sim\p6e_pcie\xdma_0_sim_stub.v                  >> files.f
call %XV%\xvlog.bat -work xil_defaultlib -d PCIE_OBS -d DEV_USP -i %ROOT%\rtl -i %ROOT%\board -f files.f > xvlog_noapp.log 2>&1
echo XVLOG_EXIT=%ERRORLEVEL%
findstr /I /C:"ERROR" xvlog_noapp.log >NUL && (echo XVLOG-ERROR-FAIL & findstr /I /C:"ERROR" xvlog_noapp.log & exit /b 1)
call %XV%\xvlog.bat -d PCIE_OBS -d DEV_USP -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_noapp.log 2>&1
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.wrapper_p4 xil_defaultlib.glbl -s noapp -log xelab_noapp.log > NUL 2>&1
if errorlevel 1 (echo XELAB-FAIL & type xelab_noapp.log & exit /b 1)
findstr /C:"Built simulation snapshot" xelab_noapp.log >NUL || (echo XELAB-NO-SNAPSHOT & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_noapp.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & exit /b 1)
echo NOAPP-ELAB-OK
exit /b 0
