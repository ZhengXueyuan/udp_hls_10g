@echo off
cd /d %~dp0
rem 2026-10-10 tool-debt round: standalone xsim runner (no Vivado project).
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
call "%XV%\xvlog.bat" -work work mdio_master_legacy.v mdio_master_shim.v tb_mdio_master.v > xvlog.stdout.txt 2>&1
if errorlevel 1 (echo XVLOG_FAIL & type xvlog.stdout.txt & type xvlog.log & exit /b 1)
call "%XV%\xelab.bat" work.tb_mdio_master -s tb_sim -log xelab.log > NUL 2>&1
if errorlevel 1 (echo XELAB_FAIL & type xelab.log & exit /b 1)
call "%XV%\xsim.bat" tb_sim -runall -log xsim.log > NUL 2>&1
set RC=%errorlevel%
echo XSIM_RC=%RC%
type xsim.log
exit /b %RC%
