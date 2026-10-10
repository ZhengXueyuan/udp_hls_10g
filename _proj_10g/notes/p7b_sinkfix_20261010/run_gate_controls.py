#!/usr/bin/env python3
# ===========================================================================
# run_gate_controls.py -- gate_sinkfix.py 的**有牙**对照 (2026-10-10)
#
# 每一条对照都是"gate 必须翻红"的输入 (全局纪律: 每加一条判据配一个该被抓住的反例):
#   P   正对照  = 工作树现件                    期望 RC 0
#   N0  否定对照 = git HEAD 版 (修复前)          期望 RC 1   <- 旧缺陷形态
#   M1  突变    = 两个 guard 对调 (落点翻面)     期望 RC 1
#   M2  突变    = 默认值 true (默认退回旧行为)   期望 RC 1
#   M3  突变    = 删掉见证了 printf 的 5 行      期望 RC 1
#   M4  突变    = 真回退: 调用点换回 connect_to + 旧点位 setsockopt   期望 RC 1
#   M5  突变    = 两臂都塌成"只在 connect 后设"  期望 RC 1
# 全部临时件写在系统 temp 下 (不落仓)。
#
# ---- 2026-10-10 (gate harden) 追加块 (原 7 对照生成逻辑与期望**一字未动**) ----
# 输出前 8 行与 gate_controls.txt 可逐字对 (P/N0/M1..M5 + 旧汇总行)。追加块另起 tmp 目录与
# 独立汇总行 GATE_CONTROLS_HARDEN:
#   红 (RC=1, 且 fired 集合**精确**等于期望 —— 不许"全红"蒙混过关):
#     N0pin 修复前提交 61cc107 (= 历史上被当 N0 用的 aaf17dc 同内容; md5 硬核) => 恰 C1..C10
#     A  REVIEW §D.1 A_unguard_before     => C11
#     C  REVIEW §D.1 C_fix_disabled_if0   => C11
#     B2 REVIEW §D.1 B2_witness_const_ternDEAD => C12
#     F  REVIEW §D.1 F_forces_fixed_arm   => C13
#     E1 同族加成: 旧臂被 `if (0)` 套住           => C11
#     P1 同族加成: `#if 0` 把修复整段静默禁用      => C14
#     Y1 同族加成: SO_RCVBUF -> SO_RCVBUFFORCE    => C11 (C3 的子串判据抓不到)
#   绿 (RC=0, fired 空 —— 等价小改不许被新判据误伤):
#     G1 加注释/空行 · G2 见证 printf 重排行 · G3 guard 体加花括号 ·
#     G4 加无害 include · G5 = G2+G3 合成
#   已知逃逸探针 (登记, **期望 RC=0 即"仍逃逸"**, 不是故障):
#     X1 goto 绕过 (结构完好、修复不可达) —— 本门判结构, 不判可达性
#
# 用法: python run_gate_controls.py
# 退出码: 0 = 全部对照按期望; 1 = 有对照不符 (含追加块); 9 = 追加块前置拒跑 (锚点漂移)
# ===========================================================================
import hashlib
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
GATE = os.path.join(HERE, "gate_sinkfix.py")
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))          # = udp_hls_10g
NEW = os.path.join(REPO, "_proj_pcie", "p7b_biz", "p7b_tcp_sink.cpp")
RELPATH = "_proj_pcie/p7b_biz/p7b_tcp_sink.cpp"


def run_gate(path):
    p = subprocess.run([sys.executable, GATE, path], capture_output=True, text=True)
    fired = [ln.split()[0] for ln in p.stdout.splitlines() if " VIOLATION " in ln]
    return p.returncode, fired, p.stdout


def mutant_swap_guards(s):
    t = s.replace("if (!rcvbuf_after_connect)", "if (__SWAP__)", 1)
    t = t.replace("if (rcvbuf_after_connect)", "if (!rcvbuf_after_connect)", 1)
    t = t.replace("if (__SWAP__)", "if (rcvbuf_after_connect)", 1)
    return t


def mutant_default_true(s):
    return s.replace("bool rcvbuf_after_connect = false;",
                     "bool rcvbuf_after_connect = true;", 1)


