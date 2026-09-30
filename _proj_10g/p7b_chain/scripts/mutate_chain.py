#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""P7b chain-gate mutation suite.

Each mutation is applied to a SCRATCH COPY of the offending source (never to the
real tree), the real-wrapper chain gate is re-run against that copy via %P7B_MUT%,
and the verdict must flip to FAIL -- and for the mutations whose target judgement
is known, that judgement must be among the failures (a gate that fails for the
wrong reason is not a gate).

Usage:  python mutate_chain.py            (needs a clean chain-gate PASS first)
"""
import io
import os
import re
import shutil
import subprocess
import sys

ROOT = 'D:/repo/XCKU5PMini/udp_hls_10g'
SIM = os.path.join(ROOT, '_proj_10g/p7b_chain/sim')
MUTDIR = os.path.join(ROOT, '_proj_10g/p7b_chain/_mut_rtl')
LOGDIR = os.path.join(ROOT, '_proj_10g/p7b_chain/_mut_logs')
MACD = os.path.join(ROOT, '_proj_10g/p7b_mac/rtl')

# (name, source-relative file, old, new, expected failing labels)
MUTS = [
    # NOTE: the first attempt at M1 touched `default:` -- unreachable for
    # lo in {0,4}, i.e. an EQUIVALENT mutation; the gate PASSing was correct.
    ('M1_rx_mirror_off', 'mac_rx_10g.v',
     '                3\'d0: align8 = {w[7:0],   w[15:8],  w[23:16], w[31:24],',
     '                3\'d0: align8 = {w[63:56], w[55:48], w[47:40], w[39:32],',
     ['1b RX first byte==content[0]', '1c RX 1st byte!=lane7 byte']),
    ('M2_tx_mirror_off', 'mac_tx_10g.v',
     '            for (i = 0; i < 8; i = i + 1) bswap64[i*8 +: 8] = d[(7-i)*8 +: 8];',
     '            for (i = 0; i < 8; i = i + 1) bswap64[i*8 +: 8] = d[i*8 +: 8];  // MUT',
     ['6e TX content lane order', '6f TX w2 lane order']),
    ('M4_snap_slot_shift', 'wrapper_p4.v',
     '        p7bdp_dout[0*32 +: 32],    // W39 PCS \u72b6\u6001\u675f',
     '        p7bdp_dout[2*32 +: 32],    // W39 PCS \u72b6\u6001\u675f   // MUT: slot shifted',
     ['7 W39[2] block_lock', '7 W39[4] hi_ber']),
    # ---- F2X11 (2026-09-30): the two mutations behind the false-positive fix ----
    # M5 = "pad back OUT of the CRC" = DEFECT-REG #1 restored (notes/P7B_F2_CHAIN_ATTRIB.md
    #   section 10).  Caught by the wire-side TB-crc32 oracle AND by our own RX (tcrs).
    #   The X6 "RX bytes==content+pad" criteria must stay GREEN here (the delivered bytes
    #   really are identical -- only the FCS differs): that is the discrimination proof.
    ('M5_pad_nocrc', 'mac_tx_10g.v',
     '    wire [7:0]  crc_keep = (state == S_TAIL0)\r\n'
     '                           ? ((p0_rst != 6\'d0) ? 8\'hFF : (8\'hFF << (5\'d8 - p0_use)))\r\n'
     '                           : (cw_last ? (8\'hFF << (5\'d8 - lw_ts)) : cw_keep);\r\n'
     '    wire [63:0] crc_d    = (state == S_TAIL0) ? 64\'d0 : (cw_data & cmask64(cw_len));\r\n'
     '    wire        crc_en   = (state == S_DATA)  ? (cw_len != 4\'d0)\r\n'
     '                         : (state == S_TAIL0) ? 1\'b1 : 1\'b0;\r\n',
     '    // MUT-PADNOCRC: pad lanes NOT fed into the CRC (pre-2026-09-30 behaviour)\r\n'
     '    wire [7:0]  crc_keep = (state == S_TAIL0) ? 8\'h00\r\n'
     '                           : (cw_last ? (8\'hFF << (5\'d8 - {1\'b0, cw_len})) : cw_keep);\r\n'
     '    wire [63:0] crc_d    = (state == S_TAIL0) ? 64\'d0 : cw_data;\r\n'
     '    wire        crc_en   = (state == S_DATA) && (cw_len != 4\'d0);\r\n',
     ['X5a pad frame complete+padFCS',
      'X6a 20B wire complete+padFCS', 'X6a 20B RX tcrs=1 len=60',
      'X6b 42B wire complete+padFCS', 'X6b 42B RX tcrs=1 len=60',
      'X6c 54B wire complete+padFCS', 'X6c 54B RX tcrs=1 len=60',
      'own RX (REGISTERED DEFECT #1)']),
    # M6 = "no flush" = the pre-P6b F-2 defect: real GHOST frames on the wire.  This is the
    #   negative control for the F2X11 classifier fix: the FIXED classifier must still label
    #   those frames kind=0 (measured: logs/f2x11_mut_noflush_FINAL.log kind=0 at X1b f1/f2,
    #   X3 f1/f2/f3) -- i.e. the fix is pad-aware, NOT a blanket relax.
    ('M6_noflush', 'mac_tx_10g.v',
     '                S_ABORT: begin\r\n'
     '                    state <= S_FLUSH; flush_cnt <= 4\'d0; flush_tl <= 1\'b0;\r\n'
     '                end',
     '                S_ABORT: begin\r\n'
     '                    state <= S_IDLE;  // MUT-NOFLUSH: the pre-P6b F-2 defect\r\n'
     '                end',
     ['X3 no ghost at all', 'X4 no B on the wire', 'exactly 1 wire frame (runt only)']),
    # NOTE (equivalent, deliberately NOT a table entry -- it would make MUT_VERDICT REVIEW):
    #   MUT-DUMPOLD = put the dump_raw() print indices back to the stale group-8 window
    #   (wf_start/wf_stop).  Measured 2026-09-30: 80 checks / 0 fail, byte-identical criteria
    #   to the pristine run => the dump_raw fix is print/forensics only, no criterion depends
    #   on it (log: logs/f2x11_mut_dumpold_FINAL.log; TB copy in _f2_scratch_tb/).
]


def copy_scratch():
    if os.path.isdir(MUTDIR):
        shutil.rmtree(MUTDIR)
    os.makedirs(MUTDIR)
    shutil.copy(os.path.join(ROOT, 'board/wrapper_p4.v'), MUTDIR)
    for f in ('crc32_64.v', 'mac_rx_10g.v', 'mac_tx_10g.v'):
        shutil.copy(os.path.join(MACD, f), MUTDIR)


def apply_mut(name, fname, old, new):
    p = os.path.join(MUTDIR, fname)
    s = io.open(p, 'r', encoding='utf-8', newline='').read()
    n = s.count(old)
    if n == 1:
        s = s.replace(old, new)
    elif n == 0 and 'DEFAULT' in name:
        raise SystemExit('%s: anchor not found in %s' % (name, fname))
    else:
        raise SystemExit('%s: anchor occurs %d times in %s' % (name, n, fname))
    io.open(p, 'w', encoding='utf-8', newline='').write(s)


def run_gate(name):
    env = dict(os.environ)
    env['P7B_MUT'] = MUTDIR.replace('/', '\\')
    r = subprocess.run(['cmd', '/c', r'_proj_10g\p7b_chain\sim\run_tb_p7b_chain.bat'],
                       cwd=ROOT, env=env, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT)
    out = r.stdout.decode('utf-8', 'replace')
    if not os.path.isdir(LOGDIR):
        os.makedirs(LOGDIR)
    io.open(os.path.join(LOGDIR, name + '.log'), 'w', encoding='utf-8').write(out)
    xlog = os.path.join(SIM, 'xsim_p7bchain.log')
    txt = io.open(xlog, 'r', encoding='utf-8', errors='replace').read() if os.path.isfile(xlog) else ''
    return r.returncode, txt


def main():
    only = sys.argv[1] if len(sys.argv) > 1 else None
    results = []
    for name, fname, old, new, expect in MUTS:
        if only and only not in name:
            continue
        copy_scratch()
        apply_mut(name, fname, old, new)
        rc, log = run_gate(name)
        verdict = 'PASS' if 'VERDICT = PASS' in log else ('FAIL' if 'VERDICT = FAIL' in log else 'NO-VERDICT')
        fails = re.findall(r'\[FAIL\] (.{0,40}?)\s+src=', log)
        caught = [e for e in expect if any(e in f for f in fails)]
        results.append((name, verdict, rc, len(fails), len(caught), len(expect)))
        print('%-22s verdict=%-10s rc=%d fails=%2d expected-caught=%d/%d'
              % (name, verdict, rc, len(fails), len(caught), len(expect)))
        for f in fails[:6]:
            print('        fail: %s' % f)
    print('MUT_SUMMARY')
    for r in results:
        print('  %-22s %s rc=%d fails=%d caught=%d/%d' % r)
    ok = all(r[1] == 'FAIL' and r[4] == r[5] for r in results)
    print('MUT_VERDICT = %s' % ('PASS (all non-equivalent mutations caught, by the expected criteria)' if ok else 'REVIEW'))


if __name__ == '__main__':
    main()
