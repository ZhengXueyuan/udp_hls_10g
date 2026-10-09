#!/bin/bash
# tcpreg_j6.sh -- J6/J15 TCP 上行 A/B 测量 (peer -> board, port 8080)
#   与 Stage 1 S1.0a / Stage 2 §10.5.1 同工具同参数: p7b_tcp_src --port 8080 --seconds 6
#   同时抓: 板侧快照 pair (pre/post) + 双向 pcap (窗口轨迹) + ss -ti 采样 + ping
# 用法: bash tcpreg_j6.sh <secs> <pcap> <tag>              # PACE=<bps> 环境变量选 pacing (0 = 不限速)
#   ⚠️ 几何: 默认 = **63 字 / BID 9** (P7B-WU 二轮, 现役)。读**旧位流** (BIZ 61 字 / BID 8)
#      必须显式声明 `J6_LEGACY_GEOM=1 NW=61 EXPECT_BID=0x00000008` —— 那一档**读不到 W61/W62**
#      (字表自动退回 5 53 54), 且日志里有 J6_GEOM_LEGACY 醒目行。缺省档下 NW/BID 不符**当场红**。
#   ⛔ 2026-10-10 订正 (构建 C 门同步轮): 上面这句的"默认 = 63 字 / BID 9"**已过时** ——
#      现役 = **65 字 / BID 0x17** (构建 C: 快照 63→65, W63/W64 = app_pattern 两个停滞计数)。
#      几何档现在单一来源 = 下方 `GEOM_TIERS` 档表 (旧档全部保留), 失败提示由档表**生成**;
#      原句保留 (它描述的是 P7B-WU 二轮那一代)。
#   ⚠️ 本脚本**同时**是 J6 (对端口径) 与 J15 (板内时基新预测带) 的台架:
#      J15 的板内时基 = 同一份 pre/post 全窗快照的 ΔW 系列 (ΔW0/ΔW53/ΔW22, 速率用 ΔW5 时基)。
#
#   ⭐ 2026-10-07 (测量台准备轮) 两处加固 —— 补判据记录缺口 (全局 §六 #43/#48):
#     ① PACE_BPS= **无条件打印** (PACE=0 也打): 曾有一跑读数恰贴 2^30 bps 的 99.94%,
#        而原始件里没有任何 pace 记录 ⇒ 事后无法自证量的是板子还是工具的帽子。
#        PACE_BPS 行紧贴 SRC_* 输出行 (同一份 stdout), 此后任何速率判读必须引用它。
#     ② J6META_* 元数据块: 跑的时刻 (UTC+epoch) / 目标 / 时长 / 脚本 md5 / BIT_SHA / 板侧身份。
#        ⚠️ 位流 sha256 传不进来时打 n/a, 但 **板侧身份 (MAGIC/BID) 是现场读的、不可伪造**
#        (开始与结束各读一次 ⇒ 中途被重烧可检出)。
#
#   ⭐⭐ 2026-10-07 (wu 闭环测量轮) 三处加固 —— J6-ladder 判据 (b)/(c) 的台架自证要求:
#     ③ ss 采样**去掉 `state established` 过滤** (`-tinma`): 板子在连接建立 ~9 ms 即发 FIN
#        ⇒ 对端 socket 进 CLOSE_WAIT ⇒ 旧写法每跑只剩第 1 秒一条可用样本
#        (判据原文 P7B_BIZ_PLAN.md §4.1b (b); 出处 P7B_WU_PACE_AUDIT.md §8-⑤)。
#        分析侧只取含 `pacing_rate` 的条目 (TIME_WAIT 残骸无 socket 详情 ⇒ 自动排除)。
#     ④ tcpdump `timeout` SECS+14 → **SECS+4** + 记录 PID, t1 快照后**显式 kill**:
#        旧值 > 跑间隔 ⇒ 相邻跑的包会串进同一个 pcap (判据原文 (c), 已造成过一次误读)。
#     ⑤ 本跑 sha256 身份: 见 J6META_SCRIPT_MD5 (台架自身可追溯)。
#
#   ⭐⭐ 2026-10-07 (台架修复轮) 两处加固 —— 让"一次 j6-ladder 读数把 wu 机理升为**观测**"成立:
#     ⑥ **传输窗内的 t0/t1 也读 W61/W62**: 原先 `snap ... 5 53 54` ⇒ 紧贴传输窗的两点
#        **结构性不读** `W61 app_ctrl.stat_wu` / `W62 app_ctrl.rx_occ_bytes`, ΔW61/ΔW62 只剩
#        run 前后的两个 full 点 (与传输窗错开) ⇒ "机理落不到传输窗上" (审查 F3 §10.2)。
#        现在 63 字档的字表 = `5 53 54 61 62`; 61 字旧档 (W61/W62 不存在) 自动退回 `5 53 54`。
#     ⑦ **几何门 (硬断言)**: ① `NW=${NW:-65}` (P7B-GAP9-TX; 原 63) 且 **export** (原先那个 `NW=${NW:-61}` **没 export**,
#        只用于打印标签, 取数器仍用自己默认值 ⇒ "文档里的覆盖办法"在本脚本里**是失效的**,
#        且默认分叉后会**记录错几何而不报错**); ② 开场核 (NW, 板侧 BID) 这一对, 不符 ⇒ exit 3;
#        ③ 再跑一次 `p7b_snap.sh id` (它自己断言 MAGIC/BID/未实现地址必须 0xffffffff)。
#
#   ⭐⭐ 2026-10-09 (用户要求: 收发数据不许落盘、防止 IO 瓶颈) 三处改动 —— 与 p7b_board_stagec/j6_stagec.sh 同款:
#     ⑧ **默认不抓 pcap**: 新增 `PCAP_ON` (默认 **0**)。旧版**无条件** `tcpdump -w "$PCAP"`
#        ⇒ 每包落盘 (台架上唯一的落盘路径, ~GB 级写放大)。要取证才显式 `PCAP_ON=1`: 那一跑会打
#        **`PCAP_ACTIVE=1 IO_AFFECTING=1`** 醒目行 ⇒ **该跑读数含 IO, 不许与 PCAP_ON=0 的读数混比**。
#     ⑨ **不抓包时的替代口径** `GEOM_NOPCAP_*` 两行: ① 对端 NIC 硬件计数 (ethtool -S)
#        rx/tx 两个方向的 Δbytes/Δpkts ② 板侧 ΔW43/ΔW20 (TX 线忙度, **非 193 几何**) + fps + ΔW53 速率。
#        (raw A/B 与 wrap 位一并打印; 回卷规则不变)
#   ⛔ 2026-10-10 口径订正 (注释; 行为零改动): "TX 线忙度"这个叫法**作废** —— W43 每拍无条件 +1
#      (mac_tx_10g.v:330, 在 case(state) 之外) ⇒ ΔW43/ΔW20 ≡ 156.25e6/fps (恒等式) ⇒ 该数只能读作
#      "帧率相对几何上限的换算", **不是**线占空/线忙度测量 (板侧没有线占空计数器)。
#      printf 里的 "(TX 线忙度, 非 193 几何)" 字样**本轮未改**, 引用其输出时按本条读。
#     ⑩ t0/t1 快照**同时落盘** + 字表加 20 43 (GEOM_NOPCAP 要用); abort 守卫改用 PIPESTATUS。
set -u
SECS=${1:-6}; PCAP=${2:-/tmp/tcpreg.pcap}; TAG=${3:-J6}
PCAP_ON=${PCAP_ON:-0}                 # ⭐ 2026-10-09: 默认不抓 (旧版无条件抓)
S=${P7B_SNAP:-/tmp/p7b_biz/p7b_snap.sh}
T=${P7B_TOOLS:-/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools}
D=/dev/xdma0_user
cd /tmp/p7b_biz || exit 9

