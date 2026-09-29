#!/bin/bash
REPO_ROOT="$(cd -- "$(dirname -- "$0")/../../../../" && pwd)" || exit 1
if [ ! -f "$REPO_ROOT/CLAUDE.md" ]; then
  echo "[PATHGUARD FAIL] cannot locate this checkout from $0" >&2
  echo "  derived REPO_ROOT = $REPO_ROOT" >&2
  exit 1
fi
# P4c 全矩阵 第二轮 (冻结复跑): 首轮中途 tb/tb_p4_chain.v 于 18:58:43 被并行 agent 修改
# (md5 cea2ef98 -> 9b445fb9, cfg_suppress_data_ack 1'b1 -> 1'b0), 首轮 01-04 门跑的是旧 TB。
# 本轮到同一目录、同命令重跑, 全部落 9b445fb9 TB + 未变 RTL。
cd %REPO_ROOT%/sim/p4sim || exit 1
R=%REPO_ROOT%
D=$R/sim/p4sim/p6logs/indep4c
: > "$D/summary2.txt"
: > "$D/progress2.txt"

{
  echo "== 第二轮指纹 (开始时刻) =="
  for f in rtl/retx_ram.v rtl/tcp_tx_frame.v rtl/tcp_rx.v rtl/tcb.v rtl/slow_cfg_adp.v \
           tb/tb_p4_chain.v tools/gen_stim_p4_chain.py; do
    md5sum "$R/$f" | sed "s#$R/##"
    stat -c '   mtime %y  %n' "$R/$f"
  done
} > "$D/00_rev_fingerprint2.txt" 2>&1

run2() {
  tag="$1"; cmd="$2"; keep="$3"
  rm -f trunc.memh halfdrop.memh txdrop.memh
  {
    echo "=================================================================="
    echo "### $tag :: $cmd"
    t0=$(date +%s)
    eval "$cmd" > "$D/$tag.txt" 2>&1
    rc=$?
    t1=$(date +%s)
    echo "### EXIT=$rc  dur=$((t1-t0))s"
    echo "### memh after : trunc=[$(cat trunc.memh 2>/dev/null)] halfdrop=[$(cat halfdrop.memh 2>/dev/null)] txdrop=[$(cat txdrop.memh 2>/dev/null)]"
    if [ -f resp_p4_chain.memh ]; then
      echo "### resp md5: $(md5sum resp_p4_chain.memh | cut -c1-32)  size=$(stat -c %s resp_p4_chain.memh)"
      echo "### ack-events: $(grep -c '^ACK ' resp_p4_chain.memh)"
      if [ "$keep" = "keep" ]; then
        cp -f resp_p4_chain.memh "$D/${tag}_resp.memh"
        echo "### archived resp"
      fi
    fi
    if [ -f xsim_run.log ]; then
      cp -f xsim_run.log "$D/${tag}_xsim.log"
      echo "### collision-errors: $(grep -cE 'Memory Collision Error' xsim_run.log)"
      grep -aoE 'GATEPROBE.*' xsim_run.log | tail -1
    fi
    echo "------------------------------------------"
    iconv -f GBK -t UTF-8 "$D/$tag.txt" 2>/dev/null \
      | grep -aE "BURST OK|BURST FAIL|P4 CHAIN OK|P4 CHAIN FAIL|MISMATCH|FAIL|截断验证|dup-ACK|HALFDROP|半帧段|echo seq 链|重传容错|载荷逐字节|conn1 连接级|TRUNCS|conn0 echoes|^STATS7|^STATS_TX|^RETX|^STATS_ECO|^TCBF|^STATS_MAC"
    echo
  } >> "$D/summary2.txt" 2>&1
  echo "[$tag] rc=$rc dur=$((t1-t0))s" >> "$D/progress2.txt"
}

B='run_tb_p4_burst.bat'
C='run_tb_p4_chain.bat'
run2 11_gate1_base         "cmd //c \"D:\\repo\\ECO\\udp_hls_10g\\sim\\p4sim\\$B 200\"" keep
run2 12_gate1_base_rep     "cmd //c \"D:\\repo\\ECO\\udp_hls_10g\\sim\\p4sim\\$B 200\""
run2 13_gate2_trunc100_m8  "TRUNC=100 TRUNCM=8 cmd //c \"D:\\repo\\ECO\\udp_hls_10g\\sim\\p4sim\\$B 200\"" keep
run2 14_gate3_half100_k990 "HALFDROP=100 HALFDROPK=990 cmd //c \"D:\\repo\\ECO\\udp_hls_10g\\sim\\p4sim\\$B 200\"" keep
run2 15_gate4_chain        "cmd //c \"D:\\repo\\ECO\\udp_hls_10g\\sim\\p4sim\\$C\"" keep
run2 16_txdrop50           "cmd //c \"D:\\repo\\ECO\\udp_hls_10g\\sim\\p4sim\\$B 200 -1 0 4000 0 0 50\"" keep
run2 17_gate4096_pcwnd1k   "cmd //c \"D:\\repo\\ECO\\udp_hls_10g\\sim\\p4sim\\$B 200 0 0 10\"" keep
run2 18_dupstorm           "cmd //c \"D:\\repo\\ECO\\udp_hls_10g\\sim\\p4sim\\$B 200 0 0 4000 608 dup\"" keep
echo "MATRIX4C RERUN DONE" >> "$D/progress2.txt"
