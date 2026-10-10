#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""P7B 构建 F —— 主验证器 TB (`tb/tb_tcp_tx_ovl.v`) 的改动 (CRLF 文件).

   ① 新增 `TB_WIN_CAP` 局部参数 (由 `-d W67_CAP_SMALL` 选档) + **两个实例同值传参**
      (`u_tcb.WIN_CAP` / `u_dut.RING_CAP`) —— 默认档 = `16'hBFFE` = 今天的取值 ⇒
      既有 A..M 十一臂**逐位不变** (参数默认同值, 见下面 TB 注释)。
   ② W67/W69 的 **TB 侧独立复算** + 判据 (双边界等式 + `ΔW67 <= ΔW66` 结构性牙 +
      小帽臂的 `>= 64` 见证)。
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


# ---- ① TB_WIN_CAP 局部参数 (放在既有几何参数之后; xvlog 先声明后用) ----
E("    localparam [31:0]  CBASE   = 32'h0010_0000;\n",
  "    localparam [31:0]  CBASE   = 32'h0010_0000;\n"
  "    // ⭐ 构建 F: **窗帽档位** (TB 与 DUT 必须同值 —— 生产里两者同源于 wrapper 的 `WIN_CAP_5`)。\n"
  "    //   `-d W67_CAP_SMALL`: 把帽压到 **8192 B**。为什么需要这一臂 (结构性, 不是调参):\n"
  "    //     W67 的判据 = `win_wnd_eff >= RING_CAP`, 而 `!wnd_open` 要求在飞 >= min(snd_wnd, 帽)。\n"
  "    //     默认帽 0xBFFE=49150 下本 TB 的**在飞到不了** (ack_lag=8192) ⇒ 板帽侧**恒 0**\n"
  "    //     = 空判据 (判据会退化成\"两个 0 相等\"); 压到 8192 后每个 ACK 周期都自然越过\n"
  "    //     ⇒ 板帽侧有靶; 而关窗插曲 (snd_wnd=1460) 仍是**对端侧** ⇒ 同一臂里**两侧都激励**。\n"
  "    //   ⚠️ 默认档 (无该宏) = `0xBFFE` = 今天的取值 ⇒ 既有 A..M 各臂**逐位不变**。\n"
  "`ifdef W67_CAP_SMALL\n"
  "    localparam [15:0] TB_WIN_CAP = 16'd8192;\n"
  "`else\n"
  "    localparam [15:0] TB_WIN_CAP = 16'hBFFE;\n"
  "`endif\n", 1)

# ---- ② 两个实例同值传参 ----
E("    tcb #(.N(16), .WIN_CAP(16'hBFFE)) u_tcb (\n",
  "    tcb #(.N(16), .WIN_CAP(TB_WIN_CAP)) u_tcb (   // 构建 F: 与 DUT 的 RING_CAP 同值 (见 TB_WIN_CAP 注)\n", 1)
E("    tcp_tx_frame u_dut (\n",
  "    tcp_tx_frame #(.RING_CAP(TB_WIN_CAP)) u_dut (   // 构建 F: 与 u_tcb.WIN_CAP 同值\n", 1)

# ---- ③ 新字号线 (- W67/W69 的 DUT 输出) ----
E("    // ⭐ 构建 E: W66 = tcp_tx_frame.stat_winstall (帧器侧窗口门停顿拍数)\n"
  "    wire [31:0] w_stat_winstall;\n",
  "    // ⭐ 构建 E: W66 = tcp_tx_frame.stat_winstall (帧器侧窗口门停顿拍数)\n"
  "    wire [31:0] w_stat_winstall;\n"
  "    // ⭐ 构建 F: W67 = 板帽侧等窗拍数 / W69 = 等窗拍操作点锁存 (源同模块, 纯观测)\n"
  "    wire [31:0] w_stat_winstall_cap;\n"
  "    wire [31:0] w_win_at_winstall;\n", 1)

