# fix_bat2.py <path> -- comment-encoding + line-ending fix for the two probe bats.
#   * translates the 7 non-ASCII REM lines via a byte-exact lookup table
#   * normalises every line ending to CRLF (the two probes have LF-only lines)
#   * asserts every OTHER line is byte-identical (no logic change)
import os, sys

TABLE = {
 b"REM run_tb_app_wu.bat -- P7b-WU \xe9\x97\xa8: app_ctrl C6 (\xe7\xaa\x97\xe5\x8f\xa3\xe9\x87\x8d\xe5\xbc\x80\xe9\x80\x9a\xe5\x91\x8a wu) \xe7\x9a\x84\xe5\x90\x8c\xe6\xbf\x80\xe5\x8a\xb1 A/B":
 b"REM run_tb_app_wu.bat -- P7b-WU gate: same-stimulus A/B for app_ctrl C6 (window reopen notify wu)",
 b"REM   \xe5\x90\x8c\xe4\xb8\x80\xe6\xbf\x80\xe5\x8a\xb1/\xe5\x90\x8c gnt \xe5\x90\x8c\xe6\x97\xb6\xe9\xa9\xb1\xe5\x8a\xa8\xe4\xb8\xa4\xe8\x87\x82:":
 b"REM   both arms driven at the same time by identical stimulus / identical gnt:",
 b"REM     u_new = app_ctrl (\xe9\xbb\x98\xe8\xae\xa4\xe5\x8f\x82\xe6\x95\xb0, \xe4\xbf\xae\xe5\xa4\x8d\xe5\x90\x8e) \xc2\xb7 u_old = app_ctrl #(.WU_LEGACY(1)) (\xe4\xbf\xae\xe5\xa4\x8d\xe5\x89\x8d)":
 b"REM     u_new = app_ctrl (default params, after fix) / u_old = app_ctrl #(.WU_LEGACY(1)) (before fix)",
 b"REM   \xe4\xb8\xbb\xe5\x88\xa4\xe6\x8d\xae: \xe7\x8e\xb0\xe5\x9c\xba\xe6\xa8\xa1\xe6\x80\x81 (\xe7\xaa\x97\xe5\x8f\xa3\xe8\xa2\xab\xe6\x89\x98\xe5\x9c\xa8 56..128, \xe4\xbb\x8e\xe4\xb8\x8d\xe6\x81\xb0\xe5\xa5\xbd 0) \xe4\xb8\x8b \xe6\x96\xb0\xe8\x87\x82\xe5\xbf\x85\xe5\x8f\x91 / \xe6\x97\xa7\xe8\x87\x82 0 \xe6\xac\xa1;":
 b"REM   main criteria: in the field modality (window held at 56..128, never exactly 0) NEW must fire / OLD 0 times;",
 b"REM           \xe8\xae\xbe\xe8\xae\xa1\xe5\xb7\xa5\xe5\x86\xb5 (occ>=winq => wscan==0) \xe4\xb8\x8b \xe4\xb8\xa4\xe8\x87\x82\xe5\x90\x84\xe5\x8f\x91 1 \xe6\xac\xa1 (\xe4\xb8\xa4\xe8\x87\x82\xe9\x83\xbd\xe6\xb4\xbb\xe7\x9d\x80)\xe3\x80\x82":
 b"REM           in the designed condition (occ>=winq => wscan==0) both arms fire once (both arms alive).",
 b"REM \xe5\x88\xa4\xe6\x8d\xae: TB \xe5\x86\x85\xe9\x83\xa8\xe9\x80\x90\xe9\xa1\xb9 PASS/FAIL + \xe6\x9c\xab\xe8\xa1\x8c \"P7B WU GATE OK\" / \"P7B WU GATE FAIL n\"":
 b"REM criteria: per-item PASS/FAIL inside the TB + last line \"P7B WU GATE OK\" / \"P7B WU GATE FAIL n\"",
 b"REM \xe7\x8b\xac\xe7\xab\x8b\xe5\xb7\xa5\xe4\xbd\x9c\xe7\x9b\xae\xe5\xbd\x95 sim\\p5wu\\run (\xe5\xb7\xa5\xe7\xa8\x8b\xe9\x93\x81\xe5\xbe\x8b: \xe6\xae\x8b\xe7\x95\x99 xsim \xe8\xbf\x9b\xe7\xa8\x8b\xe5\x8d\xa0 xsim.dir \xe4\xbc\x9a\xe8\xae\xa9\xe9\x97\xa8\xe5\x81\x87\xe5\xa4\xb1\xe8\xb4\xa5)":
 b"REM dedicated work dir sim\\p5wu\\run (project rule: leftover xsim procs holding xsim.dir cause false gate failures)",
}

path = sys.argv[1]
raw = open(path, "rb").read()
lines = raw.split(b"\n")
if lines[-1] == b"":
    lines = lines[:-1]
else:
    sys.exit("FATAL: %s does not end with LF" % path)
lines = [l[:-1] if l.endswith(b"\r") else l for l in lines]   # strip CR -> record the logical lines

out, changed, lf_fixed = [], [], 0
for i, l in enumerate(lines, 1):
    if any(c > 127 for c in l):
        if l not in TABLE:
            sys.exit("FATAL: %s line %d has no translation entry: %r" % (path, i, l[:80]))
        out.append(TABLE[l]); changed.append(i)
    else:
        out.append(l)

# line-ending census of the ORIGINAL
orig_parts = raw.split(b"\n")[:-1]
lf_fixed = [i for i, p in enumerate(orig_parts, 1) if not p.endswith(b"\r")]

newraw = b"\r\n".join(out) + b"\r\n"
assert len(out) == len(lines), "line count changed"
for i, (a, b) in enumerate(zip(lines, out), 1):
    if i in changed:
        assert a != b and b.isascii()
        continue
    assert a == b, "line %d changed but is not a translated comment" % i
assert newraw.isascii() if hasattr(newraw, "isascii") else all(c < 128 for c in newraw)
assert newraw.count(b"\r") == newraw.count(b"\n") == len(out)
assert newraw.endswith(b"\r\n")
open(path, "wb").write(newraw)
print("OK %s: translated comment lines %s ; LF-only lines converted to CRLF: %s"
      % (path, changed, lf_fixed))
print("   bytes %d -> %d ; lines %d ; CR %d ; LF %d ; max byte %d"
      % (len(raw), len(newraw), len(out), newraw.count(b"\r"), newraw.count(b"\n"), max(newraw)))
