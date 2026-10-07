#!/bin/bash
# tcpreg_j6.sh -- J6/J15 TCP 上行 A/B 测量 (peer -> board, port 8080)
#   与 Stage 1 S1.0a / Stage 2 §10.5.1 同工具同参数: p7b_tcp_src --port 8080 --seconds 6
#   同时抓: 板侧快照 pair (pre/post) + 双向 pcap (窗口轨迹) + ss -ti 采样 + ping
# 用法: bash j6_stagea.sh <secs> <pcap> <tag>   # PACE=<bytes/s> 选 pacing (0 = 不限速); BIN=<路径> 选被测二进制
#   ⚠️ 本件 = tcpreg_j6.sh (md5 见 J6META_SCRIPT_MD5) + **仅 BIN 可切换** 3 处 (先例 = p7b_wu_w54/j6_fix.sh):
#      `BIN=${BIN:-./p7b_tcp_src}` / 打 `BIN=`+`BIN_MD5=` / 调用改 `$BIN`。其余逐字未动。
#   ⚠️ 几何: 默认 = **63 字 / BID 9** (P7B-WU 二轮, 现役)。读**旧位流** (BIZ 61 字 / BID 8)
#      必须显式声明 `J6_LEGACY_GEOM=1 NW=61 EXPECT_BID=0x00000008` —— 那一档**读不到 W61/W62**
#      (字表自动退回 5 53 54), 且日志里有 J6_GEOM_LEGACY 醒目行。缺省档下 NW/BID 不符**当场红**。
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
#     ⑦ **几何门 (硬断言)**: ① `NW=${NW:-63}` 且 **export** (原先那个 `NW=${NW:-61}` **没 export**,
#        只用于打印标签, 取数器仍用自己默认值 ⇒ "文档里的覆盖办法"在本脚本里**是失效的**,
#        且默认分叉后会**记录错几何而不报错**); ② 开场核 (NW, 板侧 BID) 这一对, 不符 ⇒ exit 3;
#        ③ 再跑一次 `p7b_snap.sh id` (它自己断言 MAGIC/BID/未实现地址必须 0xffffffff)。
set -u
SECS=${1:-6}; PCAP=${2:-/tmp/tcpreg.pcap}; TAG=${3:-J6}
S=/tmp/p7b_biz/p7b_snap.sh
T=${P7B_TOOLS:-/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools}
D=/dev/xdma0_user
cd /tmp/p7b_biz || exit 9

# ---- 几何门 (⑦): 只认两套**显式**几何, 其余一律拒绝 -------------------------------
#   默认 = 63 字 / BID 9 (P7B-WU 二轮, 现役)  ⇒ t0/t1 读 5 53 54 61 62
#   旧档 = 61 字 / BID 8 (BIZ) 需 `J6_LEGACY_GEOM=1` ⇒ t0/t1 读 5 53 54 (无 W61/W62 可读)
NW=${NW:-63}
EXPECT_BID=${EXPECT_BID:-0x00000009}
export NW EXPECT_BID        # ⚠️ 必须 export: 取数器 p7b_snap.sh 读的是**它自己的环境**
LEGACY=${J6_LEGACY_GEOM:-0}
if [ "$LEGACY" = "1" ]; then
  WEXTRA=""
  { [ "$NW" = "61" ] && [ "$EXPECT_BID" = "0x00000008" ]; } || {
    echo "J6_GEOM_FAIL legacy 档要求 NW=61 + EXPECT_BID=0x00000008 (实测 NW=$NW EXPECT_BID=$EXPECT_BID)"; exit 3; }
else
  { [ "$NW" = "63" ] && [ "$EXPECT_BID" = "0x00000009" ]; } || {
    echo "J6_GEOM_FAIL 默认档要求 NW=63 + EXPECT_BID=0x00000009 (实测 NW=$NW EXPECT_BID=$EXPECT_BID);"
    echo "             读 BIZ 61 字旧位流请显式 J6_LEGACY_GEOM=1 NW=61 EXPECT_BID=0x00000008"; exit 3; }
  WEXTRA="61 62"
fi

BIN=${BIN:-./p7b_tcp_src}
PACE=${PACE:-0}
if [ "$PACE" != "0" ]; then EXTRA="--pace-bps $PACE"; else EXTRA=""; fi

