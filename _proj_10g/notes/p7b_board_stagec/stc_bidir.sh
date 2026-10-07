#!/bin/bash
# stc_bidir.sh -- P7b Stage C 板级轮: **双向** (板 TX = UDP 泛洪数据帧 + TCP 纯 ACK 共用同一条 TX 线)
#   用法: bash stc_bidir.sh <secs> <tag>
#   前置: 板侧 UDP 泛洪**已在跑** (由一次 `p7b_udp_src -> 8081` 触发)。
#   口径: 设计件 §6.3 的双向预算 = 数据帧 193 拍 + 纯 ACK 11 拍 ⇒ 有效载荷带宽按 ~204 拍/帧算。
#         本脚本量的是**板侧 TX 线的帧率与每帧拍数**在"只有下行"与"下行+上行同时"两个窗的差
#         (纯 ACK 由板侧每收一帧上行数据发一个 ⇒ 上行一开，TX 线就被 ACK 抢占)。
#   ⚠️ 本构型 = UDP 数据帧 + TCP ACK (演示 app 单会话限制 ⇒ TCP 数据帧不能与上行并发)；
#      与设计件"TCP 数据 + TCP ACK"在**共用 TX 线**这一点上同构, 但数据帧来源不同 (登记在报告)。
set -u
SECS=${1:-6}; TAG=${2:-STC_BI}
S=/tmp/p7b_biz/p7b_snap.sh
KW="5 8 9 20 22 43 51 52 14 15 0 1 55 58 56"
cd /tmp/p7b_biz || exit 9
echo "### BIDIR_BEGIN $(date -u +%Y-%m-%dT%H:%M:%SZ) TAG=$TAG SECS=$SECS"
echo "BIDIR_META_SCRIPT_MD5=$(md5sum "$0" | cut -d' ' -f1)"
ip route get 192.168.100.2 | head -1
echo "CARRIER=$(cat /sys/class/net/enp1s0f1np1/carrier 2>&1)"
bash "$S" id || { echo "BIDIR_GEOM_FAIL 身份闸"; exit 3; }
echo "### A) UDP-only 基线的第 1 点 (t=0)"
bash "$S" snap "${TAG}_u0" $KW
sleep 2.5
echo "### A) UDP-only 基线的第 2 点 (t=+2.5s)"
bash "$S" snap "${TAG}_u1" $KW
echo "### B) 上行开始 (TCP src ${SECS}s)"
bash "$S" snap "${TAG}_b0" $KW
./p7b_tcp_src_fix --host 192.168.100.2 --port 8080 --seconds "$SECS" > /tmp/src_${TAG}.txt 2>&1 &
SPID=$!
sleep 1
bash "$S" snap "${TAG}_b1" $KW
wait $SPID; echo "SRC_RC=$? $(date +%s.%N)"
bash "$S" snap "${TAG}_b2" $KW
sleep 1
bash "$S" snap "${TAG}_b3" $KW
echo "### SRC_SUM:"; grep -E "SRC_SUM" /tmp/src_${TAG}.txt | tail -1
echo "BIDIR_DONE $(date +%s.%N)"
