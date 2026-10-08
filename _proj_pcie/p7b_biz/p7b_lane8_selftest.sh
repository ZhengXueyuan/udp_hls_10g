#!/bin/bash
# p7b_lane8_selftest.sh -- M^8 lane-parallel 校验路径 (+ R2 的 CPU_FREQ_KHZ 语义订正) 的板外自检
#                          2026-10-09 (R1/R2/R4 轮)
#
# 为什么要有它 (全局纪律"每加一条判据配一个该被抓住的反例" + "注释不算证据"):
#   ① `check()` 的**默认路径是 seq** ⇒ 既有全部门 (p7b_selftest.sh T1–T8b /
#      p7b_dualthread_selftest.sh D1–D8) 跑的都是 seq —— **新路径不被任何既有判据覆盖**。
#   ② 两个新开关 (`--check=seq|lane8` 与"报告频率 = 工作线程自采样") 都有各自的**静默失效形态**:
#      * `--check=lane8` 传了没生效 ⇒ 看起来"新路径跑通了", 其实还是老路径 (读数一模一样, 无法从数值看出);
#      * 频率字段"看起来像在报运行频率" ⇒ 其实报的是**空闲主线程核**(800 MHz) —— 数值合法、字段名合法, 无人报警。
#   ⇒ 本门用**两条独立的手**把这两件事钉住: 前者用"注入已知失配 + 两臂逐字比", 后者用
#      **LD_PRELOAD 把指定核的 scaling_cur_freq 换成常数** (确定性、可独立复算 —— 不是
#      "看起来频率挺高"这种软判据)。
#
# 判据 (PASS/FAIL 逐条打; SKIP 是醒目行、**不算通过**):
#   L1  bench --selftest-equiv: PASS 且 RC=0
#   L2  sink  --selftest-equiv: PASS 且 RC=0
#   L3  长序列三全等 (n 非 8 对齐): 两路径 (first, mism, 末态) 相等 + 与构造函数快进 oracle 相等
#   L4  注入失配 6 点全 MATCH (含 0 / 非对齐 / 块首 / 块尾 / 尾段末字节 / 多字节)
#   L5  跨块连续性: 12 个块界 (含 8 的倍数与非倍数) 的中间态逐个 == `P7bPat(累计字节).s`
#   L6  表复核 (编译期常量表 vs 运行时独立重算) bad=0/4096
#   L7  突变负对照 M1 (砍掉尾段循环): 自检**必须翻红** (RC!=0 且有 MISMATCH)
#   L8  突变负对照 M2 (表里翻 1 位): 自检**必须翻红**
#   L9  端到端 A/B (回环假板干净流): seq 与 lane8 的 bytes/first_mismatch/mism_bytes/clean_conns 逐字相同
#   L10 端到端 A/B (假板翻 1 bit @500000): **两臂**都必须 first_mismatch=500000 / mism_bytes=1 / RC=1
#   L11 见证: SINK_SUM 的 `check=` 字段 == 传进去的模式 (两臂各一条)
#   L12 默认登记: 不带 --check 时 `check=seq` (默认 = 已上板验过的逐字节路径)
#   L13 未知模式必须**响亮**失败: `--check=bogus` ⇒ RC=2 (不许静默回落到默认)
#   L14 加速正证据 (非零可复算): check-only 的 lane8 Gbps 必须 > 1.5 × seq Gbps
#   L15 R2 正证据: 把**工作核**的 scaling_cur_freq 换成 8888000 ⇒ 报告 CPU_FREQ_KHZ == 8888000
#   L16 R2 负对照: 把**主线程核**换成 8888000 ⇒ PIN_FREQ_START_KHZ == 8888000 (注入活着, 自证)
#                   **且** CPU_FREQ_KHZ != 8888000 (报告**不是**打行那条线程的核 —— 旧语义已消除)
#
# 用法 (对端机): bash /tmp/p7b_biz/p7b_lane8_selftest.sh [端口基址, 默认 18960]
# ⛔ 全程只在回环口 (127.0.0.1) 跑; 不碰板子 / 不发板级流量 / 不写任何载荷到盘。
set -u
PORT=${1:-18960}
cd "$(dirname "$0")"
BIN=./p7b_tcp_sink
BENCH=./p7b_rate2_bench
PASS=0; FAIL=0; SKIP=0
ck(){ if [ "$2" = "$3" ]; then echo "  [PASS] $1 = $2"; PASS=$((PASS+1));
      else echo "  [FAIL] $1 got='$2' want='$3'"; FAIL=$((FAIL+1)); fi; }
