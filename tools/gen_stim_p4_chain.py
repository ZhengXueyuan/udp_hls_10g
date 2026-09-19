#!/usr/bin/env python
"""P4a 全链 (mac_rx_64->rx_classify->{fast TCP 链, slow HLS 链}->tx_arb->mac_tx_64)
刺激 + 语义校验。慢路径带**真 HLS udp_echo** (158 个综合 verilog 进 xsim)。

拓扑: classify 按 ethertype/proto 分流; ARP/ICMP/UDP -> slow_rx_adp -> HLS
-> slow_tx_adp; TCP -> P3 链 (tcp_synp 握手 conn0; conn1 TB 预配)。
TX 汇合 tx_arb (fast 优先) — 快慢两流在 GMII 捕获里自由交错。

校验全语义级 (HLS 应答拍级不可预期; classify 周期精确由单元 TB 覆盖):
- 慢流顺序 = RX 顺序 (HLS 串行处理): arp_reply / icmp_reply / udp_echo / arp_reply
  逐帧谓词 (关键字段 + IP/ICMP 校验和 + 载荷逐字节 + FCS)
- 快流 = tb_tcp_echo 的逐字节匹配 (kind/cid/seq/ack/plen + expected_frame_bytes,
  ip id = 快流内序号 — 慢帧不过 tcp_tx_frame 不占 id)
- 事件计数 (FEND/SYNP/ACK) + STATS7/TX/ECO/CAMF/TCBF 精确 + 慢路径统计
帧间距: 慢帧后 20000B (HLS 应答余量), TCP 段 1500B (tx 排空)。
"""
import json
import os
import struct
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_stim_tcp_chain as C

# P4 统一 MAC = C0 (HLS 编译期值); fast path cfg_src_mac 同步 C0。
C.DUT_MAC = bytes([0x00, 0x0A, 0x35, 0x01, 0xFE, 0xC0])
DUT_MAC = C.DUT_MAC
DUT_IP = C.DUT_IP
PC_MAC = bytes([0x11, 0x22, 0x33, 0x44, 0x55, 0x66])   # = CONN[0].dmac
PC_IP = 0xC0A86401                                    # 192.168.100.1
payload = C.payload
csum16 = C.csum16
PRE = C.PRE

# P4b: 握手归慢路径 HLS — conn0 的 TCP 帧源必须 = ARP 学到的 PC 身份
# (192.168.100.1), 否则 HLS ARP 查不到 → SYN+ACK 走广播。CONN[0] 原为
# 10.0.0.1 (chain 时代), 在此覆盖为 PC_IP。
C.CONN[0]['sip'] = PC_IP
# P4c: conn0 的我方通告窗 = 48K。RTL 实际写 TCB 的值 = slow_cfg_adp 里手打
# 的 0x0000C000 (HLS cfg 记录只带对端窗, 我方 rcv_wnd 由 RTL 常量落盘); 此处
# 覆盖 CONN[0]['rcv_wnd'] 使 expected_frame_bytes 的 echo 帧窗口字段 (由 RTL
# rb_rcv_wnd 生成) 与之一致。旧 TB (tb_tcp_chain/echo) 仍走各自生成器的
# 0x3000 模型 (tcp_synp 路径), 不受影响。
C.CONN[0]['rcv_wnd'] = 0xC000
HLS_ISS = 0x12345678          # HLS layer_tcp 的我方 ISS (cid=0)
HS_ACKVAL = HLS_ISS + 1       # 握手 ACK 应确认的值 = SYN+ACK 发出后的 snd_nxt

GAP_SLOW = 20000       # 慢帧后的 HLS 应答余量
GAP_TCP = 1500         # TCP 段间 (tx 排空)


def ip_hdr_p(src_ip, dst_ip, proto, total_len):
    h = bytearray(struct.pack('!BBHHHBBH', 0x45, 0, total_len & 0xFFFF,
                              0x4321, 0, 64, proto, 0))
    h += struct.pack('!4s4s', struct.pack('!I', src_ip), struct.pack('!I', dst_ip))
    h[10:12] = struct.pack('!H', csum16(struct.unpack('!10H', bytes(h[:20]))))
    return bytes(h)


def finish(fb):
    if len(fb) < 60:
        fb += b'\x00' * (60 - len(fb))
    return fb, struct.pack('<I', zlib.crc32(fb) & 0xFFFFFFFF)


def mk_arp_req():
    body = struct.pack('!HHBBH', 1, 0x0800, 6, 4, 1)
    body += PC_MAC + struct.pack('!I', PC_IP)
    body += b'\x00' * 6 + struct.pack('!I', DUT_IP)
    return finish(b'\xFF' * 6 + PC_MAC + b'\x08\x06' + body)


