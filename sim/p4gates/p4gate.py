#!/usr/bin/env python
"""P4 default-build regression matrix: path-boundary guard + revision fingerprint.

This file lives next to sim/p4gates/paths.txt (the single source of truth for
repo-relative paths) and is reachable from any gate script as
"%~dp0p4gate.py" / "<gates dir>/p4gate.py" WITHOUT knowing the repo root --
that is deliberate: the guard must be able to reject a wrong root, so it cannot
itself depend on the root being right.

Subcommands
-----------
  guard        --root R --self-root S [--self F]...
        Root must exist, must contain the checkout this tool lives in (S is
        derived from the script's own location), and must contain every
        REQUIRED_MARKERS / REQUIRED_DIRS entry from paths.txt.
        Exit 1 + prints the ACTUAL path on any violation.

  checkpaths   --root R [--manifest F]... [--path P]...
        Every path (and every entry of every manifest) must resolve INSIDE R
        and must exist.  Run before xvlog so a foreign path can never be
        compiled silently.

  manifestcheck --root R --manifest F --bat B
        The manifest (declared file list, hashed into the fingerprint) must
        equal the file list literally present in the gate .bat.  Drift between
        the two representations of the same list = FAIL.

  scanlog      --root R --log L... [--allow P]...
        Post-run: every absolute path appearing in the compile/sim logs must be
        inside R (or under an allowed toolchain prefix).  This is the tripwire
        that catches a hardcoded foreign path even if it slipped past the
        pre-flight checks.  Prints the offending log line + the actual path.

  fingerprint  --root R --out F [--label L]
        Writes path+SHA256+size+mtime for the whole compile set (union of the
        manifests referenced by the runner) plus FINGERPRINT_GLOBS, plus the
        git HEAD / modified-tracked file list, plus a DIGEST_COMPILE summary
        line meant to be echoed into the matrix log header.
        Style follows the project's existing good practice
        (sim/fifoasync/fingerprint.txt: hash the sources, stamp the run) but is
        ASCII-only so it survives a GBK console.

  table
        Prints gate -> bat -> manifest -> env -> args, and the per-manifest
        file list (the "sensitivity surface" table).

Exit codes: 0 = ok, 1 = refused.
"""

import glob
import hashlib
import io
import locale
import os
import re
import subprocess
import sys
import time

# ---- make our own diagnostics unable to kill the tools ----------------------
# Pit 16(1) of this repository, met again here: on a GBK console (this box's
# stdout encoding is cp936/gbk) writing a character the code page cannot encode
# raises UnicodeEncodeError -- and U+FFFD, the very character errors='replace'
# produces, is one of them.  The crash is not a reading, it is a *reporting*
# failure that also turns the exit code into 1 (a reader that judges by exit
# code sees FAIL where the gate said OK).  This script hit it in gatebrief: the
# tail of the `chain` gate console log contains GBK bytes, so the last lines --
# including that gate's verdict line -- never reached the matrix log.
# Same fix as sim/f4sim/f4_verdict.py and tools/*.py.  Note it is byte-neutral
# for ASCII output, so every currently-working invocation prints identically.
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:      # pragma: no cover -- reconfigure needs py3.7+, always ok
    pass

GATES_DIR = os.path.dirname(os.path.abspath(__file__))
PATHS_FILE = os.path.join(GATES_DIR, "paths.txt")
RUNNER_DEFAULT = os.path.join(GATES_DIR, "run_matrix_p4dfix.bat")

WINPATH = re.compile(r"[A-Za-z]:[\\/][^\s\"'<>|*?,;()\[\]]*")
LINECOL = re.compile(r":\d+(?::\d+)?$")


def out(msg):
    sys.stdout.write(msg + "\n")
    sys.stdout.flush()


def ascii_safe(s):
    """Log/git text -> ASCII (the logs must survive a GBK console)."""
    if s is None:
        return ""
    if not isinstance(s, str):
        s = s.decode("utf-8", "replace")
    return s.encode("ascii", "replace").decode("ascii")


