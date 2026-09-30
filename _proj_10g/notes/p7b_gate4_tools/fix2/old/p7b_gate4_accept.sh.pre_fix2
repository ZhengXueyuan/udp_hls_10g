#!/bin/bash
#=============================================================================
# p7b_gate4_accept.sh — **P7b 闸 4 板级验收** (板侧 51 字 + NIC 侧网关判据)
#
# 为什么新写一个 (而不是只改 p6e_snap_check.sh):
#   ① 闸 4 的几何是 **51 字** (0x20..0xE8, 未实现 = 0xEC), p6e_snap_check.sh 是 36 字口径
#      (它已就地修成"字数可覆盖"的版本, 可单独当窗口快检用);
#   ② 闸 4 的头条判据在 **NIC 侧** (真网卡 802.3 裁决) —— 那部分以前**没有脚本**, 只在文档里;
#   ③ 负对照必须能"把**合成的假读数**喂给解析函数" ⇒ 本脚本把 **I/O 层**与**解析/判据层**分开,
#      解析层是纯函数 (只吃规范文本), 所以假读数能直接灌进来 (见 p7b_gate4_negctrl.sh)。
#
# ---- 怎么跑 (本机 Git Bash, 工作目录 = 本仓根) -------------------------------
#   前置 (顺序不可换): **烧位流 → 重启对端机 → 才读得到板侧** (见 P7B_GATE4_PLAN.md 步骤 0/2/3)
#
#   # ① 全链 (板侧停机态 → NIC 基线 → 教学打流 → NIC 测量 → 板侧洪泛窗):
#   PEER_PW=111111 bash _proj_pcie/p7b_gate4_accept.sh
#
#   # ② 只跑停机态 + NIC 基线 (不教学/不打流):
#   PEER_PW=111111 G4_SKIP_TRAFFIC=1 bash _proj_pcie/p7b_gate4_accept.sh
#
#   # ③ 离线/负对照 (喂合成文本, 完全不碰板子与对端机): 逗号分隔 **2 或 4 个文件**
#   G4_SNAP_TEXT=a.txt,b.txt,c.txt,d.txt G4_NIC_TEXT=e.txt,f.txt,g.txt,h.txt \
#     bash _proj_pcie/p7b_gate4_accept.sh
#
#   开关: G4_BIT=<位流路径> · EXPECT_BID=0x... · SNAP_WORDS=51 · G4_IFACE=enp1s0f1np1
#         G4_TRAFFIC_CMD=<激励命令> · NIC_GOOD_MIN / NIC_MBPS_MIN (阈值)
#         G4_LIB_ONLY=1 (只加载函数; 负对照脚本 source 用)
#
# ---- 判据 (逐条打印 判定/判据号/判据/期望/实测; 判定 ∈ PASS|FAIL|SKIP) ----------
#   板侧 (G1/G2/G3/B/C/E4): B_GEN  B_WIN  B_UNIMPL  G2-W5/W24/W50  B_CONS-a/b  B_DIR
#                           C1-C5  C6-C7  C8  C6-ev  B_G6
#   NIC 侧 (闸 2 网关判据 —— **四件一起**, 旧的 `port_rx_good > 0` 已被板子自己的
#   HELLO/ARP 背景流量满足 ⇒ 无判别力, 见 P7B_GATE4_PLAN.md §0.1):
#                           N_CRC N_BAD **N_RATE(增量+速率阈值)** **N_UCAST** **N_LEN(长度桶)**
#                           N_AVG N_SELF **N_BASE(判别力自检)** N_XCHK(板侧×网卡对账)
#   负对照 = p7b_gate4_negctrl.sh (12 条变异, 全部真跑; 见 P7B_GATE4_TOOLING.md)
# ---- 退出码: 0=全 PASS / 1=有 FAIL / 2=前置闸拒绝 (身份/通道/结构) ------------
#=============================================================================
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PY=${PY:-/c/Users/zhxue/anaconda3/python.exe}
BIT=${G4_BIT:-$ROOT/vivado_prj/p7b_ku5p_prj.runs/impl_1/wrapper_p4.bit}
IFACE=${G4_IFACE:-enp1s0f1np1}
BOARD_IP=192.168.100.2
MYIP=192.168.100.100
DEV=/dev/xdma0_user
TOOLS=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
EXPECT_BID=${EXPECT_BID:-0x00000007}      # P7b = 7 (源码 board/wrapper_p4.v:3701 的 BUILD_ID_V)
SNAP_WORDS=${SNAP_WORDS:-51}
UNIMPL_ADDR=${UNIMPL_ADDR:-$(printf '0x%X' $(( 0x20 + 4*SNAP_WORDS )))}   # 51 ⇒ 0xEC
W32=$((1<<32))
NIC_GOOD_MIN=${NIC_GOOD_MIN:-100000}      # 增量阈值 (帧): 背景 0.1~0.5 帧/s, 差 6 个数量级
NIC_MBPS_MIN=${NIC_MBPS_MIN:-800}         # 速率阈值 (Mbps, 线上字节率)
TRAFFIC_SECS=${TRAFFIC_SECS:-15}
G4_SKIP_TRAFFIC=${G4_SKIP_TRAFFIC:-0}
G4_TRAFFIC_CMD=${G4_TRAFFIC_CMD:-/home/a/xdma_test/p6e_udp_pattern --secs $TRAFFIC_SECS --board $BOARD_IP --port 8081}
OUTDIR=${G4_OUTDIR:-$ROOT/_proj_10g/notes/p7b_gate4_tools}
MARKER_EXP=0xdeadbeef

