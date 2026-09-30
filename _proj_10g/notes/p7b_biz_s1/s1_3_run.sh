#!/bin/bash
# s1_3_run.sh -- S1.3 UDP 上行: 段1 慢档 (2 Gbps) 建对齐基线, 段2..4 满速,
#               每段 2.5 s 且 **--off 逐段接力** (不接力 = 对端从 0 重发 = 自伤成"发现缺陷")
#   ⚠️ 每段前后各一次 full 快照; 每段独立自证 gen+1 (由 p7b_snap.sh 保证)
#   ⚠️ 本脚本一跑, 板子的 UDP app 就"上电" (learn-on-RX) => 之后板子会 ~9.5 Gbps 持续发射
set -u
cd /tmp/p7b_biz || exit 9
S=/tmp/p7b_biz/p7b_snap.sh
OFF=0
KW='^W(0|1|3|4|5|10|11|12|13|20|21|22|23|24|32|33|34|35|36|37|43|46|47|48|49) '
seg(){
  local tag="$1"; shift
  echo "### SEG_SEND $tag $(date +%s.%N) off_in=$OFF"
  local out
  out=$(./p7b_udp_src --host 192.168.100.2 --port 8081 --paylen 1472 --off "$OFF" "$@")
  echo "$out"
  OFF=$(echo "$out" | sed -n 's/.*off_end=\([0-9]*\).*/\1/p' | tail -1)
  [ -n "$OFF" ] || { echo "S1_3_ABORT 解析不到 off_end"; exit 1; }
  echo "### SEG_DONE $tag off_out=$OFF $(date +%s.%N)"
  echo "### SNAP $tag $(date +%s.%N)"
  bash "$S" full "S1_3_$tag" | grep -E "$KW" || exit 1
}
echo "### PEER_TX_PRE $(date +%s.%N)"
ethtool -S enp1s0f1np1 | grep -E '^ +(tx-[0-9]\.tx_packets|port_tx_packets|port_tx_bytes)'
echo "### SNAP p0 $(date +%s.%N)"
bash "$S" full S1_3_p0 | grep -E "$KW" || exit 1
seg p1 --seconds 2   --mbps 2000 --batch 32
seg p2 --seconds 2.5 --mbps 0    --batch 32
seg p3 --seconds 2.5 --mbps 0    --batch 32
seg p4 --seconds 2.5 --mbps 0    --batch 32
echo "### PEER_TX_POST $(date +%s.%N)"
ethtool -S enp1s0f1np1 | grep -E '^ +(tx-[0-9]\.tx_packets|port_tx_packets|port_tx_bytes)'
echo "S1_3_DONE $(date +%s.%N)"