def read_console_text(path):
    """Read a gate console log without destroying its non-ASCII bytes.

    A gate console log is written by cmd.exe (console code page -- GBK here)
    and by xsim (ASCII).  Reading it as ASCII with errors='replace' -- what the
    old gatebrief did -- turned every GBK byte into U+FFFD, which no GBK stdout
    can encode (see the reconfigure note at the top).  So: UTF-8 first (a log
    written by one of our own UTF-8 tools), then the console code page, and
    U+FFFD only for bytes broken in both.  ASCII logs decode identically under
    every scheme, so nothing that worked before changes bytes.
    """
    with open(path, "rb") as f:
        raw = f.read()
    encs = ["utf-8"]
    try:
        cp = locale.getpreferredencoding(False)
    except Exception:
        cp = None
    if cp and cp.lower().replace("-", "") != "utf8":
        encs.append(cp)
    for enc in encs:
        try:
            return raw.decode(enc)
        except (UnicodeDecodeError, LookupError):
            continue
    return raw.decode("utf-8", "replace")


def die(msg):
    out("[P4GUARD FAIL] " + msg)
    sys.exit(1)


def split_list(val):
    return [x.strip() for x in (val or "").split(";") if x.strip()]


def read_kv(path):
    d = {}
    with io.open(path, "r", encoding="ascii", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            d[k.strip()] = v.strip()
    return d


def cfg():
    if not os.path.isfile(PATHS_FILE):
        die("missing single-source-of-truth file: %s" % PATHS_FILE)
    return read_kv(PATHS_FILE)


def norm(p):
    return os.path.normcase(os.path.normpath(os.path.abspath(p)))


def is_inside(child, parent):
    c = norm(child)
    p = norm(parent).rstrip("\\/")
    return c == p or c.startswith(p + os.sep)


def strip_linecol(tok):
    for _ in range(2):
        m = LINECOL.search(tok)
        if not m:
            break
        tok = tok[:m.start()]
    return tok.rstrip(".").rstrip("/").rstrip("\\")


def resolve(root, entry):
    entry = entry.strip().strip('"')
    if not entry:
        return None
    if os.path.isabs(entry):
        return os.path.normpath(entry)
    return os.path.normpath(os.path.join(root, entry))


def read_manifest(root, path):
    """Returns (resolved_paths, raw_entries) of a compile manifest."""
    if not os.path.isfile(path):
        die("manifest not found: %s" % path)
    res, raw = [], []
    with io.open(path, "r", encoding="ascii", errors="replace") as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            raw.append(line)
            res.append(resolve(root, line))
    return res, raw


# --------------------------------------------------------------------------
# guard
# --------------------------------------------------------------------------
def cmd_guard(a):
    if not os.path.isdir(a.root):
        die("repo root does not exist / is not a directory:\n    %s" % norm(a.root))
    if a.self_root:
        if not os.path.isdir(a.self_root):
            die("self root (derived from the running script) does not exist:\n"
                "    %s" % norm(a.self_root))
        if not is_inside(a.self_root, a.root):
            die("REFUSING to run: the configured repo root does not contain the\n"
                "  checkout this script lives in -- that is the 'empty gate' mode\n"
                "  (compile somebody else's sources, write logs into somebody else's\n"
                "  repo, exit 0):\n"
                "    configured root : %s\n"
                "    my own root     : %s"
                % (norm(a.root), norm(a.self_root)))
        if norm(a.root) != norm(a.self_root):
            out("[P4GUARD NOTE] root override in effect: configured=%s self=%s"
                % (norm(a.root), norm(a.self_root)))
    k = cfg()
    miss = []
    for rel in split_list(k.get("REQUIRED_MARKERS")):
        if not os.path.isfile(os.path.join(a.root, rel)):
            miss.append(os.path.join(a.root, rel))
    for rel in split_list(k.get("REQUIRED_DIRS")):
        if not os.path.isdir(os.path.join(a.root, rel)):
            miss.append(os.path.join(a.root, rel) + os.sep)
    if miss:
        die("root %s is not this checkout -- missing:\n%s"
            % (norm(a.root), "\n".join("    " + m for m in miss)))
    # the compile manifests must exist too (they are the declared file lists)
    mans = sorted(glob.glob(os.path.join(a.root, k.get("MANIFEST_GLOB", ""))))
    if not mans:
        die("no compile manifests found under %s (pattern %s)"
            % (norm(a.root), k.get("MANIFEST_GLOB")))
    out("[P4GUARD OK] root=%s self=%s manifests=%d"
        % (norm(a.root), norm(a.self_root) if a.self_root else "-", len(mans)))
    return 0


# --------------------------------------------------------------------------
# checkpaths
# --------------------------------------------------------------------------
def cmd_checkpaths(a):
    bad, checked = [], 0
    for p in a.path or []:
        rp = resolve(a.root, p)
        checked += 1
        if not is_inside(rp, a.root):
            bad.append((rp, "outside the repo root"))
        elif not os.path.exists(rp):
            bad.append((rp, "does not exist"))
    for m in a.manifest or []:
        res, raw = read_manifest(a.root, resolve(a.root, m))
        for rp, rr in zip(res, raw):
            checked += 1
            if not is_inside(rp, a.root):
                bad.append((rp, "outside the repo root (manifest %s entry '%s')"
                            % (m, rr)))
            elif not os.path.exists(rp):
                bad.append((rp, "does not exist (manifest %s entry '%s')"
                            % (m, rr)))
    if bad:
        die("path-boundary check failed for %d of %d paths:\n%s"
            % (len(bad), checked,
               "\n".join("    %s  <- %s" % (p, why) for p, why in bad)))
    if not a.quiet:
        out("[P4GUARD OK] checkpaths: %d paths inside %s" % (checked, norm(a.root)))
    return 0


# --------------------------------------------------------------------------
# manifestcheck  (declared list == list literally in the .bat)
# --------------------------------------------------------------------------
XVLOG_HINT = re.compile(r"xvlog\.bat", re.I)
ENVREF = re.compile(r"%([A-Za-z_][A-Za-z0-9_]*)%")


def p4env_var_map(root):
    """{VAR: path} for the variables sim\\p4gates\\p4env.bat exports."""
    m = {}
    for ent in split_list(cfg().get("P4ENV_VARS")):
        if ":" not in ent:
            continue
        name, rel = ent.split(":", 1)
        m[name.strip().upper()] = os.path.normpath(
            os.path.join(root, rel.strip()) if rel.strip() not in (".", "")
            else root)
    return m


def bat_file_list(bat_path, root):
    """Every *.v handed to xvlog in the gate .bat, as root-relative paths.

    A %VAR% the .bat assigns itself is expanded with that literal -- so a
    re-hardcoded foreign path IS caught.  Otherwise the variable is resolved
    through P4ENV_VARS (what sim\\p4gates\\p4env.bat exports).  Toolchain tokens
    (%XV%, %PY%, glbl.v) are skipped.
    """
    text = io.open(bat_path, "r", encoding="ascii", errors="replace").read()
    text = text.replace("^\r\n", " ").replace("^\n", " ")
    envmap = p4env_var_map(root)
    found = []
    varvals = {}
    for line in text.splitlines():
        s = line.strip()
        if s.upper().startswith("SET "):
            kv = s[4:]
            if "=" in kv:
                name, val = kv.split("=", 1)
                varvals[name.strip().strip('"').upper()] = val.strip().strip('"')
            continue
        if not XVLOG_HINT.search(s):
            continue
        for raw in s.split():
            if "xvlog.bat" in raw or "%XV%" in raw or "%PY%" in raw:
                continue
            tok = raw.strip('"')
            if not tok:
                continue
            guard = 0
            unres = False
            while guard < 10:
                guard += 1
                em = ENVREF.match(tok)
                if not em:
                    break
                name = em.group(1).upper()
                if name in varvals:
                    val = varvals[name]
                    if val.upper() == "%" + name + "%":
                        unres = True      # self-referential
                        break
                else:
                    val = envmap.get(name)       # p4env-provided
                    if val is None:
                        unres = True
                        break
                tok = val + tok[em.end():]
            if unres or not tok.lower().endswith(".v"):
                continue
            if "AMDDesignTools" in tok or "anaconda" in tok:
                continue      # the glbl.v toolchain file, not a repo source
            if re.match(r"^[A-Za-z]:", tok):
                rp = os.path.normpath(tok)
            else:
                continue      # unresolved (%~f1 style)
            if is_inside(rp, root):
                found.append(os.path.relpath(rp, root).replace("\\", "/"))
            else:
                found.append("<OUTSIDE-ROOT>" + rp)
    return found


def cmd_manifestcheck(a):
    root = a.root
    bat = resolve(root, a.bat)
    if not os.path.isfile(bat):
        die("gate bat not found: %s" % bat)
    res, raw = read_manifest(root, resolve(root, a.manifest))
    declared = [os.path.relpath(p, root).replace("\\", "/") for p in res]
    present = bat_file_list(bat, root)
    if sorted(declared) != sorted(present):
        only_d = [x for x in declared if x not in present]
        only_b = [x for x in present if x not in declared]
        die("manifest/bat file-list drift for %s:\n"
            "  manifest %s declares %d, bat carries %d\n"
            "  only in manifest : %s\n"
            "  only in bat      : %s"
            % (bat, a.manifest, len(declared), len(present),
               only_d or "-", only_b or "-"))
    out("[P4GUARD OK] manifestcheck %s: %d files == manifest %s"
        % (os.path.basename(bat), len(declared), a.manifest))
    return 0


# --------------------------------------------------------------------------
# scanlog
# --------------------------------------------------------------------------
def cmd_scanlog(a):
    k = cfg()
    allow = [norm(x) for x in split_list(k.get("TOOLCHAIN_ALLOW"))]
    for p in a.allow or []:
        allow.append(norm(p))
    for v in ("TEMP", "TMP"):
        if os.environ.get(v):
            allow.append(norm(os.environ[v]))
    root = norm(a.root)
    logs = list(a.log or [])
    for d in a.logdir or []:
        dd = resolve(a.root, d)
        if not os.path.isdir(dd):
            die("log dir does not exist: %s" % dd)
        logs.extend(sorted(glob.glob(os.path.join(dd, "*.log"))))
    if not logs:
        # No logs = no evidence.  Do NOT report OK (an empty reading is not a
        # pass) and do not fail either: the caller knows whether the gate was
        # supposed to run (exit code 97 = refused before compiling).
        out("[P4GUARD NOTE] scanlog: no log files in %s -- nothing scanned"
            % ", ".join(a.logdir or a.log or []))
        return 0
    nfiles = ntokens = 0
    bad = []
    for lg in logs:
        lp = resolve(a.root, lg)
        if not os.path.isfile(lp):
            bad.append((lg, "<log file missing>", "<log file missing>"))
            continue
        nfiles += 1
        with io.open(lp, "r", encoding="ascii", errors="replace") as f:
            for ln, line in enumerate(f, 1):
                for m in WINPATH.finditer(line):
                    tok = strip_linecol(m.group(0))
                    if len(tok) < 4 or not os.path.isabs(tok):
                        continue
                    ntokens += 1
                    t = norm(tok)
                    if is_inside(t, root):
                        continue
                    if any(is_inside(t, al) or t == al for al in allow):
                        continue
                    bad.append((lg + ":%d" % ln, tok,
                                line.strip()[:160]))
    if bad:
        uniq = sorted(set((b[1] for b in bad)))
        die("compile/sim logs reference %d path(s) OUTSIDE the repo root %s:\n"
            "  distinct offending paths (%d):\n%s\n"
            "  first sightings:\n%s"
            % (len(bad), root, len(uniq),
               "\n".join("    " + u for u in uniq[:20]),
               "\n".join("    %s  %s   |  %s" % b for b in bad[:10])))
    out("[P4GUARD OK] scanlog: %d files, %d path tokens, 0 outside the repo"
        % (nfiles, ntokens))
    return 0


# --------------------------------------------------------------------------
# fingerprint
# --------------------------------------------------------------------------
def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(1 << 20)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def git_lines(root, args):
    try:
        p = subprocess.Popen(["git", "-C", root] + args,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        o, _ = p.communicate(timeout=60)
        if p.returncode != 0:
            return None
        return o.decode("utf-8", "replace").strip().splitlines()
    except Exception:
        return None


def parse_gate_calls(runner):
    """(name, bat, manifest, env, args) for every 'call :gate ...' in runner."""
    rows = []
    text = io.open(runner, "r", encoding="ascii", errors="replace").read()
    for line in text.splitlines():
        s = line.strip()
        m = re.match(r"^call\s+:gate\s+(\S+)\s+(\S+)\s+(\S+)\s+"
                     r"(\"[^\"]*\"|\S+)\s+(\"[^\"]*\"|\S+)\s*$", s, re.I)
        if not m:
            continue
        rows.append((m.group(1), m.group(2), m.group(3),
                     m.group(4).strip('"'), m.group(5).strip('"')))
    return rows


def cmd_fingerprint(a):
    root = a.root
    k = cfg()
    runner = resolve(root, k.get("RUNNER", "sim/p4gates/run_matrix_p4dfix.bat"))
    if not os.path.isfile(runner):
        die("runner not found: %s" % runner)
    rows = parse_gate_calls(runner)
    if not rows:
        die("no 'call :gate' rows parsed out of %s -- fingerprint would be empty"
            % runner)

    man_names = []
    for r in rows:
        if r[2] not in man_names:
            man_names.append(r[2])
    compile_set = []
    for mn in man_names:
        res, _ = read_manifest(root, os.path.join(GATES_DIR, mn))
        for p in res:
            rp = os.path.normpath(p)
            if rp not in compile_set:
                compile_set.append(rp)
    # HLS netlist handed to xsim (hls_files.f content) + .dat side files
    hls_dir = os.path.join(root, k.get("HLS", ""))
    hls = []
    if os.path.isdir(hls_dir):
        for ext in ("*.v", "*.dat"):
            hls.extend(sorted(glob.glob(os.path.join(hls_dir, ext))))
    else:
        die("HLS netlist dir missing: %s" % hls_dir)

    extra = []
    for g in split_list(k.get("FINGERPRINT_GLOBS")):
        for p in sorted(glob.glob(os.path.join(root, g))):
            if os.path.isfile(p):
                extra.append(p)

    allset = []
    for p in compile_set + hls + extra:
        rp = os.path.normpath(p)
        if rp not in allset:
            allset.append(rp)

    lines_c, digest_c = [], hashlib.sha256()
    lines_a, digest_a = [], hashlib.sha256()
    records = []
    for p in allset:
        if not os.path.isfile(p):
            die("fingerprint: file disappeared: %s" % p)
        h = sha256(p)
        st = os.stat(p)
        rec = (os.path.relpath(p, root).replace("\\", "/"), h,
               st.st_size, int(st.st_mtime))
        records.append(rec)
        # CONTENT-ONLY digest line: sha256 + path, no size/mtime, so a file that
        # is rewritten with identical bytes does not change the revision digest
        # (the per-file table below still records size/mtime as metadata).
        ln = "%s  %s\n" % (h, rec[0])
        lines_a.append(ln)
        if p in compile_set or p in hls:
            lines_c.append(ln)
    for ln in sorted(lines_c):
        digest_c.update(ln.encode("ascii"))
    for ln in sorted(lines_a):
        digest_a.update(ln.encode("ascii"))

    rels = [r[0] for r in records]
    mod = git_lines(root, ["diff", "--name-only", "-uno", "HEAD", "--"] + rels)
    head = git_lines(root, ["rev-parse", "--short", "HEAD"])
    subj = git_lines(root, ["log", "-1", "--format=%s"])
    dirty = git_lines(root, ["status", "--porcelain", "-uno", "--"] + rels)

    stamp = time.strftime("%Y/%m/%d %H:%M:%S")
    hdr = [
        "#" * 78,
        "# P4 DEFAULT-BUILD REGRESSION MATRIX -- REVISION FINGERPRINT",
        "#   label      : %s" % a.label,
        "#   repo root  : %s" % norm(root),
        "#   run at     : %s" % stamp,
        "#   git HEAD   : %s%s"
        % (ascii_safe(head[0]) if head else "<git unavailable>",
           ("  " + ascii_safe(subj[0])) if subj else ""),
        "#   compile set: %d files (manifests: %s)"
        % (len(compile_set) + len(hls), ", ".join(man_names)),
        "#   extra      : %d files (generators/bats/criteria)"
        % len(extra),
        "#   total      : %d files hashed" % len(records),
        "#",
        "#   style follows sim/fifoasync/fingerprint.txt (hash the sources, stamp",
        "#   the run) but is ASCII-only, so it survives a GBK console/log.",
        "#" * 78,
    ]
    if dirty is None:
        hdr.append("# git: unavailable (fingerprint still valid)")
    elif dirty:
        hdr.append("# MODIFIED vs HEAD (tracked, inside the hashed set): %d"
                   % len(dirty))
        for d in dirty:
            hdr.append("#   M %s" % ascii_safe(d))
    else:
        hdr.append("# MODIFIED vs HEAD (tracked, inside the hashed set): none")
    hdr.append("")
    body = [
        "",
        "#" * 78,
        "# SUMMARY (this is what the matrix log header prints)",
        "#" * 78,
        "DIGEST_COMPILE = %s" % digest_c.hexdigest(),
        "FILES_COMPILE  = %d" % (len(compile_set) + len(hls)),
        "DIGEST_ALL     = %s" % digest_a.hexdigest(),
        "FILES_ALL      = %d" % len(records),
        "GIT_HEAD       = %s" % (ascii_safe(head[0]) if head else "-"),
        "DIGEST_SCHEME  = content-v1 (sha256+path only; mtime is metadata)",
    ]
    text = "\n".join(hdr) + "\n".join(
        "SHA256 %s  %s  %d  %d" % (h, r, sz, mt) for r, h, sz, mt in
        [(r[0], r[1], r[2], r[3]) for r in sorted(records)]) + "\n" + \
        "\n".join(body) + "\n"
    if a.out:
        op = resolve(root, a.out)
        if not is_inside(op, root):
            die("refusing to write a fingerprint outside the repo: %s" % op)
        try:
            with io.open(op, "w", encoding="ascii", errors="replace",
                         newline="\r\n") as f:
                f.write(text)
        except Exception as e:
            try:
                os.remove(op)          # never leave a truncated fingerprint
            except Exception:
                pass
            die("cannot write the fingerprint %s: %s" % (op, e))
        out("[P4GATE] fingerprint written: %s" % op)
    out("DIGEST_COMPILE = %s" % digest_c.hexdigest())
    out("FILES_COMPILE  = %d" % (len(compile_set) + len(hls)))
    out("DIGEST_ALL     = %s" % digest_a.hexdigest())
    out("FILES_ALL      = %d" % len(records))
    out("GIT_HEAD       = %s" % (ascii_safe(head[0]) if head else "-"))
    return 0


# --------------------------------------------------------------------------
# compare  (revision drift across a run: fingerprint before vs after)
# --------------------------------------------------------------------------
SUMMARY_KEYS = ("DIGEST_COMPILE", "FILES_COMPILE", "DIGEST_ALL", "FILES_ALL",
                "GIT_HEAD")


def read_summary(path):
    """Parse the SUMMARY block.  Key match is on the stripped token either side
    of '=', so the aligned padding in the file cannot silently hide a key (an
    earlier version compared None == None and reported a false FROZEN)."""
    d = {}
    with io.open(path, "r", encoding="ascii", errors="replace") as f:
        for line in f:
            if "=" not in line:
                continue
            k, v = line.split("=", 1)
            k = k.strip()
            if k in SUMMARY_KEYS:
                d[k] = v.strip()
    return d


def read_hashes(path):
    """{relpath: (sha256, size)} from a fingerprint file."""
    d = {}
    with io.open(path, "r", encoding="ascii", errors="replace") as f:
        for line in f:
            if not line.startswith("SHA256 "):
                continue
            p = line.split()
            if len(p) >= 4:
                d[p[2]] = (p[1], p[3])
    return d


def cmd_compare(a):
    pa = resolve(os.getcwd(), a.a)
    pb = resolve(os.getcwd(), a.b)
    for p in (pa, pb):
        if not os.path.isfile(p):
            die("fingerprint file missing: %s" % p)
    x, y = read_summary(pa), read_summary(pb)
    missing = [k for k in SUMMARY_KEYS if k not in x or k not in y]
    if missing:
        die("fingerprint summary key(s) %s missing from %s -- refusing to "
            "declare FROZEN on absent readings"
            % (", ".join(missing), pa if k in x else pb))
    ha, hb = read_hashes(pa), read_hashes(pb)
    if not ha or not hb:
        die("no SHA256 records in %s -- refusing to declare FROZEN"
            % (pa if not ha else pb))
    out("BEFORE  DIGEST_COMPILE=%s  FILES=%s  DIGEST_ALL=%s  HEAD=%s"
        % (x["DIGEST_COMPILE"], x["FILES_COMPILE"], x["DIGEST_ALL"],
           x["GIT_HEAD"]))
    out("AFTER   DIGEST_COMPILE=%s  FILES=%s  DIGEST_ALL=%s  HEAD=%s"
        % (y["DIGEST_COMPILE"], y["FILES_COMPILE"], y["DIGEST_ALL"],
           y["GIT_HEAD"]))
    # The verdict is decided on CONTENT (sha256), never on mtime: a file that
    # was rewritten with identical bytes is not a revision change.  (An earlier
    # version compared the whole "hash path size mtime" record and reported
    # DRIFT for a touched-but-identical file -- the fingerprint evidence itself
    # was fine, the verdict logic was not.)
    changed = sorted(k for k in set(ha) | set(hb) if ha.get(k) != hb.get(k))
    if changed:
        out("VERDICT: DRIFT -- %d participating file(s) CHANGED CONTENT while "
            "the matrix was running; the per-gate results are NOT bound to any "
            "single revision:" % len(changed))
        for k in changed[:20]:
            out("   %s  before=%s  after=%s" % (k, ha.get(k), hb.get(k)))
        return 2
    # recompute the content digest from the records themselves instead of
    # trusting the stored summary (fingerprints written before content-v1 carry
    # a digest that also covered size/mtime)
    d = hashlib.sha256()
    for k in sorted(ha):
        d.update(("%s  %s\n" % (ha[k][0], k)).encode("ascii"))
    recomputed = d.hexdigest()
    out("VERDICT: FROZEN -- all %d hashed files byte-identical across the run; "
        "this log is bound to revision DIGEST_ALL(content)=%s"
        % (len(ha), recomputed))
    if x["DIGEST_ALL"] != recomputed or y["DIGEST_ALL"] != recomputed:
        out("NOTE: the stored DIGEST_ALL in these files was produced by the "
            "pre-content-v1 scheme (it included size/mtime): before=%s after=%s"
            % (x["DIGEST_ALL"], y["DIGEST_ALL"]))
    out("NOTE: the verdict is content identity only -- file mtimes are recorded "
        "as metadata but are not part of it.")
    return 0


# --------------------------------------------------------------------------
# gatebrief  (append the tail of one gate console log to the matrix log)
# --------------------------------------------------------------------------
def cmd_gatebrief(a):
    """Print the tail of one gate console log to STDOUT.

    Deliberately does NOT write the matrix log itself: the caller (the runner)
    already holds that file open for append and a second writer gets
    PermissionError on Windows -- the caller redirects stdout instead.
    """
    src = resolve(os.getcwd(), a.log)
    if not os.path.isfile(src):
        out("(no console log: %s)" % src)
        return 1
    # StringIO keeps readlines()' exact splitting (on '\n' only, terminators
    # kept, no phantom line for a trailing newline) -- only the decoding changed
    lines = io.StringIO(read_console_text(src)).readlines()
    tail = [l.rstrip("\r\n") for l in lines[-a.lines:]]
    out("--- last %d lines of %s" % (len(tail), os.path.basename(src)))
    for l in tail:
        out("| " + l)
    if a.out:
        dest = resolve(os.getcwd(), a.out)
        # utf-8 for the same reason stdout is: the tail is only ASCII-safe by
        # luck, and ascii/replace would quietly write '?' over the gate's own
        # verdict text (the Chinese word for "expected" in the chain gate log);
        # identical bytes while the tail is ASCII.
        with io.open(dest, "a", encoding="utf-8", errors="replace",
                     newline="\r\n") as f:
            f.write("--- last %d lines of %s\n" % (len(tail),
                                                   os.path.basename(src)))
            for l in tail:
                f.write("| " + l + "\n")
    return 0


# --------------------------------------------------------------------------
# selfcheck  (standing tripwire for the repo-wide path fix)
# --------------------------------------------------------------------------
SELF_COMMENT = re.compile(r'^\s*(REM\b|rem\b|#|//|::|;|--|\*|<!--)')


def cmd_selfcheck(a):
    """No LIVE absolute path in this script may point outside the repo.

    This is the tripwire installed in every path-fixed gate script: if someone
    re-hardcodes D:\\repo\\ECO\\... (or any other tree) into a live line, the
    script refuses to run instead of silently testing another checkout.
    Comment lines are ignored on purpose -- they are the historical record.
    """
    k = cfg()
    root = norm(a.root)
    allow = [norm(x) for x in split_list(k.get("TOOLCHAIN_ALLOW"))]
    for v in ("TEMP", "TMP"):
        if os.environ.get(v):
            allow.append(norm(os.environ[v]))
    p = resolve(a.root, a.bat)
    if not os.path.isfile(p):
        die("selfcheck: file not found: %s" % p)
    bad = []
    n = 0
    with io.open(p, "r", encoding="ascii", errors="replace") as f:
        for i, line in enumerate(f, 1):
            if SELF_COMMENT.match(line):
                continue
            for m in WINPATH.finditer(line):
                tok = strip_linecol(m.group(0))
                if len(tok) < 4 or not os.path.isabs(tok):
                    continue
                n += 1
                t = norm(tok)
                if is_inside(t, root):
                    continue
                if any(is_inside(t, al) or t == al for al in allow):
                    continue
                if "%REPO_ROOT%" in tok or "$REPO_ROOT" in tok:
                    continue          # already derived, not a literal
                bad.append((i, tok, line.strip()[:120]))
    if bad:
        die("selfcheck: %s contains %d LIVE absolute path(s) outside %s --\n"
            "  refusing to run (this is exactly the 'empty gate' failure mode):\n%s"
            % (os.path.relpath(p, os.getcwd()) if os.path.isabs(p) else a.bat,
               len(bad), root,
               "\n".join("    %s:%d  %s   |  %s" % (a.bat, i, t, s)
                         for i, t, s in bad[:10])))
    if not a.quiet:
        out("[PATHGUARD OK] selfcheck: %d path token(s), 0 outside the repo"
            % n)
    return 0


# --------------------------------------------------------------------------
# table
# --------------------------------------------------------------------------
def cmd_table(a):
    k = cfg()
    root = os.path.normpath(os.path.join(GATES_DIR, "..", ".."))
    runner = RUNNER_DEFAULT
    rows = parse_gate_calls(runner)
    if not rows:
        die("no 'call :gate' rows parsed out of %s" % runner)
    out("gate            bat                                     "
        "manifest       env                       args")
    out("-" * 118)
    for name, bat, man, env, args in rows:
        out("%-15s %-39s %-14s %-25s %s" % (name, bat, man, env, args))
    out("")
    out("per-manifest compile file list (this is the sensitivity surface):")
    seen = []
    for _, _, man, _, _ in rows:
        if man in seen:
            continue
        seen.append(man)
    for man in seen:
        gates = [r[0] for r in rows if r[2] == man]
        res, raw = read_manifest(root, os.path.join(GATES_DIR, man))
        out("")
        out("== %s  (%d files)  gates: %s" % (man, len(res), ", ".join(gates)))
        for p in res:
            out("     %s" % os.path.relpath(p, root).replace("\\", "/"))
    return 0


# --------------------------------------------------------------------------
def main(argv):
    import argparse
    p = argparse.ArgumentParser(prog="p4gate.py", add_help=True)
    sub = p.add_subparsers(dest="cmd")

    g = sub.add_parser("guard")
    g.add_argument("--root", required=True)
    g.add_argument("--self-root", dest="self_root", default="")
    g.add_argument("--self", action="append")

    c = sub.add_parser("checkpaths")
    c.add_argument("--root", required=True)
    c.add_argument("--manifest", action="append")
    c.add_argument("--path", action="append")
    c.add_argument("--quiet", action="store_true")

    mc = sub.add_parser("manifestcheck")
    mc.add_argument("--root", required=True)
    mc.add_argument("--manifest", required=True)
    mc.add_argument("--bat", required=True)

    s = sub.add_parser("scanlog")
    s.add_argument("--root", required=True)
    s.add_argument("--log", action="append")
    s.add_argument("--logdir", action="append")
    s.add_argument("--allow", action="append")

    f = sub.add_parser("fingerprint")
    f.add_argument("--root", required=True)
    f.add_argument("--out", default="")
    f.add_argument("--label", default="run")

    cp = sub.add_parser("compare")
    cp.add_argument("--a", required=True)
    cp.add_argument("--b", required=True)

    gb = sub.add_parser("gatebrief")
    gb.add_argument("--log", required=True)
    gb.add_argument("--out", default="")
    gb.add_argument("--lines", type=int, default=6)

    sub.add_parser("table")
    sub.add_parser("stamp")

    sc = sub.add_parser("selfcheck")
    sc.add_argument("--root", required=True)
    sc.add_argument("--bat", required=True)
    sc.add_argument("--quiet", action="store_true")

    a = p.parse_args(argv)
    if a.cmd == "guard":
        return cmd_guard(a)
    if a.cmd == "checkpaths":
        return cmd_checkpaths(a)
    if a.cmd == "manifestcheck":
        return cmd_manifestcheck(a)
    if a.cmd == "scanlog":
        return cmd_scanlog(a)
    if a.cmd == "fingerprint":
        return cmd_fingerprint(a)
    if a.cmd == "compare":
        return cmd_compare(a)
    if a.cmd == "selfcheck":
        return cmd_selfcheck(a)
    if a.cmd == "gatebrief":
        return cmd_gatebrief(a)
    if a.cmd == "table":
        return cmd_table(a)
    if a.cmd == "stamp":
        out(time.strftime("%Y%m%d_%H%M%S"))
        return 0
    p.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
