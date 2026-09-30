#!/bin/bash
# rate_negA2.sh -- 负对照 N-a (零重建, **改正版**): 拉 TX_DIS ⇒ 对端 carrier 必掉 + Δport_rx_packets 必 = 0
#
# 更正记录: 第一版 (rate_negA.sh) 的 pair() 里两次 NIC 采样只差 0.04 s (没插窗口) ⇒
#   相位内的 Δ 结构上恒为 0, 无判别力。本版把窗口做**真的**: NIC_A → [锁存A] → 补足 W 秒
#   → [锁存B] → NIC_B。与 rate_probe.sh 同一编排。
# 判据: N-a1 读回 0x08 == 0x2 ; N-a2 carrier → 0 ; N-a3 Δport_rx_packets = 0 (≤2)
#       N-a4 ΔW20 **记录实测值**(不预设) ; 恢复后 carrier 必回 1
set -u
T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
D=/dev/xdma0_user
IF=enp1s0f1np1
W=${1:-5}
rd(){ $T/reg_rw $D "$1" w 2>/dev/null | tail -1 | sed 's/.*: *//'; }
wr(){ $T/reg_rw $D "$1" w "$2" >/dev/null 2>&1; }
carrier(){ echo "carrier=$(cat /sys/class/net/$IF/carrier) operstate=$(cat /sys/class/net/$IF/operstate) speed=$(cat /sys/class/net/$IF/speed) carrier_changes=$(cat /sys/class/net/$IF/carrier_changes)"; }
nic(){
  echo "NIC_T0_$1 $(date +%s.%N)"
  ethtool -S $IF | grep -E '^ +(port_rx_(packets|good|bad|bytes|good_bytes|1024_to_15xx|overflow|nodesc_drops)|rx_eth_crc_err):' | tr -d ' ' | tr ':' ' '
  ethtool -S $IF | grep -E '^ +rx-[0-9]+\.' | tr -d ' ' | tr ':' ' '
  echo "NIC_T1_$1 $(date +%s.%N)"
}
trig(){
  local g0 g1 s i
  g0=$(rd 0x1c); g0=$(( (g0 >> 16) & 0xffff ))
  echo "SNAP_T0_$1 $(date +%s.%N)"
  wr 0x18 0x1
  for i in $(seq 1 500); do s=$(rd 0x1c); [ -z "$s" ] && continue; [ $(( s & 2 )) -ne 0 ] && break; sleep 0.002; done
  g1=$(rd 0x1c); g1=$(( (g1 >> 16) & 0xffff ))
  LATCH=$(date +%s.%N)
  echo "SNAP_T1_$1 $LATCH"
  printf 'GEN %s %s\n' "$g0" "$g1"
}
dump(){ local i; for i in 0 5 8 9 13 20 21 24 41 42 43; do printf 'W%s %s\n' "$i" "$(rd $(printf '0x%X' $(( 0x20 + 4*i ))))"; done; }

echo "########## PHASE 1: 拉 TX_DIS 后**静默窗口** (${W}s) ##########"
wr 0x08 0x2
echo "TXDIS_RB1 $(rd 0x08)   (N-a1: 期望 0x00000002)"
sleep 4                                    # 让 laggy 计数器把这之前的流量冲干净
carrier
nic A; trig A; dump A
TA=$LATCH
PAD=$(awk -v a="$TA" -v w="$W" 'BEGIN{printf "%.3f", w}')
sleep "$PAD"
trig B; nic B; dump B
echo "(窗口 ${W}s: 判 N-a3 Δport_rx_packets = 0; N-a4 ΔW20 记录实测)"

echo "########## PHASE 2: 恢复 ##########"
wr 0x08 0x0
echo "TXDIS_RB2 $(rd 0x08)   (期望 0x00000000)"
sleep 4
carrier
echo "########## PHASE 3: 恢复后对照窗口 (${W}s) ##########"
nic C; trig C; dump C
TC=$LATCH
PAD=$(awk -v a="$TC" -v w="$W" 'BEGIN{printf "%.3f", w}')
sleep "$PAD"
trig D; nic D; dump D
echo "NEGA2_DONE"
