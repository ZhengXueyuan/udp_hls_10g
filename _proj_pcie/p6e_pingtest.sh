#!/bin/bash
#=============================================================================
# p6e_pingtest.sh [iface] — P6a 板级正题: 真 ping 通不通, 并用数据面自己的计数解释为什么
#   用法: sudo bash /home/a/xdma_test/p6e_pingtest.sh enp3s0
#   本脚本自包含: ① 给直连板子的网卡配上 192.168.100.1/24 (板子固定 192.168.100.2)
#                 ② 采基线 ③ 起 ping ④ 边 ping 边采 ⑤ 汇总判读
#   硬判据 = **ping 自己的回显** (Reply from 192.168.100.2) —— 那才是"通了"的地面真相;
#   计数只用来解释失败在哪一环 (哪一环不涨 = 断在那一环)。
#   接线事实 (2026-09-29): 板子 RJ45 接在本机唯一 1G 网卡 enp3s0 (RTL8111E) 上;
#   本机 SSH/WiFi 走 wlp6s0, 所以给 enp3s0 加地址不会影响当前会话。
#=============================================================================
set -u
IFACE=${1:-enp3s0}
BOARD=192.168.100.2
MYCIDR=192.168.100.1/24
T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
DEV=/dev/xdma0_user
rd(){ $T/reg_rw $DEV $1 w 2>/dev/null | tail -1 | sed 's/.*: *//' | grep -oE '^0x[0-9a-fA-F]+'; }
wr(){ $T/reg_rw $DEV $1 w $2 >/dev/null 2>&1; }
snap(){ wr 0x18 0x1; local i s; for i in $(seq 1 100); do s=$(rd 0x1c); [ -z "$s" ] && continue
        [ $(( s & 2 )) -ne 0 ] && return 0; sleep 0.01; done; return 1; }
declare -a W
read8(){ local a i=0; for a in 20 24 28 2c 30 34 38 3c; do W[$i]=$(rd 0x$a); i=$((i+1)); done; }

echo "===== 0. 网卡准备 ====="
echo "-- 现有地址 --"; ip -br addr show "$IFACE"
if ! ip -br addr show "$IFACE" | grep -q "192.168.100.1"; then
  echo "-- 添加 $MYCIDR 到 $IFACE --"
  ip addr add "$MYCIDR" dev "$IFACE" 2>&1 || echo "  (添加失败或已存在)"
fi
ip link set "$IFACE" up 2>/dev/null
echo "-- 加完后 --"; ip -br addr show "$IFACE"

echo; echo "===== 1. ping 前基线 (8 样本) ====="
snap || { echo "快照触发失败 (观测通道没应答?) — 先跑 p6e_snap_check.sh"; exit 1; }
read8; f0=$((W[0])); b0=$((W[1])); k0=$((W[6])); t0=$((W[7]))
for i in $(seq 1 8); do sleep 0.3; snap && read8; done
f1=$((W[0])); k1=$((W[6])); t1=$((W[7]))
echo "  基线 Δ: W0帧=$((f1-f0))  W6进慢路=$((k1-k0))  W7 HLS发=$((t1-t0))  (2.4s 窗口)"
echo "  末次线上帧长 W2=$((W[2])) 字节, FCS错帧 W3=$((W[3]))"

echo; echo "===== 2. 起 ping (10 个, 0.3s 间隔) 并同时采样 ====="
ping -c 10 -i 0.3 -W 1 "$BOARD" > /tmp/p6e_ping.txt 2>&1 &
PINGPID=$!
sleep 0.2
f2=$((W[0])); b2=$((W[1])); k2=$((W[6])); t2=$((W[7]))
for i in $(seq 1 12); do sleep 0.3; snap && read8; done
f3=$((W[0])); b3=$((W[1])); k3=$((W[6])); t3=$((W[7]))
wait $PINGPID 2>/dev/null

echo; echo "----- ping 自己的输出 (这是硬判据) -----"
cat /tmp/p6e_ping.txt
echo "----- ping 期间的数据面增量 -----"
echo "  ΔW0帧=$((f3-f2))  ΔW1字节=$((b3-b2))  ΔW6进慢路=$((k3-k2))  ΔW7 HLS发=$((t3-t2))   (3.6s 窗口)"
echo "  末次: W2线上帧长=$((W[2])) 字节, W3错帧=$((W[3])), W4丢弃=$((W[4]))"

echo; echo "===== 3. 判读 ====="
if grep -q "bytes from $BOARD" /tmp/p6e_ping.txt; then
  echo "  [PASS] **ping 通** —— P6a 板级正题成立 (RGMII 15 根引脚全线工作)"
else
  echo "  [FAIL] ping 没通, 按【哪一环不涨】定位:"
  [ $((f3-f2)) -eq 0 ] && echo "         ΔW0=0 ⇒ PC 的帧根本没到 FPGA: 网线/网卡没 up/发到别的口去了"
  [ $((f3-f2)) -gt 0 ] && [ $((k3-k2)) -eq 0 ] && echo "         ΔW0>0 但 ΔW6=0 ⇒ 帧到了但没进慢路径: rx_classify 过滤 / IP 配置"
  [ $((k3-k2)) -gt 0 ] && [ $((t3-t2)) -eq 0 ] && echo "         ΔW6>0 但 ΔW7=0 ⇒ HLS 收到但没回: 慢路径 / ICMP 处理"
  [ $((t3-t2)) -gt 0 ] && echo "         ΔW7>0 (回包发出去了) ⇒ 回包没回到 PC: 对端 ARP 表 / 网卡"
  echo "         其他要看的: W3 错帧=$((W[3])) (物理层), W4 丢弃=$((W[4])), ip -s link show $IFACE"
  echo "         本机 ARP 表里板子条目: arp -n | grep 192.168.100.2"
fi
