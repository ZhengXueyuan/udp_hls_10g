#!/bin/bash
# s2_setup.sh -- P7B-BIZ Stage 2 对端侧一次性环境恢复 (重启后必跑)
#   用法(对端机): bash /tmp/p7b_biz/s2_setup.sh
#   前置: 先把 p7b_biz_tools.tgz 放到 /tmp/p7b_biz_tools.tgz
set -u
echo "### S2_SETUP_BEGIN $(date +%s.%N)"
mkdir -p /tmp/p7b_biz || { echo "S2_SETUP_FAIL mkdir"; exit 1; }
tar -xzf /tmp/p7b_biz_tools.tgz -C /tmp/p7b_biz || { echo "S2_SETUP_FAIL untar"; exit 1; }
chmod +x /tmp/p7b_biz/*.sh /tmp/p7b_biz/*.py 2>/dev/null
cd /tmp/p7b_biz || exit 1
ls -la | head -25
echo "### COMPILE $(date +%s.%N)"
g++ -O2 -o p7b_tcp_sink p7b_tcp_sink.cpp 2>&1 | head -5 ; echo "sink_rc=${PIPESTATUS[0]}"
g++ -O2 -o p7b_tcp_src  p7b_tcp_src.cpp  2>&1 | head -5 ; echo "src_rc=${PIPESTATUS[0]}"
g++ -O2 -o p7b_udp_src  p7b_udp_src.cpp  2>&1 | head -5 ; echo "udp_rc=${PIPESTATUS[0]}"
for b in p7b_tcp_sink p7b_tcp_src p7b_udp_src; do
  [ -x "$b" ] && echo "BIN_OK $b $(stat -c %s $b)" || echo "BIN_MISSING $b"
done
echo "### SELFTESTS $(date +%s.%N)"
python3 p7b_tcp_badbyte.py --selftest 2>&1 | tail -2
./p7b_udp_src --help >/dev/null 2>&1 && echo "UDP_SRC_HELP_OK" || echo "UDP_SRC_HELP_FAIL"
echo "### S2_SETUP_DONE $(date +%s.%N)"
