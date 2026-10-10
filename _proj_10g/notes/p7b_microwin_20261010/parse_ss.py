#!/usr/bin/env python3
# 解析 peer 端 /tmp/ss_<TAG>.log (10 ms 采样, ss -tinma '( dport = :8080 or sport = :8080 )')
# 输出该连接 (非 43120 残骸) 的逐点状态: t / state / recv-q / skmem r / bytes_received /
# segs_out / segs_in / data_segs_in / cwnd / rcv_space / unacked / rto / lastsnd / lastrcv
import re, sys, collections

def parse(path, want_port=None):
    rows = []
    t = None
    cur = None
    for line in open(path, errors="replace"):
        line = line.rstrip("\n")
        m = re.match(r"SS_T ([0-9.]+)", line)
        if m:
            t = float(m.group(1))
            cur = None
        parts = line.split("|")
        for p in parts:
            p = p.strip()
            m2 = re.match(r"^([A-Z0-9-]+)\s+(\d+)\s+(\d+)\s+([\d.]+):(\d+)\s+([\d.]+):(\d+)$", p)
            if m2:
                st, rq, sq, la, lp, pa, pp = m2.groups()
                if want_port and lp != str(want_port):
                    cur = None
                    continue
                cur = {"t": t, "state": st, "recvq": int(rq), "sendq": int(sq),
                       "lport": lp, "peer": f"{pa}:{pp}"}
                rows.append(cur)
                continue
            m3 = re.search(r"skmem:\(r(\d+),rb(\d+).*?\)\s+cubic\s+rto:(\d+)(?:\s+backoff:(\d+))?", p)
            if m3 and cur is not None:
                cur["r"] = int(m3.group(1)); cur["rb"] = int(m3.group(2))
                cur["rto"] = int(m3.group(3)); cur["backoff"] = int(m3.group(4) or 0)
            if cur is not None:
                for k, pat in (("rtt", r"rtt:([\d.]+)/([\d.]+)"), ("cwnd", r"cwnd:(\d+)"),
                               ("bytes_acked", r"bytes_acked:(\d+)"), ("bytes_received", r"bytes_received:(\d+)"),
                               ("segs_out", r"segs_out:(\d+)"), ("segs_in", r"segs_in:(\d+)"),
                               ("data_segs_in", r"data_segs_in:(\d+)"), ("rcv_space", r"rcv_space:(\d+)"),
                               ("rcv_ssthresh", r"rcv_ssthresh:(\d+)"), ("unacked", r"unacked:(\d+)"),
                               ("lastsnd", r"lastsnd:(\d+)"), ("lastrcv", r"lastrcv:(\d+)"),
                               ("minrtt", r"minrtt:([\d.]+)"), ("rcv_ooopack", r"rcv_ooopack:(\d+)"),
                               ("snd_wnd", r"snd_wnd:(\d+)"), ("lost", r"lost:(\d+)"),
                               ("retrans", r"retrans:(\d+)/(\d+)"), ("delivered", r"delivered:(\d+)")):
                    m4 = re.search(pat, p)
                    if m4:
                        v = m4.group(1)
                        try:
                            cur[k] = float(v) if "." in v else int(v)
                        except ValueError:
                            cur[k] = v
    return rows

def main():
    path = sys.argv[1]
    want = sys.argv[2] if len(sys.argv) > 2 else None
    rows = parse(path, want)
    if not rows:
        print("no rows (want_port=%s)" % want); return
    t0 = rows[0]["t"]
    # 去重: 只打印“关键字段变化”的行, 但保证首末与状态切换
    prev = None
    keys = ("state", "recvq", "sendq", "r", "rb", "bytes_received", "segs_out", "segs_in",
            "data_segs_in", "cwnd", "rto", "backoff", "unacked", "rcv_space", "rcv_ooopack", "lost")
    print("t_rel(s) state rq sq r rb bytes_recv segs_out segs_in data_segs_in cwnd rto backoff unacked rcv_space ooopack lost")
    n = 0
    for r in rows:
        sig = tuple(r.get(k) for k in keys)
        if sig != prev:
            print("%8.3f %-12s %4s %4s %6s %6s %10s %8s %8s %12s %5s %6s %7s %7s %9s %7s %4s" % (
                r["t"] - t0, r["state"], r.get("recvq"), r.get("sendq"), r.get("r"), r.get("rb"),
                r.get("bytes_received"), r.get("segs_out"), r.get("segs_in"), r.get("data_segs_in"),
                r.get("cwnd"), r.get("rto"), r.get("backoff"), r.get("unacked"), r.get("rcv_space"),
                r.get("rcv_ooopack"), r.get("lost")))
            prev = sig
            n += 1
        if n > 400:
            print("...(truncated)"); break
    print("# total samples=%d, printed=%d" % (len(rows), n))

if __name__ == "__main__":
    main()
