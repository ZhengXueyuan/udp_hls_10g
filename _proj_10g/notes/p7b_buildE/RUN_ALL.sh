#!/bin/bash
# 构建 E —— 全部验证门的一次跑全 (串行: 本机同一时刻只能一路 Vivado 系工具).
# 每门独立留 stdout; 前面记一次源文件 sha256, 跑完再记一次 (纪律 #57: 跑动期间源不许变).
set -u
R=D:/repo/XCKU5PMini/udp_hls_10g
L=$R/_proj_10g/notes/p7b_buildE/logs
PY=/c/Users/zhxue/anaconda3/python.exe
cd "$R" || exit 99
mkdir -p "$L"

sha_src() {
  echo "--- sha256 of compiled sources @ $(date +%H:%M:%S) ---"
  for f in rtl/tcp_tx_frame.v rtl/app_pattern.v board/wrapper_p4.v tb/tb_tcp_tx_ovl.v tb/tb_app_cont.v; do
    printf "%-28s %s\n" "$f" "$($PY -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$f")"
  done
}

{
sha_src
echo "=== G1: TX_OVL author gate ==="
cmd //c 'sim\p7b_stagec_tx_regress\author_gate\run_tx_ovl_gate.bat'
echo "G1_RC=$?"
sha_src
echo
echo "=== G2: RX8 gate ==="
cmd //c 'sim\p7b_stageb_rx8\run_rx8_gate.bat'
echo "G2_RC=$?"
echo
echo "=== G3: CONT (longsend) gate ==="
cmd //c 'sim\p7b_longsend\run_cont_gate.bat'
echo "G3_RC=$?"
echo
echo "=== G4: check_window.py (static assembly) ==="
$PY _proj_10g/notes/p7b_biz_win/check_window.py
echo "G4_RC=$?"
echo
echo "=== G5: xvlog wrapper (4 macro combos) ==="
cmd //c '_proj_10g\notes\p7b_biz_win\run_xvlog_wrapper.bat'
echo "G5_RC=$?"
echo
echo "=== G6: tb_biz_win (per-word readback) ==="
cmd //c '_proj_10g\notes\p7b_biz_win\run_tb_biz_win.bat'
echo "G6_RC=$?"
sha_src
echo "ALL_DONE"
} > "$L/RUN_ALL_stdout.txt" 2>&1