def mutant_drop_witness(s):
    i = s.find("    // ⭐⭐ 2026-10-10 (sinkfix) 见证行")
    if i < 0:
        i = s.find('    printf("SINK_RCVBUF_ORDER')
        if i < 0:
            return s
    j = s.find('fflush(stdout);', i)
    j = s.find("\n", j)
    return s[:i] + s[j + 1:]


def mutant_true_revert(s):
    t = s.replace("int fd = sink_connect_rcvbuf(host, port, 5, rcvbuf, rcvbuf_after_connect, &why);",
                  "int fd = p7b_io_connect_to(host, port, 5, &why);", 1)
    t = t.replace("        if (c == 0) first_conn_at = t1;",
                  "        if (c == 0) first_conn_at = t1;\n"
                  "        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));", 1)
    return t


def mutant_both_arms_late(s):
    t = s.replace("if (!rcvbuf_after_connect)", "if (0)", 1)
    t = t.replace("if (rcvbuf_after_connect)", "if (1)", 1)
    return t


# ===========================================================================
# 2026-10-10 (gate harden) 追加块 —— 生成器与驱动器
#   突变件全部生成在 %TEMP% (不落仓); 每个生成器找不到锚点就**抛异常**(不许静默 no-op,
#   否则"突变没落上"会被读成"门有牙")。
# ===========================================================================
_CALL = "setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));"
_CALLSITE = "        int fd = sink_connect_rcvbuf(host, port, 5, rcvbuf, rcvbuf_after_connect, &why);"
PIN_N0 = "61cc107"                              # 修复提交 a03d227 的父 (= 历史 aaf17dc 同内容)
PIN_N0_MD5 = "5b6d757b17ed9b49db77c34494319264"  # 与 REVIEW.md 附录记录的历史值一致


def _must(s, old, new, n=1):
    c = s.count(old)
    if c != n:
        raise RuntimeError("anchor count=%d (want %d) for %r" % (c, n, old[:60]))
    return s.replace(old, new, n)


def _append_code(line, suffix):
    """在注释之前追加代码 (否则后缀会落进 `//` 注释里 = 突变静默失效)。"""
    code, sep, cmt = line.partition("//")
    return code.rstrip() + suffix + (("   " + sep + cmt) if sep else "")


def _edit_guard_pair(s, guard_sub, new_lines):
    """把'含 guard_sub 的行 + 下一行(SO_RCVBUF setsockopt)'整体换成 new_lines。"""
    lines = s.split("\n")
    for k in range(len(lines) - 1):
        if guard_sub in lines[k] and _CALL in lines[k + 1]:
            return "\n".join(lines[:k] + new_lines + lines[k + 2:])
    raise RuntimeError("anchor pair not found for %r" % guard_sub)


def mutant_A_unguard_before(s):
    """REVIEW §D.1 A: guard 体变空语句 `;`, setsockopt 变无条件 (仍在 connect 之前)。
    默认臂看着照旧, 但**旧臂也变成"connect 前设"** (旧臂不再保真), 而见证行照打 LEGACY。"""
    lines = s.split("\n")
    for k in range(len(lines) - 1):
        if "if (!rcvbuf_after_connect)" in lines[k] and _CALL in lines[k + 1]:
            return "\n".join(lines[:k] + [lines[k], "        ;", "    " + lines[k + 1].strip()]
                             + lines[k + 2:])
    raise RuntimeError("anchor not found: unguard_before")


def mutant_C_fix_disabled_if0(s):
    """REVIEW §D.1 C: `if (!rcvbuf_after_connect) { if (0) setsockopt(…); }` => 修复被静默禁用。"""
    lines = s.split("\n")
    for k in range(len(lines) - 1):
        if "if (!rcvbuf_after_connect)" in lines[k] and _CALL in lines[k + 1]:
            return "\n".join(lines[:k] + [_append_code(lines[k], " {"), "        if (0)",
                                          lines[k + 1], "    }"] + lines[k + 2:])
    raise RuntimeError("anchor not found: fix_disabled_if0")


