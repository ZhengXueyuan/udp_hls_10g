#!/bin/bash
# f3_and_na_probe.sh — 本轮 F3 (图案流逐字节, 抓包) + F1 的负对照 N-a (TX_DIS 必须掉 carrier)
#   F3: 不重烧也能做 —— 板子已连续发 UDP 图案流 (port 8081), 抓 3000 帧全载荷;
#       流偏移的**绝对锚定**由本地 xs_solve.py 的 GF(2) 求解给出 (它从任意 96 连续字节
#       反解出 LFSR 状态) ⇒ 不需要"重烧到 offset 0"这一步。
#   N-a: 写 0x08=0x2 (SFP1_TX_DIS) ⇒ 网卡必须掉 carrier (否则 F1 的 "Link detected: yes"
#        可能是陈旧值 —— 本工程实测过 speed 字段在无 link 时仍读 10000 的陷阱)。
T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
D=/dev/xdma0_user
IF=enp1s0f1np1
car(){ echo "carrier=$(cat /sys/class/net/$IF/carrier) operstate=$(cat /sys/class/net/$IF/operstate) speed=$(cat /sys/class/net/$IF/speed) carrier_changes=$(cat /sys/class/net/$IF/carrier_changes)"; }

echo "=== F3: 抓 3000 帧 (板子->:8081, 全载荷 1600) ==="
timeout 30 tcpdump -Z root -i $IF -c 3000 -s 1600 -w /tmp/g4_f3.pcap 'udp and dst port 8081 and src 192.168.100.2' 2>/tmp/g4_f3.err
echo "TCPDUMP_RC=$?"
tail -3 /tmp/g4_f3.err
ls -la /tmp/g4_f3.pcap

echo "=== N-a: F1 的负对照 (TX_DIS) ==="
echo "PRE  $(car)"
$T/reg_rw $D 0x08 w 0x2 >/dev/null 2>&1
echo "SCRATCH_READBACK $($T/reg_rw $D 0x08 w 2>/dev/null | tail -1 | sed 's/.*: *//')"
sleep 3
echo "TX_DIS $(car)"
$T/reg_rw $D 0x08 w 0x0 >/dev/null 2>&1
sleep 4
echo "RESTORED $(car)"
echo "NA_DONE"
