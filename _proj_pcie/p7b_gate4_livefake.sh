#!/bin/bash
#=============================================================================
# p7b_gate4_livefake.sh — **live 路径**的假对端台架 (闸 4 工具轮 fix2 ②a/②b/②c)
#
# 为什么需要它: `P7B_GATE4_TOOLING.md` 自己声明"live 路径没有跑过"; 首次上板果然三处失效,
#   而**合成文本路径** (negctrl) 结构性看不见它们 —— 那三处全在"I/O 与编排"层:
#     (a) live 只取 1 块快照 ⇒ G2/G3/C 组被 SKIP
#     (b) 传给 `python.exe` 的**激励命令首词是 `/...` 时被 MSYS 改写成 `C:/Program Files/Git/...`**
#         ⇒ 远端 `No such file or directory` ⇒ 激励静默没跑, NIC 判据照常 FAIL (看着像板子坏了)
#     (c) Windows Python 的 stdout 把远程 LF 翻成 CRLF ⇒ 解析前置闸 ABORT
#
# 本台架 = **假工程树 + 假对端脚本**: 树里 `_proj_pcie/p7b_gate4_accept.sh` 是**真脚本的副本**,
#   `tools/peer_ssh.py` 换成假对端 (仍由**真的 Windows python.exe** 执行) ⇒
#   三个机制全是**真的**: ① MSYS 的路径改写 (参数经 python.exe 这一层, 完全同真)
#   ② Windows Python 的 **LF→CRLF 翻译** (真 TextIOWrapper, 不是我手工插 \r)
#   ③ 激励命令"是否可执行"由假对端按**收到的字节**判定 ⇒ "激励没跑"与"板子不收帧"在日志里可分。
#   ⚠️ 试过但**不能用**的写法: 用 `.bat` 包装 python —— cmd.exe 会把**多行参数**重新切分,
#      快照脚本只送到第一行 (实测), 那是台架自身的缺陷, 会污染结论。
#
# ⚠️ 假板子几何必须与**现役 RTL 同代** (= 63 字 / BID 9, P7B-WU 二轮; 2026-10-07 "台架修复轮"
#    从 51 字/BID 8 同步过来) —— 否则正例的判据 1.2 与"窗口不完整"会**假红**。
#    ⛔ 2026-10-07 Stage C BID 同步轮: 几何 (63 字) 不变, **身份 9 → 10**;
#       假对端的 nw→BID 表与兜底值已跟着改 (文件内 `bid = {...}` 那行) —— 它与真 accept
#       的 EXPECT_BID 同代 (F-b 的"按请求方那一代回"原则不变: 61/51 臂仍是 8/7)。
# ⚠️ 本台架验的是**传输与取数编排** (取几块快照 / CRLF / 参数改写 / 判据有没有跑), **不是判据本身**;
#    判据的"牙"由 `p7b_gate4_negctrl.sh` 的合成读数负对照负责 (那套是 15/0)。
#
# 用法: bash _proj_pcie/p7b_gate4_livefake.sh
# 产物: _proj_10g/notes/p7b_gate4_tools/fix2/livefake/**  (原始日志 + 调用记录 + SUMMARY)
# 退出码: 0 = 全部按期望 / 1 = 有不符
#=============================================================================
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
W=$ROOT/_proj_10g/notes/p7b_gate4_tools/fix2/livefake
OLD=$ROOT/_proj_10g/notes/p7b_gate4_tools/fix2/old/p7b_gate4_accept.sh.pre_fix2
NEW=$ROOT/_proj_pcie/p7b_gate4_accept.sh
rm -rf "$W"; mkdir -p "$W/state"
[ -f "$OLD" ] || { echo "[FATAL] 缺留档旧版 $OLD"; exit 1; }
# 假工程树 (两棵: 新版 / 旧版); tools/peer_ssh.py 稍后写成假对端
mkdir -p "$W/tree/tools" "$W/tree/_proj_pcie" "$W/tree_old/tools" "$W/tree_old/_proj_pcie"
cp "$NEW" "$W/tree/_proj_pcie/p7b_gate4_accept.sh"
cp "$OLD" "$W/tree_old/_proj_pcie/p7b_gate4_accept.sh"
[ -n "${PY:-}" ] && { echo "[FATAL] 本台架必须用**默认的** Windows python (CRLF 翻译是被验对象之一); 请 unset PY"; exit 1; }