E("    integer     exp_winstall_cyc;          // TB 复算的窗口门停顿拍数\n"
  "    reg         wc_seen;                   // 见证: 窗口确实被观察到关过 (!wnd_open)\n",
  "    integer     exp_winstall_cyc;          // TB 复算的窗口门停顿拍数\n"
  "    // ⭐ 构建 F 的 TB 侧复算 (与 W66 同款: **逐项自写**, 不引用 DUT 的判据线)\n"
  "    integer     exp_winstall_cap_cyc;      // TB 复算: 其中\"板帽侧\"那一份 (W67 的期望值)\n"
  "    reg  [31:0] exp_win_at_winstall;       // TB 复算: 最近一次等窗拍的 {在飞, 有效窗} (W69)\n"
  "    reg         wc_seen;                   // 见证: 窗口确实被观察到关过 (!wnd_open)\n", 1)

# ---- ④ DUT 例化: 两个新端口的接线 ----
E("        .stat_winstall(w_stat_winstall),\n",
  "        .stat_winstall(w_stat_winstall),\n"
  "        .stat_winstall_cap(w_stat_winstall_cap),   // 构建 F: W67\n"
  "        .o_win_at_winstall(w_win_at_winstall),     // 构建 F: W69\n", 1)

# ---- ⑤ TB 侧逐拍复算 (整块重写: 提出谓词线 tb_winstall_ev, 供 W66/W67/W69 三个判据共用) ----
E("`ifdef TCP_TX_OVL\n"
  "    always @(posedge clk or negedge rst_n) begin\n"
  "        if (!rst_n) begin exp_winstall_cyc <= 0; wc_seen <= 1'b0; end\n"
  "        else begin\n"
  "            if ((u_dut.rx_state == 2'd0) && u_dut.recv_first && s_tvalid &&\n"
  "                !u_dut.ack_pend_r && !u_dut.svc && !u_dut.ring_eval && !u_dut.scan_now &&\n"
  "                !u_dut.rx_flush && !u_dut.fifo_full && !u_dut.bank_rdy[u_dut.rx_bank] &&\n"
  "                !u_dut.tx_blk_sid && !win_open)\n"
  "                exp_winstall_cyc <= exp_winstall_cyc + 1;\n"
  "            if (!win_open) wc_seen <= 1'b1;\n"
  "        end\n"
  "    end\n"
  "`endif\n",
  "`ifdef TCP_TX_OVL\n"
  "    // ⭐ 构建 F: 谓词线提出成 `wire` —— W66/W67/W69 三个判据共用同一份**TB 自写**表达式\n"
  "    //   (与改动前的内联写法**逐字同款**; 提出只是去重, 值不变)。\n"
  "    wire tb_winstall_ev = (u_dut.rx_state == 2'd0) && u_dut.recv_first && s_tvalid &&\n"
  "                          !u_dut.ack_pend_r && !u_dut.svc && !u_dut.ring_eval && !u_dut.scan_now &&\n"
  "                          !u_dut.rx_flush && !u_dut.fifo_full && !u_dut.bank_rdy[u_dut.rx_bank] &&\n"
  "                          !u_dut.tx_blk_sid && !win_open;\n"
  "    // ⭐ 构建 F: 分裂判据 (TB 侧独立写; 与 DUT 的 `win_cap_bind` 同式不同源 —— 阈值取 TB 的档位值)\n"
  "    wire tb_winstall_cap_ev = tb_winstall_ev && (win_wnd_eff >= TB_WIN_CAP);\n"
  "    always @(posedge clk or negedge rst_n) begin\n"
  "        if (!rst_n) begin\n"
  "            exp_winstall_cyc <= 0; exp_winstall_cap_cyc <= 0;\n"
  "            exp_win_at_winstall <= 32'd0; wc_seen <= 1'b0;\n"
  "        end else begin\n"
  "            if (tb_winstall_ev) begin\n"
  "                exp_winstall_cyc <= exp_winstall_cyc + 1;\n"
  "                exp_win_at_winstall <= {win_inflight, win_wnd_eff};   // W69 的期望锁存值\n"
  "            end\n"
  "            if (tb_winstall_cap_ev) exp_winstall_cap_cyc <= exp_winstall_cap_cyc + 1;\n"
  "            if (!win_open) wc_seen <= 1'b1;\n"
  "        end\n"
  "    end\n"
  "`endif\n", 1)

