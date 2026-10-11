#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
mut_bwire.py -- M1 **期 B** 的"该红时红"突变件生成器 (给 run_tb_p6e_pcie_mut2.bat 用)

做什么: 把 board/wrapper_p4.v 里**环的写数据口**一行改掉 ——
        `.src_data  (mir_dout),` -> `.src_data  (32'd0),`
        落到 sim/p6e_pcie/mut/wrapper_p4_mut_bwire.v。

为什么这么改 (与 mut_srcinv.py 的差别): srcinv 是**期 A** 的突变 (它的红来自期 A 的
        M1-10* 判据) —— 它**不覆盖期 B 的接线**。本突变只动期 B 的一根线: 环照常收到
        "写脉冲"(计数器照涨 ⇒ M1-B-1/3a 仍过), 但**写进去的数据恒 0** ⇒ 只该由
        **内容对账**那几条判据 (M1-B-2e / M1-B-3d) 翻红。这就是"期 B 的新判据有自己的牙"
        的证明 (若全绿 ⇒ 内容判据是空判据)。

纪律 (全局 #90-#94 精神, 同 mut_srcinv.py):
  · **恰好 1 处命中**才算成功 (打印 new_hits 供 bat 判); 只做一次替换;
  · 不改仓库里的任何源文件 (只读 wrapper, 只写 mut/ 下)。

用法: python mut_bwire.py [--repo <repo>]      (退出码 0 = 已生成且 hits==1)
"""
from __future__ import print_function
import io, os, sys, argparse

# ⚠️ 锚点**不带换行** —— wrapper_p4.v 是 CRLF 行尾 (带 \n 的锚点会 0 命中; 实测踩过),
#    而带 \r\n 的锚点又会让本脚本自身行尾敏感 ⇒ 只锚行内容。
OLD = "        .src_data  (mir_dout),           // FWFT 头字 (与 dma_gnt 同拍有效)"
NEW = "        .src_data  (32'd0),              // MUT(bwire): ring data pinned 0"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    a = ap.parse_args()
    src = os.path.join(a.repo, "board", "wrapper_p4.v")
    dst_dir = os.path.join(a.repo, "sim", "p6e_pcie", "mut")
    dst = os.path.join(dst_dir, "wrapper_p4_mut_bwire.v")
    text = io.open(src, encoding="utf-8", newline="").read()
    hits = text.count(OLD)
    print("MUT_BWIRE anchor_hits = %d" % hits)
    if hits != 1:
        print("MUT_BWIRE FAIL: anchor must hit exactly 1 line (got %d)" % hits)
        return 2
    out = text.replace(OLD, NEW)
    if out.count(NEW) != 1:
        print("MUT_BWIRE FAIL: replacement count != 1")
        return 2
    if not os.path.isdir(dst_dir):
        os.makedirs(dst_dir)
    with io.open(dst, "w", encoding="utf-8", newline="") as f:
        f.write(out)
    print("MUT_BWIRE WROTE %s (bytes=%d)" % (dst, len(out)))
    print("MUT_BWIRE_OK")
    return 0

if __name__ == "__main__":
    sys.exit(main())
