#!/usr/bin/env python3
# pc_wire_pattern_check.py -- independent wire-level check of the PC peer's TX pattern.
# Reads UDP payloads (hex, one per line, from `tshark -T fields -e udp.payload`) and
# verifies each against the RTL xorshift64 pattern (rtl/app_udp_pattern.v /
# rtl/app_pattern.v: take s>>24 FIRST, then advance; seed 0x9E3779B97F4A7C15).
# Frames are consecutive slices of one continuous stream; a hole is resynced by a
# search, a value error is reported byte-by-byte.
import sys

MASK = (1 << 64) - 1
SEED = 0x9E3779B97F4A7C15
RESYNC_HORIZON = 1 << 16


def xs_next(s):
    s ^= (s << 13) & MASK
    s ^= (s >> 7)
    s ^= (s << 17) & MASK
    return s & MASK


class Seq:
    """lazy byte stream of the RTL pattern"""

    def __init__(self):
        self.s = SEED
        self.buf = bytearray()
        self.base = 0          # sequence position of buf[0]

    def extend_to(self, pos):
        need = pos - (self.base + len(self.buf))
        if need <= 0:
            return
        s = self.s
        buf = self.buf
        for _ in range(need):
            buf.append((s >> 24) & 0xFF)
            s = xs_next(s)
        self.s = s

    def get(self, pos, n):
        self.extend_to(pos + n)
        i = pos - self.base
        return bytes(self.buf[i:i + n])


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/pcpay.txt"
    maxbad = int(sys.argv[2]) if len(sys.argv) > 2 else 20
    lines = [l.strip() for l in open(path) if len(l.strip()) > 16]
    seq = Seq()
    pos = 0
    nframes = 0
    nhole = 0
    hole_bytes = 0
    bad_frames = 0
    bad_bytes = 0
    first_bad = []
    prev_pay = None
    for li, hx in enumerate(lines):
        pay = bytes.fromhex(hx)
        plen = len(pay)
        # npcap delivers each TX frame 2-3x on this NIC (capture artifact):
        # drop an exact repeat of the immediately preceding payload.
        if pay == prev_pay:
            continue
        prev_pay = pay
        exp = seq.get(pos, plen)
        if pay == exp:
            nframes += 1
            pos += plen
            continue
        # resync: look for a 32-byte anchor of this payload ahead in the stream
        anchor = pay[:32]
        found = None
        for off in range(plen, RESYNC_HORIZON):
            if seq.get(pos + off, 32) == anchor:
                found = off
                break
        if found is not None:
            nhole += 1
            hole_bytes += found
            pos += found
            exp = seq.get(pos, plen)
            if pay == exp:
                nframes += 1
                pos += plen
                continue
        bad_frames += 1
        for i in range(plen):
            if pay[i] != exp[i]:
                bad_bytes += 1
                if len(first_bad) < maxbad:
                    first_bad.append((li, i, pay[i], exp[i]))
        pos += plen
        nframes += 1
    print("frames=%d payload_bytes=%d holes=%d hole_bytes=%d" %
          (nframes, pos, nhole, hole_bytes))
    print("BAD frames=%d bad bytes=%d" % (bad_frames, bad_bytes))
    for li, i, got, want in first_bad:
        print("  frame#%d byte_off=%d got=%02X want=%02X" % (li, i, got, want))


main()
