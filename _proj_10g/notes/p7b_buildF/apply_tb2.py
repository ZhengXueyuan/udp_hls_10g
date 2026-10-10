#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""P7B 构建 F —— TB 第二轮补丁 (第一轮实测后):

  实测 (arm B: `W69 dut=00000000 tb=00000000`, arm O 同) ⇒ **末尾快照落在 {0,0} 上**
  (跑窗内确有把 \"零帽 conn\" 采样进来的等窗事件: `tcb` 复位把 16 槽全清 0 ⇒
   `win_cap = 0` ⇒ `win_open ≡ 0` ⇒ 那些拍也算等窗、且样本是 {0,0}) ⇒ 末尾比较**空**。
  修法 = **定向见证快照**: 在关窗保持期 (`wc_st == 2`) 抓\"样本归属 = WC_CONN\"的那些事件
  (`prev_rb_id == WC_CONN`) —— 那时样本必是 `{在飞≥1460, 1460}` ⇒ **构造上非零**;
  在事件后 1 拍同时采 DUT 与 TB 的锁存值并比。⇒ 判据非空、两个变异方向都有牙。
  (第一轮的末尾等式保留为**次要**显示, 并注明它可能落到 0 上。)

  另: 为 arm B 里那 4 个\"板帽侧\"事件加一个 ≤8 条 debug 打印 (机理未定位 ⇒ 先取原始读数)。
