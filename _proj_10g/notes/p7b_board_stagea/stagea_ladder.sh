#!/bin/bash
# stagea_ladder.sh -- Stage A 阶梯驱动 (板侧, 对端机执行)
#   usage: BIT_SHA=... BIN=./p7b_tcp_src_fix bash stagea_ladder.sh <secs> "PACE TAG" ...
#   每跑: 全量 stdout 落 /tmp/p7b_stagea/run_<TAG>.txt; 屏幕只打紧凑摘要 (逐字读数仍在文件里)。
set -u
SECS=${1:-12}; shift
BINV=${BIN:-./p7b_tcp_src_fix}
BITV=${BIT_SHA:-n/a}
mkdir -p /tmp/p7b_stagea
for spec in "$@"; do
  set -- $spec
  PACE=$1; TAG=$2
  echo "==== RUN ${TAG} PACE=${PACE} BIN=${BINV} ===="
  BIT_SHA="$BITV" BIN="$BINV" PACE="$PACE" \
    bash /tmp/p7b_biz/j6_stagea.sh "$SECS" "/tmp/p7b_stagea/wu_stg_${TAG}.pcap" "STG_${TAG}" \
    > "/tmp/p7b_stagea/run_${TAG}.txt" 2>&1
  echo "rc_${TAG}=$?"
  grep -E "J6_GEOM|PACE_BPS|CARRIER=|SRC_SUM|SRC_RC|SRC_EOF|SNAP_BEGIN|SNAP_END|^W5 |^W53|^W54|^W61|^W62|TCPREG_ABORT|J6_GEOM_FAIL|J6META_BOARD_BID" \
    "/tmp/p7b_stagea/run_${TAG}.txt"
done
echo LADDER_DONE
