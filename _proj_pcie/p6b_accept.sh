#!/bin/bash
#=============================================================================
# p6b_accept.sh — P6b 板级验收 (数据面时钟从 PHY 回送的 125MHz 搬到独立 156.25MHz 自由运行域)
#
#   ⚠️ **本轮不要运行** (P6b 位流还没出)。语法自检: `bash -n _proj_pcie/p6b_accept.sh`
#   用法: sudo bash /home/a/xdma_test/p6b_accept.sh [iface]
#         部署: scp _proj_pcie/p6b_accept.sh a@192.168.0.38:/home/a/xdma_test/
#   日志: /tmp/p6b_accept.log (脚本自己 tee; **每次覆盖** ⇒ 日志与结论只对应最后一次运行)
#
#   为什么写成脚本 (而不是每次手打): 判据里有几处**顺序不可换** (前置闸必须在最前;
#   图案测试必须最后), 还有几处**只有在同一进程里才成立**的自证 (快照的 gen 字段),
#   手打迟早会省掉其中一步 —— 上一次省掉的代价是"把工具的天花板当成板子的能力"。
#
#   ---- 判据 (逐条打印 判据/期望/实测/判定; 判定 ∈ PASS|FAIL|SKIP) ----
#     判据1 前置闸: MAGIC=0x50360001 + BUILD_ID == 集成 agent 报告的新值; 不通过**拒绝继续**
#     判据2 活性: FREECNT(0x0C) 两次读数必须变化; MARKER/地址译码可读 (判活**只看 BAR 读得动**,
#           绝不用 lspci / config 空间 —— 那可能是主机侧缓存状态, 本工程踩过)
#     判据3 真 ping: ping -c 5 5/5, 再 ping -c 20 -i 0.05 复测 (接口 enp3s0 / 本机 192.168.100.1/24;
#           重启后地址会丢 ⇒ 脚本自己补, 见 prep())
#     判据4 图案/吞吐: 板子自报速率 >= 900 Mbps (历史 931) + 收到帧逐字节等于图案流
#           + 板子自报 RX 失配 W13=0 + FCS 错帧 W3=0。**速率只认板子自报或网卡硬件计数**,
#           用户态 socket 在 ~80k pps 必丢 (本工程已把工具天花板误读成板子能力过一次)。
#     判据5 观测通道对账 (稳态): W20(MAC 发帧) == W7(HLS 发帧)、ΔW0 >= ΔW7、W13/W18/W19 恒 0、W17 = 0
#     判据6 ⭐ 数据面时钟频率实测 (P6b 的核心判据): 读"数据面域自由计数器"两次, 间隔 10~20s,
#           算频率, 判 156.25MHz ±1% (154.7~157.8); 并打印 125MHz vs 156.25MHz 的判决
#     判据7 MMCM locked 位 = 1 (从快照里读)
#     判据8 ⭐ 停机态跨域锚点 **W0==W30 且 W1==W31 逐位相等** (P6b 独有; 最有判别力)
#     判据9 重启次序纪律 = 下面的"上板运行手册"+ 前置闸纪律 (文档项, 不是运行项)
#
#   ---- 上板运行手册 (顺序不可换) ----
#     ① 本机 (Windows) **JTAG 烧位流**, 经对端 hw_server 192.168.0.38:3121:
#          vivado -mode batch -source _proj_pcie/program_p6b.tcl    (或对应 run_program_*.bat)
#          判据: 日志出现 'End of startup status: HIGH'。**绝不写板载 QSPI** (那里是厂商出厂设计)
#     ② **再重启主机**: `ssh a@192.168.0.38 sudo reboot`
#          PCIe 端点只认"FPGA 配置先于主机 POST"。烧完不重启 ⇒ /dev/xdma0_user 不出来;
#          **事后补救无效** (rescan / 桥复位 / setpci Retrain Link / Link Disable 1→0, 四种主机侧
#          手段实测全废)。判别器: p6e_precheck.sh (config BAR 与 user BAR 一起看)
#     ③ 等端点出现 (本脚本自己等, 最多 120s) + insmod xdma
#     ④ 跑本脚本
#
#   ⚠️ 前置闸纪律 (本工程, 别省): **构建期间不得从被构建的工程烧位流**; **每次测量前必重烧**。
#      理由: 读数必须对应"就是这一版位流" —— 唯一能证明这一点的是判据 1 (MAGIC + BUILD_ID)。
#
#   ---- 退出码 ----
#     0 = 全过 / 1 = 有 FAIL / 2 = 前置闸不通过 (已拒绝继续) /
#     3 = 前置闸未武装 (BUILD_ID 期望值仍是 TODO ⇒ 结论不可用) / 4 = 核心判据(6/7)SKIP(未实现)
#=============================================================================
set -u

