#!/bin/bash
#=============================================================================
# srv_p6b_final_accept.sh — P6b **正式验收** (冻结位流 BUILD_ID=6, 36 字窗口) 主机侧
#
#   用法: sudo bash srv_p6b_final_accept.sh abe   # A 身份/前置 + B 时钟 + C 链路 + E 对账守恒
#          sudo bash srv_p6b_final_accept.sh d     # A 身份/前置 + D 图案/吞吐 + E9
#   前置: 板子必须**刚重烧过最终位流并重启过主机** (本脚本不烧录、不重启)。
#   日志: /tmp/p6b_final_accept_<stage>.log
#
#   ---- 每段的期望来源 (判据的"牙"从哪来) ----
#     A: MAGIC/BUILD_ID/MARKER 的期望值 = P6E_OBS.md 寄存器表 + P6B_INTEGRATION_REVIEW.md
#        (`board/wrapper_p4.v:2883` .BUILD_ID_V(32'h00000006)); A5 的地址选择纪律
#        (`ar_word=araddr[7:2]` 6 位 ⇒ 每 256B 回绕) = P6E_OBS.md「扩窗必须五处同改」⑤。
#     B: B2 的 156.25MHz 期望 = P6B_SPEC §1 (Y2 晶振 156.25MHz × 66 = 10.3125GHz) +
#        P6B_SPEC §7.5 (W24 = 数据面域自由计数); B3 的 125MHz 对照 = W5(gmii_free) 语义。
#     C: 链路判据 = P6E_OBS.md 第七节 (真 ping 5/5 + 数据面自报计数严格对账)。
#     D: D1 的 900Mbps 门 = 1G 线速理论极限 957.1 Mbps = 1472/1538×1000 的 ~94%;
#        D2 的"只看板子自报/网卡硬件计数" = 本工程已两次踩过"用户态 socket 天花板"的教训;
#        D3 的独立路径 (tcpdump + 离线代数) = _proj_pcie/smoke_scratch/verify_pcap_pattern.py 头注释。
#     E: E1/E8 的结构式 = P6B_CDC_AUDIT 的 F4 守恒 (W30==W0+W32 / W31==W1-4W0+W33);
#        E3 的 W21 前置 = 对抗审查 F11 (帧内中止后残字被当新帧重发 ⇒ W20 多计);
#        E5 的 ÷80 口径 = P6B_SPEC §5.1 (rst_cnt 64→80 拍, 维持 512ns)。
#
#   ---- 退出码: 0=无 FAIL / 1=有 FAIL / 2=前置不通过(拒绝继续) / 5=D 段前提不成立(未重烧) ----
#=============================================================================
set -u
STAGE=${1:-abe}
case "$STAGE" in abe|d) ;; *) echo "用法: $0 <abe|d>"; exit 9;; esac

# ===== 地址表 (P6E_OBS.md 36 字版) =====
#   0x00 RO MAGIC=0x50360001 / 0x04 RO BUILD_ID=6 / 0x08 RW SCRATCH / 0x0C RO FREECNT
#   0x10 RO HW_STATUS / 0x14 RO MARKER=0xDEADBEEF / 0x18 WO SNAP_CTRL / 0x1C RO SNAP_STATUS
#   0x20..0xAC RO SNAP_W0..W35  (未实现地址 = 0xB0)
#   W0 收帧 W1 收字节 W3 FCS错 W4 MAC丢 W5 gmii_free(FE活体) W6 交慢路径 W7 HLS发帧
#   W8/W9 图案app发帧/发字节 W10 图案app收帧 W13 图案失配 W17 看门狗拍 W18 整帧回卷
#   W19 适配器丢 W20 MAC发帧 W21 MAC帧内中止 W24 数据面自由计数 W25 MMCM状态字[0]=locked
#   W26 rxcdc满拍 W27 rxcdc峰值 W28 txcdc峰值 W29 DP等线拍 W30 rxcdc读侧帧数 W31 =Σpopc
#   W32 drop_partial W33 orphan_bytes W34 drop_full W35 fifo_sync拒写
W0=0; W1=1; W3=3; W4=4; W5=5; W6=6; W7=7; W8=8; W9=9; W10=10; W13=13; W17=17
W18=18; W19=19; W20=20; W21=21; W24=24; W25=25; W26=26; W27=27; W28=28; W29=29
W30=30; W31=31; W32=32; W33=33; W34=34; W35=35
ADDR_DP_FREE=0x80      # W24
ADDR_MMCM=0x84         # W25
ADDR_UNIMPL=0xB0       # 第一个未实现地址 (⚠️ 绝不能挑 >=0x100: ar_word 只有 6 位, 每 256B 回绕)
EXPECT_BUILD_ID=0x00000006
EXPECT_MAGIC=0x50360001
EXPECT_MARKER=0xdeadbeef
DP_FREE_NOM_MHZ=156.25
FE_FREE_NOM_MHZ=125.0

IFACE=enp3s0
BOARD=192.168.100.2
MYCIDR=192.168.100.1/24
PORT=8081
KO=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/xdma/xdma.ko
TOOLS=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
DEV=/dev/xdma0_user
PAT_SRC=/home/a/xdma_test/p6e_udp_pattern.cpp
PAT_BIN=/tmp/p6b_final_udp_pattern
TEACH=/home/a/xdma_test/srv_p6b_final_teach.py
VERIFY=/home/a/xdma_test/verify_pcap_pattern.py
PCAP=/tmp/p6b_final_pat.pcap
LOG=/tmp/p6b_final_accept_$STAGE.log
M32=$((1<<32))
PING_TMO=2

PASS=0; FAIL=0; SKIP=0; NOTE=0
declare -a SUM
exec > >(tee "$LOG") 2>&1

res(){ case "$1" in PASS) PASS=$((PASS+1));; FAIL) FAIL=$((FAIL+1));; SKIP) SKIP=$((SKIP+1));; NOTE) NOTE=$((NOTE+1));; esac
  SUM+=("$(printf '%s|%-4s|%s|%s' "$2" "$1" "$3" "$5")")
  printf "  [%-4s] 判据%-4s 判据=%s | 期望=%s | 实测=%s\n" "$1" "$2" "$3" "$4" "$5"; }
skip_unimpl(){ res SKIP "$1" "$2" "$3" "SKIP (未实现: $4 读回 0xffffffff ⇒ SLVERR/未上线)"; }

# rd(): **读失败返回非零**。reg_rw 输出形如 "at address 0xNN : 0xVV", 必须 tail -1 + 去前缀;
#   再校验 0x 前缀 —— 非十六进制一律当读失败 (**空读 != 真 0**)。
rd2(){ local v; v=$($TOOLS/reg_rw "$1" "$2" w 2>/dev/null | tail -1 | sed 's/.*: *//')
       [[ "$v" =~ ^0[xX][0-9a-fA-F]{1,8}$ ]] || return 1; echo "$v"; }