# ---- 几何门 (⑦): 只认**显式**几何档, 其余一律拒绝 -------------------------------
#   档表 = 下面 `GEOM_TIERS` (**单一来源**); 新增一代 = 加一行; **旧档一律保留** ⇒ 旧位流仍可测。
#   ⛔ 判据语义 = "声明的几何必须与板侧身份**成对**" —— 档表之外的组合照样 exit 3。
#      加档 ≠ 放闸: 65 字档**不接受** BID 9, 63 字档**不接受** BID 0x17 (配错对 ⇒ 读数不可归因)。
#   ⛔ 2026-10-10 (构建 C 门同步轮): 本轮之前门里只列了 61/8 与 63/9 两档, 而 `NW` 默认早已随
#      构建抬到 65 ⇒ **默认跑必然 J6_GEOM_FAIL + exit 3** (新位流测不了)。现在档表是唯一来源。
NW=${NW:-65}
EXPECT_BID=${EXPECT_BID:-0x00000017}   # 2026-10-10 构建 C (65 字; 原 0x00000009 = P7B-WU 二轮 / Build 2)
export NW EXPECT_BID        # ⚠️ 必须 export: 取数器 p7b_snap.sh 读的是**它自己的环境**
# 十六进制**大小写归一** (只用于比较, 打印仍用原样; 判据语义零改动 —— 先例 = p7b_snap.sh 的
#   Stage C 订正 / j6_r6fix.sh 的 geom_gate 块: `reg_rw` 打小写而期望值写大写时字符串比较必假红)
norm(){ printf "%s" "$1" | tr "A-F" "a-f"; }
# 档表格式: "NW|BID|WEXTRA|说明"  (WEXTRA 空 = t0/t1 字表退回 5 20 43 53 54)
GEOM_TIERS=(
  "65|0x00000017|61 62|构建 C (2026-10-10) 65 字 / BID 0x17"
  "63|0x00000009|61 62|P7B-WU 二轮 / Build 2 63 字 / BID 9"
  "61|0x00000008||P7B-BIZ 61 字 / BID 8 (必须同时 J6_LEGACY_GEOM=1; W61/W62 结构性不可读)"
)
geom_tiers_echo(){ local _t; for _t in "${GEOM_TIERS[@]}"; do
    IFS='|' read -r _a _b _c _d <<< "$_t"; echo "   档: NW=$_a + EXPECT_BID=$_b  ($_d)"; done; }
