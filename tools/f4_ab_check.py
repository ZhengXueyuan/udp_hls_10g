#!/usr/bin/env python
"""F4 A/B 判据: **好帧不被白丢** (NEW 的交付不得低于 OLD)。

用法: f4_ab_check.py <old_case_stats.txt> <new_case_stats.txt>
两侧文件由 tb/tb_mac_rx_f4.v 逐例写 (STAT 行; 每行 = 该例的增量)。

判据:
  R1 逐例: DP_good(NEW) >= DP_good(OLD) 且 DP_good_bytes(NEW) >= DP_good_bytes(OLD)
           —— "实际交付的好帧/好字节" 不允许比修复前少 (这是缺陷被抓到的形态)。
  R2 FE 计数 (`stat_frames`/`stat_bytes`) 若 NEW < OLD, 必须能证明 **OLD 自己的记录是谎报**:
     要求 DP_good(OLD) < FE_frames(OLD) (旧版把没交付完的帧记成成功) —— 否则算回归 FAIL。
     理由: F4(b) 的旧行为 = "计数器 +1 但 TLAST 字被静默丢弃", 旧读数天然虚高;
     用旧版自证矛盾来区分 "真回归" 与 "去掉虚高"。
  R3 两侧例名集合必须一致 (激励变了就没法比)。
输出: 逐例差异明细 + `F4_AB: PASS|FAIL`。
"""
import sys

COLS = ["FE_frames", "FE_bytes", "FE_drop", "FE_dropfull", "FE_partial",
        "FE_orphanb", "FE_ovf", "DP_words", "DP_popc", "DP_sop", "DP_good",
        "DP_goodbytes", "DP_term", "DP_bare"]


def load(path):
    d = {}
    order = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for ln in fh:
            p = ln.split()
            if len(p) != len(COLS) + 2 or p[0] != "STAT":
                continue
            name = p[1]
            d[name] = dict(zip(COLS, (int(x) for x in p[2:])))
            order.append(name)
    return d, order


def main():
    old, o_order = load(sys.argv[1])
    new, n_order = load(sys.argv[2])
    bad = []
    if set(old) != set(new):
        print("R3 FAIL: 例名集合不一致 old=%d new=%d (差集 %s)" %
              (len(old), len(new), sorted(set(old) ^ set(new))[:5]))
        print("F4_AB: FAIL (1)")
        return 1

    r1 = r2 = 0
    excused = []
    for name in o_order:
        o, n = old[name], new[name]
        if n["DP_good"] < o["DP_good"] or n["DP_goodbytes"] < o["DP_goodbytes"]:
            r1 += 1
            print("R1 FAIL %-14s 好帧交付倒退: DP_good %d->%d, DP_goodbytes %d->%d"
                  % (name, o["DP_good"], n["DP_good"], o["DP_goodbytes"], n["DP_goodbytes"]))
        for k in ("FE_frames", "FE_bytes"):
            if n[k] < o[k]:
                # 允许: 旧版虚高 (其自证矛盾)
                if o["DP_good"] < o["FE_frames"]:
                    excused.append((name, k, o[k], n[k]))
                else:
                    r2 += 1
                    print("R2 FAIL %-14s %s 倒退 %d->%d 且 OLD 记录自洽 (非虚高)"
                          % (name, k, o[k], n[k]))
    if excused:
        print("R2 说明: %d 处 FE 计数下降, 均为 OLD 虚高 (OLD 的 DP_good=%d < FE_frames), 例: %s"
              % (len(excused), old[excused[0][0]]["DP_good"],
                 ", ".join("%s.%s %d->%d" % e for e in excused[:6])))
    ago = sum(old[k]["DP_good"] for k in old)
    agn = sum(new[k]["DP_good"] for k in new)
    bgo = sum(old[k]["DP_goodbytes"] for k in old)
    bgn = sum(new[k]["DP_goodbytes"] for k in new)
    print("TOTAL: DP_good %d -> %d | DP_goodbytes %d -> %d | 例数 %d" %
          (ago, agn, bgo, bgn, len(o_order)))
    ok = (r1 == 0 and r2 == 0)
    print("F4_AB: %s%s" % ("PASS" if ok else "FAIL",
                           "" if ok else " (%d 条)" % (r1 + r2)))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
