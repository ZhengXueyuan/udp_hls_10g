p7b_w9fix/ -- P7B-W9 (app_udp_pattern TX 字 FIFO 空间门一拍错位) 修复的判别性台架
================================================================================
复现:  sh run_case.sh <tag> <app_src> "<xvlog -d flags>" ["<xsim plusargs>"]
       例: sh run_case.sh p7b_postfix mut/app_udp_pattern_postfix.v "-d P7B_10G -d UDP_TX_OVL -d POSTFIX"
       日志落在 run_<tag>/{cmd.txt(含 md5),xvlog.log,xelab.log,xsim.log,xsim_out.log}
判据:  见 P7B_W9_FIX.md §3 判据表; 关键行前缀 W9FIX
被测件: mut/app_udp_pattern_prefix.v  = git HEAD 版 (修前)
        mut/app_udp_pattern_postfix.v = 修复后的 rtl/app_udp_pattern.v 冻结副本
        mut/app_udp_pattern_ovfctl.v  = 负对照 (修复接线 + 只把 gen_ok/nul_push 退回本拍 full)
门日志: logs/gate_p5e_udp_pos.log (EXIT=0) / gate_p5e_rate.log (EXIT=0)
        / gate_p5e_udp_wrapper.log (EXIT=1, errs=1489 -- 既存 FAIL, 见 P7B_REGRESSION.md:101,210)
