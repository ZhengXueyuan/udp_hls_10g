#!/bin/bash
# a3_round2.sh -- P7B A3 负对照轮 (2026-10-10, p7b_a3_negctl_20261010): A3 行为验证 **节流档**
#   构型: phase1 用**小 rcvbuf + 匀速节流读** (8 MB/s) ⇒ 板侧窗口被压住 ⇒ 帧器大部分时间卡在
#         `wnd_open` 门 (正是 A3 的触发前提) ⇒ 在此状态下关闭并**立刻重连**;
#         phase2 全速收 (判据 = 第二条连接上板子照常发数据)。
#   ⛔ 本副本 vs E 轮原件 (`p7b_buildE_board_20261010/a3_round2.sh`) 的差异 (逐条; 逻辑未动, 只改参数):
#      (1) OUT 路径 → 本目录; (2) TAG 默认 A3T → A3DT; (3) 部署源 → 本目录 a3_reconnect.py (逐字节同 E 轮件);
#      (4) 快照字表 `5 20 52 63 64 65 66` → `5 20 43 51 52 15 63 64` (受派单字表 + 补 W52; D 无 W66);
#      其余 (rate1=8000000 / rcvbuf=65536 / recv1=1.5 / recv2=2.0 / close 序) 逐字未动。
#   用法: bash a3_round2.sh [TAG]
set -u
TAG=${1:-A3DT}
ROOT=/d/repo/XCKU5PMini/udp_hls_10g
OUT=$ROOT/_proj_10g/notes/p7b_a3_negctl_20261010
export MSYS_NO_PATHCONV=1 PYTHONIOENCODING=utf-8
PY=/c/Users/zhxue/anaconda3/python.exe
SSH="$PY D:/repo/XCKU5PMini/udp_hls_10g/tools/peer_ssh.py"
RAW=$OUT/runs/${TAG}.txt

echo "### A3T_DEPLOY $(date +%s.%N)"
$SSH --put 'D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_a3_negctl_20261010\a3_reconnect.py' /tmp/p7b_biz/a3_reconnect.py
$SSH "md5sum /tmp/p7b_biz/a3_reconnect.py"; md5sum "$OUT/a3_reconnect.py"

{
echo "### A3T_TAG $TAG BEGIN $(date +%s.%N)"
for R in 1 2; do
  CLOSE=close; [ "$R" = "2" ] && CLOSE=rst
  echo "### THROTTLED ROUND $R (close=$CLOSE; rate1=8MB/s rcvbuf=64KB) $(date +%s.%N)"
  PEER_PW=111111 $SSH --sudo "cd /tmp/p7b_biz && \
    bash /tmp/p7b_biz/p7b_snap.sh snap ${TAG}_R${R}_pre 5 20 43 51 52 15 63 64 && \
    python3 /tmp/p7b_biz/a3_reconnect.py --rounds 1 --recv1 1.5 --rate1 8000000 --rcvbuf 65536 --recv2 2.0 --close $CLOSE --tag ${TAG}_R${R}; A3RC=\$?; \
    bash /tmp/p7b_biz/p7b_snap.sh snap ${TAG}_R${R}_post 5 20 43 51 52 15 63 64; echo A3T_ROUND_RC=\$A3RC"
done
echo "### A3T_TAG $TAG END $(date +%s.%N)"
} 2>&1 | tee "$RAW"
echo "### A3T_DONE bytes=$(stat -c %s "$RAW")"