# ---- ⑥ 判据 (接在既有 W66 段之后) ----
E("            if (w_stat_winstall !== exp_winstall_cyc) begin tot_red = tot_red + 1;\n"
  "                $display(\"[FAIL] W66 语义不符 (逐拍复算): dut=%0d tb=%0d\",\n"
  "                         w_stat_winstall, exp_winstall_cyc); end\n"
  "`endif\n",
  "            if (w_stat_winstall !== exp_winstall_cyc) begin tot_red = tot_red + 1;\n"
  "                $display(\"[FAIL] W66 语义不符 (逐拍复算): dut=%0d tb=%0d\",\n"
  "                         w_stat_winstall, exp_winstall_cyc); end\n"
  "            // ---- ⭐ 构建 F: W67 (板帽侧那一份) + W69 (操作点锁存) -----------------\n"
  "            //   判据形状 = **双边等式** (与 TB 侧独立复算逐字相等) ⇒ 两个方向都有牙:\n"
  "            //     多数 (把对端侧也算进来) 与 少数 (哑计数器) 都会红。\n"
  "            //   ⚠️ 在**默认帽** (0xBFFE) 下板帽侧结构性为 0 ⇒ 该方向是**空判据**;\n"
  "            //     真正激励它的是 `-d W67_CAP_SMALL` 那一臂 (`W67_MINCAP_WIT 见下)。\n"
  "            $display(\"W67 dut=%0d tb_cap=%0d tb_peer=%0d (W66=%0d)\",\n"
  "                     w_stat_winstall_cap, exp_winstall_cap_cyc,\n"
  "                     exp_winstall_cyc - exp_winstall_cap_cyc, w_stat_winstall);\n"
  "            $display(\"W69 dut=%08h tb=%08h\", w_win_at_winstall, exp_win_at_winstall);\n"
  "            if (w_stat_winstall_cap !== exp_winstall_cap_cyc) begin tot_red = tot_red + 1;\n"
  "                $display(\"[FAIL] W67 语义不符 (逐拍复算): dut=%0d tb_cap=%0d\",\n"
  "                         w_stat_winstall_cap, exp_winstall_cap_cyc); end\n"
  "            // 结构性牙 (设计件 §2.2 点名的**免费**判据): W67 是 W66 的子集 ⇒ 逐窗恒真\n"
  "            if (w_stat_winstall_cap > w_stat_winstall) begin tot_red = tot_red + 1;\n"
  "                $display(\"[FAIL] W67 > W66 (=%0d > %0d) ⇒ 子集关系被破坏 (实现错)\",\n"
  "                         w_stat_winstall_cap, w_stat_winstall); end\n"
  "            if (w_win_at_winstall !== exp_win_at_winstall) begin tot_red = tot_red + 1;\n"
  "                $display(\"[FAIL] W69 锁存值与复算不符: dut=%08h tb=%08h\",\n"
  "                         w_win_at_winstall, exp_win_at_winstall); end\n"
  "`ifdef W67_CAP_SMALL\n"
  "            // 本臂的存在理由 = 让\"板帽侧\"非空 ⇒ 必须见证它真的被激励 (否则又是空判据)\n"
  "            if (exp_winstall_cap_cyc < 64) begin tot_red = tot_red + 1;\n"
  "                $display(\"[FAIL] W67 空判据 (W67_CAP_SMALL 臂): TB 侧板帽侧拍=%0d < 64\",\n"
  "                         exp_winstall_cap_cyc); end\n"
  "`endif\n"
  "`endif\n", 1)


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
        tag = "OK  " if k == n else "FAIL"
        print("%s hits=%d/%d  %s" % (tag, k, n, old.split("\n")[0].strip()[:56]))
        if k != n:
            fails += 1
            continue
        if not check:
            s = s.replace(old2, new2)
    if not check and not fails:
        io.open(p, "w", encoding="utf-8", newline="").write(s)
    print("APPLY_TB %s (%d edits, %d fail)" % ("OK" if not fails else "FAIL", len(EDITS), fails))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
