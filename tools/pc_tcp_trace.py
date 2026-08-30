#!/usr/bin/env python
"""pktmon 抓包 + TCP 流式负载, 分析窗口节奏/重传/停顿。
用法: 管理员终端; /c/Users/zhxue/anaconda3/python.exe tools/pc_tcp_trace.py [秒数]
产物: trace_p4.txt (etl2txt) + 分析摘要
"""
import os
import re
import subprocess
import sys
import time

DUR = float(sys.argv[1]) if len(sys.argv) > 1 else 5.0
OUT = os.path.dirname(os.path.abspath(__file__))
ETL = os.path.join(os.environ.get('TEMP', '/tmp'), 'p4trace.etl')
TXT = os.path.join(os.environ.get('TEMP', '/tmp'), 'p4trace.txt')


def sh(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, shell=True,
                          encoding='gbk', errors='ignore')


def main():
    sh('pktmon stop')
    if os.path.exists(ETL):
        os.remove(ETL)
    r = sh('pktmon start --capture --comp 102 -f "%s" --pkt-size 128' % ETL)
    print('pktmon start rc=%d' % r.returncode, (r.stdout or '').strip()[:100])
    # 负载
    import socket
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect(('192.168.100.2', 8080))
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    blk = bytes(65536)
    t0 = time.time()
    sent = 0
    while time.time() - t0 < DUR:
        s.sendall(blk)
        sent += len(blk)
        try:
            s.settimeout(0.1)
            s.recv(1 << 16)
        except socket.timeout:
            pass
    s.close()
    sh('pktmon stop')
    r = sh('pktmon etl2txt "%s" --out "%s" --verbose --hex' % (ETL, TXT))
    print('etl2txt:', r.returncode, os.path.getsize(TXT) if os.path.exists(TXT) else 'MISSING')
    # ---- 分析 ----
    txt = open(TXT, encoding='utf-16', errors='ignore').read()
    lines = txt.splitlines()
    # pktmon verbose 行: 时间戳 ... 方向Tx/Rx ... TCP 行含 Flags/Sport/Dport/Seq/Ack
    ev = []
    ts = None
    for ln in lines:
        m = re.match(r'(\d{2}:\d{2}:\d{2}\.\d+).*方向(Tx|Rx)', ln)
        if m:
            ts = m.group(1)
            d = m.group(2)
            ev.append([ts, d, ''])
            continue
        if ev and ('Seq' in ln or 'SEQ' in ln.upper()):
            ev[-1][2] += ln.strip() + ' '
    # 简化: 只统计方向时间序列的帧间隔
    import datetime
    tss = []
    for ts_, d, _ in ev:
        try:
            t = datetime.datetime.strptime(ts_, '%H:%M:%S.%f')
            tss.append((t, d))
        except ValueError:
            pass
    if len(tss) < 10:
        print('events too few:', len(ev))
        return
    gaps = []
    for i in range(1, len(tss)):
        dt = (tss[i][0] - tss[i - 1][0]).total_seconds() * 1e3
        gaps.append((dt, tss[i][1], tss[i][0]))
    gaps.sort(reverse=True)
    print('总帧数 %d, 时长 %.1fs' % (len(tss),
          (tss[-1][0] - tss[0][0]).total_seconds()))
    print('最大帧间隔 Top12 (ms, 方向, 时刻):')
    for g, d, t in gaps[:12]:
        print('  %9.2f %s %s' % (g, d, t.time()))
    import statistics
    gs = [g for g, _, _ in gaps]
    print('间隔中位 %.3fms 均值 %.3fms' % (statistics.median(gs), statistics.mean(gs)))


if __name__ == '__main__':
    main()
