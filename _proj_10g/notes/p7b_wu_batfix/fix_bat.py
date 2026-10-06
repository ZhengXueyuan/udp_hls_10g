# fix_bat.py -- surgical, comment-only fix of sim/p5wu/run_tb_app_wu.bat
#   * replaces the 8 non-ASCII REM lines with ASCII-English equivalents
#     (semantic translation, no information removed)
#   * guarantees CRLF line endings and a pure-ASCII result
#   * asserts every OTHER line is byte-identical to the original
import io, sys, os

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
TARGET = os.path.join(REPO, "sim", "p5wu", "run_tb_app_wu.bat")

# line number (1-based, as in the original file) -> new ASCII comment text (no CR/LF)
NEW = {
    21: "REM run_tb_app_wu.bat -- P7b-WU gate: same-stimulus A/B for app_ctrl C6 (window reopen notify wu)",
    22: "REM   both arms driven at the same time by identical stimulus / identical gnt:",
    23: "REM     u_new = app_ctrl (default params, after fix) / u_old = app_ctrl #(.WU_LEGACY(1)) (before fix)",
    24: "REM   main criteria: in the field modality (window held at 56..128, never exactly 0) NEW must fire / OLD 0 times;",
    25: "REM           in the designed condition (occ>=winq => wscan==0) both arms fire once (both arms alive).",
    26: "REM criteria: per-item PASS/FAIL inside the TB + last line \"P7B WU GATE OK\" / \"P7B WU GATE FAIL n\"",
    27: "REM dedicated work dir sim\\p5wu\\run (project rule: leftover xsim procs holding xsim.dir cause false gate failures)",
    44: "REM ---- pitfall 24 (implicit net / port width silently truncated) criteria: only the xelab/synth side can catch it (CLAUDE.md pit 24)",
}

raw = open(TARGET, "rb").read()
assert b"PHASE-NEVER" not in raw  # sentinel; never true, keeps the intent obvious
lines = raw.split(b"\r\n")
if lines[-1] == b"":
    lines = lines[:-1]           # file ends with CRLF -> last element empty
else:
    sys.exit("FATAL: file does not end with CRLF")

# every line must end cleanly at the CRLF split; nothing else may contain CR or LF
for i, l in enumerate(lines, 1):
    if b"\r" in l or b"\n" in l:
        sys.exit("FATAL: embedded CR/LF in line %d" % i)

out = []
changed = []
for i, l in enumerate(lines, 1):
    if i in NEW:
        old_nonascii = [c for c in l if c > 127]
        if not old_nonascii:
            sys.exit("FATAL: line %d expected to hold non-ASCII, but does not" % i)
        new = NEW[i].encode("ascii")
        if new == l:
            sys.exit("FATAL: line %d replacement is a no-op" % i)
        changed.append(i)
        out.append(new)
    else:
        if any(c > 127 for c in l):
            sys.exit("FATAL: unexpected non-ASCII in line %d (not in replacement table)" % i)
        out.append(l)

newraw = b"\r\n".join(out) + b"\r\n"

# ---- hard assertions on the result -----------------------------------------
assert len(changed) == len(NEW), (changed, len(NEW))
assert all(c < 128 for c in newraw), "result is not pure ASCII"
assert newraw.count(b"\r") == newraw.count(b"\n") == len(out), "result is not all-CRLF"
assert newraw.endswith(b"\r\n")

# ---- prove nothing outside the 8 comment lines changed ---------------------
assert len(out) == len(lines), "line count changed!"
for i, (a, b) in enumerate(zip(lines, out), 1):
    if i in NEW:
        continue
    assert a == b, "line %d changed but was not in the replacement table" % i

open(TARGET, "wb").write(newraw)
print("OK: replaced %d comment lines: %s" % (len(changed), changed))
print("bytes %d -> %d ; lines %d ; CR %d ; LF %d ; max byte %d"
      % (len(raw), len(newraw), len(out), newraw.count(b"\r"), newraw.count(b"\n"), max(newraw)))
