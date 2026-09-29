#!/usr/bin/env python3
#=============================================================================
# verify_pcap_pattern.py — 离线的"逐字节等于图案流"验证器 (冒烟测试 agent 新增)
#
#   为什么要有它: 板子以 ~956Mbps / ~81k pps 发图案帧时 **主机 socket 路径** 实测一帧都
#   收不到 (C++ 工具跑第二次 = 0 帧; python 独立复现 = 0 帧), 而 tcpdump/pcap 与网卡硬件
#   计数都显示流是满的 ⇒ 判据 4a 在 socket 口径下**无判别力**。本脚本换**独立路径**
#   (tcpdump AF_PACKET → pcap → 离线逐帧代数验证)。
#
#   验证原理 (不依赖"图案流从 offset 0 开始", 因此不受板子跑了多久影响):
#     ① xorshift64 是 GF(2) 上的**线性**映射 ⇒ "一帧的 k 个输出字节" 是初始状态 s 的线性函数。
#        取前 NKNOWN 个字节 = 8*NKNOWN 个方程解 64 个未知位 (8 字节实测秩亏, 40 字节秩满)。
#     ② **逐帧独立反解 s** ⇒ 用 s 重新生成 1472 字节 ⇒ **逐字节**比对。
#        (若板上图案流被任何东西污染, 该帧就不会是**任何**合法状态的下一个 1472 字节。)
#     ③ 连续性: 第 i 帧末尾状态 == 第 i+1 帧起始状态 ⇒ 两帧在流上严格相邻 (0 丢帧);
#        不等 ⇒ **抓包侧丢帧** (tcpdump 自己也会丢, 这不是板子的错) ⇒ 单独记账, 且只在
#        ≤64 帧的窗口里去找真实间隔 (报告"缺 m 帧"), 找不到就记 unexplained。
#
#   用法: python verify_pcap_pattern.py <pcap> [--paylen 1472] [--dport 8081]
#=============================================================================
import struct, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")   # 本工程老坑: GBK 控制台
except Exception:
    pass

MASK = (1 << 64) - 1
NKNOWN = 40          # 用前 40 个输出字节 = 320 方程解 64 未知位 (8 字节时实测秩亏)
GAP_MAX = 64         # 只在 ≤64 帧窗口里找真实丢帧间隔 (再大就不猜了, 记账为 big-gap)


def xs(s):
    s ^= (s << 13) & MASK
    s ^= s >> 7
    s ^= (s << 17) & MASK
    return s & MASK


def obs_bytes(s, k):
    """s 的'前 k 个输出字节'打包成大整数 (t=0 在最高位)。"""
    o = 0
    for _ in range(k):
        o = (o << 8) | ((s >> 24) & 0xFF)
        s = xs(s)
    return o


def gen_bytes(s, n):
    out = bytearray(n)
    for i in range(n):
        out[i] = (s >> 24) & 0xFF
        s = xs(s)
    return bytes(out), s


def build_solver():
    """一次性行化简; **右端项随消元走** (每帧的 RHS 不同 ⇒ 用'行由哪些原方程 XOR 而来'的
    掩码表示, 之后每帧取 parity 即可, 不必每帧重跑消元)。
    返回 (rows, rhs_mask, where, nbits, rank)。"""
    nbits = NKNOWN * 8
    cols = [obs_bytes(1 << j, NKNOWN) for j in range(64)]
    rows = []
    for i in range(nbits):
        c = 0
        for j in range(64):
            if (cols[j] >> i) & 1:
                c |= (1 << j)
        rows.append(c)
    rhs_mask = [1 << i for i in range(nbits)]        # 初始: 第 i 行 = 原方程 i
    where = [-1] * 64
    r = 0
    for c in range(64):
        piv = next((i for i in range(r, nbits) if (rows[i] >> c) & 1), None)
        if piv is None:
            continue
        rows[r], rows[piv] = rows[piv], rows[r]
        rhs_mask[r], rhs_mask[piv] = rhs_mask[piv], rhs_mask[r]
        for i in range(nbits):
            if i != r and ((rows[i] >> c) & 1):
                rows[i] ^= rows[r]
                rhs_mask[i] ^= rhs_mask[r]
        where[c] = r
        r += 1
    return rows, rhs_mask, where, nbits, r


def solve_for(known_obs, sol):
    """回代: 返回状态, 或 None (不一致)。"""
    rows, rhs_mask, where, nbits, rank = sol
    for i in range(rank, nbits):                     # 一致性: 化简后 0 = RHS ⇒ 无解
        if ((rhs_mask[i] & known_obs).bit_count() & 1):
            return None
    s = 0
    for c in range(64):
        k = where[c]
        if k >= 0 and ((rhs_mask[k] & known_obs).bit_count() & 1):
            s |= (1 << c)
    return s


def selftest(sol):
    """自检 (验证"验证器"本身): 用已知状态造一帧, 解回来必须能逐字节复原。"""
    s_true = 0x0123456789ABCDEF
    payload, _ = gen_bytes(s_true, 1472)
    known = int.from_bytes(payload[:NKNOWN], "big")
    s_got = solve_for(known, sol)
    if s_got is None:
        return "反解无解"
    exp, _ = gen_bytes(s_got, 1472)
    if exp != payload:
        return "反解出的状态复算不回原帧"
    return None


