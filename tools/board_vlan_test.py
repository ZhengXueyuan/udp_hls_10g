#!/usr/bin/env python
"""board_vlan_test.py — P4d 板级 VLAN fast path 验收 (scapy 注入 + 回显判定)

原理: 板子 fast path 的 VLAN 剥离 (vlan_strip) 把 802.1Q tag 删掉后交给
rx_classify/tcp_rx (无 tag 布局)。板级验证 = 在一条**已建立且空闲**的 TCP
连接上注入一个**带 tag** 的数据段 (seq/ack 精确续接), 板侧应:
  ① 剥掉 tag -> fast path 正常处理 -> echo 回来 (无 tag, 载荷逐字节一致)
  ② 若剥离失效, 帧将因 TPID 落 byte 12-13 被判非 IPv4 -> 走慢路径 HLS
     -> 不回 echo (判定失败, 可检出)

步骤:
  1. python socket 连 192.168.100.2:8080 (正常握手, 板侧 fast path 建 TCB)
  2. 发 20B 探针, sniff 捕获探针段 (得 PC seq) 与 echo (得板侧 seq/ack)
  3. scapy sendp 注入: Ether/Dot1Q(vlan=0)/IP/TCP(seq=探针seq+20,
     ack=板侧snd_nxt)/Raw(100B)
  4. sniff 等 echo: 载荷 == 注入载荷 && 帧无 Dot1Q -> PASS
     同时 socket recv 应收 == 注入载荷 (板侧 rcv 流被注入段推进)

用法: python tools/board_vlan_test.py [--iface NPF路径] [--no-inject]
      --no-inject = 只跑基线 (普通段 echo), 用于对照
"""
import socket
import struct
import sys
import threading
import time

from scapy.all import UDP, Dot1Q, Ether, IP, Raw, TCP, conf, get_if_hwaddr, sendp, sniff

conf.use_pcap = True

BOARD_IP = "192.168.100.2"
BOARD_PORT = 8080
BOARD_MAC = "00:0a:35:01:fe:c0"          # 板级 MAC (cfg_src_mac, 抓包实锤)
PC_IP = "192.168.100.1"
IFACE = r"\Device\NPF_{528A3E8C-9A80-4D17-96A0-48F3FD70186E}"   # Killer NIC
PROBE_LEN = 20
INJECT_LEN = 107          # MW 判决用: UDP 帧体 = 14+[4]+28+107 = 153(带tag) / 149;
                          # ceil(/8) = 20 词 vs 19 词 — 恰跨 8B 边界 (tag 4B 在线
                          # 则多 1 词)。UART MW 计数差 = tag 是否真上线


def payload(n, seed=0x41):
    return bytes(((i * 7 + seed) & 0xFF) for i in range(n))


def sniff_collect(iface, flt, stop_evt, out):
    """后台抓包直到 stop_evt 置位; out 收包列表 (线程内 append)。"""
    def prn(p):
        out.append(p)
    try:
        sniff(iface=iface, filter=flt, prn=prn, stop_filter=lambda p: stop_evt.is_set())
    except Exception as e:
        print("sniff err:", e)


def find_tcp(pkts, src, dport, payload_bytes=None):
    """在包里找 TCP 段; src = 'pc'|'board'。"""
    for p in pkts:
        if not p.haslayer(TCP) or not p.haslayer(IP):
            continue
        ip = p[IP]
        if src == "pc" and (ip.src != PC_IP or p[TCP].dport != dport):
            continue
        if src == "board" and (ip.src != BOARD_IP or p[TCP].sport != dport):
            continue
        if payload_bytes is not None:
            if bytes(p[TCP].payload) != payload_bytes:
                continue
        return p
    return None


def uart_mw(port="COM9", timeout=20.0):
    """读 COM9 的一行完整快照 (行每 ~5s 一发), 返回 MW (mac_rx_64 出词计数)。"""
    import re
    import serial
    try:
        sp = serial.Serial(port, 9600, timeout=3.0)
    except Exception as e:
        print("uart open fail:", e)
        return None
    try:
        buf = b""
        t0 = time.time()
        while time.time() - t0 < timeout:
            chunk = sp.read(512)
            if chunk:
                buf += chunk
                ms = re.findall(rb"MW=([0-9A-Fa-f]{8})", buf)
                # 取最后一次出现 (防驱动缓冲里的旧行), 且其后须有 CRLF (整行已到)
                if ms and b"\r\n" in buf[buf.rfind(b"MW="):]:
                    return int(ms[-1], 16)
    finally:
        sp.close()
    print("uart read timeout (buf %d bytes)" % len(buf))
    return None