# ===== 地址表 =====
# 主机侧唯一要看的表: `reg_rw <device> <字节地址> w [值]` (带值 = 写, 不带 = 读)
#   用法已核实来源: reg_rw 自己的 Usage 行 = "reg_rw <device> <address> [[type] data]";
#   本脚本统一用 `reg_rw $DEV <addr> w` 读 / `... w <v>` 写 (与 p6e_snap_check.sh 一致)。
#
#   0x00 RO MAGIC        0x50360001          <- 判据1 前置闸 (证明读的是我们自己的逻辑)
#   0x04 RO BUILD_ID     **P6b+F4 双域 36 字版 = 6**  <- 判据1 前置闸 (已定稿)
#   0x08 RW SCRATCH
#   0x0C RO FREECNT      axi_aclk 自由计数   <- 判据2 活性 + (顺带)反解 AXI 时钟
#   0x10 RO HW_STATUS    [3]=user_lnk_up
#   0x14 RO MARKER       0xDEADBEEF          <- 判据2 地址译码
#   0x18 WO SNAP_CTRL    写 bit0=1 触发快照
#   0x1C RO SNAP_STATUS  [31:16]gen [2]seen [1]done [0]busy     <- gen 自证用
#   0x20..0xAC RO SNAP_W0..W35  (P6b+F4 36 字; 全部含义见 P6E_OBS.md 一表)
#     判据5/6 用到的字: W0 0x20 MAC收帧 / W1 0x24 MAC收字节 / W3 0x2C FCS错 /
#                       W5 0x34 gmii_free / W6 0x38 交慢路径 / W7 0x3C HLS发帧 /
#                       W8 0x40 图案发帧 / W9 0x44 图案发字节 / W10 0x48 图案收帧 /
#                       W13 0x54 图案失配 / W17 0x64 看门狗拍 / W18 0x68 回卷 /
#                       W19 0x6C 适配器丢 / W20 0x70 MAC发帧 / W24 0x80 数据面自由计数 /
#                       W25 0x84 MMCM locked / W26 0x88 rxcdc 满拍 /
#                       W27 0x8C rxcdc 占用峰值 / W28 0x90 txcdc 占用峰值 /
#                       W29 0x94 DP 等线拍 / W30 0x98 rxcdc 读侧帧数 / W31 0x9C rxcdc 读侧字节
#
# ⚠️⚠️ **P6b 的地址表已定稿** (由集成 agent 填; 只改了本区块 + EXPECT_BUILD_ID):
#      W24 = 0x80 (数据面 156.25MHz 域自由计数器) / W25 = 0x84 (MMCM 状态字, [0] = locked)。
#      两个新字一律按"**未实现则 SKIP**"处理: 读出 0xffffffff ⇒ 打印 SKIP (未实现), 绝不当 PASS。
ADDR_DP_FREE=${ADDR_DP_FREE:-0x80}   # W24 数据面(156.25MHz)域自由计数器; 32 位 ⇒ 每 27.5s 绕一圈
ADDR_MMCM=${ADDR_MMCM:-0x84}         # W25 MMCM 状态字; [0] = locked (SNAP_STATUS[6] 是它的镜像)
MMCM_LOCK_MASK=${MMCM_LOCK_MASK:-0x1}  # locked 位掩码 (bit0)
DP_FREE_NOM_MHZ=${DP_FREE_NOM_MHZ:-156.25}   # 该计数的标称频率
EXPECT_BUILD_ID=${EXPECT_BUILD_ID:-0x00000006}  # P6b+F4 双域 36 字版 = 6 (前置闸认位流)
# ⚠️ 扩窗的连带影响 (P6E_OBS.md「扩窗必须七处同改」⑤): 36 字把 0x20..0xAC 全占了 ⇒
#   "**未实现地址**"已挪到 **0xB0** (p6e_snap_check.sh / p6e_capture.sh 同步改过)。
#   本脚本不受影响 (它按**读出值**判 SKIP, 不挑死地址)。
# ⚠️ 另一处必改 (③): axi_regs 的 `snap_base` 位宽要够装 {snap_idx,5'b0}; **36 字版 max = 1120,
#   11 位** (索引 6 位)。NW>40 时必须再加宽, 否则静默回绕 —— xvlog 不报。
# ===== 地址表结束 =====

IFACE=${1:-enp3s0}
BOARD=192.168.100.2
MYCIDR=192.168.100.1/24
PORT=8081
KO=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/xdma/xdma.ko
# ⚠️ 变量名纪律: 工具目录叫 TOOLS, **绝不能叫 T** —— T 曾被"已跑秒数"覆盖 ⇒ 第 2 轮起
#    $TOOLS/reg_rw 变成 "1/reg_rw" ⇒ **所有读静默失败、空读被 $(()) 当 0** (排查半天的真凶)。
TOOLS=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
DEV=/dev/xdma0_user
PAT_SRC=/home/a/xdma_test/p6e_udp_pattern.cpp     # 用法见其头注释 (C++ = 吞吐口径; Python 只做功能)
PAT_BIN=/tmp/p6b_udp_pattern
LOG=/tmp/p6b_accept.log
W32=$((1<<32))
PING_TMO=2

PASS=0; FAIL=0; SKIP=0; CORE_SKIP=0; GATE_UNARMED=0
declare -a W
declare -a SUM

exec > >(tee "$LOG") 2>&1

res(){ # res <判定> <判据号> <判据> <期望> <实测>
  case "$1" in
    PASS) PASS=$((PASS+1));;
    FAIL) FAIL=$((FAIL+1));;
    SKIP) SKIP=$((SKIP+1));;
  esac
  SUM+=("$(printf '%s|%-4s|%s|%s' "$2" "$1" "$3" "$5")")   # 汇总行 (key|判定|判据|实测); 字段里**不能含 `|`**
  printf "  [%-4s] 判据%-3s 判据=%s | 期望=%s | 实测=%s\n" "$1" "$2" "$3" "$4" "$5"
}
# skips(): "未实现" 语义的 SKIP —— 单独一个函数, 免得与"没跑到"混为一谈
skip_unimpl(){ res SKIP "$1" "$2" "$3" "SKIP (未实现: $4 读回 0xffffffff ⇒ SLVERR/未上线)"; }

# rd(): **读失败返回非零**。⚠️ reg_rw 的输出是 "at address 0xNN : 0xVV" 一行, 用 grep -oE '0x..'
#   会把**地址**也抠出来 ⇒ 后面算术全乱 (p6e_rate.sh 头注释记的坑) ⇒ 必须 `tail -1 | sed 's/.*: *//'`。
#   再补一道 `0x` 前缀校验: 非十六进制一律当读失败 (空读 != 真 0)。
rd(){ local v; v=$($TOOLS/reg_rw $DEV "$1" w 2>/dev/null | tail -1 | sed 's/.*: *//')
      [[ "$v" =~ ^0[xX][0-9a-fA-F]{1,8}$ ]] || return 1
      echo "$v"; }
wr(){ $TOOLS/reg_rw $DEV "$1" w "$2" >/dev/null 2>&1; }
# rd_new(): 新字的读 —— 0xffffffff 一律按"未实现"处理 (XDMA 的 AXI-Lite 主机把 SLVERR 的数据
#   填成 0xffffffff 交给用户态; 这是主机侧行为, 不是 axi_regs 的行为)。
#   ⚠️ 只对**不可能合法等于 0xffffffff** 的字成立 (本脚本两个新字是计数器/状态位, 满足);
#      MAGIC/BUILD_ID 之类绝不能这么判。返回  0=读到值 / 1=读失败 / 2=未实现
rd_new(){ local v; v=$(rd "$1") || return 1; [ "$v" = "0xffffffff" ] && return 2; echo "$v"; }
now(){ # 真实墙钟秒 (用 $EPOCHREALTIME; 退路 date +%s.%N)。
       # ⚠️ 判频率**绝不能拿 sleep 的名义值**当间隔 —— 那正是"空读数 ≠ 真 0"的同类错误。
  if [ -n "${EPOCHREALTIME:-}" ]; then echo "$EPOCHREALTIME"; else date +%s.%N; fi; }
el(){ awk -v a="$1" -v b="$2" 'BEGIN{printf "%.6f", b-a}'; }

