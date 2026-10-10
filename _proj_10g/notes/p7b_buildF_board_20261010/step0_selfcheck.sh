#!/bin/bash
# step0_selfcheck.sh -- P7B 构建 F 板级轮 (2026-10-10, 构建 F = W67/W68/W69 三个纯观测仪器 + 快照 70 字)
#   派单原话: "70 字是新代 ⇒ 读侧脚本仓内默认已跟到 70 / 0x138 / 0x1A, 但**对端 /tmp/p7b_biz/ 的副本是旧的**
#     ⇒ 你要先把更新的读侧脚本 (至少 p7b_snap.sh) 部署过去并记 md5 对照 (仓库 vs 对端 vs 历史).
#     先做步骤 0 默认档位自检 (没有原始输出不许往下走)."
#   做法 (两相, 中间夹一次烧录):
#     相 A (烧 F 之前; 板上现役 = 构建 D / BID 0x18 / 66 字):
#       (a) 默认档 (NW=70 / 0x138 / BID 0x1A)  ⇒ 期望 ID_FAIL (身份不符; 门有牙 = 红得响亮)
#       (b) 显式旧档 (NW=66 / 0x128 / BID 0x18) ⇒ 期望 ID_OK   (旧代位流仍能被显式覆盖读到)
#       (c) 显式旧档 67 (NW=67 / 0x12C / BID 0x18) ⇒ 期望 ID_OK (0x12C 在 D 上仍是未实现字 ⇒ 断言过)
#           ⚠️ 这一格是为了烧 F 之后做对照 (F 上 0x12C 变成真字 W67 ⇒ 同一命令必须 ID_FAIL)
#     相 B (烧 F 之后; 板上 = 构建 F / BID 0x1A / 70 字): 见 step0b_selfcheck.sh
#   ⚠️ 全部读数 tee 到 $OUT/STEP0_selfcheck.txt; 没有原始输出不算数。
set -u
ROOT=/d/repo/XCKU5PMini/udp_hls_10g
OUT=$ROOT/_proj_10g/notes/p7b_buildF_board_20261010
export MSYS_NO_PATHCONV=1 PYTHONIOENCODING=utf-8
PY=/c/Users/zhxue/anaconda3/python.exe
SSH="$PY D:/repo/XCKU5PMini/udp_hls_10g/tools/peer_ssh.py"
SREAD=/tmp/p7b_biz/p7b_snap.sh

mkdir -p "$OUT/_tools" "$OUT/runs" "$OUT/burn"
exec > >(tee "$OUT/STEP0_selfcheck.txt") 2>&1

echo "### STEP0_BEGIN $(date +%Y-%m-%dT%H:%M:%S%z)"
echo "### A) 部署新一代取数器 (仓库 _proj_pcie/p7b_biz/p7b_snap.sh -> 对端 $SREAD)"
LOCAL=$ROOT/_proj_pcie/p7b_biz/p7b_snap.sh
LOCAL_WIN='D:\repo\XCKU5PMini\udp_hls_10g\_proj_pcie\p7b_biz\p7b_snap.sh'
echo "### 部署前: 仓库 md5 / 对端旧副本 md5 (旧 = 构建 E 轮部署件)"
md5sum "$LOCAL"
$SSH "md5sum $SREAD"
echo "LOCAL_SHA256 $(sha256sum "$LOCAL" | cut -d' ' -f1)"
$SSH --put "$LOCAL_WIN" "$SREAD"
echo "### 部署后对端 md5 与本地 md5 (必须相同):"
$SSH "md5sum $SREAD" ; md5sum "$LOCAL"
echo "### 部署后对端文件里的生效默认值 (逐字三行):"
$SSH "grep -nE '^NW=|^UNIMPL_ADDR=|^EXPECT_BID=' $SREAD | head -6"
echo "### 部署后对端文件里的 NAME 表 W66..W69 逐字 (旧缺口 = 打成 '?'; 本轮应全有名字):"
$SSH "grep -nE '^ \[6[5-9]\]=|\[6[5-9]\]= ' $SREAD"
echo "### 本地归档部署件 (取证):"
cp "$LOCAL" "$OUT/_tools/p7b_snap.deployed.sh"; md5sum "$OUT/_tools/p7b_snap.deployed.sh"
echo "### 历史对照 md5: 构建 E 轮部署件 ="
md5sum "$ROOT/_proj_10g/notes/p7b_buildE_board_20261010/_tools/p7b_snap.deployed.sh"
echo "### 对端 lf_dl.sh md5 (本轮回合不变更; 判据 = 与 _tools/lf_dl.deployed.sh 相同):"
$SSH "md5sum /tmp/p7b_biz/lf_dl.sh"; md5sum "$ROOT/_proj_10g/notes/p7b_buildE_board_20261010/_tools/lf_dl.deployed.sh"

