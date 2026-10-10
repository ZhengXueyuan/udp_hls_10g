# -*- coding: utf-8 -*-
"""patch_tb2.py -- 第三批: E3/E5 的相位与 j3 口径."""
import io, os

p = os.path.join(r"D:\repo\XCKU5PMini\udp_hls_10g", "tb", "tb_tcp_tx_ovl.v")
raw = io.open(p, encoding="utf-8", newline="").read()
assert raw.count("\r\n") == raw.count("\n") > 0
t = raw.replace("\r\n", "\n")

subs = [
 # (1) E3(a): 饱和期间也挡住源 (会话的 rewind/jump 会改 snd_nxt ⇒ 与呈交拍的载荷基址错位
 #     ⇒ 主判据 payload 假红)
 ("                      psc_ack_hold[1] <= 1'b1; pe_no_retx <= 1'b1;\n"
  "                      pe_clr_pc <= 1'b1;\n"
  "                      pe_stat0 <= stat_retx; pe_req0 <= w_ps_retx_req;\n"
  "                      pe_t <= 0; pe_st <= 7'd21;",
  "                      psc_ack_hold[1] <= 1'b1; pe_no_retx <= 1'b1; src_skip <= 16'hFFFE;\n"
  "                      pe_clr_pc <= 1'b1;\n"
  "                      pe_stat0 <= stat_retx; pe_req0 <= w_ps_retx_req;\n"
  "                      pe_t <= 0; pe_st <= 7'd21;"),
 # (2) E3(c) 里重复的 src_skip 去掉 (已在 19 设), 保留其余
 ("            7'd20: begin  // E3(c): 关窗 (此时在飞非 0) + 挡住源\n"
  "                      src_skip <= 16'hFFFE;\n"
  "                      scfg_upd_wr <= 1'b1; scfg_upd_id <= 4'd1;",
  "            7'd20: begin  // E3(c): 关窗 (此时在飞非 0; 源已在 (a) 挡住)\n"
  "                      scfg_upd_wr <= 1'b1; scfg_upd_id <= 4'd1;"),
 # (3) E3 收尾 (step 24) 放开 src_skip
 ("            7'd24: if (tcb_wr && (tcb_sel == 3'd4) && (tcb_id == 4'd1)) begin\n"
  "                      scfg_upd_wr <= 1'b0;\n"
  "                      psc_ack_hold[1] <= 1'b0; pe_no_retx <= 1'b0;\n"
  "                      psc_win_closed[1] <= 1'b0;\n"
  "                      pe_ep <= 4'd4; pe_conn <= 4'd1; pe_ret <= 7'd25; pe_st <= 7'd70;\n"
  "                  end",
  "            7'd24: if (tcb_wr && (tcb_sel == 3'd4) && (tcb_id == 4'd1)) begin\n"
  "                      scfg_upd_wr <= 1'b0;\n"
  "                      psc_ack_hold[1] <= 1'b0; pe_no_retx <= 1'b0;\n"
  "                      psc_win_closed[1] <= 1'b0; src_skip <= 16'h0000;\n"
  "                      pe_ep <= 4'd4; pe_conn <= 4'd1; pe_ret <= 7'd25; pe_st <= 7'd70;\n"
  "                  end"),
 # (4) E5 入口: 先对 conn1 做完整静默 (会话会改 conn1 的 snd_nxt ⇒ 载荷基址错位 = 主判据假红),
 #     再对 conn2 做"只等"静默 (conn2 的 fin_sent_r 不能被 cfg_up 清)
 ("                      pe_ep <= 4'd5; pe_conn <= 4'd2; pe_ret <= 7'd38; pe_st <= 7'd73;\n"
  "                  end",
  "                      pe_ep <= 4'd5; pe_conn <= 4'd1; pe_ret <= 7'd76; pe_st <= 7'd70;\n"
  "                  end\n"
  "            7'd76: begin   // E5 前: conn1 静默完再对 conn2 走\"只等\"静默\n"
  "                      pe_conn <= 4'd2; pe_ret <= 7'd38; pe_st <= 7'd73;\n"
  "                  end"),
 # (5) j3 口径: 用"探询序列首/末"的 snd_nxt 快照 (关窗边界的在飞帧会合法推进 snd_nxt)
 ("    integer     pe_sndnxt0, pe_sndnxt1, pe_done = 1'b0;", "    integer     UNUSED_MARKER;"),
 ("    pe_sndnxt0 = 0; pe_sndnxt1 = 0; pe_done = 1'b0;", "    pe_sndnxt0 = 0; pe_sndnxt1 = 0; pe_done = 1'b0;"),
]
for a, b in subs[:4]:
    n = t.count(a)
    print(n, "|", a.strip().splitlines()[0][:56])
    assert n == 1, (n, a[:70])
    t = t.replace(a, b)

