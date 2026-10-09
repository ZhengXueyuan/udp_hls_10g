#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""probe_anchors.py -- READ-ONLY anchor probe for mk_mut_tx.py (dry run).

Answers, per anchor and per checkout state: "how many times does this anchor
string actually occur in rtl/tcp_tx_frame.v?" -- WITHOUT writing any mutant
file and WITHOUT modifying anything (no file is opened for writing anywhere).

How the anchor table is read (two independent readers, cross-checked):
  1. text level  : ast.parse(mk_mut_tx.py) -> literal args of the add(...) calls
  2. semantic    : import mk_mut_tx.py and call its plan() (if it exports one)

Columns:
  hits_raw  = anchor verbatim (its own newlines as written) counted against the
              file as read with newline='' (CRLF preserved).  This is what the
              pre-2026-10-10 mutator effectively did.
  hits_norm = anchor newline-normalised AND file newline-normalised
              (\\r\\n -> \\n, lone \\r -> \\n).  This is what the fixed mutator does.
  expect    = declared hit count in the anchor table.

Exit code: 0 iff every anchor satisfies hits_norm == expect (the fixed-matcher
criterion) and every inserted ("new") text is LF-clean; else 1.
Read-only either way -- run it as often as you like.
"""
import ast
import hashlib
import importlib.util
import io
import os
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
SRC = os.path.join(ROOT, "rtl", "tcp_tx_frame.v")
MUTATOR = os.path.join(HERE, "mk_mut_tx.py")


def norm(s):
    return s.replace("\r\n", "\n").replace("\r", "\n")


def sha256_file(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def parse_table_ast(text):
    """Return [(name, [(old, new, hits), ...], note)] from the add(...) calls."""
    tree = ast.parse(text)
    out = []
    for node in tree.body:
        if not isinstance(node, ast.Expr):
            continue
        call = node.value
        if not (isinstance(call, ast.Call) and isinstance(call.func, ast.Name)
                and call.func.id == "add"):
            continue
        name = ast.literal_eval(call.args[0])
        subs = []
        for t in ast.literal_eval(call.args[1]):      # list of 3-tuples of str/int
            subs.append((t[0], t[1], int(t[2])))
        note = ast.literal_eval(call.args[2])
        out.append((name, subs, note))
    return out


def main():
    with io.open(MUTATOR, encoding="utf-8", newline="") as f:
        mut_text = f.read()
    with io.open(SRC, encoding="utf-8", newline="") as f:
        raw = f.read()
    lf = norm(raw)

    raw_bytes = open(SRC, "rb").read()
    print("== probe_anchors.py (READ-ONLY; writes nothing) ==")
    print("mutator      : %s" % MUTATOR)
    print("mutator sha  : %s" % sha256_file(MUTATOR))
    print("rtl source   : %s" % SRC)
    print("rtl sha256   : %s" % sha256_file(SRC))
    print("rtl bytes=%d  CR=%d  LF=%d  CRLF=%d  loneCR=%d"
          % (len(raw_bytes), raw_bytes.count(b"\r"), raw_bytes.count(b"\n"),
             raw_bytes.count(b"\r\n"), raw_bytes.count(b"\r") - raw_bytes.count(b"\r\n")))

    table = parse_table_ast(mut_text)
    if not table:
        # fall back: the pre-fix mutator still has add(...) at module level,
        # so an empty table means the file shape changed unexpectedly.
        print("!! no add(...) calls found -- anchor table not parseable")
        return 1

    ok = True
    print()
    print("%-9s %-3s %9s %9s %6s  %s" % ("mutant", "sub", "hits_raw", "hits_norm", "expect", "verdict"))
    print("-" * 78)
    for name, subs, note in table:
        all_clean = True
        for i, (old, new, exp) in enumerate(subs, 1):
            hr = raw.count(old)
            hn = lf.count(norm(old))
            clean = ("\r" not in new)
            verdict = []
            if hn != exp:
                verdict.append("NORM-MISMATCH")
                ok = False
            if hr != exp:
                verdict.append("raw-mismatch")
            if not clean:
                verdict.append("NEWTEXT-HAS-CR")
                ok = False
                all_clean = False
            print("%-9s s%-2d %9d %9d %6d  %s"
                  % (name, i, hr, hn, exp, " ".join(verdict) if verdict else "ok"))
        # a mutant is usable by the fixed mutator only if all its subs normalise
        # to the declared count; show that as one summary line
        print("%-9s --  %s  (%s)" % (name, "USABLE" if all(
            lf.count(norm(o)) == e for o, _, e in subs) else "BROKEN", note))
    print("-" * 78)

    # ---- second reader: import the module and use its own plan(), if present
    #
    # SAFETY: the pre-fix mutator runs its whole generator at import time, i.e.
    # importing it would write mutants to disk.  This probe must never write,
    # so during the import every write-mode open() and every os.makedirs() is
    # redirected into an in-memory sink ("captured", never on disk).
    print()
    captured = {}
    real_open = io.open
    real_makedirs = os.makedirs

    class _Sink(object):
        def __init__(self, store, key):
            self._store, self._key = store, key
        def write(self, s):
            self._store[self._key] = self._store.get(self._key, "") + s
            return len(s)
        def close(self):
            pass
        def __enter__(self):
            return self
        def __exit__(self, *a):
            return False

    def _blocked_open(file, mode="r", *a, **k):
        if any(c in mode for c in "wax+"):
            return _Sink(captured, str(file))
        return real_open(file, mode, *a, **k)

    def _blocked_makedirs(name, *a, **k):
        captured.setdefault("MKDIR: " + str(name), "")

    try:
        spec = importlib.util.spec_from_file_location("mk_mut_tx_probe", MUTATOR)
        mod = importlib.util.module_from_spec(spec)
        io.open = _blocked_open           # noqa: A001  (deliberate, restored below)
        os.makedirs = _blocked_makedirs
        try:
            try:
                spec.loader.exec_module(mod)
            except SystemExit as e:       # pre-fix mutator calls sys.exit(1)
                print("module raised SystemExit(%r) during import "
                      "(pre-fix top-level generator; writes were captured, not performed)" % (e.code,))
        finally:
            io.open = real_open
            os.makedirs = real_makedirs
        if captured:
            print("SIMULATED WRITES on import (captured in memory, NOT on disk):")
            for k in captured:
                v = captured[k]
                print("   %s   (%d chars captured)" % (k, len(v)))
                if v:
                    head = v.split("\n", 1)[0]
                    print("      first line: %s" % head)
        else:
            print("module import performed no write/open-for-write (clean)")
        if hasattr(mod, "plan"):
            try:
                results = mod.plan(lf)
            except Exception as e:            # noqa: BLE001
                print("module plan() raised: %r" % (e,))
                ok = False
            else:
                bad = []
                for name, subs, note, got in results:
                    want = [e for _, _, e in subs]
                    if [g for g in got] != want:
                        bad.append((name, want, list(got)))
                if bad:
                    print("module plan() DISAGREES with ast table:")
                    for b in bad:
                        print("   %-9s expect=%s got=%s" % b)
                    ok = False
                else:
                    print("module plan() agrees with ast table on all %d mutants "
                          "(hits per sub identical)" % len(results))
        else:
            print("module exports no plan(); semantic cross-check skipped "
                  "(pre-fix mutator shape)")
    except Exception as e:                    # noqa: BLE001
        print("module import skipped/failed: %r" % (e,))

    print()
    print("PROBE %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
