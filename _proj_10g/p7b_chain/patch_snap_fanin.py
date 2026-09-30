# -*- coding: utf-8 -*-
"""Feed axi_regs the assembled 51-word bus / combined valid / combined busy."""
import io

P = 'D:/repo/XCKU5PMini/udp_hls_10g/board/wrapper_p4.v'
s = io.open(P, 'r', encoding='utf-8', newline='').read()

# 1) declaration: split snap_busy into seq-busy + combined
old = '    wire         snap_req, snap_busy, snap_valid;\n'
new = ('    wire         snap_req, snap_valid;\n'
       '    wire         snap_seq_busy;        // snap_seq \u81ea\u5df1\u7684 busy\n'
       '    wire         snap_busy;            // = \u4e94\u675f\u7684 busy \u4e4b\u548c (P7b \u6269\u5c55)\n')
assert s.count(old) == 1
s = s.replace(old, new)

# 2) snap_seq instantiation: busy -> snap_seq_busy
old = '.busy       (snap_busy),'
assert s.count(old) == 1, s.count(old)
s = s.replace(old, '.busy       (snap_seq_busy),')

# 3) axi_regs fan-in
old = ('        .snap_req       (snap_req),\n'
       '        .snap_busy      (snap_busy),\n'
       '        .snap_valid     (snap_valid),\n'
       '        .snap_din       (snap_dout),\n')
assert s.count(old) == 1
new = ('        .snap_req       (snap_req),\n'
       '        // \u26a0\ufe0f P7b: busy/valid/din \u4e09\u6839\u90fd\u6362\u6210**\u4e94\u675f**\u7684\u5408\u4f53\u7248\n'
       '        //   (snap_seq \u7684 FE+DP \u4e24\u675f + \u672c\u8f6e\u65b0\u52a0\u7684 p7bfe/p7bdp/tx \u4e09\u675f):\n'
       '        //   \u00b7 busy  = \u5408\u4f53 \u21d2 \u4e3b\u673a\u4e0d\u4f1a\u5728\u4efb\u4e00\u675f\u8fd8\u5728\u98de\u7684\u65f6\u5019\u91cd\u89e6\u53d1\n'
       '        //   \u00b7 valid = `snap_valid_all` \u21d2 \u4e94\u675f\u672c\u4ee3\u5168\u5230\u9f50\u624d\u91c7 (\u5426\u5219\u8bfb\u5230 "**\u534a\u4ee3**\u5feb\u7167")\n'
       '        //   \u00b7 din   = `snap_dout_all` (51 \u5b57, axi \u57df\u88c5\u914d, \u89c1\u91c7\u96c6\u6bb5)\n'
       '        .snap_busy      (snap_busy),\n'
       '        .snap_valid     (snap_valid_all),\n'
       '        .snap_din       (snap_dout_all),\n')
s = s.replace(old, new)

# 4) define the combined busy next to snap_valid_all
old = '    wire snap_valid_all = snap_valid & p7bfe_seen & p7bdp_seen & tx_seen;\n'
assert s.count(old) == 1
s = s.replace(old, old + '    // \u5408\u4f53 busy: \u4efb\u4e00\u675f\u5728\u98de\u5c31\u662f busy (\u4e3b\u673a\u7684 "trigger\u2192poll done"\u534f\u8bae\u9760\u5b83)\n'
              '    wire snap_busy = snap_seq_busy | p7bfe_busy | p7bdp_busy | txsnap_busy;\n')

io.open(P, 'w', encoding='utf-8', newline='').write(s)
print('snap fan-in patched')
