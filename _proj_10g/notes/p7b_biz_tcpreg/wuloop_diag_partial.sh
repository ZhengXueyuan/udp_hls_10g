#!/bin/bash
# wuloop_diag_partial.sh -- 诊断跑 (非基线): 量 p7b_tcp_src 的**部分发送**次数与跳字节数
#   动机: 基线跑里 W54 (app_pattern.stat_mismatch) 非 0 (2.1-2.4M), 而 J12 的 64 KB 跑 ΔW54=0。
#   候选机理 A (工具侧): `tx.fill(sbuf,chunk)` 每拍把图案**推进整 chunk**, 而 send() 非阻塞
#   时可只收 n<chunk => 线上图案流**内部跳 (chunk-n) 字节** => 板侧连续 LFSR 永久失步。
#   本跑用**带计数器的变体二进制** p7b_tcp_src_diag (与 p7b_tcp_src 唯一区别 = 多打三个字段),
#   若 partial_sends>0 且 skip_bytes>0 => 机理 A 成立 (板侧 mismatch 至少部分由工具造成)。
#   用法: BIT_SHA=... PACE=<bps> [BIN=./p7b_tcp_src_fix] bash wuloop_diag_partial.sh <secs> <tag>
set -u
SECS=${1:-6}; TAG=${2:-WU_DIAG}
S=/tmp/p7b_biz/p7b_snap.sh
BIN=${BIN:-./p7b_tcp_src_diag}
cd /tmp/p7b_biz || exit 9
PACE=${PACE:-0}
if [ "$PACE" != "0" ]; then EXTRA="--pace-bps $PACE"; else EXTRA=""; fi
echo "### DIAG_BEGIN $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "DIAG_TOOL=$BIN DIAG_TOOL_MD5=$(md5sum $BIN | cut -d' ' -f1)"
echo "DIAG_SCRIPT_MD5=$(md5sum "$0" | cut -d' ' -f1)"
echo "DIAG_BIT_SHA=${BIT_SHA:-n/a}"
echo "PACE_BPS=$PACE"
bash "$S" snap "${TAG}_pre" 0 1 22 53 54 55 || exit 1
$BIN --host 192.168.100.2 --port 8080 --seconds "$SECS" $EXTRA
sleep 2
bash "$S" snap "${TAG}_post" 0 1 22 53 54 55 || exit 1
echo "DIAG_DONE $(date -u +%Y-%m-%dT%H:%M:%SZ)"
