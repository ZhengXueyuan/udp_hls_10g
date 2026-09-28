#!/bin/bash
#=============================================================================
# p6e_snap_check.sh — P6e **合体版**验收: 数据面计数经 PCIe 寄存器窗口读出来
#   前置: (1) FPGA 已烧上 p6e (合体) 位流 —— BUILD_ID 必须 = 0x00000002;
#         (2) **主机已在烧录之后重启过** (PCIe 端点只认"配置先于 POST"; 见 _pcie/README.md);
#         (3) 驱动已 insmod (本脚本自己 insmod)。
#   用法: sudo bash /home/a/xdma_test/p6e_snap_check.sh     日志: /tmp/p6e_snap_check.log
#
#   最有价值的一条 = 判据 4: **gmii 域自由计数器在两次快照之间的增量**。
#   它一次回答两个问题:
#     ① PHY 回送的 RXC 时钟到底有没有在跑 (这块板没有 UART, 别的手段问不出来);
#     ② 反解出它的实际频率 (应 ≈125MHz; 也顺带证明快照 CDC 真的在搬数)。
#   数据面"死了"还是"没时钟"这两件事, 靠这一个计数分开 —— 不算出频率就没法区分。
#=============================================================================
set -u
KO=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/xdma/xdma.ko
TOOLS=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
DEV=/dev/xdma0_user
LOG=/tmp/p6e_snap_check.log
EXPECT_BID=0x00000002          # 合体版位流身份 (前置闸)
PASS=0; FAIL=0
exec > >(tee "$LOG") 2>&1
echo "########## P6e 合体版验收 (数据面 + 观测通道) $(date '+%F %T') ##########"
chk(){ if [ "$2" = "$3" ]; then echo "  [PASS] $1: $2"; PASS=$((PASS+1));
       else echo "  [FAIL] $1: got='$2' want='$3'"; FAIL=$((FAIL+1)); fi; }

# reg_rw 的输出形如 "Read 32-bit ... : 0x12345678" ⇒ 抠最后一个 0x........
rd(){ $TOOLS/reg_rw $DEV $1 w 2>/dev/null | tail -1 | sed 's/.*: *//' | grep -oE '^0x[0-9a-fA-F]+'; }
wr(){ $TOOLS/reg_rw $DEV $1 w $2 >/dev/null 2>&1; }

# 触发一次快照并等 done (SNAP_STATUS.bit1); done 是 sticky 的 ⇒ 不会漏看
snap_take(){
  wr 0x18 0x1
  local i s
  for i in $(seq 1 100); do
    s=$(rd 0x1c); [ -z "$s" ] && continue
    [ $(( s & 2 )) -ne 0 ] && return 0
    sleep 0.02
  done
  return 1
}
# 快照字 W0..W7 (0x20,0x24,...,0x3c) 一次读全, 打印成一行
snap_words(){
  local a
  for a in 20 24 28 2c 30 34 38 3c; do printf "%s " "$(rd 0x$a)"; done
  echo
}

echo; echo "===== 0. 前提 ====="
lspci -nn | grep -i 10ee || { echo "  [FAIL] 端点不在 (先重启主机!)"; exit 1; }
# 别把 BDF 钉死 (上次是 02:00.0, 换槽/换内核都可能变) —— 现查现用
BDF=$(lspci -n | grep -i '10ee:9034' | awk '{print $1}' | head -1)
echo "  [INFO] 端点 BDF = ${BDF:-未找到}"
chk "0.1 链路" "$(cat /sys/bus/pci/devices/0000:${BDF}/current_link_speed 2>/dev/null)" "5.0 GT/s PCIe"
if ! lsmod | grep -qw xdma; then echo "  (insmod)"; insmod "$KO" || { echo "  [FAIL] insmod"; exit 1; }; sleep 2; fi
ls /dev/xdma0_* | tr '\n' ' '; echo
if [ -e $DEV ]; then echo "  [PASS] 0.2 user BAR 节点存在 ($DEV)"; PASS=$((PASS+1));
else echo "  [FAIL] 0.2 没有 $DEV"; FAIL=$((FAIL+1)); exit 1; fi

echo; echo "===== 1. 身份 (前置闸: 认位流) ====="
chk "1.1 MAGIC (0x00)"  "$(rd 0x00)" "0x50360001"
chk "1.2 BUILD_ID (0x04) = 合体版" "$(rd 0x04)" "$EXPECT_BID"
chk "1.3 MARKER (0x14)" "$(rd 0x14)" "0xdeadbeef"
hw=$(rd 0x10); echo "  [INFO] 1.4 HW_STATUS (0x10) = $hw  (bit0 = user_lnk_up, bit1 = msi_enable)"

