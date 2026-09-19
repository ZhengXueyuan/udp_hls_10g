#!/usr/bin/env python
"""board_active_test.py — P4d 板级主动连接 (TCP 客户端) 验收

板侧 (ACTIVE_CONNECT=1 板级 bitstream) 上电 ~2s 后自动:
  ARP who-has 192.168.100.1 (本机) -> SYN 到 :9090 -> 等 SYN+ACK ->
  纯 ACK 建连 -> fast path TCB 由 HLS cfg 记录配好
失败 (ARP 限次 / SYN 超时) 回等待 ~2s 重试。

本脚本 = PC 侧对端: 监听 9090, 接受板侧连接, 验证:
  1) 板侧主动 SYN 到达 (源 = 192.168.100.2, 端口 = 板侧临时口)
  2) 握手完成 (accept 返回)
  3) 数据 echo: 本脚本发 N 字节 -> 板侧 fast path 回显逐字节一致
  ④ (可选) 板侧 ACK 推进正确

用法: python tools/board_active_test.py [--port 9090] [--bytes 100] [--wait 30]
"""
import socket
import sys
import time

BOARD_IP = "192.168.100.2"
BOARD_PORT = 9090


def main():
    port = 9090
    nbytes = 100
    wait = 30
    if "--port" in sys.argv:
        port = int(sys.argv[sys.argv.index("--port") + 1])
    if "--bytes" in sys.argv:
        nbytes = int(sys.argv[sys.argv.index("--bytes") + 1])
    if "--wait" in sys.argv:
        wait = int(sys.argv[sys.argv.index("--wait") + 1])

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", port))
    srv.listen(4)
    srv.settimeout(wait)
    print("listening on :%d (等板侧主动连接, 最多 %ds)" % (port, wait))
    t0 = time.time()
    try:
        conn, addr = srv.accept()
    except socket.timeout:
        print("ACTIVE TEST FAIL: %ds 内没有板侧连接" % wait)
        return 1
    dt = time.time() - t0
    print("accept: %s:%d (等待 %.2fs)" % (addr[0], addr[1], dt))
    if addr[0] != BOARD_IP:
        print("ACTIVE TEST FAIL: 来源 %s != 板 IP %s" % (addr[0], BOARD_IP))
        return 1
    print("1) 板侧主动 SYN + 握手完成 OK (来源 = 板 IP)")

    # 3) 数据 echo
    pay = bytes(((i * 7 + 3) & 0xFF) for i in range(nbytes))
    conn.sendall(pay)
    got = b""
    conn.settimeout(5)
    t1 = time.time()
    while len(got) < nbytes and time.time() - t1 < 5:
        try:
            chunk = conn.recv(4096)
        except socket.timeout:
            break
        if not chunk:
            break
        got += chunk
    if got == pay:
        print("3) 数据 echo: %d B 逐字节一致 OK (fast path 已配好)" % nbytes)
    else:
        print("ACTIVE TEST FAIL: echo %d/%d B, 一致=%s"
              % (len(got), nbytes, got == pay))
        conn.close(); srv.close()
        return 1

    conn.close()
    srv.close()
    print("ACTIVE TEST OK (板侧主动连接 + 数据面 echo 全链通过)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
