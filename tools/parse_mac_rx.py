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
        alien = [f for f in frames if f not in exp_set]
        if alien:
            ok = False
            print("[%s] 结构异常: 外来帧 %d" % (tag, len(alien)))
        # 半帧 = 帧原子丢弃的正常产物 (前部已出 FIFO 的词无 TLAST), 数量 <= drop
        if stats is None or stats[0] + stats[2] != ef or stats[1] > ec or len(partials) > stats[2]:
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