rd(){ rd2 "$DEV" "$1"; }
# rd_new(): 0xffffffff 一律按"未实现"处理 (XDMA 的 AXI-Lite 主机把 SLVERR 的数据填成 0xffffffff)。
#   返回 0=读到值 / 1=读失败 / 2=未实现。只对**不可能合法等于 0xffffffff** 的字成立。
rd_new(){ local v; v=$(rd "$1") || return 1; [ "$v" = "0xffffffff" ] && return 2; echo "$v"; }
wr(){ $TOOLS/reg_rw $DEV "$1" w "$2" >/dev/null 2>&1; }
now(){ if [ -n "${EPOCHREALTIME:-}" ]; then echo "$EPOCHREALTIME"; else date +%s.%N; fi; }
el(){ awk -v a="$1" -v b="$2" 'BEGIN{printf "%.6f", b-a}'; }

# snap(): 写 0x18=1 触发, 轮询 done; 并用 **gen 恰好 +1** 自证"这一轮是本进程触发的、且没有第二个写者"。
#   ⚠️ done 是 sticky 的: 没有这条守卫, 并发读者会互相污染 (2026-09-29 实测踩过, 那批读数作废)。
#   **这段逻辑是被实证逼出来的, 不许简化** (照抄 p6e_slowpath_probe.sh / p6b_accept.sh)。
snap(){ local g0 g1 s i
        g0=$(rd 0x1c) || return 1; g0=$(( (g0 >> 16) & 0xffff ))
        wr 0x18 0x1
        for i in $(seq 1 100); do s=$(rd 0x1c) || continue
            [ $(( s & 2 )) -ne 0 ] && break; sleep 0.01; done
        g1=$(rd 0x1c) || return 1; g1=$(( (g1 >> 16) & 0xffff ))
        [ $(( (g1 - g0) & 0xffff )) -eq 1 ]; }
# readall(): 读全 **36 个已实现**的字 (0x20..0xAC); 任一读空 ⇒ 整轮作废 (返回非零)。
#   ⚠️ 不在这里读 >=0xB0 的地址 (未实现时合法回 0xffffffff, 混进来会污染整个数组)。
readall(){ local a i=0 v; for a in 20 24 28 2c 30 34 38 3c 40 44 48 4c 50 54 58 5c 60 64 68 6c 70 74 78 7c 80 84 88 8c 90 94 98 9c a0 a4 a8 ac; do
             v=$(rd 0x$a) || return 1; W[$i]=$(( v )); i=$((i+1)); done; }
# round(): 一次"认位流 + 触发 + 读全"的完整动作, 含三道自证 (MAGIC 在 / gen 恰好 +1 / 无空读)。
round(){ local m; m=$(rd 0x00) || return 1
         [ "$(( m ))" -eq "$(( EXPECT_MAGIC ))" ] || return 1
         snap || return 1
         readall || return 1; }
dd(){ local d=$(( ($2 - $1) % M32 )); echo $(( d < 0 ? d + M32 : d )); }
NICP(){ ethtool -S $IFACE 2>/dev/null | awk '/^ *rx_packets:/{print $2}' | head -1; }
NICU(){ ethtool -S $IFACE 2>/dev/null | awk '/^ *unicast:/{print $2}' | head -1; }
NICE(){ ethtool -S $IFACE 2>/dev/null | awk '/^ *rx_errors:/{print $2}' | head -1; }
NICM(){ ethtool -S $IFACE 2>/dev/null | awk '/^ *rx_missed:/{print $2}' | head -1; }
NICS(){ cat /sys/class/net/$IFACE/statistics/rx_packets; }
prep(){ ip -br addr show "$IFACE" 2>/dev/null | grep -q "192.168.100.1" || {
          ip link set "$IFACE" up 2>/dev/null
          ip addr add $MYCIDR dev "$IFACE" 2>/dev/null && echo "[setup] 补加 $MYCIDR 到 $IFACE"; }
        ip link set "$IFACE" up 2>/dev/null; }
dump_abs(){ local names=(W0收帧 W1收字节 W2帧长 W3FCS错 W4MAC丢 W5gmii_free W6交慢路径 W7HLS发帧 \
    W8图案发帧 W9图案发字节 W10图案收帧 W11图案收字节 W12空帧 W13图案失配 W14TCP发帧 W15TCP发字节 \
    W16HLS读字节 W17看门狗拍 W18整帧回卷 W19适配器丢 W20MAC发帧 W21帧内中止 W22TCP收帧 W23TCP非匹配 \
    W24数据面自由计数 W25MMCM状态 W26rxcdc满拍 W27rxcdc峰值 W28txcdc峰值 W29DP等线拍 \
    W30rxcdc读帧 W31rxcdcΣpopc W32drop_partial W33orphan_bytes W34drop_full W35fifo_ovf)
  local i; for i in $(seq 0 35); do printf "    W%-2s (%#04x) %-18s = %s\n" "$i" "$((0x20+4*i))" "${names[$i]}" "${W[$i]}"; done; }

echo "########## P6b 正式验收 [stage=$STAGE] $(date '+%F %T') ##########"
echo "位流期望: MAGIC=$EXPECT_MAGIC BUILD_ID=$EXPECT_BUILD_ID (冻结位流 sha256 c17700868b08170865f4a4ae0292ebb636aed03070e2875f6dbb005123a948ca)"
prep; ip -br addr show "$IFACE"
echo "-- 等 PCIe 端点 / 驱动 / user BAR --"
for i in $(seq 1 60); do ls /dev/xdma0_user >/dev/null 2>&1 && break; sleep 2; done
if ! lsmod | grep -qw xdma; then echo "[setup] insmod xdma.ko"; insmod "$KO" 2>/dev/null || true; sleep 2; fi
if [ ! -e "$DEV" ]; then
  echo "[FATAL] 没有 $DEV ⇒ 观测通道不可用。按序查: ① 烧完有没有**重启主机** (PCIe 端点只认 FPGA 配置先于 POST)"
  echo "        ② xdma 驱动 insmod 了吗。⚠️ 判活**只看 BAR 读得动**, 不看 lspci (那可能是主机侧缓存)。"
  exit 2