def mutant_B2_witness_const_ternDEAD(s):
    """REVIEW §D.1 B2: 见证 printf 打常量, 三元字面量留在 `if (0) {…}` 死码里 (C7 的 in src 抓不到)。"""
    lines = s.split("\n")
    for k, ln in enumerate(lines):
        if 'printf("SINK_RCVBUF_ORDER' in ln:
            j = k + 1
            while j < len(lines) and not lines[j].rstrip().endswith(");"):
                j += 1
            if j >= len(lines):
                raise RuntimeError("witness printf tail not found")
            dead = ('    if (0) { const char *dead_arm = rcvbuf_after_connect ? '
                    '"after_connect_LEGACY" : "before_connect"; (void)dead_arm; }')
            live = ('    printf("SINK_RCVBUF_ORDER RCVBUF_ORDER=%s rcvbuf=%d\\n", '
                    '"before_connect", rcvbuf);')
            return "\n".join(lines[:k] + [dead, live] + lines[j + 1:])
    raise RuntimeError("witness printf not found")


def mutant_F_forces_fixed_arm(s):
    """REVIEW §D.1 F: 调用点前插一行 `rcvbuf_after_connect = false;` => 开关永不生效。"""
    return _must(s, _CALLSITE, "        rcvbuf_after_connect = false;\n" + _CALLSITE)


def mutant_E1_legacy_arm_if0(s):
    """同族加成 (审查未点名): 旧臂被 `if (0)` 套住 => 旧臂 setsockopt 静默消失。"""
    lines = s.split("\n")
    for k in range(len(lines) - 1):
        if "if (rcvbuf_after_connect)" in lines[k] and _CALL in lines[k + 1]:
            return "\n".join(lines[:k] + [_append_code(lines[k], " {"), "        if (0)",
                                          lines[k + 1], "    }"] + lines[k + 2:])
    raise RuntimeError("anchor not found: legacy_arm_if0")


def mutant_P1_preproc_if0(s):
    """同族加成: `#if 0` 把修复整段静默禁用 (token 全在, 编译期消失)。"""
    lines = s.split("\n")
    for k in range(len(lines) - 1):
        if "if (!rcvbuf_after_connect)" in lines[k] and _CALL in lines[k + 1]:
            return "\n".join(lines[:k] + ["#if 0", lines[k], lines[k + 1], "#endif"]
                             + lines[k + 2:])
    raise RuntimeError("anchor not found: preproc_if0")


def mutant_Y1_rcvbufforce(s):
    """同族加成: SO_RCVBUF -> SO_RCVBUFFORCE (C3 的 `"SO_RCVBUF" in ln` 子串判据抓不到)。"""
    if s.count(_CALL) != 2:
        raise RuntimeError("SO_RCVBUF setsockopt count=%d (want 2)" % s.count(_CALL))
    return s.replace("SO_RCVBUF, &rcvbuf", "SO_RCVBUFFORCE, &rcvbuf", 1)


def mutant_G1_comments_blank(s):
    """应当绿: 只在 3 处加注释/空行 (语义一字不变)。"""
    t = _must(s, "#include <vector>\n",
              "#include <vector>\n\n// (G1) 等价小改: 加注释 + 空行 (语义不变)\n")
    t = _must(t, "static int sink_connect_rcvbuf(",
              "// (G1) 等价小改: helper 之前的注释\nstatic int sink_connect_rcvbuf(")
    t = _must(t, '    printf("SINK_CHECK check=%s\\n", p7b_check_mode_name());',
              '    // (G1) 等价小改: 见证行之前的注释\n\n'
              '    printf("SINK_CHECK check=%s\\n", p7b_check_mode_name());')
    return t


def mutant_G2_witness_reformat(s):
    """应当绿: 见证 printf 重排行 (三元逐字保持单行, 满足 C7 的既有字面量判据)。"""
    old = ('    printf("SINK_RCVBUF_ORDER RCVBUF_ORDER=%s rcvbuf=%d\\n",\n'
           '           rcvbuf_after_connect ? "after_connect_LEGACY" : "before_connect", rcvbuf);')
    new = ('    printf(\n'
           '        "SINK_RCVBUF_ORDER RCVBUF_ORDER=%s rcvbuf=%d\\n",\n'
           '        rcvbuf_after_connect ? "after_connect_LEGACY" : "before_connect",\n'
           '        rcvbuf);')
    return _must(s, old, new)


