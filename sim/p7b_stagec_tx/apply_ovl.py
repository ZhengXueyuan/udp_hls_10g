#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply_ovl.py -- 把 sim/p7b_stagec_tx/ovl_branch.v 插入 rtl/tcp_tx_frame.v 的
   `` `ifdef TCP_TX_OVL `` 分支, 并做机器证明。

⚠️ **口径变更 (2026-10-07, 对抗审查 B1/F1 之后)**: 原先的等价规则是
   "宏关预处理输出 == **插入前的纯件**"; 现在 `ring_start` 的 **F1 修复**
   (回绕安全的"正 delta", 防 `retx_hi` 被控制帧预留 +1 越顶 ⇒ 32 位下溢 ⇒ G9 类重放洪水)
   **必须同时落在默认分支** (审查 arm D 实测: 该下溢在今天的生产 RTL 上也已存在)。
   ⇒ 新的等价规则 = "宏关输出 == **插入前纯件 + 这一处已声明的 bugfix**",
   并**逐行打印**这两者之间的差异 (只准是那几行)。

证明:
  P1) 宏关预处理输出 == (纯基线 + F1 fix) 的预处理输出 (逐字节);
  P1b) (纯基线 + F1 fix) 与**纯基线**的预处理差异 = **只有 F1 fix 那几行** (逐行列出);
  P2) (纯基线 + F1 fix) 的每一行在新文件里按序逐字出现 (0 deletions);
  P3) 锚点各命中恰 1 次。
用法: python apply_ovl.py [--check]
"""
import hashlib
import io
import os
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
BASE = os.path.join(HERE, "tcp_tx_frame.v.base")
TGT = os.path.join(ROOT, "rtl", "tcp_tx_frame.v")
BR = os.path.join(HERE, "ovl_branch.v")

ANCH1 = ("    parameter integer ACKQ_D  = 32;\n"
         "    parameter integer ACKQ_AW = 5;\n"
         "\n")
ANCH2 = "    assign dbg_plen     = plen;\n"
ANCH_END = "\nendmodule"

# ---- 默认分支的同一处 F1 修复 ----
FIX_OLD = "    wire        ring_start = ring_eval && (ring_delta != 32'd0) && scan_estab;"
FIX_NEW = (
    "    // ⭐ Stage C 修复 (对抗审查 B1/F1): 控制帧帧首预留的 +1 可以让\n"
    "    //    `rb_snd_nxt` 越过 `retx_hi` ⇒ `ring_delta` 32 位下溢成 0xFFFFFFFF,\n"
    "    //    而 `!=0` 判据仍为真 ⇒ 伪 ring_start ⇒ G9 类自持重放洪水 (每次 1460 B)。\n"
    "    //    改成回绕安全的\"正 delta\": snd_nxt 越顶时不再起重放, 会话走排空支收尾。\n"
    "    wire        retx_ovf = (rb_snd_nxt != retx_hi) &&\n"
    "                           ((rb_snd_nxt - retx_hi) < 32'h8000_0000);\n"
    "    wire        ring_start = ring_eval && (ring_delta != 32'd0) && !retx_ovf &&\n"
    "                             scan_estab;")


def rd(p):
    return io.open(p, encoding="utf-8", newline="").read()


def pp(src, defs):
    """极简预处理器 (与 sim/p7b_stageb_rx8/apply_rx8.py 逐字同款)."""
    out, st = [], []
    for ln in src.split("\n"):
        t = ln.lstrip()
        if t.startswith("`ifdef ") or t.startswith("`ifndef "):
            inv = t.startswith("`ifndef ")
            name = t.split()[1]
            v = (name in defs) != inv
            st.append([v, v])
            continue
        if t.startswith("`else"):
            st[-1][0] = not st[-1][1]
            st[-1][1] = st[-1][1] or st[-1][0]
            continue
        if t.startswith("`endif"):
            st.pop()
            continue
        if all(f[0] for f in st):
            out.append(ln)
    assert not st, "unbalanced ifdef"
    return "\n".join(out)


base0 = rd(BASE)
br = rd(BR)
check = "--check" in sys.argv

# --- 锚点存在性 ---
assert base0.count(ANCH1) == 1, "anchor1"
assert base0.count(ANCH2) == 1, "anchor2"
assert base0.count(ANCH_END) == 1, "anchor_end"
assert "TCP_TX_OVL" not in base0, "baseline already has TCP_TX_OVL"
assert base0.count(FIX_OLD) == 1, "FIX_OLD hit %d" % base0.count(FIX_OLD)

base = base0.replace(FIX_OLD, FIX_NEW)          # 纯基线 + F1 fix = 新的等价基线
new = base.replace(ANCH1, ANCH1 + "`ifdef TCP_TX_OVL\n" + br + "`else\n")
new = new.replace(ANCH2, ANCH2 + "`endif\n")

# --- P1: 宏关预处理 == (纯基线 + fix) ---
p_ref = pp(base, set())
p_new = pp(new, set())
assert p_ref == p_new, "P1 FAIL"
assert pp(new, {"TCP_TX_OVL"}) != p_new, "P1 FAIL: macro-on identical (no effect)"
assert "retx_ovf" in pp(new, {"TCP_TX_OVL"})

# --- P1b: 与**纯基线**的差异 = 只有 F1 fix ---
p_pure = pp(base0, set()).split("\n")
p_fix = p_ref.split("\n")
import difflib
dl = list(difflib.unified_diff(p_pure, p_fix, "pure_baseline", "baseline+F1fix", n=1))
removed = [l[1:] for l in dl if l.startswith("-") and not l.startswith("---")]
added   = [l[1:] for l in dl if l.startswith("+") and not l.startswith("+++")]
print("P1  OK: macro-off preprocessing == (pure baseline + F1 fix): %d lines" % len(p_fix))
print("P1b OK: vs PURE baseline: -%d/+%d lines; diff:" % (len(removed), len(added)))
for l in removed:
    print("   -  " + l.strip()[:96])
for l in added:
    print("   +  " + l.strip()[:96])
assert len(removed) == 1 and removed[0].strip() == FIX_OLD.strip(), "P1b: 删除行不止 F1 fix"
assert [l.rstrip(chr(10)) for l in added] == FIX_NEW.split(chr(10)), "P1b: added lines != declared F1 fix block"

# --- P2: 0 deletions (对 base) ---
bl = base.split("\n")
nl = new.split("\n")
j = 0
for i, line in enumerate(bl):
    while j < len(nl) and nl[j] != line:
        j += 1
    assert j < len(nl), "P2 FAIL: line %d not found in order: %r" % (i + 1, line[:80])
    j += 1
ins = len(nl) - len(bl)
print("P2  OK: 0 deletions vs (baseline+fix); +%d inserted" % ins)
print("P3  OK: anchors hit once each")
print("macro-on preprocessed lines = %d" % len(pp(new, {"TCP_TX_OVL"}).split("\n")))

if not check:
    io.open(TGT, "w", encoding="utf-8", newline="").write(new)
    h = hashlib.sha256(new.encode("utf-8")).hexdigest()
    print("WROTE %s  sha256=%s  bytes=%d" % (TGT, h, len(new.encode("utf-8"))))
else:
    print("check-only, not written")
