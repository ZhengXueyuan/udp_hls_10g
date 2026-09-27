#!/usr/bin/env bash
# board_rounds_v6_batch.sh -- the v6 board run. Short by design.
#
# WHY two rounds: v6 answers ONE binary question (ISSUE §18.14). The v6 verifier sits on
# the PREFETCH INPUT (upstream of udp_rx), while v5's sits on the u_uf write data port
# (din). The chain is mac_rx_64 -> rx_classify -> vlan_strip -> udp_split.u_pre -> udp_rx
# -> u_uf, and every module except u_pre's input is now instrumented:
#
#   CZ=0 (input side clean) + din corrupt  -> reorder happens INSIDE u_pre or udp_rx
#                                             (prime suspect: udp_split_fifo's LUTRAM
#                                             read semantics / full-empty flags -- this
#                                             project already has a board-only incidence:
#                                             "RAMB18E1 side-store drops tlast on the board,
#                                             unit TB cannot see it")
#   CZ=1 (input side also corrupt)         -> mac_rx_64 / rx_classify / vlan_strip, and the
#                                             "no frame-capable store up there" argument
#                                             must be re-examined with that counterexample
#
# PRECONDITION, TWO parts:
#   * CS == 0 -- the v6 engine is 1 word / 2 cycles and the input side CANNOT be
#     backpressured, so a full skid DROPS words. CS is the drop counter; non-zero means
#     the v6 reading is a self-inflicted artifact that would otherwise look like
#     "input side clean". (1G = 1 word / 8 cycles, so 4x margin -- but verify, don't assume.)
#   * WF == 0 -- v6 counts every payload byte ARRIVING at udp_split, v5 counts those
#     actually WRITTEN into u_uf; the two anchors only coincide when nothing was dropped.
#     CO/CG/CE are index-free and comparable unconditionally.
set -u
cd /d/repo/ECO/udp_hls_10g || exit 1
BIT="${1:-wrapper_p4_diag_v6.bit}"
P=p5diag_verify/v6
mkdir -p "$P"

run () {   # $1=tag $2=bytes $3=frames $4=paylen
    echo "##################### $1 : $2 B @ ${4}B = $3 frames #####################"
    tools/board_round.sh "$BIT" "$P/$1" "$2" "$3" "$4"
    echo "  driver exit=$?"
}

run r01_8M_p1472   8388608  5699 1472
run r02_8M_p1472   8388608  5699 1472

echo "##################### 汇总判读 #####################"
/c/Users/zhxue/anaconda3/python.exe tools/rxp_digest.py --window 200000 "$P"/*.line
