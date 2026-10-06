#!/bin/bash
# s2_udp5.sh -- P7B-BIZ Stage 2: UDP 上行 5 段 (从给定 off 接力), 每段一次 snap
#   用法: bash /tmp/p7b_biz/s2_udp5.sh <start_off>
#   ⚠️ 板侧 UDP app LFSR 是一条全局连续序列 ⇒ off 必须接力, 否则 W13 必爆 (自伤)
set -u
cd /tmp/p7b_biz || exit 9
S=/tmp/p7b_biz/p7b_snap.sh
OFF=${1:-0}
echo "### INIT_OFF $OFF"

snapf(){ # snapf TAG  -> 只打关心的字 (含 W53..W60 新字)
  bash "$S" snap "$1" 0 1 3 4 10 11 12 13 20 21 32 33 34 35 36 37 43 46 47 48 49 53 54 55 56 60 \
    | grep -E "^W|SNAP_BEGIN|SNAP_END"
}

seg(){ local tag="$1"; shift
  echo "### SEG_SEND $tag off_in=$OFF $(date +%s.%N)"
  local out
  out=$(./p7b_udp_src --host 192.168.100.2 --port 8081 --paylen 1472 --off "$OFF" "$@")
  echo "$out"
  OFF=$(echo "$out" | sed -n 's/.*off_end=\([0-9]*\).*/\1/p' | tail -1)
  [ -n "$OFF" ] || { echo "S2_U5_ABORT 解析不到 off_end"; exit 1; }
  echo "### SEG_DONE $tag off_out=$OFF"
  snapf "S2_U5_$tag"
}

snapf S2_U5_p0
seg p1 --seconds 2.0 --mbps 2000 --batch 32
seg p2 --seconds 2.5 --mbps 0    --batch 32
seg p3 --seconds 2.5 --mbps 0    --batch 32
seg p4 --seconds 2.5 --mbps 0    --batch 128
seg p5 --seconds 2.0 --mbps 2000 --batch 32
echo "S2_UDP5_DONE $(date +%s.%N)"
