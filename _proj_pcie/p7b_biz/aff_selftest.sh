#!/bin/bash
# aff_selftest.sh -- p7b_affinity.h 的板外自检 (不发起任何真实连接)
#   用法(对端机): bash /tmp/aff_selftest/aff_selftest.sh
set -u
cd /tmp/p7b_biz || exit 9
run() {                       # run <标签> <命令...>
  local tag="$1"; shift
  echo "### CASE $tag"
  echo "### CMD $*"
  "$@" >/tmp/aff_selftest/o.txt 2>/tmp/aff_selftest/e.txt
  local rc=$?
  echo "### RC $rc"
  echo "--- STDOUT"
  cat /tmp/aff_selftest/o.txt
  echo "--- STDERR"
  cat /tmp/aff_selftest/e.txt
  echo "### ENDCASE $tag"
}
mkdir -p /tmp/aff_selftest
echo "### HOST $(hostname) $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "### NPROC $(nproc) ONLINE $(cat /sys/devices/system/cpu/online)"
echo "### SIBLINGS $(for c in 0 1 2 3 4 5 6 7; do printf '%s=%s ' $c "$(cat /sys/devices/system/cpu/cpu$c/topology/thread_siblings_list)"; done)"

run A_help_auto      ./p7b_tcp_sink --help
run B_selftest_auto  ./p7b_tcp_sink --selftest
run C_core999        ./p7b_tcp_sink --core 999 --help
run D_core8          ./p7b_tcp_sink --core 8 --help
run E_nopin          ./p7b_tcp_sink --no-pin --help
run F_taskset3       taskset -c 3 ./p7b_tcp_sink --help
run G_env_core5      env PIN_CORE=5 ./p7b_tcp_sink --help
run H_env_rule_none  env PIN_RULE=none ./p7b_tcp_sink --help
run I_env_rule_auto  env PIN_RULE=auto ./p7b_tcp_sink --help
run J_iface_bogus    env PIN_NIC_IFACE=bogus0 ./p7b_tcp_sink --help
run K_rule_bogus     env PIN_RULE=bogus ./p7b_tcp_sink --help
run L_strip_src      ./p7b_tcp_src --no-pin --help
run M_strip_mid      ./p7b_udp_src --host 127.0.0.1 --no-pin --port 1 --help
run N_nopin_and_core ./p7b_tcp_sink --no-pin --core 5 --help
run O_help_all       sh -c 'for n in p7b_tcp_sink p7b_tcp_src p7b_udp_src p7b_tcp_src_fix p7b_tcp_sink_rate p7b_tcp_src_rate; do ./$n --help >/tmp/aff_selftest/h_$n.txt 2>&1; echo "HELP_RC $n=$?"; grep -oE "PIN_CPU=[0-9]+" /tmp/aff_selftest/h_$n.txt; grep -oE "PIN_GETCPU_END=[0-9]+" /tmp/aff_selftest/h_$n.txt; grep -oE "PIN_RULE=[a-z-]+" /tmp/aff_selftest/h_$n.txt; grep -oE "PIN_ALLOWED_MASK=[0-9a-f]+" /tmp/aff_selftest/h_$n.txt; done'
# ⭐ 判据口径自检: "PIN_CPU 是数值 <=> 真绑了核" 必须在两个方向上都被验证
run P_naive_grep     sh -c '
for n in p7b_tcp_sink p7b_tcp_src p7b_udp_src p7b_tcp_src_fix p7b_tcp_sink_rate p7b_tcp_src_rate; do
  a=$(./$n --help); b=$(./$n --no-pin --help)
  echo "NAIVE $n pinned=[$(printf %s "$a" | grep -oE "PIN_CPU=[0-9]+" || echo NO_MATCH)] nopin=[$(printf %s "$b" | grep -oE "PIN_CPU=[0-9]+" || echo NO_MATCH)]"
  echo "      pinned_start=[$(printf %s "$a" | grep -oE "PIN_GETCPU_START=[0-9]+")] pinned_end=[$(printf %s "$a" | grep -oE "PIN_GETCPU_END=[0-9]+")] nopin_unpinned=[$(printf %s "$b" | grep -oE "UNPINNED=[0-9]+")] nopin_end=[$(printf %s "$b" | grep -oE "PIN_GETCPU_END=[0-9]+")]"
done'
# ⭐ 失败分支负对照: 运行中被**外部改核** => PIN_GETCPU_END != PIN_CPU => 醒目错误 + _exit(2)
#    (只走 127.0.0.1 回环, 不碰板子/不碰 10G 口; 对端机上的一个假监听器)
#    ⚠️ Q 需要一个回环连接 (不是 --help 路径)。SKIP_NET=1 时整段跳过 (给"不发任何连接"的
#    会话留的口子); 它本来就不碰板子/10G 口, 只是形式上会 connect() 一次 127.0.0.1。
if [ "${SKIP_NET:-0}" = "1" ]; then
  echo "### CASE Q_end_mismatch SKIPPED (SKIP_NET=1)"
