#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""P7B 构建 E —— TB / 变异器 / 门的改动 (显式清单; 每条断言命中数).
   ① tb/tb_tcp_tx_ovl.v : W66 (stat_winstall) 的判据 + **定向窗口关闭插曲** (造靶)
   ② tb/tb_app_cont.v   : u_rec1/u_rec2 从"只记录"升级成**断言恢复** (A3 的行为判据)
   ③ author_gate/mk_mut_tx.py  : 新增两个 W66 变异件 (声明期望命中数)
   ④ author_gate/run_tx_ovl_gate.bat : 加两个臂 (L/M)
   ⑤ sim/p7b_longsend/mk_mut_cont.py : 新增 M5 (A3 待补位删除 = 负对照)
   ⑥ sim/p7b_longsend/run_cont_gate.bat : 加 M5 臂
   行尾: 插入行用**文件自身的**行尾风格。
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


# ===========================================================================
# ① tb/tb_tcp_tx_ovl.v
# ===========================================================================
# ---- V1: 声明 (wires/regs/localparams) ----
E("tb/tb_tcp_tx_ovl.v",
  "    wire [31:0] stat_retx;\n",
  "    wire [31:0] stat_retx;\n"
  "    // ⭐ 构建 E: W66 = tcp_tx_frame.stat_winstall (帧器侧窗口门停顿拍数)\n"
  "    wire [31:0] w_stat_winstall;\n"
  "    //   定向窗口关闭插曲 (见下方激励块) 的参数与状态\n"
  "    localparam integer WC_AT   = 120000;   // 关窗起始拍 (远早于覆盖率目标)\n"
  "    localparam integer WC_HOLD = 12000;    // 关窗保持拍 (≈6 个 ACK 周期)\n"
  "    localparam [3:0]   WC_CONN = 4'd1;     // 目标连接 (避开 conn0 的 SYN 特例 / conn2·3 的 FIN·RST 臂)\n"
  "    reg  [1:0]  wc_st;                     // 0=等触发 1=写关窗中 2=保持 3=写回中 4=完\n"
  "    reg  [31:0] wc_cyc;                    // 关窗保持计时\n"
  "    // ⭐ W66 的 **TB 侧独立复算** (逐拍; 与 RTL 判据同源但**独立实现**):\n"
  "    //   ⚠️ 刻意**不引用** `u_dut.stat_winstall_ev` —— 引用它会让判据变成环路恒等式\n"
  "    //      (变异体改判据时 oracle 跟着改 ⇒ 永远相等 = 没牙)。这里逐项自写:\n"
  "    //      rx_state/recv_first/ack_pend_r/svc/ring_eval/scan_now/rx_flush/fifo_full/\n"
  "    //      bank_rdy/tx_blk_sid 全是读 DUT 的**状态线**, 判据表达式由本 TB 写。\n"
  "    integer     exp_winstall_cyc;          // TB 复算的窗口门停顿拍数\n"
  "    reg         wc_seen;                   // 见证: 窗口确实被观察到关过 (!wnd_open)\n",
  1)

# ---- V2: 端口接线 ----
E("tb/tb_tcp_tx_ovl.v",
  "        .stat_retx(stat_retx),\n",
  "        .stat_retx(stat_retx),\n"
  "        .stat_winstall(w_stat_winstall),\n", 1)

# ---- V3: 复位加一行 ----
E("tb/tb_tcp_tx_ovl.v",
  "            setup_c <= 4'd0; ack_req <= 1'b0; cfg_up <= 1'b0;\n",
  "            setup_c <= 4'd0; ack_req <= 1'b0; cfg_up <= 1'b0;\n"
  "            wc_st <= 2'd0; wc_cyc <= 32'd0;   // 构建 E: 窗口关闭插曲 FSM\n", 1)

