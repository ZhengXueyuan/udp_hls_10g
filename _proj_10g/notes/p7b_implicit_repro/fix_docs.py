# fix_docs.py -- correct every DOC place that prescribes the dead "implicit"
# keyword as a gate criterion, and annotate the places that only *record* a
# reading taken with it (numbers are NOT rewritten -- they are historical).
import io, os, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")   # project trap 16(1): GBK console

REPO = r"D:\repo\XCKU5PMini\udp_hls_10g"
APPLY = "--apply" in sys.argv

NOTE = ("\u26a0\ufe0f **2026-09-29 \u8ba2\u6b63 (P7B \u5b9e\u6d4b)**: Vivado 2025.2 **\u4e0d\u518d\u6253\u5370 "
        "`implicitly declared`** (\u5b9e\u6d4b\u5168\u90e8\u65e5\u5fd7\u547d\u4e2d 0) \u21d2 \u65e7\u5173\u952e\u5b57\u662f**\u54d1\u95e8**\u3002"
        "2025.2 \u7684\u771f\u5b9e\u7b7e\u540d\u5206\u4e24\u79cd\u5f62\u6001\u3001**\u4e24\u4e2a\u4e0d\u540c\u68c0\u6d4b\u70b9**: "
        "\u2460 \u7aef\u53e3\u8fde\u63a5\u5f62\u5f0f (\u9759\u9ed8\u622a\u65ad) \u2014\u2014 **xvlog \u4e00\u4e2a\u5b57\u90fd\u4e0d\u6253\u5370**\uff0c"
        "\u53ea\u6709 `xelab` \u62a5 `WARNING: [VRFC 10-3091] actual bit length 1 differs from formal bit length 64 for port 'q'`\uff0c"
        "\u6216 `synth_design` \u62a5 `INFO: [Synth 8-11241] undeclared symbol 'mid', assumed default net type 'wire'`\uff1b"
        "\u2461 \u8868\u8fbe\u5f0f\u5f62\u5f0f \u2014\u2014 `ERROR: [VRFC 10-2989] '<name>' is not declared`\u3002"
        "\u21d2 **\u53ea grep xvlog \u65e5\u5fd7\u7684\u95e8\u7ed3\u6784\u6027\u5730\u6293\u4e0d\u5230\u672c\u5751**\u3002"
        "\u89c4\u8303\u68c0\u6d4b\u5668 = `sim/p4gates/implicit_gate.bat` (+ `implicit_gate_selftest.bat` \u4e5d\u9879\u5bf9\u7167)\uff1b"
        "\u53d6\u8bc1 = `_proj_10g/notes/P7B_IMPLICIT_GATE_FIX.md`\u3002")

