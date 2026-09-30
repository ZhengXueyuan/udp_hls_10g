# -*- coding: utf-8 -*-
"""6b was written as `wf_cnt === 1` -- a duplicate of 6a with zero discriminative
power for "is /S/ really at lane0".  Replace it with a direct check on the frame's
first wire word: its control byte must be exactly 8'h01 (only lane0 is a control
character) and lane0 must be 0xFB."""
import io

P = 'D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/p7b_chain/sim/tb_p7b_chain.v'
s = io.open(P, 'r', encoding='utf-8', newline='').read()

old = ('        chk("6b TX /S/ at lane0", (wf_cnt === 1) === 1\'b1,\n'
       '            "vendor :995 + GATE1 C.4 (decoded)");')
assert s.count(old) == 1, s.count(old)
new = ('        // \u26a0\ufe0f \u7b2c\u4e00\u7248\u5199\u6210 `wf_cnt === 1` \u2014\u2014 \u90a3\u662f 6a \u7684**\u91cd\u590d**, \u5bf9\n'
       '        //    "lane0 \u662f\u4e0d\u662f /S/" \u96f6\u5224\u522b\u529b\u3002\u6539\u6210\u76f4\u63a5\u67e5\u626b\u5230\u7684\u90a3\u4e2a\u5e27\u9996\u5b57:\n'
       '        //    \u63a7\u5236\u4f4d\u5fc5\u987b**\u6070\u597d 8\'h01** (\u53ea\u6709 lane0 \u662f\u63a7\u5236\u5b57\u7b26)\u3002\n'
       '        chk("6b TX /S/ at lane0", (wq_c[wq_sw] === 8\'h01) === 1\'b1,\n'
       '            "vendor :995/:1147 + GATE1 C.4");')
s = s.replace(old, new)
io.open(P, 'w', encoding='utf-8', newline='').write(s)
print('6b fixed')
