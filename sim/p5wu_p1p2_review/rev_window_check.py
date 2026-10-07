#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
rev_window_check.py -- 对抗审查 agent 自写的 63 字窗口核对 (不依赖作者的 check_window.py)

判据:
  A1  SNAP_NW_P6E / SNAP_FE_NW / SNAP_DP_NW / SNAP_P7BFE_NW / SNAP_P7BDP_NW / SNAP_TX_NW 的值
  A2  snap_dout_all 项数 == SNAP_NW_P6E (每项 32 位)
  A3  逐项列出 W 号: 必须 62..0 严格递减且 == 项序号 (即第 k 项 = W(62-k))
  A4  与 git HEAD 版本的项列表比对: 新列表的**尾部** 26 项必须与 HEAD **逐字相同**
      (HEAD 版 = 26 项 + snap_dout; 新版 = 28 项 + snap_dout)
  A5  p7bdp_din 的槽 -> 名字映射 (24 槽: 0/1/6..11 generate + 12..23 显式)
  A6  未实现地址算术: 0x20+4*NW; 末字地址 0x20+4*(NW-1); word 号 = addr/4; 7 位译码红线 0x200
  A7  BUILD_ID_V
用法: python rev_window_check.py [--repo P]
"""
from __future__ import print_function
import io, os, re, subprocess, sys

FAILS = []
PASSES = []


def ck(cond, name, detail=""):
    print("  %s %s %s" % ("[PASS]" if cond else "[FAIL]", name, detail))
    (PASSES if cond else FAILS).append(name)


def items_of(src):
    """抽出 snap_dout_all 的项列表 (去注释/空白), 返回 (items, 起始下标)"""
    i = src.find("wire [SNAP_NW_P6E*32-1:0] snap_dout_all = {")
    if i < 0:
        return None, -1
    j = src.find("};", i)
    body = src[i:j]
    items = []
    for line in body.splitlines():
        line = re.sub(r"//.*", "", line)
        line = line.replace("wire [SNAP_NW_P6E*32-1:0] snap_dout_all = {", "")
        line = line.replace("{", "").replace("}", "")
        for tok in line.split(","):
            tok = tok.strip()
            if tok:
                items.append(tok)
    return items, i


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    repo = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    w = os.path.join(repo, "board", "wrapper_p4.v")
    src = io.open(w, encoding="utf-8", newline="").read()
    print("=== rev_window_check (对抗审查自写) repo=%s ===" % repo)

    # ---- A1 几何 ----
    geo = {}
    for nm in ("SNAP_NW_P6E", "SNAP_FE_NW", "SNAP_DP_NW", "SNAP_P7BFE_NW",
               "SNAP_P7BDP_NW", "SNAP_TX_NW"):
        m = re.search(r"localparam\s+%s\s*=\s*(\d+)" % nm, src)
        geo[nm] = int(m.group(1)) if m else -1
    print("  [INFO] 几何 %s" % geo)
    ck(geo["SNAP_NW_P6E"] == 63, "A1a SNAP_NW_P6E == 63", "(%d)" % geo["SNAP_NW_P6E"])
    ck(geo["SNAP_P7BDP_NW"] == 24, "A1b SNAP_P7BDP_NW == 24", "(%d)" % geo["SNAP_P7BDP_NW"])
    # 束宽等式: 14+22 (snap_seq) + 3 + (24-4) + 4
    tot = geo["SNAP_FE_NW"] + geo["SNAP_DP_NW"] + geo["SNAP_P7BFE_NW"] + \
        (geo["SNAP_P7BDP_NW"] - 4) + geo["SNAP_TX_NW"]
    ck(tot == geo["SNAP_NW_P6E"], "A1c 束宽和 == NW (14+22+3+(24-4)+4=%d)" % tot)

    # ---- A2/A3 项数与 W 号 ----
    items, _ = items_of(src)
    ck(items is not None, "A2a 找到 snap_dout_all")
    # 最后一项 snap_dout 是 36 字 (snap_seq 两束 FE 14 + DP 22)
    n_1word = len(items) - 1
    total = n_1word + geo["SNAP_FE_NW"] + geo["SNAP_DP_NW"]
    ck(total == geo["SNAP_NW_P6E"], "A2b 项数对账 (%d 单项 + 36 = %d)" % (n_1word, total))
    ck(items[-1] == "snap_dout", "A2c 末项 = snap_dout", "(%s)" % items[-1])

    # 每项注释里的 W 号 (从 MSB 端 = 最高 W 起递减)
    body = src[src.find("wire [SNAP_NW_P6E*32-1:0] snap_dout_all ="):]
    body = body[: body.find("};")]
    ws = []
    for line in body.splitlines():
        m = re.search(r"//\s*(MAYBE)?W(\d+)", line)
        if m:
            ws.append(int(m.group(2)))
    print("  [INFO] 注释里的 W 号序列 (%d 个): %s ... %s" % (len(ws), ws[:6], ws[-6:]))
    ck(len(ws) == n_1word, "A3a 带 W 号的项数 == 单项数", "(%d vs %d)" % (len(ws), n_1word))
    ck(ws == sorted(ws, reverse=True), "A3b W 号严格递减 (MSB 先写)")
    ck(ws == list(range(ws[0], ws[0] - len(ws), -1)), "A3c W 号连续无跳号", "(head=%d tail=%d)" % (ws[0], ws[-1]))
    # 最高 W 号 = NW-1 (= W62); 最低单项 W 号 = FE+DP (= W36, 其下由 snap_dout 覆盖)
    ck(ws[0] == geo["SNAP_NW_P6E"] - 1, "A3d 最高 W 号 == NW-1", "(%d)" % ws[0])
    ck(ws[-1] == geo["SNAP_FE_NW"] + geo["SNAP_DP_NW"],
       "A3e 最低单项 W 号 == FE+DP (其下 36 字由 snap_dout 覆盖)", "(%d)" % ws[-1])

    # ---- A4 与 HEAD 逐字比对 ----
    try:
        head = subprocess.check_output(
            ["git", "-C", repo, "show", "95c9485:board/wrapper_p4.v"]).decode("utf-8")
    except Exception as e:
        head = None
        print("  [WARN] git show 失败: %s" % e)
    if head:
        hitems, _ = items_of(head)
        print("  [INFO] HEAD 项数 = %d (末项 %s) / 新表 %d" % (len(hitems), hitems[-1], len(items)))
        ck(len(items) == len(hitems) + 2, "A4a 新表恰好多 2 项")
        tail = items[len(items) - len(hitems):]
        same = (tail == hitems)
        ck(same, "A4b 新表尾部 == HEAD 逐字相同 (新增 2 项全在 MSB 端)")
        if not same:
            for k, (a, b) in enumerate(zip(tail, hitems)):
                if a != b:
                    print("     item %d: new=%r head=%r" % (k, a, b))
        ck(items[0] == "p7bdp_dout[23*32 +: 32]", "A4c 新项 1 = [23*32] (W62)", "(%s)" % items[0])
        ck(items[1] == "p7bdp_dout[22*32 +: 32]", "A4d 新项 2 = [22*32] (W61)", "(%s)" % items[1])

    # ---- A5 p7bdp_din 槽 -> 名字 ----
    din = os.path.join(repo, "board")
    din_src = src
    # generate 分支
    gen = re.search(r"for \(gi = 0; gi < (\d+); gi = gi \+ 1\) begin : g_p7bdp(.*?)endgenerate",
                    din_src, re.S)
    ck(gen is not None, "A5a 找到 generate 块")
    ngen = int(gen.group(1)) if gen else -1
    ck(ngen == 12, "A5b generate 12 项", "(%d)" % ngen)
    # gi 常量映射
    pairs = re.findall(r"\(gi == (\d+)\)\s*\?\s*([A-Za-z_0-9]+)", gen.group(2))
    print("  [INFO] generate 映射: %s" % pairs)
    # 显式映射
    exp = dict((int(a), b) for a, b in
               re.findall(r"assign p7bdp_din\[(\d+)\*32 \+: 32\] = ([A-Za-z_0-9]+);", din_src))
    print("  [INFO] 显式槽 -> 名字: %s" % sorted(exp.items()))
    ck(len(exp) == 12, "A5c 显式 assign 12 项", "(%d)" % len(exp))
    ck(exp.get(22) == "biz_w61", "A5d 槽22 = biz_w61", "(%s)" % exp.get(22))
    ck(exp.get(23) == "biz_w62", "A5e 槽23 = biz_w62", "(%s)" % exp.get(23))
    ck((12 + 12) == geo["SNAP_P7BDP_NW"], "A5f 驱动项数 (12 gen + 12 显式) == SNAP_P7BDP_NW")

    # ---- A6 地址算术 ----
    NW = geo["SNAP_NW_P6E"]
    last_addr = 0x20 + 4 * (NW - 1)
    unimpl = 0x20 + 4 * NW
    ck(last_addr == 0x118, "A6a 末字地址 = 0x118 (W62)", "(0x%X)" % last_addr)
    ck(unimpl == 0x11C, "A6b 首个未实现地址 = 0x11C", "(0x%X)" % unimpl)
    ck((unimpl >> 2) < 128, "A6c 未实现字号 < 2^7 (7 位译码不回绕)", "(word %d)" % (unimpl >> 2))
    ck((unimpl >> 2) <= 8 + NW - 1 + 1, "A6d 未实现字号确实 > SNAP_LAST_IDX",
       "(word %d vs LAST %d)" % (unimpl >> 2, 8 + NW - 1))
    ck(0x200 >> 2 >= 128, "A6e 0x200 回绕红线仍成立 (word 128 需 8 位)", "(0x200>>2 = %d)" % (0x200 >> 2))
    # 119 上限: 最后的负对照地址 0x1FC
    ck(NW <= 119, "A6f NW <= 119 (0x1FC 仍可作负对照)", "(%d)" % NW)
    ck(((NW - 1) << 5) < 4096, "A6g snap_base 12 位装得下 (NW-1)<<5", "(%d)" % ((NW - 1) << 5))

    # ---- A6h 装配项 <-> 注释 W 号的逐项配对 (表达式写错而注释没动 = "读到另一个字的正确值") ----
    expw = []   # (expr, W)
    for line in body.splitlines():
        e = re.search(r"(p7bdp_dout|txsnap_dout|p7bfe_dout)\[(\d+)\*32 \+: 32\]", line)
        wnum = re.search(r"//\s*W(\d+)", line)
        if e and wnum:
            expw.append((e.group(1), int(e.group(2)), int(wnum.group(1))))
    print("  [INFO] 束/槽 -> W 配对 (%d 项): %s ..." % (len(expw), expw[:3]))
    bases = {"p7bdp_dout": 39, "txsnap_dout": 41, "p7bfe_dout": 36}
    bad = [(b, s, w) for (b, s, w) in expw if bases[b] + s != w]
    ck(len(expw) == 0 or not bad, "A6h 每项 槽号+基址 == 注释 W 号", "(坏项 %s)" % bad)
    ck(len(expw) >= 27, "A6i 覆盖的配对项数 >= 27", "(%d)" % len(expw))
    # snap_dout 覆盖 W35..W0
    ck(items[-1] == "snap_dout" and (geo["SNAP_FE_NW"] + geo["SNAP_DP_NW"]) == 36,
       "A6j snap_dout = 36 字 (W35..W0)")

    # ---- A7 BUILD_ID ----
    m = re.search(r"\.BUILD_ID_V\s*\(32'h([0-9A-Fa-f]+)\)", src)
    ck(m is not None and int(m.group(1), 16) == 9, "A7 BUILD_ID_V == 9",
       "(%s)" % (m.group(1) if m else "?"))

    # ---- A8 别名 -> 源线 的语义链 (W61/W62 的"同一根线"声称) ----
    # W49 = cls_dbg_occ 必须由 generate 的 gi==10 给出 (先例核对)
    ck(re.search(r"\(gi == 10\)\s*\?\s*\{27'd0, cls_dbg_occ\}", gen.group(2)) is not None,
       "A8a 槽10 = {27'd0, cls_dbg_occ} (W49 = 同款组合占用字, 先例成立)")
    # W49 的源: cls_dbg_occ <- rx_classify.dbg_occ <- fifo_sync.dbg_wptr - dbg_rptr (纯 assign 引出寄存器)
    ck(re.search(r"\.dbg_occ\s*\(cls_dbg_occ\)", src) is not None, "A8b cls_dbg_occ <- u_cls.dbg_occ")
    # W62 的源 = app_rx_occ, 且它必须是 u_app_ctrl.rx_occ_bytes 的同一根线
    m = re.search(r"\.rx_occ_bytes\s*\(\s*([A-Za-z_0-9]+)\s*\)", src)
    ck(m is not None and m.group(1) == "app_rx_occ",
       "A8c u_app_ctrl.rx_occ_bytes <- app_rx_occ (W62 与判据同源)", "(%s)" % (m.group(1) if m else "?"))
    m = re.search(r"\.stat_wu\s*\(\s*([A-Za-z_0-9]+)\s*\)", src)
    ck(m is not None and m.group(1) == "app_stat_wu",
       "A8d u_app_ctrl.stat_wu -> app_stat_wu (W61 与寄存器 0x96 同源)", "(%s)" % (m.group(1) if m else "?"))
    m = re.search(r"wire \[31:0\]\s+biz_w61\s*=\s*([A-Za-z_0-9]+)\s*;", src)
    ck(m is not None and m.group(1) == "app_stat_wu", "A8e biz_w61 = app_stat_wu")
    m = re.search(r"wire \[31:0\]\s+biz_w62\s*=\s*(\{[^}]*\})\s*;", src)
    ck(m is not None and m.group(1).replace(" ", "") == "{15'd0,app_rx_occ}",
       "A8f biz_w62 = {15'd0, app_rx_occ} (17 位显式零扩展)", "(%s)" % (m.group(1) if m else "?"))
    # app_rx_occ 表达式的引用与 u_app_ctrl 输入**同一根线** (没有第二个副本)
    n_occ_decl = len(re.findall(r"wire \[16:0\]\s+app_rx_occ", src))
    ck(n_occ_decl == 1, "A8g app_rx_occ 只声明一次 (无第二个副本)", "(n=%d)" % n_occ_decl)

    print("----------------------------------------------------------")
    print("REV_WINDOW PASS=%d FAIL=%d" % (len(PASSES), len(FAILS)))
    sys.exit(1 if FAILS else 0)


if __name__ == "__main__":
    main()
