#!/usr/bin/env python3
"""mk_fake.py -- 生成一对**合成的**快照/NIC 文本 (期望档 808,579 fps), 用于离线验证取数器。
用途 = 工程纪律要求的"用合成数据做正/负对照": 判据必须在这里报对, 才允许拿到板上用。
全 0 模态 / 只一刀模态的变体由命令行 --mode 选。"""
import sys, os
HERE = os.path.dirname(os.path.abspath(__file__))
F_DP, PLOAD, XGMII = 156.25e6, 1472, 193.24
W32 = 1 << 32
mode = sys.argv[1] if len(sys.argv) > 1 else "full"
DT = 2.5
# 三个模态的每帧拍数
TPF = {"full": 193.24, "half": 378.0, "old": 1474.0}[mode]
dW5 = int(round(DT * F_DP)); dW24 = dW5
dW20 = int(round(DT * F_DP / TPF))
dW43 = int(round(dW20 * XGMII))
dW9 = int(round(dW20 * PLOAD))
A = dict(W5=0x10000000, W20=0x00100000, W24=0x10000000, W43=0, W8=0x00100000, W9=0,
         W21=0, W41=0, W42=0, W13=0)
B = dict(A); B["W5"] += dW5; B["W24"] += dW24; B["W20"] += dW20; B["W43"] += dW43
B["W8"] += dW20 + 1; B["W9"] += dW9
for p, W, g in (("a", A, 12), ("b", B, 13)):
    with open(os.path.join(HERE, "fake_snap_%s.txt" % p), "w") as f:
        for i in range(51):
            f.write("W%d 0x%08X\n" % (i, W.get("W%d" % i, 0)))
        f.write("GEN %d %d\n" % (g, g))
# NIC: 甲 情形 (d_mac == d_board, 差额被 nodesc_drops 解释)
na = dict(**{"port_rx_packets": 2600444047, "port_rx_good": 1579810536, "port_rx_bad": 1020633512,
             "port_rx_good_bytes": 2397570863398, "port_rx_bytes": 2650687976438,
             "port_rx_nodesc_drops": 109876, "port_rx_overflow": 0, "rx_eth_crc_err": 1,
             "rx-0.rx_packets": 1403489479})
nb = dict(na)
nb["port_rx_packets"] += dW20
nb["port_rx_good"] += dW20
nb["port_rx_good_bytes"] += dW20 * 1518
nb["port_rx_bytes"] += dW20 * 1518
nb["rx-0.rx_packets"] += dW20 - 250000
nb["port_rx_nodesc_drops"] += 250000
for p, d in (("a", na), ("b", nb)):
    with open(os.path.join(HERE, "fake_nic_%s.txt" % p), "w") as f:
        for k, v in d.items():
            f.write("%s %d\n" % (k, v))
print("mode=%s  dW20=%d dW5=%d dW43=%d dW9=%d" % (mode, dW20, dW5, dW43, dW9))