LEGACY=${J6_LEGACY_GEOM:-0}
GEOM_HIT=""; WEXTRA=""
for _t in "${GEOM_TIERS[@]}"; do
  IFS='|' read -r _nw _bid _we _desc <<< "$_t"
  if [ "$NW" = "$_nw" ] && [ "$(norm "$EXPECT_BID")" = "$(norm "$_bid")" ]; then
    GEOM_HIT="$_desc"; WEXTRA="$_we"; break
  fi
done
if [ -z "$GEOM_HIT" ]; then
  echo "J6_GEOM_FAIL 声明的几何不在本台架认的档表里 (实测 NW=$NW EXPECT_BID=$EXPECT_BID):"
  geom_tiers_echo
  echo "             ⇒ 板上不是本台架认的位流 (几何/身份不符) ⇒ 拒绝继续 (读数不可归因)"
  exit 3
fi
if [ "$LEGACY" = "1" ]; then
  [ "$NW" = "61" ] || {
    echo "J6_GEOM_FAIL legacy 档只认 61 字 (实测 NW=$NW EXPECT_BID=$EXPECT_BID)"; geom_tiers_echo; exit 3; }
else
  [ "$NW" != "61" ] || {
    echo "J6_GEOM_FAIL 61 字旧档必须显式声明 J6_LEGACY_GEOM=1 (W61/W62 结构性不可读); 档表:"; geom_tiers_echo; exit 3; }
fi

PACE=${PACE:-0}
if [ "$PACE" != "0" ]; then EXTRA="--pace-bps $PACE"; else EXTRA=""; fi
IF=enp1s0f1np1                        # ⭐ 2026-10-09: NIC 计数采样用

# ---- ⭐ 2026-10-09: NIC 硬件计数 + 不抓包时的几何口径 (见文件头 ⑨) --------------------
nicv(){ awk -v k="$2:" '$1==k {print $2; exit}' "$1"; }
NIC(){ local tag="${1:-x}";
       { ethtool -S $IF 2>/dev/null | grep -E '^ +(port_rx_good_bytes|port_rx_packets|port_rx_bad|rx_eth_crc_err|port_rx_nodesc_drops|port_tx_packets|port_tx_bytes):';
         nstat -az 2>/dev/null | grep -E '^(TcpInSegs|TcpOutSegs|TcpRetransSegs|TcpExtTCPOFOQueue|TcpExtTCPACKSkippedSeq|TcpExtTCPFastRetrans) '; } | tee /tmp/nic_${TAG}_${tag}.txt; }
