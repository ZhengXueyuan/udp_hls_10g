@echo off
cd /d "%~dp0"
set R=%~dp0
call "%R%run_tb_p5_wrapper_head.bat" > "%R%ab_wrapper_head.log" 2>&1
echo ab_wrapper_head_EXIT=%ERRORLEVEL%
call "%R%run_tb_p5_multi_head.bat" neg_wq > "%R%ab_neg_wq_head.log" 2>&1
echo ab_neg_wq_head_EXIT=%ERRORLEVEL%
echo AB_DONE
