#!/usr/bin/env python
"""pc_p5b_win_test.py - P5b 板级窗口闭环验收 (app RX 方向, PC 全速灌)

背景 (P5b): 板侧 app 校验器逐字节比对 (rtl/app_pattern.v 每 8 字节字需 9 拍:
取字 1 拍 + 逐字节比对 8 拍) => **消费速率约 0.89 字节/拍 < 1G 线速 1 字节/拍**,
所以本脚本全速灌 >= 1MB 时板侧必然积压: 通告窗口按 frame_fifo 占用收缩到 0,
对端 (本脚本) 停等 -> app 消费 -> 板侧发窗口更新 ACK (wu_req) -> 恢复。这就是
P5b 要验的闭环。

判据在**板侧** (UART 状态行, 见 rtl/app_status_uart.v 头注释):
  RX=<bytes> 完整 (等于本脚本发出的字节数)
  MM=0000    零失配 (窗口闭环没有让任何字节丢失/重复/乱序)
  WU>0       窗口更新 ACK 确实发出过 (闭环真的被触发)
  AD=0000    ackq 无溢出丢弃
  OC/WQ/PO   占用峰值 / 配额 / 池余额 (诊断)

本脚本只负责: 连上 -> 后台收 (板侧 app_pattern 会主动发 TX_BYTES 字节, 必须
收走否则板侧发送窗口满 -> 干扰) -> 主线程全速灌图案 -> 报告。

图案约定 (与 rtl/app_pattern.v 一致, 见 peer.cpp pat_init 的 H1 修复注释):
  byte = s[31:24] (先取), 然后 s ^= s<<13; s ^= s>>7; s ^= s<<17 (后推进)
  种子 0x9E3779B97F4A7C15

用法:
  python tools/pc_p5b_win_test.py [--bytes 4194304] [--host 192.168.100.2]
                                  [--port 8080] [--offset 0] [--timeout 60]
  --offset N  跳过图案前 N 字节。**默认 0 就是正确的**: P5b 的 C11 已在 `ev_up` 把板侧
              `rx_lfsr <= SEED` ⇒ **每个连接都从图案头开始** (与 TX 侧对称)。本参数只为
              特殊调试保留 —— 若照旧文档累加 offset 反而会得到**假的 MM 失配**。
"""
import socket
import sys
import threading
import time

# GBK 控制台下 print 非 ASCII 会抛 UnicodeEncodeError 并让退出码变 1 (同 board_p5b_check.py)
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except (AttributeError, ValueError):
    pass

MASK64 = (1 << 64) - 1
SEED = 0x9E3779B97F4A7C15


def xs_next(s):
    s ^= (s << 13) & MASK64
    s ^= s >> 7
    s ^= (s << 17) & MASK64
    return s & MASK64


def gen_pattern(n, offset=0):
    """图案前 offset+n 字节的 [offset, offset+n) 段 (先取后推进)。"""
    s = SEED
    for _ in range(offset):
        s = xs_next(s)
    buf = bytearray(n)
    for i in range(n):
        buf[i] = (s >> 24) & 0xFF
        s = xs_next(s)
    return bytes(buf)


