#!/bin/bash
# step0_selfcheck.sh -- P7b snd_wnd 守卫板级轮 (2026-10-11): 只读自检
#   目的 = 在两臂位流 (0x1E 含守卫 / 0x1D 不含守卫) 开烧之前, 核: 归档件 sha256 / 对端可达
#          + 工具名册 / 网络面 / 板上现态 / 无残留进程。
#   ⚠️ 本步不烧录、不写任何寄存器、不动 /tmp/p7b_biz/。
#   用法: PEER_PW=... bash step0_selfcheck.sh
set -u
ROOT=/d/repo/XCKU5PMini/udp_hls_10g
OUT=$ROOT/_proj_10g/notes/p7b_sndwnd_board_20261011
export MSYS_NO_PATHCONV=1 PYTHONIOENCODING=utf-8
PY=/c/Users/zhxue/anaconda3/python.exe
ROOTW=D:/repo/XCKU5PMini/udp_hls_10g
SSH="$PY $ROOTW/tools/peer_ssh.py"
[ -n "${PEER_PW:-}" ] || { echo "FATAL: 需要 PEER_PW 环境变量 (只用于 --sudo, 不落盘)"; exit 3; }

mkdir -p "$OUT/_tools" "$OUT/runs" "$OUT/burn"
exec > >(tee "$OUT/STEP0_selfcheck.txt") 2>&1

echo "### STEP0_BEGIN $(date +%Y-%m-%dT%H:%M:%S%z)"

echo
echo "### A) 两个位流归档副本 (派单指定源; 只烧这两个目录里的 wrapper_p4.bit)"
for P in 0x1E 0x1D; do
  F=$ROOT/_proj_10g/notes/p7b_build_$P/wrapper_p4.bit
  echo "--- $P ---"
  sha256sum "$F"
  stat -c 'BIT %n size=%s mtime=%y' "$F"
  grep -n 'wrapper_p4.bit' "$ROOT/_proj_10g/notes/p7b_build_$P/SHA256SUMS.txt" 2>/dev/null | head -3
done
echo "WANT_0x1E=e489ae4a4b868695cff1c6dfc2fbdef70de29d391cdb9a43e0a08accd342be1a"
echo "WANT_0x1D=b48dc7ee7ddb7df2a057fdae324dbf302c5adc6f430a413e0bce0e3a25ee0b1f"

echo
echo "### B) 对端可达 + 工具名册 (md5; 只读, 不动 /tmp/p7b_biz)"
$SSH "echo PEER_OK; hostname; date; uptime | head -1"
echo "--- 现役工具 md5 (对端 /tmp/p7b_biz) ---"
$SSH "md5sum /tmp/p7b_biz/p7b_tcp_sink /tmp/p7b_biz/p7b_snap.sh 2>&1"
echo "--- sinkfix 后编译件 (对端 /tmp/p7b_biz_refresh) ---"
$SSH "cd /tmp/p7b_biz_refresh 2>/dev/null && md5sum p7b_tcp_sink p7b_tcp_sink.cpp 2>&1 || echo NO_REFRESH_DIR"
echo "--- refresh sink 是否支持 --rcvbuf-after-connect (应 >=1) ---"
$SSH "strings /tmp/p7b_biz_refresh/p7b_tcp_sink 2>/dev/null | grep -c 'rcvbuf-after-connect'; strings /tmp/p7b_biz_refresh/p7b_tcp_sink 2>/dev/null | grep -c 'RCVBUF_ORDER'"
echo "--- persist 轮遗留物 (只读; 本轮不碰) ---"
$SSH "ls -la /tmp/p7b_persist/ 2>&1 | head -12; md5sum /tmp/p7b_persist/stall_probe.py /tmp/p7b_persist/persist_client.py 2>&1"
echo "--- 仓库侧对照 md5 (现核) ---"
md5sum "$ROOT/_proj_pcie/p7b_biz/p7b_snap.sh"
md5sum "$ROOT/tools/peer_ssh.py"
echo "--- 对端 python3 / g++ 可用性 + /tmp 空间 ---"
$SSH "python3 -V 2>&1; which tcpdump; which timeout; df -h /tmp | tail -1"

echo
echo "### C) 网络面 (每次测量前现取): /32 路由 + NetworkManager 托管位 + link + coalesce"
$SSH "ip -4 addr show enp1s0f1np1 | grep -E 'inet |state'; echo ---; nmcli device show enp1s0f1np1 2>/dev/null | grep -E 'GENERAL.STATE|GENERAL.CONNECTION'; echo ---; ip route get 192.168.100.2 | head -2; echo ---; ethtool enp1s0f1np1 | grep -E 'Speed|Link detected'; echo ---; ethtool -c enp1s0f1np1 | grep -E 'Coalesce|Adaptive|rx-usecs' | head -4"

echo
echo "### D) 板上现态 (烧 0x1E 之前) —— 期望: persist 轮留下的 0x1D / 70 字 / 0x138 未实现"
$SSH --sudo "T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools; \
  echo -n 'BID_0x04='; \$T/reg_rw /dev/xdma0_user 0x04 w 2>&1 | tail -1; \
  echo -n 'MAGIC_0x00='; \$T/reg_rw /dev/xdma0_user 0x00 w 2>&1 | tail -1; \
  echo -n 'SCRATCH_0x08='; \$T/reg_rw /dev/xdma0_user 0x08 w 2>&1 | tail -1; \
  echo -n 'UNIMPL_0x138='; \$T/reg_rw /dev/xdma0_user 0x138 w 2>&1 | tail -1; \
  echo -n 'CARRIER='; cat /sys/class/net/enp1s0f1np1/carrier; \
  lspci -vvv -s 02:00.0 2>/dev/null | grep -E 'LnkSta:|Region 0|Region 1'; \
  echo -n 'DEVS='; ls /dev/xdma0_user 2>&1"

echo
echo "### E) 残留进程 (对端: sink/tcpdump/python3 探针; 本地轮内脚本)"
$SSH --sudo "pgrep -a p7b_tcp_sink; pgrep -a tcpdump; pgrep -af 'stall_probe|persist_client'; echo '(空 = 无残留)'"
echo "--- 本地 (只查 python/vivado/xsim) ---"
tasklist 2>/dev/null | grep -iE 'python|vivado|xsim' | head -10 || true

echo
echo "### STEP0_END $(date +%Y-%m-%dT%H:%M:%S%z)"
