#!/bin/bash
#=============================================================================
# p6b_smoke_gate.sh — P6b **冒烟测试的门 (stage A)**: 只看两件事, 不过就**立刻停**
#   新增文件 (冒烟测试 agent 写), 不改任何既有脚本。判据与守卫逐字照抄 p6e_slowpath_probe.sh /
#   p6b_accept.sh 的实证版 (rd() 读失败返回非零 / snap() 的 gen 恰好 +1 自证), **不简化**。
#
#   本次测量针对**非最终位流** (不含 F4 第二轮修复) —— 结论不可当 P6b 验收。
#
#   ---- 判据 (逐条 判据/期望/实测/判定) ----
#     A1 前置闸: MAGIC=0x50360001 且 BUILD_ID=6 且 MARKER=0xdeadbeef
#     A2 未实现地址语义: 0xB0 读回 0xffffffff ⇒ 确认"未实现 = SKIP 而非 PASS"这条例律成立
#     A3 ⭐ MMCM locked: 0x84 的 bit0 == 1        (锁定**看快照字**, 所以要先 snap)
#     A4 ⭐ 数据面频率: 0x80 自由计数两次 (各由独立快照冻结), 真实墙钟间隔 [10,20)s ⇒ 156.25MHz ±1%
#
#   退出码: 0=门通过  2=通道/身份不过(停)  4=locked=0(停)  5=频率不对(停)  6=自证失败(停)
#           **7=身份闸红但按归因纪律继续读完了 (上面有 FAIL ⇒ 不许当通过)**  ← 2026-10-07 加
#   ⚠️ 本门是 **P6b 时代**的门 (BID 必须 = 6 / 36 字)。在现役位流 (BID 9 / 63 字) 上跑:
#      A1b 会红 (身份不符)、A2 会 SKIP (0xB0 现在是已实现字) —— 这是**预期**, 不是板子坏。
#      2026-10-07 之前它在这种情形下**仍打 PASS + rc=0** (哑门, 已修; 现在 rc=7)。
#   用法: sudo bash /home/a/xdma_test/p6b_smoke_gate.sh
#=============================================================================
set -u
IFACE=${1:-enp3s0}
BOARD=192.168.100.2
MYCIDR=192.168.100.1/24
KO=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/xdma/xdma.ko
TOOLS=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
DEV=/dev/xdma0_user
LOG=/tmp/p6b_smoke_gate.log
W32=$((1<<32))
A_DP_FREE=0x80      # W24 数据面 (156.25MHz) 域自由计数
A_MMCM=0x84         # W25 MMCM 状态字, [0]=locked
A_UNIMPL=0xb0       # 未实现地址 (36 字占满 0x20..0xAC)
exec > >(tee "$LOG") 2>&1

PASS=0; FAIL=0; SKIP=0
res(){ case "$1" in PASS) PASS=$((PASS+1));; FAIL) FAIL=$((FAIL+1));; SKIP) SKIP=$((SKIP+1));; esac
       printf "  [%-4s] %-3s 判据=%s | 期望=%s | 实测=%s\n" "$1" "$2" "$3" "$4" "$5"; }

# rd(): 读失败返回非零 (reg_rw 输出 "at address 0xNN : 0xVV" ⇒ 必须 tail -1 + 剥前缀 + 校验 0x)
rd(){ local v; v=$($TOOLS/reg_rw $DEV "$1" w 2>/dev/null | tail -1 | sed 's/.*: *//')
      [[ "$v" =~ ^0[xX][0-9a-fA-F]{1,8}$ ]] || return 1; echo "$v"; }
