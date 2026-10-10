#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mk_snmp_patch.py -- 从 lf_dl.base.sh (对端 /tmp/p7b_biz/lf_dl.sh 的逐字副本, md5 8c8301aa...)
   生成 lf_dl_snmp.sh = 原文 + **只在 4 处插入** /proc/net/snmp 独立分母取样 (L 的独立分母)。

   插入点 (逐字锚点, 命中数必须 == 1, 否则硬失败):
     ① h2d(){ ... } 之后  -> SNMP() 函数 + 连续采样器
     ② `### PHASE pre_snapshot` 块  -> SNMP pre_a (触发前) / SNMP pre_b (读完后)
     ③ `### PHASE post_snapshot` 块 -> SNMP post_a (触发前) / SNMP post_b (读完后) + kill 采样器
     ④ `### PHASE nic_pre` 之前     -> SNMP idle0 / sleep N / SNMP idle1 (背景率见证)
   其余**一字不改** (由 diff 自证)。
"""
import hashlib
import sys

BASE = sys.argv[1] if len(sys.argv) > 1 else "_tools/lf_dl.base.sh"
OUT = sys.argv[2] if len(sys.argv) > 2 else "_tools/lf_dl_snmp.sh"

src = open(BASE, encoding="utf-8", newline="").read()
BASE_MD5 = hashlib.md5(src.encode("utf-8")).hexdigest()

SNMP_FN = r'''
# =====================================================================
# ⭐ 板级二轮 (2026-10-10) 插入段 A: 对端内核独立计数 (L 的独立分母)
#   来源: /proc/net/snmp 的 `Tcp:` 行 (InSegs/OutSegs/RetransSegs/CurrEstab)
#         + /proc/net/netstat 的 `TcpExt:` 行 (DelayedACKs/DelayedACKLost/DelayedACKLocked)
#   ⚠️ 口径 = **全系统** (内核不按连接给) ⇒ 必须配 `ss -s` 与 idle 背景率见证;
#      其它 TCP 流量 = 我方的 ssh 会话 (wlp6s0, 本跑期间只承载本脚本 stdout).
#   字段位次自证: $10=CurrEstab 与 `ss -s` 的 estab 数一致 (2026-10-10 已核).
# =====================================================================
SNMP(){   # SNMP <phase>  —— 点采样 (写 stdout + /tmp/snmp_${TAG}.log)
  local ph="$1" t os is rs est da dl dk n so
  t=$(date +%s.%N)
  read is os rs est <<<$(awk '/^Tcp:/{if($2 ~ /^[0-9]+$/){print $11, $12, $13, $10}}' /proc/net/snmp | tail -1)
  read da dl dk <<<$(awk '/^TcpExt:/{ if ($2 ~ /^[0-9]+$/) { for(i=2;i<=NF;i++) v[nm[i]]=$i } else { for(i=2;i<=NF;i++) nm[i]=$i } } END { printf "%s %s %s", v["DelayedACKs"], v["DelayedACKLost"], v["DelayedACKLocked"] }' /proc/net/netstat)
  # ⭐ sshd 侧 per-socket segs_out 合计 = **非测量 TCP 流量的直接测量** (本跑 ssh 只承载本脚本 stdout)
  read n so <<<$(ss -tinm '( sport = :22 )' 2>/dev/null | awk '/segs_out:/{n++; if (match($0,/segs_out:[0-9]+/)) s+=substr($0,RSTART+9,RLENGTH-9)} END{printf "%d %d", n+0, s+0}')
  local ln="SNMP $ph t=$t TcpInSegs=$is TcpOutSegs=$os TcpRetransSegs=$rs CurrEstab=$est DelayedACKs=$da DelayedACKLost=$dl DelayedACKLocked=$dk"
  echo "$ln"
  echo "$ln" >> /tmp/snmp_${TAG}.log
  echo "SNMP_SS $ph t=$t $(ss -s 2>/dev/null | tr '\n' ' ' | tr -s ' ')" >> /tmp/snmp_${TAG}.log
  echo "SNMP_SSH $ph t=$t n_sock=$n ssh_segs_out_sum=$so" | tee -a /tmp/snmp_${TAG}.log
}
SNMPSEQ_START(){  # 连续采样器 (0.5 s; 只写本地文件 => 不产生 SSH 流量)
  ( while :; do
      echo "S $(date +%s.%N) $(awk '/^Tcp:/{if($2 ~ /^[0-9]+$/){print $11, $12}}' /proc/net/snmp | tail -1)"
      sleep 0.5
    done ) > /tmp/snmpseq_${TAG}.log 2>&1 &
  SNMPPID=$!
}
'''

IDLE_BLOCK = '''echo "### PHASE snmp_idle $(date +%s.%N)  (背景率见证: 无连接空闲窗)"
SNMPSEQ_START
SNMP idle0
if [ "${SNMP_IDLE:-1}" = "1" ]; then sleep "${SNMP_IDLE_SECS:-5}"; SNMP idle1; fi
'''

PRE_BLOCK = '''echo "### PHASE pre_snapshot $(date +%s.%N)"
SNMP pre_a
bash "$S" full "${TAG}_pre" || { echo "LF_ABORT pre_snapshot"; exit 1; }
SNMP pre_b
'''

POST_BLOCK = '''echo "### PHASE post_snapshot $(date +%s.%N)"
SNMP post_a
bash "$S" full "${TAG}_post" || { echo "LF_ABORT post_snapshot"; exit 1; }
SNMP post_b
kill $SNMPPID 2>/dev/null
'''

ANCHOR_FN = "h2d(){ [ -n \"$1\" ] && echo $(( $1 )) || echo \"\"; }\n"
ANCHOR_IDLE = 'echo "### PHASE nic_pre $(date +%s.%N)"; NIC pre\n'
ANCHOR_PRE = 'echo "### PHASE pre_snapshot $(date +%s.%N)"\nbash "$S" full "${TAG}_pre" || { echo "LF_ABORT pre_snapshot"; exit 1; }\n'
ANCHOR_POST = 'echo "### PHASE post_snapshot $(date +%s.%N)"\nbash "$S" full "${TAG}_post" || { echo "LF_ABORT post_snapshot"; exit 1; }\n'

for nm, a in [("FN", ANCHOR_FN), ("IDLE", ANCHOR_IDLE), ("PRE", ANCHOR_PRE), ("POST", ANCHOR_POST)]:
    n = src.count(a)
    print("ANCHOR %-5s hits=%d" % (nm, n))
    if n != 1:
        print("PATCH_FAIL 锚点 %s 命中 %d != 1" % (nm, n))
        sys.exit(1)

out = src
out = out.replace(ANCHOR_FN, ANCHOR_FN + SNMP_FN)
out = out.replace(ANCHOR_IDLE, IDLE_BLOCK + ANCHOR_IDLE)
out = out.replace(ANCHOR_PRE, PRE_BLOCK)
out = out.replace(ANCHOR_POST, POST_BLOCK)

open(OUT, "w", encoding="utf-8", newline="").write(out)
OUT_MD5 = hashlib.md5(out.encode("utf-8")).hexdigest()
print("BASE_MD5=%s" % BASE_MD5)
print("OUT_MD5 =%s" % OUT_MD5)
print("BASE_BYTES=%d OUT_BYTES=%d" % (len(src), len(out)))
print("PATCH_OK")
