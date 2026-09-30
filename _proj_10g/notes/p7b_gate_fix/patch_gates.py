# -*- coding: utf-8 -*-
"""P7b gate-harness fix: byte-level patches of the gate driver scripts.

Every edit is asserted (exact occurrence count) and the CRLF invariant is
re-checked after each write, so a silently mangled .bat cannot pass.
Run:  C:/Users/zhxue/anaconda3/python.exe patch_gates.py [--revert-check]
"""
import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    '..', '..', '..'))
EDITS = []


def rw(rel, old, new, count=1):
    p = os.path.join(ROOT, rel)
    b = open(p, 'rb').read()
    c = b.count(old)
    assert c == count, '%s: expected %d occurrence(s), found %d' % (rel, count, c)
    open(p, 'wb').write(b.replace(old, new))
    b2 = open(p, 'rb').read()
    assert b2.count(b'\r\n') == b2.count(b'\n'), rel + ': CRLF/LF mismatch'
    EDITS.append((rel, count))
    print('OK  %-44s x%d' % (rel, count))


NEWLINE = b'\r\n'

# --- 1/2: rx_classify unit gates -- v2 added a fifo_sync instance, the two
#         gates' compile sets (rtl/rx_classify.v + tb) never got the new file
for rel in ('sim/p4sim/run_tb_rxclass.bat', 'sim/p4sim/run_tb_rxclass_xk.bat'):
    rw(rel,
       b'-work xil_defaultlib ..\\..\\rtl\\rx_classify.v ..\\..\\tb\\tb_rx_classify.v',
       b'-work xil_defaultlib ..\\..\\rtl\\rx_classify.v ..\\..\\rtl\\fifo_sync.v'
       b' ..\\..\\tb\\tb_rx_classify.v')

# --- 3: p4_replay -- a REM line carrying %1/%2 *and* non-ASCII text is re-parsed
#         by cmd: it printed "'CACK' is not recognized..." and ran a garbage
#         command before the simulation.  ASCII-only comment + a real verdict.
rel = 'sim/p4sim/run_tb_p4_replay.bat'
b = open(os.path.join(ROOT, rel), 'rb').read()
hits = [l for l in b.split(NEWLINE) if l.startswith(b'REM') and b'%1' in l and b'%2' in l]
assert len(hits) == 1, hits
rw(rel, hits[0],
   b'REM   arg1 = NOPCACK (default +PCACK); arg2 = run log name (default xsim_run.log)')
rw(rel,
   b'call %XV%\\xsim.bat tb_p4_chain -runall %XPA% -log %RUNLOG% > NUL 2>&1'
   b' || (type %RUNLOG% & exit /b 1)' + NEWLINE,
   b'call %XV%\\xsim.bat tb_p4_chain -runall %XPA% -log %RUNLOG% > NUL 2>&1'
   b' || (type %RUNLOG% & exit /b 1)' + NEWLINE +
   b'REM verdict (2026-09-30): the xsim exit code alone cannot tell "ran to the end"' + NEWLINE +
   b'REM from "never started / died early" -- the TB must reach its final DONE line.' + NEWLINE +
   b'findstr /C:"DONE rx" %RUNLOG% >NUL || (echo [P4_REPLAY FAIL] TB never reached'
   b' its final DONE line: & type %RUNLOG% & exit /b 1)' + NEWLINE +
   b'findstr /C:"DONE rx" %RUNLOG%' + NEWLINE +
   b'exit /b 0' + NEWLINE)

# --- 4: p5c_t3/rev wrapper elab check -- (a) the APP_MODE branch instantiates
#         udp_tx_cfg/udp_tx_frame, which were not in RTLF => hard elab failure
#         that the gate swallowed ('echo DONE' was its last line, always exit 0).
rel = 'sim/p5c_t3/rev/run_wrapper_elab_chk.bat'
rw(rel,
   b'%RTL%\\udp_rx.v %RTL%\\udp_split.v %RTL%\\tx_arb.v',
   b'%RTL%\\udp_rx.v %RTL%\\udp_split.v %RTL%\\tx_arb.v'
   b' %RTL%\\udp_tx_cfg.v %RTL%\\udp_tx_frame.v')
rw(rel,
   b'echo DONE (logs: wchk\\xv_a.log xv_b.log xe_a.log xe_b.log)' + NEWLINE,
   b'REM --- verdict (2026-09-30): this gate used to end on "echo DONE" => exit 0' + NEWLINE +
   b'REM even when xelab had hard-failed (it swallowed a real "Module <udp_tx_cfg>' + NEWLINE +
   b'REM / <udp_tx_frame> not found" for both build configs).  Any ERROR line in' + NEWLINE +
   b'REM either elab log is now a hard failure.' + NEWLINE +
   b'findstr /C:"ERROR" xe_a.log xe_b.log >NUL' + NEWLINE +
   b'if not errorlevel 1 (' + NEWLINE +
   b'  echo [ELAB-CHK FAIL] xelab reported ERROR in one of the two configs:' + NEWLINE +
   b'  findstr /C:"ERROR" xe_a.log xe_b.log' + NEWLINE +
   b'  exit /b 1' + NEWLINE +
   b')' + NEWLINE +
   b'echo [ELAB-CHK PASS] both configs elaborated with 0 ERROR lines' + NEWLINE +
   b'echo DONE (logs: wchk\\xv_a.log xv_b.log xe_a.log xe_b.log)' + NEWLINE +
   b'exit /b 0' + NEWLINE)

print('\n%d file(s) patched' % len(set(e[0] for e in EDITS)))