wr(){ $TOOLS/reg_rw $DEV "$1" w "$2" >/dev/null 2>&1; }
# rd_new(): 0xffffffff 一律当"未实现" (返回 2), 与读失败 (返回 1) 分开
rd_new(){ local v; v=$(rd "$1") || return 1; [ "$v" = "0xffffffff" ] && return 2; echo "$v"; }
now(){ if [ -n "${EPOCHREALTIME:-}" ]; then echo "$EPOCHREALTIME"; else date +%s.%N; fi; }
el(){ awk -v a="$1" -v b="$2" 'BEGIN{printf "%.6f", b-a}'; }
# snap(): 写 0x18=1 触发, 轮询 done; **gen 必须恰好 +1** 自证 (done 是 sticky 的, 没有这条守卫
#   并发读者会互相污染 —— 本工程 2026-09-29 实测踩过, 那次读数全部作废)
snap(){ local g0 g1 s i
        g0=$(rd 0x1c) || return 1; g0=$(( (g0 >> 16) & 0xffff ))
        wr 0x18 0x1
        for i in $(seq 1 100); do s=$(rd 0x1c) || continue
            [ $(( s & 2 )) -ne 0 ] && break; sleep 0.01; done
        g1=$(rd 0x1c) || return 1; g1=$(( (g1 >> 16) & 0xffff ))
        [ $(( (g1 - g0) & 0xffff )) -eq 1 ]; }

echo "########## P6b 冒烟门 (stage A) $(date '+%F %T')  —— 针对**非最终位流** ##########"
ip -br addr show "$IFACE" 2>/dev/null | grep -q "192.168.100.1" || {
    ip link set "$IFACE" up 2>/dev/null; ip addr add "$MYCIDR" dev "$IFACE" 2>/dev/null; }
ip link set "$IFACE" up 2>/dev/null
for i in $(seq 1 60); do lspci -n 2>/dev/null | grep -q '10ee:9034' && break; sleep 2; done
lsmod | grep -qw xdma || { insmod "$KO" 2>/dev/null || true; sleep 2; }
if [ ! -e "$DEV" ]; then
  echo "[FATAL] 没有 $DEV ⇒ 观测通道不可用 (先跑 p6e_precheck.sh 判别该不该重启)"; exit 2
fi

echo; echo "===== A1 前置闸 (identity) ====="
M0=$(rd 0x00); B0=$(rd 0x04); K0=$(rd 0x14)
if [ -z "$M0" ] || [ -z "$B0" ] || [ -z "$K0" ]; then
  echo "  [FATAL] MAGIC/BUILD_ID/MARKER 读不出来 ⇒ 通道没应答"; exit 2; fi
echo "  [RAW] 0x00 MACRO/裸值 = $M0 | 0x04 = $B0 | 0x14 = $K0"
if [ "$M0" = "0xffffffff" ]; then
  echo "  [FATAL] user BAR 全 0xffffffff (SLVERR) ⇒ 通道没应答 (最可能: 烧录后主机还没重启)"; exit 2; fi
if [ "$(( M0 ))" -eq "$(( 0x50360001 ))" ]; then res PASS A1a "MAGIC" "0x50360001" "$M0"
else res FAIL A1a "MAGIC" "0x50360001" "$M0"; echo "  [FATAL] MAGIC 不对 ⇒ 拒绝继续"; exit 2; fi
if [ "$(( B0 ))" -eq 6 ]; then res PASS A1b "BUILD_ID (P6b+F4 双域 36 字版)" "6" "$B0"
else res FAIL A1b "BUILD_ID" "6" "$B0"
     echo "  [FATAL] BUILD_ID 不是 6 ⇒ 板上不是这一版位流 ⇒ 拒绝继续 (但**仍然继续读**下面两项, 供归因)"; ID_BAD=1; fi
if [ "$K0" = "0xdeadbeef" ]; then res PASS A1c "MARKER/地址译码" "0xdeadbeef" "$K0"
else res FAIL A1c "MARKER/地址译码" "0xdeadbeef" "$K0"; fi

echo; echo "===== A2 未实现地址语义 (0xB0) ====="
U0=$(rd_new $A_UNIMPL); RC_U=$?
if [ "$RC_U" -eq 2 ]; then res PASS A2 "0xB0 (未实现) 读回 0xffffffff" "0xffffffff" "0xffffffff ⇒ 未实现字按 SKIP 处理这条例律**在本轮成立**"
elif [ "$RC_U" -eq 0 ]; then res SKIP A2 "0xB0 (未实现) 读回 0xffffffff" "0xffffffff" "$U0 (不是 ffffffff: 要么该地址已实现, 要么读法有别)"
else res SKIP A2 "0xB0 读回 0xffffffff" "0xffffffff" "读失败"; fi

