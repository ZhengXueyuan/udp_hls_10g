#!/usr/bin/env python3
"""p7b_fake_board.py -- 假板台架: 在**回环口**上模仿 KU5P 的 APP_MODE TCP app, 用来给
p7b_tcp_sink / p7b_tcp_src 的判据做"有牙"自检 (方案 §附录 B)。

为什么要它 (全局纪律 "每加一条判据配一个该被抓住的反例"):
  真正的验收判据是"对端逐字节等于图案流"。这条判据必须有**能被抓住的反例** ——
  在回环上用同一个二进制、同一套代码、只注入一个缺陷, 看判据是否翻红。

模仿对象 (逐条对齐 RTL):
  * 接受连接后立刻推 N 字节图案流 (rtl/app_pattern.v TX, 偏移 0, 每连接归零)
  * 推完就 close (AUTO_CLOSE=1)
  * 同时**读**对端发来的上行流并按图案复算 (rtl/app_pattern.v RX, 每连接偏移 0)
  * **单会话**: 一次只服务一条连接 (rtl/app_pattern.v:356-361)

注入项:
  --flip-at N   第 N 个下行字节翻一个 bit => sink 必须报 first_mismatch == N 且退出码 1
  --short N     只发 N 字节                        => 用于"下载量不足"的判定
  --silent      不发任何下行字节 (连接后立即 close)
  --hold S      下行发完后保持连接 S 秒 (测"半关闭后上行仍被接受", 见方案 §4.3 步 0)

用法:
  python3 p7b_fake_board.py --listen 127.0.0.1:18888 --bytes 1048576 [--flip-at N]
"""
import argparse, socket, sys, threading, time

SEED = 0x9E3779B97F4A7C15
M64 = (1 << 64) - 1


def xs_next(s):
    s ^= (s << 13) & M64
    s ^= s >> 7
    s ^= (s << 17) & M64
    return s & M64


def gen(n, off=0):
    s = SEED
    for _ in range(off):
        s = xs_next(s)
    out = bytearray(n)
    for i in range(n):
        out[i] = (s >> 24) & 0xFF
        s = xs_next(s)
    return bytes(out)


def serve_down(conn, nbytes, flip_at, short):
    n = nbytes if short is None else short
    if n <= 0:
        try:
            conn.shutdown(socket.SHUT_WR)
        except OSError:
            pass
        print("DOWN_SENT 0 bytes", flush=True)
        return
    blk = bytearray(gen(min(n, 1 << 22)))
    if flip_at is not None and flip_at < n:
        blk[flip_at] ^= 0x01                       # 只翻一个 bit
    i = 0
    while i < n:
        k = min(len(blk), n - i)
        try:
            conn.sendall(blk[:k])
        except OSError as e:
            print("DOWN_SEND_ERR %s" % e, flush=True)
            return
        i += k
    print("DOWN_SENT %d bytes (flip_at=%s short=%s)" % (i, flip_at, short), flush=True)
    try:
        conn.shutdown(socket.SHUT_WR)              # == 板侧 FIN
    except OSError:
        pass


def read_up(conn, t_end):
    """读上行流并按图案复算; 返回 (收字节, 首个失配的流内偏移 或 -1)。"""
    s = SEED
    got = 0
    first = -1
    conn.settimeout(0.5)
    while time.time() < t_end:
        try:
            d = conn.recv(1 << 20)
        except socket.timeout:
            continue
        except OSError:
            break
        if not d:
            break
        for j, by in enumerate(d):
            if ((s >> 24) & 0xFF) != by and first < 0:
                first = got + j
            s = xs_next(s)
        got += len(d)
    return got, first


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", default="127.0.0.1:18888")
    ap.add_argument("--bytes", type=int, default=1048576)
    ap.add_argument("--flip-at", type=int, default=None)
    ap.add_argument("--short", type=int, default=None)
    ap.add_argument("--silent", action="store_true")
    ap.add_argument("--hold", type=float, default=0.0)
    ap.add_argument("--conns", type=int, default=8)
    a = ap.parse_args()
    host, port = a.listen.rsplit(":", 1)
    port = int(port)
    ls = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    ls.bind((host, port))
    ls.listen(8)
    print("FAKE_BOARD listening %s:%d bytes=%d flip_at=%s short=%s silent=%s"
          % (host, port, a.bytes, a.flip_at, a.short, a.silent), flush=True)
    for i in range(a.conns):
        ls.settimeout(30)
        try:
            conn, peer = ls.accept()
        except socket.timeout:
            print("FAKE_BOARD accept timeout", flush=True)
            break
        t0 = time.time()
        print("FAKE_BOARD conn %d from %s" % (i, peer), flush=True)
        box = {}
        t_end = (t0 + a.hold) if a.hold > 0 else (t0 + 1e9)

        def up():
            box["got"], box["first"] = read_up(conn, t_end)
        th = threading.Thread(target=up, daemon=True)
        th.start()
        if not a.silent:
            serve_down(conn, a.bytes, a.flip_at, a.short)
        th.join(timeout=max(0.0, t_end - time.time()) + 1.0)
        try:
            conn.close()
        except OSError:
            pass
        print("FAKE_BOARD conn %d closed up_bytes=%s up_first_mismatch=%s"
              % (i, box.get("got"), box.get("first")), flush=True)
    print("FAKE_BOARD_DONE", flush=True)


if __name__ == "__main__":
    main()