PASS=0; FAIL=0; SKIP=0; FATAL=0
declare -a SUM
# 解析结果的容器 (必须**顶层**声明: 在函数里 `declare -A` 会变成局部变量, 属性装不上)
declare -a SW
declare -A SM NC
# NIC 块的四个容器 (必须**声明成关联数组**: 普通赋值会退化成下标数组, 之后 NC[<键>] 会被
# 当成算术下标 ⇒ 在 set -u 下报 "unbound variable", 看着像脚本坏了)
declare -A NB_NC NQ_NC

res(){ case "$1" in PASS) PASS=$((PASS+1));; FAIL) FAIL=$((FAIL+1));; SKIP) SKIP=$((SKIP+1));; esac
       SUM+=("$1|$2|$3|$5")
       printf "  [%-4s] %-10s %s | 期望=%s | 实测=%s\n" "$1" "$2" "$3" "$4" "$5"; }
fatal(){ echo "  [FATAL] $*"; FATAL=1; }
hr(){ echo; echo "===== $* ====="; }

dd32(){ local d=$(( ($2 - $1) % W32 )); [ "$d" -lt 0 ] && d=$(( d + W32 )); echo "$d"; }
# 结构坏 ⇒ **拒绝出结论**。⚠️ 不这么做的后果不是"少一条判据", 而是**静默用上一块的陈旧数组**:
#   解析失败时不调用 nic_copy/snap_copy ⇒ 全局数组还留着**上一对**的值 ⇒ 判据照常打印 PASS/FAIL,
#   而它与本块读数毫无关系 (= 本工程最贵的"判据与读数脱钩")。负对照 `nic_missing` 就是为它加的。
abort_if_fatal(){ [ "$FATAL" = 0 ] && return 0
  echo; echo "  [ABORT] $1: 结构/前置未过 ⇒ **本轮读数不可用** (退出 2): $PARSE_ERR"
  echo "########## PASS=$PASS FAIL=$FAIL SKIP=$SKIP ##########"; exit 2; }
bit(){ echo $(( ($1 >> $2) & 1 )); }
# 百分比/在容差内 (awk 做浮点; bash 只做整数)
in_pct(){ awk -v a="$1" -v b="$2" -v p="$3" 'BEGIN{ d=a-b; if(d<0)d=-d; exit !(b!=0 && d/b<=p/100) }'; }
hz2mhz(){ awk -v d="$1" -v t="$2" -v k="$3" 'BEGIN{ printf "%.4f", (t>0)? d/k/t/1e6 : 0 }'; }
mbps(){ awk -v b="$1" -v t="$2" 'BEGIN{ printf "%.2f", (t>0)? b*8/t/1e6 : 0 }'; }
dt2(){ awk -v a="$1" -v b="$2" -v c="$3" -v d="$4" 'BEGIN{ printf "%.6f", ((c+d)-(a+b))/2 }'; }
ge(){ awk -v a="$1" -v b="$2" 'BEGIN{ exit !(a>=b) }'; }
le(){ awk -v a="$1" -v b="$2" 'BEGIN{ exit !(a<=b) }'; }

# ---- I/O 层 (唯一碰外部世界的地方) -------------------------------------------
peer(){ PYTHONIOENCODING=utf-8 "$PY" "$ROOT/tools/peer_ssh.py" "$@"; }
need_pw(){ [ -n "${PEER_PW:-}" ] || { fatal "本脚本的 --sudo 调用需要 PEER_PW (环境变量, 不落盘)"; exit 2; }; }

read -r -d '' SNAP_REMOTE <<'EOS'
T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
D=/dev/xdma0_user
rd(){ $T/reg_rw $D "$1" w 2>/dev/null | tail -1 | sed 's/.*: *//'; }
g0=$(rd 0x1c); g0=$(( (g0 >> 16) & 0xffff ))
t0=$(date +%s.%N)
$T/reg_rw $D 0x18 w 0x1 >/dev/null 2>&1
for i in $(seq 1 100); do s=$(rd 0x1c); [ -n "$s" ] && [ $(( s & 2 )) -ne 0 ] && break; sleep 0.01; done
t1=$(date +%s.%N)
g1=$(rd 0x1c); g1=$(( (g1 >> 16) & 0xffff ))
printf 'SNAP_BEGIN\n'
printf 'TLATCH %s %s\n' "$t0" "$t1"
printf 'GEN %s %s\n' "$g0" "$g1"
printf 'MAGIC %s\n'  "$(rd 0x00)"
printf 'BID %s\n'    "$(rd 0x04)"
printf 'MARKER %s\n' "$(rd 0x14)"
for i in $(seq 0 50); do printf 'W%s %s\n' "$i" "$(rd $(printf '0x%X' $(( 0x20 + 4*i ))))"; done
printf 'UNIMPL %s\n' "$(rd 0xEC)"
printf 'SNAP_END\n'
EOS

read -r -d '' NIC_REMOTE <<'EOS'
t0=$(date +%s.%N)
OUT=$(ethtool -S enp1s0f1np1 | grep -E '^ +(port_rx_(packets|good|bad|bytes|unicast|multicast|broadcast|64|65_to_127|128_to_255|256_to_511|512_to_1023|1024_to_15xx|15xx_to_jumbo|overflow|nodesc_drops|pause|control)|rx_eth_crc_err|rx_frm_trunc|port_tx_packets):')
t1=$(date +%s.%N)
printf 'NIC_BEGIN\n'
printf 'TLATCH %s %s\n' "$t0" "$t1"
echo "$OUT" | tr -d ' ' | tr ':' ' '
printf 'NIC_END\n'
EOS

snap_fetch(){  # live: 一次 ssh; 离线: 从 G4_SNAP_TEXT 列表里取第 n 个
  if [ -n "${G4_SNAP_TEXT:-}" ]; then cat "$1"; return 0; fi
  need_pw; peer --sudo --timeout 120 "$SNAP_REMOTE"
}
nic_fetch(){
  if [ -n "${G4_NIC_TEXT:-}" ]; then cat "$1"; return 0; fi
  peer --timeout 60 "$NIC_REMOTE"
}
# 逗号列表取第 n 项 (1-based)
pick(){ echo "$1" | awk -F, -v n="$2" '{print $n}'; }
# 逗号列表的项数
count_items(){ echo "$1" | awk -F, '{print NF}'; }

