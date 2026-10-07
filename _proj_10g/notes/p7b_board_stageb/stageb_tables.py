#!/usr/bin/env python3
# stageb_tables.py -- 从 run_*.txt 机械算 Stage B 逐跑表 (不改任何读数)
#
# ⛔ 2026-10-07 订正 (P7B StB 判据修正轮): 32 位计数器回卷处置。
#    本件在 Stage B 轮已做"k·2^32 还原"(原文保留在下面那行注释里), 但有三处不够, 本轮补齐:
#    ① `k` 只搜 0..2 (range(0,3)) ⇒ 只覆盖到 2 轮回卷 (12 s 窗 ≈ 5.7 Gbps); 10G 目标下不够;
#    ② 表里**只有余数**(`dW53_raw` 列其实是 mod 值) ⇒ "回卷发生过"这件事在表上不可见;
#    ③ W5 时基无 27.487 s 上限守卫 (156.25 MHz 自由计数, 窗超限 ⇒ 速率静默错 70%)。
#    ⚠️ 盲区 (原理极限, 必须登记): 真偏差恰 ≈ j·2^32 时不可分辨 (j=1 ≈ 12 s 窗流量的 70%)。
import re, sys, glob, os
sys.stdout.reconfigure(encoding="utf-8", errors="replace")   # 工程坑 16①: GBK 控制台下 print 中文会抛 UnicodeEncodeError ⇒ 退出码 1 = 假 FAIL
M32 = 2**32
TB_MAX_S = M32 / 156.25e6        # W5/W24 自由计数回绕周期 = 27.487 s
def words(txt):
    out = {}
    for m in re.finditer(r'^W(\d+)\s+0x[0-9A-F]+\s+(\S+)\s+0x([0-9a-fA-F]+)\s*$', txt, re.M):
        out.setdefault(int(m.group(1)), []).append(int(m.group(3), 16))
    return out
rows = []
for path in sorted(glob.glob('run_*.txt')):
    tag = os.path.basename(path)[4:-4]
    txt = open(path, encoding='utf-8', errors='replace').read()
    sm = re.search(r'SRC_SUM tx_bytes=(\d+) .*?dur_s=([\d.]+) tx_Mbps=([\d.]+)', txt)
    pace = re.search(r'^PACE_BPS=(\d+)', txt, re.M)
    if not sm: continue
    tx, dur, mbps = int(sm.group(1)), float(sm.group(2)), float(sm.group(3))
    w = words(txt)
    # t0/t1 = 第 2/3 次出现 (第 1 次 = pre full); snap 段按顺序: pre(full), t0, t1, post(full)
    def pair(i):
        v = w.get(i, [])
        return (v[1], v[2]) if len(v) >= 3 else (None, None)
    w5a, w5b = pair(5); w53a, w53b = pair(53); w54a, w54b = pair(54)
    w61a, w61b = pair(61); w62a, w62b = pair(62)
    d5 = (w5b - w5a) % M32 if w5a is not None else 0
    d53 = (w53b - w53a) % M32 if w53a is not None else 0
    # 32 位 app 计数器: 取与对端 tx 同量级的 k
    # ⛔ 订正 (2026-10-07): 原句 = `cand = [d53 + k*M32 for k in range(0,3)]` —— k 上限硬写 2,
    #    只覆盖 ≤2 轮回卷 (12 s 窗 ≈ 5.7 Gbps); 10G 目标下会静默少算 k·2^32。
    #    现由对端口径 tx 反推 k 上限 (tx//2^32 + 1)。盲区见文件头。
    cand = [d53 + k*M32 for k in range(0, tx // M32 + 2)]
    d53c = min(cand, key=lambda v: abs(v - tx))
    k53 = (d53c - d53) // M32
    ratio_board = d53c / tx if tx else 0
    # ⛔ 订正 (2026-10-07): W5 时基 27.487 s 上限守卫 —— 超限时 brd_Mbps 标不可判, 不许静默出数
    tb_ok = bool(d5) and (d5 / 156.25e6) < TB_MAX_S
    brd_mbps = d53c * 8.0 / (d5 / 156.25e6) / 1e6 if tb_ok else -1.0
    d54 = (w54b - w54a) % M32 if w54a is not None else None
    d61 = (w61b - w61a) % M32 if w61a is not None else None
    d62max = max([v for v in w.get(62, [])] or [0])
    rows.append((tag, int(pace.group(1)) if pace else -1, tx, mbps, d53, d53c, k53, ratio_board, brd_mbps, d54, d61, d62max,
                 (w53a, w53b)))
print("%-12s %10s %14s %10s %12s %12s %5s %9s %10s %6s %8s %8s" % (
    "tag","PACE","tx_bytes","tx_Mbps","dW53_raw","dW53_wrapok","k53","d/tx","brd_Mbps","dW54","dW61","maxW62"))
for r in rows:
    print("%-12s %10d %14d %10.3f %12d %12d %5d %9.6f %10.3f %6s %8s %8d" % r[:-1])
    # ⛔ 原始读数必须落表 (mod 只给余数; 不落原始值 = "回卷发生了"被静默抹掉)
    print("      RAW t0_W53=%s t1_W53=%s %s" % (r[12][0], r[12][1],
          "" if r[8] >= 0 else "[brd_Mbps 不可判: W5 时基超 27.487 s 或为空]"))
