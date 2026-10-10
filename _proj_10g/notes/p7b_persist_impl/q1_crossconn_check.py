# -*- coding: utf-8 -*-
# Q1 步 3: 交叉核对 -- 错值究竟是 (a) 同连接上一圈, (b) 别的连接的图案, 还是 (c) 都不是
# 数据源 = gate2_stdout.txt / runS,runT,runU,runV,runW 的逐字 [FAIL] 行 + APP-SNAP dump54..69
M32 = 0xFFFFFFFF
CBASE = 0x0010_0000
ISN = {0: 0x0000_F100, 1: 0x0001_2300, 2: 0x7FFF_FC00, 3: 0x0000_0800}

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

# (臂, conn, fseq, plen, 16 字节截面或 None)
CASES = [
    ("S#1", 0, 0x000de510, 1460, hx("cf 38 c3 dc 40 ca a0 ee 62 20 4b d7 f9 22 36 26")),
    ("S#2", 1, 0x0004e59c,   29, hx("ae 42 83 ee d7 94 42 da 2d 03 65 2a b6 0a e7 a8")),
    ("S#3", 1, 0x0004e5a4,   21, hx("2d 03 65 2a b6 0a e7 a8 01 d8 ff ab bd b0 83 60")),
    ("W-1", 1, 0x0004e59c,   29, None),   # got=c1 @341392 (仅首字节)
    ("T-1", 0, 0x00140c02,    1, hx("ee 51 96 85 d6 2e ef db e4 52 bc 42 30 5b 81 f1")),
    ("U-2", 1, 0x0004e59c,   29, None),   # got=c1 @346247 (仅首字节)
]

print("== 错值归类: 同连接上一圈 / 同连接其它圈 / 跨连接 / 都对不上 ==")
for tag, c, fseq, plen, obs in CASES:
    o = fseq - ISN[c]
    if obs is None:
        # 只有 [FAIL] 行: 用 exp 反推该 off 的错值
        print(f"[{tag}] conn={c} fseq={fseq:08x}: 无截面 (只有 [FAIL] 行)")
        continue
    print(f"[{tag}] conn={c} fseq={fseq:08x} plen={plen} 流偏移 o={o}")
    bad = [k for k in range(min(16, plen)) if fb(CBASE*c + o + k) != obs[k]]
    print(f"   16 字节截面里失配位置 = {bad}")
    for k in bad:
        got = obs[k]
        same = [lap for lap in range(-40, 41)
                if fb(CBASE*c + o + k + lap * 65536) == got]
        cross = [(cc, lap) for cc in ISN if cc != c for lap in range(-2, 3)
                 if fb(CBASE*cc + o + k + lap * 65536) == got]
        print(f"     off={k}: got={got:02x} 同连接命中圈数={same}  跨连接(±2圈)={cross}")
    print()

# arm W / U 的单字节红 (got=c1 @ conn1 off0, 期望 ae) 单独归类
print("== arm W/U 的单字节错值 c1 (conn1 fseq=0x0004e59c off=0, 期望 ae) ==")
o = 0x0004e59c - ISN[1]
print(f"   同连接 c1 命中圈数: {[lap for lap in range(-40,41) if fb(CBASE*1+o+lap*65536)==0xc1]}")
for cc in ISN:
    hit = [lap for lap in range(-40, 41) if fb(CBASE*cc + o + lap*65536) == 0xc1]
    if hit:
        print(f"   conn{cc} 的图案在 o+{hit}*65536 处 = c1")
