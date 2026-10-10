#!/bin/bash
# wdump.sh -- 流中 ACK 抓包 (窗口字段地基真相): 两相
#   相1: 抓握手 (SYN/SYN-ACK, wscale 选项见证) —— 等 port 8080 上的 SYN 类包
#   相2: 等 ESTAB 后 sleep3, 再打 6 个**点采样** (每个 80 包, 间隔 1.5 s) —— 窗口字段时序分布
#   用法(对端机): bash wdump.sh TAG [NPKT=80] [NPOINT=6]
#   产出: /tmp/dump_${TAG}_hs.pcap, /tmp/dump_${TAG}_p{0..N-1}.pcap (与 /tmp/dump_${TAG}.err)
#   ⚠️ IO_AFFECTING: 只在单跑登记, 不全程开
set -u
TAG=${1:?need TAG}; NPKT=${2:-80}; NPOINT=${3:-6}
IF=enp1s0f1np1
ERR=/tmp/dump_${TAG}.err
: > "$ERR"
# ---- 相1: 握手 (SYN 或 SYN-ACK) ----
# ⚠️ -c 只能是 2 (SYN + SYN-ACK): 写成 4 会永远凑不满 ⇒ tcpdump 不退出 ⇒ -w 文件 0 字节
#    (缓冲只在退出时 flush; 教训 2026-10-10 r2 首次尝试)。加 -U 持续 flush 兜底。
timeout 150 tcpdump -U -i "$IF" -s 128 -c 2 'port 8080 and tcp[tcpflags] & tcp-syn != 0' -w "/tmp/dump_${TAG}_hs.pcap" 2>>"$ERR"
echo "PHASE1_DONE rc=$? at $(date +%s.%N)" >> "$ERR"
# ---- 相2: 等 ESTAB ----
for i in $(seq 1 240); do
  ss -tinH '( dport = :8080 or sport = :8080 )' 2>/dev/null | grep -q ESTAB && break
  sleep 0.5
done
sleep 3
for p in $(seq 0 $((NPOINT-1))); do
  # ⚠️ 方向: 对端(客户端, 临时端口) -> 板(8080) ⇒ 'dst port 8080' 才是**对端的 ACK**
  #    ('src port 8080' 抓的是板发的数据包, 其 win = 板我方的 49152 —— 2026-10-10 首跑踩过)
  timeout 3 tcpdump -i "$IF" -s 96 -c "$NPKT" 'dst port 8080' -w "/tmp/dump_${TAG}_p${p}.pcap" 2>>"$ERR"
  echo "PHASE2_P${p}_DONE rc=$? at $(date +%s.%N)" >> "$ERR"
  sleep 1.5
done
echo "DUMP_DONE at $(date +%s.%N)" >> "$ERR"
