#!/bin/bash
# P5e-T3 回归驱动: P1 三门 + P4 矩阵 16 门 + P5 全套 + 新增 T3/T4/T5 门
# 用法: bash sim/p5e_udp/run_regress.sh [p1|p4|p5|new|all]
R=/d/repo/ECO/udp_hls_10g
OUT=$R/sim/p5e_udp/regress_t3.log
WHICH=${1:-all}

say() { echo "$*" >> $OUT; }

rung() {  # rung <name> <cmd...>
  name="$1"; shift
  "$@" > /tmp/rg_$name.log 2>&1
  rc=$?
  say "GATE $name EXIT=$rc"
  echo "GATE $name EXIT=$rc"
  sleep 2
}

{ echo "=== P5e-T3 regress [$WHICH] start $(date) ==="; } >> $OUT

if [ "$WHICH" = "p1" ] || [ "$WHICH" = "all" ]; then
  say "--- P1 (3 gates) ---"
  rung p1_echo  cmd //c "D:\\repo\\ECO\\udp_hls_10g\\sim\\echosim\\run_tb_echo.bat"
  rung p1_udprx cmd //c "D:\\repo\\ECO\\udp_hls_10g\\sim\\rxsim\\run_tb_udp_rx.bat"
  rung p1_udptx cmd //c "D:\\repo\\ECO\\udp_hls_10g\\sim\\txsim\\run_tb_udp_tx.bat"
fi

if [ "$WHICH" = "p4" ] || [ "$WHICH" = "all" ]; then
  say "--- P4 matrix (16 gates) ---"
  bash $R/sim/p4sim/run_matrix_p4dfix.sh >> $OUT 2>&1
  say "P4 matrix rc=$?"
  grep -c "EXIT=0" $R/sim/p4sim/matrix_p4dfix.log >> $OUT
  grep "EXIT=[^0]" $R/sim/p4sim/matrix_p4dfix.log >> $OUT
fi

if [ "$WHICH" = "p5" ] || [ "$WHICH" = "all" ]; then
  say "--- P5 suite ---"
  rung p5_app      cmd //c "D:\\repo\\ECO\\udp_hls_10g\\sim\\p5sim\\run_tb_p5_app.bat"
  rung p5_close    cmd //c "D:\\repo\\ECO\\udp_hls_10g\\sim\\p5sim\\run_tb_p5_app.bat close"
  rung p5_wrapper  cmd //c "D:\\repo\\ECO\\udp_hls_10g\\sim\\p5sim\\run_tb_p5_wrapper.bat"
  rung p5_status   cmd //c "D:\\repo\\ECO\\udp_hls_10g\\sim\\p5sim\\run_tb_p5_status.bat"
  for c in len b2b wnd fin findrop abort evfifo reconn_fast reconn_slow multi accmgn; do
    rung p5_adv_$c cmd //c "D:\\repo\\ECO\\udp_hls_10g\\sim\\p5sim\\run_tb_p5_adv.bat $c"
  done
  rung p5_flow     cmd //c "D:\\repo\\ECO\\udp_hls_10g\\sim\\p5sim\\run_tb_p5_flow.bat"
  rung p5_fc       cmd //c "D:\\repo\\ECO\\udp_hls_10g\\sim\\p5sim\\run_tb_p5_fc.bat"
  rung p5close_g   cmd //c "D:\\repo\\ECO\\udp_hls_10g\\sim\\p5close\\run_tb_tcp_close.bat"
  rung p5c_t3      cmd //c "D:\\repo\\ECO\\udp_hls_10g\\sim\\p5c_t3\\run_tb_p5c_fence.bat"
  rung p5d_d1      cmd //c "D:\\repo\\ECO\\udp_hls_10g\\sim\\p5d_d1\\run_tb_p5d_d1.bat"
  rung p5d_fence_neg cmd //c "D:\\repo\\ECO\\udp_hls_10g\\sim\\p5d_d1\\run_fence_neg.bat"
  rung p5d_main    cmd //c "D:\\repo\\ECO\\udp_hls_10g\\sim\\p5d_multi\\run_tb_p5_multi.bat main"
  rung p5d_known   cmd //c "D:\\repo\\ECO\\udp_hls_10g\\sim\\p5d_multi\\run_tb_p5_multi.bat known_idle_fifo"
fi

if [ "$WHICH" = "new" ] || [ "$WHICH" = "all" ]; then
  say "--- P5e-T3/T4/T5 new gates ---"
  for m in pos splitoff portout badcrc nopeer; do
    rung t4_$m cmd //c "D:\\repo\\ECO\\udp_hls_10g\\sim\\p5e_udp\\run_tb_app_udp.bat $m"
  done
  # neglearn = P5d 风格负对照, **期望 EXIT=1**
  rung t4_neglearn cmd //c "D:\\repo\\ECO\\udp_hls_10g\\sim\\p5e_udp\\run_tb_app_udp.bat neglearn"
  rung t5_wrapper  cmd //c "D:\\repo\\ECO\\udp_hls_10g\\sim\\p5e_udp\\run_tb_p5e_udp_wrapper.bat"
fi

say "=== done $(date) ==="
echo "=== regress done ==="