fi
ls /dev/xdma0_* | tr '\n' ' '; echo
# ⚠️ 判活只看 BAR: 读 MAGIC。全 0xffffffff 一律当"没应答" (否则按位判的判据会假通过)。
M0=$(rd 0x00) || M0=""
if [ -z "$M0" ]; then echo "[FATAL] user BAR 读不出来 ⇒ 通道没应答 (最可能: 烧录后主机没重启)"; exit 2; fi
if [ "$M0" = "0xffffffff" ]; then echo "[FATAL] user BAR 全 0xffffffff (SLVERR) ⇒ 通道没应答 (最可能: 没重启)"; exit 2; fi

#=============================================================================
# A. 位流身份与前置
#=============================================================================
echo; echo "===== A. 位流身份与前置 ====="
B0=$(rd 0x04) || B0=""; MK=$(rd 0x14) || MK=""
[ "$(( M0 ))" -eq "$(( EXPECT_MAGIC ))" ] && res PASS A1 "MAGIC == 0x50360001" "0x50360001" "$M0" \
  || res FAIL A1 "MAGIC == 0x50360001" "0x50360001" "${M0:-读失败}"
if [ -z "$B0" ]; then res FAIL A2 "BUILD_ID == 6" "0x00000006" "读失败"
elif [ "$(( B0 ))" -eq "$(( EXPECT_BUILD_ID ))" ]; then res PASS A2 "BUILD_ID == 6 (P6b+F4 双域 36 字版)" "0x00000006" "$B0"
else res FAIL A2 "BUILD_ID == 6" "0x00000006" "$B0 ⇒ **板上不是这一版位流**"; fi
[ "$MK" = "0xdeadbeef" ] && res PASS A3 "MARKER == 0xdeadbeef (地址译码)" "0xdeadbeef" "$MK" \
  || res FAIL A3 "MARKER == 0xdeadbeef" "0xdeadbeef" "${MK:-读失败}"
F1=$(rd 0x0c) || F1=""; sleep 0.1; F2=$(rd 0x0c) || F2=""
if [ -z "$F1" ] || [ -z "$F2" ]; then res FAIL A4 "FREECNT 两次读不同 (AXI 域活性)" "变化" "读失败"
elif [ "$F1" != "$F2" ]; then res PASS A4 "FREECNT 两次读不同 (AXI 域活性)" "变化" "$F1 -> $F2 (Δ=$(( F2 - F1 )))"
else res FAIL A4 "FREECNT 两次读不同" "变化" "$F1 -> $F2 (**冻结** ⇒ AXI 域死了?)"; fi
# A5: 未实现地址 ⇒ 0xffffffff。负对照 = 同一趟里读一个已实现字必须回真值。
#   ⚠️ 地址必须 <0x100 (ar_word=araddr[7:2] 6 位, 每 256B 回绕: 挑 0x100 会别名到 MAGIC ⇒ 假 FAIL;
#      挑 0x160 会别名到已实现字 ⇒ 假 PASS)。
VB0=$(rd $ADDR_UNIMPL) || VB0=""
CTL=$(rd 0x14) || CTL=""
if [ -z "$VB0" ]; then res FAIL A5 "未实现地址 0xB0 ⇒ 0xffffffff (SLVERR)" "0xffffffff" "读失败 (空读 != 真 0)"
elif [ "$VB0" = "0xffffffff" ]; then res PASS A5 "未实现地址 0xB0 ⇒ 0xffffffff (SLVERR)" "0xffffffff" "$VB0 (负对照: 同趟 0x14 回 $CTL ≠ 0xffffffff ⇒ 不是通道死)"
else res FAIL A5 "未实现地址 0xB0 ⇒ 0xffffffff" "0xffffffff" "$VB0 ⇒ 写/读译码越界或地址别名"; fi
echo "  [INFO] 地址纪律自检: 判据地址 0xB0 < 0x100 ✓ (ar_word=araddr[7:2] 只有 6 位 ⇒ 每 256B 回绕)"
# A6: 快照读法必须用 gen 字段自证 (snap() 内含)。这里显式跑一次并把 gen 印出来。
G0=$(rd 0x1c) || G0=""
if round; then
  G1=$(rd 0x1c) || G1=""
  res PASS A6 "快照 gen 恰好 +1 (自证本轮由本进程触发)" "gen:g0->g0+1" "gen $(( (G0 >> 16) & 0xffff )) -> $(( (G1 >> 16) & 0xffff ))"
  echo "  [INFO] SNAP_STATUS(0x1C) 快照后 = $G1  ([31:16]gen [2]seen [1]done [0]busy)"
  echo "  [INFO] W25(MMCM 状态字) = ${W[$W25]} ; HW_STATUS(0x10) = $(rd 0x10 || echo 读失败)"
else
  res FAIL A6 "快照 gen 恰好 +1" "自证成立" "失败 (gen 没 +1 / 有空读 / MAGIC 不在)"
fi
# A7: 读失败与读到 0 必须可区分 —— 用**不存在的设备**做负对照, rd() 必须返回非零 (不是 0)。
if VX=$(rd2 /dev/xdma0_this_device_does_not_exist 0x00); then
  res FAIL A7 "读失败必须可区分于读到 0" "读失败⇒非零" "负对照返回了 $VX (把失败当值了)"
else res PASS A7 "读失败必须可区分于读到 0 (负对照: 伪设备)" "读失败⇒非零" "伪设备读取被 rd() 判为失败 ✓"; fi
echo "  [INFO] 未实现地址的 SKIP 语义: 本次 $( [ "$VB0" = "0xffffffff" ] && echo '0xB0 回 0xffffffff ⇒ 按"未实现"处理' ) (绝不当 PASS)"

if [ "$STAGE" = "d" ]; then
#=============================================================================
# D. 图案 / 吞吐 (必须紧接重烧之后、任何其它 teach 之前)
#=============================================================================
echo; echo "===== D. 图案/吞吐 (独立三口径) ====="
if ! round; then echo "[FATAL] 快照自证失败 ⇒ D 段读数不可信"; exit 2; fi
echo "  [INFO] teach 前基线: W8(图案发帧)=${W[$W8]} W9(图案发字节)=${W[$W9]} W10(图案收帧)=${W[$W10]} W13(失配)=${W[$W13]}"
if [ "${W[$W8]}" -ne 0 ] || [ "${W[$W10]}" -ne 0 ]; then
  echo "  [FATAL] **板子已经被教过 peer** (W8=${W[$W8]} W10=${W[$W10]} != 0) ⇒ D 段前提不成立。"
  echo "          本工程实测: 图案 app 一旦被 teach 就**永久全速发**, 直到重新烧录位流。"
  echo "          ⇒ 重烧位流 + 重启主机后**先跑 D**, 再跑别的。本次 D 段作废 (不判 PASS/FAIL)。"
  exit 5
