#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""s2_equiv_persist.py -- P7B-PERSIST 设计件 §7.2-S2 的**等价门** (2026-10-11 建).

背景 (问题 P-6): 设计件 §7.2-S2 要求"实施轮先建此门 + 负对照（拿 118 KB 旧锚当被测件必红）"。
本仓此前**只有冻锚没有门** (`grep -rl revcfd3b1a` = 0 命中, 锚是死资产)。本脚本就是那扇门。

两条腿 (全部**只读**; 零 xsim / 零 Vivado / 零板卡; 只用 sha256 与逐行比对):

  [L-A] 锚的**出处完整性** (sha256 比对于 git 对象):
        `frozen/tcp_tx_frame_revcfd3b1a.v` 去 CR 后的 sha256 必须 == `git show cfd3b1a:rtl/tcp_tx_frame.v`
        的 sha256。⚠️ 仓内对象是 LF、checkout 因 `core.autocrlf=true` 落成 CRLF ⇒ 比对前统一去 CR
        (这也解释了 142,733 B(CRLF checkout) vs 140,501 B(LF blob) 的差: 差 = 2232 个 CR)。
        负对照 (--selfcheck): 拿 **118 KB 旧锚** `frozen/tcp_tx_frame_rev1a1f0439.v` 代入必须**不相等**。

  [L-B] L2 行为等价的**机器化核对** (形态 = 设计件 §7.2"相差集必须恰为指定产物 + 统计件去指定行后全同"):
        取 **现成的一对日志** —— `_proj_10g/notes/p7b_persist_impl/base/xs_runB_baseline.log`(改前)
        vs `ev/xs_runB_after.log`(改后, 臂 B = TCP_TX_OVL + PERSIST_EN=0), 断言三条:
          ① 原始两份**必须不同** (否则本条是空判据);
          ② 去"指定元数据行"后两份**逐字节全同** (sha256 相等);
          ③ 每一条原始差异行都必须命中"指定元数据类" (逐行分类, 无一条例外)。
        指定元数据类 = 时间戳 / PID / 可用内存 / hostname / `$finish` 行号 / 退出时间戳 / 仿真器版本行
        (harness 元数据; 判据读数不在此列 —— 它们必须逐字相同)。
        负对照 (--selfcheck): (B-neg1) 换一条**别的臂**的日志当对端 (`ev/orS_oracle_xs.log`) ⇒ 必须红;
                              (B-neg2) 在临时副本里注入一行**非指定类**差异 ⇒ 必须红。

口径纪律 (与工程纪律同族):
  · 判据的锚 = **提交 sha + 内容 sha256** (不钉 HEAD 这类会漂的坐标);
  · 判据自己也要有对照 ⇒ 三条负对照都必须"该红时红";
  · 本门**不判** RTL 行为对不对, 只判"锚的出处"与"给定日志对的差异集被枚举穷尽"。

退出码: 0 = 两条腿全过 (含非空判据); 1 = 有腿失败。
用法:
  python s2_equiv_persist.py               # 正式跑
  python s2_equiv_persist.py --selfcheck   # 三条负对照 (全部必须红)
