#!/bin/bash
# a3_round.sh -- P7B 构建 E 板级轮: A3 行为验证 (连续模式下"对端关闭 -> 立刻重连")
#   判据 (派单): 第二条连接上**板子是不是照常发数据** (ΔW20 增长 / sink 收到字节)。
#   ⚠️ 负对照做不到 (D 档也含 A3 代码) —— 只报"修后行为"; 若在 E 与 D 之间看到差异, 那**不是** A3 的对照。
#   构型: 每回合 python 一次性完成 connect#1 -> 收 -> 关闭(数据中途) -> **立刻** connect#2 -> 收 -> 关闭;
#         板侧在每回合前后取快照 (W5/W20/W52/W63/W64/W65/W66) 作 ΔW20 见证。
#   用法: bash a3_round.sh [TAG]  (本机 Git Bash; 需 PEER_PW)
set -u
TAG=${1:-A3E}
ROOT=/d/repo/XCKU5PMini/udp_hls_10g
OUT=$ROOT/_proj_10g/notes/p7b_buildE_board_20261010
export MSYS_NO_PATHCONV=1 PYTHONIOENCODING=utf-8
PY=/c/Users/zhxue/anaconda3/python.exe
SSH="$PY D:/repo/XCKU5PMini/udp_hls_10g/tools/peer_ssh.py"

RAW=$OUT/runs/${TAG}.txt

echo "### A3_DEPLOY $(date +%s.%N)"
$SSH --put 'D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_buildE_board_20261010\a3_reconnect.py' /tmp/p7b_biz/a3_reconnect.py
$SSH "md5sum /tmp/p7b_biz/a3_reconnect.py"; md5sum "$OUT/a3_reconnect.py"

echo "### A3_RUN $(date +%s.%N)"
{
echo "### A3_TAG $TAG BEGIN $(date +%s.%N)"
echo "### 静默态快照 (无连接; W20 应不增长 = 负对照的性格)"
PEER_PW=111111 $SSH --sudo "cd /tmp/p7b_biz && bash /tmp/p7b_biz/p7b_snap.sh snap ${TAG}_idle0 5 20 52 63 64 65 66; sleep 2; bash /tmp/p7b_biz/p7b_snap.sh snap ${TAG}_idle1 5 20 52 63 64 65 66"
for R in 1 2 3; do
  CLOSE=close; [ "$R" = "3" ] && CLOSE=rst
  echo "### ROUND $R (close=$CLOSE) $(date +%s.%N)"
  PEER_PW=111111 $SSH --sudo "cd /tmp/p7b_biz && \
    bash /tmp/p7b_biz/p7b_snap.sh snap ${TAG}_R${R}_pre 5 20 52 63 64 65 66 && \
    python3 /tmp/p7b_biz/a3_reconnect.py --rounds 1 --recv1 1.0 --recv2 1.5 --close $CLOSE --tag ${TAG}_R${R}; A3RC=\$?; \
    bash /tmp/p7b_biz/p7b_snap.sh snap ${TAG}_R${R}_post 5 20 52 63 64 65 66; echo A3_ROUND_RC=\$A3RC"
done
echo "### A3_TAG $TAG END $(date +%s.%N)"
} 2>&1 | tee "$RAW"
echo "### A3_DONE bytes=$(stat -c %s "$RAW")"
