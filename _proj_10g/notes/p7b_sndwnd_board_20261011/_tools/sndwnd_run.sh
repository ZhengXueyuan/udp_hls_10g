#!/bin/bash
# sndwnd_run.sh -- P7b snd_wnd 守卫板级轮 (2026-10-11): 一跑的执行件 (**在对端机以 root 跑**)
#   用法: bash sndwnd_run.sh <TAG> <MODE> <SECS> [RCVBUF] [INJECT_AT] [INJECT_N]
#   MODE:
#     pa     = task-2 persist 回归 (照抄 persist 轮 P-A): sink (refresh件) --rcvbuf 1460
#              --rcvbuf-after-connect + 注入器 (PROBE_WIN=0 ACK_MODE=fresh)
#     active = task-3/4 判别 (活跃流): sink (refresh件) --rcvbuf 2920 (默认 before_connect, 在读)
#              + 注入器 (PROBE_WIN=0 ACK_MODE=fresh_minus = 不可接受 ACK + win=0)
#     c2s    = task-3/4 的功率版: persist_client (--order after --rcvbuf 2920, 永不读 = 真零窗停滞)
#              + 注入器 (PROBE_WIN=65535 ACK_MODE=fresh_minus = 不可接受 ACK + 假大窗)
#   env: EXPECT_BID / NW / INJECT_AT / INJECT_N / PROBE_WIN_OVR / ACK_MODE_OVR / GAP /
#        STALL_N / POLL_MS / MAXBYTES / SNAP_MAX / SNAPGAP
#   取数面: capA = 板->对端 小帧(<=100B) 全程 (探询识别); capB = 双向 小帧(<=100B) -c 限深;
#           capD (active) = 板->对端 数据帧(>100B, -s 64) 注入前后窗; capC (c2s) = 同款 -c 4000
#           snap 环 = p7b_snap.sh snap (KW 字表)
set -u
TAG=${1:?usage: sndwnd_run.sh TAG MODE SECS [RCVBUF] [INJECT_AT] [INJECT_N]}
MODE=${2:?need MODE}; SECS=${3:?need SECS}
RCVBUF=${4:-}; INJECT_AT=${5:-}; INJECT_N=${6:-}
IF=enp1s0f1np1
BOARD=192.168.100.2
D=/dev/xdma0_user
T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
S=/tmp/p7b_biz/p7b_snap.sh
D2=/tmp/p7b_sndwnd
SINK=/tmp/p7b_biz_refresh/p7b_tcp_sink
KW=${KW:-'5 14 15 20 43 51 55 57 58 63 66 67 68 69'}
STALL_N=${STALL_N:-3}; POLL_MS=${POLL_MS:-5000}
SNAP_MAX=${SNAP_MAX:-2000}; SNAPGAP=${SNAPGAP:-0.1}
GAP=${GAP:-0.15}
export EXPECT_BID=${EXPECT_BID:-0x0000001E} NW=${NW:-70}

case "$MODE" in
  pa)     : "${RCVBUF:=1460}"; : "${INJECT_AT:=3.0}";  : "${INJECT_N:=3}"; PW=${PROBE_WIN_OVR:-0};   AM=${ACK_MODE_OVR:-fresh};       MB=${MAXBYTES:-400000000} ;;
  active) : "${RCVBUF:=2920}"; : "${INJECT_AT:=10.0}"; : "${INJECT_N:=5}"; PW=${PROBE_WIN_OVR:-0};   AM=${ACK_MODE_OVR:-fresh_minus}; MB=${MAXBYTES:-4000000000} ;;
  c2s)    : "${RCVBUF:=2920}"; : "${INJECT_AT:=8.0}";  : "${INJECT_N:=3}"; PW=${PROBE_WIN_OVR:-65535}; AM=${ACK_MODE_OVR:-fresh_minus}; MB=${MAXBYTES:-4000000000} ;;
  *) echo "FATAL: 未知 MODE=$MODE"; exit 3 ;;
esac

