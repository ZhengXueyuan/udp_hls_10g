#!/usr/bin/env python
"""board_p5b_check.py — 读板侧 P5B1 状态行并自动判据 (P5b 窗口闭环板级验收)

板侧 UART = 板载 CH340E (当前枚举为 COM9, 9600-8N1; 若换 USB 口用 --port 覆盖)。
状态行格式见 rtl/app_status_uart.v 头注释 (220 字符, ~2s 一行):
  P5B1 ST=x NX=xxxxxxxx UA=xxxxxxxx RW=xxxx RN=xxxxxxxx RX=xxxxxxxx TX=xxxxxxxx
       TF=xxxx MM=xxxx OC=xxxxx EV=xxxx DP=xxxx RY=xxxx EC=xx DL=xxxx FI=xxxx RS=xxxx
       AK=xxxx AD=xxxx TS=x WQ=xxxx WM=xxxx WU=xxxx PO=xxxxx PX=xxxx

判据 (P5b 应用 RX 窗口闭环):
  RX == PC 发出的字节数     数据完整收到
  MM == 0                   图案逐字节零失配 (窗口关/重开过程中无丢失/重复/乱序)
  AD == 0                   ackq 无溢出丢弃
  DL == 0                   无超长帧
  OC <  8192*8              占用未越物理界 (65536)
诊断 (不判 FAIL, 仅展示): WQ(配额) WM(上次 wu 通告值) PO(池余额) PX(池受限授予)
                          TS(tcp_tx_frame FSM) AK(已发 ACK 段) OC(占用瞬时值)
                          EC(ESTAB 连接数) FI/RS(FIN/RST 发出数) WU(窗口更新 ACK 数)
⚠️ 口径 (2026-09-20 板级实测):
  - `WU` **不是** PASS 判据: 板侧 app 消费 ~0.89 字节/拍 vs 1G 到达 ≤1 字节/拍
    ⇒ 窗口通常只收缩不归零; 冷启动单次 4MB 运行 WU 可能为 0。`WU>0` 只在
    app 显著落后或配额竞争时出现。
  - `FI` 只是 **fast path** 的 FIN 计数 (tx_stat_fin) —— 慢路径 HLS 会另发
    FIN+ACK (见 hls/src/layer_tcp.cpp 的 T_SYN_RCVD 收 FIN 分支), 所以
    "一次 close 恰 1 帧 FIN" 这类判据在线上**不成立**。
  - `RS` 只有在"FIN 已发且对端静默 >400ms"时才递增; 若脚本发送后保持 socket
    静默 (如 pc_p5b_win_test.py 的 drain 窗口 > 400ms), **必然**出现一次 RST,
    属正常语义, 不是丢数据的 RST (以 RX 是否精确为判据)。

用法:
  python tools/board_p5b_check.py [--port COM9] [--lines 6] [--expect-rx 4194304]
  (--expect-rx 0 = 不判 RX; 不指定则只打印解析结果)
"""
import re
import sys
import time

# GBK 控制台下 print 非 ASCII (例如箭头字符) 会抛 UnicodeEncodeError, 使退出码变 1 ——
# 任何"按 exit code 判 PASS/FAIL"的自动化都会**误报 FAIL** (2026-09-20 板级实测:
# 判据全过却 exit 1)。Python 3.7+ 用 reconfigure 兜底。
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except (AttributeError, ValueError):
    pass

FIELDS = ["ST", "NX", "UA", "RW", "RN", "RX", "TX", "TF", "MM", "OC", "EV", "DP",
          "RY", "EC", "DL", "FI", "RS", "AK", "AD", "TS", "WQ", "WM", "WU", "PO",
          "PX"]


def read_p5b_line(port, timeout=12.0):
    """读到一条完整 P5B1 行为止 (行间隔 ~2s; 返回解析出的 dict 或 None)。"""
    try:
        import serial
    except ImportError:
        print("FAIL: 需要 pyserial (anaconda python: /c/Users/zhxue/anaconda3/python.exe)")
        return None
    t0 = time.time()
    try:
        sp = serial.Serial(port, 9600, timeout=1.0)
    except Exception as e:                      # noqa: BLE001
        print("FAIL: 打不开 %s: %s" % (port, e))
        return None
    buf = b""
    try:
        while time.time() - t0 < timeout:
            chunk = sp.read(512)
            if chunk:
                buf += chunk
                # 行以 CR/LF 结束; 提取最后一条完整的 P5B1 行
                m = re.findall(rb"P5B1[^\r\n]*", buf)
                if m and (buf.endswith(b"\n") or buf.endswith(b"\r")):
                    txt = m[-1].decode("ascii", "replace")
                    if len(txt) >= 200:         # 完整行 (220 字符)
                        return txt
    finally:
        sp.close()
    return None


