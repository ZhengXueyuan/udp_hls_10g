#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""alias_dir_check.py -- static port-direction trace for pure-alias assigns.

Why this face exists (2026-10-10, the p5_wrapper red)
-----------------------------------------------------
`board/wrapper_p4.v:2771-2775` (the `ifndef DP_156MHZ` TX single-domain alias
block) had all five `assign`s swapped, so `m_tx_tvalid` / `txsrc_tready` were
left UNDRIVEN (Z) in that configuration: the whole TX path is dead there.
The live lint entries structurally cannot see this class:

  * Vivado 2025.2 prints NOTHING for an undriven net (measured 2026-10-10:
    zero hits for m_tx_tvalid / txsrc_tready / m_tx_tready in the gate's
    xvlog_w.log and xelab_w.log);
  * `board/run_lint_p6e.bat`'s macro set is PCIE_OBS+DEV_USP+APP_MODE (no
    DP_156MHZ) => it compiles exactly the buggy branch and prints LINT-OK
    (measured negative control 2026-10-10, see the aliasgate report).

So this file is a NEW face: a pure-text port-direction trace.  No simulator,
no toolchain, ~2 s.

Criterion (exact, deliberately narrow)
--------------------------------------
For `assign X = Y;` with both sides a single identifier, in an ACTIVE `ifdef
branch:

    X is driven by an OUTPUT port of an instantiated module  (ndrv[X] != [])
    AND
    Y has NO driver -- not an instance output port, not a decl-init
    (`wire Y = ...`), not the LHS of any other assign, not a concat-LHS
    member, not a reg, not an input/inout port of its enclosing module
  ==>  REVERSED (verdict red, exit 1).  X ends up double-driven and Y floats.

Other cases:
  * Y driven, X not port-driven            -> correct (a plain alias)
  * X port-driven AND Y driven             -> MULTI-DRIVER (also red: two
                                              drivers on one net is a defect)
  * neither side traceable                 -> UNRESOLVED (printed with a
                                              count; NOT a failure -- this
                                              face covers the pure-alias form
                                              only; see the report's coverage
                                              boundary section)

Self-trust instrument
---------------------
The port-table parser is re-checked against 18 hand-verified
(module, port, direction) facts on EVERY run.  A mismatch is a HARD FAIL
(exit 1): a silent parser regression would otherwise turn this gate into a
sieve.  Line endings are normalised (\r\n -> \n, lone \r -> \n) before any
regex, so CRLF (rtl/tcp_rx.v), LF (rtl/tcb.v) and mixed files all work.

Exit codes: 0 = clean, 1 = reversed alias found (or parser selfcheck failed),
            2 = usage / missing input.
"""

import argparse
import glob
import os
import re
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:                                  # pragma: no cover
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))

# the live gate target: the only wrapper that any live build/gate compiles
GATE_TARGETS = ["board/wrapper_p4.v"]

# the two macro combinations the board actually uses
CONFIGS = [
    ("A_appmode_only", {"APP_MODE"}),
    ("G_appmode_dp156", {"APP_MODE", "DP_156MHZ"}),
]

# hand-verified port directions (module, port, direction) -- re-checked on
# every run; any mismatch = HARD FAIL (the instrument must not trust itself)
PORT_SELFCHECK = [
    ("tx_arb", "m_axis_tvalid", "output"),
    ("tx_arb", "m_axis_tready", "input"),
    ("tx_arb", "s_fast_tready", "output"),
    ("mac_tx_64", "s_axis_tready", "output"),
    ("mac_tx_64", "s_axis_tvalid", "input"),
    ("tcp_tx_frame", "m_axis_tready", "input"),
    ("tcp_tx_frame", "m_axis_tvalid", "output"),
    ("app_ctrl", "dbg_c0_state", "output"),
    ("app_ctrl", "rst_req", "output"),
    ("app_pattern", "m_tready", "input"),
    ("app_pattern", "stat_tx_bytes", "output"),
    ("axis_pipe", "s_ready", "output"),
    ("axis_pipe", "m_valid", "output"),
    ("fifo_sync", "full", "output"),
    ("clk_gen_p6b", "clk_dp", "output"),
    ("fifo_async", "full", "output"),
    ("tcb", "rb_state", "output"),
    ("app_udp_pattern", "m_tvalid", "output"),
]

PAT_PORT = re.compile(
    r'\b(input|output|inout)\b\s*'
    r'(?:wire|reg|signed|unsigned|logic)?\s*'
    r'((?:\[[^\]]*\]\s*)*)'
    r'([A-Za-z_]\w*(?:\s*,\s*(?!(?:input|output|inout|wire|reg|signed|'
    r'unsigned|logic)\b)[A-Za-z_]\w*)*)')

ASSIGN_RE = re.compile(r'(?m)^[ \t]*assign\s+([A-Za-z_]\w*)\s*=\s*([^;]+);')
IDENT_RE = re.compile(r'[A-Za-z_]\w*$')


def read_norm(path):
    """Read a source file, normalise line endings, report the ending census."""
    with open(path, "rb") as f:
        raw = f.read()
    crlf = raw.count(b"\r\n")
    lone_lf = raw.count(b"\n") - crlf
    lone_cr = raw.count(b"\r") - crlf
    txt = raw.decode("utf-8", "replace")
    txt = txt.replace("\r\n", "\n").replace("\r", "\n")
    return txt, (crlf, lone_lf, lone_cr)


def blank_comments(t):
    """Replace comments with equal-length blanks (newlines kept) so that every
    character offset still maps 1:1 onto the original text."""
    out = list(t)
    i = 0
    while i < len(t):
        if t.startswith('/*', i):
            j = t.find('*/', i + 2)
            j = len(t) - 2 if j < 0 else j
            for k in range(i, min(j + 2, len(t))):
                if out[k] != '\n':
                    out[k] = ' '
            i = j + 2
        elif t.startswith('//', i):
            j = t.find('\n', i)
            j = len(t) if j < 0 else j
            for k in range(i, j):
                out[k] = ' '
            i = j
        else:
            i += 1
    return ''.join(out)


def skip_paren(t, k):
    """t[k] == '(' -> index of the matching ')'."""
    depth = 0
    while k < len(t):
        if t[k] == '(':
            depth += 1
        elif t[k] == ')':
            depth -= 1
            if depth == 0:
                return k
        k += 1
    return len(t) - 1


def collect_ports(t):
    """{module: {port: direction}} for every module defined in t."""
    out = {}
    for m in re.finditer(r'\bmodule\s+([A-Za-z_]\w*)', t):
        name = m.group(1)
        k = m.end()
        while k < len(t) and t[k].isspace():
            k += 1
        if k < len(t) and t[k] == '#':
            p = t.find('(', k)
            if p < 0:
                continue
            k = skip_paren(t, p) + 1
            while k < len(t) and t[k].isspace():
                k += 1
        if k >= len(t) or t[k] != '(':
            continue
        e = skip_paren(t, k)
        hdr = t[k:e + 1]
        endm = t.find('endmodule', e)
        body = t[e:endm if endm > 0 else len(t)]
        d = out.setdefault(name, {})
        for pm in PAT_PORT.finditer(hdr + '\n' + body):
            dr = pm.group(1)
            for nm in [x.strip() for x in pm.group(3).split(',')]:
                if nm and nm not in d:
                    d[nm] = dr
    return out


def module_spans(t):
    """[(module, start, end)] -- used to attribute an assign to its module."""
    spans = []
    for m in re.finditer(r'(?m)^[ \t]*module\s+([A-Za-z_]\w*)', t):
        endm = t.find('endmodule', m.end())
        spans.append((m.group(1), m.start(),
                      endm if endm > 0 else len(t)))
    return spans


def enclosing_module(spans, off):
    best = None
    for name, a, b in spans:
        if a <= off < b:
            if best is None or a > best[1]:
                best = (name, a)
    return best[0] if best else None


def active_lines(t, macros):
    """line-start-offset -> is this line inside an ACTIVE ifdef branch."""
    act = {}
    stack = []
    off = 0
    for line in t.split('\n'):
        s = line.strip()
        act[off] = all(x[0] for x in stack)
        if s.startswith('`ifdef'):
            mac = s.split()[1] if len(s.split()) > 1 else ''
            stack.append((mac in macros, True))
        elif s.startswith('`ifndef'):
            mac = s.split()[1] if len(s.split()) > 1 else ''
            stack.append((mac not in macros, True))
        elif s.startswith('`else'):
            if stack:
                taken, first = stack.pop()
                stack.append(((not taken) if first else False, False))
        elif s.startswith('`endif'):
            if stack:
                stack.pop()
        off += len(line) + 1
    return act


