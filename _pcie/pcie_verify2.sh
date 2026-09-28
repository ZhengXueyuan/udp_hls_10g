#!/bin/bash
#=============================================================================
# pcie_verify2.sh -- KU5P PCIe/XDMA **阶段 2**: 修判据 + 吞吐特性 + 用法要点
#   阶段 1 (/tmp/pcie_verify.log, 2026-09-28 22:53) 已证: 端点枚举 (5GT/s x4)、
#   xdma v2025.2.0 probe 成功、19 个 /dev/xdma* 节点、配置 BAR 读通、4MB 双向
#   DMA 逐字节一致。当时唯一的 FAIL 是**脚本判据写错**(用 lspci -k 判绑定:
#   insmod 的 out-of-tree 模块不一定显示为 in-use) —— 本次改成 dmesg probe 行判据。
#   本脚本还测: 传输尺寸/提交次数对吞吐的影响 (这就是"用法": -s / -c 的语义)。
#   用法: sudo bash /home/a/xdma_test/pcie_verify2.sh    产物: /tmp/pcie_verify2.log
#=============================================================================
set -u
KO=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/xdma/xdma.ko
TOOLS=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
BDF=0000:02:00.0
LOG=/tmp/pcie_verify2.log
PASS=0; FAIL=0
exec > >(tee "$LOG") 2>&1
echo "########## PCIe/XDMA 阶段2 $(date '+%F %T') ##########"
chk(){ if [ "$2" = "$3" ]; then echo "  [PASS] $1: $2"; PASS=$((PASS+1));
       else echo "  [FAIL] $1: got='$2' want='$3'"; FAIL=$((FAIL+1)); fi; }

# ---- 0. 前提核对 (免 sudo 也能看, 这里一并记) ----
echo; echo "===== 0. 前提 ====="
for f in current_link_speed current_link_width max_link_speed; do
  echo "  $(cat /sys/bus/pci/devices/$BDF/$f 2>/dev/null) <- $f"
done
chk "0.1 链路 5.0GT/s" "$(cat /sys/bus/pci/devices/$BDF/current_link_speed)" "5.0 GT/s PCIe"
chk "0.2 链路 x4"      "$(cat /sys/bus/pci/devices/$BDF/current_link_width)" "4"
chk "0.3 驱动已在"     "$(lsmod | grep -cw xdma)" "1"
chk "0.4 dmesg 有 probe 行 (绑定真证据)" \
    "$(dmesg | grep -c 'probe_one: 0000:02:00.0 xdma0')" "1"
chk "0.5 节点数" "$(ls /dev/xdma* 2>/dev/null | wc -l)" "19"
echo "  [INFO] identify_bars: $(dmesg | grep -o 'identify_bars.*' | tail -1)"

# ---- 1. 寄存器通路 (配置 BAR) ----
echo; echo "===== 1. 配置 BAR 寄存器 (XDMA IP 自身寄存器) ====="
V=$($TOOLS/reg_rw /dev/xdma0_control 0x0 w 2>/dev/null | tail -1 | awk '{print $NF}')
echo "  ctrl[0x0] = $V"
if [ "$V" = "0x1fc00006" ]; then echo "  [PASS] 1.1 与阶段1读数一致 (0x1fc00006)"; PASS=$((PASS+1));
else echo "  [INFO] 1.1 与阶段1不同 (可能是复位后重新加载的 IP)"; fi

# ---- 2. 吞吐特性 (H2C / C2H; 尺寸与提交次数) ----
echo; echo "===== 2. 吞吐特性 (-s 单次字节 / -c 提交次数) ====="
head -c 16777216 /dev/urandom > /tmp/p6a_pat.bin     # 16MB 图案
printf "  %-28s %10s %10s\n" "用例" "H2C MB/s" "C2H MB/s"
run_case(){  # $1=单次字节 $2=提交次数 $3=标签
  local sz=$1 cnt=$2 label=$3
  local t0 t1 t2 tot h c
  tot=$((sz*cnt))
  t0=$(date +%s.%N)
  $TOOLS/dma_to_device   -d /dev/xdma0_h2c_0 -f /tmp/p6a_pat.bin -s $sz -c $cnt -a 0 >/dev/null 2>&1
  t1=$(date +%s.%N)
  $TOOLS/dma_from_device -d /dev/xdma0_c2h_0 -f /tmp/p6a_out.bin -s $sz -c $cnt -a 0 >/dev/null 2>&1
  t2=$(date +%s.%N)
  h=$(awk -v a=$t0 -v b=$t1 -v m=$tot 'BEGIN{d=b-a; if(d<=0)d=0.000001; printf "%.1f", (m/1048576)/d}')
  c=$(awk -v a=$t1 -v b=$t2 -v m=$tot 'BEGIN{d=b-a; if(d<=0)d=0.000001; printf "%.1f", (m/1048576)/d}')
  printf "  %-22s %10s %10s\n" "$label" "$h" "$c"
}
run_case 65536    1  "64KB x1"
run_case 65536    64 "64KB x64 (=4MB)"
run_case 1048576  1  "1MB x1"
run_case 4194304  1  "4MB x1"
run_case 16777216 1  "16MB x1"
echo "  (单发口径, 含工具 open/close 与文件 IO 开销)"
# 最大用例做逐字节校验
$TOOLS/dma_from_device -d /dev/xdma0_c2h_0 -f /tmp/p6a_out16.bin -s 16777216 -a 0 >/dev/null 2>&1
if cmp -s /tmp/p6a_pat.bin /tmp/p6a_out16.bin; then
  echo "  [PASS] 2.1 16MB 往返逐字节一致"; PASS=$((PASS+1))
else echo "  [FAIL] 2.1 16MB 往返失配"; FAIL=$((FAIL+1)); fi
# 反向读序 (排除"只能顺序读"的伪存储): 先读尾部 1MB, 再读头部 1MB, 两次都对
$TOOLS/dma_from_device -d /dev/xdma0_c2h_0 -f /tmp/p6a_tail.bin -s 1048576 -a 15728640 >/dev/null 2>&1
$TOOLS/dma_from_device -d /dev/xdma0_c2h_0 -f /tmp/p6a_head.bin -s 1048576 -a 0 >/dev/null 2>&1
tail -c 1048576 /tmp/p6a_pat.bin > /tmp/p6a_tail_ref.bin
head -c 1048576 /tmp/p6a_pat.bin > /tmp/p6a_head_ref.bin
ok=1; cmp -s /tmp/p6a_tail.bin /tmp/p6a_tail_ref.bin || ok=0
cmp -s /tmp/p6a_head.bin /tmp/p6a_head_ref.bin || ok=0
if [ $ok = 1 ]; then echo "  [PASS] 2.2 反向读序(尾->头)两段都对"; PASS=$((PASS+1));
else echo "  [FAIL] 2.2 反向读序失配"; FAIL=$((FAIL+1)); fi
rm -f /tmp/p6a_pat.bin /tmp/p6a_out.bin /tmp/p6a_out16.bin /tmp/p6a_tail*.bin /tmp/p6a_head*.bin

echo; echo "########## 汇总: PASS=$PASS FAIL=$FAIL ##########"
echo "########## 日志: $LOG ##########"
exit $FAIL