def parse(line):
    d = {}
    for k, v in re.findall(r"([A-Z]{2})=([0-9A-Fx]+)", line):
        d[k] = v
    return d


def main():
    port = "COM9"
    lines = 6
    expect_rx = None
    argv = sys.argv[1:]
    for opt, cast in (("--port", str), ("--lines", int), ("--expect-rx", int)):
        if opt in argv:
            v = argv[argv.index(opt) + 1]
            if opt == "--port":
                port = v
            elif opt == "--lines":
                lines = cast(v)
            else:
                expect_rx = cast(v)

    print("读 %s (9600-8N1), 最多等 %d 行 (每行 ~2s)..." % (port, lines))
    line = None
    for i in range(lines):
        line = read_p5b_line(port, timeout=8.0)
        if line:
            break
        print("  (第 %d 次未读到完整行, 重试)" % (i + 1))
    if not line:
        print("FAIL: 未读到 P5B1 完整状态行 — 检查板子是否在跑 APP_MODE 位流 / 端口号")
        return 1

    # 2026-09-20 修复: read_p5b_line 返回的是字符串, 必须以 parse() 转成字段字典
    # (旧版直接 d.get() ⇒ AttributeError; 板级 agent 实测评测到该 bug)
    d = parse(line)
    print("")
    print(line)
    print("")
    fails = []
    if expect_rx is not None and expect_rx > 0:
        got = int(d.get("RX", "0"), 16)
        ok = (got == expect_rx)
        print("  RX = %d (期望 %d) %s" % (got, expect_rx, "OK" if ok else "FAIL"))
        if not ok:
            fails.append("RX 不匹配: %d != %d" % (got, expect_rx))
    for key, want, desc in (("MM", 0, "图案失配字节数"),
                            ("AD", 0, "ACK 队列丢弃"),
                            ("DL", 0, "超长帧丢弃")):
        got = int(d.get(key, "0"), 16)
        ok = (got == want)
        print("  %s = %d %s  (%s)" % (key, got, "OK" if ok else "FAIL", desc))
        if not ok:
            fails.append("%s=%d (%s)" % (key, got, desc))
    wu = int(d.get("WU", "0"), 16)
    print("  WU = %d   (窗口更新 ACK 发出数; 非 FAIL 判据 — 见下)" % wu)
    if wu == 0:
        print("       (WU=0 是常见且正常的: 板侧 app 校验器消费 ~0.89 字节/拍, 而 1G 到达")
        print("        最多 1 字节/拍 ⇒ 窗口只会收缩不会归零; 只有 app 消费显著落后 (或配额")
        print("        竞争致瞬时 winq=0) 才会触发 wu。2026-09-20 板级实测: 冷启动单次 4MB")
        print("        运行 WU=0, 两次 256MB 洪泛的 WU 也只由**连接建立的配额竞争**触发)")
    print("  PX = %d   (池受限授予次数; 与 WU 同步增长即说明 wu 来自配额竞争, 非背压)"
          % int(d.get("PX", "0"), 16))
    occ = int(d.get("OC", "0"), 16)
    ok = occ < 8192 * 8
    print("  OC = %d %s  (占用, 物理界 65536)" % (occ, "OK" if ok else "FAIL"))
    if not ok:
        fails.append("OC=%d 越物理界" % occ)
    print("")
    print("  诊断: WQ=%s WM=%s PO=%s PX=%s TS=%s AK=%s EC=%s FI=%s RS=%s TF=%s"
          % (d.get("WQ"), d.get("WM"), d.get("PO"), d.get("PX"), d.get("TS"),
             d.get("AK"), d.get("EC"), d.get("FI"), d.get("RS"), d.get("TF")))
    print("")
    if fails:
        print("BOARD_P5B FAIL: " + "; ".join(fails))
        return 1
    print("BOARD_P5B OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
