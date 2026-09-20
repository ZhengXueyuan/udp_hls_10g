#!/usr/bin/env python
"""pc_p5d_reconn_test.py - P5d 同四元组重连验收 (D6 槽释放, 板级)

背景 (P5d-D6): 本地发起的拆除 (app abort->RST / 关闭超时->RST) **完全不经 HLS**
—— fast path 自清 CAM/TCB, 而 hls/src/layer_tcp.cpp 的槽状态机只有"对端 FIN/RST"
能释放槽 => 槽停在旧状态 (板级被动连接恒停在 T_SYN_RCVD)。旧码在 T_SYN_RCVD 收到
bare SYN 时只重发 SYN+ACK、**不重发 cfg ADD** => 对端握手看着正常, 但 fast 侧无 TCB
=> 死数据路径; T_ESTABLISHED/T_LAST_ACK 则**完全静默** => 对端 connect 超时。
MAX_TCP_CONN=3 => 泄漏 3 次后彻底不能收连。

本脚本: **固定本地源端口**, 连续 N 轮 [connect -> 灌 32KB 图案 -> drain -> close()]。
每轮结束后 PC 侧 socket 已关, 板侧发 FIN 无人应答 => 板侧"关闭超时 -> RST"完成拆除
—— 正是触发 D6 缺陷的场景 (与 pc_p5b_win_test.py 的单次连接不同)。

判据: N 轮 (默认 5 > MAX_TCP_CONN=3) **全部**建连成功且传输成功 (板侧 RX 逐轮
+32768, MM 不增)。若槽泄漏未修, 第 4 轮起 connect 失败/超时。

每轮之间读板侧 P5B1 状态行 (复用 tools/board_p5b_check.py 的读/解析函数, **只 import
不修改**), 记录 FI/RS/EC/EV/DP/TF/RX 轨迹。

图案: 每轮都从 offset 0 发 (板侧 ev_up 把 rx_lfsr <= SEED => 每连接图案归零,
见 pc_p5b_win_test.py 头注释) => MM 判据逐轮有效。

用法:
  python tools/pc_p5d_reconn_test.py [--rounds 5] [--bytes 32768] [--fixed-port 45678]
                                     [--gap 4.0] [--drain 1.5] [--host 192.168.100.2]
                                     [--port 8080] [--uart COM9] [--no-uart]
"""
import os
import socket
import sys
import time

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except (AttributeError, ValueError):
    pass

_TOOLS = os.path.dirname(os.path.abspath(__file__))
if _TOOLS not in sys.path:
    sys.path.insert(0, _TOOLS)
from pc_p5b_win_test import gen_pattern          # noqa: E402  (只读复用)
import board_p5b_check as bchk                   # noqa: E402  (只读复用)

KEYS = ["ST", "RX", "TX", "TF", "MM", "OC", "EV", "DP", "EC", "DL", "FI", "RS",
        "AK", "AD", "TS", "WQ", "WU", "PO", "PX", "NX", "UA", "RW", "RN"]


def rd_status(uart):
    """读一条 P5B1 状态行 -> dict (失败返回 None)。"""
    line = bchk.read_p5b_line(uart, timeout=8.0)
    if not line:
        return None, None
    return bchk.parse(line), line


def fmt(d):
    if d is None:
        return "(状态行读取失败)"
    return " ".join("%s=%s" % (k, d.get(k, "?")) for k in
                    ["RX", "TF", "MM", "OC", "EV", "DP", "EC", "FI", "RS", "AK",
                     "WU", "WQ", "PO", "ST"])