def main():
    host = "192.168.100.2"
    port = 8080
    nbytes = 4 * 1024 * 1024
    offset = 0
    timeout = 60.0

    argv = sys.argv[1:]
    for opt, cast in (("--bytes", int), ("--host", str), ("--port", int),
                      ("--offset", int), ("--timeout", float)):
        if opt in argv:
            v = argv[argv.index(opt) + 1]
            if opt == "--host":
                host = v
            elif opt == "--bytes":
                nbytes = cast(v)
            elif opt == "--port":
                port = cast(v)
            elif opt == "--offset":
                offset = cast(v)
            else:
                timeout = cast(v)

    print("P5b 窗口闭环板级测试: %s:%d, 灌 %d 字节 (图案偏移 %d)"
          % (host, port, nbytes, offset))

    # ⚠️ 图案必须**先于 connect** 生成: 板侧关闭超时是 400ms (FIN_TO_LIM=195313 轮
    # @125MHz = 4xRTO), 而本机 4MB 图案生成约 1.13s。若在 connect 之后才生成, 板侧
    # 早已发完自己的 1MB + FIN 并在 400ms 后超时 RST ⇒ 连接被拆、数据全丢
    # (2026-09-20 板级实测: WinError 10053, 板侧 RX=0/RS=1)。
    print("生成图案 (先于 connect, 见下方注释)...")
    tg = time.time()
    payload = gen_pattern(nbytes, offset)
    print("图案生成完成 (%d B, %.2fs)" % (nbytes, time.time() - tg))

    t0 = time.time()
    try:
        conn = socket.create_connection((host, port), timeout=10)
    except OSError as e:
        print("FAIL: 连接失败 %s" % e)
        return 1
    print("连接建立 (%.2fs)" % (time.time() - t0))

    # 后台接收: 板侧 app_pattern 会主动发 TX_BYTES 字节 (P5a: 1MB), 不收会反压
    # 板侧发送窗口 -> 干扰 RX 方向观测。只计数不校验 (TX 方向自有 --rx-only 门)。
    rx_cnt = [0]
    rx_err = [None]
    rx_done = threading.Event()

    def rx_loop():
        conn.settimeout(5.0)
        try:
            while True:
                try:
                    chunk = conn.recv(65536)
                except socket.timeout:
                    rx_done.set()
                    return
                if not chunk:
                    rx_done.set()
                    return
                rx_cnt[0] += len(chunk)
        except Exception as e:          # noqa: BLE001 - 报告用
            rx_err[0] = e
            rx_done.set()

    th = threading.Thread(target=rx_loop, daemon=True)
    th.start()

    # 全速灌。注意 (2026-09-20 板级实测): sendall 只要数据进了内核发送缓冲就返回,
    # 阻塞时长**不反映**板侧窗口收缩 (本机 4MB < 0.5ms、256MB 0.031s 即返回) ——
    # 流控闭环的观测必须在**板侧 UART** (tools/board_p5b_check.py)。
    ts = time.time()
    try:
        conn.sendall(payload)
    except OSError as e:
        print("FAIL: 发送中断 %s (已发 %d/%d)" % (e, rx_cnt[0], nbytes))
        return 1
    dt = time.time() - ts
    print("发送完成: %d B / %.3fs = %.2f Mbps (socket 缓冲口径, **不是线速**)"
          % (nbytes, dt, nbytes * 8.0 / dt / 1e6))
    print("  (sendall 只要数据进了内核发送缓冲就返回 — 2026-09-20 板级实测 256MB 仅")
    print("   0.031s 返回; 真正的窗口收缩只能在**板侧 UART** 观测, 见判据工具)")

    # 等板侧把剩余字节收完 (窗口循环的最后一段) + 板侧计数器刷新。
    # 2026-09-20 板级实测: 固定 sleep(2.0) 对 256MB 不够 (排空约 4.5s) ⇒ 尾部会短缺
    # (268435456 mod 1460 = 1316 B 未到即 close)。改为按数据量估算。
    drain = max(3.0, nbytes / 60e6)
    print("等板侧排空 %.1fs ..." % drain)
    time.sleep(drain)
    print("板侧 TX 方向收到: %d B" % rx_cnt[0])
    if rx_err[0]:
        print("(接收线程异常: %s)" % rx_err[0])

    try:
        conn.close()
    except OSError:
        pass
    print("")
    print("== 板侧判据 (自动): python tools/board_p5b_check.py --expect-rx %d ==" % nbytes)
    print("   判据: RX=%08X  MM=0000  WU>0  AD=0000  (COM9 9600-8N1, 见 tools/board_p5b_check.py)" % nbytes)
    print("PC_P5B_DONE")
    return 0


if __name__ == "__main__":
    sys.exit(main())