# snap(): 写 0x18=1 触发, 轮询 done; 并用 **gen 必须恰好 +1** 自证"这一轮是本进程触发的、
#   且没有第二个写者"。⚠️ done 是 sticky 的: 不发这条守卫的话, 并发读者会互相污染 ——
#   症状是"计数冻结在某个值而别的字仍在变", 单看日志看不出 (2026-09-29 实测踩过, 那次探针的
#   计数读数因此全部作废)。**这段逻辑是被实证逼出来的, 别简化。**
snap(){ local g0 g1 s i
        g0=$(rd 0x1c) || return 1; g0=$(( (g0 >> 16) & 0xffff ))
        wr 0x18 0x1
        for i in $(seq 1 100); do s=$(rd 0x1c) || continue
            [ $(( s & 2 )) -ne 0 ] && break; sleep 0.01; done
        g1=$(rd 0x1c) || return 1; g1=$(( (g1 >> 16) & 0xffff ))
        [ $(( (g1 - g0) & 0xffff )) -eq 1 ]; }
# readall(): 读全 **36 个已实现**的字 (W0..W35 = 0x20..0xAC); 任一读空 ⇒ 整轮作废 (返回非零),
#   别让空读伪装成 0。⚠️ 不要在这里顺带读 0xB0 以上的地址: 未实现时它们合法地回 0xffffffff,
#   混进来会污染整个数组 (新字一律走 rd_new)。
readall(){ local a i=0 v; for a in 20 24 28 2c 30 34 38 3c 40 44 48 4c 50 54 58 5c 60 64 68 6c 70 74 78 7c 80 84 88 8c 90 94 98 9c a0 a4 a8 ac 80 84 88 8c 90 94 98 9c; do
             v=$(rd 0x$a) || return 1; W[$i]=$(( v )); i=$((i+1)); done; }
# round(): 一次"触发 + 读全"的完整动作, 内含三道自证: MAGIC 在 / gen 恰好 +1 / 无空读。
#   任一不成立 ⇒ 这一轮的读数整体不可信 (明确说出来, 不让它伪装成数据)。
round(){ local m; m=$(rd 0x00) || return 1
         [ "$(( m ))" -eq "$(( 0x50360001 ))" ] || return 1
         snap || return 1
         readall || return 1; }
# dd(): 增量 (模 2^32, 抗回绕 —— 931Mbps 下 32 位计数每 ~37s 绕一圈)
dd(){ local d=$(( ($2 - $1) % W32 )); echo $(( d < 0 ? d + W32 : d )); }
rxn(){ cat /sys/class/net/$IFACE/statistics/rx_packets; }

# ---------- 0. 主机侧前提 (把"我没发"和"板子不回"分开) ----------
# 重启后网卡地址会被清掉 ⇒ 先补上 (否则连 ARP 都不发, 会把"我没发"误读成"板子不回")
prep(){
    ip -br addr show "$IFACE" 2>/dev/null | grep -q "192.168.100.1" || {
        ip link set "$IFACE" up 2>/dev/null
        ip addr add "$MYCIDR" dev "$IFACE" 2>/dev/null && echo "[setup] 补加 $MYCIDR 到 $IFACE"
    }
    ip link set "$IFACE" up 2>/dev/null
}
echo "########## P6b 板级验收 $(date '+%F %T') ##########"
echo "地址表: W24=$ADDR_DP_FREE(数据面自由计数) W25=$ADDR_MMCM(MMCM); 期望 BUILD_ID=$EXPECT_BUILD_ID"
prep
ip -br addr show "$IFACE"
echo "-- 等 PCIe 端点 (烧录后重启才会出现) --"
for i in $(seq 1 60); do lspci -n 2>/dev/null | grep -q '10ee:9034' && break; sleep 2; done
if ! lsmod | grep -qw xdma; then echo "[setup] insmod xdma.ko"; insmod "$KO" 2>/dev/null || true; sleep 2; fi
if [ ! -e "$DEV" ]; then
  echo "[FATAL] 没有 $DEV ⇒ 观测通道不可用, 验收无从做起。按序查:"
  echo "        1) **烧录后主机有没有重启** (PCIe 端点只认 FPGA 配置先于 POST; 事后补救无效)"
  echo "        2) 驱动 insmod 了吗 (lsmod | grep xdma)"
  echo "        (注意: lspci 看得到端点**不算**证据)"
  exit 2
fi
ls /dev/xdma0_* | tr '\n' ' '; echo

# ---------- 1. 前置闸 (不通过就拒绝继续) ----------
echo; echo "===== 1. 前置闸: 认位流 ====="
M0=$(rd 0x00); B0=$(rd 0x04)
if [ -z "$M0" ] || [ -z "$B0" ]; then
  echo "  [FATAL] MAGIC/BUILD_ID 读不出来 ⇒ 通道没应答 (先跑 p6e_precheck.sh 判别该不该重启)"; exit 2
fi
# 通道活性总闸: 全 0xffffffff 一律当"没应答", 不当数据 (否则后面按位判的判据会**假通过**:
# 例 0xffffffff & 2 != 0 恒真)
if [ "$M0" = "0xffffffff" ]; then
  echo "  [FATAL] user BAR 全读回 0xffffffff (SLVERR) ⇒ 观测通道没在应答, 后面判据无意义"
  echo "          最可能: **烧录后主机还没重启** (PCIe 端点只认 FPGA 配置先于主机 POST)"; exit 2
fi
if [ "$(( M0 ))" -eq "$(( 0x50360001 ))" ]; then
  res PASS 1a "MAGIC 是我们自己的逻辑" "0x50360001" "$M0"
else
  res FAIL 1a "MAGIC 是我们自己的逻辑" "0x50360001" "$M0"
  echo "  [FATAL] MAGIC 不对 ⇒ **拒绝继续** (读到的不是我们的寄存器块, 或烧的不是这一版)"
  exit 2
fi
if [ "$EXPECT_BUILD_ID" = "TODO" ]; then
  GATE_UNARMED=1
  res SKIP 1b "BUILD_ID == 集成 agent 报告的新值" "0x???????" "SKIP (期望值未定稿: EXPECT_BUILD_ID=TODO)"
  echo "         ⚠️ 前置闸**未武装**: 无法证明板上就是 P6b 位流 ⇒ 本次运行**不能**作为 P6b 验收结论。"
  echo "            定稿后: EXPECT_BUILD_ID=0x00000005 sudo bash $0 $IFACE"
elif [ "$(( B0 ))" -eq "$(( EXPECT_BUILD_ID ))" ]; then
  res PASS 1b "BUILD_ID == 集成 agent 报告的新值" "$EXPECT_BUILD_ID" "$B0"
