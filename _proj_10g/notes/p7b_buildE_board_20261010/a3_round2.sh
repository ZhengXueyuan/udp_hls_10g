#!/bin/bash
# a3_round2.sh -- P7B 构建 E 板级轮: A3 行为验证 **节流档** (尽力制造"关闭时帧器正忙/窗口关着")
#   构型: phase1 用**小 rcvbuf + 匀速节流读** (8 MB/s) ⇒ 板侧窗口被压住 ⇒ 帧器大部分时间卡在
#         `wnd_open` 门 (正是 A3 的触发前提) ⇒ 在此状态下关闭并**立刻重连**;
#         phase2 全速收 (判据 = 第二条连接上板子照常发数据)。
#   用法: bash a3_round2.sh [TAG]
set -u
TAG=${1:-A3T}
ROOT=/d/repo/XCKU5PMini/udp_hls_10g
OUT=$ROOT/_proj_10g/notes/p7b_buildE_board_20261010
export MSYS_NO_PATHCONV=1 PYTHONIOENCODING=utf-8
PY=/c/Users/zhxue/anaconda3/python.exe
SSH="$PY D:/repo/XCKU5PMini/udp_hls_10g/tools/peer_ssh.py"
RAW=$OUT/runs/${TAG}.txt

echo "### A3T_DEPLOY $(date +%s.%N)"
$SSH --put 'D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_buildE_board_20261010\a3_reconnect.py' /tmp/p7b_biz/a3_reconnect.py
$SSH "md5sum /tmp/p7b_biz/a3_reconnect.py"; md5sum "$OUT/a3_reconnect.py"

{
echo "### A3T_TAG $TAG BEGIN $(date +%s.%N)"
for R in 1 2; do
  CLOSE=close; [ "$R" = "2" ] && CLOSE=rst
  echo "### THROTTLED ROUND $R (close=$CLOSE; rate1=8MB/s rcvbuf=64KB) $(date +%s.%N)"
  PEER_PW=111111 $SSH --sudo "cd /tmp/p7b_biz && \
    bash /tmp/p7b_biz/p7b_snap.sh snap ${TAG}_R${R}_pre 5 20 52 63 64 65 66 && \
    python3 /tmp/p7b_biz/a3_reconnect.py --rounds 1 --recv1 1.5 --rate1 8000000 --rcvbuf 65536 --recv2 2.0 --close $CLOSE --tag ${TAG}_R${R}; A3RC=\$?; \
    bash /tmp/p7b_biz/p7b_snap.sh snap ${TAG}_R${R}_post 5 20 52 63 64 65 66; echo A3T_ROUND_RC=\$A3RC"
done
echo "### A3T_TAG $TAG END $(date +%s.%N)"
} 2>&1 | tee "$RAW"
echo "### A3T_DONE bytes=$(stat -c %s "$RAW")"
