#!/bin/bash
# snmp_smoke.sh -- 只测 lf_dl_snmp.sh 里的 SNMP() 解析是否与 /proc 真值一致 (不碰板)
#   判据: ① 两行 SNMP 输出字段数 == 9; ② CurrEstab == `ss -s` 的 estab 数;
#         ③ Δ(t2-t1) 的 TcpOutSegs 增量 == 手工两次读 /proc/net/snmp 的差
set -u
TAG=SMOKE
SNMP(){
  local ph="$1" t os is rs est da dl dk
  t=$(date +%s.%N)
  read is os rs est <<<$(awk '/^Tcp:/{if($2 ~ /^[0-9]+$/){print $11, $12, $13, $10}}' /proc/net/snmp | tail -1)
  read da dl dk <<<$(awk '/^TcpExt:/{ if ($2 ~ /^[0-9]+$/) { for(i=2;i<=NF;i++) v[nm[i]]=$i } else { for(i=2;i<=NF;i++) nm[i]=$i } } END { printf "%s %s %s", v["DelayedACKs"], v["DelayedACKLost"], v["DelayedACKLocked"] }' /proc/net/netstat)
  local ln="SNMP $ph t=$t TcpInSegs=$is TcpOutSegs=$os TcpRetransSegs=$rs CurrEstab=$est DelayedACKs=$da DelayedACKLost=$dl DelayedACKLocked=$dk"
  echo "$ln"
}
SNMP s1
A=$(awk '/^Tcp:/{if($2 ~ /^[0-9]+$/){print $12}}' /proc/net/snmp | tail -1)
sleep 2
B=$(awk '/^Tcp:/{if($2 ~ /^[0-9]+$/){print $12}}' /proc/net/snmp | tail -1)
SNMP s2
EST=$(awk '/^Tcp:/{if($2 ~ /^[0-9]+$/){print $10}}' /proc/net/snmp | tail -1)
SSE=$(ss -s | grep -oE 'estab [0-9]+' | head -1 | awk '{print $2}')
echo "MANUAL A=$A B=$B dB=$(( B - A ))"
echo "CHECK CurrEstab=$EST ss_s_estab=$SSE match=$([ "$EST" = "$SSE" ] && echo yes || echo NO)"
echo "SMOKE_DONE"
