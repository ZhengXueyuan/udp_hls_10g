#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""patch_mut_clearothers.py -- TL 裁定①(b) 的**分离实验**用诊断变异:
   只撤 `cfg_up` 对 `epoch / snd_una_prev / rto_pend / rto_timer` 的清位 (= 候选②),
   **保留** 对 `whi_r` / `fin_sent_r` / `rst_sent_r` / `fin_retx_pend` 的清位 (底线语义).
   两分支各一处 => 声明命中数 2.  这不是门臂 (不进 run_tx_ovl_gate.bat 的契约), 仅供诊断."""
import os, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
HERE = os.path.dirname(os.path.abspath(__file__))
MK = os.path.join(HERE, "mk_mut_tx.py")
t = open(MK, encoding="utf-8").read()

ADD = r'''
# ---- 诊断 (TL 裁定①(b) 分离实验): 只撤 cfg_up 的**其它**清位, 保留 whi_r 清位 ----
#   用途 = 把 "PS j9/j6 是不是由 cfg_up 的其它清位 (rto_pend/rto_timer/epoch) 造成" 分离掉.
#   ⚠️ 不是门臂: 它故意破坏 persist 状态机的前提 (quiet 例程靠 cfg_up 清 rto_pend),
#      预期长出别的红; 判读只看 **j9/j6 是否变化**.
add("mut_ghost_noclearothers", [(
    "                epoch[cfg_up_id]        <= 4'd0;\n"
    "                snd_una_prev[cfg_up_id] <= 32'd0;\n"
    "                rto_pend[cfg_up_id]     <= 1'b0;\n"
    "                rto_timer[cfg_up_id]    <= 21'd0;\n",
    "                // DIAG (mut_ghost_noclearothers): 撤 epoch/snd_una_prev/rto_pend/rto_timer 清位\n",
    2)], "DIAG 撤 cfg_up 的'其它'清位 (保留 whi_r) => 分离候选②")
'''
if "mut_ghost_noclearothers" in t:
    print("already present")
else:
    # 插到 "def norm(" 之前 (与既有变异同区, 保证在 main() 之前注册)
    anchor = "def norm(s):"
    assert t.count(anchor) == 1
    t = t.replace(anchor, ADD.strip() + "\n\n\n" + anchor)
    open(MK, "w", encoding="utf-8", newline="\n").write(t)
    print("WROTE mk_mut_tx.py (added diagnostic mutant)")
