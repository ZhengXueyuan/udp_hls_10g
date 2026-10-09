#!/bin/bash
# tcpreg_j6.sh -- J6/J15 TCP 上行 A/B 测量 (peer -> board, port 8080)
# ⭐ 2026-10-07 Stage C 板级轮副本 j6_stagec.sh: 种子 = p7b_board_stagea/j6_stagea.sh
#    md5(c6b27b1bba00d0535bdd8aeb28471c88); 种子的 STALE 注释写 '默认 = 63 字 / BID 9';
#    本副本**唯一改动** = 几何默认 9 -> 0xA。
#    ⛔ 原句保留在下方 (BID 9 = P7B-WU 二轮 = Build 2 的历史口径)。
#   与 Stage 1 S1.0a / Stage 2 §10.5.1 同工具同参数: p7b_tcp_src --port 8080 --seconds 6
#   同时抓: 板侧快照 pair (pre/post) + 双向 pcap (窗口轨迹) + ss -ti 采样 + ping
# 用法: bash j6_stagea.sh <secs> <pcap> <tag>   # PACE=<bytes/s> 选 pacing (0 = 不限速); BIN=<路径> 选被测二进制
#   ⚠️ 本件 = tcpreg_j6.sh (md5 见 J6META_SCRIPT_MD5) + **仅 BIN 可切换** 3 处 (先例 = p7b_wu_w54/j6_fix.sh):
#      `BIN=${BIN:-./p7b_tcp_src}` / 打 `BIN=`+`BIN_MD5=` / 调用改 `$BIN`。其余逐字未动。
#   ⚠️ 几何: 默认 = **63 字 / BID 0xA** (P7b Stage C, 现役; ⛔ 种子原写 '63 字 / BID 9')。读**旧位流** (BIZ 61 字 / BID 8)
#      必须显式声明 `J6_LEGACY_GEOM=1 NW=61 EXPECT_BID=0x00000008` —— 那一档**读不到 W61/W62**
#      (字表自动退回 5 53 54), 且日志里有 J6_GEOM_LEGACY 醒目行。缺省档下 NW/BID 不符**当场红**。
#   ⛔ 2026-10-10 订正 (构建 C 门同步轮): 上面这句的"默认 = 63 字 / BID 0xA"**已过时** ——
#      现役 = **65 字 / BID 0x17** (构建 C: 快照 63→65, W63/W64 = app_pattern 两个停滞计数)。
#      几何档现在单一来源 = 下方 `GEOM_TIERS` 档表 (旧档全部保留), 失败提示由档表**生成**;
#      原句保留 (它描述的是 Stage C 那一代)。
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
#   ⛔ 2026-10-07 (P7B StB 判据修正轮) **回卷规则 (下游解析器必须遵守)**:
#     板侧**所有计数器都是 32 位**; 12 s 跑窗下, **字节类 >2.863 Gbps (2^32 B/12 s) 必回卷**
#     (实测: `ΔW53_raw = 1,792,146,940` vs 对端 `tx_bytes = 6,087,114,752` —— 出处
#     P7B_BOARD_STAGEB.md §2.3(a))。**因此**:
#       ① 本脚本**不变换读数** —— 只搬**原始寄存器值** (pre/t0/t1/post 四段全窗快照逐字落盘),
#          "原始值必须记录" 这条要求由**这台架的输出格式**保证, 解析器**不许**用打印过的差值顶替;
#       ② 任何 `ΔWxx` 比较 / 比率 / 速率: **先按 k·2^32 还原** (k 由板外 64 位口径或帧数反推),
#          并把 `raw` 与 `k` 一起落表 —— mod 只给余数, 不记 raw 就是让"回卷发生了"静默消失
#          (本工程"判据安静失效"老坑); 解析器清单见 P7B_STAGEB_CRITERIA_FIX.md §①;
#       ③ 时基 `W5`/`W24` 是 156.25 MHz 自由计数 ⇒ **任何 ≥27.487 s 的窗不可判** (回绕周期);
#          本脚本 pre→post 窗 ≈ `SECS+10 s` ⇒ `SECS` 必须 < 17 s。
set -u
SECS=${1:-6}; PCAP=${2:-/tmp/tcpreg.pcap}; TAG=${3:-J6}
S=/tmp/p7b_biz/p7b_snap.sh
T=${P7B_TOOLS:-/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools}
D=/dev/xdma0_user
cd /tmp/p7b_biz || exit 9