# ---- V4: 窗口关闭插曲 FSM (放在激励 always 块的**最后** = 与 setup FSM 无多写者) ----
E("tb/tb_tcp_tx_ovl.v",
  "            win_prev <= d_ctrl_win;\n"
  "`endif\n"
  "        end\n"
  "    end\n",
  "            win_prev <= d_ctrl_win;\n"
  "`endif\n"
  "            // ---- ⭐ 构建 E: 定向窗口关闭插曲 (给 W66 = stat_winstall 造靶) ----\n"
  "            //   动机: 本 TB 的 snd_wnd = 0xC000 (49152) 而 ACK 每 8192 B 一次 ⇒ 在飞\n"
  "            //   常年 <10 KB ⇒ `wnd_open` **结构性恒 1**; 不加激励的话新计数器是\n"
  "            //   空判据 (永远 0, 变异体也照不出来)。\n"
  "            //   做法: 把 conn1 的 snd_wnd 压到 **1 MSS (1460)**, 保持 WC_HOLD 拍,\n"
  "            //   再写回 0xC000。在飞一旦 >=1460 ⇒ 帧器启动点的 `wnd_open` 落 0 ⇒\n"
  "            //   只要 TB 还在给 conn1 喂帧 (round-robin), 就必然出现\"启动点 + 有字 +\n"
  "            //   其余门全开 + 只有窗口关着\"的拍 = 本字的靶。\n"
  "            //   ⚠️ 自恢复 (不靠 ack_lag 那条路 —— snd_wnd=1460 下它够不着):\n"
  "            //      本 TB 的 rx ACK 调度含**周期支** (`cyc % 2048 == 0 &&\n"
  "            //      peer_rcv > sh_una`) ⇒ 关窗期间 snd_una 照常被推进 ⇒ 窗口自行重开。\n"
  "            //   ⚠️ 与 setup FSM 的多写者风险: 出发条件含 `setup_c >= NCONN`, 而 setup\n"
  "            //      FSM 整段在 `if (setup_c < NCONN)` 里 ⇒ 两者**结构性互斥**;\n"
  "            //      本块又写在同一个 always 块的**最后** ⇒ 顺序上也安全。\n"
  "            case (wc_st)\n"
  "            2'd0: if ((setup_c >= NCONN) && (cyc == WC_AT)) begin\n"
  "                      scfg_upd_wr <= 1'b1; scfg_upd_id <= WC_CONN;\n"
  "                      scfg_upd_sel <= 3'd4; scfg_upd_val <= 32'd1460;\n"
  "                      wc_st <= 2'd1;\n"
  "                  end\n"
  "            2'd1: if (tcb_wr && (tcb_sel == 3'd4) && (tcb_id == WC_CONN)) begin\n"
  "                      scfg_upd_wr <= 1'b0; wc_cyc <= 32'd0; wc_st <= 2'd2;\n"
  "                  end\n"
  "            2'd2: begin\n"
  "                      wc_cyc <= wc_cyc + 32'd1;\n"
  "                      if (wc_cyc == WC_HOLD) begin\n"
  "                          scfg_upd_wr <= 1'b1; scfg_upd_id <= WC_CONN;\n"
  "                          scfg_upd_sel <= 3'd4; scfg_upd_val <= {16'b0, SND_WND};\n"
  "                          wc_st <= 2'd3;\n"
  "                      end\n"
  "                  end\n"
  "            2'd3: if (tcb_wr && (tcb_sel == 3'd4) && (tcb_id == WC_CONN)) begin\n"
  "                      scfg_upd_wr <= 1'b0; wc_st <= 2'd4;\n"
  "                  end\n"
  "            default: ;\n"
  "            endcase\n"
  "        end\n"
  "    end\n", 1)

# ---- V5: TB 侧逐拍复算 (独立 always 块, 放在影子账本块之前) ----
E("tb/tb_tcp_tx_ovl.v",
  "    // ===================== 影子账本 + 相位 =====================\n",
  "    // ===================== ⭐ 构建 E: W66 的 TB 侧逐拍复算 =====================\n"
  "    //   判据 (与 rtl/tcp_tx_frame.v 的 stat_winstall_ev **逐项同款**, 但在本 TB 里\n"
  "    //   独立写出): 帧器站在数据帧启动点 + 呈交口有字 + 其余门全开 + 只有窗口关着。\n"
  "    //   ⚠️ 只在 TCP_TX_OVL 分支有对应实现 (默认/串行分支的启动点是 state==S_IDLE,\n"
  "    //      判据不同) ⇒ 本判据包 OVL。\n"
  "`ifdef TCP_TX_OVL\n"
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
  "`endif\n"
  "\n"
  "    // ===================== 影子账本 + 相位 =====================\n", 1)

