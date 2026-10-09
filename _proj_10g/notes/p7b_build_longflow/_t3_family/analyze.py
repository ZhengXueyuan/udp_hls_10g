# -*- coding: utf-8 -*-
"""T3 分析: 读 out/<rung>/t3_stdout_*.txt + worst2000_*.txt, 出族普查与近临界计数。
只读脚本 (不改任何构建产物)。"""
import os, re, sys
from collections import Counter, defaultdict

BASE = r"D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_build_longflow\_t3_family\out"
RUNGS = ["C1", "S1", "S2", "S3", "R1"]


def load(rung):
    d = os.path.join(BASE, rung)
    so = os.path.join(d, "t3_stdout_%s.txt" % rung)
    if not os.path.exists(so):
        return None
    lines = [l.rstrip("\n") for l in open(so, encoding="utf-8", errors="replace")]
    t3 = [l for l in lines if l.startswith("T3|")]
    paths = []
    pf = os.path.join(d, "worst2000_%s.txt" % rung)
    if os.path.exists(pf):
        for l in open(pf, encoding="utf-8", errors="replace"):
            if l.startswith("#") or not l.strip():
                continue
            parts = l.rstrip("\n").split("|")
            if len(parts) < 5:
                continue
            paths.append({"slack": float(parts[0]), "src": parts[1], "dst": parts[2],
                          "lv": parts[3], "dly": parts[4]})
    return {"t3": t3, "paths": paths}


def parse_t3(t3):
    out = {"CNT": {}, "FAM": defaultdict(list), "CELLS": {}, "WNS": None, "UTIL": None,
           "FAMRES": {}, "NOTFOUND": []}
    for l in t3:
        f = l.split("|")
        if len(f) < 4:
            continue
        kind = f[1]          # T3|<KIND>|<rung>|...
        if kind == "CNT":
            out["CNT"][f[3]] = int(f[4])
        elif kind == "WNS":
            kv = dict(x.split("=", 1) for x in f[3:] if "=" in x)
            out["WNS"] = kv
        elif kind == "UTIL":
            out["UTIL"] = f[3:]
        elif kind == "UTIL2":
            out["UTIL2"] = f[3:]
        elif kind == "CELLS":
            out["CELLS"][f[3]] = (int(f[4].split("=")[1]), f[5:])
        elif kind == "FAMRES":
            for x in f[4:]:
                if "=" in x:
                    k, v = x.split("=", 1)
                    out["FAMRES"].setdefault(f[3], {})[k] = v
        elif kind == "FAM":
            lab = f[3]
            if len(f) >= 6 and f[4].endswith("NOT_FOUND"):
                out["NOTFOUND"].append((lab, f[4], f[5]))
            elif len(f) >= 6 and f[4] == "NOPATH":
                out["NOTFOUND"].append((lab, "NOPATH", ""))
            elif len(f) >= 6:
                kv = dict(x.split("=", 1) for x in f[5:] if "=" in x)
                out["FAM"][lab].append((int(f[4]), kv))
    return out


def norm_src(s):
    return re.sub(r"/[CD]$", "", s)


def fam_census(paths, thr):
    sel = [p for p in paths if p["slack"] < thr]
    c = Counter(norm_src(p["src"]) for p in sel)
    return sel, c


def main():
    data = {}
    for r in RUNGS:
        d = load(r)
        if d is None:
            print("## %s: NO DATA" % r)
            continue
        data[r] = d
        t = parse_t3(d["t3"])
        print("=" * 100)
        print("## %s" % r)
        print("  UTIL:  %s | %s" % (t.get("UTIL"), t.get("UTIL2")))
        if t["WNS"]:
            print("  WNS:   slack=%s src=%s dst=%s lv=%s" % (
                t["WNS"].get("slack"), t["WNS"].get("src"), t["WNS"].get("dst"), t["WNS"].get("lv")))
        print("  CELLS: " + "  ".join("%s=%s" % (k, v[0]) for k, v in t["CELLS"].items()))
        print("  CNT:   " + "  ".join("%s=%d" % (k, v) for k, v in sorted(t["CNT"].items())))
        if t["NOTFOUND"]:
            print("  NOTFOUND: %s" % t["NOTFOUND"])
        # 族精确查询
        for lab in ["A_exact", "A_dst_only", "B_exact", "B_dst_only", "C_exact", "D_exact", "E_exact"]:
            if lab in t["FAM"]:
                k0 = t["FAM"][lab][0]
                print("  FAM %-11s -> slack=%s src=%s dst=%s lv=%s" % (lab, k0[1].get("slack"), k0[1].get("src"), k0[1].get("dst"), k0[1].get("lv")))
            elif lab in t["FAMRES"]:
                print("  FAM %-11s -> (resolved but no path) %s" % (lab, t["FAMRES"][lab]))
        # 近临界族普查
        for thr in (0.05, 0.10, 0.20):
            sel, c = fam_census(d["paths"], thr)
            n_dump = len(sel)
            n_cnt = t["CNT"].get("lt_%.2f" % thr)
            tag = "EXACT" if (n_cnt is not None and n_cnt == n_dump) else ("CAP(dump<count)" if n_cnt and n_cnt > n_dump else "")
            print("  --- slack<%.2f : dump=%d cnt=%s %s" % (thr, n_dump, n_cnt, tag))
            for name, cnt in c.most_common(6):
                sub = [p for p in sel if norm_src(p["src"]) == name]
                mn = min(p["slack"] for p in sub)
                lvs = Counter(p["lv"] for p in sub)
                print("      %-42s n=%-4d minslack=%+.3f lv=%s" % (name, cnt, mn, dict(lvs)))
        # 全部 2000 条的源族分布 (广度)
        c_all = Counter(norm_src(p["src"]) for p in d["paths"])
        print("  --- 全 2000 条源族 (top8): %s" % c_all.most_common(8))


if __name__ == "__main__":
    main()
