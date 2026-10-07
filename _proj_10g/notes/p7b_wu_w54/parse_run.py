#!/usr/bin/env python3
"""parse_run.py -- W54 关闸轮: 从 j6_fix.sh 原始件提取读数 (自写, 只读文本)。

用法: python parse_run.py <run.txt> [<run.txt> ...]
输出: 每跑一段 KEY=VALUE (便于 grep/md 粘贴) + 一行 CSV。
口径 (写死):
  dW53/dW54(pre->post)   = 该跑 pre 快照 -> post 快照 的板侧增量 (mod 2^32; W5/W53/W54 均为 32 位自由计数)
  dW53/dW54(t0->t1)      = 紧贴传输窗的两点 (台架自证 (d) 用的窗口)
  ratio                  = dW53(pre->post) / tx_bytes (台架自证 (d): 应 ~1)
                           ⛔ 2026-10-07 订正: `dW53(pre->post)` 必须是**按 k·2^32 还原后**的值 ——
                           原来只取 mod 2^32 余数 ⇒ >2.86 Gbps 时 ratio ≈ 0.29~0.5 = **假 FAIL**
                           (本文件的 dW54 关闸轮跑在 ≤1.28 Gbps, 未触发; 口径已按新规则统一)。
                           `*_raw` (余数) 与 `k` 仍全部落表 ⇒ 回卷可见。
  tx%64Ki                = tx_bytes mod 65536 (旧工具"打洞"的指纹: !=0 时洞必然存在)
  board_Mbps             = dW53 * 8 * 156.25e6 / dW5 / 1e6
  partial_sends/skip_bytes/first_partial_at = 工具自证 (fix 版打前两个; diag 版打三个)
"""
import re
import sys

MOD32 = 1 << 32
TB_MAX_S = MOD32 / 156.25e6      # W5 自由计数回绕周期 = 27.487 s
sys.stdout.reconfigure(encoding="utf-8", errors="replace")   # 工程坑 16①: GBK 控制台假 FAIL


def unwrap32(d_raw, ref):
    """mod-2^32 差值 -> 与 ref (64 位口径) 同量纲; 返回 (值, k)。盲区 = 真偏差 ≈ j·2^32
    (原理极限); 错 k 必差 4.295 GB >> ±0.5% 容差 ⇒ 判别力不受影响。"""
    k = max(0, int(round((ref - d_raw) / float(MOD32))))
    return d_raw + k * MOD32, k


def w_of(txt, snap_suffix, word):
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


def gets(txt, pat, cast=str, default="?"):
    m = re.search(pat, txt, re.M)
    return cast(m.group(1)) if m else default


def parse(path):
    txt = open(path, encoding="utf-8", errors="replace").read()
    r = {"file": path.split("/")[-1].split("\\")[-1]}
    r["tag"] = gets(txt, r"SNAP_BEGIN (\S+)_pre", str)
    r["pace"] = gets(txt, r"^PACE_BPS=(\d+)", int)
    r["bin"] = gets(txt, r"^BIN=(\S+)", str)
    r["bin_md5"] = gets(txt, r"BIN_MD5=([0-9a-f]+)", str)
    r["script_md5"] = gets(txt, r"J6META_SCRIPT_MD5=([0-9a-f]+)", str)
    r["bit_sha"] = gets(txt, r"J6META_BIT_SHA=(\S+)", str)
    r["magic"] = gets(txt, r"J6META_BOARD_MAGIC=(\S+)", str)
    r["bid_begin"] = gets(txt, r"J6META_BOARD_BID=(\S+)", str)
    r["bid_end"] = gets(txt, r"J6META_BOARD_BID_END=(\S+)", str)
    r["carrier"] = gets(txt, r"^CARRIER=(\d+)", str)
    r["t_start"] = gets(txt, r"J6META_T_START_UTC=(\S+)", str)
    r["t_end"] = gets(txt, r"J6META_T_END_UTC=(\S+)", str)
    m = re.search(r"SRC_SUM tx_bytes=(\d+) rx_bytes=(\d+) dur_s=([\d.]+) tx_Mbps=([\d.]+)", txt)
    r["tx_bytes"] = int(m.group(1)) if m else None
    r["dur_s"] = float(m.group(3)) if m else None
    r["tx_Mbps"] = float(m.group(4)) if m else None
    r["partial_sends"] = gets(txt, r"partial_sends=(-?\d+)", int, None)
    r["skip_bytes"] = gets(txt, r"skip_bytes=(-?\d+)", int, None)
    r["first_partial_at"] = gets(txt, r"first_partial_at=(-?\d+)", int, None)
    for tag in ("pre", "t0", "t1", "post"):
        for w in (5, 53, 54):
            r["%s_W%d" % (tag, w)] = w_of(txt, "_" + tag, w)
    # ⛔ 2026-10-07 订正 (P7B StB 判据修正轮): 原句 (保留) = `r["ratio"] = r["dW53_prepost"] / r["tx_bytes"]`,
    #    其中 dW53_prepost 只有 mod 2^32 余数 ⇒ >2.86 Gbps (2^32 B / 12 s) 时 ratio 假 FAIL;
    #    板侧速率 (dW53*8/…) 同病 (低 70%)。现: `*_raw` 落表 + unwrap 到 tx_bytes 量纲后再算。
    if r["pre_W53"] is not None and r["post_W53"] is not None:
        r["dW53_prepost_raw"] = (r["post_W53"] - r["pre_W53"]) % MOD32
        r["dW5_prepost"] = (r["post_W5"] - r["pre_W5"]) % MOD32
        r["dW54_prepost"] = (r["post_W54"] - r["pre_W54"]) % MOD32
        if r["tx_bytes"]:
            r["dW53_prepost"], r["dW53_prepost_k"] = unwrap32(r["dW53_prepost_raw"], r["tx_bytes"])
        else:
            r["dW53_prepost"], r["dW53_prepost_k"] = r["dW53_prepost_raw"], None
        if r["dW5_prepost"]:
            r["board_Mbps_prepost"] = r["dW53_prepost"] * 8 * 156.25e6 / r["dW5_prepost"] / 1e6
    if r["t0_W53"] is not None and r["t1_W53"] is not None:
        r["dW53_t0t1_raw"] = (r["t1_W53"] - r["t0_W53"]) % MOD32
        r["dW5_t0t1"] = (r["t1_W5"] - r["t0_W5"]) % MOD32
        r["dW54_t0t1"] = (r["t1_W54"] - r["t0_W54"]) % MOD32
        if r["tx_bytes"]:
            r["dW53_t0t1"], r["dW53_t0t1_k"] = unwrap32(r["dW53_t0t1_raw"], r["tx_bytes"])
        else:
            r["dW53_t0t1"], r["dW53_t0t1_k"] = r["dW53_t0t1_raw"], None
        if r["dW5_t0t1"]:
            r["win_s"] = r["dW5_t0t1"] / 156.25e6
            r["tb_ok"] = r["win_s"] < TB_MAX_S
            r["board_Mbps_t0t1"] = (r["dW53_t0t1"] * 8 * 156.25e6 / r["dW5_t0t1"] / 1e6
                                    if r["tb_ok"] else None)
    if r.get("dW53_prepost") is not None and r["tx_bytes"]:
        r["ratio"] = r["dW53_prepost"] / r["tx_bytes"]
        r["tx_mod64k"] = r["tx_bytes"] % 65536
    return r


