#!/bin/bash
# tcpreg_j6.sh -- J6/J15 TCP 上行 A/B 测量 (peer -> board, port 8080)
#   与 Stage 1 S1.0a / Stage 2 §10.5.1 同工具同参数: p7b_tcp_src --port 8080 --seconds 6
#   同时抓: 板侧快照 pair (pre/post) + 双向 pcap (窗口轨迹) + ss -ti 采样 + ping
# 用法: NW=61 bash tcpreg_j6.sh <secs> <pcap> <tag>        # PACE=<bps> 环境变量选 pacing (0 = 不限速)
#   ⚠️ NW 默认 61 (BIZ 位流); 旧 51 字位流要 NW=51 UNIMPL_ADDR=0xEC EXPECT_BID=0x00000007
#   ⚠️ 本脚本**同时**是 J6 (对端口径) 与 J15 (板内时基新预测带) 的台架:
#      J15 的板内时基 = 同一份 pre/post 全窗快照的 ΔW 系列 (ΔW0/ΔW53/ΔW22, 速率用 ΔW5 时基)。
#
#   ⭐ 2026-10-07 (测量台准备轮) 两处加固 —— 补判据记录缺口 (全局 §六 #43/#48):
#     ① PACE_BPS= **无条件打印** (PACE=0 也打): 曾有一跑读数恰贴 2^30 bps 的 99.94%,
#        而原始件里没有任何 pace 记录 ⇒ 事后无法自证量的是板子还是工具的帽子。
#        PACE_BPS 行紧贴 SRC_* 输出行 (同一份 stdout), 此后任何速率判读必须引用它。
#     ② J6META_* 元数据块: 跑的时刻 (UTC+epoch) / 目标 / 时长 / 脚本 md5 / BIT_SHA / 板侧身份。
#        ⚠️ 位流 sha256 传不进来时打 n/a, 但 **板侧身份 (MAGIC/BID) 是现场读的、不可伪造**
#        (开始与结束各读一次 ⇒ 中途被重烧可检出)。
set -u
SECS=${1:-6}; PCAP=${2:-/tmp/tcpreg.pcap}; TAG=${3:-J6}
S=/tmp/p7b_biz/p7b_snap.sh
T=${P7B_TOOLS:-/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools}
D=/dev/xdma0_user
cd /tmp/p7b_biz || exit 9

PACE=${PACE:-0}
if [ "$PACE" != "0" ]; then EXTRA="--pace-bps $PACE"; else EXTRA=""; fi

T_START=$(date +%s.%N)
brd(){ [ -x "$T/reg_rw" ] && $T/reg_rw $D "$1" w 2>/dev/null | tail -1 | sed 's/.*: *//'; }
echo "### J6META_BEGIN $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "J6META_T_START_EPOCH=$T_START J6META_T_START_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "J6META_HOST=$(hostname) J6META_TAG=$TAG"
echo "J6META_TARGET=192.168.100.2:8080 J6META_SECS=$SECS J6META_PCAP=$PCAP"
echo "J6META_SCRIPT=$0 J6META_SCRIPT_MD5=$(md5sum "$0" 2>/dev/null | cut -d' ' -f1)"
echo "J6META_BIT_SHA=${BIT_SHA:-n/a}"
echo "PACE_BPS=$PACE"
echo "SRC_CMD=./p7b_tcp_src --host 192.168.100.2 --port 8080 --seconds $SECS $EXTRA"
echo "J6META_BOARD_MAGIC=$(brd 0x00) J6META_BOARD_BID=$(brd 0x04)"
echo "### J6META_END $(date +%s.%N)"

echo "### PHASE route_carrier $(date +%s.%N)"
ip route get 192.168.100.2 | head -2
echo "CARRIER=$(cat /sys/class/net/enp1s0f1np1/carrier 2>&1)"

echo "### PHASE pre_snapshot $(date +%s.%N)  NW=${NW:-61}"
bash "$S" full "${TAG}_pre" || { echo "TCPREG_ABORT pre_snapshot"; exit 1; }

rm -f "$PCAP"
( timeout $((SECS+14)) tcpdump -i enp1s0f1np1 -s 96 -w "$PCAP" "tcp and host 192.168.100.2" >/tmp/tcpdump_${TAG}.log 2>&1 & )
sleep 1.5

( for i in $(seq 1 $((SECS+3))); do
    echo "SS_T $(date +%s.%N) $(ss -tinm state established '( dport = :8080 or sport = :8080 )' 2>/dev/null | tr '\n' '|')"
    sleep 1
  done > /tmp/ss_${TAG}.log 2>&1 & )

echo "### PHASE src_start $(date +%s.%N)"
echo "PACE_BPS=$PACE"
# J15 板内时基: 紧贴传输窗的两点 (W5=156.25MHz 自由计数 / W53=app 收字节 / W54=失配)
#   => 板侧速率 = ΔW53 / (ΔW5/156.25e6), 不依赖主机墙钟、也不含 tcpdump/收尾的死时间。
bash "$S" snap "${TAG}_t0" 5 53 54 || { echo "TCPREG_ABORT t0_snapshot"; exit 1; }
./p7b_tcp_src --host 192.168.100.2 --port 8080 --seconds "$SECS" $EXTRA
echo "SRC_RC=$? $(date +%s.%N)"
echo "### PHASE t1_snapshot $(date +%s.%N)"
bash "$S" snap "${TAG}_t1" 5 53 54 || { echo "TCPREG_ABORT t1_snapshot"; exit 1; }
sleep 2

echo "### PHASE post_snapshot $(date +%s.%N)"
bash "$S" full "${TAG}_post" || { echo "TCPREG_ABORT post_snapshot"; exit 1; }

sleep 1
echo "### PHASE ping $(date +%s.%N)"
ping -c 3 -i 0.2 -W 1 192.168.100.2 2>/dev/null | tail -2 | tr '\n' ' '; echo

wc -c "$PCAP"
T_END=$(date +%s.%N)
echo "J6META_T_END_EPOCH=$T_END J6META_T_END_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ) J6META_DUR_S=$(awk -v a="$T_START" -v b="$T_END" 'BEGIN{printf "%.3f", b-a}')"
echo "PACE_BPS=$PACE J6META_BOARD_BID_END=$(brd 0x04)"
echo "TCPREG_J6_DONE"
