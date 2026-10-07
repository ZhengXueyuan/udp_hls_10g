import re, sys
# ⛔ 2026-10-07 订正 (P7B StB 判据修正轮): 原句 = `d20, d8, d9 = WB[20]-WA[20], WB[8]-WA[8], WB[9]-WA[9]`
#    —— **裸减法**, 无 mod。W9 (`udpapp_tx_bytes`) 是 32 位, 9.53 Gbps 载荷下 **3.61 s 就回卷一次**,
#    而本档 xchk 窗实测 dtB ≈ 5.7 s (P7B_GATE4_ACCEPT2/3 的端点时差) ⇒ dW9 至少回卷 1 次, 印出的
#    "板侧 app 载荷率 (W9)" 会**静默错 70%**。现: mod 2^32 + 用**网卡字节** (含 FCS, 每帧 +4) 还原
#    k·2^32, 并打印 raw/k (回卷必须可见)。
M32 = 1 << 32
def dw32(a, b):
    """32 位差分: 返回 (mod 余数, 是否肉眼可见地"减了")。⚠️ 余数本身仍可能差 k·2^32。"""
    return (b - a) % M32, (b < a)
p = sys.argv[1] if len(sys.argv) > 1 else r'D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_gate4_2\xchk_probe.txt'
t = open(p, encoding='utf-8', errors='replace').read().replace('\r', '')
nic_ts = {}
snap_ts = {}
for m in re.finditer(r'^NIC_TS (\w+) ([\d.]+) ([\d.]+)$', t, re.M):
    nic_ts[m.group(1)] = (float(m.group(2)), float(m.group(3)))
for m in re.finditer(r'^SNAP_TS (\w+) ([\d.]+)$', t, re.M):
    snap_ts[m.group(1)] = float(m.group(2))
blocks = re.findall(r'NIC_BEGIN \w+\n(.*?)NIC_TS', t, re.S)
snic = {}
for name, blk in zip(['A', 'B'], blocks):
    d = {}
    for line in blk.strip().splitlines():
        k, v = line.split()
        d[k] = int(v)
    snic[name] = d
A, B = snic['A'], snic['B']
dtN = (nic_ts['B'][0] + nic_ts['B'][1]) / 2 - (nic_ts['A'][0] + nic_ts['A'][1]) / 2
dg = B['port_rx_good'] - A['port_rx_good']
db = B['port_rx_bad'] - A['port_rx_bad']
dp = B['port_rx_packets'] - A['port_rx_packets']
dby = B['port_rx_bytes'] - A['port_rx_bytes']
duni = B['port_rx_unicast'] - A['port_rx_unicast']
d15 = B['port_rx_1024_to_15xx'] - A['port_rx_1024_to_15xx']
d64 = B['port_rx_64'] - A['port_rx_64']
dcrc = B['rx_eth_crc_err'] - A['rx_eth_crc_err']
print("=== NIC 硬件口径 (两点) ===")
print(f"dt={dtN:.4f}s  dGood={dg}  dBad={db}  dPkt={dp}  dBytes={dby}  dUni={duni}  d1518={d15}  d64={d64}  dCRC={dcrc}")
print(f"N_SELF: dGood+dBad={dg+db} vs dPkt={dp}  -> {'PASS' if dg+db==dp else 'FAIL'}")
print(f"rate={dby*8/dtN/1e6:.2f} Mbps   avg frame={dby/dp:.6f} B")
sW = {}
for name, blk in zip(['A', 'B'], re.findall(r'SNAP_BEGIN \w+\n(.*?)SNAP_TS', t, re.S)):
    d = {}
    for line in blk.strip().splitlines():
        parts = line.split(None, 1)
        k = parts[0]
        v = parts[1] if len(parts) > 1 else ''
        if k.startswith('W'):
            d[int(k[1:])] = int(v, 16)
        else:
            d[k] = v
    sW[name] = d
WA, WB = sW['A'], sW['B']
dtB = snap_ts['B'] - snap_ts['A']
d20, d20w = dw32(WA[20], WB[20])
d8,  d8w  = dw32(WA[8],  WB[8])
d9r, d9w  = dw32(WA[9],  WB[9])
# 还原 W9 的 k·2^32: 独立口径 = 网卡字节 dby (线上含 FCS, 每帧 +4) ⇒ 期望载荷 ≈ dby - 4*dp
exp9 = dby - 4 * dp
k9 = max(0, int(round((exp9 - d9r) / float(M32))))
d9 = d9r + k9 * M32
print("\n=== 板侧自报 (两点) ===")
print(f"dt={dtB:.4f}s   dW20(MAC tx frames)={d20}{' [回绕!]' if d20w else ''}  "
      f"dW8(app tx frames)={d8}{' [回绕!]' if d8w else ''}  "
      f"dW9(app tx bytes)={d9} [raw={d9r}{' [回绕!]' if d9w else ''} k={k9}]")
print(f"W10(app rx frames) A={WA[10]} B={WB[10]}   W11(app rx bytes) A={WA[11]} B={WB[11]}")
print(f"W13(mismatch)={WA[13]}/{WB[13]}  W34={WA[34]}/{WB[34]}  W38={WA[38]}/{WB[38]}  W45={WA[45]}/{WB[45]}  W3(FCS err)={WA[3]}/{WB[3]}")
print(f"GEN: A {sW['A']['GEN']}  B {sW['B']['GEN']}")
br = d20 * 1518 * 8 / dtB / 1e6
nr = dby * 8 / dtN / 1e6
print("\n=== N_XCHK (手工复算, 脚本结构性跳过) ===")
print(f"板侧 dW20*1518*8/dt = {br:.2f} Mbps ; 网卡 dBytes*8/dt = {nr:.2f} Mbps ; 偏差={(nr-br)/nr*100:.3f}%")
print(f"板侧 app 载荷率 (W9, 已按 k·2^32 还原) = {d9*8/dtB/1e6:.2f} Mbps ; 帧率 = {d20/dtB:.0f} fps")
print(f"板侧 app 帧率 (W8) = {d8/dtB:.0f} fps")