def find_insts(t, act, portmap):
    """[(module, instance, {port: net}, offset)] for active instantiations."""
    res = []
    for m in re.finditer(r'(?m)^[ \t]*([A-Za-z_]\w*)[ \t]*', t):
        mod = m.group(1)
        if mod not in portmap or mod == 'module':
            continue
        ls = t.rfind('\n', 0, m.start()) + 1
        if not act.get(ls, True):
            continue
        k = m.end()
        if k < len(t) and t[k] == '#':
            p = t.find('(', k)
            if p < 0:
                continue
            k = skip_paren(t, p) + 1
        while k < len(t) and t[k].isspace() and t[k] != '\n':
            k += 1
        nm = re.match(r'([A-Za-z_]\w*)\s*\(', t[k:])
        if not nm:
            continue
        inst = nm.group(1)
        p = t.find('(', k + nm.end() - 1)
        e = skip_paren(t, p)
        body = t[p:e + 1]
        conns = {}
        for cm in re.finditer(r'\.(\w+)\s*\(\s*([^()]*?)\s*\)', body):
            conns[cm.group(1)] = cm.group(2).strip()
        if conns:
            res.append((mod, inst, conns, m.start()))
    seen = set()
    out = []
    for r in res:
        if r[3] in seen:
            continue
        seen.add(r[3])
        out.append(r)
    return out


