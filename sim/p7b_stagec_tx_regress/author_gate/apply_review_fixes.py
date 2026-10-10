#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply_review_fixes.py -- 审查后处置 ①(a)/②/③/④/⑤ (全部落在新增的承重注释里).
   ①(a) 撤回 "PS j9/j6 与 e_ghost 假阳性同源" 的机制, 改口径 + 三条候选 + 同位素臂证据
   ②    R5 (豁免的覆盖代价) 写进 e_ghost 登记块
   ③    "板侧结构性不可达" 补未覆盖子类
   ④    6 处行号订正 (tb:1266/1511 · tb:1126-1128 · tb:2627-2630 · rtl:1300 ·
        rtl:2060/2305/2344) + 行号纪律一行
   ⑤    证据换掉 (arm A → V6 变体臂 + arm B 惰性)
   CRLF 保持; 每处声明命中数; 不符即不落盘."""
import os, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
TB = os.path.join(ROOT, "tb", "tb_tcp_tx_ovl.v")
RTL = os.path.join(ROOT, "rtl", "tcp_tx_frame.v")
NL = "\r\n"
E = []

# ---------------- ①(a)+②+③+④+⑤: e_ghost 登记块整体重写 ----------------
old_egh = (
"                    // ⭐ TL 裁定①(c) (2026-10-10): **探询帧 (`is_probe`) 豁免** + 承重登记." + NL +
"                    //   为什么这是\"按帧类划范围\"而不是为变绿放水: 先例 = `J9` 已把探询段显式" + NL +
"                    //   排除出重放覆盖窗口 (本文件 J9 段注释); 且**非探询帧的门限/语义/`tot_red`" + NL +
"                    //   落位一律未动** (豁免只多一个 `!is_probe &&`)." + NL)
new_egh = (
"                    // ⭐ TL 裁定①(c) (2026-10-10): **探询帧 (`is_probe`) 豁免** + 承重登记." + NL +
"                    //   0) 行号纪律 (审查 §② 的订正办法, 免下一轮再犯): 本仓凡引**行号**一律" + NL +
"                    //      **当场现读** (`grep -n` / `sed -n`) 后再落笔 —— 设计件的行号是**它" + NL +
"                    //      那一轮**的, 本刀两次插入注释后整体下移; 本轮审查抓到的 6 处错法" + NL +
"                    //      **一致** = 照抄设计件\"改前\"行号 (无一条指向无关区域). 本登记里的" + NL +
"                    //      行号 = 2026-10-10 **现读**值 (本文件 2706 行版)." + NL +
"                    //   为什么这是\"按帧类划范围\"而不是为变绿放水: 先例 = `J9` 已把探询段显式" + NL +
"                    //   排除出重放覆盖窗口 (本文件 J9 段注释); 且**非探询帧的门限/语义/`tot_red`" + NL +
"                    //   落位一律未动** (豁免只多一个 `!is_probe &&`)." + NL)
E.append(("A1 registry head (+行号纪律)", TB, old_egh, new_egh, 1))

old_a = (
"                    //   ① 假阳性**根因** = TB 的 episode `cfg_up` (tb:1219/1464) **不是 faithful 的" + NL +
"                    //      会话建立**: 它绕过 setup FSM、**不写 TCB `sel=1/2`** ⇒ 造出" + NL +
"                    //      `whi_r = 0 ∧ snd_nxt 高` 的状态 ⇒ 该连**任何**帧 (含探询帧) 帧尾都" + NL +
"                    //      \"越过\" whi. 证据 (GHOST_DBG 原始打印): 两条红均 `PROBE=1` 且" + NL +
"                    //      `whi=00000000` 而 `sndnxt=0004896f / 0004eb98`; 且 `GDBG cfgup @300587" + NL +
"                    //      id=1` 紧邻其后; 该连第一笔活帧刷高水位要到 @300951." + NL)
new_a = (
"                    //   ① 假阳性**根因** = TB 的 episode `cfg_up` (现读 **tb:1266** (`7'd70`) /" + NL +
"                    //      **tb:1511** (E4 `7'd28`)) **不是 faithful 的会话建立**: 它绕过" + NL +
"                    //      setup FSM、**不写 TCB `sel=1/2`** ⇒ 造出 `whi_r = 0 ∧ snd_nxt 高` 的" + NL +
"                    //      状态 ⇒ 该连**任何**帧 (含探询帧) 帧尾都\"越过\" whi. **三条独立证据**:" + NL +
"                    //      (i) GHOST_DBG 原始打印: 两条红均 `PROBE=1` 且 `whi=00000000` 而" + NL +
"                    //          `sndnxt=0004896f / 0004eb98`; `GDBG cfgup @300587 id=1` 紧邻其后;" + NL +
"                    //          该连第一笔活帧刷高水位要到 @300951." + NL +
"                    //      (ii) 审查的**变体臂 V6** (撤 `!is_probe`、其余同 S 臂 + GHOST_DBG) ⇒" + NL +
"                    //          `ghost=2 / reds=6`, 两条打印与 (i) **逐字相同** ⇒ 豁免正打在那两条上." + NL +
"                    //          ⛔ 本处**不再**用 \"arm A `ghost=0`\" 作证据 —— arm A **根本没编本判据**" + NL +
"                    //          (`ifdef TCP_TX_OVL` 之外), 其 REDS 行连 `ghost=` 字段都没有 = 空话;" + NL +
"                    //          豁免\"惰性面\"改用 **arm B**: `-d TCP_TX_OVL` 无 ARM_PERSIST ⇒" + NL +
"                    //          `is_probe ≡ 1'b0` ⇒ `TB_TCP_TX_OVL: OK` / REDS 全 0." + NL +
"                    //      (iii) 审查的**同位素臂 V1/V5** (只撤 `cfg_up` 的 `whi_r` 清位、其余逐字" + NL +
"                    //          不动; V1 = S 配置 / V5 = T 配置) ⇒ `RETXFIX jump` 与 13 条 `seqcont`" + NL +
"                    //          **全部消失** ⇒ 这两族的必要成因 = 清位 ✓." + NL)
E.append(("A2 registry ① + 证据换血", TB, old_a, new_a, 1))

old_b = (
"                    //   ② 该状态**板侧结构性不可达**: 板上 `cfg_up` = `slow_cfg_adp` 的 ADD 收尾," + NL +
"                    //      必先写 TCB `sel=0..6` (含 snd_nxt/snd_una 重基) 才 `ev_up`" + NL +
"                    //      (设计件 §3.4(c) 现核) ⇒ 不存在\"清了 whi 而序号空间没重基\"的窗口." + NL)
new_b = (
"                    //   ② 该状态**板侧结构性不可达** —— ⚠️ **但只关掉\"陈旧数据\"那一半 (审查 §①(2)" + NL +
"                    //      的范围注, 降级采纳)**: 板上 `cfg_up` = `slow_cfg_adp` 的 ADD 收尾, 必先写" + NL +
"                    //      TCB `sel=0..6` (含 snd_nxt/snd_una 重基) 才 `ev_up` (设计件 §3.4(c) 现核)" + NL +
"                    //      ⇒ 不存在\"清了 whi 而序号空间没重基\"的窗口." + NL +
"                    //      ⛔ **未覆盖的子类 (如实登记)**: \"**`cfg_up` 清位后、该连还没被任何活帧" + NL +
"                    //      刷过高水位时, 探针帧上线**\" —— 本 TB 实测的假阳性正是这一形态; 板上是否" + NL +
"                    //      可达 = **未证** (探针武装需\"有在飞/被阻塞\" ⇒ 【推断】多半不可达, 但**无" + NL +
"                    //      读数、无源码论证**) ⇒ 它只影响 **TB 仪器的假阳性率**, **不是板级缺陷**" + NL +
"                    //      (**未观测到 ≠ 不存在**)." + NL)
E.append(("A3 registry ② 范围限定", TB, old_b, new_b, 1))

old_c = (
"                    //      `ack_first` 只在建连路径写, tb:1085-1087), 否则会给板子喂\"高于 snd_nxt 的" + NL +
"                    //      陈旧 ACK\" = 设计件 §2-A2 的 **P4d 死锁面**; 且会把 conn1 的 `snd_nxt` 在" + NL +
"                    //      episode 中途改掉 ⇒ 直接撞 `PS j3` (tb:2580 \"探询序列内 snd_nxt 逐位不变\")." + NL)
new_c = (
"                    //      `ack_first` 只在建连路径写, 现读 **tb:1126-1128**), 否则会给板子喂\"高于" + NL +
"                    //      snd_nxt 的陈旧 ACK\" = 设计件 §2-A2 的 **P4d 死锁面**; 且会把 conn1 的" + NL +
"                    //      `snd_nxt` 在 episode 中途改掉 ⇒ 直接撞 `PS j3` (现读 **tb:2627-2630**" + NL +
"                    //      \"探询序列内 snd_nxt 逐位不变\")." + NL)
E.append(("A4 registry ③ 行号", TB, old_c, new_c, 1))

old_d = (
"                    //   ④ 将来若要收紧 (= 撤掉本豁免) 的最小实验: 给 episode 加\"建连同形\"三步" + NL +
"                    //      (写 `sel=2` → `sel=1` → 脉冲 `cfg_up`, 值 = `isn[conn]`; 对齐 setup FSM" + NL +
"                    //      4'd0/4'd1 的次序) **并且**同步重基对端模型 (`peer_rcv[conn] <= isn+1;`" + NL +
"                    //      `exp_new[conn] <= isn+1; ack_first[conn] <= 1'b1;`) ⇒ 再看 `PS j3` 是否仍绿:" + NL +
"                    //      绿 ⇒ 可撤豁免; 红 ⇒ 维持豁免 (并把这 13 条 seqcont 的归属一并重判)." + NL)
new_d = (
"                    //   ④ 将来若要收紧 (= 撤掉本豁免) 的最小实验: 给 episode 加\"建连同形\"三步" + NL +
"                    //      (写 `sel=2` → `sel=1` → 脉冲 `cfg_up`, 值 = `isn[conn]`; 对齐 setup FSM" + NL +
"                    //      现读 **tb:1094-1117** 的 4'd0/4'd1 次序) **并且**同步重基对端模型" + NL +
"                    //      (`peer_rcv[conn] <= isn+1; exp_new[conn] <= isn+1; ack_first[conn] <= 1'b1;`)" + NL +
"                    //      ⇒ 再看 `PS j3` 是否仍绿: 绿 ⇒ 可撤豁免; 红 ⇒ 维持豁免" + NL +
"                    //      (并把这 13 条 `seqcont` 的归属一并重判)." + NL +
"                    //   ⭐ ⑤ **残留 R5 = 本豁免的覆盖代价 (审查实测, 已升 R5)**: 豁免按**帧类**划" + NL +
"                    //      范围 ⇒ 它同样放过\"**探针类**的真幽灵帧\". 实测: **M-3 臂带豁免 `ghost=25`**" + NL +
"                    //      vs **撤豁免 `30`** ⇒ **削掉 5 条** (该臂 25 条全在 conn3 = TB 从不开窗的" + NL +
"                    //      连接 ⇒ 被削的 5 条属探针类). 后果口径: ① **不影响\"达成\"证据** —— M-3 的" + NL +
"                    //      红分解仍成立 `25+3+1+1 = 30` (审查独立验证) ⇒ `e_ghost ∈ tot_red` 仍被证到;" + NL +
"                    //      且真内容红 `payload=3 / seqcont=1` 与 `PS j8` 一字未变. ② 若将来要收回这" + NL +
"                    //      5 条覆盖, 最小实验 = 在**缺陷语义臂**上关掉 `is_probe` 豁免 (V6 构造 + M-3" + NL +
"                    //      的 RTL), 直读 `ghost` 计数." + NL)
E.append(("A5 registry ④ + R5", TB, old_d, new_d, 1))

# ---------------- ①(a): PS j9/j6 登记改口径 ----------------
old_ps = (
"            // ⚠️ 登记 (TL 裁定①同批, 2026-10-10) —— **j9/j6 在本 TB 构造下不可判** (与 `e_ghost`" + NL +
"            //   两条假阳性同源): 实测 `Δstat_retx=21 > 注入=17` 与 `j6=1` 都出现在同一段" + NL +
"            //   `whi=0 ∧ snd_nxt 高` 的窗口里 —— 该状态下重放被 `ring_ovf` 结构性关掉 ⇒" + NL +
"            //   未确认区间永不重传 ⇒ RTO 反复 ⇒ 多出 4 次回卷 / 探询相位偏移. **旁证**: M-3 臂" + NL +
"            //   (同 `cfg_up` 清位、环上界 = `retx_hi`) **无**此两红. 判据一字未改." + NL)
new_ps = (
"            // ⚠️ 登记 (TL 裁定①同批, 2026-10-10) —— **j9/j6 在本 TB 构造下不可判**;" + NL +
"            //   ⛔ **\"与 `e_ghost` 假阳性同源 (`whi=0 ∧ snd_nxt 高` ⇒ `ring_ovf` 拦重放 ⇒ RTO" + NL +
"            //   反复)\"这条机制已被同位素臂否掉 ⇒ 撤回 (审查 §⑥)**: 同位素臂 (只撤 `cfg_up`" + NL +
"            //   的 `whi_r` 清位、其余逐字不动) ⇒ `RETXFIX jump` 与 13 条 `seqcont` **消失**," + NL +
"            //   但 **`PS j9`/`PS j6` 不消失** (V1 臂 = S 配置: `reds=3` = `payload 1 + PS j9 +" + NL +
"            //   PS j6`; V5 臂 = T 配置: `reds=9`, 含 `PS j9`) ⇒ 且 **`j9` 在 T 臂缺席、却在 V5" + NL +
"            //   出现** ⇒ 同源说不成立." + NL +
"            //   ⇒ **现口径 = 本刀在 persist 臂引入的新红 (改前两臂 PRE1/PRE2 都无 j9/j6)、" + NL +
"            //   归因未定位**; 三条候选: ① `ring_restore` 的**延迟洞读** (= 残留 **R2** 的" + NL +
"            //   可观测面) ② TB `cfg_up` 的**其它**清位 (`rto_pend/rto_timer/epoch` —— 落笔时" + NL +
"            //   **未分离**; 分离实验 = 诊断臂 `mut_ghost_noclearothers`, 见 author_gate/) ③ persist" + NL +
"            //   FSM 相位漂移. 判据一字未改; 本 TB 构造下**不可判** (不写\"已收口\", 不写\"不是缺陷\")." + NL)
E.append(("A6 PS j9/j6 改口径", TB, old_ps, new_ps, 1))

# ---------------- ④: RTL 两条行号 ----------------
old_r1 = "    //   ctrl_seq = rb_snd_nxt (:1264) ⇒ seq 下漂 ⇒ spurious FIN (本文件 :2003-2007 逐字警告)." + NL
new_r1 = ("    //   ctrl_seq = rb_snd_nxt (现读 :1300) ⇒ seq 下漂 ⇒ spurious FIN" + NL +
          "    //   (本文件现读 :2060 / :2305 / :2344 三处逐字警告)." + NL)
E.append(("C1 rtl 行号 (ctrl_seq/spurious)", RTL, old_r1, new_r1, 1))

old_r2 = ("            // ⚠️ 登记 (TL 裁定③, 2026-10-10): 本支的 `whi_r` **没有任何判据** —— `e_ghost` 已" + NL)
new_r2 = ("            // ⚠️ 登记 (TL 裁定③, 2026-10-10; 本登记块 = **:2182-2187** (6 行) 现读, `if` 在" + NL +
          "            //   :2188-2189、写值在 :2190): 本支的 `whi_r` **没有任何判据** —— `e_ghost` 已" + NL)
E.append(("C2 rtl 裁定③ 范围行号", RTL, old_r2, new_r2, 1))

bad = 0
for name, path, old, new, hits in E:
    t = open(path, "rb").read().decode("utf-8")
    n = t.count(old)
    print("%s%-34s hits=%d (declared %d)" % ("OK " if n == hits else "!! ", name, n, hits))
    if n != hits:
        bad += 1
        print("   anchor head:", repr(old[:130]))
        continue
    t = t.replace(old, new)
    out = t.encode("utf-8")
    open(path, "wb").write(out)
    print("   WROTE %-20s bytes=%d lines=%d CR=%d CRLF=%d" %
          (os.path.basename(path), len(out), out.count(b"\n"), out.count(b"\r"), out.count(b"\r\n")))
if bad:
    print("*** %d 处不符 => 未落盘的那些见上 ***" % bad)
    sys.exit(1)
print("ALL OK")