# ---- V6: 判据 + 读数打印 (放在 T8 判据之后, ARM_ACKGATE 段之前) ----
E("tb/tb_tcp_tx_ovl.v",
  "            if ((fp1460_min > 220) && (tx1460_n > 100)) begin tot_red = tot_red + 1;\n"
  "                $display(\"[FAIL] T8 满长帧帧周期 min=%0d > 220 (乒乓退化?)\", fp1460_min); end\n",
  "            if ((fp1460_min > 220) && (tx1460_n > 100)) begin tot_red = tot_red + 1;\n"
  "                $display(\"[FAIL] T8 满长帧帧周期 min=%0d > 220 (乒乓退化?)\", fp1460_min); end\n"
  "`ifdef TCP_TX_OVL\n"
  "            // ---- ⭐ 构建 E: W66 (stat_winstall = 帧器侧**窗口门**停顿拍数) ------\n"
  "            $display(\"W66 dut=%0d tb=%0d wndclosed_seen=%0d wc_st=%0d\",\n"
  "                     w_stat_winstall, exp_winstall_cyc, wc_seen, wc_st);\n"
  "            if (!wc_seen) begin tot_red = tot_red + 1;\n"
  "                $display(\"[FAIL] W66 空判据: 整个跑窗内 wnd_open 从未观察到 0\"); end\n"
  "            if (exp_winstall_cyc < 64) begin tot_red = tot_red + 1;\n"
  "                $display(\"[FAIL] W66 空判据: TB 侧窗口门停顿拍=%0d < 64\", exp_winstall_cyc); end\n"
  "            if (w_stat_winstall !== exp_winstall_cyc) begin tot_red = tot_red + 1;\n"
  "                $display(\"[FAIL] W66 语义不符 (逐拍复算): dut=%0d tb=%0d\",\n"
  "                         w_stat_winstall, exp_winstall_cyc); end\n"
  "`endif\n", 1)

# ===========================================================================
# ② tb/tb_app_cont.v —— A3 的行为判据
# ===========================================================================
# ---- W4: 打印块的口径就地订正 (M_nst 已经是"ev_up 之后新起帧数" —— 见其声明与
#          `if (up_w[gi]) ... M_nst[gi] = 0;` 那一段; 旧注释"不是判据"已过时) ----
E("tb/tb_app_cont.v",
  "        // ⚠️ 重连臂观测 (不是判据, 只有 u_rec3 有断言): starts_after_up>0 = \"恢复\";\n"
  "        //    =0 = \"ev_up 被吞 / 静默零数据\"。预测 (审查员 ① 的机理): k 落在\n"
  "        //    \"收尾仍被 m_tready 卡住\"的窗口内 (rec1/rec2, tready 低 300 拍) => 0;\n"
  "        //    u_rec3 (tready 低 6 拍, 收尾早已完成) => >0。\n",
  "        // ⭐ 构建 E (A3): 三个重连臂**全部升级为判据** (原句 = \"不是判据, 只有\n"
  "        //    u_rec3 有断言\")。口径确认 (读 TB 自己的实现): `M_nst` 在 `up_w[gi]`\n"
  "        //    那一拍被清 0 (见上面 `if (up_w[gi]) ... M_nst[gi] = 0;`) ⇒ 打印出来的\n"
  "        //    `starts_after_up` 字面就是\"**最近一次 ev_up 之后**新起的帧数\",\n"
  "        //    不是总帧数 (本轮先误以为要另立快照寄存器, 核对实现后撤回 —— 记录在此\n"
  "        //    免得下一个读的人重犯)。\n"
  "        //    修前机理 (审查员 ①): k 落在\"收尾仍被 m_tready 卡住\"的窗口内\n"
  "        //    (rec1 k=40/tw=300, rec2 k=240/tw=300) ⇒ ev_up 被吞 ⇒ 修前 = 0;\n"
  "        //    rec3 (tw=6, 收尾早已完成) ⇒ 修前就 >0 (对照臂, 行为不得变)。\n", 1)

