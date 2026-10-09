#!/usr/bin/env python3
# a3_reconnect.py -- A3 行为验证 (构建 E 修复 = ev_up pending 补做): 对端"连接 -> 收一段 -> 关闭 -> 立刻重连"
#   ⚠️ 功能验证 (不是速率测试) ⇒ 用 Python 合适 (工程约定: 速度相关一律 C++/内核旁路)。
#
#   构型 (每回合):  connect#1 -> 收 RECV1 秒 (板子持续下行) -> **在数据中途关闭** -> 立刻 connect#2
#                  -> 收 RECV2 秒 -> 关闭。判据 = 第二条连接上**板子照常发数据** (bytes2 显著 > 0)。
#   ⚠️ 关闭语义登记: 板子正在高速发流时 close() 通常发 **RST** (接收缓冲里有未读数据);
#      本脚本另做一档 --close=rst (SO_LINGER 0 强制 RST) 做形态对照。**不许**把两者读成"FIN vs RST 的对照"。
#   ⚠️ 负对照做不到 (D 档也含 A3 代码) ⇒ 只报"修后行为", 不报"修前 vs 修后"。
import argparse, socket, struct, sys, time

RCVBUF = 8 << 20

def mk_sock(host, port, rcvbuf):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, rcvbuf)
    s.settimeout(2.0)
    s.connect((host, port))
    return s

def recv_for(s, secs, bufsz=1 << 20, rate_bps=0):
    """rate_bps > 0 = 匀速节流 (每轮读 bufsz 字节后按速率睡够) ⇒ 板侧窗口被压住.
    ⚠️ 节流的目的是把"关闭那一刻"推到**帧器正卡在窗口门上** (尽力制造 A3 的触发条件)。"""
    n = 0
    t0 = time.time()
    end = t0 + secs
    s.settimeout(0.25)
    while time.time() < end:
        try:
            if rate_bps > 0:
                # 只读到本窗应到的量 (按时间配额), 读满就睡
                quota = int(rate_bps * (time.time() - t0 + 0.02)) - n
                if quota <= 0:
                    time.sleep(0.002)
                    continue
                b = s.recv(min(bufsz, max(4096, quota)))
            else:
                b = s.recv(bufsz)
        except socket.timeout:
            continue
        except OSError as e:
            return n, 'ERR:%s' % e
        if not b:
            return n, 'EOF'
        n += len(b)
    return n, 'OK'

def close_sock(s, mode):
    try:
        if mode == 'rst':
            s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))
        s.close()
    except OSError as e:
        print('CLOSE_ERR %s' % e)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--host', default='192.168.100.2')
    ap.add_argument('--port', type=int, default=8080)
    ap.add_argument('--rounds', type=int, default=3)
    ap.add_argument('--recv1', type=float, default=1.0)
    ap.add_argument('--recv2', type=float, default=1.5)
    ap.add_argument('--close', default='close', choices=['close', 'rst'])
    ap.add_argument('--rate1', type=float, default=0, help='phase1 读速率 (bytes/s, 0=不限)')
    ap.add_argument('--rcvbuf', type=int, default=RCVBUF)
    ap.add_argument('--tag', default='A3')
    a = ap.parse_args()

    print('A3_BEGIN tag=%s host=%s port=%d rounds=%d recv1=%.2f recv2=%.2f close=%s rcvbuf=%d rate1=%.0f'
          % (a.tag, a.host, a.port, a.rounds, a.recv1, a.recv2, a.close, a.rcvbuf, a.rate1), flush=True)
    allok = True
    for r in range(1, a.rounds + 1):
        t0 = time.time()
        try:
            s1 = mk_sock(a.host, a.port, a.rcvbuf)
        except OSError as e:
            print('ROUND %d CONNECT1_FAIL %s' % (r, e), flush=True)
            allok = False
            continue
        t_conn1 = time.time()
        n1, st1 = recv_for(s1, a.recv1, rate_bps=a.rate1)
        t_rcv1 = time.time()
        # 关闭语义: 收在中途 (板子仍在发) => close() 一般发 RST
        close_sock(s1, a.close)
        t_closed = time.time()
        # 立刻重连
        try:
            s2 = mk_sock(a.host, a.port, a.rcvbuf)
        except OSError as e:
            print('ROUND %d CONNECT2_FAIL %s (t=%.6f)' % (r, e, time.time()), flush=True)
            allok = False
            continue
        t_conn2 = time.time()
        n2, st2 = recv_for(s2, a.recv2)
        t_end = time.time()
        close_sock(s2, a.close)
        print('ROUND %d bytes1=%d (%s) bytes2=%d (%s) | conn1_ms=%.2f rcv1_s=%.3f gap_ms=%.2f rcv2_s=%.3f close=%s'
              % (r, n1, st1, n2, st2,
                 (t_conn1 - t0) * 1e3, t_rcv1 - t_conn1,
                 (t_conn2 - t_closed) * 1e3, t_end - t_conn2, a.close), flush=True)
        if n2 <= 0:
            allok = False
    print('A3_END tag=%s all_rounds_bytes2_positive=%s' % (a.tag, 'YES' if allok else 'NO'), flush=True)
    return 0 if allok else 1

if __name__ == '__main__':
    sys.exit(main())
