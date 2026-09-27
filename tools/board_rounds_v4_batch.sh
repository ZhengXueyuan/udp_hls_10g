#!/usr/bin/env bash
# board_rounds_v4_batch.sh -- the planned v4 board measurement batch.
#
# WHY these eight rounds and not fewer:
#   * the event FIFO records at most 8 events PER ROUND, so the pre-registered
#     ring-phase test (ISSUE §17.7) needs MANY rounds to reach ~50 samples.
#   * two rounds at the v3 size (8.39 MB) keep a direct like-for-like comparison with
#     the v3 baseline (the "instrument did not change the phenomenon" control:
#     II % paylen == 0, unique k == +paylen, integer n, OZ == n, same rate band).
#   * four larger rounds (16.78 MB) make n big enough that the FIFO fills every time.
#   * one paylen=512 round re-tests the displacement law ON THE SAME INSTRUMENT
#     (the v2 512-rounds came from a different bitstream, so that comparison was
#     confounded -- see ISSUE §16.11).
#   * one 32 MB round gives a long-run envelope with the sysmon min/max.
# Every round records sysmon (die temp + VCCINT/VCCAUX/VCCBRAM current/min/max),
# whose MIN/MAX latches reset on reconfiguration, so they bracket exactly that round.
set -u
cd /d/repo/ECO/udp_hls_10g || exit 1
BIT="${1:-wrapper_p4_diag_v4.bit}"
P=p5diag_verify/v4
mkdir -p "$P"

run () {   # $1=tag $2=bytes $3=frames $4=paylen
    echo "##################### $1 : $2 B @ ${4}B = $3 frames #####################"
    tools/board_round.sh "$BIT" "$P/$1" "$2" "$3" "$4"
    echo "  driver exit=$?"
}

run r01_8M_p1472      8388608  5699 1472
run r02_8M_p1472      8388608  5699 1472
run r03_16M_p1472    16777216 11398 1472
run r04_16M_p1472    16777216 11398 1472
run r05_16M_p1472    16777216 11398 1472
run r06_16M_p1472    16777216 11398 1472
run r07_8M_p512       8388608 16384  512
run r08_32M_p1472    33554432 22796 1472

echo "##################### 汇总判读 (一次生成图案, 全部轮次) #####################"
/c/Users/zhxue/anaconda3/python.exe tools/rxp_digest.py --window 200000 "$P"/*.line
