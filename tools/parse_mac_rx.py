#!/usr/bin/env python
"""比对 resp.memh 与 expected.memh。

严格模式: 词流逐词全等 + 统计行全等。
lenient 模式 (硬停): 每帧必须完整 (sop+last 配对), 内容必须属于期望帧集;
stats 满足 frames + drop == 总帧数, crc_err <= 期望坏帧数。
"""
import sys


def load(path):
    words, stats = [], None
    with open(path) as fh:
        for ln in fh:
            ln = ln.strip().upper()
            if not ln:
                continue
            if ln.startswith("STATS"):
                stats = tuple(int(x) for x in ln.split()[1:5])
            else:
                words.append(ln)
    return words, stats


def group(words):
    """按 sop/last 分组 -> (完整帧列表, 半帧列表)。半帧 = 无 TLAST 的丢弃残留。"""
    frames, partials, cur = [], [], None
    for ln in words:
        p = ln.split()
        sop, last = int(p[2]), int(p[3])
        if cur is None and sop:
            cur = [ln]
        elif cur is not None:
            cur.append(ln)
        if cur is not None and last:
            frames.append(tuple(cur))
            cur = None
    if cur is not None:
        partials.append(tuple(cur))
    return frames, partials


def check(resp_path, exp_path, stats_path, lenient=False, tag=""):
    words, stats = load(resp_path)
    exp_words, _ = load(exp_path)
    with open(stats_path) as fh:
        ef, ec, ed, eb = (int(x) for x in fh.read().split())
    ok = True
    if not lenient:
        if words != exp_words:
            ok = False
            print("[%s] 词流不一致: resp %d 词 vs exp %d 词" % (tag, len(words), len(exp_words)))
            for a, b in zip(words, exp_words):
                if a != b:
                    print("  resp: %s" % a)
                    print("  exp : %s" % b)
                    break
        if stats != (ef, ec, ed, eb):
            ok = False
            print("[%s] stats 不一致: resp %s vs exp %s" % (tag, stats, (ef, ec, ed, eb)))
    else:
        frames, partials = group(words)
        exp_frames, _ = group(exp_words)
        exp_set = set(exp_frames)
        # P6b F4: mac_rx_64 的整帧中止现在会补一个 **TERM 字** (tkeep=8'h00 的 TLAST,
        # tcrs=0/terr=1) ⇒ 被中止的帧在流里是"sop..last 完整"的, 但它的**末字 keep=0**。
        # 按 MAC 的新合同 (§4): 那是 MAC 层中止标记, 应由下游整帧丢弃 —— 与"半帧"同类
        # (都是丢帧产物), 故计入 partials 而不是外来帧。**计数约束不放松** (仍要求
        # partials+aborted <= drop, 且**好帧**必须逐词属于期望帧集); aborted 帧的
        # 词内容不做逐词比对 —— 这一条与旧版对"半帧"的处理口径相同 (旧版也不比半帧内容)。
        good, aborted = [], []
        for f in frames:
            k = int(f[-1].split()[1], 16)      # 末字 tkeep
            (aborted if k == 0 else good).append(f)
        alien = [f for f in good if f not in exp_set]
        if alien:
            ok = False
            print("[%s] 结构异常: 外来帧 %d" % (tag, len(alien)))
        # 半帧 = 帧原子丢弃的正常产物 (前部已出 FIFO 的词无 TLAST); TERM 帧 = 中止标记。
        # 两者数量之和 <= drop。 ⚠️ 本分支与 expected.memh 的生成 (gen_stim_mac.expected_words)
        # 无关: 严格档 (NOSTALL/STALL, 无丢帧 ⇒ 无 TERM) 不走这里; 若将来严格档也产生 TERM,
        # 必须**同批**扩 expected_words 与本检查器, 否则会出现新的不一致。
        if stats is None or stats[0] + stats[2] != ef or stats[1] > ec or \
           len(partials) + len(aborted) > stats[2]:
            ok = False
            print("[%s] stats 算术不符: %s 半帧=%d (期望 frames+drop=%d, crc_err<=%d, 半帧<=drop=%d)"
                  % (tag, stats, len(partials), ef, ec, stats[2] if stats else -1))
    print("[%s] %s" % (tag, "PASS" if ok else "FAIL"))
    return ok


if __name__ == "__main__":
    import os
    sim = sys.argv[1] if len(sys.argv) > 1 else "sim"
    lenient = "--lenient" in sys.argv
    tag = sys.argv[2] if len(sys.argv) > 2 else "check"
    sys.exit(0 if check(os.path.join(sim, "resp.memh"),
                        os.path.join(sim, "expected.memh"),
                        os.path.join(sim, "expected_stats.txt"),
                        lenient=lenient, tag=tag) else 1)
