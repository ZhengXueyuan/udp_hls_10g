#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""P7b final: register the newly found TX pad/FCS-scope defect as a criterion and
annotate the historical F-2 probe.

X5 readings (logs/f2x9_pristine.txt, our own RX as the reference after the X5c
calibration passed):
  X5b   DUT  60B content, no pad            -> delivered, crc_err +0
  X5c-a DUT  68B content, no pad            -> delivered, crc_err +0
  X5c-b TB   same 68B content               -> delivered, crc_err +0  (calibration OK)
  X5a   DUT  20B content padded to 60       -> delivered, crc_err +1  <== defect
  X5d-1 TB   18 data + 42 pad, FCS over 60  -> crc_err +0  (standard scope accepted)
  X5d-2 TB   same 60 wire bytes, FCS over 18-> crc_err +1  (DUT scope rejected)
=> the only variable is the FCS scope: our RX wants the PAD inside the FCS, and
   mac_tx_10g does not put it there (mac_tx_64 does: crc_en = S_DATA || S_PAD).

So X5a becomes a real criterion (it FAILS while the defect is unfixed; rtl/ is
off-limits in this round, so it stays red on purpose) and a [DEFECT-REG] banner
makes it unmissable.  Group 8's four [OPEN] lines get a pointer to the
attribution + the contract-correct replacement (F2X X4).
"""
import io
import sys

P = 'D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/p7b_chain/sim/tb_p7b_chain.v'
s = io.open(P, 'r', encoding='utf-8', newline='').read()

if 'F2X10-PATCH' in s:
    print('already patched')
    sys.exit(0)


def sub(old, new, tag):
    global s
    n = s.count(old)
    if n != 1:
        raise SystemExit('anchor %s occurs %d times' % (tag, n))
    s = s.replace(old, new)
    print('anchor %s ok' % tag)


# 1. X5a diagnostic -> registered-defect criterion + banner
sub("""            $display("  [F2X X5a] DIAG only (not a criterion): replayed frame delivered=%b crc_err_delta=%0d",
                     (u_dut.rx_stat_frames > rf0), (u_dut.rx_stat_crc_err - rc0));""",
    """            // F2X10-PATCH: 这条是**缺陷登记判据** (不是 F-2 判据):
            //   DUT 短帧 (20B 内容补 pad 到 60) 的 FCS 只覆盖数据字节, 而我们自己的 RX
            //   (以及任何标准对端) 要求 FCS 覆盖 **pad 在内**的全部 60 字节。
            //   校准: X5c-b/X5d-1 (TB 自算 FCS) 都通过 => 回放通路可信;
            //         X5d-2 只改 FCS 覆盖面 => 立刻被判 crc_err (判别力证明)。
            //   ⚠️ 修法在 rtl/mac_tx_10g.v (crc_en 需含 pad), 本轮**按指示不动 rtl/**,
            //      所以这条在修好之前**应该保持红**。
            $display("  [DEFECT-REG #1] mac_tx_10g padded-frame FCS scope: DUT TX frame of a 20B-content frame (padded to 60) is rejected by OUR OWN RX (crc_err +1); TB-built frame with the pad inside the FCS is accepted (X5d-1) and the same bytes with a data-only FCS is rejected (X5d-2). 1G mac_tx_64 feeds the pad into the CRC (crc_en = S_DATA || S_PAD); mac_tx_10g does not (crc_en = S_DATA only, rtl/mac_tx_10g.v:207). UNFIXED in this round (rtl/ off-limits).");
            chk("X5a DUT padded short frame passes our own RX (REGISTERED DEFECT #1)",
                (u_dut.rx_stat_crc_err === rc0) && (u_dut.rx_stat_frames > rf0),
                "derived: TX and RX must agree on the FCS of a padded frame; see [DEFECT-REG #1]");""",
    'x5a_criterion')

# 2. group-8 [OPEN] lines: point at the attribution
sub("""            $display("  [OPEN] 8a F-2 wire frames == 2 = %b   (UNRESOLVED: see the round report)", (wf_cnt === 2) === 1'b1);""",
    """            // F2X10-PATCH: 归因完成 (2026-09-30) -- see notes/P7B_F2_CHAIN_ATTRIB.md
            //   (1) 本组解码窗口 [0, wq_wr) 是**陈旧的**: 开头的 `wq_wr = 0` 被捕获 always
            //       块同拍 NBA 覆盖 (实测 wq_wr: 1202 -> 1205, 而 group6 那次生效) =>
            //       窗口里含**上一组 (group 6) 的帧** (它在 wf_start[0]=7)。
            //   (2) 本组期望 (runt + 完整 B) 与自己的激励矛盾: A 没有 TLAST => 按 F-2 合同
            //       (rtl/mac_tx_10g.v:24-31 情形3) 冲刷必然吞掉 B 整帧。
            //   => 合同正确的判据见 F2X X4 (同一激励) 与 X3 (A 带 TLAST 的场景)。
            $display("  [OPEN] 8a F-2 wire frames == 2 = %b   (SUPERSEDED by F2X X4; see notes/P7B_F2_CHAIN_ATTRIB.md)", (wf_cnt === 2) === 1'b1);""",
    'open8a')

for k in ('8b', '8c', '8d'):
    pass
s = s.replace('(UNRESOLVED: see the round report)", (ok_prefix === 1\'b1) === 1\'b1);',
              '(SUPERSEDED by F2X X4; see notes/P7B_F2_CHAIN_ATTRIB.md)", (ok_prefix === 1\'b1) === 1\'b1);')
s = s.replace('(UNRESOLVED: see the round report)", (ok_b === 1\'b1) === 1\'b1);',
              '(SUPERSEDED by F2X X4; see notes/P7B_F2_CHAIN_ATTRIB.md)", (ok_b === 1\'b1) === 1\'b1);')
s = s.replace('(UNRESOLVED: see the round report)", (nb === 64) === 1\'b1);',
              '(SUPERSEDED by F2X X4; see notes/P7B_F2_CHAIN_ATTRIB.md)", (nb === 64) === 1\'b1);')

io.open(P, 'w', encoding='utf-8', newline='').write(s)
print('patched OK')
