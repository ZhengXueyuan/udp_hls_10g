#!/bin/bash
#=============================================================================
# p6e_capture.sh [iface] — ping 时同时抓包, 把"主机发了什么/板子回了什么"摊开看
#   用法: sudo bash /home/a/xdma_test/p6e_capture.sh enp3s0
#   为什么需要它: 上一轮只看清了"帧到 FPGA (ΔW0>0) / 进慢路径 (ΔW6>0) / 慢路径没回 (ΔW7=0)",
#     但还有两个关键歧义分不开:
#       ① 主机**到底发出去没有** (ARP 请求/ICMP echo 有没有真的上线) —— 用 iface 的 TX 计数 + 抓包
#       ② 板子**到底回没回** (有没有任何从 00:0a:35:01:fe:c0 发出来的帧) —— 抓包直接看源 MAC
#     ⇒ 抓包给的是"地面真相", 计数给的是"FPGA 自己怎么看", 两边对上才是完整证据。
#   注意: enp3s0 是直连 (点对点), 所以抓到的"从板子来的帧"只可能来自板子。
#=============================================================================
set -u
# 输出同时落盘 ⇒ 合作方 (或我) 可以直接读 /tmp/p6e_capture.log, 不必靠终端回贴
exec > >(tee -a /tmp/p6e_capture.log) 2>&1
IFACE=${1:-enp3s0}
BOARD=192.168.100.2
BOARDMAC=00:0a:35:01:fe:c0
T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
DEV=/dev/xdma0_user
rd(){ $T/reg_rw $DEV $1 w 2>/dev/null | tail -1 | sed 's/.*: *//' | grep -oE '^0x[0-9a-fA-F]+'; }
wr(){ $T/reg_rw $DEV $1 w $2 >/dev/null 2>&1; }
snap(){ wr 0x18 0x1; local i s; for i in $(seq 1 100); do s=$(rd 0x1c); [ -z "$s" ] && continue
        [ $(( s & 2 )) -ne 0 ] && return 0; sleep 0.01; done; return 1; }
declare -a W
read8(){ local a i=0; for a in 20 24 28 2c 30 34 38 3c; do W[$i]=$(rd 0x$a); i=$((i+1)); done; }
# ⚠️ 计数必须从 sysfs 拿: 早先用 `ip -s link | awk '/RX:/{r=$2}'` 把**表头行**("RX: bytes packets...")
#    当成了数值 ⇒ 拿到字面量 "bytes" ⇒ set -u 下算术展开炸掉 (unbound variable), 后面的对账全丢
srx(){ cat /sys/class/net/$IFACE/statistics/rx_packets; }
stx(){ cat /sys/class/net/$IFACE/statistics/tx_packets; }

which tcpdump >/dev/null 2>&1 || { echo "没有 tcpdump, 先装: sudo apt install -y tcpdump"; exit 2; }

echo "===== 0. 前置 ====="
ip -br addr show "$IFACE"
if ! ip -br addr show "$IFACE" | grep -q "192.168.100.1"; then
  echo "-- 加 192.168.100.1/24 --"; ip addr add 192.168.100.1/24 dev "$IFACE"
fi
snap || { echo "快照触发失败 (观测通道?)"; exit 1; }
read8; f0=$((W[0])); k0=$((W[6])); t0=$((W[7]))
r0=$(srx); tx0=$(stx)
echo "  起点: 网卡 RX=$r0 TX=$tx0 | FPGA W0=$f0 W6=$k0 W7=$t0"

echo; echo "===== 1. 抓包 + ping (12s) ====="
rm -f /tmp/p6e_ping.pcap
tcpdump -i "$IFACE" -n -e -s 200 -w /tmp/p6e_ping.pcap >/dev/null 2>&1 &
TCPID=$!
sleep 1
echo "-- ping --"
ping -c 5 -W 1 "$BOARD" 2>&1 | tail -4
echo "-- 等抓包收尾 --"
sleep 4
kill $TCPID 2>/dev/null; wait $TCPID 2>/dev/null

sleep 1
snap && read8
r1=$(srx); tx1=$(stx)
echo; echo "===== 2. 数据面增量 (整个窗口) ====="
echo "  ΔW0帧=$((W[0]-f0))  ΔW6进慢路=$((W[6]-k0))  ΔW7 HLS发=$((W[7]-t0))"
echo "  网卡侧: ΔRX=$((r1-r0)) 帧  ΔTX=$((tx1-tx0)) 帧"
echo "  ⚠️ 对账: 网卡 ΔTX 应 ≈ FPGA ΔW0 (主机发的都到了 FPGA); 网卡 ΔRX 应 ≥ 板子发出的"