def decls(t, act):
    """(wires, regs, init_driven) declared in active branches."""
    wires, regs, initw = set(), set(), set()
    for m in re.finditer(r'(?m)^[ \t]*(wire|reg)\b([^;]*);', t):
        ls = t.rfind('\n', 0, m.start()) + 1
        if not act.get(ls, True):
            continue
        kind = m.group(1)
        tail = m.group(2)
        if '=' in tail:
            lhs = tail.split('=', 1)[0]
            for nm in re.findall(r'[A-Za-z_]\w*',
                                 re.sub(r'\[[^\]]*\]', ' ', lhs)):
                initw.add(nm)
        tail = re.sub(r'\[[^\]]*\]', ' ', tail)
        for nm in re.findall(r'[A-Za-z_]\w*', tail):
            (wires if kind == 'wire' else regs).add(nm)
    return wires, regs, initw


def analyze(text, macros, portmap, spans, cfg_name):
    """Returns dict with the per-config verdict."""
    act = active_lines(text, macros)
    insts = find_insts(text, act, portmap)
    ndrv = {}          # net -> [ 'inst.port', ... ] driven by instance OUTPUT ports
    for mod, inst, conns, off in insts:
        pm = portmap.get(mod, {})
        for port, net in conns.items():
            if not IDENT_RE.match(net):
                continue
            if pm.get(port, '?') == 'output':
                ndrv.setdefault(net, []).append('%s.%s' % (inst, port))

    aliases = []       # (lhs, rhs, offset)
    expr_lhs = set()
    for m in ASSIGN_RE.finditer(text):
        ls = text.rfind('\n', 0, m.start()) + 1
        if not act.get(ls, True):
            continue
        lhs, rhs = m.group(1), m.group(2).strip()
        if IDENT_RE.match(rhs):
            aliases.append((lhs, rhs, m.start()))
        else:
            expr_lhs.add(lhs)

    concat_lhs = set()
    for m in re.finditer(r'(?m)^[ \t]*assign\s*\{([^}]*)\}\s*=\s*([^;]+);', text):
        ls = text.rfind('\n', 0, m.start()) + 1
        if not act.get(ls, True):
            continue
        for nm in re.findall(r'[A-Za-z_]\w*', m.group(1)):
            concat_lhs.add(nm)

    wires, regs, initw = decls(text, act)
    alias_lhs = set(l for l, _, _ in aliases)

    # fixpoint: which aliases have an untraceable RHS (the RHS is not itself
    # the LHS of a live alias, and has no other driver)
    def external_driver(n, mod):
        """True if net n has a driver other than a pure-alias chain."""
        if n in ndrv or n in expr_lhs or n in concat_lhs or n in initw \
                or n in regs:
            return True
        enc = portmap.get('__encl__' + (mod or ''), {})
        if enc.get(n) in ('input', 'inout'):
            return True
        return False

    bad = set()
    changed = True
    while changed:
        changed = False
        for i, (l, r, off) in enumerate(aliases):
            if i in bad:
                continue
            mod = enclosing_module(spans, off)
            if external_driver(r, mod):
                continue
            if any(l2 == r and j not in bad
                   for j, (l2, _, _) in enumerate(aliases)):
                continue
            bad.add(i)
            changed = True

    rows = []
    n_ok = n_rev = n_multi = n_und = 0
    for i, (l, r, off) in enumerate(aliases):
        mod = enclosing_module(spans, off)
        dl = ndrv.get(l, [])
        enc = portmap.get('__encl__' + (mod or ''), {})
        r_extra = []
        if r in ndrv:
            r_extra.append('inst-out')
        if r in initw:
            r_extra.append('decl-init')
        if r in expr_lhs:
            r_extra.append('assign-lhs')
        if r in concat_lhs:
            r_extra.append('concat-lhs')
        if r in regs:
            r_extra.append('reg')
        if enc.get(r) in ('input', 'inout'):
            r_extra.append('module-%s-port' % enc[r])
        # Y is driven if it has any real driver, or if some OTHER alias drives
        # it and that alias is itself not untraceable (j not in bad)
        rdrv = bool(r_extra) or any(
            l2 == r and j not in bad for j, (l2, _, _) in enumerate(aliases))
        line = text.count('\n', 0, off) + 1
        if dl and not rdrv:
            v = 'REVERSED'
            n_rev += 1
        elif dl and rdrv:
            v = 'MULTI-DRIVER'
            n_multi += 1
        elif i in bad:
            v = 'UNRESOLVED'
            n_und += 1
        elif rdrv:
            v = 'ok'
            n_ok += 1
        else:
            v = 'UNRESOLVED'
            n_und += 1
        rows.append(dict(line=line, lhs=l, rhs=r, verdict=v,
                         x_drv=','.join(dl), y_drv=','.join(r_extra)))
    return dict(cfg=cfg_name, n_alias=len(aliases), ok=n_ok, rev=n_rev,
                multi=n_multi, und=n_und, rows=rows, n_inst=len(insts))


