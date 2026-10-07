#!/usr/bin/env python3
"""stagea_tables.py -- Stage A 逐跑表 (机械从原始件算, 不手抄)。

输入: run_*.txt (j6 台架全量 stdout) + ss_STG_*.log
输出: 每跑一行; 另打 (g') 的 rho 与两段速率判据 (e)/(f) 的判定值。
用法: python stagea_tables.py <run_dir> [<prefix>]

⛔ 2026-10-07 订正 (P7B StB 判据修正轮): 32 位计数器回卷 -- 见下面 `unwrap32` 与 parse_run 里的
   两处订正块。**原句保留在各订正块里**。起因 = 板级实测 `ΔW53_raw = 1,792,146,940` /
   对端 `tx_bytes = 6,087,114,752` (P7B_BOARD_STAGEB.md §2.3(a)): 只 mod 2^32 会让 (d) 假 FAIL。
"""
import glob
import os
import re
import sys

CAP_BOARD = 1111.1     # TCP app 结构天花板 Mbps (0.889 B/拍 x 156.25 MHz)
# ⚠️ 2026-10-07 加口子 (不改默认值): §4.1c 的 (g') 把 `板容量` 定义为"当前 TCP app 结构天花板,
#    RX/TX 加宽后按新天花板重取" —— R1 (RX 8 路) 之后该值 = 9759.4 Mbps (P7B_STAGEB_RX8.md §2),
#    但本脚本此前**没有覆盖口子** (Stage B 轮只能手工重算)。现允许 `CAP_BOARD=9759.4 python ...` 覆盖;
#    默认值逐字未动 ⇒ 旧读数复算结果与以前一致。
CAP_BOARD = float(os.environ.get("CAP_BOARD", str(CAP_BOARD)))
MOD32 = 1 << 32
# ⛔ 2026-10-07 订正 (P7B StB 判据修正轮, 本件): 本脚本原先只做 `% MOD32` 就算 (d),
#    那把"回卷后的余数"直接当成了增量 ⇒ **>2.86 Gbps (2^32 B / 12 s) 时 (d) 按字面必 FAIL**。
#    实测原件 = P7B_BOARD_STAGEB.md §2.3(a): `ΔW53_raw = 1,792,146,940`, 对端 `tx_bytes = 6,087,114,752`
#    (= 2^32 + 1,792,147,456) ⇒ 未还原时 ratio = 0.294 ⇒ 假 FAIL。
#    现改为: ① 原始读数**全部落表**(回卷必须可见, 不许被 mod 抹掉); ② 按 k·2^32 还原后再判 (d);
#    ③ W5 时基加 27.487 s 上限守卫 (156.25 MHz 自由计数, 窗超限即不可判)。
TB_MAX_S = MOD32 / 156.25e6      # 156.25 MHz 自由计数 (W5/W24/W36/W43) 的回绕周期 = 27.487 s


def unwrap32(d_raw, ref):
    """把 mod-2^32 的差值还原到 ref (64 位口径) 的同一量纲; 返回 (值, k)。

    k = 使 |d_raw + k*2^32 - ref| 最小的整数 (k >= 0) —— 这是**歧义消解**, 不是自证:
    任何错误的 k 都差 2^32 = 4.295 GB, 而 ±0.5% 容差在 tx ~ 6 GB 时只有 30 MB
    ⇒ 判别力不受影响 (k 选错必被抓)。
    ⚠️ **盲区 (必须登记)**: 真偏差恰 ≈ j*2^32 时结构性不可分辨 (j=1 = 一轮回卷
    ≈ 12 s 窗流量的 70%) —— 32 位计数器 + 两点读数, 这是原理极限。
    """
    k = max(0, int(round((ref - d_raw) / float(MOD32))))
    return d_raw + k * MOD32, k


