#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_mutants.py -- 从 rtl/fifo_async.v 生成 3 个**故意做错**的变体 (负对照)。

为什么要有变体: 单元门的判据必须证明"它错了会失败", 否则判据可能是空的。
每个变体只改一处, 且改的正是某条判据声称能守住的点:

  mut_binptr.v      灰码指针 → 二进制 (wgray_n = wbin_n)      ⇒ 灰码监视必须报警
  mut_full_off.v    满判据用当前 wgray 而不是 wgray_n (晚一拍) ⇒ 金标准对拍必须报内容错
  mut_empty_1stage.v 空判据只用一级同步 (wgray_s1_r)           ⇒ LAT 延迟契约必须报警

用法 (Windows, anaconda python):
  C:/Users/zhxue/anaconda3/python.exe sim/fifoasync/mut/gen_mutants.py
⚠️ 每条 patch 必须**恰好命中一次**, 否则脚本报错退出 —— 改了 rtl/fifo_async.v 之后
   必须重跑本脚本 (沉默地生成"没改到"的副本 = 变体门假绿)。
"""
import io
import os
import sys

# GBK 控制台下 print 非 ASCII 会抛 UnicodeEncodeError ⇒ 退出码变 1 (本工程坑 16①)
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.normpath(os.path.join(HERE, "..", "..", "..", "rtl", "fifo_async.v"))

MUTANTS = [
    ("mut_binptr.v",
     "灰码指针换二进制 (灰码监视判据的负对照)",
     [("    wire [AW:0] wgray_n = wbin_n ^ (wbin_n >> 1);                 // bin2gray",
       "    wire [AW:0] wgray_n = wbin_n;                                  // MUT: 二进制 (无灰码)"),
      ("    wire [AW:0] rgray_n = rbin_n ^ (rbin_n >> 1);",
       "    wire [AW:0] rgray_n = rbin_n;                                  // MUT: 二进制 (无灰码)")]),

    ("mut_full_off.v",
     "满判据用当前 wgray (不含本拍待写) ⇒ 满标志晚一拍 (多写一个字, 覆盖未读槽)",
     [("    wire        full_n  = (wgray_n == {~rgray_s2_w[AW:AW-1], rgray_s2_w[AW-2:0]});",
       "    wire        full_n  = (wgray_r == {~rgray_s2_w[AW:AW-1], rgray_s2_w[AW-2:0]});  // MUT")]),

    ("mut_empty_1stage.v",
     "空判据只用一级同步 (少一级) ⇒ 空标志提前一拍 (LAT 延迟契约的负对照)",
     [("    wire        empty_n = (rgray_n == wgray_s2_r);",
       "    wire        empty_n = (rgray_n == wgray_s1_r);                 // MUT: 少一级同步")]),

    ("mut_full_1stage.v",
     "满判据只用一级同步 (少一级) ⇒ 满标志提前一拍 (LAT 满延迟契约的负对照)",
     [("    wire        full_n  = (wgray_n == {~rgray_s2_w[AW:AW-1], rgray_s2_w[AW-2:0]});",
       "    wire        full_n  = (wgray_n == {~rgray_s1_w[AW:AW-1], rgray_s1_w[AW-2:0]});  // MUT: 少一级同步")]),

    ("mut_noovf.v",
     "拒写探针被拿掉 (ovf_pulse 钉 0) ⇒ 复位释放窗口的丢字重新变成静默 (F-1 判据的负对照)",
     [("    wire        ovf_pulse_w = wr_en && full_r;",
       "    wire        ovf_pulse_w = 1'b0;                                // MUT: 探针被拿掉")]),

    ("mut_pref1.v",
     "F-1 修前行为: full 复位值仍是 0 (复位释放窗口报'不满') ⇒ 窗口内的写被静默丢弃",
     [("            full_r     <= 1'b1;",
       "            full_r     <= 1'b0;                                // MUT: 修前行为 (F-1)")]),

    ("mut_rst_1stage.v",
     "两侧复位同步器各少一级 (单拍释放) ⇒ 释放沿不再经两级同步 (复位释放时序的负对照)",
     [("    wire wr_rst_n_s = wr_rst_sync[1];",
       "    wire wr_rst_n_s = wr_rst_sync[0];                              // MUT: 少一级"),
      ("    wire rd_rst_n_s = rd_rst_sync[1];",
       "    wire rd_rst_n_s = rd_rst_sync[0];                              // MUT: 少一级")]),
]


def main():
    src = io.open(SRC, encoding="utf-8").read()
    rc = 0
    for name, why, patches in MUTANTS:
        txt = src
        for old, new in patches:
            n = txt.count(old)
            if n != 1:
                sys.stdout.write("ERROR: patch for %s matched %d times (expected 1):\n  %s\n"
                                 % (name, n, old[:80]))
                rc = 1
                continue
            txt = txt.replace(old, new)
        if rc:
            continue
        hdr = ("// !!! MUTANT (负对照) — 不要综合, 不要当交付件 !!!\n"
               "// %s\n"
               "// 由 sim/fifoasync/mut/gen_mutants.py 从 rtl/fifo_async.v 生成;\n"
               "// 只改一处, 模块名保持不变 (TB 无需改动)。\n" % why)
        out = os.path.join(HERE, name)
        io.open(out, "w", encoding="utf-8", newline="\n").write(hdr + txt)
        sys.stdout.write("wrote %s (%s)\n" % (name, why))
    sys.stdout.write("gen_mutants: %s\n" % ("OK" if rc == 0 else "FAILED"))
    return rc


if __name__ == "__main__":
    sys.exit(main())
