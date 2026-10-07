@echo off
cd /d "%~dp0"
set R=%~dp0

call "%R%run_tb_p5_wrapper_here.bat" > "%R%extra_p5_wrapper.log" 2>&1
echo p5_wrapper_EXIT=%ERRORLEVEL%
call "%R%run_tb_p5_status_here.bat" > "%R%extra_p5_status.log" 2>&1
echo p5_status_EXIT=%ERRORLEVEL%
call "%R%run_tb_p5_pattern_here.bat" > "%R%extra_p5_pattern.log" 2>&1
echo p5_pattern_EXIT=%ERRORLEVEL%

call "%R%run_tb_p5_multi.bat" neg_wq > "%R%extra_p5d_neg_wq.log" 2>&1
echo p5d_neg_wq_EXIT=%ERRORLEVEL%
call "%R%run_tb_p5_multi.bat" neg_mgn > "%R%extra_p5d_neg_mgn.log" 2>&1
echo p5d_neg_mgn_EXIT=%ERRORLEVEL%
call "%R%run_tb_p5_multi.bat" neg_mgn0 > "%R%extra_p5d_neg_mgn0.log" 2>&1
echo p5d_neg_mgn0_EXIT=%ERRORLEVEL%
call "%R%run_tb_p5_multi.bat" known_idle_fifo > "%R%extra_p5d_known_idle_fifo.log" 2>&1
echo p5d_known_idle_fifo_EXIT=%ERRORLEVEL%
echo EXTRA_GATES_DONE
