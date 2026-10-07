#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
check_wu_words.py -- P7B-WU 扩窗 (61 -> 63, W61/W62) 的**定向静态核对**

为什么还要一个专门的检查器 (不重复 check_window.py):
  p7b_biz_win/check_window.py 的第 7 条只扫 `snap_dout_all` 的**顶层项**
  (p7bdp_dout / txsnap_dout / p7bfe_dout / snap_dout 四个名字) —— 它**看不到**
  `biz_w61/biz_w62` 这两个新别名**有没有被声明**。而未声明的名字在 xvlog 下是
  **合法隐式 1 位网** (rc=0、日志全空, 工程坑 24) ⇒ "接线写错名字" 这一类只能靠
  静态扫描守。本脚本补的就是这一格 + 本次改动的**逐处指纹**。

判据 (每条对着一个具体的、本工程踩过的失效形态):
  1  SNAP_NW_P6E == 63 且 SNAP_P7BDP_NW == 24
  2  BUILD_ID_V == 32'h9 (身份闸读它认位流)
  3  biz_w61 / biz_w62 **都在 `ifdef APP_MODE` 里声明** (`wire [31:0]`), 且
     else 分支有常量占位 (非 APP_MODE 构建里它们是未驱动线 => X 传播)
  4  `biz_w62` 是 `{15'd0, app_rx_occ}` (**17 位显式零扩展**; 漏了 = 截断/隐式网同族)
  5  biz_w61/biz_w62 的**声明行在使用行之前** (xelog 的"先声明后用")
  6  两根源线 `app_stat_wu` / `app_rx_occ` 在它们之前已声明
  7  `assign p7bdp_din[22*32 +: 32] = biz_w61;` / `[23*32 +: 32] = biz_w62;` (槽号不串)
  8  装配最上面两项 = `p7bdp_dout[23*32 +: 32]` / `[22*32 +: 32]` (**MSB 端先写**, 旧字不动)