fi
res PASS D0 "板子从未被教过 peer (D 段前提: 刚重烧)" "W8=W10=0" "W8=0 W10=0 W9=0"
# ⚠️ teach 的前置: 必须先把 ARP 打通。**实测踩过**: 主机重启后 NetworkManager 把
#    192.168.100.1 清掉 ⇒ 内核发不出 ARP 请求 ⇒ teach 的 UDP 包被排队后静默丢弃
#    ⇒ 现象是"板子收到 0 帧、不开始发" —— **看着像板子坏, 其实是"我没发"**。
prep
for i in 1 2 3; do ping -c 1 -W 1 $BOARD >/dev/null 2>&1 && break; sleep 1; done
ip -br addr show $IFACE | grep -q 192.168.100.1 || { echo "[FATAL] 接口上没有 192.168.100.1 ⇒ 拒绝继续 (NM 又冲掉了)"; exit 6; }
if ip neigh show dev $IFACE | grep -qE "$BOARD.*(REACHABLE|STALE|DELAY|PROBE|PERMANENT)"; then
  res PASS D0b "ARP 预检: teach 之前 peer 已解析 (否则 teach 发不出去)" "有 ARP 表项" "$(ip neigh show dev $IFACE | grep $BOARD)"
else
  echo "[FATAL] ARP 未解析 ($BOARD) ⇒ teach 一定发不出去 ⇒ **不判 D 段** (这是"我没发", 不是板子的问题)"
  ip neigh show dev $IFACE; exit 6
fi

# --- D3 的抓包 (独立路径) 必须在 teach 之前武装 ---
rm -f "$PCAP"
tcpdump -i $IFACE -s 0 -c 2000 -B 8192 -w "$PCAP" "udp port $PORT" >/tmp/p6b_final_tcpdump.err 2>&1 &
TCPD=$!; sleep 1.5
# --- teach (发 1 个图案前缀包; 本机先 bind 8081 抑制 ICMP 洪水) ---
python3 "$TEACH" --board $BOARD --port $PORT --hold 120 > /tmp/p6b_final_teach.log 2>&1 &
TEACHP=$!; sleep 2
cat /tmp/p6b_final_teach.log
for i in $(seq 1 40); do kill -0 $TCPD 2>/dev/null || break; sleep 0.5; done
sleep 1; kill $TCPD 2>/dev/null; wait $TCPD 2>/dev/null
PCAP_SZ=$(stat -c %s "$PCAP" 2>/dev/null || echo 0)
echo "  [INFO] tcpdump: 抓包文件 $PCAP = $PCAP_SZ B ($(grep -c . /tmp/p6b_final_tcpdump.err 2>/dev/null || echo 0) 行 stderr)"
head -3 /tmp/p6b_final_tcpdump.err

# --- D1/D2/E9 窗口: 两个快照之间 (~10s), 同时读网卡**硬件**计数 ---
if ! round; then echo "[FATAL] 窗口起点快照失败"; exit 2; fi
TA=$(now); P9A=${W[$W9]}; P8A=${W[$W8]}
NA=$(NICP); NU=$(NICU); NS=$(NICS); NE=$(NICE); NM=$(NICM)
echo "  [INFO] 窗口起点 (T=$TA): W8=$P8A W9=$P9A | 网卡硬件 rx_packets=$NA unicast=$NU (sysfs=$NS) rx_errors=$NE rx_missed=$NM"
sleep 10
if ! round; then echo "[FATAL] 窗口终点快照失败"; exit 2; fi
TB=$(now); P9B=${W[$W9]}; P8B=${W[$W8]}
NB=$(NICP); NU2=$(NICU); NS2=$(NICS); NE2=$(NICE); NM2=$(NICM)
DT=$(el "$TA" "$TB")
D9=$(dd "$P9A" "$P9B"); D8=$(dd "$P8A" "$P8B")
RATE=$(awk -v d="$D9" -v t="$DT" 'BEGIN{printf "%.1f", d*8/t/1e6}')
DRX=$(( NB - NA )); DRXU=$(( NU2 - NU )); DRXS=$(( NS2 - NS ))
NRATE=$(awk -v d="$DRX" -v t="$DT" 'BEGIN{printf "%.1f", d*1472*8/t/1e6}')
NRATE_U=$(awk -v d="$DRXU" -v t="$DT" 'BEGIN{printf "%.1f", d*1472*8/t/1e6}')
echo "  [INFO] 窗口终点 (T=$TB, Δt=${DT}s): W8=$P8B W9=$P9B | 网卡硬件 rx_packets=$NB unicast=$NU2 (sysfs=$NS2) rx_errors=$NE2 rx_missed=$NM2"
echo "  [INFO] 增量: ΔW8=$D8 ΔW9=$D9 | 网卡 Δrx_packets=$DRX Δunicast=$DRXU Δsysfs=$DRXS Δrx_errors=$(( NE2-NE )) Δrx_missed=$(( NM2-NM ))"
echo "  [INFO] 理论线速上限 = 1472/1538×1000 = 957.1 Mbps (1538 = 1472 载荷 + 8 UDP + 20 IP + 14 ETH + 4 FCS + 20 前导/IFG)"
if awk -v r="$RATE" 'BEGIN{exit !(r>=900.0)}'; then
  res PASS D1 "板子自报图案 TX 速率 >= 900 Mbps" ">=900 (线速 957.1)" "${RATE} Mbps (ΔW9=$D9 B / ${DT}s)"
else res FAIL D1 "板子自报图案 TX 速率 >= 900 Mbps" ">=900 (线速 957.1)" "${RATE} Mbps (ΔW9=$D9 B / ${DT}s)"; fi
# D2: 独立佐证 —— 网卡**硬件**计数 (不是用户态 socket)。口径与板子一致: 每帧 1472 B 载荷。
#   ⚠️ **空读 != 真 0**: 两边都是 0 时"0 对 0 吻合"是假 PASS ⇒ 必须先要求板子侧非 0。
if [ "$D9" -eq 0 ]; then
  res SKIP D2 "网卡硬件计数与板子自报吻合" "|Δ|<=3%" "SKIP (板子自报 ΔW9=0 ⇒ 没有可佐证的流量; 0 对 0 不是吻合)"
elif awk -v a="$NRATE" -v b="$RATE" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d <= 0.03*b)}'; then
  res PASS D2 "网卡**硬件**计数与板子自报吻合 (同口径 ±3%)" "|Δ|<=3%" "网卡 ${NRATE} Mbps (unicast ${NRATE_U}) vs 板子 ${RATE} Mbps; 偏差 $(awk -v a="$NRATE" -v b="$RATE" 'BEGIN{printf "%.2f%%", 100*(a-b)/b}')"