fld(){ awk -v k="$2" -v p="$3" '$0 ~ p { for(i=1;i<=NF;i++) if (index($i, k"=")==1) { print substr($i, length(k)+2); exit } }' "$1"; }

WORK=/tmp/l8_selftest
mkdir -p $WORK

echo "===== L1/L2/L3/L4/L5/L6 seq vs lane8 逐位等价自检 (两件工具各跑一遍) ====="
$BENCH --selftest-equiv >$WORK/eq_bench.log 2>&1; RC_EB=$?
$BIN  --selftest-equiv >$WORK/eq_sink.log 2>&1;  RC_ES=$?
echo "--- bench 自检原文"
sed 's/^/  /' $WORK/eq_bench.log
ck "L1 bench --selftest-equiv 末行 PASS" "$(grep -c 'EQUIV p7b_rate2_bench: PASS (checks=10 fail=0)' $WORK/eq_bench.log)" "1"
ck "L1 bench --selftest-equiv RC" "$RC_EB" "0"
ck "L2 sink --selftest-equiv 末行 PASS"  "$(grep -c 'EQUIV p7b_tcp_sink: PASS (checks=10 fail=0)' $WORK/eq_sink.log)" "1"
ck "L2 sink --selftest-equiv RC" "$RC_ES" "0"
L3LINE=$(grep 'long n=' $WORK/eq_bench.log)
echo "  [INFO] L3 原始行: $L3LINE"
ck "L3 长序列行 MATCH" "$(printf '%s' "$L3LINE" | grep -c 'MATCH')" "1"
ck "L3 无失配 (first=-1, mism=0)" "$(printf '%s' "$L3LINE" | grep -c 'seq=(-1,0,')" "1"
ck "L3 三个末态 (seq / lane8 / ctor oracle) 逐字相同" \
   "$(printf '%s' "$L3LINE" | grep -oE '0x[0-9A-F]{16}' | sort -u | wc -l)" "1"
ck "L3 全表无 MISMATCH (两件工具)" "$(cat $WORK/eq_bench.log $WORK/eq_sink.log | grep -c MISMATCH)" "0"
ck "L4 注入失配 6 点全 MATCH" "$(grep -c 'inj\[' $WORK/eq_bench.log)" "6"
ck "L4 注入点都报出真偏移 (首字节=0)" "$(grep -c 'inj\[0\] 首字节 off=0 cnt=1 seq=(0,1) lane8=(0,1) state_eq=1 MATCH' $WORK/eq_bench.log)" "1"
ck "L5 跨块 12/12 中间态 == 独立快进 oracle" "$(grep -c 'xblk L=1048579 blocks=11 states=12/12' $WORK/eq_bench.log)" "1"
ck "L6 表复核 bad=0/4096" "$(grep -c 'table_rebuild bad=0/4096 want=0 MATCH' $WORK/eq_bench.log)" "1"