# ---- W5: 断言 (u_rec1/u_rec2 升级成判据; u_rec3 原判据保留 = 对照) ----
E("tb/tb_app_cont.v",
  "        // --- u_rec3 (对照臂): 收尾能完成 => 必须恢复 (帧起始拍在 ev_up 之后) ---\n"
  "        chk(M_nst[9] >= 32'd1,        \"A13 u_rec3 resumed after same-slot reconnect (new frame start)\");\n",
  "        // --- ⭐ 构建 E (A3): 三个重连臂都断言\"换流后确有新帧起始\" ----------------\n"
  "        //   修前: u_rec1/u_rec2 = 0 (ev_up 被吞 ⇒ 新连接静默零数据、无自愈);\n"
  "        //         u_rec3 = 1 (对照臂, 收尾早已完成 ⇒ 修前修后都恢复)。\n"
  "        //   判据 = **ev_up 之后新起的帧数 >= 1** (M_nst 已在 up_w 拍清 0 ⇒ 该口径\n"
  "        //   天然成立; 见打印块的就地说明)。\n"
  "        chk(M_nst[7] >= 32'd1,\n"
  "            \"A13a u_rec1 resumed after same-slot reconnect (k=40, tready low 300)\");\n"
  "        chk(M_nst[8] >= 32'd1,\n"
  "            \"A13b u_rec2 resumed after same-slot reconnect (k=240, tready low 300)\");\n"
  "        chk(M_nst[9] >= 32'd1,\n"
  "            \"A13c u_rec3 resumed after same-slot reconnect (k=240, tready low 6; 对照臂)\");\n"
  "`ifndef APP_CONT_ARM\n"
  "        // 对照臂**行为不得变** (只在本 TB 的非连续臂 = ARM A 成立): u_rec3 修前修后\n"
  "        //   都是\"恰好 1 帧\" (1000B 量子; ev_up 落在帧 1 之后 ⇒ 补做换流只发下一帧)。\n"
  "        //   ⚠️ 连续臂 (ARM B/C) 里它一直发 ⇒ 本条不适用 (所以包 ifndef)。\n"
  "        chk(M_nst[9] == 32'd1,\n"
  "            \"A13c' u_rec3 resume count == 1 (补做逻辑不给对照臂多发帧; ARM A only)\");\n"
  "`endif\n", 1)

# ---- W6: 头注释里的实例表期望订正 ----
E("tb/tb_app_cont.v",
  "//   idx9 u_rec3      arm, 1000B  -- ev_down(k=240) + tready 低 6 拍 (收尾能完成: 对照)\n",
  "//   idx9 u_rec3      arm, 1000B  -- ev_down(k=240) + tready 低 6 拍 (收尾能完成: 对照)\n"
  "//   ⭐ 构建 E (A3): rec1/rec2 由\"只记录\"升级为**判据** (starts_after_up >= 1);\n"
  "//      修前这两臂 = 0 (ev_up 被吞 ⇒ 新连接静默零数据), 修后必须 >= 1。\n", 1)

# ===========================================================================
# ③ author_gate/mk_mut_tx.py —— 两个 W66 变异件
# ===========================================================================
E("sim/p7b_stagec_tx_regress/author_gate/mk_mut_tx.py",
  "# ---- M-C9: 仲裁键改回 ctrl_slot_busy (两处帧边界判定) ----\n",
  "# ---- W66-1 (构建 E): 窗口门停顿计数器**永不计数** (哑观测) ----\n"
  "#   判据 (tb_tcp_tx_ovl.v 的 W66 段) 逐拍复算同一个判据并要求两者**相等** ⇒\n"
  "#   计数器死掉 (恒 0) 而 TB 侧照数 ⇒ 必红。两个分支各一处 (声明命中数 = 2)。\n"
  "add(\"mut_w66_dead\", [(\n"
  "    \"            if (stat_winstall_ev) stat_winstall <= stat_winstall + 32'd1;\",\n"
  "    \"            // M-W66-1: 哑观测 (永不计数)\",\n"
  "    2)], \"M-W66-1 计数器恒 0 (两分支各一处) => 判据必红\")\n"
  "\n"
  "# ---- W66-2 (构建 E): 判据**语义**错 (去掉 `!wnd_open` = 把\"想开\"当\"被窗挡\") ----\n"
  "#   定向反例: 计数器会**多**数 (把 start_data 拍也算进去) ⇒ 与 TB 复算不等 ⇒ 红。\n"
  "add(\"mut_w66_nownd\", [(\n"
  "    \"                                   !fifo_full && !bank_rdy[rx_bank] &&\\n\"\n"
  "    \"                                   !tx_blk_sid && !wnd_open;\",\n"
  "    \"                                   !fifo_full && !bank_rdy[rx_bank] &&\\n\"\n"
  "    \"                                   !tx_blk_sid;\",\n"
  "    1)], \"M-W66-2 (OVL) 判据去掉 !wnd_open => 多数 start_data 拍\")\n"
  "\n"
  "# ---- M-C9: 仲裁键改回 ctrl_slot_busy (两处帧边界判定) ----\n", 1)

