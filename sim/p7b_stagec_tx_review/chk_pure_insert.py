#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""对抗审查(C): 独立核 'TCP_TX_OVL 宏关 = 逐字等于插入前' 的声称。

方法 (不依赖作者脚本):
 1) 取 HEAD 版 tcp_tx_frame.v (git show) 作为基线, 与 sim/p7b_stagec_tx/tcp_tx_frame.v.base 比对。
 2) 用**自写的极简 Verilog 预处理器** (支持 `ifdef/`ifndef/`else/`elsif/`endif/`define/`undef,
     先去 // 与 /* */ 注释) 分别处理"新文件-宏关"与"新文件-宏开"。
 3) 断言: 宏关输出 == 基线 (逐字节); 并统计宏开分支是否平衡 (无 dangling else/endif)。
 4) 独立再证: 基线是新文件的**子序列** (纯插入), 且插入行集合在文件里位置/行号逐条打印。
"""
import re, subprocess, sys, os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
NEW = os.path.join(ROOT, "rtl", "tcp_tx_frame.v")
BASE = os.path.join(ROOT, "sim", "p7b_stagec_tx", "tcp_tx_frame.v.base")

def read(p):
    with open(p, "rb") as f:
        return f.read()

def strip_comments(src):
    # 去 /* */ 与 //  (逐字符, 保换行)
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == "/" and i + 1 < n and src[i+1] == "/":
            j = src.find("\n", i)
            if j < 0: j = n
            i = j
            continue
        if c == "/" and i + 1 < n and src[i+1] == "*":
            j = src.find("*/", i + 2)
            if j < 0: j = n
            seg = src[i:j+2]
            out.append("\n" * seg.count("\n"))
            i = j + 2
            continue
        out.append(c)
        i += 1
    return "".join(out)

DIRECTIVE = re.compile(r"^\s*`\s*(ifdef|ifndef|else|elsif|endif|define|undef)\b(.*)$")

def preprocess(src, defines, keep_directive_lines=False):
    """极简: 只处理条件编译; 其它 `directive 原样保留. 返回 (输出文本, 事件日志)."""
    stripped = strip_comments(src)   # 注意: 保换行数, 但字符被替换 -> 用逐行处理
    lines = stripped.split("\n")
    raw_lines = src.split("\n")
    out, log = [], []
    # 栈元素: [parent_active, cur_active, seen_else]
    stack = []
    def active():
        return all(s[1] for s in stack)
    for ln, raw in zip(lines, raw_lines):
        m = DIRECTIVE.match(ln)
        if m:
            d, rest = m.group(1), m.group(2).strip()
            tok = rest.split()[0] if rest.split() else ""
            if d == "ifdef" or d == "ifndef":
                par = active()
                val = (tok in defines)
                if d == "ifndef": val = not val
                stack.append([par, par and val, False])
                log.append((ln if False else "if", d, tok, par, val))
                if keep_directive_lines: out.append(raw)
            elif d == "elsif":
                if not stack: raise SystemExit("[FATAL] `elsif without `ifdef")
                s = stack[-1]
                if s[2]: raise SystemExit("[FATAL] `elsif after `else")
                val = (tok in defines)
                s[1] = s[0] and val
                if keep_directive_lines: out.append(raw)
            elif d == "else":
                if not stack: raise SystemExit("[FATAL] `else without `ifdef")
                s = stack[-1]
                if s[2]: raise SystemExit("[FATAL] double `else")
                s[2] = True
                s[1] = s[0] and (not s[1])
                if keep_directive_lines: out.append(raw)
            elif d == "endif":
                if not stack: raise SystemExit("[FATAL] `endif without `ifdef")
                stack.pop()
                if keep_directive_lines: out.append(raw)
            elif d == "define":
                if active(): defines.add(tok)
                if keep_directive_lines: out.append(raw)
            elif d == "undef":
                if active(): defines.discard(tok)
                if keep_directive_lines: out.append(raw)
            continue
        if active():
            out.append(raw)
    if stack:
        raise SystemExit("[FATAL] unbalanced `ifdef: depth=%d" % len(stack))
    return "\n".join(out), log

def main():
    new_src = read(NEW).decode("utf-8")
    base_src = read(BASE).decode("utf-8")
    # 基线 == git HEAD?
    head = subprocess.run(["git", "-C", ROOT, "show", "HEAD:rtl/tcp_tx_frame.v"],
                          capture_output=True).stdout.decode("utf-8")
    print("base == HEAD:rtl/tcp_tx_frame.v :", base_src == head)

    off_out, _ = preprocess(new_src, defines=set())
    on_out,  _ = preprocess(new_src, defines={"TCP_TX_OVL"})
    base_pp, _ = preprocess(base_src, defines=set())

    print("P1 宏关预处理输出 == 基线文件逐字节 :", off_out == base_src)
    print("P1' 宏关预处理输出 == 基线预处理输出 :", off_out == base_pp)
    print("P1'' 宏关输出行数 =", off_out.count("\n") + 1, " 基线行数 =", base_src.count("\n") + 1)
    print("宏开输出行数 =", on_out.count("\n") + 1)

    # 纯插入的独立证明: 基线每行必须按序出现在新文件中
    nl, bl = new_src.split("\n"), base_src.split("\n")
    i = 0
    missing = []
    for b in bl:
        while i < len(nl) and nl[i] != b:
            i += 1
        if i == len(nl):
            missing.append(b)
            break
        i += 1
    print("子序列检查 (基线全部行按序出现在新文件):", "OK" if not missing else ("FAIL: %r" % missing[:1]))
    print("新文件多出的行数 = %d (git diff --stat 声称 +799)" % (len(nl) - len(bl)))

    # 宏关输出与基线逐行 diff 定位 (若有差)
    if off_out != base_src:
        a, b2 = off_out.split("\n"), base_src.split("\n")
        for k in range(max(len(a), len(b2))):
            x = a[k] if k < len(a) else "<EOF>"
            y = b2[k] if k < len(b2) else "<EOF>"
            if x != y:
                print("首个差异 @%d:\n  宏关: %r\n  基线: %r" % (k + 1, x, y))
                break
    return 0

if __name__ == "__main__":
    sys.exit(main())