# ---- 解析层 (纯函数: 规范文本 → 数组; **负对照就是往这里喂假文本**) ------------
# parse_snap <file> → SW[] + SM{GEN0,GEN1,T0,T1,MAGIC,BID,MARKER,UNIMPL,OPEN,CLOSE}
parse_snap(){
  PARSE_ERR=""; SW=(); SM=(); local k v v2 idx nw=0 dup=0
  while read -r k v v2 || [ -n "${k:-}" ]; do
    case "$k" in
      SNAP_BEGIN) SM[OPEN]=1;;
      SNAP_END)   SM[CLOSE]=1;;
      W[0-9]*)    idx=${k#W}
                  [[ "$idx" =~ ^[0-9]+$ ]] || continue
                  [[ "$v" =~ ^0[xX][0-9a-fA-F]{1,8}$ ]] || { PARSE_ERR="W$idx 的读数是 '$v' (不是 0x 十六进制 ⇒ 空读/读失败); **空读 ≠ 真 0**"; return 1; }
                  [ -n "${SW[$idx]:-}" ] && dup=1
                  SW[$idx]=$(( v )); nw=$(( nw+1 ));;
      GEN)        SM[GEN0]=$v; SM[GEN1]=${v2:-};;
      TLATCH)     SM[T0]=$v;   SM[T1]=${v2:-};;
      "")         ;;
      *)          SM[$k]=$v;;
    esac
  done < "$1"
  [ -n "${SM[OPEN]:-}" ] && [ -n "${SM[CLOSE]:-}" ] || { PARSE_ERR="缺 SNAP_BEGIN/SNAP_END"; return 1; }
  local i
  for (( i = 0; i < SNAP_WORDS; i++ )); do
    [ -n "${SW[$i]:-}" ] || { PARSE_ERR="窗口不完整: 缺 W$i (共收到 $nw 字; 期望下标 0..$((SNAP_WORDS-1)) 连续)"; return 1; }
  done
  [ "$dup" -eq 0 ] || { PARSE_ERR="有**下标重复**的字 (地址表重复 / 末字回绕成低地址字 —— 正是旧脚本尾部 8 项重复那处笔误的形态)"; return 1; }
  [ "${#SW[@]}" -eq "$SNAP_WORDS" ] || { PARSE_ERR="字数不符: 收到 ${#SW[@]} 个下标 (期望 $SNAP_WORDS)"; return 1; }
  for k in GEN0 GEN1; do [[ "${SM[$k]:-}" =~ ^[0-9]+$ ]] || { PARSE_ERR="缺/坏 GEN ($k='${SM[$k]:-}')"; return 1; }; done
  local dg=$(( (SM[GEN1] - SM[GEN0]) % 65536 )); [ "$dg" -lt 0 ] && dg=$(( dg + 65536 ))
  [ "$dg" -eq 1 ] || { PARSE_ERR="gen 不是恰好 +1 (${SM[GEN0]} → ${SM[GEN1]}) ⇒ 这一代不是我触发的/有并发写者; **读数不可归因, 整轮作废**"; return 1; }
  for k in MAGIC BID MARKER UNIMPL; do
    [[ "${SM[$k]:-}" =~ ^0[xX][0-9a-fA-F]{1,8}$ ]] || { PARSE_ERR="缺/坏 $k ('${SM[$k]:-}')"; return 1; }
  done
  return 0
}
# parse_nic <file> → NC[<key>] + NT0/NT1
parse_nic(){
  PARSE_ERR=""; NC=(); NT0=""; NT1=""; local k v v2
  while read -r k v v2 || [ -n "${k:-}" ]; do
    case "$k" in
      NIC_BEGIN|NIC_END|"") :;;
      TLATCH) NT0=$v; NT1=${v2:-};;
      *) [[ "$v" =~ ^[0-9]+$ ]] || { PARSE_ERR="NIC 字段 $k 的值 '$v' 不是十进制 (没采到/解析失败)"; return 1; }
         NC[$k]=$v;;
    esac
  done < "$1"
  [ -n "$NT0" ] && [ -n "$NT1" ] || { PARSE_ERR="NIC 文本缺 TLATCH"; return 1; }
  local need="rx_eth_crc_err port_rx_good port_rx_bad port_rx_bytes port_rx_packets port_rx_unicast port_rx_64 port_rx_1024_to_15xx port_rx_multicast"
  for k in $need; do [ -n "${NC[$k]:-}" ] || { PARSE_ERR="NIC 文本缺字段 $k"; return 1; }; done
  return 0
}
# snap_copy <A|B|C|D>: 把刚解析的 SW/SM 复制到 <P>_SW/<P>_* (前缀由本脚本写死 ⇒ eval 安全)
snap_copy(){ local p="$1"; eval "${p}_SW=(\"\${SW[@]}\")"
  for k in GEN0 GEN1 T0 T1 MAGIC BID MARKER UNIMPL; do eval "${p}_$k=\${SM[$k]}"; done; }
nic_copy(){ local p="$1" k; eval "${p}_NC=()"
  for k in "${!NC[@]}"; do eval "${p}_NC[\$k]=\${NC[\$k]}"; done
  eval "${p}_T0=\$NT0"; eval "${p}_T1=\$NT1"; }