# ===========================================================================
# ④ author_gate/run_tx_ovl_gate.bat —— L/M 两臂
# ===========================================================================
E("sim/p7b_stagec_tx_regress/author_gate/run_tx_ovl_gate.bat",
  "call :run K \"%HERE%\\mut\\mut_c8.v\" \"-d TCP_TX_OVL\"\r\n"
  "set RCK=%errorlevel%",
  "call :run K \"%HERE%\\mut\\mut_c8.v\" \"-d TCP_TX_OVL\"\r\n"
  "set RCK=%errorlevel%\r\n"
  "call :run L \"%HERE%\\mut\\mut_w66_dead.v\" \"-d TCP_TX_OVL\"\r\n"
  "set RCL=%errorlevel%\r\n"
  "call :run M \"%HERE%\\mut\\mut_w66_nownd.v\" \"-d TCP_TX_OVL\"\r\n"
  "set RCM=%errorlevel%", 1)

E("sim/p7b_stagec_tx_regress/author_gate/run_tx_ovl_gate.bat",
  "echo   K M-C8  no rx_idle RC=%RCK% (expect nonzero)\r\n",
  "echo   K M-C8  no rx_idle RC=%RCK% (expect nonzero)\r\n"
  "echo   L M-W66-1 dead counter RC=%RCL% (expect nonzero; 构建 E 新判据的牙)\r\n"
  "echo   M M-W66-2 no !wnd_open RC=%RCM% (expect nonzero; 语义错方向)\r\n", 1)

E("sim/p7b_stagec_tx_regress/author_gate/run_tx_ovl_gate.bat",
  "if \"%RCK%\"==\"0\" set /a FAILS+=1\r\n",
  "if \"%RCK%\"==\"0\" set /a FAILS+=1\r\n"
  "if \"%RCL%\"==\"0\" set /a FAILS+=1\r\n"
  "if \"%RCM%\"==\"0\" set /a FAILS+=1\r\n", 1)

E("sim/p7b_stagec_tx_regress/author_gate/run_tx_ovl_gate.bat",
  "findstr /C:\"FRAMES\" /C:\"COV \" /C:\"MINGAP\" /C:\"CYCRX\" /C:\"CYCTX\" /C:\"FRAMEPERIOD\" /C:\"OVL \" /C:\"REDS\" /C:\"T8 \" /C:\"TB_TCP_TX_OVL\" \"runB\\xs.log\"\r\n",
  "findstr /C:\"FRAMES\" /C:\"COV \" /C:\"MINGAP\" /C:\"CYCRX\" /C:\"CYCTX\" /C:\"FRAMEPERIOD\" /C:\"OVL \" /C:\"REDS\" /C:\"T8 \" /C:\"W66\" /C:\"TB_TCP_TX_OVL\" \"runB\\xs.log\"\r\n", 1)

E("sim/p7b_stagec_tx_regress/author_gate/run_tx_ovl_gate.bat",
  "for %%M in (C D E F G H I J K) do (\r\n",
  "for %%M in (C D E F G H I J K L M) do (\r\n", 1)

E("sim/p7b_stagec_tx_regress/author_gate/run_tx_ovl_gate.bat",
  "REM     I = M-C2   control reservation registered 8 cycles (form A)\r\n"
  "REM Contract: A/B RC==0; C..I RC!=0.\r\n",
  "REM     I = M-C2   control reservation registered 8 cycles (form A)\r\n"
  "REM   L = M-W66-1  stat_winstall never counts (构建 E)\r\n"
  "REM   M = M-W66-2  stat_winstall predicate drops !wnd_open (构建 E)\r\n"
  "REM Contract: A/B RC==0; C..M RC!=0 (J = KNOWN GAP, 不计).\r\n", 1)

# ===========================================================================
# ⑤ sim/p7b_longsend/mk_mut_cont.py —— M5 (A3 负对照)
# ===========================================================================
E("sim/p7b_longsend/mk_mut_cont.py",
  "     M4 = 删 :676 的 `&& !CONT_OK`\n",
  "     M4 = 删 :676 的 `&& !CONT_OK`\n"
  "     M5 = 删 A3 的\"待补登记\"(被吞的 ev_up 又变回永久丢失 = 修前行为; 构建 E)\n", 1)

