#!/bin/bash
#=============================================================================
# p6e_boot_timeline.sh [轮数] [间隔秒] — 烧录+重启之后, 按时间线记录**慢路径多久才肯响应**
#   用法: sudo bash /home/a/xdma_test/p6e_boot_timeline.sh 24 20   (≈8 分钟)
#   为什么需要它: 2026-09-29 观测到一次"帧进了慢路径(W6 涨)但 HLS 一个包不回(W7 不动)"的窗口,
#   约 20 分钟后自愈, 机理未明。要查机理, 先得知道**这个窗口是不是每次配置后都有、持续多久** ——
#   本脚本就是回答这个的: 每轮同时抓四样东西:
#     ① 板子自报计数 (触发快照后读): W0 MAC收帧 / W5 gmii活性 / W6 交慢路径 / W7 HLS发出 / W13 图案失配
#     ② 从本机 ping 2 包 ⇒ 收到的包数 (**慢路径响应的地面真相**)
#     ③ ARP 表里有没有板子 (**ARP 有没有被应答** —— 比 ping 更早暴露"慢路径通不通")
#     ④ 网卡 RX 增量 (有没有帧从板子过来)
#   ⚠️ 判读: "W6 涨而 W7 不动 + ping 0/2 + ARP 空" = 现象复现; 若第一轮就通, 说明那次不是必然。
#   ⚠️ 只发 ICMP (不进 8081) ⇒ **不会**触发图案 app 的 peer 学习, 不会开线速灌流。
#
#   ---- 2026-09-29 地址地图更新 (本脚本**未改动列**, 这里只记事实) ----
#   快照窗口 16 -> **24 字 (P6e) -> 32 字 (P6b 双域)**: 0x20..0x5C 逐位不变 (本脚本读的都在其中),
#   新增 0x60..0x7C = W16..W23:
#     W16 0x60 srx_hls_bytes (HLS 真读走的字节) / W17 0x64 hr_cnt (看门狗复位拍数 ÷80, P6b)
#     W18 0x68 stx_stat_purge / W19 0x6C srx_stat_drop / W20 0x70 mac_tx_frames (MAC 级发帧)
#     W21 0x74 tx_stat_abort / W22 0x78 rx_stat_pass / W23 0x7C rx_stat_nonmatch
#   要看这几路的逐轮增量, 用 **p6e_slowpath_probe.sh** (它就是为"失聪"现象写的, 每轮打足流量)。
#   ⚠️ 加"未实现地址"判据时**绝不能挑 ≥0x100**: `ar_word = araddr[7:2]` 只有 6 位 ⇒ 每 256 字节
#      回绕 (0x100 别名到 MAGIC ⇒ 假 FAIL; 0x160 别名到已实现字 ⇒ 假 PASS)。**32 字版 (P6b) 用 0xB0**。
#=============================================================================
set -u
ROUNDS=${1:-24}
IV=${2:-20}
IFACE=enp3s0
BOARD=192.168.100.2
T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
D=/dev/xdma0_user
LOG=/tmp/p6e_boot_timeline.log
exec > >(tee -a "$LOG") 2>&1

rd(){ $T/reg_rw $D "$1" w 2>/dev/null | tail -1 | sed 's/.*: *//'; }
snap(){ $T/reg_rw $D 0x18 w 0x1 >/dev/null 2>&1; local i s
        for i in $(seq 1 100); do s=$(rd 0x1c); [ -n "$s" ] || continue
            [ $(( s & 2 )) -ne 0 ] && return 0; sleep 0.01; done; return 1; }

# 重启后网卡地址会被清掉 ⇒ 先补上 (否则连 ARP 都不发, 会把"我没发"误读成"板子不回")
if ! ip -br addr show "$IFACE" 2>/dev/null | grep -q "192.168.100.1"; then
    ip link set "$IFACE" up 2>/dev/null
    ip addr add 192.168.100.1/24 dev "$IFACE" && echo "[setup] 已给 $IFACE 加 192.168.100.1/24"
fi

# 等端点 (烧录后重启, 端点要 POST 完才出现)
for i in $(seq 1 60); do lspci -n 2>/dev/null | grep -q '10ee:9034' && break; sleep 2; done
if ! lsmod | grep -qw xdma; then echo "[setup] insmod"; insmod /home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/xdma/xdma.ko; sleep 2; fi
[ -e $D ] || { echo "没有 $D ⇒ 观测通道不可用, 中止"; exit 1; }
M=$(rd 0x00); B=$(rd 0x04)
echo "===== 时间线开始 $(date '+%T')  板子: MAGIC=$M BUILD_ID=$B ====="
echo "轮  t(s)  W0收帧  W6交慢路  W7HLS发  W13失配  W5gmii    ping收到  ARP表  网卡ΔRX"
RX0=$(cat /sys/class/net/$IFACE/statistics/rx_packets)
T0=$(date +%s)
for n in $(seq 1 "$ROUNDS"); do
    snap
    W0=$(( $(rd 0x20) )); W5=$(( $(rd 0x34) )); W6=$(( $(rd 0x38) ))
    W7=$(( $(rd 0x3c) )); W13=$(( $(rd 0x54) ))
    RX1=$(cat /sys/class/net/$IFACE/statistics/rx_packets)
    ARP=$(arp -n 2>/dev/null | grep -c "$BOARD")
    GOT=$(ping -c 2 -W 1 "$BOARD" 2>/dev/null | grep -oE '[0-9]+ received' | grep -oE '[0-9]+')
    printf "%2d  %4d  %6d  %8d  %7d  %8d  %8x  %8s  %5s  %7d\n" \
        "$n" "$(( $(date +%s) - T0 ))" "$W0" "$W6" "$W7" "$W13" "$W5" \
        "${GOT:-0}/2" "$ARP" "$(( RX1 - RX0 ))"
    RX0=$RX1
    sleep "$IV"
done
echo "===== 时间线结束 $(date '+%T')  日志: $LOG ====="
