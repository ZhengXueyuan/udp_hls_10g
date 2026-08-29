#!/usr/bin/env python
"""P4a 板测: HLS 慢路径 (ARP/ICMP/UDP) + TCP fast path 回归。

前置: 删除 PC 静态 ARP (证明 HLS ARP 应答生效):
    netsh interface ip delete neighbors "以太网 2"     (管理员)
  或  arp -d 192.168.100.2

用法: /c/Users/zhxue/anaconda3/python.exe tools/pc_p4_test.py [--skip-arp-check]
阶段:
  1 ARP+ICMP: ping 192.168.100.2 4/4, 随后 ARP 表应出现 -> 00-0a-35-01-fe-c0
    (动态, HLS ARP 应答; C0 是 P4 统一 MAC)
  2 TCP echo 回归: 连 192.168.100.2:8080, 14 块 1..1460B 逐字节比对 (fast path)
  3 UDP echo (HLS 慢路径白送): 发 192.168.100.2:8080, 收回显
"""
import socket
import subprocess
import sys
import time

HOST = '192.168.100.2'
BOARD_MAC = '00-0a-35-01-fe-c0'


def payload(n, seed=0):
    return bytes(((i * 7 + 3 + seed) & 0xFF) for i in range(n))


def phase_arp_icmp():
    print('== 阶段 1: ARP + ICMP (ping) ==')
    r = subprocess.run(['ping', '-n', '4', HOST],
                       capture_output=True, text=True, timeout=20)
    out = r.stdout
    lost4 = ('Lost = 4' in out) or ('100% loss' in out) or ('100%' in out and 'loss' in out)
    ok = (r.returncode == 0) and not lost4
    print(out.strip().splitlines()[-2:])
    if not ok:
        print('FAIL: ping 不通 (检查 ARP 是否已删 / 板子是否烧录 wrapper_p4)')
        return False
    r = subprocess.run(['arp', '-a', HOST], capture_output=True, text=True)
    print(r.stdout.strip())
    if BOARD_MAC not in r.stdout.lower().replace(':', '-'):
        print('FAIL: ARP 表无 %s -> %s (HLS ARP 应答未生效)' % (HOST, BOARD_MAC))
        return False
    print('ok: ARP 动态绑定 %s -> %s (HLS 慢路径应答)' % (HOST, BOARD_MAC))
    return True


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


def phase_tcp():
    print('== 阶段 2: TCP echo 回归 (fast path) ==')
    sizes = [1, 2, 5, 8, 9, 42, 100, 255, 512, 1000, 1460, 42, 1, 512]
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(5.0)
    t0 = time.time()
    s.connect((HOST, 8080))
    print('connected in %.1f ms' % ((time.time() - t0) * 1000))
    fails = 0
    rtt_sum = 0.0
    for idx, n in enumerate(sizes):
        pl = payload(n, seed=idx)
        t0 = time.time()
        s.sendall(pl)
        buf, dt, ok = recv_exact(s, n)
        rtt_sum += dt
        if not ok:
            print('FAIL blk%d len=%d: 超时/断链 (收 %d/%d)' % (idx, n, len(buf), n))
            fails += 1
            break
        if buf != pl:
            dpos = next(i for i in range(n) if buf[i] != pl[i])
            print('FAIL blk%d len=%d: 差异@%d' % (idx, n, dpos))
            fails += 1
        else:
            print('ok   blk%d len=%-5d RTT %.2f ms' % (idx, n, dt * 1000))
    s.close()
    print('TCP %s (fails=%d, avg RTT %.2f ms)' %
          ('PASS' if fails == 0 else 'FAIL', fails,
           rtt_sum / max(1, len(sizes)) * 1000))
    return fails == 0


def phase_udp():
    print('== 阶段 3: UDP echo (HLS 慢路径) ==')
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(3.0)
    pl = payload(64, seed=99)
    t0 = time.time()
    s.sendto(pl, (HOST, 8080))
    try:
        data, _ = s.recvfrom(2048)
    except socket.timeout:
        print('FAIL: UDP 回显超时')
        return False
    dt = time.time() - t0
    if data != pl:
        print('FAIL: UDP 回显内容不符 (%d/%d B)' % (len(data), len(pl)))
        return False
    print('ok: UDP 64B 回显 RTT %.2f ms' % (dt * 1000))
    return True


def main():
    results = {}
    if '--skip-arp-check' not in sys.argv:
        results['ARP+ICMP'] = phase_arp_icmp()
    results['TCP'] = phase_tcp()
    results['UDP'] = phase_udp()
    print('----')
    for k, v in results.items():
        if v is not None:
            print('%-8s %s' % (k, 'PASS' if v else 'FAIL'))
    ok = all(v for v in results.values() if v is not None)
    print('P4a BOARD PASS' if ok else 'P4a BOARD FAIL')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
