#!/bin/bash
#=============================================================================
# p7b_gate4_negctrl.sh — **P7b 闸 4 判据的负对照** (12 条变异 + 1 条正对照, 全部真跑)
#
# 思路 (本工程血泪: "判据要**有判别力**", 已三次吃亏):
#   闸 4 的验收链被切成两半 —— **I/O 层**(碰板子/网卡) 与 **解析+判据层**(纯函数)。
#   本脚本**不碰板子、不碰对端机**: 它把**合成的假读数**写成规范文本, 直接灌进解析函数,
#   然后断言"该被抓住的必须被抓住"(退出码非 0 且日志里出现指定的判据号)。
#
#   ⚠️ 负对照里必须有一条**正对照**: clean 那一条要求**全 PASS / 退出 0**。
#      没有它, 一个"什么都报 FAIL"的坏脚本也能让 12 条负对照全过 ⇒ 负对照本身成了真空门。
#
# 用法 (本机 Git Bash, 任选 cwd —— 脚本自定位):
#   bash _proj_pcie/p7b_gate4_negctrl.sh
# 产物: _proj_10g/notes/p7b_gate4_tools/negctrl/{<case>.log, SUMMARY.txt, 输入文本}
# 退出码: 0 = 全部按期望 (含 clean 全 PASS) / 1 = 有 case 不符期望
#=============================================================================
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ACCEPT=$ROOT/_proj_pcie/p7b_gate4_accept.sh
BASE=$ROOT/_proj_10g/notes/p7b_gate4_tools
OUT=$BASE/negctrl
mkdir -p "$OUT"

GOOD_BASE=5000000            # 测量窗起点 (帧)
DGOOD=4060000               # Δgood (帧) —— 10G 线速 1518B 帧 ≈ 812k 帧/s × 5 s
DBYTES=$((DGOOD*1518))      # Δbytes
BGOOD=1375                  # 基线 (背景) 起点

