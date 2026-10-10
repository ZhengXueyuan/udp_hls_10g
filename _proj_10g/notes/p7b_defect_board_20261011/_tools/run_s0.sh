#!/bin/bash
# run_s0.sh -- P7B-RETXHI-GHOST 板级轮 A (S-0 臂) 的执行件 (对端机, root)
#   轮级背景: 设计件 §6.2 的 S-0 构型要求 "发数据 -> abort(RST) -> 小窗慢读 -> RTO 会话重放".
#   本轮现核发现: **板级没有 host 可达的 abort 通路** (app_ctrl 的寄存器总线在 wrapper 里被钉死:
#   `assign app_reg_addr = 8'h00; app_reg_wr = 1'b0;`) ⇒ 只能执行"可得近邻"构型:
#     小窗慢读 + 连接收尾 (对端 FIN -> 板对该连的全部可达控制帧行为) + 全窗控制帧普查.
#   本脚本做四件互不干扰的事 (各自独立取证):
#     ① 控制帧普查抓包: 只抓 tcp port 8080 的 FIN/RST 包 (全窗, 包数极少 => 零丢包)
#     ② 环形全帧抓包 (板->对端, `-C/-W` 限盘): 内容口径 (逐字节图案复算的原料)
#     ③ sink (现役部署件, 只在后方运行; 本脚本一字不改 /tmp/p7b_biz)
#     ④ 板侧快照环 (p7b_snap.sh snap): W5/W20/W43/W51/W14/W15/W55/W57/W58
#   用法: bash run_s0.sh <TAG> <RCVBUF> <CONNS> <SECS> <MAXBYTES> [PCAP_FULL=0|1]
set -u
TAG=${1:?usage: run_s0.sh TAG RCVBUF CONNS SECS MAXBYTES [PCAP_FULL]}
RCVBUF=${2:?}; CONNS=${3:?}; SECS=${4:?}; MAXBYTES=${5:?}; PCAP_FULL=${6:-1}
IF=enp1s0f1np1
BOARD=192.168.100.2
D=/dev/xdma0_user
T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
S=/tmp/p7b_biz/p7b_snap.sh
KW='5 20 43 51 14 15 55 57 58'
export EXPECT_BID=0x0000001A NW=70

echo "### S0_BEGIN tag=$TAG rcvbuf=$RCVBUF conns=$CONNS secs=$SECS maxbytes=$MAXBYTES pcap_full=$PCAP_FULL $(date +%s.%N)"
echo "### SNAP_MD5 $(md5sum $S | awk '{print $1}')"
echo "### SINK_MD5 $(md5sum /tmp/p7b_biz/p7b_tcp_sink | awk '{print $1}')"
echo "### SNAP_KW $KW"

echo "--- 板侧身份闸 (跑前) ---"
bash $S id; echo "ID_RC=$?"
echo -n "BID="; $T/reg_rw $D 0x04 w 2>&1 | tail -1
echo -n "SCRATCH_0x08="; $T/reg_rw $D 0x08 w 2>&1 | tail -1
echo -n "CARRIER="; cat /sys/class/net/$IF/carrier
echo -n "NETADDR="; ip -4 addr show $IF | grep -o 'inet [0-9./]*'

echo "--- 抓包 ①: 控制帧普查 (FIN/RST, 全窗) ---"
rm -f /tmp/ghost_${TAG}_ctl.pcap /tmp/ghost_${TAG}_ctl.err
setsid nohup tcpdump -i $IF -s 0 -U -w /tmp/ghost_${TAG}_ctl.pcap \
   "tcp port 8080 and (tcp[tcpflags] & (tcp-fin|tcp-rst) != 0)" \
   > /tmp/ghost_${TAG}_ctl.err 2>&1 < /dev/null &
CTLPID=$!
sleep 1
echo "CTL_PID=$CTLPID"