EDITS = [
    # (file, old, new, kind)
    ("CLAUDE.md",
     "   \u21d2 \u95e8\u91cc\u5fc5\u987b\u628a **`findstr implicit` \u5f53\u786c\u5931\u8d25** (P5e-T3/T5 \u7684\u95e8\u5df2\u52a0, 4 \u4e2a\u65e5\u5fd7\u547d\u4e2d 0)\u3002",
     "   \u21d2 \u95e8\u91cc\u5fc5\u987b\u628a\u9690\u5f0f\u7f51\u5f53**\u786c\u5931\u8d25**\u3002\n   " + NOTE,
     "prescriptive"),

    ("PORT_NOTES.md",
     "`findstr implicit` \u505a**\u786c\u5931\u8d25** (T3/T5 \u7684\u95e8\u5df2\u52a0, 4 \u4e2a\u65e5\u5fd7\u547d\u4e2d 0)\u3002",
     "**\u9690\u5f0f\u7f51\u5f53\u786c\u5931\u8d25** (T3/T5 \u7684\u95e8\u5df2\u52a0)\u3002\n  " + NOTE,
     "prescriptive"),

    ("PORT_NOTES.md",
     "**DRC \u7ea7\u9759\u6001\u68c0\u67e5** (xvlog + xelab, **\u4e24\u4e2a ifdef \u914d\u7f6e\u90fd\u67e5**): `implicit` (T2 \u5efa\u8bae\u52a0 \u2014\u2014",
     "**DRC \u7ea7\u9759\u6001\u68c0\u67e5** (xvlog + xelab, **\u4e24\u4e2a ifdef \u914d\u7f6e\u90fd\u67e5**): \u9690\u5f0f\u7f51 (T2 \u5efa\u8bae\u52a0 \u2014\u2014",
     "prescriptive"),

    ("PORT_NOTES.md",
     "(\u5168\u662f\u65e2\u6709 `dbg_wptr`/`crc_nxt` \u7c7b), **\u65e0\u65b0\u589e**\u3002",
     "(\u5168\u662f\u65e2\u6709 `dbg_wptr`/`crc_nxt` \u7c7b), **\u65e0\u65b0\u589e**\u3002\n  " + NOTE,
     "reading"),

    ("PORT_NOTES.md",
     "\u21d2 \u5df2\u628a `findstr /C:\"10-3091\"` \u4e0e `findstr /I /C:\"implicitly\"` \u4e00\u5e76\u5217\u4e3a\u95e8\u91cc\u7684**\u786c\u5931\u8d25**\u3002",
     "\u21d2 \u5df2\u628a `10-3091` \u4e0e\u9690\u5f0f\u7f51\u7b7e\u540d\u4e00\u5e76\u5217\u4e3a\u95e8\u91cc\u7684**\u786c\u5931\u8d25**\u3002\n   " + NOTE,
     "prescriptive"),

    ("P7B_SPEC.md",
     "| F6 | `implicitly declared` \u547d\u4e2d **0**\uff08\u5f53\u786c\u5931\u8d25\uff09\u00b7 `10-3091` \u8ba1\u6570 **0** |",
     "| F6 | \u9690\u5f0f\u7f51\u7b7e\u540d\u547d\u4e2d **0**\uff08\u5f53\u786c\u5931\u8d25\uff1a`Synth 8-11241` / `VRFC 10-3091` / `10-2989`\uff09\u00b7 `10-3091` \u8ba1\u6570 **0** |",
     "prescriptive"),

    ("P7B_SPEC.md",
     "| A14 | lint\uff1a`implicitly declared` = 0 \u00b7 `10-3091` = 0 |",
     "| A14 | lint\uff1a\u9690\u5f0f\u7f51\u7b7e\u540d = 0 (`Synth 8-11241` / `VRFC 10-3091` / `10-2989`) \u00b7 `10-3091` = 0 |",
     "prescriptive"),

    ("P6B_SPEC.md",
     "4. \u6784\u5efa\u65e5\u5fd7\u91cc **\u65e0** `implicit` \u9690\u5f0f\u7f51",
     "4. \u6784\u5efa\u65e5\u5fd7\u91cc **\u65e0** \u9690\u5f0f\u7f51\u7b7e\u540d (`Synth 8-11241` / `VRFC 10-3091`)\u3001**\u65e0** `implicit` \u9690\u5f0f\u7f51",
     "prescriptive"),

    ("P6B_INTEGRATION_REVIEW.md",
     "\u4e24\u6761\u53d8\u5f02\u7684 `xvlog` **\u4f4d\u5bbd\u544a\u8b66 `10-3091` \u8ba1\u6570\u90fd\u662f 0\u3001`implicitly` \u8ba1\u6570\u4e5f\u662f 0**",
     "\u4e24\u6761\u53d8\u5f02\u7684 `xvlog` **\u4f4d\u5bbd\u544a\u8b66 `10-3091` \u8ba1\u6570\u90fd\u662f 0\u3001`implicitly` \u8ba1\u6570\u4e5f\u662f 0** (\u26a0\ufe0f \u540e\u8005 2026-09-29 \u5b9e\u6d4b\u5df2\u662f**\u6b7b\u5173\u952e\u5b57**, 0 \u547d\u4e2d = \u65e0\u8bdd\u53ef\u8bf4, \u4e0d\u80fd\u5f53\u8bc1\u636e; \u89c1 `_proj_10g/notes/P7B_IMPLICIT_GATE_FIX.md`)",
     "reading"),

    ("P6B_INTEGRATION_REVIEW.md",
     "\u21d2 \u56db\u79cd\u7ec4\u5408**\u5168\u90e8\u7f16\u8fc7\u4e14\u80fd elaborate**\uff08\u56db\u7ec4\u5408\u90fd\u6ca1\u62a5 undeclared / implicit / \u4f4d\u5bbd\uff09\u3002",
     "\u21d2 \u56db\u79cd\u7ec4\u5408**\u5168\u90e8\u7f16\u8fc7\u4e14\u80fd elaborate**\uff08\u56db\u7ec4\u5408\u90fd\u6ca1\u62a5 undeclared / implicit / \u4f4d\u5bbd\uff09\u3002\n  \u26a0\ufe0f **2026-09-29 \u8ba2\u6b63**: \u8fd9\u91cc\u7684 \"implicit\" \u662f**\u6b7b\u5173\u952e\u5b57** \u21d2 \u8be5\u9879\u5b9e\u9645\u53ea\u80fd\u8bc1 \"\u6ca1\u6709**\u8868\u8fbe\u5f0f\u5f62\u5f0f**\u7684\u672a\u58f0\u660e\"\uff0c**\u4e0d\u80fd\u8bc1 \"\u6ca1\u6709\u9690\u5f0f\u7f51\"**\uff08\u7aef\u53e3\u8fde\u63a5\u5f62\u5f0f\u5728 xvlog \u91cc\u5168\u9759\u9ed8\uff09\u3002\u89c1 `_proj_10g/notes/P7B_IMPLICIT_GATE_FIX.md`\u3002",
     "reading"),

    ("P7A_COMMIT_PLAN.md",
     "- `tcl/run_lint_p7a.bat`: elaboration \u7ea7 lint(implicit net / \u4f4d\u5bbd / ERROR \u4e09\u7c7b\u786c\u5931\u8d25)\u3002",
     "- `tcl/run_lint_p7a.bat`: elaboration \u7ea7 lint(\u9690\u5f0f\u7f51\u7b7e\u540d `Synth 8-11241` / `VRFC 10-3091` / `10-2989` / \u4f4d\u5bbd / ERROR \u786c\u5931\u8d25)\u3002\n  " + NOTE,
     "prescriptive"),

    ("P6E_OBS.md",
     "**5 \u6761 FAIL**\uff09\uff1b\u4e24\u6761\u53d8\u5f02\u7684 xvlog `10-3091` \u4e0e `implicitly` \u8ba1\u6570**\u90fd\u662f 0**",
     "**5 \u6761 FAIL**\uff09\uff1b\u4e24\u6761\u53d8\u5f02\u7684 xvlog `10-3091` \u4e0e `implicitly` \u8ba1\u6570**\u90fd\u662f 0** (\u26a0\ufe0f `implicitly` 2026-09-29 \u5b9e\u6d4b\u5df2\u662f\u6b7b\u5173\u952e\u5b57 \u21d2 \u8fd9\u534a\u53e5\u65e0\u8bc1\u636e\u529b)",
     "reading"),

    ("README.md",
     "\u5185\u7f6e\u8d1f\u5bf9\u7167) / `run_tb_p5e_t2_wrapper.bat` (**T2 \u771f wrapper \u5168\u94fe**, \u542b `implicit` \u68c0\u67e5)\u3002",
     "\u5185\u7f6e\u8d1f\u5bf9\u7167) / `run_tb_p5e_t2_wrapper.bat` (**T2 \u771f wrapper \u5168\u94fe**, \u542b\u9690\u5f0f\u7f51\u68c0\u67e5: `Synth 8-11241` / `VRFC 10-3091` / `10-2989`)\u3002",
     "prescriptive"),
]

bad = 0
for f, old, new, kind in EDITS:
    p = os.path.join(REPO, f)
    t = io.open(p, encoding="utf-8").read()
    n = t.count(old)
    if n != 1:
        print("SKIP (%d occurrences) %s :: %r" % (n, f, old[:60]))
        bad = 1
        continue
    print("EDIT [%s] %s\n  OLD: %s\n  NEW: %s\n" % (kind, f, old.replace("\n", " | ")[:150],
                                                   new.replace("\n", " | ")[:260]))
    if APPLY:
        io.open(p, "w", encoding="utf-8", newline="").write(t.replace(old, new))
print("doc edits done (apply=%s, skipped=%d)" % (APPLY, bad))
