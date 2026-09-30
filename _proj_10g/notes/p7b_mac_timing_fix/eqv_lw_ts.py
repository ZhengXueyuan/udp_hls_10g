# -*- coding: utf-8 -*-
"""
eqv_lw_ts.py -- P7b 时序修复的**等价性证明 (穷举)**。

被改的量: mac_tx_10g.v 里的 lw_ts (末内容字的"尾起始 lane" = 内容字节数 + 本字 pad 数)。

原文:
    lw_L  = plen + cw_len
    lw_pad= max(0, 60 - lw_L)
    lw_room = 8 - cw_len
    lw_ph = min(lw_pad, lw_room)
    lw_ts = cw_len + lw_ph

改后:
    padrem = max(0, 60 - plen)          <-- 新寄存器 (与 plen 同拍更新, 见下面 INV)
    lw_ts  = 8            if padrem > 8
           = max(cw_len, padrem)  否则

本脚本穷举**全部可达的 (plen, cw_len)** 组合, 逐点比对两个式子; 并证明
    INV: 每一拍开始时 padrem == max(0, 60 - plen)
对所有单步转移成立 (因此对任意帧长/任意输入字序列成立)。

不用任何第三方库。 用法:
    /c/Users/zhxue/anaconda3/python.exe _proj_10g/notes/p7b_mac_timing_fix/eqv_lw_ts.py
"""
import sys

MIN_CLEN = 60
MAX_PLEN = 1600          # plen 的物理上界: 帧内容最长 1518 (含 pad), 取 1600 覆盖余量
MAX_CWLEN = 8


def old_lw_ts(plen, cw_len):
    lw_L = plen + cw_len
    lw_pad = 0 if lw_L >= MIN_CLEN else MIN_CLEN - lw_L
    lw_room = 8 - cw_len
    lw_ph = min(lw_pad, lw_room)
    return cw_len + lw_ph


def new_lw_ts(padrem, cw_len):
    if padrem > 8:
        return 8
    return max(cw_len, padrem)


def main():
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    bad = 0
    n = 0
    for plen in range(0, MAX_PLEN + 1):
        padrem = max(0, MIN_CLEN - plen)
        for cw_len in range(0, MAX_CWLEN + 1):
            a = old_lw_ts(plen, cw_len)
            b = new_lw_ts(padrem, cw_len)
            n += 1
            if a != b:
                bad += 1
                if bad <= 10:
                    print("MISMATCH plen=%d cw_len=%d old=%d new=%d" % (plen, cw_len, a, b))
    print("exhaustive compare: %d points, %d mismatch" % (n, bad))

    # ---- INV: padrem 的单步转移与 plen 一致 ----
    inv_bad = 0
    inv_n = 0
    for plen in range(0, MAX_PLEN + 1):
        padrem = max(0, MIN_CLEN - plen)
        for cw_len in range(0, MAX_CWLEN + 1):
            # 两个寄存器同拍更新 (S_DATA 非末字分支):
            #   plen' <= plen + cw_len      (16 位, 不截断)
            #   padrem' <= lw_pad = max(0, 60 - (plen+cw_len))   [6 位, 上界 60 不溢出]
            plen_n = plen + cw_len
            lw_L = plen + cw_len
            padrem_n = 0 if lw_L >= MIN_CLEN else MIN_CLEN - lw_L
            inv_n += 1
            if padrem_n != max(0, MIN_CLEN - plen_n):
                inv_bad += 1
            if padrem != max(0, MIN_CLEN - plen):        # 前提 (本拍不变式)
                inv_bad += 1
            assert 0 <= padrem_n <= MIN_CLEN, "padrem 溢出 6 位!"
    print("padrem invariant over all single steps: %d steps, %d violations" % (inv_n, inv_bad))

    # ---- S_PRE 复位点: plen=0 / padrem=60 ----
    ok_pre = (new_lw_ts(MIN_CLEN, 0) == old_lw_ts(0, 0))
    print("S_PRE reset point (plen=0,padrem=60) agrees: %s" % ok_pre)

    # ---- 关键边界: 60B 最小帧的两种路径 (pad 落在末字内 / 溢出到 S_TAIL0) ----
    for (plen, cw) in [(0, 8), (0, 1), (59, 1), (52, 8), (51, 8), (52, 7), (53, 8), (60, 8), (500, 8), (1510, 8)]:
        a = old_lw_ts(plen, cw)
        b = new_lw_ts(max(0, MIN_CLEN - plen), cw)
        print("  plen=%-5d cw_len=%d -> old=%d new=%d %s" % (plen, cw, a, b, "OK" if a == b else "MISMATCH"))

    verdict = (bad == 0 and inv_bad == 0 and ok_pre)
    print("\nEQV_VERDICT = %s" % ("PASS" if verdict else "FAIL"))
    return 0 if verdict else 1


if __name__ == "__main__":
    sys.exit(main())
