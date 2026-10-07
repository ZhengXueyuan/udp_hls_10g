# -*- coding: utf-8 -*-
"""Stage C 回归: 把矩阵 log 拆成"逐门两列"表 (A = 矩阵日志 gatebrief 尾 / B = 门自己的
work 目录 console 的判据行) + 每门 console 的 grep -i fail 命中数。

用法: python collect_matrix.py <matrix_log> [work_root]
"""
import io
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

VERDICT = re.compile(
    r"(P4 CHAIN OK|BURST OK|PCSTALL OK|PASS_ALL|ALL 7 GROUPS PASS|"
    r"VLAN_STRIP TB PASS|ALL_OK|UART-GATE-OK|"
    r"TB_TCP_TX_OVL: OK|VERDICT = (PASS|FAIL))")
FAILPAT = re.compile(r"fail", re.I)


def read(path):
    with open(path, "rb") as f:
        raw = f.read()
    for enc in ("utf-8", "gbk"):
        try:
            return raw.decode(enc)
        except Exception:
            pass
    return raw.decode("latin-1")


def main():
    log = sys.argv[1]
    work = sys.argv[2] if len(sys.argv) > 2 else None
    txt = read(log)
    gates, cur = [], None
    for line in txt.splitlines():
        m = re.match(r"=== GATE (\S+) : (\S+)(.*?)   \[env (.*?)\]   \[cwd (.*?)\]", line)
        if m:
            cur = {"name": m.group(1), "bat": m.group(2), "env": m.group(4),
                   "cwd": m.group(5), "tail": [], "exit": None}
            gates.append(cur)
            continue
        if cur is None:
            continue
        m = re.match(r"EXIT=(\d+)", line)
        if m:
            cur["exit"] = int(m.group(1))
            continue
        if line.startswith("| "):
            cur["tail"].append(line[2:].rstrip())
        elif "PRECHECK-FAIL" in line:
            cur["tail"].append(line.rstrip())

    print("| # | gate | EXIT | A列(矩阵日志 gatebrief 尾) | B列(门 console 判据行 + fail 计数) |")
    print("|---|---|---|---|---|")
    for i, g in enumerate(gates, 1):
        b = ""
        if work:
            cpath = os.path.join(work, g["name"], "_gate_console.log")
            if os.path.isfile(cpath):
                ct = read(cpath)
                v = [l.strip() for l in ct.splitlines() if VERDICT.search(l)]
                nf = sum(1 for l in ct.splitlines() if FAILPAT.search(l))
                b = " | ".join(v[-3:]) + " ;; grep -i fail hits=%d" % nf
            else:
                b = "(no console)"
        a = " / ".join(g["tail"][-4:])
        print("| %d | `%s` | **%s** | %s | %s |"
              % (i, g["name"], g["exit"], a.replace("|", "\\|"), b.replace("|", "\\|")))

    # 总结行
    print()
    for line in txt.splitlines():
        if re.match(r"(gates run|gates failed|VERDICT:|DIGEST_|FILES_|GIT_HEAD)", line):
            print("    " + line)


if __name__ == "__main__":
    main()
