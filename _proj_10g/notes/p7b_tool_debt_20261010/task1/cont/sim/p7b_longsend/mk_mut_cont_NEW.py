#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mk_mut_cont.py -- 从现役 rtl/app_pattern.v 生成 P7B-LONGSEND 负对照变异件
   (每个 = 1 处声明过的改动; 命中数不足/超出 => 硬失败, 不是"静默没打上")。
   输出到 sim/p7b_longsend/mut/*.v   (由 run_cont_gate.bat 消费)
   形状照 sim/p7b_stagec_tx_regress/author_gate/mk_mut_tx.py (参照件)。
   变异集 (设计件 §4.2):
     M1 = CONT_OK 钉 1'b0            (连续逻辑整条失效)
     M2 = 删 tx_ok 臂的重装载         (:688-690 处那一行)
     M3 = 只改 tx_ok 臂、漏改 frm_wait 臂 (§1.5 陷阱的定向反例)
     M4 = 删 :676 的 `&& !CONT_OK`
     M5 = 删 A3 的"待补登记"(被吞的 ev_up 又变回永久丢失 = 修前行为; 构建 E)
   ⛔ 只读 rtl/app_pattern.v; 不写任何别的文件。

   ------------------------------------------------------------------
   2026-10-10 工具修复 (地雷处置, 两条; 修法照参照件):
   (1) **落盘时机 = 全成或全不落 (all-or-nothing)**: 旧版**边匹配边写盘** ⇒
       锚点没命中的那些变异被写成**未变异的源文件副本** (参照件那支实测: 三件 sha256
       == 源文件), 多锚点的变异只落**一半替换** —— 而"变异臂"这个名字会照样被门消费
       = 哑门族 (判据看着有牙, 其实打的是源文件)。旧版还会对失败的件照打 `WROTE`。
       现在: 先在内存里把**所有**变异件做完 + 逐锚点核命中数 + 核源文件 sha256 未变,
       全部通过才一次性落盘; 任一失败 ⇒ **不落盘任何变异件**, 并把本清单里**已存在的**
       同名旧件删掉 (打印 PURGED) ⇒ 硬不变式:
       **mut/ 要么是"本清单全部变异件的完整、已核验的一份", 要么是空的**,
       绝不会出现"半套/陈旧混装"。
   (2) **命中数一律在【未修改的源文本】上计** (参照件同款): 旧版在**逐条替换后的**
       中间文本上 `t.count(old)` —— 一旦某条替换的 new 里含另一条的 old 就会静默漂移。
       本清单一律核过 (逐锚点见 `--dry-run`), 两法等价; 取参照件写法防将来漂移。
   ⚠️ CRLF 归一化: 多行锚点一律用 `\n` 写 ⇒ 若工作树被 checkout 成 CRLF
      (core.autocrlf=true 在本机是 true), 多行锚点会 0 命中。这里**读入即显式归一化**
      (不经读侧的隐式通用换行), 输出统一写 LF (xvlog 两种行尾都吃)。
      反面教材 = 参照件的**旧版** `mk_mut_tx.py` 用 `newline=""` 读 + 裸 `\n` 锚点
      ⇒ 2026-10-09 实测 MUTGEN FAIL 5 (见 P7B_LONGSEND_DESIGN.md §7.3)。
      2026-10-10 实测: `rtl/app_pattern.v` 工作树是 **LF** (82,034 B / 0 CRLF),
      但归一化保住"别的 checkout 风格"下同样成立。
   ------------------------------------------------------------------
   `--dry-run` (或 `--check`): 只做匹配 + 打印逐锚点命中表, **一个字节都不写**.
   退出码: 0 = 全部锚点命中数 == 声明值; 1 = 有差异.
"""
import hashlib
import io
import os
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SRC = os.path.join(ROOT, "rtl", "app_pattern.v")
OUT = os.path.join(HERE, "mut")

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

# ---- M5 (构建 E): 删掉 A3 的待补登记 ⇒ 回到"被吞的 ev_up 永久丢失" ----
#   定向反例: tb_app_cont 的 A13a/A13b (u_rec1/u_rec2 换流后新起帧数 >= 1) 必红,
#   而 A13c (u_rec3 对照臂) 必须**照旧绿** ⇒ 这条变异同时证明判据有牙 + 只咬该咬的。
add("m5_no_uppend", [(
    "            if (up_do) up_pend_r <= 1'b0;\n"
    "            else if (ev_up) begin\n"
    "                up_pend_r  <= 1'b1;\n"
    "                up_pend_id <= ev_slot;\n"
    "            end\n",
    "            if (up_do) up_pend_r <= 1'b0;   // M5: 删掉待补登记 (修前行为)\n",
    1)], "M5 无待补登记 => u_rec1/u_rec2 又静默 (A13a/A13b 必红; A13c 仍绿)")

# ---- M4: 删掉终结判据的 !CONT_OK (连续模式仍会"结束") ----
add("m4_term_open", [(
    "                    if ((remain == 32'd0) && !CONT_OK) begin",
    "                    if (remain == 32'd0) begin    // M4: 删掉 !CONT_OK",
    1)], "M4 终结判据开 => 连续模式也终结 (A1/A2 必红)")


def norm(s):
    """换行归一化: \\r\\n / 单独 \\r 一律成 \\n (幂等)."""
    return s.replace("\r\n", "\n").replace("\r", "\n")


def sha256_bytes(b):
    return hashlib.sha256(b).hexdigest()


def plan(src_lf):
    """只做匹配, 不落盘. 源文本必须已归一化为 LF.
    返回 [(name, subs, note, hits_list)]; hits_list[i] = 第 i 个锚点的实测命中数.
    ⚠️ 命中数一律在**未修改的源文本**上计 (见文件头 (2))."""
    out = []
    for name, subs, note in MUTS:
        out.append((name, subs, note, [src_lf.count(norm(old)) for old, _, _ in subs]))
    return out


def render(src_lf, subs):
    """按 subs 逐条替换, 返回变异件正文 (LF). 调用前必须已核过命中数."""
    t = src_lf
    for old, new, _ in subs:
        t = t.replace(norm(old), norm(new))
    return t


def main(argv):
    dry = ("--dry-run" in argv) or ("--check" in argv)

    raw_bytes = open(SRC, "rb").read()
    src = norm(io.open(SRC, encoding="utf-8", newline="").read())
    ref = sha256_bytes(raw_bytes)
    n_crlf = raw_bytes.count(b"\r\n")
    n_cr = raw_bytes.count(b"\r") - n_crlf
    print("SRC %s  %d B  sha256 %s" % (SRC, len(raw_bytes), ref))
    if n_crlf or n_cr:
        print("NORM: %d CRLF / %d lone CR -> LF (matching + output, 与签出风格无关)"
              % (n_crlf, n_cr))

    results = plan(src)
    fails = []
    for name, subs, note, hits in results:
        want = [e for _, _, e in subs]
        if hits != want:
            for i, (h, e) in enumerate(zip(hits, want), 1):
                if h != e:
                    print("MUTFAIL %s: pattern hits=%d expect=%d" % (name, h, e))
            fails.append(name)

    if dry:
        print("%-18s %-4s %s" % ("mutant", "sub", "hits/expect"))
        for name, subs, note, hits in results:
            for i, ((_, _, e), h) in enumerate(zip(subs, hits), 1):
                print("%-18s s%-3d %d/%d %s" % (name, i, h, e, "" if h == e else "<== MISMATCH"))
            print("%-18s %s" % ("", "USABLE" if hits == [e for _, _, e in subs] else "BROKEN"))
        print("DRYRUN %s (0 bytes written)" % ("OK" if not fails else "FAIL %d" % len(fails)))
        return 0 if not fails else 1

    if fails:
        print("MUTGEN FAIL %d" % len(fails))
        purge(results)
        return 1

    # 源文件在匹配期间被改过 ⇒ 整轮作废 (与"改 RTL / 在跑回归 互斥"同一条纪律)
    now = sha256_bytes(open(SRC, "rb").read())
    if now != ref:
        print("SRC-CHANGED during generation: %s -> %s" % (ref, now))
        print("MUTGEN FAIL 1")
        purge(results)
        return 1

    texts = [(name, note, render(src, subs)) for name, subs, note, _ in results]
    os.makedirs(OUT, exist_ok=True)
    for name, note, text in texts:
        io.open(os.path.join(OUT, name + ".v"), "w", encoding="utf-8", newline="").write(text)
        print("WROTE %-22s %s" % (name, note))

    # 落盘后再核一次 (窗口内被改也作废, 保证落盘集 = 单一已核源修订)
    now = sha256_bytes(open(SRC, "rb").read())
    if now != ref:
        print("SRC-CHANGED after write: %s -> %s" % (ref, now))
        print("MUTGEN FAIL 1")
        purge(results)
        return 1

    n_subs = sum(len(subs) for _, subs, _, _ in results)
    print("ANCHORS: all %d mutants matched (%d subs, each hits==expect)"
          % (len(results), n_subs))
    print("MUTGEN OK (%d mutants)" % len(MUTS))
    return 0


def purge(results):
    """失败路径: 删掉本清单里**已存在的**同名旧件 (只删这些文件名, 不做通配删除).
    理由: mut/ 里同名旧件一定来自**另一个源修订**, 混装 = 静默陈旧证据;
    硬不变式 = mut/ 要么是"本清单的完整已核验一份", 要么是空的."""
    for name, _, _, _ in results:
        p = os.path.join(OUT, name + ".v")
        if os.path.exists(p):
            os.remove(p)
            print("PURGED stale %s" % p)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
