#!/bin/bash
# stageb_ladder.sh -- Stage B 阶梯驱动 (板侧, 对端机执行) —— 逐字继承 stagea_ladder.sh,
#   只有两处不同: ① 落盘目录 /tmp/p7b_stageb ② 每跑前后加 CPU 采样 (判"对端单核是否成为限制")
#   usage: BIT_SHA=... BIN=./p7b_tcp_src_fix bash stageb_ladder.sh <secs> "PACE TAG" ...
#
#   ⛔ 2026-10-07 (P7B StB 判据修正轮) 回卷 (只登记, 不改读数/不改本脚本行为):
#     12 s 窗内**字节类计数器 >2.863 Gbps 必回卷** (实测 ΔW53_raw vs tx_bytes, P7B_BOARD_STAGEB.md §2.3(a))。
#     本脚本打印的 `^W5/^W53/^W54/^W61` 都是**原始寄存器值** (要求如此, 别删); 差值/比率一律
#     由解析器按 `mod 2^32 + k·2^32` 还原, 见 P7B_STAGEB_CRITERIA_FIX.md §①。
#     `SECS` 上限 = 17 s (W5/W24 自由计数 27.487 s 回绕 ⇒ pre→post 窗 ≈ SECS+10 s)。
set -u
SECS=${1:-12}; shift
BINV=${BIN:-./p7b_tcp_src_fix}
BITV=${BIT_SHA:-n/a}
mkdir -p /tmp/p7b_stageb
for spec in "$@"; do
  set -- $spec
  PACE=$1; TAG=$2
  echo "==== RUN ${TAG} PACE=${PACE} BIN=${BINV} ===="
  # CPU 采样: 本跑窗口内 8 核占用 (每 1 s) + 采样器进程留证
  ( for i in $(seq 1 $((SECS+14))); do
      echo "CPU_T $(date +%s.%N) $(LC_ALL=C top -bn1 | grep -E '^%Cpu|^ *[0-9]+ a ' | head -3 | tr '\n' '|')"
      sleep 1
    done > "/tmp/p7b_stageb/cpu_${TAG}.log" 2>&1 & )
  ( for i in $(seq 1 $((SECS+14))); do
      echo "PID_T $(date +%s.%N) $(ps -eo pid,pcpu,comm --sort=-pcpu | head -4 | tr '\n' '|')"
      sleep 1
    done > "/tmp/p7b_stageb/ps_${TAG}.log" 2>&1 & )
  BIT_SHA="$BITV" BIN="$BINV" PACE="$PACE" \
    bash /tmp/p7b_biz/j6_stagea.sh "$SECS" "/tmp/p7b_stageb/wu_stg_${TAG}.pcap" "STB_${TAG}" \
    > "/tmp/p7b_stageb/run_${TAG}.txt" 2>&1
  echo "rc_${TAG}=$?"
  grep -E "J6_GEOM|PACE_BPS|CARRIER=|SRC_SUM|SRC_RC|SRC_EOF|SNAP_BEGIN|SNAP_END|^W5 |^W53|^W54|^W61|^W62|TCPREG_ABORT|J6_GEOM_FAIL|J6META_BOARD_BID" \
    "/tmp/p7b_stageb/run_${TAG}.txt" | head -30
  # tcpdump 自己的丢包统计 (高pps 下台架可能丢包 ⇒ 必须看)
  echo "--- tcpdump log ${TAG}: $(tail -3 /tmp/tcpdump_STB_${TAG}.log 2>/dev/null | tr '\n' ' ')"
done
echo LADDER_DONE
