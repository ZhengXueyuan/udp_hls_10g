#!/bin/bash
# a3_round.sh -- P7B A3 负对照轮 (2026-10-10, p7b_a3_negctl_20261010): A3 行为验证 **常规档**
#   判据 (派单): 第二条连接上**板子是不是照常发数据** (ΔW20 增长 / sink 收到字节)。
#   ⛔ 2026-10-10 订正 (源码/哈希核实): E 轮原注释里"负对照做不到 (D 档也含 A3 代码)"**与源码不符** ——
#      构建 D 的 `rtl/app_pattern.v` sha256 = 387a7d94… (与 C 档逐字相同, = A3 落地前) ⇒ **D 不含 A3 修复**;
#      本副本存在的意义就是拿 D 当"改动前"臂。⚠️ 严格说 D↔E 差异 = A3 修复 + W66 纯观测计数器 (后者按语义不该改行为)。
#   构型: 每回合 python 一次性完成 connect#1 -> 收 -> 关闭(数据中途) -> **立刻** connect#2 -> 收 -> 关闭;
#         板侧在每回合前后取快照 (本表字均在 D 的 66 字窗口内; **D 无 W66**) 作 Δ 见证。
#   ⛔ 本副本 vs E 轮原件 (`p7b_buildE_board_20261010/a3_round.sh`) 的差异 (逐条; 逻辑未动, 只改参数):
#      (1) OUT 路径 → 本目录; (2) TAG 默认 A3E → A3D; (3) 部署源 → 本目录的 a3_reconnect.py (与 E 轮件逐字节相同,
#      md5 9dd2a2c3e195c57b112a178d98b5e053); (4) 快照字表 `5 20 52 63 64 65 66` → `5 20 43 51 52 15 63 64`
#      (受派单字表 `5 20 43 51 15 63 64` + 补 W52 —— 同一句要求记录 ΔW52, 且 W52 是 D 的真字 0xF0 非新字);
#      其余 (recv1/recv2/close 序/idle 快照/sleep 2) 逐字未动。
#   用法: bash a3_round.sh [TAG]  (本机 Git Bash; 需 PEER_PW)
set -u
TAG=${1:-A3D}
ROOT=/d/repo/XCKU5PMini/udp_hls_10g
OUT=$ROOT/_proj_10g/notes/p7b_a3_negctl_20261010
export MSYS_NO_PATHCONV=1 PYTHONIOENCODING=utf-8
PY=/c/Users/zhxue/anaconda3/python.exe
SSH="$PY D:/repo/XCKU5PMini/udp_hls_10g/tools/peer_ssh.py"

RAW=$OUT/runs/${TAG}.txt

echo "### A3_DEPLOY $(date +%s.%N)"
$SSH --put 'D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_a3_negctl_20261010\a3_reconnect.py' /tmp/p7b_biz/a3_reconnect.py
$SSH "md5sum /tmp/p7b_biz/a3_reconnect.py"; md5sum "$OUT/a3_reconnect.py"

echo "### A3_RUN $(date +%s.%N)"
{
echo "### A3_TAG $TAG BEGIN $(date +%s.%N)"
echo "### 静默态快照 (无连接; W20 应不增长 = 负对照的性格)"
PEER_PW=111111 $SSH --sudo "cd /tmp/p7b_biz && bash /tmp/p7b_biz/p7b_snap.sh snap ${TAG}_idle0 5 20 43 51 52 15 63 64; sleep 2; bash /tmp/p7b_biz/p7b_snap.sh snap ${TAG}_idle1 5 20 43 51 52 15 63 64"
for R in 1 2 3; do
  CLOSE=close; [ "$R" = "3" ] && CLOSE=rst
  echo "### ROUND $R (close=$CLOSE) $(date +%s.%N)"
  PEER_PW=111111 $SSH --sudo "cd /tmp/p7b_biz && \
    bash /tmp/p7b_biz/p7b_snap.sh snap ${TAG}_R${R}_pre 5 20 43 51 52 15 63 64 && \
    python3 /tmp/p7b_biz/a3_reconnect.py --rounds 1 --recv1 1.0 --recv2 1.5 --close $CLOSE --tag ${TAG}_R${R}; A3RC=\$?; \
    bash /tmp/p7b_biz/p7b_snap.sh snap ${TAG}_R${R}_post 5 20 43 51 52 15 63 64; echo A3_ROUND_RC=\$A3RC"
done
echo "### A3_TAG $TAG END $(date +%s.%N)"
} 2>&1 | tee "$RAW"
echo "### A3_DONE bytes=$(stat -c %s "$RAW")"
