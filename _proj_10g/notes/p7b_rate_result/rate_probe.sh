#!/bin/bash
# rate_probe.sh -- P7B 线速测量：板侧 51 字 A/B 快照 + 对端 NIC 计数（同窗包围）
#
# 取数编排（逐条对应 P7B_RATE_MEASURE_PLAN.md §5.3 / §9）：
#   nic_A → [锁存 A] → dump A(51 字) → 补足到 WIN 秒 → [锁存 B] → nic_B → dump B(51 字)
#   ⇒ 板侧窗 [latchA, latchB] 由**板内 W5 计数**度量（时基精确到 1 拍）；
#     NIC 窗 [nic_A, nic_B] 两端各在锁存外 ~0.1 s ⇒ 宽度 ≈ 板侧窗 + 0.2 s（如实登记）
#   ⚠️ 两个"不许"：
#     ① 锁存后**先取 NIC 再 dump** 才不影响锁存时刻（快照是锁存的，读回时间不改变它）
#     ② dump A 必须在 trig B 之前（否则快照被新一代覆盖）
#   ⚠️ 窗口由 WIN 参数**自适应补足**（不是"睡 WIN 秒"）—— 否则 dump 的耗时会把
#      latch→latch 窗口撑到 W9(3.61s) 之外 ⇒ A5 回绕不可判。
# 只触发快照（写 0x18），不改任何板侧配置；NIC 侧只读 ethtool -S。
# 用法: rate_probe.sh <win_secs> <tag>
set -u
T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
D=/dev/xdma0_user
WIN=${1:-2.5}
TAG=${2:-R}
rd(){ $T/reg_rw $D "$1" w 2>/dev/null | tail -1 | sed 's/.*: *//'; }

nic(){
  echo "NIC_T0_$TAG $(date +%s.%N)"
  ethtool -S enp1s0f1np1 | grep -E '^ +(port_rx_(packets|good|bad|bytes|good_bytes|bad_bytes|unicast|multicast|broadcast|64|65_to_127|128_to_255|256_to_511|512_to_1023|1024_to_15xx|15xx_to_jumbo|overflow|nodesc_drops|pause|control)|rx_eth_crc_err|rx_frm_trunc|rx_overlength|port_tx_packets):' | tr -d ' ' | tr ':' ' '
  ethtool -S enp1s0f1np1 | grep -E '^ +rx-[0-9]+\.' | tr -d ' ' | tr ':' ' '
  echo "NIC_T1_$TAG $(date +%s.%N)"
}

trig(){   # 触发一次快照并轮询 done；回显 G0/G1 与锁存时刻（L3 归属自证）
  G0=$(rd 0x1c); G0=$(( (G0 >> 16) & 0xffff ))
  echo "SNAP_T0_$TAG $(date +%s.%N)"
  $T/reg_rw $D 0x18 w 0x1 >/dev/null 2>&1
  S=""
  local i
  for i in $(seq 1 500); do S=$(rd 0x1c); [ -z "$S" ] && continue; [ $(( S & 2 )) -ne 0 ] && break; sleep 0.002; done
  G1=$(rd 0x1c); G1=$(( (G1 >> 16) & 0xffff ))
  LATCH_WALL=$(date +%s.%N)          # ⭐ 本代的锁存时刻（自适应补足用它算 pad）
  echo "SNAP_T1_$TAG $LATCH_WALL"
  printf 'GEN %s %s\n' "$G0" "$G1"
}
LATCH_WALL=0

dump(){   # 逐字读 51 字 + 身份闸（parse 层要求每个值都匹配 ^0x[0-9a-f]{1,8}$ ⇒ 空读立刻现形）
  printf 'MAGIC %s\n'  "$(rd 0x00)"
  printf 'BID %s\n'    "$(rd 0x04)"
  printf 'MARKER %s\n' "$(rd 0x14)"
  local i
  for i in $(seq 0 50); do printf 'W%s %s\n' "$i" "$(rd $(printf '0x%X' $(( 0x20 + 4*i ))))"; done
  printf 'UNIMPL %s\n' "$(rd 0xEC)"
}

echo "PROBE_BEGIN tag=$TAG win=$WIN t=$(date +%s.%N)"
echo "ROUTE $(ip route get 192.168.100.2 2>&1 | head -1)"
echo "NIC_LINK carrier=$(cat /sys/class/net/enp1s0f1np1/carrier) operstate=$(cat /sys/class/net/enp1s0f1np1/operstate) changes=$(cat /sys/class/net/enp1s0f1np1/carrier_changes)"

echo "===== BLOCK A ====="
nic
trig
dump
TA=$(date +%s.%N)
echo "LATCHA_WALL $TA"

# 自适应补足：让 latch→latch 恰好 WIN 秒（dump 的耗时已经吃掉了大半；不足则 pad=0）
PAD=$(awk -v a="$LATCH_WALL" -v b="$TA" -v w="$WIN" 'BEGIN{p=w-(b-a); if(p<0)p=0; printf "%.3f", p}')
echo "PAD_SLEEP $PAD  (dumpA 已耗时 $(awk -v a="$LATCH_WALL" -v b="$TA" 'BEGIN{printf "%.3f", b-a}') s)"
sleep "$PAD"

echo "===== BLOCK B ====="
trig
nic
dump
echo "PROBE_END tag=$TAG t=$(date +%s.%N)"
