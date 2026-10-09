#!/bin/bash
# udp_longrun.sh -- P7b **UDP 演示 app 长时间线速**测量台架 (2026-10-09, 板级测试工程师轮)
#
# 被测对象: 板上 UDP app (rtl/app_udp_pattern.v, wrapper 里 TX_BYTES=0/TX_GAP=0 ⇒ 永久连续)
#   → udp_tx_cfg(peer 门) → udp_tx_frame → tx_arb → mac_tx_10g → XGMII → 对端 enp1s0f1np1
#
# 口径 (下游解析器必须遵守):
#   * 板侧计数器**全 32 位**: 任何 ΔW 一律 mod 2^32 且 raw 与回卷次数 k 一起记。
#       W9/W11/W13  (app 字节)  @9.5 Gbps ⇒ 3.604 s 回卷一次
#       W5/W24/W43/W29 (时基/字) 156.25 MHz ⇒ 27.487 s 回卷一次
#       W20/W8/W10  (帧, 813.8 kfps) ⇒ 88 min 回卷一次 (本台架窗内结构性不回卷)
#     ⇒ 长窗 (SECS≥60 s) **只能用逐点累加**(每点 ΔW5 < 27.5 s 无回卷) 或 mod+k 还原;
#       本台架两者都落盘: 逐点 raw 值 + 点间时间戳。
#   * 每个点 = 一次**触发锁存**(12/8 字同拍), gen 逐点 +1 自证; 点与点之间是差分。
#   * 对端 NIC: `port_rx_*` 是**周期刷新**的快照 (量子 ~1.2 s) ⇒ 判据一律取 pre2/post2
#     (≥2.5 s 后再读); `rx-N.rx_packets` 是连续可读计数 (逐点 trace 用它)。
#   * ⛔ 默认**不抓 pcap**(不落盘); 内容取证阶段 (phase content) 才抓 `-c N` 帧,
#     那一小段打 CONTENT_PCAP_ACTIVE=1 IO_AFFECTING=1。
#
# 用法(对端机, root): PEER_PW=... python tools/peer_ssh.py --sudo 'TAG=U1 SECS=300 bash /tmp/p7b_udp_longrun/udp_longrun.sh'
#   env: TAG(默认 U1) SECS(默认 300) STEP(默认 1.0 s) WORDS(默认 "5 9 20 43 56 21 11 13")
#        NFR(默认 3000, 内容抓帧数) LEARN_MBPS(默认 100) LEARN_SECS(默认 1)
#        SKIP_PING(默认 0) — 置 1 跳过 phase ping
set -u
TAG=${TAG:-U1}
SECS=${SECS:-300}
STEP=${STEP:-1.0}
WORDS=${WORDS:-"5 9 20 43 56 21 11 13"}
NFR=${NFR:-3000}
LEARN_MBPS=${LEARN_MBPS:-100}
LEARN_SECS=${LEARN_SECS:-1}
SKIP_PING=${SKIP_PING:-0}
IF=enp1s0f1np1
S=${P7B_SNAP:-/tmp/p7b_biz/p7b_snap.sh}
T=${P7B_TOOLS:-/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools}
D=/dev/xdma0_user
OUT=/tmp/p7b_udp_longrun
mkdir -p "$OUT"
export EXPECT_BID=${EXPECT_BID:-0x00000015}   # S3 长流刀 (BID 0x15)
export NW=${NW:-63}
EXPECT_GEN_STEP=1

brd(){ $T/reg_rw $D "$1" w 2>/dev/null | tail -1 | sed 's/.*: *//'; }
NIC(){ local tag="$1"
  { echo "### COALESCE $(ethtool -c $IF 2>/dev/null | grep -E 'Adaptive RX|rx-usecs:|tx-usecs:|rx-usecs-irq:|tx-usecs-irq:' | tr '\n' ' ')"
    ethtool -S $IF 2>/dev/null | grep -E '^ +(port_rx_good_bytes|port_rx_bytes|port_rx_packets|port_rx_bad|port_rx_bad_bytes|rx_eth_crc_err|port_rx_nodesc_drops|port_rx_overflow|port_rx_1024_to_15xx|port_rx_15xx_to_jumbo|port_rx_lt64|port_rx_64|port_tx_packets|port_tx_bytes|rx_ip_hdr_chksum_err|rx_tcp_udp_chksum_err|rx_frm_trunc|rx_overlength|rx_noskb_drops|rx_nodesc_trunc|rx-0.rx_packets|rx-1.rx_packets|rx-2.rx_packets|rx-3.rx_packets):'
    nstat -az 2>/dev/null | grep -E '^(UdpInDatagrams|UdpNoPorts|UdpInErrors|UdpRcvbufErrors|IcmpOutDestUnreachs|IcmpInMsgs|IpInReceives|IpOutRequests|TcpInSegs|TcpOutSegs|TcpRetransSegs) '
  } | tee "$OUT/nic_${TAG}_${tag}.txt"
}

