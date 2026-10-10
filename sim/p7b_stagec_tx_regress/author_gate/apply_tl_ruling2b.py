#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply_tl_ruling2b.py -- apply_tl_ruling2.py 的补打 (两处锚点句尾是全角 '。', 上一版写成半角 '.').
   TB-2 = RETXFIX jump 登记;  RTL-1 = else 支镜像无判据登记.  CRLF 保持."""
import os, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
TB = os.path.join(ROOT, "tb", "tb_tcp_tx_ovl.v")
RTL = os.path.join(ROOT, "rtl", "tcp_tx_frame.v")
NL = "\r\n"
E = []

E.append(("TB-2 jump registry", TB, (
"            //   M-K2 变体 (只撤跳写) 确定性命中; 全窗排空 (==) / F1 越顶 (>) 均合法。" + NL +
"            if ((u_tcb.snd_nxt_r[j9_conn] - rep_hi_w) >= 32'h8000_0000) begin"),
(
"            //   M-K2 变体 (只撤跳写) 确定性命中; 全窗排空 (==) / F1 越顶 (>) 均合法。" + NL +
"            // ⚠️ 登记 (TL 裁定①同批, 2026-10-10) —— **本判据在本 TB 构造下不可判**: 实测那条红" + NL +
"            //   (@342415 `snd_nxt=0004e59c < retx_hi=0004ebb9`; GDBG: `ring_hi=00000000 ovf=1" + NL +
"            //   rest=0 drain=1`) 与 `e_ghost` 的两条假阳性**同源** = TB episode `cfg_up` 非 faithful" + NL +
"            //   ⇒ `whi=0 ∧ snd_nxt 高` ⇒ `ring_ovf` 拦住重放 ⇒ 会话秒收尾 ⇒ `snd_nxt` 停在" + NL +
"            //   `snd_una < retx_hi`. **旁证**: M-3 臂 (缺陷语义, 同 `cfg_up` 清位, 但环上界 =" + NL +
"            //   `retx_hi`) 无此红 ⇒ 与本刀\"环上界分离\"耦合, 不是本刀的语义缺陷. 判据一字未改." + NL +
"            if ((u_tcb.snd_nxt_r[j9_conn] - rep_hi_w) >= 32'h8000_0000) begin"), 1))

E.append(("RTL-1 mirror-no-judge registry", RTL, (
"            //   ring 重放帧亦置 `is_data_r=1` ⇒ 仍靠 `!retx_active` 门掉 (会话期无活帧)。" + NL +
"            if ((state == S_DONE) && is_data_r && m_axis_tvalid && m_axis_tready &&"),
(
"            //   ring 重放帧亦置 `is_data_r=1` ⇒ 仍靠 `!retx_active` 门掉 (会话期无活帧)。" + NL +
"            // ⚠️ 登记 (TL 裁定③, 2026-10-10): 本支的 `whi_r` **没有任何判据** —— `e_ghost` 已" + NL +
"            //   限定在 OVL 支 (默认支的推进写落在 **S_DONE = 该帧自己的尾拍**, 帧尾直读会结构性" + NL +
"            //   误报: 实测 arm A `e_ghost=346`, 全部呈 `tail=本帧尾 / whi=上帧尾`)." + NL +
"            //   收益 = 镜像一致性 + 防未来 (设计件 §4.4 本就承认\"镜像对幽灵无门可测\")." + NL +
"            //   ⛔ **若将来本支被启用, 或本支的 `whi_r` 语义/写者被改, 这是它的第一个未覆盖面**" + NL +
"            //   (届时要么补一条 S_DONE 口径的等价判据, 要么维持\"无判据\"并重新登记)." + NL +
"            if ((state == S_DONE) && is_data_r && m_axis_tvalid && m_axis_tready &&"), 1))

bad = 0
for name, path, old, new, hits in E:
    t = open(path, "rb").read().decode("utf-8")
    n = t.count(old)
    print("%s%-34s hits=%d (declared %d)" % ("OK " if n == hits else "!! ", name, n, hits))
    if n != hits:
        bad += 1
        print("   anchor head:", repr(old[:150]))
        continue
    t = t.replace(old, new)
    out = t.encode("utf-8")
    open(path, "wb").write(out)
    print("   WROTE %-22s bytes=%d lines=%d CR=%d CRLF=%d" %
          (os.path.basename(path), len(out), out.count(b"\n"), out.count(b"\r"), out.count(b"\r\n")))
if bad:
    print("*** %d 处不符 ***" % bad)
    sys.exit(1)
print("ALL OK")
