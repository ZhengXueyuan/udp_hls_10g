#!/bin/bash
# stc_dl.sh -- P7b **Stage C 板级轮**: 下行 (板 -> 对端, port 8080) TCP 速率测量台架
#   用法(对端机): CONNS=300 SECS=30 TAG=STC_DL1 bash /tmp/p7b_biz/stc_dl.sh
#   env: CONNS(默认300) SECS(30, sink 墙钟上限) TAG RCVBUF(8388608) PCAP_ON(**默认 0 = 不抓**)
#        SINK(默认 ./p7b_tcp_sink) SINK_EXTRA(如 --nocheck)
#   ⚠️ 下行**没有 pace 旋钮** (板是发送方) ⇒ 本台架记录 STC_META_PACE=N/A 并记 rcvbuf/conns
#      (台架帽子的对照臂 = SINK=p7b_tcp_sink_rate SINK_EXTRA=--nocheck, 见 P7B_BOARD_STAGEC)
#   记什么: 板侧两代全窗快照 + 紧贴传输窗的 t0/t1(#KW) + 对端 NIC 前后计数 + ss 采样 +
#           sink 逐连接读数 + sink 进程 CPU 见证 (/proc/<pid>/stat utime/stime 采样) + **可选** pcap
#   ⚠️ 回卷规则 (下游解析器必须遵守): 板侧所有计数器 32 位; ΔW 一律 mod 2^32 且记 raw 与 k;
#      W51/W15 在 9.4 Gbps 下 3.65 s 回卷一次; 时基 W5 回绕 27.487 s。
#
# ⭐⭐ 2026-10-09 (用户要求: 收发数据不许落盘、防止 IO 瓶颈) 两处改动:
#   ① **默认不抓 pcap** (`PCAP_ON` 默认 1 → **0**)。抓包 = `tcpdump -w` ⇒ 每包都过磁盘,
#      是台架上**唯一**的落盘路径 (也是 ~GB 级写放大)。需要取证时才显式 `PCAP_ON=1`:
#      那一跑会打 **`PCAP_ACTIVE=1 IO_AFFECTING=1`** 醒目行 ⇒ **该跑读数含 IO, 不许与
#      `PCAP_ON=0` 的读数直接混合比较** (报告里必须标注)。
#   ② **不抓包时的替代几何口径** (原来只有 pcap 能判帧几何): 收尾打 `GEOM_NOPCAP_*` 三行 ——
#      ① 对端 NIC 硬件计数 `Δport_rx_good_bytes/Δport_rx_packets` (J0 口径 = 1518.0009)
#      ② 板侧 `ΔW43/ΔW20` (拍/帧, J0 口径 = 192.999989) + `ΔW20/(ΔW5/156.25e6)` = fps
#      ⚠️ 两者都是**原始读数现算**且 raw A/B 一并落盘 (回卷规则照旧)。
#   ⛔ 2026-10-10 口径订正 (注释; 行为零改动): W43 = mac_tx_10g.stat_tx_words = **每拍无条件 +1 的
#      tx 域拍钟** (mac_tx_10g.v:330, 在 case(state) 之外) ⇒ `ΔW43/ΔW20 ≡ 156.25e6/fps` (恒等式)
#      ⇒ 本行只能当**帧周期/帧率的换算**, **不是**"线占空/线忙度"测量 (板侧没有线占空计数器);
#      本构型下它易被读成 193 几何 (错 ~5.5×) 的老警告仍然成立 (见 p7b_bench/ACCEPT_FIRST_RUN.md §81)。
set -u
CONNS=${CONNS:-300}; SECS=${SECS:-30}; TAG=${TAG:-STC_DL}; RCVBUF=${RCVBUF:-8388608}
PCAP_ON=${PCAP_ON:-0}; SINK=${SINK:-./p7b_tcp_sink}; SINK_EXTRA=${SINK_EXTRA:-}
# 身份: 默认 Stage C = 0xA; **A/B 负对照臂** (Build 2 = BID 9) 用 `BID_EXPECT=0x00000009` 覆盖
#   (同时 export EXPECT_BID 给 p7b_snap.sh 的身份闸 —— 否则取数器会按自己的默认 0xA 拒绝)
BID_EXPECT=${BID_EXPECT:-0x0000000A}
export EXPECT_BID=$BID_EXPECT
S=${P7B_SNAP:-/tmp/p7b_biz/p7b_snap.sh}   # ⭐ 2026-10-09: 可覆盖 (干跑/自检用桩件; 默认路径不变)
T=${P7B_TOOLS:-/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools}
D=/dev/xdma0_user
IF=enp1s0f1np1
PCAP=${PCAP:-/tmp/${TAG}.pcap}
# KW = 传输窗 t0/t1 读的字 (W5=时基 / 51,52=app 发字节帧 / 15,14=TCP fast path / 20,43=MAC /
#      55,57,58=重传 / 54=失配 / 61,62=wu 机制 / 56,59,60=ovf 守卫 / 0,22=收帧)
KW="5 51 52 15 14 20 43 55 57 58 54 61 62 56 59 60 0 22"
cd /tmp/p7b_biz || exit 9
brd(){ [ -x "$T/reg_rw" ] && $T/reg_rw $D "$1" w 2>/dev/null | tail -1 | sed 's/.*: *//'; }
# ⭐ 2026-10-09: NIC 采样**落盘**(计数器日志, 不是载荷) 并带相位标签 —— GEOM_NOPCAP 要拿它做 Δ
NIC(){ local tag="${1:-x}";
       { ethtool -S $IF 2>/dev/null | grep -E '^ +(port_rx_good_bytes|port_rx_packets|port_rx_bad|rx_eth_crc_err|port_rx_nodesc_drops|port_tx_packets|port_tx_bytes):';
         nstat -az 2>/dev/null | grep -E '^(TcpInSegs|TcpOutSegs|TcpRetransSegs|TcpExtTCPOFOQueue|TcpExtTCPRcvCollapsed|TcpExtTCPACKSkippedSeq|TcpExtTCPACKSkippedPAWS|TcpExtTCPLossUndo|TcpExtTCPSackRecv|TcpExtTCPFastRetrans) '; } | tee /tmp/nic_${TAG}_${tag}.txt; }

