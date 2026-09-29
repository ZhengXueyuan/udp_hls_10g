# -*- coding: utf-8 -*-
import sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
POLY = 0xEDB88320; M32 = 0xFFFFFFFF
def step_bit(c, bit):
    m = (c & 1) ^ (bit & 1); c >>= 1
    if m: c ^= POLY
    return c & M32
def step8(c, b):
    for i in range(8): c = step_bit(c, (b >> i) & 1)
    return c
def rstep8(c): return step8(c, 0)

def rows_of(f):
    cols = [f(1 << k) for k in range(32)]
    return [sum((((cols[k] >> j) & 1) << k) for k in range(32)) for j in range(32)]

Mrows = rows_of(rstep8)
def mat_inv(rows):
    n=32; a=list(rows); b=[1<<j for j in range(n)]
    for col in range(n):
        p=None
        for r in range(col,n):
            if (a[r]>>col)&1: p=r; break
        assert p is not None
        a[col],a[p]=a[p],a[col]; b[col],b[p]=b[p],b[col]
        for r in range(n):
            if r!=col and ((a[r]>>col)&1): a[r]^=a[col]; b[r]^=b[col]
    return b
Minv = mat_inv(Mrows)
def apply(rows,v):
    r=0
    for j in range(32):
        if bin(rows[j]&v).count('1')&1: r|=1<<j
    return r
def mpow_rows(n):
    # M^n 的行
    return rows_of(lambda v: [mat_apply_n(v,n)][0])
def mat_apply_n(v,n):
    for _ in range(n): v = apply(Mrows, v)
    return v
Rk  = {n: rows_of(lambda v, n=n: mat_apply_n(v,n)) for n in range(9)}
# N_m = M^{-m}
def ninv_rows(m):
    return rows_of(lambda v, m=m: (lambda x: [x for _ in range(1)][0])(None) if False else None)
# 直接构造: N_m(v) = M^{-m} v
def ninv_apply(v, m):
    for _ in range(m): v = apply(Minv, v)
    return v
Nk = {m: rows_of(lambda v, m=m: ninv_apply(v, m)) for m in range(9)}

# 字节贡献行: E_i = R_{7-i} ∘ D  (D: 8 位 -> 32 位)
Dcols = [step8(0, 1 << k) for k in range(8)]      # D(1<<k)
def Dapply(b):
    r = 0
    for k in range(8):
        if (b >> k) & 1: r ^= Dcols[k]
    return r
def E_i_rows(i):
    # 输入 8 位 b, 输出 32 位: E_i(b) = M^{7-i}(D(b))
    cols = []
    for k in range(8):
        v = Dcols[k]
        for _ in range(7 - i): v = apply(Mrows, v)
        cols.append(v)
    return [sum((((cols[k] >> j) & 1) << k) for k in range(8)) for j in range(32)]

Erows = [E_i_rows(i) for i in range(8)]

def concat_items(rows, src):
    # 生成拼接项: 从 bit31 到 bit0
    items = []
    for j in range(31, -1, -1):
        items.append("^(%s & 32'h%08X)" % (src, rows[j]))
    return items

out = []
w = out.append
w("    // ===== 以下常量块由 scripts/gen_crc32_64.py 从 rtl/crc32_8b.v 的 step8 逐位导出 =====")
w("    // R_k = rstep8^k (k 次\"喂 0 字节\"推进); N_m = M^{-m} (尾部字节数修正的逆矩阵)")
w("    // 无效 lane 必须先按 0 值参与 (D(0)=0 才会把它的贡献屏蔽掉)")
for i in range(8):
    w("    wire [7:0] zb%d = keep[%d] ? d[%d:%d] : 8'h00;" % (i, 7-i, 63-8*i, 56-8*i))
w("    // pad = R_8(c) ^ Σ_{i=0..7} R_{7-i} · D(b_i)   (无效字节按 0 值参与: D(0)=0 自动屏蔽)")
w("    wire [31:0] pad_r = {")
for j in range(31, -1, -1):
    terms = ["^(crc_r & 32'h%08X)" % Rk[8][j]]
    for i in range(8):
        terms.append("^(zb%d & 8'h%02X)" % (i, Erows[i][j]))
    w("        " + " ^ ".join(terms) + ("," if j > 0 else ""))
w("    };")
w("    // 修正: crc_nxt = N_{8-popc(keep)} · pad")
for m in range(9):
    if m == 0:
        w("    wire [31:0] nv0 = pad_r;")
    else:
        w("    wire [31:0] nv%d = {" % m)
        for j in range(31, -1, -1):
            w("        ^(pad_r & 32'h%08X)%s" % (Nk[m][j], "," if j > 0 else ""))
        w("    };")

open("crc_body.vh","w",encoding="utf-8").write("\n".join(out) + "\n")
print("wrote crc_body.vh, lines =", len(out))

# 反向自检: 用生成的常量重建 crc, 与参考实现比对
def gen_model(c, d, keep, en, init):
    if init: return M32
    if not en: return c
    k = bin(keep).count('1')
    # pad
    pad = 0
    for j in range(32):
        x = 0
        if bin(Rk[8][j] & c).count('1') & 1: x ^= 1
        for i in range(8):
            b = (d >> (8*(7-i))) & 0xFF
            if (keep >> (7-i)) & 1:
                if bin(Erows[i][j] & b).count('1') & 1: x ^= 1
        pad |= x << j
    for _ in range(8 - k):
        pad = apply(Minv, pad)
    return pad
import random
random.seed(7)
bad = 0
for _ in range(4000):
    c = random.getrandbits(32); k = random.randint(0, 8)
    d = random.getrandbits(64)
    keep = (0xFF << (8-k)) & 0xFF
    a = gen_model(c, d, keep, 1, 0)
    ref = c
    for i in range(k):
        ref = step8(ref, (d >> (8*(7-i))) & 0xFF)
    if a != ref:
        bad += 1
        if bad < 4: print("MODEL FAIL", hex(c), k, hex(d), hex(a), hex(ref))
print("常量表重建失配:", bad, "/4000")

# 帧残留自检: 造一个 64B 帧, FCS 用生成模型算, 再整帧流过看残留
def crc_bytes(state, bs):
    for b in bs: state = step8(state, b)
    return state
payload = bytes(range(60))   # 60 字节内容
st = crc_bytes(0xFFFFFFFF, payload)
fcs_val = st ^ 0xFFFFFFFF
fcs_bytes = bytes([(fcs_val>>(8*i))&0xFF for i in range(4)])   # LSB-first
res = crc_bytes(0xFFFFFFFF, payload + fcs_bytes)
print("帧残留 = 0x%08X (期望 0xDEBB20E3)" % res)
