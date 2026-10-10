# -*- coding: utf-8 -*-
"""patch_tb.py -- 对 tb/tb_tcp_tx_ovl.v 做 CRLF 安全的批量替换 (实施轮一次性工具)."""
import io, os, sys

ROOT = r"D:\repo\XCKU5PMini\udp_hls_10g"
p = os.path.join(ROOT, "tb", "tb_tcp_tx_ovl.v")
raw = io.open(p, encoding="utf-8", newline="").read()
assert raw.count("\r\n") == raw.count("\n") > 0, "not pure CRLF"
t = raw.replace("\r\n", "\n")

subs = [
 # --- E3 重构: 先在**窗开着**时打饱和 (data 在流 ⇒ 关窗后有在飞), 再关窗 ---
 ("            7'd19: begin  // E3: 关窗 + 冻结 snd_una (epoch 饱和需要\"无进展\")\n"
  "                      psc_ack_hold[1] <= 1'b1; pe_no_retx <= 1'b1; src_skip <= 16'hFFFE;\n"
  "                      scfg_upd_wr <= 1'b1; scfg_upd_id <= 4'd1;\n"
  "                      scfg_upd_sel <= 3'd4; scfg_upd_val <= 32'd0;\n"
  "                      pe_st <= 7'd20;\n"
  "                  end\n"
  "            7'd20: if (tcb_wr && (tcb_sel == 3'd4) && (tcb_id == 4'd1)) begin\n"
  "                      scfg_upd_wr <= 1'b0; psc_win_closed[1] <= 1'b1;\n"
  "                      pe_clr_pc <= 1'b1; pe_exp_conn <= 4'd1;\n"
  "                      pe_exp_seq[1] <= u_tcb.snd_una_r[1];\n"
  "                      pe_stat0 <= stat_retx; pe_req0 <= w_ps_retx_req;\n"
  "                      pe_sndnxt0 <= u_tcb.snd_nxt_r[1];\n"
  "                      pe_t <= 0; pe_st <= 7'd21;\n"
  "                  end\n"
  "            7'd21: begin  // E3: 注入 retx_req 直到 epoch 饱和 (见证: blocked 面)\n"
  "                      pe_t <= pe_t + 1;\n"
  "                      if (!retx_req) begin\n"
  "                          retx_req <= 1'b1; retx_id <= 4'd1;\n"
  "                          w_ps_retx_req <= w_ps_retx_req + 1;\n"
  "                      end else if (retx_gnt) retx_req <= 1'b0;\n"
  "                      if ((u_dut.epoch[1] >= 4'd15) || (pe_t > PE_E3_SESS)) begin\n"
  "                          retx_req <= 1'b0;\n"
  "                          if (u_dut.epoch[1] >= 4'd15) w_ps_blocked <= w_ps_blocked + 1;\n"
  "                          pe_t <= 0; pe_st <= 7'd22;\n"
  "                      end\n"
  "                  end\n"
  "            7'd22: begin  // E3: 关窗观察窗 (j8: blocked 后仍要 >=2 条)\n"
  "                      pe_t <= pe_t + 1;\n"
  "                      if (pe_t > PE_E3_HOLD) begin\n"
  "                          pe_f_e3_probe <= pe_probe_cur;\n"
  "                          pe_stat1 <= stat_retx; pe_req1 <= w_ps_retx_req;\n"
  "                          pe_sndnxt1 <= u_tcb.snd_nxt_r[1];\n"
  "                          pe_st <= 7'd23;\n"
  "                      end\n"
  "                  end",
  "            7'd19: begin  // E3(a): 冻结 snd_una + 注入 retx_req 直到 epoch 饱和\n"
  "                      //   [!!] **先饱和、后关窗**: 每次回卷 (svc_rewind) 都把 snd_nxt\n"
  "                      //   写回 snd_una => 若先关窗, 饱和结束时在飞 = 0 => 武装条件\n"
  "                      //   第二子句为假 => 探询结构性不发 (首轮实测 0 条探询)。\n"
  "                      //   窗开着时饱和: data 照流 => 关窗那一刻在飞非 0。\n"
  "                      psc_ack_hold[1] <= 1'b1; pe_no_retx <= 1'b1;\n"
  "                      pe_clr_pc <= 1'b1;\n"
  "                      pe_stat0 <= stat_retx; pe_req0 <= w_ps_retx_req;\n"
  "                      pe_t <= 0; pe_st <= 7'd21;\n"
  "                  end\n"
  "            7'd21: begin  // E3(b): 注入 retx_req 直到 epoch 饱和 (见证 blocked 面)\n"
  "                      pe_t <= pe_t + 1;\n"
  "                      if (!retx_req) begin\n"
  "                          retx_req <= 1'b1; retx_id <= 4'd1;\n"
  "                          w_ps_retx_req <= w_ps_retx_req + 1;\n"
  "                      end else if (retx_gnt) retx_req <= 1'b0;\n"
  "                      if ((u_dut.epoch[1] >= 4'd15) || (pe_t > PE_E3_SESS)) begin\n"
  "                          retx_req <= 1'b0;\n"
  "                          if (u_dut.epoch[1] >= 4'd15) w_ps_blocked <= w_ps_blocked + 1;\n"
  "                          pe_t <= 0; pe_st <= 7'd20;\n"
  "                      end\n"
  "                  end\n"
  "            7'd20: begin  // E3(c): 关窗 (此时在飞非 0) + 挡住源\n"
  "                      src_skip <= 16'hFFFE;\n"
  "                      scfg_upd_wr <= 1'b1; scfg_upd_id <= 4'd1;\n"
  "                      scfg_upd_sel <= 3'd4; scfg_upd_val <= 32'd0;\n"
  "                      pe_st <= 7'd65;\n"
  "                  end\n"
  "            7'd65: if (tcb_wr && (tcb_sel == 3'd4) && (tcb_id == 4'd1)) begin\n"
  "                      scfg_upd_wr <= 1'b0; psc_win_closed[1] <= 1'b1;\n"
  "                      pe_clr_pc <= 1'b1; pe_exp_conn <= 4'd1;\n"
  "                      pe_exp_seq[1] <= u_tcb.snd_una_r[1];\n"
  "                      pe_t <= 0; pe_st <= 7'd22;\n"
  "                  end\n"
  "            7'd22: begin  // E3(d): 关窗观察窗 (j8: blocked 后仍要 >=2 条)\n"
  "                      pe_t <= pe_t + 1;\n"
  "                      if (pe_t > PE_E3_HOLD) begin\n"
  "                          pe_f_e3_probe <= pe_probe_cur;\n"
  "                          pe_stat1 <= stat_retx; pe_req1 <= w_ps_retx_req;\n"
  "                          pe_sndnxt1 <= u_tcb.snd_nxt_r[1];\n"
  "                          pe_st <= 7'd23;\n"
  "                      end\n"
  "                  end"),
 # --- E4 等 fire 的诊断 (step 27) ---
 ("            7'd27: begin  // E4: 等 fire\n"
  "                      pe_t <= pe_t + 1;\n"
  "                      if (u_dut.ps_fire || (pe_t > PE_E4_WAIT)) begin pe_t <= 0; pe_st <= 7'd28; end\n"
  "                  end",
  "            7'd27: begin  // E4: 等 fire\n"
  "                      pe_t <= pe_t + 1;\n"
  "                      if (((pe_t % 3000) == 0) && (w_ps_dbg3 < 12)) begin\n"
  "                          w_ps_dbg3 <= w_ps_dbg3 + 1;\n"
  "                          $display(\"DBG E4 @%0d t=%0d sw=%0d scn=%b sid=%0d nxt=%h una=%h fin=%b rst=%b pt=%0d pp=%0d ract=%b\",\n"
  "                                   cyc, pe_t, u_tcb.snd_wnd_r[1], u_dut.scan_now, u_dut.scan_id,\n"
  "                                   u_tcb.snd_nxt_r[1], u_tcb.snd_una_r[1],\n"
  "                                   u_dut.fin_sent_r[1], u_dut.rst_sent_r[1],\n"
  "                                   u_dut.ps_timer[1], u_dut.ps_phase[1], u_dut.retx_active);\n"
  "                      end\n"
  "                      if (u_dut.ps_fire || (pe_t > PE_E4_WAIT)) begin pe_t <= 0; pe_st <= 7'd28; end\n"
  "                  end"),
 ("    integer     w_ps_dbg2;          // conn1 数据帧诊断计数 (<=14 行)",
  "    integer     w_ps_dbg2;          // conn1 数据帧诊断计数 (<=14 行)\n    integer     w_ps_dbg3;          // E4 等 fire 的诊断计数 (<=12 行)"),
 ("        w_ps_dbg2 = 0;", "        w_ps_dbg2 = 0; w_ps_dbg3 = 0;"),
 ("                     w_ps_e5ok, w_ps_e6ok, pe_de1 - pe_de0, w_ps_rst1, w_ps_quiet_to);",
  "                     w_ps_e5ok, w_ps_e6ok, pe_de1 - pe_de0, w_ps_rst1, w_ps_quiet_to);\n"
  "            $display(\"PS4b E7wit_snapshot=%0d (live=%0d)\", pe_f_e7_wit, pe_coll_wit);"),
]

for a, b in subs:
    n = t.count(a)
    print(n, "|", a.strip().splitlines()[0][:56])
    assert n == 1, (n, a[:70])
    t = t.replace(a, b)

io.open(p, "w", encoding="utf-8", newline="").write(t.replace("\n", "\r\n"))
print("OK")
