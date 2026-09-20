#!/usr/bin/env python3
"""P5d exp2 analyser: attribute HLS tx frames + cfg records to stimulus frames.

Reads exp2_marks.log / exp2_tx.log / exp2_cfg.log written by tb_hls_slotleak.v
and frames_tags.txt (stimulus frame names) from gen_frames.py.

Black-box only: the HLS internal tcp_conn[] state is BRAM-backed and not
readable from the TB, so the state is inferred from (a) whether a SYN+ACK came
back on the wire and (b) whether a cfg ADD/DEL was pushed to the fast path.
"""
import os
import struct
import sys

TCP_FIN, TCP_SYN, TCP_RST, TCP_PSH, TCP_ACK = 1, 2, 4, 8, 16


def flags_str(f):
    n = []
    for bit, name in ((TCP_SYN, "SYN"), (TCP_ACK, "ACK"), (TCP_FIN, "FIN"),
                      (TCP_RST, "RST"), (TCP_PSH, "PSH")):
        if f & bit:
            n.append(name)
    return "|".join(n) or "-"


def parse_tx_frame(b):
    """b = raw HLS tx bytes incl. 8-byte preamble and trailing CRC."""
    if len(b) < 14:
        return None
    try:
        i = b.index(0xD5)
    except ValueError:
        return None
    b = b[i + 1:]
    if len(b) < 34:
        return None
    eth = b[:14]
    etype = (eth[12] << 8) | eth[13]
    if etype != 0x0800:
        return {"kind": "eth", "etype": "0x%04x" % etype, "len": len(b)}
    ip = b[14:]
    if len(ip) < 20 or (ip[0] >> 4) != 4:
        return None
    ihl = (ip[0] & 0xF) * 4
    proto = ip[9]
    src = ".".join(str(x) for x in ip[12:16])
    dst = ".".join(str(x) for x in ip[16:20])
    if proto != 6:
        return {"kind": "ip", "proto": proto, "src": src, "dst": dst,
                "len": len(b)}
    t = ip[ihl:]
    sport, dport, seq, ack = struct.unpack(">HHII", t[:12])
    doff = (t[12] >> 4) * 4
    fl = t[13]
    plen = len(t) - doff
    return {"kind": "tcp", "sport": sport, "dport": dport, "seq": seq,
            "ack": ack, "flags": fl, "plen": plen, "src": src, "dst": dst}


def load_log(path):
    out = []
    if not os.path.exists(path):
        return out
    with open(path) as f:
        for ln in f:
            p = ln.split()
            if not p:
                continue
            if p[0] == "TX":
                out.append((int(p[1]), int(p[2]), int(p[3], 16)))
            elif p[0] == "CFG":
                out.append((int(p[1]), int(p[2], 16)))
    return out


def main():
    d = sys.argv[1] if len(sys.argv) > 1 else "."
    tags = []
    tp = os.path.join(d, "frames_tags.txt")
    if os.path.exists(tp):
        tags = [x.strip() for x in open(tp) if x.strip()]

    marks = []
    for ln in open(os.path.join(d, "exp2_marks.log")):
        p = ln.split()
        if p and p[0] == "FSTART":
            marks.append(int(p[1]))
    marks.append(1 << 60)

    tx = load_log(os.path.join(d, "exp2_tx.log"))
    cfg = load_log(os.path.join(d, "exp2_cfg.log"))

    # ---- slice tx bytes into frames on the `last` bit ----
    tx_frames = []       # (cycle_of_last_byte, raw_bytes)
    acc = []
    for c, last, b in tx:
        acc.append(b)
        if last:
            tx_frames.append((c, bytes(acc)))
            acc = []

    # ---- slice cfg words into 8-word records ----
    cfg_recs = []        # (cycle, cmd, slot, w0)
    for i in range(0, len(cfg) - 7, 8):
        chunk = cfg[i:i + 8]
        w0 = chunk[0][1]
        cfg_recs.append((chunk[0][0], (w0 >> 8) & 0xFF, w0 & 0xFF, w0))

    print("tx_bytes=%d tx_frames=%d cfg_words=%d cfg_records=%d"
          % (len(tx), len(tx_frames), len(cfg), len(cfg_recs)))
    print("=" * 74)

    n = len(marks) - 1
    for i in range(n):
        t0, t1 = marks[i], marks[i + 1]
        name = tags[i] if i < len(tags) else "frame%d" % i
        tf = [f for f in tx_frames if t0 <= f[0] < t1]
        cr = [r for r in cfg_recs if t0 <= r[0] < t1]
        desc = []
        for _, raw in tf:
            p = parse_tx_frame(raw)
            if p is None:
                desc.append("<unparsed len=%d>" % len(raw))
            elif p["kind"] == "tcp":
                desc.append("TCP %d->%d %s seq=%08x ack=%08x plen=%d"
                            % (p["sport"], p["dport"], flags_str(p["flags"]),
                               p["seq"], p["ack"], p["plen"]))
            else:
                desc.append(str(p))
        cdesc = ["CFG_%s slot=%d w0=%08x" % ("ADD" if r[1] == 0 else
                                             ("DEL" if r[1] == 1 else "?%d" % r[1]),
                                             r[2], r[3]) for r in cr]
        print("[%2d] %-14s win=%d..%d" % (i, name, t0, t1))
        print("     tx  : %s" % ("; ".join(desc) if desc else "(none)"))
        print("     cfg : %s" % ("; ".join(cdesc) if cdesc else "(none)"))

    # ---- verdicts ----
    print("=" * 74)

    def outcome(i):
        t0, t1 = marks[i], marks[i + 1]
        synack = 0
        for c, raw in tx_frames:
            if t0 <= c < t1:
                p = parse_tx_frame(raw)
                if p and p["kind"] == "tcp" and (p["flags"] & TCP_SYN) and (p["flags"] & TCP_ACK):
                    synack += 1
        add = sum(1 for r in cfg_recs if t0 <= r[0] < t1 and r[1] == 0)
        dele = sum(1 for r in cfg_recs if t0 <= r[0] < t1 and r[1] == 1)
        return synack, add, dele

    def show(label, idx):
        if idx >= n:
            print("  %-34s : frame index %d out of range" % (label, idx))
            return
        sa, ad, de = outcome(idx)
        print("  %-34s : SYN+ACK=%d  CFG_ADD=%d  CFG_DEL=%d" % (label, sa, ad, de))

    print("VERDICTS (stimulus index -> HLS reaction):")
    show("A1 SYN (fresh tuple A)", 0)
    show("A2 ACK (3rd handshake)", 1)
    show("A3 SYN-retry same tuple (KEY A)", 2)
    show("B1 SYN (fresh tuple B)", 3)
    show("B2 SYN-retry no-ACK (KEY B)", 4)
    show("A4 peer FIN (frees slot)", 5)
    show("A5 SYN after peer FIN (ctrl)", 6)
    for j in range(4):
        show("X%d SYN 4th distinct tuple" % (j + 1), 7 + j)
    print("=" * 74)


if __name__ == "__main__":
    main()