N_OK=0; N_BAD=0
ck(){ if [ "$2" = "$3" ]; then N_OK=$((N_OK+1)); printf "  [OK  ] %-48s %s\n" "$1" "$2"
      else N_BAD=$((N_BAD+1)); printf "  [BAD ] %-48s got='%s' want='%s'\n" "$1" "$2" "$3"; fi; }
ckc(){ if grep -qF -- "$2" "$3"; then N_OK=$((N_OK+1)); printf "  [OK  ] %-48s 命中 '%s'\n" "$1" "$2"
       else N_BAD=$((N_BAD+1)); printf "  [BAD ] %-48s 日志里没有 '%s' (%s)\n" "$1" "$2" "$3"; fi; }
ckn(){ if ! grep -qF -- "$2" "$3"; then N_OK=$((N_OK+1)); printf "  [OK  ] %-48s 未出现 '%s'\n" "$1" "$2"
       else N_BAD=$((N_BAD+1)); printf "  [BAD ] %-48s 不该出现 '%s' (%s)\n" "$1" "$2" "$3"; fi; }

# ---------- ① 假对端 (python; 由**真 python.exe** 执行 ⇒ CRLF 翻译是真的) ----------
FAKE_CODE=$W/fake_peer.py
cat > "$FAKE_CODE" <<'PYEOF'
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
        + [0] * 20          # W51..W70 = P7B-BIZ/WU/C/D/E/F + M1 新增字 (accept 只要求窗口齐全 + 无 0xffffffff)
        #   ⛔ 2026-10-10 (构建 F): 16 -> **19** —— 构建 F 的远端请求是 70 字 (`for i in seq 0 69`),
        #     `W[i]` 只到 W66 ⇒ 不同步会 `IndexError` (假对端直接崩 = "整台安静")。
        #   ⛔ 2026-10-10 (构建 E): 15 -> **16** —— 构建 E 的远端请求是 67 字 (`for i in seq 0 66`),
        #     `W[i]` 只到 W65 ⇒ 不同步会 `IndexError` (假对端直接崩 = "整台安静")。
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
    #   ⛔ 2026-10-10 (构建 D): 加 **66 字那一代 = 0x18**。
    #   ⛔ 2026-10-10 (构建 E): 加 **67 字那一代 = 0x19**。
    #   ⛔ 2026-10-10 (构建 F): 加 **70 字那一代 = 0x1A**。
    #   ⛔ 2026-10-11 (缺陷刀/persist 刀): 70 字那一代的身份 0x1A → 0x1C → 0x1D。
    #   ⛔ 2026-10-11 (snd_wnd 守卫 → M1 镜像窗): 70 字槽的身份 0x1D → 0x1E; M1 起几何变 **71 字**,
    #      但本字典**按 NW 索引** ⇒ 新增 **71 槽 = 0x1F** (现役代); 70 槽降为历史 (0x1E)。
    bid = {71: "0x0000001F", 70: "0x0000001E", 67: "0x00000019", 66: "0x00000018", 65: "0x00000017", 63: "0x0000000A", 61: "0x00000008", 51: "0x00000007"}.get(nw, "0x0000001F")
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
PYEOF

# ---------- ② 两棵假树各放一份假对端 -------------------------------------------
cp "$FAKE_CODE" "$W/tree/tools/peer_ssh.py"
cp "$FAKE_CODE" "$W/tree_old/tools/peer_ssh.py"
echo "假对端部署: tree/tools/peer_ssh.py (新版) · tree_old/tools/peer_ssh.py (旧版)"

