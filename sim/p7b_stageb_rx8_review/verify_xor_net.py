#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""verify_xor_net.py -- 对抗审查 (Stage B/R1) 的**独立**数学核对.

不看 gen_mat8.py 的自检结论, 直接从**磁盘上的 RTL 文本**(rtl/app_pattern.v 的
工作副本) 解析出 xs_next8 / xs_word8 的 XOR 网, 然后:

  V1  线性算子的**完备**证明: XOR 网对输入位是线性的 ⇒ 只要在 **64 个基向量
      e_j = 1<<j (+0)** 上等于参考, 就处处相等 (不需要随机采样/不需要"跑过就算")。
      参考 = 逐步 xs_next 的 8 次迭代 (xs_next 的定义从 rtl 的 xs_next 函数体
      文本里解析, 不硬抄)。
  V2  xs_word8 的每个 lane = (M^k·s)[31:24] (k = lane 序号), 同样按基向量完备核对。
  V3  与 rtl/app_udp_pattern.v 的同名函数**逐字节比对** (再对同文件内做一次
      "两份一样就一起错"的排除: 逐字节相同 ⇒ 二者不能互为独立证据, 只能算
      一处已验证 / 一处复制)。
  V4  XOR 项数 (作者声称 2283 = 1392 + 891)。
  V5  SEED 轨迹上的长序列 (抽取 100k 字节) 三方一致: 参考递推 / xs_word8 /
      xs_next8 推进。

