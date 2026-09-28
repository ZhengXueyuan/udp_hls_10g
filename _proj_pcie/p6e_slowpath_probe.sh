#!/bin/bash
#=============================================================================
# p6e_slowpath_probe.sh [轮数] [间隔秒] — 配置+重启后长跑, 专测"慢路径多久失聪、为什么会好"
#   用法: sudo bash /home/a/xdma_test/p6e_slowpath_probe.sh 100 20     (≈33 分钟)
#
#   与 p6e_boot_timeline.sh 的差别 (按两个调查 agent 的建议改的):
#     ① **每轮打足流量**: `ping -c 20 -i 0.05` ⇒ ΔW0 明显 (只 ping 2 包时 ΔW0 被背景流量淹没,
#        分不清"我的包到了没有");
#     ② **记绝对值**: 判 `reset_n`(=PERST#) 抖动/计数归零必须看绝对值, 差值看不出来;
#     ③ **读健康位 W16-W19**: HLS 到底吃没吃字节(W16) / 看门狗复位拍数(W17) /
#        慢 TX 回卷(W18) / 适配器丢帧(W19) —— 这四个是本次扩窗的全部意义;
#     ④ **读 MAC 锚点 W20/W21**: "线上实际发了多少帧" (以前全设计没有这个数);
#     ⑤ **ARP 与路由每轮都记**: 把"主机没发出去"和"板子没回"在同一行里分开 (前者会导致假故障,
#        本工程已因操作失误误判过一次);
#     ⑥ **ping 失败时自动抓一小段包**: 看主机到底发了什么、板子回了什么 (地面真相)。
#
#   ⚠️ 判读要点: 若"T+若干秒 W17 开始涨 + W16 停止增长 + ping 变 0/N"同时发生 ⇒ **HLS 被看门狗
#      打进复位循环** (W17 ÷ 64 ≈ 复位次数)。若 W17 不动而 W16 也不涨 ⇒ HLS 卡在"不吃字节"。
#   ⚠️ 未实现地址/别名: axi_regs 的 ar_word 只有 6 位 ⇒ **地址每 256 字节回绕**, 判据里绝不能挑 ≥0x100。
#=============================================================================
set -u
ROUNDS=${1:-100}
IV=${2:-20}
IFACE=enp3s0
BOARD=192.168.100.2
T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
D=/dev/xdma0_user
LOG=/tmp/p6e_slowpath_probe.log
PING_N=20
exec > >(tee -a "$LOG") 2>&1

W32=$((1<<32))
rd(){ $T/reg_rw $D "$1" w 2>/dev/null | tail -1 | sed 's/.*: *//'; }
snap(){ $T/reg_rw $D 0x18 w 0x1 >/dev/null 2>&1; local i s
        for i in $(seq 1 100); do s=$(rd 0x1c); [ -n "$s" ] || continue
            [ $(( s & 2 )) -ne 0 ] && return 0; sleep 0.01; done; return 1; }
# 读全 24 字 (0x20..0x7C); W[n] 用十进制绝对值
declare -a W
readall(){ local a i=0; for a in 20 24 28 2c 30 34 38 3c 40 44 48 4c 50 54 58 5c 60 64 68 6c 70 74 78 7c; do
             W[$i]=$(( $(rd 0x$a) )); i=$((i+1)); done; }
# 增量 (模 2^32, 抗回绕 —— 931Mbps 下 32 位计数每 ~37s 绕一圈)
dd(){ local d=$(( ($2 - $1) % W32 )); echo $(( d < 0 ? d + W32 : d )); }

# ---------- 主机侧前提 (每轮都查, 把"我没发"和"板子不回"分开) ----------
prep(){
    ip -br addr show "$IFACE" 2>/dev/null | grep -q "192.168.100.1" || {
        ip link set "$IFACE" up 2>/dev/null
        ip addr add 192.168.100.1/24 dev "$IFACE" 2>/dev/null && echo "[setup] 补加 192.168.100.1/24"
    }
    ROUTE=$(ip route get "$BOARD" 2>/dev/null | head -1 | grep -c "$IFACE")
    ARP=$(arp -n 2>/dev/null | grep -c "$BOARD")
}
for i in $(seq 1 30); do lspci -n 2>/dev/null | grep -q '10ee:9034' && break; sleep 2; done
lsmod | grep -qw xdma || { insmod /home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/xdma/xdma.ko; sleep 2; }
[ -e $D ] || { echo "没有 $D ⇒ 观测通道不可用"; exit 1; }

echo "===== 慢路径探针开始 $(date '+%T')  MAGIC=$(rd 0x00) BUILD_ID=$(rd 0x04) ====="
echo "列: t秒 | ping收到 | ARP | 路由 | W0收帧 | ΔW0 | W6交慢路 | ΔW6 | W7HLS发 | W16HLS吃字节 | W17看门狗拍 | W18回卷 | W19适配器丢 | W20MAC发帧 | NICΔRX"
snap; readall
P0=$(cat /sys/class/net/$IFACE/statistics/rx_packets)
T0=$(date +%s); PREV0=${W[0]}; PREV6=${W[6]}; PREVRX=$P0
W16_0=${W[16]}; W17_0=${W[17]}
FIRST_DEAF=""; PREV_PING="-"
for n in $(seq 1 "$ROUNDS"); do
    prep
    GOT=$(ping -c $PING_N -i 0.05 -W 1 "$BOARD" 2>/dev/null | grep -oE '[0-9]+ received' | grep -oE '[0-9]+')
    GOT=${GOT:-0}
    snap; readall
    RX=$(cat /sys/class/net/$IFACE/statistics/rx_packets)
    T=$(( $(date +%s) - T0 ))
    printf "%5d | %2s/%2d | %2s | %2s | %8d | %5d | %8d | %5d | %7d | %10d | %9d | %5d | %7d | %8d | %6d\n" \
        "$T" "$GOT" "$PING_N" "$ARP" "$ROUTE" \
        "${W[0]}" "$(dd $PREV0 ${W[0]})" "${W[6]}" "$(dd $PREV6 ${W[6]})" "${W[7]}" \
        "$(dd $W16_0 ${W[16]})" "$(dd $W17_0 ${W[17]})" "${W[18]}" "${W[19]}" "${W[20]}" "$(dd $PREVRX $RX)"
    PREV0=${W[0]}; PREV6=${W[6]}; PREVRX=$RX
    # ping 第一次从"通"变"不通" ⇒ 记时刻 + 抓一小段包 (地面真相)
    if [ "$GOT" = "0" ] && [ "$PREV_PING" != "0" ] && [ -z "$FIRST_DEAF" ]; then
        FIRST_DEAF=$T
        echo "  ⭐ t=${T}s: ping 从通变不通 (第一次失聪)。抓 4s 包看主机发了什么/板子回了什么:"
        timeout 4 tcpdump -i "$IFACE" -n -e -c 40 arp or icmp 2>/dev/null | sed 's/^/     /'
        echo "     ↑ 若只有 who-has 没有板子的应答 ⇒ 板子不应答 ARP; 若连 who-has 都没有 ⇒ 主机没发"
    fi
    PREV_PING=$GOT
    sleep "$IV"
done
echo "===== 结束 $(date '+%T')  首次失聪时刻: ${FIRST_DEAF:-未出现} 秒 ====="
echo "最终绝对值: W0=${W[0]} W6=${W[6]} W7=${W[7]} W16(HLS吃字节累计)=$(dd $W16_0 ${W[16]}) W17(看门狗拍累计)=$(dd $W17_0 ${W[17]}) W18=${W[18]} W19=${W[19]} W20=${W[20]}"
echo "日志: $LOG"