echo; echo "===== 2. 快照触发协议 (0x18 / 0x1C) ====="
s0=$(rd 0x1c)
if snap_take; then echo "  [PASS] 2.1 触发后 done 置起"; PASS=$((PASS+1));
else echo "  [FAIL] 2.1 触发后 done 一直不置 (gmii 时钟没跑?)"; FAIL=$((FAIL+1)); fi
s1=$(rd 0x1c)
echo "  [INFO] SNAP_STATUS: 触发前 $s0 -> 触发后 $s1 (bit0=busy bit1=done bit2=seen, [31:16]=gen)"
if [ -n "$s0" ] && [ -n "$s1" ] && [ $(( s1 >> 16 )) -eq $(( (s0 >> 16) + 1 )) ]; then
  echo "  [PASS] 2.2 gen 恰好 +1"; PASS=$((PASS+1))
else echo "  [FAIL] 2.2 gen 不是恰好 +1 ($s0 -> $s1)"; FAIL=$((FAIL+1)); fi

echo; echo "===== 3. 读窗口原子性 (不重新触发 ⇒ 8 字必须逐位不变) ====="
R1=$(snap_words); R2=$(snap_words)
echo "  [INFO] 第 1 次: $R1"
echo "  [INFO] 第 2 次: $R2"
chk "3.1 未触发时 8 字完全不变" "$R1" "$R2"

echo; echo "===== 4. ★ GMII 时钟活性 + 频率反解 (W5 = 0x34) ====="
snap_take; A=$(rd 0x34); T1=$(date +%s.%N)
sleep 0.5
snap_take; B=$(rd 0x34); T2=$(date +%s.%N)
if [ -z "$A" ] || [ -z "$B" ]; then echo "  [FAIL] 4.1 W5 读不出来"; FAIL=$((FAIL+1))
else
  DA=$((A)); DB=$((B)); DT=$(awk -v t1="$T1" -v t2="$T2" 'BEGIN{printf "%.4f", t2-t1}')
  echo "  [INFO] W5(gmii_free): $A -> $B   Δ=$((DB-DA)) / ${DT}s"
  if [ "$DB" -gt "$DA" ]; then
    echo "  [PASS] 4.1 **GMII 时钟在跑** (数据面时钟活着)"; PASS=$((PASS+1))
    echo "  [INFO] 4.2 GMII 时钟 ≈ $(awk -v d=$((DB-DA)) -v t="$DT" 'BEGIN{printf "%.2f", d/t/1e6}') MHz  (1G 时应 ≈125)"
  else echo "  [FAIL] 4.1 GMII 时钟**没在跑** (RXC 没来 / PHY 没起 / 网线没插)"; FAIL=$((FAIL+1)); fi
fi

echo; echo "===== 5. 数据面计数快照 (W0..W7) ====="
snap_take
W0=$(rd 0x20); W1=$(rd 0x24); W2=$(rd 0x28); W3=$(rd 0x2c)
W4=$(rd 0x30); W5=$(rd 0x34); W6=$(rd 0x38); W7=$(rd 0x3c)
cat <<EOF
  W0 0x20 rx_stat_frames (MAC 收帧数)      = $W0
  W1 0x24 rx_stat_bytes  (MAC 收字节)      = $W1
  W2 0x28 {16'd0,wl_last} (最近线上帧长)   = $W2
  W3 0x2c rx_stat_crc_err (FCS 错帧)       = $W3
  W4 0x30 rx_stat_drop   (MAC 丢弃)        = $W4
  W5 0x34 gmii_free      (gmii 自由计数)   = $W5
  W6 0x38 srx_stat_commit (交 HLS 慢路径)  = $W6
  W7 0x3c stx_stat_frames (HLS 发出帧)     = $W7
EOF
echo "  [INFO] 判读: 有 ping 流量时 W0/W1 应涨; 若 W0 涨而 W6 不涨 ⇒ 帧没进慢路径 (ARP/ICMP 收不到);"
echo "          W6 涨而 W7 不涨 ⇒ HLS 收到了但没回 ⇒ 问题在慢路径/HLS, 不在前端。"

echo; echo "===== 6. 负向: 未实现地址必须走 SLVERR ====="
U44=$(rd 0x44); U00=$(rd 0x00)
echo "  [INFO] 0x44 (未实现) = $U44 ; 0x00 (实现) = $U00"
if [ "$U44" = "0xffffffff" ] && [ "$U44" != "$U00" ]; then
  echo "  [PASS] 6.1 未实现地址返回 0xffffffff (SLVERR)"; PASS=$((PASS+1))
else echo "  [FAIL] 6.1 未实现地址读出 $U44 ⇒ 译码可能过宽"; FAIL=$((FAIL+1)); fi

echo; echo "########## 汇总: PASS=$PASS FAIL=$FAIL ##########"
echo "########## 日志: $LOG ##########"
exit $FAIL
