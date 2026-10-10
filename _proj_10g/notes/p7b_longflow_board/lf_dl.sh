#!/bin/bash
# lf_dl.sh -- P7b-LONGFLOW 长流下行 (板 -> 对端, port 8080) 速率台架
#   ⭐ 与 stc_dl.sh 的**唯一结构差别** = 内窗系列:
#      sink 在**后台**跑, 前台**连续** snap (12 字/次, 实测 ~51 ms) 直到 sink 退出 + 2 次
#      ⇒ 得到流内多个**各自自证 (gen 恰好 +1)** 的瞬间点 ⇒ 主判据取"两点全在流内"的点对
#      (stc_dl.sh 的 t0/t1 是**包围窗**: t0 早于流、t1 晚于收尾, 227 ms 流会被 ~80-90 ms 脚本
#       开销稀释 ⇒ 按全局 #43/#48 的口径, 那种窗**不许**当速率判据)。
#   ⚠️ 每个点都是**一次触发锁存的同一代**(12 个字同拍), 故点内跨字一致; 点间是差分 (mod 2^32)。
#
#   用法(对端机): TAG=LF1 SINK_EXTRA='--check lane8 --maxbytes 269484031' bash /tmp/p7b_biz/lf_dl.sh
#   env: CONNS(1) SECS(30, sink 墙钟上限) TAG RCVBUF(8388608) PCAP_ON(默认 0)
#        SINK(默认 ./p7b_tcp_sink) SINK_EXTRA(如 --check lane8 --maxbytes N)
#        ⚠️ 2026-10-10 订正(注释): `--check lane8` 是**两个参数**; 写成一个词 `--check=lane8`
#           时 sink 报 `unknown arg` 并 **RC=2 硬失败**(不静默回落) —— 旧注释写成一个词, 是文档缺陷。
#        BID_EXPECT(默认 0x00000015 = S3/长流档; 同时 export 给 p7b_snap.sh 的身份闸)
#        MAXSNAP(默认 40) SNAPGAP(默认 0.02 s)
#   ⚠️ 回卷规则 (下游解析器必须遵守): 板侧计数器全 32 位; 任何 ΔW 一律 mod 2^32 且记 raw 与 k;
#      W51/W15 在 9.4 Gbps 下 3.63 s 回卷一次 (本档单会话 256 MiB < 2^32 ⇒ 结构性不回卷);
#      时基 W5/W43 回绕 27.487 s (> 全场时长)。
#   ⛔ 2026-10-10 口径订正 (注释; 行为零改动): W43 = mac_tx_10g.stat_tx_words = **每拍无条件 +1 的
#      tx 域拍钟** (mac_tx_10g.v:330, 在 case(state) 之外) ⇒ 它**只能当时基**(本文件就是这么用的),
#      **不许**把 ΔW43/ΔW20 的倒数式 (193/P) 当"线占空测量" —— P ≡ 156.25e6/fps 是恒等式,
#      板侧没有线占空计数器。口径全文 = P7B_LONGSEND_ACCEPT.md §4-① / P7B_RESIDUAL_ANALYSIS.md §6。
set -u
CONNS=${CONNS:-1}; SECS=${SECS:-30}; TAG=${TAG:-LF1}; RCVBUF=${RCVBUF:-8388608}
PCAP_ON=${PCAP_ON:-0}
SINK=${SINK:-./p7b_tcp_sink}; SINK_EXTRA=${SINK_EXTRA:-}
BID_EXPECT=${BID_EXPECT:-0x00000015}
export EXPECT_BID=$BID_EXPECT
S=${P7B_SNAP:-/tmp/p7b_biz/p7b_snap.sh}
T=${P7B_TOOLS:-/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools}
D=/dev/xdma0_user
IF=enp1s0f1np1
PCAP=${PCAP:-/tmp/${TAG}.pcap}
MAXSNAP=${MAXSNAP:-40}; SNAPGAP=${SNAPGAP:-0.02}
# 内窗系列的 12 个字 (5=时基 / 51,52=app 下行字节帧 / 20,43=MAC 帧与自由拍 / 15,14=TCP fast path /
#                55,57,58=重传 / 61,62=wu 机制)
KW=${KW:-"5 51 52 20 43 15 14 55 57 58 61 62"}
# ⚠️ LF7 实测: 流**快**时 (9.31 Gbps / 230 ms) 快照**本身变慢** (12 字 ~288 ms > 整个流) ⇒ 系列
#    结构性落在流外 (三个点全是终值)。⇒ 快流必须用**短字表** (`KW='5 20 43 51 15'` ~5 字)。
cd /tmp/p7b_biz || exit 9
brd(){ [ -x "$T/reg_rw" ] && $T/reg_rw $D "$1" w 2>/dev/null | tail -1 | sed 's/.*: *//'; }
NIC(){ local tag="${1:-x}";
       { ethtool -S $IF 2>/dev/null | grep -E '^ +(port_rx_good_bytes|port_rx_packets|port_rx_bad|rx_eth_crc_err|port_rx_nodesc_drops|port_tx_packets|port_tx_bytes):';
         nstat -az 2>/dev/null | grep -E '^(TcpInSegs|TcpOutSegs|TcpRetransSegs|TcpExtTCPOFOQueue|TcpExtTCPRcvCollapsed|TcpExtTCPACKSkippedSeq|TcpExtTCPLossUndo|TcpExtTCPSackRecv|TcpExtTCPFastRetrans) '; } | tee /tmp/nic_${TAG}_${tag}.txt; }