else
echo "### CASE Q_end_mismatch"
python3 - <<'PYEOF' &
import socket, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 18080)); s.listen(1)
c, _ = s.accept(); time.sleep(6); c.close(); s.close()
PYEOF
sleep 0.6
./p7b_tcp_sink --host 127.0.0.1 --port 18080 --conns 1 --seconds 25 \
  >/tmp/aff_selftest/end_mm.out 2>/tmp/aff_selftest/end_mm.err &
SPID=$!
sleep 1.5
echo "### Q BEFORE_REPIN $(taskset -pc $SPID 2>&1)"
taskset -pc 2 $SPID
sleep 0.3
echo "### Q AFTER_REPIN $(taskset -pc $SPID 2>&1)"
wait $SPID; echo "### RC_Q $?"
echo "--- STDOUT"; cat /tmp/aff_selftest/end_mm.out
echo "--- STDERR"; cat /tmp/aff_selftest/end_mm.err
echo "### ENDCASE Q_end_mismatch"
fi

# ===========================================================================
# F1/F2/F3 自检 (2026-10-08 对抗审查反例的固定回归; 全部 --help 路径, 不发任何连接)
# ===========================================================================
echo "### F1_CHECKS  --core/PIN_CORE 严格解析 (F1): 6 个反例全 RC=2, 正例 RC=0 且 PIN_CPU=5"
for a in 4294967296 2147483648 +1 0x5 5abc; do
  ./p7b_tcp_sink --core "$a" --help >/dev/null 2>&1; echo "CHECK_F1 --core '$a' RC=$? expect=2"
done
./p7b_tcp_sink --core "" --help >/dev/null 2>&1; echo "CHECK_F1 --core '' RC=$? expect=2"
env PIN_CORE=4294967296 ./p7b_tcp_sink --help >/dev/null 2>&1; echo "CHECK_F1 PIN_CORE=4294967296 RC=$? expect=2"
./p7b_tcp_sink --core 5 --help >/dev/null 2>&1; echo "CHECK_F1 --core 5 RC=$? expect=0"
./p7b_tcp_sink --core 999 --help >/dev/null 2>&1; echo "CHECK_F1 --core 999 (不在线) RC=$? expect=2"

echo "### F2_CHECKS  探针退化必须响亮 (F2): PIN_RULE 带后缀 + PIN_DEGRADED 非 none"
echo "CHECK_F2 healthy  $(./p7b_tcp_sink --help 2>/dev/null | grep -oE 'PIN_RULE=[a-z-]+ PIN_DEGRADED=[a-z+]+')"
echo "CHECK_F2 nic_deg  $(env PIN_NIC_IFACE=lo ./p7b_tcp_sink --help 2>/dev/null | grep -oE 'PIN_RULE=[a-z-]+ PIN_DEGRADED=[a-z+]+')"
echo "CHECK_F2 nopin    $(./p7b_tcp_sink --no-pin --help 2>/dev/null | grep -oE 'PIN_RULE=[a-z-]+ PIN_DEGRADED=[a-z+]+')"
echo "CHECK_F2 nic_excl_health=$(./p7b_tcp_sink --help 2>/dev/null | grep -oE 'PIN_NIC_EXCLUDED=[^ ]+') nic_excl_deg=$(env PIN_NIC_IFACE=lo ./p7b_tcp_sink --help 2>/dev/null | grep -oE 'PIN_NIC_EXCLUDED=[^ ]+')"
echo "CHECK_F6 PIN_AVOID 命中数 (期望 0)=$(./p7b_tcp_sink --help 2>/dev/null | grep -c PIN_AVOID || true)"

echo "### F3_CHECK  own-first: 期望 PIN_TUPLE_ORDER=own_sib_t 且 (本机) PIN_CPU=5"
./p7b_tcp_sink --help 2>/dev/null | head -1 | grep -oE 'PIN_CPU=[0-9]+ .*PIN_TUPLE_ORDER=[a-z_]+' | sed 's/^/CHECK_F3 /'

echo "### F9_CHECK  周期行尾的 CPU_FREQ_KHZ 需要**真跑一次**(--help 出不来周期行)"
echo "### 专用仪器 = /tmp/p7b_afftest/f9_loopback_check.sh (回环口: sink 的 SINK_CONN / src 的 SRC_T / udp_src 的 UDP_T 各打一行, 不碰板子)"

echo "### ALLDONE $(date -u +%Y-%m-%dT%H:%M:%SZ)"