echo; echo "===== 3. 抓到的帧 (最多 30 条) ====="
tcpdump -r /tmp/p6e_ping.pcap -n -e 2>/dev/null | head -30
echo
echo "-- 按源 MAC 分类计数 --"
echo "  从板子($BOARDMAC)来的: $(tcpdump -r /tmp/p6e_ping.pcap -n -e 2>/dev/null | grep -ci "$BOARDMAC")"
echo "  广播帧:               $(tcpdump -r /tmp/p6e_ping.pcap -n -e 2>/dev/null | grep -ci 'ff:ff:ff:ff:ff:ff')"
echo "  ARP:                  $(tcpdump -r /tmp/p6e_ping.pcap -n -e 2>/dev/null | grep -ci 'ARP')"
echo "  ICMP:                 $(tcpdump -r /tmp/p6e_ping.pcap -n -e 2>/dev/null | grep -ci 'ICMP')"

echo; echo "===== 4. 判读 (按抓包内容判, **不预设结论**) ====="
# ⚠️ 这一段原来写的是"如果没回 ARP 就查 HLS"这种**固定文案** —— 结果 5/5 全通的那一轮里
#    它照样打印"⇒ 慢路径没回 ARP, 去查 HLS", 与事实相反 (打印与检查脱节, 与审查 agent 在
#    单元门里抓到的 F2 同一类错)。现在一律**按抓到的内容**分支。
n_board=$(tcpdump -r /tmp/p6e_ping.pcap -n -e 2>/dev/null | grep -ci "$BOARDMAC")
n_icmp=$( tcpdump -r /tmp/p6e_ping.pcap -n -e 2>/dev/null | grep -ci "ICMP")
n_arp=$(  tcpdump -r /tmp/p6e_ping.pcap -n -e 2>/dev/null | grep -ci "ARP")
n_whohas=$(tcpdump -r /tmp/p6e_ping.pcap -n -e 2>/dev/null | grep -ci "who-has $BOARD")
if [ "$n_icmp" -ge 2 ]; then
  echo "  [PASS] 抓包里 ICMP 成对出现 (共 $n_icmp 帧) ⇒ 板子在回 echo, 慢路径通"
elif [ "$n_whohas" -gt 0 ] && [ "$n_board" -eq 0 ]; then
  echo "  [FAIL] 有 who-has 但**没有任何**来自板子的帧 ($n_arp 条 ARP) ⇒ 慢路径没回 ARP"
  echo "         ⇒ 查 HLS: hls_rst_n 是否一直被拉低 / 饥饿看门狗是否在反复复位它"
elif [ "$n_whohas" -eq 0 ] && [ "$n_board" -eq 0 ]; then
  echo "  [FAIL] 连 who-has 都没有 ⇒ 主机的 ARP 没上线 ⇒ 查主机侧 (网卡/路由/网段)"
else
  echo "  [WARN] 抓到板子的帧 ($n_board) 但没解出 ICMP/ARP ⇒ 帧格式可疑, 逐条看上面"
fi

echo; echo "===== 5. 稳定性: 10 轮 x 3 包, 每轮间隔 2s (回答【那次不响应是一次性还是间歇】) ====="
LOST=0
for i in $(seq 1 10); do
  out=$(ping -c 3 -W 1 "$BOARD" 2>&1 | tail -2 | grep -E 'packet loss|received')
  got=$(echo "$out" | grep -oE "[0-9]+ received, [0-9]+% packet loss")
  echo "  轮 $i: ${got:-无输出}"
  echo "$out" | grep -q "0% packet loss" || LOST=$((LOST+1))
  sleep 2
done
echo "  ⇒ 10 轮里丢包的轮数 = $LOST"
if [ "$LOST" -eq 0 ]; then
  echo "  [PASS] 稳定性: 10/10 轮全通 (慢路径无间歇失效)"
else
  echo "  [FAIL] 稳定性: $LOST/10 轮丢包 => 慢路径存在间歇失效, 下一步查 hls_rst_n / 饥饿看门狗"
fi