def mw_test(iface, pc_mac):
    """精确窗口 MW 判决: tagged/untagged 各注一帧, 比较 MW 增量差。
    用 **UDP 到未服务端口 9999** (HLS 只认 8080, 静默丢弃) — 板侧不回帧, PC 栈
    无反应, MW 增量 = 注入帧自身词数: tagged 帧体 58+103=161 -> 21 词,
    untagged 157 -> 20 词 (mac_rx_64 剥 FCS 后按 8B/词)。差 1 = tag 真上线。"""
    res = {'tagged': [], 'untagged': []}
    for _rd in range(3):
        for tag_on in (True, False):
            mw0 = uart_mw()
            if mw0 is None:
                print("MW-TEST FAIL: UART 读失败")
                return 1
            inj_pay = payload(INJECT_LEN, 0x42 if tag_on else 0x43)
            inner = IP(src=PC_IP, dst=BOARD_IP) / \
                UDP(sport=lport_unused(), dport=9999) / Raw(inj_pay)
            frame = Ether(src=pc_mac, dst=BOARD_MAC) / \
                (Dot1Q(vlan=0) if tag_on else Raw(b"")) / inner
            sendp(frame, iface=iface, verbose=False)
            time.sleep(0.5)
            mw1 = uart_mw()
            if mw1 is None:
                print("MW-TEST FAIL: UART 读失败(2)")
                return 1
            d = mw1 - mw0
            res['tagged' if tag_on else 'untagged'].append(d)
            print("r%d %s 注入: MW %08X -> %08X (delta %d 词)" %
                  (_rd, "tagged" if tag_on else "untagged", mw0, mw1, d))
            time.sleep(0.6)

    dt = min(res['tagged'])              # 最小 = 最干净窗口 (无旁路帧混入)
    du = min(res['untagged'])
    print("各轮: tagged=%s untagged=%s" % (res['tagged'], res['untagged']))
    print("判决 (取最小): tagged=%d untagged=%d 差=%d" % (dt, du, dt - du))
    if dt - du == 1:
        print("MW-TEST OK: tag 确实上线 (tagged 恰多 1 词 = 4B tag 跨词边界)")
        return 0
    if dt == du:
        print("MW-TEST INCONCLUSIVE: 无词数差 — PC 网卡可能自行剥掉 tag (对 shim 无结论)")
        return 2
    print("MW-TEST ODD: 差值 = %d (预期 1 或 0)" % (dt - du))
    return 1


def lport_unused():
    return 40000


