import os, sys, time
# 假对端 = 替掉 tools/peer_ssh.py 的那一层。⚠️ 故意用 **sys.stdout.write(text) + "\n"**
#   (走 TextIOWrapper) ⇒ 在 Windows 上由**真 Python** 翻成 CRLF —— 这正是被验的机制。
S = os.environ.get("FAKE_STATE", ".")
LOG = os.environ.get("FAKE_CALLS", os.path.join(S, "calls.txt"))
F156 = 156250000.0
def st(name, dflt="0"):
    p = os.path.join(S, name)
    return open(p).read().strip() if os.path.exists(p) else dflt
def put(name, v): open(os.path.join(S, name), "w").write(str(v))
def out(s):
    sys.stdout.write(s + "\n"); sys.stdout.flush()
def freecnt(t):                      # 前端/数据面/TX 三域自由计数 (同一口径: 156.25 MHz)
    return int((t - 1.7e9) * F156) % (1 << 32)
args = [a for a in sys.argv[1:] if not a.startswith("-")]
# 命令行做一次简单梳理: 丢掉 peer_ssh.py 自己的位置参数与旗标值
remote = sys.argv[-1]
open(LOG, "a").write("CALL|%s\n" % remote.replace("\n", "\\n"))
now = time.time()
if "SNAP_BEGIN" in remote:                                   # ---- 快照块 ----
    g0 = int(st("gen")); g1 = g0 + 1; put("gen", g1)
    blk = int(st("spec_blk")); put("spec_blk", blk + 1)
    t0 = time.time(); time.sleep(0.001); t1 = time.time()
    lat = (t0 + t1) / 2.0
    vcc = 0x66 if blk == 0 else min(0xFF, 0x99 + blk)
    W = [100, 151800, 1518, 0, 0, freecnt(lat), 100, 4] + [0] * 12 + [0, 0, 0, 0, freecnt(lat), 1, 0, 0, 0, 0, 100, 151400, 0, 0, 0, 0] \
        + [20000000, 151800000, 0, 0x2000100C, vcc, 0, 0, 0, 0, 0, 0, 0, 0, 0, freecnt(lat)]
    out("SNAP_BEGIN"); out("TLATCH %.9f %.9f" % (t0, t1)); out("GEN %d %d" % (g0, g1))
    out("MAGIC 0x50360001"); out("BID 0x00000007"); out("MARKER 0xdeadbeef")
    for i in range(51): out("W%d 0x%X" % (i, W[i]))
    out("UNIMPL 0xffffffff"); out("SNAP_END"); sys.exit(0)
if "ethtool -S" in remote:                                   # ---- NIC 块 ----
    n = int(st("nic_n")); put("nic_n", n + 1)
    t0 = time.time(); t1 = t0 + 0.001
    meas = (n >= 2) and st("traffic_ran") == "1"             # 只有激励真送达才涨计数
    pk = (5000000 + (n - 2) * 4060000) if meas else (1375 + 3 * n)
    v = {"port_rx_packets": pk, "port_rx_good": pk, "port_rx_bad": 0,
         "port_rx_bytes": pk * 1518, "port_rx_unicast": pk if meas else 0, "port_rx_multicast": 0,
         "port_rx_broadcast": 0, "port_rx_64": 0, "port_rx_65_to_127": 0, "port_rx_128_to_255": 0,
         "port_rx_256_to_511": 0, "port_rx_512_to_1023": 0,
         "port_rx_1024_to_15xx": pk if meas else 0, "port_rx_15xx_to_jumbo": 0,
         "port_rx_overflow": 0, "port_rx_nodesc_drops": 0, "port_rx_pause": 0, "port_rx_control": 0,
         "rx_eth_crc_err": 0, "rx_frm_trunc": 0, "port_tx_packets": 7585}
    out("NIC_BEGIN"); out("TLATCH %.9f %.9f" % (t0, t1))
    for k in sorted(v): out("%s %d" % (k, v[k]))
    out("NIC_END"); sys.exit(0)
# ---- 其余: 环境命令 (ip addr/route) / 激励命令 ----
# ⚠️ 这里**故意不用正则**: 回显里含字面反斜杠+n, 用 `\n` 写正则会被解释成**换行转义** ⇒
#    静默不匹配 ⇒ 本假对端"安静地什么都没做"(实测踩到, 正是本工程最恨的那类失效)。
#    改成纯字符串切分 (chr() 组装, 免得再被转义层坑一次)。
BS, Q = chr(92), chr(39)
if "ip addr" in remote or "ip route" in remote:
    sys.exit(0)                        # 环境命令: 成功返回, **不动 traffic_ran**
if "TRAFFIC_BEGIN" in remote:          # 新版包装: 远端脚本自己会回显命令与退出码
    MARK = "TRAFFIC_CMD <%s>" + BS + "n" + Q + " " + Q
    i = remote.find(MARK)
    if i >= 0:
        i += len(MARK); j = remote.find(Q + "; true; ", i)
        cmd = remote[i:j] if j > i else ""
    else:
        cmd = ""
    ok = ("p6e_udp_pattern" in cmd) and (cmd.startswith("/home/a/")
         or ("./p6e_udp_pattern" in cmd.split("&&")[-1]))
    put("traffic_ran", "1" if ok else "0")
    out("TRAFFIC_BEGIN"); out("TRAFFIC_CMD <%s>" % cmd)
    if ok:
        out("    收 4060000 帧 / 6163080000 字节 / 15.18s"); out("TRAFFIC_RC=0")
    else:
        out("bash: line 1: %s: No such file or directory" % (cmd.split() or ["?"])[0])
        out("TRAFFIC_RC=127")
    out("TRAFFIC_END"); sys.exit(0)
cmd = remote.strip()                   # 旧版: 裸命令 (可能已被 MSYS 改写)
ok = ("p6e_udp_pattern" in cmd) and (cmd.startswith("/home/a/")
     or ("./p6e_udp_pattern" in cmd.split("&&")[-1]))
put("traffic_ran", "1" if ok else "0")
if ok:
    sys.exit(0)
out("bash: line 1: %s: No such file or directory" % (cmd.split() or ["?"])[0]); sys.exit(127)
