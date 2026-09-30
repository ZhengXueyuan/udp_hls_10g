#!/bin/bash
# nb_probe.sh — 重烧后两块判据:
#   ① 静默核查: peer 表已被位流复位 ⇒ 板子零图案帧 (网卡硬件计数不涨)
#   ② N-b 负对照: `--no-teach` ⇒ 只有背景 HELLO/ARP 小帧 (工具退出码 1)
T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
D=/dev/xdma0_user
nic(){ ethtool -S enp1s0f1np1 | grep -E '^ +(port_rx_(good|bad|packets|bytes|unicast|broadcast|64|128_to_255|1024_to_15xx)|rx_eth_crc_err):' | tr -d ' ' | tr ':' ' ' | tr '\n' ' '; echo; }
echo "carrier=$(cat /sys/class/net/enp1s0f1np1/carrier) carrier_changes=$(cat /sys/class/net/enp1s0f1np1/carrier_changes)"
echo "NIC_A $(date +%s.%N)"; nic
echo "SLEEP 5 (纯静默)"; sleep 5
echo "NIC_B $(date +%s.%N)"; nic
echo "=== N-b: --no-teach (10 s) ==="
cd /home/a/xdma_test && ./p6e_udp_pattern --secs 10 --board 192.168.100.2 --port 8081 --no-teach 2>&1 | tail -12
echo "NB_RC=$?"
echo "NIC_C $(date +%s.%N)"; nic
echo "NB_DONE"