snapw(){ awk -v w="W$2" '$1==w {print $NF; exit}' "$1"; }      # p7b_snap 行取字 (0x..)
h2d(){ [ -n "$1" ] && echo $(( $1 )) || echo ""; }
geom_nopcap(){
  local A=/tmp/nic_${TAG}_pre.txt B=/tmp/nic_${TAG}_post.txt
  local SA=/tmp/snap_${TAG}_t0.txt SB=/tmp/snap_${TAG}_t1.txt
  echo "### GEOM_NOPCAP (PCAP_ON=$PCAP_ON; 不抓包也能给几何/方向口径; raw 与 wrap 位一并落盘)"
  if [ -f "$A" ] && [ -f "$B" ]; then
    awk -v rb0="$(nicv "$A" port_rx_good_bytes)" -v rb1="$(nicv "$B" port_rx_good_bytes)" \
        -v rp0="$(nicv "$A" port_rx_packets)"    -v rp1="$(nicv "$B" port_rx_packets)" \
        -v tb0="$(nicv "$A" port_tx_bytes)"      -v tb1="$(nicv "$B" port_tx_bytes)" \
        -v tp0="$(nicv "$A" port_tx_packets)"    -v tp1="$(nicv "$B" port_tx_packets)" 'BEGIN{
      if (rb0==""||rb1==""||rp0==""||rp1=="") { print "GEOM_NOPCAP_NIC_rx NA (空读)"; exit }
      drb=rb1-rb0; w1=0; if (drb<0) { drb+=4294967296; w1=1 }
      drp=rp1-rp0; w2=0; if (drp<0) { drp+=4294967296; w2=1 }
      printf "GEOM_NOPCAP_NIC_rx A_bytes=%s B_bytes=%s d_bytes=%d wrap=%d | A_pkts=%s B_pkts=%s d_pkts=%d wrap=%d | bytes_per_pkt=%s\n",
             rb0, rb1, drb, w1, rp0, rp1, drp, w2, (drp>0 ? sprintf("%.6f", drb/drp) : "NA")
      if (tb0!="" && tb1!="" && tp0!="" && tp1!="") {
        dtb=tb1-tb0; w3=0; if (dtb<0) { dtb+=4294967296; w3=1 }
        dtp=tp1-tp0; w4=0; if (dtp<0) { dtp+=4294967296; w4=1 }
        printf "GEOM_NOPCAP_NIC_tx A_bytes=%s B_bytes=%s d_bytes=%d wrap=%d | A_pkts=%s B_pkts=%s d_pkts=%d wrap=%d | bytes_per_pkt=%s\n",
               tb0, tb1, dtb, w3, tp0, tp1, dtp, w4, (dtp>0 ? sprintf("%.6f", dtb/dtp) : "NA")
      } }'
  else
    echo "GEOM_NOPCAP_NIC NA (缺 $A 或 $B)"
  fi
  if [ -f "$SA" ] && [ -f "$SB" ]; then
    awk -v a20="$(h2d "$(snapw "$SA" 20)")" -v b20="$(h2d "$(snapw "$SB" 20)")" \
        -v a43="$(h2d "$(snapw "$SA" 43)")" -v b43="$(h2d "$(snapw "$SB" 43)")" \
        -v a5="$(h2d "$(snapw "$SA" 5)")"   -v b5="$(h2d "$(snapw "$SB" 5)")" \
        -v a53="$(h2d "$(snapw "$SA" 53)")" -v b53="$(h2d "$(snapw "$SB" 53)")" 'BEGIN{
      if (a20==""||b20==""||a43==""||b43==""||a5==""||b5=="") { print "GEOM_NOPCAP_BOARD NA (t0/t1 快照缺字)"; exit }
      d20=b20-a20; w1=0; if (d20<0) { d20+=4294967296; w1=1 }
      d43=b43-a43; w2=0; if (d43<0) { d43+=4294967296; w2=1 }
      d5=b5-a5;    w3=0; if (d5<0)  { d5+=4294967296;  w3=1 }
      d53=b53-a53; w4=0; if (a53==""||b53=="") { d53=-1 } else if (d53<0) { d53+=4294967296; w4=1 }
      printf "GEOM_NOPCAP_BOARD A_W20=%s B_W20=%s dW20=%d wrap=%d | A_W43=%s B_W43=%s dW43=%d wrap=%d | A_W5=%s B_W5=%s dW5=%d wrap=%d | cpf=%s (TX 线忙度, 非 193 几何) | fps=%s | 板侧上行 Mbps=%s (ΔW53/时基)\n",
             a20,b20,d20,w1, a43,b43,d43,w2, a5,b5,d5,w3,
             (d20>0 ? sprintf("%.6f", d43/d20) : "NA"),
             (d5>0 ? sprintf("%.3f", d20*156250000.0/d5) : "NA"),
             ((d5>0 && d53>=0) ? sprintf("%.3f", d53*8.0*156250000.0/d5/1e6) : "NA") }'
  else
    echo "GEOM_NOPCAP_BOARD NA (缺 $SA 或 $SB)"
  fi
}

