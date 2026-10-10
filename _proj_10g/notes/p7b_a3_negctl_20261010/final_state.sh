#!/bin/bash
# final_state.sh -- P7B A3 负对照轮 (2026-10-10): 收尾态取证 (形状与 E 轮 FINAL_STATE.txt 同源)
#   ⛔ 收尾不用 0x08 w 0x2 (那是物理停发/断链, 派单明令不许); 本脚本只读不写。
#   ⚠️ 期望收尾态: BID 0x18 (D) / 0x08=0 / carrier=1 / 无残留连接与进程; COALESCE 见证一并落档。
set -u
ROOT=/d/repo/XCKU5PMini/udp_hls_10g
OUT=$ROOT/_proj_10g/notes/p7b_a3_negctl_20261010
export MSYS_NO_PATHCONV=1 PYTHONIOENCODING=utf-8
PY=/c/Users/zhxue/anaconda3/python.exe
SSH="$PY D:/repo/XCKU5PMini/udp_hls_10g/tools/peer_ssh.py"

exec > >(tee "$OUT/FINAL_STATE.txt") 2>&1

echo "### FINAL_STATE_BEGIN $(date +%Y-%m-%dT%H:%M:%S%z)"
PEER_PW=111111 $SSH --sudo "T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools; \
  echo -n 'FINAL_BID='; \$T/reg_rw /dev/xdma0_user 0x04 w 2>&1 | tail -1; \
  echo -n 'FINAL_SCRATCH_0x08='; \$T/reg_rw /dev/xdma0_user 0x08 w 2>&1 | tail -1; \
  echo -n 'FINAL_CARRIER='; cat /sys/class/net/enp1s0f1np1/carrier; \
  echo 'FINAL_LNKSTA='; lspci -vvv -s 02:00.0 2>/dev/null | grep -E 'LnkSta:'; \
  echo '--- ss ---'; ss -tn state established '( sport = :8080 or dport = :8080 )' 2>/dev/null; \
  echo '--- sink procs ---'; echo SINKPROC=\$(ps aux | grep -E 'p7b_tcp_sink|a3_reconnect|lf_dl' | grep -v grep | wc -l); \
  echo '--- coalesce ---'; ethtool -c enp1s0f1np1 | grep -E 'Adaptive|rx-usecs'; \
  echo '--- route ---'; ip route get 192.168.100.2"
echo "### FINAL_STATE_END $(date +%Y-%m-%dT%H:%M:%S%z)"
