#!/usr/bin/env python3
"""mini_server.py -- sinkfix 验证的判据隔离件 (极简 TCP 服务端).

用法: python3 mini_server.py <port> <hold_seconds>
行为: listen -> accept 一次 -> 只 sleep <hold> 秒 (**不放任何数据**) -> close -> exit.

目的: 让链路上只有 SYN / SYN-ACK / ACK (再加收尾 FIN/ACK), 窗口字段被干净隔离
      (数据一动就会叠上窗口更新, 反而难读). 本件不做判据、不打判据结论.
"""
import socket
import sys
import time


def main():
    if len(sys.argv) != 3:
        print("usage: mini_server.py <port> <hold_s>", file=sys.stderr)
        return 2
    port = int(sys.argv[1])
    hold = float(sys.argv[2])
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port))
    s.listen(4)
    print("SERVER_LISTENING port=%d hold=%.1f" % (port, hold), flush=True)
    c, addr = s.accept()
    print("SERVER_ACCEPTED peer=%s:%d" % (addr[0], addr[1]), flush=True)
    time.sleep(hold)          # 只等, 不发数据, 不提前关
    c.close()
    s.close()
    print("SERVER_DONE", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
