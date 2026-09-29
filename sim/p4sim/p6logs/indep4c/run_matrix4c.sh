#!/bin/bash
REPO_ROOT="$(cd -- "$(dirname -- "$0")/../../../../" && pwd)" || exit 1
if [ ! -f "$REPO_ROOT/CLAUDE.md" ]; then
  echo "[PATHGUARD FAIL] cannot locate this checkout from $0" >&2
  echo "  derived REPO_ROOT = $REPO_ROOT" >&2
  exit 1
fi
# P4c 窗口扩张 (12KB->48KB) 全矩阵 独立复跑 (测试 agent, 2026-09-12)
# 规约: 只跑测试, 不改任何源文件; 每门先删注入 memh (防残留), 记录 exit/时长/md5/关键行
cd %REPO_ROOT%/sim/p4sim || exit 1
R=%REPO_ROOT%
D=$R/sim/p4sim/p6logs/indep4c
mkdir -p "$D"
: > "$D/summary.txt"
: > "$D/progress.txt"

# ---- 被测版本指纹 (逐位证据: 本复跑跑的就是这个 revision) ----
{
  echo "== 被测源文件指纹 (md5 / mtime) =="
  for f in rtl/retx_ram.v rtl/frame_fifo.v rtl/tcp_tx_frame.v rtl/tcp_echo.v rtl/tcb.v \
           rtl/slow_cfg_adp.v rtl/tcp_rx.v rtl/tcp_synp.v tb/tb_p4_chain.v \
           tb/tb_retx_ram.v tb/tb_frame_fifo.v tools/gen_stim_p4_chain.py \
           hls/slowstack_prj/solution1/syn/verilog/udp_echo.v ; do
    md5sum "$R/$f" | sed "s#$R/##"
    stat -c '   mtime %y  %n' "$R/$f"
  done
} > "$D/00_rev_fingerprint.txt" 2>&1

run() {   # run <tag> <cmdline> [keep]
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
      if [ "$keep" = "keep" ]; then
        cp -f resp_p4_chain.memh "$D/${tag}_resp.memh"
        echo "### archived resp_p4_chain.memh"
      fi
    fi
    if [ -f xsim_run.log ]; then
      cp -f xsim_run.log "$D/${tag}_xsim.log"
      echo "### xsim markers: $(grep -cE 'Memory Collision Error' xsim_run.log) collision-errors ; HALFD/TXSTUCK lines:"
      grep -aoE 'HALFDROP n=[0-9]+ k=[0-9]+ fired=[0-9]+ ECOMAX=[0-9]+ TXSTUCK=[0-9]+' xsim_run.log | tail -2
    fi
    echo "------------------------------------------"
    iconv -f GBK -t UTF-8 "$D/$tag.txt" 2>/dev/null \
      | grep -aE "BURST OK|BURST FAIL|P4 CHAIN OK|P4 CHAIN FAIL|MISMATCH|REPRODUCED|FAIL|截断验证|dup-ACK|HALFDROP|半帧段|echo seq 链|重传容错|载荷逐字节|conn1 连接级|TRUNCS|conn0 echoes|STATS_MAC|^STATS7|^STATS_TX|^STATS_ECO|^TCBF|RX frames"
    echo
  } >> "$D/summary.txt" 2>&1
  echo "[$tag] rc=$rc dur=$((t1-t0))s" >> "$D/progress.txt"
}

B='run_tb_p4_burst.bat'
C='run_tb_p4_chain.bat'

run 01_gate1_base_run1    "cmd //c \"D:\\repo\\ECO\\udp_hls_10g\\sim\\p4sim\\$B 200\"" keep
run 02_gate1_base_run2    "cmd //c \"D:\\repo\\ECO\\udp_hls_10g\\sim\\p4sim\\$B 200\""
run 03_gate2_trunc100_m8  "TRUNC=100 TRUNCM=8 cmd //c \"D:\\repo\\ECO\\udp_hls_10g\\sim\\p4sim\\$B 200\"" keep
run 04_gate3_half100_k990 "HALFDROP=100 HALFDROPK=990 cmd //c \"D:\\repo\\ECO\\udp_hls_10g\\sim\\p4sim\\$B 200\"" keep
run 05_gate4_chain        "cmd //c \"D:\\repo\\ECO\\udp_hls_10g\\sim\\p4sim\\$C\""
run 06_txdrop50           "cmd //c \"D:\\repo\\ECO\\udp_hls_10g\\sim\\p4sim\\$B 200 -1 0 4000 0 0 50\"" keep
run 07_gate4096_pcwnd1k   "cmd //c \"D:\\repo\\ECO\\udp_hls_10g\\sim\\p4sim\\$B 200 0 0 10\"" keep
run 08_dupstorm           "cmd //c \"D:\\repo\\ECO\\udp_hls_10g\\sim\\p4sim\\$B 200 0 0 4000 608 dup\"" keep

# ---- 单元 TB (独立目录) ----
u() {  # u <tag> <workdir> <cmdline>
  tag="$1"; wd="$2"; cmd="$3"
  {
    echo "=================================================================="
    echo "### $tag (wd=$wd) :: $cmd"
    t0=$(date +%s)
    ( cd "$wd" && eval "$cmd" ) > "$D/$tag.txt" 2>&1
    rc=$?
    t1=$(date +%s)
    echo "### EXIT=$rc  dur=$((t1-t0))s"
    echo "------------------------------------------"
    iconv -f GBK -t UTF-8 "$D/$tag.txt" 2>/dev/null \
      | grep -aE "GRP |ALL 7 GROUPS|PASS|FAIL|PASS_ALL|PASS_ph" | head -30
    echo
  } >> "$D/summary.txt" 2>&1
  echo "[$tag] rc=$rc dur=$((t1-t0))s" >> "$D/progress.txt"
}

u 09_unit_retx_ram  "%REPO_ROOT%/sim/retxsim"  "cmd //c \"D:\\repo\\ECO\\udp_hls_10g\\sim\\retxsim\\run_retx_tb.bat\""
u 10_unit_frame_fifo "%REPO_ROOT%/sim/retxsim2" "cmd //c \"D:\\repo\\ECO\\udp_hls_10g\\sim\\retxsim2\\run_tb_frame_fifo.bat D:\\repo\\ECO\\udp_hls_10g\\rtl\\frame_fifo.v\""

echo "MATRIX4C DONE" >> "$D/progress.txt"
