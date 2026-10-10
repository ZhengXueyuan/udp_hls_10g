#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply_review_fixes2.py -- ①(b) 分离实验结果的登记 (两处):
   1) PS j9/j6 登记块: 补 "候选② 已由诊断臂排除" 的读数
   2) e_ghost 登记块 ③: 补一条实测细化 (未覆盖子类**不只**探针帧)
   CRLF 保持; 命中数不符即不落盘."""
import os, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
TB = os.path.join(ROOT, "tb", "tb_tcp_tx_ovl.v")
NL = "\r\n"
E = []

E.append(("PS j9/j6 登记 + ①(b) 结果", TB, (
"            //   FSM 相位漂移. 判据一字未改; 本 TB 构造下**不可判** (不写\"已收口\", 不写\"不是缺陷\")." + NL),
(
"            //   FSM 相位漂移. 判据一字未改; 本 TB 构造下**不可判** (不写\"已收口\", 不写\"不是缺陷\")." + NL +
"            //   ⭐ **①(b) 分离实验已做 (2026-10-10, 诊断臂 `mut_ghost_noclearothers`** = 只撤" + NL +
"            //   `cfg_up` 对 `epoch/snd_una_prev/rto_pend/rto_timer` 的清位、**保留** `whi_r` 清位," + NL +
"            //   见 author_gate/)**:** S 配置 ⇒ `PS j9` **仍在** (`Δstat_retx=19 > 注入=15`)、" + NL +
"            //   `PS j6` **仍在** (=1) ⇒ **候选② 被排除** (该臂 `reds=5`; 另注: 该臂还冒出一条" + NL +
"            //   **非探针** ghost, `conn=1 seq=0004eb98 plen=1460 tail=0004f14c whi=00000000 @317084`" + NL +
"            //   —— 见 `e_ghost` 登记块的 ③ 细化); T 配置 (= `RCT` 臂) ⇒ `j9/j6` **仍缺** (与 T 同)" + NL +
"            //   ⇒ 两配置下结论一致 ⇒ **候选收敛到 ① / ③, 仍不可判** (不写\"已定位\")." + NL)
, 1))

E.append(("e_ghost ③ 细化 (非探针假阳性)", TB, (
"                    //      读数、无源码论证**) ⇒ 它只影响 **TB 仪器的假阳性率**, **不是板级缺陷**" + NL +
"                    //      (**未观测到 ≠ 不存在**)." + NL),
(
"                    //      读数、无源码论证**) ⇒ 它只影响 **TB 仪器的假阳性率**, **不是板级缺陷**" + NL +
"                    //      (**未观测到 ≠ 不存在**)." + NL +
"                    //      ⭐ **细化 (实施轮诊断臂实测, 2026-10-10)**: 该未覆盖子类**不只**是探针帧 ——" + NL +
"                    //      `mut_ghost_noclearothers` 臂上出现一条**非探针**假阳性:" + NL +
"                    //      `[FAIL] ghost conn=1 seq=0004eb98 plen=1460 tail=0004f14c whi=00000000 @317084`" + NL +
"                    //      (一条 1460 B 数据帧, 其 `whi` 仍是清位后的 0) ⇒ 子类的正确措辞 = \"**该连的" + NL +
"                    //      任何帧** (探针或数据) 落在 `whi` 尚未被活帧刷新的窗口里\"." + NL +
"                    //      ⚠️ **干净臂上未观测到**: S/T 臂 (HEAD RTL) 该窗口内只有探针帧 ⇒ 豁免足够;" + NL +
"                    //      该帧的确切成因 (在飞/bank 残留 vs 推进写被会话挡掉) = **未定** (【未定】)," + NL +
"                    //      本轮未追. ⇒ 若将来在**非诊断臂**上看到非探针的 `e_ghost` 红, 按 §① 的回路重查." + NL)
, 1))

bad = 0
for name, path, old, new, hits in E:
    t = open(path, "rb").read().decode("utf-8")
    n = t.count(old)
    print("%s%-34s hits=%d (declared %d)" % ("OK " if n == hits else "!! ", name, n, hits))
    if n != hits:
        bad += 1
        print("   head:", repr(old[:120]))
        continue
    t = t.replace(old, new)
    out = t.encode("utf-8")
    open(path, "wb").write(out)
    print("   WROTE bytes=%d lines=%d CR=%d CRLF=%d" % (len(out), out.count(b"\n"), out.count(b"\r"), out.count(b"\r\n")))
if bad:
    print("*** %d 处不符 ***" % bad)
    sys.exit(1)
print("ALL OK")