def main():
    for path in sys.argv[1:]:
        r = parse(path)
        print("== RUN %s" % r["file"])
        for k in ("tag", "pace", "bin", "bin_md5", "script_md5", "bit_sha", "magic",
                  "bid_begin", "bid_end", "carrier", "t_start", "t_end"):
            print("   %s=%s" % (k, r.get(k)))
        print("   tx_bytes=%s dur_s=%s tx_Mbps=%s tx%%64Ki=%s" % (
            r.get("tx_bytes"), r.get("dur_s"), r.get("tx_Mbps"), r.get("tx_mod64k")))
        print("   partial_sends=%s skip_bytes=%s first_partial_at=%s" % (
            r.get("partial_sends"), r.get("skip_bytes"), r.get("first_partial_at")))
        print("   pre  W5=%s W53=%s W54=%s" % (r.get("pre_W5"), r.get("pre_W53"), r.get("pre_W54")))
        print("   t0   W5=%s W53=%s W54=%s" % (r.get("t0_W5"), r.get("t0_W53"), r.get("t0_W54")))
        print("   t1   W5=%s W53=%s W54=%s" % (r.get("t1_W5"), r.get("t1_W53"), r.get("t1_W54")))
        print("   post W5=%s W53=%s W54=%s" % (r.get("post_W5"), r.get("post_W53"), r.get("post_W54")))
        print("   dW53(p->p)=%s [raw=%s k=%s] dW54(p->p)=%s ratio=%s board_Mbps(p->p)=%s" % (
            r.get("dW53_prepost"), r.get("dW53_prepost_raw"), r.get("dW53_prepost_k"),
            r.get("dW54_prepost"),
            ("%.6f" % r["ratio"]) if r.get("ratio") else None,
            ("%.3f" % r["board_Mbps_prepost"]) if r.get("board_Mbps_prepost") else None))
        print("   dW53(t0t1)=%s [raw=%s k=%s] dW54(t0t1)=%s win_s=%s board_Mbps(t0t1)=%s tb=%s" % (
            r.get("dW53_t0t1"), r.get("dW53_t0t1_raw"), r.get("dW53_t0t1_k"),
            r.get("dW54_t0t1"),
            ("%.4f" % r["win_s"]) if r.get("win_s") else None,
            ("%.3f" % r["board_Mbps_t0t1"]) if r.get("board_Mbps_t0t1") else None,
            "OK" if r.get("tb_ok") else "**不可判(W5 时基)**"))
        # CSV 行
        print("CSV %s,%s,%s,%s,%s,%s,%s,%s,%s,%s" % (
            r["tag"], r.get("pace"), r.get("bin"), r.get("tx_bytes"), r.get("tx_Mbps"),
            r.get("dW53_prepost"), r.get("dW54_prepost"),
            ("%.6f" % r["ratio"]) if r.get("ratio") else "",
            r.get("partial_sends"), r.get("skip_bytes")))


if __name__ == "__main__":
    main()
