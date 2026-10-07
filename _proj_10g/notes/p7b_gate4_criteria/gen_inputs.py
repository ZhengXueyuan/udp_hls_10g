#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_inputs.py — 为「闸 4 判据收口」的负对照生成**规范形态**的合成读数文本。

为什么用 Python 而不是 sed: 每个 case 里要动的量之间有算术约束 (守恒律 / good+bad==packets /
两个口径的窗口与速率), 用 sed 拼就是一堆隐式耦合; 这里全部**显式算出来**, 每个数都来自算式。

形态与真读数**逐字同形** (`reg_rw` 打 `0x..`; `ethtool -S` 打 "键 十进制"):
  快照 : SNAP_BEGIN / TLATCH / GEN / MAGIC / BID / MARKER / W0..W62 / UNIMPL / SNAP_END
         ⚠️ 几何 = **63 字 / BID 9** (P7B-WU 二轮, 2026-10-07 "台架修复轮"从 51 字/BID 7 同步)
            —— 必须与 `_proj_pcie/p7b_gate4_accept.sh` 的默认 `SNAP_WORDS`/`EXPECT_BID` 同代,
            否则 accept 会因"窗口不完整: 缺 W51 / 身份不符"把整套反例台架打成假红 (实测)。
  NIC  : NIC_BEGIN / TLATCH / <键 十进制>... / NIC_END

⚠️ 值口径与 `board/wrapper_p4.v` 逐项对应 (不是随手编的数):
  · W5/W24/W50 = 三个时钟域的 32 位自由计数 ⇒ Δ = 标称 156.25 MHz × 窗口
  · W0/W30/W32/W33/W1/W31 = 停机态守恒律 (W30 == W0+W32; W31 == W1-4·W0+W33)
  · W20 = mac_tx_frames (**MAC 级**发帧) ⇒ N_XCHK 的板侧分子
  · W39 = 0x2000100C (PCS 状态束: gpw/block_lock/rx_status=1 且 err 全 0)
  · W40 = {evt×3, valid_ctrl_code_cyc}: 两块之间必须"在涨" (否则 C8 判据自己要 FAIL)
⚠️ 时间戳口径: 快照的 TLATCH = **一次读数**的起止 (~50 ms, 与真 `SNAP_REMOTE` 同形);
  NIC 的 TLATCH = 一次 `ethtool -S` 的起止 (~1.3 ms)。判据用的窗口 = 两块 TLATCH 的**中点差**。
