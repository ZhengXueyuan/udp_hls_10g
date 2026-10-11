#!/usr/bin/env python3
# stall_probe_u7.py -- P7b snd_wnd 守卫板级轮 (2026-10-11): 注入器 (**U7 修正版**)
#   ⭐ 底本 = persist 轮 `stall_probe.py` (md5 2274c15975e78307dc9d9b286da03ffb = microwin 修好版)。
#   ⭐ U7 (审查 FINDINGS §4 末行 + 设计件 §4.6-②): "注入器的 ack 字段必须取**注入时刻**的
#      snd_una..snd_nxt"。原版把 (ack,win) **一次**嗅探后用于全部 n 次注入 —— 嗅探之后
#      板若推进过 snd_una, 该 ack 会落在守卫之外 ⇒ win 注入被**静默吞掉** (正控失效)。
#      本版: ① 每次注入前**现取**最新 ack: 新开一个 AF_PACKET 套接字收集 SNIFF_MS 毫秒
#      (新套接字只看**绑定之后**到达的包 ⇒ 不读陈旧 backlog; 取 ack 最大者 = 最新; ack 单调);
#      ② ACK_MODE 决定怎么用它:
#           fresh       = 直接用          (要求**可接受** ⇒ 守卫放行; task-2 正控口径)
#           fresh_minus = ack - ACK_OFFSET (mod 2^32) ⇒ 刻意**不可接受**(陈旧 ACK) ⇒ 判别臂
#           fresh_plus  = ack + ACK_OFFSET             ⇒ 刻意**不可接受**(越界 ACK) ⇒ 备选
#   其余 (seq = isn+1 / doff=5 / 校验和 / 帧构造 / PROBE_DATA / POST_INJECT) 与原版逐字相同。
#   用法: PROBE_WIN=0 ACK_MODE=fresh bash stall_probe_u7.py [注入时刻=SYN后秒] [n] [gap秒]
import os, socket, struct, sys, time

WIN = int(os.environ.get("PROBE_WIN", "1460"))
ACK_MODE = os.environ.get("ACK_MODE", "fresh")           # U7: fresh | fresh_minus | fresh_plus
ACK_OFFSET = int(os.environ.get("ACK_OFFSET", "4194304")) # U7: 偏移量 (默认 4 MiB)
SNIFF_MS = float(os.environ.get("SNIFF_MS", "20"))        # U7: 每次注入前现取的收集时长 (ms)
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

def parse_pkt(pkt):
    """⭐ U7 新增: 解析一个以太帧 → (src, sport, dport, seq, ack, flags, win) 或 None。
       口径与 sniff_and_wait 内联解析逐字相同 (只抽出来给 drain_latest 复用)。"""
    if len(pkt) < 14 + 20 + 20:
        return None
    if pkt[12:14] != b"\x08\x00":
        return None
    ip = pkt[14:]
    ihl = (ip[0] & 0xF) * 4
    if ip[9] != 6:
        return None
    src = socket.inet_ntoa(ip[12:16])
    tcp = ip[ihl:]
    sport, dport, seq, ack, off_flags = struct.unpack(">HHIIH", tcp[:14])
    flags = off_flags & 0x1FF
    win = struct.unpack(">H", tcp[14:16])[0]
    return src, sport, dport, seq, ack, flags, win

def drain_latest(lport, budget_ms):
    """⭐ U7: 现取"注入时刻"的最新对端 ACK 的 (ack, win)。
       新开套接字 (只看绑定后到达的包) + 收集 budget_ms 毫秒 + 取 ack 最大者 (ack 单调)。"""
    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.ntohs(0x0003))
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 * 1024 * 1024)
    except OSError:
        pass
    s.bind((IFACE, 0)); s.settimeout(0.005)
    best = None; t_end = time.time() + budget_ms / 1000.0
    while time.time() < t_end:
        try:
            pkt = s.recv(2048)
        except socket.timeout:
            continue
        except OSError:
            break
        f = parse_pkt(pkt)
        if f is None:
            continue
        src, sport, dport, seq, ack, flags, win = f
        if src == MY_IP and dport == PORT and sport == lport and (flags & 0x10):
            if best is None or ((ack - best[0]) & 0xFFFFFFFF) < 0x80000000:
                best = (ack, win)
    s.close()
    return best

def sniff_and_wait(inject_at=4.0):
    """抓本连接: 对端 SYN 的 ISN + 最近的 (ack, win, 端口);
       并在 **SYN 之后 inject_at 秒** 停止嗅探 ⇒ 此刻正是 stall 中段 (sink 15 s 才超时)。
       每包后检查"是否已到注入时刻" ⇒ 精确对齐连接起点, 不靠墙钟猜。
       ⭐ U7: 套接字**保持打开** (drain_latest 之外的兜底), 返回值多一个 s。"""
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
    return isn, lport, last, t_syn, s

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
    print("PROBE_START win=%d inject_at=%.1fs n=%d gap=%.2f ack_mode=%s ack_offset=%d sniff_ms=%.1f t=%.6f" % (
        WIN, WAIT, N, GAP, ACK_MODE, ACK_OFFSET, SNIFF_MS, time.time()), flush=True)
    isn, lport, last, t_syn, sock = sniff_and_wait(WAIT)
    if isn is None or last is None or lport is None:
        print("PROBE_FAIL 未抓到握手/ACK (isn=%s lport=%s last=%s)" % (isn, lport, last), flush=True)
        return 2
    print("PROBE_TARGET lport=%d isn=%d last_ack=%d last_win=%d (SYN+%.2fs)" % (
        lport, isn, last[0], last[1], time.time() - t_syn), flush=True)
    ack_use = last[0]
    for i in range(N):
        fresh = drain_latest(lport, SNIFF_MS)               # ⭐ U7: 注入时刻现取
        src_tag = "held"
        if fresh is not None:
            last = fresh; src_tag = "fresh"
        if ACK_MODE == "fresh":
            ack_use = last[0]
        elif ACK_MODE == "fresh_minus":
            ack_use = (last[0] - ACK_OFFSET) & 0xFFFFFFFF
        elif ACK_MODE == "fresh_plus":
            ack_use = (last[0] + ACK_OFFSET) & 0xFFFFFFFF
        else:
            print("PROBE_FAIL 未知 ACK_MODE=%s" % ACK_MODE, flush=True)
            return 3
        inject(lport, isn, ack_use, WIN, 0x4000 + i)
        print("PROBE_INJECT i=%d ack=%d win=%d ack_src=%s fresh_ack=%d fresh_win=%d t=%.6f (SYN+%.2fs)" % (
            i, ack_use, WIN, src_tag, last[0], last[1], time.time(), time.time() - t_syn), flush=True)
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
    sock.close()
    return 0

if __name__ == "__main__":
    sys.exit(main())
