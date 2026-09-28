#!/bin/bash
#=============================================================================
# pcie_verify.sh -- KU5P PCIe/XDMA **功能与用法**验证 (一次 sudo 跑完)
#   背景: P6 的观测通道定为 PCIe/XDMA (板上无 UART)。U4 状态: 驱动"能编译+能链接"
#   已证, "能加载+能搬数据"未证 —— 本脚本就是要关掉这个缺口。
#   前置: FPGA 已由本机经 JTAG 烧上**厂商出厂位流**(带 XDMA+DDR4), DONE=HIGH。
#   用法: sudo bash /home/a/xdma_test/pcie_verify.sh
#   产物: /tmp/pcie_verify.log (逐阶段证据) + /tmp/p6a_patA.bin 等
#   阶段: A 重扫/枚举  B insmod+节点  C user BAR 寄存器读  D H2C/C2H 数据往返  E XVC 节点
#=============================================================================
set -u
KO=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/xdma/xdma.ko
TOOLS=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
ROOTPORT=0000:00:1c.0          # 板子所在的芯片组根端口 (bus 02)
LOG=/tmp/pcie_verify.log
A_BYTES=$((4*1024*1024))       # 每个图案 4 MB
OFF_B=$((16*1024*1024))        # 第二个图案的地址偏移 16 MB
PASS=0; FAIL=0

exec > >(tee "$LOG") 2>&1
echo "########## PCIe/XDMA 验证 $(date '+%F %T') ##########"
chk(){ if [ "$2" = "$3" ]; then echo "  [PASS] $1: $2"; PASS=$((PASS+1));
       else echo "  [FAIL] $1: got='$2' want='$3'"; FAIL=$((FAIL+1)); fi; }

# ---------------- A. PCIe 重扫 + 枚举 ----------------
echo; echo "===== A. PCIe 重扫与枚举 ====="
echo "--- A0: 重扫前 ---"
lspci -nn | grep -i 10ee || echo "  (无 Xilinx 设备)"
echo "--- A1: 重扫根端口 $ROOTPORT ---"
[ -w /sys/bus/pci/devices/$ROOTPORT/rescan ] && echo 1 > /sys/bus/pci/devices/$ROOTPORT/rescan
sleep 2
BDF=$(lspci -d 10ee: 2>/dev/null | head -1 | cut -d' ' -f1)
if [ -z "$BDF" ]; then
  echo "--- A2: 重扫后仍无 ⇒ 试桥复位 (secondary bus reset) 再扫 ---"
  [ -w /sys/bus/pci/devices/$ROOTPORT/reset ] && echo 1 > /sys/bus/pci/devices/$ROOTPORT/reset
  sleep 3
  echo 1 > /sys/bus/pci/devices/$ROOTPORT/rescan
  sleep 2
  BDF=$(lspci -d 10ee: 2>/dev/null | head -1 | cut -d' ' -f1)
fi
if [ -z "$BDF" ]; then
  # ---- A3: 主机侧强制重训 (根端口 LTSSM 从 Detect 重来) --------------
  #  场景: FPGA 是在主机**开机之后**才配置的 ⇒ 根端口早已放弃链路 (LnkSta Width x0)。
  #  手段1: Link Control 的 Retrain Link (bit5) 置 1;
  #  手段2: Link Disable (bit4) 1 -> 0 ⇒ 根端口重新 Detect/训练 (更彻底)。
  echo "--- A3: 主机侧强制重训 (setpci CAP_EXP+0x10) ---"
  setpci -s $ROOTPORT CAP_EXP+0x10.w 2>/dev/null | sed 's/^/    重训前 LnkCtl = /'
  setpci -s $ROOTPORT CAP_EXP+0x10.w=0x20 2>/dev/null; sleep 2
  echo 1 > /sys/bus/pci/devices/$ROOTPORT/rescan; sleep 1
  BDF=$(lspci -d 10ee: 2>/dev/null | head -1 | cut -d' ' -f1)
  if [ -z "$BDF" ]; then
    echo "    重训请求无效 ⇒ 试 Link Disable 1->0 (完全重来)"
    setpci -s $ROOTPORT CAP_EXP+0x10.w=0x10 2>/dev/null; sleep 1
    setpci -s $ROOTPORT CAP_EXP+0x10.w=0x00 2>/dev/null; sleep 4
    echo 1 > /sys/bus/pci/devices/$ROOTPORT/rescan; sleep 2
    BDF=$(lspci -d 10ee: 2>/dev/null | head -1 | cut -d' ' -f1)
  fi
  lspci -vv -s $ROOTPORT 2>/dev/null | grep -E "LnkSta:" | sed 's/^/    /'