def w_of(txt, tag, word):
    cur = None
    for line in txt.splitlines():
        if line.startswith("SNAP_BEGIN "):
            cur = line.split()[1]
            continue
        if line.startswith("SNAP_END"):
            cur = None
            continue
        if cur is None or not cur.endswith("_" + tag):
            continue
        m = re.match(r"^W(\d+)\s+0x\S+\s+\S+\s+(0x[0-9a-fA-F]+)$", line)
        if m and int(m.group(1)) == word:
            return int(m.group(2), 16)
    return None


def parse_run(path):
    txt = open(path, encoding="utf-8", errors="replace").read()
    r = {"file": os.path.basename(path)}
    m = re.search(r"^PACE_BPS=(\d+)", txt, re.M)
    r["pace"] = int(m.group(1)) if m else None
    m = re.search(r"SRC_SUM tx_bytes=(\d+) rx_bytes=(\d+) dur_s=([\d.]+) tx_Mbps=([\d.]+)", txt)
    if m:
        r["tx_bytes"] = int(m.group(1))
        r["dur"] = float(m.group(3))
        r["tx_mbps"] = float(m.group(4))
    else:
        r["tx_bytes"] = r["dur"] = r["tx_mbps"] = None
    for tag in ("pre", "t0", "t1", "post"):
        for w in (5, 53, 54, 61, 62):
            r["%s_W%d" % (tag, w)] = w_of(txt, tag, w)
    # ⛔ 订正 (2026-10-07): 原来的两句 (逐字保留于此, 只作历史):
    #   r["d53"]   = (r["post_W53"] - r["pre_W53"]) % MOD32   ← 只有"余数", 直接进 ratio ⇒ 回卷后假 FAIL
    #   r["d53_t"] = (r["t1_W53"]   - r["t0_W53"])   % MOD32   ← 同上 (板侧速率会低 70%)
    #   新口径: `*_raw` = mod 2^32 余数 (原始读数落表可见), `d53*` = 还原后 (与 tx_bytes 同量纲)。
    r["d53_raw"] = (r["post_W53"] - r["pre_W53"]) % MOD32 if None not in (r["post_W53"], r["pre_W53"]) else None
    r["d53_t_raw"] = (r["t1_W53"] - r["t0_W53"]) % MOD32 if None not in (r["t1_W53"], r["t0_W53"]) else None
    r["d5_t"] = (r["t1_W5"] - r["t0_W5"]) % MOD32 if None not in (r["t1_W5"], r["t0_W5"]) else None
    r["d61"] = (r["t1_W61"] - r["t0_W61"]) % MOD32 if None not in (r["t1_W61"], r["t0_W61"]) else None
    r["d54"] = (r["t1_W54"] - r["t0_W54"]) % MOD32 if None not in (r["t1_W54"], r["t0_W54"]) else None
    if r["d53_raw"] is not None and r["tx_bytes"]:
        r["d53"], r["d53_k"] = unwrap32(r["d53_raw"], r["tx_bytes"])
    else:
        r["d53"], r["d53_k"] = None, None
    if r["d53_t_raw"] is not None and r["tx_bytes"]:
        r["d53_t"], r["d53_t_k"] = unwrap32(r["d53_t_raw"], r["tx_bytes"])
    else:
        r["d53_t"], r["d53_t_k"] = None, None
    r["ratio53"] = (r["d53"] / r["tx_bytes"]) if (r["d53"] is not None and r["tx_bytes"]) else None
    # 时基守卫: W5 是 32 位自由计数 ⇒ 窗 (pre->post / t0->t1) 超 27.487 s 就回卷, 速率不可判
    m = re.search(r"J6META_DUR_S=([\d.]+)", txt)
    r["dur_meta"] = float(m.group(1)) if m else None
    r["tb_ok"] = (r["d5_t"] is not None and r["d5_t"] > 0
                  and (r["dur_meta"] is None or r["dur_meta"] < TB_MAX_S))
    if r.get("d5_t"):
        r["brd_mbps"] = (r["d53_t"] * 8 * 156.25e6 / r["d5_t"] / 1e6) if r.get("tb_ok") else None
    else:
        r["brd_mbps"] = None
    gm = re.search(r"J6_GEOM_OK NW=(\d+) BID=(\S+)", txt)
    r["geom"] = ("%s/%s" % (gm.group(1), gm.group(2))) if gm else "MISSING"
    m = re.search(r"CARRIER=(\d)", txt)
    r["carrier"] = m.group(1) if m else "?"
    return r