else
  res FAIL 1b "BUILD_ID == 集成 agent 报告的新值" "$EXPECT_BUILD_ID" "$B0"
  echo "  [FATAL] BUILD_ID 不对 ⇒ **拒绝继续** (板上不是这一版位流, 或者期望值填错了)"
  exit 2
fi

# ---------- 2. 活性 ----------
echo; echo "===== 2. 活性 (判活只看 BAR 读得动) ====="
MK=$(rd 0x14)
if [ "$MK" = "0xdeadbeef" ]; then res PASS 2a "MARKER/地址译码" "0xdeadbeef" "$MK"
else res FAIL 2a "MARKER/地址译码" "0xdeadbeef" "${MK:-读失败}"; fi
HW=$(rd 0x10); echo "  [INFO] HW_STATUS (0x10) = ${HW:-读失败}  ([3]=user_lnk_up [4]=msi_enable [7:5]=msi_vec_w)"
F1=$(rd 0x0c); sleep 0.1; F2=$(rd 0x0c)
if [ -z "$F1" ] || [ -z "$F2" ]; then
  res FAIL 2b "FREECNT(0x0C) 两次读数必须变化" "变化" "读失败"
elif [ "$F1" != "$F2" ]; then
  res PASS 2b "FREECNT(0x0C) 两次读数必须变化" "变化" "$F1 -> $F2 (Δ=$(( F2 - F1 )) / 0.1s)"
else
  res FAIL 2b "FREECNT(0x0C) 两次读数必须变化" "变化" "$F1 -> $F2 (**冻结** ⇒ AXI 域死了?)"
fi

