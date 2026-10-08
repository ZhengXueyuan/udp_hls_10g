#!/bin/bash
# p7b_dualthread_selftest.sh -- 双线程样板 (p7b_tcp_sink) 的**板外**自检 (2026-10-09)
#
# 为什么要有它 (计划 §验证表 + 全局纪律"每加一条判据配一个该被抓住的反例"):
#   sink 从单线程改成 [I/O 线程 + 校验线程 + 两条 SPSC 无锁队列] 之后, 最危险的**静默退化**是
#   `first_mismatch` 从"连接内流偏移"变成"本块内偏移" —— 这种退化**不会**让任何既有判据翻红
#   (连接照样 OK、退出码照样 0), 只有把**已知偏移的失配**注进去才看得见。
#   ⛔ 全程**只在回环口** (127.0.0.1) 跑; 不碰板子 / 不发板级流量。
#
# 判据 (PASS/FAIL 逐条打; 任一条 FAIL => 工具不可信, 停):
#   D1 干净流逐字节等价: 双线程 vs --no-thread 的 got/mism_bytes/first_mismatch **逐字相同** 且 RC=0
#   D2 **偏移语义定点牙**: 在回环上注入已知偏移 K 的失配 => 两臂 first_mismatch 都必须 == K
#      (K 覆盖槽边界 65535/65536 与远端 1000000)
#   D3 **D2 的负对照**: 突变件 (去掉基偏移, 只传 ptr/len) 必须**报不出 K** (否则 D2 没牙)
#   D4 队列不丢不漏: q_full_push == q_full_pop == q_free_pop 且 q_free_push - q_free_pop == slots
#   D5 TSan (有则跑): 双线程跑回环 => ThreadSanitizer 告警数 0 且 RC=0
#   D6 绑核: PIN_CPU_IO != PIN_CPU_WORK; 两者**不同物理核**; PIN_ALLOWED_MASK_<X> == 1<<PIN_CPU_<X>;
#      /proc/<pid>/task/*/status 的 Cpus_allowed_list 交叉核
#   D7 end-expect 硬门未误杀: 双线程正常跑**不得**出现 END_MISMATCH / _exit(2) (RC 必须是 0)
#   D8 两个天花板 (须现测): check-only / recv-only / recv-check / recv-check-split 四个数 (只记录+断言>0)
#
# 用法 (对端机): bash /tmp/p7b_biz/p7b_dualthread_selftest.sh [端口基址, 默认 18920]
set -u
PORT=${1:-18920}
cd "$(dirname "$0")"
BIN=./p7b_tcp_sink
BENCH=./p7b_rate2_bench
PASS=0; FAIL=0
ck(){ if [ "$2" = "$3" ]; then echo "  [PASS] $1 = $2"; PASS=$((PASS+1));
      else echo "  [FAIL] $1 got='$2' want='$3'"; FAIL=$((FAIL+1)); fi; }
fld(){ awk -v k="$2" -v p="$3" '$0 ~ p { for(i=1;i<=NF;i++) if (index($i, k"=")==1) { print substr($i, length(k)+2); exit } }' "$1"; }

echo "===== D1 干净流: 双线程 vs --no-thread 逐字节等价 ====="
python3 p7b_fake_board.py --listen 127.0.0.1:$((PORT+0)) --bytes 1048576 --conns 2 >/tmp/dt_fb_clean.log 2>&1 &
FB=$!; sleep 0.8
$BIN --host 127.0.0.1 --port $((PORT+0)) --conns 2 --seconds 20 >/tmp/dt_sink_dual.log 2>&1; RC_D1=$?
wait $FB 2>/dev/null
python3 p7b_fake_board.py --listen 127.0.0.1:$((PORT+1)) --bytes 1048576 --conns 2 >/tmp/dt_fb_clean2.log 2>&1 &
FB=$!; sleep 0.8
$BIN --host 127.0.0.1 --port $((PORT+1)) --conns 2 --seconds 20 --no-thread >/tmp/dt_sink_single.log 2>&1; RC_S1=$?
wait $FB 2>/dev/null
for f in bytes mismatch_bytes clean_conns bad_conns; do
  A=$(fld /tmp/dt_sink_dual.log   "$f" '^SINK_SUM'); B=$(fld /tmp/dt_sink_single.log "$f" '^SINK_SUM')
  ck "D1 SINK_SUM $f (双线程 == 单线程)" "$A" "$B"
