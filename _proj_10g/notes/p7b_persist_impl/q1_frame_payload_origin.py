# -*- coding: utf-8 -*-
# Q1 步 2: 从帧上 16 字节原始截面反解 "这帧的载荷到底取自哪个流偏移"
#   判据: 对每条红帧, 在 s = o+[-3*65536 .. +3*65536] 范围里搜
#         使 fb(CBASE*c + s + k) == obs[k] 命中最多的 s (逐位精确, 无拟合参数)
M32 = 0xFFFFFFFF
CBASE = 0x0010_0000
ISN = {0: 0x0000_F100, 1: 0x0001_2300}

def fb(i):
    x = ((i & M32) * 0x9E3779B1) & M32
    x ^= 0x5A5A5A5A
    x &= M32
    x ^= (x >> 15)
    x = (x * 0x85EBCA6B) & M32
    x ^= (x >> 13)
    x = (x * 0xC2B2AE35) & M32
    x ^= (x >> 16)
    return (x >> 16) & 0xFF

def hx(s):
    return [int(t, 16) for t in s.split()]

# (来源, conn, fseq, plen, 帧上载荷前 16 字节)
FRAMES = [
    ("S#1", 0, 0x000de510, 1460, hx("cf 38 c3 dc 40 ca a0 ee 62 20 4b d7 f9 22 36 26")),
    ("S#2", 1, 0x0004e59c,   29, hx("ae 42 83 ee d7 94 42 da 2d 03 65 2a b6 0a e7 a8")),
    ("S#3", 1, 0x0004e5a4,   21, hx("2d 03 65 2a b6 0a e7 a8 01 d8 ff ab bd b0 83 60")),
]

for tag, c, fseq, plen, obs in FRAMES:
    o = fseq - ISN[c]
    best = None
    for lap in range(-3, 4):
        for sh in range(-16, 17):
            s = o + lap * 65536 + sh
            hit = sum(1 for k in range(16) if fb(CBASE * c + s + k) == obs[k])
            if best is None or hit > best[0]:
                best = (hit, lap, sh, s)
    hit, lap, sh, s = best
    print(f"[{tag}] conn={c} fseq={fseq:08x} plen={plen} 帧内流偏移 o={o}")
    print(f"   帧上 16 字节 = {['%02x' % b for b in obs]}")
    print(f"   最优解释: 流偏移 s={s} = o {lap:+d}圈 {sh:+d}字节 -> 命中 {hit}/16 字节")
    print(f"   按 o 直算应得 16 字节 = "
          f"{['%02x' % fb(CBASE*c + o+k) for k in range(16)]} (命中 "
          f"{sum(1 for k in range(16) if fb(CBASE*c+o+k)==obs[k])}/16)")
    print()
