#!/bin/bash
# final_state.sh — 本轮收尾: (1) 板侧最终读数 (2) 对端机 /tmp 清单 (3) 网络配置复原 + 复原后复核
T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
D=/dev/xdma0_user
IF=enp1s0f1np1
rd(){ $T/reg_rw $D "$1" w 2>/dev/null | tail -1 | sed 's/.*: *//'; }
echo "=== 1. 板侧最终读数 (PCIe 观测窗口**仍然活着**) ==="
$T/reg_rw $D 0x18 w 0x1 >/dev/null 2>&1
for i in $(seq 1 400); do s=$(rd 0x1c); [ -n "$s" ] && [ $(( s & 2 )) -ne 0 ] && break; sleep 0.002; done
echo "MAGIC=$(rd 0x00) BID=$(rd 0x04) MARKER=$(rd 0x14) UNIMPL=$(rd 0xEC) gen=$(( (s >> 16) & 0xffff ))"
echo "W0=$(rd 0x20) W3=$(rd 0x2c) W8=$(rd 0x40) W10=$(rd 0x48) W13=$(rd 0x54) W14=$(rd 0x58) W20=$(rd 0x70) W34=$(rd 0xa8) W39=$(rd 0xbc) W40=$(rd 0xc0)"
echo "=== 2. 对端机 /tmp 里本轮产物清单 (取回后删) ==="
ls -la /tmp/*.pcap /tmp/*.py /tmp/*.sh 2>/dev/null
echo "=== 3. 网络配置复原 ==="
ip addr del 192.168.100.100/32 dev $IF 2>/dev/null
ip route del 192.168.100.2/32 dev $IF 2>/dev/null
rm -f /tmp/g4_rate.pcap /tmp/g4_f3.pcap /tmp/g4_f3.err /tmp/g4_tcpdump.err
echo "AFTER_CLEANUP addr: $(ip -br addr show $IF)"
echo "AFTER_CLEANUP route: $(ip route get 192.168.100.2 2>&1 | head -1)"
echo "AFTER_CLEANUP /tmp: $(ls /tmp/*.pcap 2>&1 | head -2)"
echo "hw_server=$(systemctl is-active hw_server) ; uptime=$(uptime -p)"
echo "FINAL_DONE"
