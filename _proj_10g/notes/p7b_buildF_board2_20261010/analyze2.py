#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""analyze2.py -- P7B 构建 F 板级二轮 (2026-10-10): 逐跑解析 + L 的**独立分母**

口径 (逐条落盘, 便于核; 与上一轮 analyze.py 同源, 差异只在下两条加号项):
  * 板侧计数器全 32 位 ⇒ 一切 Δ 一律 mod 2^32, 且**同时记 raw 与 k** (#55);
    解卷 = 相邻 mod 2^32 差之和 (望远镜求和; 修好的那一版)。
  * 时基 = W5 (FE 域自由计数, 156.25 MHz) 与 W43 (tx 域自由计数); 两者应逐字相等。
  * fps = ΔW20 / (ΔW5/156.25e6);  ⛔ 不写"线占空 = 193/P" (恒等式, 已订正)。
  * ⭐ L[µs/**事件**] = ΔW66 / (156.25 × ΔW68)   (W68 = 推进 snd_una 的 ACK 事件数)
  + ⭐ (本轮) L'[µs/**对端段**] = ΔW66 / (156.25 × ΔTcpOutSegs)
        ΔTcpOutSegs 有两个窗口 (同一次跑、点采样紧贴快照触发点):
          lo = post_a − pre_b   (⊂ 板侧窗口; 采样点全在板窗口内)
          hi = post_b − pre_a   (⊃ 板侧窗口; 采样点包住板窗口)
        两量的语义不同 (W68 = 推进事件; TcpOutSegs = 对端发出的段) ⇒ 比值不必 = 1。
  + 独立分母口径链: N_adv(真实推进事件数) ≤ min(ΔW68, ΔTcpOutSegs) ⇒ L_true ≥ max(L, L'_lo)。
  * 窗口换算 (显式写出): L_每窗[µs] = L_事件[µs] × (ΔW68/ΔW20) × (W_eff/1518)  (W_eff = W69 低 16 位)
  * 板帽侧占比 = ΔW67/ΔW66 (自洽牙 ΔW67 <= ΔW66); ⚠️ W67 高 = **阈值归属板帽**, ≠"板是瓶颈"。
  * W69 读法: {infl=高16, eff=低16}; **仅当同窗 ΔW66>0 才有效**。
用法: python analyze2.py runs/R1A.txt [runs/R1B.txt ...]
"""
import json
import re
import sys
import os

MOD = 1 << 32
NORMSUSPECT = []
WORDS = [5, 20, 43, 51, 66, 67, 68, 69]
# 全窗口径的**补充字** (只在 pre/post 的 full 快照里; 2 个采样点 ⇒ 只对"确定不回卷"的字有效)
#   W22 rx_stat_pass_TCP = 板收到并通过 TCP 分类器的帧数 ≈ 对端发出的段数 (独立于 W68)
#   W14 tx_stat_frames_TCP / W15 tx_stat_bytes_TCP = 快路径发出的 TCP 帧/字节 (W15 单跑回卷 17 次 ⇒ 只记 raw)
#   W55 tx_stat_retx = 重传/RTO 回卷次数
EXTRA = [22, 14, 55]
EXTRA_RAWONLY = [15]


def parse_ssh(path):
    """SNMP_SSH 行 -> {phase: (n_sock, sum_segs_out)}"""
    out = {}
    for ln in open(path, encoding="utf-8", errors="replace"):
        m = re.match(r"^SNMP_SSH (\S+) t=([\d.]+) n_sock=(\d+) ssh_segs_out_sum=(\d+)$", ln.strip())
        if m:
            out[m.group(1)] = (int(m.group(3)), int(m.group(4)))
    return out


def parse_snaps(path):
    snaps = []
    cur = None
    for ln in open(path, encoding="utf-8", errors="replace"):
        m = re.match(r"^SNAP_BEGIN (\S+) gen=(\d+)", ln)
        if m:
            cur = {"tag": m.group(1), "gen": int(m.group(2)), "w": {}, "t": None}
            continue
        if re.match(r"^SNAP_END ", ln):
            if cur is not None:
                snaps.append(cur)
            cur = None
            continue
        m = re.match(r"^W(\d+)\s+(0x[0-9A-Fa-f]+)\s+(\S+)\s+(0x[0-9a-fA-F]+|\?)$", ln)
        if m and cur is not None:
            v = m.group(4)
            if v.startswith("0x"):
                cur["w"][int(m.group(1))] = int(v, 16)
    return snaps


def parse_snmp(path):
    """-> {"idle0":{...}, "pre_a":{...}, ...}  (t 与各计数)"""
    out = {}
    for ln in open(path, encoding="utf-8", errors="replace"):
        m = re.match(r"^SNMP (\S+) t=([\d.]+) TcpInSegs=(\d+) TcpOutSegs=(\d+) TcpRetransSegs=(\d+) "
                     r"CurrEstab=(\d+) DelayedACKs=(\d+) DelayedACKLost=(\d+) DelayedACKLocked=(\d+)$", ln.strip())
        if m:
            out[m.group(1)] = {"t": float(m.group(2)), "in": int(m.group(3)), "out": int(m.group(4)),
                               "retr": int(m.group(5)), "estab": int(m.group(6)),
                               "dack": int(m.group(7)), "dacklost": int(m.group(8)), "dacklock": int(m.group(9))}
    return out


def norm(snaps, w):
    total = 0
    prev = None
    out = {}
    for i, s in enumerate(snaps):
        if w not in s["w"]:
            continue
        v = s["w"][w]
        if prev is not None:
            dd = (v - prev) % MOD
            if dd > (MOD >> 1):
                NORMSUSPECT.append((w, i, s["tag"], dd))
            total += dd
        prev = v
        out[i] = total
    return out


def med(xs):
    if not xs:
        return None
    a = sorted(xs)
    n = len(a)
    return a[n // 2] if n % 2 else 0.5 * (a[n // 2 - 1] + a[n // 2])


def load_line(path, pat):
    for ln in open(path, encoding="utf-8", errors="replace"):
        if re.match(pat, ln):
            return ln.strip()
    return None


def report(path):
    del NORMSUSPECT[:]
    tag = os.path.basename(path)[:-4]
    raw = open(path, encoding="utf-8", errors="replace").read()
    snaps = parse_snaps(path)
    snmp = parse_snmp(path)
    print("=" * 100)
    print("== %s  (snaps=%d, snmp_points=%d)" % (tag, len(snaps), len(snmp)))

    for pat, lab in [(r"^LF_META_TAG=", "META"), (r"^SINK_LIMITS", "LIMITS"),
                     (r"^CARRIER=", "CARRIER"), (r"^LF_GEOM_OK|^LF_GEOM_FAIL", "GEOM"),
                     (r"^LF_META_BOARD_BID_PRE", "BID_PRE"), (r"^LF_META_BOARD_BID_END", "BID_END")]:
        ln = load_line(path, pat)
        if ln:
            print("   %s | %s" % (lab, ln))
    sink = load_line(path, r"^SINK_SUM") or ""
    print("   SINK | %s" % sink[:300])
    guards = re.findall(r"^(LF_SNAP_MAXREACHED|SNAP_FAIL|GEN_FAIL|LF_ABORT).*$", raw, re.M)
    print("   GUARDS | %s" % (guards if guards else "无 (0 命中)"))

    mono = {w: norm(snaps, w) for w in WORDS if w != 69}
    idx_ok = [i for i in range(len(snaps)) if all(i in mono[w] for w in (5, 20, 43, 51, 66, 67, 68))]
    if len(idx_ok) < 2:
        print("   !! 可用点不足 (<2)")
        return None
    a, b = idx_ok[0], idx_ok[-1]
    print("   --- 全窗 (a=%s gen=%d -> b=%s gen=%d) ---" % (snaps[a]["tag"], snaps[a]["gen"], snaps[b]["tag"], snaps[b]["gen"]))
    res = {}
    for w in WORDS:
        ra, rb = snaps[a]["w"][w], snaps[b]["w"][w]
        if w == 69:
            print("   W%-3d raw %08x -> %08x  (**锁存字, 无 delta 语义**)" % (w, ra, rb))
            continue
        d = mono[w][b] - mono[w][a]
        k = round((d - (rb - ra)) / MOD)
        res[w] = d
        print("   W%-3d raw %08x -> %08x  d=%d  k=%d" % (w, ra, rb, d, k))
    print("   TIME | dW5=%d dW43=%d equal=%s | dt=%.6f s" % (res[5], res[43], res[5] == res[43], res[5] / 156.25e6))

    # ---- ⭐ 独立分母 (对端内核) ----
    print("   --- 独立分母 (对端 /proc/net/snmp; 全系统口径) ---")
    pd = None
    ssh = parse_ssh(path)
    if all(kk in snmp for kk in ("pre_a", "pre_b", "post_a", "post_b")):
        pa, pb, qa, qb = snmp["pre_a"], snmp["pre_b"], snmp["post_a"], snmp["post_b"]
        d_out_lo = qa["out"] - pb["out"]
        d_out_hi = qb["out"] - pa["out"]
        d_in_lo = qa["in"] - pb["in"]
        d_in_hi = qb["in"] - pa["in"]
        d_retr = qb["retr"] - pa["retr"]
        d_dack = qb["dack"] - pa["dack"]
        d_dl = qb["dacklost"] - pa["dacklost"]
        print("   SNMP raw: pre_a out=%d pre_b out=%d post_a out=%d post_b out=%d" % (pa["out"], pb["out"], qa["out"], qb["out"]))
        print("   dTcpOutSegs: lo(post_a-pre_b)=%d  hi(post_b-pre_a)=%d  (bracket 宽=%d = %.4f%%)"
              % (d_out_lo, d_out_hi, d_out_hi - d_out_lo, 100.0 * (d_out_hi - d_out_lo) / max(d_out_lo, 1)))
        print("   dTcpInSegs : lo=%d  hi=%d | dTcpRetransSegs=%d | dDelayedACKs=%d | dDelayedACKLost=%d"
              % (d_in_lo, d_in_hi, d_retr, d_dack, d_dl))
        print("   t: pre_a=%.3f pre_b=%.3f post_a=%.3f post_b=%.3f | 快照窗(pre_b->post_a)=%.3f s"
              % (pa["t"], pb["t"], qa["t"], qb["t"], qa["t"] - pb["t"]))
        if "idle0" in snmp and "idle1" in snmp:
            i0, i1 = snmp["idle0"], snmp["idle1"]
            dt = i1["t"] - i0["t"]
            print("   背景率见证 idle: dTcpOutSegs=%d / %.3f s = %.2f 段/s (无连接空闲窗)"
                  % (i1["out"] - i0["out"], dt, (i1["out"] - i0["out"]) / dt))
        # ⭐ sshd 侧直接测量 (非测量 TCP 流量)
        d_ssh = None
        if all(kk in ssh for kk in ("pre_b", "post_a")):
            d_ssh = ssh["post_a"][1] - ssh["pre_b"][1]
            print("   sshd 见证: pre_b sum=%d -> post_a sum=%d  d_ssh=%d (n_sock=%d, 占全系统 %.4f%%)"
                  % (ssh["pre_b"][1], ssh["post_a"][1], d_ssh, ssh["post_a"][0], 100.0 * d_ssh / max(d_out_lo, 1)))
        if res.get(68):
            print("   ⭐ dW68 / dTcpOutSegs = lo: %.6f   hi: %.6f" % (res[68] / d_out_lo, res[68] / d_out_hi))
            Lp_lo = res[66] / (156.25 * d_out_lo)
            Lp_hi = res[66] / (156.25 * d_out_hi)
            L = res[66] / (156.25 * res[68])
            print("   ⭐ L  (分母=W68)        = %.6f µs/事件" % L)
            print("   ⭐ L' (分母=TcpOutSegs) = lo: %.6f  hi: %.6f µs/对端段" % (Lp_lo, Lp_hi))
            print("   ⭐ L'/L = lo: %.6f  hi: %.6f  (={dTcpOutSegs 与 dW68 的相对大小})" % (Lp_lo / L, Lp_hi / L))
            pd = {"d_out_lo": d_out_lo, "d_out_hi": d_out_hi, "L": L, "Lp_lo": Lp_lo, "Lp_hi": Lp_hi, "d_ssh": d_ssh}
            # ⭐ 独立分母的分解: 全系统 = 本连接 + ssh;  本连接 − W68 = 非推进段 (U) 的估计
            if d_ssh is not None:
                d_conn = d_out_lo - d_ssh
                U_sys = d_conn - res[68]
                print("   分解: dTcpOutSegs_lo(%d) − d_ssh(%d) = 本连接近似 %d;  本连接 − dW68 = %d (%.4f%% of dW68)"
                      % (d_out_lo, d_ssh, d_conn, U_sys, 100.0 * U_sys / res[68]))
    else:
        print("   !! 缺 SNMP 点 (至少需要 pre_a/pre_b/post_a/post_b)")
    # ---- 补充字 (全窗; pre/post full 快照) ----
    print("   --- 补充字 (全窗 pre->post; 只对确定不回卷的字算 delta) ---")
    for w in EXTRA + EXTRA_RAWONLY:
        if w in snaps[a]["w"] and w in snaps[b]["w"]:
            mw = norm(snaps, w)
            npts = sum(1 for s in snaps if w in s["w"])
            if a in mw and b in mw:
                ra_, rb_ = snaps[a]["w"][w], snaps[b]["w"][w]
                dd = mw[b] - mw[a]
                note = "" if w in EXTRA else "  ⚠️ 单跑回卷 >1 次 ⇒ 只记 raw, delta 不可解"
                print("   W%-2d raw %08x -> %08x  d=%d (npts=%d)%s" % (w, ra_, rb_, dd, npts, note))
                res[w] = dd
    if 22 in res and res.get(68):
        U_board = res[22] - res[68]
        print("   ⭐ U_board = dW22 − dW68 = %d (%.4f%% of dW68)  [板侧: 收到但未推进的 TCP 帧]"
              % (U_board, 100.0 * U_board / res[68]))

    # ---- 逐区间 ----
    iv = []
    for i in range(len(idx_ok) - 1):
        p, q = idx_ok[i], idx_ok[i + 1]
        d = {w: (mono[w][q] - mono[w][p]) for w in WORDS if w != 69}
        dt = d[5] / 156.25e6
        if dt <= 0:
            continue
        row = {"i": i, "p": snaps[p]["tag"], "q": snaps[q]["tag"], "dt": dt, **{"d%d" % w: d[w] for w in WORDS if w != 69}}
        row["fps"] = d[20] / dt
        row["L_us"] = (d[66] / (156.25 * d[68])) if d[68] > 0 else None
        row["ev"] = (d[68] / d[20]) if d[20] else None
        row["cap_share"] = (d[67] / d[66]) if d[66] > 0 else None
        row["app_Mbps"] = d[51] * 8 / dt / 1e6 if d[51] else None
        v69 = snaps[q]["w"][69]
        row["w69_eff"] = v69 & 0xFFFF
        row["w69_infl"] = (v69 >> 16) & 0xFFFF
        row["w69_valid"] = d[66] > 0
        iv.append(row)
    in_flow = [r for r in iv if r["d20"] > 0]
    print("   区间: 总 %d, 含帧 %d" % (len(iv), len(in_flow)))
    if not in_flow:
        return None

    def pstat(rows, key, fmt="%.4f"):
        xs = [r[key] for r in rows if r[key] is not None]
        if not xs:
            return "n/a"
        return ("n=%d min=%s med=%s max=%s" % (len(xs), fmt % min(xs), fmt % med(xs), fmt % max(xs)))

    fmed = med([r["fps"] for r in in_flow])
    plateau = [r for r in in_flow if r["fps"] >= 0.9 * fmed]
    print("   稳态区间 (fps >= 0.9×含帧中位): n=%d / %d" % (len(plateau), len(in_flow)))
    print("   ⭐[稳态] fps      %s" % pstat(plateau, "fps", "%.1f"))
    print("   ⭐[稳态] L_us     %s" % pstat(plateau, "L_us", "%.6f"))
    print("   ⭐[稳态] cap_share%s" % pstat(plateau, "cap_share", "%.6f"))
    print("   ⭐[稳态] 事件/帧  %s" % pstat(plateau, "ev", "%.6f"))
    print("   --- 逐区间 (含帧) ---")
    print("   fps        %s" % pstat(in_flow, "fps", "%.1f"))
    print("   app_Mbps   %s" % pstat(in_flow, "app_Mbps", "%.1f"))
    print("   L_us       %s" % pstat(in_flow, "L_us", "%.6f"))
    print("   dW68>0 区间数 = %d / %d" % (sum(1 for r in in_flow if r["d68"] > 0), len(in_flow)))
    # W69 直方 + W_eff
    effc = {}
    for r in plateau:
        if r["w69_valid"] and r["w69_eff"]:
            effc[r["w69_eff"]] = effc.get(r["w69_eff"], 0) + 1
    weff = max(effc, key=effc.get) if effc else None
    w69 = {}
    for r in in_flow:
        if r["w69_valid"]:
            w69[(r["w69_infl"], r["w69_eff"])] = w69.get((r["w69_infl"], r["w69_eff"]), 0) + 1
    print("   W69 (infl,eff) 直方 (仅 dW66>0): %s" % (sorted(w69.items(), key=lambda x: -x[1])[:8] if w69 else "无"))
    # 全窗 W 域
    print("   --- 全窗比率 ---")
    if res[66]:
        print("   dW67/dW66 = %.6f   (1-该值 = 对端侧占比)" % (res[67] / res[66]))
    if res[20]:
        print("   dW68/dW20 = %.6f 事件/帧   dW66/dW20 = %.4f 拍/帧" % (res[68] / res[20], res[66] / res[20]))
    vL = [r for r in in_flow if r["d67"] > r["d66"]]
    print("   三角核左腿 dW67<=dW66 (真牙): 违例 = %d/%d" % (len(vL), len(in_flow)))
    if NORMSUSPECT:
        print("   WARN UNWRAP_SUSPECT n=%d: %s" % (len(NORMSUSPECT), NORMSUSPECT[:6]))
    out = {"tag": tag, "snaps": len(snaps), "n_iv": len(in_flow), "n_plateau": len(plateau),
           "dW20": res[20], "dW43": res[43], "dW51": res[51], "dW66": res[66], "dW67": res[67], "dW68": res[68],
           "dW22": res.get(22), "dW14": res.get(14), "dW55": res.get(55),
           "U_board": (res[22] - res[68]) if 22 in res else None,
           "cap_share": (res[67] / res[66]) if res[66] else None,
           "ev_per_frm": (res[68] / res[20]) if res[20] else None,
           "W_eff": weff, "fps_med_iv": med([r["fps"] for r in in_flow]),
           "fps_med_plat": med([r["fps"] for r in plateau]),
           "L_med_iv": med([r["L_us"] for r in in_flow if r["L_us"] is not None]),
           "L_med_plat": med([r["L_us"] for r in plateau if r["L_us"] is not None]),
           "cap_share_ovl": (res[67] / res[66]) if res[66] else None, "snmp": pd}
    return out


if __name__ == "__main__":
    outs = []
    for p in sys.argv[1:]:
        o = report(p)
        if o:
            outs.append(o)
    print("=" * 100)
    print("JSON_SUM:", json.dumps(outs, ensure_ascii=False))
