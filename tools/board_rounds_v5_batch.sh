#!/usr/bin/env bash
REPO_ROOT="$(cd -- "$(dirname -- "$0")/../" && pwd)" || exit 1
if [ ! -f "$REPO_ROOT/CLAUDE.md" ]; then
  echo "[PATHGUARD FAIL] cannot locate this checkout from $0" >&2
  echo "  derived REPO_ROOT = $REPO_ROOT" >&2
  exit 1
fi
# board_rounds_v5_batch.sh -- the v5 board run. Deliberately SHORT.
#
# WHY only three rounds: v5 exists to answer ONE binary question (ISSUE §18.12):
#   does the din-side byte-serial LFSR verifier see the corruption?
#     VZ=1 and DV==II and DM==UMM  -> both mechanisms agree, the corruption is at/before din
#     VZ=0 while the app reports   -> SW was mis-attributed, the corruption is created
#                                     between din and the app (u_uf / read path)
# That is answered by a single round; two more are redundancy plus one larger round so
# the FIFO-based fields have bigger counts. (The v4 batch needed 8 rounds only because the
# event FIFO caps at 8 entries per round and the ring-phase test wanted >=50 samples.)
#
# Every round records sysmon (die temp + VCCINT/VCCAUX/VCCBRAM current/min/max); its
# MIN/MAX latches reset on reconfiguration so they bracket exactly that round.
#
# PRECONDITION for the DV/DM comparisons: RL==0 && WF==0 (verified in gate phase W7:
# with RL=4 the din verifier reports dm=0 because rollback only moves pointers and does
# not rewrite the byte stream). tools/rxp_digest.py enforces this and marks the section
# UNUSABLE otherwise.
set -u
cd %REPO_ROOT% || exit 1
BIT="${1:-wrapper_p4_diag_v5.bit}"
P=p5diag_verify/v5
mkdir -p "$P"

run () {   # $1=tag $2=bytes $3=frames $4=paylen
    echo "##################### $1 : $2 B @ ${4}B = $3 frames #####################"
    tools/board_round.sh "$BIT" "$P/$1" "$2" "$3" "$4"
    echo "  driver exit=$?"
}

run r01_8M_p1472   8388608  5699 1472
run r02_8M_p1472   8388608  5699 1472
run r03_16M_p1472 16777216 11398 1472

echo "##################### 汇总判读 #####################"
/c/Users/zhxue/anaconda3/python.exe tools/rxp_digest.py --window 200000 "$P"/*.line