# ---- 判据层 (纯函数) ----------------------------------------------------------
check_identity(){ # <标签> <MAGIC> <BID> <MARKER>
  local tg="$1" mg="$2" bd="$3" mk="$4"
  if [ "$mg" = "0x50360001" ] && [ "$(( bd ))" -eq "$(( EXPECT_BID ))" ] && [ "$mk" = "$MARKER_EXP" ]; then
    res PASS "G1" "位流身份 ($tg)" "MAGIC=0x50360001 BID=$EXPECT_BID MARKER=$MARKER_EXP" "MAGIC=$mg BID=$bd MARKER=$mk"; return 0
  fi
  res FAIL "G1" "位流身份 ($tg)" "MAGIC=0x50360001 BID=$EXPECT_BID MARKER=$MARKER_EXP" \
      "MAGIC=$mg BID=$bd MARKER=$mk ⇒ 不是本轮位流, 后面所有读数都不算数"; return 1
}
check_window(){ # <标签> <unimpl 值> <数组名>
  local tg="$1" un="$2"; local -n W="$3"
  local i nff=0
  for (( i = 0; i < SNAP_WORDS; i++ )); do [ "${W[$i]}" = "4294967295" ] && nff=$(( nff+1 )); done
  [ "$nff" -eq 0 ] && res PASS "B_WIN" "$tg 窗口 $SNAP_WORDS 字齐全且无 0xffffffff" "0 个 F" "0 个 F (SLVERR 没混进窗口)" \
                   || res FAIL "B_WIN" "$tg 窗口内不得出现 0xffffffff" "0 个 F" "$nff 个 F ⇒ 这些是**读失败**, 不是数据"
  if [ "$(( un ))" -eq 4294967295 ]; then res PASS "B_UNIMPL" "$tg 未实现地址 $UNIMPL_ADDR" "0xffffffff" "0xffffffff"
  else res FAIL "B_UNIMPL" "$tg 未实现地址 $UNIMPL_ADDR" "0xffffffff" "$un ⇒ 译码过宽, 或该地址其实是已实现字 (窗口挪了地址没挪)"; fi
}
check_freq(){ # <判据号> <名> <a> <b> <t0a> <t1a> <t0b> <t1b> <标称MHz> <除数>
  local id="$1" nm="$2" a="$3" b="$4" t0a="$5" t1a="$6" t0b="$7" t1b="$8" nom="$9" div="${10}"
  local dt d f
  dt=$(dt2 "$t0a" "$t1a" "$t0b" "$t1b"); d=$(dd32 "$a" "$b")
  if le "$dt" 0.05; then res SKIP "$id" "$nm 频率" "Δ/墙钟" "窗口 ${dt}s 太短 (合成文本里 TLATCH 相同?) ⇒ 反解不出频率"; return 0; fi
  if ! le "$dt" 20; then res SKIP "$id" "$nm 频率" "窗口 <20s" "窗口 ${dt}s ⇒ 32 位计数可能已回绕 (27.49s 一圈), 本轮不判"; return 0; fi
  f=$(hz2mhz "$d" "$dt" "$div")
  if in_pct "$f" "$nom" 1.0; then res PASS "$id" "$nm = $f MHz (Δ=$d / ${dt}s / ÷$div)" "$nom ±1%" "$f MHz"
  else res FAIL "$id" "$nm 频率" "$nom ±1%" "$f MHz (Δ=$d / ${dt}s / ÷$div) ⇒ 该域没起 / 计数被钉死 / 窗口里回绕过"; fi
}
# ⚠️ W50 的口径**在源码里是自相矛盾的, 不许猜** (本工程"未核实项不许当结论用"):
#   `board/wrapper_p4.v:3389` 的注释写"频率 = 沿数/2", 但 RTL (`:3387-3400`) 是
#   `tx_tgl_tx <= ~tx_tgl_tx` —— **每拍 tx_fe_clk 翻转一次**, dp 侧数的是**每次变化**
#   ⇒ 数学上 沿数/秒 = tx_fe_clk 频率, 也就是 **÷1**; 若按 ÷2 读会得到 78.125 MHz = **假 FAIL**。
#   两种口径差正好 2 倍, 不烧板判不了 ⇒ 本函数**两个都算**, 命中哪个就把它记下来
#   (命中 ÷1 ⇒ 注释错了要订正; 命中 ÷2 ⇒ 我这段分析错了) —— 一次上板就把这条钉死。
check_freq_tgl(){ # <判据号> <名> <a> <b> <t0a> <t1a> <t0b> <t1b> <标称MHz>
  local id="$1" nm="$2" a="$3" b="$4" t0a="$5" t1a="$6" t0b="$7" t1b="$8" nom="$9"
  local dt d f1 f2
  dt=$(dt2 "$t0a" "$t1a" "$t0b" "$t1b"); d=$(dd32 "$a" "$b")
  if le "$dt" 0.05; then res SKIP "$id" "$nm 频率" "Δ/墙钟" "窗口 ${dt}s 太短 ⇒ 反解不出频率"; return 0; fi
  if ! le "$dt" 20; then res SKIP "$id" "$nm 频率" "窗口 <20s" "窗口 ${dt}s ⇒ 32 位计数可能已回绕, 本轮不判"; return 0; fi
  f1=$(hz2mhz "$d" "$dt" 1); f2=$(hz2mhz "$d" "$dt" 2)
  if in_pct "$f1" "$nom" 1.0; then
    res PASS "$id" "$nm = $f1 MHz (**÷1 口径命中**)" "$nom ±1%" "÷1 ⇒ $f1 / ÷2 ⇒ $f2 (⇒ wrapper_p4.v:3389 的 '÷2' 注释需订正)"
  elif in_pct "$f2" "$nom" 1.0; then
    res PASS "$id" "$nm = $f2 MHz (**÷2 口径命中**)" "$nom ±1%" "÷1 ⇒ $f1 / ÷2 ⇒ $f2 (⇒ 注释的 ÷2 成立, 本文档的分析需订正)"
  else
    res FAIL "$id" "$nm 频率" "$nom ±1% (两种口径之一)" "÷1 ⇒ $f1 / ÷2 ⇒ $f2 都不命中 (Δ=$d / ${dt}s) ⇒ 该域没起 / 计数被钉死"
  fi
}
check_cons(){ # <数组名> 停机态守恒律
  local -n W="$1"
  local a=${W[0]} b=${W[1]} c=${W[32]} e=${W[33]} x=${W[30]} y=${W[31]}
  local rx=$(( (a + c) % W32 )) ry=$(( (b - 4*a + e) % W32 )); [ "$ry" -lt 0 ] && ry=$(( ry + W32 ))
  [ "$x" -eq "$rx" ] && res PASS "B_CONS-a" "W30 == W0 + W32" "$rx" "$x" \
                     || res FAIL "B_CONS-a" "W30 == W0 + W32" "$rx" "$x (差 $(( x - rx )) ⇒ CDC 丢/重帧)"
  [ "$y" -eq "$ry" ] && res PASS "B_CONS-b" "W31 == W1 - 4*W0 + W33" "$ry" "$y" \
                     || res FAIL "B_CONS-b" "W31 == W1 - 4*W0 + W33" "$ry" "$y (差 $(( y - ry )) ⇒ CDC 丢/重字节)"
  [ "$(( a - x ))" -ge -1 ] && res PASS "B_DIR" "链式触发方向性 W0 - W30 >= -1" ">=-1" "$(( a - x ))" \
                           || res FAIL "B_DIR" "链式触发方向性 W0 - W30 >= -1" ">=-1" "$(( a - x )) ⇒ 两束被写反了?"
}
check_pcs(){ # <数组名>
  local -n W="$1"; local v=${W[39]}
  if [ "$(bit $v 29)" = 1 ] && [ "$(bit $v 2)" = 1 ] && [ "$(bit $v 3)" = 1 ] \
     && [ "$(bit $v 4)" = 0 ] && [ "$(bit $v 5)" = 0 ] && [ "$(bit $v 6)" = 0 ]; then
    res PASS "C1-C5" "PCS: gtpowergood/block_lock/rx_status=1 且 hi_ber/local_fault=0" "全成立" "W39=0x$(printf '%08X' $v)"
  else res FAIL "C1-C5" "PCS 状态位" "gpw=1 blk=1 st=1 ber=0 lf=0" \
      "W39=0x$(printf '%08X' $v) (gpw=$(bit $v 29) blk=$(bit $v 2) st=$(bit $v 3) ber=$(bit $v 4) rlf=$(bit $v 5) tlf=$(bit $v 6))"; fi
  if [ "$(bit $v 21)" = 0 ] && [ "$(bit $v 11)" = 0 ] && [ "$(bit $v 10)" = 0 ] && [ "$(bit $v 8)" = 0 ] && [ "$(( v & 0x003FE000 ))" -eq 0 ]; then
    res PASS "C6-C7" "rx_error/fifo_error/bad_code_valid/framing_err_valid 全 0" "全 0" "W39=0x$(printf '%08X' $v)"
  else res FAIL "C6-C7" "PCS 的 err 位必须全 0" "全 0" "W39=0x$(printf '%08X' $v)"; fi
}
check_evt(){ # <数组名1> <数组名2|->  W40: C8 正证据 + 事件计数恒 0
  local -n W="$1"; local v1=${W[40]}
  local evt1=$(( (v1 >> 8) & 0xffffff )) vcc1=$(( v1 & 0xff ))
  if [ "$2" != "-" ]; then
    local -n W2="$2"; local v2=${W2[40]}
    local vcc2=$(( v2 & 0xff )) evt2=$(( (v2 >> 8) & 0xffffff ))
    [ "$vcc2" -gt "$vcc1" ] && res PASS "C8" "W40.valid_ctrl_code_cyc 非 0 且在涨 (⭐正证据)" "> $vcc1" "$vcc1 → $vcc2" \
                            || res FAIL "C8" "W40.valid_ctrl_code_cyc 必须非 0 且在涨" "> $vcc1" "$vcc1 → $vcc2 (钉死 ⇒ 这条例数不是来自核)"
    [ "$evt1" -eq 0 ] && [ "$evt2" -eq 0 ] && res PASS "C6-ev" "W40 的 framing/bad_code/rx_error 事件计数恒 0" "0/0" "0/0" \
                                          || res FAIL "C6-ev" "W40 事件计数必须恒 0" "0/0" "$evt1/$evt2"
  else
    res SKIP "C8" "W40.valid_ctrl_code_cyc 在涨" ">0 且随窗口单调增" "只有一块 ⇒ 判不了'在涨' (vcc=$vcc1)"
    [ "$evt1" -eq 0 ] && res PASS "C6-ev" "W40 事件计数恒 0 (单块)" "0" "0" || res FAIL "C6-ev" "W40 事件计数恒 0" "0" "$evt1"
  fi
}
check_nic(){ # <标签> <want:1 测量窗 / 0 基线窗> <前缀1> <前缀2>
  local tg="$1" want="$2" p1="$3" p2="$4"
  local -n A="${p1}_NC" B="${p2}_NC"
  local t0a=${p1}_T0 t1a=${p1}_T1 t0b=${p2}_T0 t1b=${p2}_T1
  local dt dg dbad dpkt dbyt duni d1518 d64 dcrc avg mbps_v
  dt=$(dt2 "${!t0a}" "${!t1a}" "${!t0b}" "${!t1b}")
  dg=$(( B[port_rx_good] - A[port_rx_good] ))
  dbad=$(( B[port_rx_bad] - A[port_rx_bad] ))
  dpkt=$(( B[port_rx_packets] - A[port_rx_packets] ))
  dbyt=$(( B[port_rx_bytes] - A[port_rx_bytes] ))
  duni=$(( B[port_rx_unicast] - A[port_rx_unicast] ))
  d1518=$(( B[port_rx_1024_to_15xx] - A[port_rx_1024_to_15xx] ))
  d64=$(( B[port_rx_64] - A[port_rx_64] ))
  dcrc=$(( B[rx_eth_crc_err] - A[rx_eth_crc_err] ))
  mbps_v=$(mbps "$dbyt" "$dt")
  if [ "$want" = "0" ]; then
    # ⭐ 判别力自检: 同一套 N_RATE **必须不成立** (否则判据被背景流量满足 = 真空门)
    if [ "$dg" -lt "$NIC_GOOD_MIN" ]; then
      res PASS "N_BASE" "$tg: 速率判据**不成立** ⇒ 该判据有判别力" "< $NIC_GOOD_MIN 帧" "Δport_rx_good=$dg / ${dt}s (背景)"
    else res FAIL "N_BASE" "$tg: 速率判据必须不成立 (判别力自检)" "< $NIC_GOOD_MIN 帧" "Δ=$dg ⇒ 背景已满足阈值 ⇒ 该判据是**真空门**"; fi
    return 0
  fi
  [ "$dcrc" -eq 0 ] && res PASS "N_CRC" "$tg Δrx_eth_crc_err == 0" "0" "0" \
                    || res FAIL "N_CRC" "$tg Δrx_eth_crc_err == 0" "0" "$dcrc (FCS 错帧 ⇒ 立刻停, 回 mac_tx_10g 的 pad/FCS 修复)"
  [ "$dbad" -eq 0 ] && res PASS "N_BAD" "$tg Δport_rx_bad == 0" "0" "0" \
                    || res FAIL "N_BAD" "$tg Δport_rx_bad == 0" "0" "$dbad"
  if [ "$dg" -ge "$NIC_GOOD_MIN" ] && ge "$mbps_v" "$NIC_MBPS_MIN"; then
    res PASS "N_RATE" "$tg 增量 + 速率阈值" "Δ>=$NIC_GOOD_MIN 帧 且 >=$NIC_MBPS_MIN Mbps" "Δ=$dg 帧 / ${dt}s = $mbps_v Mbps"
  else res FAIL "N_RATE" "$tg 增量 + 速率阈值" "Δ>=$NIC_GOOD_MIN 帧 且 >=$NIC_MBPS_MIN Mbps" "Δ=$dg 帧 / ${dt}s = $mbps_v Mbps"; fi
  if [ "$dg" -gt 0 ] && ge "$duni" "$(awk -v g="$dg" 'BEGIN{print 0.9*g}')"; then
    res PASS "N_UCAST" "$tg Δport_rx_unicast 同步涨 (图案是单播)" ">=0.9Δgood" "Δuni=$duni / Δgood=$dg"
  else res FAIL "N_UCAST" "$tg Δport_rx_unicast 同步涨" ">=0.9Δgood" "Δuni=$duni / Δgood=$dg (涨的是广播 ⇒ 是板子背景, 不是图案)"; fi
  if [ "$dg" -gt 0 ] && ge "$d1518" "$(awk -v g="$dg" 'BEGIN{print 0.9*g}')" && le "$d64" "$(awk -v g="$dg" 'BEGIN{print 0.1*g}')"; then
    res PASS "N_LEN" "$tg 长度桶: 1518B 占绝对多数" "1024_15xx>=0.9Δgood 且 64<=0.1Δgood" "1518桶=$d1518 64桶=$d64 Δgood=$dg"
  else res FAIL "N_LEN" "$tg 长度桶" "1024_15xx>=0.9Δgood 且 64<=0.1Δgood" "1518桶=$d1518 64桶=$d64 Δgood=$dg (背景是 64/66B 小帧)"; fi
  if [ "$dpkt" -gt 0 ]; then
    avg=$(awk -v b="$dbyt" -v p="$dpkt" 'BEGIN{printf "%.6f", b/p}')
    if ge "$avg" 1517.5 && le "$avg" 1518.5; then res PASS "N_AVG" "$tg Δbytes/Δpackets ≈ 1518.000000" "[1517.5,1518.5]" "$avg"
    else res FAIL "N_AVG" "$tg Δbytes/Δpackets ≈ 1518.000000" "[1517.5,1518.5]" "$avg"; fi
  else res SKIP "N_AVG" "$tg Δbytes/Δpackets" "≈1518.000000" "Δpackets=0"; fi
  [ "$(( dg + dbad ))" -eq "$dpkt" ] && res PASS "N_SELF" "$tg 自洽: Δgood + Δbad == Δpackets" "相等" "$dg + $dbad == $dpkt" \
                                     || res FAIL "N_SELF" "$tg 自洽: Δgood + Δbad == Δpackets" "相等" "$dg + $dbad != $dpkt"
}
check_xchk(){ # <ΔW20> <Δbytes> <Δt>
  local d20="$1" dbyt="$2" dt="$3" br nr
  if [ "$d20" -eq 0 ]; then res SKIP "N_XCHK" "板侧 W20 vs 网卡硬件计数" "偏差<1%" "ΔW20=0 (板子没在发) ⇒ 无从对账"; return 0; fi
  br=$(awk -v f="$d20" -v t="$dt" 'BEGIN{printf "%.3f", f*1518*8/t/1e6}')
  nr=$(mbps "$dbyt" "$dt")
  if in_pct "$br" "$nr" 1.0; then res PASS "N_XCHK" "板侧自报率 vs 网卡硬件率 (两个独立来源)" "偏差<1%" "板 $br vs 网卡 $nr Mbps"
  else res FAIL "N_XCHK" "板侧自报率 vs 网卡硬件率" "偏差<1%" "板 $br vs 网卡 $nr Mbps (偏差 $(awk -v a="$br" -v b="$nr" 'BEGIN{printf "%.2f", (b-a)/b*100}')%)"; fi
}

