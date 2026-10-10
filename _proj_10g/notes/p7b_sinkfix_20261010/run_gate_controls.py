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
# 用法: python run_gate_controls.py
# 退出码: 0 = 全部对照按期望; 1 = 有对照不符
# ===========================================================================
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
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
