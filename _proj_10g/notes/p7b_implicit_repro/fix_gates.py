# fix_gates.py -- replace the dead "implicitly"/"implicit" findstr key with the
# MEASURED Vivado-2025.2 signature set, and add the missing xelab-side check.
#
# MEASURED 2026-09-29 (see _proj_10g/notes/P7B_IMPLICIT_GATE_FIX.md):
#   synth_design : INFO: [Synth 8-11241] undeclared symbol 'mid', assumed default net type 'wire'
#   xelab        : WARNING: [VRFC 10-3091] actual bit length 1 differs from formal bit length 64 for port 'q'
#   xvlog        : ERROR: [VRFC 10-2989] 'pay_sel' is not declared
#   xvlog        : (the port-connection form prints NOTHING -- gate must use the xelab log)
#   "implicitly declared" : 0 hits in every 2025.2 log measured -> kept only for old tools
import io, os, re, sys

ROOT = r"D:\repo\XCKU5PMini\udp_hls_10g"
KEYS = ('/I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091" '
        '/C:"VRFC 10-2989" /C:"implicitly declared"')
OLD1 = 'findstr /I /C:"implicitly"'
OLD2 = 'findstr /I /C:"implicit"'
DRY = ("--apply" not in sys.argv)

TARGETS = []
for dp, dn, fn in os.walk(ROOT):
    dn[:] = [d for d in dn if not d.startswith("work_")
             and d not in ("evidence", "xsim.dir", ".Xil", ".git", "p7b_implicit_repro")]
    for f in fn:
        if f.lower().endswith((".bat", ".py")):
            TARGETS.append(os.path.join(dp, f))
TARGETS.sort()

changelog = []
logf = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "fix_gates_changelog.txt"),
            "w", encoding="utf-8")

def emit(s):
    logf.write(s + "\n")
    print(s)

# ---------------------------------------------------------------------------
for p in TARGETS:
    rel = os.path.relpath(p, ROOT).replace("\\", "/")
    try:
        # newline="" -> keep the file's own CRLF bytes intact (bat rule: CRLF only)
        text = io.open(p, "r", encoding="utf-8", errors="surrogateescape", newline="").read()
    except Exception:
        continue
    # sim/p4sim/*.bat are the CANONICAL P4 matrix gates and had NO implicit-net
    # check at all (measured: grep = 0 hits).  They are processed for Rule C only.
    canonical = (rel.startswith("sim/p4sim/run_tb_p4_")
                 or rel.startswith("sim/retxsim/") or rel.startswith("sim/retxsim2/")
                 or rel.startswith("sim/vlansim/") or rel.startswith("sim/tbgate/"))
    if "implicit" not in text.lower() and not canonical:
        continue
    if canonical:
        emit("CANONICAL %s (no implicit check existed before)" % rel)
    orig = text
    lines = text.splitlines(True)

    # ---- Rule A: key substitution (hard-fail checks, advisory checks, and the
    #      hit-echo inside the same line) -------------------------------------
    for i, ln in enumerate(lines):
        if OLD1 in ln or OLD2 in ln:
            new = ln.replace(OLD1, "findstr " + KEYS).replace(OLD2, "findstr " + KEYS)
            if new != ln:
                lines[i] = new
                emit("A %s:%d\n  OLD: %s\n  NEW: %s" % (rel, i + 1, ln.rstrip("\r\n"), new.rstrip("\r\n")))

    # ---- Rule B: quoted keyword inside REM comments --------------------------
    for i, ln in enumerate(lines):
        s = ln.lstrip()
        if not (s[:4].upper() == "REM " or s[:1] == "#"):
            continue
        if '"implicitly"' in ln or '"implicit"' in ln:
            new = ln.replace('"implicitly"', '"8-11241/10-3091"').replace('"implicit"', '"8-11241/10-3091"')
            if new != ln:
                lines[i] = new
                emit("B %s:%d\n  OLD: %s\n  NEW: %s" % (rel, i + 1, ln.rstrip("\r\n"), new.rstrip("\r\n")))

    # ---- Rule C: add the missing xelab-side check ----------------------------
    # An implicit net used as a PORT CONNECTION is invisible to xvlog, so a gate
    # that only greps the xvlog log CANNOT catch it.  xelab reports it as 10-3091.
    xelab_idxs = [i for i, ln in enumerate(lines) if "xelab.bat" in ln]
    if xelab_idxs:
        for xi in xelab_idxs:
            ln = lines[xi]
            m = re.search(r"-log\s+(\S+)", ln)
            if m:
                xlog = m.group(1)
            else:
                m = re.search(r">\s*(\S+)\s+2>&1", ln)
                xlog = m.group(1) if m else None
            if not xlog:
                emit("C-SKIP %s:%d (could not parse the xelab log name)" % (rel, xi + 1))
                continue
            # is there already a check that greps this xelab log?
            tail = "".join(lines[xi + 1:xi + 12])
            if re.search(r"findstr[^\n]*" + re.escape(xlog), tail):
                emit("C-OK   %s:%d (xelab log %s already checked)" % (rel, xi + 1, xlog))
                continue
            ins = ('findstr ' + KEYS + ' ' + xlog + ' >NUL && '
                   '(echo IMPLICIT-DECL-FAIL-XELAB & findstr ' + KEYS + ' ' + xlog + ' & exit /b 1)\r\n')
            lines.insert(xi + 1, ins)
            emit("C %s:%d  INSERTED after the xelab call:\n  NEW: %s" % (rel, xi + 2, ins.rstrip()))

    new = "".join(lines)
    if new != orig:
        changelog.append(rel)
        if not DRY:
            with io.open(p, "w", encoding="utf-8", errors="surrogateescape", newline="") as fh:
                fh.write(new)

emit("\n=== files touched (%d) ===" % len(changelog))
for c in changelog:
    emit("  " + c)
logf.close()