def mutant_G3_braces(s):
    """应当绿: guard 体加一对配对花括号 (C 语言里语义等价)。"""
    lines = s.split("\n")
    for k in range(len(lines) - 1):
        if "if (!rcvbuf_after_connect)" in lines[k] and _CALL in lines[k + 1]:
            return "\n".join(lines[:k] + [_append_code(lines[k], " {"), lines[k + 1], "    }"]
                             + lines[k + 2:])
    raise RuntimeError("anchor not found: braces")


def mutant_G4_add_include(s):
    """应当绿: 加一行无害 include (证明 C14 不是"凡 `#` 就红")。"""
    return _must(s, "#include <vector>\n",
                 "#include <vector>\n#include <stdint.h>   // (G4) 等价小改: 无害 include\n")


def mutant_G5_braces_and_reformat(s):
    """应当绿: G3 + G2 合成 (判据交互)。"""
    return mutant_G2_witness_reformat(mutant_G3_braces(s))


def mutant_X1_goto_skip(s):
    """已知逃逸探针 (对抗形状, **不是**疏忽形状): 结构完好, 但 goto 让修复不可达。
    期望 RC=0 (仍逃逸) —— 本门判结构/同源, 不判可达性 (作用域已在 gate 头注释声明)。"""
    t = _must(s, "    p7b_io_set_nonblock(fd);",
              "    p7b_io_set_nonblock(fd);\n    goto x_skip_before_fix;   // (X1) 结构完好但不可达")
    t = _must(t, "sizeof(rcvbuf));\n    if (p7b_io_connect_nb(",
              "sizeof(rcvbuf));\n    x_skip_before_fix:\n    if (p7b_io_connect_nb(")
    return t


def run_harden_controls(new_src):
    """加固轮追加块驱动器: 返回 mismatch 数 (0 = 全部按期望; 9 = 前置拒跑)。"""
    tmp = tempfile.mkdtemp(prefix="sinkfix_gate_harden_")

    def run_gate_h(path):
        """与既有 run_gate 隔离的 runner: 显式 UTF-8 双向 (子进程 PYTHONIOENCODING=utf-8,
        父进程 encoding='utf-8' + errors='replace') ⇒ 不受本机控制台编码影响.
        ⚠️ 既有 run_gate (前 7 条对照用) 一字未动 —— 它在环境变量 PYTHONIOENCODING=utf-8
        时会因子/父编码不一致而 UnicodeDecodeError (既存脆性, 本机默认环境不触发)."""
        env = dict(os.environ)
        env["PYTHONIOENCODING"] = "utf-8"
        p = subprocess.run([sys.executable, GATE, path], capture_output=True, text=True,
                           encoding="utf-8", errors="replace", env=env)
        fired = [ln.split()[0] for ln in p.stdout.splitlines() if " VIOLATION " in ln]
        return p.returncode, fired, p.stdout

    pin = subprocess.run(["git", "-C", REPO, "show", PIN_N0 + ":" + RELPATH],
                         capture_output=True)
    if pin.returncode != 0:
        sys.stderr.write("[HARDEN] git show %s 失败: %s\n"
                         % (PIN_N0, pin.stderr.decode("utf-8", "replace")))
        return 9
    pin_md5 = hashlib.md5(pin.stdout).hexdigest()
    if pin_md5 != PIN_N0_MD5:
        sys.stderr.write("[HARDEN] 拒跑: %s 的 .cpp md5=%s != 历史 %s => 不许拿错件当对照\n"
                         % (PIN_N0, pin_md5, PIN_N0_MD5))
        return 9
    pin_src = pin.stdout.decode("utf-8")

    head = subprocess.run(["git", "-C", REPO, "show", "HEAD:" + RELPATH], capture_output=True)
    head_md5 = hashlib.md5(head.stdout).hexdigest() if head.returncode == 0 else "n/a"
    print("[HARDEN-NOTE] legacy N0 anchor drifted: git show HEAD:<file> md5=%s (post-fix) != historical %s (pre-fix)"
          % (head_md5, PIN_N0_MD5))
    print("[HARDEN-NOTE]   => in-script N0 is now equivalent to P (RC=0); this run did NOT touch it (dispatch: no edits to the first 7)")
    print("[HARDEN-NOTE]   => compensation = appended N0pin case (pinned to pre-fix commit %s, md5 verified)" % PIN_N0)

    OLD10 = ("C1", "C2", "C3", "C4", "C5", "C6", "C7", "C8", "C9", "C10")
    hcases = [
        ("N0pin pre_fix_61cc107", pin_src, 1, OLD10),
        ("A_unguard_before", mutant_A_unguard_before(new_src), 1, ("C11",)),
        ("C_fix_disabled_if0", mutant_C_fix_disabled_if0(new_src), 1, ("C11",)),
        ("B2_witness_const_ternDEAD", mutant_B2_witness_const_ternDEAD(new_src), 1, ("C12",)),
        ("F_forces_fixed_arm", mutant_F_forces_fixed_arm(new_src), 1, ("C13",)),
        ("E1_legacy_arm_if0", mutant_E1_legacy_arm_if0(new_src), 1, ("C11",)),
        ("P1_preproc_if0", mutant_P1_preproc_if0(new_src), 1, ("C14",)),
        ("Y1_rcvbufforce", mutant_Y1_rcvbufforce(new_src), 1, ("C11",)),
        ("G1 comments_blank", mutant_G1_comments_blank(new_src), 0, ()),
        ("G2 witness_reformat", mutant_G2_witness_reformat(new_src), 0, ()),
        ("G3 braces_around_body", mutant_G3_braces(new_src), 0, ()),
        ("G4 add_include", mutant_G4_add_include(new_src), 0, ()),
        ("G5 braces+reformat", mutant_G5_braces_and_reformat(new_src), 0, ()),
        ("X1_goto_skip KNOWN-ESCAPE", mutant_X1_goto_skip(new_src), 0, ()),
    ]
    print("---- harden block: 4 escapees + same-family bonuses (want RED) / equivalent edits (want GREEN) / known-escape probe ----")
    bad = 0
    for name, src, want_rc, want_fired in hcases:
        p = os.path.join(tmp, name.split()[0] + ".cpp")
        with open(p, "w", encoding="utf-8", newline="") as f:
            f.write(src)
        rc, fired, out = run_gate_h(p)
        ok = (rc == want_rc) and (tuple(fired) == tuple(want_fired))
        print("%-30s RC=%d want=%d %s fired=%s want_fired=%s" % (
            name, rc, want_rc, "OK" if ok else "MISMATCH",
            ",".join(fired) if fired else "-",
            ",".join(want_fired) if want_fired else "-"))
        if not ok:
            bad += 1
            print(out)
    print("GATE_CONTROLS_HARDEN cases=%d mismatch=%d tmp=%s" % (len(hcases), bad, tmp))
    return bad


