#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
rev_p1_equiv.py -- P1 的等价性声称的**穷举核对** (对抗审查自写)

被检声称 (作者在 rtl/app_ctrl.v 的文件头/C6 块 + note §1.2 写):
  (a) 目标语义 = wscan < max(floor(winq/4), 1)
  (b) 实现 = (wscan < winq[15:2]) || (wscan == 0)     <-- winq[15:2] = floor(winq/4)
  (c) 声称 b == a 对**所有** (winq, wscan) 成立
  (d) 声称 winq/4 >= 1 时 "后项被前项蕴含" ⇒ 相对旧式 `wscan < winq/4` **逐位不变**
      (即: 产品配置 winq>=3072 下 P1 子改动是 no-op)

方法: 两个谓词都是 wscan 上的**单调阈值谓词** ⇒ 只需在**临界点**上比对:
      wscan ∈ {0, 1, T-1, T, T+1, 0x8000, 0xFFFF} (T = floor(winq/4))
      再对每个 winq 抽 32 个伪随机 wscan 做冗余覆盖。
      另外对**全 winq 空间** (0..65535) 逐值核对 (c)。
用法: python rev_p1_equiv.py
"""
from __future__ import print_function
import random, sys


def impl_new(winq, wscan):          # 实现: (wscan < winq[15:2]) || (wscan == 0)
    return (wscan < (winq >> 2)) or (wscan == 0)


def target(winq, wscan):            # 目标语义: wscan < max(winq//4, 1)
    return wscan < max(winq >> 2, 1)


def impl_old(winq, wscan):          # 旧式 (首轮修复): wscan < winq[15:2]
    return wscan < (winq >> 2)


def main():
    fails = 0
    rnd = random.Random(20261007)
    # ---- (c) 全 winq x 临界点 + 随机 ----
    for winq in range(0, 65536):
        T = winq >> 2
        cand = set([0, 1, 2, 0xFFFF, 0x8000, 0x4000])
        if T >= 1:
            cand |= set([T - 1, T, T + 1, min(T + 2, 0xFFFF)])
        for _ in range(32):
            cand.add(rnd.randrange(0, 65536))
        for wscan in cand:
            if impl_new(winq, wscan) != target(winq, wscan):
                if fails < 20:
                    print("  [FAIL] (c) winq=%d wscan=%d new=%s target=%s"
                          % (winq, wscan, impl_new(winq, wscan), target(winq, wscan)))
                fails += 1
    print("  [%s] (c) 实现 == 目标语义 (全 winq 0..65535, 每值 %d 点)"
          % ("PASS" if fails == 0 else "FAIL", 38))

    # ---- (d) winq/4 >= 1 ⇒ 与旧式逐个 wscan 相同 ----
    diff_ge1 = []
    diff_lt1 = []
    for winq in range(0, 65536):
        T = winq >> 2
        sample = [0, 1, 2, 3, 0xFFFF, 0x8000]
        if T >= 1:
            sample += [T - 1, T, T + 1]
        for wscan in sample:
            if impl_new(winq, wscan) != impl_old(winq, wscan):
                if T >= 1:
                    diff_ge1.append((winq, wscan))
                else:
                    diff_lt1.append((winq, wscan))
    print("  [%s] (d) T>=1 (winq>=4) 时 新式 == 旧式 (差异数 = %d)"
          % ("PASS" if not diff_ge1 else "FAIL", len(diff_ge1)))
    print("  [INFO] T==0 (winq<=3) 时 差异数 = %d  (差异 = 修复点, 预期非零)" % len(diff_lt1))
    # 差异的 winq 值域
    wq = sorted(set(w for w, s in diff_lt1))
    print("  [INFO] 差异仅出现在 winq ∈ %s ... %s (共 %d 个值)"
          % (wq[:4], wq[-4:], len(wq)))

    # ---- 产品配置 (winq >= 3072) 下 P1 子改动是 no-op? ----
    bad_prod = 0
    for winq in range(3072, 65536, 7):      # 抽样 (步长 7 覆盖非 4 倍数/4 倍数两族)
        T = winq >> 2
        for wscan in [0, 1, T - 1, T, T + 1, 0xFFFF]:
            if impl_new(winq, wscan) != impl_old(winq, wscan):
                bad_prod += 1
    print("  [%s] 产品配置抽样 (winq 3072..65535 步长 7): P1 子改动 0 处行为差"
          % ("PASS" if bad_prod == 0 else "FAIL"))

    # ---- 边界/退化表 (给报告用) ----
    print("  [INFO] 逐域行为 (wscan 取 T-1/T/T+1):")
    for winq in [0, 1, 2, 3, 4, 5, 7, 8, 15, 16, 3072, 0xC000]:
        T = winq >> 2
        print("     winq=%-6d floor(winq/4)=%-6d arm@wscan=0:%s/%s  (T-1,T,T+1)=(%s,%s,%s) new/target 一致"
              % (winq, T, impl_new(winq, 0), impl_old(winq, 0),
                 impl_new(winq, max(T - 1, 0)) == target(winq, max(T - 1, 0)),
                 impl_new(winq, T) == target(winq, T),
                 impl_new(winq, T + 1) == target(winq, T + 1)))
    sys.exit(1 if (fails or diff_ge1 or bad_prod) else 0)


if __name__ == "__main__":
    main()
