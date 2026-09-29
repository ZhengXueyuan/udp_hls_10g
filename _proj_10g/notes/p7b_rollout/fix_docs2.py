# -*- coding: utf-8 -*-
"""P7B rollout: correct the docs.  Only 'already falsified implementation
details' are touched (key strings / instructions for the future).  Historical
READINGS (the numbers) are never altered."""
import os
import re
import sys

ROOT = r"D:\repo\XCKU5PMini\udp_hls_10g"
apply = "--apply" in sys.argv

BLOCK = (
    "\u26a0\ufe0f **2026-09-29 \u8ba2\u6b63 (P7B \u5b9e\u6d4b)**: Vivado 2025.2 **\u4e0d\u518d\u6253\u5370 `implicitly declared`** (\u5b9e\u6d4b\u5168\u90e8\u65e5\u5fd7\u547d\u4e2d 0) \u21d2 \u65e7\u5173\u952e\u5b57\u662f**\u54d1\u95e8**\u3002Vivado 2025.2 \u7684\u771f\u5b9e\u7b7e\u540d\u5206\u4e24\u79cd\u5f62\u6001\u3001**\u4e24\u4e2a\u4e0d\u540c\u68c0\u6d4b\u70b9**: \u2460 \u7aef\u53e3\u8fde\u63a5\u5f62\u5f0f (\u9759\u9ed8\u622a\u65ad) \u2014\u2014 **xvlog \u4e00\u4e2a\u5b57\u90fd\u4e0d\u6253\u5370** (exit 0\u3001\u65e5\u5fd7\u5168\u7a7a, `-sv` \u4e5f\u4e00\u6837), \u53ea\u6709 `xelab` \u62a5 `WARNING: [VRFC 10-3091] actual bit length 1 differs from formal bit length 64 for port 'q'`, \u6216 `synth_design` \u62a5 `INFO: [Synth 8-11241] undeclared symbol 'mid', assumed default net type 'wire'`; \u2461 \u8868\u8fbe\u5f0f\u5f62\u5f0f \u2014\u2014 `xvlog` \u62a5 `ERROR: [VRFC 10-2989] '<name>' is not declared` (synth \u7528 `8-36`)\u3002"
    "\u21d2 **\u53ea grep xvlog \u65e5\u5fd7\u7684\u95e8\u7ed3\u6784\u6027\u5730\u62d3\u4e0d\u5230\u672c\u5751 \u2014\u2014 \u6362\u4efb\u4f55\u5173\u952e\u5b57\u90fd\u4e0d\u884c, \u5fc5\u987b\u8865 `xelab`/`synth_design` \u8fd9\u4e00\u9762** (\u73b0\u5f79\u4e24\u5904 lint \u5165\u53e3 `board/run_lint_p6e.bat` / `_proj_10g/tcl/run_lint_p7a.bat` \u5df2\u8865, \u5404 +12 s / +24 s)\u3002"
    "\u2003**\u63a8\u8350\u952e\u8868 (5 \u952e, OR \u8bed\u4e49)**: `Synth 8-11241` \u00b7 `undeclared symbol` \u00b7 `VRFC 10-3091] actual bit length 1 differs from formal bit length` \u00b7 `VRFC 10-2989` \u00b7 `implicitly declared` (\u672b\u8005\u53ea\u4e3a 2025.2 \u4e4b\u524d\u7684\u5de5\u5177\u4fdd\u7559, \u5728 2025.2 \u4e0b\u6052 0)\u3002"
    "\u2003\u26a0\ufe0f **`10-3091` \u5fc5\u987b\u5e26\u4e0a `] actual bit length 1 differs from formal bit length`**: \u88f8 `VRFC 10-3091` \u4f1a\u547d\u4e2d `board/util_gmii_to_rgmii.v` \u7684 **14 \u5904\u826f\u6027 unsized \u5b57\u9762\u91cf** (`.CE(1)`/`.D1(1)`/`.D2(0)`/`.R(0)`/`.S(0)`, \u62a5 `actual bit length 32 differs from formal bit length 1`) \u2014\u2014 \u9ed8\u8ba4 (K7) \u914d\u7f6e\u6bcf\u6b21 xelab \u90fd\u62a5, \u5f53\u786c\u5931\u8d25\u5c31\u662f\u5929\u5929\u8bef\u4f24\u3002\u9690\u5f0f\u7f51**\u5fc5\u7136\u662f 1 \u4f4d** \u21d2 \"actual = 1\" \u5c31\u662f\u672c\u5751\u7684\u7cbe\u786e\u7b7e\u540d (\u6536\u7a84\u540e\u4ecd\u6293\u4f4f\u75c5\u7406\u4ef6 A1)\u3002"
    "\u2003**\u523b\u610f\u6392\u9664\u7684\u952e (\u90fd\u6709\u5b9e\u6d4b\u5047\u9633\u6027)**: `8-7129`/`unconnected or has no load` (\u547d\u4e2d\u5e72\u51c0\u4ef6\u7684**\u5408\u6cd5\u672a\u7528\u7aef\u53e3**)\u3001`8-6014`/`8-3917` (\u7eaf\u4f18\u5316\u63d0\u793a)\u3001`VRFC 10-3645`/`remains unconnected` (xelab \u4fa7\u5bf9\u5076 \u2014\u2014 \u5e72\u51c0\u7684\u771f\u5b9e P6e \u8bbe\u8ba1\u4e00\u8dd1\u5c31 **20 \u6761**)\u3002"
    "\u2003\u26a0\ufe0f **\u88f8 `findstr /C:\"10-3091\"` \u90a3\u4e00\u65cf\"\u4f4d\u5bbd\u4e0d\u7b26\"\u5224\u5b9a\u7ed3\u6784\u6027\u5e38\u54d1**: \u8bed\u6599\u5b9e\u6d4b `10-3091` \u5728 **869 \u4efd xvlog \u65e5\u5fd7\u4e2d 0 \u547d\u4e2d**\u3001452 \u4efd xelab \u65e5\u5fd7\u4e2d 173 \u4efd\u547d\u4e2d \u21d2 **\u51e1 grep `xvlog_*.log` \u7684\u88f8 `10-3091` \u5224\u5b9a\u6c38\u8fdc\u4e0d\u4f1a\u89e6\u53d1**\u3002"
    "\u2003\u26a0\ufe0f **\u5386\u53f2\u4e8b\u5b9e**: `IMPLICIT-DECL-FAIL` / `BITWIDTH-MISMATCH-FAIL` \u5728**\u5168\u4ed3\u7559\u5b58\u65e5\u5fd7\u91cc 0 \u547d\u4e2d** \u21d2 \u65e0\u4efb\u4f55\u8bc1\u636e\u8868\u660e\u8fd9\u4e24\u6761\u95e8**\u66fe\u7ecf**\u54cd\u8fc7 (\u4e25\u683c\u63aa\u8f9e: \"\u6ca1\u6709\u7559\u5b58\u65e5\u5fd7\u542b\u8fd9\u4e9b\u6807\u8bb0\" \u2260 \"\u4ece\u672a\u5931\u8d25\")\u3002"
    "\u2003\u89c4\u8303\u68c0\u6d4b\u5668 = `sim/p4gates/implicit_gate.bat` (+ `implicit_gate_selftest.bat` \u4e5d\u9879\u5bf9\u7167)\uff1b\u53d6\u8bc1 = `_proj_10g/notes/P7B_IMPLICIT_GATE_FIX.md` (\u4fee\u590d) + `_proj_10g/notes/P7B_IMPLICIT_GATE_ROLLOUT.md` (\u94fa\u5f00 + \u8bed\u6599\u7ea7\u5047\u9633\u6027\u9a8c\u8bc1)\u3002"
)