echo "### RUN_BEGIN tag=$TAG mode=$MODE secs=$SECS rcvbuf=$RCVBUF inject_at=$INJECT_AT n=$INJECT_N gap=$GAP $(date +%s.%N)"
echo "### PROBE_CONFIG PROBE_WIN=$PW ACK_MODE=$AM ACK_OFFSET=${ACK_OFFSET:-4194304} SNIFF_MS=${SNIFF_MS:-20}"
echo "### KW='$KW' STALL_N=$STALL_N POLL_MS=$POLL_MS MAXBYTES=$MB SNAP_MAX=$SNAP_MAX SNAPGAP=$SNAPGAP"
echo "### SNAP_MD5 $(md5sum $S | awk '{print $1}')  SINK_MD5 $(md5sum $SINK | awk '{print $1}')  CLIENT_MD5 $(md5sum $D2/persist_client.py 2>/dev/null | awk '{print $1}')  PROBE_MD5 $(md5sum $D2/stall_probe_u7.py 2>/dev/null | awk '{print $1}')"
echo "### EXPECT_BID=$EXPECT_BID NW=$NW"

echo "--- 板侧身份闸 (跑前) ---"
bash $S id; echo "ID_RC=$?"
echo -n "BID="; $T/reg_rw $D 0x04 w 2>&1 | tail -1
echo -n "SCRATCH_0x08="; $T/reg_rw $D 0x08 w 2>&1 | tail -1
echo -n "CARRIER="; cat /sys/class/net/$IF/carrier
echo -n "NETADDR="; ip -4 addr show $IF | grep -o 'inet [0-9./]*'
echo -n "ROUTE="; ip route get $BOARD | head -1

echo "--- 抓包 A: 板->对端 小帧 (<=100B, 全程) ---"
rm -f /tmp/sndwnd_${TAG}_capA.pcap /tmp/sndwnd_${TAG}_capA.err
setsid nohup tcpdump -i $IF -s 0 -U -w /tmp/sndwnd_${TAG}_capA.pcap \
   "tcp port 8080 and src host $BOARD and less 100" \
   > /tmp/sndwnd_${TAG}_capA.err 2>&1 < /dev/null &
CAPA=$!
echo "--- 抓包 B: 双向 小帧 (<=100B, -c 400000 限深) ---"
rm -f /tmp/sndwnd_${TAG}_capB.pcap /tmp/sndwnd_${TAG}_capB.err
setsid nohup tcpdump -i $IF -s 0 -U -c 400000 -w /tmp/sndwnd_${TAG}_capB.pcap \
   "tcp port 8080 and less 100" \
   > /tmp/sndwnd_${TAG}_capB.err 2>&1 < /dev/null &
CAPB=$!
echo "CAPA=$CAPA CAPB=$CAPB"
CAPD=""
if [ "$MODE" = "active" ]; then
  echo "--- 抓包 D: 板->对端 数据帧 (>100B; -s 64; -c 400000; 延时 ${INJECT_AT}s 后启动 = 覆盖注入窗) ---"
  rm -f /tmp/sndwnd_${TAG}_capD.pcap /tmp/sndwnd_${TAG}_capD.err
  DSLEEP=$(awk -v a=$INJECT_AT 'BEGIN{printf "%.1f", (a-0.8>0)? a-0.8 : 0}')
  ( sleep $DSLEEP; setsid nohup tcpdump -i $IF -s 64 -U -c 400000 -w /tmp/sndwnd_${TAG}_capD.pcap \
       "tcp port 8080 and src host $BOARD and greater 100" \
       > /tmp/sndwnd_${TAG}_capD.err 2>&1 < /dev/null ) &
  CAPD=$!
  echo "CAPD=$CAPD (delay $DSLEEP s)"
  echo "--- 抓包 E: 对端->板 小帧 且 win==0 (= 注入帧的**直接上线见证**; 本构型天然 ACK 的 win!=0; -c 200) ---"
  rm -f /tmp/sndwnd_${TAG}_capE.pcap /tmp/sndwnd_${TAG}_capE.err
  setsid nohup tcpdump -i $IF -s 0 -U -c 200 -w /tmp/sndwnd_${TAG}_capE.pcap \
     "tcp port 8080 and src host 192.168.100.100 and less 100 and tcp[14:2] = 0" \
     > /tmp/sndwnd_${TAG}_capE.err 2>&1 < /dev/null &
  CAPE=$!
  echo "CAPE=$CAPE"
