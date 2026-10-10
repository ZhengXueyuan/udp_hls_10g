# -*- coding: utf-8 -*-
# Q1 复算: 用 TB 里逐字相同的 fb() 函数, 对每条 payload 红反解
#   exp = fb(CBASE*c + (fseq-isn[c]) + off)
#   got = ?
# 并搜索 got 是否等于"同流偏移 ±k*65536"的 fb 值 (环形 64KB 圈数).
# fb 源码 = tb/tb_tcp_tx_ovl.v:111-123 (逐字搬运, 32 位回绕)
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

# 红: (源, conn, fseq, off, got, exp)  -- 逐字取自已落盘的 gate2_stdout.txt
REDS = [
    ("S", 0, 0x000de510, 0, 0xcf, 0x6b),
    ("S", 1, 0x0004e59c, 8, 0x2d, 0x9f),
    ("S", 1, 0x0004e5a4, 0, 0x2d, 0x9f),
    ("T", 0, 0x00140c02, 0, 0xee, 0xf6),
]

print("== 逐条: 期望值复算 + 双向圈数搜索 (k = +/-0..40) ==")
for src, c, fseq, off, got, exp in REDS:
    isn = ISN[c]
    o = (fseq - isn) & M32                 # 流偏移 (TB 判据的口径)
    exp_calc = fb((CBASE * c + o + off) & M32)
    hits = [k for k in range(-40, 41)
            if fb((CBASE * c + o + off + k * 65536) & M32) == got]
    print(f"[{src}] conn={c} fseq={fseq:08x} off={off} got={got:02x} exp={exp:02x}")
    print(f"      isn={isn:08x} 流偏移={o} (={o/65536:.3f} 圈) exp复算={exp_calc:02x}"
          f" {'MATCH' if exp_calc == exp else 'MISMATCH'}")
    print(f"      got 命中的圈数 k = {hits}   (正=更晚一圈, 负=更早一圈)")
    for k in hits:
        lo = k < 0
        print(f"        k={k:+d}: fb(流偏移{'+' if k>=0 else '-'}{abs(k)}*65536) "
              f"= {got:02x}  => 该字节对应的流偏移 = {o + k*65536}")

print()
print("== 对照: 该 conn 在整跑里一共推了多少流 (由红点 fseq 反推下限) ==")
for c in sorted(ISN):
    print(f"  conn{c}: isn={ISN[c]:08x}")