# ---- 造一块**规范**快照文本 ---------------------------------------------------
# 几何: **67 字 (W0..W66)** —— 构建 E (2026-10-10, BID=0x19 / 未实现 0x12C);
#       (原句: "66 字 (W0..W65) —— P7B-A7 构建 D (2026-10-10, BID=0x18 / 未实现 0x128)" = 历史代, 逐字保留于下)
#       (原句: ‘63 字 (W0..W62)’ = 历史代, 逐字保留于下)
#       ⛔ 2026-10-07 Stage C BID 同步轮: 几何 / 未实现地址不变, **身份 9 → 10**
#          (上面这句原句保留: 描述的是 P7B-WU 二轮那一代; 本夹具现 = 63 字 / BID 10)。
#       守恒律 W30==W0+W32 / W31==W1-4·W0+W33 逐字成立;
#       W39 = PCS 状态束 (gpw/block_lock/rx_status=1); W40 = {evt×3, vcc_cyc} vcc 在涨。
#       ⚠️ W51..W66 = P7B-BIZ/WU/构建C/构建D/构建E 新增字, 本夹具全填 0 (accept 只要求"窗口齐全且无 0xffffffff");
#          若将来判据开始消费某个新字, **这里要跟着造它的真形态** (否则负对照会"打空")。
gen_snap(){  # gen_snap <文件> <第一块|第二块|洪泛A|洪泛B>
  local f="$1" kind="$2"
  local w5=1000000 w24=2000000 w50=3000000 vcc=66 tl="1000.000 1000.010" gen="5 6" w20=998
  case "$kind" in
    # ⚠️ 字值的口径必须与**真板**一致 (fix2 ④ 之后): P7B_10G 构建里 W5 的前端域 = PCS 恢复钟
    #    ⇒ 3 个域的 Δ 都按 156.25 MHz × 5 s = 781,250,000 造 (旧夹具把 W5 造成 125 口径,
    #    那是 P6b 的假设 ⇒ 修好 nominal 之后 clean 正对照反而会 FAIL —— 夹具跟着改).
    第二块)  w5=$((1000000+781250000)); w24=$((2000000+781250000)); w50=$((3000000+781250000)); vcc=153; tl="1005.000 1005.010"; gen="6 7";;
    洪泛A)   tl="1010.000 1010.010"; gen="7 8";;
    洪泛B)   w5=$((1000000+1562500000)); w24=$((2000000+1562500000)); w50=$((3000000+1562500000)); vcc=210
             tl="1015.000 1015.010"; gen="8 9"; w20=$((998+DGOOD));;
  esac
  # ⚠️ 字的取值必须是 **0x 十六进制** —— 这就是 live 路径的规范形态 (`reg_rw` 打出来就是 0x..);
  #    假读数必须与真读数**同形**, 否则抓到的只是"格式不符", 判据本身没被验到。
  { echo SNAP_BEGIN
    echo "TLATCH $tl"
    echo "GEN $gen"
    echo "MAGIC 0x50360001"; echo "BID 0x00000019"; echo "MARKER 0xdeadbeef"   # 构建 D: 原 0x0000000A = Stage C   # Stage C: 原 0x00000009
    local -a V=(1000 1518000 1518 0 0 $w5 998 998 0 0 0 0 0 0 0 0 0 0 0 0
                $w20 0 0 0 $w24 1 0 0 0 0 1000 1514000 0 0 0 0
                20000000 151800000 0 0x2000100C $vcc 0 0 0 0 0 0 0 0 0 $w50
                0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)   # W51..W66 (构建 E: W66 = tcp_tx_frame.stat_winstall)
    local i; for (( i = 0; i < 67; i++ )); do printf 'W%d 0x%X\n' "$i" "${V[$i]}"; done
    echo "UNIMPL 0xffffffff"
    echo SNAP_END
  } > "$f"
}
# ---- 造一块**规范** NIC 文本 ---------------------------------------------------
gen_nic(){  # gen_nic <文件> <基线A|基线B|测量A|测量B>
  local f="$1" kind="$2"
  local good=$BGOOD bad=1020633510 pkt=1020634885 byt=253117205778 uni=0 m64=1182 b1518=0 crc=1020523634 tl="1000.000 1000.010"
  case "$kind" in
    基线B) good=$((BGOOD+3)); pkt=$((1020634885+3)); byt=$((253117205778+198)); m64=1184; tl="1005.000 1005.010";;
    测量A) good=$GOOD_BASE; bad=0; pkt=$GOOD_BASE; byt=$((GOOD_BASE*1518)); uni=$GOOD_BASE; m64=0; b1518=$GOOD_BASE; crc=0; tl="1010.000 1010.010";;
    测量B) good=$((GOOD_BASE+DGOOD)); bad=0; pkt=$((GOOD_BASE+DGOOD)); byt=$(((GOOD_BASE+DGOOD)*1518)); uni=$((GOOD_BASE+DGOOD)); m64=0; b1518=$((GOOD_BASE+DGOOD)); crc=0; tl="1015.000 1015.010";;
  esac
  { echo NIC_BEGIN; echo "TLATCH $tl"
    echo "rx_eth_crc_err $crc"; echo "port_rx_packets $pkt"; echo "port_rx_good $good"
    echo "port_rx_bad $bad";    echo "port_rx_bytes $byt";   echo "port_rx_unicast $uni"
    echo "port_rx_multicast 0"; echo "port_rx_broadcast $good"
    echo "port_rx_64 $m64";     echo "port_rx_65_to_127 170"
    echo "port_rx_128_to_255 0"; echo "port_rx_256_to_511 0"; echo "port_rx_512_to_1023 0"
    echo "port_rx_1024_to_15xx $b1518"; echo "port_rx_15xx_to_jumbo 0"
    echo "port_rx_overflow 0";  echo "port_rx_nodesc_drops 0"; echo "port_tx_packets 7585"
    echo NIC_END
  } > "$f"
}
setkey(){ sed -i "s/^$2 .*/$2 $3/" "$1"; }     # setkey <文件> <键> <值>
delkey(){ sed -i "/^$2 /d" "$1"; }

# ---- 跑一条 case --------------------------------------------------------------
N_OK=0; N_BAD=0
run_case(){  # run_case <名> <期望退出码> <期望在日志里出现的串> <snap列表> <nic列表> [额外 env]
  local name="$1" want_rc="$2" want_pat="$3" snap="$4" nic="$5" extra="${6:-}"
  local log="$OUT/$name.log"
  env G4_SNAP_TEXT="$snap" G4_NIC_TEXT="$nic" G4_OUTDIR="$OUT" ${extra} \
      bash "$ACCEPT" > "$log" 2>&1
  local rc=$?
  local hit=OK; grep -qF -- "$want_pat" "$log" || hit="MISS(日志里没有 '$want_pat')"
  local rcv="OK"; [ "$rc" = "$want_rc" ] || rcv="BAD(退出码 $rc, 期望 $want_rc)"
  if [ "$hit" = OK ] && [ "$rcv" = OK ]; then
    N_OK=$((N_OK+1)); printf "  [OK  ] %-16s 退出码=%s 命中=%s\n" "$name" "$rc" "$want_pat"
  else
    N_BAD=$((N_BAD+1)); printf "  [BAD ] %-16s %s / %s\n" "$name" "$rcv" "$hit"
  fi
}

