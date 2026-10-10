@echo off
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
call "%XV%\xvlog.bat" -work work mdio_master.v mdio_vio_top.v vio_0.v vio_0_sim_netlist.v dbg_hub_sim_netlist.v C:/AMDDesignTools/2025.2/data/verilog/src/glbl.v > xvlog.stdout.txt 2>&1
if errorlevel 1 (echo XVLOG_FAIL & type xvlog.stdout.txt & exit /b 1)
call "%XV%\xelab.bat" -L unisims_ver work.mdio_vio_top work.glbl -s top_elab -log xelab.log > NUL 2>&1
echo XELAB_RC=%errorlevel%
type xelab.log
exit /b 0
