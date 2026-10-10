#!/usr/bin/env python3
# ghost_inject.py -- P7B-RETXHI-GHOST 板级轮 A (S-0 臂) 的对端侧注入器 + 见证器
#   角色: 在【修复前】位流 (构建 F / BID 0x1A) 上执行设计件 P7B_RETXHI_GHOST_DESIGN.md §6.2 的 S-0 构型:
#         "发数据 -> abort(RST) -> 让该连尾部长期不确认(小窗/慢读) => RTO 会话重放 [snd_una, retx_hi)"
#   做什么 (全部经 /dev/xdma0_user 的 mmap 直读直写; 只读既有寄存器, 不新增任何 RTL):
#     mode=abort: 轮询每连接状态块 (0x0A/0x0B 状态 + 0x10+4c 的 state/snd_una/snd_nxt);
#                 命中 "ESTAB 且 snd_nxt != snd_una" (= 该连有在飞数据, 即环里已写过字节) 时:
#                   (1) 起一个全帧 pcap 窗口 (可选) (2) 写 0x06 = {cmd=2,id} = abort(RST)
#                   (3) 高频重读 snd_nxt 抓【+1】(控制帧占 seq 的板侧直接见证)
#                   (4) 高频重读 state 量【拆除延迟】(RST 发出 -> state 归 0 的拍数级时延)
#                   并记 W55/W57/W58 快照 (会话计数 / 重放上界 / 会话进行中)。
#     mode=watch: 同一轮询, 但**不发 abort** —— 负对照臂 (S-2) 用, 逐字保留同样的见证字段。
#   只读/只写既有寄存器地址; 绝不写 QSPI; 不碰 /tmp/p7b_biz/。
#   用法 (对端, root):
#     python3 /tmp/p7b_ghost/ghost_inject.py --mode abort --dur 60 --tag G1 --min-gap-ms 40 --att-cap
#     python3 /tmp/p7b_ghost/ghost_inject.py --mode watch --dur 60 --tag N1
import argparse, mmap, os, struct, subprocess, sys, time

D = "/dev/xdma0_user"
IF = "enp1s0f1np1"

A_SCRATCH_CMD = 0x06     # W: {cmd[3:0], id[3:0]}; cmd 2 = abort -> rst_req[id]
A_STATES_LO   = 0x0A     # R: conn7..0 state (nibble/conn)
A_STATES_HI   = 0x0B     # R: conn15..8 state
A_BLK_BASE    = 0x10     # R: 0x10+4c: +0 state / +1 snd_una / +2 snd_nxt / +3 {rcv_wnd,snd_wnd}
A_TRIG        = 0x18     # W: 1 = 触发快照
A_GEN         = 0x1C     # R: {gen[31:16], ., done=bit1}
A_ABORTCNT    = 0x94     # R: stat_cmd_abort
A_WBASE       = 0x20     # 字 Wi = 0x20 + 4*i

W_W5  = 5    # gmii_free_FE (时基, 前端 125MHz 域自由计数)
W_W20 = 20   # mac_tx_frames
W_W43 = 43   # mtx_stat_tx_words
W_W55 = 55   # tx_stat_retx (会话计数)
W_W57 = 57   # tx_retx_hi
W_W58 = 58   # tx_retx_active
W_W15 = 15   # tx_stat_bytes_TCP
W_W51 = 51   # app_tx_bytes


class Reg:
    def __init__(self):
        self.fd = os.open(D, os.O_RDWR | os.O_SYNC)
        self.mm = mmap.mmap(self.fd, 65536, mmap.MAP_SHARED,
                            mmap.PROT_READ | mmap.PROT_WRITE)

    def rd(self, a):
        return struct.unpack_from("<I", self.mm, a)[0]

    def wr(self, a, v):
        struct.pack_into("<I", self.mm, a, v)


