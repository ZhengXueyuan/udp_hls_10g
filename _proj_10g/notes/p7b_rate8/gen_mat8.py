#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_mat8.py -- P7B app 8 字节/拍: xorshift64 的 M^k 常量矩阵生成 + 自校验.

序列定义 (与 tools/cpp_peer/peer.cpp 的 rpat::fill 逐字节一致):
    byte_i = s_i[31:24];  s_{i+1} = xs_next(s_i)
    xs_next(s): t = s ^ (s<<13); t = t ^ (t>>7); t = t ^ (t<<17)   (64 位截断)

8 路展开要用到两件事 (都只是同一个线性算子 M 的幂, 故逐字节恒等, 不是近似):
    xs_next8(s)  = M^8 · s            (一拍推进 8 步)
    xs_word8(s)  = {b_0, b_1, ... b_7}  其中 b_k = (M^k · s)[31:24]
                 (lane0 = 第一个字节 = m_tdata[63:56], 与 byte_at() 同约定)

自校验 (三种独立路径, 任一不符即抛异常):
    A) 矩阵作用 vs 逐步 xs_next:  s8 = M^8·s  ==  8 次 xs_next   (随机 + 种子)
    B) 字节行 vs 逐步 xs_next:    b_k == (xs_next^k(s))[31:24]
    C) 全序列: 8 路产出拼起来的 1000 字节 == 逐字节序列的前 1000 字节