"""
import os
import re
import sys

F = 156_250_000.0          # 三个域的标称 (P7B_10G 前端 = PCS 恢复钟; 数据面/TX 同)
W32 = 1 << 32

# 本生成器的几何 (必须与 `_proj_pcie/p7b_gate4_accept.sh` 的**默认**值同代, 否则整套反例台架
# 会在"窗口不完整 / 身份不符"上**假红** —— 2026-10-07 "台架修复轮"实测: 51 字夹具 + BID 7
# 喂给 63 字/BID 9 的 accept ⇒ clean 正对照退出 2、15 条反例全部 BAD)。
NW_FIX = 63                # 快照字数 (W0..W62)
BID_FIX = 0x00000009       # 位流身份 (P7B-WU 二轮)


def _geo_guard():
    """生成前先核: accept 的默认几何必须与本夹具同代 —— 不同代就**拒绝生成** (否则喂出去是假红)。

    只读 `SNAP_WORDS=${SNAP_WORDS:-N}` / `EXPECT_BID=${EXPECT_BID:-0xN}` 两行 (源码是唯一权威)。"""
    here = os.path.dirname(os.path.abspath(__file__))
    acc = os.path.join(here, '..', '..', '..', '_proj_pcie', 'p7b_gate4_accept.sh')
    try:
        s = open(acc, encoding='utf-8').read()
    except OSError as e:
        sys.stderr.write("GEOM_GUARD_FAIL 读不到 %s: %s\n" % (acc, e))
        sys.exit(3)
    m1 = re.search(r'SNAP_WORDS=\$\{SNAP_WORDS:-(\d+)\}', s)
    m2 = re.search(r'EXPECT_BID=\$\{EXPECT_BID:-(0x[0-9a-fA-F]+)\}', s)
    nw = int(m1.group(1)) if m1 else -1
    bid = int(m2.group(1), 16) if m2 else -1
    if nw != NW_FIX or bid != BID_FIX:
        sys.stderr.write(
            "GEOM_GUARD_FAIL: accept 默认几何 = (SNAP_WORDS=%s, EXPECT_BID=0x%X), "
            "本夹具 = (%d, 0x%X)\n  两者不同代 ⇒ 生成出来的合成读数会被 accept 判成"
            "窗口不完整/身份不符 (假红)。\n  请先同步 gen_inputs.py 的 NW_FIX/BID_FIX "
            "(或反过来核 RTL 的 SNAP_NW_P6E/BUILD_ID_V), 再跑。\n"
            % (nw, bid if bid >= 0 else 0, NW_FIX, BID_FIX))
        sys.exit(3)


# ---- 每个 case 的"形状" ---------------------------------------------------------
#   midA/midB : 快照 A/B 的锁存时刻 (G2 频率窗);  midC/midD : 快照 C/D 的锁存时刻 (N_XCHK 板侧窗)
#   nic_ab/nic_cd : NIC 读数的 t0 (t1 = t0 + 1.3 ms)
#   d20   : 板侧 C→D 的 ΔW20 (MAC 发帧)     dpkt : 主机侧 C→D 的 Δport_rx_packets
#   resid_d : nic_D 的 good 端点偏置 (自洽残差)
CASES = {
    # 正对照: 一切自洽, 两口径**同刻** (板侧锁存 1000.0/1020.0; NIC 读数 999.98/1019.98)
    "clean":           dict(midA=1000.0, midB=1005.0, midC=1000.0, midD=1020.0,
                            nic_ab=(999.99, 1004.99), nic_cd=(999.98, 1019.98),
                            d20=2_120_000, dpkt=2_120_000, resid_d=0),
    # ★ 实测形态 (真验收轮 `nic_D` 内部 good+bad = packets **+1**): 容差内 ⇒ 必须 PASS
    "ns_self_plus1":   dict(midA=1000.0, midB=1005.0, midC=1000.0, midD=1020.0,
                            nic_ab=(999.99, 1004.99), nic_cd=(999.98, 1019.98),
                            d20=2_120_000, dpkt=2_120_000, resid_d=+1),
    # ★ 真缺陷形态: 有一类帧记进 packets 却不进 good/bad (1% = 21200 帧) ⇒ 必须 FAIL
    "ns_self_classgap": dict(midA=1000.0, midB=1005.0, midC=1000.0, midD=1020.0,
                             nic_ab=(999.99, 1004.99), nic_cd=(999.98, 1019.98),
                             d20=2_120_000, dpkt=2_120_000, resid_d=-21200),
    # ★ 真验收轮的**取数编排**形态: NIC 窗先 (1000.05 → 1004.05), 板侧窗后 (1010.0 → 1015.9)
    #   ⇒ 两端错开 9.95 / 11.85 s ⇒ 同刻守卫必须 SKIP (旧口径在这里算出了 0.4%~24.5% 的"偏差")
    "xchk_offset":     dict(midA=1000.0, midB=1005.0, midC=1010.0, midD=1015.9,
                            nic_ab=(999.99, 1004.99), nic_cd=(1000.05, 1004.05),
                            d20=630_681, dpkt=423_597, resid_d=0),
    # 同刻但窗口只有 5 s ⇒ 参考侧量子(≈1 s)/窗口 = 20% ⇒ 结构性反解不到 1% ⇒ SKIP(口径不足)
    "xchk_narrow":     dict(midA=1000.0, midB=1005.0, midC=1000.0, midD=1005.0,
                            nic_ab=(999.99, 1004.99), nic_cd=(999.98, 1004.98),
                            d20=530_000, dpkt=530_000, resid_d=0),
    # 同刻 + 20 s 窗, 但主机侧帧率高出 30% ⇒ 超量子容差(10%) ⇒ 必须 FAIL (证明判据还有牙)
    "xchk_dev30":      dict(midA=1000.0, midB=1005.0, midC=1000.0, midD=1020.0,
                            nic_ab=(999.99, 1004.99), nic_cd=(999.98, 1019.98),
                            d20=2_120_000, dpkt=2_756_000, resid_d=0),
}

TRAFFIC = {
    # ★ 本轮**真实**的激励日志 (原件 = notes/p7b_gate4_2/accept/traffic_cmd.txt)
    #   ⇒ T_RUN PASS + T_TOOL SKIP(工具接收侧天花板), 且**不得**出现"板子缺陷"式结论
    "t_run_ok": "@REAL@",
    # 工具自己报零帧 ⇒ 真警示 (板子没发 / peer 没学到 / 网段不对)
    "t_tool_noframes": """TRAFFIC_BEGIN
