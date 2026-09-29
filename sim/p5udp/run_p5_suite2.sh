#!/bin/bash
REPO_ROOT="$(cd -- "$(dirname -- "$0")/../../" && pwd)" || exit 1
if [ ! -f "$REPO_ROOT/CLAUDE.md" ]; then
  echo "[PATHGUARD FAIL] cannot locate this checkout from $0" >&2
  echo "  derived REPO_ROOT = $REPO_ROOT" >&2
  exit 1
fi
# P5e-T1 复核第二轮: adv 11 例 + p5d_multi (main + 负对照) —— 在 run_p5_suite.sh 之后跑。
B=%REPO_ROOT%
OUT=$B/sim/p5udp/p5suite2.log
: > $OUT
gate () {
  name="$1"; shift
  bat="$1"; shift
  echo "=== GATE $name : $bat $*" >> $OUT
  cmd //c "$bat $*" >> $OUT 2>&1
  rc=$?
  echo "GATE $name EXIT=$rc" >> $OUT
  echo "GATE $name EXIT=$rc"
  sleep 2
}
for c in len b2b wnd fin findrop abort evfifo reconn_fast reconn_slow multi accmgn; do
  gate p5_adv_$c '%REPO_ROOT%\sim\p5sim\run_tb_p5_adv.bat' $c
done
gate p5d_multi_main    '%REPO_ROOT%\sim\p5d_multi\run_tb_p5_multi.bat' main
gate p5d_multi_neg_wq  '%REPO_ROOT%\sim\p5d_multi\run_tb_p5_multi.bat' neg_wq
gate p5d_multi_neg_mgn '%REPO_ROOT%\sim\p5d_multi\run_tb_p5_multi.bat' neg_mgn
gate p5d_multi_neg_mgn0 '%REPO_ROOT%\sim\p5d_multi\run_tb_p5_multi.bat' neg_mgn0
gate p5d_multi_idlefifo '%REPO_ROOT%\sim\p5d_multi\run_tb_p5_multi.bat' known_idle_fifo
echo "SUITE2 DONE" >> $OUT