nicv(){ awk -v k="$2:" '$1==k {print $2; exit}' "$1"; }
snapw(){ awk -v w="W$2" '$1==w {print $NF; exit}' "$1"; }
h2d(){ [ -n "$1" ] && echo $(( $1 )) || echo ""; }
geom_nopcap(){
  local A=/tmp/nic_${TAG}_pre.txt B=/tmp/nic_${TAG}_post.txt
  [ -f /tmp/nic_${TAG}_pre2.txt ] && A=/tmp/nic_${TAG}_pre2.txt    # ⭐ 刷新后的读优先 (sfc 计数周期刷新)
  [ -f /tmp/nic_${TAG}_post2.txt ] && B=/tmp/nic_${TAG}_post2.txt
  echo "### GEOM_NOPCAP (PCAP_ON=$PCAP_ON; raw 与 wrap 位一并落盘)"
  if [ -f "$A" ] && [ -f "$B" ]; then
    awk -v ab="$(nicv "$A" port_rx_good_bytes)" -v bb="$(nicv "$B" port_rx_good_bytes)" \
        -v ap="$(nicv "$A" port_rx_packets)"    -v bp="$(nicv "$B" port_rx_packets)" 'BEGIN{
      if (ab==""||bb==""||ap==""||bp=="") { print "GEOM_NOPCAP_NIC_rx NA (空读)"; exit }
      db=bb-ab; wb=0; if (db<0) { db+=4294967296; wb=1 }
      dp=bp-ap; wp=0; if (dp<0) { dp+=4294967296; wp=1 }
      printf "GEOM_NOPCAP_NIC_rx A_bytes=%s B_bytes=%s d_bytes=%d wrap=%d | A_pkts=%s B_pkts=%s d_pkts=%d wrap=%d | bytes_per_pkt=%s\n",
             ab, bb, db, wb, ap, bp, dp, wp, (dp>0 ? sprintf("%.6f", db/dp) : "NA") }'
  else
    echo "GEOM_NOPCAP_NIC_rx NA (缺 $A 或 $B)"
  fi
}

echo "### J6META_BEGIN $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "LF_META_TAG=$TAG LF_META_CONNS=$CONNS LF_META_SECS=$SECS LF_META_RCVBUF=$RCVBUF"
echo "LF_META_SINK=$SINK LF_META_SINK_EXTRA='$SINK_EXTRA' LF_META_PCAP_ON=$PCAP_ON LF_META_BID_EXPECT=$BID_EXPECT"
echo "PCAP_ACTIVE=$([ "$PCAP_ON" = "1" ] && echo 1 || echo 0) IO_AFFECTING=$([ "$PCAP_ON" = "1" ] && echo 1 || echo 0)"
echo "LF_META_SCRIPT=$(readlink -f "$0") LF_META_SCRIPT_MD5=$(md5sum "$0" 2>/dev/null | cut -d' ' -f1)"
echo "LF_META_SINK_MD5=$(md5sum "$SINK" 2>/dev/null | cut -d' ' -f1)"
echo "LF_META_SNAP_MD5=$(md5sum "$S" 2>/dev/null | cut -d' ' -f1)"
echo "LF_META_BIT_SHA=${BIT_SHA:-n/a}"
echo "LF_META_BOARD_BID_PRE=$(brd 0x04)"
echo "LF_META_WRAP_RULE=all_board_cnt_32bit; delta_mod_2^32_with_raw_recorded; W51_limit_3.63s(@9.4Gbps); W5_limit_27.487s"
echo "LF_META_INNER_SERIES=$KW (12 字/点, 每点=一次锁存触发+gen 自证)"

echo "### PHASE route_carrier $(date +%s.%N)"
ip route get 192.168.100.2 | head -2
echo "CARRIER=$(cat /sys/class/net/$IF/carrier 2>&1)"

echo "### PHASE geom_gate $(date +%s.%N)"
BID0=$(brd 0x04)
norm(){ printf '%s' "$1" | tr 'A-F' 'a-f'; }
if [ "$(norm "$BID0")" != "$(norm "$BID_EXPECT")" ]; then
  echo "LF_GEOM_FAIL 板侧 BID=$BID0 != $BID_EXPECT ⇒ 拒绝继续"; exit 3
fi
bash "$S" id || { echo "LF_GEOM_FAIL 取数器身份闸未过 ⇒ 拒绝继续"; exit 3; }
echo "LF_GEOM_OK NW=${NW} BID=$BID0"

