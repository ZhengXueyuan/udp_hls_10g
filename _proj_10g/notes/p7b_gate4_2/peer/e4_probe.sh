#!/bin/bash
# e4_probe.sh — F2 (ping) + E4/G6 (最小帧洪泛下 ΔW34) + 洪泛后守恒律复检
#   洪泛打到 8080 (HLS udp_echo 口, = EXCL_PORT) —— 不占 app 端口, 不污染 W13;
#   目的是让 **RX 前端/CDC/分类** 承压 ⇒ 看 rx_stat_drop_full(W34) 与守恒律。
#   ⚠️ 对端机用户态最高 ~10^5-10^6 pps, 10G 最小帧线速 = 14.88 Mpps ⇒ **弱化版洪泛**, 如实标注。
T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
D=/dev/xdma0_user
rd(){ $T/reg_rw $D "$1" w 2>/dev/null | tail -1 | sed 's/.*: *//'; }
snap(){ local tag="$1"
  $T/reg_rw $D 0x18 w 0x1 >/dev/null 2>&1
  local i s; for i in $(seq 1 400); do s=$(rd 0x1c); [ -n "$s" ] && [ $(( s & 2 )) -ne 0 ] && break; sleep 0.002; done
  echo "SNAP $tag $(date +%s.%N) gen=$(( (s >> 16) & 0xffff )) W0=$(rd 0x20) W1=$(rd 0x24) W3=$(rd 0x2c) W6=$(rd 0x38) W19=$(rd 0x6c) W20=$(rd 0x70) W30=$(rd 0x98) W31=$(rd 0x9c) W32=$(rd 0xa0) W33=$(rd 0xa4) W34=$(rd 0xa8) W36=$(rd 0xb0) W37=$(rd 0xb4) W38=$(rd 0xb8) W48=$(rd 0xe0) W49=$(rd 0xe4)"; }

ip addr add 192.168.100.100/32 dev enp1s0f1np1 2>/dev/null
ip route add 192.168.100.2/32 dev enp1s0f1np1 src 192.168.100.100 2>/dev/null
echo "ROUTE $(ip route get 192.168.100.2 2>&1 | head -1)"

echo "=== F2: ping (10G 口) ==="
ping -c 5 -i 0.2 -W 2 192.168.100.2 2>&1 | tail -4

echo "=== E4: 洪泛前 (静默) ==="
sleep 2; snap PRE

echo "=== E4: 最小帧洪泛 (64B 帧 -> 8080) ==="
/home/a/xdma_test/flood 192.168.100.2 8080 2000000 18
snap POST_FLOOD

echo "=== 等 3 s 静默后 ==="
sleep 3; snap QUIET
echo "E4_DONE"
