import io, os, re, subprocess, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
REPO = os.path.abspath(".")
def sh(c):
    return subprocess.check_output(c, shell=True, cwd=REPO).decode("utf-8", "replace").splitlines()
files = sorted(set(sh("git ls-files") + sh("git ls-files --others --exclude-standard")))
FAM = [
 ("geometry-NW", re.compile(r"NW=\$\{NW:-(\d+)|SNAP_WORDS=\$\{SNAP_WORDS:-(\d+)|SW=\$\{SNAP_WORDS:-(\d+)|NW_FIX\s*=\s*(\d+)|awk -v NW=(\d+)|localparam\s+integer NW = (\d+)|nnew_top = (\d+)|(?<![\w.])NW=(\d+)(?=[\s;)\"'&|]|$)")),
 ("identity-BID", re.compile(r"EXPECT_BID=\$\{EXPECT_BID:-(0x[0-9A-Fa-f]+)|BID_EXPECT=\$\{BID_EXPECT:-(0x[0-9A-Fa-f]+)|BID_EXPECT=(0x[0-9A-Fa-f]+)|BID_FIX = (0x[0-9A-Fa-f]+)|BIE=(0x[0-9A-Fa-f]+)|FAKE_BID:-?(0x[0-9A-Fa-f]+)|BUILD_ID_V\s*\(\s*32'h([0-9A-Fa-f]+)")),
 ("unimpl-addr", re.compile(r"axil_read\(32'h([0-9A-Fa-f]+)|UNIMPL_ADDR=\$\{UNIMPL_ADDR:-|UNIMPL=\$\(rd (0x1[0-9A-Fa-f]{2})\)|rd (0x1[0-9A-Fa-f]{2})")),
]
tot = {}
for fam, rx in FAM:
    n = 0
    for rel in files:
        if not rel.endswith(".md"):
            continue
        b = open(os.path.join(REPO, rel.replace("/", os.sep)), "rb").read()
        if rx.search(b.decode("utf-8", "replace")):
            n += 1
    tot[fam] = n
    print("MD %-13s %d 文件" % (fam, n))
print("MD 合计 (去重):", len(set(r for fam, rx in FAM for r in files if r.endswith(".md") and rx.search(open(os.path.join(REPO, r.replace('/', os.sep)), 'rb').read().decode('utf-8','replace')))))