# ---- ⭐⭐ 2026-10-09: **不抓包**时的帧几何口径 (替代 pcap 逐帧; 文件头 ②) ------------------
#   ① 对端 NIC 硬件计数 Δport_rx_good_bytes/Δport_rx_packets  (J0 口径 = 1518.0009)
#   ② 板侧 ΔW43/ΔW20 (拍/帧; J0 口径 = 192.999989) + ΔW20/(ΔW5/156.25e6) = fps
#   ⚠️ 两者都用**原始读数现算**, raw A/B 一并打印 (回卷规则: 32 位模差 + wrap 位)
nicv(){ awk -v k="$2:" '$1==k {print $2; exit}' "$1"; }                 # ethtool 行取值
snapw(){ awk -v w="W$2" '$1==w {print $NF; exit}' "$1"; }               # p7b_snap 行取字 (0x..)
h2d(){ [ -n "$1" ] && echo $(( $1 )) || echo ""; }                      # bash 自带 0x 前缀算术
geom_nopcap(){
  local A=/tmp/nic_${TAG}_pre.txt B=/tmp/nic_${TAG}_post.txt
  local SA=/tmp/snap_${TAG}_t0.txt SB=/tmp/snap_${TAG}_t1.txt
  echo "### GEOM_NOPCAP (PCAP_ON=$PCAP_ON; 不抓包也能判帧几何; raw 与 wrap 位一并落盘)"
  if [ -f "$A" ] && [ -f "$B" ]; then
    awk -v ab="$(nicv "$A" port_rx_good_bytes)" -v bb="$(nicv "$B" port_rx_good_bytes)" \
        -v ap="$(nicv "$A" port_rx_packets)"    -v bp="$(nicv "$B" port_rx_packets)" 'BEGIN{
      if (ab==""||bb==""||ap==""||bp=="") { print "GEOM_NOPCAP_NIC_rx NA (空读: ethtool 缺字段?)"; exit }
      db=bb-ab; wb=0; if (db<0) { db+=4294967296; wb=1 }
      dp=bp-ap; wp=0; if (dp<0) { dp+=4294967296; wp=1 }
      printf "GEOM_NOPCAP_NIC_rx A_bytes=%s B_bytes=%s d_bytes=%d wrap=%d | A_pkts=%s B_pkts=%s d_pkts=%d wrap=%d | bytes_per_pkt=%s\n",
             ab, bb, db, wb, ap, bp, dp, wp, (dp>0 ? sprintf("%.6f", db/dp) : "NA") }'
  else
    echo "GEOM_NOPCAP_NIC_rx NA (缺 $A 或 $B)"
  fi
  if [ -f "$SA" ] && [ -f "$SB" ]; then
    awk -v a20="$(h2d "$(snapw "$SA" 20)")" -v b20="$(h2d "$(snapw "$SB" 20)")" \
        -v a43="$(h2d "$(snapw "$SA" 43)")" -v b43="$(h2d "$(snapw "$SB" 43)")" \
        -v a5="$(h2d "$(snapw "$SA" 5)")"   -v b5="$(h2d "$(snapw "$SB" 5)")" 'BEGIN{
      if (a20==""||b20==""||a43==""||b43==""||a5==""||b5=="") { print "GEOM_NOPCAP_BOARD NA (t0/t1 快照缺字)"; exit }
      d20=b20-a20; w1=0; if (d20<0) { d20+=4294967296; w1=1 }
      d43=b43-a43; w2=0; if (d43<0) { d43+=4294967296; w2=1 }
      d5=b5-a5;    w3=0; if (d5<0)  { d5+=4294967296;  w3=1 }
      printf "GEOM_NOPCAP_BOARD A_W20=%s B_W20=%s dW20=%d wrap=%d | A_W43=%s B_W43=%s dW43=%d wrap=%d | A_W5=%s B_W5=%s dW5=%d wrap=%d | cpf=%s | fps=%s\n",
             a20,b20,d20,w1, a43,b43,d43,w2, a5,b5,d5,w3,
             (d20>0 ? sprintf("%.6f", d43/d20) : "NA"),
             (d5>0 ? sprintf("%.3f", d20*156250000.0/d5) : "NA") }'
  else
    echo "GEOM_NOPCAP_BOARD NA (缺 $SA 或 $SB)"
  fi
}

