#!/bin/bash
# ===========================================================================
# sim/p4indm/run_4gates.sh -- documented (git-bash) entry point for the
#   P4IDNM 4-gate re-run: pcackoob / vlanchain / vlanburst / stallgate.
#
#   Thin SELF-LOCATING shim onto sim/p4indm/run_4gates.bat: the gate itself,
#   its guards and its exit code all live on the Windows side, so no
#   bash<->windows path translation is involved and a stray "%VAR%" cannot
#   turn every path into a literal string again.
#
#   usage:  bash sim/p4indm/run_4gates.sh
#
#   history: until 2026-09-30 this file WAS the gate, written in cmd syntax
#   (%REPO_ROOT%) inside a bash script => under bash no variable ever
#   expanded, `cd` failed, not one gate ran, and the script still exited 0.
#   See _proj_10g/notes/P7B_GATE_HARNESS_FIX.md.
# ===========================================================================
set -u
HERE=$(cd -- "$(dirname -- "$0")" && pwd) || exit 1
RUNNER="$HERE/run_4gates.bat"
if [ ! -f "$RUNNER" ]; then
  echo "[PATHGUARD FAIL] gate runner not found: $RUNNER" >&2
  exit 1
fi
echo "[P4INDM] entry  : $0"
echo "[P4INDM] root   : $(cd -- "$HERE/../.." && pwd)   (derived from this script's own location)"
echo "[P4INDM] runner : $RUNNER"
cd -- "$HERE/../.." || exit 1
exec cmd //c 'sim\p4indm\run_4gates.bat'