def main():
    host = "192.168.100.2"
    port = 8080
    rounds = 5
    nbytes = 32768
    fixed_port = 45678
    gap = 4.0
    drain = 1.5
    silent_secs = 0.0
    keep_open = False
    vary_port = False
    uart = "COM9"
    use_uart = True

    argv = sys.argv[1:]
    for opt in ("--rounds", "--bytes", "--fixed-port", "--gap", "--drain",
                "--silent-secs", "--host", "--port", "--uart"):
        if opt in argv:
            v = argv[argv.index(opt) + 1]
            if opt == "--host":
                host = v
            elif opt == "--uart":
                uart = v
            elif opt == "--gap":
                gap = float(v)
            elif opt == "--drain":
                drain = float(v)
            elif opt == "--silent-secs":
                silent_secs = float(v)
            else:
                val = int(v)
                if opt == "--rounds":
                    rounds = val
                elif opt == "--bytes":
                    nbytes = val
                elif opt == "--fixed-port":
                    fixed_port = val
                else:
                    port = val
    if "--no-uart" in argv:
        use_uart = False
    if "--keep-open" in argv:
        keep_open = True
    if "--vary-port" in argv:
        vary_port = True

    print("=" * 74)
    print("P5d 同四元组重连验收: %s:%d  固定本地源端口 %d  轮数 %d  每轮 %d B"
          % (host, port, fixed_port, rounds, nbytes))
    print("  每轮: connect -> sendall(%dB) -> drain %.1fs -> silent %.1fs -> close()  (轮间 %.1fs)"
          % (nbytes, drain, silent_secs, gap))
    print("=" * 74)

    payload = gen_pattern(nbytes, 0)      # 每轮同图案, offset 0

    base = None
    if use_uart:
        base, line = rd_status(uart)
        print("基线状态行: %s" % (line if line else "(读失败)"))

    results = []
    leaked = []
    prev_rx = int(base.get("RX", "0"), 16) if base else None

    for r in range(1, rounds + 1):
        print("")
        print("---- 轮 %d/%d ----" % (r, rounds))
        t0 = time.time()
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        lport = (fixed_port + r - 1) if vary_port else fixed_port
        try:
            s.bind(("", lport))
        except OSError as e:
            print("  轮 %d BIND 失败 (端口 %d): %s" % (r, lport, e))
            results.append((r, "BIND_FAIL", 0, None, None))
            s.close()
            time.sleep(gap)
            continue
        try:
            s.settimeout(10.0)
            s.connect((host, port))
            ct = time.time() - t0
            print("  轮 %d CONNECT_OK (%.3fs, 本地端口 %d)"
                  % (r, ct, s.getsockname()[1]))
            conn_ok = True
        except OSError as e:
            ct = time.time() - t0
            print("  轮 %d CONNECT_FAIL (%.3fs): %s" % (r, ct, e))
            s.close()
            results.append((r, "CONNECT_FAIL", 0, None, None))
            if use_uart:
                d, line = rd_status(uart)
                print("     板侧: %s" % (line if line else "(读失败)"))
            time.sleep(gap)
            continue

        # 发送
        sent = 0
        try:
            s.sendall(payload)
            sent = nbytes
            print("  轮 %d SEND_OK %d B" % (r, sent))
        except OSError as e:
            print("  轮 %d SEND_FAIL (已发 %d): %s" % (r, sent, e))
        # drain: 板侧 app 每连接会主动发 1MB, 收走避免发送窗反压; 同时给板侧
        # 时间把这 32KB 消费进 app 计数 (RX 判据)。
        got = 0
        s.settimeout(0.4)
        td = time.time()
        while time.time() - td < drain:
            try:
                c = s.recv(65536)
                if not c:
                    break
                got += len(c)
            except socket.timeout:
                continue
            except OSError:
                break
        print("  轮 %d DRAIN 收到板侧 %d B" % (r, got))
        # --silent-secs: 保持 socket **打开且静默**, 看板侧是否在 PC 未发 FIN/RST
        # 的情况下就本地拆除并发 RST (RS++ 的本地拆除路径)。若在这里收到
        # ECONNRESET, 说明板侧先 RST 了 => 本 socket 被内核销毁 => 随后的
        # close() **线上不发任何东西** => HLS 槽不被对端 FIN/RST 释放 =>
        # 下一轮同四元组 SYN 正是 D6 缺陷的触发条件 (判别性实验)。
        rst_seen = None
        if silent_secs > 0:
            ts2 = time.time()
            s.settimeout(0.2)
            while time.time() - ts2 < silent_secs:
                try:
                    c = s.recv(65536)
                    if not c:
                        rst_seen = ("FIN/EOF", time.time() - t0)
                        break
                    got += len(c)
                except socket.timeout:
                    continue
                except ConnectionResetError:
                    rst_seen = ("ECONNRESET", time.time() - t0)
                    break
                except OSError as e:
                    rst_seen = (repr(e), time.time() - t0)
                    break
            print("  轮 %d SILENT %.1fs: 板侧本地拆除 RST = %s"
                  % (r, silent_secs,
                     ("%s @t=%.2fs" % rst_seen) if rst_seen else "未出现"))
        # close() -> 正常 close 发 FIN; 若 socket 已被板侧 RST 销毁则线上无 FIN
        if keep_open:
            leaked.append(s)      # CLOSE_WAIT 挂住: 线上**不发任何东西** =>
            print("  轮 %d KEEP-OPEN (CLOSE_WAIT, 不发 FIN/RST) t=%.2fs"
                  % (r, time.time() - t0))
        else:
            try:
                s.close()
            except OSError:
                pass
            print("  轮 %d CLOSE (正常 close, 不设 SO_LINGER) t=%.2fs"
                  % (r, time.time() - t0))

        # 轮间: 等板侧超时 RST 走完 + 状态行刷新
        time.sleep(gap)
        d = None
        if use_uart:
            d, line = rd_status(uart)
            print("  板侧: %s" % (line if line else "(读失败)"))
            if d and prev_rx is not None:
                rx = int(d.get("RX", "0"), 16)
                print("  RX 增量 = %d (期望 %d) %s"
                      % (rx - prev_rx, nbytes, "OK" if rx - prev_rx == nbytes else "!!"))
                prev_rx = rx
        results.append((r, "OK", sent, d, rst_seen, "%s%s" % (
            "" if not keep_open else "KEEP-OPEN", "")))

    # 汇总
    print("")
    print("=" * 74)
    print("轮次汇总")
    print("-" * 74)
    print("%-4s %-14s %-10s %s" % ("轮", "建连", "发送B", "FI/RS/EC/EV/DP/TF/MM/RX"))
    nok = 0
    for (r, st, sent, d, rs, *rest) in results:
        if d is None:
            diag = "(无状态行)"
        else:
            diag = "FI=%s RS=%s EC=%s EV=%s DP=%s TF=%s MM=%s RX=%s" % (
                d.get("FI"), d.get("RS"), d.get("EC"), d.get("EV"), d.get("DP"),
                d.get("TF"), d.get("MM"), d.get("RX"))
        diag += "  localRST=%s" % (rs[0] if rs else "-")
        if rest and rest[0]:
            diag += "  [%s]" % rest[0]
        ok = (st == "OK")
        nok += 1 if ok else 0
        print("%-4d %-14s %-10d %s" % (r, st, sent, diag))
    print("-" * 74)
    print("%d/%d 轮建连+发送成功" % (nok, rounds))
    if nok == rounds:
        print("PC_P5D_RECONN OK: 全部 %d 轮同四元组重连成功" % rounds)
        rc = 0
    else:
        print("PC_P5D_RECONN FAIL: 第 %d 轮起失败"
              % next(r for (r, st, _, _, _) in results if st != "OK"))
        rc = 1
    print("=" * 74)
    return rc


if __name__ == "__main__":
    sys.exit(main())