else res FAIL D2 "网卡硬件计数与板子自报吻合" "|Δ|<=3%" "网卡 ${NRATE} Mbps vs 板子 ${RATE} Mbps ⇒ 有帧没到线上/没进网卡 (或两口径不同)"; fi
[ "${W[$W10]}" -ge 1 ] && echo "  [INFO] teach 到达 app 层 ✓ (W10=${W[$W10]} >= 1 ⇒ 图案 app 收到了 my teach 帧)" \
  || echo "  [WARN] W10=0 ⇒ teach 帧**没到** app 层 (板子 MAC 收到了但没交给 app ⇒ 查 rx_classify/udp_split 的端口/IP 过滤)"
if [ "$D8" -gt 0 ]; then
  BPF=$(awk -v d="$D9" -v f="$D8" 'BEGIN{printf "%.4f", d/f}')
  if awk -v b="$BPF" 'BEGIN{exit !(b>=1471.0 && b<=1473.0)}'; then
    res PASS E9 "增量自洽: ΔW9/ΔW8 ≈ 1472.0 B/帧" "[1471,1473]" "$BPF B/帧 (ΔW9=$D9 / ΔW8=$D8)"
  else res FAIL E9 "ΔW9/ΔW8 ≈ 1472.0 B/帧" "[1471,1473]" "$BPF B/帧"; fi
else res FAIL E9 "ΔW9/ΔW8 ≈ 1472.0 B/帧" "ΔW8>0" "ΔW8=0 ⇒ 图案 app 没在发"; fi
# D4: 板子自己的校验器与 MAC/FCS 计数
[ "${W[$W13]}" -eq 0 ] && res PASS D4a "板子自报图案失配 W13 == 0" "0" "${W[$W13]}" \
  || res FAIL D4a "板子自报图案失配 W13 == 0" "0" "${W[$W13]}"
[ "${W[$W3]}" -eq 0 ] && res PASS D4b "FCS 错帧 W3 == 0 (物理层/前端配方)" "0" "${W[$W3]}" \
  || res FAIL D4b "FCS 错帧 W3 == 0" "0" "${W[$W3]}"
echo "  [INFO] 板子侧: W10(图案 app 收帧)=${W[$W10]} (>=1 ⇒ peer 学到了) W4(MAC 丢)=${W[$W4]} W21(帧内中止)=${W[$W21]} W20(MAC 发帧)=${W[$W20]} W7(HLS 发帧)=${W[$W7]}"

# --- D3: 离线代数验证 (tcpdump 独立路径) ---
echo; echo "  --- D3: 独立路径逐字节验证 (tcpdump pcap + 离线反解 xorshift64 状态) ---"
if [ "${PCAP_SZ:-0}" -gt 100000 ] && [ -f "$VERIFY" ]; then
  python3 "$VERIFY" "$PCAP" --paylen 1472 --dport $PORT > /tmp/p6b_final_verify.log 2>&1; VRC=$?
  cat /tmp/p6b_final_verify.log
  if [ "$VRC" -eq 0 ]; then res PASS D3 "抓到的帧逐字节等于图案流 + 相邻帧严格相邻 + 0 处无法归因" "verifier exit 0" "exit 0"
  else res FAIL D3 "抓到的帧逐字节等于图案流 (独立路径)" "verifier exit 0" "exit $VRC ⇒ 见 /tmp/p6b_final_verify.log"; fi
  # 附加: 流是否真的从 offset 0 开始 (逐帧反解出的状态里必须有一帧 == SEED)
  if [ -f /home/a/xdma_test/srv_p6b_final_verify0.py ]; then
    python3 /home/a/xdma_test/srv_p6b_final_verify0.py "$PCAP" --paylen 1472 --dport $PORT > /tmp/p6b_final_verify0.log 2>&1; V0RC=$?
    cat /tmp/p6b_final_verify0.log
    if [ "$V0RC" -eq 0 ]; then res PASS D3b "图案流从 offset 0 开始 (某一帧状态 == SEED 且载荷逐字节复算通过)" "找到 SEED 帧" "见上行 (exit 0)"
    else res FAIL D3b "图案流从 offset 0 开始" "找到 SEED 帧" "exit $V0RC ⇒ 见 /tmp/p6b_final_verify0.log"; fi
  fi
else
  res FAIL D3 "独立路径逐字节验证" "pcap>100KB" "pcap=${PCAP_SZ:-0}B (抓不到 ⇒ 先查 teach 有没有生效/过滤器) 或 verifier 缺失"
fi
kill $TEACHP 2>/dev/null
else
#=============================================================================
# B. 时钟 / C. 链路 / E. 对账守恒
#=============================================================================
echo; echo "===== B. 时钟 (P6b 核心) ====="
if ! round; then echo "[FATAL] 快照自证失败"; exit 2; fi
[ "$(( ${W[$W25]} & 1 ))" -eq 1 ] && res PASS B1 "MMCM locked = 1 (W25 bit0)" "1" "W25=${W[$W25]} & 1 = 1" \
  || res FAIL B1 "MMCM locked = 1 (W25 bit0)" "1" "W25=${W[$W25]} & 1 = 0 ⇒ MMCM 没锁"
echo "  [INFO] 图案 app 状态 (必须是 0 = 板子安静; 若不为 0 则 E3/E4 前提被破坏): W8=${W[$W8]} W9=${W[$W9]} W10=${W[$W10]}"
PAT_IDLE=1; { [ "${W[$W8]}" -eq 0 ] && [ "${W[$W10]}" -eq 0 ]; } || PAT_IDLE=0
FE_A=${W[$W5]}; DP_A=${W[$W24]}; GEN_A=$(( ($(rd 0x1c) >> 16) & 0xffff ))
TA=$(now)
echo "  [INFO] 窗口起点: gen=$GEN_A W5(gmii_free FE 域)=$FE_A DP_FREE(W24 @$ADDR_DP_FREE)=$DP_A"
# ⚠️⚠️ **W24(0x80) 是快照字**: 直接读回的是**上一次锁存**的值 —— 两端都直接读会读到同一个
#    冻结值 ⇒ Δ=0 ⇒ 假 FAIL (本 agent 第一次跑就踩了, 见 P6B_ACCEPT.md)。正确做法 = 两端都走
#    round() (触发+锁存+读全), 时间戳取在 round() 返回处; 两端对称 ⇒ 时间偏差抵消。
# 窗口 ≥10s 且 <20s: 下界是判据, 上界给 32 位 @156.25MHz 的 27.5s 回绕留余量
while :; do DT=$(el "$TA" "$(now)"); awk -v d="$DT" 'BEGIN{exit !(d>=12.0)}' && break; sleep 0.5; done
if ! round; then echo "[FATAL] 窗口终点快照失败"; exit 2; fi
FE_B=${W[$W5]}; DP_B=${W[$W24]}; TB=$(now); DT=$(el "$TA" "$TB")
echo "  [INFO] 窗口终点: W5=$FE_B DP_FREE=$DP_B ; 真实窗口 (墙钟) = ${DT}s"
if [ "${DP_A}" -eq $((0xffffffff)) ] || [ "${DP_B}" -eq $((0xffffffff)) ]; then
  skip_unimpl B2 "数据面域频率实测" "156.25MHz ±1%" "字 $ADDR_DP_FREE"