退出码 0 = 全部核对通过; 1 = 有 FAIL。
"""
import io
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SRC = os.path.join(ROOT, "rtl", "app_pattern.v")
UDP = os.path.join(ROOT, "rtl", "app_udp_pattern.v")

M64 = (1 << 64) - 1


def parse_func(text, name):
    """返回 {bit_index: [src_bit, ...]} —— 从 func 体里的 `name[<i>] = s[a] ^ s[b]...` 解析."""
    m = re.search(r"function\s+\[63:0\]\s+%s\s*;.*?\n(.*?)\n\s*end\s*\n\s*endfunction"
                  % re.escape(name), text, re.S)
    if not m:
        raise RuntimeError("function %s not found" % name)
    body = m.group(1)
    rows = {}
    for mm in re.finditer(r"%s\[\s*(\d+)\s*\]\s*=\s*([^;]+);" % re.escape(name), body):
        bit = int(mm.group(1))
        rhs = mm.group(2)
        terms = [int(x) for x in re.findall(r"s\[(\d+)\]", rhs)]
        # 确保 RHS 里只有 s[...] 和 ^ / 空白 (没有别的算子混入)
        residual = re.sub(r"s\[\d+\]", "", rhs).replace("^", "").strip()
        if residual:
            raise RuntimeError("unexpected tokens in %s[%d] RHS: %r" % (name, bit, residual))
        if bit in rows:
            raise RuntimeError("duplicate assignment to %s[%d]" % (name, bit))
        rows[bit] = sorted(terms)
    if sorted(rows) != list(range(64)):
        raise RuntimeError("%s: covered bits = %d (expect 64)" % (name, len(rows)))
    return rows


def apply_rows(rows, s):
    out = 0
    for bit, terms in rows.items():
        par = 0
        for t in terms:
            par ^= (s >> t) & 1
        out |= par << bit
    return out


def parse_xs_next(text):
    """从 RTL 文本里解析 xs_next 函数体 (t = s ^ (s<<13); t = t ^ (t>>7); t = t ^ (t<<17))."""
    m = re.search(r"function\s+\[63:0\]\s+xs_next\s*;.*?begin(.*?)end\s*\n\s*endfunction",
                  text, re.S)
    if not m:
        raise RuntimeError("xs_next not found")
    body = m.group(1)
    shifts = [x for x in re.findall(r"\bt\s*=\s*([^;]+);", body)]
    if len(shifts) != 3:
        raise RuntimeError("xs_next body unexpected: %r" % body)
    parsed = []
    for expr in shifts:
        expr = expr.strip()
        if expr == "s ^ (s << 13)":
            parsed.append(("s", 13))
        elif expr == "t ^ (t >> 7)":
            parsed.append(("t", -7))
        elif expr == "t ^ (t << 17)":
            parsed.append(("t", 17))
        else:
            raise RuntimeError("unparsed xs_next expr: %r" % expr)
    assert parsed == [("s", 13), ("t", -7), ("t", 17)]

    def xs_next(s):
        t = (s ^ (s << 13)) & M64
        t = (t ^ (t >> 7)) & M64
        t = (t ^ (t << 17)) & M64
        return t
    return xs_next


def main():
    text = io.open(SRC, encoding="utf-8", newline="").read()
    xs_next = parse_xs_next(text)
    n8 = parse_func(text, "xs_next8")
    w8 = parse_func(text, "xs_word8")
    fails = []

    # ---------- V1: xs_next8 完备核对 (基向量) ----------
    for j in range(64):
        s = 1 << j
        v = s
        for _ in range(8):
            v = xs_next(v)
        got = apply_rows(n8, s)
        if got != v:
            fails.append("V1 basis e%d: xs_next8=%016x expect=%016x" % (j, got, v))
    if apply_rows(n8, 0) != 0:
        fails.append("V1 zero vector: xs_next8(0) != 0 (not linear)")
    print("V1 xs_next8 vs 8x xs_next on 64 basis vectors + 0 : %s"
          % ("OK (complete for linear maps)" if not fails else "FAIL"))

    # ---------- V2: xs_word8 每 lane 完备核对 ----------
    v2bad = 0
    for lane in range(8):
        for j in range(64):
            s = 1 << j
            v = s
            for _ in range(lane):
                v = xs_next(v)
            ref_lane = (v >> 24) & 0xFF
            got_lane = (apply_rows(w8, s) >> (56 - 8 * lane)) & 0xFF
            if got_lane != ref_lane:
                v2bad += 1
                if v2bad < 5:
                    fails.append("V2 lane%d e%d: got=%02x expect=%02x"
                                 % (lane, j, got_lane, ref_lane))
    print("V2 xs_word8 lane k == (xs_next^k(s))[31:24], 8 lanes x 64 basis : %s"
          % ("OK" if v2bad == 0 else "FAIL(%d)" % v2bad))

    # ---------- V3: 与 app_udp_pattern.v 同名函数逐字节 ----------
    utext = io.open(UDP, encoding="utf-8", newline="").read()
    u8 = parse_func(utext, "xs_next8")
    uw8 = parse_func(utext, "xs_word8")
    same = (u8 == n8) and (uw8 == w8)
    print("V3 xs_next8 / xs_word8 vs app_udp_pattern.v : %s"
          % ("IDENTICAL (同一份代码; 非独立证据)" if same else "DIFFER"))
    if not same:
        fails.append("V3: functions differ from app_udp_pattern.v (claim broken)")

    # ---------- V4: XOR 项数 ----------
    c8 = sum(len(t) for t in n8.values())
    cw = sum(len(t) for t in w8.values())
    print("V4 XOR terms: xs_next8=%d, xs_word8=%d, total=%d (author: 1392+891=2283)"
          % (c8, cw, c8 + cw))
    if c8 + cw != 2283:
        fails.append("V4: term count %d != 2283" % (c8 + cw))

    # ---------- V5: 长轨迹三方一致 ----------
    s = 0x9E3779B97F4A7C15
    t = s
    bad = 0
    nbytes = 100000
    for blk in range(nbytes // 8):
        ref = 0
        for _ in range(8):
            ref = (ref << 8) | ((t >> 24) & 0xFF)
            t = xs_next(t)
        got = apply_rows(w8, s)
        if got != ref or apply_rows(n8, s) != t:
            bad += 1
            if bad < 3:
                fails.append("V5 blk%d: word mismatch" % blk)
        s = apply_rows(n8, s)
    print("V5 100000-byte trajectory, word+advance both nets : %s"
          % ("OK" if bad == 0 else "FAIL(%d)" % bad))

    if fails:
        print("\nVERIFY-XOR-NET: FAIL")
        for f in fails[:20]:
            print("  " + f)
        return 1
    print("\nVERIFY-XOR-NET: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
