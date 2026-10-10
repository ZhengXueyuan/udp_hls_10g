#!/bin/bash
# step0_selfcheck.sh -- P7B A3 负对照轮 (2026-10-10, p7b_a3_negctl_20261010)
#   目的: 在**刚烧入的构建 D 位流** (66 字 / BID 0x18 / 未实现地址 0x128) 上做档位自检 —— 证明
#     (i)  缺省档 (NW=70 / 0x138 / BID 0x1D) 对 D **响亮失败** (且失败点只在 BID = 档位错, 不是板错);
#     (ii) 显式 66 档 (= 本臂正确档位) ID_OK;
#     (iii) 66 档下的业务字表 (与 a3_round*.sh 逐字相同) 全部有名、nff=0;
#     (iv) 负对照: 声称 NW=65 时未实现地址 0x124 在 D 上读出**真数据** ⇒ 断言有牙 ⇒ D 的窗口 ≥ 66 字;
#           (与 (ii) 的 0x128=SLVERR 合起来 ⇒ **窗口恰 = 66 字**)。
#   ⛔ 本副本 vs E 轮原件 (`p7b_buildE_board_20261010/step0_selfcheck.sh`) 的差异 = 上面 (i)–(iv) 的**期望值**
#      与字表 (66 字档 + D 业务字表); 骨架/命令形状逐字同源。区段编号与 E 轮对齐 (A/B/C-a/C-b/C-b2/C-c/C-d)。
#   ⚠️ 全部读数 tee 到 $OUT/STEP0_selfcheck.txt; 没有原始输出不算数。
set -u
ROOT=/d/repo/XCKU5PMini/udp_hls_10g
OUT=$ROOT/_proj_10g/notes/p7b_a3_negctl_20261010
export MSYS_NO_PATHCONV=1 PYTHONIOENCODING=utf-8
PY=/c/Users/zhxue/anaconda3/python.exe
SSH="$PY D:/repo/XCKU5PMini/udp_hls_10g/tools/peer_ssh.py"
SREAD=/tmp/p7b_biz/p7b_snap.sh

exec > >(tee "$OUT/STEP0_selfcheck.txt") 2>&1

echo "### STEP0_BEGIN $(date +%Y-%m-%dT%H:%M:%S%z)"
echo "### A) 取数器部署自证 (仓库 _proj_pcie/p7b_biz/p7b_snap.sh -> 对端 $SREAD; 幂等重放)"
LOCAL=$ROOT/_proj_pcie/p7b_biz/p7b_snap.sh
LOCAL_WIN='D:\repo\XCKU5PMini\udp_hls_10g\_proj_pcie\p7b_biz\p7b_snap.sh'
echo "LOCAL_SHA256 $(sha256sum "$LOCAL" | cut -d' ' -f1)"
$SSH --put "$LOCAL_WIN" "$SREAD"
echo "### 部署后对端 md5 与本地 md5 (必须相同):"
$SSH "md5sum $SREAD" ; md5sum "$LOCAL"
echo "### 部署后对端文件里的生效默认值 (逐字三行; ⚠️ 本臂全部调用都会显式覆盖 NW/EXPECT_BID):"
$SSH "grep -nE '^NW=|^UNIMPL_ADDR=|^EXPECT_BID=' $SREAD"
echo "### 对端 a3_reconnect.py md5 (判据 = 与本目录部署源相同 = E 轮原件逐字节同源):"
$SSH "md5sum /tmp/p7b_biz/a3_reconnect.py" ; md5sum "$OUT/a3_reconnect.py"
echo "### 本地归档部署件 (取证):"
cp "$LOCAL" "$OUT/_tools/p7b_snap.deployed.sh"; md5sum "$OUT/_tools/p7b_snap.deployed.sh"

echo
echo "### B) 板上现态 = 本轮刚烧的构建 D (经 burn_arm.sh D; 期望 BID 0x18 / 66 字 / 0x08=0)"
PEER_PW=111111 $SSH --sudo "T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools; \
  echo -n 'BID='; \$T/reg_rw /dev/xdma0_user 0x04 w 2>&1 | tail -1; \
  echo -n 'SCRATCH_0x08='; \$T/reg_rw /dev/xdma0_user 0x08 w 2>&1 | tail -1; \
  echo -n 'CARRIER='; cat /sys/class/net/enp1s0f1np1/carrier; \
  lspci -vvv -s 02:00.0 2>/dev/null | grep -E 'LnkSta:'"

echo
echo "### C-a) 默认档 (NW=70 / 0x138 / BID 0x1D) —— 对 D 位流: 期望 ID_FAIL 且失败点=身份不符 (BID 0x18 != 0x1D)"
PEER_PW=111111 $SSH --sudo "bash $SREAD id; echo RC=\$?" || true

echo
echo "### C-b) 显式 66 档 (NW=66 UNIMPL_ADDR=0x128 EXPECT_BID=0x00000018) —— 期望 ID_OK"
PEER_PW=111111 $SSH --sudo "NW=66 UNIMPL_ADDR=0x128 EXPECT_BID=0x00000018 bash $SREAD id; echo RC=\$?" || true

echo
echo "### C-b2) 显式 66 档业务字表短取数 (与 a3_round*.sh 的字表逐字相同; 期望 8 个名字全真、nff=0)"
PEER_PW=111111 $SSH --sudo "NW=66 UNIMPL_ADDR=0x128 EXPECT_BID=0x00000018 bash $SREAD snap STEP0_WORDS 5 20 43 51 52 15 63 64; echo RC=\$?" || true

echo
echo "### C-c) 负对照: 显式 65 档 (NW=65 UNIMPL_ADDR=0x124 EXPECT_BID=0x00000018) —— 期望 ID_FAIL (0x124 是 D 的真字 W65 ⇒ 未实现地址断言该报 ⇒ D 窗口 ≥ 66)"
PEER_PW=111111 $SSH --sudo "NW=65 UNIMPL_ADDR=0x124 EXPECT_BID=0x00000018 bash $SREAD id; echo RC=\$?" || true

echo
echo "### C-d) 负对照: 显式 63 档 (NW=63 UNIMPL_ADDR=0x11C EXPECT_BID=0x00000018) —— 期望 ID_FAIL (0x11C 是 D 的真字 W63 ⇒ 同上)"
PEER_PW=111111 $SSH --sudo "NW=63 UNIMPL_ADDR=0x11C EXPECT_BID=0x00000018 bash $SREAD id; echo RC=\$?" || true

echo
echo "### STEP0_END $(date +%Y-%m-%dT%H:%M:%S%z)"