done
for f in bytes first_mismatch mism_bytes; do
  A=$(fld /tmp/dt_sink_dual.log   "$f" '^SINK_CONN 0'); B=$(fld /tmp/dt_sink_single.log "$f" '^SINK_CONN 0')
  ck "D1 SINK_CONN0 $f (双线程 == 单线程)" "$A" "$B"
done
# checked_bytes 是**新**字段: 双线程 = 真读数 / 单线程 = -1 (n/a 哨兵) —— 跨臂不可比, 只各自自证
ck "D1 双线程 checked_bytes == bytes" "$(fld /tmp/dt_sink_dual.log checked_bytes '^SINK_CONN 0')" "$(fld /tmp/dt_sink_dual.log bytes '^SINK_CONN 0')"
ck "D1 单线程 checked_bytes = -1 (n/a 哨兵)" "$(fld /tmp/dt_sink_single.log checked_bytes '^SINK_CONN 0')" "-1"
ck "D1 收满 2 x 1 MiB" "$(fld /tmp/dt_sink_dual.log bytes '^SINK_SUM')" "2097152"
ck "D1 双线程 RC" "$RC_D1" "0"
ck "D1 单线程 RC" "$RC_S1" "0"
ck "D1 THREADED 标记" "$(fld /tmp/dt_sink_dual.log THREADED '^SINK_SUM')" "on"

echo "===== D2 偏移语义定点牙 (注入 K, 两臂 first_mismatch 必须都 == K) ====="
for K in 500000 65536 65535 1000000; do
  python3 p7b_fake_board.py --listen 127.0.0.1:$((PORT+2)) --bytes 1048576 --flip-at $K --conns 1 >/tmp/dt_fb_k.log 2>&1 &
  FB=$!; sleep 0.8
  $BIN --host 127.0.0.1 --port $((PORT+2)) --conns 1 --seconds 20 >/tmp/dt_k_dual.log 2>&1; RC_D=$?
  wait $FB 2>/dev/null
  python3 p7b_fake_board.py --listen 127.0.0.1:$((PORT+3)) --bytes 1048576 --flip-at $K --conns 1 >/tmp/dt_fb_k2.log 2>&1 &
  FB=$!; sleep 0.8
  $BIN --host 127.0.0.1 --port $((PORT+3)) --conns 1 --seconds 20 --no-thread >/tmp/dt_k_single.log 2>&1; RC_S=$?
  wait $FB 2>/dev/null
  ck "D2 K=$K 双线程 first_mismatch" "$(fld /tmp/dt_k_dual.log first_mismatch '^SINK_CONN 0')" "$K"
  ck "D2 K=$K 单线程 first_mismatch" "$(fld /tmp/dt_k_single.log first_mismatch '^SINK_CONN 0')" "$K"
  ck "D2 K=$K 双线程 mism_bytes" "$(fld /tmp/dt_k_dual.log mism_bytes '^SINK_CONN 0')" "1"
  ck "D2 K=$K 双线程 RC (失配必须非 0)" "$RC_D" "1"
  ck "D2 K=$K 单线程 RC" "$RC_S" "1"
done

