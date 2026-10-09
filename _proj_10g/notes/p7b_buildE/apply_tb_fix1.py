#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""构建 E 首轮门跑完后的两处**自查修复** (跑完 TX_OVL 门才暴露):
   ① tb_tb_tcp_tx_ovl.v: 窗口关闭 FSM 的 `wc_st` 是 2 位却写了 `2'd4` ⇒ 终态截断回 0
      (行为无害 —— 触发条件 `cyc == WC_AT` 不会再成立 —— 但**读数有误导性**:
       arm B 打印 `wc_st=0`, 看着像"插曲没跑") ⇒ 改成 3 位。
   ② 我加进两个 .bat 的 echo 文本含**非 ASCII** —— 违反本工程 ".bat 只 ASCII" 铁律
      (实测 stdout 里中文被打成 "构建 E 新判据的�?") ⇒ 全部改成 ASCII。
"""
import io
import os
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))


def rd(p):
    b = open(p, "rb").read()
    return b, (b"\r\n" if b.count(b"\r\n") else b"\n")


EDITS = []


def E(rel, old, new, n=1):
    EDITS.append((rel, old, new, n))


# ---- ① 状态宽度 ----
E("tb/tb_tcp_tx_ovl.v",
  "    reg  [1:0]  wc_st;                     // 0=等触发 1=写关窗中 2=保持 3=写回中 4=完\n",
  "    reg  [2:0]  wc_st;                     // 0=等触发 1=写关窗中 2=保持 3=写回中 4=完\n"
  "                                           //   ⚠️ 必须 3 位: 终态 4 大于 2 位满量程 ⇒\n"
  "                                           //   2 位时会被截断回 0 (读数看着像\"插曲没跑\")\n", 1)
for a, b in (("2'd0: if ((setup_c >= NCONN) && (cyc == WC_AT)) begin", "3'd0: if ((setup_c >= NCONN) && (cyc == WC_AT)) begin"),
             ("                      wc_st <= 2'd1;\n", "                      wc_st <= 3'd1;\n"),
             ("            2'd1: if (tcb_wr && (tcb_sel == 3'd4) && (tcb_id == WC_CONN)) begin\n"
              "                      scfg_upd_wr <= 1'b0; wc_cyc <= 32'd0; wc_st <= 2'd2;",
              "            3'd1: if (tcb_wr && (tcb_sel == 3'd4) && (tcb_id == WC_CONN)) begin\n"
              "                      scfg_upd_wr <= 1'b0; wc_cyc <= 32'd0; wc_st <= 3'd2;"),
             ("            2'd2: begin\n"
              "                      wc_cyc <= wc_cyc + 32'd1;\n",
              "            3'd2: begin\n"
              "                      wc_cyc <= wc_cyc + 32'd1;\n"),
             ("                          wc_st <= 2'd3;\n", "                          wc_st <= 3'd3;\n"),
             ("            2'd3: if (tcb_wr && (tcb_sel == 3'd4) && (tcb_id == WC_CONN)) begin\n"
              "                      scfg_upd_wr <= 1'b0; wc_st <= 2'd4;",
              "            3'd3: if (tcb_wr && (tcb_sel == 3'd4) && (tcb_id == WC_CONN)) begin\n"
              "                      scfg_upd_wr <= 1'b0; wc_st <= 3'd4;")):
    E("tb/tb_tcp_tx_ovl.v", a, b, 1)

# ---- ② .bat 只 ASCII (两处 echo) ----
E("sim/p7b_stagec_tx_regress/author_gate/run_tx_ovl_gate.bat",
  "echo   L M-W66-1 dead counter RC=%RCL% (expect nonzero; 构建 E 新判据的牙)\r\n"
  "echo   M M-W66-2 no !wnd_open RC=%RCM% (expect nonzero; 语义错方向)\r\n",
  "echo   L M-W66-1 dead counter RC=%RCL% (expect nonzero; new W66 judge, build E)\r\n"
  "echo   M M-W66-2 no !wnd_open RC=%RCM% (expect nonzero; semantic-wrong direction)\r\n", 1)
E("sim/p7b_stagec_tx_regress/author_gate/run_tx_ovl_gate.bat",
  "REM   L = M-W66-1  stat_winstall never counts (构建 E)\r\n"
  "REM   M = M-W66-2  stat_winstall predicate drops !wnd_open (构建 E)\r\n",
  "REM   L = M-W66-1  stat_winstall never counts (build E)\r\n"
  "REM   M = M-W66-2  stat_winstall predicate drops !wnd_open (build E)\r\n", 1)
E("sim/p7b_longsend/run_cont_gate.bat",
  "echo   M5 no-uppend (A3)   RC=%RCM5%  (expect nonzero; 构建 E)\r\n",
  "echo   M5 no-uppend (A3)   RC=%RCM5%  (expect nonzero; build E)\r\n", 1)
E("sim/p7b_stagec_tx_regress/author_gate/run_tx_ovl_gate.bat",
  "REM Contract: A/B RC==0; C..M RC!=0 (J = KNOWN GAP, 不计).\r\n",
  "REM Contract: A/B RC==0; C..M RC!=0 (J = KNOWN GAP, not counted).\r\n", 1)


def main():
    check = "--check" in sys.argv[1:]
    fails = []
    for rel, old, new, n in EDITS:
        p = os.path.join(REPO, rel.replace("/", os.sep))
        b, nl = rd(p)
        if nl != b"\n":
            old2 = old.replace("\r\n", "\n").replace("\n", nl.decode())
            new2 = new.replace("\r\n", "\n").replace("\n", nl.decode())
        else:
            old2 = old.replace("\r\n", "\n")
            new2 = new.replace("\r\n", "\n")
        s = b.decode("utf-8")
        k = s.count(old2)
        tag = "OK  " if k == n else "FAIL"
        print("%s %-52s hits=%d/%d  %s" % (tag, rel, k, n, old.split("\n")[0][:44]))
        if k != n:
            fails.append((rel, k, n, old.split("\n")[0][:80]))
            continue
        if not check:
            io.open(p, "w", encoding="utf-8", newline="").write(s.replace(old2, new2))
    print("APPLY_FIX1 %s (%d edits, %d fail)" % ("OK" if not fails else "FAIL", len(EDITS), len(fails)))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
