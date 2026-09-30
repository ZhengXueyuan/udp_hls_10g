#!/bin/bash
# gatecheck.sh -- run_build_p7b_ku5p.bat 的**三条硬门**逐串 grep, **分两栏**:
#   栏 A = 主 stdout (board/p7b_ku5p_stdout.txt)
#   栏 B = 各 run 的日志 (synth_1 / impl_1 / pcs64_synth_1 / xdma_0_synth_1 的 runme.log)
# 为什么必须分栏: bat 里的三条门只 grep 主 stdout, 且**只打 banner 不置退出码**
#   (命中照样 exit /b 0) ⇒ 它既不是"门"、覆盖面也缺 OOC run 日志这一半。
# 用法: bash gatecheck.sh <repo_root>
set -u
R=${1:-.}
MAIN=$R/board/p7b_ku5p_stdout.txt
RUNS=$R/vivado_prj/p7b_ku5p_prj.runs
LOGS=""
for d in synth_1 impl_1 pcs64_synth_1 xdma_0_synth_1; do
  [ -f "$RUNS/$d/runme.log" ] && LOGS="$LOGS $RUNS/$d/runme.log"
done
KEYS=(
  "12-4739"
  "Synth 8-11241"
  "undeclared symbol"
  "VRFC 10-3091] actual bit length 1 differs from formal bit length"
  "VRFC 10-2989"
  "implicitly declared"
  "NSTD-1"
  "UCIO-1"
  "AVAL-326"
  "Opt 31-155"
  "Opt 31-67"
  "Route 35-7"
)
c(){ grep -c -F -- "$1" "$2" 2>/dev/null | tr -d '\r' || echo 0; }
echo "MAIN  = $MAIN"
for L in $LOGS; do echo "RUNLOG= $L"; done
echo
printf "%-62s %8s %8s\n" "KEY" "MAIN" "RUNLOGS"
for k in "${KEYS[@]}"; do
  a=$(c "$k" "$MAIN")
  b=0
  for L in $LOGS; do n=$(c "$k" "$L"); b=$((b+n)); done
  printf "%-62s %8s %8s\n" "$k" "$a" "$b"
done
echo
echo "---- 附加面 (任务要求的宽面扫描) ----"
printf "%-62s %8s %8s\n" "KEY" "MAIN" "RUNLOGS"
for k in "^ERROR" "^CRITICAL WARNING" "VRFC 10-" "Synth 8-" "xelab" "\\[Synth 8-36\\]" ; do
  a=$(grep -c -E -- "$k" "$MAIN" 2>/dev/null | tr -d '\r'); a=${a:-0}
  b=0
  for L in $LOGS; do n=$(grep -c -E -- "$k" "$L" 2>/dev/null | tr -d '\r'); b=$((b+n)); done
  printf "%-62s %8s %8s\n" "$k" "$a" "$b"
done
echo
echo "---- 命中明细 (非 0 才打, 带来源文件) ----"
for k in "${KEYS[@]}"; do
  for F in "$MAIN" $LOGS; do
    n=$(c "$k" "$F")
    [ "$n" != "0" ] && { echo "== [$k] x$n in $F"; grep -n -F -- "$k" "$F" | head -40 | cut -c1-200; }
  done
done
exit 0