fi
if [ -n "$BDF" ]; then
  echo "  [PASS] A: 端点已枚举 BDF=$BDF"
  lspci -nn -s "$BDF"
  lspci -vv -s "$BDF" | grep -E "LnkCap:|LnkSta:|Region|Interrupt"
  PASS=$((PASS+1))
else
  echo "  [FAIL] A: 重扫后仍无 10ee 设备 ⇒ PCIe 链路未建立"
  echo "   参考: 根端口链路状态"; lspci -vv -s "$ROOTPORT" | grep -E "LnkCap:|LnkSta:|SltSta"
  echo "   ⇒ 主机侧手段已尽: 请做一次**热重启** (FPGA 不掉电, BIOS 会在 POST 时训练链路)"
  FAIL=$((FAIL+1))
  echo; echo "########## 中止: 无端点, 后续阶段无意义 ##########"; exit 1
fi

# ---------------- B. insmod 驱动 ----------------
echo; echo "===== B. insmod XDMA 驱动 ====="
if lsmod | grep -qw xdma; then echo "  (已加载, 先卸载)"; rmmod xdma || true; sleep 1; fi
# ⚠️ 必须 insmod 绝对路径; modprobe 会取 in-tree 的 DMAEngine 版 (不提供 /dev/xdma*)
insmod "$KO"; RC=$?
chk "B1 insmod 返回 0" "$RC" "0"
sleep 2
chk "B2 lsmod 有 xdma" "$(lsmod | grep -cw xdma)" "1"
chk "B3 lspci 绑定到 xdma" "$(lspci -k -s "$BDF" | grep -cw 'Driver: xdma')" "1"
echo "--- B4 /dev/xdma* ---"; ls -l /dev/xdma* 2>/dev/null | sed 's/^/    /'
NX=$(ls /dev/xdma* 2>/dev/null | wc -l)
if [ "$NX" -ge 4 ]; then echo "  [PASS] B4 设备节点数=$NX (>=4)"; PASS=$((PASS+1));
else echo "  [FAIL] B4 设备节点数=$NX (<4)"; FAIL=$((FAIL+1)); fi
echo "--- B5 dmesg xdma 段 ---"; dmesg | grep -i xdma | tail -25 | sed 's/^/    /'
echo "--- B6 通道节点 ---"
for n in control user h2c_0 c2h_0 xvc; do
  if [ -e /dev/xdma0_$n ]; then echo "    [PASS] B6 /dev/xdma0_$n 存在"; PASS=$((PASS+1));
  else echo "    [INFO] B6 /dev/xdma0_$n 不存在"; fi
done

# ---------------- C. user BAR 寄存器读 ----------------
echo; echo "===== C. 寄存器通路 (user BAR / config BAR) ====="
if [ -e /dev/xdma0_user ]; then
  echo "--- C1 /dev/xdma0_user 读 3 个地址 (只读, 不写) ---"
  for a in 0x0 0x100 0x1000; do
    printf "    user[%s] = " $a; $TOOLS/reg_rw /dev/xdma0_user $a b 2>&1 | tail -1
  done
  PASS=$((PASS+1))
else
  echo "  [INFO] C: 无 /dev/xdma0_user ⇒ 该设计未引出 user BAR"
fi
if [ -e /dev/xdma0_control ]; then
  echo "--- C2 /dev/xdma0_control (XDMA 配置 BAR) 读 4 个字 ---"
  for a in 0x0 0x4 0x8 0x40; do
    printf "    ctrl[%s] = " $a; $TOOLS/reg_rw /dev/xdma0_control $a w 2>&1 | tail -1
  done
fi

