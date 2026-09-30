#!/bin/bash
# p7b_selftest.sh -- **不碰板子**的工具自检 (回环口 + 假板台架)
#
# 为什么要有它 (全局纪律: 每加一条判据配一个"该被抓住"的反例):
#   本轮的验收判据是"对端逐字节等于图案流"。这条判据必须有能被抓住的反例 ——
#   在 127.0.0.1 上用同一个二进制、只注入**一个 bit**, 看判据是否翻红。
#   板子上的每一次测量都比这条自检贵得多 (重烧 + rescan + 对端机), 所以先在这里把工具钉死。
#
# 判据 (预期值写死在脚本里; 任何一条不符 => 工具不可信, 停):
#   T1 三个二进制 --selftest 全 OK (图案向量是**独立手算**的常量)
#   T2 干净流   : sink 报 first_mismatch=-1, 退出码 0
#   T3 翻 1 bit : sink 报 first_mismatch=<N>, 退出码 1      <= 判据有牙的**正证据**
#   T4 短流     : sink 的 bytes 小于假板字节数 (量程判据有牙)
#   T5 上行     : tcp_src 的 SRC_SUM send_err=0, tx_bytes>0, 且假板侧 up_first_mismatch=-1
#
# 用法: bash p7b_selftest.sh [端口, 默认 18888]
set -u
PORT=${1:-18888}
cd "$(dirname "$0")"
BIN_SINK=./p7b_tcp_sink
BIN_SRC=./p7b_tcp_src
PASS=0; FAIL=0
ck(){ if [ "$2" = "$3" ]; then echo "  [PASS] $1 = $2"; PASS=$((PASS+1));
      else echo "  [FAIL] $1 got='$2' want='$3'"; FAIL=$((FAIL+1)); fi; }
# 从 SINK_SUM 行取一个字段 (逐行 only; 多行 grep 会把下一行的字段也拼进来 => 曾误判 FAIL)
fld(){ awk -v k="$2" -v p="$3" '$0 ~ p { for(i=1;i<=NF;i++) if (index($i, k"=")==1) { print substr($i, length(k)+2); exit } }' "$1"; }

echo "===== T0 编译 ====="
for t in p7b_tcp_sink p7b_tcp_src p7b_udp_src; do
  g++ -O3 -std=c++17 -Wall -o $t $t.cpp || { echo "  [FAIL] 编译 $t"; FAIL=$((FAIL+1)); }
done
echo "===== T1 图案自检向量 (独立手算常量) ====="
for t in $BIN_SINK $BIN_SRC ./p7b_udp_src; do
  out=$($t --selftest); rc=$?
  echo "$out" | grep -q "OK" && ck "$t --selftest" "OK" "OK" || { echo "$out"; ck "$t --selftest" FAIL OK; }
done

echo "===== T2 干净流 (假板 = 满 1MB 图案 + FIN) ====="
python3 p7b_fake_board.py --listen 127.0.0.1:$PORT --bytes 1048576 --conns 2 >/tmp/p7b_fb1.log 2>&1 &
FB=$!; sleep 0.7
$BIN_SINK --host 127.0.0.1 --port $PORT --conns 2 --seconds 30 >/tmp/p7b_sink1.log 2>&1; RC=$?
wait $FB 2>/dev/null
grep -q "first_mismatch=-1" /tmp/p7b_sink1.log && ck "T2 干净流 first_mismatch" "-1" "-1" || { cat /tmp/p7b_sink1.log; ck "T2 干净流 first_mismatch" "有失配" "-1"; }
ck "T2 sink 退出码" "$RC" "0"
B=$(fld /tmp/p7b_sink1.log bytes '^SINK_SUM')
ck "T2 收满 2 连接 x 1MB" "$B" "2097152"

echo "===== T3 翻 1 个 bit @500000 (判据必须有牙) ====="
python3 p7b_fake_board.py --listen 127.0.0.1:$PORT --bytes 1048576 --flip-at 500000 --conns 1 >/tmp/p7b_fb2.log 2>&1 &
FB=$!; sleep 0.7
$BIN_SINK --host 127.0.0.1 --port $PORT --conns 1 --seconds 30 >/tmp/p7b_sink2.log 2>&1; RC=$?
wait $FB 2>/dev/null
FM=$(fld /tmp/p7b_sink2.log first_mismatch '^SINK_CONN')
ck "T3 首个失配偏移" "$FM" "500000"
ck "T3 sink 退出码 (必须非 0)" "$RC" "1"
MB=$(fld /tmp/p7b_sink2.log mism_bytes '^SINK_CONN')
ck "T3 失配字节数 = 1 (只翻了一 bit)" "$MB" "1"

echo "===== T4 短流 (量程判据有牙: 收到 < 声明) ====="
python3 p7b_fake_board.py --listen 127.0.0.1:$PORT --bytes 1048576 --short 300000 --conns 1 >/tmp/p7b_fb3.log 2>&1 &
FB=$!; sleep 0.7
$BIN_SINK --host 127.0.0.1 --port $PORT --conns 1 --seconds 30 >/tmp/p7b_sink3.log 2>&1
wait $FB 2>/dev/null
B=$(fld /tmp/p7b_sink3.log bytes '^SINK_SUM')
ck "T4 收到的字节数" "$B" "300000"

echo "===== T5 上行 (src -> 假板; 假板侧独立复算) ====="
python3 p7b_fake_board.py --listen 127.0.0.1:$PORT --bytes 1048576 --hold 4 --conns 1 >/tmp/p7b_fb4.log 2>&1 &
FB=$!; sleep 0.7
$BIN_SRC --host 127.0.0.1 --port $PORT --seconds 3 >/tmp/p7b_src1.log 2>&1; RC=$?
wait $FB 2>/dev/null
SE=$(fld /tmp/p7b_src1.log send_err '^SRC_SUM')
ck "T5 src send_err" "$SE" "0"
RF=$(fld /tmp/p7b_src1.log rx_first_mismatch '^SRC_SUM')
ck "T5 src 下行逐字节 (假板的干净流)" "$RF" "-1"
UF=$(fld /tmp/p7b_fb4.log up_first_mismatch '^FAKE_BOARD conn')
ck "T5 **假板侧**独立复算上行" "$UF" "-1"
UB=$(fld /tmp/p7b_fb4.log up_bytes '^FAKE_BOARD conn')
echo "  [INFO] 3 s 内上行被假板侧复算到的字节数 = ${UB:-0} (环回, 仅作有流量证据)"

echo
echo "SELFTEST_SUMMARY PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "SELFTEST_OK" || echo "SELFTEST_BAD"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
