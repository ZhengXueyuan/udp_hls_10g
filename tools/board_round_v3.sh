#!/usr/bin/env bash
REPO_ROOT="$(cd -- "$(dirname -- "$0")/../" && pwd)" || exit 1
if [ ! -f "$REPO_ROOT/CLAUDE.md" ]; then
  echo "[PATHGUARD FAIL] cannot locate this checkout from $0" >&2
  echo "  derived REPO_ROOT = $REPO_ROOT" >&2
  exit 1
fi
# board_round_v3.sh -- one complete RXP measurement round, gate enforced.
#
#   program (== reset, mandatory) -> load pattern at line rate -> read the 637-char
#   status line -> run the precondition gate -> classify.
#
# WHY a single driver: every step here has bitten us.
#   * reprogramming is the ONLY reset (the app RX LFSR never resyncs, counters sticky)
#   * the program step must run from the RETAINED bitstream copy (a concurrent build
#     deletes the project-owned .bit and the program silently no-ops -> garbage round)
#   * a round is only interpretable AFTER the precondition gate passes
# so the steps are chained and any failure aborts the round instead of yielding numbers.
#
# usage: tools/board_round_v3.sh <bitfile-in-keep> <out.line> [sent-bytes] [sent-frames]
set -u
REPO=%REPO_ROOT%
PY=/c/Users/zhxue/anaconda3/python.exe
IFACE='\Device\NPF_{528A3E8C-9A80-4D17-96A0-48F3FD70186E}'
SRC_MAC='FC:9D:05:7D:88:6B'
BIT="${1:?usage: board_round_v3.sh <bitfile-in-keep> <out.line> [bytes] [frames]}"
OUT="${2:?missing out.line}"
BYTES="${3:-8388608}"
FRAMES="${4:-5699}"
PAYLEN=1472

cd "$REPO" || exit 1
echo "=== [1/4] program (reset) : $BIT ==="
cmd //c '%REPO_ROOT%\board\run_program_p5_keep.bat' "$BIT" >/tmp/round_prog.out 2>&1
if [ $? -ne 0 ]; then
    echo "!! PROGRAM GATE FAILED -- round aborted, no reading taken"
    tail -4 /tmp/round_prog.out
    exit 1
fi
echo "    ok (PROGRAM_OK)"

echo "=== [2/4] load pattern: $BYTES B / ${PAYLEN} B frames = $FRAMES ==="
./tools/cpp_peer/peer.exe --iface "$IFACE" --src-mac "$SRC_MAC" \
    --sport 8081 --dport 8081 \
    --udp-send-pattern "$BYTES" --udp-paylen "$PAYLEN" --rate-mbps 0 \
    >/tmp/round_peer.out 2>&1
grep -E "^VERDICT|^TX  |^RX  " /tmp/round_peer.out | sed 's/^/    /'

echo "=== [3/4] read status line ==="
"$PY" tools/board_p5b_check.py --port COM9 --lines 8 >/tmp/round_read.out 2>&1
LINE=$(grep -m1 '^P5B1 ' /tmp/round_read.out)
if [ -z "$LINE" ]; then
    echo "!! no P5B1 line on COM9 -- round aborted"
    tail -5 /tmp/round_read.out
    exit 1
fi
printf '%s\n' "$LINE" > "$OUT"
echo "    saved -> $OUT  (${#LINE} chars)"

echo "=== [4/4] precondition gate ==="
"$PY" tools/rxp_round_check.py --line "$LINE" --sent-bytes "$BYTES" --sent-frames "$FRAMES"
RC=$?
if [ $RC -ne 0 ]; then
    echo "!! GATE FAILED (exit $RC) -- do NOT draw conclusions from this round"
    exit $RC
fi
echo
echo "=== classify ==="
"$PY" tools/rxp_classify.py --line "$LINE"
