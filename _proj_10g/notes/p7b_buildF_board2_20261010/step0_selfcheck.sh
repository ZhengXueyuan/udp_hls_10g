#!/bin/bash
# step0_selfcheck.sh -- P7B 构建 F 板级二轮 (2026-10-10) 步骤 0: 环境/身份/工具自证
#   判据 (全部必须逐字落盘):
#     ① 归档位流 sha256 == 89e89f31...0f45 (构建 F)
#     ② 板侧身份: ID_BID 0x0000001a + ID_UNIMPL 0xffffffff + ID_MAGIC/ID_MARKER 全中 (ID_OK)
#        ⚠️ 身份**只引** ID_BID + ID_UNIMPL; `LF_GEOM_OK NW=63` 是硬编码字面量, 不作证据
#     ③ 工具三件 md5 三方对照: 本机副本 ↔ 对端部署件 (p7b_snap 一字不许改)
#     ④ COALESCE = Adaptive RX: off / rx-usecs 0 (上一轮口径, 本轮不许动 sysctl)
#     ⑤ SNMP 解析器 smoke (字段位次自证: CurrEstab == ss -s estab)
set -u
ROOT=/d/repo/XCKU5PMini/udp_hls_10g
OUT=$ROOT/_proj_10g/notes/p7b_buildF_board2_20261010
export MSYS_NO_PATHCONV=1 PYTHONIOENCODING=utf-8
PY=/c/Users/zhxue/anaconda3/python.exe
SSH="$PY D:/repo/XCKU5PMini/udp_hls_10g/tools/peer_ssh.py"

echo "=== STEP0_BEGIN $(date +%s.%N) $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "--- ① 归档位流 sha256 ---"
sha256sum "$ROOT/_proj_10g/notes/p7b_buildF_build/F/wrapper_p4.bit"
stat -c 'BIT %n size=%s mtime=%y' "$ROOT/_proj_10g/notes/p7b_buildF_build/F/wrapper_p4.bit"
echo "want 89e89f31efb5f1450a1c39acfce587bb4e4b6347c5fdc2f470c91ff0d4400f45"

echo "--- ③ 本机工具副本 md5 ---"
md5sum "$OUT/_tools/p7b_snap.deployed.sh" "$OUT/_tools/lf_dl.base.sh" "$OUT/_tools/lf_dl_snmp.sh"

echo "--- 对端: 时间/工具 md5/身份/态 ---"
PEER_PW=111111 $SSH --sudo "date +%s.%N; date -u +%Y-%m-%dT%H:%M:%SZ; hostname; uname -r; nproc; md5sum /tmp/p7b_biz/p7b_snap.sh /tmp/p7b_biz/lf_dl.sh /tmp/p7b_biz/p7b_tcp_sink /tmp/p7b_biz/wdump.sh /tmp/p7b_board2/lf_dl_snmp.sh; echo '--- id ---'; EXPECT_BID=0x0000001A NW=70 bash /tmp/p7b_biz/p7b_snap.sh id; echo ID_RC=\$?; echo '--- 0x08 ---'; /home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools/reg_rw /dev/xdma0_user 0x08 w 2>&1 | tail -1; echo '--- carrier ---'; cat /sys/class/net/enp1s0f1np1/carrier; echo '--- COALESCE ---'; ethtool -c enp1s0f1np1 | grep -E 'Adaptive|rx-usecs'; echo '--- 残留进程 ---'; pgrep -a p7b_tcp_sink; pgrep -a tcpdump; echo '(空 = 无残留)'; echo '--- ss -s ---'; ss -s; echo '--- established (谁在用 TCP) ---'; ss -tan state established | head -8" 2>&1 | tee "$OUT/STEP0_peer.txt"

echo "--- ⑤ SNMP 解析器 smoke ---"
PEER_PW=111111 $SSH "bash /tmp/p7b_board2/snmp_smoke.sh" 2>&1 | tee "$OUT/STEP0_snmp_smoke.txt"

echo "--- 对端 /proc/net/snmp 逐字 (基线) ---"
PEER_PW=111111 $SSH "grep -A1 '^Tcp:' /proc/net/snmp | head -2" 2>&1

echo "=== STEP0_END $(date +%s.%N)"