def main():
    with open(NEW, "r", encoding="utf-8", newline="") as f:
        new_src = f.read()
    old = subprocess.run(["git", "-C", REPO, "show", "HEAD:" + RELPATH],
                         capture_output=True)
    if old.returncode != 0:
        sys.stderr.write("git show 失败: %s\n" % old.stderr.decode("utf-8", "replace"))
        return 2
    old_src = old.stdout.decode("utf-8")

    tmp = tempfile.mkdtemp(prefix="sinkfix_gate_")
    cases = [
        ("P  working_tree_now", new_src, 0),
        ("N0 HEAD_version_pre_fix", old_src, 1),
        ("M1 guards_swapped", mutant_swap_guards(new_src), 1),
        ("M2 default_true", mutant_default_true(new_src), 1),
        ("M3 witness_removed", mutant_drop_witness(new_src), 1),
        ("M4 true_revert", mutant_true_revert(new_src), 1),
        ("M5 both_arms_late", mutant_both_arms_late(new_src), 1),
    ]
    bad = 0
    for name, src, want in cases:
        p = os.path.join(tmp, name.split()[0] + ".cpp")
        with open(p, "w", encoding="utf-8", newline="") as f:
            f.write(src)
        rc, fired, out = run_gate(p)
        ok = (rc == want)
        print("%-26s RC=%d want=%d %s fired=%s" %
              (name, rc, want, "OK" if ok else "MISMATCH", ",".join(fired) if fired else "-"))
        if not ok:
            bad += 1
            print(out)
    print("GATE_CONTROLS cases=%d mismatch=%d tmp=%s" % (len(cases), bad, tmp))
    # ---- 2026-10-10 (gate harden) 追加块 (上面 7 条的生成/期望一字未动; 见文件头注释) ----
    bad_h = run_harden_controls(new_src)
    if bad_h:
        return 1 if bad_h != 9 else 9
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
