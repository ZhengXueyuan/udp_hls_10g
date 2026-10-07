#!/usr/bin/env python3
"""wu_ladder_parse.py -- 从 J6-ladder 原始件提取每跑读数 + 判据 (b)(d) 的计算。

用法: python wu_ladder_parse.py <dir> <prefix>   # 例: _proj_10g/notes/p7b_wu_loop/neg wu_neg
  文件命名约定: <prefix>_<Ppoint>_r<N>.txt / ss_WU_<ARM>_<Ppoint>_R<n>.log
输出: 每跑一行 CSV 风格; 附 ss 的 pacing_rate 汇总 (判据 (b))。

⛔ 2026-10-07 订正 (P7B StB 判据修正轮): `d_ratio` (判据 (d) 的核心) 原先 = **mod 2^32 余数 ÷ 64 位
   tx_bytes** ⇒ >2.86 Gbps (2^32 B / 12 s) 时按字面必 FAIL (板侧速率同病, 低 70%)。现改为
   `unwrap32` 还原后再算, 且 `raw`/`k` 全部落表 (回卷必须可见)。见 parse_run 里的订正块。
"""
import glob
import os
import re
import sys

MOD32 = 1 << 32
TB_MAX_S = MOD32 / 156.25e6      # W5/W24 自由计数 (156.25 MHz) 回绕周期 = 27.487 s
sys.stdout.reconfigure(encoding="utf-8", errors="replace")   # 工程坑 16①: GBK 控制台假 FAIL


def unwrap32(d_raw, ref):
    """mod-2^32 差值 -> 与 ref (64 位口径) 同量纲; 返回 (值, k)。盲区 = 真偏差 ≈ j·2^32
    (原理极限); 错 k 必差 2^32 = 4.295 GB >> ±0.5% 容差 ⇒ 判别力不受影响 (详见
    P7B_STAGEB_CRITERIA_FIX.md §①)。"""
    k = max(0, int(round((ref - d_raw) / float(MOD32))))
    return d_raw + k * MOD32, k


def w_of(txt, snap_suffix, word):
    """在指定快照块里取字 Wi 的值 (十六进制文本 -> int)。"""
    cur = None
    for line in txt.splitlines():
        if line.startswith("SNAP_BEGIN "):
            cur = line.split()[1]
            continue
        if line.startswith("SNAP_END"):
            cur = None
            continue
        if cur is None or not cur.endswith(snap_suffix):
            continue
        m = re.match(r"^W(\d+)\s+0x\S+\s+\S+\s+(0x[0-9a-fA-F]+)$", line)
        if m and int(m.group(1)) == word:
            return int(m.group(2), 16)
    return None


def parse_run(path):
    txt = open(path, encoding="utf-8", errors="replace").read()
    r = {"file": os.path.basename(path)}
    m = re.search(r"J6META_T_START_UTC=(\S+)", txt)
    r["t_start"] = m.group(1) if m else "?"
    m = re.search(r"J6META_T_END_UTC=(\S+)", txt)
    r["t_end"] = m.group(1) if m else "?"
    m = re.search(r"^PACE_BPS=(\d+)", txt, re.M)
    r["pace"] = int(m.group(1)) if m else None
    m = re.search(r"SCRIPT_MD5=(\S+)", txt)
    r["script_md5"] = m.group(1) if m else "?"
    m = re.search(r"SRC_SUM tx_bytes=(\d+) rx_bytes=(\d+) dur_s=([\d.]+) tx_Mbps=([\d.]+) rx_Mbps=([\d.]+)",
                  txt)
    if m:
        r["tx_bytes"] = int(m.group(1))
        r["dur_s"] = float(m.group(3))
        r["tx_Mbps"] = float(m.group(4))
    else:
        r["tx_bytes"] = r["dur_s"] = r["tx_Mbps"] = None
    # 快照字
    for tag, w in (("pre", 0), ("pre", 5), ("pre", 20), ("pre", 22), ("pre", 53), ("pre", 54),
                   ("pre", 55), ("t0", 5), ("t0", 53), ("t0", 54), ("t1", 5), ("t1", 53),
                   ("t1", 54), ("post", 0), ("post", 5), ("post", 20), ("post", 22),
                   ("post", 53), ("post", 54), ("post", 55)):
        key = "%s_W%d" % (tag, w)
        if key in r:
            continue
        r[key] = w_of(txt, "_" + tag, w)
    # 差分 (W5 = 32 位自由计数, mod 2^32)
    # ⛔ 2026-10-07 订正 (P7B StB 判据修正轮): 原句 (保留) =
    #      r["dW53_prepost"] = (r["post_W53"] - r["pre_W53"]) % MOD32     ← 只有余数
    #      r["d_ratio"]      = r["dW53_prepost"] / r["tx_bytes"]          ← 余数 ÷ 64 位 ⇒ >2.86 Gbps 假 FAIL
    #      r["board_Mbps_prepost"] = dW53_prepost * 8 * 156.25e6 / dW5…   ← 板侧速率低 70% (同一余数)
    #    改为: `*_raw` = 余数 (落表), 还原到 tx_bytes 量纲后再算 ratio / 速率; 全部记 k。
    if r.get("post_W53") is not None and r.get("pre_W53") is not None:
        r["dW53_prepost_raw"] = (r["post_W53"] - r["pre_W53"]) % MOD32
        r["dW5_prepost"] = (r["post_W5"] - r["pre_W5"]) % MOD32
        if r.get("tx_bytes"):
            r["dW53_prepost"], r["dW53_prepost_k"] = unwrap32(r["dW53_prepost_raw"], r["tx_bytes"])
        else:
            r["dW53_prepost"], r["dW53_prepost_k"] = r["dW53_prepost_raw"], None
        r["board_Mbps_prepost"] = (r["dW53_prepost"] * 8 * 156.25e6 / r["dW5_prepost"] / 1e6
                                   if r["dW5_prepost"] else None)
    if r.get("t1_W53") is not None and r.get("t0_W53") is not None:
        r["dW53_t0t1_raw"] = (r["t1_W53"] - r["t0_W53"]) % MOD32
        r["dW5_t0t1"] = (r["t1_W5"] - r["t0_W5"]) % MOD32
        if r.get("tx_bytes"):
            r["dW53_t0t1"], r["dW53_t0t1_k"] = unwrap32(r["dW53_t0t1_raw"], r["tx_bytes"])
        else:
            r["dW53_t0t1"], r["dW53_t0t1_k"] = r["dW53_t0t1_raw"], None
        r["win_s"] = r["dW5_t0t1"] / 156.25e6
        # 时基守卫: W5 32 位自由计数 ⇒ 窗 ≥ 27.487 s 时速率不可判 (静默错 70%)
        r["tb_ok"] = r["win_s"] < TB_MAX_S
        r["board_Mbps_t0t1"] = (r["dW53_t0t1"] * 8 * 156.25e6 / r["dW5_t0t1"] / 1e6
                                if (r["dW5_t0t1"] and r["tb_ok"]) else None)
    if r.get("dW53_prepost") is not None and r.get("tx_bytes"):
        r["d_ratio"] = r["dW53_prepost"] / r["tx_bytes"]
    if r.get("dW54_t0t1") is None and r.get("t1_W54") is not None and r.get("t0_W54") is not None:
        r["dW54_t0t1"] = (r["t1_W54"] - r["t0_W54"]) % MOD32
    return r