# ---- 几何门 (⑦): 只认**显式**几何档, 其余一律拒绝 -------------------------------
#   档表 = 下面 `GEOM_TIERS` (**单一来源**); 新增一代 = 加一行; **旧档一律保留** ⇒ 旧位流仍可测。
#   ⛔ 判据语义 = "声明的几何必须与板侧身份**成对**" —— 档表之外的组合照样 exit 3。
#      加档 ≠ 放闸: 65 字档**不接受** BID 0x11, 63 字档**不接受** BID 0x17 (配错对 ⇒ 读数不可归因)。
#   ⛔ 2026-10-10 (构建 C 门同步轮): 本轮之前门里只列了 61/8 与 63/0x11 两档, 而 `NW` 默认早已
#      随构建抬到 65 ⇒ **默认跑必然 J6_GEOM_FAIL + exit 3** (新位流测不了); 且失败提示里打的
#      是 "要求 NW=63 + EXPECT_BID=0x0000000A" (与实际默认 0x11 自相矛盾 —— 一句话两处过时)。
#      现在: 档表是唯一来源, 失败提示与档位元数据都由它派生。
NW=${NW:-65}
EXPECT_BID=${EXPECT_BID:-0x00000017}   # 2026-10-10 构建 C (65 字; 原 0x00000011 = r6-fix / 更早 0x0000000A = Stage C)
export NW EXPECT_BID        # ⚠️ 必须 export: 取数器 p7b_snap.sh 读的是**它自己的环境**
# 十六进制**大小写归一** (只用于比较, 打印仍用原样; 判据语义零改动 —— 先例 = 下面 geom_gate 块)
norm(){ printf "%s" "$1" | tr "A-F" "a-f"; }
# 档表格式: "NW|BID|WEXTRA|说明"  (WEXTRA 空 = t0/t1 字表退回 5 53 54)
GEOM_TIERS=(
  "65|0x00000017|61 62|构建 C (2026-10-10) 65 字 / BID 0x17"
  "63|0x00000011|61 62|r6-fix (2026-10-08) 63 字 / BID 0x11"
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
# ⛔ 2026-10-07 (P7B StB 判据修正轮): 回卷规则随**每一跑**的 stdout 一起落盘 (下游解析器/复算者必读)
echo "J6META_WRAP_RULE=all_board_cnt_are_32bit; delta_must_be_mod_2^32_with_k_recorded; raw_reads_are_the_snap_words; byte_cnt_wrap_at_2.863Gbps_per_12s; free_cnt_W5_W24_limit_27.487s; ref=P7B_STAGEB_CRITERIA_FIX.md"
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
# ⛔ 2026-10-07 Stage C 二次订正: reg_rw 打**小写** (0x0000000a) 而 EXPECT_BID 写大写
#    ⇒ 原句 `[ "$BID0" != "$EXPECT_BID" ]` 在 BID 含字母的世代**必假红** (板子是对的);
#    比较前两边归一到小写, 判据语义零改动 (打印仍用原样)。
#    ⚠️ 2026-10-10 (构建 C 门同步轮): `norm()` 的**定义**已上移到前面的几何档块 (那里也要用它比
#       档), 这里不再重复定义; 下面第二行原写 "(现役 = 0x00000011 r6-fix)" —— 那是**写死的现役
#       值**, 每换一代就过时一次 ⇒ 改成由档表派生。
if [ "$(norm "$BID0")" != "$(norm "$EXPECT_BID")" ]; then
  echo "J6_GEOM_FAIL 板侧 BID=$BID0 != 声明值 $EXPECT_BID ⇒ 板上不是本台架认的位流 (几何不符) ⇒ 拒绝继续"
  echo "             声明档 = ${GEOM_HIT:-?}; 本台架认的档表 (旧位流按档显式声明 NW/EXPECT_BID):"
  geom_tiers_echo
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