# ---- 主流程 ------------------------------------------------------------------
main(){
  mkdir -p "$OUTDIR"
  hr "0. 位流身份 (G1 的位流一半) 与前置"
  if [ -f "$BIT" ]; then
    echo "  [INFO] 位流 = $BIT"
    echo "  [INFO] sha256 = $(sha256sum "$BIT" | awk '{print $1}')"
    echo "  [INFO] size   = $(wc -c < "$BIT") ; mtime = $(date -r "$BIT" '+%F %T')"
  else
    echo "  [WARN] 找不到位流 $BIT ⇒ G1 少了 sha256 那一半 (必须在验收报告里如实标注)"
  fi

  local OFFLINE=0; [ -n "${G4_SNAP_TEXT:-}${G4_NIC_TEXT:-}" ] && OFFLINE=1

  # ---------- 板侧: 停机态一对 (A,B) + (可选) 洪泛态一对 (C,D) ----------
  local nsf=1; [ -n "${G4_SNAP_TEXT:-}" ] && nsf=$(count_items "$G4_SNAP_TEXT")
  local sf1=$OUTDIR/_snap_in1.txt
  if [ "$OFFLINE" = 1 ]; then
    echo "  [INFO] **离线/负对照模式**: 读数来自合成文本, 不碰板子/对端机"
    sf1=$(pick "$G4_SNAP_TEXT" 1); parse_snap "$sf1" || { fatal "合成快照块1: $PARSE_ERR"; }
  else
    snap_fetch "$sf1" > "$OUTDIR/snap_A.txt" || fatal "快照块 A 取数失败"
    sf1=$OUTDIR/snap_A.txt; if ! parse_snap "$sf1"; then fatal "快照块 A 解析: $PARSE_ERR"; fi
  fi
  if [ "$FATAL" = 0 ]; then
    snap_copy A; check_identity "块A" "$A_MAGIC" "$A_BID" "$A_MARKER" || fatal "身份不符 ⇒ 拒绝继续 (G1 前置闸)"
    check_window "块A" "$A_UNIMPL" A_SW
  fi
  if [ "$FATAL" != 0 ]; then echo; echo "  [ABORT] 前置闸未过 ⇒ 后面的读数都不算数"; echo "-------- 原始文本 --------"; cat "$sf1"; echo "########## PASS=$PASS FAIL=$FAIL SKIP=$SKIP ##########"; exit 2; fi

  local sf2
  if [ "$nsf" -lt 2 ]; then
    echo "  [SKIP] 只给了一块快照 ⇒ 频率/守恒/增量判据全部无法判 (需要两点)"
  else
    if [ "$OFFLINE" = 1 ]; then sf2=$(pick "$G4_SNAP_TEXT" 2)
    else echo "  (等 5 s 再取第二块 —— 频率与增量判据需要两点)"; sleep 5; snap_fetch "$sf2" > "$OUTDIR/snap_B.txt"; sf2=$OUTDIR/snap_B.txt; fi
    if parse_snap "$sf2"; then
      snap_copy B
      check_identity "块B" "$B_MAGIC" "$B_BID" "$B_MARKER" || fatal "块 B 身份不符"
      check_window "块B" "$B_UNIMPL" B_SW
      check_freq "G2-W5"  "前端域 gmii_free"   "${A_SW[5]}"  "${B_SW[5]}"  "$A_T0" "$A_T1" "$B_T0" "$B_T1" 125.00 1
      check_freq "G2-W24" "数据面域 dp_free"   "${A_SW[24]}" "${B_SW[24]}" "$A_T0" "$A_T1" "$B_T0" "$B_T1" 156.25 1
      check_freq_tgl "G2-W50" "TX 域 tx_clk_act" "${A_SW[50]}" "${B_SW[50]}" "$A_T0" "$A_T1" "$B_T0" "$B_T1" 156.25
      check_cons A_SW
      check_pcs A_SW
      check_evt A_SW B_SW
    else fatal "快照块 B 解析: $PARSE_ERR"; fi
  fi
  if [ "$FATAL" != 0 ]; then
    echo; echo "  [ABORT] 快照块结构/身份未过 ⇒ **整轮读数不可用** (退出 2): $PARSE_ERR"
    echo "########## PASS=$PASS FAIL=$FAIL SKIP=$SKIP ##########"; exit 2
  fi

  # ---------- NIC 侧 ----------
  local nicn=1; [ -n "${G4_NIC_TEXT:-}" ] && nicn=$(count_items "$G4_NIC_TEXT")
  hr "NIC 侧: 基线窗 (教学前) —— 含**判别力自检** N_BASE"
  if [ "$OFFLINE" = 1 ]; then
    if [ "$nicn" -ge 4 ]; then
      parse_nic "$(pick "$G4_NIC_TEXT" 1)" && nic_copy NB || fatal "合成 NIC 块1: $PARSE_ERR"
      parse_nic "$(pick "$G4_NIC_TEXT" 2)" && nic_copy NQ || fatal "合成 NIC 块2: $PARSE_ERR"
      abort_if_fatal "NIC 基线窗"
      check_nic "基线" 0 NB NQ
    elif [ "$nicn" -eq 2 ]; then
      res SKIP "N_BASE" "基线窗判别力自检" "判据必须不成立" "只给了 2 个 NIC 文本 ⇒ 当测量窗用, 基线自检无从做"
    else fatal "G4_NIC_TEXT 至少要 2 个文件"; abort_if_fatal "NIC 文本清单"; fi
  else
    nic_fetch > "$OUTDIR/nic_A.txt"; sleep 5; nic_fetch > "$OUTDIR/nic_B.txt"
    parse_nic "$OUTDIR/nic_A.txt" && nic_copy NB || fatal "NIC 块 A: $PARSE_ERR"
    parse_nic "$OUTDIR/nic_B.txt" && nic_copy NQ || fatal "NIC 块 B: $PARSE_ERR"
    if [ "$FATAL" != 0 ]; then
      echo; echo "  [ABORT] NIC 基线窗取数/解析失败 ⇒ **NIC 判据全部作废** (退出 2): $PARSE_ERR"
      echo "        先查: 口名对不对 (G4_IFACE=$IFACE) / ethtool 在不在 / ssh 通不通"
      echo "########## PASS=$PASS FAIL=$FAIL SKIP=$SKIP ##########"; exit 2
    fi
    check_nic "基线" 0 NB NQ
  fi

  hr "测量窗 (教学 → 打流 → NIC 两点 + 板侧洪泛两点)"
  local d20=0
  if [ "$OFFLINE" = 1 ]; then
    if [ "$nicn" -ge 4 ]; then
      parse_nic "$(pick "$G4_NIC_TEXT" 3)" && nic_copy NB || fatal "合成 NIC 块3: $PARSE_ERR"
      parse_nic "$(pick "$G4_NIC_TEXT" 4)" && nic_copy NQ || fatal "合成 NIC 块4: $PARSE_ERR"
      abort_if_fatal "NIC 测量窗"
      check_nic "测量" 1 NB NQ
    elif [ "$nicn" -eq 2 ]; then
      parse_nic "$(pick "$G4_NIC_TEXT" 1)" && nic_copy NB || fatal "合成 NIC 块1: $PARSE_ERR"
      parse_nic "$(pick "$G4_NIC_TEXT" 2)" && nic_copy NQ || fatal "合成 NIC 块2: $PARSE_ERR"
      abort_if_fatal "NIC 测量窗"
      check_nic "测量" 1 NB NQ
    fi
    if [ "$nsf" -ge 4 ]; then
      parse_snap "$(pick "$G4_SNAP_TEXT" 3)" && snap_copy C || fatal "合成快照块3: $PARSE_ERR"
      parse_snap "$(pick "$G4_SNAP_TEXT" 4)" && snap_copy D || fatal "合成快照块4: $PARSE_ERR"
    fi
  elif [ "$G4_SKIP_TRAFFIC" = "1" ]; then
    res SKIP "N_RATE" "测量窗" "需要打流" "G4_SKIP_TRAFFIC=1 ⇒ 本段没跑 (按 P7B_GATE4_PLAN.md 步骤 5 打流后重跑)"
  else
    echo "  [INFO] 教学 + 图案激励: $G4_TRAFFIC_CMD"
    peer --sudo "ip addr add $MYIP/32 dev $IFACE 2>/dev/null; ip route add $BOARD_IP/32 dev $IFACE src $MYIP 2>/dev/null; ip route get $BOARD_IP" || true
    peer --timeout 180 "$G4_TRAFFIC_CMD" || echo "  [WARN] 图案工具退出码非 0 (读它的 gap/bad 汇总; gap=接收侧掉包, bad=真失配)"
    nic_fetch > "$OUTDIR/nic_C.txt"; sleep 3; nic_fetch > "$OUTDIR/nic_D.txt"
    parse_nic "$OUTDIR/nic_C.txt" && nic_copy NB || fatal "NIC 块 C: $PARSE_ERR"
    parse_nic "$OUTDIR/nic_D.txt" && nic_copy NQ || fatal "NIC 块 D: $PARSE_ERR"
    if [ "$FATAL" != 0 ]; then
      echo; echo "  [ABORT] NIC 测量窗取数/解析失败 ⇒ **NIC 判据全部作废** (退出 2): $PARSE_ERR"
      echo "########## PASS=$PASS FAIL=$FAIL SKIP=$SKIP ##########"; exit 2
    fi
    check_nic "测量" 1 NB NQ
    echo "  (打流后取板侧洪泛两点: ΔW34 与 ΔW20 对账用)"
    snap_fetch > "$OUTDIR/snap_C.txt"; sleep 3; snap_fetch > "$OUTDIR/snap_D.txt"
    parse_snap "$OUTDIR/snap_C.txt" && snap_copy C || fatal "快照块 C: $PARSE_ERR"
    parse_snap "$OUTDIR/snap_D.txt" && snap_copy D || fatal "快照块 D: $PARSE_ERR"
  fi
  # 洪泛窗: ΔW34 (E4/G6) 与 ΔW20 (N_XCHK)
  if [ -n "${C_SW+x}" ] && [ -n "${D_SW+x}" ] && [ "${#C_SW[@]}" -gt 0 ]; then
    local d34; d34=$(dd32 "${C_SW[34]}" "${D_SW[34]}")
    [ "$d34" -eq 0 ] && res PASS "B_G6" "洪泛窗 ΔW34 (rx_stat_drop_full) == 0" "0" "0" \
                     || res FAIL "B_G6" "洪泛窗 ΔW34 (rx_stat_drop_full) == 0" "0" "$d34 (有 FIFO 空间不足丢帧)"
    d20=$(dd32 "${C_SW[20]}" "${D_SW[20]}")
  fi
  if [ -n "${NQ_NC+x}" ] && [ -n "${NB_NC+x}" ]; then
    local dbyt dtb; dbyt=$(( NQ_NC[port_rx_bytes] - NB_NC[port_rx_bytes] ))
    dtb=$(dt2 "$NB_T0" "$NB_T1" "$NQ_T0" "$NQ_T1")
    check_xchk "$d20" "$dbyt" "$dtb"
  fi

  hr "汇总"
  printf '  %s\n' "${SUM[@]}"
  echo "########## PASS=$PASS FAIL=$FAIL SKIP=$SKIP (窗口 $SNAP_WORDS 字; 未实现地址 $UNIMPL_ADDR; EXPECT_BID=$EXPECT_BID) ##########"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
}

if [ "${G4_LIB_ONLY:-0}" = "1" ]; then return 0 2>/dev/null || exit 0; fi
main "$@"
