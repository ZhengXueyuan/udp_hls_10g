#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""**负彩排**（判据逐处有牙的更强证据; 本目录的小工具, 不属于主脚本链）:
链式 apply 但**故意漏掉末阶段的最后一处 edit** ⇒ 断言必须**恰好红那一处** (不是红一片, 也不是全绿)。
用法:  python neg_rehearse.py [0x1E|0x1F]
"""
import importlib.util
import os
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
spec = importlib.util.spec_from_file_location(
    "rs", os.path.join(os.path.dirname(os.path.abspath(__file__)), "apply_readside_bid1c.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

_raw = (sys.argv[1] if len(sys.argv) > 1 else "1F").strip().upper().replace("0X", "").lstrip("0")
target = next((b for b in m.ALL_BIDS
               if b.upper().replace("0X", "").lstrip("0") == _raw), None)
assert target, "未知 target: %s (支持 %s)" % (_raw, m.ALL_BIDS)
todo = m.stages_to_do(target)
if not todo:
    # ⚠️ **apply 之后**链已空 ⇒ 负彩排"没输入"(不是断言失效)。这里**反演重建**同一内存态:
    #    把末阶段的每条 edit **反向**(new → old) 撤到 overlay 上 (得到 apply 前的树), 再照常
    #    "应用除最后一处以外的全部" ⇒ 与 apply 前那次负彩排等价。
    st = m.chain_for(target)[-1]
    base = {}
    for rel, old, new, n in st[1]:
        p = os.path.join(m.REPO, rel.replace("/", os.sep))
        b, nl = m.rd(p)
        cur = base.get(rel) or b.decode("utf-8")
        new2 = new.replace(chr(10), nl.decode())
        old2 = old.replace(chr(10), nl.decode())
        cnt = cur.count(new2)
        assert cnt == n, ("反演失败(末阶段 new 侧不在盘上): %s %d/%d" % (rel, cnt, n))
        base[rel] = cur.replace(new2, old2)
    print("ℹ️ 链已空 (post-apply) ⇒ **反演重建** apply 前态, 再跑同一套负彩排。")
    todo = [(st[0], st[1], st[2], st[3], st[4])]
    prebase = base
else:
    prebase = None
print("负彩排 target=%s; 阶段 = %s" % (target, [(b, len(e)) for b, e, n, w, u in todo]))
overlay = dict(prebase) if prebase else {}
skipped = None
for bk, edits, nm, w, u in todo:
    for idx, (rel, old, new, n) in enumerate(edits):
        if bk == todo[-1][0] and idx == len(edits) - 1:
            skipped = (bk, rel, old.split(chr(10))[0][:70])
            continue                                  # ⛔ 故意漏掉这一处
        p = os.path.join(m.REPO, rel.replace("/", os.sep))
        b, nl = m.rd(p)
        cur = overlay.get(rel) or b.decode("utf-8")
        old2 = old.replace(chr(10), nl.decode())
        new2 = new.replace(chr(10), nl.decode())
        cnt = cur.count(old2)
        assert cnt == n, (bk, rel, cnt, n)
        overlay[rel] = cur.replace(old2, new2)
print("故意漏掉的 1 处 = %s" % (skipped,))
nw, unimpl = m.stage_nw(target), m.stage_unimpl(target)
fails = m.assert_defaults(nw, target, overlay, unimpl) + m.assert_tables(nw, overlay, unimpl)
print("负彩排 FAIL 条数 = %d" % len(fails))
print("负彩排 FAIL 列表 = %s" % fails)
print("NEG_REHEARSE %s" % ("有牙 (漏一处 ⇒ 恰好那处红)" if len(fails) == 1 else "**没牙/多处红**"))
sys.exit(0 if len(fails) == 1 else 1)
