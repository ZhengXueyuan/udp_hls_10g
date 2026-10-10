#!/usr/bin/env python3
# ===========================================================================
# gate_sinkfix.py -- sinkfix 的**本机**结构性自检 (2026-10-10)
#
# 为什么是这个形态 (而不是"跑起来看窗口"): 本机是 Windows ——
#   (a) 没有可用的 Linux/POSIX 工具链 (Git Bash 无 g++; C:\msys64 只有 MinGW-w64,
#       缺 sys/socket.h/arpa/inet.h/poll.h/pthread.h, 且其 g++/cc1plus 实测连平凡
#       文件都失败) => 编不了这份 Linux 目标件;
#   (b) 即使编了, 首窗通告是**内核**行为, Windows 栈的读数不构成对 Linux 台架的判据。
#   => **行为判据必须在对端 Linux 上跑 (tcpdump 看 SYN/首个 ACK 的 win), 见 REPORT §4**;
#      本脚本是**本机可跑**的那一层: 它判"源码结构里那条修复是否真的在位、且回退会被抓住"。
#
# ⛔⛔ 本门的**作用域声明** (2026-10-10 加固轮落笔; 照抄到 GATE_HARDEN.md 顶部):
#   **本门判 = 源码 token/结构形态与修复一致 + （加固后）条件语义与见证同源。**
#   **本门不判 = ① 编译能否通过 ② 真 Linux 上的行为 ③ 旧臂在**行为**上是否真的等于 HEAD。**
#   (③ 的"行为"指 socket syscall 次序之外的 conn_ms 口径等微差, 见 REVIEW §A.2;
#    本门判的"结构形态一致"**不等于**行为逐字一致。)
#
# 判据 (14 条; 每条都有一条能让它翻红的对照, 见 run_gate_controls.py):
#   C1  存在 sink_connect_rcvbuf() 函数体 (修复的载体)
#   C2  函数体内次序: if(!rcvbuf_after_connect) -> setsockopt -> connect_nb
#                                      -> if(rcvbuf_after_connect) -> setsockopt
#   C3  全文件 `setsockopt(...SO_RCVBUF...)` 恰好 2 处, 且**都在**函数体内 (主循环里不再有)
#   C4  主循环调用点 = sink_connect_rcvbuf(host, port, 5, rcvbuf, rcvbuf_after_connect, &why)
#   C5  全文件**不出现** p7b_io_connect_to  (否则存在绕过 rcvbuf 钩子的连接路径)
#   C6  启动见证行存在: SINK_RCVBUF_ORDER RCVBUF_ORDER=%s
#   C7  见证行的取值 = 同一变量: rcvbuf_after_connect ? "after_connect_LEGACY" : "before_connect"
#   C8  两个臂名逐字存在 (before_connect / after_connect_LEGACY)
#   C9  默认 = 修复后: bool rcvbuf_after_connect = false;
#   C10 --rcvbuf-after-connect 开关被参数解析器接住
#
# ---- 2026-10-10 (gate harden) 新增 C11..C14 ----
# 动因: 对抗审查 (REVIEW.md §D.1) 自造 7 个"应当红"突变, 其中 4 个全绿 (A/C/B2/F) ——
#   共同形状 = "token 全在、位置次序全对, 但条件语义 / 见证同源 / 可执行性已翻".
#   C1..C10 一字未动 (语义不变); extract_fn_body 也一字未动 (新判据用自带的花括号配平版).
#   C11 guard_direct_setsockopt —— 每个 flag guard (`if (!rcvbuf_after_connect)` 与
#       `if (rcvbuf_after_connect)`) 的**直接体**必须逐字是那条 SO_RCVBUF setsockopt:
#       guard 的 `)` 与 `setsockopt` 之间只许空白 + 至多一对**配对**花括号, 且花括号内
#       不许有别的东西 (抓 A_unguard_before / C_fix_disabled_if0 及对称件:
#       旧臂被 `if (0)` 套住 / SO_RCVBUFFORCE 等 token 替换).
#   C12 witness_arg_live_value —— 见证 printf 的**第一个实参**必须逐字是那个三元
#       `rcvbuf_after_connect ? "after_connect_LEGACY" : "before_connect"` (只允许空白差异);
#       抓 B2 (printf 打常量 + 三元被埋进 `if (0)` 死码 —— C7 的 `in src` 抓不到).
#   C13 flag_writes_pinned —— flag 的**写**只许出现在两处: 它的声明行 / `--rcvbuf-after-connect`
#       解析行, 且解析行必须把它写成 `= true`; 抓 F (调用点前插 `rcvbuf_after_connect = false;`).
#   C14 no_cond_preproc —— 全文件除 `#include` 外不许有其它的预处理指令
#       (本文件今天实测 16 行全 `#include`, 0 条件指令) ⇒ 抓 `#if 0` 之类的静默禁用.
# ⚠️ 锚点缺失时的定义 (为满足"加固不得改变既有 7 对照 + N0 的 fired 集合"): C11/C12/C13
#   在**锚点不存在**时判 OK, 并把 vacuous 计数打进 detail. 这不是放水 —— 三个锚点各自被
#   既有判据钉死 (C11 的 guard 字面量 = C2 的 gb; C12 的 printf 标记 = C6; C13 的声明 = C9),
#   锚点真没了, 既有的牙会响 (N0 对照实测: fired 仍恰为 C1..C10).
#
# 用法: python gate_sinkfix.py <p7b_tcp_sink.cpp>
# 退出码: 0 = 14 条全成立; 1 = 有违例 (逐条打印 VIOLATION); 2 = 用法错
# ===========================================================================
import re
import sys