E("sim/p7b_longsend/mk_mut_cont.py",
  "# ---- M4: 删掉终结判据的 !CONT_OK (连续模式仍会\"结束\") ----\n",
  "# ---- M5 (构建 E): 删掉 A3 的待补登记 ⇒ 回到\"被吞的 ev_up 永久丢失\" ----\n"
  "#   定向反例: tb_app_cont 的 A13a/A13b (u_rec1/u_rec2 换流后新起帧数 >= 1) 必红,\n"
  "#   而 A13c (u_rec3 对照臂) 必须**照旧绿** ⇒ 这条变异同时证明判据有牙 + 只咬该咬的。\n"
  "add(\"m5_no_uppend\", [(\n"
  "    \"            if (up_do) up_pend_r <= 1'b0;\\n\"\n"
  "    \"            else if (ev_up) begin\\n\"\n"
  "    \"                up_pend_r  <= 1'b1;\\n\"\n"
  "    \"                up_pend_id <= ev_slot;\\n\"\n"
  "    \"            end\\n\",\n"
  "    \"            if (up_do) up_pend_r <= 1'b0;   // M5: 删掉待补登记 (修前行为)\\n\",\n"
  "    1)], \"M5 无待补登记 => u_rec1/u_rec2 又静默 (A13a/A13b 必红; A13c 仍绿)\")\n"
  "\n"
  "# ---- M4: 删掉终结判据的 !CONT_OK (连续模式仍会\"结束\") ----\n", 1)

# ===========================================================================
# ⑥ sim/p7b_longsend/run_cont_gate.bat —— M5 臂
# ===========================================================================
E("sim/p7b_longsend/run_cont_gate.bat",
  "call :run M4 \"%HERE%\\mut\\m4_term_open.v\" \"-d APP_CONT_ARM\"\r\n"
  "set \"RCM4=%errorlevel%\"\r\n",
  "call :run M4 \"%HERE%\\mut\\m4_term_open.v\" \"-d APP_CONT_ARM\"\r\n"
  "set \"RCM4=%errorlevel%\"\r\n"
  "call :run M5 \"%HERE%\\mut\\m5_no_uppend.v\" \"-d APP_CONT_ARM\"\r\n"
  "set \"RCM5=%errorlevel%\"\r\n", 1)

E("sim/p7b_longsend/run_cont_gate.bat",
  "echo   M4 term-open        RC=%RCM4%  (expect nonzero)\r\n",
  "echo   M4 term-open        RC=%RCM4%  (expect nonzero)\r\n"
  "echo   M5 no-uppend (A3)   RC=%RCM5%  (expect nonzero; 构建 E)\r\n", 1)

E("sim/p7b_longsend/run_cont_gate.bat",
  "if \"%RCM4%\"==\"0\" set /a FAILS+=1\r\n",
  "if \"%RCM4%\"==\"0\" set /a FAILS+=1\r\n"
  "if \"%RCM5%\"==\"0\" set /a FAILS+=1\r\n", 1)

E("sim/p7b_longsend/run_cont_gate.bat",
  "echo   [M4] term-open:\r\n"
  "findstr /C:\"[FAIL]\" \"runM4\\xs.log\"\r\n",
  "echo   [M4] term-open:\r\n"
  "findstr /C:\"[FAIL]\" \"runM4\\xs.log\"\r\n"
  "echo   [M5] no-uppend (A3):\r\n"
  "findstr /C:\"[FAIL]\" \"runM5\\xs.log\"\r\n", 1)

E("sim/p7b_longsend/run_cont_gate.bat",
  "REM   M1..M4 = mutants under APP_CONT_ARM       expect RC != 0\r\n",
  "REM   M1..M5 = mutants under APP_CONT_ARM       expect RC != 0\r\n", 1)


def main():
    check = "--check" in sys.argv[1:]
    fails = []
    for rel, old, new, n in EDITS:
        p = os.path.join(REPO, rel.replace("/", os.sep))
        b, nl = rd(p)
        if nl != b"\n":
            # 先归一化 (允许清单里**混用** \n 与 \r\n 两种写法), 再按文件风格落笔
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
    print("APPLY_TB %s (%d edits, %d fail)" % ("OK" if not fails else "FAIL", len(EDITS), len(fails)))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
