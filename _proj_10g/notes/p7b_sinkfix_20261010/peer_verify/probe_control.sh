#!/bin/bash
# probe_control.sh -- 对照臂: 钉住"落点事后设 rcvbuf 是否会影响后续通告窗"
#   A3: before_connect  rcvbuf=2920     (判据臂, 加 ss 见证)
#   B3: after_connect   rcvbuf=2920     (旧行为臂, 加 ss 见证)
#   C3: after_connect   rcvbuf=204800   (对照: 若事后设值能反映到窗口, 后续包应见 ~200 个单位)
# 服务端 +0.5 s 发 4 字节 => 客户端 ACK 携带"当时"的通告窗 (setsockopt 之后).
# ss -tinme 在连接存活期抽样 = 缓冲/窗口的独立见证 (不经 tcpdump).
set -u
DIR=/tmp/sinkfix_verify
PORT=39021
cd "$DIR" || exit 90
echo "PROBE2_TAG=PROBE2_$(date +%Y%m%d_%H%M%S)_d4e5"

probe_arm () {
  local name="$1" rcvbuf="$2"; shift 2
  echo ""
  echo "#### PROBE2 ARM $name (rcvbuf=$rcvbuf $*) ####"
  runuser -u a -- python3 "$DIR/miniserver_send.py" "$PORT" 6 > "p2_server_${name}.log" 2>&1 &
  local srv=$!
  for _ in $(seq 1 50); do grep -q SERVER_LISTENING "p2_server_${name}.log" 2>/dev/null && break; sleep 0.1; done
  tcpdump -i lo -nn -s 0 -U -w "$DIR/p2_${name}.pcap" "tcp port $PORT" > "p2_tcpdump_${name}.log" 2>&1 &
  local td=$!
  for _ in $(seq 1 50); do grep -q "listening on" "p2_tcpdump_${name}.log" 2>/dev/null && break; sleep 0.1; done
  runuser -u a -- "$DIR/p7b_tcp_sink" --host 127.0.0.1 --port "$PORT" \
        --rcvbuf "$rcvbuf" --conns 1 --seconds 6 "$@" > "p2_${name}.out" 2> "p2_${name}.err" &
  local sk=$!
  sleep 1.2
  echo "--- ss -tinme 抽样 (+1.2s, 连接存活中) ---"
  ss -tinme "( sport = :$PORT or dport = :$PORT )" 2>&1 | head -30
  wait "$sk"; echo "SINK_RC_${name}=$?"
  sleep 3
  kill -INT "$td" 2>/dev/null; wait "$td" 2>/dev/null
  kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null
  echo "--- 见证行 ---"; grep -n "SINK_RCVBUF_ORDER" "p2_${name}.out" || echo "MISSING_WITNESS"
  echo "--- sink stdout (SINK_CONN/SUM) ---"; grep -E "SINK_CONN|SINK_SUM" "p2_${name}.out"
  echo "--- tcpdump stats ---"; cat "p2_tcpdump_${name}.log"
  echo "--- 裸字段 ---"; python3 "$DIR/parse_pcap_tcp.py" "$DIR/p2_${name}.pcap" 2>&1
}

probe_arm A3 2920
probe_arm B3 2920 --rcvbuf-after-connect
probe_arm C3 204800 --rcvbuf-after-connect
echo ""
echo "PROBE2_DONE"
