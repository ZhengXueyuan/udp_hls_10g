"""xs_lib.py — xorshift64 图案流的 GF(2) 线性求解库 (与 `rtl/app_udp_pattern.v:6-7` 同算式).

为什么用线性求解而不是搜索: 板子的流偏移是**硬件常数速率**推进的 (106k 帧/s × 1472 B ≈
156 MB/s), 跑十几分钟就走到 GB 级 ⇒ 任何"从 offset 0 顺序搜索"的校验器**结构上不可能**命中;
而 xorshift 的三步全是 GF(2) 上的线性映射 ⇒ 8 个连续输出字节 (64 bit) 就已**超定**地定出
初始状态。⇒ 从**任意**流位置都能反解出偏移, 逐字节判据不再依赖"重烧到 offset 0"。

`selftest()` 是**判据的判据**: 随机状态必须解回、随机字节必须被判矛盾 (否则本库是真空的)。
"""
M64 = (1 << 64) - 1
SEED = 0x9E3779B97F4A7C15


def step(s):
    s ^= (s << 13) & M64
    s ^= s >> 7
    s ^= (s << 17) & M64
    return s & M64


def out_byte(s):
    return (s >> 24) & 0xFF          # 先取后推进


def linear_forms(nbytes):
    """forms[n][k] = 第 n 个输出字节第 k 位 关于初始状态 64 bit 的线性掩码"""
    form = [1 << j for j in range(64)]
    forms = []
    for _ in range(nbytes):
        forms.append([form[24 + k] for k in range(8)])
        nf = [0] * 64
        for i in range(64):
            t = step(1 << i)
            for j in range(64):
                if (t >> j) & 1:
                    nf[j] ^= form[i]
        form = nf
    return forms


def solve(forms, data):
    """返回 (state, free_bits) 或 (None, None) 表示矛盾。"""
    rows = {}
    for n in range(len(data)):
        for k in range(8):
            m, r = forms[n][k], (data[n] >> k) & 1
            while m:
                p = m.bit_length() - 1
                if p in rows:
                    pm, pr = rows[p]
                    m ^= pm
                    r ^= pr
                else:
                    rows[p] = (m, r)
                    break
            else:
                if r:
                    return None, None
    x = 0
    for p in sorted(rows):
        m, r = rows[p]
        v, mm = r, m & ~(1 << p)
        while mm:
            q = mm.bit_length() - 1
            v ^= (x >> q) & 1
            mm ^= 1 << q
        if v:
            x |= 1 << p
    return x, 64 - len(rows)


def verify(state, data):
    """从 state 起逐字节复核 data; 返回首个不符的下标 (全符 ⇒ -1)"""
    s = state
    for i, b in enumerate(data):
        if out_byte(s) != b:
            return i
        s = step(s)
    return -1


def selftest(nbytes=96, seed=12345):
    """3 正 (随机状态必须解回) + 3 负 (随机字节必须矛盾)。返回 True/False。"""
    import random
    rnd = random.Random(seed)
    forms = linear_forms(nbytes)
    ok = True
    for _ in range(3):
        st = rnd.getrandbits(64)
        s, data = st, []
        for _ in range(nbytes):
            data.append(out_byte(s))
            s = step(s)
        x, free = solve(forms, data)
        good = (free == 0 and x == st and verify(x, data) == -1)
        print('    xs_lib 正对照: 解回=%s free=%s ⇒ %s' % (hex(x) if x is not None else None, free, 'OK' if good else 'BAD'))
        ok &= good
    for _ in range(3):
        data = [rnd.randrange(256) for _ in range(nbytes)]
        x, free = solve(forms, data)
        consistent = (x is not None) and (verify(x, data) == -1)
        print('    xs_lib 负对照: 随机字节 ⇒ 相容=%s ⇒ %s' % (consistent, 'OK(被否)' if not consistent else 'BAD(真空)'))
        ok &= (not consistent)
    return ok
