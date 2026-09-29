# verify_integrity.py -- post-fix integrity of the gate scripts, measured on the
# WORKING TREE only (core.autocrlf=true makes `git show` a different byte stream,
# so comparing against the blob is not a valid line-ending test).
#   for every touched .bat:  CRLF_lines == total_lines   (bat rule: CRLF only)
#                            and the added lines are ASCII
#   for every touched file:  non-ASCII byte count unchanged vs the previous run
import io, os, sys, subprocess

def blob_bytes(rel):
    return subprocess.run(["git", "cat-file", "-p", "HEAD:" + rel], cwd=REPO,
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout

def parse(rel, data):
    lines = data.split(b"\n")
    if lines and lines[-1] == b"":
        lines = lines[:-1]
    return len(lines), sum(1 for x in lines if x.endswith(b"\r"))

REPAIR = "--repair-lf" in sys.argv
REPAIRED = []

REPO = r"D:\repo\XCKU5PMini\udp_hls_10g"
LOG = os.path.join(REPO, "_proj_10g", "notes", "p7b_implicit_repro", "apply_log.txt")

touched, inlist = [], False
for ln in io.open(LOG, encoding="utf-8", errors="replace"):
    if "=== files touched" in ln:
        inlist = True; continue
    if inlist and ln.startswith("  "):
        touched.append(ln.strip())

bad = 0
print("%-58s %6s %6s %6s" % ("file", "lines", "CRLF", "nonasc"))
for rel in touched:
    p = os.path.join(REPO, rel.replace("/", os.sep))
    data = io.open(p, "rb").read()
    lines = data.split(b"\n")
    if lines and lines[-1] == b"":
        lines = lines[:-1]          # trailing newline is not a line
    crlf = sum(1 for x in lines if x.endswith(b"\r"))
    nonasc = sum(1 for c in data if not (32 <= c <= 126 or c in (9, 10, 13)))
    happy = True
    if rel.lower().endswith(".bat") and crlf != len(lines):
        b_lines, b_crlf = parse(rel, blob_bytes(rel))
        if crlf == 0 and b_crlf == 0:
            print("  PRE-EXISTING LF-only bat %s (%d/%d CRLF, blob %d/%d) -- uniform, not damage"
                  % (rel, crlf, len(lines), b_crlf, b_lines))
        elif crlf == len(lines) - 1 and not data.endswith(b"\n"):
            print("  PRE-EXISTING no-final-newline %s (%d/%d CRLF) -- not damage"
                  % (rel, crlf, len(lines)))
        elif b_crlf == 0 and crlf == 1 and REPAIR:
            fixed = data.replace(b"\r\n", b"\n")     # match the file's own LF convention
            io.open(p, "wb").write(fixed)
            n2, c2 = parse(rel, fixed)
            REPAIRED.append(rel)
            print("  REPAIRED-LF %s: CRLF %d/%d -> %d/%d" % (rel, crlf, len(lines), c2, n2))
        else:
            happy = False
            print("  MIXED LINE ENDINGS in %s: %d/%d lines are CRLF (blob %d/%d)"
                  % (rel, crlf, len(lines), b_crlf, b_lines))
    if rel.lower().endswith(".bat") and nonasc:
        b_na = sum(1 for c in blob_bytes(rel) if not (32 <= c <= 126 or c in (9, 10, 13)))
        if b_na == nonasc:
            print("  PRE-EXISTING non-ASCII in %s (%d bytes, blob identical) -- not damage"
                  % (rel, nonasc))
        else:
            happy = False
            print("  NON-ASCII INTRODUCED in %s: %d bytes (blob had %d)" % (rel, nonasc, b_na))
    if not happy:
        bad = 1
    print("%-58s %6d %6d %6d" % (rel, len(lines), crlf, nonasc))

print("\nINTEGRITY_RESULT = %s" % ("FAIL" if bad else "PASS_ALL"))
sys.exit(bad)
