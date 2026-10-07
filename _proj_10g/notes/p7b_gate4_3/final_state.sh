#!/bin/bash
# final_state.sh — 本轮收尾: (1) 板侧最终读数 (2) 对端机 /tmp 清单 (3) 网络配置复原 + 复原后复核
T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
D=/dev/xdma0_user
IF=enp1s0f1np1
rd(){ $T/reg_rw $D "$1" w 2>/dev/null | tail -1 | sed 's/.*: *//'; }
echo "=== 1. 板侧最终读数 (PCIe 观测窗口**仍然活着**) ==="
$T/reg_rw $D 0x18 w 0x1 >/dev/null 2>&1
for i in $(seq 1 400); do s=$(rd 0x1c); [ -n "$s" ] && [ $(( s & 2 )) -ne 0 ] && break; sleep 0.002; done
BID=$(rd 0x04)
echo "MAGIC=$(rd 0x00) BID=$BID MARKER=$(rd 0x14) UNIMPL=$(rd 0x11C) gen=$(( (s >> 16) & 0xffff ))"
# ⚠️ UNIMPL 地址跟窗口宽度走: **63 字 (P7B-WU 二轮起) ⇒ 0x11C** (word 71);
#    61 字 (P7B-BIZ) ⇒ 0x114; 51 字 (RATE) ⇒ 0xEC。
#    绝不能用 ≥0x200 —— 读侧 ar_word 7 位, 地址每 512 字节回绕 ⇒ 0x200 别名回 MAGIC。
# ⚠️ **前置闸 (本脚本原先没有)**: 上面这行与下面两行都**不判断**读数对不对 —— 拿新口径读旧位流
#    会把 W61/W62 读成 0xffffffff (SLVERR) 而**看着像数据** ⇒ 必须由 BID 认代。
#    (口径: 9 = 63 字 / 0x04 的期望值见 board/wrapper_p4.v 的 BUILD_ID_V。)
if [ "$BID" != "0x00000009" ]; then
  echo "  [ABORT] BID=$BID != 0x00000009 ⇒ **板上不是 63 字位流**; 下面 W61/W62 若为 0xffffffff 是 SLVERR(读失败) 不是数据"
  GATE_BAD=1
else
  GATE_BAD=0
fi
echo "W0=$(rd 0x20) W3=$(rd 0x2c) W8=$(rd 0x40) W10=$(rd 0x48) W13=$(rd 0x54) W14=$(rd 0x58) W20=$(rd 0x70) W34=$(rd 0xa8) W39=$(rd 0xbc) W40=$(rd 0xc0)"
echo "W51=$(rd 0xec) W52=$(rd 0xf0) W53=$(rd 0xf4) W54=$(rd 0xf8) W55=$(rd 0xfc) W56=$(rd 0x100) W57=$(rd 0x104) W58=$(rd 0x108) W59=$(rd 0x10c) W60=$(rd 0x110)  # P7B-BIZ 十字"
echo "W61=$(rd 0x114) W62=$(rd 0x118)  # P7B-WU 二轮新增 (stat_wu / rx_occ_bytes)"
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
# 前置闸没过 ⇒ 出声 (本脚本的读数只在 BID=9 的板上才算数)
if [ "${GATE_BAD:-0}" != "0" ]; then echo "FINAL_STATE_INVALID (前置闸未过: BID != 9 ⇒ 窗口口径不符)"; exit 3; fi
echo "FINAL_DONE"