"""
import difflib
import hashlib
import io
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))

# ---- 钉死的坐标 (提交 sha, 不是 HEAD) ----
ANCHOR_REV = "cfd3b1a"                       # persist 刀的"改前"锚提交
ANCHOR_PATH = os.path.join(ROOT, "sim", "p7b_stagec_tx_regress", "frozen",
                           "tcp_tx_frame_revcfd3b1a.v")
OLD_ANCHOR_PATH = os.path.join(ROOT, "sim", "p7b_stagec_tx_regress", "frozen",
                               "tcp_tx_frame_rev1a1f0439.v")   # 118,054 B 旧锚 (负对照用)
GIT_PATH = "rtl/tcp_tx_frame.v"

# ---- L2 日志对 (臂 B: TCP_TX_OVL + PERSIST_EN=0) ----
LOG_BEFORE = os.path.join(ROOT, "_proj_10g", "notes", "p7b_persist_impl",
                          "base", "xs_runB_baseline.log")
LOG_AFTER = os.path.join(ROOT, "_proj_10g", "notes", "p7b_persist_impl",
                         "ev", "xs_runB_after.log")
LOG_OTHER = os.path.join(ROOT, "_proj_10g", "notes", "p7b_persist_impl",
                         "ev", "orS_oracle_xs.log")            # 别的臂 (负对照用)

# ---- "指定元数据类" (harness 元数据; 逐行匹配, 用 search 不用 fullmatch) ----
DESIGNATED = [
    (r"^#\s*Start of session at\s*:", "时间戳-start"),
    (r"^#\s*Process ID\s*:", "PID"),
    (r"^#\s*Available Virtual\s*:", "可用内存-Virtual"),
    (r"^#\s*Available Physical\s*:", "可用内存-Physical"),
    (r"^#\s*Total Available Memory\s*:", "可用内存-Total"),
    (r"^#\s*Hostname\s*:", "hostname"),
    (r"^\$finish called at time\s*:", "finish-行号"),
    (r"^INFO:\s*\[Common 17-206\]\s*Exiting xsim at", "退出时间戳"),
    (r"^#\s*xsim\b.*version", "sim-版本"),
]


def sha256(b):
    return hashlib.sha256(b).hexdigest()


def read_bytes(path):
    with io.open(path, "rb") as f:
        return f.read()


def designated_class(line):
    for pat, name in DESIGNATED:
        if re.search(pat, line):
            return name
    return None


def split_lines(text):
    """按 \\n 切, 返回带行尾的原行列表 (以 '\\n' keepends 切). 去 CR 后比较。"""
    return [l.replace("\r", "") for l in text.splitlines(True)]


def raw_diff_lines(a_lines, b_lines):
    """返回原始差异行列表 (difflib, n=0; 只取 +/- 行, 去头)。"""
    out = []
    for l in difflib.unified_diff(a_lines, b_lines, lineterm="", n=0):
        if l.startswith("---") or l.startswith("+++") or l.startswith("@@"):
            continue
        if l[:1] in "+-":
            out.append(l)
    return out


def leg_a(anchor_path, rev=ANCHOR_REV):
    """返回 (ok, 说明行 list)."""
    msgs = []
    if not os.path.exists(anchor_path):
        return False, ["[L-A] 锚文件不存在: %s" % anchor_path]
    anchor_b = read_bytes(anchor_path).replace(b"\r", b"")
    out = subprocess.run(["git", "show", "%s:%s" % (rev, GIT_PATH)],
                         cwd=ROOT, capture_output=True)
    if out.returncode != 0:
        return False, ["[L-A] git show 失败: " + out.stderr.decode("utf-8", "replace")]
    git_b = out.stdout
    a_sha, g_sha = sha256(anchor_b), sha256(git_b)
    ok = (a_sha == g_sha)
    msgs.append("[L-A] 锚 = %s" % os.path.basename(anchor_path))
    msgs.append("      anchor(LF-normalized, %d B) sha256 = %s" % (len(anchor_b), a_sha))
    msgs.append("      git show %s:%s (%d B)     sha256 = %s" % (rev, GIT_PATH, len(git_b), g_sha))
    msgs.append("[L-A] %s" % ("PASS (锚的出处 = 钉死提交 %s, 逐字节)" % rev if ok
                              else "FAIL (锚与 git 对象不一致)"))
    return ok, msgs


def leg_b(before_path, after_path, corrupt=False):
    """返回 (ok, 说明行 list, body_sha). corrupt=True 时注入一行非指定类差异 (负对照 B-neg2)。"""
    msgs = []
    for p in (before_path, after_path):
        if not os.path.exists(p):
            return False, ["[L-B] 日志不存在: %s" % p], None
    a_raw = io.open(before_path, encoding="utf-8", errors="replace", newline="").read()
    b_raw = io.open(after_path, encoding="utf-8", errors="replace", newline="").read()
    if corrupt:
        b_raw = b_raw.replace("TB_TCP_TX_OVL:", "TB_TCP_TX_OVL_CORRUPTED:")
    a_lines, b_lines = split_lines(a_raw), split_lines(b_raw)

    # ① 非空判据: 原始两份必须不同
    diff_raw = raw_diff_lines(a_lines, b_lines)
    if len(diff_raw) == 0:
        return False, ["[L-B] **空判据**: 两份日志原始逐字节相同 ⇒ 本腿无判别力 (拒绝)"], None

    # ③ 每条差异行必须命中"指定元数据类"
    bad = [l for l in diff_raw if designated_class(l[1:]) is None]
    ok3 = (len(bad) == 0)

    # ② 去指定行后逐字节全同
    def strip_designated(lines):
        return "".join(l for l in lines if designated_class(l) is None)
    a_body, b_body = strip_designated(a_lines), strip_designated(b_lines)
    body_sha_a, body_sha_b = sha256(a_body.encode("utf-8")), sha256(b_body.encode("utf-8"))
    ok2 = (body_sha_a == body_sha_b)

    kinds = {}
    for l in diff_raw:
        c = designated_class(l[1:])
        kinds[c] = kinds.get(c, 0) + 1
    msgs.append("[L-B] 对 = %s  <->  %s" % (os.path.basename(before_path), os.path.basename(after_path)))
    msgs.append("      原始差异行 = %d 条; 逐类 = %s" % (len(diff_raw), kinds))
    msgs.append("      去指定行后 sha256: before=%s after=%s" % (body_sha_a[:16], body_sha_b[:16]))
    if not ok3:
        for l in bad[:6]:
            msgs.append("      [越界差异] %s" % l.strip()[:100])
    msgs.append("[L-B] ①差异非空: %s  ②去指定行全同: %s  ③差异全属指定类: %s"
                % (len(diff_raw) > 0, ok2, ok3))
    return (ok2 and ok3), msgs, body_sha_a


def main():
    selfcheck = "--selfcheck" in sys.argv
    print("=" * 74)
    print("P7B-PERSIST S2 等价门 (锚出处 L-A / 日志对去指定行 L-B)"
          + ("  [SELFCHECK]" if selfcheck else ""))
    print("  L1 之外的独立门; 只读; 零 xsim / 零 Vivado")
    print("=" * 74)

    if not selfcheck:
        ok_a, msg_a = leg_a(ANCHOR_PATH)
        for m in msg_a:
            print(m)
        ok_b, msg_b, _ = leg_b(LOG_BEFORE, LOG_AFTER)
        print("")
        for m in msg_b:
            print(m)
        ok = ok_a and ok_b
        print("\n" + "=" * 74)
        print("S2_EQUIV_PERSIST: %s" % ("PASS" if ok else "FAIL"))
        return 0 if ok else 1

    # ---------------- selfcheck: 三条负对照, 全部必须红 ----------------
    teeth = True
    print("[NEG-A] 拿 118 KB 旧锚当被测件 (必须 FAIL):")
    ok_a, msg_a = leg_a(OLD_ANCHOR_PATH)
    print("      => %s" % ("红 ✓" if not ok_a else "**没红 (无牙)**"))
    teeth &= (not ok_a)

    print("\n[NEG-B1] 换别的臂的日志当对端 (必须 FAIL):")
    ok_b1, msg_b1, _ = leg_b(LOG_BEFORE, LOG_OTHER)
    for m in msg_b1[-1:]:
        print("      " + m)
    print("      => %s" % ("红 ✓" if not ok_b1 else "**没红 (无牙)**"))
    teeth &= (not ok_b1)

    print("\n[NEG-B2] 注入一行非指定类差异 (必须 FAIL):")
    ok_b2, msg_b2, _ = leg_b(LOG_BEFORE, LOG_AFTER, corrupt=True)
    for m in msg_b2[-2:]:
        print("      " + m)
    print("      => %s" % ("红 ✓" if not ok_b2 else "**没红 (无牙)**"))
    teeth &= (not ok_b2)

    print("\n" + "=" * 74)
    print("S2 等价门自检: %s" % ("三条负对照都有牙" if teeth else "**某处没牙**"))
    return 0 if teeth else 1


if __name__ == "__main__":
    sys.exit(main())
