#!/bin/bash
# persist_run.sh -- P7B-PERSIST 板级 A/B 轮: 一跑的执行件 (**在对端机以 root 跑**)
#   用法: bash persist_run.sh <TAG> <MODE> <SECS> [RCVBUF] [INJECT_AT] [INJECT_N]
#   MODE:
#     pa      = P-A 主测法: sink (refresh件) --rcvbuf <RCVBUF> --rcvbuf-after-connect
#               + stall_probe.py 注入 N 个"重复 ACK, win=0"
#     c1      = P-C(c1): sink (refresh件) 默认 before_connect, --rcvbuf 2920 (SYN 就小窗)
#     c2a     = P-C(c2a): 不读客户端, SO_RCVBUF 在 connect **之前**设 (SYN 小窗) 且永不读
#     c2b     = P-C(c2b): 不读客户端, SO_RCVBUF 在 connect **之后**设 (先大窗后塌, LEGACY 序)
#     healthy = J-P5: sink (refresh件) 默认 before_connect + 大 rcvbuf, 无注入
#     teardown= J-P7: 先 pa 式 stall 若干秒 -> SIGKILL sink -> 续抓 TEARDOWN_TAIL 秒
#               -> 再连一次 (重连) SECS2 秒
#   env: EXPECT_BID / NW / STALL_N / POLL_MS / SNAP_MAX / SNAPGAP / TEARDOWN_TAIL / SECS2
#   取数面: capA = 板->对端 小帧(<=100B) 全程; capB = 双向 小帧(<=100B) 全程(-c 限深)
#           snap 环 = p7b_snap.sh snap (KW 字表)
set -u
TAG=${1:?usage: persist_run.sh TAG MODE SECS [RCVBUF] [INJECT_AT] [INJECT_N]}
MODE=${2:?need MODE}; SECS=${3:?need SECS}
RCVBUF=${4:-1460}; INJECT_AT=${5:-3.0}; INJECT_N=${6:-3}
IF=enp1s0f1np1
BOARD=192.168.100.2
D=/dev/xdma0_user
T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
S=/tmp/p7b_biz/p7b_snap.sh
D2=/tmp/p7b_persist
SINK=/tmp/p7b_biz_refresh/p7b_tcp_sink
KW=${KW:-'5 14 15 20 43 51 55 57 58 66 67 68 69'}
STALL_N=${STALL_N:-3}; POLL_MS=${POLL_MS:-5000}
SNAP_MAX=${SNAP_MAX:-2000}; SNAPGAP=${SNAPGAP:-0.1}
TEARDOWN_TAIL=${TEARDOWN_TAIL:-10}; SECS2=${SECS2:-15}
export EXPECT_BID=${EXPECT_BID:-0x0000001D} NW=${NW:-70}

echo "### RUN_BEGIN tag=$TAG mode=$MODE secs=$SECS rcvbuf=$RCVBUF inject_at=$INJECT_AT n=$INJECT_N $(date +%s.%N)"
echo "### KW='$KW' STALL_N=$STALL_N POLL_MS=$POLL_MS SNAP_MAX=$SNAP_MAX SNAPGAP=$SNAPGAP"
echo "### SNAP_MD5 $(md5sum $S | awk '{print $1}')  SINK_MD5 $(md5sum $SINK | awk '{print $1}')  CLIENT_MD5 $(md5sum $D2/persist_client.py 2>/dev/null | awk '{print $1}')  PROBE_MD5 $(md5sum $D2/stall_probe.py 2>/dev/null | awk '{print $1}')"
echo "### EXPECT_BID=$EXPECT_BID NW=$NW"

echo "--- 板侧身份闸 (跑前) ---"
bash $S id; echo "ID_RC=$?"
echo -n "BID="; $T/reg_rw $D 0x04 w 2>&1 | tail -1
echo -n "SCRATCH_0x08="; $T/reg_rw $D 0x08 w 2>&1 | tail -1
echo -n "CARRIER="; cat /sys/class/net/$IF/carrier
echo -n "NETADDR="; ip -4 addr show $IF | grep -o 'inet [0-9./]*'
echo -n "ROUTE="; ip route get $BOARD | head -1

echo "--- 抓包 A: 板->对端 小帧 (<=100B, 全程) ---"
rm -f /tmp/persist_${TAG}_capA.pcap /tmp/persist_${TAG}_capA.err
setsid nohup tcpdump -i $IF -s 0 -U -w /tmp/persist_${TAG}_capA.pcap \
   "tcp port 8080 and src host $BOARD and less 100" \
   > /tmp/persist_${TAG}_capA.err 2>&1 < /dev/null &
