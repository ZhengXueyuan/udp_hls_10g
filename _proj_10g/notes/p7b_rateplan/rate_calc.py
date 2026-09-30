#!/usr/bin/env python3
"""rate_calc.py -- P7B_RATE_MEASURE_PLAN.md 的算式实现 + **量测函数自检** (纯离线).

为什么单独一个文件: 本工程纪律 = "量测函数要有自检 (喂已知真值必须报对)" + "每个采样点必须自证是新一代".
所以本文件把 §2 的算式写成**纯函数**, 并配一组**已知真值** (_selftest):
  旧模态   106,003.170 fps  <=>  1474 拍/帧  (闸 4 板级实测, P7B_RATE_BOTTLENECK.md §0)
  期望档   ~808,579  fps     <=>  193.24 拍/帧 (mac_tx_10g.v:19 的公式)
自检不过 ==> 本文件的任何读数都不许用.

⚠️ 本文件**不碰板子/对端机**, 只吃文本 (与 p7b_gate4_accept.sh 的 snap 文本同形).
   输入 = 两次快照 (A/B) 各自的 51 字 + gen + NIC 计数文本; 输出 = 主判据 + 辅助判据 + 分级.

用法
    python rate_calc.py --selftest                      # 只跑自检
    python rate_calc.py --tf 193.24                     # 由拍/帧算期望值
    python rate_calc.py --snapA a.txt --snapB b.txt [--nicA na.txt --nicB nb.txt]
       snap 文本格式 (与 p7b_gate4_accept.sh 一致, 每行 "W<n> 0x...", 另有 GEN <n> <n>):
           W20 0x00001234
           ...
           GEN 12 13
"""
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")   # 工程坑 16①: GBK 控制台

W32 = 1 << 32
F_FE = 156.25e6          # 前端域标称 (P7B 构建: PCS CDR 恢复钟; 板级实测 156.1986 MHz)
F_DP = 156.25e6          # 数据面域标称
PLOAD = 1472             # UDP 载荷字节/帧
LWIRE = 1538             # 线上: 1500(IP)+14(ETH)+4(FCS)+20(PRE+IFG)
HDR_XGMII = 193.24       # 每帧 XGMII 字数 (= mac_tx_10g 拍/帧, 1472B 载荷)
UP_8023 = 9.571          # 802.3 口径上限 Gbps (1472/1538 * 10G)
# 界的设定 (P7B_RATE_MEASURE_PLAN.md §2.3): M1=4.870 (只一刀) 与 M2=9.523 (满效) 的几何中点
# = sqrt(4.870*9.523) = 6.810, **判据取整到 6.8** (文档/代码/速查表三处必须逐字一致; 取整方向
# 对判别力无害: 到 M1 的裕量仍 +39.6%, 到 M2 仍 -28.6%).
BOUND_MID = (4.870 * 9.523) ** 0.5
BOUND_GBPS = 6.8


def d32(a, b):
    """32 位差分 (带回绕). 返回 (delta, wrapped)."""
    d = (b - a) % W32
    return d, (b < a)


def fps_from(dW20, dW5, dW24):
    """主判据: 两种时基 (FE 同域优先 / DP 交叉)."""
    return (dW20 * F_FE / dW5, dW20 * F_DP / dW24)


def gbps_load(fps):
    return fps * PLOAD * 8 / 1e9


def predict_from_tpf(tpf, f=F_DP):
    """由每帧拍数给期望值 (量程自检 B0-1 的反向用法)."""
    fps = f / tpf
    return fps, gbps_load(fps)


def grade(g):
    """§2.4 分级读数表 (区间必须与 §2.3 的达标界 BOUND_GBPS 逐字一致).

    ⚠️ 本函数的第一版把 ">=4.5 不达标" 写在 ">=BOUND 达标" 之前 ⇒ 6.81 附近的两档
       互相冲突 (自检当场抓住). 教训与 P7B_RATE_MEASURE_PLAN.md §10 引的工程纪律同源:
       **量测函数必须喂已知真值自检** —— 否则判据表的边界会被静默写反.
    """
    if g > UP_8023:
        return "口径错 (> 802.3 上限)"
    if g >= 9.50:
        return "满效"
    if g >= 8.5:
        return "达标(有可解释损失)"
    if g >= BOUND_GBPS:
        return "达标"
    if g >= 4.5:                      # 上界严格 < BOUND_GBPS (两档不重叠)
        return "不达标: 疑似只有一刀生效 (M1~4.87)"
    if g >= 1.0:
        return "不达标: 接近 M0 (两刀都未生效?)"
    return "异常: 先查守卫与流是否在跑"