T_START=$(date +%s.%N)
brd(){ [ -x "$T/reg_rw" ] && $T/reg_rw $D "$1" w 2>/dev/null | tail -1 | sed 's/.*: *//'; }
echo "### J6META_BEGIN $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "J6META_T_START_EPOCH=$T_START J6META_T_START_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "J6META_HOST=$(hostname) J6META_TAG=$TAG"
echo "J6META_TARGET=192.168.100.2:8080 J6META_SECS=$SECS J6META_PCAP=$PCAP"
echo "J6META_NW=$NW J6META_EXPECT_BID=$EXPECT_BID J6META_LEGACY=$LEGACY J6META_T0T1_WORDS=5,53,54${WEXTRA:+,$WEXTRA}"
echo "J6META_SCRIPT=$0 J6META_SCRIPT_MD5=$(md5sum "$0" 2>/dev/null | cut -d' ' -f1)"
echo "J6META_BIT_SHA=${BIT_SHA:-n/a}"
echo "PACE_BPS=$PACE"
echo "BIN=$BIN BIN_MD5=$(md5sum "$BIN" 2>/dev/null | cut -d' ' -f1)"
echo "SRC_CMD=$BIN --host 192.168.100.2 --port 8080 --seconds $SECS $EXTRA"
echo "J6META_BOARD_MAGIC=$(brd 0x00) J6META_BOARD_BID=$(brd 0x04)"
echo "### J6META_END $(date +%s.%N)"

echo "### PHASE route_carrier $(date +%s.%N)"
ip route get 192.168.100.2 | head -2
echo "CARRIER=$(cat /sys/class/net/enp1s0f1np1/carrier 2>&1)"

# ---- 几何门 (⑦): 板侧 BID 与声明几何必须成对; 不符 ⇒ 拒绝继续 (读数不可归因) ----
echo "### PHASE geom_gate $(date +%s.%N)  NW=$NW EXPECT_BID=$EXPECT_BID"
[ "$LEGACY" = "1" ] && echo "J6_GEOM_LEGACY ⚠️ 显式读**旧几何** (61 字 / BID 8): W61/W62 结构性不可读 ⇒ 本跑的 ΔW61/ΔW62 不存在, 不许当 0"
BID0=$(brd 0x04)
if [ "$BID0" != "$EXPECT_BID" ]; then
  echo "J6_GEOM_FAIL 板侧 BID=$BID0 != 声明值 $EXPECT_BID ⇒ 板上不是本台架认的位流 (几何不符) ⇒ 拒绝继续"
  echo "              (现役 63 字 = 0x00000009; BIZ 61 字 = 0x00000008 需 J6_LEGACY_GEOM=1)"
  exit 3
fi
bash "$S" id || { echo "J6_GEOM_FAIL 取数器身份闸未过 (MAGIC/BID/未实现地址必须 0xffffffff) ⇒ 拒绝继续"; exit 3; }
echo "J6_GEOM_OK NW=$NW BID=$BID0 T0T1_WORDS=5,53,54${WEXTRA:+,$WEXTRA}"

echo "### PHASE pre_snapshot $(date +%s.%N)  NW=$NW"
bash "$S" full "${TAG}_pre" || { echo "TCPREG_ABORT pre_snapshot"; exit 1; }

rm -f "$PCAP"
# ④ timeout = SECS+4 (< 本脚本总时长 ⇒ 与下一跑天然隔离); PID 记录供收尾显式 kill (双保险)
( timeout $((SECS+4)) tcpdump -i enp1s0f1np1 -s 96 -w "$PCAP" "tcp and host 192.168.100.2" >/tmp/tcpdump_${TAG}.log 2>&1 & echo $! >/tmp/tcpdump_${TAG}.pid )
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
bash "$S" snap "${TAG}_t0" 5 53 54 $WEXTRA || { echo "TCPREG_ABORT t0_snapshot"; exit 1; }
"$BIN" --host 192.168.100.2 --port 8080 --seconds "$SECS" $EXTRA
echo "SRC_RC=$? $(date +%s.%N)"
echo "### PHASE t1_snapshot $(date +%s.%N)"
bash "$S" snap "${TAG}_t1" 5 53 54 $WEXTRA || { echo "TCPREG_ABORT t1_snapshot"; exit 1; }
# ④ 收尾显式 kill tcpdump (timeout 之外的双保险; 不再让尾巴跨到下一跑)
kill "$(cat /tmp/tcpdump_${TAG}.pid 2>/dev/null)" 2>/dev/null
sleep 2

echo "### PHASE post_snapshot $(date +%s.%N)"
bash "$S" full "${TAG}_post" || { echo "TCPREG_ABORT post_snapshot"; exit 1; }

sleep 1
echo "### PHASE ping $(date +%s.%N)"
ping -c 3 -i 0.2 -W 1 192.168.100.2 2>/dev/null | tail -2 | tr '\n' ' '; echo

wc -c "$PCAP"
T_END=$(date +%s.%N)
echo "J6META_T_END_EPOCH=$T_END J6META_T_END_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ) J6META_DUR_S=$(awk -v a="$T_START" -v b="$T_END" 'BEGIN{printf "%.3f", b-a}')"
echo "PACE_BPS=$PACE J6META_BOARD_BID_END=$(brd 0x04)"
echo "TCPREG_J6_DONE"
