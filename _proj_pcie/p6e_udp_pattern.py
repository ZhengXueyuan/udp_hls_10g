#!/usr/bin/env python3
#=============================================================================
# p6e_udp_pattern.py — Linux 侧 UDP 图案对端 (P6a 图案/吞吐测试的判据方)
#   它做两件事:
#     ① **教会板子 peer** (learn-on-RX): 往 192.168.100.2:8081 发一个**图案正确的**数据报。
#        板子的 udp_split 从收到帧的 meta 里学 src_mac/src_ip ⇒ peer 表有效 ⇒ 图案 app 启动门
#        (i_en=1 && i_tx_ready=peer_v) 打开 ⇒ 板子开始**全速**发图案帧 (TX_GAP=0, 载荷 1472B)。
#        ⚠️ 教学包必须是**图案流的前缀** (从 offset 0 起), 否则板子的 RX 校验器会把它记成失配
#        (W13 会涨) —— 那是"我们喂了坏数据", 不是板子的毛病。
#     ② **逐字节校验板子发来的图案流**: 所有数据报的载荷接起来必须等于 xorshift64 图案流
#        从 offset 0 起的连续前缀 (跨帧连续, 不重置)。
#
#   图案约定 (与 rtl/app_udp_pattern.v 及 tools/cpp_peer 逐字节一致):
#     xorshift64: s ^= s<<13; s ^= s>>7; s ^= s<<17;   每步取 s[31:24] (高字节)
#     种子 0x9E3779B97F4A7C15, **先取后推进**: byte = s>>24; s = next(s)
#
#   用法:
#     python3 p6e_udp_pattern.py                 # 教学 + 收 10s + 逐字节校验
#     python3 p6e_udp_pattern.py --secs 20       # 收久一点
#     python3 p6e_udp_pattern.py --no-teach      # 只收 (上次已教过 peer)
#   退出码: 0 = 图案逐字节校验通过; 1 = 有失配/没收到帧
#   ⚠️ **本工具报的 Mbps 是 Python 接收侧的天花板, 不是板子的能力** —— 判"板子能跑多快"要用
#      C++/内核旁路版本 (本工程纪律: 速率测试不用 Python)。这里只用来做**功能/逐字节**验证。
#=============================================================================
import socket, sys, time, argparse

M64 = (1 << 64) - 1
SEED = 0x9E3779B97F4A7C15
BOARD = "192.168.100.2"
PORT = 8081

class Pattern:
    """图案流发生器: 与 RTL / peer.cpp 逐字节一致 (先取后推进)"""
    def __init__(self, seed=SEED):
        self.s = seed
    def fill(self, n):
        out = bytearray(n)
        s = self.s
        for i in range(n):
            out[i] = (s >> 24) & 0xFF
            s ^= (s << 13) & M64
            s ^= (s >> 7)
            s ^= (s << 17) & M64
            s &= M64
        self.s = s
        return bytes(out)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--board", default=BOARD)
    ap.add_argument("--port", type=int, default=PORT)
    ap.add_argument("--teach-len", type=int, default=100, help="教学包载荷字节数 (必须是图案前缀)")
    ap.add_argument("--secs", type=float, default=10.0)
    ap.add_argument("--no-teach", action="store_true")
    a = ap.parse_args()

    rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rx.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    rx.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 32 * 1024 * 1024)   # 尽人事, 防内核丢包
    rx.bind(("0.0.0.0", a.port))
    rx.settimeout(1.0)
    print(f"=== p6e_udp_pattern: 本地 :{a.port} ⇄ 板子 {a.board}:{a.port} ===")

    tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if not a.no_teach:
        # 教学包 = 图案流前缀 (offset 0 起) ⇒ 板子的 RX 校验器也会通过 (W13 不涨)
        teach = Pattern().fill(a.teach_len)
        tx.sendto(teach, (a.board, a.port))
        print(f"  [teach] 发 {a.teach_len} B 图案前缀给 {a.board}:{a.port} (教 peer; 板子随即开始全速发)")
    else:
        print("  [teach] 跳过 (--no-teach)")

    pat = Pattern()            # 校验用: 期望板子的载荷从这里(offset 0)连续接下去
    off = 0                    # 已校验的流偏移
    frames = 0
    bad = 0
    first = None
    t_end = time.time() + a.secs
    t0 = time.time()
    last_report = t0
    buf = bytearray(65536)
    sizes = set()
    while time.time() < t_end:
        try:
            n, peer = rx.recvfrom_into(buf, len(buf))
        except socket.timeout:
            continue
        if first is None:
            first = peer
            print(f"  [recv] 第一个数据报来自 {peer[0]}:{peer[1]}")
        sizes.add(n)
        payload = bytes(buf[:n])
        frames += 1
        exp = pat.fill(n)          # 期望: 图案流的连续下一段
        if payload != exp:
            bad += 1
            if bad <= 3:
                i = next((k for k in range(n) if payload[k] != exp[k]), n)
                print(f"  [FAIL] 第 {frames} 帧失配: 长 {n}, 首个不同字节 @{i} "
                      f"(got {payload[i] if i < n else '-'} exp {exp[i] if i < n else '-'}); 流偏移 {off+i}")
        off += n
        now = time.time()
        if now - last_report >= 1.0:
            dt = now - t0
            print(f"    [{now-t0:5.1f}s] 帧={frames} 字节={off} ≈{off*8/dt/1e6:7.1f} Mbps "
                  f"失配={bad}")
            last_report = now

    dt = time.time() - t0
    print()
    print(f"  [汇总] 收 {frames} 帧 / {off} 字节 / {dt:.1f}s ⇒ **{off*8/dt/1e6:.1f} Mbps** "
          f"(Python 接收侧口径, 不是板子上限)")
    print(f"        载荷长度集合 = {sorted(sizes) if sizes else '-'} (板子 i_paylen=1472 ⇒ 应为 {{1472}})")
    if frames == 0:
        print("  [FAIL] 一个包都没收到 ⇒ peer 没学到 / 板子没发 / 网段不对")
        return 1
    if bad:
        print(f"  [FAIL] {bad}/{frames} 帧图案失配 ⇒ 板子的图案流不是连续前缀 (跨帧断了?)")
        return 1
    print(f"  [PASS] 全部 {frames} 帧**逐字节**等于图案流前缀 (offset 0 起到 {off}) ⇒ 图案通路成立")
    return 0

if __name__ == "__main__":
    sys.exit(main())