CAPA=$!
echo "--- 抓包 B: 双向 小帧 (<=100B, -c 400000 限深) ---"
rm -f /tmp/persist_${TAG}_capB.pcap /tmp/persist_${TAG}_capB.err
setsid nohup tcpdump -i $IF -s 0 -U -c 400000 -w /tmp/persist_${TAG}_capB.pcap \
   "tcp port 8080 and less 100" \
   > /tmp/persist_${TAG}_capB.err 2>&1 < /dev/null &
CAPB=$!
echo "CAPA=$CAPA CAPB=$CAPB"
echo "--- 抓包 C: 板->对端 大帧 (>100B, -c 400 限深) = 初突发/恢复段的数据帧序 (算 snd_nxt 用) ---"
rm -f /tmp/persist_${TAG}_capC.pcap /tmp/persist_${TAG}_capC.err
setsid nohup tcpdump -i $IF -s 0 -U -c 400 -w /tmp/persist_${TAG}_capC.pcap \
   "tcp port 8080 and src host $BOARD and greater 100" \
   > /tmp/persist_${TAG}_capC.err 2>&1 < /dev/null &
CAPC=$!
echo "CAPC=$CAPC"
sleep 1

echo "--- 板侧快照环 (后台; ${SNAPGAP}s/点; 上限 $SNAP_MAX 点) ---"
( n=0; while [ $n -lt $SNAP_MAX ]; do
    echo "SNAP_T $(date +%s.%N)"
    bash $S snap "${TAG}_N${n}" $KW 2>&1
    n=$((n+1))
    sleep $SNAPGAP
  done ) > /tmp/persist_${TAG}_snap.log 2>&1 &
SNAPPID=$!
echo "SNAP_PID=$SNAPPID"

echo "--- 侧信道: ss 采样 (0.5s/点; 本连接的 rcv_space/Recv-Q/rwnd_limited/bytes_received) ---"
( while :; do
    echo "SS_T $(date +%s.%N)"
    ss -tinm state established '( dport = :8080 )' 2>&1
    sleep 0.5
  done ) > /tmp/persist_${TAG}_ss.log 2>&1 &
SSPID=$!
echo "SS_PID=$SSPID"

echo "--- 对端内核计数 (跑前) ---"
nstat -az 2>/dev/null | grep -E '^(TcpInSegs|TcpOutSegs|TcpRetransSegs|TcpExtTCPOFOQueue|TcpExtTCPFastRetrans|TcpExtTCPZeroWindowDrop|TcpExtTCPRcvQDrop|TcpExtTCPBacklogDrop) ' > /tmp/persist_${TAG}_nstat_pre.txt
cat /tmp/persist_${TAG}_nstat_pre.txt

if [ "$MODE" = "pa" ] || [ "$MODE" = "teardown" ]; then
  echo "--- 注入器 (stall_probe; PROBE_WIN=0; 等 SYN 后 ${INJECT_AT}s 注入 ${INJECT_N} 个) ---"
  rm -f /tmp/persist_${TAG}_probe.log
  setsid nohup env PROBE_WIN=0 PYTHONUNBUFFERED=1 python3 $D2/stall_probe.py $INJECT_AT $INJECT_N 0.15 \
     > /tmp/persist_${TAG}_probe.log 2>&1 < /dev/null &
  echo "PROBE_PID=$!"
  # ⛔ N1 教训: python 起 + 绑 AF_PACKET 要 ~百 ms, 与 sink 同拍起会**错过 SYN** ⇒ 注入器静默不干活。
  #    这里等 2 s (注入器在等 SYN, 空等无害)。
  sleep 2
  echo "PROBE_ARMED (已给注入器 2 s 绑套接字窗口) $(date +%s.%N)"
fi