def _strip_ws(s):
    """去掉全部空白 (判"逐字相等"时只留 token 级差异可见)."""
    return "".join(s.split())


def _line_of(src, pos):
    return src.count("\n", 0, pos) + 1


def _skip_string(src, i):
    """src[i] 是引号: 返回闭合引号之后的位置 (未闭合返回 None). 处理 '\\\\' 转义."""
    q = src[i]
    i += 1
    while i < len(src):
        c = src[i]
        if c == "\\":
            i += 2
            continue
        if c == q:
            return i + 1
        i += 1
    return None


def extract_fn_body_balanced(src, sig):
    """加固新增 (与既有 extract_fn_body 并存, 互不影响): 花括号配平 + 跳过字符串字面量.
    返回 (body, i0, i1); 找不到返回 (None, -1, -1)."""
    i = src.find(sig)
    if i < 0:
        return None, -1, -1
    j = src.find("{", i)
    if j < 0:
        return None, -1, -1
    depth, k = 0, j
    while k < len(src):
        c = src[k]
        if c in "\"'":
            nk = _skip_string(src, k)
            if nk is None:
                return None, -1, -1
            k = nk
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return src[i:k + 1], i, k
        k += 1
    return None, -1, -1


def _split_call_args(src, op):
    """op = '(' 的位置: 返回 (实参字符串列表, 右括号位置); 解析失败返回 (None, -1)."""
    args, cur, depth, i = [], [], 0, op + 1
    while i < len(src):
        c = src[i]
        if c in "\"'":
            ni = _skip_string(src, i)
            if ni is None:
                return None, -1
            cur.append(src[i:ni])
            i = ni
            continue
        if c in "([{":
            depth += 1
            cur.append(c)
            i += 1
            continue
        if c in ")]}":
            if depth == 0:
                if c != ")":
                    return None, -1
                args.append("".join(cur))
                return args, i
            depth -= 1
            cur.append(c)
            i += 1
            continue
        if c == "," and depth == 0:
            args.append("".join(cur))
            cur = []
            i += 1
            continue
        cur.append(c)
        i += 1
    return None, -1


_RE_GUARD_NEG = re.compile(r"if\s*\(\s*!\s*rcvbuf_after_connect\s*\)")
_RE_GUARD_POS = re.compile(r"if\s*\(\s*rcvbuf_after_connect\s*\)")
_RE_CALL_RCVBUF = re.compile(
    r"setsockopt\s*\(\s*fd\s*,\s*SOL_SOCKET\s*,\s*SO_RCVBUF\s*,\s*&\s*rcvbuf\s*,"
    r"\s*sizeof\s*\(\s*rcvbuf\s*\)\s*\)\s*;")
# guard 的直接体: 可选的一对配对花括号 + 那条 setsockopt (花括号内不许有别的东西)。
# ⚠️ 两个当日实测踩过的坑 (两次都被对照/探针抓住, 2026-10-10):
#   ① 花括号**前**必须有 `\s*` —— 首版漏了, 等价写法 `if (g) { setsockopt(...); }` 被误红
#      (绿色对照 G3/G5 抓到);
#   ② 条件组 `(?(b)\s*\})` **不许**再挂 `?` —— 首版挂了, 于是"花括号没闭合"与"括号里多一条
#      语句"两种破坏等价性的形状都**逃逸** (边界探针 P_EQ3/P_EQ4 抓到)。
_RE_GUARD_BODY = re.compile(r"\s*(?P<b>\{)?\s*" + _RE_CALL_RCVBUF.pattern + r"(?(b)\s*\})")
_WITNESS_MARK = "SINK_RCVBUF_ORDER RCVBUF_ORDER=%s"
_WITNESS_TERN = 'rcvbuf_after_connect ? "after_connect_LEGACY" : "before_connect"'
_RE_FLAG_WRITE = re.compile(r"\brcvbuf_after_connect\s*=(?!=)")
_RE_FLAG_DECL = re.compile(r"\bbool\s+rcvbuf_after_connect\s*=(?!=)")
_RE_FLAG_CLI_TRUE = re.compile(r"rcvbuf_after_connect\s*=\s*true\s*;")
_RE_PP = re.compile(r"^\s*#\s*([A-Za-z_]\w*)")


