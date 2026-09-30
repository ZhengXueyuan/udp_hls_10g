# -*- coding: utf-8 -*-
"""
fingerprint.py -- 按**端点指纹**（不是 clock group 名）对齐 report_timing_summary。

为什么不用 clock group 名: 本工程实测过 group 名后缀 `_2/_3` 跨轮漂移
（自动生成名随 IP 例化顺序/层级编号变化），按名对齐会把"同一组"错配成两组。

指纹 = (Path Group, From Clock 代表段, To Clock 代表段, 最差 setup 路径的
Source/Destination 端点、最差 hold 路径的 Source/Destination 端点)。
两个时钟名做**去后缀归一化**后比较: `xxx_2` / `xxx_3` -> `xxx`。

用法: python fingerprint.py <timing_summary.rpt> [--global]
"""
import re
import sys


def norm_clock(c):
    c = c.strip()
    c = re.sub(r"_\d+$", "", c)          # rxoutclk_out[0]_3 -> rxoutclk_out[0]
    return c


def squeeze_clock(c):
    """完整时钟名太长 (xdma 的 buf_gt 路径) -> 只留最后 3 段做可读指纹。"""
    parts = c.split("/")
    return "/".join(parts[-2:]) if len(parts) > 2 else c


def parse(path):
    txt = open(path, encoding="utf-8", errors="replace").read().splitlines()
    # ---- 1. Design Timing Summary (全局 6 个数) ----
    g = {}
    for i, l in enumerate(txt[:200]):
        if "WNS(ns)" in l:
            for j in range(i + 2, i + 6):
                v = txt[j].split()
                if len(v) >= 12:
                    g = dict(WNS=v[0], TNS=v[1], TNS_FAIL=v[2], TNS_TOT=v[3],
                             WHS=v[4], THS=v[5], THS_FAIL=v[6], THS_TOT=v[7],
                             WPWS=v[8], TPWS=v[9], TPWS_FAIL=v[10], TPWS_TOT=v[11])
                    break
            break
    # ---- 2. Timing Details: 每个 From/To 块的**首条** setup / hold 路径 ----
    blocks = []
    cur = None
    p = None                      # 当前正在收集的那条 path
    for l in txt:
        s = l.strip()
        m = re.match(r"^From Clock:\s+(\S+)", s)
        if m:
            cur = dict(frm=norm_clock(m.group(1)), to="?", setup=None, hold=None, paths={})
            blocks.append(cur)
            p = None
            continue
        m = re.match(r"^To Clock:\s+(\S+)", s)
        if m and cur is not None:
            cur["to"] = norm_clock(m.group(1))
            continue
        m = re.match(r"^Slack\s+\((?:MET|VIOLATED)\)\s*:\s*(-?[\d.]+)ns", s)
        if m:
            p = dict(slack=float(m.group(1)))
            continue
        if p is None:
            continue
        if s.startswith("Source:"):
            p["src"] = squeeze_clock(s.split(":", 1)[1].strip())
        elif s.startswith("Destination:"):
            p["dst"] = squeeze_clock(s.split(":", 1)[1].strip())
        elif s.startswith("Path Group:"):
            p["grp"] = s.split(":", 1)[1].strip()
        elif s.startswith("Path Type:"):
            kind = s.split(":", 1)[1].strip()
            # ⚠️ async_default 束 (= 跨域/异步复位) 的 Path Type 报的是
            #    `Recovery` / `Removal`, **不是** `Setup` / `Hold` —— 只认后者会
            #    让整束 async 路径静默不入表 (本轮实测踩到: 全局 WNS 就在这一束里)。
            key = "setup" if kind.startswith(("Setup", "Recovery")) else (
                "hold" if kind.startswith(("Hold", "Removal")) else None)
            if key and cur is not None and cur[key] is None:
                cur[key] = p
            # 按 Path Group 收每一束的**首条** setup 路径 (async_default 束单独成键)
            if cur is not None and key == "setup":
                grp = p.get("grp", "?")
                grp = "**async_default**" if "async_default" in grp else "intra"
                if grp not in cur["paths"]:
                    cur["paths"][grp] = p
            p = None
    return g, blocks


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    show_global = "--global" in sys.argv
    g, blocks = parse(args[0])
    if g:
        print("GLOBAL: WNS=%s TNS=%s setup_fail=%s/%s | WHS=%s THS=%s hold_fail=%s/%s | "
              "WPWS=%s TPWS=%s pw_fail=%s/%s" % (
                  g["WNS"], g["TNS"], g["TNS_FAIL"], g["TNS_TOT"],
                  g["WHS"], g["THS"], g["THS_FAIL"], g["THS_TOT"],
                  g["WPWS"], g["TPWS"], g["TPWS_FAIL"], g["TPWS_TOT"]))
    if show_global:
        return
    print("%-30s %-16s %8s  %s" % ("FROM/TO CLOCK", "PATH GROUP", "SLACK", "WORST ENDPOINT (src -> dst)"))
    for b in blocks:
        for tag in ("intra", "**async_default**"):
            s = b["paths"].get(tag) or (b["setup"] if tag == "intra" else None)
            if not s:
                continue
            print("%-30s %-16s %8.3f  %s -> %s" % (
                squeeze_clock(b["frm"]) + " -> " + squeeze_clock(b["to"]),
                tag, s["slack"], s.get("src", "?"), s.get("dst", "?")))
        h = b["hold"]
        if h:
            print("%-30s %-16s %8.3f  [hold] %s -> %s" % (
                "", "", h["slack"], h.get("src", "?"), h.get("dst", "?")))


if __name__ == "__main__":
    main()
