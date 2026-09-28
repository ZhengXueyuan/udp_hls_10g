#!/bin/bash
#=============================================================================
# p6e_watch.sh [样本数] [间隔秒] — 连续采样数据面快照, 看清"谁在发帧 / 板子在回什么"
#   用法: sudo bash /home/a/xdma_test/p6e_watch.sh 12 0.4
#   每个样本: 触发一次快照 → 读 W0..W7 → 打印与上一样本的**差值** + 当帧线上长度 W2。
#   判读:
#     W0 差值 >0 且 W3(W3=crc_err)=0   ⇒ 链路在收帧且 FCS 干净 (前端配方成立)
#     W6 差值 ≈ W0 差值                ⇒ 每一帧都进了慢路径 (ARP/ICMP 路径通)
#     W7 差值 稳定小量 (~每几秒 1)      ⇒ HLS 在做周期性自发帧 (静止时的正常心跳)
#     W7 差值 跟着 W0 涨                ⇒ 慢路径在**应答**收到的帧 (= ping 通了)
#     W2 的样本集合                    ⇒ 线上都是多大的帧 (1518/342/66 一眼看出类别)
#   注: 本脚本会边采样边触发, 所以每次读到的都是"最新一代"; 同代内的字原子 (显式触发语义)。
#   ⚠️ 地址: 24 字 = 0x20..0x7C (2026-09-29 扩)。要加"未实现地址"判据时**绝不能挑 ≥0x100** ——
#      axi_regs 的 `ar_word = araddr[7:2]` 只有 6 位 ⇒ 地址每 256 字节回绕 (0x100 别名到 MAGIC
#      ⇒ 判据假 FAIL; 0x160 别名到已实现字 ⇒ 假 PASS)。24 字版的未实现地址是 **0x84**。
#=============================================================================
set -u
T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
DEV=/dev/xdma0_user
N=${1:-12}; IV=${2:-0.4}
rd(){ $T/reg_rw $DEV $1 w 2>/dev/null | tail -1 | sed 's/.*: *//' | grep -oE '^0x[0-9a-fA-F]+'; }
wr(){ $T/reg_rw $DEV $1 w $2 >/dev/null 2>&1; }
snap(){                       # 触发一次并等 done
  wr 0x18 0x1
  local i s
  for i in $(seq 1 100); do
    s=$(rd 0x1c); [ -z "$s" ] && continue
    [ $(( s & 2 )) -ne 0 ] && return 0
    sleep 0.01
  done
  return 1
}
# 读全 24 个字到全局 W[] (0x20..0x7C)。本脚本目前只用到 W0..W13,
#   W16-W23 (0x60..0x7C, 2026-09-29 新增: HLS 健康位 + MAC 级 TX 锚点) 一并读出来备用;
#   要看那几路的**增量判读**请用 p6e_slowpath_probe.sh (它就是为失聪现象写的)。
declare -a W
readall(){ local a i=0; for a in 20 24 28 2c 30 34 38 3c 40 44 48 4c 50 54 58 5c 60 64 68 6c 70 74 78 7c; do W[$i]=$(rd 0x$a); i=$((i+1)); done; }

snap || { echo "触发失败 (通道没应答?)"; exit 1; }
readall
# ⚠️ 基线要单独存 — 循环里会把 pf/pb/pk/pt 一路吃掉, 拿它们算"总差值"只会得到 0
#    (本轮已经在"判据算术"上栽过两次: 判据 4 的 k0、snap_take 的输出端口覆盖调用变量)
f0=$((W[0])); b0=$((W[1])); k0=$((W[6])); t0=$((W[7])); a8=$((W[8])); a10=$((W[10]))
pf=$f0; pb=$b0; pk=$k0; pt=$t0
echo "样本   Δt(s)  ΔW0帧  ΔW1字节  ΔW6进慢路  ΔW7 HLS发  ΔW8图案发  ΔW10图案收  W13失配   W2当帧长   W3错帧"
for n in $(seq 1 $N); do
  sleep "$IV"
  snap || { echo "第 $n 次触发超时"; break; }
  readall
  f=$((W[0])); b=$((W[1])); k=$((W[6])); t=$((W[7]))
  echo "$(printf '%3d' $n)  $(printf '%7s' $IV)  $(printf '%7d' $((f-pf)))  $(printf '%8d' $((b-pb)))  $(printf '%9d' $((k-pk)))  $(printf '%9d' $((t-pt)))  $(printf '%9d' $((W[8]-a8)))  $(printf '%10d' $((W[10]-a10)))  $(printf '%7d' $((W[13])))   $(printf '%8d' $((W[2])))  $(printf '%6d' $((W[3])))"
  pf=$f; pb=$b; pk=$k; pt=$t
done
echo
echo "[汇总] 本次采样窗口合计: ΔW0=$((W[0]-f0)) 帧 / ΔW1=$((W[1]-b0)) 字节 / ΔW6=$((W[6]-k0)) 进慢路 / ΔW7=$((W[7]-t0)) HLS发出"
echo "       末次绝对值: W0=$((W[0])) / W1=$((W[1])) / W6=$((W[6])) / W7=$((W[7])) / W3错帧=$((W[3]))"
echo "[提示] 现在从 PC 上 ping 192.168.100.2, 再跑一遍本脚本:"
echo "        若 ΔW0 涨 且 ΔW7 跟着涨 ⇒ **ping 通了** (板子在回应答)"
echo "        若 ΔW0 涨 而 ΔW7 不涨 ⇒ 帧收到了但慢路径没回 (查 ICMP/IP 配置)"
echo "        若 ΔW0 = 0 ⇒ PC 侧的帧根本没到 FPGA (网线/IP/网段)"