echo "### PHASE nic_pre $(date +%s.%N)"; NIC pre
sleep 2.0; echo "### PHASE nic_pre2 $(date +%s.%N)"; NIC pre2   # 同上: 取刷新后的读数 (判据用 pre2)
echo "### PHASE pre_snapshot $(date +%s.%N)"
bash "$S" full "${TAG}_pre" || { echo "LF_ABORT pre_snapshot"; exit 1; }

if [ "$PCAP_ON" = "1" ]; then
  echo "PCAP_ACTIVE=1 IO_AFFECTING=1 target=$PCAP (⚠️ 含磁盘 IO)"
else
  echo "PCAP_ACTIVE=0 IO_AFFECTING=0 (默认: 不抓包, 不写盘)"
fi
# ⭐ ss 采样加密 (0.5 s -> 0.01 s): 长流只有 ~250-300 ms, 0.5 s 采样**结构性落在流外**
#    (LF2 实测: 那条 rtt:0.156 的样本取自流前) ⇒ 每 10 ms 一次, 直到收尾显式 kill。
( while :; do
    echo "SS_T $(date +%s.%N) $(ss -tinma '( dport = :8080 or sport = :8080 )' 2>/dev/null | tr '\n' '|')"
    sleep 0.01
  done ) > /tmp/ss_${TAG}.log 2>&1 &
SSPID=$!
sleep 1

echo "### PHASE sink_start $(date +%s.%N)"
setsid timeout -k 2 $((SECS+60)) "$SINK" --host 192.168.100.2 --port 8080 --conns "$CONNS" \
   --seconds "$SECS" --rcvbuf "$RCVBUF" $SINK_EXTRA > /tmp/sink_${TAG}.txt 2>&1 &
SPID=$!

# ---- ⭐ 内窗系列: 前台连续 snap, 直到 sink 退出 + EXTRA 次 -----------------------------
EXTRA=${EXTRA:-2}
i=0; seen_alive=0
while :; do
  echo "LF_SNAP_T $(date +%s.%N) $i"
  bash "$S" snap "${TAG}_s$i" $KW | tee /tmp/lf_${TAG}_s$i.txt
  RC=${PIPESTATUS[0]}
  echo "LF_SNAP_RC $i $RC"
  i=$((i+1))
  alive=0; kill -0 $SPID 2>/dev/null && alive=1
  if [ "$alive" = "0" ]; then
    # sink 已退出: 再补 EXTRA 次 (点必须落在流后, 用来判"收尾不动")
    k=0
    while [ $k -lt "$EXTRA" ]; do
      echo "LF_SNAP_T $(date +%s.%N) $i"
      bash "$S" snap "${TAG}_s$i" $KW | tee /tmp/lf_${TAG}_s$i.txt
      echo "LF_SNAP_RC $i ${PIPESTATUS[0]}"
      i=$((i+1)); k=$((k+1)); sleep 0.05
    done
    break
  else
    seen_alive=1
  fi
  [ $i -ge "$MAXSNAP" ] && { echo "LF_SNAP_MAXREACHED $i"; break; }
  sleep "$SNAPGAP"
done
wait $SPID; SINK_RC=$?
kill $SSPID 2>/dev/null
echo "SINK_RC=$SINK_RC saw_alive=$seen_alive snaps=$i $(date +%s.%N)"

echo "### PHASE nic_post $(date +%s.%N)"; NIC post
# ⚠️ LF2 实测坑: sfc 网卡的硬件计数 (port_rx_*) 是**周期性刷新**的 —— 流后 1.7 s 读到的
#    仍是流前的值 (读两次逐字相同) ⇒ 加 **2.5 s 等待 + 二次读** (nic_post2), 判据一律用后读
sleep 2.5
echo "### PHASE nic_post2 $(date +%s.%N)"; NIC post2
echo "### PHASE post_snapshot $(date +%s.%N)"
bash "$S" full "${TAG}_post" || { echo "LF_ABORT post_snapshot"; exit 1; }
echo "### PHASE geom_nopcap $(date +%s.%N)"; geom_nopcap

echo "### PHASE ping $(date +%s.%N)"
ping -c 3 -i 0.2 -W 1 192.168.100.2 2>/dev/null | tail -2 | tr '\n' ' '; echo
echo "### SINK tail:"; tail -6 /tmp/sink_${TAG}.txt 2>/dev/null
echo "### SINK_SUM:"; grep SINK_SUM /tmp/sink_${TAG}.txt 2>/dev/null
echo "### SINK head:"; head -3 /tmp/sink_${TAG}.txt 2>/dev/null
echo "### SS samples (last 8):"; tail -8 /tmp/ss_${TAG}.log 2>/dev/null | cut -c1-300
echo "LF_META_BOARD_BID_END=$(brd 0x04)"
[ "$PCAP_ON" = "1" ] && { echo "### PCAP: $(ls -la "$PCAP" 2>/dev/null)"; } || echo "PCAP_SKIPPED (PCAP_ON=0)"
echo "LF_DL_DONE $(date +%s.%N)"
