#!/usr/bin/env bash
REPO_ROOT="$(cd -- "$(dirname -- "$0")/../" && pwd)" || exit 1
if [ ! -f "$REPO_ROOT/CLAUDE.md" ]; then
  echo "[PATHGUARD FAIL] cannot locate this checkout from $0" >&2
  echo "  derived REPO_ROOT = $REPO_ROOT" >&2
  exit 1
fi
# board_round.sh -- one complete RXP measurement round, gate enforced, sysmon recorded.
#
#   program (== reset, mandatory) -> load pattern at line rate -> read the status line
#   -> read the on-chip sysmon (die temp + rails, incl. min/max) -> precondition gate -> classify
#
# WHY a single driver: every step here has bitten us.
#   * reprogramming is the ONLY reset (the app RX LFSR never resyncs, counters sticky)
#   * the program step must run from the RETAINED bitstream copy (a concurrent build
#     deletes the project-owned .bit and the program silently no-ops -> garbage round)
#   * a round is only interpretable AFTER the precondition gate passes
#   * the XADC MIN/MAX latches reset on reconfiguration, so reading them right after the
#     round brackets exactly that round's thermal/voltage envelope -- which matters because
#     the corruption rate drifts ~24x between rounds and the droop exclusion in the doc
#     was admitted to be pure inference (no measurement channel).
# so the steps are chained and any failure aborts the round instead of yielding numbers.
#
# usage: tools/board_round.sh <bitfile-in-keep> <out-prefix> [sent-bytes] [sent-frames] [paylen]
#   writes <out-prefix>.line  (status line)  and  <out-prefix>.sm  (sysmon line)
set -u
REPO=%REPO_ROOT%
PY=/c/Users/zhxue/anaconda3/python.exe
VIVADO='C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat'
IFACE='\Device\NPF_{528A3E8C-9A80-4D17-96A0-48F3FD70186E}'
SRC_MAC='FC:9D:05:7D:88:6B'
BIT="${1:?usage: board_round.sh <bitfile-in-keep> <out-prefix> [bytes] [frames] [paylen]}"
OUT="${2:?missing out-prefix}"
BYTES="${3:-8388608}"
FRAMES="${4:-5699}"
PAYLEN="${5:-1472}"
# Vivado log must not collide with a tool's own default log name (xvlog.log et al),
# and -log must precede -tclargs (that flag is greedy and would swallow it).
SMLOG="$REPO/vivado_sysmon.log"

cd "$REPO" || exit 1
echo "=== [1/5] program (reset) : $BIT ==="
cmd //c '%REPO_ROOT%\board\run_program_p5_keep.bat' "$BIT" >/tmp/round_prog.out 2>&1
if [ $? -ne 0 ]; then
    echo "!! PROGRAM GATE FAILED -- round aborted, no reading taken"
    tail -4 /tmp/round_prog.out
    exit 1
fi
echo "    ok (PROGRAM_OK)"

echo "=== [2/5] load pattern: $BYTES B / paylen $PAYLEN = $FRAMES frames ==="
./tools/cpp_peer/peer.exe --iface "$IFACE" --src-mac "$SRC_MAC" \
    --sport 8081 --dport 8081 \
    --udp-send-pattern "$BYTES" --udp-paylen "$PAYLEN" --rate-mbps "${RATE:-0}" \
    >/tmp/round_peer.out 2>&1
grep -E "^VERDICT|^TX  |^RX  " /tmp/round_peer.out | sed 's/^/    /'

echo "=== [3/5] read status line ==="
"$PY" tools/board_p5b_check.py --port COM9 --lines 8 >/tmp/round_read.out 2>&1
LINE=$(grep -m1 '^P5B1 ' /tmp/round_read.out)
if [ -z "$LINE" ]; then
    echo "!! no P5B1 line on COM9 -- round aborted"
    tail -5 /tmp/round_read.out
    exit 1
fi
printf '%s\n' "$LINE" > "$OUT.line"
echo "    saved -> $OUT.line  (${#LINE} chars)"

echo "=== [4/5] read sysmon (die temp + rails, this round's envelope) ==="
# ⚠️ MUST go through the .bat with SINGLE quotes. Passing the command line inline
# with double quotes + variable expansion let MSYS2 mangle it, which silently failed
# on all 8 rounds on 2026-09-27 (same root cause as the documented pit).
cmd //c '%REPO_ROOT%\board\run_sysmon.bat' >/dev/null 2>&1
SM=$(grep -m1 '^SYSMON T=' "$SMLOG" 2>/dev/null | tr -d '\r')
if [ -z "$SM" ]; then
    echo "    !! sysmon read failed (no SYSMON line) -- recording NA"
    SM="SYSMON NA"
fi
printf '%s\n' "$SM" > "$OUT.sm"
echo "    $SM"

echo "=== [5/5] precondition gate ==="
"$PY" tools/rxp_round_check.py --line "$LINE" --sent-bytes "$BYTES" --sent-frames "$FRAMES" --paylen "$PAYLEN"
RC=$?
if [ $RC -ne 0 ]; then
    echo "!! GATE FAILED (exit $RC) -- do NOT draw conclusions from this round"
    exit $RC
fi
echo
echo "=== classify ==="
"$PY" tools/rxp_classify.py --line "$LINE" --paylen "$PAYLEN"
