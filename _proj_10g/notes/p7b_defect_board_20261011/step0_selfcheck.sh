#!/bin/bash
# step0_selfcheck.sh -- PETXHI-GHOST 板级轮 A (S-0 臂) 2026-10-11
#   目的 = 在【修复前】位流 (构建 F / BID 0x1A) 上用 abort RST 构型测"板上到底会不会出幽灵"。
#   本步 = 只读自检: 对端可达 / 工具 md5 / 板上现态 (烧前) / 归档件 sha256。
#   ⚠️ 本步不烧录、不写任何寄存器、不动 /tmp/p7b_biz/。
set -u
ROOT=/d/repo/XCKU5PMini/udp_hls_10g
OUT=$ROOT/_proj_10g/notes/p7b_defect_board_20261011
export MSYS_NO_PATHCONV=1 PYTHONIOENCODING=utf-8
PY=/c/Users/zhxue/anaconda3/python.exe
SSH="$PY D:/repo/XCKU5PMini/udp_hls_10g/tools/peer_ssh.py"

mkdir -p "$OUT/_tools" "$OUT/runs" "$OUT/burn"
exec > >(tee "$OUT/STEP0_selfcheck.txt") 2>&1

echo "### STEP0_BEGIN $(date +%Y-%m-%dT%H:%M:%S%z)"

echo
echo "### A) 归档 F 位流 (派单指定源 = _proj_10g/notes/p7b_build_archive/20261011_002044/wrapper_p4.bit)"
ARCH=$ROOT/_proj_10g/notes/p7b_build_archive/20261011_002044
echo "--- SHA256SUMS.txt 里 wrapper_p4.bit 那一行 (逐字) ---"
grep 'wrapper_p4.bit' "$ARCH/SHA256SUMS.txt"
echo "--- 按其中值核归档副本 ---"
sha256sum "$ARCH/wrapper_p4.bit"
stat -c 'ARCH_BIT %n size=%s mtime=%y' "$ARCH/wrapper_p4.bit"
echo "WANT=89e89f31efb5f1450a1c39acfce587bb4e4b6347c5fdc2f470c91ff0d4400f45"

echo
echo "### B) 对端可达 + 工具名册 (md5; 只读, 不动 /tmp/p7b_biz)"
$SSH "echo PEER_OK; hostname; date; uptime | head -1"
echo "--- 现役工具 md5 (对端) ---"
$SSH "md5sum /tmp/p7b_biz/p7b_tcp_sink /tmp/p7b_biz/p7b_snap.sh /tmp/p7b_biz/lf_dl.sh 2>&1"
echo "--- 仓库侧对照 md5 (现核) ---"
md5sum "$ROOT/_proj_pcie/p7b_biz/p7b_snap.sh"
echo "--- 部署的 sink 是否支持 sinkfix 开关 (strings 探测; 空 = 旧件 = after_connect 落点) ---"
$SSH "strings /tmp/p7b_biz/p7b_tcp_sink | grep -c 'rcvbuf-after-connect'; strings /tmp/p7b_biz/p7b_tcp_sink | grep -c 'RCVBUF_ORDER'"
echo "--- 对端 python3 / g++ 可用性 (只在需要新编译时才用; 本轮不覆盖 /tmp/p7b_biz) ---"
$SSH "python3 -V 2>&1; which g++ 2>&1 | head -1"

echo
echo "### C) 网络面 (每次测量前现取): /32 路由 + NetworkManager 托管位 + link 状态"
$SSH "ip -4 addr show enp1s0f1np1 | grep -E 'inet |state'; echo ---; nmcli device show enp1s0f1np1 2>/dev/null | grep -E 'GENERAL.STATE|GENERAL.CONNECTION' ; echo ---; ip route get 192.168.100.2 | head -2; echo ---; ethtool enp1s0f1np1 | grep -E 'Speed|Link detected'; echo ---; ethtool -c enp1s0f1np1 | grep -E 'Coalesce|Adaptive|rx-usecs' | head -4"

echo
echo "### D) 板上现态 (烧 F 之前) —— 派单要求先核: 0x04 BID / 0x138 未实现地址 / LnkSta x4 / 2 BARs"
PEER_PW=111111 $SSH --sudo "T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools; \
  echo -n 'BID_0x04='; \$T/reg_rw /dev/xdma0_user 0x04 w 2>&1 | tail -1; \
  echo -n 'MARSHAL_0x00='; \$T/reg_rw /dev/xdma0_user 0x00 w 2>&1 | tail -1; \
  echo -n 'SCRATCH_0x08='; \$T/reg_rw /dev/xdma0_user 0x08 w 2>&1 | tail -1; \
  echo -n 'UNIMPL_0x138='; \$T/reg_rw /dev/xdma0_user 0x138 w 2>&1 | tail -1; \
  echo -n 'W61_0x114='; \$T/reg_rw /dev/xdma0_user 0x114 w 2>&1 | tail -1; \
  echo -n 'CARRIER='; cat /sys/class/net/enp1s0f1np1/carrier; \
  echo -n 'ABORTCNT_0x94='; \$T/reg_rw /dev/xdma0_user 0x94 w 2>&1 | tail -1; \
  echo -n 'STATES_0x0A='; \$T/reg_rw /dev/xdma0_user 0x0A w 2>&1 | tail -1; \
  lspci -vvv -s 02:00.0 2>/dev/null | grep -E 'LnkSta:|Region 0|Region 1'"

echo
echo "### E) 身份档 (默认 NW=70 / 0x138 / BID 0x1A) —— 现核是否与构建 F 一致"
PEER_PW=111111 $SSH --sudo "bash /tmp/p7b_biz/p7b_snap.sh id; echo RC=\$?" || true

echo
echo "### STEP0_END $(date +%Y-%m-%dT%H:%M:%S%z)"
