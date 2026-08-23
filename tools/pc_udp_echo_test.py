#!/usr/bin/env python
"""板上 UDP echo 功能测试 (PC 对端)。

FPGA: dst_ip 192.168.100.2 / 组播任意, port 8080; echo 回帧 dst = 原帧 src。
两种模式:
  unicast: PC 发单播 192.168.100.2:8080 — 需要静态 ARP:
     netsh interface ipv4 add neighbors "以太网" 192.168.100.2 00-0a-35-01-fe-c1
     (管理员权限; 网卡名按实际改)
  multicast: PC 发组播 239.1.2.3:8080 — 无需 ARP (FPGA cfg_multi_en=1)。

用法:
  /c/Users/zhxue/anaconda3/python.exe tools/pc_udp_echo_test.py [unicast|multicast] [n]
每帧载荷 = 4 字节序号 + 递增模式字节; 收 echo 逐字节对比, 统计丢包/错包/乱序。
"""
import socket
import sys
import time

FPGA_IP = '192.168.100.2'
FPGA_MAC = '00-0a-35-01-fe-c1'
MCAST_IP = '239.1.2.3'
PORT = 8080
PAYLOAD_N = 48


def payload(seq):
    b = bytearray(PAYLOAD_N)
    b[0:4] = seq.to_bytes(4, 'big')
    for i in range(4, PAYLOAD_N):
        b[i] = (seq * 7 + i) & 0xFF
    return bytes(b)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else 'unicast'
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 100
    interval = float(sys.argv[3]) if len(sys.argv) > 3 else 0.005   # 5ms

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(1.0)
    if mode == 'unicast':
        dst = (FPGA_IP, PORT)
        print('模式: 单播 %s:%d (需静态 ARP -> %s)' % (FPGA_IP, PORT, FPGA_MAC))
        print('  若 ARP 失败: netsh interface ipv4 add neighbors "<网卡>" %s %s'
              % (FPGA_IP, FPGA_MAC))
    else:
        dst = (MCAST_IP, PORT)
        print('模式: 组播 %s:%d' % dst)

    sent = 0
    got = {}
    bad = []
    t0 = time.time()
    for seq in range(n):
        s.sendto(payload(seq), dst)
        sent += 1
        # 边发边收 (echo 延迟 ~ 帧长×2)
        while True:
            try:
                data, addr = s.recvfrom(2048)
            except socket.timeout:
                break
            if len(data) >= 4:
                rseq = int.from_bytes(data[0:4], 'big')
                if data == payload(rseq):
                    got[rseq] = True
                else:
                    bad.append((rseq, data[:16].hex()))
        time.sleep(interval)

    # 尾段收尾
    deadline = time.time() + 2.0
    while time.time() < deadline:
        try:
            data, addr = s.recvfrom(2048)
        except socket.timeout:
            break
        if len(data) >= 4:
            rseq = int.from_bytes(data[0:4], 'big')
            if data == payload(rseq):
                got[rseq] = True
            else:
                bad.append((rseq, data[:16].hex()))

    dt = time.time() - t0
    missing = [i for i in range(n) if i not in got]
    print('发送 %d 帧 / 收对 %d 帧 / 丢失 %d 帧 / 内容错 %d 帧 (%.1f s, %.0f fps)'
          % (sent, len(got), len(missing), len(bad), dt, n / dt))
    if missing[:5]:
        print('  丢失序号示例:', missing[:5])
    if bad[:5]:
        print('  错包示例:', bad[:5])
    print('== PASS ==' if (len(got) == n and not bad) else '== FAIL ==')


if __name__ == '__main__':
    main()