# ---------- 跑一个 case --------------------------------------------------------
# runcase <名> <树目录> <traffic_cmd> [PY 覆盖]
#   PY 默认**不设** ⇒ 用脚本默认的 Windows python (CRLF 翻译是被验机制之一);
#   只有"给旧版补上它当年必须靠人肉注入的 py_nocrlf.sh"那一例才覆盖 (否则旧版到不了激励段).
runcase(){
  local name="$1" tree="$2" tcmd="$3" pyovr="${4:-}"
  rm -f "$W/state/gen" "$W/state/nic_n" "$W/state/spec_blk" "$W/state/traffic_ran"
  echo 0 > "$W/state/gen"
  if [ -n "$pyovr" ]; then
    env FAKE_STATE="$W/state" FAKE_CALLS="$W/$name.calls" PEER_PW=dummy PY="$pyovr" \
        G4_TRAFFIC_CMD="$tcmd" G4_OUTDIR="$W/out_$name" G4_SKIP_TRAFFIC="${SKIP:-0}" \
        bash "$tree/_proj_pcie/p7b_gate4_accept.sh" > "$W/$name.log" 2>&1
  else
    env FAKE_STATE="$W/state" FAKE_CALLS="$W/$name.calls" PEER_PW=dummy \
        G4_TRAFFIC_CMD="$tcmd" G4_OUTDIR="$W/out_$name" G4_SKIP_TRAFFIC="${SKIP:-0}" \
        bash "$tree/_proj_pcie/p7b_gate4_accept.sh" > "$W/$name.log" 2>&1
  fi
  echo "$?" > "$W/$name.rc"
}

echo "########## fix2 ② live 路径假对端台架 $(date '+%F %T') ##########"
echo "— ②c 先钉死"旧版在 CRLF 下会 ABORT"(同一假对端, 不注入 py_nocrlf.sh) —"
runcase crlf_old "$W/tree_old" "cd /home/a/xdma_test && ./p6e_udp_pattern --secs 3 --board 192.168.100.2 --port 8081"
ck  "②c 旧版: 退出码 2 (ABORT)"        "$(cat "$W/crlf_old.rc")" "2"
ckc "②c 旧版: 报的就是 CRLF 那个症状"   "不是 0x 十六进制"          "$W/crlf_old.log"

echo "— ②c 新版: 同一假对端 (照旧吐 CRLF), **不做任何注入** 必须不再 ABORT —"
runcase crlf_new "$W/tree" "cd /home/a/xdma_test && ./p6e_udp_pattern --secs 3 --board 192.168.100.2 --port 8081"
ckn "②c 新版: 不再 ABORT"              "[ABORT]"                  "$W/crlf_new.log"
ckc "②c 新版: 前置闸过了 (G1)"          "[PASS] G1"                "$W/crlf_new.log"

echo "— ②a live 取多块: 全链档必须取 4 块, 且 G2 频率/G3 守恒/C 组**不再是 SKIP** —"
runcase full "$W/tree" "cd /home/a/xdma_test && ./p6e_udp_pattern --secs 3 --board 192.168.100.2 --port 8081"
ck  "②a 快照取块数 = 4"                "$(grep -c 'SNAP_BEGIN' "$W/full.calls")" "4"
ckc "②a G2-W5 频率判据跑了 (PASS)"      "[PASS] G2-W5"             "$W/full.log"
ckc "②a G2-W24 频率判据跑了 (PASS)"     "[PASS] G2-W24"            "$W/full.log"
ckc "②a G2-W50 跑了 (两种口径之一命中)" "[PASS] G2-W50"            "$W/full.log"
ckc "②a G3 守恒律跑了 (PASS)"           "[PASS] B_CONS-a"          "$W/full.log"
ckc "②a C 组 PCS 跑了 (PASS)"           "[PASS] C1-C5"             "$W/full.log"
ckc "②a C8 正证据 (两块对比)"           "[PASS] C8"                "$W/full.log"
ckc "②a 洪泛窗 B_G6 跑了 (PASS)"        "[PASS] B_G6"              "$W/full.log"
ckn "②a 不该再出现"只给了一块快照""      "只给了一块快照"            "$W/full.log"
ck  "②a 整轮退出码 0"                  "$(cat "$W/full.rc")"      "0"

