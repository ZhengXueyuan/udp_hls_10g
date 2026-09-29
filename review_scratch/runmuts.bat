@echo off
set HERE=%~dp0
for %%C in (C_BAL C_WRFAST C_BOUND) do call "%HERE%run.bat" "%HERE%rw\mutC_full1stage.v" %%C "%HERE%rd_mutC_%%C"
for %%C in (C_BAL C_RESET) do call "%HERE%run.bat" "%HERE%rw\mutF_rst1stage.v" %%C "%HERE%rd_mutF_%%C"
echo ALLDONE
