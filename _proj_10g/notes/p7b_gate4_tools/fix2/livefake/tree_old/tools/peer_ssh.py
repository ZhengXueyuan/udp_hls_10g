import os, re, sys, time
# 假对端 = 替掉 tools/peer_ssh.py 的那一层。⚠️ 故意用 **sys.stdout.write(text) + "\n"**
#   (走 TextIOWrapper) ⇒ 在 Windows 上由**真 Python** 翻成 CRLF —— 这正是被验的机制。
S = os.environ.get("FAKE_STATE", ".")
LOG = os.environ.get("FAKE_CALLS", os.path.join(S, "calls.txt"))
F156 = 156250000.0
# ⚠️ 2026-10-07 "台架修复轮": **必须显式 utf-8**。远端命令文本里含 ⚠ (accept 的 SNAP_REMOTE
#    注释), 而 Windows Python 的 `open()` 默认用 **GBK**(locale) —— 不是 stdout 那层
#    (那层有 PYTHONIOENCODING=utf-8), 于是 `open(LOG,"a").write(remote)` 直接
#    UnicodeEncodeError 崩掉假对端 ⇒ 整个台架 22 条假红 (实测, 与几何无关的独立缺陷)。
#    ⚠️ 只给**文件**加 encoding; stdout 的 CRLF 翻译仍必须保真 (那是被验机制之一)。
ENC = "utf-8"
def st(name, dflt="0"):
    p = os.path.join(S, name)
    return open(p, encoding=ENC).read().strip() if os.path.exists(p) else dflt
def put(name, v): open(os.path.join(S, name), "w", encoding=ENC).write(str(v))
def out(s):
    sys.stdout.write(s + "\n"); sys.stdout.flush()
def freecnt(t):                      # 前端/数据面/TX 三域自由计数 (同一口径: 156.25 MHz)
    return int((t - 1.7e9) * F156) % (1 << 32)
args = [a for a in sys.argv[1:] if not a.startswith("-")]
# 命令行做一次简单梳理: 丢掉 peer_ssh.py 自己的位置参数与旗标值
remote = sys.argv[-1]
open(LOG, "a", encoding=ENC).write("CALL|%s\n" % remote.replace("\n", "\\n"))
now = time.time()
if "SNAP_BEGIN" in remote:                                   # ---- 快照块 ----
    g0 = int(st("gen")); g1 = g0 + 1; put("gen", g1)
    blk = int(st("spec_blk")); put("spec_blk", blk + 1)
    t0 = time.time(); time.sleep(0.001); t1 = time.time()
    lat = (t0 + t1) / 2.0
    vcc = 0x66 if blk == 0 else min(0xFF, 0x99 + blk)
    W = [100, 151800, 1518, 0, 0, freecnt(lat), 100, 4] + [0] * 12 + [0, 0, 0, 0, freecnt(lat), 1, 0, 0, 0, 0, 100, 151400, 0, 0, 0, 0] \
        + [20000000, 151800000, 0, 0x2000100C, vcc, 0, 0, 0, 0, 0, 0, 0, 0, 0, freecnt(lat)] \
        + [0] * 15          # W51..W65 = P7B-BIZ/WU/构建C/构建D 新增字 (accept 只要求窗口齐全 + 无 0xffffffff)
        #   ⛔ 2026-10-10 (构建 D): 14 -> **15** —— 构建 D 的远端请求是 66 字 (`for i in seq 0 65`),
        #     `W[i]` 只到 W64 ⇒ 不同步会 `IndexError` (假对端直接崩 = "整台安静")。
    #   ⛔ 2026-10-10 (构建 D): 14 -> **15** (构建 D 的远端请求是 66 字; 见下方 W 列表注释)。
    #   ⛔ 2026-10-10 (构建 C): 12 -> **14** —— 构建 C 的远端请求是 65 字 (`for i in seq 0 64`),
    #      而 `W[i]` 只到 W62 ⇒ 若不同步, `for i in range(nw)` 读到 W63/W64 会 **IndexError**
    #      (假对端直接崩, 表现为"整台安静"—— 本工程最恨的一类失效); 同步后为 W63/W64 = 0 (健康值)。
    # ⚠️ 几何**自适配**: 老版 accept (pre_fix2) 的远端文本是 `for i in $(seq 0 50)` (51 字),
    #    新版是 `for i in $(seq 0 $(( 63 - 1 )))` (63 字, 占位符已在发送前替换)。假板子必须
    #    **按请求方那一代的几何**回, 否则老版那一路会因"字数不符/身份不符"提前 ABORT,
    #    检查点够不着激励段 (2026-10-07 实测踩到: 把 51 直接改成 63 之后 rawabs_old 退回 → 2 条 [BAD])。
    #    ⚠️ **不许用 `"seq 0 50" in remote` 这种子串判定** —— 新版远端文本的**注释里**就含着
    #    "旧版写死 `seq 0 50`" 这句话 (实测踩到: 新版被误判成 51 字 ⇒ 整台 22 条假红)。
    #    只认 `for i in $(seq ...)` 这一行的**实际边界**; W[:nw] 的末字恰是 W50 自由计数 ✓
    nwm = re.search(r'for i in \$\(seq 0 \$\(\(\s*(\d+)\s*-\s*1\s*\)\)\)', remote)
    if nwm:
        nw = int(nwm.group(1))
    else:
        nwm = re.search(r'for i in \$\(seq 0 (\d+)\)', remote)
        nw = int(nwm.group(1)) + 1 if nwm else 63
    # ⛔ 2026-10-07 Stage C: 63 字那一代的身份 9 -> 10 (兜底同改); 61/51 代 (8/7) 是历史值, 不动。
    # ⛔ 2026-10-10 (构建 C 门同步轮): 加 **65 字那一代 = 17** (构建 C; `p7b_gate4_accept.sh`
    #    的默认 EXPECT_BID 同批改成 0x00000017 —— 本假板子必须跟着, 否则整台 case 在 G1 身份上假红)。
    #    ⚠️ 兜底值也已从 "0x0000000A" (Stage C 63 字) 改成 **"0x00000017"** (现役代) ——
    #    兜底只在 nw 不在表里时用, 取"现役那一代"比取历史代更不容易静默假红。
    #   ⛔ 2026-10-10 (构建 D): 加 **66 字那一代 = 0x18**; 兜底值同改 0x18 (现役代)。
    bid = {66: "0x00000018", 65: "0x00000017", 63: "0x0000000A", 61: "0x00000008", 51: "0x00000007"}.get(nw, "0x00000018")
    out("SNAP_BEGIN"); out("TLATCH %.9f %.9f" % (t0, t1)); out("GEN %d %d" % (g0, g1))
    out("MAGIC 0x50360001"); out("BID %s" % bid); out("MARKER 0xdeadbeef")
    for i in range(nw): out("W%d 0x%X" % (i, W[i]))
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
