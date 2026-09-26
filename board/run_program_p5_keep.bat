@echo off
REM run_program_p5_keep.bat - program a PRESERVED diagnostic bitstream (v1/v2/v3).
REM usage: run_program_p5_keep.bat <filename inside p5diag_verify\keep>
REM WHY THIS EXISTS: pointing a JTAG program step at vivado_prj\p5diag_prj.runs\impl_1
REM breaks whenever a build is regenerating that project (create_project -force
REM deletes and recreates it, so the .bit does not exist for minutes). On 2026-09-26
REM that silently skipped the reset and produced three rounds of garbage (UMM ~1e8,
REM identical II every round) that were nearly read as a mechanism result.
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;%PATH%
cd /d D:\repo\ECO\udp_hls_10g
if "%~1"=="" (echo usage: run_program_p5_keep.bat ^<file in p5diag_verify\keep^> & exit /b 2)
REM Delete first: the findstr gate below must only ever read THIS run's log,
REM otherwise a green from an earlier round could satisfy it from a stale file.
del /q vivado_program_keep.log 2>NUL
REM ORDER MATTERS: Vivado -tclargs is GREEDY - it swallows every following
REM argument, so "-log X -nojournal" placed after it is never seen by Vivado
REM and the run silently writes its default vivado.log instead. Proven 2026-09-27:
REM the command line showed -log vivado_program_keep.log yet no such file was
REM created, while vivado_program_p4.bat (no -tclargs) DID create its log.
REM Keep -log/-nojournal BEFORE -tclargs or the gate below can never pass.
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source D:\repo\ECO\udp_hls_10g\board\program_p4.tcl -log vivado_program_keep.log -nojournal -tclargs D:\repo\ECO\udp_hls_10g\p5diag_verify\keep\%~1
findstr /C:"PROGRAM_OK" vivado_program_keep.log > NUL || (echo PROGRAM DID NOT REPORT OK - DO NOT TRUST ANY READING & exit /b 1)
exit /b 0