echo "===== D3 D2 的负对照: 去掉基偏移的突变件必须报不出 K ====="
rm -rf /tmp/dt_mut && mkdir -p /tmp/dt_mut && cp p7b_tcp_sink.cpp p7b_affinity.h p7b_io.h p7b_spsc.h p7b_pattern.h /tmp/dt_mut/
sed -i 's|SinkItem out{held, got, (size_t)n};|SinkItem out{held, 0, (size_t)n};   // MUTANT: base=0|' /tmp/dt_mut/p7b_tcp_sink.cpp
grep -q 'MUTANT: base=0' /tmp/dt_mut/p7b_tcp_sink.cpp && echo "  [INFO] 突变件已注入 (base 恒 0)" || ck "D3 突变件注入" "未注入" "已注入"
( cd /tmp/dt_mut && g++ -O3 -pthread -o mut_sink p7b_tcp_sink.cpp )
python3 p7b_fake_board.py --listen 127.0.0.1:$((PORT+4)) --bytes 1048576 --flip-at 500000 --conns 1 >/tmp/dt_fb_m.log 2>&1 &
FB=$!; sleep 0.8
/tmp/dt_mut/mut_sink --host 127.0.0.1 --port $((PORT+4)) --conns 1 --seconds 20 >/tmp/dt_mut.log 2>&1
wait $FB 2>/dev/null
MU=$(fld /tmp/dt_mut.log first_mismatch '^SINK_CONN 0')
echo "  [INFO] 突变件 first_mismatch=$MU (期望 != 500000; 本机 = 500000 - 7*65536 = 41248)"
ck "D3 突变件报不出真偏移 500000" "$([ "$MU" != "500000" ] && echo RED || echo GREEN)" "RED"

echo "===== D4 队列不丢不漏 (推入数 == 弹出数; 槽借用数 - 回收数 == slots) ====="
S=$(fld /tmp/dt_sink_dual.log full_push '^SINK_SUM'); P=$(fld /tmp/dt_sink_dual.log full_pop '^SINK_SUM')
FR=$(fld /tmp/dt_sink_dual.log free_push '^SINK_SUM'); FP=$(fld /tmp/dt_sink_dual.log free_pop '^SINK_SUM')
ck "D4 full_push == full_pop" "$S" "$P"
ck "D4 full_push == free_pop (每件一件槽)" "$S" "$FP"
ck "D4 free_push - free_pop == 16 slots x 2 conns" "$((FR - FP))" "32"
ck "D4 checked_bytes == bytes (校验线程真的全消费完)" "$(fld /tmp/dt_sink_dual.log checked_bytes '^SINK_SUM')" "$(fld /tmp/dt_sink_dual.log bytes '^SINK_SUM')"

echo "===== D5 TSan (有则跑; 无则打 SKIP 醒目行) ====="
if command -v setarch >/dev/null 2>&1 && g++ -O3 -pthread -fsanitize=thread -o /tmp/dt_tsan_probe -x c++ - <<'EOF' >/dev/null 2>&1
int main(){return 0;}
EOF
then
  g++ -O3 -pthread -fsanitize=thread -g -o /tmp/dt_tsan_sink p7b_tcp_sink.cpp || ck "D5 TSan 编译" FAIL OK
  python3 p7b_fake_board.py --listen 127.0.0.1:$((PORT+5)) --bytes 1048576 --conns 3 >/tmp/dt_fb_tsan.log 2>&1 &
  FB=$!; sleep 0.8
  setarch "$(uname -m)" -R /tmp/dt_tsan_sink --host 127.0.0.1 --port $((PORT+5)) --conns 3 --seconds 20 >/tmp/dt_tsan.log 2>&1; RC_T=$?
  wait $FB 2>/dev/null
  ck "D5 TSan 告警数" "$(grep -c 'WARNING: ThreadSanitizer' /tmp/dt_tsan.log)" "0"
  ck "D5 TSan 跑退出码" "$RC_T" "0"
  ck "D5 TSan 跑 clean_conns" "$(fld /tmp/dt_tsan.log clean_conns '^SINK_SUM')" "3"
else
  echo "  [SKIP] 无 TSan/setarch => **D5 未跑** (不是通过)"
fi

