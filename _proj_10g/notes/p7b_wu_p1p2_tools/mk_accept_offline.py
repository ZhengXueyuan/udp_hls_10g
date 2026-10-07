#!/usr/bin/env python3
"""mk_accept_offline.py -- 造 **63 字 / BUILD_ID=10** 的合成快照与 NIC 文本, 给
   ⛔ 2026-10-07 Stage C BID 同步轮: 上一行原写 "BUILD_ID=9" (P7B-WU 二轮) —— 窗口没动,
      身份 9 → 10; 本夹具的 BID 行必须与 accept 默认 EXPECT_BID 同代 (否则离线正例身份闸假红)。
`_proj_pcie/p7b_gate4_accept.sh` 的**离线档**当正例 (不碰板子)。

为什么要有它 (本工程"判据必须真跑"):
  p7b_gate4_accept.sh 的两半里, **判据层是纯函数** ⇒ 可以喂合成文本证明"它在正确输入下判 PASS"。
  这是"新脚本 × 旧板"失败证据的**对照组**: 失败必须归因于"板上是旧几何", 不是"脚本写坏了"。

口径 (与真板/真判据对齐的地方):
  · W0..W50 的取值**照抄** `_proj_pcie/p7b_gate4_negctrl.sh` 的 clean 夹具
    (守恒律 W30==W0+W32 / W31==W1-4W0+W33 / W39 的 PCS 位 / W40 的 vcc 递增 都由它满足)。
  · W51..W60 用**现场真读数** (`logs/new_script_old_board_snapcheck.txt` 那一趟的 63 字窗口)。
  · W61/W62 = 63 字窗口的新字: W61=stat_wu(次数) / W62=rx_occ_bytes(17 位 ⇒ 高 15 位恒 0)。
  · 两个快照块的 TLATCH 差 10 s ⇒ G2 三个频率判据的窗口成立;
    W5/W24/W50 的增量 = 156.25e6 × 10 = 1,562,500,000 (三个域都按 156.25 MHz)。
  · NIC 的 A/B 两块差 5 s, Δgood = 4,060,000 帧 ⇒ ≈9.86 Gbps > 阈值 800 Mbps。

用法: python _proj_10g/notes/p7b_wu_p1p2_tools/mk_accept_offline.py <输出目录>
"""
import os
import sys

# ---- W0..W50: 照抄 negctrl 的 clean 夹具 (只把 w5/w24/w50 参数化) -----------------
W5_A, W24_A, W50_A = 1000000, 2000000, 3000000
D10 = 156250000 * 10            # 10 s @156.25 MHz
VCC_A, VCC_B = 0x66, 0x99
# 现场真读数 (63 字窗口 W51..W60; 取自 2026-10-07 的实测窗口)
REAL = {51: 0x01900000, 52: 0x00004637, 53: 0x2bd63cfc, 54: 0x3c9160c2,
        55: 0x000004d0, 56: 0x00000000, 57: 0x123640f1, 58: 0x00000000,
        59: 0x00000000, 60: 0x00000000}
W61, W62 = 7, 0x00000800    # stat_wu=7 次 / rx_occ=2048 B (17 位 ⇒ 高 15 位 0)


def words(which):
    """which ∈ {A, B}: 返回 63 个字的列表"""
    inc = 0 if which == "A" else D10
    vcc = VCC_A if which == "A" else VCC_B
    w5, w24, w50 = W5_A + inc, W24_A + inc, W50_A + inc
    w20 = 998
    head = [1000, 1518000, 1518, 0, 0, w5, 998, 998, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            w20, 0, 0, 0, w24, 1, 0, 0, 0, 0, 1000, 1514000, 0, 0, 0, 0,
            20000000, 151800000, 0, 0x2000100C, vcc, 0, 0, 0, 0, 0, 0, 0, 0, 0, w50]
    assert len(head) == 51
    tail = [REAL[i] for i in range(51, 61)] + [W61, W62]
    return head + tail


def snap_text(which, t0, t1, gen):
    v = words(which)
    return ("SNAP_BEGIN\n"
            "TLATCH %.3f %.3f\n"
            "GEN %d %d\n"
            "MAGIC 0x50360001\n"
            "BID 0x0000000A\n"   # ⛔ 2026-10-07 Stage C: 原 0x00000009
            "MARKER 0xdeadbeef\n"
            % (t0, t1, gen, gen + 1)
            ) + "".join("W%d 0x%X\n" % (i, x) for i, x in enumerate(v)) + \
        "UNIMPL 0xffffffff\nSNAP_END\n"


NIC_HEAD = "NIC_BEGIN\nTLATCH %.3f %.3f\n"
NIC_BODY = ("rx_eth_crc_err {crc}\nport_rx_packets {pkt}\nport_rx_good {good}\n"
            "port_rx_bad {bad}\nport_rx_bytes {byt}\nport_rx_unicast {uni}\n"
            "port_rx_multicast 0\nport_rx_broadcast {good}\nport_rx_64 {m64}\n"
            "port_rx_65_to_127 170\nport_rx_128_to_255 0\nport_rx_256_to_511 0\n"
            "port_rx_512_to_1023 0\nport_rx_1024_to_15xx {b1518}\nport_rx_15xx_to_jumbo 0\n"
            "port_rx_overflow 0\nport_rx_nodesc_drops 0\nport_tx_packets 7585\nNIC_END\n")


def nic_text(good, t0, t1):
    return NIC_HEAD % (t0, t1) + NIC_BODY.format(
        crc=0, pkt=good, good=good, bad=0, byt=good * 1518, uni=good,
        m64=0, b1518=good)


def main():
    out = sys.argv[1]
    if not os.path.isdir(out):
        os.makedirs(out)
    files = {}
    files["snap_A.txt"] = snap_text("A", 1000.000, 1000.010, 140)
    files["snap_B.txt"] = snap_text("B", 1010.000, 1010.010, 141)
    files["nic_A.txt"] = nic_text(5000000, 1000.000, 1000.010)
    files["nic_B.txt"] = nic_text(5000000 + 4060000, 1005.000, 1005.010)
    for name, txt in files.items():
        p = os.path.join(out, name)
        with open(p, "w", newline="\n") as fh:
            fh.write(txt)
        print("WROTE %s (%d B)" % (p, len(txt)))
    print("USE: G4_SNAP_TEXT=%s/snap_A.txt,%s/snap_B.txt "
          "G4_NIC_TEXT=%s/nic_A.txt,%s/nic_B.txt bash _proj_pcie/p7b_gate4_accept.sh"
          % (out, out, out, out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
