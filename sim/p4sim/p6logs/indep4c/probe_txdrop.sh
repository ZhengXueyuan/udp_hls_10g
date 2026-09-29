#!/bin/bash
REPO_ROOT="$(cd -- "$(dirname -- "$0")/../../../../" && pwd)" || exit 1
if [ ! -f "$REPO_ROOT/CLAUDE.md" ]; then
  echo "[PATHGUARD FAIL] cannot locate this checkout from $0" >&2
  echo "  derived REPO_ROOT = $REPO_ROOT" >&2
  exit 1
fi
# P4c 独立复跑附加判别实验: TXDROP 注入落点是否随索引变化 (机制 = "arm 后第一个 S_PRE 的帧被遮")
# 逐一串行跑 (共用目录, 不可并行): TXDROP=51 与 TXDROP=2, 记录 exit/md5/ACK 事件, 归档 resp。
cd %REPO_ROOT%/sim/p4sim || exit 1
D=%REPO_ROOT%/sim/p4sim/p6logs/indep4c
: > "$D/probe_summary.txt"
one() {
  tag="$1"; idx="$2"
  rm -f trunc.memh halfdrop.memh txdrop.memh
  {
    echo "=================================================================="
    echo "### $tag :: TXDROP=$idx"
    t0=$(date +%s)
    cmd //c "%REPO_ROOT%\sim\p4sim\run_tb_p4_burst.bat 200 -1 0 4000 0 0 $idx" > "$D/$tag.txt" 2>&1
    rc=$?
    t1=$(date +%s)
    echo "### EXIT=$rc dur=$((t1-t0))s"
    if [ -f resp_p4_chain.memh ]; then
      echo "### resp md5: $(md5sum resp_p4_chain.memh | cut -c1-32) size=$(stat -c %s resp_p4_chain.memh)"
      cp -f resp_p4_chain.memh "$D/${tag}_resp.memh"
    fi
    iconv -f GBK -t UTF-8 "$D/$tag.txt" 2>/dev/null \
      | grep -aE "BURST OK|BURST FAIL|MISMATCH|洞|RETX|STATS7|STATS_TX|^STATS_MAC|TCBF"
  } >> "$D/probe_summary.txt" 2>&1
  echo "[$tag idx=$idx] rc=$rc dur=$((t1-t0))s" >> "$D/probe_progress.txt"
}
: > "$D/probe_progress.txt"
one 19_txdrop51 51
one 20_txdrop2 2
echo "PROBE DONE" >> "$D/probe_progress.txt"