def mk_icmp_req(ident=0x1234, seq=1, n=32):
    pl = payload(n)
    ic = struct.pack('!BBHHH', 8, 0, 0, ident, seq) + pl
    pad = b'\x00' if len(ic) % 2 else b''
    cs = csum16(struct.unpack('!%dH' % (len(ic + pad) // 2), ic + pad))
    ic = ic[:2] + struct.pack('!H', cs) + ic[4:]
    fb = DUT_MAC + PC_MAC + b'\x08\x00' + ip_hdr_p(PC_IP, DUT_IP, 1, 20 + len(ic)) + ic
    fb, fcs = finish(fb)
    return fb, fcs, pl


def mk_udp(sport=0x9C42, dport=0x1F90, n=24):
    pl = payload(n)
    uh = struct.pack('!HHHH', sport, dport, 8 + n, 0)
    fb = DUT_MAC + PC_MAC + b'\x08\x00' + ip_hdr_p(PC_IP, DUT_IP, 17, 20 + 8 + n) + uh + pl
    fb, fcs = finish(fb)
    return fb, fcs, pl


# SYN 固定带 WS=8 (Windows 实测值, doff=8) — P4b-6 板测根因: 旧 HLS 钳
# ws<=7 把 Windows 的 8 变 0 → fast 门控用原始窗口 → 死锁。此值让 wscale
# 缩放链 (HLS 解析 -> cfg w0[19:16] -> slow_cfg_adp 第 7 字段 -> tcp_rx
# drain 移位钳位) 在 Windows 量纲下真实交战。
SYN_WSCALE = 8


def mk_syn_ws(wnd=0x2000, wscale=SYN_WSCALE):
    """SYN (doff=6): 选项 [kind=3 len=3 val=wscale, NOP]。"""
    c = C.CONN[0]
    eth = DUT_MAC + c['dmac'] + b'\x08\x00'   # SYN: dst=DUT, src=PC
    tcp = struct.pack('!HHLLBBHHH', c['sport'], c['dport'], 999, 0,
                      0x60, 0x02, wnd, 0, 0) + bytes([3, 3, wscale, 1])
    ph = struct.pack('!4s4sBBH', struct.pack('!I', c['sip']),
                     struct.pack('!I', c['dip']), 0, 6, len(tcp))
    buf = ph + tcp
    if len(buf) % 2:
        buf += b'\x00'
    cs = csum16(struct.unpack('!%dH' % (len(buf) // 2), buf))
    tcp = tcp[:16] + struct.pack('!H', cs) + tcp[18:]
    fb = eth + C.ip_hdr(c['sip'], c['dip'], 20 + len(tcp)) + tcp
    if len(fb) < 60:
        fb += b'\x00' * (60 - len(fb))
    return finish(fb)


def read_trunc(simdir):
    """P4b-7-P6 截断注入参数: trunc.memh 由 run_tb_p4_burst.bat 写入 ("N M",
    bat 环境变量 TRUNC/TRUNCM); 文件缺失 = (0, 8) 关。与 txdrop.memh 同通道 —
    xsim loader 会拆含 '=' 的 -testplusarg ("TRUNC=N" 到不了 TB), 文件绕开。"""
    try:
        with open(os.path.join(simdir, 'trunc.memh')) as fh:
            v = [int(x) for x in fh.read().split()]
        return (v[0], v[1] if len(v) > 1 else 8)
    except (OSError, ValueError, IndexError):
        return (0, 8)


def read_halfdrop(simdir):
    """P4b-7-P6 半帧中止注入参数: halfdrop.memh 由 run_tb_p4_burst.bat 写入
    ("N K", bat 环境变量 HALFDROP/HALFDROPK); 文件缺失 = (0, 0) 关。与
    trunc.memh/txdrop.memh 同通道 (xsim loader 拆含 '=' 的 -testplusarg)。
    N = 第 N 个 conn0 数据段 (编号同 TRUNC/TXDROP: data7a=1, data7b=2,
    burst_k=k+3); K = 停线前已发出的载荷字节数 (线上帧 = 54B 头 + K 字节载荷,
    无 FCS/tlast — 板上 PC/NIC 驱动重启时 TX DMA 半途中断的帧形)。"""
    try:
        with open(os.path.join(simdir, 'halfdrop.memh')) as fh:
            v = [int(x) for x in fh.read().split()]
        return (v[0], v[1] if len(v) > 1 else 0)
    except (OSError, ValueError, IndexError):
        return (0, 0)


def build_rx_frames(burst=0, pause_at=-1, pause_len=0, burst_wnd=0x4000,
                    tail608=False, dupstorm=False, trunc_at=0, trunc_len=8,
                    half_at=0, half_k=0):
    """返回 (F, pmap)。pmap: conn0 每数据段的 echo seq (hex str) -> 该段载荷
    (hex str, 全 plen 字节)。echo seq = conn0 snd_nxt 链 (握手后 = HS_ACKVAL,
    每段累加实际 plen)。burstcheck 用它逐字节验证 echo 与 ring 重放帧 (P4b-7-P5):
    ring 回放帧是原字节流的连续切片, 不保证切在段界 — 校验按流偏移做。

    P4b-7-P6 截断注入: trunc_at = 第 N 个 conn0 数据段 (1 基, 与 TXDROP 同编号:
    data7a=1, data7b=2, burst_k=k+3), 0 = 关。该段线上帧头全保原样 (同 seq /
    IP total_len=40+plen=1500 / TCP 头 / 源端口) 而载荷只发前 trunc_len 字节,
    FCS 按截断后内容重算 — 复现板级 PC/NIC 截断帧 (线上 54+trunc_len+4 字节,
    FCS 有效)。后续段 seq/载荷不变 (PC 无感, 板上全判 OOO)。截断缺口只能由
    PC 侧重传补回 (板上 ring 只有真实的 trunc_len 字节): 尾部追加 PC RTO
    重传 — 自 seq+trunc_len 重发本段剩余, 其后被丢各段按原样重放。

    P4b-7-P6 半帧中止注入 (half_at > 0, 与 trunc_at 互斥): half_at = 第 N 个
    conn0 数据段 (编号同上)。该段线上只发帧头 54B (seq / IP total_len=1500 /
    TCP 头 / csum 全保原样) + 前 half_k 字节载荷, 随即停线 — 无 FCS, 无 tlast,
    帧后为普通 IFG 空闲 (下一帧前导正常)。复现板级 PC/NIC 驱动重启时 TX DMA
    半途中断打出的半帧。链 TB 的 mac_rx_64 对线上中止走 S_DATA 帧尾支: 残段
    仍交付一拍 push_last=1/push_crs=0 (≠ 板上"半帧词不入流"), 故 TB 在
    mac_rx->classify 边界抹掉该残段拍的 tlast (tb_p4_chain.v HALFDROP 掩码,
    halfdrop.memh 与生成器同源) — 与板级中止行为对齐。半帧无 tlast → tcp_rx
    的 pend_rcv 需 s_axis_tcrs → rcv_nxt 不推进 → 其后原发段全 OOO 被丢;
    echo 侧残留 (has_data 无 fend) 与后续帧合并 (P6 冻结根因)。缺口只能由 PC
    重传补回: 尾部追加 seq=S 整段重传 + 其后各段原样重放。

    合法性 (half_k): (a) K >= 6: 帧头 54B 走完 TCP 头, mac_rx 剔掉末 4 字节
    前瞻后仍含 w6 (meta_valid 需 wcnt==6); (b) (50+K) % 8 == 0 (K ≡ 6 mod 8):
    残段尾字在 tcp_rx 侧整字落地 — 尾拍 tkeep != 0xFF 且 (抹后) 无 tlast 会把
    tcp_rx 打进 S_DROP (S_DROP 只在真 tlast 退出) → 变成"吞掉后续整帧", 注入
    语义不再是"SOP 截断防御"; (c) K < 该段 plen (否则不是半帧)。"""
    F = []
    pmap = {}

    def add(name, fb, fcs, gap):
        F.append(dict(name=name, fb=fb, fcs=fcs, gap=gap))

    fb, fcs = mk_arp_req()
    add('arp1', fb, fcs, GAP_SLOW)
    fb, fcs, _pl = mk_icmp_req()
    add('icmp1', fb, fcs, GAP_SLOW)
    fb, fcs, _pl = mk_udp()
    add('udp1', fb, fcs, GAP_SLOW)
    fb, fcs = mk_syn_ws()            # SYN 带 WS=2 (wscale 链覆盖)
    add('syn', fb, fcs, 300)
    # P4b: hs_ack 前留 GAP_SLOW (gap 是帧前间距! 改 syn 的 gap 只会推迟 syn
    # 自己) — 真实 TCP 里 PC 要等收到 SYN+ACK 才发数据; HLS 处理 SYN + cfg
    # 落地 ~4k 拍 (wire 时间), 300B 的旧间距会让 hs_ack/data 在 fast 路径
    # CAM/TCB 配好前到达被丢 (SYN 重传才能救)。
    fb, fcs = C.mk_tcp_frame(0, 1000, HS_ACKVAL, 0x10, 0, 0x4000, True)
    add('hs_ack', fb, fcs, GAP_SLOW)
    fb, fcs = C.mk_tcp_frame(0, 1000, HS_ACKVAL, 0x18, 7, 0x4000, True)
    add('data7a', fb, fcs, GAP_TCP)
    fb, fcs = C.mk_tcp_frame(0, 1007, HS_ACKVAL, 0x18, 9, 0x4000, True)
    add('data7b', fb, fcs, GAP_TCP)
    # echo 载荷地图: data7a echo seq = 0x12345679 (握手后 snd_nxt = HLS_ISS+1,
    # 板测/TCBF 观序实证), data7b = +7, burst 段顺延实际 plen (pause/608 变体
    # 由生成器 plen 决定, 与 RX seq 书签无关 — echo seq 只看 snd_nxt 侧累加)。
    eseq = HS_ACKVAL
    pmap['%X' % eseq] = C.payload(7).hex()
    eseq += 7
    pmap['%X' % eseq] = C.payload(9).hex()
    eseq += 9
    # P4b-5 排障: burst 模式 — 连续大段 (1460B, 线速帧距 12B), 复现板级
    # 吞吐测试的 echo 停滞。seq 从 1016 起每段 +1460。
    # P4b-6: pause_at >= 0 时, 第 pause_at 段改 352B 载荷 (停顿前末段尾包),
    # 其后一段 gap 拉 pause_len — 模拟板测抓到的 PC 发送停顿-恢复。
    # P4b-7-P6 截断注入合法性 — S_PAY 截断支 + 逐字节可验的 M 范围:
    #  (a) M <= 10: 帧 ≤ 64B 体, 末字必为部分字 (pop8w < pay_r) → 走 S_PAY 截断支;
    #      M >= 55 会变成满载荷多字 (不再截断);
    #  (b) M >= 6: finish() 只补到 60B 最小帧 — M<=5 的帧 (54+M<60) 被填零到
    #      60B, 板上把填充当载荷收 (echo plen=6+), 注入语义不再等长;
    #  (c) M=0..2: w6-截断支 (fend_w6t) — 帧体 54+M <= 56 无 pad, tlast 落 w6
    #      拍 (finish 的 60B 补零会把 tlast 推到 w7 走 S_PAY); 0 字节交付,
    #      rcv_nxt 不推进, ACK 停 s_tr, PC RTO 重传补缺口。
    #      RTL 侧真实字节 = pop8w+2 (M<=8) / 8+尾字 (M=9,10) = M 恒等。
    if trunc_at and not (3 <= trunc_at <= burst + 2 and
                         (0 <= trunc_len <= 2 or 6 <= trunc_len <= 10)):
        print('TRUNC 参数非法: at=%d len=%d (需 at 3..%d, len 0..2 或 6..10)'
              % (trunc_at, trunc_len, burst + 2))
        sys.exit(2)
    # P4b-7-P6 半帧中止注入合法性 (见 docstring): 段号范围 + K 的取整/幅度
    if half_at:
        if not (3 <= half_at <= burst + 2):
            print('HALFDROP 参数非法: at=%d (需 3..%d = data7a..burst 末段)'
                  % (half_at, burst + 2))
            sys.exit(2)
        if half_k < 6 or (50 + half_k) % 8 != 0:
            print('HALFDROP 参数非法: k=%d (需 >=6 且 (50+k)%%8==0 -> k ≡ 6 mod 8)'
                  % half_k)
            sys.exit(2)
        if trunc_at:
            print('HALFDROP 与 TRUNC 不能同时注入 (同一帧两种篡改)')
            sys.exit(2)
    seq = 1016
    seq_hist = []
    segs = []          # burst 各段 (seq, plen) — 截断自愈重传重放用
    dfi = 2            # conn0 数据段计数 (data7a=1, data7b=2 已过)
    for b in range(burst):
        if b == pause_at:
            plen = 352
        elif tail608 and (b % 9) == 8:
            plen = 608      # PC 12KB 窗口尾包 (8x1460+608) — 板测段模式
        else:
            plen = 1460
        segs.append((seq, plen))
        dfi += 1
        fb, fcs = C.mk_tcp_frame(0, seq, HS_ACKVAL, 0x18, plen, burst_wnd, True)
        if dfi == trunc_at:
            # 截断帧: 头 (:total_len=40+plen=1500 / seq / 端口 / 原 csum) 原样,
            # 载荷只留前 trunc_len 字节, FCS 按截断后内容重算
            hdr = 14 + (fb[14] & 0xF) * 4 + 20      # eth + TCP + IP = 54
            if trunc_len <= 2:
                # w6 截断支: 无 pad (finish 的 60B 补零会把 tlast 推到 w7 走
                # S_PAY) — 帧体 54+M <= 56B, tlast 落 w6 拍 → fend_w6t 路径
                fb = fb[:hdr] + C.payload(plen)[:trunc_len]
                fcs = struct.pack('<I', zlib.crc32(fb) & 0xFFFFFFFF)
            else:
                fb, fcs = finish(fb[:hdr] + C.payload(plen)[:trunc_len])
            add('burst%d' % b, fb, fcs, 12)         # 截断帧照常上线 (载短+重算 FCS)
        elif dfi == half_at:
            # 半帧中止: 帧头 54B 原样 (total_len/csum 仍按满载荷 1460 承诺),
            # 只发前 half_k 字节载荷, 线上就此停住 — 无 FCS (fcs=b'' 使
            # gen_memh 不追加 FCS 字节, 帧后直接进 IFG 空闲; 布局仍为其留位)
            if half_k >= plen:
                print('HALFDROP 参数非法: k=%d >= 该段 plen=%d (不是半帧)'
                      % (half_k, plen))
                sys.exit(2)
            hdr = 14 + (fb[14] & 0xF) * 4 + 20      # eth + TCP + IP = 54
            add('half%d' % b, fb[:hdr] + C.payload(plen)[:half_k], b'', 12)
        else:
            add('burst%d' % b, fb, fcs, 12)
        seq_hist.append(seq)
        seq += plen
        pmap['%X' % eseq] = C.payload(plen).hex()
        eseq += plen
        # dupstorm: 窗口边界后重放最后 2 段 (旧 seq = 重传) — 板测实锤的
        # 重传风暴 (ackresp 纯 ACK 路径与 echo 交错是空洞嫌疑场景)。
        # RX 重放段是 dup (seq < rcv_nxt → 纯 ACK 应答, 无 echo) — 不进 pmap。
        if dupstorm and (b % 9) == 8 and b >= 2:
            for d in (b - 2, b - 1):
                fb, fcs = C.mk_tcp_frame(0, seq_hist[d], HS_ACKVAL, 0x18,
                                         1460, burst_wnd, True)
                add('dup%d_%d' % (b, d), fb, fcs, 12)
            # RTT 间隙 (12KB 窗口周期: PC 等 ACK ~0.1ms = 12500 拍)
            if len(F) >= 1:
                F[-1]['gap'] = 12500
    if 0 <= pause_at < burst - 1:
        F[pause_at + 1 + 7]['gap'] = pause_len   # +7: 前 7 帧 (arp..data7b)
    # ---- P4b-7-P6 截断自愈 (仅 trunc_at): 截断段之后的原发段在板上全判 OOO
    #      (rcv_nxt 停在 S+trunc_len, 板上逐帧回 dup-ACK 但丢载荷), 缺口只能由
    #      PC 重传补回。模型 = PC RTO 自 snd_una=S+trunc_len 起重发剩余字节,
    #      其后被丢各段按原样重放 (seq/plen 不变)。板上顺序收下 → echo 流
    #      (截断段 8B 短帧 + 续传帧) 重新连续, 覆盖并集回到完整原计划。----
    if trunc_at:
        hi = trunc_at - 3
        s0, p0 = segs[hi]
        # 重传段恰为缺口长度 (snd_nxt - snd_una = p0 - adv, < MSS):
        # 不能补满 1460 — 多发的字节会越过下一段起点, 板上把下一段判 dup
        # 丢掉 → 覆盖反而破洞 (真实 TCP tcp_retransmit_skb 同样按 snd_nxt
        # 截断到 MSS 或更短)。载荷必须按流偏移切 payload(p0)[adv:]
        # (payload(n) 是序号索引函数: payload(p0-adv) 会从段头重来,
        #  板级实测 = echo 载荷整体回退 adv 字节)。
        # adv = 板上真实收下的字节: S_PAY 截断 = trunc_len; w6 截断 = 0
        # (fend_w6t 不推进 rcv_nxt — PC ACK 只确认 s_tr, RTO 从 s_tr 整段重发)
        adv = trunc_len if trunc_len >= 6 else 0
        fb, fcs = C.mk_tcp_frame(0, s0 + adv, HS_ACKVAL, 0x18,
                                 p0 - adv, burst_wnd, True)
        hdr = 14 + (fb[14] & 0xF) * 4 + 20
        fb, fcs = finish(fb[:hdr] + C.payload(p0)[adv:])
        add('healrem', fb, fcs, 24)
        for j in range(hi + 1, burst):
            s1, p1 = segs[j]
            fb, fcs = C.mk_tcp_frame(0, s1, HS_ACKVAL, 0x18, p1, burst_wnd, True)
            add('heal%d' % j, fb, fcs, 12)
    # ---- P4b-7-P6 半帧中止自愈 (仅 half_at): 半帧无 tlast → 板上 rcv_nxt 不动
    #      (pend_rcv 需 s_axis_tcrs), snd_una 不平 → 其后原发段全判 OOO 丢载荷。
    #      PC 从 snd_una=S 整段重传 (真实 tcp_retransmit_skb 自 snd_una 起),
    #      其后各段按原样重放。修复后 (RX SOP 防御合成坏尾拍) 半帧载荷被
    #      echo 回卷丢弃, 重传段补位 → echo 恢复 nburst+2 段连续流。----
    if half_at:
        hi = half_at - 3
        s0, p0 = segs[hi]
        fb, fcs = C.mk_tcp_frame(0, s0, HS_ACKVAL, 0x18, p0, burst_wnd, True)
        add('halfrem', fb, fcs, 24)
        for j in range(hi + 1, burst):
            s1, p1 = segs[j]
            fb, fcs = C.mk_tcp_frame(0, s1, HS_ACKVAL, 0x18, p1, burst_wnd, True)
            add('halfheal%d' % j, fb, fcs, 12)
    fb, fcs = mk_arp_req()
    add('arp2', fb, fcs, GAP_SLOW)
    fb, fcs = C.mk_tcp_frame(1, 77, 900, 0x18, 20, 0x1A00, True)
    add('c1data', fb, fcs, GAP_TCP)
    if burst:
        # P4 (RTO 门): conn1 echo 无 PCACK (matcher 只认 conn0) — RTO_LIM
        # 压缩 (RTOLIM_FAST) 下 20B 永久未确认会 RTO 风暴 (+1..2 破门)。
        # 注入 conn1 纯 ACK: seq = c1data20 尾后 (77+20=97), ack = 920 =
        # conn1 snd_nxt (echo 发出后), win 0x4000 — 让 snd_una 追平。
        # 位置必须在 conn1 echo TX 完成之后: c1data 是刺激末帧, echo 只能
        # 在其上线后 ~300 拍完成; 此处紧接 c1data, GAP_TCP 1500 拍空闲 ≫
        # echo 延迟, ACK 的 ack_ok 判定 ([snd_una,snd_nxt] = [900,920])
        # 时 snd_nxt 必已 = 920。仅 burst 模式 (chain 门无 ACK 闭环)。
        fb, fcs = C.mk_tcp_frame(1, 97, 920, 0x10, 0, 0x4000, True)
        add('c1ack', fb, fcs, GAP_TCP)
    off = 0
    for f in F:
        off += f['gap']
        f['first'] = off + 8
        f['B'] = len(f['fb'])
        off += 8 + f['B'] + 4 + 12
    return F, pmap


def gen_memh(simdir, frames):
    os.makedirs(simdir, exist_ok=True)
    nstim = max(f['first'] + f['B'] + 4 + 12 for f in frames)
    data = [0] * nstim
    dv = [0] * nstim
    for f in frames:
        stream = PRE + f['fb'] + f['fcs']
        base = f['first'] - 8
        for j, b in enumerate(stream):
            data[base + j] = b
            dv[base + j] = 1

    def w(fn, vals, fmt):
        with open(os.path.join(simdir, fn), 'w') as fh:
            fh.write('\n'.join(fmt % v for v in vals) + '\n')
    w('stim_data.memh', data, '%02X')
    w('stim_dv.memh', dv, '%d')
    w('stim_er.memh', [0] * nstim, '%d')
    with open(os.path.join(simdir, 'cfg_tcb.memh'), 'w') as fh:
        for fld in C.FIELDS:
            fh.write('%X\n' % C.TCB1_INIT[fld])


# ================= 校验 =================

def parse_gmii(fn):
    byte_lines = []
    ev = dict(fend=[], ack=[], synp=[], stats7=None, stx=None, seco=None,
              camf=None, tcbf=None, srx=None, stx2=None, smac=None, retx=None,
              truncs=None, ecomax=None, halfd=None)
    with open(fn) as fh:
        for line in fh:
            p = line.split()
            if not p:
                continue
            if p[0] == 'FEND':
                ev['fend'].append((int(p[1]), int(p[2])))
            elif p[0] == 'ACK':
                ev['ack'].append((int(p[1]), int(p[2]), int(p[3], 16)))
            elif p[0] == 'SYNP':
                ev['synp'].append(tuple(int(x, 16) for x in p[1:7]))
            elif p[0] == 'STATS7':
                ev['stats7'] = tuple(int(x) for x in p[1:])
            elif p[0] == 'STATS_TX':
                ev['stx'] = tuple(int(x) for x in p[1:])
            elif p[0] == 'STATS_ECO':
                ev['seco'] = tuple(int(x) for x in p[1:])
            elif p[0] == 'CAMF':
                ev['camf'] = tuple(int(x, 16) for x in p[1:])
            elif p[0] == 'TCBF':
                ev['tcbf'] = tuple(int(x, 16) for x in p[1:])
            elif p[0] == 'SLOWRX':
                ev['srx'] = tuple(int(x) for x in p[1:])
            elif p[0] == 'SLOWTX':
                ev['stx2'] = tuple(int(x) for x in p[1:])
            elif p[0] == 'STATS_MAC':
                ev['smac'] = tuple(int(x) for x in p[1:])
            elif p[0] == 'RETX':
                ev['retx'] = int(p[1])
            elif p[0] == 'TRUNCS':
                ev['truncs'] = tuple(int(x) for x in p[1:])
            elif p[0] == 'ECOMAX':
                ev['ecomax'] = int(p[1])
            elif p[0] == 'HALFD':
                ev['halfd'] = tuple(int(x) for x in p[1:])
            else:
                byte_lines.append((int(p[0], 16), int(p[1])))
    frames = []
    cur = []
    active = False
    for b, en in byte_lines:
        if en:
            cur.append(b) if active else None
            if not active:
                cur = [b]
                active = True
        else:
            if active:
                frames.append(bytes(cur))
                active = False
    return frames, ev


def ip_ok(body):
    """IP 头校验和有效 + 返回 proto。"""
    if len(body) < 34 or body[14] >> 4 != 4:
        return 0
    hw = struct.unpack('!10H', body[14:34])
    s = sum(hw)
    s = (s & 0xFFFF) + (s >> 16)
    s = (s & 0xFFFF) + (s >> 16)
    if s != 0xFFFF:
        return -1
    return body[23]


def check_arp_reply(body, errs, tag):
    if len(body) < 42:
        errs.append('%s: arp reply too short' % tag)
        return
    if body[12:14] != b'\x08\x06':
        errs.append('%s: not arp' % tag)
        return
    op, = struct.unpack('!H', body[20:22])
    sha = body[22:28]
    spa, = struct.unpack('!I', body[28:32])
    tha = body[32:38]
    tpa, = struct.unpack('!I', body[38:42])
    if body[:6] != PC_MAC or body[6:12] != DUT_MAC:
        errs.append('%s: eth addr dst=%s src=%s' % (tag, body[:6].hex(), body[6:12].hex()))
    if op != 2 or sha != DUT_MAC or spa != DUT_IP or tha != PC_MAC or tpa != PC_IP:
        errs.append('%s: arp fields op=%d sha=%s spa=%08x tha=%s tpa=%08x'
                    % (tag, op, sha.hex(), spa, tha.hex(), tpa))


def check_icmp_reply(body, errs, tag, n=32):
    proto = ip_ok(body)
    if proto != 1:
        errs.append('%s: icmp ip proto/csum %s' % (tag, proto))
        return
    ihl = (body[14] & 0xF) * 4
    ic = body[14 + ihl:]
    if ic[0] != 0:
        errs.append('%s: icmp type %d != 0' % (tag, ic[0]))
    if struct.unpack('!HH', ic[4:8]) != (0x1234, 1):
        errs.append('%s: icmp id/seq %s' % (tag, ic[4:8].hex()))
    pad = b'\x00' if (len(ic) - 8) % 2 else b''
    # ICMP csum 覆盖 type..payload 末 (无 pad; HLS 按 ip total_len 界)
    total = struct.unpack('!H', body[16:18])[0]
    icl = body[14 + ihl:14 + total]
    pad = b'\x00' if len(icl) % 2 else b''
    s = sum(struct.unpack('!%dH' % (len(icl + pad) // 2), icl + pad))
    s = (s & 0xFFFF) + (s >> 16)
    s = (s & 0xFFFF) + (s >> 16)
    if s != 0xFFFF:
        errs.append('%s: icmp csum bad' % tag)
    if icl[8:8 + n] != payload(n):
        errs.append('%s: icmp payload mismatch' % tag)


def check_udp_echo(body, errs, tag, n=24):
    proto = ip_ok(body)
    if proto != 17:
        errs.append('%s: udp ip proto/csum %s' % (tag, proto))
        return
    ihl = (body[14] & 0xF) * 4
    uh = body[14 + ihl:]
    sport, dport, ulen = struct.unpack('!HHH', uh[:6])
    if (sport, dport) != (0x1F90, 0x9C42):
        errs.append('%s: udp ports %04x/%04x' % (tag, sport, dport))
    if uh[8:8 + n] != payload(n):
        errs.append('%s: udp payload mismatch' % tag)


def check_synack(body, errs, tag):
    """HLS SYN+ACK 语义: proto/flags/seq=HLS_ISS/ack=对端 ISS+1/doff=7 带 MSS=1460。"""
    proto = ip_ok(body)
    if proto != 6:
        errs.append('%s: synack ip proto/csum %s' % (tag, proto))
        return
    if body[:6] != PC_MAC or body[6:12] != DUT_MAC:
        errs.append('%s: synack eth addr' % tag)
    sport, dport = struct.unpack('!HH', body[34:38])
    if (sport, dport) != (0x1F90, 0x3039):
        errs.append('%s: synack ports %04x/%04x' % (tag, sport, dport))
    seq, = struct.unpack('!I', body[38:42])
    ack, = struct.unpack('!I', body[42:46])
    if seq != HLS_ISS:
        errs.append('%s: synack seq %08x != HLS_ISS %08x' % (tag, seq, HLS_ISS))
    if ack != 1000:
        errs.append('%s: synack ack %d != 1000' % (tag, ack))
    if body[46] >> 4 != 6:
        errs.append('%s: synack doff %d != 6 (P4b-6: 仅 MSS, 无 WS)' % (tag, body[46] >> 4))
    if body[47] != 0x12:
        errs.append('%s: synack flags %02x != 0x12' % (tag, body[47]))
    # MSS 选项 (doff=7: 选项 8B 在 byte 54..61 = body[54:62]... body 含以太头:
    # TCP 选项在 body[34+20:34+28] = body[54:62]): MSS kind=2 len=4 val=1460
    if len(body) >= 62 and body[54:56] == b'\x02\x04':
        mss, = struct.unpack('!H', body[56:58])
        if mss != 1460:
            errs.append('%s: synack MSS %d != 1460' % (tag, mss))
    # TCP 校验和 fold
    ihl = (body[14] & 0xF) * 4
    total = struct.unpack('!H', body[16:18])[0]
    tcb = body[14 + ihl:14 + total]
    sip = struct.unpack('!I', body[26:30])[0]
    dip = struct.unpack('!I', body[30:34])[0]
    ph = struct.pack('!4s4sBBH', body[26:30], body[30:34], 0, 6, len(tcb))
    buf = ph + tcb
    if len(buf) % 2:
        buf += b'\x00'
    s = sum(struct.unpack('!%dH' % (len(buf) // 2), buf))
    s = (s & 0xFFFF) + (s >> 16)
    s = (s & 0xFFFF) + (s >> 16)
    if s != 0xFFFF:
        errs.append('%s: synack tcp csum bad (sip=%08x dip=%08x)' % (tag, sip, dip))


def tcp_fields(body):
    sport, = struct.unpack('!H', body[34:36])
    flags = body[47]
    kind = 'data' if flags == 0x18 else ('synack' if flags == 0x12 else 'ack')
    cid = 0 if sport == 0x1F90 else 1
    seq, = struct.unpack('!I', body[38:42])
    ack, = struct.unpack('!I', body[42:46])
    plen = struct.unpack('!H', body[16:18])[0] - 40
    return kind, cid, seq, ack, plen


def check(simdir):
    frames, _ = build_rx_frames()
    got, ev = parse_gmii(os.path.join(simdir, 'resp_p4_chain.memh'))
    errs = []

    # ---- 期望快流 (TCP): 每数据段先纯 ACK 再 echo (P4b: SYN+ACK 由 HLS
    # 慢路径发, 不在快流; P4c: suppress_data_ack=0 — 每接受段发 ACK 帧,
    # 板上帧序实测 = [ACK, echo] 交替, ACK 与 echo 同 seq (= snd_nxt),
    # ack 字段 = rcv_nxt 推进值; echo 拍 snd_nxt 才推进) ----
    exp_fast = []
    rcv = {0: 1000, 1: 77}
    snd = {0: HS_ACKVAL, 1: 900}         # HLS 握手后 snd_nxt = ISS+1
    for i, f in enumerate(frames):
        if f['name'].startswith('data') or f['name'] == 'c1data':
            cid = 0 if f['name'].startswith('data') else 1
            plen = 7 if f['name'] == 'data7a' else (9 if f['name'] == 'data7b' else 20)
            na = rcv[cid] + plen
            exp_fast.append(dict(kind='ack', cid=cid, seq=snd[cid], ack=na,
                                 plen=0, rx_i=i))
            exp_fast.append(dict(kind='data', cid=cid, seq=snd[cid], ack=na,
                                 plen=plen, rx_i=i))
            rcv[cid] = na
            snd[cid] += plen
    # ---- 期望慢流 (HLS, 顺序 = RX 顺序): P4b SYN 进慢路径 -> SYN+ACK ----
    exp_slow = ['arp', 'icmp', 'udp', 'synack', 'arp']

    # ---- 帧分类 ----
    slow_got = []
    fast_got = []
    for fb in got:
        body = fb[8:-4]
        if len(body) < 14:
            errs.append('runt frame len=%d' % len(body))
            continue
        if body[6:12] != DUT_MAC:
            errs.append('frame src mac %s != DUT C0' % body[6:12].hex())
        et = struct.unpack('!H', body[12:14])[0]
        if et == 0x0806:
            slow_got.append(('arp', fb))
        elif et == 0x0800:
            proto = body[23]
            if proto == 6:
                # P4b: flags=0x12 (SYN+ACK) 来自慢路径 HLS; 数据 0x18 = fast echo
                flags = body[47]
                if flags == 0x12:
                    slow_got.append(('synack', fb))
                else:
                    fast_got.append(fb)
            elif proto == 1:
                slow_got.append(('icmp', fb))
            elif proto == 17:
                slow_got.append(('udp', fb))
            else:
                errs.append('unknown ip proto %d' % proto)
        else:
            errs.append('unknown ethertype %04x' % et)
        # FCS 全帧校验
        if struct.pack('<I', zlib.crc32(body) & 0xFFFFFFFF) != fb[-4:]:
            errs.append('frame fcs bad')

    # ---- 慢流匹配 (严格顺序) ----
    if [k for k, _ in slow_got] != exp_slow:
        errs.append('slow stream %s != %s' % ([k for k, _ in slow_got], exp_slow))
    for i, (k, fb) in enumerate(slow_got):
        body = fb[8:-4]
        if k == 'arp':
            check_arp_reply(body, errs, 'slow%d' % i)
        elif k == 'icmp':
            check_icmp_reply(body, errs, 'slow%d' % i)
        elif k == 'udp':
            check_udp_echo(body, errs, 'slow%d' % i)
        elif k == 'synack':
            check_synack(body, errs, 'slow%d' % i)

    # ---- 快流匹配 (逐字节, ip id = 快流序号) ----
    if len(fast_got) != len(exp_fast):
        errs.append('fast count %d != %d' % (len(fast_got), len(exp_fast)))
    else:
        used = [False] * len(exp_fast)
        last_ack_i = -1
        last_echo_i = -1
        used_by = []
        for i, fb in enumerate(fast_got):
            kind, cid, seq, ack, plen = tcp_fields(fb[8:-4])
            cand = [j for j, e in enumerate(exp_fast) if not used[j] and
                    e['kind'] == kind and e['cid'] == cid and e['plen'] == plen and
                    e['ack'] == ack and e['seq'] == seq and
                    (kind == 'data' and e['rx_i'] > last_echo_i or
                     kind == 'ack' and e['rx_i'] >= last_ack_i or
                     kind == 'synack')]
            if not cand:
                errs.append('fast %d no match: %s c%d seq=%d ack=%d plen=%d'
                            % (i, kind, cid, seq, ack, plen))
                used_by.append(None)
                continue
            j = cand[0]
            used[j] = True
            used_by.append(j)
            e = exp_fast[j]
            if kind == 'ack':
                last_ack_i = e['rx_i']
            if kind == 'data':
                last_echo_i = e['rx_i']
                aj = next((k for k in range(j + 1) if exp_fast[k]['kind'] == 'ack'
                           and exp_fast[k]['rx_i'] == e['rx_i']), None)
                if aj is not None and not used[aj]:
                    errs.append('fast %d: echo before its ACK' % i)
        for i, (j, fb) in enumerate(zip(used_by, fast_got)):
            if j is None:
                continue
            e2 = dict(exp_fast[j], idx=i)
            eb = C.expected_frame_bytes(e2)
            body = fb[8:-4]
            if len(body) < len(eb) or body[:len(eb)] != eb:
                errs.append('fast %d (%s c%d) bytes mismatch' %
                            (i, exp_fast[j]['kind'], exp_fast[j]['cid']))

    # ---- 事件 / 统计 / 终态 ----
    if len(ev['fend']) != 4:
        errs.append('FEND count %d != 4' % len(ev['fend']))
    # P4c suppress=0: 每接受数据段 (3 段) 一条 ACK 事件, (id, val) = 数据段序
    if [(i, v) for _k, i, v in ev['ack']] != [(0, 1007), (0, 1016), (1, 97)]:
        errs.append('ACK events got %s exp [(0,1007),(0,1016),(1,97)]'
                    % ([(i, v) for _k, i, v in ev['ack']],))
    if ev['synp']:                   # P4b: SYN 进慢路径, tcp_rx 不再见 SYN
        errs.append('SYNP should be empty, got %s' % (ev['synp'],))
    exp_bytes = 7 + 9 + 20     # stat_bytes 计载荷字节 (plen_l = ip_len-40)
    # nonmatch=0: SYN 已不进 fast 路径; ack=3: suppress=0 每段一 ACK 事件
    if ev['stats7'] != (4, 0, 0, 0, 0, 3, exp_bytes):
        errs.append('STATS7 got %s exp (4,0,0,0,0,3,%d)' % (ev['stats7'], exp_bytes))
    if ev['stx'] != (6, 36, 3, 0):   # 6 帧 = 3 纯 ACK + 3 echo (SYN+ACK 走 HLS)
        errs.append('STATS_TX got %s' % (ev['stx'],))
    if ev['seco'] != (3, 0):
        errs.append('STATS_ECO got %s' % (ev['seco'],))
    # CAMF: conn0 由 HLS cfg 记录写入 (peer=PC 192.168.100.1@PC_MAC, dport=8080)
    if ev['camf'] != (PC_IP, DUT_IP, C.CONN[0]['sport'],
                      C.CONN[0]['dport'], int.from_bytes(PC_MAC, 'big')):
        errs.append('CAMF got %s' % (ev['camf'],))
    # TCBF: conn0 = HLS 握手配置 + 数据推进; ISS 链 = 0x12345678;
    # rcv_wnd: P4c 48K (slow_cfg_adp 常量 0xC000, echo 帧窗口字段同源);
    # snd_wnd: SYN WS=8 后 drain 缩放 0x4000<<8=0x400000 → 钳 0xFFFF
    texp = (1016, 0x12345679 + 16, HS_ACKVAL, 0xC000, 0xFFFF, 1,
            97, 920, 900, 0x1800, 0x1A00, 1)
    if ev['tcbf'] != texp:
        errs.append('TCBF exp %s got %s' % (texp, ev['tcbf']))
    if ev['srx'] != (5, 0):
        errs.append('SLOWRX got %s exp (5,0)' % (ev['srx'],))
    if ev['stx2'] != (5, 0):
        errs.append('SLOWTX got %s exp (5,0)' % (ev['stx2'],))
    # 缺陷 A 哨兵: mac abort / tx 欠载提前收帧 恒 0
    if ev['smac'] is None or ev['smac'][1] != 0 or ev['smac'][2] != 0:
        errs.append('STATS_MAC (frames,abort,eend) got %s' % (ev['smac'],))
    # P4b-7-P6: 全链不含截断 -> stat_drop_trunc 恒 0; echo 无合并 (<= 182 词)
    if ev['truncs'] not in (None, (0, 0)):
        errs.append('TRUNCS got %s exp (0, 0) (全链不应有截断)' % (ev['truncs'],))
    if ev['ecomax'] is not None and ev['ecomax'] > 182:
        errs.append('ECOMAX got %s > 182 (echo 帧合并/无尽帧)' % (ev['ecomax'],))

    print('frames RX=%d TX=%d (fast=%d slow=%d)'
          % (len(frames), len(got), len(fast_got), len(slow_got)))
    if errs:
        for e in errs[:12]:
            print('MISMATCH:', e)
        print('P4 CHAIN FAIL (%d errs)' % len(errs))
        return False
    print('P4 CHAIN OK')
    return True


def check_burst(simdir, nburst, txdrop1=0, txdrop2=0, trunc_at=0, trunc_len=8,
                half_at=0, half_k=0):
    """burst 诊断: conn0 echo 字节覆盖 + RETX/计数/统计终态。

    无 TXDROP (txdrop1==0): 严格 — echo 数 = nburst+2 (data7a/data7b+burst) 且
    seq 链连续, RETX 必须 0 (无丢帧无重传)。
    有 TXDROP: 重传容错 merge (区间并集) — 修复需 3 dup, OOO 原发帧先于修复
    帧上线, 顺序 merge 不可行; 并集必须恰为 [base, base+16+nburst*1460)
    连续无洞 (洞 = FAIL)。RETX 按连接语义 (全局计数 = conn0 + conn1 会话):
    conn0 期望 = 单丢 1; 双丢相邻 (txdrop2==txdrop1+1, 一次回卷覆盖) 1, 否则 2;
    conn1 允许独立自愈 +1 (TAILDROP 场景: conn0 洞后凑不满 3 dup 走 RTO 回卷,
    重放帧压后 c1ack 窗口假设被打破 → conn1 自身 RTO 重发, RTL 行为正确)。
    conn1 数据面独立验: echo <= 2 帧, 每帧 plen=20 且载荷 == 首发; snd_nxt=920。
    mac abort / 欠载提前收帧恒 0 (缺陷 A 哨兵)。PCACK 注入的纯 ACK 不上 TX。
    P4b-7-P5: 逐字节载荷验证 — payload_map.json (生成器按段 echo seq 建) 重建
    echo 字节流; 每个 conn0 echo (live 或 ring 回放) 的载荷必须 = 流内
    [seq-base, +plen) 切片。ring 回放帧是流的连续切片 (不保证切在段界),
    流偏移比对两者皆验 — 旧 r_sel 漏斗错位 (回放选口超前) 在此逐字节现行。

    P4b-7-P6 截断注入 (trunc_at > 0): 判据 = ①TB 的 stat_drop_trunc >= 1 (截断支
    被走过); ②截断段 echo 恰 trunc_len 字节且 ACK 号只推进真实字节 (板上
    rcv_nxt 不按承诺 plen 走); ③板上对后续 OOO 段的 dup-ACK 纯 ACK 一律只确认
    S+trunc_len; ④echo 无合并 (单帧 plen <= 1460, TB ECOMAX <= 182 词);
    ⑤覆盖并集 = 完整原计划 (PC RTO 重传补回缺口, 覆盖率自愈)。"""
    got, ev = parse_gmii(os.path.join(simdir, 'resp_p4_chain.memh'))
    echoes = []     # conn0 数据 echo: (seq, plen, 载荷 body[54:54+plen], ack 号)
    ackf = []       # conn0 纯 ACK (板上 rcv_nxt 应答帧) 的 ack 号 (dup-ACK 证据)
    c1_echoes = []  # conn1 数据 echo (P4b-7-P6-fix: 连接级自愈判据用)
    other_fast = 0
    max_plen = 0
    for fb in got:
        body = fb[8:-4]
        if len(body) >= 48 and body[12:14] == b'\x08\x00' and body[23] == 6:
            flags = body[47]
            sport, dport = struct.unpack('!HH', body[34:38])
            if flags == 0x18:
                seq, = struct.unpack('!I', body[38:42])
                ackn, = struct.unpack('!I', body[42:46])
                plen = struct.unpack('!H', body[16:18])[0] - 40
                if sport == 0x1F90 and dport == 0x3039:
                    echoes.append((seq, plen, body[54:54 + plen], ackn))
                    if plen > max_plen:
                        max_plen = plen
                else:
                    other_fast += 1   # conn1 echo
                    if (sport, dport) == (C.CONN[1]['dport'], C.CONN[1]['sport']):
                        c1_echoes.append((seq, plen, body[54:54 + plen], ackn))
            elif flags == 0x10 and sport == 0x1F90 and dport == 0x3039:
                plen = struct.unpack('!H', body[16:18])[0] - 40
                if plen == 0:
                    ackf.append(struct.unpack('!I', body[42:46])[0])

    # ---- P4b-7-P5 载荷逐字节验证: 每 conn0 echo 的载荷必须 = 生成器原段
    #      字节流在该 seq 偏移处的切片 (地图按段 echo seq 建)。live echo 切在
    #      段界; ring 回放帧 (重传) 是流的连续切片, 不保证段对齐 — 流偏移
    #      比对两者皆验。旧 r_sel 漏斗错位 (ring 读选口超前 1 字) 会让回放
    #      帧载荷整体移位 — 本检查逐字节捕获, seq 覆盖门测不到。----
    pv_ok = True
    pm = {}
    try:
        with open(os.path.join(simdir, 'payload_map.json')) as fh:
            pm = json.load(fh)
    except (OSError, ValueError) as ex:
        print('MISMATCH: payload_map.json 缺失/损坏 (%s) — 载荷验证无法执行' % ex)
        pv_ok = False
    if pm:
        mseqs = sorted(int(k, 16) for k in pm)
        pbase = mseqs[0]
        # 地图自身连续性 (段链 = echo seq 累加实际 plen)
        cur = pbase
        for s in mseqs:
            if s != cur:
                print('MISMATCH: payload_map 段链断裂: 期望 seq=%X 实有 %X'
                      % (cur, s))
                pv_ok = False
                break
            cur += len(bytes.fromhex(pm['%X' % s]))
        pstream = b''.join(bytes.fromhex(pm['%X' % s]) for s in mseqs)
        pv_n = 0
        for seq, plen, pay, _ack in echoes:
            off = seq - pbase
            if off < 0 or off + plen > len(pstream):
                print('MISMATCH: echo seq=%X plen=%d 越出期望载荷流 [%X, %X)'
                      % (seq, plen, pbase, pbase + len(pstream)))
                pv_ok = False
            elif pay != pstream[off:off + plen]:
                # 帧起始恰在段界且 plen 不同 → 先报长度不符再报内容
                if '%X' % seq in pm and len(pay) != len(pstream[off:off + plen]):
                    print('MISMATCH: 重放帧 seq=%X plen=%d 与地图该段载荷长 %d 不符'
                          % (seq, plen, len(pstream[off:off + plen])))
                print('MISMATCH: 载荷不符 seq=%X plen=%d off=%d\n'
                      '          期望 %s...\n'
                      '          实得 %s...'
                      % (seq, plen, off,
                         pstream[off:off + min(plen, 16)].hex(),
                         pay[:min(len(pay), 16)].hex()))
                pv_ok = False
            else:
                pv_n += 1
        if pv_ok and pv_n:
            print('载荷逐字节验证: %d 帧 (live + ring 重放) 全等' % pv_n)
    ndrops = (1 if txdrop1 > 0 else 0) + (1 if txdrop2 > 0 else 0)
    # conn0 TX 字节总数 = data7a(7) + data7b(9) + nburst*1460
    exp_total = 16 + nburst * 1460
    ok = True
    union_ok = False
    if not echoes:
        print('MISMATCH: no conn0 echoes')
        ok = False
    else:
        base = echoes[0][0]
        if ndrops == 0 and trunc_at == 0:
            # 无注入丢帧: 严格计数 + 连续链
            if len(echoes) != nburst + 2:
                print('MISMATCH: conn0 echo %d != %d' % (len(echoes), nburst + 2))
                ok = False
            for i in range(1, len(echoes)):
                want = echoes[i - 1][0] + echoes[i - 1][1]
                if echoes[i][0] != want:
                    print('MISMATCH: echo #%d seq=%d, 空洞/重叠 %d 字节 (期望 %d)'
                          % (i, echoes[i][0], echoes[i][0] - want, want))
                    ok = False
            if ok:
                print('echo seq 链连续: %d 帧, %d 字节, 无空洞'
                      % (len(echoes), sum(p for _, p, _b, _a in echoes)))
        else:
            # 重传容错 merge (区间并集): 修复回卷需 3 个 dup-ACK 才触发, TX
            # 顺序里 OOO 原发帧必然先于回卷修复帧上线 — 顺序 merge 会把 OOO
            # 原发帧误判成洞 (P3 gate3 实测抓到)。并集语义: 每 echo 覆盖
            # [s, s+p), 最终并集必须恰为 [base, base+exp_total) 连续无洞
            # (重传重叠/全重包自然吸收)。
            # 基准 = snd_una = 全部 echo (含回卷修复帧) 的最小 seq。TXDROP 丢
            # 首帧 (data7a) 时 echoes[0] = data7b (snd_una+7), 若用 RX 首帧当
            # 基准, 修复帧按 snd_una 补回的 7 字节会落在基准之外 → 假 FAIL。
            base = min(s for s, p, _b, _a in echoes)
            iv = []
            for lo, hi in sorted((s, s + p) for s, p, _b, _a in echoes):
                if iv and lo <= iv[-1][1]:
                    iv[-1][1] = max(iv[-1][1], hi)
                else:
                    iv.append([lo, hi])
            if iv == [[base, base + exp_total]]:
                union_ok = True
                print('重传容错 merge 干净: 覆盖 %d 字节 (含重传)' % exp_total)
            else:
                union_ok = False
                ok = False
                exp2 = base
                holed = False
                for lo, hi in sorted((s, s + p) for s, p, _b, _a in echoes):
                    if lo > exp2:
                        print('MISMATCH: 洞 %d 字节 @seq=%d (exp=%d)'
                              % (lo - exp2, lo, exp2))
                        holed = True
                        break
                    exp2 = max(exp2, hi)
                if not holed:
                    print('MISMATCH: 覆盖末字节 %d != 期望 %d'
                          % (exp2, base + exp_total))
    # ---- P4b-7-P6 截断注入验证 (trunc_at 来自 trunc.memh; 仅 plain burst) ----
    if trunc_at > 0:
        tr_n, tr_stat = ev['truncs'] if ev['truncs'] else (0, 0)
        hi = trunc_at - 3
        s_tr = 1016 + hi * 1460                             # 截断段 PC seq
        e_tr = (HS_ACKVAL + 16 + hi * 1460) & 0xFFFFFFFF    # 截断段 echo seq
        # adv = 板上真实收下的字节 (S_PAY 截断 = trunc_len; w6 截断 = 0,
        # fend_w6t 不推进 rcv_nxt, ACK/dup-ACK 停 s_tr)
        adv = trunc_len if trunc_len >= 6 else 0
        # ① 截断支被走过 (RTL 按真实字节收下, 而非旧行为静默吞尾不发 fend)
        if tr_n != trunc_at:
            print('MISMATCH: TB TRUNCS n=%d != 期望 %d (trunc.memh 未同步)'
                  % (tr_n, trunc_at))
            ok = False
        if tr_stat < 1:
            print('MISMATCH: stat_drop_trunc=%d < 1 (截断支未走过 — RTL 未修/激励未截断)'
                  % tr_stat)
            ok = False
        # ② 截断段 echo 恰 trunc_len 字节, 且该帧 ACK 号只推进真实字节
        #    (板上 rcv_nxt 不按承诺的 plen=1460 走 — dup-ACK 语义根源)
        #    w6 截断支 (trunc_len <= 2): 0 字节交付 — 无 meta 无 echo,
        #    fend_w6t 闭合边界, rcv_nxt 不推进 (ACK 停 s_tr)。注意 healrem
        #    段 (PC 整段重传, seq=s_tr) 的 echo 也落在 seq=e_tr 且 plen=1460
        #    — 与截断段短 echo 按 plen 区分 (截断段 echo 只可能 <= 2 字节)
        hit = [e for e in echoes if e[0] == e_tr]
        if trunc_len <= 2:
            w6h = [e for e in hit if e[1] <= 2]
            if w6h:
                print('MISMATCH: w6 截断段不该有短 echo (seq=%X plen=%d — 0 字节交付)'
                      % (w6h[0][0], w6h[0][1]))
                ok = False
            else:
                print('w6 截断验证: 截断段无短 echo (fend_w6t 闭合边界, rcv_nxt 停 '
                      '%08X; seq=e_tr 的 1460B echo = healrem 整段重传回显)'
                      % (s_tr & 0xFFFFFFFF))
        elif not hit:
            print('MISMATCH: 截断段无 echo (seq=%X)' % e_tr)
            ok = False
        elif hit[0][1] != trunc_len:
            print('MISMATCH: 截断段 echo plen=%d != %d (未按真实字节交付)'
                  % (hit[0][1], trunc_len))
            ok = False
        elif hit[0][3] != (s_tr + trunc_len) & 0xFFFFFFFF:
            print('MISMATCH: 截断段 echo ack=%08X != %08X (rcv_nxt 未只按真实字节推进)'
                  % (hit[0][3], (s_tr + trunc_len) & 0xFFFFFFFF))
            ok = False
        else:
            print('截断验证: echo seq=%X plen=%d ack=%08X (只确认真实 %d 字节)'
                  % (hit[0][0], hit[0][1], hit[0][3], trunc_len))
        # ③ 板上 ACK 位置合法性 (P4c suppress=0: 每 conn0 数据段触发一个纯 ACK,
        #    GMII 顺序 = 段序; ackf[i] = 第 i+1 段的 ACK):
        #    i < trunc_at-1            正常推进 (ackf[0]=1007, [1]=1016, 步进 1460,
        #                              截断段前一拍 ackf[trunc_at-2] == s_tr)
        #    i == trunc_at-1           截断段: s_tr+trunc_len (只确认真实字节)
        #    trunc_at-1 < i <= trunc_at+n_ooo_w-1  OOO 段 dup-ACK 停 s_tr+trunc_len
        #    i == trunc_at+n_ooo_w     RTO 补缺口段: s_tr+1460 (缺口补齐)
        #    i >  补缺口段             被丢各段重放: 正常推进, 单调无回退
        #    OOO 段 dup-ACK 只在窗口内回 (tcp_rx 设计: 窗口外丢段不回 ACK):
        #    第 k 段 (k>trunc_at) 的 seq diff = (1460-trunc_len) + (k-trunc_at-1)*1460,
        #    窗口内 ⇔ k-trunc_at-1 <= floor((rcv_wnd-1452)/1460) = 32 (48K 窗)
        #    -> 前 33 个 OOO 段回 dup-ACK, 其后超窗静默 (TRUNC=100/200 实测 33 帧;
        #    TRUNC=50/55 全部 OOO 段在窗口内不受此限)。旧判据 (全 = s_tr+trunc_len)
        #    是 suppress=1 时代语义; suppress=0 下正常段 ACK 也推进, 必须按位置分流
        a_tr = (s_tr + adv) & 0xFFFFFFFF
        # 窗口内 OOO 段数: 第 k 段 (k>trunc_at) 的 seq diff =
        # (1460-adv) + (k-trunc_at-1)*1460, k-trunc_at-1 = 0..n-1 共 n 段
        # 窗口内 ⇔ 偏移 n-1 <= (rcv_wnd-(1460-adv))//1460 = 32 (48K 窗) -> n = 33
        n_ooo_w = min(nburst + 2 - trunc_at,
                      (C.CONN[0]['rcv_wnd'] - (1460 - adv)) // 1460 + 1)
        ack_ok3 = True
        if len(ackf) < trunc_at + n_ooo_w + 1:
            print('MISMATCH: 板上纯 ACK %d 帧 < %d (截断段+窗口内 OOO+补缺口段)'
                  % (len(ackf), trunc_at + n_ooo_w + 1))
            ack_ok3 = False
        else:
            if ackf[0] != 1007 or ackf[1] != 1016:
                print('MISMATCH: 前两段 ACK %s != [1007, 1016]' % ackf[:2])
                ack_ok3 = False
            for i in range(2, trunc_at - 1):
                if ackf[i] != 1016 + (i - 1) * 1460:
                    print('MISMATCH: 正常段 ACK[%d]=%08X != %d (推进链断裂)'
                          % (i, ackf[i], 1016 + (i - 1) * 1460))
                    ack_ok3 = False
                    break
            if ack_ok3 and ackf[trunc_at - 1] != a_tr:
                print('MISMATCH: 截断段 ACK=%08X != %08X (未按真实字节推进)'
                      % (ackf[trunc_at - 1], a_tr))
                ack_ok3 = False
            for i in range(trunc_at, trunc_at + n_ooo_w):
                if ackf[i] != a_tr:
                    print('MISMATCH: OOO 段 ACK[%d]=%08X != %08X (dup-ACK 越推进)'
                          % (i, ackf[i], a_tr))
                    ack_ok3 = False
                    break
            if ack_ok3 and ackf[trunc_at + n_ooo_w] != (s_tr + 1460) & 0xFFFFFFFF:
                print('MISMATCH: 补缺口段 ACK[%d]=%08X != %08X (RTO 重传未补回)'
                      % (trunc_at + n_ooo_w, ackf[trunc_at + n_ooo_w],
                         (s_tr + 1460) & 0xFFFFFFFF))
                ack_ok3 = False
            for i in range(1, len(ackf)):
                if ackf[i] < ackf[i - 1]:
                    print('MISMATCH: ACK 序列回退 [%d]=%08X < [%d]=%08X'
                          % (i, ackf[i], i - 1, ackf[i - 1]))
                    ack_ok3 = False
                    break
        if not ack_ok3:
            ok = False
        else:
            print('ACK 位置合法性: %d 帧 — 前 %d 段推进, 截断段+窗口内 %d 个 OOO '
                  '停 %08X, 补缺口段 %08X, 重放段推进到 %08X (全链无回退)'
                  % (len(ackf), trunc_at - 1, n_ooo_w, a_tr,
                     (s_tr + 1460) & 0xFFFFFFFF, ackf[-1]))
        # ⑤ 好 FCS 截断帧必须按真实字节计入 pass/bytes (RTL 审查 P2-3: 截断支
        #    按 tcrs 分流 — 好 FCS -> stat_pass/stat_bytes, 坏 -> drop_crc)。
        #    RX 载荷总字节 = 原计划 + conn1 20B: S_PAY 截断段 adv 字节 + 续传
        #    1460-adv 恰补满该段; w6 截断段 0 字节 + 整段重传 1460 也恰补满
        #    (两种情形总账均为 exp_total; 若按承诺字节记账会多计入 1460-adv)
        if ev['stats7'] and ev['stats7'][6] != exp_total + 20:
            print('MISMATCH: STATS7 bytes %d != 期望 %d (截断帧记账异常 — 按承诺字节?)'
                  % (ev['stats7'][6], exp_total + 20))
            ok = False
        # ④ 覆盖并集完整 = 原计划 (截断缺口经 PC 重传 / 板上 ring 重放补齐)
        if union_ok:
            print('自愈覆盖: 并集完整 = 原计划 %d 字节 (截断缺口已补齐)' % exp_total)
        else:
            print('MISMATCH: 覆盖并集不完整 (截断缺口未补回 — 见上 merge 诊断)')
            ok = False
    # ---- echo 无合并 (全局不变量: 单帧 <= 1460 = ring 回放 plen_preset 上限;
    #      合并帧 = P6 冻结签名 2048B/256 词, 在此现行) ----
    if max_plen > 1460:
        print('MISMATCH: echo 帧 plen=%d > 1460 (帧合并 — tlast 丢失)' % max_plen)
        ok = False
    if ev['ecomax'] is None or ev['ecomax'] > 182:
        print('MISMATCH: echo 出口 ECOMAX %s > 182 词 (无尽帧)' % (ev['ecomax'],))
        ok = False
    # ---- P4b-7-P6 半帧中止注入复现证据 (half_at 来自 halfdrop.memh; burst 专用) ----
    if half_at > 0:
        hd_n, hd_k, hd_fired, hd_stuck = (list(ev['halfd']) + [0, 0, 0, 0])[:4] \
            if ev['halfd'] else (0, 0, 0, 0)
        hi = half_at - 3
        s_hd = 1016 + hi * 1460
        e_hd = (HS_ACKVAL + 16 + hi * 1460) & 0xFFFFFFFF
        print('HALFDROP 注入: 第 %d 段 (PC seq=%d) 线上半帧: 头 54B + %d 字节载荷'
              ' 后停线, 无 FCS/tlast; TB HALFD n=%d k=%d fired=%d'
              % (half_at, s_hd, half_k, hd_n, hd_k, hd_fired))
        if hd_n != half_at or hd_k != half_k:
            print('MISMATCH: TB HALFD %d/%d != 期望 %d/%d (halfdrop.memh 未同步)'
                  % (hd_n, hd_k, half_at, half_k))
            ok = False
        if not hd_fired:
            print('MISMATCH: TB HALFD 掩码未触发 (半帧残段拍未在 mac_rx 出口落地)')
            ok = False
        # 复现判据①: 残留半帧 (has_data 无 fend) 与下一顺序帧合并 → echo 出口
        #            无 tlast 长跑 > 182 词 (单帧上限 1460B = 182 词)。
        if (ev['ecomax'] or 0) > 182:
            print('HALFDROP 复现①: echo 出口合并巨帧 ECOMAX=%d 词 > 182 (残留半帧'
                  ' 永不判尾, 与随后重传帧合并)' % ev['ecomax'])
        # 复现判据②: 合并帧 > 2048B (256 字) → tcp_tx_frame S_RECV 吞到 pay FIFO
        #            满 (256) 即停, tlast 永不到 = 板级冻结签名 (PLN=0x800, PF=1)。
        if hd_stuck >= 1000:
            print('HALFDROP 复现②: tcp_tx_frame 卡 S_RECV + pay FIFO 满 共 %d 拍'
                  ' (帧超 2048B 无 tlast — 板级冻结同构)' % hd_stuck)
        if (ev['ecomax'] or 0) > 182 or hd_stuck >= 1000:
            print('HALFDROP REPRODUCED: 合并/冻结成立 — 本注入下现存 RTL 必 FAIL'
                  ' (修复方向 = RX SOP 防御合成坏尾拍, 让残段判尾回卷丢弃)')
        else:
            print('HALFDROP 未复现合并/冻结 (残留已判尾丢弃 — 修复已生效?)')
        # 修复后语义 (不算 ok, 仅供对照): 半帧段 echo 应由 seq=S 重传补位
        hit = [e for e in echoes if e[0] == e_hd]
        if hit:
            print('半帧段 echo: seq=%X plen=%d (seq=S 整段重传补位)'
                  % (hit[0][0], hit[0][1]))
        else:
            print('半帧段 echo: 无 (seq=%X — 合并/冻结时预期; 修复后应由重传补位)'
                  % e_hd)
    retx = ev['retx'] if ev['retx'] is not None else 0
    # ---- P4b-7-P6-fix: RETX 按连接语义 (全局计数器 = conn0 会话 + conn1 会话) ----
    # conn1 独立自愈: c1data 的 20B echo 发在 GMII 上, c1ack (seq=97, ack=920)
    # 靠 1500 拍窗口才落在 [snd_una, snd_nxt]=[900,920] 内。conn0 尾部丢帧
    # (如 TXDROP=200) 时 conn0 洞后凑不满 3 dup → 走 RTO 回卷, 重放帧压在
    # conn1 echo 之前 → c1ack 来时 snd_nxt 仍 900 被拒 (ack > snd_nxt) →
    # conn1 走自身 RTO 自愈重发 (+1 会话)。RTL 行为正确 (双连接独立自愈),
    # 判据必须按连接拆: 多出的一次会话只允许由 conn1 重发解释 (echo 帧 ≥2),
    # conn0 侧仍严格 (无 conn1 重发时 RETX 必须恰为原期望)。
    c1_extra = 1 if len(c1_echoes) > 1 else 0
    c1_exp_pay = C.payload(20)
    if not c1_echoes:
        print('MISMATCH: conn1 无 echo 帧 (c1data 20B 未交付)')
        ok = False
    else:
        if len(c1_echoes) > 2:
            print('MISMATCH: conn1 echo %d 帧 > 2 (自愈会话过多)' % len(c1_echoes))
            ok = False
        for _i, (_sq, _pl, _pay, _ak) in enumerate(c1_echoes):
            if _pl != 20 or _pay != c1_exp_pay:
                print('MISMATCH: conn1 echo #%d seq=%X plen=%d 载荷 != 首发 20B'
                      % (_i, _sq, _pl))
                ok = False
        # conn1 终态: 20B 必须全部发出 (snd_nxt = 900+20); snd_una 覆盖程度
        # 受 TB 模型限制 (无 conn1 ACK 注入) — 首个 c1ack 被拒后不会被重发,
        # 故只断言 900 <= snd_una <= snd_nxt 并打印实际值
        tcbf = ev['tcbf']
        if tcbf:
            if tcbf[7] != 920:
                print('MISMATCH: conn1 snd_nxt %X != 920 (20B 未全发出)' % tcbf[7])
                ok = False
            if not (900 <= tcbf[8] <= tcbf[7]):
                print('MISMATCH: conn1 snd_una %X 越界 (snd_nxt %X)'
                      % (tcbf[8], tcbf[7]))
                ok = False
            print('conn1 连接级: echo %d 帧 (载荷全等首发), snd_nxt=%d snd_una=%d%s'
                  % (len(c1_echoes), tcbf[7], tcbf[8],
                     '' if tcbf[8] == tcbf[7] else ' (无 conn1 ACK 模型: c1ack 被拒后不重发)'))
    if ndrops == 0:
        # 无丢帧/无截断: conn0 不该重传; 只允许 conn1 独立自愈的会话数
        if retx != c1_extra:
            print('MISMATCH: RETX %d != 期望 %d (无丢帧: 只允许 conn1 自愈会话)'
                  % (retx, c1_extra))
            ok = False
    else:
        # 双丢相邻 (txdrop2 == txdrop1+1) = 一次回卷覆盖两个洞 = 1 会话
        exp_retx = (1 if (ndrops == 1 or txdrop2 == txdrop1 + 1) else 2) + c1_extra
        if retx != exp_retx:
            print('MISMATCH: RETX %d != 期望 %d (drop %d,%d conn0 会话 + conn1 自愈 %d)'
                  % (retx, exp_retx, txdrop1, txdrop2, c1_extra))
            ok = False
    print('burst sent=%d  conn0 echoes=%d  conn1 echoes=%d  RETX=%d'
          % (nburst, len(echoes), other_fast, retx))
    print('STATS7  %s' % (ev['stats7'],))
    print('STATS_TX %s' % (ev['stx'],))
    print('STATS_ECO %s' % (ev['seco'],))
    print('STATS_MAC (mac_frames,abort,eend) %s' % (ev['smac'],))
    print('TCBF %s' % (ev['tcbf'],))
    print('TRUNCS %s  ECOMAX %s (注入 at=%d len=%d; ECOMAX 上限 182 词)'
          % (ev['truncs'], ev['ecomax'], trunc_at, trunc_len))
    if ev['smac'] is None or ev['smac'][1] != 0 or ev['smac'][2] != 0:
        print('MISMATCH: mac abort / tx eend 非零 (缺陷 A 哨兵)')
        ok = False
    if not pv_ok:
        print('MISMATCH: 载荷逐字节验证未全过')
        ok = False
    print('BURST %s' % ('OK' if ok else 'FAIL'))
    return ok




# ================= P4b-6 抓包重放 (replay 模式) =================
def build_replay_frames(cap_path, w0=0.440, w1=0.752, n_warmup=10):
    """标准前置 + 预热 N 段 + pcapng [w0,w1] 窗口的 PC 帧重放 (seq/ack 重定基)。"""
    import json as _json
    F = []

    def add(name, fb, fcs, gap):
        F.append(dict(name=name, fb=fb, fcs=fcs, gap=gap))

    fb, fcs = mk_arp_req()
    add('arp1', fb, fcs, GAP_SLOW)
    fb, fcs, _ = mk_icmp_req()
    add('icmp1', fb, fcs, GAP_SLOW)
    fb, fcs, _ = mk_udp()
    add('udp1', fb, fcs, GAP_SLOW)
    fb, fcs = mk_syn_ws()
    add('syn', fb, fcs, 300)
    fb, fcs = C.mk_tcp_frame(0, 1000, HS_ACKVAL, 0x10, 0, 0x4000, True)
    add('hs_ack', fb, fcs, GAP_SLOW)
    fb, fcs = C.mk_tcp_frame(0, 1000, HS_ACKVAL, 0x18, 7, 0x4000, True)
    add('data7a', fb, fcs, GAP_TCP)
    fb, fcs = C.mk_tcp_frame(0, 1007, HS_ACKVAL, 0x18, 9, 0x4000, True)
    add('data7b', fb, fcs, GAP_TCP)
    seq = 1016
    for b in range(n_warmup):
        fb, fcs = C.mk_tcp_frame(0, seq, HS_ACKVAL, 0x18, 1460, 0x4000, True)
        add('warm%d' % b, fb, fcs, 12)
        seq += 1460
    raw = _json.load(open(cap_path))
    rp = []
    for t, h in raw:
        p = bytes.fromhex(h)
        if len(p) < 48 or p[23] != 6:
            continue
        if not (w0 <= t <= w1):
            continue
        sp, dp = struct.unpack('!HH', p[34:38])
        if sp == 8080:
            continue
        seq_p, ack_p = struct.unpack('!II', p[38:46])
        plen = struct.unpack('!H', p[16:18])[0] - 40
        rp.append((t, p, seq_p, ack_p, plen))
    if not rp:
        print('REPLAY: no frames in window')
        return None
    seq_off = seq - rp[0][2]
    ack_off = (HS_ACKVAL + 16 + n_warmup * 1460) - rp[0][3]
    prev_t = rp[0][0]
    for i, (t, p, seq_p, ack_p, plen) in enumerate(rp):
        gap = max(12, min(int((t - prev_t) * 125e6), 50000))
        prev_t = t
        nseq = (seq_p + seq_off) & 0xFFFFFFFF
        nack = (ack_p + ack_off) & 0xFFFFFFFF
        fb = bytearray(p)
        fb[34:36] = struct.pack('!H', 0x3039)
        fb[38:42] = struct.pack('!I', nseq)
        fb[42:46] = struct.pack('!I', nack)
        fb[24:26] = struct.pack('!H', 0)
        hw = struct.unpack('!10H', bytes(fb[14:34]))
        cs = sum(hw)
        cs = (cs & 0xFFFF) + (cs >> 16)
        cs = (cs & 0xFFFF) + (cs >> 16)
        fb[24:26] = struct.pack('!H', (~cs) & 0xFFFF)
        fb = bytes(fb)
        add('rp%d' % i, fb, struct.pack('<I', zlib.crc32(fb) & 0xFFFFFFFF),
            gap if i else 12)
    print('REPLAY: %d frames rebased (seq_off=%d ack_off=%d)'
          % (len(rp), seq_off, ack_off))
    off = 0
    for f in F:
        off += f['gap']
        f['first'] = off + 8
        f['B'] = len(f['fb'])
        off += 8 + f['B'] + 4 + 12
    return F


if __name__ == '__main__':
    simdir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'sim', 'p4sim')
    nburst = 0
    pause_at, pause_len = -1, 0
    burst_wnd = 0x4000
    tail608 = False
    dupstorm = False
    mode = 'gen'
    if len(sys.argv) > 2:
        if sys.argv[2] == 'check':
            mode = 'check'
        elif sys.argv[2] == 'burst':
            nburst = int(sys.argv[3]) if len(sys.argv) > 3 else 100
            if len(sys.argv) > 5:
                pause_at, pause_len = int(sys.argv[4]), int(sys.argv[5])
            if len(sys.argv) > 6:
                burst_wnd = int(sys.argv[6], 16)
            if len(sys.argv) > 7:
                tail608 = (sys.argv[7] == '608')
            if len(sys.argv) > 8:
                dupstorm = (sys.argv[8] == 'dup')
            mode = 'gen'
        elif sys.argv[2] == 'burstcheck':
            nburst = int(sys.argv[3]) if len(sys.argv) > 3 else 100
            # TXDROP 故障注入参数 (0 = 无): 只影响 check_burst 判据
            txdrop1 = int(sys.argv[4]) if len(sys.argv) > 4 else 0
            txdrop2 = int(sys.argv[5]) if len(sys.argv) > 5 else 0
            mode = 'burstcheck'
        elif sys.argv[2] == 'replay':
            cap = sys.argv[3] if len(sys.argv) > 3 else 'rate4.pcapng.json'
            w0 = float(sys.argv[4]) if len(sys.argv) > 4 else 0.440
            w1 = float(sys.argv[5]) if len(sys.argv) > 5 else 0.752
            frames = build_replay_frames(cap, w0=w0, w1=w1)
            gen_memh(simdir, frames)
            print('replay memh written')
            sys.exit(0)
    # P4b-7-P6: 截断注入参数与 TB 同源 (trunc.memh, 由 run_tb_p4_burst.bat 写入;
    # xsim 到不了含 '=' 的 -testplusarg, 与 txdrop.memh 同通道)
    trunc_at, trunc_len = read_trunc(simdir)
    if trunc_at:
        print('TRUNC 注入: 第 %d 个 conn0 数据段裁到 %d 字节' % (trunc_at, trunc_len))
    # P4b-7-P6: 半帧中止注入参数与 TB 同源 (halfdrop.memh, 同 trunc.memh 通道;
    # 仅 burst 用例 — chain 门由 run_tb_p4_chain.bat 删该文件防残留)
    half_at, half_k = read_halfdrop(simdir)
    if half_at:
        print('HALFDROP 注入: 第 %d 个 conn0 数据段线上半帧中止 (K=%d 字节载荷)'
              % (half_at, half_k))
    frames, pmap = build_rx_frames(burst=nburst, pause_at=pause_at,
                                   pause_len=pause_len, burst_wnd=burst_wnd,
                                   tail608=tail608, dupstorm=dupstorm,
                                   trunc_at=trunc_at, trunc_len=trunc_len,
                                   half_at=half_at, half_k=half_k)
    print('%d RX frames' % len(frames))
    if mode == 'check':
        sys.exit(0 if check(simdir) else 1)
    if mode == 'burstcheck':
        sys.exit(0 if check_burst(simdir, nburst, txdrop1, txdrop2,
                                  trunc_at, trunc_len, half_at, half_k) else 1)
    gen_memh(simdir, frames)
    # P4b-7-P5: echo 载荷地图 sidecar (burstcheck 逐字节验证用)
    if pmap:
        with open(os.path.join(simdir, 'payload_map.json'), 'w') as fh:
            json.dump(pmap, fh, indent=0, sort_keys=True)
    print('memh written')