echo "===== L7/L8 负对照: 突变件上这条自检**必须翻红** (没有它 L1–L6 只是空话) ====="
rm -rf $WORK/mut1 $WORK/mut2 && mkdir -p $WORK/mut1 $WORK/mut2
cp p7b_pattern.h p7b_affinity.h p7b_io.h p7b_spsc.h p7b_rate2_bench.cpp $WORK/mut1/
cp p7b_pattern.h p7b_affinity.h p7b_io.h p7b_spsc.h p7b_rate2_bench.cpp $WORK/mut2/
# M1: 砍掉 lane8 的**尾段**循环 (经典漏改: 只处理 8 的整倍数) —— 只动 check_lane8 里那一条
sed -i 's|for (; i < n; i++) {|for (; 0; i++) {   // MUTANT M1: 尾段被砍|' $WORK/mut1/p7b_pattern.h
grep -q 'MUTANT M1' $WORK/mut1/p7b_pattern.h && echo "  [INFO] M1 已注入 (尾段循环被砍)" || ck "L7 M1 注入" "未注入" "已注入"
# M2: 表里翻 1 位 (单点数值错, 只有真跑数据流才碰得到)
sed -i 's|^    return t;$|    t.Tj[3][200] ^= 1;   // MUTANT M2\n    return t;|' $WORK/mut2/p7b_pattern.h
grep -q 'MUTANT M2' $WORK/mut2/p7b_pattern.h && echo "  [INFO] M2 已注入 (Tj[3][200] 翻 1 位)" || ck "L8 M2 注入" "未注入" "已注入"
( cd $WORK/mut1 && g++ -O3 -pthread -o bench_m1 p7b_rate2_bench.cpp ) || ck "L7 M1 编译" FAIL OK
( cd $WORK/mut2 && g++ -O3 -pthread -o bench_m2 p7b_rate2_bench.cpp ) || ck "L8 M2 编译" FAIL OK
$WORK/mut1/bench_m1 --selftest-equiv >$WORK/eq_m1.log 2>&1; RC_M1=$?
$WORK/mut2/bench_m2 --selftest-equiv >$WORK/eq_m2.log 2>&1; RC_M2=$?
echo "  [INFO] M1 突变件: RC=$RC_M1 MISMATCH 行=$(grep -c MISMATCH $WORK/eq_m1.log)"
grep 'MISMATCH' $WORK/eq_m1.log | sed 's/^/    /'
echo "  [INFO] M2 突变件: RC=$RC_M2 MISMATCH 行=$(grep -c MISMATCH $WORK/eq_m2.log)"
grep 'MISMATCH' $WORK/eq_m2.log | sed 's/^/    /'
ck "L7 M1 (砍尾段) 自检必须翻红" "$([ "$RC_M1" != "0" ] && [ "$(grep -c MISMATCH $WORK/eq_m1.log)" -ge 1 ] && echo RED || echo GREEN)" "RED"
ck "L8 M2 (表翻 1 位) 自检必须翻红" "$([ "$RC_M2" != "0" ] && [ "$(grep -c MISMATCH $WORK/eq_m2.log)" -ge 1 ] && echo RED || echo GREEN)" "RED"

echo "===== L9/L10/L11/L12/L13 开关端到端 (回环假板; 真 socket 读 => 真跨块) ====="
python3 p7b_fake_board.py --listen 127.0.0.1:$((PORT+0)) --bytes 1048576 --conns 2 >$WORK/fb_clean.log 2>&1 &
FB=$!; sleep 0.8
$BIN --host 127.0.0.1 --port $((PORT+0)) --conns 2 --seconds 20 --check seq  >$WORK/s_clean_seq.log 2>&1;  RC_CS=$?
wait $FB 2>/dev/null
python3 p7b_fake_board.py --listen 127.0.0.1:$((PORT+1)) --bytes 1048576 --conns 2 >$WORK/fb_clean2.log 2>&1 &
FB=$!; sleep 0.8
$BIN --host 127.0.0.1 --port $((PORT+1)) --conns 2 --seconds 20 --check lane8 >$WORK/s_clean_l8.log 2>&1;  RC_CL=$?
wait $FB 2>/dev/null
for f in bytes first_mismatch mism_bytes; do
  ck "L9 干净流 SINK_CONN0 $f (seq == lane8)" "$(fld $WORK/s_clean_seq.log $f '^SINK_CONN 0')" "$(fld $WORK/s_clean_l8.log $f '^SINK_CONN 0')"