# (a) expand the standard correction sentence, wherever the previous rollout put it
STD = re.compile(r"\u26a0\ufe0f \*\*2026-09-29 \u8ba2\u6b63 \(P7B \u5b9e\u6d4b\)\*\*: Vivado 2025\.2 .*?P7B_IMPLICIT_GATE_FIX\.md`\u3002")

# (b) targeted key-string corrections: file -> [(old, new)]
TARGETS = {
    "CLAUDE.md": [],
    "PORT_NOTES.md": [],
    "P7B_SPEC.md": [
        ("`Synth 8-11241` / `VRFC 10-3091` / `10-2989`",
         "`Synth 8-11241` / `VRFC 10-3091] actual bit length 1 differs from formal bit length` / `VRFC 10-2989`\u2003(\u26a0\ufe0f \u88f8 `VRFC 10-3091` \u4f1a\u8bef\u4f24 `board/util_gmii_to_rgmii.v` \u7684 14 \u5904\u826f\u6027 unsized \u5b57\u9762\u91cf \u2014\u2014 \u5fc5\u987b\u5e26 `actual bit length 1` \u90a3\u4e00\u6bb5)"),
    ],
    "README.md": [
        ("\u542b\u9690\u5f0f\u7f51\u68c0\u67e5: `Synth 8-11241` / `VRFC 10-3091` / `10-2989`",
         "\u542b\u9690\u5f0f\u7f51\u68c0\u67e5: `Synth 8-11241` / `VRFC 10-3091] actual bit length 1 differs from formal bit length` / `VRFC 10-2989`\u2003(\u26a0\ufe0f \u88f8 `10-3091` \u4e0d\u884c \u2014\u2014 \u89c1 CLAUDE.md \u5751 24)"),
    ],
    "P7A_COMMIT_PLAN.md": [
        ("\u9690\u5f0f\u7f51\u7b7e\u540d `Synth 8-11241` / `VRFC 10-3091` / `10-2989` / \u4f4d\u5bbd / ERROR \u786c\u5931\u8d25",
         "\u9690\u5f0f\u7f51\u7b7e\u540d `Synth 8-11241` / `VRFC 10-3091] actual bit length 1 differs from formal bit length` / `VRFC 10-2989` / \u4f4d\u5bbd / ERROR \u786c\u5931\u8d25; **2026-09-29 \u8ffd\u52a0 xelab \u9762** (p7a_top \u7684\u7aef\u53e3\u8fde\u63a5\u5f62\u5f0f xvlog \u5168\u9759\u9ed8; \u7528 gt_10gbr \u7684 synth+hdl \u6e90 + vio_p7a_stub.v, `-L unisims_ver -L secureip`, ~24 s; IP \u672a\u751f\u6210\u65f6 exit 97)"),
    ],
    "P6B_SPEC.md": [
        ("4. \u6784\u5efa\u65e5\u5fd7\u91cc **\u65e0** \u9690\u5f0f\u7f51\u7b7e\u540d (`Synth 8-11241` / `VRFC 10-3091`)\u3001**\u65e0** `implicit` \u9690\u5f0f\u7f51\u3001`10-3091` \u4f4d\u5bbd\u4e0d\u7b26\uff08\u7167\u6284\u65e2\u6709\u95e8\u7684\u786c\u5931\u8d25\u89c4\u5219\uff09\u3002",
         "4. \u6784\u5efa\u65e5\u5fd7\u91cc **\u65e0** \u9690\u5f0f\u7f51\u7b7e\u540d (`Synth 8-11241` / `VRFC 10-3091] actual bit length 1 differs from formal bit length`)\u3001**\u65e0** `VRFC 10-2989`\u3001`10-3091` \u4f4d\u5bbd\u4e0d\u7b26\uff08\u7167\u6284\u65e2\u6709\u95e8\u7684\u786c\u5931\u8d25\u89c4\u5219\uff09\u3002\u26a0\ufe0f \u65e7\u53e5\u5b50\u91cc\u7684 `implicit` \u662f**\u6b7b\u5173\u952e\u5b57** (\u6052 0 \u547d\u4e2d)\u3001\u4e14 **\u7aef\u53e3\u8fde\u63a5\u5f62\u5f0f\u5728 xvlog \u91cc\u5168\u9759\u9ed8** \u21d2 \u53ea\u8dd1 xvlog \u7684\u6784\u5efa\u65e5\u5fd7\u8bfb\u6570**\u4e0d\u80fd**\u8bc1\u660e\u65e0\u9690\u5f0f\u7f51 (\u89c1 CLAUDE.md \u5751 24)\u3002"),
    ],
    "P6B_INTEGRATION_REVIEW.md": [
        ("\uff08\u672c\u5de5\u7a0b\u5df2\u6709 `findstr implicit` / `10-3091` \u7684\u5148\u4f8b\uff0c\u7167\u6284\u5373\u53ef\uff09\uff1b",
         "\uff08\u672c\u5de5\u7a0b\u5df2\u6709\u9690\u5f0f\u7f51\u5236\u5b9a\u4f8b\uff1b\u26a0\ufe0f **2026-09-29 \u8ba2\u6b63**: \u4e0d\u8981\u7167\u6284\u65e7\u7684 `findstr implicit` \u2014\u2014 \u5b83\u5728 2025.2 \u4e0b\u6052 0 \u547d\u4e2d, \u800c\u4e14\u53ea grep xvlog \u65e5\u5fd7\u65f6**\u7ed3\u6784\u6027\u62d3\u4e0d\u5230\u7aef\u53e3\u8fde\u63a5\u5f62\u5f0f**\u3002\u7528 `sim/p4gates/implicit_gate.bat` \u7684 5 \u952e\u8868, \u5e76\u4fdd\u8bc1\u5224\u636e\u8dd1\u5728 `xelab`/`synth_design` \u65e5\u5fd7\u4e0a\uff09\uff1b"),
        ("| **B7** |", "| **B7** |"),
    ],
    "P6E_OBS.md": [
        ("\u591a\u4e00\u9879\u4f1a\u88ab\u9759\u9ed8\u622a\u65ad (\u95e8\u91cc `findstr 10-3091` \u5f53\u786c\u5931\u8d25)\u3002",
         "\u591a\u4e00\u9879\u4f1a\u88ab\u9759\u9ed8\u622a\u65ad\u3002\u26a0\ufe0f **2026-09-29 \u8ba2\u6b63**: \u73b0\u5728\u8981\u7528 `findstr /C:\"VRFC 10-3091] actual bit length 1 differs from formal bit length\"` (\u88f8 `10-3091` \u4f1a\u8bef\u4f24 util_gmii_to_rgmii.v \u7684 14 \u5904\u826f\u6027 unsized \u5b57\u9762\u91cf), \u4e14\u5fc5\u987b\u8dd1\u5728 **xelab** \u65e5\u5fd7\u4e0a (\u88f8 `10-3091` \u5728 869 \u4efd xvlog \u65e5\u5fd7\u91cc 0 \u547d\u4e2d)\u3002"),
    ],
}

changed = []
for rel, pairs in TARGETS.items():
    p = os.path.join(ROOT, rel)
    t = open(p, "r", encoding="utf-8", errors="surrogateescape").read()
    orig = t
    n = len(STD.findall(t))
    if n:
        t = STD.sub(lambda m: BLOCK, t)
        changed.append("%s: expanded %d standard correction block(s)" % (rel, n))
    for old, new in pairs:
        if old == new:
            continue
        c = t.count(old)
        if c:
            t = t.replace(old, new)
            changed.append("%s: key-string fix x%d  [%s...]" % (rel, c, old[:34]))
        else:
            changed.append("%s: ANCHOR-NOT-FOUND  [%s...]" % (rel, old[:34]))
    if t != orig and apply:
        open(p, "w", encoding="utf-8", errors="surrogateescape", newline="").write(t)

print("MODE =", "APPLY" if apply else "DRYRUN")
for c in changed:
    print("  ", c)