echo "### META_BEGIN $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "LR_META_TAG=$TAG LR_META_SECS=$SECS LR_META_STEP=$STEP LR_META_WORDS='$WORDS'"
echo "LR_META_SCRIPT=$(readlink -f "$0") LR_META_SCRIPT_MD5=$(md5sum "$0" 2>/dev/null | cut -d' ' -f1)"
echo "LR_META_SNAP_MD5=$(md5sum "$S" 2>/dev/null | cut -d' ' -f1)"
echo "LR_META_UDP_SRC_MD5=$(md5sum /tmp/p7b_biz/p7b_udp_src 2>/dev/null | cut -d' ' -f1)"
echo "LR_META_BIT_SHA=${BIT_SHA:-n/a}"
echo "LR_META_BOARD_BID_PRE=$(brd 0x04)"
echo "LR_META_WRAP_RULE=all_board_cnt_32bit;delta_mod_2^32_raw_recorded;W9_3.604s(@9.5Gbps);W5/W43_27.487s;W20_88min"
echo "LR_META_IF=$IF IF_MAC=$(cat /sys/class/net/$IF/address) CARRIER=$(cat /sys/class/net/$IF/carrier 2>&1)"
echo "### PHASE geom_gate $(date +%s.%N)"
ip route get 192.168.100.2 | head -2
ip neigh show 192.168.100.2
bash "$S" id || { echo "LR_GEOM_FAIL 取数器身份闸未过"; exit 3; }

# ⭐ 2026-10-09 (D2 轮实测教训): `0x08` 既是 SCRATCH 又是 TX_DIS 门 —— 上一跑把它写成 0x2
#    之后, 板子的**内部计数器照跑**(W20 仍 809,578 fps) 而线上**一帧都没有**(NIC 全 0,
#    tcpdump 0 包) ⇒ 不先把它清 0 就测, 量到的是"内部速率"而不是"线上速率"。
echo "### PHASE tx_enable $(date +%s.%N)"
$T/reg_rw $D 0x08 w 0x0 >/dev/null 2>&1
for k in 1 2 3 4 5 6 7 8 9 10; do
  C=$(cat /sys/class/net/$IF/carrier 2>/dev/null)
  [ "$C" = "1" ] && break
  sleep 0.5
done
echo "TX_ENABLE_0x08=$(brd 0x08) CARRIER=$C"
[ "$C" = "1" ] || { echo "LR_ABORT 载波未起 (0x08=$(brd 0x08), carrier=$C): 不测 0 包窗口"; exit 3; }
sleep 1

echo "### PHASE ctrl0_ping_nocflood $(date +%s.%N)"
echo "CTRL0_TS $(date +%s.%N)"
ping -c 5 -i 0.3 -W 2 192.168.100.2 2>&1 | tail -4
echo "CTRL0_NC_TS $(date +%s.%N)"
nc -z -w 3 192.168.100.2 8080; echo "CTRL0_NC_RC=$?"

echo "### PHASE nic_pre $(date +%s.%N)"; NIC pre
sleep 2.5
echo "### PHASE nic_pre2 $(date +%s.%N)"; NIC pre2
echo "### PHASE pre_snapshot $(date +%s.%N)"
bash "$S" full "${TAG}_pre" || { echo "LR_ABORT pre_snapshot"; exit 1; }

echo "### PHASE learn_peer $(date +%s.%N)"
cd /tmp/p7b_biz || exit 9
BIT_SHA=${BIT_SHA:-n/a} ./p7b_udp_src --host 192.168.100.2 --port 8081 --paylen 1472 \
    --seconds "$LEARN_SECS" --mbps "$LEARN_MBPS" > "$OUT/learn_${TAG}.txt" 2>&1
echo "LEARN_RC=$? $(date +%s.%N)"
tail -12 "$OUT/learn_${TAG}.txt"
sleep 0.3
echo "### PHASE flood_check $(date +%s.%N)"
bash "$S" snap "${TAG}_check" 5 9 20 43

echo "### PHASE trace_start $(date +%s.%N)"
T0=$(date +%s.%N); echo "TRACE_T0 $T0"
i=0
MAXPTS=$(( SECS + 1 ))
while :; do
  TS=$(date +%s.%N)
  echo "TRACE_T $i $TS"
  bash "$S" snap "${TAG}_s$i" $WORDS
  RC=$?
  NICQ=$(ethtool -S $IF 2>/dev/null | grep -E '^ +rx-[0-9]\.rx_packets:' | awk '{printf "%s=%s ", $1, $2}')
  echo "TRACE_RC $i $RC $(date +%s.%N) NICQ $NICQ"
  i=$((i+1))
  [ "$i" -ge "$MAXPTS" ] && break
  NOW=$(date +%s.%N)
  NEXT=$(awk -v t0="$T0" -v i="$i" -v st="$STEP" 'BEGIN{printf "%.6f", t0+i*st}')
  SL=$(awk -v n="$NEXT" -v c="$NOW" 'BEGIN{d=n-c; if(d<0)d=0; printf "%.6f", d}')
  sleep "$SL"