def pace_of(fn):
    m = re.search(r"_([Pp]\w+?)_r(\d)", os.path.basename(fn))
    return m.group(1).upper() if m else "?"


d = sys.argv[1]
pref = sys.argv[2] if len(sys.argv) > 2 else "run_"
files = sorted(glob.glob(os.path.join(d, pref + "*.txt")))

print("%-30s %-12s %-13s %-10s %-10s %-8s %-9s %-12s %-8s %-6s" % (
    "RUN", "PACE(B/s)", "tx_bytes", "tx_Mbps", "cap", "rho", "dW53/txb", "brd_Mbps(t0t1)", "dW61", "geom"))
for f in files:
    r = parse_run(f)
    pace = r["pace"] if r["pace"] is not None else -1
    cap = CAP_BOARD if pace == 0 else min(CAP_BOARD, 8 * pace / 1e6)
    rho = (r["tx_mbps"] / cap) if (r["tx_mbps"] and cap) else None
    print("%-30s %-12s %-13s %-10s %-10.1f %-8s %-9s %-12s %-8s %-6s" % (
        r["file"], pace, r["tx_bytes"], r["tx_mbps"], cap,
        "%.5f" % rho if rho else "-",
        "%.6f" % r["ratio53"] if r["ratio53"] else "-",
        "%.3f" % r["brd_mbps"] if r["brd_mbps"] else "-",
        r["d61"], r["geom"]))
    # ⛔ 订正 (2026-10-07): 原始读数 + 回卷次数必须落表 —— mod 2^32 只给余数,
    #    若不把 `k` 与四个原始读数打出来, "回卷发生过"这件事就被静默抹掉了 (本工程老坑)。
    print("      RAW W53 pre=%s t0=%s t1=%s post=%s | dW53_raw=%s k=%s -> dW53=%s | dW53_t_raw=%s k=%s | tb=%s(dur_meta=%s)"
          % (r.get("pre_W53"), r.get("t0_W53"), r.get("t1_W53"), r.get("post_W53"),
             r.get("d53_raw"), r.get("d53_k"), r.get("d53"),
             r.get("d53_t_raw"), r.get("d53_t_k"),
             "OK" if r.get("tb_ok") else "**不可判(W5 时基超 27.487 s 或空)**", r.get("dur_meta")))
    # 判定
    if rho is not None:
        e = (pace is not None and pace <= 100e6)
        f_ = (pace is not None and (pace >= 160e6 or pace == 0))
        tags = []
        if e:
            tags.append("(e)%s" % ("OK" if r["tx_mbps"] >= 0.95 * 8 * pace / 1e6 else "FAIL"))
        if f_:
            tags.append("(f)%s" % ("OK" if r["tx_mbps"] >= 1000 else "FAIL"))
        tags.append("(g')%s" % ("OK" if 0.95 <= rho <= 1.05 else "FAIL"))
        # (d): 用**还原后**的 d53 (与 tx_bytes 同量纲); k>0 = 本跑内发生过回卷 (读数仍有效)
        # ⚠️ 2026-10-07: 读数缺失 (ratio53 = None) 记 **"不可判"** —— 不许当 FAIL (空判据先例: W13)
        if not r["ratio53"]:
            tags.append("(d)不可判(缺读数)")
        else:
            tags.append("(d)%s%s" % ("OK" if abs(r["ratio53"] - 1) <= 0.005 else "FAIL/BAD",
                                     "+wrap%dx" % r["d53_k"] if r.get("d53_k") else ""))
        print("      " + "  ".join(tags))