def main():
    iface = IFACE
    if "--iface" in sys.argv:
        iface = sys.argv[sys.argv.index("--iface") + 1]
    tag_on = "--untagged" not in sys.argv
    no_inject = "--no-inject" in sys.argv
    pc_mac = get_if_hwaddr(iface)
    print("iface=%s pc_mac=%s tag=%s" % (iface, pc_mac, tag_on))

    if "--mw-test" in sys.argv:
        pc_mac = get_if_hwaddr(iface)
        print("mw-test iface=%s pc_mac=%s" % (iface, pc_mac))
        return mw_test(iface, pc_mac)

    s = socket.create_connection((BOARD_IP, BOARD_PORT), timeout=5)
    lport = s.getsockname()[1]
    print("connected, local port %d" % lport)
    flt = "tcp and port %d" % lport

    pkts = []
    stop = threading.Event()
    th = threading.Thread(target=sniff_collect, args=(iface, flt, stop, pkts), daemon=True)
    th.start()
    time.sleep(0.3)

    # ---- 1) 基线: 探针段 + echo ----
    probe = payload(PROBE_LEN, 0x41)
    s.sendall(probe)
    got = b""
    t0 = time.time()
    while len(got) < PROBE_LEN and time.time() - t0 < 3:
        try:
            got += s.recv(4096)
        except socket.timeout:
            break
    print("baseline echo: sent %d got %d %s" % (len(probe), len(got),
          "OK" if got == probe else "MISMATCH"))
    if got != probe:
        print("VLAN TEST FAIL (baseline 基线 echo 不通 — 连接/板卡状态问题)")
        stop.set(); s.close(); return 1

    time.sleep(0.3)
    seg = find_tcp(pkts, "pc", BOARD_PORT, probe)
    echo = find_tcp(pkts, "board", BOARD_PORT, probe)
    if seg is None or echo is None:
        print("VLAN TEST FAIL (抓包缺探针段/echo; pkts=%d)" % len(pkts))
        stop.set(); s.close(); return 1
    pc_seq = seg[TCP].seq
    board_snd = echo[TCP].seq
    print("probe: pc_seq=%d board_echo_seq=%d ack=%d" %
          (pc_seq, board_snd, echo[TCP].ack))

    inj_seq = (pc_seq + PROBE_LEN) & 0xFFFFFFFF
    inj_ack = (board_snd + PROBE_LEN) & 0xFFFFFFFF   # echo 长 = 探针长

    if no_inject:
        print("no-inject: 只跑基线 -> VLAN TEST BASELINE OK")
        stop.set(); s.close(); return 0

    # ---- 2) 注入数据段 (默认带 tag; --untagged = 对照组) ----
    # 载荷 103B 使字数可分辨: tagged 帧体 58+103=161 -> 21 词; untagged 157 -> 20 词
    # (板侧 UART MW 计数差 = 判决 tag 是否真上线: 21=线上有 tag 且被 shim 剥掉后
    #  fast path 回显; 20=PC 网卡自己剥了 tag, 对 shim 无结论)
    inj_pay = payload(INJECT_LEN, 0x42)
    inner = IP(src=PC_IP, dst=BOARD_IP) / \
        TCP(sport=lport, dport=BOARD_PORT, seq=inj_seq, ack=inj_ack, flags="PA") / \
        Raw(inj_pay)
    if tag_on:
        frame = Ether(src=pc_mac, dst=BOARD_MAC) / Dot1Q(vlan=0) / inner
    else:
        frame = Ether(src=pc_mac, dst=BOARD_MAC) / inner
    print("inject: seq=%d ack=%d len=%d (%s)" %
          (inj_seq, inj_ack, INJECT_LEN, "802.1Q tag vlan=0" if tag_on else "untagged"))
    sendp(frame, iface=iface, verbose=False)

    # ---- 3) 等 echo (板侧剥 tag 后 fast path 回显, 无 tag) ----
    got2 = b""
    t0 = time.time()
    while len(got2) < INJECT_LEN and time.time() - t0 < 4:
        s.settimeout(0.5)
        try:
            got2 += s.recv(4096)
        except socket.timeout:
            continue
    time.sleep(0.3)
    stop.set()
    echoed = find_tcp(pkts, "board", BOARD_PORT, inj_pay)
    tag_in_echo = any(p.haslayer(Dot1Q) for p in pkts if p.haslayer(TCP))

    # 回显帧无 tag 判定: 只看 echo 匹配帧自身 (不扫全抓包 — 本机注入帧可能
    # 被 npcap 也抓到, 会把带 tag 的"我方发送帧"误算进来)
    echo_tag = echoed is not None and echoed.haslayer(Dot1Q)
    print("socket recv: %d/%d bytes %s (PC 栈语义不可靠: 注入段绕过栈, 其 ACK 号"
          " 使 PC 可能丢返回段 — 仅参考)" %
          (len(got2), INJECT_LEN, "OK" if got2 == inj_pay else "MISMATCH"))
    print("sniff echo: %s, echo 自身带 tag: %s" %
          ("OK" if echoed is not None else "缺失", echo_tag))
    print("注: 判据 = echo 匹配帧存在且无 tag; tag 是否真上线另由 UART MW 计数差判"
          " (tagged 21 词 / untagged 20 词)")

    ok = (echoed is not None) and (not echo_tag)
    print("VLAN TEST " + ("OK (注入段被 fast path 回显)" if ok else "FAIL"))
    s.close()
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
