#!/bin/bash
REPO_ROOT="$(cd -- "$(dirname -- "$0")/../" && pwd)" || exit 1
if [ ! -f "$REPO_ROOT/CLAUDE.md" ]; then
  echo "[PATHGUARD FAIL] cannot locate this checkout from $0" >&2
  echo "  derived REPO_ROOT = $REPO_ROOT" >&2
  exit 1
fi
S=%REPO_ROOT%/sim
for c in dbg wnd fin abort evfifo reconn_fast reconn_slow multi len b2b findrop; do
  bash $S/adv_run4.sh $c
  sleep 3
done
echo "ADV ALL DONE"
