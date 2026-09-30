#!/usr/bin/env python3
"""p7b_nic_txcalib.py -- 标定对端 NIC 的 TX 连续计数 (S0-B #B3)

问题: `ethtool -S enp1s0f1np1` 里 `tx-N.tx_packets` **出现两次** (8 行 / 4 队列)
      => 裸 grep + sum 会把两个不同的底层计数器一起加, 口径不明。

做法: 用**可控数量**的 UDP datagram 打出真实 TX 流量, 前后各取一次全量 ethtool,
      看**哪一个 (哪一组) 计数器恰好 += N**, 以及 byte 计数器是否 += N*(paylen+42)。

用法: python3 p7b_nic_txcalib.py <iface> <dst_ip> <dst_port> <n_pkts> <paylen>
"""
import subprocess
import socket
import sys
import time

FIELDS = None


def snap(iface):
    out = subprocess.check_output(["ethtool", "-S", iface], text=True)
    d = {}
    for line in out.splitlines():
        if ":" not in line:
            continue
        k, v = line.split(":", 1)
        k = k.strip()
        v = v.strip()
        if not v.isdigit():
            continue
        # 重名 => 用 list 收集 (后面带序号)
        if k in d:
            if not isinstance(d[k], list):
                d[k] = [d[k]]
            d[k].append(int(v))
        else:
            d[k] = int(v)
    return d


def main():
    iface, dst, port, n, paylen = (sys.argv[1], sys.argv[2], int(sys.argv[3]),
                                   int(sys.argv[4]), int(sys.argv[5]))
    a = snap(iface)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    payload = bytes(range(256)) * (paylen // 256 + 1)
    payload = payload[:paylen]
    sent = 0
    t0 = time.time()
    for i in range(n):
        try:
            s.sendto(payload, (dst, port))
            sent += 1
        except OSError as e:
            print("SEND_ERR i=%d %s" % (i, e))
            break
    t1 = time.time()
    time.sleep(0.5)
    b = snap(iface)
    print("CALIB iface=%s dst=%s:%d sent=%d paylen=%d wire_per_pkt=%d dur_s=%.3f"
          % (iface, dst, port, sent, paylen, paylen + 42, t1 - t0))
    keys = sorted(set(a) | set(b))
    for k in keys:
        va, vb = a.get(k), b.get(k)
        if isinstance(va, list) or isinstance(vb, list):
            va = va if isinstance(va, list) else []
            vb = vb if isinstance(vb, list) else []
            for i in range(max(len(va), len(vb))):
                x = va[i] if i < len(va) else 0
                y = vb[i] if i < len(vb) else 0
                if y != x:
                    print("  [DUP#%d] %-28s %d -> %d  (delta=%+d)" % (i, k, x, y, y - x))
            continue
        if va is None or vb is None:
            continue
        if vb != va:
            print("  %-28s %d -> %d  (delta=%+d)" % (k, va, vb, vb - va))
    print("CALIB_DONE")


if __name__ == "__main__":
    main()