echo "### J6META_BEGIN $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "STC_META_TAG=$TAG STC_META_CONNS=$CONNS STC_META_SECS=$SECS STC_META_RCVBUF=$RCVBUF"
echo "STC_META_SINK=$SINK STC_META_SINK_EXTRA='$SINK_EXTRA' STC_META_PCAP_ON=$PCAP_ON STC_META_BID_EXPECT=$BID_EXPECT"
echo "STC_META_PCAP_ACTIVE=$([ "$PCAP_ON" = "1" ] && echo 1 || echo 0) STC_META_IO_AFFECTING=$([ "$PCAP_ON" = "1" ] && echo 1 || echo 0) STC_META_PCAP_TARGET=$PCAP STC_META_SNAP=$S"
echo "STC_META_GEOM_FALLBACK=GEOM_NOPCAP_* (NIC Δport_rx_good_bytes/Δport_rx_packets + 板侧 ΔW43/ΔW20/fps; 见文件头 ②)"
echo "STC_META_SCRIPT=$(readlink -f "$0") STC_META_SCRIPT_MD5=$(md5sum "$0" 2>/dev/null | cut -d' ' -f1)"
echo "STC_META_SINK_MD5=$(md5sum "$SINK" 2>/dev/null | cut -d' ' -f1)"
echo "STC_META_PACE=N/A(board_is_sender) STC_META_BOARD_BID_PRE=$(brd 0x04)"
echo "STC_META_WRAP_RULE=all_board_cnt_32bit; delta_mod_2^32_with_k_recorded; W51_wrap@9.4Gbps=3.65s; W5_limit_27.487s"

echo "### PHASE route_carrier $(date +%s.%N)"
ip route get 192.168.100.2 | head -2
echo "CARRIER=$(cat /sys/class/net/$IF/carrier 2>&1)"

echo "### PHASE geom_gate $(date +%s.%N)"
BID0=$(brd 0x04)
# ⛔ 2026-10-07 Stage C: reg_rw 打小写 (0x0000000a) ⇒ 比较必须大小写无关 (否则 BID>=0xA 世代必假红)
norm(){ printf '%s' "$1" | tr 'A-F' 'a-f'; }
if [ "$(norm "$BID0")" != "$(norm "$BID_EXPECT")" ]; then
  echo "STC_GEOM_FAIL 板侧 BID=$BID0 != $BID_EXPECT (期望位流) ⇒ 拒绝继续"; exit 3
fi
bash "$S" id || { echo "STC_GEOM_FAIL 取数器身份闸未过 (MAGIC/BID/未实现地址) ⇒ 拒绝继续"; exit 3; }
echo "STC_GEOM_OK NW=63 BID=$BID0"

echo "### PHASE nic_pre $(date +%s.%N)"; NIC pre
echo "### PHASE pre_snapshot $(date +%s.%N)"
bash "$S" full "${TAG}_pre" || { echo "STC_ABORT pre_snapshot"; exit 1; }

# ⭐ 2026-10-09: 默认 **不抓包** (落盘 = IO 瓶颈); 显式 PCAP_ON=1 才抓, 且打醒目 IO 标记
if [ "$PCAP_ON" = "1" ]; then
  echo "PCAP_ACTIVE=1 IO_AFFECTING=1 target=$PCAP (⚠️ 本跑读数含磁盘 IO: tcpdump -w 逐包落盘 ⇒ 不许与 PCAP_ON=0 的读数混比)"
  rm -f "$PCAP"
  ( timeout $((SECS+12)) tcpdump -i $IF -s 96 -w "$PCAP" "tcp and host 192.168.100.2" >/tmp/tcpdump_${TAG}.log 2>&1 & echo $! >/tmp/tcpdump_${TAG}.pid )
