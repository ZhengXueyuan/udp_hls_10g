#!/usr/bin/env python3
"""win_tcp_sink.py -- 最小 TCP 接收基准 (Windows 侧), 给 peer->Windows 的 LAN 基线用。

用法: python win_tcp_sink.py <port> <seconds> [idle_ms]
打印: 接收总字节 / 速率 (Mbps)。纯 Python, 用于 >100 Mbps 级别的
粗基线判断 (不是精密仪器; 结论只用于"对端 TCP 发送路径是否健康"这一档)。

⭐ 2026-10-09 (R1 用户要求落地): **非阻塞 + 电平触发** —— accept/recv 都先等"就绪"再动,
   两个 socket 一律 setblocking(False), recv 容忍 EAGAIN; 等待超时 = **确定语义**
   (计数 + 打 `*_TIMEOUT`/`IDLE_TMO` 行 + 退出码, 不静默吞; 旧版把 socket.timeout 静默吞掉)。
   ⛔ **不写盘**: 数据只进内存缓冲区做计数, 没有任何文件读写。
   ⚠️ **本件跑在 Windows 上 ⇒ 等待原语用 `selectors.DefaultSelector` 而不是 `select.poll`**:
   `select.poll` 在 Windows 上**不存在** (实测 AttributeError; 本文件初版就是这么写的)。
   DefaultSelector 在 Linux 上 = epoll / 在 Windows 上 = select —— 两者都是**电平触发**语义
   (⛔ 不用边沿技巧: 不做"只报一次"的状态机, 每次 select 返回的都是**当前仍就绪**的集合)。
"""
import selectors
import socket
import sys
import time

port = int(sys.argv[1]) if len(sys.argv) > 1 else 5201
secs = float(sys.argv[2]) if len(sys.argv) > 2 else 5.0
idle_ms = int(sys.argv[3]) if len(sys.argv) > 3 else 2000   # 单次等待上限; 一次超时即判空闲

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.setblocking(False)                                     # ⭐ R1: 一律非阻塞
srv.bind(("0.0.0.0", port))
srv.listen(4)

sel = selectors.DefaultSelector()                          # 电平触发 (平台原生: epoll/select)
sel.register(srv, selectors.EVENT_READ)

t_wait0 = time.time()
conn = None
wait_tmo = 0
while time.time() - t_wait0 < secs + 5:                    # 总窗 = secs+5 (与旧版 settimeout 同)
    ev = sel.select(idle_ms / 1000.0)
    if not ev:
        wait_tmo += 1                                      # 分片等待: 计数后继续等, 到总窗才放弃
        continue
    try:
        conn, addr = srv.accept()
        break
    except BlockingIOError:                                # 非阻塞语义: 容忍 EAGAIN
        continue
if conn is None:
    print("ACCEPT_TMO %.1f s 内没有连接 (分片等待超时 %d 次, 确定语义 ⇒ 退出码 1)"
          % (time.time() - t_wait0, wait_tmo), flush=True)
    srv.close()
    sys.exit(1)

sel.unregister(srv)
conn.setblocking(False)                                    # ⭐ R1
sel.register(conn, selectors.EVENT_READ)
print("CONN from %s" % (addr,), flush=True)
buf = bytearray(1 << 20)
total = 0
idle_tmo = 0
t0 = time.time()
while time.time() - t0 < secs:
    ev = sel.select(idle_ms / 1000.0)
    if not ev:
        idle_tmo += 1
        continue                                            # 计数在案, 收尾按 IDLE_TMO 打行
    n = conn.recv_into(buf)
    if n == 0:
        break
    total += n
dt = max(time.time() - t0, 1e-9)
if idle_tmo:
    print("IDLE_TMO idle_ms=%d count=%d (等待超时次数; 不是静默)" % (idle_ms, idle_tmo), flush=True)
print("RECV bytes=%d dt=%.3f s => %.1f Mbps idle_tmo=%d" % (total, dt, total * 8 / dt / 1e6, idle_tmo),
      flush=True)
conn.close()
srv.close()