# ---- 造干净的一对 / 洪泛一对 / NIC 两对 ---------------------------------------
S=$OUT;  gen_snap "$S/s1.txt" 第一块;  gen_snap "$S/s2.txt" 第二块
gen_snap "$S/s3.txt" 洪泛A;             gen_snap "$S/s4.txt" 洪泛B
gen_nic  "$S/n1.txt" 基线A;             gen_nic  "$S/n2.txt" 基线B
gen_nic  "$S/n3.txt" 测量A;             gen_nic  "$S/n4.txt" 测量B
SNAP="$S/s1.txt,$S/s2.txt,$S/s3.txt,$S/s4.txt"
NIC="$S/n1.txt,$S/n2.txt,$S/n3.txt,$S/n4.txt"

echo "########## P7b 闸 4 负对照 $(date '+%F %T') ##########"
echo "—— 正对照 (clean) 必须**全 PASS / 退出 0** (否则本脚本自己就是真空门) ——"
run_case clean 0 "FAIL=0" "$SNAP" "$NIC"

echo "—— 板侧负对照 (快照文本变异) ——"
cp "$S/s2.txt" "$S/m_genstuck.txt"; sed -i 's/^GEN .*/GEN 6 6/' "$S/m_genstuck.txt"
run_case genstuck 2 "gen 不是恰好 +1" "$S/s1.txt,$S/m_genstuck.txt" "$NIC"

cp "$S/s2.txt" "$S/m_empty.txt";  sed -i 's/^W17 .*/W17 /' "$S/m_empty.txt"
run_case emptyread 2 "空读" "$S/s1.txt,$S/m_empty.txt" "$NIC"

cp "$S/s2.txt" "$S/m_missing.txt"; delkey "$S/m_missing.txt" W50
run_case missinglast 2 "窗口不完整: 缺 W50" "$S/s1.txt,$S/m_missing.txt" "$NIC"

cp "$S/s2.txt" "$S/m_duptail.txt"; sed -n 's/^\(W4[89]\|W50\) \(.*\)/\1 \2/p' "$S/s2.txt" >> "$S/m_duptail.txt"
run_case duptail 2 "下标重复" "$S/s1.txt,$S/m_duptail.txt" "$NIC"

cp "$S/s2.txt" "$S/m_36word.txt"; grep -vE '^W(3[6-9]|4[0-9]|50) ' "$S/m_36word.txt" > "$S/m_36word2.txt"; mv "$S/m_36word2.txt" "$S/m_36word.txt"
run_case oldwindow 2 "窗口不完整: 缺 W36" "$S/s1.txt,$S/m_36word.txt" "$NIC"

# 地址错一位: 每个 W<i> 里装的是 word i+1 的值 (末字回绕成 W0) —— 守恒律必然破
awk '/^W[0-9]+ /{ split($1,a,"W"); idx=a[2]; val[idx]=$2; n++; next } { print }' "$S/s1.txt" > "$S/m_off_a.txt"
awk '/^W[0-9]+ /{ split($1,a,"W"); idx=a[2]; val[idx]=$2; n++; next } { print }' "$S/s2.txt" > "$S/m_off_b.txt"
shift1(){ awk -v NW=67 '/^W[0-9]+ /{ split($1,a,"W"); idx=a[2]+1; if(idx>NW-1) idx=0; printf "W%d %s\n", idx, $2; next } { print }' "$1" > "$2"; }
shift1 "$S/s1.txt" "$S/m_off_a.txt"; shift1 "$S/s2.txt" "$S/m_off_b.txt"
run_case offbyone 1 "B_CONS-a" "$S/m_off_a.txt,$S/m_off_b.txt" "$NIC"

