#!/usr/bin/env python3
# ===========================================================================
# win_loopback_rcvbuf_order.py -- 本机回环上的**机制**演示 (2026-10-10)
#
# 演示什么: SO_RCVBUF 的**落点**决定**首个窗口通告**的大小 ——
#   臂 A (before_connect, = sinkfix 修复后): setsockopt 抢在 connect 之前 =>
#        **SYN 的 win 字段一开始就是小值**;
#   臂 B (after_connect_LEGACY, = sinkfix 旧行为): connect 之后才 setsockopt =>
#        **SYN 先通告默认大窗**, 之后才塌。
#
# ⛔ 边界 (如实): 本脚本跑在 **Windows 栈**上 —— 它演示的是**顺序这件事本身在起作用**
#   (机制), **不是** p7b_tcp_sink (Linux 目标件) 的行为判据; 真判据必须在对端 Linux
#   上抓 (REPORT §4)。数值 (64240 / 2920 的具体取值) 也**不可**跨栈照抄。
#
# 观测: `tshark -i \Device\NPF_Loopback` 抓 SYN / 首个 ACK 的 `tcp.window_size_value`。
# 用法: python win_loopback_rcvbuf_order.py [--tshark PATH] [--rcvbuf 2920] [--send 8192]
# ===========================================================================
import argparse
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time

DEFAULT_TSHARK = r"C:\Program Files\Wireshark\tshark.exe"
IFACE = r"\Device\NPF_Loopback"
CAP_SECS = 6


def _b(x):
    """tshark -T fields 的布尔字段在不同版本里渲染为 1/0 或 True/False (本机实测后者)。"""
    return x in ("1", "True", "true")


def run_arm(tshark, rcvbuf, send_bytes, tag):
    """返回 (raw_lines, parsed_rows)。parsed_rows = [(dir, flags, win, wscale), ...]"""
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)
    sport = srv.getsockname()[1]
    tmpd = tempfile.mkdtemp(prefix="sinkfix_cap_")
    cap = os.path.join(tmpd, "arm_%s.pcapng" % tag)

    state = {}

    def server():
        try:
            conn, _ = srv.accept()
            state["acc"] = True
            conn.sendall(b"P" * send_bytes)
            time.sleep(1.5)          # 保持连接: 让客户端的 ACK(带窗口) 被抓到
            conn.close()
        except Exception as e:       # noqa
            state["srv_err"] = repr(e)

    t = threading.Thread(target=server)
    t.start()

    cap_proc = subprocess.Popen(
        [tshark, "-i", IFACE, "-f", "tcp port %d" % sport,
         "-a", "duration:%d" % CAP_SECS, "-w", cap, "-q"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    time.sleep(2.0)                  # 等抓包真的起来 (tshark 起捕有延迟)

    cli = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    if tag == "A_before":
        cli.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, rcvbuf)   # 臂 A: connect 之前
    cli.connect(("127.0.0.1", sport))
    if tag == "B_after":
        cli.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, rcvbuf)   # 臂 B: connect 之后 (旧行为)
    cport = cli.getsockname()[1]
    state["cport"] = cport
    state["eff_rcvbuf"] = cli.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)
    time.sleep(1.2)                  # 不 read: 让发送数据撞上接收缓冲 (窗口塌陷可见)
    cli.close()
    t.join(timeout=3)
    srv.close()
    # ⚠️ 必须让 tshark **自己干净退出** (-a duration) 再读文件 —— 强杀会留下未收尾的 pcapng
    #    (第一版实测: terminate() => 0 包可解析)。
    try:
        cap_out = cap_proc.communicate(timeout=CAP_SECS + 15)[0].decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        cap_proc.kill()
        cap_out = "(capture hang)"

    # 解析: 逐包取 (srcport, dstport, syn, ack, win, wscale, len)
    p = subprocess.run(
        [tshark, "-r", cap, "-T", "fields",
         "-e", "tcp.srcport", "-e", "tcp.dstport",
         "-e", "tcp.flags.syn", "-e", "tcp.flags.ack",
         "-e", "tcp.window_size_value", "-e", "tcp.options.wscale.shift",
         "-e", "tcp.len"],
        capture_output=True, text=True)
    rows = []
    for ln in p.stdout.splitlines():
        f = ln.split("\t")
        if len(f) < 5 or f[0] == "":
            continue
        rows.append(f)
    return {"sport": sport, "cport": cport, "rcvbuf_cfg": rcvbuf,
            "eff_rcvbuf": state.get("eff_rcvbuf"), "cap_out": cap_out,
            "rows": rows, "cap": cap, "srv_err": state.get("srv_err")}


