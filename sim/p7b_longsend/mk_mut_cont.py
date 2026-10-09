#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mk_mut_cont.py -- 从现役 rtl/app_pattern.v 生成 P7B-LONGSEND 负对照变异件
   (每个 = 1 处声明过的改动; 命中数不足/超出 => 硬失败, 不是"静默没打上")。
   输出到 sim/p7b_longsend/mut/*.v
   形状照 sim/p7b_stagec_tx_regress/author_gate/mk_mut_tx.py。
   变异集 (设计件 §4.2):
     M1 = CONT_OK 钉 1'b0            (连续逻辑整条失效)
     M2 = 删 tx_ok 臂的重装载         (:688-690 处那一行)
     M3 = 只改 tx_ok 臂、漏改 frm_wait 臂 (§1.5 陷阱的定向反例)
     M4 = 删 :676 的 `&& !CONT_OK`
   ⛔ 只读 rtl/app_pattern.v; 不写任何别的文件。
"""
import io
import os
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SRC = os.path.join(ROOT, "rtl", "app_pattern.v")
OUT = os.path.join(HERE, "mut")

# ⚠️ CRLF 归一化: 多行锚点一律用 `\n` 写 ⇒ 若工作树被 checkout 成 CRLF (core.autocrlf=true
#    在本机是 true), 多行锚点会 0 命中. 这里**读入即归一化**, 输出统一写 LF
#    (xvlog 两种行尾都吃). 反面教材 = sim/p7b_stagec_tx_regress/author_gate/mk_mut_tx.py
#    没做这一步 ⇒ 2026-10-09 实测 MUTGEN FAIL 5 (见 P7B_LONGSEND_DESIGN.md §7.3).
src = io.open(SRC, encoding="utf-8", newline="").read().replace("\r\n", "\n")

MUTS = []   # (name, [(old, new, hits)], note)


def add(name, subs, note):
    MUTS.append((name, subs, note))


# ---- M1: 连续逻辑整条失效 (CONT_OK 钉 0) ----
add("m1_cont_off", [(
    "    localparam CONT_OK = TX_CONTINUOUS && (TX_BYTES != 32'd0);",
    "    localparam CONT_OK = 1'b0;   // M1: 连续逻辑整条失效",
    1)], "M1 CONT_OK=0 => 连续模式整条失效 (A1/A3 必红)")

# ---- M2: 删掉 tx_ok 臂的重装载 (frm_wait 臂保留) ----
add("m2_no_reload_txok", [(
    "                        // ⭐ 连续模式: 量子耗尽 ⇒ 重装载 (图案 LFSR 不动 ⇒ 线上无缝)\n"
    "                        if (cont_reload) remain <= TX_BYTES;\n",
    "                        // M2: 删掉 tx_ok 臂的重装载\n",
    1)], "M2 tx_ok 臂不重装载 => 连续会停在量子末")

# ---- M3: 只改 tx_ok 臂, 漏改 frm_wait 臂 (§1.5 陷阱定向反例) ----
add("m3_miss_frmwait", [(
    "                seg_len  <= ((i_bad_frame != 16'd0) &&\n"
    "                             ((frm_idx + 16'd1) == i_bad_frame)) ? BAD_LEN :\n"
    "                            ((remain_nxt > {20'b0, TX_SEGSZ}) ? TX_SEGSZ : remain_nxt[11:0]);\n"
    "                seg_sent <= 12'd0;\n"
    "                bcnt     <= 4'd0;\n"
    "                op_pend  <= 1'b1; op_sent <= 1'b0;   // P5e: 同样以 opener 起帧\n"
    "                // ⭐ 连续模式: 量子耗尽 ⇒ 重装载 (与 tx_ok 臂同一件事, 两处都要有)\n"
    "                if (cont_reload) remain <= TX_BYTES;\n",
    "                seg_len  <= ((i_bad_frame != 16'd0) &&\n"
    "                             ((frm_idx + 16'd1) == i_bad_frame)) ? BAD_LEN :\n"
    "                            ((remain > {20'b0, TX_SEGSZ}) ? TX_SEGSZ : remain[11:0]);\n"
    "                seg_sent <= 12'd0;\n"
    "                bcnt     <= 4'd0;\n"
    "                op_pend  <= 1'b1; op_sent <= 1'b0;   // M3: 漏改 frm_wait 臂 (§1.5 陷阱)\n",
    1)], "M3 漏改 frm_wait 臂 => 量子末边界遇 tx_ok=0 即静默停滞 (A11/A3 必红)")

# ---- M4: 删掉终结判据的 !CONT_OK (连续模式仍会"结束") ----
add("m4_term_open", [(
    "                    if ((remain == 32'd0) && !CONT_OK) begin",
    "                    if (remain == 32'd0) begin    // M4: 删掉 !CONT_OK",
    1)], "M4 终结判据开 => 连续模式也终结 (A1/A2 必红)")

os.makedirs(OUT, exist_ok=True)
fail = 0
for name, subs, note in MUTS:
    t = src
    for old, new, hits in subs:
        n = t.count(old)
        if n != hits:
            print("MUTFAIL %s: pattern hits=%d expect=%d" % (name, n, hits))
            fail += 1
            continue
        t = t.replace(old, new)
    p = os.path.join(OUT, name + ".v")
    io.open(p, "w", encoding="utf-8", newline="").write(t)
    print("WROTE %-22s %s" % (name, note))
if fail:
    print("MUTGEN FAIL %d" % fail)
    sys.exit(1)
print("MUTGEN OK (%d mutants)" % len(MUTS))
