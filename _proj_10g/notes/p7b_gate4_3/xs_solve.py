"""xs_solve.py — 判定一段字节流**是不是** `rtl/app_udp_pattern.v` 的 xorshift64 输出流。

原理 (**线性代数, 不是蛮力搜索** — 所以不受"流偏移已到 GB 级"的限制):
  xorshift64 的三步 (`s^=s<<13; s^=s>>7; s^=s<<17`) **每一步都是 GF(2) 上的线性映射**,
  输出 `out_n = s_n[31:24]` (先取后推进) 也是线性的。
  ⇒ 每一输出 bit 都是初始状态 64 个 bit 的一个线性组合 (一个 64 位掩码)。
  给定 K 个连续输出字节 (8K 个方程), 解 64 个未知数:
    · 全部方程相容 ⇒ **是**这条流 (且解出状态 ⇒ 也就定出了流偏移);
    · 矛盾 ⇒ **不是**这条流。
  判据自带反例: `--selftest` 用**随机**状态生成 96 字节, 求解器必须解回同一个状态;
  再喂一段随机字节, 求解器必须报**矛盾** (否则它是恒真的真空判据)。

用法: python xs_solve.py <head.hex>        # 连续字节的 hex (从连接/帧的首字节开始)
      python xs_solve.py --selftest
"""
import random
import sys

M64 = (1 << 64) - 1
SEED = 0x9E3779B97F4A7C15


def step(s):
    s ^= (s << 13) & M64
    s ^= s >> 7
    s ^= (s << 17) & M64
    return s & M64


def out_byte(s):
    return (s >> 24) & 0xFF          # 先取后推进


def linear_forms(nbits=96):
    """返回 [ (mask, ) ... ]: 第 n 个输出字节的第 k 位 = mask 所选的初始状态位异或。
    用"状态每个 bit 的线性形式"递推 (form[j] = 第 j 位 = 初始状态位的异或掩码)。"""
    form = [1 << j for j in range(64)]
    forms = []                        # forms[n][k] = 第 n 字节第 k 位的掩码
    for _ in range(nbits):
        forms.append([form[24 + k] for k in range(8)])
        # 推进: new_form[j] = XOR_{i: f(e_i) bit j == 1} form[i]
        nf = [0] * 64
        for i in range(64):
            t = step(1 << i)
            for j in range(64):
                if (t >> j) & 1:
                    nf[j] ^= form[i]
        form = nf
    return forms


def solve(forms, bits):
    """GF(2) 高斯消元。forms = [(mask, bit)] ⇒ 返回 (状态, 相容?) ; 满秩时状态唯一。"""
    rows = {}                         # 主元位 → (mask, rhs)
    for mask, b in forms:
        m, r = mask, b
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
            if r:                     # 0 = 1 ⇒ 矛盾
                return None, False
    # 回代: 低主元位已知后可定高主元位 -> 直接按主元从低到高消元
    piv = sorted(rows)
    x = 0
    for p in piv:
        m, r = rows[p]
        v = r
        mm = m & ~(1 << p)
        while mm:
            q = mm.bit_length() - 1
            v ^= (x >> q) & 1
            mm ^= 1 << q
        if v:
            x |= 1 << p
    # 只可保证"与所有方程相容"; 未定自由度 = 0 时才是唯一解
    free = 64 - len(piv)
    return x, free


def check_stream(state, data):
    s = state
    for b in data:
        if out_byte(s) != b:
            return False
        s = step(s)
    return True


def main():
    if sys.argv[1] == '--selftest':
        rnd = random.Random(12345)
        forms = linear_forms(96)
        ok = 0
        for t in range(3):
            st = rnd.getrandbits(64)
            data = []
            s = st
            for _ in range(96):
                data.append(out_byte(s))
                s = step(s)
            eq = [(forms[n][k], (data[n] >> k) & 1) for n in range(96) for k in range(8)]
            x, free = solve(eq, None)
            good = (free == 0 and x == st and check_stream(x, data))
            print('  selftest#%d: 状态解回 = %s (free=%d) ⇒ %s' % (t + 1, hex(x), free, 'OK' if good else 'BAD'))
            ok += good
        # 负对照: 随机字节必须矛盾
        bad = 0
        for t in range(3):
            data = [rnd.randrange(256) for _ in range(96)]
            eq = [(forms[n][k], (data[n] >> k) & 1) for n in range(96) for k in range(8)]
            x, free = solve(eq, None)
            consistent = (x is not None) and check_stream(x, data)
            bad += (not consistent)
            print('  负对照#%d: 随机字节 ⇒ 相容=%s ⇒ %s' % (t + 1, consistent, 'OK(被否掉)' if not consistent else 'BAD(真空)'))
        print('SELFTEST %s' % ('PASS' if ok == 3 and bad == 3 else 'FAIL'))
        return 0 if ok == 3 and bad == 3 else 1

    data = bytes.fromhex(sys.argv[1].strip())
    n = len(data)
    forms = linear_forms(n)
    eq = [(forms[i][k], (data[i] >> k) & 1) for i in range(n) for k in range(8)]
    x, free = solve(eq, None)
    if x is None:
        print('  输入 %d B: **矛盾** ⇒ 这段字节**不是** xorshift64 图案流 (差值数 %d' % (n, 0))
        return 1
    good = check_stream(x, data)
    print('  输入 %d B: 相容, 解出状态 = 0x%016X (自由位 %d) ; 全流复核 = %s' % (n, x, free, good))
    if good:
        print('  ⇒ 是图案流, 起点状态 = 0x%016X %s' % (x, '(== 公共种子 0x9E3779B97F4A7C15)' if x == SEED else ''))
    return 0 if good else 1


sys.exit(main())