echo "— ②a SKIP_TRAFFIC 档 (runbook §8 的停机档): 必须取 2 块, 频率/守恒照样跑 —"
SKIP=1 runcase skiptraffic "$W/tree" "cd /home/a/xdma_test && ./p6e_udp_pattern --secs 3 --board 192.168.100.2 --port 8081"
ck  "②a 停机档快照块数 = 2"            "$(grep -c 'SNAP_BEGIN' "$W/skiptraffic.calls")" "2"
ckc "②a 停机档 G2-W5 仍跑 (旧版这里是 SKIP)" "[PASS] G2-W5"       "$W/skiptraffic.log"
ckc "②a 停机档 N_RATE 如常 SKIP"        "[SKIP] N_RATE"            "$W/skiptraffic.log"

echo "— ②b 激励命令首词是**裸绝对路径** (上报的那个失败形态): 修改后必须原样送达 —"
RAW="/home/a/xdma_test/p6e_udp_pattern --secs 3 --board 192.168.100.2 --port 8081"
# 旧版必须补上它当年"要靠人记得注入"的 py_nocrlf.sh, 否则它先在 CRLF 那道闸上 ABORT, 到不了激励段
runcase rawabs_old "$W/tree_old" "$RAW" "$ROOT/_proj_10g/notes/p7b_gate4/py_nocrlf.sh"
ckc "②b 旧版: 假对端收到的命令**被 MSYS 改写**了" "Program Files/Git/home/a" "$W/rawabs_old.calls"
ckc "②b 旧版: 激励其实**没跑** (NIC 判据照常 FAIL)" "[FAIL] N_RATE"  "$W/rawabs_old.log"
runcase rawabs_new "$W/tree" "$RAW"
ckc "②b 新版: 假对端收到 == 原样的绝对路径命令" "/home/a/xdma_test/p6e_udp_pattern --secs 3" "$W/rawabs_new.calls"
ckn "②b 新版: 收到的命令里没有 Git 改写痕迹"    "Program Files"      "$W/rawabs_new.calls"
ckc "②b 新版: T_RUN 判据 PASS (回显+退出码)"     "[PASS] T_RUN"      "$W/rawabs_new.log"
ckc "②b 新版: 激励送达后 NIC 速率判据 PASS"      "[PASS] N_RATE"     "$W/rawabs_new.log"
ck  "②b 新版: 整轮退出码 0"                      "$(cat "$W/rawabs_new.rc")" "0"

echo "— ②b 反例: 命令不可执行时, 必须报 T_RUN FAIL 并点名"先怀疑激励侧"—"
runcase noexec "$W/tree" "/nonexistent/p6e_udp_pattern --secs 3"
ckc "②b 不可执行 ⇒ T_RUN FAIL (带退出码)" "[FAIL] T_RUN"             "$W/noexec.log"
ckc "②b 且明确点名"先怀疑激励侧""          "先怀疑激励侧"              "$W/noexec.log"

echo
echo "########## fix2 ② 汇总: OK=$N_OK BAD=$N_BAD ##########"
{ echo "fix2 ② live 路径假对端台架 $(date '+%F %T')"
  echo "OK=$N_OK BAD=$N_BAD"
  echo "case: crlf_old / crlf_new / full / skiptraffic / rawabs_old / rawabs_new / noexec"
  echo "原始件: <case>.log (验收脚本 stdout) · <case>.calls (假对端收到的每一条远程命令) · <case>.rc"
} > "$W/SUMMARY.txt"
[ "$N_BAD" -eq 0 ] || exit 1
exit 0
