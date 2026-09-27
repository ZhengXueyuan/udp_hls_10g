#!/usr/bin/env bash
# board_rounds_v7_batch.sh -- the v7 board run.
#
# THE QUESTION (ISSUE §18.17): was the frame ORDER on the wire permuted, or is the
# board's RX path responsible?
#   * peer's IP identification is +1 per frame (capture-verified: 0x0001,0x0002,0x0003...)
#   * IW = count of frames whose ID went BACKWARD (id < prev). This is the decisive one:
#       other IP frames (ICMP etc.) also consume peer's ID space, so a FORWARD jump
#       (IV-IW) is ambiguous -- but a BACKWARD jump cannot be produced that way.
#   * IA/IB = the first violation's {this ID, prev ID}; IS = frames through the match gate
#     (board-side identity: IS == PS + DC).
#
#   IW > 0 and ~= the number of corrupted frames -> the WIRE order was permuted
#                                                  -> root cause is the PC-side NIC/driver,
#                                                     the board is exonerated
#   IW == 0                                    -> the wire order is intact
#                                                  -> points at IFG / preamble receive margin
#                                                     at minimum frame spacing (PHY/GMII)
#
# WHY the low-rate rounds: the corruption is rate-dependent and VANISHES at 100 Mbps
# (§18.16). So IV/IW must be measured at several rates to see whether the ordering
# violation tracks the corruption. The 100 Mbps round additionally tests task B's
# prediction in the falsifiable form NB==560 && CM==0 (the 560 non-UDP tail bytes that
# v6 used to mis-count as payload now land in NB instead).
set -u
cd /d/repo/ECO/udp_hls_10g || exit 1
BIT="${1:-wrapper_p4_diag_v7.bit}"
P=p5diag_verify/v7
mkdir -p "$P"

run () {   # $1=tag $2=bytes $3=frames $4=paylen $5=rate-mbps
    echo "##################### $1 : $2 B @ ${4}B, rate=${5} #####################"
    RATE="$5" tools/board_round.sh "$BIT" "$P/$1" "$2" "$3" "$4"
    echo "  driver exit=$?"
}

run r01_line_p1472  8388608 5699 1472 0
run r02_line_p1472  8388608 5699 1472 0
run r03_500M_p1472  8388608 5699 1472 500
run r04_100M_p1472  8388608 5699 1472 100

echo "##################### 汇总判读 #####################"
/c/Users/zhxue/anaconda3/python.exe tools/rxp_digest.py --window 200000 "$P"/*.line
