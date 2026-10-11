#!/usr/bin/env python3
# stall_probe.py -- 微窗 stall 轮: 判别臂 (对端侧, 只发包不碰任何配置)
#   stall 建立后, 从对端注入 N 个"重复 ACK" (ack = 已观测到的 rcv_nxt, win = 指定值)。
#   若机理 = "板等一个窗口通告", 则 win>0 的注入应让板立刻恢复发送; win=0 应毫无变化。
#   判据读数 = 板侧 W20(帧)/W55(retx) 与 sink 是否继续收数据。
#   用法: PROBE_WIN=1460 bash stall_probe.py [等待秒数=3] [注入个数=3] [间隔秒=0.15]
import os, socket, struct, sys, time

WIN = int(os.environ.get("PROBE_WIN", "1460"))
WAIT = float(sys.argv[1]) if len(sys.argv) > 1 else 3.0
N = int(sys.argv[2]) if len(sys.argv) > 2 else 3
GAP = float(sys.argv[3]) if len(sys.argv) > 3 else 0.15
IFACE = "enp1s0f1np1"
BOARD_IP = "192.168.100.2"
MY_IP = "192.168.100.100"
PORT = 8080

def csum(data):
    if len(data) % 2:
        data += b"\x00"
    s = 0
    for i in range(0, len(data), 2):
        s += (data[i] << 8) + data[i+1]
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF

def sniff_and_wait(inject_at=4.0):
    """抓本连接: 对端 SYN 的 ISN + 最近的 (ack, win, 端口);
       并在 **SYN 之后 inject_at 秒** 停止嗅探 ⇒ 此刻正是 stall 中段 (sink 15 s 才超时)。
       每包后检查"是否已到注入时刻" ⇒ 精确对齐连接起点, 不靠墙钟猜。"""
    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.ntohs(0x0003))
    s.bind((IFACE, 0))
    s.settimeout(0.2)
    isn = None; last = None; lport = None; t_syn = None
    t_end = time.time() + 60.0
    while time.time() < t_end:
        if t_syn is not None and time.time() >= t_syn + inject_at:
            break
        try:
            pkt = s.recv(2048)
        except socket.timeout:
            continue
        if len(pkt) < 14 + 20 + 20:
            continue
        if pkt[12:14] != b"\x08\x00":
            continue
        ip = pkt[14:]
        ihl = (ip[0] & 0xF) * 4
        if ip[9] != 6:
            continue
        src = socket.inet_ntoa(ip[12:16])
        tcp = ip[ihl:]
        sport, dport, seq, ack, off_flags = struct.unpack(">HHIIH", tcp[:14])
        flags = off_flags & 0x1FF
        win = struct.unpack(">H", tcp[14:16])[0]
        if src == MY_IP and dport == PORT:
            if flags & 0x02 and not (flags & 0x10):      # 我方 SYN
                isn = seq; lport = sport; t_syn = time.time()
                print("SNIFF_SYN lport=%d isn=%d t=%.6f" % (sport, seq, t_syn), flush=True)
            elif (flags & 0x10) and isn is not None and sport == lport:
                last = (ack, win)
    s.close()
    return isn, lport, last, t_syn

def inject(lport, isn, ack, win, ident, data=b"", flags_extra=0):
    s = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_RAW)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_HDRINCL, 1)
    seq = (isn + 1) & 0xFFFFFFFF
    src = socket.inet_aton(MY_IP); dst = socket.inet_aton(BOARD_IP)
    # ⚠️ doff=5 ⇒ 头必须**恰好 20 字节** (多塞填充会让 IP 总长/doff 不一致; MW9 实测该形态没上线)
    tcp = struct.pack(">HHIIHHHH", lport, PORT, seq, ack, (5 << 12) | 0x10 | flags_extra, win, 0, 0)
    payload = data
    pseudo = src + dst + struct.pack(">BBH", 0, 6, len(tcp) + len(payload))
    tc = csum(pseudo + tcp + payload)
    tcp = tcp[:16] + struct.pack(">H", tc) + tcp[18:]
    tot = 20 + len(tcp) + len(payload)
    ip = struct.pack(">BBHHHBBH4s4s", 0x45, 0, tot, ident & 0xFFFF, 0x4000, 64, 6, 0, src, dst)
    ip = ip[:10] + struct.pack(">H", csum(ip)) + ip[12:]
    s.sendto(ip + tcp + payload, (BOARD_IP, 0))
    s.close()

def main():
    print("PROBE_START win=%d inject_at=%.1fs n=%d gap=%.2f t=%.6f" % (WIN, WAIT, N, GAP, time.time()), flush=True)
    isn, lport, last, t_syn = sniff_and_wait(WAIT)
    if isn is None or last is None or lport is None:
        print("PROBE_FAIL 未抓到握手/ACK (isn=%s lport=%s last=%s)" % (isn, lport, last), flush=True)
        return 2
    print("PROBE_TARGET lport=%d isn=%d last_ack=%d last_win=%d (SYN+%.2fs)" % (
        lport, isn, last[0], last[1], time.time() - t_syn), flush=True)
    for i in range(N):
        inject(lport, isn, last[0], WIN, 0x4000 + i)
        print("PROBE_INJECT i=%d ack=%d win=%d t=%.6f (SYN+%.2fs)" % (
            i, last[0], WIN, time.time(), time.time() - t_syn), flush=True)
        time.sleep(GAP)
    if os.environ.get("PROBE_DATA") == "1":
        # 活性探针: 3 个 1 字节 in-window 数据段 (seq = 对端 ISN+1 = 板的 rcv_nxt)
        # 板若活着 ⇒ 必须推进 rcv_nxt 并回 ACK (与窗口状态无关) ⇒ 用来把"连接还活着但逻辑不放行"
        # 与"连接在板内已消失/失聪"分开。
        for i in range(3):
            inject(lport, isn, last[0], WIN, 0x5000 + i, data=b"\xAA", flags_extra=0x08)
            print("PROBE_DATA i=%d t=%.6f (SYN+%.2fs)" % (i, time.time(), time.time() - t_syn), flush=True)
            time.sleep(GAP)
    # 注入后再盯 1.5 s, 记录板是否立刻回帧
    t_end = time.time() + 1.5
    seen = 0
    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.ntohs(0x0003))
    s.bind((IFACE, 0)); s.settimeout(0.2)
    while time.time() < t_end:
        try:
            pkt = s.recv(2048)
        except socket.timeout:
            continue
        if len(pkt) < 54 or pkt[12:14] != b"\x08\x00":
            continue
        ip = pkt[14:]; ihl = (ip[0] & 0xF) * 4
        if ip[9] != 6:
            continue
        tcp = ip[ihl:]
        sport, dport, seq, = struct.unpack(">HHI", tcp[:8])
        flags = struct.unpack(">H", tcp[12:14])[0] & 0x1FF
        plen = len(ip) - ihl - ((tcp[12] >> 4) * 4)
        if socket.inet_ntoa(ip[12:16]) == BOARD_IP and sport == PORT:
            seen += 1
            print("POST_INJECT_BOARD_FRAME t=%.6f seq=%d len=%d flags=%02x" % (
                time.time() - t_syn, seq, plen, flags), flush=True)
    print("PROBE_DONE board_frames_after_inject=%d t=%.6f" % (seen, time.time() - t_syn), flush=True)
    return 0

if __name__ == "__main__":
    sys.exit(main())