T_START=$(date +%s.%N)
brd(){ [ -x "$T/reg_rw" ] && $T/reg_rw $D "$1" w 2>/dev/null | tail -1 | sed 's/.*: *//'; }
echo "### J6META_BEGIN $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "J6META_T_START_EPOCH=$T_START J6META_T_START_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "J6META_HOST=$(hostname) J6META_TAG=$TAG"
echo "J6META_TARGET=192.168.100.2:8080 J6META_SECS=$SECS J6META_PCAP=$PCAP"
echo "J6META_PCAP_ON=$PCAP_ON J6META_PCAP_ACTIVE=$([ "$PCAP_ON" = "1" ] && echo 1 || echo 0) J6META_IO_AFFECTING=$([ "$PCAP_ON" = "1" ] && echo 1 || echo 0) J6META_SNAP=$S"
echo "J6META_GEOM_FALLBACK=GEOM_NOPCAP_* (NIC 硬件计数 rx/tx 比值 + 板侧 ΔW43/ΔW20/ΔW53; 见文件头 ⑨)"
echo "J6META_NW=$NW J6META_EXPECT_BID=$EXPECT_BID J6META_LEGACY=$LEGACY J6META_T0T1_WORDS=5,20,43,53,54${WEXTRA:+,$WEXTRA}"
echo "J6META_SCRIPT=$0 J6META_SCRIPT_MD5=$(md5sum "$0" 2>/dev/null | cut -d' ' -f1)"
echo "J6META_BIT_SHA=${BIT_SHA:-n/a}"
echo "PACE_BPS=$PACE"
echo "SRC_CMD=./p7b_tcp_src --host 192.168.100.2 --port 8080 --seconds $SECS $EXTRA"
echo "J6META_BOARD_MAGIC=$(brd 0x00) J6META_BOARD_BID=$(brd 0x04)"
echo "### J6META_END $(date +%s.%N)"

echo "### PHASE route_carrier $(date +%s.%N)"
ip route get 192.168.100.2 | head -2
echo "CARRIER=$(cat /sys/class/net/enp1s0f1np1/carrier 2>&1)"

# ---- 几何门 (⑦): 板侧 BID 与声明几何必须成对; 不符 ⇒ 拒绝继续 (读数不可归因) ----
echo "### PHASE geom_gate $(date +%s.%N)  NW=$NW EXPECT_BID=$EXPECT_BID"
[ "$LEGACY" = "1" ] && echo "J6_GEOM_LEGACY ⚠️ 显式读**旧几何** (61 字 / BID 8): W61/W62 结构性不可读 ⇒ 本跑的 ΔW61/ΔW62 不存在, 不许当 0"
BID0=$(brd 0x04)
# ⚠️ 2026-10-10 (构建 C 门同步轮): 比较改成 **norm() 大小写无关** —— 原文是字符串比较,
#    在 BID 含字母的世代 (0xA..0x1F 中的 0xA-0xF 类) 必假红 (板子是对的, 是门错);
#    本工程已为此踩过两次 (p7b_snap.sh / j6_r6fix.sh 的 Stage C 订正), 判据语义零改动。
#    且失败提示原写死 "(现役 63 字 = 0x00000009)" ⇒ 改成由档表派生。
if [ "$(norm "$BID0")" != "$(norm "$EXPECT_BID")" ]; then
  echo "J6_GEOM_FAIL 板侧 BID=$BID0 != 声明值 $EXPECT_BID ⇒ 板上不是本台架认的位流 (几何不符) ⇒ 拒绝继续"
  echo "             声明档 = ${GEOM_HIT:-?}; 本台架认的档表 (旧位流按档显式声明 NW/EXPECT_BID):"
  geom_tiers_echo
  exit 3
fi
bash "$S" id || { echo "J6_GEOM_FAIL 取数器身份闸未过 (MAGIC/BID/未实现地址必须 0xffffffff) ⇒ 拒绝继续"; exit 3; }
echo "J6_GEOM_OK NW=$NW BID=$BID0 T0T1_WORDS=5,53,54${WEXTRA:+,$WEXTRA}"

echo "### PHASE nic_pre $(date +%s.%N)"; NIC pre
echo "### PHASE pre_snapshot $(date +%s.%N)  NW=$NW"
bash "$S" full "${TAG}_pre" || { echo "TCPREG_ABORT pre_snapshot"; exit 1; }

