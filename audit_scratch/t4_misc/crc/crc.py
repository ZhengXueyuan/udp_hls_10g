import zlib, itertools
msg = b"123456789"
raw = zlib.crc32(msg) ^ 0xFFFFFFFF
print("raw ref =", hex(raw))
print("zlib    =", hex(zlib.crc32(msg)))
fcs = raw ^ 0xFFFFFFFF
b = [fcs & 0xFF, (fcs>>8)&0xFF, (fcs>>16)&0xFF, (fcs>>24)&0xFF]
print("fcs bytes LSB-first:", [hex(x) for x in b])
for name, order in [("LSB-first", b), ("MSB-first", b[::-1])]:
    r = raw
    for x in order:
        r ^= x
        for _ in range(8):
            r = (r>>1) ^ (0xEDB88320 if (r & 1) else 0)
    print(name, "residue raw =", hex(r), " zlib =", hex(r ^ 0xFFFFFFFF))
# what FCS bytes would drive raw to 0xDEBB20E3 ?
target = 0xDEBB20E3
# search over all 4-byte sequences is too big; instead check known constant
print("zlib.crc32(msg + fcs LSB) =", hex(zlib.crc32(msg + bytes(b))))
print("0x2144DF1C ^ 0xFFFFFFFF =", hex(0x2144DF1C ^ 0xFFFFFFFF))