echo; echo "===== A3 ⭐ MMCM locked (0x84 bit0; 快照字 ⇒ 先 snap) ====="
LOCKV=""; RC_LK=1
if snap; then
  LOCKV=$(rd_new $A_MMCM); RC_LK=$?
  echo "  [RAW] 0x84 = ${LOCKV:-读失败/未实现}  (gen 自证: snap 成功)"
else
  echo "  [FAIL] snap 的 gen 自证不成立 (可能有第二个读者) ⇒ 本项不可信"
  res FAIL A3 "snap/gen 自证" "gen 恰好 +1" "自证失败"
fi
if [ "$RC_LK" -eq 0 ]; then
  LOCKB=$(( LOCKV & 1 ))
  if [ "$LOCKB" -eq 1 ]; then res PASS A3 "MMCM locked 位 (0x84 bit0)" "1" "$LOCKV & 1 = 1 ⇒ **MMCM 锁了**"
  else
    res FAIL A3 "MMCM locked 位 (0x84 bit0)" "1" "$LOCKV & 1 = 0 ⇒ **MMCM 没锁**"
    echo "  [RAW] 0x84 全字 = $LOCKV"
    echo "！[STOP] locked=0 ⇒ 按冒烟测试纪律**立刻停止**: 不做频率/ping/图案 (硬跑会污染判读)"
    echo "########## 冒烟门: HALTTED (MMCM 没锁)  PASS=$PASS FAIL=$FAIL SKIP=$SKIP  日志: $LOG ##########"
    exit 4
  fi
elif [ "$RC_LK" -eq 2 ]; then
  res SKIP A3 "MMCM locked 位 (0x84 bit0)" "1" "0x84 读回 0xffffffff ⇒ **未实现**"
  echo "！[STOP] 0x84 未实现 ⇒ 无法做电气裁决 (本次位流的字表与期望不符), 停止"
  echo "########## 冒烟门: HALTTED (0x84 未实现)  PASS=$PASS FAIL=$FAIL SKIP=$SKIP ##########"
  exit 4
else
  res FAIL A3 "MMCM locked 位" "1" "读失败 (空读 != 真 0)"; echo "！[STOP]"; exit 4
fi

echo; echo "===== A4 ⭐ 数据面频率 (0x80; 两次独立快照 + 真实墙钟) ====="
DP_A=""; DP_B=""; RC_A=1; RC_B=1; DT=""; T0=""; T1=""
if snap; then
  DP_A=$(rd_new $A_DP_FREE); RC_A=$?; T0=$(now)
  echo "  [RAW] 起点: 0x80 = ${DP_A:-读失败/未实现}  t0=$T0"
else echo "  [FAIL] 起点 snap 自证失败"; fi
# 窗口补到 [12,20)s (下限 10 是判据; 上限 20 给 32 位 @156.25MHz 的 27.5s 回绕留余量)
for i in $(seq 1 40); do
  DTS=$(el "$T0" "$(now)"); awk -v d="$DTS" 'BEGIN{exit !(d>=12.0)}' && break; sleep 0.5
done
if snap; then
  DP_B=$(rd_new $A_DP_FREE); RC_B=$?; T1=$(now)
  echo "  [RAW] 终点: 0x80 = ${DP_B:-读失败/未实现}  t1=$T1"
else echo "  [FAIL] 终点 snap 自证失败"; fi
DT=$(el "$T0" "$T1")
echo "  [RAW] 真实窗口长度 (墙钟, 非 sleep 名义值) = ${DT}s"