echo "--- 主跑 ($MODE) ---"
T0=$(date +%s.%N)
case "$MODE" in
  pa)
    timeout -k 5 $((SECS+30)) $SINK --host $BOARD --port 8080 --rcvbuf $RCVBUF --rcvbuf-after-connect \
      --conns 1 --seconds $SECS --maxbytes 400000000 --check lane8 \
      --poll-ms $POLL_MS --stall-n $STALL_N > /tmp/persist_${TAG}_sink.txt 2>&1
    echo "### SINK_RC=$?"
    ;;
  c1)
    timeout -k 5 $((SECS+30)) $SINK --host $BOARD --port 8080 --rcvbuf $RCVBUF \
      --conns 1 --seconds $SECS --maxbytes 400000000 --check lane8 \
      --poll-ms $POLL_MS --stall-n $STALL_N > /tmp/persist_${TAG}_sink.txt 2>&1
    echo "### SINK_RC=$?"
    ;;
  healthy)
    timeout -k 5 $((SECS+30)) $SINK --host $BOARD --port 8080 --rcvbuf $RCVBUF \
      --conns 1 --seconds $SECS --maxbytes 4000000000 --check lane8 \
      --poll-ms $POLL_MS --stall-n $STALL_N > /tmp/persist_${TAG}_sink.txt 2>&1
    echo "### SINK_RC=$?"
    ;;
  c2a|c2b)
    ORD=before; [ "$MODE" = "c2b" ] && ORD=after
    timeout -k 5 $((SECS+30)) python3 $D2/persist_client.py --host $BOARD --port 8080 \
      --rcvbuf $RCVBUF --order $ORD --secs $SECS > /tmp/persist_${TAG}_client.txt 2>&1
    echo "### CLIENT_RC=$?"
    ;;
  teardown)
    timeout -k 5 $((SECS+30)) $SINK --host $BOARD --port 8080 --rcvbuf $RCVBUF --rcvbuf-after-connect \
      --conns 1 --seconds $SECS --maxbytes 400000000 --check lane8 \
      --poll-ms $POLL_MS --stall-n $STALL_N > /tmp/persist_${TAG}_sink.txt 2>&1 &
    SP=$!
    sleep $SECS
    echo "### KILL sink pid=$SP at $(date +%s.%N) (拆除; SIGKILL => 无 FIN, 内核有未读数据 => RST)"
    kill -9 $SP 2>/dev/null; pkill -9 -f 'p7b_tcp_sink.*--rcvbuf-after-connect' 2>/dev/null
    sleep $TEARDOWN_TAIL
    echo "### TEARDOWN_TAIL 结束, 进入重连段 $(date +%s.%N)"
    timeout -k 5 $((SECS2+30)) $SINK --host $BOARD --port 8080 --rcvbuf $RCVBUF --rcvbuf-after-connect \
      --conns 1 --seconds $SECS2 --maxbytes 400000000 --check lane8 \
      --poll-ms $POLL_MS --stall-n $STALL_N > /tmp/persist_${TAG}_sink2.txt 2>&1
    echo "### SINK2_RC=$?"
    ;;
  *) echo "FATAL: 未知 MODE=$MODE"; exit 3 ;;
esac
T1=$(date +%s.%N)
echo "### MAIN_DONE T0=$T0 T1=$T1 dur=$(echo "$T1 - $T0" | bc)"

echo "--- 对端内核计数 (跑后) ---"
nstat -az 2>/dev/null | grep -E '^(TcpInSegs|TcpOutSegs|TcpRetransSegs|TcpExtTCPOFOQueue|TcpExtTCPFastRetrans|TcpExtTCPZeroWindowDrop|TcpExtTCPRcvQDrop|TcpExtTCPBacklogDrop) ' > /tmp/persist_${TAG}_nstat_post.txt
cat /tmp/persist_${TAG}_nstat_post.txt

echo "--- 收尾: 停快照环 + ss 采样 + 抓包 ---"
kill $SNAPPID $SSPID 2>/dev/null; sleep 0.3
kill $CAPA $CAPB $CAPC 2>/dev/null; sleep 0.6
pkill -f "tcpdump -i $IF" 2>/dev/null
sleep 0.5
echo "--- 抓包自报 (丢包 = 判据污染的见证) ---"
echo "[capA]"; tail -3 /tmp/persist_${TAG}_capA.err
echo "[capB]"; tail -3 /tmp/persist_${TAG}_capB.err
echo "[capC]"; tail -3 /tmp/persist_${TAG}_capC.err
ls -la /tmp/persist_${TAG}_*.pcap 2>&1

echo "--- 探针日志 (注入的 (ack,win) 原始值) ---"
cat /tmp/persist_${TAG}_probe.log 2>/dev/null

echo "--- sink 摘要 (逐字) ---"
grep -E '^SINK_LIMITS|^SINK_RCVBUF_ORDER|^SINK_CONN|^SINK_SUM|^PIN_' /tmp/persist_${TAG}_sink.txt 2>/dev/null | head -20
[ -f /tmp/persist_${TAG}_sink2.txt ] && { echo "--- sink2 (重连段) ---"; grep -E '^SINK_LIMITS|^SINK_RCVBUF_ORDER|^SINK_CONN|^SINK_SUM' /tmp/persist_${TAG}_sink2.txt | head -10; }
[ -f /tmp/persist_${TAG}_client.txt ] && { echo "--- client (不读档) ---"; grep -E '^CLIENT_|^PIN_' /tmp/persist_${TAG}_client.txt | head -20; }

echo "--- 板侧态 (跑后) ---"
echo -n "BID="; $T/reg_rw $D 0x04 w 2>&1 | tail -1
echo -n "SCRATCH_0x08="; $T/reg_rw $D 0x08 w 2>&1 | tail -1
echo -n "CARRIER="; cat /sys/class/net/$IF/carrier
pgrep -a p7b_tcp_sink; pgrep -a tcpdump; echo "(空=无残留进程)"
echo "### RUN_END tag=$TAG $(date +%s.%N)"