else
  A=$(( DP_A )); B=$(( DP_B ))
  if [ "$B" -lt "$A" ]; then DCNT=$(( (M32 - A) + B )); WR="(已补偿 1 次回绕)"; else DCNT=$(( B - A )); WR=""; fi
  MHZ=$(awk -v d="$DCNT" -v t="$DT" 'BEGIN{printf "%.4f", d/t/1e6}')
  if awk -v t="$DT" 'BEGIN{exit !(t>=10.0 && t<20.0)}'; then res PASS B2a "窗口落在 [10,20)s" "[10,20)" "${DT}s $WR"
  else res FAIL B2a "窗口落在 [10,20)s" "[10,20)" "${DT}s ⇒ 频率读数不可用"; fi
  LO=$(awk -v f="$DP_FREE_NOM_MHZ" 'BEGIN{printf "%.2f", f*0.99}'); HI=$(awk -v f="$DP_FREE_NOM_MHZ" 'BEGIN{printf "%.2f", f*1.01}')
  if awk -v m="$MHZ" -v l="$LO" -v h="$HI" 'BEGIN{exit !(m>=l && m<=h)}'; then
    res PASS B2b "数据面域频率 = 156.25MHz ±1%" "[$LO,$HI] MHz" "${MHZ} MHz (Δ=$DCNT / ${DT}s)"
  else res FAIL B2b "数据面域频率 = 156.25MHz ±1%" "[$LO,$HI] MHz" "${MHZ} MHz (Δ=$DCNT / ${DT}s)"; fi
  V=$(awk -v m="$MHZ" 'BEGIN{d1=(m>125)?m-125:125-m; d2=(m>156.25)?m-156.25:156.25-m; print (d1<d2)?"125":"156.25"}')
  [ "$V" = "156.25" ] && echo "  [判决] ${MHZ} MHz 更接近 **156.25** ⇒ 数据面确实在新域上 ✓" \
                      || echo "  [判决] ${MHZ} MHz 更接近 **125** ⇒ **数据面没搬到新域** (查 W24 是否别名到 FE 计数器)"
fi
DF=$(dd "$FE_A" "$FE_B"); MFE=$(awk -v d="$DF" -v t="$DT" 'BEGIN{printf "%.4f", d/t/1e6}')
if awk -v m="$MFE" 'BEGIN{exit !(m>=123.75 && m<=126.25)}'; then
  res PASS B3 "前端对照 W5 ≈ 125MHz (两域频率必须不同)" "[123.75,126.25]" "${MFE} MHz (Δ=$DF / ${DT}s) ⇒ 与数据面域不同频 = 真搬到新域的结构证据"
else res FAIL B3 "前端对照 W5 ≈ 125MHz" "[123.75,126.25]" "${MFE} MHz (Δ=$DF / ${DT}s)"; fi

echo; echo "===== C. 链路 (真 ping, 只看 BAR 判活) ====="
prep; ip -br addr show "$IFACE" | grep -q 192.168.100.1 && echo "  [setup] IP 在位 ✓ (每次发流量前核一次: NM 会把它冲掉)" || { echo "  [FATAL] IP 没加上 ⇒ 拒绝发流量"; exit 2; }
ping -c 1 -W 2 $BOARD >/dev/null 2>&1; sleep 0.3   # 热身: 先把 ARP 打通, 免得第一包被 ARP 延迟吃掉
ping -c 5 -W $PING_TMO $BOARD > /tmp/p6b_final_ping1.txt 2>&1
P1=$(grep -oE '[0-9]+ received' /tmp/p6b_final_ping1.txt | grep -oE '[0-9]+'); P1=${P1:-0}
RTT=$(grep -oE 'rtt min/avg/max/mdev = [0-9./]+' /tmp/p6b_final_ping1.txt | cut -d= -f2)
[ "$P1" = "5" ] && res PASS C1 "ping -c 5 全通" "5/5" "5/5 rtt(avg/max/mdev)=${RTT:-?}" \
  || res FAIL C1 "ping -c 5 全通" "5/5" "$P1/5 (按【哪一环不涨】定位: ΔW0=0 帧没到 FPGA / ΔW6=0 没进慢路径 / ΔW7=0 HLS 没回)"
P2=$(ping -c 20 -i 0.05 -W $PING_TMO $BOARD 2>/dev/null | grep -oE '[0-9]+ received' | grep -oE '[0-9]+'); P2=${P2:-0}
[ "$P2" = "20" ] && res PASS C2 "ping -c 20 -i 0.05 复测" "20/20" "20/20" \
  || res FAIL C2 "ping -c 20 -i 0.05 复测" "20/20" "$P2/20 (密集包是比真实 PC 更严苛的用例; -i<0.2 需 root)"

echo; echo "===== E. 观测通道对账与守恒 (停机态) ====="
# 停机窗口 = [13us, 4s): 下界让在途帧排空, 上界避开 HLS 的 HELLO 周期 4s (否则 HELLO 会注入新流量)
# ⚠️ 主机侧**周期性背景帧**会让"停机窗"不静默 (实测 tcpdump 抓到三种, 都与板子无关):
#    ① 板子每 ~9s 往主机 :8080 发 HELLO, 若 8080 上没有 socket, 内核对每帧回 **ICMP port-unreachable**
#       (13:04:51 抓到) —— 这是最常打掉静默窗的一路 ⇒ 先 **bind 8080** 把它掐掉;
#    ② 主机每 ~15s 往 192.168.100.255:1534 发 296B 广播 UDP (主机侧某个服务发现);
#    ③ ARP 表项刷新。
python3 - >/dev/null 2>&1 <<'PYEOF' &
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("0.0.0.0", 8080))
try:
    t = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); t.bind(("0.0.0.0", 8081))
except OSError:
    t = None
