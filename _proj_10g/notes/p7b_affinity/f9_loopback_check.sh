#!/bin/bash
# f9_loopback_check.sh -- F9 的复现脚本: 在**回环口**上跑出各程序的周期行, 验证行尾多出的
#   ` CPU_FREQ_KHZ=<n>` —— 非零、会随跑变化(轨迹)、且与同期独立读数同量级。
#   ⛔ 全程只走 127.0.0.1 —— 不碰板子 / 不碰 10G 口。
#   用法(对端机): bash /tmp/p7b_afftest/f9_loopback_check.sh
set -u
cd /tmp/p7b_biz || exit 9
exec > >(tee /tmp/f9_run.log) 2>&1      # 自留一份, 给 E) 段做自复算
REF() { echo "REFCUR cpu5=$(cat /sys/devices/system/cpu/cpu5/cpufreq/scaling_cur_freq 2>/dev/null) avail=$(cat /sys/devices/system/cpu/cpu5/cpufreq/scaling_available_frequencies 2>/dev/null)"; }
echo "### F9_LOOPBACK_BEGIN $(date -u +%Y-%m-%dT%H:%M:%SZ)  host=$(hostname)"
REF

echo "### A) sink 的 SINK_CONN 行 (回环假板推 256KB 图案)"
python3 p7b_fake_board.py --listen 127.0.0.1:18888 --bytes 262144 >/tmp/f9_fb1.log 2>&1 &
FB1=$!; sleep 0.6
./p7b_tcp_sink --host 127.0.0.1 --port 18888 --conns 1 --seconds 10 --maxbytes 1048576
echo "SINK_RC=$?"; REF
wait $FB1 2>/dev/null

echo "### B) src 的 SRC_T 行 (回环假板 hold 住连接)"
python3 p7b_fake_board.py --listen 127.0.0.1:18889 --bytes 262144 --hold 4 >/tmp/f9_fb2.log 2>&1 &
FB2=$!; sleep 0.6
./p7b_tcp_src --host 127.0.0.1 --port 18889 --seconds 3 --chunk 32768
echo "SRC_RC=$?"; REF
wait $FB2 2>/dev/null

echo "### C) udp_src 的 UDP_T 行 (回环 UDP 收豆机, 限速 200 Mbps)"
python3 -c "
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(('127.0.0.1', 18890))
while True:
    s.recvfrom(2048)
" >/dev/null 2>&1 &
UD=$!; sleep 0.6
./p7b_udp_src --host 127.0.0.1 --port 18890 --seconds 3 --mbps 200
echo "UDP_RC=$?"; REF
kill $UD 2>/dev/null

echo "### D) 其余 4 个产物 (sink_rate / src_fix / src_rate / src_diag) 的周期行"
for name in p7b_tcp_sink_rate; do
  python3 p7b_fake_board.py --listen 127.0.0.1:18891 --bytes 131072 >/tmp/f9_fb3.log 2>&1 &
  F=$!; sleep 0.6
  ./$name --host 127.0.0.1 --port 18891 --conns 1 --seconds 10 --maxbytes 1048576
  echo "${name}_RC=$?"; wait $F 2>/dev/null
done
for name in p7b_tcp_src_fix p7b_tcp_src_rate p7b_tcp_src_diag; do
  python3 p7b_fake_board.py --listen 127.0.0.1:18892 --bytes 131072 --hold 4 >/tmp/f9_fb4.log 2>&1 &
  F=$!; sleep 0.6
  ./$name --host 127.0.0.1 --port 18892 --seconds 3 --chunk 32768
  echo "${name}_RC=$?"; wait $F 2>/dev/null
done
REF

echo "### E) 判据自复算: 收集到的 CPU_FREQ_KHZ 值 (去重排序)"
grep -hoE 'CPU_FREQ_KHZ=[0-9]+' /tmp/f9_run.log 2>/dev/null | sort -u | head -20
echo "### F9_LOOPBACK_END $(date -u +%Y-%m-%dT%H:%M:%SZ)"
