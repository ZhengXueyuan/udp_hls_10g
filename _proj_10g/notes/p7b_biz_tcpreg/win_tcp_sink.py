#!/usr/bin/env python3
"""win_tcp_sink.py -- 最小 TCP 接收基准 (Windows 侧), 给 peer->Windows 的 LAN 基线用。

用法: python win_tcp_sink.py <port> <seconds>
打印: 接收总字节 / 速率 (Mbps)。纯 Python recv_into 循环, 用于 >100 Mbps 级别的
粗基线判断 (不是精密仪器; 结论只用于"对端 TCP 发送路径是否健康"这一档)。
"""
import socket
import sys
import time

port = int(sys.argv[1]) if len(sys.argv) > 1 else 5201
secs = float(sys.argv[2]) if len(sys.argv) > 2 else 5.0

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("0.0.0.0", port))
srv.listen(4)
srv.settimeout(secs + 5)
buf = bytearray(1 << 20)
total = 0
t0 = None
conn, addr = srv.accept()
conn.settimeout(secs + 5)
print("CONN from %s" % (addr,), flush=True)
t0 = time.time()
try:
    while time.time() - t0 < secs:
        n = conn.recv_into(buf)
        if n == 0:
            break
        total += n
except socket.timeout:
    pass
dt = max(time.time() - t0, 1e-9)
print("RECV bytes=%d dt=%.3f s => %.1f Mbps" % (total, dt, total * 8 / dt / 1e6), flush=True)
conn.close()
srv.close()
