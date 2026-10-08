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
# ⭐ 2026-10-09 (R1: 非阻塞 + 电平触发) 新增三条 —— 让新语义有**常驻**判据:
#   T6 **stall 语义**: 假板 --silent (只连不发) => sink 必须打 `POLL_TIMEOUT` + `SINK_CONN n STALL`,
#      `stall_conns=1` **且不许算进 clean_conns**, 退出码 1 (旧版无超时护栏 = 永久挂住, 静默)
#   T7 **非阻塞实测 (strace)**: connect 返回 EINPROGRESS; 全部 connect/recv*/send* 的**单次耗时
#      < 5 ms** (阻塞版在等数据时会现出长耗时) —— strace 不在则打 SKIP 醒目行 (不静默跳过)
#   T8 **udp_src 载荷**: 回环 UDP 收豆机在内存里按图案流增量复算 (不落盘), send_err/poll_tmo=0
#   T8b **EAGAIN 注入**: strace `-e inject=sendmmsg:error=EAGAIN` ⇒ udp_src 的 EAGAIN→poll(POLLOUT)
#      分支必须被真的走到且不崩 (回环上 UDP 天生不产生 EAGAIN ⇒ 不注入就**测不到**这条路径)
#
# 用法: bash p7b_selftest.sh [端口, 默认 18888]
set -u
PORT=${1:-18888}
cd "$(dirname "$0")"
BIN_SINK=./p7b_tcp_sink
BIN_SRC=./p7b_tcp_src
BIN_UDP=./p7b_udp_src
PASS=0; FAIL=0
ck(){ if [ "$2" = "$3" ]; then echo "  [PASS] $1 = $2"; PASS=$((PASS+1));
      else echo "  [FAIL] $1 got='$2' want='$3'"; FAIL=$((FAIL+1)); fi; }
# 从 SINK_SUM 行取一个字段 (逐行 only; 多行 grep 会把下一行的字段也拼进来 => 曾误判 FAIL)
fld(){ awk -v k="$2" -v p="$3" '$0 ~ p { for(i=1;i<=NF;i++) if (index($i, k"=")==1) { print substr($i, length(k)+2); exit } }' "$1"; }

echo "===== T0 编译 ====="
# ⭐ 2026-10-09: 旗标改成**部署口径** (原 `-O3 -std=c++17`; ⭐⭐ 同日用户裁定 = `-O3`) —— 门与部署件必须是同一份
#   构建命令 (BUILD.md §2/§4; 旧的三条互相打架的编译行里, 本行是其中一条)。
# ⭐⭐ 2026-10-09 (双线程样板): 追加 **`-pthread`** —— sink 现在用 pthread_create/join
#   (glibc 2.39 的 libpthread 已并入 libc, 少了它在本机仍能链上, 但**门与部署件的旗标必须逐字相同**,
#    否则"门与板跑两个配置"的老坑会以"换台机器就链不上"的形式复发)。BUILD.md §2 同步。
for t in p7b_tcp_sink p7b_tcp_src p7b_udp_src; do
  g++ -O3 -pthread -Wall -o $t $t.cpp || { echo "  [FAIL] 编译 $t"; FAIL=$((FAIL+1)); }
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

echo "===== T6 stall 语义 (假板 --silent: 只连不发; poll 超时必须有确定语义) ====="
python3 p7b_fake_board.py --listen 127.0.0.1:$PORT --bytes 1 --silent --hold 4 --conns 1 >/tmp/p7b_fb5.log 2>&1 &
FB=$!; sleep 0.7
$BIN_SINK --host 127.0.0.1 --port $PORT --conns 1 --seconds 30 --poll-ms 500 --stall-n 3 >/tmp/p7b_sink4.log 2>&1; RC=$?
wait $FB 2>/dev/null
grep -q "POLL_TIMEOUT" /tmp/p7b_sink4.log && ck "T6 poll 超时日志行" "有" "有" || { cat /tmp/p7b_sink4.log; ck "T6 poll 超时日志行" "无" "有"; }
grep -q "^SINK_CONN 0 STALL" /tmp/p7b_sink4.log && ck "T6 SINK_CONN STALL 行" "有" "有" || { cat /tmp/p7b_sink4.log; ck "T6 SINK_CONN STALL 行" "无" "有"; }
ck "T6 stall_conns" "$(fld /tmp/p7b_sink4.log stall_conns '^SINK_SUM')" "1"
ck "T6 clean_conns (STALL 不许算 clean)" "$(fld /tmp/p7b_sink4.log clean_conns '^SINK_SUM')" "0"
ck "T6 sink 退出码 (STALL 必须非 0)" "$RC" "1"

