#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""MUT-PADNOCRC: put the pad back OUT of the CRC -- i.e. re-create DEFECT-REG #1
(notes/P7B_F2_CHAIN_ATTRIB.md section 10) in a SCRATCH copy of mac_tx_10g.v that the
gate picks up through %P7B_MUT% (never the real tree).

Undo of the 2026-09-30 fix (git diff HEAD -- _proj_10g/p7b_mac/rtl/mac_tx_10g.v):
  fixed : crc_keep covers the pad lanes (lw_ts / p0_use), crc_en is 1 in S_TAIL0
  mutant: crc_keep covers only the content lanes, crc_en is 0 outside S_DATA
=> the wire FCS of a padded frame becomes crc32(content only) instead of
   crc32(content ++ pad), so the wire frame keeps its length/content/pad but the
   4 FCS bytes are wrong for every <60B-content frame.

Teeth expected (all from the F2X11 criteria, none from counters):
  * X5a "pad frame not ghost (F2X11)"      -> kind 2 -> 3 (still not a ghost: it IS
                                              our frame, so that one stays green)
  * X5a "own RX ... (REGISTERED DEFECT #1)" -> FAIL (crc_err +1)
  * X6a/b/c "wire complete+padFCS"          -> FAIL (TB crc32 oracle over on-wire bytes)
  * X6a/b/c "RX tcrs=1 len=60"              -> FAIL
  * X5c (68B, no pad) must stay green       -> the mutation is pad-only
Usage:  <anaconda>/python.exe mut_f2_padnocrc.py   (run the gate separately with %P7B_MUT%)
"""
import io
import os

ROOT = 'D:/repo/XCKU5PMini/udp_hls_10g'
SCRATCH = os.path.join(ROOT, '_proj_10g/p7b_chain/_f2_scratch_pad')
MACD = os.path.join(ROOT, '_proj_10g/p7b_mac/rtl')

OLD = ('    wire [7:0]  crc_keep = (state == S_TAIL0)\r\n'
       '                           ? ((p0_rst != 6\'d0) ? 8\'hFF : (8\'hFF << (5\'d8 - p0_use)))\r\n'
       '                           : (cw_last ? (8\'hFF << (5\'d8 - lw_ts)) : cw_keep);\r\n'
       '    wire [63:0] crc_d    = (state == S_TAIL0) ? 64\'d0 : (cw_data & cmask64(cw_len));\r\n'
       '    wire        crc_en   = (state == S_DATA)  ? (cw_len != 4\'d0)\r\n'
       '                         : (state == S_TAIL0) ? 1\'b1 : 1\'b0;\r\n')
NEW = ('    // MUT-PADNOCRC: pad lanes NOT fed into the CRC (pre-2026-09-30 behaviour)\r\n'
       '    wire [7:0]  crc_keep = (state == S_TAIL0) ? 8\'h00\r\n'
       '                           : (cw_last ? (8\'hFF << (5\'d8 - {1\'b0, cw_len})) : cw_keep);\r\n'
       '    wire [63:0] crc_d    = (state == S_TAIL0) ? 64\'d0 : cw_data;\r\n'
       '    wire        crc_en   = (state == S_DATA) && (cw_len != 4\'d0);\r\n')

if not os.path.isdir(SCRATCH):
    os.makedirs(SCRATCH)
for src, dst in [(os.path.join(ROOT, 'board/wrapper_p4.v'), 'wrapper_p4.v')] + \
                [(os.path.join(MACD, f), f) for f in ('crc32_64.v', 'mac_rx_10g.v', 'mac_tx_10g.v')]:
    io.open(os.path.join(SCRATCH, dst), 'w', encoding='utf-8', newline='').write(
        io.open(src, 'r', encoding='utf-8', newline='').read())

p = os.path.join(SCRATCH, 'mac_tx_10g.v')
s = io.open(p, 'r', encoding='utf-8', newline='').read()
if s.count(OLD) != 1:
    raise SystemExit('MUT-PADNOCRC anchor occurs %d times' % s.count(OLD))
s = s.replace(OLD, NEW)
io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('scratch ready: %s (pad lanes removed from the CRC)' % SCRATCH)
