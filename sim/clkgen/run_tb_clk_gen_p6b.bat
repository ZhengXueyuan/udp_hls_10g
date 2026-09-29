@echo off
REM run_tb_clk_gen_p6b.bat -- P6b clock-generator gate (tb_clk_gen_p6b.v)
REM   own sim dir (project rule 7: never share xsim.dir across gates)
REM   hard failures: implicit nets / bit-width mismatches (project rule 24)
REM   runs BOTH paths: SIM_BYPASS=1 (behavioural) and SIM_BYPASS=0 (real MMCME4_BASE unisim)
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib %ROOT%\rtl\clk_gen_p6b.v %ROOT%\tb\tb_clk_gen_p6b.v > xvlog_clkgen.log 2>&1 || (type xvlog_clkgen.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_clkgen.log 2>&1 || (type xvlog_clkgen.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_clkgen.log >NUL && (echo IMPLICIT-DECL-FAIL & type xvlog_clkgen.log & exit /b 1)
findstr /C:"10-3091" xvlog_clkgen.log >NUL && (echo BITWIDTH-MISMATCH-FAIL & type xvlog_clkgen.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_clk_gen_p6b xil_defaultlib.glbl -s tb_clk_gen_p6b -log xelab_clkgen.log > NUL 2>&1 || (type xelab_clkgen.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_clkgen.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_clkgen.log & exit /b 1)
call %XV%\xsim.bat tb_clk_gen_p6b -runall -log xsim_clkgen.log > NUL 2>&1
findstr /C:"CLKGEN" /C:"PASS_ALL" /C:"TIMEOUT" xsim_clkgen.log
REM exit code: PASS_ALL => 0, anything else => 1
findstr /C:"PASS_ALL" xsim_clkgen.log >NUL || exit /b 1
echo CLK GEN P6B GATE PASS
