def step(c, b):
    r = c
    for i in range(8):
        r = ((r >> 1) ^ 0xEDB88320) if ((r & 1) ^ ((b >> i) & 1)) else (r >> 1)
    return r
def step_z(c, b):
    r = c ^ b
    for _ in range(8):
        r = (r >> 1) ^ (0xEDB88320 if (r & 1) else 0)
    return r
c = 0xFFFFFFFF
msg = [((k*13) ^ (k>>3)) & 0xFF for k in range(60)]
for k in range(4):
    c = step(c, msg[k]); print("STEP k=%d byte=%02x raw=%08x" % (k, msg[k], c))
for b in msg[4:]: c = step(c, b)
print("RAW60=%08x" % c)
# cross-check the two formulations agree on the whole message
c2 = 0xFFFFFFFF
for b in msg: c2 = step_z(c2, b)
print("RAW60_zlibform=%08x" % c2)
raw = c
fcs = raw ^ 0xFFFFFFFF
print("FCS bytes:", [hex(x) for x in [fcs & 0xFF, (fcs>>8)&0xFF, (fcs>>16)&0xFF, (fcs>>24)&0xFF]])
r = raw
for x in [fcs & 0xFF, (fcs>>8)&0xFF, (fcs>>16)&0xFF, (fcs>>24)&0xFF]:
    r = step(r, x)
print("RESIDUE=%08x" % r)
