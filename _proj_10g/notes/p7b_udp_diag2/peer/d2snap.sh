#!/bin/bash
# d2snap.sh -- 读 P7b 51 字快照窗口 (diag2 自建; 只读, 不改任何板侧/仓内文件)
# 用法: d2snap.sh [word ...]   (无参 = 打印关键 15 字)
TOOLS=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
DEV=/dev/xdma0_user
rd(){ local v; v=$($TOOLS/reg_rw $DEV "$1" w 2>/dev/null | tail -1 | sed 's/.*: *//'); case "$v" in 0x*) echo "$v";; *) echo "0xERR";; esac; }
$TOOLS/reg_rw $DEV 0x18 w 1 >/dev/null 2>&1
s=0
for i in $(seq 1 500); do s=$(rd 0x1C); [ "$((s & 2))" != "0" ] && break; done
printf 'GEN=%d STATUS=%s\n' $(( (s >> 16) & 0xffff )) "$s"
[ $# -eq 0 ] && set -- 0 1 2 3 6 7 8 9 10 11 13 20 21 31 38
for w in "$@"; do a=$(printf '0x%X' $(( 0x20 + 4*w ))); printf 'W%-3s@%s=%s\n' "$w" "$a" "$(rd $a)"; done
