#!/bin/bash
# probe_collapse.sh -- 补充探针 (非派单指定, 为回答两个遗留问题):
#   Q1 "旧臂的窗'之后才塌'"到底塌没塌: 服务端在 +0.5 s 发 4 字节, 客户端随后的 ACK
#      携带的是 **setsockopt 之后** 的当前通告窗 (这是"塌窗"的直接对象).
#   Q2 上一轮 pcap 只有 3 个握手包 (FIN 在线上但没写进文件): 本轮把 kill 前的等待
#      从 0.4 s 拉到 3 s, 看收尾包是否出现.
# 仍用真 sink 本体 (同二进制/同 sink_connect_rcvbuf 路径); 图案校验必然失配 = 预期, 非本判据对象.
set -u
DIR=/tmp/sinkfix_verify
PORT=39019
cd "$DIR" || exit 90
echo "PROBE_C_TAG=PROBEC_$(date +%Y%m%d_%H%M%S)_c9d1"

cat > "$DIR/miniserver_send.py" <<'PYEOF'
import socket, sys, time
port = int(sys.argv[1]); hold = float(sys.argv[2])
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port)); s.listen(4)
print("SERVER_LISTENING port=%d hold=%.1f" % (port, hold), flush=True)
c, addr = s.accept()
print("SERVER_ACCEPTED peer=%s:%d" % (addr[0], addr[1]), flush=True)
time.sleep(0.5)
c.sendall(b"\xde\xad\xbe\xef")
print("SERVER_SENT_4B", flush=True)
time.sleep(hold)
c.close(); s.close()
print("SERVER_DONE", flush=True)
PYEOF

probe_arm () {
  local name="$1"; shift
  echo ""
  echo "#### PROBE ARM $name ####"
  runuser -u a -- python3 "$DIR/miniserver_send.py" "$PORT" 6 > "pc_server_${name}.log" 2>&1 &
  local srv=$!
  for _ in $(seq 1 50); do grep -q SERVER_LISTENING "pc_server_${name}.log" 2>/dev/null && break; sleep 0.1; done
  cat "pc_server_${name}.log"
  tcpdump -i lo -nn -s 0 -U -w "$DIR/pc_${name}.pcap" "tcp port $PORT" > "pc_tcpdump_${name}.log" 2>&1 &
  local td=$!
  for _ in $(seq 1 50); do grep -q "listening on" "pc_tcpdump_${name}.log" 2>/dev/null && break; sleep 0.1; done
  runuser -u a -- "$DIR/p7b_tcp_sink" --host 127.0.0.1 --port "$PORT" \
        --rcvbuf 2920 --conns 1 --seconds 6 "$@" > "pc_${name}.out" 2> "pc_${name}.err"
  echo "SINK_RC_${name}=$?"
  sleep 3
  kill -INT "$td" 2>/dev/null; wait "$td" 2>/dev/null
  kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null
  echo "--- 见证行 ---"; grep -n "SINK_RCVBUF_ORDER" "pc_${name}.out" || echo "MISSING_WITNESS"
  echo "--- sink stdout (SINK_CONN/SINK_SUM) ---"; grep -E "SINK_CONN|SINK_SUM" "pc_${name}.out"
  echo "--- server log ---"; cat "pc_server_${name}.log"
  echo "--- tcpdump stats ---"; cat "pc_tcpdump_${name}.log"
  echo "--- tcpdump text ---"; tcpdump -nn -vv -r "$DIR/pc_${name}.pcap" 2>&1
  echo "--- 裸字段 ---"; python3 "$DIR/parse_pcap_tcp.py" "$DIR/pc_${name}.pcap" 2>&1
}

probe_arm A2
probe_arm B2 --rcvbuf-after-connect
echo ""
echo "PROBE_C_DONE"