TRAFFIC_CMD <cd /home/a/xdma_test && ./p6e_udp_pattern --secs 15 --board 192.168.100.2 --port 8081>
=== p6e_udp_pattern (C++, 吞吐口径): 本地 :8081 <-> 板子 192.168.100.2:8081 ===
  [汇总] 收 0 帧 / 0 字节 / 15.00s ⇒ **0.0 Mbps** (接收侧口径)
  [FAIL] 一个包都没收到 ⇒ peer 没学到 / 板子没发 / 网段不对
TRAFFIC_RC=1
TRAFFIC_END
""",
    # 命令本身没跑起来 (shell 找不到) ⇒ T_RUN FAIL, 且必须点名"先怀疑激励侧"
    "t_run_127": """TRAFFIC_BEGIN
TRAFFIC_CMD </nonexistent/p6e_udp_pattern --secs 3>
bash: line 1: /nonexistent/p6e_udp_pattern: No such file or directory
TRAFFIC_RC=127
TRAFFIC_END
""",
    # fix2 (b) 要防的**原始**失效形态: 没有 BEGIN/END/RC 三行凭证 ⇒ 必须 FAIL
    "t_run_noproof": """=== p6e_udp_pattern (C++, 吞吐口径): 本地 :8081 <-> 板子 192.168.100.2:8081 ===
    [  1.0s] 帧=547 字节=805184  ≈    6.4 Mbps  失配=0 掉包=546
  [汇总] 收 1665 帧 / 2450880 字节 / 17.17s ⇒ **1.1 Mbps** (接收侧口径)
