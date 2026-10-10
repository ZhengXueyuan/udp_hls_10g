#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply_final_registry.py -- 最后一轮登记:
   ①   最后一条分离臂 (M-4 = ring_restore≡0, 两配置) 的结果 + 判读 (候选①成立) 写进 PS j9/j6 登记块
   ②a  13 条 seqcont 成因改成 "cfg_up 清位整体 (whi 且 其它) 的联合效应" + 注明 V5 只测一侧
   ②b  e_ghost ③ 的子类措辞按 TL 定稿收紧 + 干净臂足够 + 仅诊断臂 + 成因【未定】
   ③   设计件 §9.1 R5 行补交叉引用 (§8.2 同名不同物)
   CRLF 保持 (设计件为 LF-native); 命中数不符即不落盘."""
import os, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
TB = os.path.join(ROOT, "tb", "tb_tcp_tx_ovl.v")
DOC = os.path.join(ROOT, "_proj_10g", "notes", "P7B_RETXHI_GHOST_DESIGN.md")
NL = "\r\n"
E = []

# ---- ① 最后一条分离臂 (写进 PS j9/j6 登记块) ----
E.append(("FIN-1 ring_restore 分离臂", TB, (
"            //   ⇒ 两配置下结论一致 ⇒ **候选收敛到 ① / ③, 仍不可判** (不写\"已定位\")." + NL),
(
"            //   ⇒ 两配置下结论一致 ⇒ 候选收敛到 ① / ③." + NL +
"            //   ⭐⭐ **① 的判别臂已做 (2026-10-10, TL 裁定最后一条; 诊断臂 = `mut_ghost_norestore`" + NL +
"            //   (**只**把 `ring_restore` 钉 `1'b0`、其余逐字不动 = 门的 Y 臂同一变异, 此处只作诊断读" + NL +
"            //   `j9/j6`; **不进门的契约**):**" + NL +
"            //     · **S 配置**: HEAD `j9=1 (21>17) / j6=1` → **M-4 臂 `j9=0 / j6=0`** (`reds=49` =" + NL +
"            //       `payload 2 + seqcont 44 + jump 3`; 无任何 PS 族红) ⇒ **`j9/j6` 消失 ⇒ 候选 ①" + NL +
"            //       **成立** (TL 事先定死的判读) = 本刀**预期内**的行为改动: 关掉它就把\"立即发旧字节\"" + NL +
"            //       换回\"延迟洞读\", persist 判据随之变化." + NL +
"            //     · **T 配置**: HEAD `j9=0 / j6=0` (本就缺席) → M-4 臂 `j9=0 / j6=0` ⇒ **该配置对" + NL +
"            //       j9/j6 无判别力** (两侧同号, 与 ① 相容)." + NL +
"            //   ⚠️ **如实附条件 (不许读成\"已完全定位\")**: 两配置的 M-4 臂**轨迹差异极大** (S: seqcont" + NL +
"            //   `0→44`; T: `13→149`) ⇒ 该臂是**大扰动**、不是\"同轨迹 ± 一处改动\"; `j9/j6` 又是" + NL +
"            //   窗口统计型判据 ⇒ 消失**与**去掉 `ring_restore` **相关**, 但\"因果\"只到" + NL +
"            //   【推断·按事先定死的规则判 ①成立】级; 若将来要更硬的因果, 建议的最小实验 = 找一条" + NL +
"            //   `ring_restore` 只在**少量**会话上生效的轨迹 (即让两臂的输出流更接近), 再复读 j9/j6." + NL)
, 1))

# ---- ②a 13 条 seqcont 成因改口径 (写进同块) ----
E.append(("FIN-2 seqcont 联合效应", TB, (
"            //   `PS j6` (=1) ⇒ **候选② 被排除** (该臂 `reds=5`; 另注: 该臂还冒出一条" + NL),
(
"            //   `PS j6` (=1) ⇒ **候选② 被排除** (该臂 `reds=5`; 另注: 该臂还冒出一条" + NL +
"            //   ⭐ **13 条 `seqcont` 的成因订正为\"`cfg_up` 清位整体 (whi **且** 其它) 的联合效应**" + NL +
"            //   (审查 V5 只测了 whi 一侧 ⇒ **结论不矛盾、但不完整**): 本轮的 `RCT` 臂 (保留 whi 清位、" + NL +
"            //   撤其它清位) `seqcont = 0` (T 臂 = 13) ⇒ **撤任意一头都能消掉它们**." + NL)
, 1))

# ---- ②b e_ghost ③ 子类措辞定稿 ----
E.append(("FIN-3 ③ 子类措辞定稿", TB, (
"                    //      (一条 1460 B 数据帧, 其 `whi` 仍是清位后的 0) ⇒ 子类的正确措辞 = \"**该连的" + NL +
"                    //      任何帧** (探针或数据) 落在 `whi` 尚未被活帧刷新的窗口里\"." + NL +
"                    //      ⚠️ **干净臂上未观测到**: S/T 臂 (HEAD RTL) 该窗口内只有探针帧 ⇒ 豁免足够;" + NL +
"                    //      该帧的确切成因 (在飞/bank 残留 vs 推进写被会话挡掉) = **未定** (【未定】)," + NL +
"                    //      本轮未追. ⇒ 若将来在**非诊断臂**上看到非探针的 `e_ghost` 红, 按 §① 的回路重查." + NL),
(
"                    //      (一条 1460 B 数据帧, 其 `whi` 仍是清位后的 0) ⇒ 子类措辞 (TL 定稿) = \"**该连的" + NL +
"                    //      任何帧 (探针 或 数据)** 落在 `whi` 尚未被活帧刷新的窗口里\"." + NL +
"                    //      ⭐ **豁免在干净臂足够**: S/T 臂 (HEAD RTL) `ghost=0` (该窗口内只出现探针帧 ⇒" + NL +
"                    //      豁免全额覆盖) ⇒ **干净臂不需要再扩豁免**." + NL +
"                    //      ⚠️ 那例非探针假阳性**只出现在诊断臂** (刻意破坏 persist 状态机的变体 `mut_ghost_" + NL +
"                    //      noclearothers`); 它的成因 (在飞/bank 残留 vs 推进写被会话挡掉) = **【未定】**, 本轮未追." + NL +
"                    //      ⇒ 若将来在**非诊断臂**上看到非探针的 `e_ghost` 红, 按 §① 的回路重查; `is_probe`" + NL +
"                    //      豁免**不扩到非探针** (TL 维持)." + NL)
, 1))

# ---- ③ 设计件 §9.1 R5 行交叉引用 (只改这一行) ----
t = open(DOC, encoding="utf-8").read()
old_r5 = "实施件登记 = `tb/tb_tcp_tx_ovl.v` 的 `e_ghost` 登记块 ⑤ 条 |"
new_r5 = ("实施件登记 = `tb/tb_tcp_tx_ovl.v` 的 `e_ghost` 登记块 ⑤ 条. ⚠️ **与 §8.2 的 `R5` 同名不同物** "
          "—— 后者 = 板级可复现性未证 |")
n = t.count(old_r5)
print("%s%-34s hits=%d (declared 1)" % ("OK " if n == 1 else "!! ", "FIN-4 doc R5 xref", n))
if n == 1:
    t = t.replace(old_r5, new_r5)
    out = t.encode("utf-8")
    open(DOC, "wb").write(out)
    print("   WROTE %s bytes=%d lines=%d CR=%d CRLF=%d" % (os.path.basename(DOC), len(out), out.count(b"\n"), out.count(b"\r"), out.count(b"\r\n")))
    docok = True
else:
    docok = False

bad = 0
for name, path, old, new, hits in E:
    tt = open(path, "rb").read().decode("utf-8")
    nn = tt.count(old)
    print("%s%-34s hits=%d (declared %d)" % ("OK " if nn == hits else "!! ", name, nn, hits))
    if nn != hits:
        bad += 1
        print("   head:", repr(old[:120]))
        continue
    tt = tt.replace(old, new)
    o = tt.encode("utf-8")
    open(path, "wb").write(o)
    print("   WROTE bytes=%d lines=%d CR=%d CRLF=%d" % (len(o), o.count(b"\n"), o.count(b"\r"), o.count(b"\r\n")))
if bad or not docok:
    print("*** 有处不符 ***")
    sys.exit(1)
print("ALL OK")
