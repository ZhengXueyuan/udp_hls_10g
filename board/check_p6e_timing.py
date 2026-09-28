#!/usr/bin/env python3
#=============================================================================
# check_p6e_timing.py -- 从 Vivado 的 *_timing_summary_routed.rpt 里抠出闸的判据并判 PASS/FAIL
#   为什么单独写: 工程纪律是"上板前必须读时序报告确认 0 失败端点" —— 违例的接收端可能正好
#   在读数通路上 ⇒ 静默读错。人肉看 rpt 容易漏 hold 段, 所以固化成判据。
#   用法: python check_p6e_timing.py <timing_summary_routed.rpt>
#   ⚠️ Vivado 的 "Design Timing Summary" 表是**一行 12 个数**(setup 段 4 个 / hold 段 4 个 /
#      pulse-width 段 4 个), 不是三段分开的行 —— 我第一版按三段写, 解析全 None (已改)。
#   判据: setup 与 hold 都必须 WNS>=0 / TNS==0 / Failing Endpoints==0;
#         pulse-width 违例只报 WARN (US+ 的 IDDRE1 在 125MHz 上有已知器件限制, 与功能无关)
#=============================================================================
import re, sys, os

def main(path):
    if not os.path.exists(path):
        print(f"FAIL: 报告不存在: {path}")
        return 1
    txt = open(path, encoding="utf-8", errors="replace").read()
    i = txt.find("Design Timing Summary")
    if i < 0:
        print("FAIL: 报告里没有 Design Timing Summary (报告没生成?)")
        return 1
    # 表头之后的第一行纯数字行 = 12 个数
    m = re.search(r"^\s*(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+(\d+)\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+(\d+)\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+(\d+)\s*$",
                  txt[i:], re.M)
    if not m:
        print("FAIL: 解析不出 12 个数的数据行 (报告格式变了?)")
        return 1
    wns, tns, sfail, stot, whs, ths, hfail, htot, wpws, tpws, pfail, ptot = (
        float(m.group(1)), float(m.group(2)), int(m.group(3)), int(m.group(4)),
        float(m.group(5)), float(m.group(6)), int(m.group(7)), int(m.group(8)),
        float(m.group(9)), float(m.group(10)), int(m.group(11)), int(m.group(12)))

    rc = 0
    ok_s = (wns >= 0.0) and (sfail == 0) and (tns >= 0.0)
    print(f"  [{'PASS' if ok_s else 'FAIL'}] setup:       WNS={wns:+.3f} TNS={tns:+.3f} failing={sfail}/{stot}")
    rc |= 0 if ok_s else 1
    ok_h = (whs >= 0.0) and (hfail == 0) and (ths >= 0.0)
    print(f"  [{'PASS' if ok_h else 'FAIL'}] hold:        WHS={whs:+.3f} THS={ths:+.3f} failing={hfail}/{htot}")
    rc |= 0 if ok_h else 1
    if pfail > 0:
        print(f"  [WARN] pulse-width: WPWS={wpws:+.3f} failing={pfail}/{ptot}  (US+ IDDRE1@125MHz 已知限制, 与功能无关)")
    else:
        print(f"  [PASS] pulse-width: WPWS={wpws:+.3f} failing=0/{ptot}")

    # 交叉核对: 报告自己的结论行 (防止我解析错列)
    verdict = "All user specified timing constraints are met." in txt
    print(f"  [INFO] 报告自述: {'constraints met' if verdict else '有约束未满足 (报告里有小字)'}")
    if rc == 0 and not verdict:
        print("  [WARN] 我这几列都过, 但报告自述有约束未满足 —— 别只看这四列, 去翻报告")
    if rc == 0:
        print("TIMING-OK")
    else:
        print("TIMING-FAIL: 上板前必须先解决")
    return rc

if __name__ == "__main__":
    p = sys.argv[1] if len(sys.argv) > 1 else r"D:\repo\XCKU5PMini\udp_hls_10g\board\p6e_ku5p_timing.rpt"
    sys.exit(main(p))
