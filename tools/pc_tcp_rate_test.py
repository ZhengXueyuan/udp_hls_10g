#!/usr/bin/env python
"""TCP 流式吞吐精确测量 (修复版): 双线程, 稳态速率 (10%..90%)。
用法: /c/Users/zhxue/anaconda3/python.exe tools/pc_tcp_rate_test.py [MB]
"""
import socket
import sys
import threading
import time

HOST, PORT = '192.168.100.2', 8080
TOTAL = int(sys.argv[1]) * 1024 * 1024 if len(sys.argv) > 1 else 64 * 1024 * 1024

recv_log = []
stop_flag = False


def receiver(sock):
    import select
    got = 0
    while not stop_flag:
        r, _, _ = select.select([sock], [], [], 3)
        if not r:
            continue
        chunk = sock.recv(1 << 16)
        if not chunk:
            break
        got += len(chunk)
        recv_log.append((time.time(), got))


def main():
    global stop_flag
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect((HOST, PORT))
    s.settimeout(None)        # 阻塞: sendall 仅受窗口流控
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1 << 20)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 20)
    t = threading.Thread(target=receiver, args=(s,), daemon=True)
    t.start()
    blk = bytes(1 << 16)
    sent = 0
    ts0 = time.time()
    while sent < TOTAL:
        s.sendall(blk)        # 阻塞受窗口流控 — 其速率即路径速率
        sent += len(blk)
    send_dt = time.time() - ts0
    tw = time.time()
    while (not recv_log or recv_log[-1][1] < TOTAL) and time.time() - tw < 30:
        time.sleep(0.05)
    stop_flag = True
    t.join(timeout=3)
    s.close()
    got = recv_log[-1][1] if recv_log else 0
    print('发送 %d MB 墙钟 %.2fs -> 发送侧 %.1f Mbps' %
          (TOTAL >> 20, send_dt, TOTAL * 8 / send_dt / 1e6))
    print('echo 收齐 %d B' % got)
    if len(recv_log) >= 4 and got > TOTAL // 2:
        i0 = next(i for i, x in enumerate(recv_log) if x[1] >= got * 0.1)
        i1 = next(i for i, x in enumerate(recv_log) if x[1] >= got * 0.9)
        b0, t0 = recv_log[i0][1], recv_log[i0][0]
        b1, t1 = recv_log[i1][1], recv_log[i1][0]
        print('echo 稳态 (10-90%%) %.1f Mbps' % ((b1 - b0) * 8 / (t1 - t0) / 1e6))


if __name__ == '__main__':
    main()
