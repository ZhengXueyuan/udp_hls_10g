# -*- coding: utf-8 -*-
import io, os, re, subprocess, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
REPO = os.path.abspath(".")
def sh(cmd):
    return subprocess.check_output(cmd, shell=True, cwd=REPO).decode("utf-8", "replace").splitlines()
files = sorted(set(sh("git ls-files") + sh("git ls-files --others --exclude-standard")))
EXT = (".sh", ".bat", ".py", ".v", ".vh", ".tcl", ".ps1", ".cmd")
FAM = [
  ("geometry-NW", re.compile(r"NW=\$\{NW:-(\d+)|SNAP_WORDS=\$\{SNAP_WORDS:-(\d+)|SW=\$\{SNAP_WORDS:-(\d+)|NW_FIX\s*=\s*(\d+)|awk -v NW=(\d+)|nnew_top = (\d+)|localparam\s+integer NW = (\d+)")),
  ("identity-BID", re.compile(r"EXPECT_BID=\$\{EXPECT_BID:-(0x[0-9A-Fa-f]+)|BID_EXPECT=\$\{BID_EXPECT:-(0x[0-9A-Fa-f]+)|BID_FIX = (0x[0-9A-Fa-f]+)|BIE=(0x[0-9A-Fa-f]+)|FAKE_BID:-?(0x[0-9A-Fa-f]+)|BUILD_ID_V\s*\(\s*32'h([0-9A-Fa-f]+)")),
  ("unimpl-addr", re.compile(r"axil_read\(32'h([0-9A-Fa-f]+)|UNIMPL_ADDR=\$\{UNIMPL_ADDR:-|rd (0x1[0-9A-Fa-f]{2})|UNIMPL=\$\(rd (0x1[0-9A-Fa-f]{2})\)")),
]
out = {}
for fam, rx in FAM:
    hits = {}
    for rel in files:
        if not rel.endswith(EXT):
            continue
        p = os.path.join(REPO, rel.replace("/", os.sep))
        try:
            b = open(p, "rb").read()
        except OSError:
            continue
        if b"\x00" in b[:4096]:
            continue
        s = b.decode("utf-8", "replace")
        n = len(rx.findall(s))
        if n:
            hits[rel] = n
    out[fam] = hits
    print("########## %s: %d files" % (fam, len(hits)))
    for k, v in sorted(hits.items()):
        print("   %-72s %d" % (k, v))
