#!/usr/bin/env python3
#=============================================================================
# srv_p6b_final_teach.py — P6b 最终验收 D 段的"教学包"发送器 (主机侧)
#
#   为什么不用 p6e_udp_pattern (C++ 工具) 做教学:
#     该工具教学后还会用**用户态 socket** 收 10s —— 满速 (~81k pps) 时内核缓冲必溢,
#     它会把 CPU 烧在无望的接收上, 与 tcpdump 抢时间片。D 段的逐字节判据已改成
#     **独立路径** (tcpdump + 离线代数验证) ⇒ 教学只需"发 1 个包"这一件事。
#
#   三个要点 (都对得上既有实证):
#     ① 载荷 = **图案前缀** (seed 0x9E3779B97F4A7C15, xorshift64, **先取后推进**,
#        每步取 s[31:24]), 长度 100 —— 与 p6e_udp_pattern.cpp 的 --teach-len 100
#        逐字节一致。板子 app 的 RX 侧会拿它当"offset 0 的连续前缀"校验 (W13) ⇒
#        载荷必须逐字节正确, 否则会在 W13 上留下假失配。
#     ② 目标 = <board>:8081 (板子 app 的静态目标端口 cfg_dst_port = UDP_APP_PORT)。
#     ③ **先 bind 本机 8081 再发**: 板子随即把图案流全速发到 **本机:8081**;
#        若 8081 上没有 socket, 内核会对每一帧回 ICMP port-unreachable (~81k pps!)
#        ⇒ 会给板子灌一大堆无关 RX 帧, 污染 W0/W3 的判读。
#        本脚本 bind 住端口后**只睡不收** (内核静默丢进已满的接收缓冲, 不产生 ICMP,
#        也不烧 CPU) —— 顺带就是"用户态 socket 在 ~81k pps 必丢"这一既有结论的现场。
#
#   用法: python3 srv_p6b_final_teach.py [--board 192.168.100.2] [--port 8081] [--hold 60]
#   退出: 0 = 教学包已发出 (板子是否真开始发, 由 D1/D2/D3 三个独立口径判)
#=============================================================================
import socket, sys, time

MASK = (1 << 64) - 1


def xs(s):
    s ^= (s << 13) & MASK
    s ^= s >> 7
    s ^= (s << 17) & MASK
    return s & MASK


def pattern_prefix(n, seed=0x9E3779B97F4A7C15):
    """与 p6e_udp_pattern.cpp / rtl/app_udp_pattern.v 逐字节一致: 先取 s[31:24], 再推进。"""
    s, out = seed, bytearray()
    for _ in range(n):
        out.append((s >> 24) & 0xFF)
        s = xs(s)
    return bytes(out)


def main():
    board, port, hold = "192.168.100.2", 8081, 60.0
    a = sys.argv[1:]
    for i, x in enumerate(a):
        if x == "--board" and i + 1 < len(a):
            board = a[i + 1]
        elif x == "--port" and i + 1 < len(a):
            port = int(a[i + 1])
        elif x == "--hold" and i + 1 < len(a):
            hold = float(a[i + 1])

    rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rx.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
    rx.bind(("0.0.0.0", port))          # ③ 必须先占住端口 (否则 ICMP 洪水)
    print("[teach] 已 bind 0.0.0.0:%d (抑制 ICMP unreachable 洪水; 本 socket 只睡不收)"
          % port, flush=True)

    payload = pattern_prefix(100)
    tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    dst = (board, port)
    n = tx.sendto(payload, dst)
    print("[teach] 已发 %d B 图案前缀 -> %s:%d ; 载荷前 8 字节 = %s"
          % (n, board, port, payload[:8].hex()), flush=True)
    print("[teach] 板子随即全速发 (后续保持 hold=%.0fs 不退, 让 8081 一直有 socket)" % hold,
          flush=True)
    try:
        time.sleep(hold)
    except KeyboardInterrupt:
        pass
    print("[teach] 退出", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
