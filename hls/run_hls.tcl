#=============================================================================
# udp_hls_10g/hls/run_hls.tcl — 慢路径协议栈 (P4b 修改版) HLS 综合
# 与 udp_hls_eco/run_csynth_only.tcl 同模式 (vitis-run --mode hls --tcl);
# 只 csynth (老 tb 端口列表与新签名不匹配, 不进工程; 功能验证走 xsim 真 RTL)
#=============================================================================

open_project -reset slowstack_prj
add_files src/udp_echo.cpp
set_top udp_echo

open_solution -reset solution1
set_part {xc7k325tffg676-2}
create_clock -period 8 -name default

# Reset: async, active low
config_rtl -reset all -reset_async -reset_level low

puts "\n===== C SYNTHESIS ====="
csynth_design

puts "\n===== CSYNTH DONE ====="
exit