def build_portmap(root, verbose=True):
    srcs = []
    for sub in ('rtl', 'board'):
        srcs += sorted(glob.glob(os.path.join(root, sub, '*.v')))
    srcs += sorted(glob.glob(os.path.join(
        root, 'hls', 'slowstack_prj', 'solution1', 'syn', 'verilog', '*.v')))
    portmap = {}
    for f in srcs:
        t, _ = read_norm(f)
        for k, v in collect_ports(blank_comments(t)).items():
            d = portmap.setdefault(k, {})
            for a, b in v.items():
                if a not in d:
                    d[a] = b
    if verbose:
        print('# port table : %d modules from %d source files (%s)'
              % (len(portmap), len(srcs), os.path.basename(root)))
    return portmap


def parser_selfcheck(portmap):
    bad = []
    for mod, port, exp in PORT_SELFCHECK:
        got = portmap.get(mod, {}).get(port, '?')
        if got != exp:
            bad.append((mod, port, exp, got))
    print('# parser selfcheck: %d/%d port directions match the hand-verified '
          'table' % (len(PORT_SELFCHECK) - len(bad), len(PORT_SELFCHECK)))
    for mod, port, exp, got in bad:
        print('# SELFCHECK-FAIL %s.%s = %s (expected %s)' % (mod, port, got, exp))
    return not bad


def enclosing_ports(text, portmap):
    """Add '__encl__<module>' entries: the port table OF the target file's own
    modules (an input port of the enclosing module IS driven, from outside)."""
    own = collect_ports(blank_comments(text))
    for mod, tbl in own.items():
        portmap['__encl__' + mod] = tbl


