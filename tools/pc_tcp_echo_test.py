#!/usr/bin/env python
"""P3 板测: PC 作 TCP client 连 FPGA (192.168.100.2:8080), 逐突发验证 echo。

用法: /c/Users/zhxue/anaconda3/python.exe tools/pc_tcp_echo_test.py [host] [port]
流程: 连接 (FPGA tcp_synp 应答 SYN) -> 逐组 send/收全 echo 比对 ->
统计 RTT。发送是定长块流, 对端 (FPGA) 逐字节原样回; 失配打印首个差异偏移。
"""
import socket
import sys
import time

HOST = sys.argv[1] if len(sys.argv) > 1 else '192.168.100.2'
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8080


def payload(n, seed=0):
    return bytes(((i * 7 + 3 + seed) & 0xFF) for i in range(n))


def recv_exact(sock, n, timeout=3.0):
    sock.settimeout(timeout)
    buf = b''
    t0 = time.time()
    while len(buf) < n:
        try:
            chunk = sock.recv(n - len(buf))
        except socket.timeout:
            return buf, time.time() - t0, False
        if not chunk:
            return buf, time.time() - t0, False
        buf += chunk
    return buf, time.time() - t0, True


def main():
    sizes = [1, 2, 5, 8, 9, 42, 100, 255, 512, 1000, 1460, 42, 1, 512]
    print('connect %s:%d ...' % (HOST, PORT))
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(5.0)
    t0 = time.time()
    s.connect((HOST, PORT))
    print('connected in %.1f ms (三次握手完成)' % ((time.time() - t0) * 1000))

    total = 0
    rtt_sum = 0.0
    fails = 0
    for idx, n in enumerate(sizes):
        pl = payload(n, seed=idx)
        t0 = time.time()
        s.sendall(pl)
        buf, dt, ok = recv_exact(s, n)
        total += n
        rtt_sum += dt
        if not ok:
            print('FAIL blk%d len=%d: 超时/断链 (收 %d/%d)' % (idx, n, len(buf), n))
            fails += 1
            break
        if buf != pl:
            dpos = next(i for i in range(n) if buf[i] != pl[i])
            print('FAIL blk%d len=%d: 差异@%d (%02x != %02x)' %
                  (idx, n, dpos, buf[dpos], pl[dpos]))
            fails += 1
        else:
            print('ok   blk%d len=%-5d echo RTT %.2f ms' % (idx, n, dt * 1000))

    # 关闭前再确认连接活着 (FIN 由 PC 发; FPGA P3 不关连接, PC 侧关闭即可)
    s.close()
    print('----')
    print('total %d bytes, %d blocks, fails=%d, avg RTT %.2f ms' %
          (total, len(sizes), fails, rtt_sum / max(1, len(sizes)) * 1000))
    print('ECHO PASS' if fails == 0 else 'ECHO FAIL')


if __name__ == '__main__':
    main()
