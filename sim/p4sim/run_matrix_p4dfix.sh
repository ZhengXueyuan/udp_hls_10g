#!/bin/bash
# ===========================================================================
# sim/p4sim/run_matrix_p4dfix.sh -- documented entry point for the P4
# default-build regression matrix (16 gates).
#
#   Thin SELF-LOCATING shim.  The real runner is a .bat
#   (sim/p4gates/run_matrix_p4dfix.bat) so that the 16 gates, the path guard
#   and the revision fingerprint all live on the Windows side and no
#   bash<->windows path translation is involved.  This file hardcodes NO
#   repository path: the root is derived from its own location
#   ($0/../..).  P4_REPO_ROOT is passed through so the guard can be exercised
#   with a deliberately wrong root (negative control A).
#
#   usage:  bash sim/p4sim/run_matrix_p4dfix.sh [/canonical]
#
#   history: until 2026-09-29 this script hardcoded
#     B=/d/repo/ECO/udp_hls_10g/sim/p4sim
#   so running it from this checkout compiled ANOTHER checkout and exited 0
#   ("empty gate", see P6B_INTEGRATION_REVIEW.md section 5).  The stale log it
#   left behind is kept as evidence in sim/p4gates/evidence/.
# ===========================================================================
set -u
HERE=$(cd -- "$(dirname -- "$0")" && pwd) || exit 1
ROOT=$(cd -- "$HERE/../.." && pwd) || exit 1
RUNNER="$ROOT/sim/p4gates/run_matrix_p4dfix.bat"
if [ ! -f "$RUNNER" ]; then
  echo "[P4GUARD FAIL] matrix runner not found: $RUNNER" >&2
  exit 1
fi
echo "[P4GATE] entry  : $0"
echo "[P4GATE] root   : $ROOT   (derived from this script's own location)"
echo "[P4GATE] runner : $RUNNER"
cd -- "$ROOT" || exit 1
# MSYS/git-bash rewrites any argument that looks like a POSIX path
# (/only -> C:/Program Files/Git/only), so a slash switch cannot survive as
# such; the runner accepts the dash spelling too (-only == /only).
ARGS=()
for a in "$@"; do
  case "$a" in
    /*) ARGS+=("-${a#/}") ;;
    *)  ARGS+=("$a") ;;
  esac
done
if [ ${#ARGS[@]} -eq 0 ]; then
  exec cmd //c 'sim\p4gates\run_matrix_p4dfix.bat'
fi
exec cmd //c 'sim\p4gates\run_matrix_p4dfix.bat' "${ARGS[@]}"
