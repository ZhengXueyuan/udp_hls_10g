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
# 判据 (10 条; 每条都有一条能让它翻红的对照, 见 run_gate_controls.py):
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
# 用法: python gate_sinkfix.py <p7b_tcp_sink.cpp>
# 退出码: 0 = 10 条全成立; 1 = 有违例 (逐条打印 VIOLATION); 2 = 用法错
# ===========================================================================
import sys


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

    n_ok = 0
    for name, ok, det in res:
        print("%-28s %s %s" % (name, "OK" if ok else "VIOLATION", det))
        n_ok += 1 if ok else 0
    print("GATE_SINKFIX checks=%d ok=%d violations=%d file=%s"
          % (len(res), n_ok, len(res) - n_ok, argv[1]))
    return 0 if n_ok == len(res) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
