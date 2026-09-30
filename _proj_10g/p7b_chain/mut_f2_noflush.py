#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""P7b F-2 attribution: mutation with teeth -- remove the flush (the pre-P6b defect).

MUT-NOFLUSH: in a SCRATCH copy of mac_tx_10g.v (never the real tree; fed to the
gate through %P7B_MUT%, exactly like scripts/mutate_chain.py), the S_ABORT exit
becomes S_IDLE instead of S_FLUSH -- i.e. "中止后只做 state <= S_IDLE", the exact
F-2 defect P6B_CDC_AUDIT.md B8 describes.

Expectation (teeth): the X3 experiment (abort + the aborted frame's own residual
words + TLAST, then a complete B) must now show a GHOST frame = a wire frame whose
content is neither a prefix of an injected frame nor a complete injected frame.
The old content-blind counters (stat_flush_done/words) cannot see it -- that is
exactly why the criterion is wire-content based.

Usage:  <anaconda>/python.exe mut_f2_noflush.py        (gate must be run separately)
"""
import io
import os
import sys

ROOT = 'D:/repo/XCKU5PMini/udp_hls_10g'
SCRATCH = os.path.join(ROOT, '_proj_10g/p7b_chain/_f2_scratch')
MACD = os.path.join(ROOT, '_proj_10g/p7b_mac/rtl')
OLD = ('                S_ABORT: begin\r\n'
       '                    state <= S_FLUSH; flush_cnt <= 4\'d0; flush_tl <= 1\'b0;\r\n'
       '                end')
NEW = ('                S_ABORT: begin\r\n'
       '                    state <= S_IDLE;  // MUT-NOFLUSH: the pre-P6b F-2 defect\r\n'
       '                end')

if not os.path.isdir(SCRATCH):
    os.makedirs(SCRATCH)
# copy the pristine sources (same file set the gate uses)
for src, dst in [(os.path.join(ROOT, 'board/wrapper_p4.v'), 'wrapper_p4.v')] + \
                [(os.path.join(MACD, f), f) for f in ('crc32_64.v', 'mac_rx_10g.v', 'mac_tx_10g.v')]:
    io.open(os.path.join(SCRATCH, dst), 'w', encoding='utf-8', newline='').write(
        io.open(src, 'r', encoding='utf-8', newline='').read())

p = os.path.join(SCRATCH, 'mac_tx_10g.v')
s = io.open(p, 'r', encoding='utf-8', newline='').read()
n = s.count(OLD)
if n != 1:
    raise SystemExit('MUT-NOFLUSH anchor occurs %d times' % n)
s = s.replace(OLD, NEW)
io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('scratch ready: %s (S_ABORT -> S_IDLE, no flush)' % SCRATCH)