else
  echo "PCAP_ACTIVE=0 IO_AFFECTING=0 (默认: 不抓包, 不写盘; 取证需显式 PCAP_ON=1)"
  [ -e "$PCAP" ] && echo "PCAP_NOTE 路径上已存在旧件 $PCAP —— 不是本跑产物, 不计入本跑"
fi
# ss 采样 (后台; 无 state 过滤 —— 板侧 9ms 发 FIN, established 过滤结构性取不到样本)
( for i in $(seq 1 $((SECS*2))); do
    echo "SS_T $(date +%s.%N) $(ss -tinma '( dport = :8080 or sport = :8080 )' 2>/dev/null | tr '\n' '|')"
    sleep 0.5
  done ) > /tmp/ss_${TAG}.log 2>&1 &
SSPID=$!
sleep 1

echo "### PHASE t0_snapshot $(date +%s.%N)"
# t0/t1 输出**同时落盘** (GEOM_NOPCAP 要拿它算板侧 ΔW43/ΔW20; PIPESTATUS 保住 abort 守卫)
bash "$S" snap "${TAG}_t0" $KW | tee /tmp/snap_${TAG}_t0.txt; RC=${PIPESTATUS[0]}
[ "$RC" -eq 0 ] || { echo "STC_ABORT t0_snapshot (snap rc=$RC)"; exit 1; }

echo "### PHASE sink_start $(date +%s.%N)"
# ⛔ Stage C: sink 必须**有超时护栏** —— 2026-10-07 实测 conn#279 收满 1MB 后板侧不发 FIN
#    ⇒ 无护栏时 sink 永远阻塞在 recv (第一跑就踩到, ssh 通道超时、输出丢失)。
setsid timeout -k 2 $((SECS+45)) "$SINK" --host 192.168.100.2 --port 8080 --conns "$CONNS" --seconds "$SECS" --rcvbuf "$RCVBUF" $SINK_EXTRA > /tmp/sink_${TAG}.txt 2>&1 &
SPID=$!
# CPU 见证: 每 0.25 s 采 **系统级** /proc/stat 聚合行 + top 进程 (sink 阻塞在 recv 时它的
#   utime/stime 反而低 —— 真正的成本在软中断/内核, 只看进程会漏掉)
( while kill -0 $SPID 2>/dev/null; do
    echo "SYS_T $(date +%s.%N) $(grep '^cpu ' /proc/stat)"
    echo "PS_T  $(date +%s.%N) $(ps -eo pcpu,comm --sort=-pcpu 2>/dev/null | head -7 | tail -6 | tr '\n' '|')"
    sleep 0.25
  done ) > /tmp/cpu_${TAG}.log 2>&1 &
CPUPID=$!
wait $SPID; SINK_RC=$?
kill $CPUPID 2>/dev/null
kill $SSPID 2>/dev/null
echo "SINK_RC=$SINK_RC $(date +%s.%N)"

echo "### PHASE t1_snapshot $(date +%s.%N)"
bash "$S" snap "${TAG}_t1" $KW | tee /tmp/snap_${TAG}_t1.txt; RC=${PIPESTATUS[0]}
[ "$RC" -eq 0 ] || { echo "STC_ABORT t1_snapshot (snap rc=$RC)"; exit 1; }
[ "$PCAP_ON" = "1" ] && kill "$(cat /tmp/tcpdump_${TAG}.pid 2>/dev/null)" 2>/dev/null   # 不抓时别去 kill 别人的 pid
sleep 1

echo "### PHASE post_snapshot $(date +%s.%N)"
bash "$S" full "${TAG}_post" || { echo "STC_ABORT post_snapshot"; exit 1; }

echo "### PHASE nic_post $(date +%s.%N)"; NIC post
echo "### PHASE geom_nopcap $(date +%s.%N)"; geom_nopcap

echo "### PHASE idle_snap $(date +%s.%N)"
sleep 2
bash "$S" snap "${TAG}_idle" $KW

echo "### SINK tail:"; tail -6 /tmp/sink_${TAG}.txt 2>/dev/null
echo "### SINK_SUM:"; grep SINK_SUM /tmp/sink_${TAG}.txt 2>/dev/null
echo "### SINK head:"; head -3 /tmp/sink_${TAG}.txt 2>/dev/null
echo "### CPU samples (last 24):"; tail -24 /tmp/cpu_${TAG}.log 2>/dev/null
echo "### SS samples (last 6):"; tail -6 /tmp/ss_${TAG}.log 2>/dev/null | cut -c1-260
if [ "$PCAP_ON" = "1" ]; then echo "### PCAP: $(ls -la "$PCAP" 2>/dev/null)"; tail -3 /tmp/tcpdump_${TAG}.log 2>/dev/null; fi
echo "STC_META_BOARD_BID_END=$(brd 0x04)"
echo "STC_DL_DONE $(date +%s.%N)"