# ---------- 判据 6/5 的共用长窗口 ----------
# 判据5 (稳态对账) 与 判据6 (频率实测) 用**同一个 10~20s 窗口**, 且必须**先于**判据4:
#   图案测试会教会板子 peer ⇒ 板子持续全速发图案帧 ⇒ **破坏判据5 的前提** (W20 会大于 W7)。
echo; echo "===== 判据5/6 共用窗口: 稳态对账 + 数据面时钟频率 (先于图案测试) ====="
DP_T0=""; DP_A=""; DP_B=""; FE_A=""; FE_B=""; GEN_A=""; RC_DP=""; RC_DP2=""; DT=""
if round; then
  FE_A=${W[5]}; GEN_A=$(rd 0x1c)
  DP_A=$(rd_new $ADDR_DP_FREE); RC_DP=$?
  DP_T0=$(now)
  G0=${W[0]}; G7=${W[7]}; G20=${W[20]}; G8=${W[8]}
  echo "  [INFO] 窗口起点: gen=$GEN_A  W0=${W[0]} W7=${W[7]} W20=${W[20]} W5(gmii_free)=$FE_A"
  case $RC_DP in
    0) echo "  [INFO] 数据面自由计数 ($ADDR_DP_FREE) = $DP_A";;
    1) echo "  [INFO] 数据面自由计数 ($ADDR_DP_FREE) 读失败 ⇒ 判据6 将 SKIP";;
    2) echo "  [INFO] 数据面自由计数 ($ADDR_DP_FREE) 读回 0xffffffff ⇒ **未实现** ⇒ 判据6 将 SKIP (未实现)";;
  esac
  # 给窗口打流量: 让 ΔW0/ΔW7 有意义 (只 ping 2 包时 ΔW0 会被背景流量淹没)
  ping -c 20 -i 0.05 -W $PING_TMO "$BOARD" > /tmp/p6b_wnd_ping.txt 2>/dev/null
  # 把窗口补到 10~20s (下限 10s 是判据; 上限 20s 是 32 位 @156.25MHz = 27.5s 回绕留的余量)
  for i in $(seq 1 40); do
    DTS=$(el "$DP_T0" "$(now)"); awk -v d="$DTS" 'BEGIN{exit !(d>=12.0)}' && break; sleep 0.5
  done
  if round; then
    DP_B=$(rd_new $ADDR_DP_FREE); RC_DP2=$?; DP_T1=$(now)   # 时间戳紧跟读数 (两端对称 ⇒ 偏差抵消)
    FE_B=${W[5]}; GEN_B=$(rd 0x1c)
    DT=$(el "$DP_T0" "$DP_T1")
    echo "  [INFO] 窗口终点: gen=$GEN_B  W0=${W[0]} W7=${W[7]} W20=${W[20]} W5(gmii_free)=$FE_B"
    echo "  [INFO] 真实窗口长度 (取墙钟, 非 sleep 名义值) = ${DT}s"
    # --- 判据5 ---
    if [ "$(( W[8] ))" -ne "$(( G8 ))" ]; then
      res SKIP 5 "稳态对账 (W20==W7 / ΔW0>=ΔW7 / W13,W18,W19,W17 恒0)" "板子安静" \
          "SKIP (前提不成立: 图案 app 正在发帧 ΔW8=$(( W[8] - G8 )) ⇒ W20!=W7 是正常的; 重烧后先跑本判据)"
    else
      # ⚠️⚠️ **前置条件 (对抗审查 F11): 本条只在 `W21 == 0` 时成立**。mac_tx 帧内中止后回到
      #    S_IDLE, 会把中止帧的**剩余字当成一帧新的**重发并 stat_frames++ ⇒ 一次 abort 让 W20
      #    多计若干"帧" ⇒ W20-W7 超出 {0,1} (那不是跨域偏斜, 是 runt 重发)。
      #    ⇒ 先判 W21==0, 否则本判据 SKIP 并点明原因, 绝不当 FAIL。
      # ⚠️ P6b: W20 在 **FE 束**、W7 在 **DP 束** ⇒ 链式触发给出方向, 但两者天然可差 1 帧
      #    (两次锁存之间最多跨 1 个帧边界, 偏斜 ≤59.2ns < 96ns 最小 IFG)。**必须用区间判据**,
      #    写成 `W20 == W7` 会把正常偏斜报成 FAIL (P6B_SPEC §9.3 点名的一处旧判据失效)。
      DW207=$(( W[20] - W[7] ))
      if [ "$(( W[21] ))" -ne 0 ]; then
        res SKIP 5a "0 <= W20-W7 <= 1" "前置: W21(MAC 帧内中止)=0" "SKIP (W21=${W[21]} != 0 ⇒ 中止帧剩余字被当新帧重发, W20 多计; 见 F11)"
      elif [ "$DW207" -ge 0 ] && [ "$DW207" -le 1 ]; then
        res PASS 5a "0 <= W20(FE MAC发帧) - W7(DP HLS发帧) <= 1 (跨束偏斜上界)" "[0,1]" "W20=${W[20]} W7=${W[7]} (差 $DW207)"
      else
        res FAIL 5a "0 <= W20(FE) - W7(DP) <= 1" "[0,1]" "W20=${W[20]} W7=${W[7]} (差 $DW207: 跨域对账失配)"
      fi
      D0=$(dd "$G0" "${W[0]}"); D7=$(dd "$G7" "${W[7]}")
      if [ "$D0" -ge "$D7" ]; then res PASS 5b "ΔW0 >= ΔW7 (收的帧不少于回的帧)" ">=" "ΔW0=$D0 ΔW7=$D7"
      else res FAIL 5b "ΔW0 >= ΔW7 (收的帧不少于回的帧)" ">=" "ΔW0=$D0 ΔW7=$D7 (回了比收的还多?!)"; fi
      if [ "$(( W[13] ))" -eq 0 ]; then res PASS 5c "W13 图案失配恒 0" "0" "${W[13]}"
      else res FAIL 5c "W13 图案失配恒 0" "0" "${W[13]}"; fi
      if [ "$(( W[18] ))" -eq 0 ]; then res PASS 5d "W18 (slow_tx_adp 整帧回卷) 恒 0" "0" "${W[18]}"
      else res FAIL 5d "W18 (slow_tx_adp 整帧回卷) 恒 0" "0" "${W[18]} (有帧被整帧回卷 ⇒ 别再怪 HLS, 查 wf FIFO 消费侧)"; fi
      # ---- P6b 新增字判据 5g/5h (P6B_SPEC §9.2-C 的 C6/C7) ----
      # W27/W28 是"新异步 FIFO 深度够不够"的**唯一直接读数**; W26 是"丢帧是不是新 FIFO 造成"的归因量。
      if [ "$(( W[27] ))" -le 256 ]; then res PASS 5g "W27 (rxcdc 占用峰值) <= 256 (= DEPTH)" "<=256" "${W[27]}"
      else res FAIL 5g "W27 (rxcdc 占用峰值) <= 256" "<=256" "${W[27]} (超深度: FIFO 模型/探针错)"; fi
      if [ "$(( W[28] ))" -le 256 ]; then res PASS 5h "W28 (txcdc 占用峰值) <= 256 (= DEPTH)" "<=256" "${W[28]}"
      else res FAIL 5h "W28 (txcdc 占用峰值) <= 256" "<=256" "${W[28]} (超深度: FIFO 模型/探针错)"; fi
      echo "  [INFO] 深度探针: W26(rxcdc 满拍)=${W[26]} W27(rxcdc 峰值)=${W[27]} W28(txcdc 峰值)=${W[28]} W29(DP 等线拍)=${W[29]}"
      echo "         ⚠️ 判读: W27 贴 256 ⇒ RX 深度真的不够 (按 P6B_SPEC §4.2 的升级路径换 FWFT=0 的 512);"
      echo "                  W28 贴 256 而 W18 不涨 ⇒ DP 在等线 (线速瓶颈), 不是深度问题。"
      echo "                  W4(丢帧) 随 W0 涨 且 W26 单调涨 ⇒ 确认丢帧是新 FIFO 造成的。" 
      if [ "$(( W[19] ))" -eq 0 ]; then res PASS 5e "W19 (slow_rx_adp 丢帧) 恒 0" "0" "${W[19]}"
      else res FAIL 5e "W19 (slow_rx_adp 丢帧) 恒 0" "0" "${W[19]}"; fi
      # ⚠️ P6b: `slow_rx_adp.rst_cnt` 由 64 拍改 **80 拍** (维持同一墙钟 512ns, 见 P6B_SPEC §5.1)
      #    ⇒ 口径必须跟着改 ÷80, 否则复位次数算错 25% (P6B_SPEC §9.3 点名的旧判据)。
      if [ "$(( W[17] ))" -eq 0 ]; then res PASS 5f "W17 (饥饿看门狗复位拍数) 恒 0" "0" "${W[17]}"
      else res FAIL 5f "W17 (饥饿看门狗复位拍数) 恒 0" "0" "${W[17]} (÷80 ≈ $(( W[17] / 80 )) 次复位)"; fi
    fi
    # --- 判据6: 数据面时钟频率 (P6b 的核心判据) ---
    if [ "$RC_DP" -eq 0 ] && [ "$RC_DP2" -eq 0 ]; then
      DA=$(( DP_A )); DB=$(( DP_B ))
      if [ "$DB" -lt "$DA" ]; then DCNT=$(( (W32 - DA) + DB )); WRAP="(已补偿 1 次回绕)"
      else DCNT=$(( DB - DA )); WRAP=""; fi
      MHZ=$(awk -v d="$DCNT" -v t="$DT" 'BEGIN{printf "%.4f", d/t/1e6}')
      res_ok_ivl=0; awk -v t="$DT" 'BEGIN{exit !(t>=10.0 && t<20.0)}' && res_ok_ivl=1
      if [ "$res_ok_ivl" -eq 1 ]; then
        res PASS 6a "窗口长度必须落在 [10, 20)s (32 位 @156.25MHz 每 27.5s 回绕)" "[10,20)" "${DT}s $WRAP"
      else
        res FAIL 6a "窗口长度必须落在 [10, 20)s (32 位 @156.25MHz 每 27.5s 回绕)" "[10,20)" "${DT}s ⇒ 频率读数不可用"
      fi
      LO=$(awk -v f="$DP_FREE_NOM_MHZ" 'BEGIN{printf "%.2f", f*0.99}')
      HI=$(awk -v f="$DP_FREE_NOM_MHZ" 'BEGIN{printf "%.2f", f*1.01}')
      if awk -v m="$MHZ" -v l="$LO" -v h="$HI" 'BEGIN{exit !(m>=l && m<=h)}'; then
        res PASS 6b "数据面域频率 = $DP_FREE_NOM_MHZ MHz ±1%" "[$LO, $HI] MHz" "${MHZ} MHz  (Δ=$DCNT / ${DT}s)"
      else
        res FAIL 6b "数据面域频率 = $DP_FREE_NOM_MHZ MHz ±1%" "[$LO, $HI] MHz" "${MHZ} MHz  (Δ=$DCNT / ${DT}s; 若刚做过回绕补偿, 也可能是窗口内该计数被复位)"
      fi
      # 125 vs 156.25 的**明确判决** (这条是本判据存在的全部理由)
      VERDICT_MODE=$(awk -v m="$MHZ" 'BEGIN{d125=(m>125)?m-125:125-m; d156=(m>156.25)?m-156.25:156.25-m; print (d125<d156)?"125":"156.25"}')
      if [ "$VERDICT_MODE" = "125" ]; then
        echo "  [判决] 实测 ${MHZ} MHz 更接近 **125MHz** ⇒ **FAIL: 数据面根本没搬到 156.25MHz 新域**"
        echo "         可能: ① 该字仍接在 phy1_rxc/gmii_clk (前端) 域 ② 字地址别名到别的计数器"
        echo "               ③ MMCM/自由运行时钟没起 (顺带看判据7 的 locked)"
      else
        echo "  [判决] 实测 ${MHZ} MHz 更接近 **156.25MHz** ⇒ 数据面确实跑在新域上 ✓"
      fi
      # 对照: 同窗口的前端 125MHz 域自由计数 (互相独立地证明"两个域各在各的频率上")
      DF=$(dd "$FE_A" "$FE_B"); MFE=$(awk -v d="$DF" -v t="$DT" 'BEGIN{printf "%.4f", d/t/1e6}')
      echo "  [INFO] 对照: W5(gmii_free, 前端域, 同窗口 ${DT}s) = ${MFE} MHz"
      if awk -v m="$MFE" 'BEGIN{exit !(m>=123.75 && m<=126.25)}'; then
        echo "         ⇒ 前端 ≈125MHz ✓ 与数据面 ${MHZ} MHz 形成**两个不同频率的域** (P6b 的结构证据)"
      else
        echo "         [WARN] 前端对照不是 ~125MHz。两种读法: (a) P6b 把 W5 的语义也改了 ⇒ 改这一行;"
        echo "                (b) 前端真出问题 ⇒ 先别下结论, 查 phy1_rxc 与 RGMII 前端"
      fi
    elif [ "$RC_DP" -eq 2 ] || [ "$RC_DP2" -eq 2 ]; then
      skip_unimpl 6 "数据面域自由计数器 ($ADDR_DP_FREE) 频率实测" "$DP_FREE_NOM_MHZ MHz ±1%" "字 $ADDR_DP_FREE"
      CORE_SKIP=$((CORE_SKIP+1))
    else
      res FAIL 6 "数据面域自由计数器 ($ADDR_DP_FREE) 频率实测" "$DP_FREE_NOM_MHZ MHz ±1%" "读失败 (空读 != 真 0)"
    fi
    # --- 判据7: MMCM locked (从快照里读; 若该字是快照字, 上面 round() 已触发过 ⇒ 读的是冻结值) ---
    LOCKV=$(rd_new $ADDR_MMCM); RC_LK=$?
    case $RC_LK in
      0) if [ "$(( LOCKV & $MMCM_LOCK_MASK ))" -eq "$(( MMCM_LOCK_MASK ))" ]; then
           res PASS 7 "MMCM locked 位 (掩码 $MMCM_LOCK_MASK)" "= 掩码 (locked=1)" "$LOCKV & $MMCM_LOCK_MASK != 0"
         else
           res FAIL 7 "MMCM locked 位 (掩码 $MMCM_LOCK_MASK)" "= 掩码 (locked=1)" "$LOCKV & $MMCM_LOCK_MASK == 0 ⇒ **MMCM 没锁**"
         fi;;
      2) skip_unimpl 7 "MMCM locked 位 (掩码 $MMCM_LOCK_MASK)" "locked=1" "字 $ADDR_MMCM"; CORE_SKIP=$((CORE_SKIP+1));;
      *) res FAIL 7 "MMCM locked 位 (掩码 $MMCM_LOCK_MASK)" "locked=1" "读失败 (空读 != 真 0)";;
    esac
  else
    echo "  [FAIL] 窗口终点 round() 自证不成立 (MAGIC / gen+1 / 无空读) ⇒ 本轮读数整体作废, 不判 5/6"
    res FAIL 5 "稳态对账" "自证成立" "round() 自证失败"
    res FAIL 6 "数据面域频率实测" "$DP_FREE_NOM_MHZ MHz ±1%" "round() 自证失败"
  fi