"""
import io
import os
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
TB = "tb/tb_tcp_tx_ovl.v"
EDITS = []


def E(old, new, n=1):
    EDITS.append((old, new, n))


# ---- ① 定向见证状态 (声明在既有复算块之前) ----
E("    // ⭐ 构建 F: 分裂判据 (TB 侧独立写; 与 DUT 的 `win_cap_bind` 同式不同源 —— 阈值取 TB 的档位值)\n"
  "    wire tb_winstall_cap_ev = tb_winstall_ev && (win_wnd_eff >= TB_WIN_CAP);\n",
  "    // ⭐ 构建 F: 分裂判据 (TB 侧独立写; 与 DUT 的 `win_cap_bind` 同式不同源 —— 阈值取 TB 的档位值)\n"
  "    wire tb_winstall_cap_ev = tb_winstall_ev && (win_wnd_eff >= TB_WIN_CAP);\n"
  "    // ⭐ 构建 F (第二轮实测后补): W69 的**定向见证快照**。\n"
  "    //   为什么第一轮的\"跑完比末尾值\"不够: 跑窗里还有一族 \"零帽 conn\" 的等窗事件\n"
  "    //   (`tcb` 复位把 16 槽全清 0 ⇒ `win_cap = 0` ⇒ `win_open ≡ 0` ⇒ 那些拍也算等窗,\n"
  "    //   且样本 = {0,0}) ⇒ 末尾值经常**恰好是 0** ⇒ \"0 == 0\" 是空判据 (实测 arm B/O 都是)。\n"
  "    //   本快照只抓\"样本归属 = 关窗那个 conn\"的事件 (prev_rb_id == WC_CONN): 那时\n"
  "    //   `win_cap == 1460` 且 `wing_diff >= 1460` ⇒ 样本**构造上非零** ⇒ 判据非空。\n"
  "    reg  [3:0]  w67w_id_d;                    // 上一拍 rb_id = 本拍样本的归属 conn\n"
  "    reg         w69_dir_arm, w69_dir_arm1;\n"
  "    reg  [31:0] w69_dir_dut, w69_dir_tb;\n"
  "    integer     w69_dir_hits;\n"
  "    // ⭐ W67 机理探针 (arm B 实测有 4 拍\"板帽侧\" —— 结构性上需要某样本在飞 >= RING_CAP,\n"
  "    //   机理**未定位** ⇒ 先取原始读数; 只打前 8 条, 不改变任何判据)\n"
  "    integer     w67_dbg_n;\n", 1)

# ---- ② 定向快照逻辑 (放进既有复算 always 块) ----
E("            if (tb_winstall_cap_ev) exp_winstall_cap_cyc <= exp_winstall_cap_cyc + 1;\n"
  "            if (!win_open) wc_seen <= 1'b1;\n"
  "        end\n"
  "    end\n"
  "`endif\n",
  "            if (tb_winstall_cap_ev) exp_winstall_cap_cyc <= exp_winstall_cap_cyc + 1;\n"
  "            if (!win_open) wc_seen <= 1'b1;\n"
  "            // ---- W69 定向见证快照 (见声明处注) ----\n"
  "            w67w_id_d   <= rb_id;\n"
  "            w69_dir_arm1 <= w69_dir_arm;\n"
  "            w69_dir_arm  <= (wc_st == 3'd2) && tb_winstall_ev && (w67w_id_d == WC_CONN);\n"
  "            if (w69_dir_arm) w69_dir_hits <= w69_dir_hits + 1;\n"
  "            if (w69_dir_arm1) begin      // 事件后 1 拍: DUT 与 TB 的锁存都已落地\n"
  "                w69_dir_dut <= w_win_at_winstall;\n"
  "                w69_dir_tb  <= exp_win_at_winstall;\n"
  "            end\n"
  "            // ---- W67 机理探针 (只打前 8 条) ----\n"
  "            if (tb_winstall_cap_ev && (w67_dbg_n < 8)) begin\n"
  "                w67_dbg_n = w67_dbg_n + 1;\n"
  "                $display(\"DBG W67CAP#%0d @%0d prev_id=%0d eff=%04h infl=%04h win_open=%0d\",\n"
  "                         w67_dbg_n, cyc, w67w_id_d, win_wnd_eff, win_inflight, win_open);\n"
  "            end\n"
  "        end\n"
  "    end\n"
  "`endif\n", 1)

# ---- ③ 复位块里带上网关变量 ----
E("        if (!rst_n) begin\n"
  "            exp_winstall_cyc <= 0; exp_winstall_cap_cyc <= 0;\n"
  "            exp_win_at_winstall <= 32'd0; wc_seen <= 1'b0;\n"
  "        end else begin\n",
  "        if (!rst_n) begin\n"
  "            exp_winstall_cyc <= 0; exp_winstall_cap_cyc <= 0;\n"
  "            exp_win_at_winstall <= 32'd0; wc_seen <= 1'b0;\n"
  "            w67w_id_d <= 4'd0; w69_dir_arm <= 1'b0; w69_dir_arm1 <= 1'b0;\n"
  "            w69_dir_dut <= 32'd0; w69_dir_tb <= 32'd0; w69_dir_hits <= 0;\n"
  "            w67_dbg_n <= 0;\n"
  "        end else begin\n", 1)

# ---- ④ 判据: W69 换成定向快照 (末尾等式降为显示) ----
E("            if (w_win_at_winstall !== exp_win_at_winstall) begin tot_red = tot_red + 1;\n"
  "                $display(\"[FAIL] W69 锁存值与复算不符: dut=%08h tb=%08h\",\n"
  "                         w_win_at_winstall, exp_win_at_winstall); end\n",
  "            // W69 判据 (定向见证快照): 关窗保持期内\"样本归属 = 关窗 conn\"的事件后 1 拍,\n"
  "            //   DUT 与 TB 的锁存值必须逐字相等, 且**非零** (构造上必非零: 窗=1460, 在飞>=1460)。\n"
  "            $display(\"W69DIR hits=%0d dut=%08h tb=%08h (末尾值 dut=%08h tb=%08h)\",\n"
  "                     w69_dir_hits, w69_dir_dut, w69_dir_tb,\n"
  "                     w_win_at_winstall, exp_win_at_winstall);\n"
  "            if (w69_dir_hits < 1) begin tot_red = tot_red + 1;\n"
  "                $display(\"[FAIL] W69 空判据: 关窗保持期内没有\\\"样本归属=关窗 conn\\\"的等窗事件\"); end\n"
  "            if (w69_dir_dut === 32'd0) begin tot_red = tot_red + 1;\n"
  "                $display(\"[FAIL] W69 空判据: 定向快照读到 0 (构造上不可能)\"); end\n"
  "            if (w69_dir_dut !== w69_dir_tb) begin tot_red = tot_red + 1;\n"
  "                $display(\"[FAIL] W69 定向快照不符: dut=%08h tb=%08h\", w69_dir_dut, w69_dir_tb); end\n"
  "            // 次要 (跑完的末尾值; ⚠️ 可能落到 {0,0} 上 ⇒ 这一条比上面弱, 只作显示)\n"
  "            if (w_win_at_winstall !== exp_win_at_winstall) begin tot_red = tot_red + 1;\n"
  "                $display(\"[FAIL] W69 末尾锁存值与复算不符: dut=%08h tb=%08h\",\n"
  "                         w_win_at_winstall, exp_win_at_winstall); end\n", 1)


def rd(p):
    b = open(p, "rb").read()
    return b, (b"\r\n" if b.count(b"\r\n") else b"\n")


def main():
    check = "--check" in sys.argv[1:]
    p = os.path.join(REPO, TB.replace("/", os.sep))
    b, nl = rd(p)
    s = b.decode("utf-8")
    fails = 0
    for old, new, n in EDITS:
        old2 = old.replace("\n", nl.decode())
        new2 = new.replace("\n", nl.decode())
        k = s.count(old2)
        print("%s hits=%d/%d  %s" % ("OK  " if k == n else "FAIL", k, n, old.split("\n")[0].strip()[:56]))
        if k != n:
            fails += 1
            continue
        if not check:
            s = s.replace(old2, new2)
    if not check and not fails:
        io.open(p, "w", encoding="utf-8", newline="").write(s)
    print("APPLY_TB2 %s (%d edits, %d fail)" % ("OK" if not fails else "FAIL", len(EDITS), fails))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
