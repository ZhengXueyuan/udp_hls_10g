#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""p7b_tcp_badbyte.py -- W54 (app_pattern.stat_mismatch) 的**有牙**判据注入器 (P7B-BIZ Stage 2)

为什么需要它 (J12 的可信度问题):
  J12 = "ΔW54 == 0 且 ΔW53 == 对端 socket 发字节" 用来关闭 R3 (TCP 上行载荷逐字节)。
  ⚠️ 但 `ΔW54 == 0` 本身**在 W53 也动的前提下**才叫"内容对"; 它也可能因为
     "校验器根本没在跑 / 比对的是别的东西" 而恒 0 —— 必须**先证明它会响**。

本工具的判据 (精确到 1):
  往 8080 灌 N 字节的**真图案流**, 只在偏移 K 处**翻转 1 个字节** (其余逐字节正确)。
  板侧 `app_pattern` 的 RX 校验是**逐字节比对 + 每比一个字节无条件推进 LFSR**
  (rtl/app_pattern.v:538-541) ⇒ 1 个错字节只造成 **1** 次失配, 后续自动重新对齐。
  ⇒ 期望 **ΔW54 == 1 (精确)**, ΔW53 == N。
  (若校验器是"粘滞失配/整帧否决"或根本没跑, 读数就不等于 1 ⇒ 判据有牙。)

用法:
  python3 p7b_tcp_badbyte.py --host 192.168.100.2 --port 8080 --bytes 65536 --flip-at 32768
  python3 p7b_tcp_badbyte.py --selftest
"""
import argparse
import socket
import sys
import time

SEED = 0x9E3779B97F4A7C15
M64 = (1 << 64) - 1


def xs_next(s):
    s ^= (s << 13) & M64
    s ^= s >> 7
    s ^= (s << 17) & M64
    return s & M64


def gen(n, seed=SEED):
    """前 n 字节的图案流 (先取后推进): byte = s[31:24]"""
    out = bytearray(n)
    s = seed
    for i in range(n):
        out[i] = (s >> 24) & 0xFF
        s = xs_next(s)
    return out


def selftest():
    a = gen(1468)
    v0 = " ".join("%02X" % b for b in a[0:16])
    v1 = " ".join("%02X" % b for b in a[1460:1468])
    s = SEED
    for _ in range(100):
        s = xs_next(s)
    ok = True
    exp0 = "7F 0B 02 E5 36 A1 4E D6 1A B0 49 B8 56 AD D6 3F"
    exp1 = "03 00 42 2D 9B 47 CA C0"
    exp2 = 0xAB5917A81F0FB2AE
    print("SELFTEST offset 0..15      = %s" % v0)
    print("SELFTEST   want            = %s" % exp0)
    ok &= (v0 == exp0)
    print("SELFTEST offset 1460..1467 = %s" % v1)
    print("SELFTEST   want            = %s" % exp1)
    ok &= (v1 == exp1)
    print("SELFTEST state@100         = 0x%016X" % s)
    print("SELFTEST   want            = 0x%016X" % exp2)
    ok &= (s == exp2)
    print("SELFTEST_%s" % ("OK" if ok else "FAIL"))
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="192.168.100.2")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--bytes", type=int, default=65536, help="上行总字节 (含被翻转的那个)")
    ap.add_argument("--flip-at", type=int, default=-1, help="在该流偏移翻转 1 bit (默认 = 不翻, 纯净对照)")
    ap.add_argument("--flip-xor", type=lambda x: int(x, 0), default=0x01, help="翻转用的 XOR 掩码")
    ap.add_argument("--drain-secs", type=float, default=2.0, help="发完后继续读下行 (板子会发 1MB 图案)")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()

    buf = gen(a.bytes)
    flipped = 0
    if 0 <= a.flip_at < a.bytes:
        old = buf[a.flip_at]
        buf[a.flip_at] ^= (a.flip_xor & 0xFF)
        flipped = 1
        print("BADBYTE flip_at=%d old=0x%02X new=0x%02X xor=0x%02X" % (a.flip_at, old, buf[a.flip_at], a.flip_xor & 0xFF))
    else:
        print("BADBYTE no_flip (纯净对照: 期望 ΔW54 == 0)")

    s = socket.create_connection((a.host, a.port), timeout=10)
    print("BADBYTE_CONNECTED %s:%d" % (a.host, a.port))
    t0 = time.time()
    sent = 0
    s.settimeout(10)
    try:
        while sent < a.bytes:
            n = s.send(buf[sent:sent + 65536])
            if n <= 0:
                break
            sent += n
    except socket.timeout:
        print("BADBYTE_SEND_TIMEOUT sent=%d" % sent)
    t1 = time.time()
    # 发完后继续读: 板子会在这个连接上发 1MB 图案 (app_pattern TX) ⇒ 不读会撑满窗口
    s.settimeout(0.5)
    drained = 0
    t_end = time.time() + a.drain_secs
    while time.time() < t_end:
        try:
            d = s.recv(1 << 20)
            if not d:
                break
            drained += len(d)
        except socket.timeout:
            pass
        except OSError:
            break
    s.close()
    print("BADBYTE_SENT bytes=%d flipped=%d dur_s=%.6f drained_down_bytes=%d"
          % (sent, flipped, t1 - t0, drained))
    print("BADBYTE_DONE")
    return 0


if __name__ == "__main__":
    sys.exit(main())
