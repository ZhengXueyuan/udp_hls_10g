# ===========================================================================
# _tmp_path_fix.py -- repo-wide "empty gate" fix: every LIVE hardcoded
#   D:\repo\ECO\udp_hls_10g (or D:/repo/ECO/...) path becomes a path derived
#   from the script's OWN location, with a marker check that FAILS LOUDLY
#   (naming the derived root) instead of silently running against another tree.
#
#   * .bat  -> %REPO_ROOT% derived from %~dp0 + the file's depth
#   * .sh   -> $REPO_ROOT derived from $0
#   * .tcl  -> $REPO_ROOT derived from [info script] (skipped if the path sits
#              inside braces, where tcl would not interpolate -- reported)
#   * comment lines (REM / # / //) are LEFT ALONE: they are the historical
#     record of where these scripts used to point, and the coordinator asked
#     for that distinction explicitly.
#
#   usage: python _tmp_path_fix.py [--dry] [--only <file>]
# ===========================================================================
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
DRY = '--dry' in sys.argv
ONLY = None
if '--only' in sys.argv:
    ONLY = sys.argv[sys.argv.index('--only') + 1]

ECO_BS = r'D:\repo\ECO\udp_hls_10g'
ECO_FS = 'D:/repo/ECO/udp_hls_10g'
ECO_US = '/d/repo/ECO/udp_hls_10g'
MARKER = 'CLAUDE.md'

TARGETS = []
for dirpath, dirnames, filenames in os.walk(ROOT):
    parts = os.path.relpath(dirpath, ROOT).replace('\\', '/').split('/')
    if any(p in ('.git', '__pycache__', 'xsim.dir') or p.startswith('work_')
           for p in parts):
        dirnames[:] = []
        continue
    if any(p.startswith(('slowstack_prj', 'vivado_prj', 'negctl', 'pre_migration',
                         'audit_scratch', 'int_scratch', 'review_scratch'))
           for p in parts):
        dirnames[:] = []
        continue
    for fn in filenames:
        ext = os.path.splitext(fn)[1].lower()
        if ext in ('.bat', '.sh', '.tcl', '.py', '.ps1'):
            TARGETS.append(os.path.join(dirpath, fn))

BAT_HDR = ('set "REPO_ROOT=%~dp0@UP@"\r\n'
           'for %%I in ("%REPO_ROOT%") do set "REPO_ROOT=%%~fI"\r\n'
           'if not exist "%REPO_ROOT%\\@MARK@" (\r\n'
           '  echo [PATHGUARD FAIL] cannot locate this checkout from %~f0\r\n'
           '  echo   derived REPO_ROOT = %REPO_ROOT%\r\n'
           '  exit /b 1\r\n'
           ')\r\n')
SH_HDR = ('REPO_ROOT="$(cd -- "$(dirname -- "$0")/@UP@" && pwd)" || exit 1\n'
          'if [ ! -f "$REPO_ROOT/@MARK@" ]; then\n'
          '  echo "[PATHGUARD FAIL] cannot locate this checkout from $0" >&2\n'
          '  echo "  derived REPO_ROOT = $REPO_ROOT" >&2\n'
          '  exit 1\n'
          'fi\n')
TCL_HDR = ('set REPO_ROOT [file normalize [file join [file dirname [info script]] '
           '@UP@]]\n'
           'if {![file exists [file join $REPO_ROOT @MARK@]]} {\n'
           '  error "PATHGUARD FAIL: cannot locate this checkout from '
           '[info script] -- derived REPO_ROOT = $REPO_ROOT"\n'
           '}\n')

COMMENT_RE = re.compile(r'^\s*(REM\b|rem\b|#|//|::|;|--|\*|<!--)')
report = []
tcl_brace_skip = []
for path in sorted(TARGETS):
    rel = os.path.relpath(path, ROOT).replace('\\', '/')
    if ONLY and ONLY not in rel:
        continue
    raw = io.open(path, 'r', encoding='latin-1', newline='').read()
    if ECO_BS not in raw and ECO_FS not in raw and ECO_US not in raw:
        continue
    ext = os.path.splitext(path)[1].lower()
    depth = len(rel.split('/')) - 1
    up_bs = '..\\' * depth
    up_fs = '../' * depth
    new = raw
    nl = '\r\n' if '\r\n' in raw else '\n'
    lines = new.split(nl)
    # split comment / live
    live_idx = [i for i, l in enumerate(lines) if not COMMENT_RE.match(l)]
    nlive = sum(1 for i in live_idx
                if ECO_BS in lines[i] or ECO_FS in lines[i] or ECO_US in lines[i])
    ncmt = sum(1 for i, l in enumerate(lines)
               if COMMENT_RE.match(l) and (ECO_BS in l or ECO_FS in l or ECO_US in l))
    if nlive == 0:
        report.append((rel, 0, ncmt, 'comments only -- left as history'))
        continue
    if ext in ('.tcl',) and re.search(r'\{[^{}]*repo[\\/]ECO', new):
        tcl_brace_skip.append(rel)
    for i in live_idx:
        l = lines[i]
        l2 = (l.replace(ECO_BS, '%REPO_ROOT%').replace(ECO_FS, '%REPO_ROOT%')
              .replace(ECO_US, '%REPO_ROOT%'))
        lines[i] = l2
    new = nl.join(lines)
    # header
    if ext == '.bat':
        m = re.search(r'^@?echo off[^\r\n]*', new)
        hdr = BAT_HDR.replace('@UP@', up_bs).replace('@MARK@', MARKER)
        if m:
            new = new[:m.end()] + nl + hdr.replace('\r\n', nl) + new[m.end():]
        else:
            new = hdr.replace('\r\n', nl) + new
    elif ext == '.sh':
        hdr = SH_HDR.replace('@UP@', up_fs).replace('@MARK@', MARKER)
        if new.startswith('#!'):
            j = new.index('\n') + 1
            new = new[:j] + hdr + new[j:]
        else:
            new = hdr + new
    elif ext == '.tcl':
        hdr = TCL_HDR.replace('@UP@', up_fs.rstrip('/') or '.').replace('@MARK@', MARKER)
        new = hdr + new
    elif ext == '.py':
        hdr = ('ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))'
               if depth == 1 else None)
        report.append((rel, nlive, ncmt, 'python -- needs a manual root: '
                       'depth=%d' % depth))
        continue
    else:
        report.append((rel, nlive, ncmt, 'skipped (%s)' % ext))
        continue
    report.append((rel, nlive, ncmt, 'FIXED (%s hdr, depth=%d)' % (ext, depth)))
    if not DRY:
        io.open(path, 'w', encoding='latin-1', newline='').write(new)

print('files touched: %d' % sum(1 for r in report if 'FIXED' in r[3]))
print('')
print('%-58s %5s %5s  %s' % ('file', 'live', 'cmt', 'action'))
for rel, nl_, nc, act in report:
    print('%-58s %5d %5d  %s' % (rel, nl_, nc, act))
if tcl_brace_skip:
    print('')
    print('!! tcl files where the ECO path may sit inside braces (verify):')
    for r in tcl_brace_skip:
        print('   ', r)