else
  echo "  [FAIL] 窗口起点 round() 自证不成立 (MAGIC / gen+1 / 无空读) ⇒ 不判 5/6"
  res FAIL 5 "稳态对账" "自证成立" "round() 自证失败"
  res FAIL 6 "数据面域频率实测" "$DP_FREE_NOM_MHZ MHz ±1%" "round() 自证失败"
fi

# ---------- 判据 8 (P6b 独有, 最有判别力): 停机态跨域恒等式 **三段式** ----------
#   为什么这条最有判别力: W0/W1 在 **FE 束** (写侧), W30/W31 在 **DP 束** (读侧),
#   两者天然差一个"在飞量"; 但停机窗口里 FIFO 必空 ⇒ 恒等式精确成立 (P6B_SPEC §7.3 有证明:
#   Σpopc(tkeep) + 4x帧数 ≡ MAC 的 stat_bytes)。
#
#   ⚠️⚠️ **三段式 (对抗审查 R4)**: 绝对值式 (W0==W30) 在**第一次丢帧之后就永久 FAIL 且无法
#   归因** —— mac_rx_64 的丢帧发生在"已 push 过字之后"(对抗审查 F4a) ⇒ 流里留下**孤儿字**
#   (有 popc、无 TLAST) ⇒ W31 永久多算。所以:
#     ① **前置**: W4 (rx_stat_drop) 在窗口内必须**从未变过**; 变过 ⇒ SKIP + 理由
#        (那是数据面丢帧, 不是 CDC 完整性故障 —— 两者必须分开归因，绝不当 FAIL)
#     ② **主判据 = 增量**: ΔW0 == ΔW30 且 ΔW1 == ΔW31 (窗口静默 ⇒ 无在飞)
#     ③ 有向不等式保留: `-1 <= W0-W30` (链式触发保证 W30 的采样不早于 W0; 长跑回归用)
#
#   ⚠️ **静默窗口 = [13us, 4s)** (对抗审查 S5): 下限 = 一个最大帧时间 (在飞字必须落地);
#      上限 = HLS 的 HELLO 周期 (P6b 下由 5s 变 **4s**, P6B_SPEC §5.3) —— 超过它 HELLO 帧
#      会注入新流量, 窗口就不再静默。本脚本取 **1s**, 稳稳落在窗口内。
echo; echo "===== 判据 8: 停机态跨域恒等式 (三段式; 静默窗口 1s in [13us, 4s)) ====="
if round; then
  P0=${W[0]}; P1=${W[1]}; P4=${W[4]}; P30=${W[30]}; P31=${W[31]}
  echo "  [INFO] 窗口起点: W0=$P0 W1=$P1 W4(丢帧)=$P4 W30=$P30 W31=$P31"
  sleep 1
  if round; then
    D0=$(dd "$P0" "${W[0]}"); D1=$(dd "$P1" "${W[1]}")
    D30=$(dd "$P30" "${W[30]}"); D31=$(dd "$P31" "${W[31]}")
    echo "  [INFO] 窗口增量: dW0=$D0 dW1=$D1 dW30=$D30 dW31=$D31 | dW4=$(( W[4] - P4 )) | W0-W30=$(( W[0] - W[30] )) W1-W31=$(( W[1] - W[31] ))"
    # ⚠️ 这里原先是"窗口内 W4 无变化"的前置分支 —— **已废除**: 下面的结构式判据对任何
    #    窗口都成立 (孤儿字由 W32/W33 显式记账), 不需要"窗口安静"这个前提。
    if true; then
      # ⚠️⚠️ **判据形式 (F4 落地后的正确守恒律)**: 朴素等式 (W0==W30 / W1==W31) **只在
      #    W32==W33==0 时成立** (帧中丢帧会留**孤儿字**: 有 popc、无 TLAST)。结构式:
      #      W30 == W0 + W32     (#TLAST交付 == stat_frames + stat_drop_partial)
      #      W31 == W1 - 4*W0 + W33  (Σpopc交付 == stat_bytes - 4*stat_frames + stat_orphan_bytes)
      #    按 mod 2^32 算差 (读数本身就是 32 位)。
      R30=$(( (W[0] + W[32]) % W32 )); R31=$(( (W[1] - 4*W[0] + W[33]) % W32 ))
      R30=$(( (R30 + W32) % W32 ));     R31=$(( (R31 + W32) % W32 ))
      echo "  [INFO] 结构式期望: W30应=$(printf 0x%x $R30) W31应=$(printf 0x%x $R31) | 实测 W30=${W[30]} W31=${W[31]}"
      echo "  [INFO] F4 健康位: W32(drop_partial)=${W[32]} W33(orphan_bytes)=${W[33]} W34(drop_full)=${W[34]} W35(fifo_ovf)=${W[35]}"
      if [ "$(( W[30] ))" -eq "$R30" ]; then res PASS 8a "W30 == W0 + W32 (F4 守恒: TLAST交付 == 收帧 + 部分丢帧)" "结构式相等" "W30=${W[30]} == ${R30}"
      else res FAIL 8a "W30 == W0 + W32" "结构式相等" "W30=${W[30]} != ${R30} (差 $(( W[30] - R30 )): CDC 丢/重帧)"; fi
      if [ "$(( W[31] ))" -eq "$R31" ]; then res PASS 8b "W31 == W1 - 4*W0 + W33 (F4 守恒: Σpopc交付 == 收字节 - 4x帧 + 孤儿字节)" "结构式相等" "W31=${W[31]} == ${R31}"
      else res FAIL 8b "W31 == W1 - 4*W0 + W33" "结构式相等" "W31=${W[31]} != ${R31} (差 $(( W[31] - R31 )): CDC 丢/重字节)"; fi
      if [ "$(( W[35] ))" -eq 0 ]; then res PASS 8d "W35 (fifo_sync 拒写) 恒 0" "0" "${W[35]}"
      else res FAIL 8d "W35 恒 0" "0" "${W[35]} (静默丢失: 见 F4 修复的 hard rule)"; fi
    fi
    if [ "$(( W[0] - W[30] ))" -ge -1 ]; then res PASS 8c "有向: W0-W30 >= -1 (链式触发方向性)" ">=-1" "W0-W30=$(( W[0] - W[30] ))"
    else res FAIL 8c "有向: W0-W30 >= -1" ">=-1" "W0-W30=$(( W[0] - W[30] )) (方向反了: 两束先后被写反?)"; fi
  else
    res FAIL 8a "dW0 == dW30" "round() 自证成立" "窗口终点 round() 自证失败"
    res FAIL 8b "dW1 == dW31" "round() 自证成立" "窗口终点 round() 自证失败"
  fi
