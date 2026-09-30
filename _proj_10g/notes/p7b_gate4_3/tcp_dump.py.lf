#!/usr/bin/env python3
"""tcp_dump.py — F5 的**定性取证**: TCP echo 到底回了什么 (只用来看清现象, 不下结论).

做法: connect -> sendall(4096 B 可复算图案) -> 带 1.5 s 超时反复 recv, 记录**每次 read 的
长度与时刻**, 打印首 96 字节的 hex + ASCII。收到的东西是"回显"(=我发的图案) 还是
"别的东西"(默认消息/图案流/垃圾) 一看即知。
"""
import argparse
import socket
import sys
import time

PAT = bytes((i * 7 + 13) & 0xFF for i in range(256))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--board", default="192.168.100.2")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--send", type=int, default=4096)
    ap.add_argument("--reads", type=int, default=40)
    a = ap.parse_args()

    payload = (PAT * (a.send // 256 + 1))[: a.send]
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(6.0)
    t0 = time.time()
    s.connect((a.board, a.port))
    print("connect OK (%.2f ms) ; 本机 %s:%d -> %s:%d"
          % ((time.time() - t0) * 1e3, *s.getsockname(), *s.getpeername()))
    s.sendall(payload)
    print("sent %d B ; 首 16 B = %s" % (len(payload), payload[:16].hex()))
    s.settimeout(1.5)
    buf = b""
    t_end = time.time() + 4.0
    n = 0
    while n < a.reads and time.time() < t_end:
        try:
            b = s.recv(65536)
        except socket.timeout:
            print("  [%6.1f ms] recv 超时 (累计 %d B)" % ((time.time() - t0) * 1e3, len(buf)))
            break
        if not b:
            print("  [%6.1f ms] 对端 FIN (累计 %d B)" % ((time.time() - t0) * 1e3, len(buf)))
            break
        n += 1
        buf += b
        print("  recv#%-2d [%6.1f ms] +%5d B (累计 %6d B) 首16=%s"
              % (n, (time.time() - t0) * 1e3, len(b), len(buf), b[:16].hex()))
    print("TOTAL %d B" % len(buf))
    head = buf[:96]
    print("HEAD_HEX %s" % head.hex())
    print("HEAD_ASC %s" % "".join(chr(c) if 32 <= c < 127 else "." for c in head))
    ok = buf.startswith(payload[:min(len(buf), len(payload))]) and len(buf) == len(payload)
    print("ECHO_EXACT %s (len=%d 期望=%d)" % (ok, len(buf), len(payload)))
    loc = buf.find(payload[:64])
    print("PAYLOAD_PREFIX_OFFSET %d (-1 = 回显里根本没有我发的图案前 64 B)" % loc)
    s.close()
    return 0


sys.exit(main())
