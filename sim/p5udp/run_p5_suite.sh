#!/bin/bash
REPO_ROOT="$(cd -- "$(dirname -- "$0")/../../" && pwd)" || exit 1
if [ ! -f "$REPO_ROOT/CLAUDE.md" ]; then
  echo "[PATHGUARD FAIL] cannot locate this checkout from $0" >&2
  echo "  derived REPO_ROOT = $REPO_ROOT" >&2
  exit 1
fi
# P5e-T1 复核用: 顺序跑 P5 全套门 + P1 三门, 每门一行 EXIT。
# 用法: bash sim/p5udp/run_p5_suite.sh > /tmp/p5suite.log 2>&1 &
B=%REPO_ROOT%
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
gate p5_wrapper '%REPO_ROOT%\sim\p5sim\run_tb_p5_wrapper.bat'
gate p5_app     '%REPO_ROOT%\sim\p5sim\run_tb_p5_app.bat'
gate p5_status  '%REPO_ROOT%\sim\p5sim\run_tb_p5_status.bat'
gate p5_fc      '%REPO_ROOT%\sim\p5sim\run_tb_p5_fc.bat'
gate p5_flow    '%REPO_ROOT%\sim\p5sim\run_tb_p5_flow.bat'
gate p5_close   '%REPO_ROOT%\sim\p5sim\run_tb_p5_app.bat' close
gate p5close    '%REPO_ROOT%\sim\p5close\run_tb_tcp_close.bat'
gate p5c_t3     '%REPO_ROOT%\sim\p5c_t3\run_tb_p5c_fence.bat'
gate p5d_d1     '%REPO_ROOT%\sim\p5d_d1\run_tb_p5d_d1.bat'
gate p5e_win    '%REPO_ROOT%\sim\p5e_win\run_tb_p5e_win.bat'
echo "SUITE DONE" >> $OUT