done
for f in bytes clean_conns bad_conns mismatch_bytes; do
  ck "L9 干净流 SINK_SUM $f (seq == lane8)" "$(fld $WORK/s_clean_seq.log $f '^SINK_SUM')" "$(fld $WORK/s_clean_l8.log $f '^SINK_SUM')"
done
ck "L9 seq 臂 RC"  "$RC_CS" "0"
ck "L9 lane8 臂 RC" "$RC_CL" "0"

for ARM in seq lane8; do
  python3 p7b_fake_board.py --listen 127.0.0.1:$((PORT+2)) --bytes 1048576 --flip-at 500000 --conns 1 >$WORK/fb_flip_$ARM.log 2>&1 &
  FB=$!; sleep 0.8
  $BIN --host 127.0.0.1 --port $((PORT+2)) --conns 1 --seconds 20 --check $ARM >$WORK/s_flip_$ARM.log 2>&1; RC_F=$?
  wait $FB 2>/dev/null
  ck "L10 翻 1 bit 臂 $ARM first_mismatch" "$(fld $WORK/s_flip_$ARM.log first_mismatch '^SINK_CONN 0')" "500000"
  ck "L10 翻 1 bit 臂 $ARM mism_bytes"      "$(fld $WORK/s_flip_$ARM.log mism_bytes '^SINK_CONN 0')" "1"
  ck "L10 翻 1 bit 臂 $ARM RC (必须非 0)"   "$RC_F" "1"
  ck "L11 臂 $ARM 见证 check= 字段"         "$(fld $WORK/s_flip_$ARM.log check '^SINK_SUM')" "$ARM"
done
python3 p7b_fake_board.py --listen 127.0.0.1:$((PORT+3)) --bytes 262144 --conns 1 >$WORK/fb_def.log 2>&1 &
FB=$!; sleep 0.8
$BIN --host 127.0.0.1 --port $((PORT+3)) --conns 1 --seconds 20 >$WORK/s_default.log 2>&1
wait $FB 2>/dev/null
ck "L12 不带 --check 时默认 = seq (已上板验过的路径)" "$(fld $WORK/s_default.log check '^SINK_SUM')" "seq"
$BIN --host 127.0.0.1 --port $((PORT+3)) --conns 1 --seconds 2 --check bogus >$WORK/s_bogus.log 2>&1; RC_B=$?
ck "L13 未知 --check 值必须响亮退出 (RC=2)" "$RC_B" "2"
ck "L13 未知值不许静默回落 (输出里没有 SINK_SUM)" "$(grep -c '^SINK_SUM' $WORK/s_bogus.log)" "0"

echo "===== L14 加速正证据: check-only 两臂 (同一台机同会话) ====="
$BENCH --mode check-only --bytes $((512*1024*1024)) --check seq   >$WORK/co_seq.log 2>&1
$BENCH --mode check-only --bytes $((512*1024*1024)) --check lane8 >$WORK/co_l8.log 2>&1
G_SEQ=$(fld $WORK/co_seq.log  Gbps '^BENCH check-only')
G_L8=$(fld  $WORK/co_l8.log   Gbps '^BENCH check-only')
grep '^BENCH check-only' $WORK/co_seq.log | sed 's/^/  /'
grep '^BENCH check-only' $WORK/co_l8.log  | sed 's/^/  /'
echo "  [INFO] 加速比 = $(awk -v a="$G_L8" -v b="$G_SEQ" 'BEGIN{printf "%.3fx", a/b}')"
ck "L14 check-only seq first_mismatch=-1 / mism=0" "$(fld $WORK/co_seq.log first_mismatch '^BENCH check-only')$(fld $WORK/co_seq.log mism_bytes '^BENCH check-only')" "-10"
ck "L14 check-only lane8 first_mismatch=-1 / mism=0" "$(fld $WORK/co_l8.log first_mismatch '^BENCH check-only')$(fld $WORK/co_l8.log mism_bytes '^BENCH check-only')" "-10"
ck "L14 两臂 check= 见证" "$(fld $WORK/co_seq.log check '^BENCH')$(fld $WORK/co_l8.log check '^BENCH')" "seqlane8"
ck "L14 lane8 > 1.5 x seq (加速是**非零正证据**)" "$(awk -v a="$G_L8" -v b="$G_SEQ" 'BEGIN{print (a > 1.5*b) ? "yes":"no"}')" "yes"

