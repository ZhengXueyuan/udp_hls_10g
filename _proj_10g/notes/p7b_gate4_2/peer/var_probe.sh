#!/bin/bash
# var_probe.sh — 逐轮**同窗**比较: 板侧 W20 帧率 vs 网卡计数帧率 (回答 4.6% 差归谁)
#   每轮: [板快照 -> 网卡读] ... 4s ... [板快照 -> 网卡读]  ⇒ 一轮给出两个同窗速率
#   只读 (除快照触发 0x18)。
T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
D=/dev/xdma0_user
rd(){ $T/reg_rw $D "$1" w 2>/dev/null | tail -1 | sed 's/.*: *//'; }
snap(){ $T/reg_rw $D 0x18 w 0x1 >/dev/null 2>&1
  local i s; for i in $(seq 1 400); do s=$(rd 0x1c); [ -n "$s" ] && [ $(( s & 2 )) -ne 0 ] && break; sleep 0.002; done
  echo "SNAP $(date +%s.%N) W20 $(rd 0x70) W8 $(rd 0x40) W9 $(rd 0x44)"; }
nic(){ echo "NIC $(date +%s.%N) $(ethtool -S enp1s0f1np1 | grep -E '^ +port_rx_(good|packets):' | tr -d ' ' | tr ':' ' ' | tr '\n' ' ')"; }
for r in 1 2 3; do
  echo "=== ROUND $r ==="
  snap; nic
  sleep 4
  snap; nic
  sleep 1
done
echo VAR_DONE
