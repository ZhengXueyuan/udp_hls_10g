#!/bin/bash
# rate_negA.sh -- 负对照 N-a (零重建): 拉 TX_DIS ⇒ 对端 carrier 必掉 + Δport_rx_packets 必 = 0
#
# 依据: P7B_RATE_MEASURE_PLAN.md §4-N-a
#   动作: reg_rw /dev/xdma0_user 0x08 w 0x2  ⇒ pcie_scratch[1] = 1 ⇒ sfp2_tx_dis = 1
#         (证据: board/wrapper_p4.v:3695-3696 `assign sfp2_tx_dis = pcie_scratch[1];` + :3727 scratch 挂在 0x08)
#   判据: N-a1 写后读回 0x08 == 0x2 ; N-a2 对端 carrier → 0 (且 carrier_changes +1)
#         N-a3 Δport_rx_packets = 0 (或 ≤2, 因该计数器有 ~1.2 s 刷新量子)
#         N-a4 ΔW20 **记录实测值, 不预设** —— 若仍 >0, 两条口径的独立性被直接证明
# 恢复: 写回 0x0 ⇒ 复核 carrier 回 1。
set -u
T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
D=/dev/xdma0_user
IF=enp1s0f1np1
W=${1:-5}
rd(){ $T/reg_rw $D "$1" w 2>/dev/null | tail -1 | sed 's/.*: *//'; }
wr(){ $T/reg_rw $D "$1" w "$2" >/dev/null 2>&1; }
carrier(){ echo "carrier=$(cat /sys/class/net/$IF/carrier) operstate=$(cat /sys/class/net/$IF/operstate) speed=$(cat /sys/class/net/$IF/speed) carrier_changes=$(cat /sys/class/net/$IF/carrier_changes)"; }
nic(){
  echo "NIC_T0 $(date +%s.%N)"
  ethtool -S $IF | grep -E '^ +(port_rx_(packets|good|bad|bytes|good_bytes|1024_to_15xx|overflow|nodesc_drops)|rx_eth_crc_err):' | tr -d ' ' | tr ':' ' '
  ethtool -S $IF | grep -E '^ +rx-[0-9]+\.' | tr -d ' ' | tr ':' ' '
  echo "NIC_T1 $(date +%s.%N)"
}
trig(){
  local g0 g1 s i
  g0=$(rd 0x1c); g0=$(( (g0 >> 16) & 0xffff ))
  echo "SNAP_T0 $(date +%s.%N)"
  wr 0x18 0x1
  for i in $(seq 1 500); do s=$(rd 0x1c); [ -z "$s" ] && continue; [ $(( s & 2 )) -ne 0 ] && break; sleep 0.002; done
  g1=$(rd 0x1c); g1=$(( (g1 >> 16) & 0xffff ))
  echo "SNAP_T1 $(date +%s.%N)"
  printf 'GEN %s %s\n' "$g0" "$g1"
}
dump(){ local i; for i in 0 5 8 9 13 20 21 24 41 42 43; do printf 'W%s %s\n' "$i" "$(rd $(printf '0x%X' $(( 0x20 + 4*i ))))"; done; }

pair(){  # NIC → 锁存 → NIC ; 返回 Δ (由调用者算)
  nic; trig; dump; nic
}

echo "===== PHASE 0: 基线 (TX_DIS 未拉) ====="
echo "TXDIS_RB0 $(rd 0x08)"
carrier
pair
echo "TXDIS_RB0B $(rd 0x08)"

echo "===== PHASE 1: 拉 TX_DIS (写 0x08 = 0x2) ====="
wr 0x08 0x2
echo "TXDIS_RB1 $(rd 0x08)   (判据 N-a1: 必须 = 0x00000002)"
sleep 3
echo "-- 掉链后 carrier (判据 N-a2: carrier 必须 = 0) --"
carrier
echo "===== PHASE 1 窗口 (${W}s; 判据 N-a3: Δport_rx_packets 必须 = 0) ====="
pair
echo "TXDIS_RB1B $(rd 0x08)"

echo "===== PHASE 2: 恢复 (写 0x08 = 0x0) ====="
wr 0x08 0x0
echo "TXDIS_RB2 $(rd 0x08)"
sleep 4
carrier
echo "NEGA_DONE"