# ---------------------------------------------------------------- 解析层
def parse_snap(path):
    """comma-free 规范文本 -> (dict W, gen0, gen1). 只做最小解析, 守卫在正式脚本里."""
    W, gen = {}, None
    for ln in open(path, encoding="utf-8", errors="replace"):
        ln = ln.strip()
        m = re.match(r"^W(\d+)\s+(0[xX][0-9a-fA-F]{1,8})$", ln)
        if m:
            W[int(m.group(1))] = int(m.group(2), 16)
            continue
        m = re.match(r"^GEN\s+(\d+)\s+(\d+)$", ln)
        if m:
            gen = (int(m.group(1)), int(m.group(2)))
    return W, (gen[0] if gen else None), (gen[1] if gen else None)


def parse_nic(path):
    """NIC 计数文本 -> dict. 每行 "key <十进制>" (key 允许 . 与 -) — 与 gate4 脚本同形."""
    d = {}
    for ln in open(path, encoding="utf-8", errors="replace"):
        ln = ln.strip()
        m = re.match(r"^([A-Za-z][A-Za-z0-9_.\-]*)\s+(\d+)$", ln)
        if m:
            d[m.group(1)] = int(m.group(2))
    return d


def report(Wa, Wb, Ga, Gb, na=None, nb=None):
    """Wa/Wb = 两次快照的字; na/nb = 两次 NIC 计数 (dict)."""
    out = []
    dg = (Gb - Ga) % 65536
    out.append("L3 gen: %d -> %d  dgen=%d  %s" % (Ga, Gb, dg, "OK" if dg == 1 else "**FAIL 整轮作废**"))

    need = (5, 8, 9, 13, 20, 21, 24, 41, 42, 43)
    miss = [k for k in need if k not in Wa or k not in Wb]
    if miss:
        return out + ["**缺字 W%s => 拒绝出结论**" % miss]

    d = {k: d32(Wa[k], Wb[k]) for k in need}
    for k in need:
        out.append("  dW%-3d = %-12d%s" % (k, d[k][0], "  (回绕!)" if d[k][1] else ""))

    dW20, dW5, dW24 = d[20][0], d[5][0], d[24][0]
    if dW20 == 0 or dW5 == 0 or dW24 == 0:
        return out + ["**dW20/dW5/dW24 有 0 => 流没在跑 / 读失败; 不许当'速率=0'报**"]

    dt = dW5 / F_FE
    fps_fe, fps_dp = fps_from(dW20, dW5, dW24)
    g = gbps_load(fps_fe)
    out.append("窗口 dt = %.4f s (由 dW5 定; 硬上限 3.6 s 由 W9 回绕定: %s)"
               % (dt, "OK" if dt < 3.6 else "**超限, W9 已回绕**"))
    out.append("fps_FE = %.1f   fps_DP = %.1f   两域差 = %+.3f%%  %s"
               % (fps_fe, fps_dp, 100 * (fps_dp / fps_fe - 1),
                  "OK" if abs(fps_dp / fps_fe - 1) < 1e-3 else "**>0.1% => 报警(时基/域）**"))
    out.append("载荷 = %.3f Gbps   线上 = %.3f Gbps   802.3 上限 %.3f"
               % (g, fps_fe * LWIRE * 8 / 1e9, UP_8023))
    out.append("分级: %s   (达标界 %.2f Gbps)" % (grade(g), BOUND_GBPS))

    # ---- A1..A5 辅助判据 ----
    out.append("A1 dW43/dW20 = %.3f  (期望 193.24±0.1) %s"
               % (d[43][0] / dW20, "OK" if abs(d[43][0] / dW20 - HDR_XGMII) <= 0.1
                  else "**FAIL 帧长/IFG/中止异常**"))
    out.append("A2 dW8-dW20 = %d  (期望 0..2, 且 dW21==0) %s"
               % (d[8][0] - dW20, "OK" if 0 <= d[8][0] - dW20 <= 2 and d[21][0] == 0
                  else "**FAIL => 主判据换 dW8**"))
    out.append("A3 dW21=%d dW41=%d dW42=%d  (全 0 才允许用主判据) %s"
               % (d[21][0], d[41][0], d[42][0],
                  "OK" if max(d[21][0], d[41][0], d[42][0]) == 0 else "**FAIL**"))
    out.append("A4 dW13(失配) = %d  (必须 0) %s"
               % (d[13][0], "OK" if d[13][0] == 0 else "**FAIL 内容错**"))
    dl, wrap9 = d32(Wa[9], Wb[9])
    out.append("A5 dW9/dW20 = %.3f (期望 1472±1%s) %s"
               % (dl / dW20, ", **已回绕, 降级旁证**" if wrap9 else "",
                  "OK" if (not wrap9 and abs(dl / dW20 - PLOAD) <= 1) else "**FAIL/不可判**"))

    # ---- 独立口径 (NIC) ----
    if na and nb:
        def di(k):
            return nb.get(k, 0) - na.get(k, 0)
        out.append("--- 独立口径 (四项差分账) ---")
        out.append("  d_board=%d  d_mac=%d  d_dma=%d  d_nd=%d"
                   % (dW20, di("port_rx_packets"), di("rx-0.rx_packets"), di("port_rx_nodesc_drops")))
        out.append("  d_crc(EF10)=%d  d_bad(port)=%d  d_ovf=%d"
                   % (di("rx_eth_crc_err"), di("port_rx_bad"), di("port_rx_overflow")))
        out.append("  N_SELF: good+bad-packets = %d  (容差 ±2) %s"
                   % (nb.get("port_rx_good", 0) + nb.get("port_rx_bad", 0) - nb.get("port_rx_packets", 0),
                      "OK" if abs(nb.get("port_rx_good", 0) + nb.get("port_rx_bad", 0)
                                  - nb.get("port_rx_packets", 0)) <= 2 else "**FAIL**"))
        dmac = di("port_rx_packets")
        if dW20:
            r = dmac / dW20
            out.append("  V1 裁决: d_mac/d_board = %.4f  => %s"
                       % (r, "甲(独立口径可用, 板子清白)" if 0.995 <= r <= 1.005
                          else "**乙/或线上丢失 => 见 P7B_RATE_MEASURE_PLAN.md §8-R1 判别树**"))
        # 量程自检 B0-2 / B0-3
        if di("port_rx_good") > 0:
            out.append("  B0-2 平均帧长 = %.2f (期望 1518±2) %s"
                       % (di("port_rx_good_bytes") / di("port_rx_good"),
                          "OK" if abs(di("port_rx_good_bytes") / di("port_rx_good") - 1518) <= 2
                          else "**FAIL => 帧不是我们的帧 / 有背景流量**"))
    return out


