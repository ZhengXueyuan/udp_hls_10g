#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#=============================================================================
# extract_build_readings.py -- P7B-LONGFLOW 换目标轮 (找最长合格档) 每档读数抽取器
#   用法: python extract_build_readings.py <tier_dir>
#   期望 <tier_dir> 里已抢救齐: wrapper_p4.bit / p7b_ku5p_{timing,util,drc,clkinteract}.rpt
#                                / p7b_ku5p_stdout.txt / runme_impl_1.log
#   输出 (只读, 不写文件):
#     (1) 位流 sha256 / 字节数 / SW_CRC / .bit 头日期时间
#     (2) tcl 显式读数 (P7B_WNS/WHS/BIT_EXISTS/DONE) + "Parameter ... bound to:" (输入自证)
#     (3) Design Timing Summary 12 数 + 报告自述结论  (判据原文 = board/check_p6e_timing.py)
#     (4) 失败族清单 ("Slack (VIOLATED)" 路径块: Slack / Path Type / Logic Levels / SRC / DST)
#     (5) Routed 资源 (CLB LUTs / CLB Registers / Unique Control Sets / BUFGCE / FDRE / FDCE
#                      / Block RAM Tile / URAM / DSPs / Bonded IOB)
#=============================================================================
import re, sys, os, hashlib

try:  # 坑 16-①: GBK 控制台下 print 非 ASCII 会抛 UnicodeEncodeError
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

def main(d):
    if not os.path.isdir(d):
        print("FAIL: not a directory:", d); return 1
    p = lambda n: os.path.join(d, n)

    print("TIER_DIR:", d)
    print("=" * 100)

    # ---- (1) bitstream -----------------------------------------------------
    bp = p("wrapper_p4.bit")
    if os.path.exists(bp):
        h = hashlib.sha256()
        with open(bp, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        head = open(bp, "rb").read(320)
        m_crc = re.search(rb"SW_CRC=([0-9a-fA-F]{8})", head)
        m_d = re.search(rb"(\d{4}/\d{2}/\d{2})", head)
        m_t = re.search(rb"(\d{2}:\d{2}:\d{2})", head)
        print("[BIT] sha256 =", h.hexdigest())
        print("[BIT] bytes  =", os.path.getsize(bp))
        print("[BIT] SW_CRC =", (m_crc.group(1).decode() if m_crc else "?"))
        print("[BIT] header =", (m_d.group(1).decode() + " " + m_t.group(1).decode())
              if (m_d and m_t) else "?")
    else:
        print("[BIT] MISSING", bp)

    # ---- (2) tcl readings + input self-证 ----------------------------------
    so = p("p7b_ku5p_stdout.txt")
    if os.path.exists(so):
        txt = open(so, encoding="utf-8", errors="replace").read()
        for key in ("P7B_CONVERGED_AT_ROUND", "P7B_IS_LOCKED_POSTGEN", "P7B_WNS", "P7B_WHS",
                    "P7B_BIT_EXISTS", "P7B DONE", "P7B_VERDICT"):
            for m in re.finditer(r"^" + re.escape(key) + r".*$", txt, re.M):
                print("[TCL]", m.group(0).strip())
        for m in re.finditer(r"^\s*Parameter (TX_BYTES|BUILD_ID_V) bound to:.*$", txt, re.M):
            print("[TCL]", m.group(0).strip())
    else:
        print("[TCL] MISSING", so)

    # ---- (3) timing summary ------------------------------------------------
    tr = p("p7b_ku5p_timing.rpt")
    if os.path.exists(tr):
        txt = open(tr, encoding="utf-8", errors="replace").read()
        i = txt.find("Design Timing Summary")
        if i < 0:
            print("[TSUM] NO Design Timing Summary")
        else:
            m = re.search(r"^\s*(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+(\d+)\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+(\d+)\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+(\d+)\s*$",
                          txt[i:], re.M)
            if m:
                g = m.groups()
                print("[TSUM] setup WNS=%s TNS=%s fail=%s/%s" % (g[0], g[1], g[2], g[3]))
                print("[TSUM] hold  WHS=%s THS=%s fail=%s/%s" % (g[4], g[5], g[6], g[7]))
                print("[TSUM] pulse WPWS=%s TPWS=%s fail=%s/%s" % (g[8], g[9], g[10], g[11]))
            else:
                print("[TSUM] row not parsed")
        print("[TSUM] SELF-VERDICT:", "constraints met"
              if "All user specified timing constraints are met." in txt else "NOT met")
        # ---- (4) fail family ----------------------------------------------
        blocks = re.split(r"Slack \(VIOLATED\)\s*:\s*", txt)[1:]
        print("[FAILFAM] VIOLATED PATH BLOCKS LISTED: %d (报告默认只列 top-N)" % len(blocks))
        for b in blocks:
            slack = b.split("ns", 1)[0].strip()
            src = re.search(r"Source:\s+(\S+)", b)
            dst = re.search(r"Destination:\s+(\S+)", b)
            pt = re.search(r"Path Type:\s+(.+?)\s*$", b, re.M)
            ll = re.search(r"Logic Levels:\s+(\d+)", b)
            print("  slack=%s type=%s levels=%s" % (slack, pt.group(1) if pt else "?", ll.group(1) if ll else "?"))
            print("    SRC=%s" % (src.group(1) if src else "?"))
            print("    DST=%s" % (dst.group(1) if dst else "?"))
    else:
        print("[TSUM] MISSING", tr)

    # ---- (5) routed resources ---------------------------------------------
    ur = p("p7b_ku5p_util.rpt")
    if os.path.exists(ur):
        txt = open(ur, encoding="utf-8", errors="replace").read()
        want = ["CLB LUTs", "CLB Registers", "Unique Control Sets", "Block RAM Tile",
                "URAM", "DSPs", "Bonded IOB", "BUFGCE "]
        seen = set()
        for line in txt.splitlines():
            for w in want:
                if line.startswith("| " + w.strip()) and w not in seen:
                    if w == "BUFGCE " and not line.startswith("| BUFGCE "):
                        continue
                    nums = [x.strip() for x in line.strip().strip("|").split("|")]
                    print("[UTIL] %-22s used=%-7s avail=%-7s pct=%s" % (
                        nums[0], nums[1],
                        nums[4] if len(nums) > 4 else "?",
                        nums[5] if len(nums) > 5 else "?"))
                    seen.add(w)
        for key in ("FDRE", "FDCE"):
            m = re.search(r"^\|\s*" + key + r"\s*\|\s*(\d+)", txt, re.M)
            if m:
                print("[UTIL] %-22s used=%s" % (key, m.group(1)))
    else:
        print("[UTIL] MISSING", ur)
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