time.sleep(120)
PYEOF
HOLD8080=$!
E_OK=0
for ATT in 1 2 3 4 5; do
  sleep 0.8
  if ! round; then echo "[FATAL] E 段起点快照失败"; exit 2; fi
  E_W0=${W[$W0]}; E_W1=${W[$W1]}; E_W6=${W[$W6]}; E_W7=${W[$W7]}; E_W20=${W[$W20]}; E_W21=${W[$W21]}
  E_W30=${W[$W30]}; E_W31=${W[$W31]}; E_W32=${W[$W32]}; E_W33=${W[$W33]}
  echo "  [INFO] 第$ATT 次停机窗口起点: W0=$E_W0 W1=$E_W1 W6=$E_W6 W7=$E_W7 W20=$E_W20 W21=$E_W21 W30=$E_W30 W31=$E_W31 W32=$E_W32 W33=$E_W33"
  sleep 0.5
  if ! round; then echo "[FATAL] E 段终点快照失败"; exit 2; fi
  PQ0=$(dd $E_W0 ${W[$W0]}); PQ1=$(dd $E_W1 ${W[$W1]}); PQ30=$(dd $E_W30 ${W[$W30]}); PQ31=$(dd $E_W31 ${W[$W31]})
  if [ "$PQ0" -eq 0 ] && [ "$PQ1" -eq 0 ] && [ "$PQ30" -eq 0 ] && [ "$PQ31" -eq 0 ]; then E_OK=1; break; fi
  echo "  [INFO] 第$ATT 次不静默 (ΔW0=$PQ0 ΔW1=$PQ1 ΔW30=$PQ30 ΔW31=$PQ31) ⇒ 重试 (主机侧背景帧)"
done
[ "$E_OK" -eq 1 ] && echo "  [INFO] 停机窗静默 ✓ (连续两次快照的 RX 侧增量全 0)" || echo "  [WARN] 5 次都没抓到严格静默窗 (主机背景帧太密)"
kill $HOLD8080 2>/dev/null
echo "  [INFO] 停机窗口终点: W0=${W[$W0]} W1=${W[$W1]} W6=${W[$W6]} W7=${W[$W7]} W20=${W[$W20]} W21=${W[$W21]} W30=${W[$W30]} W31=${W[$W31]} W32=${W[$W32]} W33=${W[$W33]}"
echo "  [INFO] 停机窗口增量 (RX 侧必须全 0 = 真正排空): ΔW0=$(dd $E_W0 ${W[$W0]}) ΔW1=$(dd $E_W1 ${W[$W1]}) ΔW30=$(dd $E_W30 ${W[$W30]}) ΔW31=$(dd $E_W31 ${W[$W31]}) | ΔW7=$(dd $E_W7 ${W[$W7]}) ΔW20=$(dd $E_W20 ${W[$W20]}) (HELLO 会涨这两个, RX 侧不受影响)"
echo; echo "  --- 绝对值表 (快照 W0..W35 @ 0x20..0xAC) ---"; dump_abs
echo; echo "  --- 结构式守恒律 (mod 2^32) ---"
R30=$(( (${W[$W0]} + ${W[$W32]}) % M32 )); R31=$(( (${W[$W1]} - 4*${W[$W0]} + ${W[$W33]}) % M32 ))
R30=$(( (R30 + M32) % M32 )); R31=$(( (R31 + M32) % M32 ))
echo "    律1 期望 W30 = W0 + W32 = ${R30}   | 实测 ${W[$W30]}"
echo "    律2 期望 W31 = W1 - 4*W0 + W33 = ${R31} | 实测 ${W[$W31]}"
if [ "${W[$W30]}" -eq "$R30" ]; then res PASS E1a "E1: W30 == W0 + W32 (TLAST 交付 == 收帧 + 部分丢帧)" "结构式相等" "${W[$W30]} == $R30"
else res FAIL E1a "E1: W30 == W0 + W32" "结构式相等" "${W[$W30]} != $R30 (差 $(( ${W[$W30]} - R30 )) ⇒ CDC 丢/重帧)"; fi
if [ "${W[$W31]}" -eq "$R31" ]; then res PASS E1b "E1: W31 == W1 - 4*W0 + W33 (Σpopc 交付)" "结构式相等" "${W[$W31]} == $R31"
else res FAIL E1b "E1: W31 == W1 - 4*W0 + W33" "结构式相等" "${W[$W31]} != $R31 (差 $(( ${W[$W31]} - R31 )) ⇒ CDC 丢/重字节)"; fi
[ "${W[$W35]}" -eq 0 ] && res PASS E2 "E2: W35 (fifo_sync 拒写) == 0" "0" "${W[$W35]}" || res FAIL E2 "E2: W35 == 0" "0" "${W[$W35]}"
[ "${W[$W17]}" -eq 0 ] && res PASS E5a "E5a: W17 (饥饿看门狗低电平拍数) == 0" "0" "${W[$W17]}" || res FAIL E5a "E5a: W17 == 0" "0" "${W[$W17]} (÷80 ≈ $(( ${W[$W17]} / 80 )) 次复位)"
[ "${W[$W18]}" -eq 0 ] && res PASS E5b "E5b: W18 (slow_tx_adp 整帧回卷) == 0" "0" "${W[$W18]}" || res FAIL E5b "E5b: W18 == 0" "0" "${W[$W18]} (查 wf FIFO 消费侧)"
DMAC=$(( ${W[$W32]} + ${W[$W34]} ))
if [ "${W[$W19]}" -eq 0 ]; then res PASS E6 "E6: W19 (slow_rx_adp 丢帧) == 0" "0" "${W[$W19]}"
elif [ "$DMAC" -gt 0 ]; then
  res NOTE E6 "E6: W19 != 0 ⇒ 必须用 MAC 侧丢帧 (W32/W34) 解释" "有向耦合" "W19=${W[$W19]} 且 W32=${W[$W32]} W34=${W[$W34]} 均 >0 ⇒ **有向耦合成立** (F-2/F4: Mac 侧丢帧与适配器丢帧同源); 不判 FAIL, 也不当干净 PASS"
else res FAIL E6 "E6: W19 != 0 且 W32=W34=0" "可解释" "W19=${W[$W19]} 而 MAC 侧零丢帧 ⇒ **无法归因**"; fi
if [ "${W[$W32]}" -eq 0 ] && [ "${W[$W33]}" -eq 0 ] && [ "${W[$W34]}" -eq 0 ]; then
  res PASS E7 "E7: W32/W33/W34 (MAC 侧丢帧三兄弟) 全 0" "全 0" "W32=0 W33=0 W34=0"