def check_file(path, root, macros_list, portmap, quiet=False):
    """Returns (rc, results, endings).  rc: 0 clean, 1 red, 2 unreadable."""
    if not os.path.isfile(path):
        print('FAIL: file not found: %s' % path)
        return 2, [], None
    text, endings = read_norm(path)
    spans = module_spans(blank_comments(text))
    enclosing_ports(text, portmap)
    rel = os.path.relpath(path, root).replace('\\', '/')
    print('== %s  (line endings: CRLF=%d LF=%d CR=%d)'
          % (rel, endings[0], endings[1], endings[2]))
    rc = 0
    results = []
    for cfg_name, macs in macros_list:
        r = analyze(text, macs, portmap, spans, cfg_name)
        results.append(r)
        print('-- config %s (macros=%s): aliases=%d ok=%d REVERSED=%d '
              'MULTI=%d unresolved=%d (insts=%d)'
              % (cfg_name, ','.join(sorted(macs)), r['n_alias'], r['ok'],
                 r['rev'], r['multi'], r['und'], r['n_inst']))
        for row in r['rows']:
            if row['verdict'] in ('REVERSED', 'MULTI-DRIVER'):
                print('   %s %s:%d  assign %s = %s;   [X driven by: %s] '
                      '[Y driven by: %s]'
                      % (row['verdict'], rel, row['line'], row['lhs'],
                         row['rhs'], row['x_drv'] or '-', row['y_drv'] or '-'))
        print('   SUMMARY %s %s aliases=%d rev=%d multi=%d unresolved=%d'
              % (rel, cfg_name, r['n_alias'], r['rev'], r['multi'], r['und']))
        if r['rev'] or r['multi']:
            rc = 1
    if not quiet and rc == 0:
        print('ALIAS-DIR OK (%s): no reversed / multi-driven pure alias in any '
              'requested config' % rel)
    return rc, results, endings


def discover_wrappers(root):
    pats = ['board/*.v', 'sim/**/*.v', '_proj_10g/**/*.v', 'vivado_prj/**/*.v']
    out = []
    for p in pats:
        for f in glob.glob(os.path.join(root, p), recursive=True):
            try:
                with open(f, 'rb') as fh:
                    head = fh.read(200000)   # enough for a module header
            except OSError:
                continue
            if re.search(rb'(?m)^[ \t]*module[ \t]+wrapper', head):
                out.append(f)
    return sorted(set(out))


def main(argv):
    ap = argparse.ArgumentParser(prog='alias_dir_check.py')
    ap.add_argument('--root', default=DEFAULT_ROOT)
    ap.add_argument('--file', action='append', default=[],
                    help='target .v (repeatable); default = the live gate '
                         'target board/wrapper_p4.v')
    ap.add_argument('--scan-all', action='store_true',
                    help='audit sweep over every wrapper-class file in the '
                         'repo (report only; never sets a red exit code)')
    ap.add_argument('--macros', default='',
                    help='override the config list, e.g. "APP_MODE" or '
                         '"APP_MODE+DP_156MHZ"')
    ap.add_argument('--list-configs', action='store_true')
    a = ap.parse_args(argv)

    root = os.path.normpath(a.root)
    if not os.path.isdir(root):
        print('FAIL: root not a directory: %s' % root)
        return 2
    if a.list_configs:
        for n, m in CONFIGS:
            print('%s = %s' % (n, ','.join(sorted(m))))
        return 0

    macro_list = CONFIGS
    if a.macros:
        macro_list = [('CLI', set(x for x in a.macros.split('+') if x))]

    portmap = build_portmap(root)
    if not parser_selfcheck(portmap):
        print('ALIAS-DIR FAIL: the port table parser failed its own selfcheck '
              '-- refusing to report a verdict from a mistrusted instrument')
        return 1

    if a.scan_all:
        files = discover_wrappers(root)
        print('# audit sweep: %d wrapper-class file(s)' % len(files))
        nrev_total = 0
        for f in files:
            rc, res, _ = check_file(f, root, macro_list, portmap, quiet=True)
            nrev_total += sum(r['rev'] + r['multi'] for r in res)
            print('   SWEEP %s  rc=%d  rev/multi=%s'
                  % (os.path.relpath(f, root).replace('\\', '/'), rc,
                     '/'.join(str(r['rev'] + r['multi']) for r in res)))
        print('# audit sweep total reversed/multi rows = %d (audit mode: exit 0)'
              % nrev_total)
        return 0

    targets = a.file or [os.path.join(root, p) for p in GATE_TARGETS]
    rc_all = 0
    for t in targets:
        rc, _, _ = check_file(t, root, macro_list, portmap)
        rc_all = max(rc_all, rc)
    if rc_all:
        print('ALIAS-DIR FAIL: reversed / multi-driven pure alias found '
              '(see rows above)')
    return rc_all


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