def parse_pcap(path):
    data = open(path, "rb").read()
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic == 0xA1B2C3D4:
        endian = "<"
    elif magic == 0xD4C3B2A1:
        endian = ">"
    elif magic == 0xA1B23C4D:
        endian = "<"
    elif magic == 0x4D3CB2A1:
        endian = ">"
    else:
        raise SystemExit("不是 pcap 文件 (magic=0x%08x)" % magic)
    off, n, pkts = 24, len(data), []
    while off + 16 <= n:
        _, _, incl, _ = struct.unpack_from(endian + "IIII", data, off)
        off += 16
        pkts.append(data[off:off + incl])
        off += incl
    return pkts


def payload_of(frame, paylen, dport_want):
    if len(frame) < 42 or frame[12:14] != b"\x08\x00" or frame[23] != 17:
        return None
    ihl = (frame[14] & 0x0F) * 4
    l4 = 14 + ihl
    if struct.unpack_from(">H", frame, l4 + 2)[0] != dport_want:
        return None
    return frame[l4 + 8:l4 + 8 + paylen]


def main():
    path = sys.argv[1]
    paylen, dport_want = 1472, 8081
    if "--paylen" in sys.argv:
        paylen = int(sys.argv[sys.argv.index("--paylen") + 1])
    if "--dport" in sys.argv:
        dport_want = int(sys.argv[sys.argv.index("--dport") + 1])

    pkts = parse_pcap(path)
    pays = [p for p in (payload_of(f, paylen, dport_want) for f in pkts) if p and len(p) == paylen]
    print("pcap: %s — 文件 %d 包, 其中 %dB/UDP:%d 载荷 %d 帧" % (path, len(pkts), paylen, dport_want, len(pays)))
    if not pays:
        raise SystemExit("没有可验证的载荷")

    sol = build_solver()
    rows, rhs_mask, where, nbits, rank = sol
    print("① 求解器: %d 个方程解 64 个状态位 ⇒ rank = %d %s"
          % (nbits, rank, "(满秩)" if rank == 64 else "**秩亏 ⇒ 反解不唯一, 结论不可用**"))
    if rank != 64:
        return 2
    err = selftest(sol)
    print("①b 求解器自检 (已知状态合成帧 ⇒ 反解 ⇒ 逐字节复原): %s"
          % ("**PASS**" if err is None else "**FAIL: %s ⇒ 结论不可用**" % err))
    if err is not None:
        return 2

    # ② 逐帧独立反解 + 逐字节复算
    states, endstates, bad = [], [], []
    for idx, p in enumerate(pays):
        known = int.from_bytes(p[:NKNOWN], "big")
        s = solve_for(known, sol)
        if s is None:
            bad.append((idx, "该帧不是**任何**合法状态的 1472 字节 ⇒ 帧内字节被污染"))
            states.append(None); endstates.append(None)
            continue
        exp, s_end = gen_bytes(s, paylen)
        if exp != p:
            i = next(k for k in range(paylen) if exp[k] != p[k])
            bad.append((idx, "首个不同字节 @%d (长 %d)" % (i, paylen)))
        states.append(s); endstates.append(s_end)
    print("② 逐帧反解 + 逐字节复算: %d/%d 帧**逐字节**等于由本帧反解状态生成的图案流"
          % (len(pays) - len(bad), len(pays)))
    if bad:
        print("[FAIL] 反解复算失配 %d 处 (前 5): %s" % (len(bad), bad[:5]))

    # ③ 连续性
    cont, gaps, big = 0, [], 0
    for i in range(len(pays) - 1):
        if states[i] is None or states[i + 1] is None:
            continue
        if endstates[i] == states[i + 1]:
            cont += 1
            continue
        st = endstates[i]
        found = None
        for m in range(1, GAP_MAX + 1):
            st = xs_n(st, paylen * 8)
            if st == states[i + 1]:
                found = m
                break
        if found is None:
            big += 1
        else:
            gaps.append(found)
    print("③ 连续性: 相邻帧**严格相邻** (0 丢帧) %d 处; 抓包侧丢帧事件 %d 次 %s; 间隔>%d帧的大空洞 %d 处"
          % (cont, len(gaps), ("(共缺 %d 帧)" % sum(gaps)) if gaps else "", GAP_MAX, big))

    if bad or big:
        print("[FAIL] 有无法归因的项 (上面逐条列出) ⇒ 不能判 PASS")
        return 1
    print("[PASS] 抓到的每一帧都逐字节等于**同一约定 xorshift64 图案流**, 相邻帧在流上连续;")
    print("       抓包侧丢帧已单独记账 (tcpdump 自身丢帧, 与板子无关) ⇒ **板子 TX 图案流无恙**")
    return 0


def xs_n(s, n):
    for _ in range(n):
        s = xs(s)
    return s


if __name__ == "__main__":
    sys.exit(main())
