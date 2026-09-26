#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""rxp_digest.py — 把一条或多条 RXP 状态行读成 §16.10 的位移律摘要。

它把"这一轮是否还是同一个现象"变成一组**可重跑**的检查 (ISSUE §16.10 的四条规律):
  1. II % paylen == 0        首失配落在帧边界 (整帧替换的必然结果)
  2. k == +paylen            收到的整字 == 流里"下一帧同偏移"的字, 且**在宽窗口内唯一**
  3. UMM / (paylen*255/256)  是整数 —— 受损帧数
  4. OZ == 该整数            字节级分桶与帧级计数互证
  5. 每帧桶剖面 == 容量*255/256  (整帧逐字节均匀替换)

**为什么要"宽窗口 + 整字 8 字节精确匹配"**: 只在正方向搜 `k` 永远搜不到 `-paylen`,
那样"找到 +paylen"就只是"在预设方向上找到的第一个解", 不能支撑单向性结论。
本工具在 +-W 内做**全搜**, 命中多于一个就报出来 (多命中 ⇒ 该轮的出处不可判)。

paylen 由 URB/URF 反推: 在候选表里找满足 `ceil(URB/pl) == URF` 的 pl。
⚠️ **不要用 URB/URF 当 paylen** —— 8388608/5699 = 1471.944 是浮点 (末尾有不满帧),
拿它去取模会得到一堆假余数 (2026-09-27 我自己这么错过一次)。

用法:
  python tools/rxp_digest.py p5diag_verify/v3_round*.line
  python tools/rxp_digest.py --window 200000 p5diag_verify/v3_long*.line
"""
import math
import re
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0].rsplit("\\", 1)[0] + "/tools")
try:
    import rxp_classify as R
except ImportError:                                    # 直接在本目录跑时的兜底
    sys.path.insert(0, ".")
    import rxp_classify as R

PAYLEN_CAND = [512, 996, 1024, 1280, 1400, 1408, 1460, 1472, 1500]


def infer_paylen(urb, urf):
    """候选中满足 ceil(URB/pl) == URF 的 paylen (可能多解, 全部返回)。"""
    return [pl for pl in PAYLEN_CAND if urf and math.ceil(urb / pl) == urf]


def one(fn, W, pat):
    line = open(fn, encoding="utf-8", errors="replace").read()
    line = re.search(r"^P5B1 .*$", line, re.M)
    if not line:
        return None, "no P5B1 line"
    line = line.group(0)
    d = dict(re.findall(r"([A-Z]{2})=([0-9A-Fx]+)", line))
    need = ("II", "MM", "OZ", "OL", "OM", "OH")
    if not all(k in d for k in need):
        return None, "missing fields (not a v2/v3 diag line?)"
    g = lambda k: int(d[k], 16)
    ii, umm = g("II"), g("MM")
    urb = int(re.search(r"URB=([0-9A-F]+)", line).group(1), 16) if "URB=" in line else None
    urf = int(re.search(r"URF=([0-9A-F]+)", line).group(1), 16) if "URF=" in line else None

    pls = infer_paylen(urb, urf) if (urb and urf) else []
    paylen = pls[0] if len(pls) == 1 else None
    amb = "" if len(pls) == 1 else "  paylen 反推%s" % ("歧义%s" % pls if pls else "失败")

    out = {"file": fn, "II": ii, "UMM": umm, "amb": amb, "paylen": paylen,
           "OZ": g("OZ"), "OL": g("OL"), "OM": g("OM"), "OH": g("OH")}
    if paylen is None:
        return out, amb

    out["off"] = ii % paylen
    out["n"] = umm / (paylen * 255.0 / 256.0)
    out["nframes"] = math.ceil(urb / paylen) if urb else None

    # k: 整字 8 字节精确匹配, 全窗口搜索 (两侧都搜)
    if "GW" in d:
        G = int(d["GW"], 16)
        hits = [c for c in range(-W, W + 1)
                if 0 <= ii + c and ii + c + 8 <= len(pat)
                and int.from_bytes(bytes(pat[ii + c:ii + c + 8]), "big") == G]
        out["k_hits"] = hits
        out["k"] = hits[0] if len(hits) == 1 else None

    # 每帧桶剖面 vs 容量*255/256
    caps = [1, 7, 56, paylen - 64]
    out["prof"] = [out[b] / out["n"] for b in ("OZ", "OL", "OM", "OH")] if out["n"] else None
    out["caps"] = [c * 255.0 / 256.0 for c in caps]
    return out, amb


def main():
    a = sys.argv[1:]
    W = int(a[a.index("--window") + 1]) if "--window" in a else 200000
    files = [x for x in a if not x.startswith("--") and x != str(W) or x.endswith(".line")]
    files = [x for x in a if x.endswith(".line")]
    if not files:
        print(__doc__)
        return 1
    maxii = 0
    rows = []
    for fn in files:
        # 先只解析 II 以便按需生成图案
        m = re.search(r"\bII=([0-9A-F]+)", open(fn, encoding="utf-8", errors="replace").read())
        if m:
            maxii = max(maxii, int(m.group(1), 16))
    pat = R.pattern(maxii + W + 8)
    print("图案流已生成 %d 字节 (max II %d + 窗口 %d)\n" % (len(pat), maxii, W))

    for fn in files:
        r, err = one(fn, W, pat)
        if r is None:
            print("%-38s  ✗ %s" % (fn, err));  continue
        if r.get("paylen") is None:
            print("%-38s  ✗ %s" % (fn, r["amb"]));  continue
        k = r.get("k_hits")
        kstr = "唯一 +%d" % r["k"] if r.get("k") == r["paylen"] else \
               ("命中 %s" % k if k else "无命中")
        ok_k = "✓" if r.get("k") == r["paylen"] else "✗"
        ok_n = "✓" if abs(r["n"] - round(r["n"])) < 0.05 else "✗"
        ok_o = "✓" if r["OZ"] == round(r["n"]) else "✗"
        print("%s" % fn)
        print("   paylen=%-5d 帧数=%-6s II%%paylen=%-3d  UMM=%-8d 整帧数=%-7.2f %s"
              % (r["paylen"], r["nframes"], r["off"], r["UMM"], r["n"], ok_n))
        print("   k(唯一整字位移)=%-10s %s   OZ=%-4d == 整帧数? %s"
              % (kstr, ok_k, r["OZ"], ok_o))
        print("   每帧桶剖面 实测 %s" % ["%.1f" % v for v in r["prof"]])
        print("                    期望 %s   <- 容量x255/256" % ["%.1f" % v for v in r["caps"]])
        print("   受损帧占比 = %.5f%%  (n / 帧数)" % (100.0 * r["n"] / r["nframes"]))
        print()


if __name__ == "__main__":
    sys.exit(main())
