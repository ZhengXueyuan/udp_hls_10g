#!/bin/bash
# teach20_probe.sh — lane4 修复的**成批认领**板级判据 (+ F3 前哨)
#   上一轮 (修复前, P7B_UDP_DIAG2.md §2.1): 同一工具 `--teach-n 20` 认领 8/20、9/20、11/20
#   ⇒ 未认领的那些正是 `/S/` 落 lane4 的帧 (整帧被透传 HLS)。
#   本轮 (修复后): 若 ΔW10 == 20 且 ΔW6 == 0 ⇒ 全部认领。
#   统计口径: 20 帧连续发送时, 帧长 142B (100B 载荷) 与 IFG 决定起始 lane 逐帧轮换
#   (1518B 帧同理: (len+IFG) mod 8 ≠ 0) ⇒ 样本天然混 lane0/lane4。
#   零假设 (lane4 仍坏, 认领率 ~40%): P(20/20) = 0.4^20 ≈ 1.1e-8 (按上一轮实测 8/20=0.40 取)
# 只读 + 发送 (不改任何板侧配置)。
T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
D=/dev/xdma0_user
rd(){ $T/reg_rw $D "$1" w 2>/dev/null | tail -1 | sed 's/.*: *//'; }
snap(){ $T/reg_rw $D 0x18 w 0x1 >/dev/null 2>&1
  local i s; for i in $(seq 1 400); do s=$(rd 0x1c); [ -n "$s" ] && [ $(( s & 2 )) -ne 0 ] && break; sleep 0.002; done
  echo "SNAP $(date +%s.%N) gen=$(( (s >> 16) & 0xffff )) W0=$(rd 0x20) W6=$(rd 0x38) W7=$(rd 0x3c) W10=$(rd 0x48) W11=$(rd 0x4c) W12=$(rd 0x50) W13=$(rd 0x54) W20=$(rd 0x70) W3=$(rd 0x2c)"; }

echo "ROUTE_BEFORE $(ip route get 192.168.100.2 2>&1 | head -1)"
ip addr add 192.168.100.100/32 dev enp1s0f1np1 2>/dev/null
ip route add 192.168.100.2/32 dev enp1s0f1np1 src 192.168.100.100 2>/dev/null
echo "ROUTE_AFTER $(ip route get 192.168.100.2 2>&1 | head -1)"
echo "PRE"; snap
echo "TEACH_BEGIN $(date +%s.%N)"
cd /home/a/xdma_test && ./p6e_udp_pattern --secs 3 --teach-n 20 --board 192.168.100.2 --port 8081 2>&1 | tail -8
echo "TEACH_RC=$?"
echo "POST"; snap
echo "T20_DONE"
