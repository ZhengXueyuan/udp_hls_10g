#!/bin/bash
#=============================================================================
# p6b_smoke_account.sh — 冒烟测试 stage D: 观测通道对账 + 结构式守恒律
#   新增文件 (冒烟测试 agent 写); 守卫逐字照抄 p6e_slowpath_probe.sh / p6b_accept.sh:
#   rd() 读失败返回非零 / 0xffffffff 一律 SKIP / snap() 的 gen 恰好 +1 自证 —— 不简化。
#   本次测量针对**非最终位流** (不含 F4 第二轮修复)。
#   用法: sudo bash /home/a/xdma_test/p6b_smoke_account.sh
#=============================================================================
set -u
TOOLS=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
DEV=/dev/xdma0_user
IFACE=${1:-enp3s0}
W32=$((1<<32))
exec > >(tee /tmp/p6b_smoke_account.log) 2>&1

rd(){ local v; v=$($TOOLS/reg_rw $DEV "$1" w 2>/dev/null | tail -1 | sed 's/.*: *//')
      [[ "$v" =~ ^0[xX][0-9a-fA-F]{1,8}$ ]] || return 1; echo "$v"; }
wr(){ $TOOLS/reg_rw $DEV "$1" w "$2" >/dev/null 2>&1; }
snap(){ local g0 g1 s i
        g0=$(rd 0x1c) || return 1; g0=$(( (g0 >> 16) & 0xffff ))
        wr 0x18 0x1
        for i in $(seq 1 100); do s=$(rd 0x1c) || continue
            [ $(( s & 2 )) -ne 0 ] && break; sleep 0.01; done
        g1=$(rd 0x1c) || return 1; g1=$(( (g1 >> 16) & 0xffff ))
        [ $(( (g1 - g0) & 0xffff )) -eq 1 ]; }
declare -a W
# 读全 36 个已实现字 (0x20..0xAC); 任一读空 ⇒ 整轮作废
readall(){ local a i=0 v; for a in 20 24 28 2c 30 34 38 3c 40 44 48 4c 50 54 58 5c 60 64 68 6c 70 74 78 7c 80 84 88 8c 90 94 98 9c a0 a4 a8 ac; do
             v=$(rd 0x$a) || return 1; W[$i]=$(( v )); i=$((i+1)); done; }
dd(){ local d=$(( ($2 - $1) % W32 )); echo $(( d < 0 ? d + W32 : d )); }
round(){ local m; m=$(rd 0x00) || return 1
         [ "$(( m ))" -eq "$(( 0x50360001 ))" ] || return 1
         snap || return 1; readall || return 1; }

echo "########## P6b 冒烟对账 (stage D) $(date '+%F %T') —— 非最终位流 ##########"
echo "MAGIC=$(rd 0x00) BUILD_ID=$(rd 0x04) MARKER=$(rd 0x14)"
echo "-- 未实现地址 0xB0 (SKIP 语义自检) = $(rd 0xb0) --"
echo "-- 网卡硬件计数 (独立口径) rx_packets=$(cat /sys/class/net/$IFACE/statistics/rx_packets) --"
echo "-- kernel UDP 丢包计数 (/proc/net/snmp) --"
awk '/^Udp:/{hdr=$0; getline; print "  hdr: "hdr; print "  val: "$0}' /proc/net/snmp