echo "===== T7 非阻塞实测 (strace: connect=EINPROGRESS 且 I/O 单次耗时 < 5 ms) ====="
# strace -T 把单次耗时写成行尾 `<0.000123>`; poll 故意会阻塞(电平触发的本意) => 分开统计。
# 这个提取器被 T7(被测件) 与 T7b(负对照) 复用 —— **同一条代码路径**。
strace_io_stats(){ awk '
    { t=0; if (match($0, /<[0-9.]+>$/)) { t=substr($0,RSTART+1,RLENGTH-2)+0 }
      if ($0 ~ /connect\(/ && $0 ~ /EINPROGRESS/) eip++
      if ($0 ~ /(recvfrom|recvmsg|sendto|sendmsg|sendmmsg|connect)\(/) { nio++; if (t>mx) mx=t }
      if ($0 ~ /(ppoll|poll)\(/) { npo++; if (t>mp) mp=t }
    }
    END { printf "EIP=%d; MXIO=%.6f; MXPOLL=%.6f; NIO=%d; NPOLL=%d", eip+0, mx+0, mp+0, nio+0, npo+0 }' "$1"; }
if command -v strace >/dev/null 2>&1; then
  python3 p7b_fake_board.py --listen 127.0.0.1:$PORT --bytes 1048576 --hold 2 --conns 1 >/tmp/p7b_fb6.log 2>&1 &
  FB=$!; sleep 0.7
  strace -f -T -o /tmp/p7b_strace.log \
    -e trace=connect,recvfrom,recvmsg,sendto,sendmsg,sendmmsg,poll,ppoll,accept,accept4 \
    $BIN_SINK --host 127.0.0.1 --port $PORT --conns 1 --seconds 10 --poll-ms 2000 >/tmp/p7b_sink5.log 2>&1
  wait $FB 2>/dev/null
  eval "$(strace_io_stats /tmp/p7b_strace.log)"
  echo "  [INFO] strace: EINPROGRESS=$EIP  I/O 调用数=$NIO (单次最大 ${MXIO}s)  poll 次数=$NPOLL (单次最大 ${MXPOLL}s)"
  ck "T7 connect 走 EINPROGRESS (非阻塞)" "$([ "${EIP:-0}" -ge 1 ] && echo yes || echo no)" "yes"
  ck "T7 无一次阻塞式 I/O (max < 5 ms)" "$(awk -v m="${MXIO:-9}" 'BEGIN{print (m<0.005)?"yes":"no"}')" "yes"
  ck "T7 poll 确实在等 (LT 语义: max >= 0.1 s)" "$(awk -v m="${MXPOLL:-0}" 'BEGIN{print (m>=0.1)?"yes":"no"}')" "yes"
  grep -q "EAGAIN" /tmp/p7b_strace.log && ck "T7 出现过 EAGAIN (非阻塞语义正证据)" "有" "有" || echo "  [INFO] 本跑没有 EAGAIN (poll 命中率高时不奇怪; 不设判据)"

  echo "----- T7b 负对照: 同一判据在一个**阻塞**程序上必须翻红 (没有它 T7 只是空话) -----"
  strace -f -T -o /tmp/p7b_strace_blk.log -e trace=accept,accept4,recvfrom,recvmsg \
    python3 -c 'import socket,sys,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(("127.0.0.1",int(sys.argv[1]))); s.listen(1)
c,_=s.accept(); d=c.recv(4096); print("BLK_GOT %d"%len(d))' "$PORT" >/tmp/p7b_blk.log 2>&1 &
  STP=$!; sleep 0.8
  python3 -c 'import socket,sys,time
s=socket.socket(); s.connect(("127.0.0.1",int(sys.argv[1]))); time.sleep(1.0)
s.send(b"hello"); time.sleep(0.2)' "$PORT"
  wait $STP 2>/dev/null
  eval "$(strace_io_stats /tmp/p7b_strace_blk.log)"
  echo "  [INFO] 阻塞对照件: I/O 调用数=$NIO 单次最大 ${MXIO}s (期望 ≈1.0 s = 它就是被 recv 卡住的)"
  ck "T7b 负对照: 阻塞程序上'无阻塞 I/O'判据必须翻红" "$(awk -v m="${MXIO:-0}" 'BEGIN{print (m<0.005)?"yes":"no"}')" "no"
else
  echo "  [SKIP] 本机没有 strace —— **T7/T7b 未跑** (不是通过! 装 strace 或到对端机跑本脚本)"
  echo "  [SKIP] 退路 (静态判据): F_SETFL 只应出现在 set_nonblock 里, 且不得有清 O_NONBLOCK 的调用"
  grep -n "F_SETFL" *.cpp | sed 's/^/    /'
fi

echo "===== T8 udp_src 载荷 (回环 UDP 收豆机: 内存里增量复算图案流, 不落盘) ====="
python3 - "$PORT" >/tmp/p7b_udpcheck.log 2>&1 <<'PYEOF' &
import socket, sys
SEED = 0x9E3779B97F4A7C15; M64 = (1 << 64) - 1
def xs(s):
    s ^= (s << 13) & M64; s ^= s >> 7; s ^= (s << 17) & M64; return s & M64
N = 4 << 20                      # 预生成 4 MB 图案 (纯内存; 只为比对, 不落盘)
buf = bytearray(N); s = SEED
for i in range(N):
    buf[i] = (s >> 24) & 0xFF; s = xs(s)
EXP = bytes(buf)
u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
u.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 << 20)
u.bind(("127.0.0.1", int(sys.argv[1])))
u.settimeout(3.0)
off = 0; pkts = 0; mis = 0; first = -1
try:
    while True:
        try:
            d, _ = u.recvfrom(65536)
        except socket.timeout:
            break
        pkts += 1
        if off + len(d) <= N:
            if d != EXP[off:off+len(d)]:
                k = next((j for j in range(len(d)) if d[j] != EXP[off+j]), -1)
                if first < 0: first = off + k
                mis += sum(1 for j in range(len(d)) if d[j] != EXP[off+j])
        else:
            mis += 1
        off += len(d)
except OSError as e:
    print("UDPCHECK_ERR %s" % e, flush=True)
print("UDPCHECK pkts=%d bytes=%d mism_bytes=%d first_mismatch=%d covered=%s"
      % (pkts, off, mis, first, "yes" if off <= N else "no"), flush=True)
PYEOF
UDPP=$!; sleep 3.0
$BIN_UDP --host 127.0.0.1 --port $PORT --seconds 1.5 --mbps 16 --paylen 1472 >/tmp/p7b_udp.log 2>&1; RC=$?
wait $UDPP 2>/dev/null
UOK=$(grep -c "^UDPCHECK" /tmp/p7b_udpcheck.log)
ck "T8 收豆机出结果行" "$UOK" "1"
ck "T8 逐字节失配 (图案流连续)" "$(fld /tmp/p7b_udpcheck.log mism_bytes '^UDPCHECK')" "0"
ck "T8 收到 datagram (非零正证据)" "$(awk -v n="$(fld /tmp/p7b_udpcheck.log pkts '^UDPCHECK')" 'BEGIN{print (n+0>0)?"yes":"no"}')" "yes"
ck "T8 udp_src 退出码" "$RC" "0"
ck "T8 udp_src send_err=0 且 poll_tmo=0" "$(fld /tmp/p7b_udp.log call_errors '^UDP_SUM')$(fld /tmp/p7b_udp.log poll_tmo '^UDP_SUM')" "00"
grep -q "^UDPCHECK" /tmp/p7b_udpcheck.log && echo "  [INFO] $(grep '^UDPCHECK' /tmp/p7b_udpcheck.log)"

echo "===== T8b 注入 EAGAIN ⇒ udp_src 必须走 poll(POLLOUT) (注入过 = 真测到) ====="
if command -v strace >/dev/null 2>&1 && strace -e inject=clock_nanosleep:error=EAGAIN:when=1 true >/dev/null 2>&1; then
  python3 - "$PORT" >/tmp/p7b_dr.log 2>&1 <<'PYEOF' &
import socket, sys, time
u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
u.bind(("127.0.0.1", int(sys.argv[1]))); u.settimeout(4)
n = 0
try:
    while True:
        d, _ = u.recvfrom(65536); n += len(d)
except socket.timeout:
    pass
print("DRAIN bytes=%d" % n, flush=True)
PYEOF
  DR=$!; sleep 0.6
  strace -f -T -o /tmp/p7b_st_inj.log -e trace=sendmmsg,poll,ppoll \
         -e inject=sendmmsg:error=EAGAIN:when=3 \
         $BIN_UDP --host 127.0.0.1 --port $PORT --seconds 1 --mbps 8 >/tmp/p7b_udp3.log 2>&1
  wait $DR 2>/dev/null
  ck "T8b 注入的 EAGAIN 确实发生 (INJECTED 1 次)" "$(grep -c 'EAGAIN.*INJECTED' /tmp/p7b_st_inj.log)" "1"
  ck "T8b EAGAIN 之后紧跟 poll(fd, POLLOUT)" \
     "$(awk '/INJECTED/{f=1;next} f && /poll\(\[\{fd=/{print "yes"; exit}' /tmp/p7b_st_inj.log)" "yes"
  ck "T8b 注入后工具继续工作 (call_errors=0 且 pkts>0)" \
     "$(awk -v e="$(fld /tmp/p7b_udp3.log call_errors '^UDP_SUM')" -v p="$(fld /tmp/p7b_udp3.log pkts '^UDP_SUM')" \
        'BEGIN{print ((e=="0") && (p+0>0)) ? "yes" : "no"}')" "yes"
else
  echo "  [SKIP] 没有 strace 或它不支持 -e inject ⇒ **T8b 未跑** (不是通过)"
fi

echo
echo "SELFTEST_SUMMARY PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "SELFTEST_OK" || echo "SELFTEST_BAD"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
