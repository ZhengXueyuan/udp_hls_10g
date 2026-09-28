#!/bin/bash
# p6e_rate.sh [秒] — 用板子自己的计数测真实速率
#   ⚠️ 两个坑都写在这儿:
#   ① rd() 必须 `tail -1 | sed 's/.*: *//'`: reg_rw 会打印地址, 用 grep -oE '0x' 会把地址也抠出来;
#   ② **每次采样前必须触发快照** (写 0x18=1): 快照寄存器是"冻结到下次触发"的语义 ⇒ 不触发就
#      读到同一个冻结值, 两次相减恒 0 (本脚本第一版就是这么骗了自己)。
set -u
T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
D=/dev/xdma0_user
rd(){ $T/reg_rw $D "$1" w 2>/dev/null | tail -1 | sed 's/.*: *//'; }
snap(){ $T/reg_rw $D 0x18 w 0x1 >/dev/null 2>&1; local i s
        for i in $(seq 1 100); do s=$(rd 0x1c); [ -n "$s" ] || continue
          [ $(( s & 2 )) -ne 0 ] && return 0; sleep 0.01; done; return 1; }
SEC=${1:-5}
snap; A5=$(rd 0x34); A7=$(rd 0x3c); A8=$(rd 0x40); A9=$(rd 0x44); AD=$(rd 0x54); AE=$(rd 0x58); AF=$(rd 0x5c)
sleep "$SEC"
snap; B5=$(rd 0x34); B7=$(rd 0x3c); B8=$(rd 0x40); B9=$(rd 0x44); BD=$(rd 0x54); BE=$(rd 0x58); BF=$(rd 0x5c)
echo "间隔 ${SEC}s (板子自报, 每次采样都触发过快照):"
echo "  图案 app 发帧 W8 : $(( B8 - A8 )) 帧 = $(( (B8 - A8) / SEC )) 帧/s"
echo "  图案 app 发字节 W9: $(( B9 - A9 )) B ⇒ **$(echo $(( (B9 - A9) * 8 / SEC / 1000000 ))) Mbps**"
echo "  MAC 发帧 W14 : $(( BE - AE )) = $(( (BE - AE) / SEC )) 帧/s ; MAC 发字节 W15 = $(echo $(( (BF - AF) * 8 / SEC / 1000000 ))) Mbps"
echo "  图案 app 收帧 W10: $(( $(rd 0x48) )) ; W13 图案失配: $(( BD )) (必须 0)"
echo "  HLS 发帧 W7 : $(( B7 - A7 )) ; gmii_free W5 增量: $(( B5 - A5 )) (应 ≈ 125e6 x ${SEC})"