if ! round; then echo "[FAIL] 起点 round() 自证不成立 (MAGIC / gen+1 / 空读) ⇒ 读数作废"; exit 1; fi
A0=${W[0]}; A1=${W[1]}; A3=${W[3]}; A6=${W[6]}; A7=${W[7]}; A8=${W[8]}; A9=${W[9]}
A13=${W[13]}; A17=${W[17]}; A18=${W[18]}; A19=${W[19]}; A20=${W[20]}; A30=${W[30]}; A31=${W[31]}
echo
echo "=== 绝对值 (快照 W0..W35 @ 0x20..0xAC) ==="
printf "  W0  (0x20) MAC收帧        = %s\n" "${W[0]}"
printf "  W1  (0x24) MAC收字节      = %s\n" "${W[1]}"
printf "  W3  (0x2c) FCS错帧        = %s\n" "${W[3]}"
printf "  W5  (0x34) 前端gmii_free  = %s\n" "${W[5]}"
printf "  W6  (0x38) 交慢路径帧     = %s\n" "${W[6]}"
printf "  W7  (0x3c) HLS发帧        = %s\n" "${W[7]}"
printf "  W8  (0x40) 图案app发帧    = %s\n" "${W[8]}"
printf "  W9  (0x44) 图案app发字节  = %s\n" "${W[9]}"
printf "  W10 (0x48) 图案app收帧    = %s\n" "${W[10]}"
printf "  W13 (0x54) 图案失配       = %s\n" "${W[13]}"
printf "  W17 (0x64) 看门狗拍       = %s\n" "${W[17]}"
printf "  W18 (0x68) 整帧回卷       = %s\n" "${W[18]}"
printf "  W19 (0x6c) 适配器丢帧     = %s\n" "${W[19]}"
printf "  W20 (0x70) MAC发帧        = %s\n" "${W[20]}"
printf "  W21 (0x74) MAC帧内中止    = %s\n" "${W[21]}"
printf "  W24 (0x80) 数据面自由计数 = %s\n" "${W[24]}"
printf "  W25 (0x84) MMCM状态字     = %s   (bit0=locked)\n" "${W[25]}"
printf "  W26/W27 (0x88/0x8c) rxcdc 满拍/占用峰值 = %s / %s\n" "${W[26]}" "${W[27]}"
printf "  W28/W29 (0x90/0x94) txcdc 峰值/DP等线拍 = %s / %s\n" "${W[28]}" "${W[29]}"
printf "  W30 (0x98) rxcdc读侧帧数  = %s\n" "${W[30]}"
printf "  W31 (0x9c) rxcdc读侧字节  = %s\n" "${W[31]}"
printf "  W32 (0xa0) drop_partial   = %s\n" "${W[32]}"
printf "  W33 (0xa4) orphan_bytes   = %s\n" "${W[33]}"
printf "  W34 (0xa8) drop_full      = %s\n" "${W[34]}"
printf "  W35 (0xac) fifo_ovf       = %s\n" "${W[35]}"

NIC_A=$(cat /sys/class/net/$IFACE/statistics/rx_packets)
sleep 1
if ! round; then echo "[FAIL] 终点 round() 自证不成立 ⇒ 增量作废"; exit 1; fi
NIC_B=$(cat /sys/class/net/$IFACE/statistics/rx_packets)
echo
echo "=== 结构式守恒律 (mod 2^32) ==="
R30=$(( (W[0] + W[32]) % W32 )); R31=$(( (W[1] - 4*W[0] + W[33]) % W32 ))
R30=$(( (R30 + W32) % W32 ));     R31=$(( (R31 + W32) % W32 ))
echo "  律1 W30 == W0 + W32        : 实测 W30=${W[30]}  期望 ${R30}  ⇒ $([ "${W[30]}" -eq "$R30" ] && echo PASS || echo "FAIL (差 $(( W[30] - R30 )))")"
echo "  律2 W31 == W1 - 4W0 + W33  : 实测 W31=${W[31]}  期望 ${R31}  ⇒ $([ "${W[31]}" -eq "$R31" ] && echo PASS || echo "FAIL (差 $(( W[31] - R31 )))")"
echo "  有向 W0 - W30 >= -1        : $(( W[0] - W[30] )) ⇒ $([ $(( W[0] - W[30] )) -ge -1 ] && echo PASS || echo FAIL)"
echo "  W35 == 0 (fifo_sync 拒写)  : ${W[35]} ⇒ $([ "${W[35]}" -eq 0 ] && echo PASS || echo FAIL)"
echo "  1s 窗口增量: dW0=$(dd $A0 ${W[0]}) dW1=$(dd $A1 ${W[1]}) dW6=$(dd $A6 ${W[6]}) dW7=$(dd $A7 ${W[7]}) dW8=$(dd $A8 ${W[8]}) dW9=$(dd $A9 ${W[9]}) dW17=$(dd $A17 ${W[17]}) dW18=$(dd $A18 ${W[18]}) dW19=$(dd $A19 ${W[19]}) dW20=$(dd $A20 ${W[20]}) dW30=$(dd $A30 ${W[30]}) dW31=$(dd $A31 ${W[31]}) dW32=$(dd ${W[32]} ${W[32]})"
echo "  恒 0 类 (绝对值): W3=${W[3]} W13=${W[13]} W17=${W[17]} W18=${W[18]} W19=${W[19]} W32=${W[32]} W33=${W[33]} W34=${W[34]} W35=${W[35]}"
echo "  1s 内网卡 rx_packets 增量 = $(( NIC_B - NIC_A )) ⇒ ≈ $(awk -v d=$(( NIC_B - NIC_A )) 'BEGIN{printf "%.1f", d*1514*8/1e6}') Mbps (线上口径 1514B/帧)"
echo "  板子自报图案发帧 W8=${W[8]} ⇒ 累计 ${W[9]} 字节 / ${W[8]} 帧 = $(awk -v b=${W[9]} -v f=${W[8]} 'BEGIN{printf "%.2f", (f>0)? b/f : 0}') B/帧"
echo "日志: /tmp/p6b_smoke_account.log"
