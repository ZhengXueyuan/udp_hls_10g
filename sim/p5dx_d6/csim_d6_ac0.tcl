#=============================================================================
# sim/p5dx_d6/csim_d6.tcl — P5d-D6 槽释放修复的 csim 逻辑检查 (自有工程目录,
# 不碰 hls/slowstack_prj — 那个目录被 board/run_build_p5.bat 的 Vivado 构建读)。
# 只有逻辑判据 (cfg ADD/DEL 记录 + SYN+ACK), 调度/时序判据在 exp2 的 xsim 门。
#=============================================================================
open_project -reset csim_prj0
add_files D:/repo/ECO/udp_hls_10g/hls/src/udp_echo.cpp -cflags "-DACTIVE_CONNECT=0"
add_files -tb D:/repo/ECO/udp_hls_10g/sim/p5dx_d6/csim_d6.cpp
set_top udp_echo

open_solution -reset solution1
set_part {xc7k325tffg676-2}
create_clock -period 8 -name default

puts "\n===== C SIMULATION (P5d-D6 slot rebuild logic) ====="
csim_design
puts "\n===== CSIM DONE ====="
exit