if [ "$RC_A" -eq 0 ] && [ "$RC_B" -eq 0 ]; then
  DA=$(( DP_A )); DB=$(( DP_B ))
  if [ "$DB" -lt "$DA" ]; then DCNT=$(( (W32 - DA) + DB )); WRAP=" (补偿 1 次回绕)"
  else DCNT=$(( DB - DA )); WRAP=""; fi
  MHZ=$(awk -v d="$DCNT" -v t="$DT" 'BEGIN{printf "%.4f", d/t/1e6}')
  if awk -v t="$DT" 'BEGIN{exit !(t>=10.0 && t<20.0)}'; then
    res PASS A4a "窗口长度 ∈ [10,20)s" "[10,20)" "${DT}s${WRAP}"
  else res FAIL A4a "窗口长度 ∈ [10,20)s" "[10,20)" "${DT}s ⇒ 频率读数不可用"; fi
  if awk -v m="$MHZ" 'BEGIN{exit !(m>=154.69 && m<=157.81)}'; then
    res PASS A4b "数据面域频率 = 156.25MHz ±1%" "[154.69,157.81] MHz" "${MHZ} MHz  (Δ=$DCNT / ${DT}s)"
  else
    res FAIL A4b "数据面域频率 = 156.25MHz ±1%" "[154.69,157.81] MHz" "${MHZ} MHz  (Δ=$DCNT / ${DT}s)"
  fi
  MODE=$(awk -v m="$MHZ" 'BEGIN{d125=(m>125)?m-125:125-m; d156=(m>156.25)?m-156.25:156.25-m; print (d125<d156)?"125":"156.25"}')
  if [ "$MODE" = "125" ]; then
    echo "  [判决] ${MHZ} MHz 更接近 **125MHz** ⇒ **数据面根本没搬到 156.25MHz 新域**"
    echo "！[STOP] 频率不对 ⇒ 不做 ping/图案"
    echo "########## 冒烟门: HALTED (频率=125MHz 域, 没搬)  PASS=$PASS FAIL=$FAIL SKIP=$SKIP ##########"
    exit 5
  fi
  echo "  [判决] ${MHZ} MHz 更接近 **156.25MHz** ⇒ 数据面确实跑在新域上 ✓"
  # 顺带: 前端对照 (若同一快照里有 D5=gmii_free 在 0x34) —— 只报数, 不作判据
  RD5=$(rd 0x34) || RD5=""
  echo "  [INFO] 对照 D5(0x34, 前端 gmii_free) 当前值 = ${RD5:-读失败} (只报数)"
  echo "  [RAW] A4 结论: 频率 = ${MHZ} MHz (Δ=$DCNT / ${DT}s)"
  # ⚠️ 2026-10-07 "台架修复轮" 修既存哑门: 旧版这一行**无条件**打 "冒烟门: PASS" 并 `exit 0`,
  #    即便上面已经打了 [FAIL] A1b/BUILD_ID(非本版位流) 或 A4a(窗口长度出界) ——
  #    实测 (2026-10-07 在现板上跑): 打 `[FAIL] A1b BUILD_ID` + `[FATAL] 拒绝继续`, 末行却是
  #    `冒烟门: PASS (可以继续 ping/图案)`, rc=0; 而 `ID_BAD=1` 设了却**从未被读** ⇒
  #    "日志里有 FAIL 但退出码 0" = 判据安静失效 (本工程最恨的一类)。
  #    ⇒ 现在是**真失败**: 只要 FAIL>0 或身份闸红过, 末行改打 FAIL 且 **退出码 7**。
  if [ "${ID_BAD:-0}" -eq 0 ] && [ "$FAIL" -eq 0 ]; then
    echo "########## 冒烟门: PASS (可以继续 ping/图案)  PASS=$PASS FAIL=$FAIL SKIP=$SKIP  日志: $LOG ##########"
    exit 0
  else
    echo "########## 冒烟门: FAIL (上面有红 ⇒ **不许**当'可以继续 ping/图案')  PASS=$PASS FAIL=$FAIL SKIP=$SKIP  日志: $LOG ##########"
    [ "${ID_BAD:-0}" -eq 0 ] || echo "！根因: BUILD_ID != 6 ⇒ 板上不是 P6b 那一版位流 (身份闸 A1b 红); 退出码 7"
    exit 7
  fi
else
  res FAIL A4 "数据面频率 (0x80)" "156.25MHz ±1%" "读失败或未实现 (A=$RC_A B=$RC_B; 空读 != 真 0)"
  echo "！[STOP]"
  echo "########## 冒烟门: HALTED (0x80 不可读)  PASS=$PASS FAIL=$FAIL SKIP=$SKIP ##########"
  exit 6
fi