fi
if [ "$MODE" = "c2s" ]; then
  echo "--- 抓包 C: 板->对端 数据帧 (>100B; -s 96; -c 4000 全程: 初突发 + 注入后突发) ---"
  rm -f /tmp/sndwnd_${TAG}_capC.pcap /tmp/sndwnd_${TAG}_capC.err
  setsid nohup tcpdump -i $IF -s 96 -U -c 4000 -w /tmp/sndwnd_${TAG}_capC.pcap \
     "tcp port 8080 and src host $BOARD and greater 100" \
     > /tmp/sndwnd_${TAG}_capC.err 2>&1 < /dev/null &
  CAPC=$!
  echo "CAPC=$CAPC"
fi

echo "--- 板侧快照环 (后台; ${SNAPGAP}s/点; 上限 $SNAP_MAX 点) ---"
( n=0; while [ $n -lt $SNAP_MAX ]; do
    echo "SNAP_T $(date +%s.%N)"
    bash $S snap "${TAG}_N${n}" $KW 2>&1
    n=$((n+1))
    sleep $SNAPGAP
  done ) > /tmp/sndwnd_${TAG}_snap.log 2>&1 &
SNAPPID=$!
echo "SNAP_PID=$SNAPPID"

echo "--- 侧信道: ss 采样 (0.5s/点) ---"
( while :; do
    echo "SS_T $(date +%s.%N)"
    ss -tinm state established '( dport = :8080 )' 2>&1
    sleep 0.5
  done ) > /tmp/sndwnd_${TAG}_ss.log 2>&1 &
SSPID=$!
echo "SS_PID=$SSPID"

echo "--- 对端内核计数 (跑前) ---"
nstat -az 2>/dev/null | grep -E '^(TcpInSegs|TcpOutSegs|TcpRetransSegs|TcpExtTCPOFOQueue|TcpExtTCPFastRetrans|TcpExtTCPZeroWindowDrop|TcpExtTcpExtTCPRcvQDrop|TcpExtTCPRcvQDrop|TcpExtTCPBacklogDrop|TcpExtTCPWqueueTooBig) ' > /tmp/sndwnd_${TAG}_nstat_pre.txt
cat /tmp/sndwnd_${TAG}_nstat_pre.txt

echo "--- 注入器 (stall_probe_u7; PROBE_WIN=$PW; ACK_MODE=$AM; 等 SYN 后 ${INJECT_AT}s 注入 ${INJECT_N} 个) ---"
rm -f /tmp/sndwnd_${TAG}_probe.log
setsid nohup env PROBE_WIN=$PW ACK_MODE=$AM ACK_OFFSET=${ACK_OFFSET:-4194304} SNIFF_MS=${SNIFF_MS:-20} \
   PYTHONUNBUFFERED=1 python3 $D2/stall_probe_u7.py $INJECT_AT $INJECT_N $GAP \
   > /tmp/sndwnd_${TAG}_probe.log 2>&1 < /dev/null &
echo "PROBE_PID=$!"
sleep 2
echo "PROBE_ARMED (已给注入器 2 s 绑套接字窗口) $(date +%s.%N)"