# ---------------- D. 数据往返 (H2C/C2H) ----------------
echo; echo "===== D. 数据往返 (H2C 写 DDR4 -> C2H 读回) ====="
if [ -e /dev/xdma0_h2c_0 ] && [ -e /dev/xdma0_c2h_0 ]; then
  head -c $A_BYTES /dev/urandom > /tmp/p6a_patA.bin
  head -c $A_BYTES /dev/urandom > /tmp/p6a_patB.bin      # 另一段随机 (交叉污染检查)
  for pair in "A 0" "B $OFF_B"; do
    set -- $pair; TAG=$1; ADDR=$2
    echo "--- D$TAG 地址 $ADDR : 写入+读回 ---"
    T0=$(date +%s.%N)
    $TOOLS/dma_to_device -d /dev/xdma0_h2c_0 -f /tmp/p6a_pat$TAG.bin -s $A_BYTES -a $ADDR >/dev/null 2>&1; RC1=$?
    T1=$(date +%s.%N)
    $TOOLS/dma_from_device -d /dev/xdma0_c2h_0 -f /tmp/p6a_out$TAG.bin -s $A_BYTES -a $ADDR >/dev/null 2>&1; RC2=$?
    T2=$(date +%s.%N)
    chk "D$TAG h2c rc" "$RC1" "0"
    chk "D$TAG c2h rc" "$RC2" "0"
    if cmp -s /tmp/p6a_pat$TAG.bin /tmp/p6a_out$TAG.bin; then
      echo "  [PASS] D$TAG 逐字节一致 ($A_BYTES B)"; PASS=$((PASS+1))
    else
      echo "  [FAIL] D$TAG 失配: $(cmp /tmp/p6a_pat$TAG.bin /tmp/p6a_out$TAG.bin 2>&1 | head -1)"; FAIL=$((FAIL+1))
      echo "         (首 16B 写 vs 读)"; cmp -l /tmp/p6a_pat$TAG.bin /tmp/p6a_out$TAG.bin 2>/dev/null | head -3 | sed 's/^/           /'
    fi
    MB=$(echo "$A_BYTES" | awk '{print $1/1048576}')
    H2C=$(echo "$T0 $T1 $MB" | awk '{d=$2-$1; if(d<=0)d=0.0001; printf "%.1f", $3/d}')
    C2H=$(echo "$T1 $T2 $MB" | awk '{d=$2-$1; if(d<=0)d=0.0001; printf "%.1f", $3/d}')
    echo "  [INFO] D$TAG 吞吐: H2C ${H2C} MB/s, C2H ${C2H} MB/s (${MB} MB)"
  done
  # 交叉检查: 先读 B 再读 A, 两次 A 必须相同 (排除"读的是缓存/固定值")
  $TOOLS/dma_from_device -d /dev/xdma0_c2h_0 -f /tmp/p6a_outA2.bin -s $A_BYTES -a 0 >/dev/null 2>&1
  if cmp -s /tmp/p6a_outA.bin /tmp/p6a_outA2.bin; then
    echo "  [PASS] D3 同址两次读一致 (排除随机/缓存)"; PASS=$((PASS+1))
  else echo "  [FAIL] D3 同址两次读不一致"; FAIL=$((FAIL+1)); fi
else
  echo "  [FAIL] D: 缺 h2c_0 / c2h_0 节点, 跳过"; FAIL=$((FAIL+1))
fi
rm -f /tmp/p6a_pat*.bin /tmp/p6a_out*.bin

# ---------------- E. XVC (可选的 JTAG-over-PCIe) ----------------
echo; echo "===== E. XVC 节点 (U4b: 经 PCIe 访问 JTAG 的可能性) ====="
if [ -e /dev/xdma0_xvc ]; then
  echo "  [INFO] /dev/xdma0_xvc 存在 ⇒ 可试 hw_server 经 PCIe 连 (未在本脚本验证)"
else
  echo "  [INFO] 无 xvc 节点 ⇒ 本次仍只能用 USB/JTAG"
fi

echo; echo "########## 汇总: PASS=$PASS FAIL=$FAIL ##########"
echo "########## 日志: $LOG ##########"
exit $FAIL
