#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
mut_srcinv.py -- M1 期 A 的"该红时红"突变件生成器 (给 run_tb_p6e_pcie_mut.bat 用)

做什么: 把 board/wrapper_p4.v 里 **src_sel 的 dp 域选择** 一行取反
        (`mir_src_sel = mir_src_sr[1]` -> `~mir_src_sr[1]`), 落到
        sim/p6e_pcie/mut/wrapper_p4_mut_srcinv.v。

为什么这么改: 取反后 `src_sel=1` 选中的是 **UDP** 口而不是 TCP 口 ⇒ p6e 全链门的
        M1-10b/10c/10d 三条判据必然翻红 (10b 期望 level=0 会看到 3 字; 10c 期望 1 字 TCP
        会看到 0 字; 10d 的同拍双打也会看到 UDP 侧的字) ⇒ "门有牙"。

纪律 (全局 #90-#94 精神):
  · **恰好 1 处命中**才算成功 (0 处 = 锚点陈旧; >1 处 = 改错地方) —— 打印 new_hits 供门判;
  · 只做**一次**替换, 不做任何别的编辑; 输出件是**产物** (不假设它已存在, 每次都重生成);
  · 不改仓库里的任何源文件 (只读 wrapper, 只写 mut/ 下)。

用法: python mut_srcinv.py [--repo <repo>]      (退出码 0 = 已生成且 new_hits==1)
"""
from __future__ import print_function
import io, os, sys, argparse

OLD = "    wire        mir_src_sel  = mir_src_sr[1];"
NEW = "    wire        mir_src_sel  = ~mir_src_sr[1];   // MUT(srcinv): 极性取反"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    a = ap.parse_args()
    src = os.path.join(a.repo, "board", "wrapper_p4.v")
    dst_dir = os.path.join(a.repo, "sim", "p6e_pcie", "mut")
    dst = os.path.join(dst_dir, "wrapper_p4_mut_srcinv.v")
    text = io.open(src, encoding="utf-8", newline="").read()
    hits = text.count(OLD)
    print("MUT_SRCINV anchor_hits = %d" % hits)
    if hits != 1:
        print("MUT_SRCINV FAIL: anchor must hit exactly 1 line (got %d)" % hits)
        return 2
    out = text.replace(OLD, NEW)
    if out.count(NEW) != 1:
        print("MUT_SRCINV FAIL: replacement count != 1")
        return 2
    if not os.path.isdir(dst_dir):
        os.makedirs(dst_dir)
    with io.open(dst, "w", encoding="utf-8", newline="") as f:
        f.write(out)
    print("MUT_SRCINV WROTE %s (bytes=%d)" % (dst, len(out)))
    print("MUT_SRCINV_OK")
    return 0

if __name__ == "__main__":
    sys.exit(main())