if [ "$PCAP_FULL" = "1" ]; then
  echo "--- 抓包 ②: 环形全帧 (板->对端, 200MB x 6) ---"
  rm -f /tmp/ghost_${TAG}_full*
  setsid nohup tcpdump -i $IF -s 0 -B 65536 -U -C 200 -W 6 -w /tmp/ghost_${TAG}_full.pcap \
     "tcp port 8080 and src host $BOARD" > /tmp/ghost_${TAG}_full.err 2>&1 < /dev/null &
  FULLPID=$!
  echo "FULL_PID=$FULLPID"
fi

echo "--- 板侧快照环 (后台; 每 0.15s 一点) ---"
( while :; do
    echo "SNAP_T $(date +%s.%N)"
    bash $S snap ${TAG} $KW 2>&1
    sleep 0.15
  done ) > /tmp/ghost_${TAG}_snap.log 2>&1 &
SNAPPID=$!
echo "SNAP_PID=$SNAPPID"

echo "--- 对端内核计数 (跑前) ---"
nstat -az 2>/dev/null | grep -E '^(TcpInSegs|TcpOutSegs|TcpRetransSegs|TcpExtTCPOFOQueue|TcpExtTCPFastRetrans|TcpExtTCPACKSkippedSeq) ' > /tmp/ghost_${TAG}_nstat_pre.txt
cat /tmp/ghost_${TAG}_nstat_pre.txt

echo "--- 主跑: sink (现役部署件) ---"
T0=$(date +%s.%N)
timeout -k 5 $((SECS+30)) /tmp/p7b_biz/p7b_tcp_sink --host $BOARD --port 8080 \
  --rcvbuf $RCVBUF --conns $CONNS --seconds $SECS --maxbytes $MAXBYTES --check lane8 \
  > /tmp/ghost_${TAG}_sink.txt 2>&1
RC=$?
T1=$(date +%s.%N)
echo "### SINK_RC=$RC T0=$T0 T1=$T1"

echo "--- 对端内核计数 (跑后) ---"
nstat -az 2>/dev/null | grep -E '^(TcpInSegs|TcpOutSegs|TcpRetransSegs|TcpExtTCPOFOQueue|TcpExtTCPFastRetrans|TcpExtTCPACKSkippedSeq) ' > /tmp/ghost_${TAG}_nstat_post.txt
cat /tmp/ghost_${TAG}_nstat_post.txt

echo "--- 收尾: 停快照环 + 抓包 ---"
kill $SNAPPID 2>/dev/null; sleep 0.3
kill $CTLPID 2>/dev/null; sleep 0.5
[ "$PCAP_FULL" = "1" ] && { kill $FULLPID 2>/dev/null; sleep 1; }
sleep 1
pkill -f "tcpdump -i $IF" 2>/dev/null
sleep 0.5

echo "--- 抓包统计 (由 tcpdump 自报; 丢包 = 判据污染的见证) ---"
echo "[ctl]";  tail -3 /tmp/ghost_${TAG}_ctl.err
if [ "$PCAP_FULL" = "1" ]; then echo "[full]"; tail -3 /tmp/ghost_${TAG}_full.err; fi
ls -la /tmp/ghost_${TAG}_*.pcap* 2>&1

echo "--- sink 摘要 (逐字) ---"
grep -E '^SINK_LIMITS|^SINK_RCVBUF_ORDER|^SINK_CONN|^SINK_SUM' /tmp/ghost_${TAG}_sink.txt | head -20

echo "--- 板侧态 (跑后) ---"
echo -n "BID="; $T/reg_rw $D 0x04 w 2>&1 | tail -1
echo -n "SCRATCH_0x08="; $T/reg_rw $D 0x08 w 2>&1 | tail -1
echo -n "CARRIER="; cat /sys/class/net/$IF/carrier
pgrep -a p7b_tcp_sink; pgrep -a tcpdump; echo "(空=无残留进程)"
echo "### S0_END tag=$TAG $(date +%s.%N)"
