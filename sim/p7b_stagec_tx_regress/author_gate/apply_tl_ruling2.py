#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply_tl_ruling2.py -- TL 第二轮裁定:
   ①(c) e_ghost 加 `is_probe` 豁免 + 承重登记 (①根因 / ②板不可达 / ③为何豁免不修源头 / ④将来收紧的最小实验)
   + 同批登记 `RETXFIX jump` / `PS j9` / `PS j6` = "该 TB 构造下不可判" (含 M-3 旁证)
   ③    else 支 `whi_r` = "镜像无判据" 登记 (写进 RTL 注释)
   ②    seqcont 逐条 trace 钩子 (GHOST_DBG, 不设上限)
   ⚠️ 豁免只覆盖 `is_probe` 帧; 判据门限/语义/tot_red 落位一律不动. CRLF 保持."""
import os, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
TB = os.path.join(ROOT, "tb", "tb_tcp_tx_ovl.v")
RTL = os.path.join(ROOT, "rtl", "tcp_tx_frame.v")
NL = "\r\n"
E = []

# ---------- TB ①(c): 豁免 + 登记 ----------
E.append(("TB-1 e_ghost is_probe exempt + registry", (TB, (
"                    //   变异臂 M-3 (ring_hi := retx_hi) 必须 > 0 ⇒ 有牙.)" + NL +
"                    if ((((fseq + {20'b0, plen}) - u_dut.whi_r[t_conn]) < 32'h8000_0000) &&" + NL +
"                        (((fseq + {20'b0, plen}) - u_dut.whi_r[t_conn]) != 32'd0)) begin"),
(
"                    //   变异臂 M-3 (ring_hi := retx_hi) 必须 > 0 ⇒ 有牙.)" + NL +
"                    // ═══════════════════════════════════════════════════════════════════" + NL +
"                    // ⭐ TL 裁定①(c) (2026-10-10): **探询帧 (`is_probe`) 豁免** + 承重登记." + NL +
"                    //   为什么这是\"按帧类划范围\"而不是为变绿放水: 先例 = `J9` 已把探询段显式" + NL +
"                    //   排除出重放覆盖窗口 (本文件 J9 段注释); 且**非探询帧的门限/语义/`tot_red`" + NL +
"                    //   落位一律未动** (豁免只多一个 `!is_probe &&`)." + NL +
"                    //   ① 假阳性**根因** = TB 的 episode `cfg_up` (tb:1219/1464) **不是 faithful 的" + NL +
"                    //      会话建立**: 它绕过 setup FSM、**不写 TCB `sel=1/2`** ⇒ 造出" + NL +
"                    //      `whi_r = 0 ∧ snd_nxt 高` 的状态 ⇒ 该连**任何**帧 (含探询帧) 帧尾都" + NL +
"                    //      \"越过\" whi. 证据 (GHOST_DBG 原始打印): 两条红均 `PROBE=1` 且" + NL +
"                    //      `whi=00000000` 而 `sndnxt=0004896f / 0004eb98`; 且 `GDBG cfgup @300587" + NL +
"                    //      id=1` 紧邻其后; 该连第一笔活帧刷高水位要到 @300951." + NL +
"                    //   ② 该状态**板侧结构性不可达**: 板上 `cfg_up` = `slow_cfg_adp` 的 ADD 收尾," + NL +
"                    //      必先写 TCB `sel=0..6` (含 snd_nxt/snd_una 重基) 才 `ev_up`" + NL +
"                    //      (设计件 §3.4(c) 现核) ⇒ 不存在\"清了 whi 而序号空间没重基\"的窗口." + NL +
"                    //   ③ 为什么选豁免而不是修源头: 源头修 = 让 episode 的 **6 处** cfg_up 真的重基" + NL +
"                    //      序号空间 (grep `pe_ret <= 7'd` ⇒ pe_ep 1/3/4/5/6/7 全用 7'd70/71 这个" + NL +
"                    //      **共用状态清除例程**) ⇒ 连带必须重基 TB 对端模型 (`peer_rcv`/`exp_new`/" + NL +
"                    //      `ack_first` 只在建连路径写, tb:1085-1087), 否则会给板子喂\"高于 snd_nxt 的" + NL +
"                    //      陈旧 ACK\" = 设计件 §2-A2 的 **P4d 死锁面**; 且会把 conn1 的 `snd_nxt` 在" + NL +
"                    //      episode 中途改掉 ⇒ 直接撞 `PS j3` (tb:2580 \"探询序列内 snd_nxt 逐位不变\")." + NL +
"                    //      ⇒ 超出\"最小等价改动\", 且与 episode 的测试目的 (在**持续连接**上测 persist" + NL +
"                    //      状态机) 冲突. (实施轮: 该判定已作为\"停下报告\"上报并获 TL 采纳.)" + NL +
"                    //   ④ 将来若要收紧 (= 撤掉本豁免) 的最小实验: 给 episode 加\"建连同形\"三步" + NL +
"                    //      (写 `sel=2` → `sel=1` → 脉冲 `cfg_up`, 值 = `isn[conn]`; 对齐 setup FSM" + NL +
"                    //      4'd0/4'd1 的次序) **并且**同步重基对端模型 (`peer_rcv[conn] <= isn+1;`" + NL +
"                    //      `exp_new[conn] <= isn+1; ack_first[conn] <= 1'b1;`) ⇒ 再看 `PS j3` 是否仍绿:" + NL +
"                    //      绿 ⇒ 可撤豁免; 红 ⇒ 维持豁免 (并把这 13 条 seqcont 的归属一并重判)." + NL +
"                    // ═══════════════════════════════════════════════════════════════════" + NL +
"                    if (!is_probe &&" + NL +
"                        (((fseq + {20'b0, plen}) - u_dut.whi_r[t_conn]) < 32'h8000_0000) &&" + NL +
"                        (((fseq + {20'b0, plen}) - u_dut.whi_r[t_conn]) != 32'd0)) begin"), 1)))

# ---------- TB 同批登记: jump judge ----------
E.append(("TB-2 jump registry", (TB, (
"            //   M-K2 变体 (只撤跳写) 确定性命中; 全窗排空 (==) / F1 越顶 (>) 均合法." + NL +
"            if ((u_tcb.snd_nxt_r[j9_conn] - rep_hi_w) >= 32'h8000_0000) begin"),
(
"            //   M-K2 变体 (只撤跳写) 确定性命中; 全窗排空 (==) / F1 越顶 (>) 均合法." + NL +
"            // ⚠️ 登记 (TL 裁定①同批, 2026-10-10) —— **本判据在本 TB 构造下不可判**: 实测那条红" + NL +
"            //   (@342415 `snd_nxt=0004e59c < retx_hi=0004ebb9`; GDBG: `ring_hi=00000000 ovf=1" + NL +
"            //   rest=0 drain=1`) 与 `e_ghost` 的两条假阳性**同源** = TB episode `cfg_up` 非 faithful" + NL +
"            //   ⇒ `whi=0 ∧ snd_nxt 高` ⇒ `ring_ovf` 拦住重放 ⇒ 会话秒收尾 ⇒ `snd_nxt` 停在" + NL +
"            //   `snd_una < retx_hi`. **旁证**: M-3 臂 (缺陷语义, 同 `cfg_up` 清位, 但环上界 =" + NL +
"            //   `retx_hi`) 无此红 ⇒ 与本刀\"环上界分离\"耦合, 不是本刀的语义缺陷. 判据一字未改." + NL +
"            if ((u_tcb.snd_nxt_r[j9_conn] - rep_hi_w) >= 32'h8000_0000) begin"), 1)))

# ---------- TB 同批登记: PS j9 / PS j6 ----------
E.append(("TB-3 PS j9/j6 registry", (TB, (
"            if ((pe_stat1 - pe_stat0) > (pe_req1 - pe_req0)) begin" + NL +
"                tot_red = tot_red + 1; e_ps_side = e_ps_side + 1;"),
(
"            // ⚠️ 登记 (TL 裁定①同批, 2026-10-10) —— **j9/j6 在本 TB 构造下不可判** (与 `e_ghost`" + NL +
"            //   两条假阳性同源): 实测 `Δstat_retx=21 > 注入=17` 与 `j6=1` 都出现在同一段" + NL +
"            //   `whi=0 ∧ snd_nxt 高` 的窗口里 —— 该状态下重放被 `ring_ovf` 结构性关掉 ⇒" + NL +
"            //   未确认区间永不重传 ⇒ RTO 反复 ⇒ 多出 4 次回卷 / 探询相位偏移. **旁证**: M-3 臂" + NL +
"            //   (同 `cfg_up` 清位、环上界 = `retx_hi`) **无**此两红. 判据一字未改." + NL +
"            if ((pe_stat1 - pe_stat0) > (pe_req1 - pe_req0)) begin" + NL +
"                tot_red = tot_red + 1; e_ps_side = e_ps_side + 1;"), 1)))

# ---------- TB ② seqcont trace 钩子 (两处, GHOST_DBG 不设上限) ----------
E.append(("TB-4 seqcont trace (partial)", (TB, (
"                                e_seqcont = e_seqcont + 1;" + NL +
"                                if (e_seqcont < 6)" + NL +
"                                    $display(\"[FAIL] seq partial conn=%0d seq=%h plen=%0d exp=%h @%0d\"," + NL +
"                                             t_conn, fseq, plen, exp_new[t_conn], cyc); end"),
(
"                                e_seqcont = e_seqcont + 1;" + NL +
"`ifdef GHOST_DBG" + NL +
"                                $display(\"GDBGSC kind=partial conn=%0d cyc=%0d fseq=%h plen=%0d exp=%h whi=%h sndnxt=%h snduna=%h ract=%b\", " + NL +
"                                         t_conn, cyc, fseq, plen, exp_new[t_conn]," + NL +
"                                         u_dut.whi_r[t_conn], u_tcb.snd_nxt_r[t_conn]," + NL +
"                                         u_tcb.snd_una_r[t_conn], u_dut.retx_active);" + NL +
"`endif" + NL +
"                                if (e_seqcont < 6)" + NL +
"                                    $display(\"[FAIL] seq partial conn=%0d seq=%h plen=%0d exp=%h @%0d\"," + NL +
"                                             t_conn, fseq, plen, exp_new[t_conn], cyc); end"), 1)))
E.append(("TB-5 seqcont trace (hole)", (TB, (
"                            e_seqcont = e_seqcont + 1;" + NL +
"                            if (e_seqcont < 6)" + NL +
"                                $display(\"[FAIL] seq hole conn=%0d seq=%h plen=%0d exp=%h @%0d\"," + NL +
"                                         t_conn, fseq, plen, exp_new[t_conn], cyc);"),
(
"                            e_seqcont = e_seqcont + 1;" + NL +
"`ifdef GHOST_DBG" + NL +
"                            $display(\"GDBGSC kind=hole conn=%0d cyc=%0d fseq=%h plen=%0d exp=%h whi=%h sndnxt=%h snduna=%h ract=%b\", " + NL +
"                                     t_conn, cyc, fseq, plen, exp_new[t_conn]," + NL +
"                                     u_dut.whi_r[t_conn], u_tcb.snd_nxt_r[t_conn]," + NL +
"                                     u_tcb.snd_una_r[t_conn], u_dut.retx_active);" + NL +
"`endif" + NL +
"                            if (e_seqcont < 6)" + NL +
"                                $display(\"[FAIL] seq hole conn=%0d seq=%h plen=%0d exp=%h @%0d\"," + NL +
"                                         t_conn, fseq, plen, exp_new[t_conn], cyc);"), 1)))

# ---------- RTL ③: 镜像无判据登记 ----------
E.append(("RTL-1 mirror-no-judge registry", (RTL, (
"            //   ring 重放帧亦置 `is_data_r=1` ⇒ 仍靠 `!retx_active` 门掉 (会话期无活帧)." + NL +
"            if ((state == S_DONE) && is_data_r && m_axis_tvalid && m_axis_tready &&"),
(
"            //   ring 重放帧亦置 `is_data_r=1` ⇒ 仍靠 `!retx_active` 门掉 (会话期无活帧)." + NL +
"            // ⚠️ 登记 (TL 裁定③, 2026-10-10): 本支的 `whi_r` **没有任何判据** —— `e_ghost` 已" + NL +
"            //   限定在 OVL 支 (默认支的推进写落在 **S_DONE = 该帧自己的尾拍**, 帧尾直读会结构性" + NL +
"            //   误报: 实测 arm A `e_ghost=346`, 全部呈 `tail=本帧尾 / whi=上帧尾`)." + NL +
"            //   收益 = 镜像一致性 + 防未来 (设计件 §4.4 本就承认\"镜像对幽灵无门可测\")." + NL +
"            //   ⛔ **若将来本支被启用, 或本支的 `whi_r` 语义/写者被改, 这是它的第一个未覆盖面**" + NL +
"            //   (届时要么补一条 S_DONE 口径的等价判据, 要么维持\"无判据\"并重新登记)." + NL +
"            if ((state == S_DONE) && is_data_r && m_axis_tvalid && m_axis_tready &&"), 1)))

bad = 0
for name, (path, old, new, hits) in E:
    t = open(path, "rb").read().decode("utf-8")
    n = t.count(old)
    print("%s%-38s hits=%d (declared %d)" % ("OK " if n == hits else "!! ", name, n, hits))
    if n != hits:
        bad += 1
        print("   anchor head:", repr(old[:120]))
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
