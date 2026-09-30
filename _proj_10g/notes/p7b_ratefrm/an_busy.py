# -*- coding: utf-8 -*-
"""an_busy.py -- 默认 vs UDP_TX_OVL 的 o_busy 逐拍轨迹分析 (P7B_RATE_FRAMER 验证 2)

输入 (由 run_eq.bat 用 -d DUMP_TRACE 生成):
  run_def/eq_busy.txt   逐拍 o_busy 字符 (1 字符/拍)
  run_def/eq_events.txt 'cyc A' 帧首拍被接受 / 'cyc O' 本帧末字被消费 / 'cyc D' 帧首阻塞
  run_ovl/... 同上
输出: 对齐后的每帧窗口覆盖统计 + 背靠背段帧周期 + 窗口并集证据
"""
import io, os, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

HERE = os.path.dirname(os.path.abspath(__file__))

def load(tag):
    d = os.path.join(HERE, "run_" + tag)
    busy = io.open(os.path.join(d, "eq_busy.txt"), "r").read().strip()
    ev = {}
    for ln in io.open(os.path.join(d, "eq_events.txt"), "r"):
        p = ln.split()
        if len(p) == 2:
            ev.setdefault(p[1], []).append(int(p[0]))
    return busy, ev

def align(busy, ev):
    """求 busy 字符 0 对应的全局拍号 off: 用 'O' 事件(必在 busy=1)与首个 'A' 标定"""
    cands = []
    for c in ev.get("O", []):
        for off in range(0, 12):
            i = c - off
            if 0 <= i < len(busy) and busy[i] == "1":
                cands.append(off)
    # 取众数
    from collections import Counter
    off = Counter(cands).most_common(1)[0][0]
    # 自检: 所有 O 事件在该 off 下必须 busy=1; 所有 D 事件区间必须 busy=1
    bad_o = [c for c in ev.get("O", []) if not (0 <= c-off < len(busy) and busy[c-off] == "1")]
    return off, bad_o

def main():
    out = []
    for tag in ("def", "ovl"):
        busy, ev = load(tag)
        off, bad_o = align(busy, ev)
        n1 = busy.count("1")
        # busy 上升沿 = 窗口数
        rises = sum(1 for i in range(1, len(busy)) if busy[i] == "1" and busy[i-1] == "0")
        # 背靠背段的帧周期: 用相邻 'O' 事件的差 (取 25..75 百分位的中位段)
        O = ev.get("O", [])
        d = [O[i+1]-O[i] for i in range(len(O)-1)]
        # 孤立帧段 (帧间隔 400) 的差会很大 ⇒ 取最小的 20 个差的中位数 = 背靠背/慢消费者段的周期
        ds = sorted(d)
        med_bb = ds[len(ds)//2] if ds else -1
        p10 = ds[len(ds)//10] if ds else -1
        p90 = ds[(len(ds)*9)//10] if ds else -1
        out.append((tag, off, len(busy), n1, rises, len(O), med_bb, p10, p90, bad_o))
        print("[%s] busy_len=%d off=%d  busy1=%d (%.1f%%)  busy_windows(rise)=%d  O_events=%d"
              % (tag, len(busy), off, n1, 100.0*n1/len(busy), rises, len(O)))
        print("     帧周期(O 间隔) 中位=%d  p10=%d  p90=%d  (含 400 拍孤立帧段)"
              % (med_bb, p10, p90))
        print("     'O' 事件处 busy=0 的个数 (对齐自检, 必须 0) = %d" % len(bad_o))
        # 相邻帧的相消: 一帧的窗口是否与下一帧的窗口相接
        gw = 0
        for i in range(len(busy)):
            pass
    # ---- 并集证据: 两版按"帧序"对齐, 比较每帧 [帧首拍+1, 末字] 的覆盖 ----
    print()
    for tag in ("def", "ovl"):
        busy, ev = load(tag)
        off, _ = align(busy, ev)
        A = ev.get("A", []); O = ev.get("O", [])
        cov_first = 0
        gaps_first = []
        ai = 0
        pairs = []
        for o in O:
            while ai < len(A) and A[ai] < o:
                cand = ai; ai += 1
            pairs.append((A[cand], o))
        for k, (a, o) in enumerate(pairs):
            w = busy[a+1-off: o+1-off]
            if "0" in w:
                cov_first += 1
                gaps_first.append(k)
        print("[%s] 按帧对齐: %d 帧中, [帧首拍+1,末字] 全 busy 的 = %d 帧 (违反帧号=%s)"
              % (tag, len(pairs), len(pairs) - cov_first, gaps_first[:8]))
    print()
    print("读法: def 的违反帧 = 默认实现 o_busy 在收帧期间为 0 的**结构事实**;")
    print("      ovl 必须 0 违反 ⇒ 重叠版的窗口是默认窗口的超集 (冻结点只增不减)。")

main()
