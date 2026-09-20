#!/bin/bash
# P5e-T1 复核用: 顺序跑 P5 全套门 + P1 三门, 每门一行 EXIT。
# 用法: bash sim/p5udp/run_p5_suite.sh > /tmp/p5suite.log 2>&1 &
B=/d/repo/ECO/udp_hls_10g
OUT=$B/sim/p5udp/p5suite.log
: > $OUT
gate () {   # $1 = 名字, $2 = bat 全路径, $3.. = 参数
  name="$1"; shift
  bat="$1"; shift
  echo "=== GATE $name : $bat $*" >> $OUT
  cmd //c "$bat $*" >> $OUT 2>&1
  rc=$?
  echo "GATE $name EXIT=$rc" >> $OUT
  echo "GATE $name EXIT=$rc"
  sleep 2
}
gate p5_wrapper 'D:\repo\ECO\udp_hls_10g\sim\p5sim\run_tb_p5_wrapper.bat'
gate p5_app     'D:\repo\ECO\udp_hls_10g\sim\p5sim\run_tb_p5_app.bat'
gate p5_status  'D:\repo\ECO\udp_hls_10g\sim\p5sim\run_tb_p5_status.bat'
gate p5_fc      'D:\repo\ECO\udp_hls_10g\sim\p5sim\run_tb_p5_fc.bat'
gate p5_flow    'D:\repo\ECO\udp_hls_10g\sim\p5sim\run_tb_p5_flow.bat'
gate p5_close   'D:\repo\ECO\udp_hls_10g\sim\p5sim\run_tb_p5_app.bat' close
gate p5close    'D:\repo\ECO\udp_hls_10g\sim\p5close\run_tb_tcp_close.bat'
gate p5c_t3     'D:\repo\ECO\udp_hls_10g\sim\p5c_t3\run_tb_p5c_fence.bat'
gate p5d_d1     'D:\repo\ECO\udp_hls_10g\sim\p5d_d1\run_tb_p5d_d1.bat'
gate p5e_win    'D:\repo\ECO\udp_hls_10g\sim\p5e_win\run_tb_p5e_win.bat'
echo "SUITE DONE" >> $OUT