def parse_ss(path):
    """从 ss 采样日志里提取 pacing_rate 值 (判据 (b))。"""
    if not os.path.exists(path):
        return None
    txt = open(path, encoding="utf-8", errors="replace").read()
    vals = re.findall(r"pacing_rate (\d+)bps(?:/(\d+)bps)?", txt)
    if not vals:
        return {"n": 0}
    cur = [int(a) for a, _b in vals]
    mx = [int(b) if b else None for _a, b in vals]
    return {
        "n": len(vals),
        "pacing_cur_min": min(cur), "pacing_cur_max": max(cur),
        "pacing_max_all": sorted(set(x for x in mx if x))[:3],
    }


def main():
    d, prefix = sys.argv[1], sys.argv[2]
    files = sorted(glob.glob(os.path.join(d, "%s_*_r*.txt" % prefix)),
                   key=lambda p: (re.search(r"_([Pp]\d+)_r(\d+)", p).group(1),
                                  re.search(r"_([Pp]\d+)_r(\d+)", p).group(2)))
    print("== %d runs in %s ==" % (len(files), d))
    for f in files:
        r = parse_run(f)
        pace = r["pace"]
        print("RUN %-32s pace=%-12s tx_bytes=%-12s dur=%-7s tx_Mbps=%-9s" % (
            r["file"], pace, r["tx_bytes"], r["dur_s"], r["tx_Mbps"]))
        print("    t %s -> %s" % (r["t_start"], r["t_end"]))
        print("    dW53(prepost)=%s [raw=%s k=%s] dW5=%s board_Mbps(prepost)=%s d/txb=%s" % (
            r.get("dW53_prepost"), r.get("dW53_prepost_raw"), r.get("dW53_prepost_k"),
            r.get("dW5_prepost"),
            "%.3f" % r["board_Mbps_prepost"] if r.get("board_Mbps_prepost") else None,
            "%.6f" % r["d_ratio"] if r.get("d_ratio") else None))
        print("    t0t1: dW53=%s [raw=%s k=%s] dW5=%s win_s=%s board_Mbps=%.3f dW54=%s tb=%s" % (
            r.get("dW53_t0t1"), r.get("dW53_t0t1_raw"), r.get("dW53_t0t1_k"),
            r.get("dW5_t0t1"),
            "%.4f" % r["win_s"] if r.get("win_s") else None,
            r["board_Mbps_t0t1"] if r.get("board_Mbps_t0t1") else -1,
            r.get("dW54_t0t1"),
            "OK" if r.get("tb_ok") else "**不可判(W5 时基)**"))
        print("    pre:  W0=%s W20=%s W22=%s W53=%s W54=%s W55=%s" % (
            r.get("pre_W0"), r.get("pre_W20"), r.get("pre_W22"), r.get("pre_W53"),
            r.get("pre_W54"), r.get("pre_W55")))
        print("    post: W0=%s W20=%s W22=%s W53=%s W54=%s W55=%s" % (
            r.get("post_W0"), r.get("post_W20"), r.get("post_W22"), r.get("post_W53"),
            r.get("post_W54"), r.get("post_W55")))
        # ss (对端日志名: ss_WU_NEG_P0_R1.log — 大写 P/R)
        arm = "WU_" + os.path.basename(d.rstrip("/\\")).upper()
        m2 = re.search(r"_([Pp]\d+)_r(\d+)\.txt$", r["file"])
        ss = None
        if m2:
            ss = parse_ss(os.path.join(d, "ss_%s_%s_R%s.log" % (
                arm, m2.group(1).upper(), m2.group(2))))
        print("    ss pacing: %s" % (ss,))


if __name__ == "__main__":
    main()
