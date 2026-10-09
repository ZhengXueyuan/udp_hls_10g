#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
mk_mut_tc.py -- P7B-GAP9-TX (TX_TAILCARRY) 门的**变异件生成器**

用途: run_tailcarry_gate.bat 的 M1/M2/M3 臂 (期望 RC != 0 = "门有牙")。
三个变异件各自钉住本刀**已识别的三个语义风险点** (不是随便挑的):
  M1 mut_tc_off.v        : TAILC_OK 常量钉 0 (carry 整条关掉) => 帧周期回落 190
                           (= 判据确实在判"carry 生效", 不是恒绿的哑门)
  M2 mut_bad_upd.v       : 坏帧期间**照样更新** wc_buf/wc_n (仓外原型第一版的错法:
                           只清 wc_n 不碰 wc_buf => 0xA5 残留跨帧泄漏) => 图案流应红
  M3 mut_noclear.v       : ev_up (换流) 时**不清** carry => 新会话头几个字节是旧流残留
                           => 重连臂 (u_rec) 的图案流应红

输入 = 现役 `rtl/app_pattern.v` (LF); 输出 = 本目录下的 3 个变异件 (LF)。
用法: python mk_mut_tc.py <repo_root>
"""
from __future__ import print_function
import io
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def read(p):
    return io.open(p, encoding="utf-8", newline="").read()


def write(p, s):
    io.open(p, "w", encoding="utf-8", newline="").write(s)


def sub_once(src, old, new, tag):
    n = src.count(old)
    if n != 1:
        raise SystemExit("ANCHOR-FAIL [%s]: count=%d (expect 1)" % (tag, n))
    return src.replace(old, new)


def main():
    repo = sys.argv[1] if len(sys.argv) > 1 else os.path.abspath(
        os.path.join(HERE, "..", "..", ".."))
    src = read(os.path.join(repo, "rtl", "app_pattern.v"))
    print("live rtl/app_pattern.v: %d bytes" % len(src))

    # --- M1: TAILC_OK 钉 0 (carry 整条关掉) ---
    m1 = sub_once(src,
                  "    localparam  TAILC_OK = (TX_TAILCARRY != 1'b0);",
                  "    localparam  TAILC_OK = 1'b0;   // [M1] mutant: carry 整条关掉",
                  "M1")
    write(os.path.join(HERE, "mut_tc_off.v"), m1)

    # --- M2: 坏帧期间照样更新 carry (= 原型第一版的错法) ---
    m2 = sub_once(src,
                  "                    if (!bad_frm) begin\n"
                  "                        wc_buf <= wc_nxt;",
                  "                    if (1'b1) begin   // [M2] mutant: carry 在坏帧期间也更新\n"
                  "                        wc_buf <= wc_nxt;",
                  "M2")
    write(os.path.join(HERE, "mut_bad_upd.v"), m2)

    # --- M3: ev_up (换流) 时不清 carry ---
    m3 = sub_once(src,
                  "                    wc_buf   <= 64'd0; wc_n <= 4'd0;\n"
                  "                    bad_frm  <= (i_bad_frame == 16'd1);",
                  "                    // [M3] mutant: 换流不清 carry\n"
                  "                    bad_frm  <= (i_bad_frame == 16'd1);",
                  "M3")
    write(os.path.join(HERE, "mut_noclear.v"), m3)

    for f in ("mut_tc_off.v", "mut_bad_upd.v", "mut_noclear.v"):
        p = os.path.join(HERE, f)
        print("  wrote %-18s %d bytes" % (f, os.path.getsize(p)))
    print("MUTGEN-TC: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