# ⭐ 2026-10-09: 默认 **不抓包** (落盘 = IO 瓶颈); 显式 PCAP_ON=1 才抓, 且打醒目 IO 标记
if [ "$PCAP_ON" = "1" ]; then
  echo "PCAP_ACTIVE=1 IO_AFFECTING=1 target=$PCAP (⚠️ 本跑读数含磁盘 IO: tcpdump -w 逐包落盘 ⇒ 不许与 PCAP_ON=0 的读数混比)"
  rm -f "$PCAP"
  # ④ timeout = SECS+4 (< 本脚本总时长 ⇒ 与下一跑天然隔离); PID 记录供收尾显式 kill (双保险)
  ( timeout $((SECS+4)) tcpdump -i $IF -s 96 -w "$PCAP" "tcp and host 192.168.100.2" >/tmp/tcpdump_${TAG}.log 2>&1 & echo $! >/tmp/tcpdump_${TAG}.pid )
else
  echo "PCAP_ACTIVE=0 IO_AFFECTING=0 (默认: 不抓包, 不写盘; 取证需显式 PCAP_ON=1)"
  [ -e "$PCAP" ] && echo "PCAP_NOTE 路径上已存在旧件 $PCAP —— 不是本跑产物, 不计入本跑"
fi
sleep 1.5

# ③ 无 state 过滤 (-a): 板子 9 ms 发 FIN ⇒ established 过滤结构性只剩 1 条样本
( for i in $(seq 1 $((SECS+3))); do
    echo "SS_T $(date +%s.%N) $(ss -tinma '( dport = :8080 or sport = :8080 )' 2>/dev/null | tr '\n' '|')"
    sleep 1
  done > /tmp/ss_${TAG}.log 2>&1 & )

echo "### PHASE src_start $(date +%s.%N)"
echo "PACE_BPS=$PACE"
# J15 板内时基: 紧贴传输窗的两点 (W5=156.25MHz 自由计数 / W53=app 收字节 / W54=失配)
#   => 板侧速率 = ΔW53 / (ΔW5/156.25e6), 不依赖主机墙钟、也不含 tcpdump/收尾的死时间。
# ⑥ wu 机理观测: 传输窗内**同一对点**也读 W61(stat_wu)/W62(rx_occ_bytes) ⇒ ΔW61/ΔW62 落在传输窗上
bash "$S" snap "${TAG}_t0" 5 20 43 53 54 $WEXTRA | tee /tmp/snap_${TAG}_t0.txt; RC=${PIPESTATUS[0]}
[ "$RC" -eq 0 ] || { echo "TCPREG_ABORT t0_snapshot (snap rc=$RC)"; exit 1; }
./p7b_tcp_src --host 192.168.100.2 --port 8080 --seconds "$SECS" $EXTRA
echo "SRC_RC=$? $(date +%s.%N)"
echo "### PHASE t1_snapshot $(date +%s.%N)"
bash "$S" snap "${TAG}_t1" 5 20 43 53 54 $WEXTRA | tee /tmp/snap_${TAG}_t1.txt; RC=${PIPESTATUS[0]}
[ "$RC" -eq 0 ] || { echo "TCPREG_ABORT t1_snapshot (snap rc=$RC)"; exit 1; }
# ④ 收尾显式 kill tcpdump (timeout 之外的双保险; 不再让尾巴跨到下一跑) —— 只在真抓了时才 kill
[ "$PCAP_ON" = "1" ] && kill "$(cat /tmp/tcpdump_${TAG}.pid 2>/dev/null)" 2>/dev/null
sleep 2

echo "### PHASE post_snapshot $(date +%s.%N)"
bash "$S" full "${TAG}_post" || { echo "TCPREG_ABORT post_snapshot"; exit 1; }
echo "### PHASE nic_post $(date +%s.%N)"; NIC post
echo "### PHASE geom_nopcap $(date +%s.%N)"; geom_nopcap

sleep 1
echo "### PHASE ping $(date +%s.%N)"
ping -c 3 -i 0.2 -W 1 192.168.100.2 2>/dev/null | tail -2 | tr '\n' ' '; echo

if [ "$PCAP_ON" = "1" ]; then wc -c "$PCAP"; else echo "PCAP_SKIPPED (PCAP_ON=0: 本跑没有 pcap; 帧几何看上面的 GEOM_NOPCAP_*)"; fi
T_END=$(date +%s.%N)
echo "J6META_T_END_EPOCH=$T_END J6META_T_END_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ) J6META_DUR_S=$(awk -v a="$T_START" -v b="$T_END" 'BEGIN{printf "%.3f", b-a}')"
echo "PACE_BPS=$PACE J6META_BOARD_BID_END=$(brd 0x04)"
echo "TCPREG_J6_DONE"
