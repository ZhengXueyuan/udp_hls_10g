#!/usr/bin/env python3
# persist_client.py -- P7B-PERSIST 板级 A/B 轮: P-C(c2) 的"不读"客户端 (对端机, 非测速件)
#   用途: 造"真·对端零窗" —— 客户端连上后 **完全不 read**, 让 rcvbuf 灌满 => 窗口关到 0。
#   两个子档 (--order):
#     before = SO_RCVBUF 在 connect **之前**设 => SYN 就通告小窗 (sinkfix 后的默认语义 = P-C(c1) 的延续)
#     after  = SO_RCVBUF 在 connect **之后**设 => 先通告默认大窗再塌 (LEGACY 序; = P-C(c2) 的"灌满")
#   ⚠️ 本件**不是测速仪器** (不读数据, 不产生速率读数) => 不产 `PIN_CPU=` 见证
#      (全局 #62 管的是速率台架; 本档的速率读数一律来自 sink / 板侧快照)。
#   输出行以 CLIENT_ 前缀, 便于机器解析。
#   用法: python3 persist_client.py --host 192.168.100.2 --port 8080 \
#            --rcvbuf 2920 --order before|after --secs 150
import argparse
import socket
import sys
import time

sys.stdout.reconfigure(encoding="utf-8", errors="replace")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="192.168.100.2")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--rcvbuf", type=int, default=2920)
    ap.add_argument("--order", choices=["before", "after"], default="before")
    ap.add_argument("--secs", type=float, default=60.0)
    ap.add_argument("--connect-timeout", type=float, default=10.0)
    a = ap.parse_args()

    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    if a.order == "before":
        s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, a.rcvbuf)
    print("CLIENT_START order=%s rcvbuf_req=%d t=%.6f" % (a.order, a.rcvbuf, time.time()), flush=True)
    print("CLIENT_SO_RCVBUF_PRE_CONNECT %d" % s.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF), flush=True)
    s.settimeout(a.connect_timeout)
    t0 = time.time()
    try:
        s.connect((a.host, a.port))
    except Exception as e:                                        # noqa: BLE001
        print("CLIENT_CONNECT_FAIL %r" % (e,), flush=True)
        return 2
    t1 = time.time()
    print("CLIENT_CONNECT_OK local=%s remote=%s dt=%.6f" % (s.getsockname(), s.getpeername(), t1 - t0), flush=True)
    if a.order == "after":
        s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, a.rcvbuf)
        print("CLIENT_SO_RCVBUF_SET_AFTER_CONNECT req=%d now=%d"
              % (a.rcvbuf, s.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)), flush=True)
    else:
        print("CLIENT_SO_RCVBUF_AFTER_CONNECT %d" % s.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF), flush=True)

    # ⛔ 核心: 一段时间内 **一个字节都不读** (窗口只会往 0 关, 不会重开)
    end = t1 + a.secs
    nxt = t1 + 5.0
    while time.time() < end:
        time.sleep(min(0.2, max(0.0, end - time.time())))
        now = time.time()
        if now >= nxt:
            print("CLIENT_TICK t=%.3f elapsed=%.3f noread=1" % (now, now - t1), flush=True)
            nxt += 5.0
    print("CLIENT_NOREAD_DONE elapsed=%.3f t=%.6f" % (time.time() - t1, time.time()), flush=True)
    # 收尾: 带未读数据的 close ⇒ 内核一般回 RST (我们只记录, 不依赖)
    s.close()
    print("CLIENT_CLOSE t=%.6f" % time.time(), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
