#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply_ghost_patch2.py -- P7B-RETXHI-GHOST 实施轮 第二批 TB 补丁 (增量, CRLF 保持).
   T7  = e_ghost/e_ringhi 进 initial 初始化块 (T1 只声明, 没清零 => REDS 打印 ghost=x)
   T8  = GHOST_DBG 调试钩子 (仅 `ifdef GHOST_DBG` 编译; 用于定位 e_replay_jump 单次红)
   用法: python apply_ghost_patch2.py tb [--dry]
"""
import os, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
TB  = os.path.join(ROOT, "tb", "tb_tcp_tx_ovl.v")
NL = "\r\n"
E = []

E.append(("T7 e_ghost/e_ringhi init", (
"        e_replay_span=0; e_replay_jump=0; e_c2_resv=0; cov_c2_resv=0;" + NL +
"        e_ag_block=0; e_ag_resume=0;"),
(
"        e_replay_span=0; e_replay_jump=0; e_c2_resv=0; cov_c2_resv=0;" + NL +
"        e_ghost=0; e_ringhi=0;   // ⭐ RETXHI-GHOST (T1 只声明; 这里清零)" + NL +
"        e_ag_block=0; e_ag_resume=0;"), 1))

_gold = (
"                $display(\"[FAIL] RETXFIX jump: session end snd_nxt=%h < retx_hi=%h conn=%0d @%0d\"," + NL +
"                         u_tcb.snd_nxt_r[j9_conn], rep_hi_w, j9_conn, cyc);" + NL +
"            end")
_gnew = (
"                $display(\"[FAIL] RETXFIX jump: session end snd_nxt=%h < retx_hi=%h conn=%0d @%0d\"," + NL +
"                         u_tcb.snd_nxt_r[j9_conn], rep_hi_w, j9_conn, cyc);" + NL +
"            end" + NL +
"`ifdef GHOST_DBG" + NL +
"            // ⭐ RETXHI-GHOST 临时调试钩子 (仅在 -d GHOST_DBG 时编译):" + NL +
"            //   会话结束拍打印 本会话内的 ring_restore / 排空拍计数 + 相关状态." + NL +
"            $display(\"GDBG sessend @%0d c=%0d snd=%h ring_hi=%h retx_hi=%h ovf=%b estab=%b re=%b rest=%0d drain=%0d\"," + NL +
"                     cyc, j9_conn, u_tcb.snd_nxt_r[j9_conn], u_dut.ring_hi, rep_hi_w," + NL +
"                     u_dut.ring_ovf, u_dut.scan_estab, u_dut.retx_active," + NL +
"                     g_dbg_rest, g_dbg_drain);" + NL +
"            g_dbg_rest = 0; g_dbg_drain = 0;" + NL +
"`endif")
E.append(("T8 GHOST_DBG hook (in jump judge)", _gold, _gnew, 1))

_gc_old = (
"`ifdef TCP_TX_OVL" + NL +
"    wire        d_svc_tap = u_dut.svc_x;" + NL +
"`else" + NL +
"    wire        d_svc_tap = u_dut.svc;    // 默认支: 同一个会话载载拍的触发信号" + NL +
"`endif" + NL +
"    reg  rh_pend, rh_exempt;")
_gc_new = (
"`ifdef TCP_TX_OVL" + NL +
"    wire        d_svc_tap = u_dut.svc_x;" + NL +
"`else" + NL +
"    wire        d_svc_tap = u_dut.svc;    // 默认支: 同一个会话载载拍的触发信号" + NL +
"`endif" + NL +
"`ifdef GHOST_DBG" + NL +
"    integer g_dbg_rest, g_dbg_drain;" + NL +
"    always @(posedge clk or negedge rst_n) begin" + NL +
"        if (!rst_n) begin g_dbg_rest <= 0; g_dbg_drain <= 0; end" + NL +
"        else begin" + NL +
"            if (u_dut.ring_restore) g_dbg_rest <= g_dbg_rest + 1;" + NL +
"            if (u_dut.ring_eval && !u_dut.ring_start) g_dbg_drain <= g_dbg_drain + 1;" + NL +
"        end" + NL +
"    end" + NL +
"`endif" + NL +
"    reg  rh_pend, rh_exempt;")
E.append(("T9 GHOST_DBG counters", _gc_old, _gc_new, 1))


def apply(path, edits, dry=False):
    b = open(path, "rb").read(); t = b.decode("utf-8"); bad = 0
    for (name, old, new, hits) in edits:
        n = t.count(old)
        if n != hits: bad += 1
        print("%s%-46s hits=%d (declared %d)" % ("OK " if n == hits else "!! ", name, n, hits))
        if n != hits: print("      anchor head: %r" % old[:140])
        if not dry: t = t.replace(old, new)
    if bad:
        print("*** 命中数不符 => 不落盘 ***"); return 1
    if dry: print("dry-run"); return 0
    out = t.encode("utf-8"); open(path, "wb").write(out)
    print("WROTE %s bytes=%d lines=%d CR=%d CRLF=%d" % (os.path.basename(path), len(out),
          out.count(b"\n"), out.count(b"\r"), out.count(b"\r\n")))
    return 0

if __name__ == "__main__":
    sys.exit(apply(TB, E, "--dry" in sys.argv))
