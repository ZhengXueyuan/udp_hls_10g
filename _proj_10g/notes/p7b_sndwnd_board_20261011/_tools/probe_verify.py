# probe_verify.py -- R1 探询帧逐字段核: 长度/seq 对位(与对端同期 ACK 的 ack)/payload==图案流
import struct, sys
SEED = 0x9E3779B97F4A7C15; M64 = (1 << 64) - 1
def read_pcap(path):
    with open(path, "rb") as f:
        gh = f.read(24)
        magic = struct.unpack("<I", gh[:4])[0]
        endian = "<" if magic in (0xA1B2C3D4, 0xA1B23C4D) else ">"
        while True:
            hdr = f.read(16)
            if len(hdr) < 16: break
            ts, tu, caplen, origlen = struct.unpack(endian + "IIII", hdr)
            data = f.read(caplen)
            if len(data) < caplen: break
            yield (ts + tu*1e-6, data, origlen)
def parse(eth):
    if len(eth) < 34: return None
    ip = eth[14:]
    if (ip[0] >> 4) != 4 or ip[9] != 6: return None
    ihl = (ip[0] & 0xF) * 4
    tot = struct.unpack(">H", ip[2:4])[0]
    tcp = ip[ihl:]
    sport, dport = struct.unpack(">HH", tcp[0:4])
    seq, ack = struct.unpack(">II", tcp[4:12])
    doff = (tcp[12] >> 4) * 4
    flags = tcp[13]
    win = struct.unpack(">H", tcp[14:16])[0]
    payload = bytes(tcp[doff:tot-ihl]) if tot >= ihl+doff else b""
    src = ".".join(str(b) for b in ip[12:16])
    return src, sport, dport, seq, ack, flags, win, payload, tot
def gen_pattern_upto(n):
    s = SEED; out = bytearray(n)
    for i in range(n):
        out[i] = (s >> 24) & 0xFF
        s ^= (s << 13) & M64; s ^= s >> 7; s ^= (s << 17) & M64; s &= M64
    return bytes(out)
capA, capB = sys.argv[1], sys.argv[2]
ISN = int(sys.argv[3], 16)   # 板 TCP ISN (SYN 的 seq)
maxoff = 0; probes = []; acks = []
for ts, eth, ol in read_pcap(capA):
    f = parse(eth)
    if not f: continue
    src, sport, dport, seq, ack, flags, win, pl, tot = f
    if src == "192.168.100.2" and len(pl) == 1 and (flags & 0x18) == 0x18:
        probes.append((ts, seq, ack, win, pl[0], tot, ol))
        maxoff = max(maxoff, seq - (ISN + 1))
for ts, eth, ol in read_pcap(capB):
    f = parse(eth)
    if not f: continue
    src, sport, dport, seq, ack, flags, win, pl, tot = f
    if src == "192.168.100.100" and dport == 8080:
        acks.append((ts, ack, win))
acks.sort()
pat = gen_pattern_upto(maxoff + 8)
print("PROBES n=%d (ISN+1=0x%08x)" % (len(probes), ISN+1))
for ts, seq, ack, win, pay, tot, ol in probes:
    off = seq - (ISN + 1)
    # 该探询之前最近一条对端 ACK
    prev = [a for a in acks if a[0] <= ts]
    pv = prev[-1] if prev else None
    match = (pat[off] == pay) if off < len(pat) else None
    print("  t=%.6f seq=0x%08x off=%d pay=0x%02x pat=0x%02x %s | tot_len=%d origlen=%d | ack_field=0x%08x | prev_peer_ack=0x%08x prev_win=%s %s" % (
        ts, seq, off, pay, pat[off], "MATCH" if match else "MISMATCH",
        tot, ol, ack, pv[1] if pv else 0, pv[2] if pv else "-",
        "seq==prev_ack" if pv and pv[1] == seq else "seq!=prev_ack"))