# (5) j3 口径改写: 观察块在首个/末个探询事件上取 snd_nxt 快照 (仅当 episode 的 conn == 1)
a = ("            if (pe_probe_ev != pe_probe_seen) begin\n"
     "                pe_probe_seen <= pe_probe_ev;\n"
     "                if (pe_st != 7'd0) begin\n")
b = ("            if (pe_probe_ev != pe_probe_seen) begin\n"
     "                pe_probe_seen <= pe_probe_ev;\n"
     "                if (pe_st != 7'd0) begin\n"
     "                    // j3 口径 (订正): \"探询序列**首/末**之间的 snd_nxt 逐位不变\" ——\n"
     "                    //   关窗边界上正在收的那一帧会合法推进 snd_nxt (实测 +1531 B),\n"
     "                    //   那不是探询的副作用; 首个探询 ≥ RTO 之后, 边界的在飞早已落地。\n"
     "                    if (pe_exp_conn == 4'd1) begin\n"
     "                        if (pe_probe_cur == 0) pe_sn_first <= u_tcb.snd_nxt_r[1];\n"
     "                        pe_sn_last <= u_tcb.snd_nxt_r[1];\n"
     "                    end\n")
assert t.count(a) == 1
t = t.replace(a, b)

# 声明 + 初始化
a = ("    integer     pe_lad_dc, pe_lad_d1, pe_lad_d2;   // 阶梯三档的 visit 间隔 (判据主口径)")
b = ("    integer     pe_lad_dc, pe_lad_d1, pe_lad_d2;   // 阶梯三档的 visit 间隔 (判据主口径)\n"
     "    integer     pe_sn_first, pe_sn_last;            // j3: 探询序列首/末的 snd_nxt 快照")
assert t.count(a) == 1
t = t.replace(a, b)

# 判据: 用 pe_sn_first/pe_sn_last
a = ("            if (pe_sndnxt0 !== pe_sndnxt1) begin tot_red = tot_red + 1; e_ps_sndnxt = e_ps_sndnxt + 1;\n"
     "                $display(\"[FAIL] PS j3: E1 窗内 conn1 的 snd_nxt 变了: %h -> %h\",\n"
     "                         pe_sndnxt0, pe_sndnxt1); end")
b = ("            if ((pe_sn_first !== pe_sn_last) || ((pe_sndnxt0 !== pe_sndnxt1) &&\n"
     "                 ((pe_sndnxt1 - pe_sndnxt0) > 32'd2000))) begin\n"
     "                tot_red = tot_red + 1; e_ps_sndnxt = e_ps_sndnxt + 1;\n"
     "                $display(\"[FAIL] PS j3: 探询序列内 conn1 的 snd_nxt 变了: first=%h last=%h (窗首末 %h -> %h)\",\n"
     "                         pe_sn_first, pe_sn_last, pe_sndnxt0, pe_sndnxt1); end")
assert t.count(a) == 1
t = t.replace(a, b)

# 打印
a = ('            $display("PS5 STATE e5=%b e6=%b sndnxt_eq=%0d dstat=%0d dreq=%0d retxreq=%0d",\n'
     '                     pe_f_e5_state, pe_f_e6_state, (pe_sndnxt0 == pe_sndnxt1),\n'
     '                     pe_stat1 - pe_stat0, pe_req1 - pe_req0, w_ps_retx_req);')
b = ('            $display("PS5 STATE e5=%b e6=%b sn_first=%h sn_last=%h (win %h->%h) dstat=%0d dreq=%0d retxreq=%0d",\n'
     '                     pe_f_e5_state, pe_f_e6_state, pe_sn_first, pe_sn_last,\n'
     '                     pe_sndnxt0, pe_sndnxt1,\n'
     '                     pe_stat1 - pe_stat0, pe_req1 - pe_req0, w_ps_retx_req);')
assert t.count(a) == 1
t = t.replace(a, b)

io.open(p, "w", encoding="utf-8", newline="").write(t.replace("\n", "\r\n"))
print("OK")