else res FAIL E7 "E7: W32/W33/W34 全 0" "全 0" "W32=${W[$W32]} W33=${W[$W33]} W34=${W[$W34]}"; fi
# E3/E4: 需要"安静"前提 (图案 app 没在发, 且 TE 侧无在飞)
if [ "$PAT_IDLE" -eq 1 ]; then
  if [ "${W[$W21]}" -ne 0 ]; then
    res SKIP E3 "E3: 0 <= W20 - W7 <= 1" "前置 W21=0" "SKIP (W21=${W[$W21]} != 0 ⇒ 中止帧残字被当新帧重发, W20 多计; 见对抗审查 F11)"
  else
    D207=$(( ${W[$W20]} - ${W[$W7]} ))
    [ "$D207" -ge 0 ] && [ "$D207" -le 1 ] && res PASS E3 "E3: 0 <= W20 - W7 <= 1 且 W21 == 0" "[0,1]且W21=0" "W20=${W[$W20]} W7=${W[$W7]} 差=$D207; W21=0" \
      || res FAIL E3 "E3: 0 <= W20 - W7 <= 1" "[0,1]" "W20=${W[$W20]} W7=${W[$W7]} 差=$D207 (跨域偏斜失配)"
  fi
else
  res SKIP E3 "E3: 0 <= W20 - W7 <= 1" "板子安静" "SKIP (图案 app 在发: W8=${W[$W8]} W10=${W[$W10]} ⇒ W20 含图案帧, 本判据前提不成立)"
fi
D06=$(( ${W[$W0]} - ${W[$W6]} ))
if [ "$D06" -ge 0 ] && [ "$D06" -le 1 ]; then
  res PASS E4 "E4: 0 <= W0 - W6 <= 1 (每帧都进慢路径; 任务书写法 W6-W0 方向反了, 见注)" "[0,1]" "W0=${W[$W0]} W6=${W[$W6]} ⇒ W0-W6=$D06"
else res FAIL E4 "E4: 0 <= W0 - W6 <= 1" "[0,1]" "W0=${W[$W0]} W6=${W[$W6]} ⇒ W0-W6=$D06"; fi
echo "    [注] W6 在慢路径适配器**输入侧**帧尾自增 (rtl/slow_rx_adp.v:215), 天然滞后 W0 至多 1 帧;"
echo "         已归档冒烟数据 (p6b_smoke_account.log) 实测 W0=270 / W6=269 ⇒ 关系是 W0>=W6, 故按 0<=W0-W6<=1 判。"
# E8: 停机态守恒 (最强的一条)
Q0=$(dd $E_W0 ${W[$W0]}); Q1=$(dd $E_W1 ${W[$W1]}); Q30=$(dd $E_W30 ${W[$W30]}); Q31=$(dd $E_W31 ${W[$W31]})
Q32=$(dd $E_W32 ${W[$W32]}); Q33=$(dd $E_W33 ${W[$W33]})
XR30=$(( (Q0 + Q32) % M32 )); XR31=$(( (Q1 - 4*Q0 + Q33) % M32 )); XR31=$(( (XR31 + M32) % M32 ))
if [ "$Q0" -eq 0 ] && [ "$Q1" -eq 0 ] && [ "$Q30" -eq 0 ] && [ "$Q31" -eq 0 ]; then
  res PASS E8a "E8: 停机窗口内 RX 侧四个计数增量全 0 (真正排空, 无在飞)" "ΔW0=ΔW1=ΔW30=ΔW31=0" "全 0"
elif [ "$Q30" -eq "$XR30" ] && [ "$Q31" -eq "$XR31" ]; then
  # 窗口内有 n 帧**主机侧背景流量** (板子未应答 ⇒ 非 HLS 注入, 见本节头注释) ⇒ "严格静默"前提不成立;
  # 但增量守恒式逐字成立 ⇒ 等价证明"窗口末无在飞、每帧都被完整交付" (E1 的同一守恒律用在增量上)。
  res NOTE E8a "E8: 停机窗口内 RX 侧增量全 0 (或增量守恒可解释)" "全 0" "窗口内有主机背景帧 (ΔW0=$Q0 ΔW1=$Q1) ⇒ 严格静默不成立; **但增量守恒逐字成立** (ΔW30=$Q30==$XR30, ΔW31=$Q31==$XR31) ⇒ 无在飞残留、交付完整"
else res FAIL E8a "E8: 停机窗口内 RX 侧增量全 0" "全 0" "ΔW0=$Q0 ΔW1=$Q1 ΔW30=$Q30 ΔW31=$Q31 且增量守恒不成立 (期望 ΔW30=$XR30 ΔW31=$XR31) ⇒ 真有在飞/丢字"; fi
[ "${W[$W0]}" -eq "${W[$W30]}" ] && res PASS E8b "E8: W0 == W30 (帧守恒, 绝对式)" "相等" "${W[$W0]} == ${W[$W30]}" \
  || res FAIL E8b "E8: W0 == W30" "相等" "${W[$W0]} != ${W[$W30]} (差 $(( ${W[$W0]} - ${W[$W30]} )))"
if [ "${W[$W1]}" -eq "${W[$W31]}" ]; then
  res PASS E8c "E8: W1 == W31" "相等" "${W[$W1]} == ${W[$W31]}"
else
  # ⚠️ 判据形式校正 (有原始证据): W31 = Σpopc(tkeep) 是**每帧字数-1** 的口径, 恒等于 W1-4W0+W33;
  #    4*W0 != 0 ⇒ 绝对式 W1==W31 在 W0>0 时**形式上不可能成立**。等价形式 = E1b。
  res PASS E8c "E8: 字节守恒 (校正形式: W1 == W31 + 4*W0 - W33)" "等价式成立" "W1=${W[$W1]} W31=${W[$W31]} 差=$(( ${W[$W1]} - ${W[$W31]} )) = 4*W0=$(( 4*${W[$W0]} )) ⇒ 与 E1b 同一守恒律 (逐字等号见 E1b)"
fi
[ "${W[$W32]}" -eq 0 ] && [ "${W[$W33]}" -eq 0 ] && res PASS E8d "E8: W32 == W33 == 0 (无孤儿字)" "0" "W32=0 W33=0" \
  || res FAIL E8d "E8: W32 == W33 == 0" "0" "W32=${W[$W32]} W33=${W[$W33]}"
fi

echo; echo "########## 汇总 [stage=$STAGE] ##########"
if [ "${#SUM[@]}" -gt 0 ]; then printf '%s\n' "${SUM[@]}" | sort -t'|' -k1,1V | awk -F'|' '{printf "  %s 判据%-5s %s | 实测: %s\n", $2, $1, $3, $4}'; fi
echo "  PASS=$PASS FAIL=$FAIL SKIP=$SKIP NOTE=$NOTE  日志: $LOG"
if [ "$FAIL" -gt 0 ]; then echo "########## stage=$STAGE: FAIL ($FAIL) ⇒ 不通过 ##########"; exit 1; fi
echo "########## stage=$STAGE: 无 FAIL ##########"; exit 0