echo "--- 主跑 ($MODE) ---"
T0=$(date +%s.%N)
case "$MODE" in
  pa)
    timeout -k 5 $((SECS+30)) $SINK --host $BOARD --port 8080 --rcvbuf $RCVBUF --rcvbuf-after-connect \
      --conns 1 --seconds $SECS --maxbytes $MB --check lane8 \
      --poll-ms $POLL_MS --stall-n $STALL_N > /tmp/sndwnd_${TAG}_sink.txt 2>&1
    echo "### SINK_RC=$?"
    ;;
  active)
    timeout -k 5 $((SECS+30)) $SINK --host $BOARD --port 8080 --rcvbuf $RCVBUF \
      --conns 1 --seconds $SECS --maxbytes $MB --check lane8 \
      --poll-ms $POLL_MS --stall-n $STALL_N > /tmp/sndwnd_${TAG}_sink.txt 2>&1
    echo "### SINK_RC=$?"
    ;;
  c2s)
    timeout -k 5 $((SECS+30)) python3 $D2/persist_client.py --host $BOARD --port 8080 \
      --rcvbuf $RCVBUF --order after --secs $SECS > /tmp/sndwnd_${TAG}_client.txt 2>&1
    echo "### CLIENT_RC=$?"
    ;;
esac
T1=$(date +%s.%N)
echo "### MAIN_DONE T0=$T0 T1=$T1 dur=$(echo "$T1 - $T0" | bc)"

echo "--- 对端内核计数 (跑后) ---"
nstat -az 2>/dev/null | grep -E '^(TcpInSegs|TcpOutSegs|TcpRetransSegs|TcpExtTCPOFOQueue|TcpExtTCPFastRetrans|TcpExtTCPZeroWindowDrop|TcpExtTCPRcvQDrop|TcpExtTCPBacklogDrop|TcpExtTCPWqueueTooBig) ' > /tmp/sndwnd_${TAG}_nstat_post.txt
cat /tmp/sndwnd_${TAG}_nstat_post.txt

echo "--- 收尾: 停快照环 + ss 采样 + 抓包 ---"
kill $SNAPPID $SSPID 2>/dev/null; sleep 0.3
kill $CAPA $CAPB 2>/dev/null
[ -n "$CAPD" ] && kill $CAPD 2>/dev/null
[ -n "${CAPE:-}" ] && kill $CAPE 2>/dev/null
[ "$MODE" = "c2s" ] && kill $CAPC 2>/dev/null
sleep 0.6
pkill -f "tcpdump -i $IF" 2>/dev/null
sleep 0.5
echo "--- 抓包自报 (丢包 = 判据污染的见证) ---"
echo "[capA]"; tail -3 /tmp/sndwnd_${TAG}_capA.err 2>/dev/null
echo "[capB]"; tail -3 /tmp/sndwnd_${TAG}_capB.err 2>/dev/null
[ "$MODE" = "active" ] && { echo "[capD]"; tail -3 /tmp/sndwnd_${TAG}_capD.err 2>/dev/null; echo "[capE]"; tail -3 /tmp/sndwnd_${TAG}_capE.err 2>/dev/null; }
[ "$MODE" = "c2s" ] && { echo "[capC]"; tail -3 /tmp/sndwnd_${TAG}_capC.err 2>/dev/null; }
ls -la /tmp/sndwnd_${TAG}_*.pcap 2>&1

echo "--- 探针日志 (注入的 (ack,win) 原始值 + ack_src) ---"
cat /tmp/sndwnd_${TAG}_probe.log 2>/dev/null

echo "--- sink 摘要 (逐字) ---"
grep -E '^SINK_LIMITS|^SINK_RCVBUF_ORDER|^SINK_CONN|^SINK_SUM|^PIN_' /tmp/sndwnd_${TAG}_sink.txt 2>/dev/null | head -20
[ -f /tmp/sndwnd_${TAG}_client.txt ] && { echo "--- client (不读档) ---"; grep -E '^CLIENT_|^PIN_' /tmp/sndwnd_${TAG}_client.txt | head -20; }

echo "--- 板侧态 (跑后) ---"
echo -n "BID="; $T/reg_rw $D 0x04 w 2>&1 | tail -1
echo -n "SCRATCH_0x08="; $T/reg_rw $D 0x08 w 2>&1 | tail -1
echo -n "CARRIER="; cat /sys/class/net/$IF/carrier
pgrep -a p7b_tcp_sink; pgrep -a tcpdump; pgrep -af 'stall_probe|persist_client'; echo "(空=无残留进程)"
echo "### RUN_END tag=$TAG $(date +%s.%N)"