echo "===== L15/L16 R2: 报告频率必须来自**干活的线程** (LD_PRELOAD 把指定核换成常数) ====="
if [ ! -f ./p7baff_faultinject.cpp ]; then
  echo "  [SKIP] 本机没有 p7baff_faultinject.cpp ⇒ **L15/L16 未跑** (不是通过)"
  SKIP=$((SKIP+2))
else
  g++ -shared -fPIC -O2 -o $WORK/libp7baff_faultinject.so ./p7baff_faultinject.cpp 2>/dev/null
  echo 8888000 > $WORK/freq8888000
  INJ="$WORK/libp7baff_faultinject.so"
  BCH_ARGS="--bytes $((256*1024*1024)) --core 5 --core-send 4 --core-io 2 --core-work 3"
  # --- L15 正证据: 把**工作核 cpu3**的频率换成 8888000 => 报告必须 == 8888000
  LD_PRELOAD=$INJ P7BAFF_MAP_FROM=/sys/devices/system/cpu/cpu3/cpufreq/scaling_cur_freq \
    P7BAFF_MAP_TO=$WORK/freq8888000 \
    $BENCH --mode recv-check-split $BCH_ARGS --check lane8 >$WORK/r2_work.log 2>&1
  grep '^BENCH recv-check-split' $WORK/r2_work.log | sed 's/^/  /'
  ck "L15 注入了 job核 (cpu3) 的假频率" "$(grep -c '8888000' $WORK/freq8888000)" "1"
  ck "L15 报告 CPU_FREQ_KHZ == 工作核的假值 8888000" \
     "$(fld $WORK/r2_work.log CPU_FREQ_KHZ '^BENCH recv-check-split')" "8888000"
  # --- L16 负对照: 把**主线程核 cpu5**换成 8888000 => 注入活着(PIN_FREQ_START 自证) 但报告**不得**用它
  LD_PRELOAD=$INJ P7BAFF_MAP_FROM=/sys/devices/system/cpu/cpu5/cpufreq/scaling_cur_freq \
    P7BAFF_MAP_TO=$WORK/freq8888000 \
    $BENCH --mode recv-check-split $BCH_ARGS --check lane8 >$WORK/r2_main.log 2>&1
  grep '^BENCH recv-check-split' $WORK/r2_main.log | sed 's/^/  /'
  ck "L16 注入确实生效 (主线程 PIN_FREQ_START_KHZ == 8888000)" \
     "$(grep -oE 'PIN_FREQ_START_KHZ=[0-9]+' $WORK/r2_main.log | head -1 | cut -d= -f2)" "8888000"
  ck "L16 报告**不是**主线程核的值 (旧语义已消除)" \
     "$([ "$(fld $WORK/r2_main.log CPU_FREQ_KHZ '^BENCH recv-check-split')" != "8888000" ] && echo not_idle_core || echo idle_core)" "not_idle_core"
fi

echo
echo "LANE8_SELFTEST_SUMMARY PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] && echo "LANE8_SELFTEST_OK" || echo "LANE8_SELFTEST_BAD"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