done
TEND=$(date +%s.%N); echo "TRACE_TEND $TEND points=$i"

echo "### PHASE snap_post $(date +%s.%N)"
bash "$S" full "${TAG}_post" || echo "LR_WARN post_snapshot 失败"
echo "### PHASE nic_post $(date +%s.%N)"; NIC post
sleep 2.5
echo "### PHASE nic_post2 $(date +%s.%N)"; NIC post2
# ⭐ 硬门 (D2 轮教训): 线上**真的有帧**才叫一次有效测量。两条独立读数:
#    ① rx-2.rx_packets (连续可读, 不受刷新量子影响) ② port_rx_packets (周期刷新, 取 post2)
GQ_A=$(awk '$1=="rx-2.rx_packets:"{print $2}' "$OUT/nic_${TAG}_pre2.txt")
GQ_B=$(awk '$1=="rx-2.rx_packets:"{print $2}' "$OUT/nic_${TAG}_post2.txt")
GP_A=$(awk '$1=="port_rx_packets:"{print $2}' "$OUT/nic_${TAG}_pre2.txt")
GP_B=$(awk '$1=="port_rx_packets:"{print $2}' "$OUT/nic_${TAG}_post2.txt")
echo "LR_GATE_NIC_DELTA rx2=$((GQ_B-GQ_A)) port=$((GP_B-GP_A)) (SECS=$SECS ⇒ 期望 rx2 ~= $((SECS*809578)))"
if [ $((GQ_B - GQ_A)) -lt $((SECS*400000)) ] && [ $((GP_B - GP_A)) -lt $((SECS*400000)) ]; then
  echo "LR_GATE_FAIL 两条 NIC 口径都近乎零增量 ⇒ 线上没帧 (TX_DIS? 载波?) ⇒ 本跑作废"; exit 4
fi

echo "### PHASE content $(date +%s.%N)"
echo "CONTENT_PCAP_ACTIVE=1 IO_AFFECTING=1 nfr=$NFR (⚠️ 只有本小段写盘, 速率窗已结束)"
rm -f "$OUT/content_${TAG}.pcap"
# ⭐ 字表含 W8/W20 (帧计数): 每帧载荷恰 1472 B ⇒ 第 n 帧的**流绝对偏移 = 1472*n**;
#    由此把离线搜索范围从"整个 2^32"收窄到"±几十 ms 的帧号区间"(W9 每 3.6 s 回卷 ⇒ 绝对偏移早已 >2^32)。
( j=0; while [ $j -lt 400 ]; do
    echo "W8L $j $(date +%s.%N)"
    bash "$S" snap W8L$j 5 8 9 20 2>/dev/null | grep -E '^(W5|W8|W9|W20|SNAP_BEGIN) '
    j=$((j+1))
  done ) > "$OUT/w9loop_${TAG}.txt" 2>&1 &
W9PID=$!
sleep 0.1
timeout 30 tcpdump -i $IF -c "$NFR" -s 0 -w "$OUT/content_${TAG}.pcap" \
   'udp and src host 192.168.100.2 and dst port 8081' > "$OUT/tcpdump_${TAG}.txt" 2>&1
echo "TCPDUMP_RC=$?"
wait $W9PID
cat "$OUT/tcpdump_${TAG}.txt"
ls -la "$OUT/content_${TAG}.pcap"

if [ "$SKIP_PING" = "0" ]; then
echo "### PHASE ping_while_flood $(date +%s.%N)"
echo "PINGF_TS $(date +%s.%N)"
ping -c 5 -i 0.3 -W 2 192.168.100.2 2>&1 | tail -4
echo "PINGF_TS_END $(date +%s.%N)"
nc -z -w 3 192.168.100.2 8080; echo "PINGF_NC_RC=$?"
echo "### PHASE snap_postP $(date +%s.%N)"
bash "$S" full "${TAG}_postP" || echo "LR_WARN postP 失败"
fi

echo "### PHASE stop_flood $(date +%s.%N)"
$T/reg_rw $D 0x08 w 0x2 >/dev/null 2>&1
sleep 2
echo "STOP_0x08=$(brd 0x08) CARRIER_AFTER_STOP=$(cat /sys/class/net/$IF/carrier 2>&1)"
echo "### PHASE ping_after_stop $(date +%s.%N)"
echo "PINGS_TS $(date +%s.%N)"
ping -c 5 -i 0.3 -W 2 192.168.100.2 2>&1 | tail -4
nc -z -w 3 192.168.100.2 8080; echo "PINGS_NC_RC=$?"
echo "LR_META_BOARD_BID_END=$(brd 0x04) LR_META_BOARD_0x08_END=$(brd 0x08)"
echo "### LR_DONE $(date +%s.%N)"