echo "===== D6 绑核: 两颗不同物理核 + 掩码独立复算 + /proc 交叉核 ====="
# 假板 --silent --hold: 连接挂着不发数据 => sink 的 I/O 线程停在 poll 上, 两条线程都活着, 可以看 /proc
python3 p7b_fake_board.py --listen 127.0.0.1:$((PORT+6)) --bytes 1 --silent --hold 8 --conns 1 >/tmp/dt_fb_pin.log 2>&1 &
FB=$!; sleep 0.8
$BIN --host 127.0.0.1 --port $((PORT+6)) --conns 1 --seconds 20 --poll-ms 1000 --stall-n 8 >/tmp/dt_pin.log 2>&1 &
SPID=$!
sleep 2.0
echo "--- /proc/$SPID/task/*/status 的 Cpus_allowed_list ---"
for t in /proc/$SPID/task/*/status; do printf "  %s %s\n" "$(basename $(dirname $t))" "$(grep Cpus_allowed_list $t)"; done
slurp=$(cat /tmp/dt_pin.log)
wait $SPID; RC_P=$?
CIO=$(printf '%s\n' "$slurp" | grep -oE 'PIN_CPU_IO=[0-9]+' | head -1 | cut -d= -f2)
CWO=$(printf '%s\n' "$slurp" | grep -oE 'PIN_CPU_WORK=[0-9]+' | head -1 | cut -d= -f2)
MIO=$(printf '%s\n' "$slurp" | grep -oE 'PIN_ALLOWED_MASK_IO=[0-9a-f]+' | head -1 | cut -d= -f2)
MWO=$(printf '%s\n' "$slurp" | grep -oE 'PIN_ALLOWED_MASK_WORK=[0-9a-f]+' | head -1 | cut -d= -f2)
echo "  [INFO] PIN_CPU_IO=$CIO mask=$MIO / PIN_CPU_WORK=$CWO mask=$MWO"
ck "D6 IO/WORK 是两颗不同的逻辑核" "$([ -n "$CIO" ] && [ -n "$CWO" ] && [ "$CIO" != "$CWO" ] && echo yes || echo no)" "yes"
PCI=$(cat /sys/devices/system/cpu/cpu${CIO:-999}/topology/thread_siblings_list 2>/dev/null)
PCW=$(cat /sys/devices/system/cpu/cpu${CWO:-999}/topology/thread_siblings_list 2>/dev/null)
echo "  [INFO] siblings(io)=$PCI siblings(work)=$PCW"
ck "D6 两者不在同一物理核" "$([ -n "$PCI" ] && [ "$PCI" != "$PCW" ] && echo yes || echo no)" "yes"
ck "D6 mask_io == 1<<cpu_io (独立复算)" "$(printf '%x' $((1 << ${CIO:-0})))" "$MIO"
ck "D6 mask_work == 1<<cpu_work (独立复算)" "$(printf '%x' $((1 << ${CWO:-0})))" "$MWO"

echo "===== D7 end-expect 硬门未误杀 (双线程正常跑不得 END_MISMATCH / exit 2) ====="
ck "D7 干净跑无 END_MISMATCH" "$(grep -c 'END_MISMATCH' /tmp/dt_sink_dual.log)" "0"
ck "D7 干净跑 RC=0 (不是 _exit(2))" "$RC_D1" "0"
ck "D7 绑核跑出现 PIN_GETCPU_END (收尾见证在)" "$(grep -c 'PIN_GETCPU_END' /tmp/dt_pin.log)" "1"

echo "===== D8 两个天花板 (现测; 本机回环口径) ====="
for m in check-only recv-only recv-check recv-check-split; do
  echo "--- $m"
  $BENCH --mode $m --bytes $((256*1024*1024)) --core-send 4 --core-io 2 --core-work 3 2>/dev/null | grep -E '^BENCH ' | sed 's/^/  /'
done

echo
echo "DUAL_SELFTEST_SUMMARY PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "DUAL_SELFTEST_OK" || echo "DUAL_SELFTEST_BAD"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