# ---------------------------------------------------------------- 自检
def _selftest():
    ok = True

    def chk(name, cond, extra=""):
        nonlocal ok
        print("  [%s] %s %s" % ("OK  " if cond else "FAIL", name, extra))
        ok = ok and cond

    print("== rate_calc 自检 (量测函数喂已知真值) ==")
    # 1) 旧模态: 闸 4 板级实测 106,003.170 fps <=> 1474 拍/帧
    fps, g = predict_from_tpf(1474)
    chk("旧模态 1474 拍/帧 -> fps", abs(fps - 106003.39) < 1.0, "= %.2f" % fps)
    chk("旧模态 -> 载荷 Gbps", abs(g - 1.248) < 0.005, "= %.4f" % g)
    # 2) 期望档: 193.24 拍/帧
    fps2, g2 = predict_from_tpf(193.24)
    chk("期望档 193.24 拍/帧 -> fps", abs(fps2 - 808579) < 50, "= %.0f" % fps2)
    chk("期望档 -> 载荷 Gbps", abs(g2 - 9.523) < 0.005, "= %.4f" % g2)
    chk("期望档 -> 线上占比 ~99.5%", abs(fps2 * LWIRE * 8 / 1e10 * 100 - 99.51) < 0.05)
    # 3) 界的设定: 几何中点, 两端各留 ~40%
    chk("几何中点 = sqrt(4.870*9.523)", abs(BOUND_MID - 6.81) < 0.02, "= %.3f" % BOUND_MID)
    chk("判据界的取整值 = 6.8", abs(BOUND_GBPS - 6.8) < 1e-9 and abs(BOUND_GBPS - BOUND_MID) < 0.02,
        "= %.3f (中点 %.3f)" % (BOUND_GBPS, BOUND_MID))
    chk("界到 M1 的裕量 >30%", (BOUND_GBPS / 4.870 - 1) > 0.30, "= +%.1f%%" % (100 * (BOUND_GBPS / 4.870 - 1)))
    chk("界到 M2 的裕量 >25%", (1 - BOUND_GBPS / 9.523) > 0.25, "= -%.1f%%" % (100 * (1 - BOUND_GBPS / 9.523)))
    # 4) 分级表覆盖三个模态
    chk("分级: 1.248 -> M0 档", "M0" in grade(1.248) or "两刀都未生效" in grade(1.248), grade(1.248))
    chk("分级: 4.870 -> 一刀档", "一刀" in grade(4.870), grade(4.870))
    chk("分级: 6.8 -> 达标", grade(6.8).startswith("达标"), grade(6.8))
    chk("分级表与达标界不冲突 (界-eps 不达标 / 界+eps 达标)",
        (not grade(BOUND_GBPS - 0.01).startswith("达标"))
        and grade(BOUND_GBPS + 0.01).startswith("达标"),
        "%.2f=%s | %.2f=%s" % (BOUND_GBPS - 0.01, grade(BOUND_GBPS - 0.01),
                               BOUND_GBPS + 0.01, grade(BOUND_GBPS + 0.01)))
    chk("分级: 9.52 -> 满效", grade(9.52) == "满效", grade(9.52))
    chk("分级: 9.6 -> 口径错", "口径错" in grade(9.6), grade(9.6))
    # 5) 32 位差分回绕
    d, w = d32(0xFFFFFF00, 0x00000100)
    chk("d32 回绕", d == 0x200 and w, "d=%d wrap=%s" % (d, w))
    # 6) 时基: 2.5 s 窗口 @156.25MHz 在 32 位内 (真正的窗口上限 3.6 s 由 W9 定, 见下一条)
    chk("2.5s 窗口内 W5/W24/W43 不回绕", 2.5 * F_FE < W32,
        "= %.0f 拍 (W5/W24/W43 的 32 位上限 = %.2f s)" % (2.5 * F_FE, W32 / F_FE))
    chk("W9 回绕周期 3.61 s", abs(W32 / (fps2 * PLOAD) - 3.61) < 0.02,
        "= %.2f s" % (W32 / (fps2 * PLOAD)))
    chk("窗口 2.5 s < W9 回绕周期", 2.5 < W32 / (fps2 * PLOAD))
    print("== 自检: %s ==" % ("全部通过" if ok else "**有失败, 本文件的读数不许用**"))
    return 0 if ok else 1


def main(argv):
    if "--selftest" in argv or len(argv) == 1:
        return _selftest()
    if "--tf" in argv:
        tpf = float(argv[argv.index("--tf") + 1])
        fps, g = predict_from_tpf(tpf)
        print("拍/帧 %.3f -> fps %.1f -> 载荷 %.3f Gbps -> 分级: %s" % (tpf, fps, g, grade(g)))
        return 0
    if "--snapA" in argv and "--snapB" in argv:
        Wa, Ga0, Ga1 = parse_snap(argv[argv.index("--snapA") + 1])
        Wb, Gb0, Gb1 = parse_snap(argv[argv.index("--snapB") + 1])
        na = parse_nic(argv[argv.index("--nicA") + 1]) if "--nicA" in argv else None
        nb = parse_nic(argv[argv.index("--nicB") + 1]) if "--nicB" in argv else None
        for ln in report(Wa, Wb, Ga1 if Ga1 is not None else 0,
                         Gb1 if Gb1 is not None else 0, na, nb):
            print(ln)
        return 0
    print(__doc__)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