else
  res FAIL 8a "dW0 == dW30" "round() 自证成立" "窗口起点 round() 自证失败"
  res FAIL 8b "dW1 == dW31" "round() 自证成立" "窗口起点 round() 自证失败"
fi

# ---------- 3. 真 ping ----------
echo; echo "===== 3. 真 ping ($BOARD) ====="
prep
# ping 只打一次, 输出落盘后再解析 (打两次既慢又可能把"第二次通"当成"第一次通")
ping -c 5 -W $PING_TMO "$BOARD" > /tmp/p6b_ping1.txt 2>&1
P1=$(grep -oE '[0-9]+ received' /tmp/p6b_ping1.txt | grep -oE '[0-9]+'); P1=${P1:-0}
RTT=$(grep -oE 'rtt min/avg/max/mdev = [0-9./]+' /tmp/p6b_ping1.txt | cut -d= -f2)
if [ "$P1" = "5" ]; then res PASS 3a "ping -c 5 全通" "5/5" "$P1/5  rtt(avg/max)=${RTT:-?}"
else res FAIL 3a "ping -c 5 全通" "5/5" "$P1/5 ⇒ 按【哪一环不涨】定位: ΔW0=0 帧没到 FPGA / ΔW6=0 没进慢路径 / ΔW7=0 HLS 没回"; fi
P2=$(ping -c 20 -i 0.05 -W $PING_TMO "$BOARD" 2>/dev/null | grep -oE '[0-9]+ received' | grep -oE '[0-9]+')
P2=${P2:-0}
# ⚠️ `-i 0.05` 只有 root 能低于 0.2s ⇒ 本脚本必须 sudo 跑 (否则 ping 会拒绝该间隔, P2 恒 0 假 FAIL)
if [ "$P2" = "20" ]; then res PASS 3b "ping -c 20 -i 0.05 复测" "20/20" "$P2/20"
else res FAIL 3b "ping -c 20 -i 0.05 复测" "20/20" "$P2/20 (密集包是比真实 PC 更严苛的用例)"; fi

# ---------- 4. 图案/吞吐 (最后跑: 它会把板子打到线速, 之后就"不安静"了) ----------
echo; echo "===== 4. 图案/吞吐 (C++; 判速率只看板子自报/网卡硬件计数) ====="
PAT_OK=0
if [ -x "$PAT_BIN" ]; then PAT_OK=1
elif [ -f "$PAT_SRC" ]; then
  if g++ -O2 -o "$PAT_BIN" "$PAT_SRC" 2>/tmp/p6b_gpp.log; then PAT_OK=1; else echo "  [FAIL] g++ 编译失败: $(tail -2 /tmp/p6b_gpp.log)"; fi
