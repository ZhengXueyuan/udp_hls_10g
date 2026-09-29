#!/bin/bash
# 回归总跑: t9(F-3 三变体) + P4 chain + P4 stall, 全部用私有工作目录
set -u
R="D:\repo\XCKU5PMini\udp_hls_10g"
A="$R\audit_scratch"
echo "=== md5 (跑门时刻) ==="
md5sum rtl/fifo_async.v rtl/mac_tx_64.v rtl/mac_rx_64.v rtl/fifo_sync.v tools/gen_stim_tx.py
for m in old new both; do
  echo "=== t9 F-3 $m ==="
  cmd //c "$A\run_t9.bat $m" > /dev/null 2>&1
  grep -E "^F3 (STOP|RELOCK|SUMMARY|STALE-CONSERV|VERDICT)" "$A/t9_f3restart/case_$m/xsim_$m.log"
done
echo "=== P4 chain ==="
P4_WORKDIR="$R\audit_scratch\t7_p4chain" cmd //c "$R\sim\p4sim\run_tb_p4_chain.bat" 2>&1 | tail -3
echo "=== P4 stall ==="
P4_WORKDIR="$R\audit_scratch\t8_stall" cmd //c "$R\sim\p4sim\run_tb_p4_chain_stall.bat" 2>&1 | tail -2
