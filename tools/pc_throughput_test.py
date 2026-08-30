#!/usr/bin/env python
"""P4a 板级吞吐率实测: TCP fast path 流式吞吐 (控 MSS 变段大小) + UDP 慢路径对比。

TCP: 连接 192.168.100.2:8080, setsockopt(TCP_MAXSEG) 控线上段大小, 流式发
TOTAL 字节并收全 echo, 吞吐 = TOTAL/墙钟 (含回环 = 有效载荷好吞吐)。
注意 FPGA 每数据段回 2 帧 (纯 ACK + echo), TX 侧天然 2 倍开销 — 解读见报告。
UDP: 慢路径 HLS echo (对照: 字节/拍级慢路径, 非吞吐设计)。

用法: /c/Users/zhxue/anaconda3/python.exe tools/pc_throughput_test.py
"""
import socket
import time

HOST = '192.168.100.2'
PORT = 8080


def payload(n, seed=0):
    return bytes(((i * 7 + 3 + seed) & 0xFF) for i in range(n))


def tcp_stream(mss, total=16 * 1024 * 1024):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(10)
    try:
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_MAXSEG, mss)
    except OSError as e:
        print('  TCP_MAXSEG=%d 设置失败: %s (用默认)' % (mss, e))
    s.connect((HOST, PORT))
    # 关 Nagle, 小写立即发
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    blk = payload(65536)
    sent = 0
    recv = 0
    t0 = time.time()
    while recv < total:
        # 收发交替 (窗口 8KB 限在途): 发一块收一块
        if sent < total:
            s.sendall(blk[:min(len(blk), total - sent)])
            sent += min(len(blk), total - sent)
        # 非阻塞收
        s.settimeout(5)
        try:
            chunk = s.recv(1 << 20)
        except socket.timeout:
            break
        if not chunk:
            break
        recv += len(chunk)
    dt = time.time() - t0
    s.close()
    return recv, dt


def udp_flood(size, count=300):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(0.5)
    pl = payload(size)
    t0 = time.time()
    for i in range(count):
        s.sendto(pl, (HOST, PORT))
    got = 0
    while True:
        try:
            s.recvfrom(2048)
            got += 1
        except socket.timeout:
            break
    dt = time.time() - t0
    s.close()
    return got, count, dt


def main():
    print('=== TCP 流式吞吐 (echo 全收, 16MB) ===')
    print('%-8s %-12s %-12s' % ('MSS', 'goodput Mbps', 'notes'))
    for mss in (128, 256, 536, 1024, 1460):
        n, dt = tcp_stream(mss)
        print('%-8d %-12.1f (%d B in %.1f s)' % (mss, n * 8 / dt / 1e6, n, dt))
        time.sleep(0.3)
    print()
    print('=== UDP 慢路径 echo (300 突发) ===')
    print('%-8s %-10s %-14s' % ('size', 'recv/send', 'echo Mbps'))
    for size in (64, 512, 1024, 1472):
        got, cnt, dt = udp_flood(size)
        print('%-8d %-10s %-14.2f' % (size, '%d/%d' % (got, cnt),
                                      got * size * 8 / dt / 1e6))
        time.sleep(0.5)


if __name__ == '__main__':
    main()
