#!/bin/bash
# up_ceil.sh -- P7B 上行天花板轮 (2026-10-10): 对端(192.168.100.100) -> 板(192.168.100.2:8080) TCP 上行
#   板 = 服务端 (Build A / BID 0x16 = TX_CONTINUOUS ⇒ 下行同时持续发送) ⇒ 本构型天然是"双向"
# 用法: bash up_ceil.sh <secs> <tag> [src二进制] [src 额外参数...]
#   ⚠️ 必须 root 跑 (快照窗口 /dev/xdma0_user = root only)
# 口径 (与 P7B_LONGSEND 轮一致):
#   * 轨迹采样: 每点 = 一次 snap (trig gen 自证 +1), 区间 dt = ΔW5/156.25e6 (必须 < 3.66 s)
#   * 每点前后自证: gen 恰 +1 (p7b_snap.sh 内部断言); 0xffffffff = SLVERR ⇒ 整窗作废
#   * W51/W53 是 32 位 ⇒ 分析端 mod 2^32 且同时记 raw 与回卷次数 k
#   * ⛔ 2026-10-10 口径订正 (注释; 行为零改动): KW 里的 W43 = mac_tx_10g.stat_tx_words =
#     **每拍无条件 +1 的 tx 域拍钟** (mac_tx_10g.v:330, 在 case(state) 之外) ⇒ an_up.py 的
#     P=ΔW43/ΔW20 ≡ 156.25e6/fps (恒等式), "duty%=193/P" 只是"fps 未达几何上限"的换算式、
#     **不是线占空测量** (板侧没有线占空计数器; W44 只数控制字符)。
set -u
SECS=${1:-40}; TAG=${2:-U1}
[ $# -ge 2 ] && shift 2
SRC=${1:-/tmp/p7b_biz/p7b_tcp_src_fix}
[ $# -ge 1 ] && shift
EXTRA="$*"
SRCDIR=/tmp/p7b_biz
S=$SRCDIR/p7b_snap.sh
KW="5 0 1 51 52 53 54 20 43 15 14 23 21 55 61 62 35 41 42 45 59 60 27 28 38"
# ⛔ p7b_snap.sh 默认 EXPECT_BID=0x0000000A (Stage C 的值) ⇒ 本构建 (BID 0x16) 必须显式覆盖
export EXPECT_BID=${EXPECT_BID:-0x00000016}
export NW=${NW:-63}
cd "$SRCDIR" || exit 9
echo "### UP_BEGIN $(date -u +%Y-%m-%dT%H:%M:%SZ) TAG=$TAG SECS=$SECS"
echo "UP_META_SCRIPT_MD5=$(md5sum "$0" | cut -d' ' -f1)"
echo "UP_META_SRC_BIN=$(basename "$SRC")  MD5=$(md5sum "$SRC" | cut -d' ' -f1)  EXTRA=[$EXTRA]"
COAL=$(ethtool -c enp1s0f1np1 2>/dev/null | awk '/Adaptive RX/{a=$3} /^rx-usecs:/{r=$2} END{printf "adaptive-rx=%s rx-usecs=%s", a, r}')
echo "COALESCE=$COAL"
echo "TCP_RMEM=$(sysctl -n net.ipv4.tcp_rmem)  TCP_MODERATE_RCVBUF=$(sysctl -n net.ipv4.tcp_moderate_rcvbuf)"
echo "ROUTE=$(ip route get 192.168.100.2 2>&1 | head -1)"
echo "CARRIER=$(cat /sys/class/net/enp1s0f1np1/carrier 2>&1)"
NICR=/sys/class/net/enp1s0f1np1/statistics
nic_snap(){ echo "$1 rx_bytes=$(cat $NICR/rx_bytes) tx_bytes=$(cat $NICR/tx_bytes) rx_packets=$(cat $NICR/rx_packets) tx_packets=$(cat $NICR/tx_packets)"; }
nic_snap NIC_PRE
ethtool -S enp1s0f1np1 > /tmp/up_${TAG}_ethpre.txt 2>&1
echo "ETHSTAT_PRE_MD5=$(md5sum /tmp/up_${TAG}_ethpre.txt | cut -d' ' -f1)"
bash "$S" id || { echo "UP_GEOM_FAIL 身份闸"; exit 3; }
echo "### 流前基线快照"
bash "$S" snap "${TAG}_s0" $KW
echo "### 起流 $(date +%s.%N)"
"$SRC" --host 192.168.100.2 --port 8080 --seconds "$SECS" $EXTRA > /tmp/up_${TAG}_src.txt 2>&1 &
SPID=$!
# CPU 见证: 逐秒 /proc/stat 全核 + 工具进程 jiffies (含运行核号 $39)
( while [ -d /proc/$SPID ]; do echo "CPU_T $(date +%s.%N)"; grep -E '^cpu' /proc/stat; sleep 1; done ) > /tmp/up_${TAG}_cpu.txt 2>&1 &
CPID=$!
( while [ -d /proc/$SPID ]; do echo "PROC_T $(date +%s.%N) $(awk '{print "uj="$14" sj="$15" core="$39}' /proc/$SPID/stat 2>/dev/null)"; sleep 1; done ) > /tmp/up_${TAG}_proc.txt 2>&1 &
PPID2=$!
# ss 见证 (内核侧独立 oracle: bytes_sent/bytes_acked + 窗口/ RTT / cwnd / unacked)
( while [ -d /proc/$SPID ]; do echo "SS_T $(date +%s.%N)"; ss -tin "dst 192.168.100.2" 2>/dev/null | head -8; sleep 1; done ) > /tmp/up_${TAG}_ss.txt 2>&1 &
SPID2=$!
# 轨迹采样 (只要源在跑就继续)
i=0
while kill -0 $SPID 2>/dev/null; do
  i=$((i+1))
  sleep 1.5
  kill -0 $SPID 2>/dev/null || break
  echo "LF_SNAP_T $(date +%s.%N) $i"
  bash "$S" snap "${TAG}_s$i" $KW || { sleep 1.0; echo "LF_SNAP_T $(date +%s.%N) $i"; bash "$S" snap "${TAG}_s$i" $KW; }
done
wait $SPID; SRC_RC=$?
echo "### SRC_RC=$SRC_RC 流止 $(date +%s.%N)"
kill $CPID $PPID2 $SPID2 2>/dev/null; sleep 0.3
i=$((i+1)); echo "LF_SNAP_T $(date +%s.%N) $i"
bash "$S" snap "${TAG}_s$i" $KW
nic_snap NIC_POST
ethtool -S enp1s0f1np1 > /tmp/up_${TAG}_ethpost.txt 2>&1
echo "### SRC 读出行 (全):"
cat /tmp/up_${TAG}_src.txt
echo "UP_DONE $(date +%s.%N)"