def extract_fn_body(src, sig):
    i = src.find(sig)
    if i < 0:
        return None
    j = src.find("\n}\n", i)
    if j < 0:
        return None
    return src[i:j + 3]


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("usage: gate_sinkfix.py <p7b_tcp_sink.cpp>\n")
        return 2
    with open(argv[1], "r", encoding="utf-8", newline="") as f:
        src = f.read()

    # ⚠️ 文本层去注释视图 (只按行内 `//` 截断; 行数逐行保留 => 报的行号仍是真行号)。
    #   动因 (本 gate 第一版实测): 注释里写了 `setsockopt(...SO_RCVBUF...)` /
    #   `p7b_io_connect_to` 这些**名字** ⇒ C3/C5 被自己的注释绊倒 (假红)。
    #   本文件的所有 `//` 都在注释里 (无字符串字面量含 `//`) —— 已逐一核过。
    src = "\n".join(ln.split("//")[0] for ln in src.split("\n"))

    res = []   # (name, ok, detail)

    body = extract_fn_body(src, "static int sink_connect_rcvbuf(")
    res.append(("C1 helper_present", body is not None,
                "" if body else "sink_connect_rcvbuf() 函数体未找到"))

    # ---- C2 次序 ----
    ok2, d2 = False, "函数体缺失"
    if body is not None:
        gb = body.find("if (!rcvbuf_after_connect)")
        s1 = body.find("setsockopt", gb) if gb >= 0 else -1
        cn = body.find("p7b_io_connect_nb(")
        ga = body.find("if (rcvbuf_after_connect)")
        s2 = body.find("setsockopt", ga) if ga >= 0 else -1
        ok2 = (0 <= gb < s1 < cn < ga < s2)
        d2 = "guards/positions gb=%d s1=%d cn=%d ga=%d s2=%d" % (gb, s1, cn, ga, s2)
    res.append(("C2 order_before_connect", ok2, "" if ok2 else d2))

    # ---- C3 恰好 2 处且都在函数体内 ----
    lines = src.split("\n")
    hits = [k for k, ln in enumerate(lines) if "setsockopt(" in ln and "SO_RCVBUF" in ln]
    if body is not None:
        i0 = src.find(body)
        # 行号换算: 函数体内的那 2 处必须等于全集
        in_body_lines = []
        off = 0
        for k, ln in enumerate(lines):
            if "setsockopt(" in ln and "SO_RCVBUF" in ln and i0 <= off < i0 + len(body):
                in_body_lines.append(k)
            off += len(ln) + 1
        ok3 = (len(hits) == 2 and hits == in_body_lines)
    else:
        ok3 = False
    res.append(("C3 two_setsockopt_inside_helper", ok3,
                "" if ok3 else "SO_RCVBUF setsockopt 行 = %s (函数体内 = %s)"
                % (hits, in_body_lines if body is not None else "n/a")))

    c4 = "sink_connect_rcvbuf(host, port, 5, rcvbuf, rcvbuf_after_connect, &why)" in src
    res.append(("C4 call_site_uses_helper", c4, "" if c4 else "调用点不是 sink_connect_rcvbuf(...)"))

    c5 = "p7b_io_connect_to" not in src
    res.append(("C5 no_bypass_connect_to", c5, "" if c5 else "文件里仍有 p7b_io_connect_to"))

    c6 = "SINK_RCVBUF_ORDER RCVBUF_ORDER=%s" in src
    res.append(("C6 witness_line", c6, "" if c6 else "见证 printf 缺失"))

    c7 = 'rcvbuf_after_connect ? "after_connect_LEGACY" : "before_connect"' in src
    res.append(("C7 witness_same_var", c7, "" if c7 else "见证取值未绑定同一变量/臂名"))

    c8 = ('"before_connect"' in src) and ('"after_connect_LEGACY"' in src)
    res.append(("C8 arm_tokens", c8, "" if c8 else "臂名字面量缺失"))

    c9 = "bool rcvbuf_after_connect = false;" in src
    res.append(("C9 default_is_fixed", c9, "" if c9 else "默认值不是 false (修复后)"))

    c10 = 'k == "--rcvbuf-after-connect"' in src
    res.append(("C10 flag_parsed", c10, "" if c10 else "开关未被参数解析器接住"))

    # ---- C11 (加固) guard 的直接体 = 源样 setsockopt ----
    ok11, d11 = True, ""
    hbody, hb_i0, _hb_i1 = extract_fn_body_balanced(src, "static int sink_connect_rcvbuf(")
    if hbody is None:
        if (_RE_GUARD_NEG.search(src) or _RE_GUARD_POS.search(src)):
            # ⚠️ 边界探针 P_EQ4 实测: helper 里插一个不配平的花括号 ⇒ 配平截取失败, 而既有
            #    C1/C2 用的截取(遇到 `\n}\n`)照旧"通过" ⇒ 若此处判 vacuous OK 就是**静默空判据**。
            ok11 = False
            d11 = "helper body 无法花括号配平 (guard 字面量却存在) => 判据不可评"
        else:
            d11 = "helper body 未找到 => vacuous OK (锚点缺失时 C1/C2 会响)"
    else:
        guards = [("!", m) for m in _RE_GUARD_NEG.finditer(hbody)] + \
                 [("+", m) for m in _RE_GUARD_POS.finditer(hbody)]
        guards.sort(key=lambda t: t[1].start())
        bad11 = []
        for pol, m in guards:
            if not _RE_GUARD_BODY.match(hbody, m.end()):
                bad11.append("L%d guard(%s) 直接体不是源样 setsockopt"
                             % (_line_of(src, hb_i0 + m.start()), pol))
        ok11 = not bad11
        d11 = "guards=%d direct=%d%s" % (len(guards), len(guards) - len(bad11),
                                         ("; " + "; ".join(bad11)) if bad11 else "")
    res.append(("C11 guard_direct_setsockopt", ok11, d11))

    # ---- C12 (加固) 见证实参 = 生效值同源的那个三元 ----
    ok12, d12 = True, ""
    mi = src.find(_WITNESS_MARK)
    if mi < 0:
        d12 = "见证标记未找到 => vacuous OK (锚点缺失时 C6 会响)"
    else:
        ci = src.rfind("printf", 0, mi)
        op = src.find("(", ci) if ci >= 0 else -1
        if ci < 0 or op < 0 or op > mi:
            ok12 = False
            d12 = "见证标记不在 printf 实参里 (L%d)" % _line_of(src, mi)
        else:
            args, _cp = _split_call_args(src, op)
            if args is None or len(args) < 2:
                ok12 = False
                d12 = "printf 调用解析失败或实参不足 (L%d)" % _line_of(src, mi)
            else:
                got = _strip_ws(args[1])
                ok12 = (got == _strip_ws(_WITNESS_TERN))
                d12 = "arg1=%s%s" % (args[1].strip()[:60],
                                     "" if ok12 else " != 生效值三元(逐字)")
    res.append(("C12 witness_arg_live_value", ok12, d12))

    # ---- C13 (加固) 对 flag 的写只许在声明行 / CLI 解析行, 且解析行必须 = true ----
    ok13, d13 = True, ""
    slines = src.split("\n")
    writes = [(k, ln) for k, ln in enumerate(slines) if _RE_FLAG_WRITE.search(ln)]
    if not writes:
        d13 = "writes=0 => vacuous OK (锚点缺失时 C9 会响)"
    else:
        bad13 = ["L%d: %s" % (k + 1, ln.strip()[:70]) for k, ln in writes
                 if not (_RE_FLAG_DECL.search(ln) or 'k == "--rcvbuf-after-connect"' in ln)]
        decls = [1 for _k, ln in writes if _RE_FLAG_DECL.search(ln)]
        cli = [1 for _k, ln in writes
               if 'k == "--rcvbuf-after-connect"' in ln and _RE_FLAG_CLI_TRUE.search(ln)]
        ok13 = (not bad13) and len(decls) == 1 and len(cli) == 1
        d13 = "writes=%d decl=%d cli_true=%d%s" % (len(writes), len(decls), len(cli),
                                                   ("; " + "; ".join(bad13)) if bad13 else "")
    res.append(("C13 flag_writes_pinned", ok13, d13))

    # ---- C14 (加固) 除 #include 外不许有别的预处理指令 ----
    pps = []
    for k, ln in enumerate(src.split("\n")):
        m = _RE_PP.match(ln)
        if m and m.group(1) != "include":
            pps.append("L%d #%s" % (k + 1, m.group(1)))
    ok14 = not pps
    res.append(("C14 no_cond_preproc", ok14,
                "non-include_directives=0" if ok14 else "; ".join(pps[:5])))

    n_ok = 0
    for name, ok, det in res:
        print("%-28s %s %s" % (name, "OK" if ok else "VIOLATION", det))
        n_ok += 1 if ok else 0
    print("GATE_SINKFIX checks=%d ok=%d violations=%d file=%s"
          % (len(res), n_ok, len(res) - n_ok, argv[1]))
    return 0 if n_ok == len(res) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
