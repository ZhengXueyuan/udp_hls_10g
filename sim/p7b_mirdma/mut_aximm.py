#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
mut_aximm.py -- M1 期 B 的"该红时红"突变件生成器 (给 run_tb_mir_dma.bat 用)

从 rtl/aximm_c2h_win.v 生成三个**单点行为突变** (每个都改"合同里的一条"):
  mut_rid   : rid_r <= arid            -> rid_r <= 4'd0        (ID 不回填)
  mut_rlast : rlast <= (arlen==0) / ((cur+1)==arlen) -> 1'b0   (rlast 永不置; 两处, 各恰 1 命中)
  mut_row   : row_r <= row_r + 1       -> row_r <= row_r       (行地址不推进; 两处, 各恰 1 命中)

纪律 (同 mut_srcinv.py): 每个 pattern **恰好 1 处命中**才算成功 (打印命中数供门判);
输出 = 产物 (每次重生成); 只读 rtl/, 只写 mut/。

用法: python mut_aximm.py --arm mut_rid|mut_rlast|mut_row [--repo R]
"""
from __future__ import print_function
import io, os, sys, argparse

MUTS = {
    "mut_rid": [
        ("\n                    rid_r   <= arid;\n",
         "\n                    rid_r   <= 4'd0;   // MUT(mut_rid): not echoed\n", 1),
    ],
    "mut_rlast": [
        ("\n                    rlast  <= (arlen_r == 8'd0);\n",
         "\n                    rlast  <= 1'b0;   // MUT(mut_rlast)\n", 1),
        ("\n                        rlast  <= ((cur_r + 8'd1) == arlen_r);\n",
         "\n                        rlast  <= 1'b0;   // MUT(mut_rlast)\n", 1),
    ],
    "mut_row": [
        ("\n                if (row_go) row_r <= row_r + {{(ROW_AW-1){1'b0}}, 1'b1};\n",
         "\n                if (row_go) row_r <= row_r;   // MUT(mut_row)\n", 1),
        ("\n                    if (row_go) row_r <= row_r + {{(ROW_AW-1){1'b0}}, 1'b1};\n",
         "\n                    if (row_go) row_r <= row_r;   // MUT(mut_row)\n", 1),
        ("\n                        if (row_go) row_r <= row_r + {{(ROW_AW-1){1'b0}}, 1'b1};\n",
         "\n                        if (row_go) row_r <= row_r;   // MUT(mut_row)\n", 1),
    ],
}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--arm", required=True, choices=sorted(MUTS.keys()))
    ap.add_argument("--repo", default=os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    a = ap.parse_args()
    src = os.path.join(a.repo, "rtl", "aximm_c2h_win.v")
    dst_dir = os.path.join(a.repo, "sim", "p7b_mirdma", "mut")
    dst = os.path.join(dst_dir, "aximm_c2h_win_%s.v" % a.arm)
    text = io.open(src, encoding="utf-8", newline="").read()
    total = 0
    for old, new, want in MUTS[a.arm]:
        hits = text.count(old)
        print("MUT_AXIMM pattern hits = %d (want %d)" % (hits, want))
        if hits != want:
            print("MUT_AXIMM FAIL: anchor hits != want")
            return 2
        text = text.replace(old, new)
        total += hits
    print("MUT_AXIMM total_replacements = %d" % total)
    if not os.path.isdir(dst_dir):
        os.makedirs(dst_dir)
    with io.open(dst, "w", encoding="utf-8", newline="") as f:
        f.write(text)
    print("MUT_AXIMM WROTE %s" % dst)
    print("MUT_AXIMM_OK")
    return 0

if __name__ == "__main__":
    sys.exit(main())