def states(r):
    lo = r.rd(A_STATES_LO)
    hi = r.rd(A_STATES_HI)
    return [(lo >> (4 * i)) & 0xF for i in range(8)] + \
           [(hi >> (4 * i)) & 0xF for i in range(8)]


def blk(r, c):
    b = A_BLK_BASE + 4 * c
    return (r.rd(b) & 0xF, r.rd(b + 4), r.rd(b + 8), r.rd(b + 12))


def snap(r, words, tries=0.2):
    g0 = (r.rd(A_GEN) >> 16) & 0xFFFF
    r.wr(A_TRIG, 1)
    t0 = time.time()
    s = 0
    while True:
        s = r.rd(A_GEN)
        if s & 2:
            break
        if time.time() - t0 > tries:
            return None
    g1 = (s >> 16) & 0xFFFF
    vals = [r.rd(A_WBASE + 4 * w) for w in words]
    return g0, g1, vals


def log(m):
    sys.stdout.write(m + "\n")
    sys.stdout.flush()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["abort", "watch"], required=True)
    ap.add_argument("--dur", type=float, required=True)
    ap.add_argument("--tag", required=True)
    ap.add_argument("--min-gap-ms", type=float, default=40.0,
                    help="两次 abort 之间对该连接的最小间隔 (ms)")
    ap.add_argument("--att-cap", action="store_true",
                    help="每次 abort 前起一个全帧 pcap 窗口 (--cap-pkts 包)")
    ap.add_argument("--cap-pkts", type=int, default=4000)
    ap.add_argument("--cap-dir", default="/tmp/p7b_ghost")
    ap.add_argument("--samples", action="store_true", help="打印 W55/W57/W58 快照序列")
    args = ap.parse_args()

    r = Reg()
    t_start = time.time()
    t_end = t_start + args.dur
    last_abort = {}          # c -> t
    n_abort = 0
    n_seen_data = 0
    os.makedirs(args.cap_dir, exist_ok=True)

    log("GINJ_BEGIN tag=%s mode=%s t=%.6f dur=%.1f" % (args.tag, args.mode, t_start, args.dur))
    st0 = states(r)
    log("GINJ_STATES0 " + " ".join("%d:%d" % (i, v) for i, v in enumerate(st0)))
    log("GINJ_ABORTCNT0 0x%08x" % r.rd(A_ABORTCNT))
    s = snap(r, [W_W5, W_W15, W_W20, W_W43, W_W51, W_W55, W_W57, W_W58])
    if s:
        log("GINJ_SNAP0 gen=%d->%d W5=%u W15=%u W20=%u W43=%u W51=%u W55=%u W57=0x%08x W58=0x%08x"
            % (s[0], s[1], *s[2]))

    # --- 状态时间线 (0.5 ms 粒度; 用于判"连接什么时候上来/什么时候被拆") ---
    next_tl = t_start
    tl_buf = []
    last_tl = None

    while time.time() < t_end:
        now = time.time()
        if now >= next_tl:
            st = states(r)
            if st != last_tl:
                tl_buf.append("GINJ_TL t=%.6f %s" % (now, ",".join(str(v) for v in st)))
                last_tl = list(st)
            next_tl = now + 0.0005

        tx = None
        for c in range(16):
            st = blk(r, c)
            if st[0] == 1 and st[1] != st[2]:      # ESTAB 且有在飞数据
                tx = (c, st)
                break
        if tx is None:
            continue
        c, (state, una, nxt, wnd) = tx
        n_seen_data += 1
        if args.mode == "watch":
            # 负对照臂: 只记录"如果发 abort 会在哪一拍发", 绝不写 0x06
            if now - last_abort.get(c, 0) > args.min_gap_ms / 1000.0:
                last_abort[c] = now
                log("GINJ_WOULD_ABORT t=%.6f id=%d una=0x%08x nxt=0x%08x d=%d wnd=0x%08x"
                    % (now, c, una, nxt, (nxt - una) & 0xFFFFFFFF, wnd))
            continue
        if now - last_abort.get(c, 0) < args.min_gap_ms / 1000.0:
            continue

        # ---- 本次 abort 尝试 ----
        n_abort += 1
        cap = None
        capf = "%s/att_%s_%03d.pcap" % (args.cap_dir, args.tag, n_abort)
        if args.att_cap:
            try:
                os.remove(capf)
            except OSError:
                pass
            cap = subprocess.Popen(
                ["tcpdump", "-i", IF, "-s", "0", "-c", str(args.cap_pkts),
                 "-w", capf, "tcp port 8080"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            time.sleep(0.03)
        s_before = snap(r, [W_W5, W_W55, W_W57, W_W58])
        t_ab = time.time()
        r.wr(A_SCRATCH_CMD, (2 << 4) | c)          # abort: {cmd=2, id=c}
        # --- 抓 +1 (高频重读 snd_nxt; 最多 ~400 us) ---
        seq_trace = []
        t0 = time.time()
        nxt_seen = nxt
        while time.time() - t0 < 0.0004:
            v = blk(r, c)
            if v[2] != nxt_seen:
                seq_trace.append((time.time() - t_ab, v[2], v[0]))
                nxt_seen = v[2]
                if len(seq_trace) >= 8:
                    break
        # --- 量拆除延迟 (state -> 0) ---
        t_die = None
        t0 = time.time()
        while time.time() - t0 < 0.002:
            v = blk(r, c)
            if v[0] != 1:
                t_die = time.time() - t_ab
                break
        s_after = snap(r, [W_W5, W_W55, W_W57, W_W58])
        log("GINJ_ABORT n=%d t=%.6f id=%d una=0x%08x nxt_pre=0x%08x infl=%d wnd=0x%08x "
            "seq_after=%s die_dt=%s snap_before=%s snap_after=%s"
            % (n_abort, t_ab, c, una, nxt, (nxt - una) & 0xFFFFFFFF, wnd,
               ";".join("%.1fus:0x%08x:st%d" % (dt * 1e6, val, stt) for dt, val, stt in seq_trace) or "none",
               ("%.1fus" % (t_die * 1e6)) if t_die is not None else "none",
               ("gen%d W5=%u W55=%u W57=0x%08x W58=0x%08x" % (s_before[1], *s_before[2])) if s_before else "none",
               ("gen%d W5=%u W55=%u W57=0x%08x W58=0x%08x" % (s_after[1], *s_after[2])) if s_after else "none"))
        last_abort[c] = t_ab
        if cap is not None:
            try:
                cap.wait(timeout=3.0)
            except subprocess.TimeoutExpired:
                cap.kill()
                cap.wait()
            log("GINJ_CAP n=%d file=%s size=%d" % (n_abort, capf,
                os.path.getsize(capf) if os.path.exists(capf) else -1))

        if args.samples and n_abort % 5 == 0:
            s2 = snap(r, [W_W5, W_W55, W_W57, W_W58])
            if s2:
                log("GINJ_SAMPLE n=%d gen=%d W5=%u W55=%u W57=0x%08x W58=0x%08x"
                    % (n_abort, s2[1], *s2[2]))

    for ln in tl_buf:
        log(ln)
    st1 = states(r)
    log("GINJ_STATES1 " + " ".join("%d:%d" % (i, v) for i, v in enumerate(st1)))
    log("GINJ_ABORTCNT1 0x%08x" % r.rd(A_ABORTCNT))
    s = snap(r, [W_W5, W_W15, W_W20, W_W43, W_W51, W_W55, W_W57, W_W58])
    if s:
        log("GINJ_SNAP1 gen=%d->%d W5=%u W15=%u W20=%u W43=%u W51=%u W55=%u W57=0x%08x W58=0x%08x"
            % (s[0], s[1], *s[2]))
    log("GINJ_END tag=%s t=%.6f n_abort=%d n_seen_data=%d" % (args.tag, time.time(), n_abort, n_seen_data))


if __name__ == "__main__":
    main()
