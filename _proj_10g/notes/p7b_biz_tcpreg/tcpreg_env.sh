#!/bin/bash
# tcpreg_env.sh -- 对端机前置闸 + 恢复 (每次重启后跑; 幂等)
#   ① carrier/地址/路由 ② xdma 驱动 ③ /dev/xdma0_user ④ 重烧后 PCIe 恢复
set -u
echo "HOST $(hostname) | UP $(uptime -p) | $(date)"
echo "=== NIC ==="
cat /sys/class/net/enp1s0f1np1/carrier 2>&1 | sed 's/^/CARRIER_BEFORE /'
ip link set enp1s0f1np1 up 2>/dev/null
if ! ip addr show enp1s0f1np1 | grep -qw inet; then
  ip addr add 192.168.100.100/32 dev enp1s0f1np1 2>&1
fi
ip addr show enp1s0f1np1 | grep -E "inet |state"
echo "ROUTE_GET $(ip route get 192.168.100.2 2>&1 | head -1)"
echo "=== XDMA ==="
lsmod | grep -E "^xdma" || { echo "modprobe xdma"; modprobe xdma 2>&1; sleep 2; }
ls /dev/xdma* 2>/dev/null | head -3
echo "=== PCIe 端点 ==="
lspci -s 02:00.0 2>/dev/null
lspci -vv -s 02:00.0 2>/dev/null | grep -E "LnkSta:" | head -1
ls -la /dev/xdma0_user 2>/dev/null || echo "NO_XDMA0_USER"
echo "TCPREG_ENV_DONE"
