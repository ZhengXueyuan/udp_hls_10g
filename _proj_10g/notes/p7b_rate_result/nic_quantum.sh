#!/bin/bash
# nic_quantum.sh -- 对端 NIC 计数器的**更新量子**反解 (V1 裁决的实验部分)
#
# 为什么要: rate_calc 的 V1 判据 (d_mac/d_board ∈ [0.995,1.005]) 在短窗下反复落在
#   0.80 与 1.31 两个极端 —— 而 d_mac < d_dma 在物理上不可能 (MAC 收不到的帧不可能被 DMA 交付)
#   ⇒ 先验怀疑 `port_rx_*` 不是连续计数, 而是**周期刷新的快照**。本脚本直接测它的刷新间隔。
# 只读: 只跑 ethtool -S, 不碰板子、不改配置。
# 用法: nic_quantum.sh <samples> <sleep_secs>
N=${1:-14}
S=${2:-0.20}
get(){ ethtool -S enp1s0f1np1 | sed -n 's/^ *port_rx_packets: //p;s/^ *port_rx_good: //p;s/^ *rx-0\.rx_packets: //p;s/^ *port_rx_nodesc_drops: //p' | tr '\n' ' '; }
prev=""; i=1
while [ "$i" -le "$N" ]; do
  t=$(date +%s.%N)
  printf 'Q %s %s %s\n' "$i" "$t" "$(get)"
  sleep "$S"
  i=$(( i + 1 ))
done
echo QUANTUM_DONE
