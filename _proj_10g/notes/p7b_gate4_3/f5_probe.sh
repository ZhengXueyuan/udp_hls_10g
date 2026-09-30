#!/bin/bash
# f5_probe.sh — F5 (TCP fast path @10G) 板级定性探针: 板侧 TCP 相关计数 前/后 + TCP echo 激励
#   判据可读的那一半: W6/W7 (慢路径: 握手由 HLS 做) / W22 (TCP fast path 接受帧) /
#                     W14/W15 (TCP fast path 发帧/字节) / W3 (FCS 错必须 0) / W39 (PCS 状态位)
#   ⚠️ tx_stat_retx **不在 51 字窗口** ⇒ "重传计数不异常"结构上不可读 (如实标注)
T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
D=/dev/xdma0_user
rd(){ $T/reg_rw $D "$1" w 2>/dev/null | tail -1 | sed 's/.*: *//'; }
snap(){ local tag="$1"
  $T/reg_rw $D 0x18 w 0x1 >/dev/null 2>&1
  local i s; for i in $(seq 1 400); do s=$(rd 0x1c); [ -n "$s" ] && [ $(( s & 2 )) -ne 0 ] && break; sleep 0.002; done
  echo "SNAP $tag $(date +%s.%N) gen=$(( (s >> 16) & 0xffff )) W0=$(rd 0x20) W3=$(rd 0x2c) W6=$(rd 0x38) W7=$(rd 0x3c) W14=$(rd 0x58) W15=$(rd 0x5c) W20=$(rd 0x70) W22=$(rd 0x78) W23=$(rd 0x7c) W39=$(rd 0xbc) W40=$(rd 0xc0)"; }

echo "=== F5: 板侧 TCP 计数 (激励前) ==="
snap PRE
echo "=== F5: TCP echo 激励 (对端 -> 板子:8080, HLS TCP_PORT_ECHO) ==="
python3 /tmp/tcp_echo_probe.py --rounds 3 --bytes 4096 2>&1 | tail -12
echo "TCP_RC=$?"
sleep 1
echo "=== F5: 板侧 TCP 计数 (激励后) ==="
snap POST
echo "F5_DONE"
