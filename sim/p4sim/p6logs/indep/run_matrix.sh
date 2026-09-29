#!/bin/bash
REPO_ROOT="$(cd -- "$(dirname -- "$0")/../../../../" && pwd)" || exit 1
if [ ! -f "$REPO_ROOT/CLAUDE.md" ]; then
  echo "[PATHGUARD FAIL] cannot locate this checkout from $0" >&2
  echo "  derived REPO_ROOT = $REPO_ROOT" >&2
  exit 1
fi
# P4b-7-P6 四门矩阵 独立复跑 (测试 agent, 2026-09-12)
# 每门: 先删三个注入 memh (防残留), 跑, 记 exit/时长/memh 状态/关键行, 存档日志
cd %REPO_ROOT%/sim/p4sim || exit 1
D=%REPO_ROOT%/sim/p4sim/p6logs/indep
: > "$D/summary.txt"

run() {   # run <tag> <cmdline> [keepresp]
  tag="$1"; cmd="$2"; keep="$3"
  rm -f trunc.memh halfdrop.memh txdrop.memh
  {
    echo "=================================================================="
    echo "### $tag :: $cmd"
    echo "### memh before (deleted by driver): trunc/halfdrop/txdrop removed"
    t0=$(date +%s)
    eval "$cmd" > "$D/$tag.txt" 2>&1
    rc=$?
    t1=$(date +%s)
    echo "### EXIT=$rc  dur=$((t1-t0))s"
    echo "### memh after : trunc=[$(cat trunc.memh 2>/dev/null)] halfdrop=[$(cat halfdrop.memh 2>/dev/null)] txdrop=[$(cat txdrop.memh 2>/dev/null)]"
    if [ "$keep" = "keep" ]; then
      cp -f resp_p4_chain.memh "$D/${tag}_resp.memh"
      cp -f xsim_run.log "$D/${tag}_xsim.log"
      echo "### archived resp_p4_chain.memh + xsim_run.log"
    fi
    echo "------------------------------------------"
    iconv -f GBK -t UTF-8 "$D/$tag.txt" 2>/dev/null \
      | grep -E "BURST OK|P4 CHAIN OK|MISMATCH|REPRODUCED|FAIL|截断验证|dup-ACK|HALFDROP|半帧段|echo seq 链|重传容错|载荷逐字节|conn1 连接级|TRUNCS|conn0 echoes|STATS_MAC|^STATS7|^STATS_TX|^STATS_ECO|^TCBF"
    echo
  } >> "$D/summary.txt" 2>&1
  echo "[$tag] rc=$rc dur=$((t1-t0))s" >> "$D/progress.txt"
}

B='run_tb_p4_burst.bat'
C='run_tb_p4_chain.bat'

run 01_gate1_base_run1   "cmd //c \"D:\\repo\\ECO\\udp_hls_10g\\sim\\p4sim\\$B 200\""
run 02_gate1_base_run2   "cmd //c \"D:\\repo\\ECO\\udp_hls_10g\\sim\\p4sim\\$B 200\""
run 03_gate2_trunc100_m8 "TRUNC=100 TRUNCM=8 cmd //c \"D:\\repo\\ECO\\udp_hls_10g\\sim\\p4sim\\$B 200\""  keep
run 04_gate2_trunc100_m10 "TRUNC=100 TRUNCM=10 cmd //c \"D:\\repo\\ECO\\udp_hls_10g\\sim\\p4sim\\$B 200\""
run 05_gate2_trunc50_m6  "TRUNC=50 TRUNCM=6 cmd //c \"D:\\repo\\ECO\\udp_hls_10g\\sim\\p4sim\\$B 200\""
run 06_gate3_half100_k990 "HALFDROP=100 HALFDROPK=990 cmd //c \"D:\\repo\\ECO\\udp_hls_10g\\sim\\p4sim\\$B 200\"" keep
run 07_gate3_half100_k22 "HALFDROP=100 HALFDROPK=22 cmd //c \"D:\\repo\\ECO\\udp_hls_10g\\sim\\p4sim\\$B 200\"" keep
run 08_gate4_chain       "cmd //c \"D:\\repo\\ECO\\udp_hls_10g\\sim\\p4sim\\$C\""
run 09_extra_txdrop50    "cmd //c \"D:\\repo\\ECO\\udp_hls_10g\\sim\\p4sim\\$B 200 -1 0 4000 0 0 50\""
run 10_extra_gate_pcwnd1k "cmd //c \"D:\\repo\\ECO\\udp_hls_10g\\sim\\p4sim\\$B 200 0 0 10\""
echo "MATRIX DONE" >> "$D/progress.txt"