else
  echo "  [FAIL] 既没有 $PAT_BIN 也没有 $PAT_SRC (部署: scp _proj_pcie/p6e_udp_pattern.cpp a@192.168.0.38:/home/a/xdma_test/)"
fi
if [ "$PAT_OK" = "1" ]; then
  # 4a 逐字节 / 4b 板子自报速率 / 4c W13 失配 / 4d FCS 错帧
  if round; then
    PA9=${W[9]}; PA10=${W[10]}; T_A=$(now); RX_A=$(rxn)
    "$PAT_BIN" --secs 10 --board "$BOARD" --port $PORT > /tmp/p6b_pattern.log 2>&1; PRC=$?
    T_B=$(now); RX_B=$(rxn)
    if round; then
      PB9=${W[9]}
      DT4=$(el "$T_A" "$T_B")
      DB9=$(dd "$PA9" "$PB9")
      RATE=$(awk -v d="$DB9" -v t="$DT4" 'BEGIN{printf "%.1f", d*8/t/1e6}')
      DFR=$(dd "$PA10" "${W[10]}")
      # 4a: C++ 对端退出码 0 = 收到的帧**逐字节**等于图案流 (含掉包后的重对齐)
      if [ "$PRC" -eq 0 ]; then res PASS 4a "收到的帧逐字节等于图案流" "exit 0" "exit 0 ($(grep -c '^  \[GAP\]' /tmp/p6b_pattern.log) 次接收侧重对齐)"
      else res FAIL 4a "收到的帧逐字节等于图案流" "exit 0" "exit $PRC ⇒ 见 /tmp/p6b_pattern.log 尾部: $(grep -E '\[FAIL\]' /tmp/p6b_pattern.log | head -2 | tr '\n' ' ')"; fi
      # 4b: **板子自报**速率 (W9 udpapp_tx_bytes) —— 与我的接收侧无关 (用户态 socket 在 ~80k pps 必丢)
      if awk -v r="$RATE" 'BEGIN{exit !(r>=900.0)}'; then
        res PASS 4b "板子自报图案 TX 速率 >= 900 Mbps" ">=900 Mbps" "${RATE} Mbps (ΔW9=$DB9 B / ${DT4}s; 历史 931)"
      else
        res FAIL 4b "板子自报图案 TX 速率 >= 900 Mbps" ">=900 Mbps" "${RATE} Mbps (ΔW9=$DB9 B / ${DT4}s; 历史 931)"
      fi
      # 网卡**硬件**计数独立复核 (不是 socket 口径) —— 只作旁证, 不作判据
      DRX=$(( RX_B - RX_A ))
      NRATE=$(awk -v d="$DRX" -v t="$DT4" 'BEGIN{printf "%.1f", d*1472*8/t/1e6}')
      echo "  [INFO] 旁证: 网卡硬件计数 Δrx_packets=$DRX ⇒ ≈${NRATE} Mbps (口径 1472B/帧)"
      awk -v a="$NRATE" -v b="$RATE" 'BEGIN{exit !(a < b*0.5)}' && \
        echo "         [WARN] 网卡只收到板子自报的 $(awk -v a="$NRATE" -v b="$RATE" 'BEGIN{printf "%.0f%%", 100*a/b}') ⇒ **先怀疑接收侧 (内核/网卡) 掉包**, 不要把工具的天花板当成板子的能力"
      # 4c/4d: 板子**自己**的校验器与 MAC 计数器 (绝对值, 恒 0 类)
      if [ "$(( W[13] ))" -eq 0 ]; then res PASS 4c "板子自报图案失配 W13 == 0" "0" "${W[13]} (图案 app 的 RX 校验器)"
      else res FAIL 4c "板子自报图案失配 W13 == 0" "0" "${W[13]}"; fi
      if [ "$(( W[3] ))" -eq 0 ]; then res PASS 4d "FCS 错帧 W3 == 0 (物理层/前端配方)" "0" "${W[3]}"
      else res FAIL 4d "FCS 错帧 W3 == 0 (物理层/前端配方)" "0" "${W[3]}"; fi
      echo "  [INFO] 教学包: ΔW10(图案 app 收帧)=$DFR (>=1 说明 peer 学到了; W8/W9 是它发出去的帧/字节)"
      echo "  [INFO] 图案测试详情: /tmp/p6b_pattern.log (⚠️ 里面打印的速率是**我的接收侧**口径, 不是板子的)"
    else
      echo "  [FAIL] 图案测试后 round() 自证不成立 ⇒ 4b/4c/4d 的读数不可信"
      res FAIL 4b "板子自报图案 TX 速率" ">=900 Mbps" "round() 自证失败"
      res FAIL 4c "板子自报图案失配 W13" "0" "round() 自证失败"
      res FAIL 4d "FCS 错帧 W3" "0" "round() 自证失败"
    fi
  else
    echo "  [FAIL] 图案测试前 round() 自证不成立"
    res FAIL 4a "图案测试" "可跑" "round() 自证失败"
  fi
else
  res SKIP 4 "图案/吞吐" ">=900 Mbps + 逐字节 + W13=0 + W3=0" "SKIP (缺 $PAT_SRC / 编译失败)"
fi

# ---------- 汇总 ----------
echo; echo "########## 汇总 (按判据号; ⚠️ 执行顺序是 1->2->5/6/7->3->4, 因为图案测试会破坏 5/6 的前提) ##########"
if [ "${#SUM[@]}" -gt 0 ]; then
  printf '%s\n' "${SUM[@]}" | sort -t'|' -k1,1V | awk -F'|' '{printf "  %s 判据%-3s %s | 实测: %s\n", $2, $1, $3, $4}'
fi
echo "  PASS=$PASS FAIL=$FAIL SKIP=$SKIP (核心判据 SKIP=$CORE_SKIP)  日志: $LOG"
if [ "$FAIL" -gt 0 ]; then
  echo "########## P6b: FAIL ($FAIL 项) ⇒ 不通过 ##########"; exit 1
fi
if [ "$CORE_SKIP" -gt 0 ]; then
  echo "########## P6b: **不能判通过** —— 核心判据 6/7 有 SKIP (新字未实现) ##########"; exit 4
fi
if [ "$GATE_UNARMED" = "1" ]; then
  echo "########## P6b: 全部 PASS, 但**前置闸未武装** (BUILD_ID 期望值=TODO) ⇒ 结论不可用 ##########"; exit 3
fi
if [ "$SKIP" -gt 0 ]; then
  echo "########## P6b: 通过 (含 $SKIP 项 SKIP —— 上面逐条已说明理由, 别当成 PASS) ##########"; exit 0
fi
echo "########## P6b: 通过 ##########"; exit 0
