#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
mut_h2cdisc.py -- M1 期 B 写从机 (aximm_h2c_discard) 的"该红时红"突变件生成器

从 rtl/aximm_h2c_discard.v 生成三个**单点行为突变** (每个都改"合同里的一条"):
  mut_bid    : bid <= aw_go ? awid : bid_r  -> bid <= 4'd0      (ID 不回填)
  mut_bearly : (aw_got||aw_go) && (w_done||w_last_go) -> (aw_got||aw_go)
               (AW 一收到就发 B —— 不等 WLAST ⇒ "B 对齐整笔"被破坏)
  mut_wready : assign wready = !w_done      -> assign wready = 1'b1
               (WLAST 后照吞 ⇒ "B 前不许再吞" 被破坏)

纪律 (同 mut_aximm.py / mut_srcinv.py): 每个 pattern **恰好 1 处命中**才算成功
(打印命中数供生成器自判); 输出 = 产物 (每次重生成); 只读 rtl/, 只写 mut/。

用法: python mut_h2cdisc.py --arm mut_bid|mut_bearly|mut_wready [--repo R]
"""
from __future__ import print_function
import io, os, sys, argparse

MUTS = {
    "mut_bid": [
        ("                bid    <= aw_go ? awid : bid_r;   // 同拍新到 ⇒ 用新 id, 否则用锁存\n",
         "                bid    <= 4'd0;   // MUT(mut_bid): id not echoed\n", 1),
    ],
    "mut_bearly": [
        ("            if ((aw_got || aw_go) && (w_done || w_last_go)) begin\n",
         "            if (aw_got || aw_go) begin   // MUT(mut_bearly): no WLAST wait\n", 1),
    ],
    "mut_wready": [
        ("    assign wready  = !w_done;\n",
         "    assign wready  = 1'b1;   // MUT(mut_wready): keeps swallowing after WLAST\n", 1),
    ],
}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--arm", required=True, choices=sorted(MUTS.keys()))
    ap.add_argument("--repo", default=os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    a = ap.parse_args()
    src = os.path.join(a.repo, "rtl", "aximm_h2c_discard.v")
    dst_dir = os.path.join(a.repo, "sim", "p7b_h2cdisc", "mut")
    dst = os.path.join(dst_dir, "aximm_h2c_discard_%s.v" % a.arm)
    text = io.open(src, encoding="utf-8", newline="").read()
    total = 0
    for old, new, want in MUTS[a.arm]:
        hits = text.count(old)
        print("MUT_H2CDISC pattern hits = %d (want %d)" % (hits, want))
        if hits != want:
            print("MUT_H2CDISC FAIL: anchor hits != want")
            return 2
        text = text.replace(old, new)
        total += hits
    print("MUT_H2CDISC total_replacements = %d" % total)
    if not os.path.isdir(dst_dir):
        os.makedirs(dst_dir)
    with io.open(dst, "w", encoding="utf-8", newline="") as f:
        f.write(text)
    print("MUT_H2CDISC WROTE %s" % dst)
    print("MUT_H2CDISC_OK")
    return 0

if __name__ == "__main__":
    sys.exit(main())
