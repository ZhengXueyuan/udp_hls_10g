#!/bin/bash
# step0_selfcheck.sh -- P7B-A7 板级轮 (2026-10-10, 构建 D / W65 线占空) 步骤 0: 默认档位自检
#   目的 (派单原话): "66 字几何是新代 ⇒ 读侧脚本默认已跟到 66/0x128/0x18
#     (先做一次默认档位自检, 并注意旧的 63/65 字档仍要能显式覆盖)".
#   做法: 把仓库里的新一代取数器 (66/0x128/0x18) 部署到对端 → 在**当前板上位流**
#     (构建 A: 63 字 / BID 0x16) 上跑三档:
#       (a) 默认档      ⇒ 期望 ID_FAIL (BID 0x16 != 0x18; 门有牙 = 红得响亮)
#       (b) 显式 63 档  ⇒ 期望 ID_OK   (旧档显式覆盖可用)
#       (c) 显式 65 档  ⇒ 期望 ID_FAIL (板上是 63 字档; BID 不符; 同时验证命令形态可跑)
#   ⚠️ 全部读数 tee 到 $OUT/STEP0_selfcheck.txt; 没有原始输出不算数。
set -u
ROOT=/d/repo/XCKU5PMini/udp_hls_10g
OUT=$ROOT/_proj_10g/notes/p7b_a7_board_20261010
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
echo "### 对端 lf_dl.sh md5 (本轮回合不变更; 判据 = 与 _tools/lf_dl.deployed.sh 相同):"
$SSH "md5sum /tmp/p7b_biz/lf_dl.sh"; md5sum "$OUT/_tools/lf_dl.deployed.sh"

echo
echo "### B) 板上现态 (烧 D 之前; 期望 = 构建 A: BID 0x16 / 63 字)"
PEER_PW=111111 $SSH --sudo "T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools; \
  echo -n 'BID='; \$T/reg_rw /dev/xdma0_user 0x04 w 2>&1 | tail -1; \
  echo -n 'SCRATCH_0x08='; \$T/reg_rw /dev/xdma0_user 0x08 w 2>&1 | tail -1; \
  echo -n 'CARRIER='; cat /sys/class/net/enp1s0f1np1/carrier; \
  lspci -vvv -s 02:00.0 2>/dev/null | grep -E 'LnkSta:'"

echo
echo "### C-a) 默认档 (NW=66 / 0x128 / BID 0x18) —— 对当前 A 位流: 期望 ID_FAIL (身份不符)"
PEER_PW=111111 $SSH --sudo "bash $SREAD id; echo RC=\$?" || true

echo
echo "### C-b) 显式 63 档 (NW=63 UNIMPL_ADDR=0x11C EXPECT_BID=0x00000016) —— 期望 ID_OK"
PEER_PW=111111 $SSH --sudo "NW=63 UNIMPL_ADDR=0x11C EXPECT_BID=0x00000016 bash $SREAD id; echo RC=\$?" || true

echo
echo "### C-c) 显式 65 档 (NW=65 UNIMPL_ADDR=0x124 EXPECT_BID=0x00000017) —— 对 A 位流: 期望 ID_FAIL (BID 不符)"
PEER_PW=111111 $SSH --sudo "NW=65 UNIMPL_ADDR=0x124 EXPECT_BID=0x00000017 bash $SREAD id; echo RC=\$?" || true

echo
echo "### STEP0_END $(date +%Y-%m-%dT%H:%M:%S%z)"
