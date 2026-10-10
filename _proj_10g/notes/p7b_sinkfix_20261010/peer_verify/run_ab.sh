#!/bin/bash
# run_ab.sh -- sinkfix 验证: SO_RCVBUF 的落点 => 首个窗口通告 (lo 回环, 真 Linux 栈)
#
# 身份: 由 tools/peer_ssh.py --sudo 以 root 启动 (tcpdump 需要特权);
#       sink 与服务端用 runuser 降权到 user a (常规台架身份); tcpdump 以 root 跑.
# 交付: 全部原始输出落在 /tmp/sinkfix_verify/ (只读台架; 绝不动 /tmp/p7b_biz).
set -u
NONCE="SFVNONCE_$(date +%Y%m%d_%H%M%S)_a1b2c3"
DIR=/tmp/sinkfix_verify
PORT=39017
HOLD=8           # 服务端 accept 后只 sleep 这么久 (不放数据)
cd "$DIR" || { echo "FATAL cd $DIR"; exit 90; }

echo "RUN_TAG=$NONCE"
echo "WHOAMI=$(whoami) UID=$(id -u) HOST=$(hostname)"
echo "=== kernel ==="; uname -a
echo "=== sysctl (窗口语义上下文) ==="
sysctl net.ipv4.tcp_rmem net.core.rmem_default net.core.rmem_max \
       net.ipv4.tcp_window_scaling net.ipv4.tcp_adv_win_scale net.ipv4.tcp_moderate_rcvbuf 2>&1
echo "=== port check (期望空) ==="
ss -ltn "sport = :$PORT" | tail -n +2 || true
echo "=== 编译件指纹 ==="
md5sum "$DIR/p7b_tcp_sink" "$DIR/p7b_tcp_sink.cpp"

echo "=== pin gate probe (--help 也会先过绑核硬门; RC=2 => 需要 --no-pin) ==="
runuser -u a -- "$DIR/p7b_tcp_sink" --help > help_head.txt 2> help_err.txt
echo "HELP_RC=$?"
head -40 help_head.txt
echo "--- help stderr ---"; cat help_err.txt

run_arm () {
  local name="$1"; shift
  echo ""
  echo "################ ARM $name  ($NONCE) ################"
  # 服务端: listen -> accept 一次 -> HOLD 秒不放数据
  runuser -u a -- python3 "$DIR/mini_server.py" "$PORT" "$HOLD" > "server_${name}.log" 2>&1 &
  local srv=$!
  for _ in $(seq 1 50); do grep -q SERVER_LISTENING "server_${name}.log" 2>/dev/null && break; sleep 0.1; done
  cat "server_${name}.log"
  # 抓包: 从 listen 之前起 (不等 -c N —— 只有 3 个握手包时 -c 6 会一直等)
  local pcap="$DIR/arm_${name}.pcap"
  tcpdump -i lo -nn -s 0 -U -w "$pcap" "tcp port $PORT" > "tcpdump_${name}.log" 2>&1 &
  local td=$!
  for _ in $(seq 1 50); do grep -q "listening on" "tcpdump_${name}.log" 2>/dev/null && break; sleep 0.1; done
  cat "tcpdump_${name}.log"
  # 臂: 默认 = 修复后 (before_connect); $@ 可带 --rcvbuf-after-connect = 旧行为臂
  runuser -u a -- "$DIR/p7b_tcp_sink" --host 127.0.0.1 --port "$PORT" \
        --rcvbuf 2920 --conns 1 --seconds 6 "$@" > "arm_${name}.out" 2> "arm_${name}.err"
  echo "SINK_RC_${name}=$?"
  sleep 0.4
  kill -INT "$td" 2>/dev/null; wait "$td" 2>/dev/null
  kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null
  echo "--- arm ${name} stdout ---"; cat "arm_${name}.out"
  echo "--- arm ${name} stderr ---"; cat "arm_${name}.err"
  echo "--- 见证行检查 (缺见证按未测读) ---"
  grep -n "SINK_RCVBUF_ORDER" "arm_${name}.out" || echo "MISSING_WITNESS_${name}"
  echo "--- arm ${name} tcpdump 文本 ---"
  tcpdump -nn -vv -r "$pcap" 2>&1
  echo "--- arm ${name} 裸字段解析 (自写解析器, 绕开显示层歧义) ---"
  python3 "$DIR/parse_pcap_tcp.py" "$pcap" 2>&1
  echo "PCAP_${name}_BYTES=$(stat -c '%s' "$pcap")"
  echo "PCAP_${name}_SHA256=$(sha256sum "$pcap" | cut -d' ' -f1)"
}

run_arm A
run_arm B --rcvbuf-after-connect

echo ""
echo "ALL_DONE $NONCE"
ls -la "$DIR"
