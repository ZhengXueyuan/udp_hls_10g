"""Generate run_route_check.bat (CRLF; ASCII only -- project bat rule)."""
import io, os
D = os.path.dirname(os.path.abspath(__file__))
bat = r"""@echo off
REM run_route_check.bat -- P5e-T1 private gate: synth + opt + place + ROUTE timing
REM (resolves the routed WHS sign; place-only numbers are pessimistic).
set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set XILINX_VITIS=C:\AMDDesignTools\2025.2\Vitis
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;C:\AMDDesignTools\2025.2\Vitis\bin;C:\AMDDesignTools\2025.2\Vitis\lib\win64.o;%PATH%
cd /d D:\repo\ECO\udp_hls_10g
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source D:\repo\ECO\udp_hls_10g\sim\p5udp\route_check.tcl -log vivado_route_check.log -nojournal
"""
io.open(os.path.join(D, 'run_route_check.bat'), 'w', newline='\r\n').write(bat)
print('written')
