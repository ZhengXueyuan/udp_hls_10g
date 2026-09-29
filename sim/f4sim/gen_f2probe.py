#!/usr/bin/env python
"""F4-2 探针激励生成 (极小, 专打 "欠 TERM 期间新帧的字抢在 TERM 之前落笔")。

复用 tools/gen_f4_stim.py 的帧构造器 (同一 FCS 口径)。用法:
    python sim/f4sim/gen_f2probe.py            # 写到 sim/f4sim/f2probe/

例组:
  A14_*  : [填充 200B][净荷 14B (1 整字+6B)][跟随 60B], 停窗到短帧帧尾之后
           —— 14B 落在 F4(b) 的临界带 (净荷 8..15)
  B200_* : [填充 200B 帧中丢 -> 欠 TERM][紧跟 60B], 停窗压到跟随帧前导附近
  C500_* : [填充 200B 帧中丢 -> 欠 TERM][紧跟 500B 多字长帧]
  Bctl   : 对照 (不 stall)
判据 (tools/f4_ab_check.py): **好帧不被白丢** —— 任何变体不得比修复前少交付好帧。
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'tools'))
import gen_f4_stim as G          # noqa: E402


def cases():
    c = []
    for k in (0, 8, 16, 24):
        c.append(("A14_k%02d" % k, [200, 14, 60], 148 - k, 236 + 14 + 6))
    c.append(("A14_long", [200, 14, 60], 120, 300))
    for k in (0, 8, 16, 24):
        c.append(("B200_k%02d" % k, [200, 60, 60], 16, 212 - k))
    c.append(("B200_x", [200, 60, 60], 16, 226))
    c.append(("B200_y", [200, 60, 60], 16, 240))
    for k in (0, 8, 16, 24, 32):
        c.append(("C500_k%02d" % k, [200, 500, 60], 16, 210 - k))
    for k in (0, 8, 16):
        c.append(("C120_k%02d" % k, [200, 120, 60], 16, 210 - k))
    c.append(("Bctl", [200, 60, 60], None, None))
    return c


def main(outdir):
    data, dv, er, wr, meta = [], [], [], [], []
    for name, lens, sfrom, sto in cases():
        i0 = len(data)
        for n in lens:
            seg = G.mk_frame(n)
            data += list(seg); dv += [1] * len(seg); er += [0] * len(seg)
            data += list(G.IFG); dv += [0] * len(G.IFG); er += [0] * len(G.IFG)
        i1 = len(data)
        for k in range(i0, i1):
            off = k - i0
            wr.append(0 if (sfrom is not None and sfrom <= off < sto) else 1)
        data += [0x07] * 400; dv += [0] * 400; er += [0] * 400; wr += [1] * 400
        i1 = len(data)
        meta.append((name, i0, i1, -1 if sfrom is None else sfrom,
                     -1 if sto is None else sto, len(lens), sum(lens)))
    os.makedirs(outdir, exist_ok=True)

    def w(fn, rows, fmt):
        with open(os.path.join(outdir, fn), "w") as fh:
            fh.write("\n".join(fmt % r for r in rows) + "\n")

    w("f4_data.memh", data, "%02X")
    w("f4_dv.memh", dv, "%d")
    w("f4_er.memh", er, "%d")
    w("f4_wr.memh", wr, "%d")
    with open(os.path.join(outdir, "f4_cases.txt"), "w") as fh:
        for m in meta:
            fh.write("%s %d %d %d %d %d %d\n" % m)
    print("gen_f2probe: %d 例 / %d 拍 -> %s" % (len(meta), len(data), outdir))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "sim/f4sim/f2probe")
