SEED = 0x9E3779B97F4A7C15
M = (1<<64)-1
def xs(s):
    s ^= (s << 13) & M
    s ^= (s >> 7)
    s ^= (s << 17) & M
    return s & M
# model: byte = state[31:24], take-then-advance
s = SEED; out = bytearray()
for i in range(16):
    out.append((s >> 24) & 0xFF)
    s = xs(s)
print("first16 :", " ".join(f"{b:02X}" for b in out))
print("want    : 7F 0B 02 E5 36 A1 4E D6 1A B0 49 B8 56 AD D6 3F")
# advance to offset 1460
s = SEED
for i in range(1460):
    s = xs(s)
out2 = bytearray()
for i in range(8):
    out2.append((s >> 24) & 0xFF)
    s = xs(s)
print("1460..1467:", " ".join(f"{b:02X}" for b in out2))
print("want      : 03 00 42 2D 9B 47 CA C0")
# state after offset 100
s = SEED
for i in range(100):
    s = xs(s)
print(f"state@100 : {s:#018X}")
print("want      : 0xAB5917A81F0FB2AE")
