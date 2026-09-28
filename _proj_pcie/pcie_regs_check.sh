#!/bin/bash
#=============================================================================
# pcie_regs_check.sh — P6e 最小版**验收**: 从主机侧读我们自己的寄存器
#   前置: (1) FPGA 已烧上 pcie_min_top.bit;
#         (2) **主机已在烧录之后重启过** (PCIe 端点只认"配置先于 POST"; 见 _pcie/README.md);
#         (3) 驱动已 insmod (本脚本会自己 insmod)。
#   用法: sudo bash /home/a/xdma_test/pcie_regs_check.sh    日志: /tmp/pcie_regs_check.log
#   判据: MAGIC / BUILD_ID / MARKER 三个常量 + SCRATCH 读写回环 + 字节选通 + FREECNT 递增
#         + 未实现地址返回错误 (负向) + **自由计数器反解 AXI 时钟频率**
#=============================================================================
set -u
KO=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/xdma/xdma.ko
TOOLS=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
DEV=/dev/xdma0_user
LOG=/tmp/pcie_regs_check.log
PASS=0; FAIL=0
exec > >(tee "$LOG") 2>&1
echo "########## P6e 最小版寄存器验收 $(date '+%F %T') ##########"
chk(){ if [ "$2" = "$3" ]; then echo "  [PASS] $1: $2"; PASS=$((PASS+1));
       else echo "  [FAIL] $1: got='$2' want='$3'"; FAIL=$((FAIL+1)); fi; }

# 从 reg_rw 输出里抠出最后一个 0x........ (它的格式是 "Read 32-bit ... : 0x12345678")
rd(){ $TOOLS/reg_rw $DEV $1 w 2>/dev/null | tail -1 | sed 's/.*: *//' | grep -oE '^0x[0-9a-fA-F]+'; }

echo; echo "===== 0. 前提 ====="
lspci -nn | grep -i 10ee || { echo "  [FAIL] 端点不在 (先重启主机!)"; exit 1; }
chk "0.1 链路" "$(cat /sys/bus/pci/devices/0000:02:00.0/current_link_speed 2>/dev/null)" "5.0 GT/s PCIe"
if ! lsmod | grep -qw xdma; then echo "  (insmod)"; insmod "$KO" || { echo "  [FAIL] insmod"; exit 1; }; sleep 2; fi
ls /dev/xdma0_* | tr '\n' ' '; echo
if [ -e $DEV ]; then echo "  [PASS] 0.2 user BAR 节点存在 ($DEV)"; PASS=$((PASS+1));
else echo "  [FAIL] 0.2 没有 $DEV (user BAR 未引出 ⇒ axilite_master_en 没生效?)"; FAIL=$((FAIL+1)); exit 1; fi
echo "  [INFO] dmesg: $(dmesg | grep -o 'identify_bars.*' | tail -1)"

echo; echo "===== 1. 身份 (前置闸) ====="
chk "1.1 MAGIC (0x00)"    "$(rd 0x00)" "0x50360001"
chk "1.2 MARKER (0x14)"   "$(rd 0x14)" "0xdeadbeef"
BID=$(rd 0x04); echo "  [INFO] 1.3 BUILD_ID (0x04) = $BID  <-- 前置闸读的就是这一项"

echo; echo "===== 2. 读写回环 (SCRATCH 0x08) ====="
$TOOLS/reg_rw $DEV 0x08 w 0xA5A55A5A >/dev/null 2>&1
chk "2.1 写 0xA5A55A5A 读回" "$(rd 0x08)" "0xa5a55a5a"
$TOOLS/reg_rw $DEV 0x08 w 0xFFFFFFFF >/dev/null 2>&1
$TOOLS/reg_rw $DEV 0x08 b 0x11     >/dev/null 2>&1     # 只写最低字节 (b = byte)
chk "2.2 字节选通 (只剩 byte0 变)" "$(rd 0x08)" "0xffffff11"

echo; echo "===== 3. 活体 + AXI 时钟反解 (FREECNT 0x0C) ====="
A=$(rd 0x0c); sleep 0.3; B=$(rd 0x0c)
echo "  [INFO] FREECNT: $A -> $B"
if [ "$A" != "$B" ]; then echo "  [PASS] 3.1 自由计数器在动"; PASS=$((PASS+1));
else echo "  [FAIL] 3.1 计数器没动 (AXI 域没时钟?)"; FAIL=$((FAIL+1)); fi
DA=$((A)); DB=$((B))          # bash 认 0x 前缀 (避免 gawk strtonum: Ubuntu 默认可能是 mawk)
if [ "$DB" -gt "$DA" ]; then
  echo "  [INFO] 3.2 Δ=$((DB-DA)) / 0.3s ⇒ AXI 时钟 ≈ $(awk -v d=$((DB-DA)) 'BEGIN{printf "%.1f", d/0.3/1e6}') MHz"
else echo "  [INFO] 3.2 计数未增 (回绕或未跑)"; fi

echo; echo "===== 4. 负向: 未实现地址必须走 SLVERR ====="
# ⚠️ 用法坑 (2026-09-28 实测): reg_rw **不会**因 SLVERR 报错 —— XDMA 的 AXI-Lite 主机把
#    错误响应的数据填成 0xffffffff 交回用户态 ⇒ 判据必须是"读出 0xffffffff", 不是找 error 字样。
U40=$(rd 0x40); U00=$(rd 0x00)
echo "  [INFO] 0x40 (未实现) = $U40 ; 0x00 (实现) = $U00"
if [ "$U40" = "0xffffffff" ] && [ "$U40" != "$U00" ]; then
  echo "  [PASS] 4.1 未实现地址返回 0xffffffff (SLVERR), 且与实现地址不同"; PASS=$((PASS+1))
else echo "  [FAIL] 4.1 未实现地址读出 $U40 ⇒ 地址译码可能过宽"; FAIL=$((FAIL+1)); fi

echo; echo "########## 汇总: PASS=$PASS FAIL=$FAIL ##########"
echo "########## 日志: $LOG ##########"
exit $FAIL
