#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fix_eghost_scope.py -- 给 e_ghost 判据块补上 `ifdef TCP_TX_OVL (实施轮实测: 默认支错位).
   ⚠️ 上一次尝试因 assert 提前退出而**没落盘**, 却已落了配对 `endif` => 预处理器不平衡
      (xvlog VRFC 10-8723). 本脚本补上开头的 `ifdef 并把四行依据写进注释."""
import os, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
HERE = os.path.dirname(os.path.abspath(__file__))
TB = os.path.join(HERE, "..", "..", "..", "tb", "tb_tcp_tx_ovl.v")
NL = "\r\n"
t = open(TB, "rb").read().decode("utf-8")

old = "                    // ⭐ RETXHI-GHOST §5.4-②: e_ghost = 定向仪器 (半区判据, **帧尾直读**)." + NL
new = ("`ifdef TCP_TX_OVL" + NL +
       "                    // ⚠️ 本判据**只在 OVL 支成立** (实施轮实测): 默认 (串行) 支的推进写落在" + NL +
       "                    //   **S_DONE = 该帧自己的尾拍** ⇒ 帧尾直读必然读到\"上一帧的高水位\"" + NL +
       "                    //   ⇒ 每条活帧必误报 (实测 arm A: e_ghost=346, 全部呈 tail=本帧尾 / whi=上帧尾)." + NL +
       "                    //   OVL 支的推进写在 RX_FIN (比上线尾拍早 ~180+ 拍) ⇒ 帧尾读安全 (下条注释)." + NL +
       "                    // ⭐ RETXHI-GHOST §5.4-②: e_ghost = 定向仪器 (半区判据, **帧尾直读**)." + NL)
n = t.count(old)
print("%s ifdef-open  hits=%d (declared 1)" % ("OK " if n == 1 else "!! ", n))
if n != 1:
    sys.exit(1)
t = t.replace(old, new)
out = t.encode("utf-8")
open(TB, "wb").write(out)
print("WROTE tb_tcp_tx_ovl.v bytes=%d lines=%d CR=%d CRLF=%d" %
      (len(out), out.count(b"\n"), out.count(b"\r"), out.count(b"\r\n")))