用法: python check_wu_words.py [--repo <repo>]   退出码 0=全过 / 1=有 FAIL
"""
from __future__ import print_function
import io, os, re, sys, argparse

FAILS, PASSES = [], []


def ck(cond, name, detail=""):
    tag = "[PASS]" if cond else "[FAIL]"
    (PASSES if cond else FAILS).append(name)
    print("  %s %s %s" % (tag, name, detail))


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..")))
    a = ap.parse_args()
    w = os.path.join(a.repo, "board", "wrapper_p4.v")
    src = io.open(w, encoding="utf-8", newline="").read()
    print("=== check_wu_words: P7B-WU 63 字窗口的定向静态核对 (repo=%s) ===" % a.repo)

    # 1 几何
    m = re.search(r"localparam\s+SNAP_NW_P6E\s*=\s*(\d+)", src)
    ck(m is not None and m.group(1) == "63", "1a SNAP_NW_P6E == 63",
       "(实际 %s)" % (m.group(1) if m else "?"))
    m = re.search(r"localparam\s+SNAP_P7BDP_NW\s*=\s*(\d+)", src)
    ck(m is not None and m.group(1) == "24", "1b SNAP_P7BDP_NW == 24",
       "(实际 %s)" % (m.group(1) if m else "?"))

    # 2 身份
    m = re.search(r"\.BUILD_ID_V\s*\(32'h([0-9A-Fa-f]+)\)", src)
    ck(m is not None and int(m.group(1), 16) == 9, "2 BUILD_ID_V == 9",
       "(实际 %s)" % (m.group(1) if m else "?"))

    # 3 APP_MODE 守卫 (两个别名都要在 ifdef 块里)
    # ⚠️ 锚点 = **声明处** (`wire [31:0] biz_w61`), **不是**"名字首次出现处" —— 本轮实测踩到:
    #    在声明之前加了一段**提到** `biz_w61` 的注释 ⇒ 用"首次出现"当锚点会把窗口对到注释上,
    #    3a/3c 变成假 FAIL (判据自身的脆弱性, 不是被检对象的缺陷)。**脆弱的判据必须修判据本身**。
    anchor = src.find("wire [31:0] biz_w61")
    blk = re.search(r"`ifdef\s+APP_MODE\s*\n((?:\s*//[^\n]*\n|\s*wire[^\n]*\n)+)\s*`else",
                    src[max(anchor - 200, 0): anchor + 600]) if anchor > 0 else None
    ck(blk is not None, "3a biz_w61/w62 在 `ifdef APP_MODE 块里声明 (非 APP_MODE 有 `else 兜常量)")
    if blk:
        ck(("biz_w61" in blk.group(1)) and ("biz_w62" in blk.group(1)),
           "3b 块内确实声明了两个别名")
    # else 分支常量
    elseblk = re.search(r"`else\s*\n((?:\s*//[^\n]*\n|\s*wire[^\n]*\n)+)?\s*`endif",
                        src[anchor: anchor + 800]) if anchor > 0 else None
    ck(elseblk is not None and "biz_w61 = 32'd0" in (elseblk.group(0) or ""),
       "3c 非 APP_MODE 分支有 `biz_w61 = 32'd0` 占位 (防 X 传播)")

    # 4 位宽 (17 位显式零扩展)
    ck(re.search(r"biz_w62\s*=\s*\{15'd0,\s*app_rx_occ\}", src) is not None,
       "4 biz_w62 = {15'd0, app_rx_occ} (17 位显式零扩展)")

    # 5 先声明后用
    decl = src.find("wire [31:0] biz_w61")
    use_assign = src.find("assign p7bdp_din[22*32 +: 32] = biz_w61;")
    use_asm = src.find("p7bdp_dout[22*32 +: 32],   // W61")
    ck(decl > 0 and use_assign > decl and use_asm > decl,
       "5 biz_w61 声明在两次使用之前", "(decl=%d assign=%d asm=%d)" % (decl, use_assign, use_asm))

    # 6 源线已声明
    d_swu = src.find("wire [31:0] app_stat_wu")
    d_occ = src.find("wire [16:0] app_rx_occ")
    ck(0 < d_swu < decl, "6a app_stat_wu 声明在 biz_w61 之前", "(decl@%d)" % d_swu)
    ck(0 < d_occ < decl, "6b app_rx_occ 声明在 biz_w62 之前", "(decl@%d)" % d_occ)

    # 7 槽号 -> 字号
    ck(re.search(r"assign\s+p7bdp_din\[22\*32\s*\+\:\s*32\]\s*=\s*biz_w61\s*;", src) is not None,
       "7a p7bdp_din[22] = biz_w61 (槽 22 -> W61)")
    ck(re.search(r"assign\s+p7bdp_din\[23\*32\s*\+\:\s*32\]\s*=\s*biz_w62\s*;", src) is not None,
       "7b p7bdp_din[23] = biz_w62 (槽 23 -> W62)")

    # 8 装配 MSB 端前两项
    body = src[src.find("wire [SNAP_NW_P6E*32-1:0] snap_dout_all ="):]
    body = body[: body.find("};")]
    items = []
    for line in body.splitlines():
        line = re.sub(r"//.*", "", line)
        for tok in line.split(","):
            tok = tok.strip()
            if tok and not tok.startswith("wire"):
                items.append(tok)
    ck(len(items) >= 2 and items[0] == "p7bdp_dout[23*32 +: 32]" and
       items[1] == "p7bdp_dout[22*32 +: 32]",
       "8 装配最上两项 = W62/W61 (MSB 端先写)", "(实际 %s)" % items[:2])
    ck(items[-1] == "snap_dout", "8b 最右一项仍是 snap_dout (旧字未动)", "(实际 %s)" % (items[-1:],))

    print("----------------------------------------------------------")
    print("PASS=%d FAIL=%d" % (len(PASSES), len(FAILS)))
    if FAILS:
        print("CHECK_WU_WORDS_FAIL")
        sys.exit(1)
    print("CHECK_WU_WORDS_PASS")
    sys.exit(0)


if __name__ == "__main__":
    main()