输出: 直接打印两段 Verilog 函数体 (供 apply_wide.py 拼进 rtl/app_udp_pattern.v).
"""
import random
import sys

M64 = (1 << 64) - 1


def xs_next(s):
    t = (s ^ (s << 13)) & M64
    t = (t ^ (t >> 7)) & M64
    t = (t ^ (t << 17)) & M64
    return t


def bit(v, i):
    return (v >> i) & 1


def build_M():
    """M 的行掩码: 输出位 r = XOR(输入位 j, j in rows[r])."""
    img = [xs_next(1 << j) for j in range(64)]      # 基向量的像 = M 的列
    rows = []
    for r in range(64):
        m = 0
        for j in range(64):
            if bit(img[j], r):
                m |= 1 << j
        rows.append(m)
    return rows


def compose(A, B):
    """(A ∘ B): 行 r = XOR_{j in A[r]} B[j]"""
    out = []
    for r in range(64):
        m, a, j = 0, A[r], 0
        while a:
            if a & 1:
                m ^= B[j]
            a >>= 1
            j += 1
        out.append(m)
    return out


def density(rows):
    ds = [bin(m).count('1') for m in rows]
    return sum(ds) / len(ds), max(ds)


def mat_apply(rows, v):
    out, r, m = 0, 0, rows
    for r in range(64):
        if bin(m[r] & v).count('1') & 1:
            out |= (1 << r)
    return out


def main():
    M = build_M()
    print("M density avg=%.1f max=%d" % density(M))
    P = [[1 << i for i in range(64)]]           # M^0 = I
    for k in range(1, 9):
        P.append(compose(P[k - 1], M))
    for k in range(9):
        a, b = density(P[k])
        print("M^%d density avg=%.1f max=%d" % (k, a, b))

    # ---------------- 自校验 A/B/C ----------------
    random.seed(20260930)
    seeds = [0x9E3779B97F4A7C15] + [random.getrandbits(64) for _ in range(200)]
    for s0 in seeds:
        # A) M^8 · s == 8 步
        v = s0
        for _ in range(8):
            v = xs_next(v)
        assert mat_apply(P[8], s0) == v, "A FAIL s0=%016x" % s0
        # B) 字节行
        for k in range(8):
            w = s0
            for _ in range(k):
                w = xs_next(w)
            got = 0
            for i in range(8):
                par = bin(P[k][24 + i] & s0).count('1') & 1
                got |= par << i
            assert got == ((w >> 24) & 0xFF), "B FAIL k=%d s0=%016x" % (k, s0)
    # C) 1000 字节序列
    s = 0x9E3779B97F4A7C15
    seq_ref = []
    t = s
    for _ in range(1000):
        seq_ref.append((t >> 24) & 0xFF)
        t = xs_next(t)
    seq8 = []
    st = s
    while len(seq8) < 1000:
        # 统一口径: lane k = M^k · s (与 RTL 的 xs_word8 逐位同款, 含拼接方向)
        raw = 0
        for k in range(8):
            by = 0
            for i in range(8):
                par = bin(P[k][24 + i] & st).count('1') & 1
                by |= par << i
            raw = (raw << 8) | by       # lane0 落在最高字节
        for k in range(8):
            seq8.append((raw >> (56 - 8 * k)) & 0xFF)
        st = mat_apply(P[8], st)
    assert seq8 == seq_ref, "C FAIL"
    print("SELF-CHECK OK: A(M^8) / B(byte rows) / C(1000-byte stream vs sequential)")

    # ---------------- 生成 Verilog ----------------
    def xor_terms(mask, var, base_bit=0):
        return " ^ ".join("%s[%d]" % (var, j) for j in range(64) if (mask >> j) & 1)

    L = []
    L.append("    // ==================================================================")
    L.append("    // 8 路展开 (P7B_10G): xorshift64 转移矩阵 M 的幂 —— **常量 XOR 网**, 不是级联")
    L.append("    // ==================================================================")
    L.append("    // 【为什么是常量网】M 是 GF(2) 上的 64x64 线性算子 (s ^= s<<13; s ^= s>>7;")
    L.append("    //   s ^= s<<17)。把 8 次 xs_next 级联写 => 24 级 LUT (~7ns @K7-2, 直接破时序);")
    L.append("    //   而 M^8 / M^k 的每一行只是「若干 s 位的 XOR」 (平均 21.8 项, 最多 34 项)")
    L.append("    //   => 深度 <= 3 级 LUT6。")
    L.append("    // 【为什么逐字节不变】b_k = (M^k·s)[31:24] 就是「先取后推进」序列的第 k 个字节")
    L.append("    //   (b_0 = s[31:24]; s <- M·s 之后的下一个字节 = (M·s)[31:24]); 状态推进 M^8")
    L.append("    //   与 8 次推进同值。⇒ 与 peer.cpp / app_pattern.v / 逐字节路径**恒等**。")
    L.append("    // 【生成方式】本段由 _proj_10g/notes/p7b_rate8/gen_mat8.py 生成 (勿手改);")
    L.append("    //   该脚本含三条自校验 (M^8 vs 8 步 / 字节行 vs 逐步 / 1000 字节全序列)。")
    L.append("    // 【lane 约定】xs_word8 的 [63:56] = 第 1 个字节 (与 m_tdata/byte_at 同约定)。")
    L.append("    function [63:0] xs_next8;                 // M^8 · s  (一拍推进 8 步)")
    L.append("        input [63:0] s;")
    L.append("        begin")
    for r in range(63, -1, -1):
        L.append("            xs_next8[%2d] = %s;" % (r, xor_terms(P[8][r], "s")))
    L.append("        end")
    L.append("    endfunction")
    L.append("")
    L.append("    function [63:0] xs_word8;                 // 8 个连续输出字节 (lane0 在前)")
    L.append("        input [63:0] s;")
    L.append("        begin")
    for lane in range(8):
        L.append("            // ---- lane %d (m_tdata[%d:%d]) = (M^%d · s)[31:24] ----"
                 % (lane, 63 - 8 * lane, 56 - 8 * lane, lane))
        for ib in range(7, -1, -1):               # 字节内 bit7..0 → 目标位 [56-8l+ib]
            L.append("            xs_word8[%2d] = %s;" % (56 - 8 * lane + ib,
                                                          xor_terms(P[lane][24 + ib], "s")))
    L.append("        end")
    L.append("    endfunction")

    tot = sum(bin(m).count('1') for m in P[8])
    tot += sum(bin(P[k][24 + i]).count('1') for k in range(8) for i in range(8))
    print("XOR term count: M^8 = %d, byte rows = %d, total = %d"
          % (sum(bin(m).count('1') for m in P[8]),
             sum(bin(P[k][24 + i]).count('1') for k in range(8) for i in range(8)), tot))

    with open("wide_funcs.v.txt", "w", encoding="utf-8", newline="") as f:
        f.write("\n".join(L) + "\n")
    print("wrote wide_funcs.v.txt (%d lines)" % len(L))


if __name__ == "__main__":
    sys.exit(main())
