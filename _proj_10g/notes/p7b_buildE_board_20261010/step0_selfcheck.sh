#!/bin/bash
# step0_selfcheck.sh -- P7B 构建 E 板级轮 (2026-10-10, 构建 E = W66 帧器侧窗口门计数 + A3 重连修复 + 67 字)
#   目的 (派单原话): "67 字是新代 ⇒ 读侧脚本默认已跟到 67 / 0x12C / 0x19; 先做默认档位自检,
#    并确认旧档 (66/65/63) 仍能显式覆盖".
#   做法: 把仓库里的新一代取数器 (67/0x12C/0x19) 部署到对端 → 在**当前板上位流**
#     (构建 D: 66 字 / BID 0x18) 上跑四档:
#       (a) 默认档      ⇒ 期望 ID_FAIL (BID 0x18 != 0x19; 门有牙 = 红得响亮; UNIMPL 0x12C 在 D 上 = SLVERR ✓)
#       (b) 显式 66 档  ⇒ 期望 ID_OK   (上一代 (= 板上现役) 显式覆盖可用)
#       (c) 显式 65 档 (EXPECT_BID 强行 0x18) ⇒ 期望 ID_FAIL (0x124 在 D 上是真字 W65 ⇒ **未实现地址断言有牙**)
#       (d) 显式 63 档 (EXPECT_BID 强行 0x18) ⇒ 期望 ID_FAIL (0x11C 在 D 上是真字 W63 ⇒ 同上)
#   ⚠️ 全部读数 tee 到 $OUT/STEP0_selfcheck.txt; 没有原始输出不算数。
set -u
ROOT=/d/repo/XCKU5PMini/udp_hls_10g
OUT=$ROOT/_proj_10g/notes/p7b_buildE_board_20261010
export MSYS_NO_PATHCONV=1 PYTHONIOENCODING=utf-8
PY=/c/Users/zhxue/anaconda3/python.exe
SSH="$PY D:/repo/XCKU5PMini/udp_hls_10g/tools/peer_ssh.py"
SREAD=/tmp/p7b_biz/p7b_snap.sh

exec > >(tee "$OUT/STEP0_selfcheck.txt") 2>&1

echo "### STEP0_BEGIN $(date +%Y-%m-%dT%H:%M:%S%z)"
echo "### A) 部署新一代取数器 (仓库 _proj_pcie/p7b_biz/p7b_snap.sh -> 对端 $SREAD)"
LOCAL=$ROOT/_proj_pcie/p7b_biz/p7b_snap.sh
LOCAL_WIN='D:\repo\XCKU5PMini\udp_hls_10g\_proj_pcie\p7b_biz\p7b_snap.sh'
echo "LOCAL_SHA256 $(sha256sum "$LOCAL" | cut -d' ' -f1)"
$SSH --put "$LOCAL_WIN" "$SREAD"
echo "### 部署后对端 md5 与本地 md5 (必须相同):"
$SSH "md5sum $SREAD" ; md5sum "$LOCAL"
echo "### 部署后对端文件里的生效默认值 (逐字三行):"
$SSH "grep -nE '^NW=|^UNIMPL_ADDR=|^EXPECT_BID=' $SREAD"
echo "### 部署后对端文件里的 NAME 表 W63..W66 逐字四行 (旧缺口 = W65 打成 '?'; 本轮应全有名字):"
$SSH "grep -nE '^ \[6[3-6]\]=|\[65\]=\[66\]|\[65\]=|\[66\]=' $SREAD"
echo "### 本地归档部署件 (取证):"
cp "$LOCAL" "$OUT/_tools/p7b_snap.deployed.sh"; md5sum "$OUT/_tools/p7b_snap.deployed.sh"
echo "### 对端 lf_dl.sh md5 (本轮回合不变更; 判据 = 与 _tools/lf_dl.deployed.sh 相同):"
$SSH "md5sum /tmp/p7b_biz/lf_dl.sh"; md5sum "$OUT/_tools/lf_dl.deployed.sh"

echo
echo "### B) 板上现态 (烧 E 之前; 期望 = 构建 D: BID 0x18 / 66 字)"
PEER_PW=111111 $SSH --sudo "T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools; \
  echo -n 'BID='; \$T/reg_rw /dev/xdma0_user 0x04 w 2>&1 | tail -1; \
  echo -n 'SCRATCH_0x08='; \$T/reg_rw /dev/xdma0_user 0x08 w 2>&1 | tail -1; \
  echo -n 'CARRIER='; cat /sys/class/net/enp1s0f1np1/carrier; \
  lspci -vvv -s 02:00.0 2>/dev/null | grep -E 'LnkSta:'"

echo
echo "### C-a) 默认档 (NW=67 / 0x12C / BID 0x19) —— 对当前 D 位流: 期望 ID_FAIL (身份不符, 且只该因 BID)"
PEER_PW=111111 $SSH --sudo "bash $SREAD id; echo RC=\$?" || true

echo
echo "### C-b) 显式 66 档 (NW=66 UNIMPL_ADDR=0x128 EXPECT_BID=0x00000018) —— 期望 ID_OK"
PEER_PW=111111 $SSH --sudo "NW=66 UNIMPL_ADDR=0x128 EXPECT_BID=0x00000018 bash $SREAD id; echo RC=\$?" || true

echo
echo "### C-b2) 显式 66 档短取数 (W65 名字打印自检; 期望 'mac_tx_idle' 而不是 '?')"
PEER_PW=111111 $SSH --sudo "NW=66 UNIMPL_ADDR=0x128 EXPECT_BID=0x00000018 bash $SREAD snap STEP0_W65NAME 5 63 64 65; echo RC=\$?" || true

echo
echo "### C-c) 显式 65 档 (NW=65 UNIMPL_ADDR=0x124 EXPECT_BID=0x00000018) —— 期望 ID_FAIL (0x124 是 D 的真字 W65 ⇒ 未实现地址断言该报)"
PEER_PW=111111 $SSH --sudo "NW=65 UNIMPL_ADDR=0x124 EXPECT_BID=0x00000018 bash $SREAD id; echo RC=\$?" || true

echo
echo "### C-d) 显式 63 档 (NW=63 UNIMPL_ADDR=0x11C EXPECT_BID=0x00000018) —— 期望 ID_FAIL (0x11C 是 D 的真字 W63 ⇒ 同上)"
PEER_PW=111111 $SSH --sudo "NW=63 UNIMPL_ADDR=0x11C EXPECT_BID=0x00000018 bash $SREAD id; echo RC=\$?" || true

echo
echo "### STEP0_END $(date +%Y-%m-%dT%H:%M:%S%z)"
