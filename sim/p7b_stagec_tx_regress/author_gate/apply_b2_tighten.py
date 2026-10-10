#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply_b2_tighten.py -- TL 裁定 ②: 收紧 else (默认) 支的 whi 刷高水位门.
   改前: `if (upd_wr && is_data_r && !retx_active)`  —— `upd_wr` 含 `svc_rewind` 拍,
         而该支 `upd_val` 在 svc 拍取 `rb_snd_una` (非数据支) ⇒ 会用**上一帧的
         `seq_r+plen_r`** 刷 `whi_r[cur_id]`。
   改后: 只在 **S_DONE 的数据推进写**那一支刷 (对齐 OVL 支 R10 的 `upd_wr_data` 语义:
         `upd_wr_data = (rx_state == RX_FIN) && (fin_cnt == 3'd0)` 在 OVL 支就是"该帧的
         推进写那一拍"; else 支的同构项 = S_DONE 数据段 +(tvalid&tready) 落笔拍).
   ⚠️ 最小编辑: 只换条件表达式, 不动落点/不动注释结构。CRLF 保持。"""
import os, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
HERE = os.path.dirname(os.path.abspath(__file__))
RTL = os.path.join(HERE, "..", "..", "..", "rtl", "tcp_tx_frame.v")
NL = "\r\n"
t = open(RTL, "rb").read().decode("utf-8")

old = ("            // ⭐ RETXHI-GHOST: 数据端高水位 (仅活帧; ring 重放帧 is_data_r 亦为 1 ⇒ 必须门掉)" + NL +
       "            if (upd_wr && is_data_r && !retx_active)" + NL +
       "                whi_r[cur_id] <= seq_r + {20'b0, plen_r};" + NL)
new = ("            // ⭐ RETXHI-GHOST: 数据端高水位 —— 只在**数据推进写**那一支 (TL 裁定 ②):" + NL +
       "            //   对齐 OVL 支的 `upd_wr_data` 语义 (那支 = \"该帧推进写那一拍\"; 本支同构项 =" + NL +
       "            //   S_DONE 数据段 +(tvalid&tready) 落笔拍)。⛔ 不能用 `upd_wr`: 它含 `svc_rewind`" + NL +
       "            //   拍, 而那拍 `upd_val` 取 `rb_snd_una` (非数据支) ⇒ 会用**上一帧的 `seq_r+plen_r`**" + NL +
       "            //   刷 `whi_r[cur_id]` (与\"环里真写出过的最高 seq\"语义不符)。" + NL +
       "            //   ring 重放帧亦置 `is_data_r=1` ⇒ 仍靠 `!retx_active` 门掉 (会话期无活帧)。" + NL +
       "            if ((state == S_DONE) && is_data_r && m_axis_tvalid && m_axis_tready &&" + NL +
       "                !retx_active)" + NL +
       "                whi_r[cur_id] <= seq_r + {20'b0, plen_r};" + NL)
n = t.count(old)
print("%s B2 tighten else gate  hits=%d (declared 1)" % ("OK " if n == 1 else "!! ", n))
if n != 1:
    sys.exit(1)
t = t.replace(old, new)
out = t.encode("utf-8")
open(RTL, "wb").write(out)
print("WROTE tcp_tx_frame.v bytes=%d lines=%d CR=%d CRLF=%d" %
      (len(out), out.count(b"\n"), out.count(b"\r"), out.count(b"\r\n")))
