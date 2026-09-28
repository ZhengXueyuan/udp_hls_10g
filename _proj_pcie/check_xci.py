# check_xci.py -- 从**持久化 .xci** 核对 XDMA 的关键配置 (纪律: 不信任即时回读)
#   用法: 在 _proj_pcie 目录下 `python check_xci.py`; 全对退出 0, 否则非零并列出不符项。
import re, sys, glob

pats = glob.glob("vivado_prj/pcie_min_prj.srcs/sources_1/ip/xdma_0/xdma_0.xci")
if not pats:
    print("XCICHK: xdma_0.xci not found")
    sys.exit(1)
s = open(pats[0], encoding="utf-8", errors="ignore").read()
# 2025.2 的 .xci 是 JSON 风格: "key": [ { "value": "..." } ]
v = dict(re.findall(r'"([A-Za-z0-9_]+)"\s*:\s*\[\s*\{\s*"value"\s*:\s*"([^"]*)"', s))

exp = {
    "pcie_blk_locn":        "X0Y0",
    "pf0_device_id":        "9034",
    "ref_clk_freq":         "100_MHz",
    "axilite_master_en":    "true",
    "axilite_master_scale": "Megabytes",
    "axilite_master_size":  "1",
    "pf0_bar0_enabled":     "true",
}
bad = 0
for k, e in exp.items():
    g = v.get(k, "<missing>")
    if g != e:
        bad += 1
    print("XCICHK %s %-22s = %-12s (want %s)" % ("OK " if g == e else "BAD", k, g, e))
print("XCICHK RESULT:", "ALL-MATCH" if bad == 0 else "%d MISMATCH" % bad)
sys.exit(1 if bad else 0)
