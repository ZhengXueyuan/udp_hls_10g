#!/bin/bash
# ls_rtt_fast.sh -- 快 ss 采样器 (无 sleep): 取"对端通告窗"见证 (rcv_space/rcv_ssthresh/minrtt)
OUT=${1:-/tmp/ls_rtt_fast.txt}; N=${2:-300}
: > $OUT
for i in $(seq 1 $N); do
  echo "SSF_T $(date +%s.%N)" >> $OUT
  ss -tinme '( dport = :8080 )' 2>/dev/null | tail -n +2 >> $OUT
done
echo "SSF_DONE $(date +%s.%N)" >> $OUT