""",
}


def snap_words(lat, w20, vcc):
    """**63 字 (W0..W62)**; lat = 该块锁存的时刻 (秒) ⇒ 三个域自由计数由它算出。
    W51..W62 (P7B-BIZ/WU 新增字) 全填 0 —— accept 只要求"窗口齐全 + 无 0xffffffff 混入";
    若将来判据开始消费某个新字, **这里要跟着造它的真形态** (否则负对照会"打空")。"""
    W = [0] * NW_FIX
    W[0] = 1000                                     # rx_stat_frames
    W[1] = 1_518_000                                # rx_stat_bytes
    W[2] = 1518                                     # 最近线上帧长
    W[5] = int(lat * F) % W32                       # gmii_free   (前端域)
    W[6] = 1000                                     # srx_stat_commit
    W[7] = 1000                                     # stx_stat_frames
    W[20] = w20                                     # mac_tx_frames ⭐N_XCHK 板侧分子
    W[24] = (int(lat * F) + 777_777) % W32          # dp_free     (数据面域)
    W[30] = 1000                                    # rxcdc_out_frames (守恒律: == W0 + W32)
    W[31] = 1_518_000 - 4 * 1000                    # rxcdc_out_bytes  (== W1 - 4W0 + W33)
    W[39] = 0x2000100C                              # PCS 状态束 (C1..C7)
    W[40] = vcc                                     # {evt×3, valid_ctrl_code_cyc} (C8/C6-ev)
    W[50] = (int(lat * F) + 555_555) % W32          # tx_clk_act (TX 域 toggle 沿)
    return W


def emit_snap(path, mid, gen0, w20, vcc, half=0.025):
    """快照块: TLATCH 是**一次读数**的起止 (±half), GEN 恰好 +1。"""
    W = snap_words(mid, w20, vcc)
    # ⚠️ `encoding="utf-8"` 必须显式给: 本机默认是 GBK ⇒ 中文/箭头字符会 UnicodeEncodeError
    #   (本工程坑 16① 的同族; 第一次跑就是这么挂的)
    with open(path, "w", newline="\n", encoding="utf-8") as fh:
        fh.write("SNAP_BEGIN\n")
        fh.write("TLATCH %.9f %.9f\n" % (mid - half, mid + half))
        fh.write("GEN %d %d\n" % (gen0, gen0 + 1))
        fh.write("MAGIC 0x50360001\nBID 0x%08X\nMARKER 0xdeadbeef\n" % BID_FIX)
        for i, v in enumerate(W):
            fh.write("W%d 0x%X\n" % (i, v))
        fh.write("UNIMPL 0xffffffff\nSNAP_END\n")


def emit_nic(path, t0, good, packets, bad=0, dt=0.0013):
    """NIC 块。⚠️ `packets` **独立传入**: 三字段不是一次原子快照 ⇒ 允许 good+bad ≠ packets
    (真 `nic_D`: good+bad = packets+1)。bytes 按 packets 记 (线上字节跟着"收了多少帧"走)。"""
    with open(path, "w", newline="\n", encoding="utf-8") as fh:
        fh.write("NIC_BEGIN\n")
        fh.write("TLATCH %.9f %.9f\n" % (t0, t0 + dt))
        for k, v in (("rx_eth_crc_err", 0), ("port_rx_packets", packets), ("port_rx_good", good),
                     ("port_rx_bad", bad), ("port_rx_bytes", packets * 1518), ("port_rx_unicast", good),
                     ("port_rx_multicast", 0), ("port_rx_broadcast", 0), ("port_rx_64", 0),
                     ("port_rx_65_to_127", 257), ("port_rx_128_to_255", 0),
                     ("port_rx_256_to_511", 0), ("port_rx_512_to_1023", 0),
                     ("port_rx_1024_to_15xx", good), ("port_rx_15xx_to_jumbo", 0),
                     ("port_rx_overflow", 0), ("port_rx_nodesc_drops", 0),
                     ("port_tx_packets", 9538)):
            fh.write("%s %d\n" % (k, v))
        fh.write("NIC_END\n")


def build(out, name, c, real_traffic):
    d = os.path.join(out, name)
    os.makedirs(d, exist_ok=True)
    # ---- 快照 4 块: A/B = 停机态 (G2 频率窗 5 s); C/D = 测量窗 ----
    emit_snap(os.path.join(d, "snap_A.txt"), c["midA"], 10, 998, 0x66)
    emit_snap(os.path.join(d, "snap_B.txt"), c["midB"], 11, 998, 0x99)   # vcc 在涨 ⇒ C8 PASS
    w20_c = 1_000_000
    emit_snap(os.path.join(d, "snap_C.txt"), c["midC"], 12, w20_c, 0xA0)
    emit_snap(os.path.join(d, "snap_D.txt"), c["midD"], 13, w20_c + c["d20"], 0xB0)
    # ---- NIC 4 块: 基线 Δgood == 0 (判别力自检必须成立); 测量 Δpackets == dpkt, 端点残差 = resid_d
    na0, na1 = c["nic_ab"]
    nc0, nc1 = c["nic_cd"]
    g_base = 5_000_000
    pkt_c = g_base + 1_000_000
    pkt_d = pkt_c + c["dpkt"]
    good_d = pkt_d + c["resid_d"]          # 端点 D 的自洽残差 (= good+bad-packets)
    emit_nic(os.path.join(d, "nic_A.txt"), na0, g_base, g_base)
    emit_nic(os.path.join(d, "nic_B.txt"), na1, g_base, g_base)
    emit_nic(os.path.join(d, "nic_C.txt"), nc0, pkt_c, pkt_c)
    emit_nic(os.path.join(d, "nic_D.txt"), nc1, good_d, pkt_d)
    # ---- 激励日志 (可无) ----
    tv = TRAFFIC.get(name)
    if tv is not None:
        p = os.path.join(d, "traffic.txt")
        with open(p, "w", newline="\n", encoding="utf-8") as fh:
            if tv == "@REAL@":
                if not real_traffic or not os.path.exists(real_traffic):
                    raise SystemExit("缺真实激励日志 (第二个参数): %s" % real_traffic)
                fh.write(open(real_traffic, encoding="utf-8", errors="replace").read())
            else:
                fh.write(tv)


def main():
    _geo_guard()           # 代际守卫: 夹具与 accept 默认几何必须同代 (不同代拒绝生成, 见上)
    here = os.path.dirname(os.path.abspath(__file__))
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "inputs")
    real_traffic = sys.argv[2] if len(sys.argv) > 2 else ""
    names = list(CASES) + [n for n in TRAFFIC if n not in CASES]
    for n in names:
        build(out, n, CASES.get(n, CASES["clean"]), real_traffic)
    print("生成完成: %d 个 case -> %s" % (len(names), out))
    for n in names:
        print("  %s" % n)


if __name__ == "__main__":
    main()
