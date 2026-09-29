#!/usr/bin/env python3
#=============================================================================
# srv_p6b_final_verify0.py — 附加验证: **图案流确实从 offset 0 开始**
#
#   为什么要有它: verify_pcap_pattern.py 的判据是"每帧都能由**某个**合法状态生成"
#   (与流起点无关), 所以它证不了"板子是从头的 SEED 开始发的"。本脚本补这一条:
#   逐帧反解出的 64 位状态里, **有一帧必须恰好等于 SEED** (0x9E3779B97F4A7C15),
#   且该帧载荷 == 从 SEED 生成的 1472 字节。抓包是在 teach **之前**武装的 ⇒
#   若 SEED 出现在第 0 帧, 就是"流从 offset 0、且第一帧就被抓到了"的直接证据
#   (对应任务书 D 段的"板子从未被教过 peer、流从 offset 0 开始")。
#
#   用法: python3 srv_p6b_final_verify0.py <pcap> [--paylen 1472] [--dport 8081]
#   退出码: 0 = 找到 SEED 帧且其载荷逐字节正确 / 1 = 没找到或不符 / 2 = 环境问题
#   ⚠️ 本脚本**只 import 既有 verifier** (不修改它)。
#=============================================================================
import sys, importlib.util

SEED = 0x9E3779B97F4A7C15
VPP_PATH = "/home/a/xdma_test/verify_pcap_pattern.py"

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


def load_vpp(path):
    spec = importlib.util.spec_from_file_location("vpp", path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)          # __name__ != "__main__" ⇒ 不会跑它的 main()
    return m


def main():
    if len(sys.argv) < 2:
        print("用法: %s <pcap> [--paylen N] [--dport N]" % sys.argv[0])
        return 2
    path = sys.argv[1]
    paylen, dport = 1472, 8081
    if "--paylen" in sys.argv:
        paylen = int(sys.argv[sys.argv.index("--paylen") + 1])
    if "--dport" in sys.argv:
        dport = int(sys.argv[sys.argv.index("--dport") + 1])
    try:
        vpp = load_vpp(VPP_PATH)
    except Exception as e:
        print("载入 %s 失败: %s" % (VPP_PATH, e))
        return 2

    pkts = vpp.parse_pcap(path)
    pays = [p for p in (vpp.payload_of(f, paylen, dport) for f in pkts) if p and len(p) == paylen]
    print("pcap=%s: %d 包, 其中 %dB/UDP:%d 载荷 %d 帧" % (path, len(pkts), paylen, dport, len(pays)))
    if not pays:
        print("[FAIL] 没有可验证的载荷")
        return 1

    sol = vpp.build_solver()
    rows, rhs_mask, where, nbits, rank = sol
    if rank != 64:
        print("[FAIL] 求解器秩亏 (%d) ⇒ 结论不可用" % rank)
        return 2
    exp0, _ = vpp.gen_bytes(SEED, paylen)

    idx_seed, bad = [], []
    for i, p in enumerate(pays):
        s = vpp.solve_for(int.from_bytes(p[:vpp.NKNOWN], "big"), sol)
        if s is None:
            bad.append((i, "不是任何合法状态"))
            continue
        if s == SEED:
            idx_seed.append(i)
            if p != exp0:
                bad.append((i, "状态是 SEED 但载荷与从 SEED 生成的 1472B 不符"))
    print("① 逐帧反解: %d 帧可解, %d 帧不可解 %s" % (len(pays) - len(bad), len(bad), bad[:3] if bad else ""))
    if idx_seed:
        print("② ⭐ 状态 == SEED(0x%016X) 的帧: 第 %d 帧 (共 %d 处) ⇒ 图案流**从 offset 0 开始**且该帧被逐字节复算通过"
              % (SEED, idx_seed[0], len(idx_seed)))
        if idx_seed[0] == 0:
            print("   且它**就是抓到的第 0 帧** ⇒ 抓包在流起点之前武装 (D3 的抓包口径成立)")
        else:
            print("   (不是第 0 帧 ⇒ 前 %d 帧是 teach 之前的其它 UDP:8081 帧, 或抓包侧丢了开头几帧)" % idx_seed[0])
    else:
        print("② [FAIL] 没找到状态 == SEED 的帧 ⇒ 流不是从 offset 0 开始的 (板子在此之前已被教过/已发过)")
    if bad:
        print("[FAIL] 有不可归因项 ⇒ 不判 PASS")
        return 1
    return 0 if idx_seed else 1


if __name__ == "__main__":
    sys.exit(main())