def show(arm):
    print("---- ARM %s (server port %d, client port %s, --rcvbuf %s, getsockopt(effective)=%s) ----"
          % (arm["tag"], arm["sport"], arm["cport"], arm["rcvbuf_cfg"], arm["eff_rcvbuf"]))
    if arm["srv_err"]:
        print("  server error: %s" % arm["srv_err"])
    if arm["cap_out"].strip():
        print("  tshark capture stderr/stdout: %s" % arm["cap_out"].strip()[:400])
    sp, cp = str(arm["sport"]), str(arm["cport"])
    n = 0
    syn_win = ack_win = None
    for f in arm["rows"]:
        src, dst, syn, ack, win, wscale, ln = (f + ["", "", "", "", "", "", ""])[:7]
        syn, ack = _b(syn), _b(ack)
        direction = "cli->srv" if src == cp else ("srv->cli" if src == sp else "?")
        kind = ""
        if syn and not ack:
            kind = "SYN"
        elif syn and ack:
            kind = "SYN-ACK"
        elif not syn and ack and ln == "0":
            kind = "ACK"
        elif not syn and not ack:
            kind = "FIN/RST?" if ln == "0" else "DATA"
        else:
            kind = "?"
        if kind in ("SYN", "SYN-ACK", "ACK") and n < 14:
            print("  %-8s %-8s win=%-6s wscale=%-3s len=%-5s"
                  % (direction, kind, win, wscale or "-", ln))
            n += 1
        if kind == "SYN" and src == cp:
            syn_win = win
        if kind == "ACK" and src == cp and ack_win is None:
            ack_win = win
    print("  ==> CLIENT_SYN_WIN=%s  CLIENT_FIRST_ACK_WIN=%s" % (syn_win, ack_win))
    return syn_win, ack_win


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tshark", default=DEFAULT_TSHARK)
    ap.add_argument("--rcvbuf", type=int, default=2920)
    ap.add_argument("--send", type=int, default=8192)
    a = ap.parse_args()
    if not os.path.exists(a.tshark):
        print("tshark 不存在: %s" % a.tshark)
        return 2
    print("INTERP=%s" % sys.version.split()[0])
    print("TSHARK=%s" % a.tshark)
    print("IFACE=%s" % IFACE)
    out = {}
    for tag, order in (("A_before", "before_connect"), ("B_after", "after_connect_LEGACY")):
        arm = run_arm(a.tshark, a.rcvbuf, a.send, tag)
        arm["tag"] = tag
        print()
        show(arm)
        out[tag] = arm
    print()
    print("==== 汇总 (Windows 栈; 机制演示, 非 Linux 判据) ====")
    for tag in ("A_before", "B_after"):
        arm = out[tag]
        sp, cp = str(arm["sport"]), str(arm["cport"])
        syn = next((f[4] for f in arm["rows"]
                    if f[0] == cp and _b(f[2]) and not _b(f[3])), None)
        first_ack = next((f[4] for f in arm["rows"]
                          if f[0] == cp and not _b(f[2]) and _b(f[3])
                          and (len(f) > 6 and f[6] == "0")), None)
        print("ARM %-8s SO_RCVBUF=%d (effective=%s) : SYN.win=%s  first_ack.win=%s"
              % (tag, arm["rcvbuf_cfg"], arm["eff_rcvbuf"], syn, first_ack))
    return 0


if __name__ == "__main__":
    sys.exit(main())
