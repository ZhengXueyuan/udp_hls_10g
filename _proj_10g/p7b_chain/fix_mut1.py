# -*- coding: utf-8 -*-
"""Retarget M1 at the REAL mirror site: the lo=0 lane-reversal.  The first
attempt touched `default:` which is unreachable for lo in {0,4} -- an equivalent
mutation, so the gate PASSing was correct, not a gap."""
import io

P = 'D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/p7b_chain/scripts/mutate_chain.py'
s = io.open(P, 'r', encoding='utf-8', newline='').read()

old = """    ('M1_rx_mirror_off', 'mac_rx_10g.v',
     '                default: align8 = 64\\'d0;',
     '                default: align8 = w;   // MUT: no 8-byte mirror',
     ['1b RX 1st byte==content[0]', '1c RX 1st byte!=lane7 byte']),"""
assert s.count(old) == 1, s.count(old)
new = """    # NOTE: the first attempt at M1 touched `default:` -- unreachable for
    # lo in {0,4}, i.e. an EQUIVALENT mutation; the gate PASSing was correct.
    ('M1_rx_mirror_off', 'mac_rx_10g.v',
     '                3\\'d0: align8 = {w[7:0],   w[15:8],  w[23:16], w[31:24],',
     '                3\\'d0: align8 = {w[63:56], w[55:48], w[47:40], w[39:32],',
     ['1b RX 1st byte==content[0]', '1c RX 1st byte!=lane7 byte']),"""
s = s.replace(old, new)
io.open(P, 'w', encoding='utf-8', newline='').write(s)
print('M1 retargeted')