echo
echo "### B) 板上现态 (烧 F 之前; 期望 = 构建 D: BID 0x18 / 66 字)"
PEER_PW=111111 $SSH --sudo "T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools; \
  echo -n 'BID='; \$T/reg_rw /dev/xdma0_user 0x04 w 2>&1 | tail -1; \
  echo -n 'SCRATCH_0x08='; \$T/reg_rw /dev/xdma0_user 0x08 w 2>&1 | tail -1; \
  echo -n 'MARSHAL_0x00='; \$T/reg_rw /dev/xdma0_user 0x00 w 2>&1 | tail -1; \
  echo -n 'CARRIER='; cat /sys/class/net/enp1s0f1np1/carrier; \
  lspci -vvv -s 02:00.0 2>/dev/null | grep -E 'LnkSta:'"

echo
echo "### C-a) 默认档 (NW=70 / 0x138 / BID 0x1A) —— 对当前 D 位流: 期望 ID_FAIL (身份不符, 且只该因 BID)"
PEER_PW=111111 $SSH --sudo "bash $SREAD id; echo RC=\$?" || true

echo
echo "### C-b) 显式 D 档 (NW=66 UNIMPL_ADDR=0x128 EXPECT_BID=0x00000018) —— 期望 ID_OK"
PEER_PW=111111 $SSH --sudo "NW=66 UNIMPL_ADDR=0x128 EXPECT_BID=0x00000018 bash $SREAD id; echo RC=\$?" || true

echo
echo "### C-b2) 显式 D 档短取数 + 计时 (为长流字表定 SNAPGAP/字数预算)"
PEER_PW=111111 $SSH --sudo "T0=\$(date +%s.%N); NW=66 UNIMPL_ADDR=0x128 EXPECT_BID=0x00000018 bash $SREAD snap STEP0_8W 5 20 43 51 63 64 65 66; RC=\$?; T1=\$(date +%s.%N); echo \"STEP0_SNAP_T0 \$T0 T1 \$T1 RC \$RC\"" || true

echo
echo "### C-c) 显式 67 档 (NW=67 UNIMPL_ADDR=0x12C EXPECT_BID=0x00000018) —— 期望 ID_OK (0x12C 在 D 上仍空)"
PEER_PW=111111 $SSH --sudo "NW=67 UNIMPL_ADDR=0x12C EXPECT_BID=0x00000018 bash $SREAD id; echo RC=\$?" || true

echo
echo "### C-d) 显式 63 档 (NW=63 UNIMPL_ADDR=0x11C EXPECT_BID=0x00000018) —— 期望 ID_FAIL (0x11C 是 D 的真字 W63 ⇒ 未实现地址断言有牙)"
PEER_PW=111111 $SSH --sudo "NW=63 UNIMPL_ADDR=0x11C EXPECT_BID=0x00000018 bash $SREAD id; echo RC=\$?" || true

echo
echo "### STEP0_END $(date +%Y-%m-%dT%H:%M:%S%z)"
