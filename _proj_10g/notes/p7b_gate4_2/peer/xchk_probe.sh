#!/bin/bash
# xchk_probe.sh — 板侧自报(W20/W8) 与 网卡硬件计数 的**同时刻**两点测量 (N_XCHK / N_SELF 独立口径)
#   为什么另写: p7b_gate4_accept.sh 的 N_XCHK 守卫 `[ -n "${NQ_NC+x}" ]` 对**关联数组**恒为假
#   (bash 语义: ${assoc+x} 只测下标 0) ⇒ 该判据在脚本里**结构性永不评估**。本脚本不改验收脚本,
#   只用同一批口径手工取两点。同时给 N_SELF (Δgood+Δbad == Δpackets) 一个独立复算的机会。
#   只读: 不开写寄存器(除快照触发 0x18), 不改网络配置, 不烧板。
T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
D=/dev/xdma0_user
rd(){ $T/reg_rw $D "$1" w 2>/dev/null | tail -1 | sed 's/.*: *//'; }
wr(){ $T/reg_rw $D "$1" w "$2" >/dev/null 2>&1; }
snap(){
  local g0 g1 s i
  g0=$(rd 0x1c); g0=$(( (g0 >> 16) & 0xffff ))
  wr 0x18 0x1
  s=""
  for i in $(seq 1 400); do s=$(rd 0x1c); [ -z "$s" ] && continue; [ $(( s & 2 )) -ne 0 ] && break; sleep 0.002; done
  g1=$(rd 0x1c); g1=$(( (g1 >> 16) & 0xffff ))
  printf 'GEN %s %s\n' "$g0" "$g1"
  for w in 0 1 3 8 9 10 11 13 16 20 21 30 31 34 38 41 43 44 45; do
    printf 'W%s %s\n' "$w" "$(rd "$(printf '0x%X' $((0x20 + 4*w)))")"
  done
}
nic(){ ethtool -S enp1s0f1np1 | grep -E '^ +(port_rx_(packets|good|bad|bytes|good_bytes|unicast|multicast|broadcast|64|128_to_255|1024_to_15xx|overflow|nodesc_drops)|rx_eth_crc_err|rx_frm_trunc):' | tr -d ' ' | tr ':' ' '; }

echo "IPROUTE $(ip route get 192.168.100.2 2>&1 | head -2 | tr '\n' '|')"
for k in A B; do
  t0=$(date +%s.%N)
  echo "NIC_BEGIN $k"
  nic
  t1=$(date +%s.%N)
  echo "NIC_TS $k $t0 $t1"
  echo "SNAP_BEGIN $k"
  snap
  echo "SNAP_TS $k $(date +%s.%N)"
  echo "SNAP_END $k"
  [ "$k" = A ] && sleep 5
done
echo "PROBE_DONE"
