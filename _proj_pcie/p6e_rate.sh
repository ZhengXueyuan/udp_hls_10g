#!/bin/bash
#=============================================================================
# p6e_rate.sh [秒] — 用**板子自报的计数**测真实速率 (与我的接收侧无关)
#   用法: sudo bash /home/a/xdma_test/p6e_rate.sh 5
#   为什么要板子自报: 用户态 socket 在 ~80k pps 下内核缓冲必然溢出, 收到的包数**远低于**
#   板子实际发出的 ⇒ 拿它当"板子能跑多快"会把自己的天花板误判成板子的能力
#   (本工程 2026-09-29 实测: 用户态收 6.4 Mbps, 而板子自报 931 Mbps = 线速)。
#   交叉验证: 网卡硬件计数 /sys/class/net/<if>/statistics/rx_packets 也可以 (不是 socket 口径)。
#
#   ⚠️ 三个坑都在这支脚本里踩过, 写下来免得重犯:
#   ① rd() 必须 `tail -1 | sed 's/.*: *//'`: reg_rw 会打印 "at address 0xNN (0x..) : 0xVV",
#      用 grep -oE '0x...' 会把**地址**也抠出来 ⇒ 后面算术全乱。
#   ② **每次采样前必须触发快照** (写 0x18=1): 快照寄存器是"冻结到下次触发"的语义 ⇒
#      不触发就读到同一个冻结值, 两次相减恒 0 (第一版就是这么骗了自己的)。
#   ③ 计数是 32 位且**会回绕**: 931 Mbps 下 W9 每 ~37s 绕一圈 ⇒ 裸减法会给出负速率
#      (上一版打印过 "-10520 Mbps")。一律先取模 2^32。
#=============================================================================
set -u
T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
D=/dev/xdma0_user
W=$((1<<32))
rd(){ $T/reg_rw $D "$1" w 2>/dev/null | tail -1 | sed 's/.*: *//'; }
snap(){ $T/reg_rw $D 0x18 w 0x1 >/dev/null 2>&1
        local i s
        for i in $(seq 1 100); do s=$(rd 0x1c); [ -n "$s" ] || continue
            [ $(( s & 2 )) -ne 0 ] && return 0; sleep 0.01; done
        return 1; }
dd(){ echo $(( (($2 - $1) % W + W) % W )); }          # 增量 (模 2^32, 抗回绕)
ps(){ echo $(( $(dd "$1" "$2") / $3 )); }             # 每秒
mb(){ echo $(( $(dd "$1" "$2") * 8 / $3 / 1000000 )); }   # Mbps

SEC=${1:-5}
snap || { echo "快照触发失败 (观测通道没应答?)"; exit 1; }
A5=$(rd 0x34); A7=$(rd 0x3c); A8=$(rd 0x40); A9=$(rd 0x44)
AA=$(rd 0x48); AB=$(rd 0x4c); AD=$(rd 0x54); AE=$(rd 0x58); AF=$(rd 0x5c)
sleep "$SEC"
snap || { echo "第二次快照触发失败"; exit 1; }
B5=$(rd 0x34); B7=$(rd 0x3c); B8=$(rd 0x40); B9=$(rd 0x44)
BA=$(rd 0x48); BB=$(rd 0x4c); BD=$(rd 0x54); BE=$(rd 0x58); BF=$(rd 0x5c)

echo "采样间隔 ${SEC}s (板子自报; 每次采样都触发过快照):"
echo "  W8  图案 app 发帧  : $(dd $A8 $B8) 帧 = $(ps $A8 $B8 $SEC) 帧/s"
echo "  W9  图案 app 发字节: $(dd $A9 $B9) B"
echo "  ==> **板子图案 TX ≈ $(mb $A9 $B9 $SEC) Mbps**  (板子自报, 与我的接收侧无关)"
echo "  W10 图案 app 收帧: $(dd $AA $BA) ; W11 收字节: $(dd $AB $BB) ; W13 图案失配: $(( BD )) (必须 0)"
echo "  W14/W15 (tcp_tx_frame, **非 MAC**): $(dd $AE $BE) 帧 / $(dd $AF $BF) B"
echo "  W7  HLS 发帧: $(dd $A7 $B7) ; W5 gmii_free 增量: $(dd $A5 $B5) (应 ≈ 125e6 x ${SEC})"