cp "$S/s1.txt" "$S/m_allF_a.txt"; cp "$S/s2.txt" "$S/m_allF_b.txt"
setkey "$S/m_allF_a.txt" W40 0xFFFFFFFF; setkey "$S/m_allF_b.txt" W40 0xFFFFFFFF
run_case allF 1 "B_WIN" "$S/m_allF_a.txt,$S/m_allF_b.txt" "$NIC"

cp "$S/s1.txt" "$S/m_wide_a.txt"; cp "$S/s2.txt" "$S/m_wide_b.txt"
setkey "$S/m_wide_a.txt" UNIMPL 0x12345678; setkey "$S/m_wide_b.txt" UNIMPL 0x12345678
run_case wideldecode 1 "B_UNIMPL" "$S/m_wide_a.txt,$S/m_wide_b.txt" "$NIC"

# W50 (TX 域 toggle 计数) 卡死: 第二块与第一块同值 ⇒ 两种口径都读 0 ⇒ 必须 FAIL
# ⚠️ 这里**不能**用"半速率"当负对照: 那与"÷1/÷2 口径未定"不可分 (会假 PASS)
cp "$S/s2.txt" "$S/m_w50.txt"; v=$(sed -n 's/^W50 //p' "$S/s1.txt"); setkey "$S/m_w50.txt" W50 "$v"
run_case w50stuck 1 "G2-W50" "$S/s1.txt,$S/m_w50.txt" "$NIC"

echo "—— NIC 侧负对照 (网关判据四件套) ——"
cp "$S/n4.txt" "$S/m_bg4.txt"; setkey "$S/m_bg4.txt" port_rx_good $((GOOD_BASE+3)); \
  setkey "$S/m_bg4.txt" port_rx_packets $((GOOD_BASE+3)); setkey "$S/m_bg4.txt" port_rx_unicast $((GOOD_BASE+3)); \
  setkey "$S/m_bg4.txt" port_rx_1024_to_15xx $((GOOD_BASE+3)); setkey "$S/m_bg4.txt" port_rx_bytes $(((GOOD_BASE+3)*1518))
run_case nic_background 1 "N_RATE" "$SNAP" "$S/n1.txt,$S/n2.txt,$S/n3.txt,$S/m_bg4.txt"

cp "$S/n4.txt" "$S/m_bcast.txt"; setkey "$S/m_bcast.txt" port_rx_unicast 0; setkey "$S/m_bcast.txt" port_rx_1024_to_15xx 0; \
  setkey "$S/m_bcast.txt" port_rx_64 $((GOOD_BASE+DGOOD))
run_case nic_broadcast 1 "N_UCAST" "$SNAP" "$S/n1.txt,$S/n2.txt,$S/n3.txt,$S/m_bcast.txt"

cp "$S/n4.txt" "$S/m_crc.txt"; setkey "$S/m_crc.txt" rx_eth_crc_err 12
run_case nic_crc 1 "N_CRC" "$SNAP" "$S/n1.txt,$S/n2.txt,$S/n3.txt,$S/m_crc.txt"

cp "$S/n4.txt" "$S/m_avg.txt"; setkey "$S/m_avg.txt" port_rx_bytes $(((GOOD_BASE+DGOOD)*66))
run_case nic_avg 1 "N_AVG" "$SNAP" "$S/n1.txt,$S/n2.txt,$S/n3.txt,$S/m_avg.txt"

# 结构坏 (字段缺) ⇒ 必须**拒绝出结论** (退出 2), 而不是拿半份读数算下去
cp "$S/n4.txt" "$S/m_missing.txt"; delkey "$S/m_missing.txt" port_rx_unicast
run_case nic_missing 2 "NIC 文本缺字段 port_rx_unicast" "$SNAP" "$S/n1.txt,$S/n2.txt,$S/n3.txt,$S/m_missing.txt"

echo
echo "########## 负对照汇总: OK=$N_OK BAD=$N_BAD ##########"
{ echo "P7b 闸 4 负对照汇总 $(date '+%F %T')"
  echo "OK=$N_OK BAD=$N_BAD (clean 那条要求 FAIL=0/退出 0, 其余每条要求退出码与判据号都对上)"
  echo "明细见同目录 <case>.log; 输入文本见 s*.txt / n*.txt / m_*.txt"
} > "$OUT/SUMMARY.txt"
[ "$N_BAD" -eq 0 ] || exit 1
exit 0
