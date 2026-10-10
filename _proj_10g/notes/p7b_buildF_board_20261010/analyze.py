#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""analyze.py -- P7B 构建 F 板级轮 (2026-10-10): 逐跑解析 (W67/W68/W69 首次板级读数)

口径 (逐条落盘, 便于核):
  * 板侧计数器全 32 位 ⇒ 一切 Δ 一律 mod 2^32, 且**同时记 raw 与 k** (#55)。
  * 时基 = W5 (gmii_free_FE, tx 域) 与 W43 (mtx_stat_tx_words, tx 域); 两者都在 tx 域自由计数。
  * fps = ΔW20 / (ΔW5/156.25e6);  ⛔ 不写"线占空 = 193/P" (恒等式, 已订正)。
  * ⭐ L[µs/**事件**] = ΔW66 / (156.25 × ΔW68)  ⚠️ 仅当 ΔW68 > 0 (否则空判据)。
    ⛔ 量纲 = µs/**每 ACK 推进事件**, **不是** µs/窗 (审查 2026-10-10 订正; W66 每拍 +1 = 拍,
       W68 = 单拍脉冲事件数 ⇒ 单位 = 拍/事件)。"1 事件 = 1 次窗刷新" **不是结构恒等**
       (replay_jump/svc_rewind 降 snd_nxt ⇒ 无 ACK 事件也能重开门)。
    ⚠️ W68 已知**多计** (drain 写口 sticky + ack_adv_l 用 w5 拍 ra_snd_una) ⇒ ΔW68 >= 真实推进次数
       ⇒ 直读 L **系统性偏小**。且 W68 与 W22 在本构型**几乎同源** ⇒ 不许互证。
  * 窗口换算 (显式写出): 每帧事件数 = ΔW68/ΔW20;  每窗帧数 = W_eff/1518;
     ⇒ L_每窗[µs] = L_事件[µs] × (ΔW68/ΔW20) × (W_eff/1518)   (W_eff 取 W69 低 16 位)
  * 板帽侧占比 = ΔW67/ΔW66 (自洽牙 ΔW67 <= ΔW66, 真牙);  对端侧 = 1 - ΔW67/ΔW66。
    ⚠️ W67 高 = **阈值归属板帽**, **不等于**"板是瓶颈"。
  * W69 读法: {infl=高16, eff=低16}; **仅当同窗 ΔW66>0 才有效**; 退化族 = infl ≫ eff。
用法: python analyze.py runs/BF1.txt [runs/BF2.txt ...]
"""
import json
import re
import sys
import os

MOD = 1 << 32
NORMSUSPECT = []          # [(word, idx, tag, raw_dd)] 单段跨 >2^31 的可疑点
WORDS = [5, 20, 43, 51, 63, 64, 65, 66, 67, 68, 69]


def parse_snaps(path):
    snaps = []
    cur = None
    for ln in open(path, encoding="utf-8", errors="replace"):
        m = re.match(r"^SNAP_BEGIN (\S+) gen=(\d+)", ln)
        if m:
            cur = {"tag": m.group(1), "gen": int(m.group(2)), "w": {}}
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


def unwrap_chain(snaps, w):
    """返回 [(snap_i, raw, mono_or_None)]; mono 用单调递增假设数回卷次数 k。"""
    out = []
    k = 0
    last = None
    for i, s in enumerate(snaps):
        if w not in s["w"]:
            out.append((i, None, None, 0))
            continue
        v = s["w"][w]
        if last is not None and v < last:
            k += 1
        last = v
        out.append((i, v, None, k))
    # mono 需要知道起点; 由调用方做 (相对第一点)
    base = None
    kk = 0
    lastv = None
    for i, v, _, _ in out:
        if v is None:
            continue
        if base is None:
            base = v
            lastv = v
            kk = 0
        elif v < lastv:
            kk += 1
        lastv = v if base is not None else lastv
        out[i] = (i, v, (v - base) % MOD + kk * MOD, kk)
    return out


def norm(snaps, w):
    """{snap_index: mono_value} —— 正确解卷 = **相邻 mod 2^32 差之和** (望远镜求和)。

    ⛔ 2026-10-10 修复: 旧版用 `(v-base)%MOD + k*MOD` —— 那个式子在**发生回卷的那一段**
    会把同一回卷**数两次** (+2^32), 实测 BF3 的 W5 有 1 个区间被算成 27.9 s
    (raw_d=65,366,369 而 mono_d=4,360,333,665)。现改为逐段 `(v-prev) % 2^32` 求和。
    单段 > 2^31 视为可疑 (可能一段内跨了多个回卷) ⇒ 记进 NORMSUSPECT。
    """
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


def esc(s):
    return s


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
    print("=" * 100)
    print("== %s  (snaps=%d)" % (tag, len(snaps)))

    # ---- 元数据 / 见证 ----
    for pat, lab in [(r"^LF_META_TAG=", "META"), (r"^SINK_LIMITS", "LIMITS"),
                     (r"^CARRIER=", "CARRIER"), (r"^LF_GEOM_OK|^LF_GEOM_FAIL", "GEOM"),
                     (r"^PIN_RULE=", "PIN_RULE"), (r"^LF_META_BOARD_BID_PRE", "BID_PRE"),
                     (r"^LF_META_BOARD_BID_END", "BID_END")]:
        ln = load_line(path, pat)
        if ln:
            print("   %s | %s" % (lab, ln))
    sink = load_line(path, r"^SINK_SUM") or ""
    conn = load_line(path, r"^SINK_CONN") or ""
    nic = load_line(path, r"^GEOM_NOPCAP") or ""
    print("   SINK_SUM | %s" % sink)
    print("   SINK_CONN| %s" % conn[:400])
    print("   NIC      | %s" % nic)
    coalf = path[:-4] + "_coalesce.txt"
    if os.path.exists(coalf):
        c = open(coalf, encoding="utf-8", errors="replace").read().splitlines()
        print("   COALESCE | %s | %s" % (c[1].strip() if len(c) > 1 else "", c[2].strip() if len(c) > 2 else ""))
    guards = re.findall(r"^(LF_SNAP_MAXREACHED|SNAP_FAIL|GEN_FAIL).*$", raw, re.M)
    print("   GUARDS   | %s" % (guards if guards else "无 (0 命中)"))

    # ---- 逐字 unwrap ----
    # ⚠️ W69 = **锁存字**, 不做解卷 (它的跳变是语义, 不是回卷)
    mono = {w: norm(snaps, w) for w in WORDS if w != 69}
    idx_ok = [i for i in range(len(snaps)) if all(i in mono[w] for w in (5, 20, 43, 51, 63, 64, 65, 66, 67, 68))]
    if len(idx_ok) < 2:
        print("   !! 可用点不足 (<2)")
        return None
    a, b = idx_ok[0], idx_ok[-1]
    print("   --- 全窗 (a=%s gen=%d -> b=%s gen=%d) ---" % (snaps[a]["tag"], snaps[a]["gen"], snaps[b]["tag"], snaps[b]["gen"]))
    res = {}
    for w in WORDS:
        raw_a, raw_b = snaps[a]["w"][w], snaps[b]["w"][w]
        if w == 69:
            print("   W%-3d raw %08x -> %08x  (**锁存字, 无 delta 语义**; 全窗两点仅列值)" % (w, raw_a, raw_b))
            continue
        d = mono[w][b] - mono[w][a]
        k = (d - (raw_b - raw_a)) // MOD
        res[w] = d
        print("   W%-3d raw %08x -> %08x  d=%d  k=%d" % (w, raw_a, raw_b, d, k))
    # 时基核: ΔW5 vs ΔW43 (都在 tx 域, 应逐字相等)
    print("   TIME | dW5=%d dW43=%d  equal=%s | dt=%.6f s" % (res[5], res[43], res[5] == res[43], res[5] / 156.25e6))

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
        row["w66_per_frm"] = d[66] / d[20] if d[20] else None
        row["w67_per_frm"] = d[67] / d[20] if d[20] else None
        row["w66m67_per_frm"] = (d[66] - d[67]) / d[20] if d[20] else None
        row["w65_per_frm"] = d[65] / d[20] if d[20] else None
        row["cap_share"] = (d[67] / d[66]) if d[66] > 0 else None
        row["ev"] = (d[68] / d[20]) if d[20] else None
        row["app_Mbps"] = d[51] * 8 / dt / 1e6 if d[51] else None
        # W69 读法 (仅当 dW66>0 有效): 取区间末点的值 (锁存是"最近一次")
        v69 = snaps[q]["w"][69]
        row["w69_eff"] = v69 & 0xFFFF
        row["w69_infl"] = (v69 >> 16) & 0xFFFF
        row["w69_valid"] = d[66] > 0
        iv.append(row)
    in_flow = [r for r in iv if r["d20"] > 0]
    plateau = []
    print("   区间: 总 %d, 含帧 %d" % (len(iv), len(in_flow)))
    if not in_flow:
        return None

    def stat(key, xs, fmt="%.4f"):
        xs = [x for x in xs if x is not None]
        if not xs:
            return "n/a"
        return ("n=%d min=%s med=%s max=%s" % (len(xs), fmt % min(xs), fmt % med(xs), fmt % max(xs)))

    # 稳态 (plateau) 过滤: fps >= 0.9 × 含帧区间 fps 中位 (排除起停/斜坡区间)
    fmed = med([r["fps"] for r in in_flow])
    plateau = [r for r in in_flow if r["fps"] >= 0.9 * fmed]
    print("   稳态区间 (fps >= 0.9×含帧中位): n=%d / %d" % (len(plateau), len(in_flow)))

    def pstat(rows, key, fmt="%.4f"):
        xs = [r[key] for r in rows if r[key] is not None]
        if not xs:
            return "n/a"
        return ("n=%d min=%s med=%s max=%s" % (len(xs), fmt % min(xs), fmt % med(xs), fmt % max(xs)))

    print("   ⭐[稳态] fps      %s" % pstat(plateau, "fps", "%.1f"))
    print("   ⭐[稳态] L_us     %s" % pstat(plateau, "L_us", "%.6f"))
    print("   ⭐[稳态] W66/frm  %s" % pstat(plateau, "w66_per_frm", "%.4f"))
    print("   ⭐[稳态] W65/frm  %s" % pstat(plateau, "w65_per_frm", "%.4f"))
    print("   ⭐[稳态] cap_share%s" % pstat(plateau, "cap_share", "%.6f"))
    print("   ⭐[稳态] 事件/帧  %s" % pstat(plateau, "ev", "%.6f"))
    print("   --- 逐区间统计 (含帧区间) ---")
    print("   fps        %s" % stat("fps", [r["fps"] for r in in_flow], "%.1f"))
    print("   app_Mbps   %s" % stat("app", [r["app_Mbps"] for r in in_flow], "%.1f"))
    print("   L_us       %s" % stat("L", [r["L_us"] for r in in_flow], "%.6f"))
    print("   dW68>0 的区间数 = %d / %d ;  dW68==0 的区间数 = %d" % (
        sum(1 for r in in_flow if r["d68"] > 0), len(in_flow), sum(1 for r in in_flow if r["d68"] == 0)))
    print("   W66/frm    %s" % stat("w66", [r["w66_per_frm"] for r in in_flow], "%.4f"))
    print("   W67/frm    %s" % stat("w67", [r["w67_per_frm"] for r in in_flow], "%.4f"))
    print("   W66-W67/frm%s" % (" " + stat("net", [r["w66m67_per_frm"] for r in in_flow], "%.4f")))
    print("   W65/frm    %s" % stat("w65", [r["w65_per_frm"] for r in in_flow], "%.4f"))
    print("   cap_share  %s  (区间数 dW66>0 = %d)" % (stat("cap", [r["cap_share"] for r in in_flow], "%.6f"),
                                                    sum(1 for r in in_flow if r["d66"] > 0)))
    ev_per_frm = [r["d68"] / r["d20"] for r in plateau]
    print("   每帧事件数 dW68/dW20 %s   (⇒ 1 事件 ≈ %.3f 帧)" % (stat("ev", ev_per_frm, "%.6f"),
                                                               1.0 / med(ev_per_frm) if med(ev_per_frm) else 0))
    # 窗口换算 (用 W69 低 16 位的众数做 W_eff; ⭐ 一律用**稳态**区间做代表值)
    effc = {}
    for r in plateau:
        if r["w69_valid"] and r["w69_eff"]:
            effc[r["w69_eff"]] = effc.get(r["w69_eff"], 0) + 1
    weff = max(effc, key=effc.get) if effc else None
    Lmed = med([r["L_us"] for r in plateau if r["L_us"] is not None])
    evmed = med([r["ev"] for r in plateau if r["ev"] is not None])
    if weff and Lmed and evmed:
        Lw = Lmed * evmed * (weff / 1518.0)
        print("   ⭐ 窗口换算 (显式): W_eff=%d (W69 众数) ⇒ 每窗帧数=%.3f; L_事件×每帧事件数×每窗帧数 = L_每窗 = %.4f µs"
              % (weff, weff / 1518.0, Lw))
    fps_med = med([r["fps"] for r in plateau])
    if fps_med and weff:
        P = 156.25e6 / fps_med
        Lh = (weff / 1518.0) * (P - 193.0) / 156.25
        print("   历史换算对照: P=156.25e6/fps_med=%.3f 拍/帧 ⇒ P−193=%.3f; L_hist=(W_eff/1518)×(P−193)/156.25 = %.4f µs/窗"
              % (P, P - 193.0, Lh))
        print("      ⚠️ 两者量纲不同 (µs/事件 vs µs/窗) —— 上面的显式换算才是可比量; 直接并列比较**不成立**。")
    # W69 直方
    w69 = {}
    for r in in_flow:
        if r["w69_valid"]:
            w69[(r["w69_infl"], r["w69_eff"])] = w69.get((r["w69_infl"], r["w69_eff"]), 0) + 1
    print("   W69 (infl,eff) 直方 (仅 dW66>0 区间末点): %s" % (sorted(w69.items(), key=lambda x: -x[1])[:8] if w69 else "无 (所有区间 dW66==0)"))
    # 三台仪器一致性
    print("   --- 对账 ---")
    nicpk = re.search(r"d_pkts=(\d+)", nic)
    print("   dW20(全窗)=%d vs NIC d_pkts=%s  diff=%s" % (
        res[20], nicpk.group(1) if nicpk else "NA",
        (res[20] - int(nicpk.group(1))) if nicpk else "NA"))
    # 守卫字
    for w, nm in [(21, "tx_abort"), (22, "rx_pass_TCP(*)"), (23, "rx_nonmatch_TCP"), (35, "rx_fifo_ovf"), (41, "flush_words"),
                  (42, "flush_done"), (45, "txcdc_ovf"), (59, "stx_fifo_ovf"), (60, "srx_fifo_ovf")]:
        if w in snaps[a]["w"] and w in snaps[b]["w"]:
            mw = norm(snaps, w)
            if a in mw and b in mw:
                va, vb = snaps[a]["w"][w], snaps[b]["w"][w]
                print("   守卫 W%-2d %-16s %08x -> %08x  d=%d" % (w, nm, va, vb, mw[b] - mw[a]))
    print("   (*) W22 与 W68 在本构型**几乎同源** (同模块同批帧事件) ⇒ 只列值, **不做互证**。")
    # 三角核 (⚠️ 审查订正 2026-10-10: 只有左腿是真牙)
    #   左腿 dW67 <= dW66 = **真牙** (结构性: stat_winstall_cap_ev = stat_winstall_ev && win_cap_bind)
    #   右腿 dW66 <= dW64 = **假牙** (rtl/tcp_tx_frame.v:605 严格成立的是 dW64 >= dW66 - dH,
    #     而 dH **没有计数器** ⇒ dW66 > dW64 是**合法情形**) ⇒ 只登记、不判异常。
    vL = [r for r in in_flow if r["d67"] > r["d66"]]
    vR = [r for r in in_flow if r["d66"] > r["d64"]]
    print("   三角核左腿 dW67<=dW66 (真牙): 违例 = %d/%d" % (len(vL), len(in_flow)))
    if vL[:3]:
        for r in vL[:3]:
            print("      !! %s->%s d66=%d d67=%d" % (r["p"], r["q"], r["d66"], r["d67"]))
    print("   三角核右腿 dW66<=dW64 (**假牙**, dW64 >= dW66-dH 才是严格式): 越界 = %d/%d (合法情形, 不判异常)"
          % (len(vR), len(in_flow)))
    # W55 重传
    for w, nm in [(55, "tx_stat_retx"), (15, "tx_stat_bytes_TCP"), (14, "tx_stat_frames_TCP"), (52, "app_tx_frames")]:
        if w in snaps[a]["w"] and w in snaps[b]["w"]:
            mw = norm(snaps, w)
            npts = sum(1 for s in snaps if w in s["w"])
            if a in mw and b in mw:
                note = "" if npts >= 3 else "  ⚠️ 仅 %d 个采样点 ⇒ 回卷数 k **不可解** (d 是下界, mod 2^32 未还原)" % npts
                print("   W%-2d %-18s %08x -> %08x d=%d%s" % (w, nm, snaps[a]["w"][w], snaps[b]["w"][w], mw[b] - mw[a], note))
    # 冗余率 (只在 W15 有 >=3 个采样点时给; 否则会因回卷不可解而**系统性错**)
    m15, m51 = norm(snaps, 15), norm(snaps, 51)
    n15 = sum(1 for s in snaps if 15 in s["w"])
    if a in m15 and a in m51 and (m51[b] - m51[a]):
        if n15 >= 3:
            print("   冗余率 dW15/dW51 = %.6f  (W15 采样点 n=%d, dW15=%d, dW51=%d)" % ((m15[b] - m15[a]) / (m51[b] - m51[a]), n15, m15[b] - m15[a], m51[b] - m51[a]))
        else:
            print("   冗余率 dW15/dW51 = **不可判** (W15 只有 %d 个采样点 ⇒ 回卷 k 不可解; 需要把 15 放进 KW)" % n15)
    m52 = norm(snaps, 52)
    if a in m52 and b in m52 and (m52[b] - m52[a]):
        print("   dW51/dW52 (几何字节/帧; 期望 1460) = %.6f" % ((mono[51][b] - mono[51][a]) / (m52[b] - m52[a])))
    if NORMSUSPECT:
        print("   WARN UNWRAP_SUSPECT n=%d: %s" % (len(NORMSUSPECT), NORMSUSPECT[:6]))
    out = {"tag": tag, "snaps": len(snaps), "whole": {("W%d" % w): res[w] for w in WORDS if w in res},
           "fps_med": med([r["fps"] for r in in_flow]), "n_iv": len(in_flow),
           "L_med": med([r["L_us"] for r in in_flow if r["L_us"] is not None])}
    return out


if __name__ == "__main__":
    outs = []
    for p in sys.argv[1:]:
        o = report(p)
        if o:
            outs.append(o)
    print("=" * 100)
    print("JSON_SUM:", json.dumps(outs, ensure_ascii=False))
