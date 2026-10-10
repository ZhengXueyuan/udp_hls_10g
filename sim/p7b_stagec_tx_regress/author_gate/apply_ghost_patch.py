#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply_ghost_patch.py -- P7B-RETXHI-GHOST 实施轮: TB + RTL 逐处补丁 (CRLF 保持).
   每处替换声明命中数, 不匹配/多匹配 => 硬失败 (绝不静默半套).
   产出: 逐处 old/new 摘要 + 命中数; 事后校验 CRLF/行数.
   用法: python apply_ghost_patch.py tb|rtl [--dry]
"""
import io, os, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
TB  = os.path.join(ROOT, "tb", "tb_tcp_tx_ovl.v")
RTL = os.path.join(ROOT, "rtl", "tcp_tx_frame.v")
NL = "\r\n"

EDITS = {}

# =========================================================================
EDITS["tb"] = []   # (name, old, new, hits)

EDITS["tb"].append(("T1 e_ghost/e_ringhi decl", (
"            e_onehot, e_pendbusy, e_replay, e_replay_stuck, e_ovf, e_ackf, e_replay_gap;" + NL +
"    integer n_frames, n_data, n_ctrl, n_dead_skip;"),
(
"            e_onehot, e_pendbusy, e_replay, e_replay_stuck, e_ovf, e_ackf, e_replay_gap;" + NL +
"    // ⭐ RETXHI-GHOST (P7B_RETXHI_GHOST_DESIGN.md §5.4): 两个定向仪器," + NL +
"    //   **都必须进 tot_red 白名单和式** (否则再红也不影响末行 = 全局 #53 哑门)." + NL +
"    integer e_ghost, e_ringhi;" + NL +
"    integer n_frames, n_data, n_ctrl, n_dead_skip;"), 1))

_gh = (
"                    if (flags !== 8'h18) begin" + NL +
"                        e_parse = e_parse + 1;" + NL +
"                        $display(\"[FAIL] data flags=%h @%0d\", flags, cyc); end")
_ghn = _gh + NL + (
"                    // ⭐ RETXHI-GHOST §5.4-②: e_ghost = 定向仪器 (半区判据, **帧尾直读**)." + NL +
"                    //   口径 = 帧尾越过该连接**当前已写高水位** (DUT `whi_r`, 不锁存)." + NL +
"                    //   为什么帧尾读安全: ① 活帧自抑制 (活帧的 whi 在其 RX_FIN 落地, 而该" + NL +
"                    //   帧上线尾拍要再等 ~180+ 拍 ⇒ tail - whi <= 0); ② 会话期 whi 冻结 (会话期无" + NL +
"                    //   活帧) ⇒ 帧尾读 == 帧首读, 没有\"可漏\". (改前计数预测 = 2, 设计件 N1;" + NL +
"                    //   变异臂 M-3 (ring_hi := retx_hi) 必须 > 0 ⇒ 有牙.)" + NL +
"                    if ((((fseq + {20'b0, plen}) - u_dut.whi_r[t_conn]) < 32'h8000_0000) &&" + NL +
"                        (((fseq + {20'b0, plen}) - u_dut.whi_r[t_conn]) != 32'd0)) begin" + NL +
"                        e_ghost = e_ghost + 1;" + NL +
"                        if (e_ghost < 6)" + NL +
"                            $display(\"[FAIL] ghost conn=%0d seq=%h plen=%0d tail=%h whi=%h @%0d\"," + NL +
"                                     t_conn, fseq, plen, fseq + {20'b0, plen}," + NL +
"                                     u_dut.whi_r[t_conn], cyc);" + NL +
"                    end")
EDITS["tb"].append(("T2 e_ghost detect (frame tail)", _gh, _ghn, 1))

_onehot_old = (
"            if ((d_upd_wr_data ? 1 : 0) + (d_upd_wr_ctrl ? 1 : 0) +" + NL +
"                (d_upd_wr_rew ? 1 : 0) > 1) begin" + NL +
"                e_onehot = e_onehot + 1;" + NL +
"                if (e_onehot < 6)" + NL +
"                    $display(\"[FAIL] onehot0 data=%b ctrl=%b rew=%b @%0d\"," + NL +
"                             d_upd_wr_data, d_upd_wr_ctrl, d_upd_wr_rew, cyc);" + NL +
"            end")
_onehot_new = _onehot_old + NL + (
"`ifdef TCP_TX_OVL" + NL +
"            // ⭐ RETXHI-GHOST §8.2-R2: `ring_restore` = OVL 支的**第 4 个** TCB 写源 —— 它已" + NL +
"            //   被上面的 `d_upd_wr_rew` 盖住 (ring_restore ⊆ upd_wr_rew), 这里再加一条**定向**" + NL +
"            //   检查: 它与其它写源 (含同一 mux 里的 replay_jump/svc_rewind) 不得同拍." + NL +
"            if (u_dut.ring_restore && (d_upd_wr_data || d_upd_wr_ctrl ||" + NL +
"                u_dut.replay_jump || u_dut.svc_rewind)) begin" + NL +
"                e_onehot = e_onehot + 1;" + NL +
"                if (e_onehot < 10)" + NL +
"                    $display(\"[FAIL] onehot0 ring_restore collision d=%b c=%b rj=%b sw=%b @%0d\"," + NL +
"                             d_upd_wr_data, d_upd_wr_ctrl, u_dut.replay_jump," + NL +
"                             u_dut.svc_rewind, cyc);" + NL +
"            end" + NL +
"`endif")
EDITS["tb"].append(("T3 e_onehot ring_restore ext", _onehot_old, _onehot_new, 1))

_ringhi_old = "    // ===================== 汇总 =====================" + NL
_ringhi_new = (
"    // ⭐ RETXHI-GHOST §5.4-③: e_ringhi = A4 不变式门 (ring_hi <= retx_hi, 回绕安全)." + NL +
"    //   口径 = **下一拍直读 DUT 的实际锁存值** (不复算表达式 —— 复算的话\"拆钳位\"变异" + NL +
"    //   打不中 = 哑门). 豁免 R4 角: (钳位判假 ∧ FIN 支) 时不计 (设计件 §3.2-(5)/§9.1-R4)." + NL +
"    //   改前它是**空判据** (信号不存在) ⇒ 牙只能挂变异臂 M-5." + NL +
"`ifdef TCP_TX_OVL" + NL +
"    wire        d_svc_tap = u_dut.svc_x;" + NL +
"`else" + NL +
"    wire        d_svc_tap = u_dut.svc;    // 默认支: 同一个会话载载拍的触发信号" + NL +
"`endif" + NL +
"    reg  rh_pend, rh_exempt;" + NL +
"    always @(posedge clk or negedge rst_n) begin" + NL +
"        if (!rst_n) begin" + NL +
"            rh_pend <= 1'b0; rh_exempt <= 1'b0; e_ringhi <= 0;" + NL +
"        end else begin" + NL +
"            if (rh_pend && !rh_exempt) begin" + NL +
"                if ((u_dut.retx_hi - u_dut.ring_hi) >= 32'h8000_0000) begin" + NL +
"                    e_ringhi = e_ringhi + 1;" + NL +
"                    if (e_ringhi < 6)" + NL +
"                        $display(\"[FAIL] ringhi: ring_hi=%h > retx_hi=%h @%0d\"," + NL +
"                                 u_dut.ring_hi, u_dut.retx_hi, cyc);" + NL +
"                end" + NL +
"            end" + NL +
"            rh_pend   <= d_svc_tap;" + NL +
"            rh_exempt <= d_svc_tap && (u_dut.fin_sent_r[u_dut.svc_id] && u_dut.svc_rewind)" + NL +
"                         && !((u_dut.rb_snd_nxt - u_dut.whi_r[u_dut.svc_id]) < 32'h8000_0000);" + NL +
"        end" + NL +
"    end" + NL + NL +
"    // ===================== 汇总 =====================" + NL)
EDITS["tb"].append(("T4 e_ringhi judge (always)", _ringhi_old, _ringhi_new, 1))

_tot_old = (
"                      e_replay_span + e_replay_jump + e_c2_resv +" + NL +
"                      e_ag_block + e_ag_resume;")
_tot_new = (
"                      e_replay_span + e_replay_jump + e_c2_resv +" + NL +
"                      e_ag_block + e_ag_resume + e_ghost + e_ringhi;   // ⭐ RETXHI-GHOST")
EDITS["tb"].append(("T5 tot_red sum +2", _tot_old, _tot_new, 1))

_reds_old = (
"            $display(\"REDS parse=%0d csum=%0d payload=%0d seqcont=%0d seqmono=%0d ctrl=%0d ctrl_to=%0d onehot=%0d pendbusy=%0d replay=%0d stuck=%0d ovf=%0d ackf=%0d\"," + NL +
"                     e_parse, e_csum, e_payload, e_seqcont, e_seqmono, e_ctrl," + NL +
"                     e_ctrl_to, e_onehot, e_pendbusy, e_replay, e_replay_stuck," + NL +
"                     e_ovf, e_ackf);")
_reds_new = (
"            $display(\"REDS parse=%0d csum=%0d payload=%0d seqcont=%0d seqmono=%0d ctrl=%0d ctrl_to=%0d onehot=%0d pendbusy=%0d replay=%0d stuck=%0d ovf=%0d ackf=%0d ghost=%0d ringhi=%0d\"," + NL +
"                     e_parse, e_csum, e_payload, e_seqcont, e_seqmono, e_ctrl," + NL +
"                     e_ctrl_to, e_onehot, e_pendbusy, e_replay, e_replay_stuck," + NL +
"                     e_ovf, e_ackf, e_ghost, e_ringhi);")
EDITS["tb"].append(("T6 REDS display +2", _reds_old, _reds_new, 1))

# =========================================================================
# RTL (OVL 支 + else 支)
EDITS["rtl"] = []

EDITS["rtl"].append(("R1 OVL decls", (
"    reg  [31:0] retx_hi;" + NL),
(
"    reg  [31:0] retx_hi;" + NL +
"    // ⭐ RETXHI-GHOST (P7B_RETXHI_GHOST_DESIGN.md): 环已写高水位 = 该连接\"数据端\" seq." + NL +
"    //   只在**活帧**推进写 (upd_wr_data && !retx_active) 时更新; 重放帧的推进写不算" + NL +
"    //   (它写回的是同一批已写过/待重放的字节, 抬高或**压低**高水位都是错的)." + NL +
"    //   活帧推进写在无会话时严格单调 ⇒ **普通写即可, 不需要 wrap-safe max**." + NL +
"    //   ⚠️ 写者纪律: `whi_r` 的写者集合 = {活帧推进写 (唯一抬高者), `cfg_up` 清位" + NL +
"    //      (唯一压低者)}; 新增任何写者都必须证明它不压低 `whi`, 否则静默关闭重放." + NL +
"    reg  [31:0] whi_r [0:15];" + NL +
"    reg  [31:0] ring_hi;      // 本会话环重放上界 (svc 拍锁存 = whi_r[svc_id])" + NL), 1))

EDITS["rtl"].append(("R2 OVL replay_jump predecl", (
"    wire        replay_jump;" + NL +
"    wire        upd_wr_data = (rx_state == RX_FIN) && (fin_cnt == 3'd0);"),
(
"    wire        replay_jump;" + NL +
"    wire        ring_restore;    // ⭐ RETXHI-GHOST 收尾恢复写 (4 写源 mux 先引用, 定义在 ring 段)" + NL +
"    wire        upd_wr_data = (rx_state == RX_FIN) && (fin_cnt == 3'd0);"), 1))

EDITS["rtl"].append(("R3 OVL write-source mux", (
"    wire        upd_wr_rew  = svc_rewind || replay_jump;" + NL +
"    assign      upd_wr  = upd_wr_data || upd_wr_ctrl || upd_wr_rew;" + NL +
"    assign      upd_id  = upd_wr_data ? f_conn[rx_bank] :" + NL +
"                          (upd_wr_ctrl ? start_id :" + NL +
"                           (replay_jump ? retx_id_r : svc_id));" + NL +
"    assign      upd_sel = 3'd1;" + NL +
"    assign      upd_val = upd_wr_data ? (f_seq[rx_bank] + {20'b0, f_plen[rx_bank]}) :" + NL +
"                          (upd_wr_ctrl ? (rb_snd_nxt + 32'd1) :" + NL +
"                           (replay_jump ? retx_hi : rb_snd_una));"),
(
"    wire        upd_wr_rew  = svc_rewind || replay_jump || ring_restore;" + NL +
"    assign      upd_wr  = upd_wr_data || upd_wr_ctrl || upd_wr_rew;" + NL +
"    // ⭐ RETXHI-GHOST B-7 (阻断级): ring_restore 拍上三个高优先支全 0" + NL +
"    //   (upd_wr_data 需 rx_state==RX_FIN; upd_wr_ctrl 需 start_ack; replay_jump 需" + NL +
"    //   ring_delta!=0) ⇒ 不补就落兜底 svc_id, 而 svc_id_r 由 :1078 每拍自由重算" + NL +
"    //   ⇒ **会把本会话的 retx_hi 写进另一条连接的 snd_nxt**." + NL +
"    assign      upd_id  = upd_wr_data ? f_conn[rx_bank] :" + NL +
"                          (upd_wr_ctrl ? start_id :" + NL +
"                           ((replay_jump || ring_restore) ? retx_id_r : svc_id));" + NL +
"    assign      upd_sel = 3'd1;" + NL +
"    assign      upd_val = upd_wr_data ? (f_seq[rx_bank] + {20'b0, f_plen[rx_bank]}) :" + NL +
"                          (upd_wr_ctrl ? (rb_snd_nxt + 32'd1) :" + NL +
"                           ((replay_jump || ring_restore) ? retx_hi : rb_snd_una));"), 1))

EDITS["rtl"].append(("R4 OVL ring_delta/ring_ovf", (
"    wire [31:0] ring_delta = retx_hi - rb_snd_nxt;" + NL),
(
"    wire [31:0] ring_delta = ring_hi - rb_snd_nxt;   // ⭐ RETXHI-GHOST: 环上界与 ack 上界分离" + NL +
"    // ⭐ RETXHI-GHOST: 环侧越顶 (与 retx_ovf **同型式、不同对象**; retx_ovf 一字不动)" + NL +
"    wire        ring_ovf   = (rb_snd_nxt != ring_hi) &&" + NL +
"                             ((rb_snd_nxt - ring_hi) < 32'h8000_0000);" + NL), 1))

EDITS["rtl"].append(("R5 OVL ring_start !ring_ovf", (
"    wire        ring_start = ring_eval && (ring_delta != 32'd0) && !retx_ovf &&" + NL +
"                             scan_estab && ((replay_left != 4'd0) || replay_full);"),
(
"    wire        ring_start = ring_eval && (ring_delta != 32'd0) && !ring_ovf &&" + NL +
"                             scan_estab && ((replay_left != 4'd0) || replay_full);"), 1))

EDITS["rtl"].append(("R6 OVL replay_jump/ring_restore def", (
"    assign      replay_jump = ring_eval && (ring_delta != 32'd0) && !retx_ovf &&" + NL +
"                              scan_estab && (replay_left == 4'd0) && !replay_full;" + NL +
"    wire        rd_tap = ring_start || (ring_act && (beat_cnt < nbeats));"),
(
"    assign      replay_jump = ring_eval && (ring_delta != 32'd0) && !ring_ovf &&" + NL +
"                              scan_estab && (replay_left == 4'd0) && !replay_full;" + NL +
"    // ⭐ RETXHI-GHOST: 排空拍恢复写 —— 环内数据已发完而 ack 上界还在更高处" + NL +
"    //   (漂移区) ⇒ 把 snd_nxt 恢复到 retx_hi。为什么不恢复不行: 随后的控制帧取" + NL +
"    //   ctrl_seq = rb_snd_nxt (:1264) ⇒ seq 下漂 ⇒ spurious FIN (本文件 :2003-2007 逐字警告)." + NL +
"    //   只增不减: 越顶 (snd_nxt > retx_hi) 时本项恒 0, 不夺 F1 的既有语义." + NL +
"    assign      ring_restore = ring_eval && !ring_ovf && scan_estab &&" + NL +
"                               (ring_delta == 32'd0) &&" + NL +
"                               (rb_snd_nxt != retx_hi) &&" + NL +
"                               ((retx_hi - rb_snd_nxt) < 32'h8000_0000);" + NL +
"    wire        rd_tap = ring_start || (ring_act && (beat_cnt < nbeats));"), 1))

EDITS["rtl"].append(("R7 OVL reset", (
"            retx_active <= 0; retx_id_r <= 0; retx_hi <= 0; scan_id <= 0;" + NL +
"            replay_left <= 4'd0;"),
(
"            retx_active <= 0; retx_id_r <= 0; retx_hi <= 0; scan_id <= 0;" + NL +
"            ring_hi <= 32'd0;    // ⭐ RETXHI-GHOST" + NL +
"            replay_left <= 4'd0;"), 1))

EDITS["rtl"].append(("R8 OVL reset loop", (
"                fin_seq_r[ri] <= 32'd0;" + NL +
"                ps_timer[ri] <= 26'd0;"),
(
"                fin_seq_r[ri] <= 32'd0;" + NL +
"                whi_r[ri]     <= 32'd0;   // ⭐ RETXHI-GHOST: 复位 ⇒ 高水位清零" + NL +
"                ps_timer[ri] <= 26'd0;"), 1))

EDITS["rtl"].append(("R9 OVL cfg_up clear", (
"                fin_sent_r[cfg_up_id]    <= 1'b0;" + NL +
"                rst_sent_r[cfg_up_id]    <= 1'b0;" + NL +
"                fin_retx_pend[cfg_up_id] <= 1'b0;" + NL +
"                epoch[cfg_up_id]        <= 4'd0;"),
(
"                fin_sent_r[cfg_up_id]    <= 1'b0;" + NL +
"                whi_r[cfg_up_id]         <= 32'd0;   // ⭐ RETXHI-GHOST: 新会话重基 ⇒ 高水位清零" + NL +
"                rst_sent_r[cfg_up_id]    <= 1'b0;" + NL +
"                fin_retx_pend[cfg_up_id] <= 1'b0;" + NL +
"                epoch[cfg_up_id]        <= 4'd0;"), 1))

EDITS["rtl"].append(("R10 OVL live-frame whi update", (
"            retx_ovf_p <= retx_ovf && retx_active;" + NL +
"            if (retx_ovf && retx_active && !retx_ovf_p)"),
(
"            retx_ovf_p <= retx_ovf && retx_active;" + NL +
"            // ⭐ RETXHI-GHOST: 数据端高水位 (活帧专有; 与同拍写进 TCB 的推进值同源同拍)" + NL +
"            if (upd_wr_data && !retx_active)" + NL +
"                whi_r[f_conn[rx_bank]] <= f_seq[rx_bank] + {20'b0, f_plen[rx_bank]};" + NL +
"            if (retx_ovf && retx_active && !retx_ovf_p)"), 1))

_c6_old = (
"                    retx_hi <= (fin_sent_r[svc_id] && svc_rewind) ? fin_seq_r[svc_id] :" + NL +
"                               rb_snd_nxt;" + NL +
"                    if (fin_sent_r[svc_id]) fin_retx_pend[svc_id] <= 1'b1;")
_c6_new = (
"                    retx_hi <= (fin_sent_r[svc_id] && svc_rewind) ? fin_seq_r[svc_id] :" + NL +
"                               rb_snd_nxt;" + NL +
"                    // ⭐ RETXHI-GHOST (v2/B-8): 环上界 = 数据端; **仅当 whi ≤ 当前 snd_nxt (回绕安全)**" + NL +
"                    //   才接受 —— 否则退回 rb_snd_nxt (= 今日行为) ⇒ ① ring_hi <= retx_hi 结构性成立" + NL +
"                    //   (非 FIN 支; FIN 支的 R4 角见设计件 §9.1-R4) ② 陈旧高水位 (同槽重连" + NL +
"                    //   窗口) 不再产生 \"巨大 delta ⇒ 伪重放\" (E3-6)." + NL +
"                    ring_hi <= ((rb_snd_nxt - whi_r[svc_id]) < 32'h8000_0000) ?" + NL +
"                               whi_r[svc_id] : rb_snd_nxt;" + NL +
"                    if (fin_sent_r[svc_id]) fin_retx_pend[svc_id] <= 1'b1;")
EDITS["rtl"].append(("R11 OVL session-load clamp", _c6_old, _c6_new, 1))

# ---- else 支 ----
EDITS["rtl"].append(("R12 else decls", (
"    reg  [31:0] retx_hi;                  // 会话重发上界 (svc 拍锁存回卷前 snd_nxt)" + NL),
(
"    reg  [31:0] retx_hi;                  // 会话重发上界 (svc 拍锁存回卷前 snd_nxt)" + NL +
"    // ⭐ RETXHI-GHOST (与 OVL 支同款): 环已写高水位 = 该连接\"数据端\" seq。" + NL +
"    //   本支的活帧推进写 = `upd_wr && is_data_r && !retx_active`" + NL +
"    //   (ring 重放帧也置 is_data_r=1 ⇒ 必须靠 !retx_active 门掉)。" + NL +
"    //   ⚠️ 写者纪律同 OVL 支 (whi 不得被压低, 否则静默关闭重放)。" + NL +
"    reg  [31:0] whi_r [0:15];" + NL +
"    reg  [31:0] ring_hi;      // 本会话环重放上界 (svc 拍锁存 = whi_r[svc_id])" + NL), 1))

EDITS["rtl"].append(("R13 else ring_delta/ring_ovf", (
"    wire [31:0] ring_delta = retx_hi - rb_snd_nxt;   // rb_* 已 mux 到 retx_id_r" + NL),
(
"    wire [31:0] ring_delta = ring_hi - rb_snd_nxt;   // rb_* 已 mux 到 retx_id_r" + NL +
"    // ⭐ RETXHI-GHOST: 环侧越顶 (与 retx_ovf **同型式、不同对象**; retx_ovf 一字不动)" + NL +
"    wire        ring_ovf   = (rb_snd_nxt != ring_hi) &&" + NL +
"                             ((rb_snd_nxt - ring_hi) < 32'h8000_0000);" + NL), 1))

EDITS["rtl"].append(("R14 else ring_start/ring_restore", (
"    wire        ring_start = ring_eval && (ring_delta != 32'd0) && !retx_ovf &&" + NL +
"                             scan_estab;"),
(
"    wire        ring_start = ring_eval && (ring_delta != 32'd0) && !ring_ovf &&" + NL +
"                             scan_estab;" + NL +
"    // ⭐ RETXHI-GHOST: 排空拍恢复写 (本支无 replay_jump 预算退避 ⇒ 这是**新写源**;" + NL +
"    //   本支的排空只靠 ring_delta==0 触发 ⇒ **必须补 !ring_ovf** 以免越顶拍误触发)." + NL +
"    wire        ring_restore = ring_eval && !ring_ovf && scan_estab &&" + NL +
"                               (ring_delta == 32'd0) &&" + NL +
"                               (rb_snd_nxt != retx_hi) &&" + NL +
"                               ((retx_hi - rb_snd_nxt) < 32'h8000_0000);"), 1))

EDITS["rtl"].append(("R15 else write-source mux", (
"    assign upd_wr  = ((state == S_DONE) && (is_data_r || is_syn_r || is_fin_r ||" + NL +
"                      is_rst_r) && m_axis_tvalid && m_axis_tready) || svc_rewind;" + NL +
"    assign upd_id  = svc_rewind ? svc_id : cur_id;" + NL +
"    assign upd_sel = 3'd1;" + NL +
"    assign upd_val = svc_rewind ? rb_snd_una :" + NL +
"                     seq_r + (is_data_r ? {20'b0, plen_r} : 32'd1);"),
(
"    // ⭐ RETXHI-GHOST: 本支的第 3 个 TCB 写源 = ring_restore (OVL 支是在既有 3 源上改条件)" + NL +
"    assign upd_wr  = ((state == S_DONE) && (is_data_r || is_syn_r || is_fin_r ||" + NL +
"                      is_rst_r) && m_axis_tvalid && m_axis_tready) || svc_rewind ||" + NL +
"                     ring_restore;" + NL +
"    assign upd_id  = ring_restore ? retx_id_r : (svc_rewind ? svc_id : cur_id);" + NL +
"    assign upd_sel = 3'd1;" + NL +
"    assign upd_val = ring_restore ? retx_hi :" + NL +
"                     (svc_rewind ? rb_snd_una :" + NL +
"                      seq_r + (is_data_r ? {20'b0, plen_r} : 32'd1));"), 1))

EDITS["rtl"].append(("R16 else reset", (
"            retx_active <= 0; retx_id_r <= 0; retx_hi <= 0; scan_id <= 0;" + NL +
"            rto_pend <= 16'h0; ring_seq <= 0; ring_rem <= 0; tap_seq <= 0;"),
(
"            retx_active <= 0; retx_id_r <= 0; retx_hi <= 0; scan_id <= 0;" + NL +
"            ring_hi <= 32'd0;    // ⭐ RETXHI-GHOST" + NL +
"            rto_pend <= 16'h0; ring_seq <= 0; ring_rem <= 0; tap_seq <= 0;"), 1))

EDITS["rtl"].append(("R17 else reset loop", (
"                fin_seq_r[ri] <= 32'd0;" + NL +
"            end"),
(
"                fin_seq_r[ri] <= 32'd0;" + NL +
"                whi_r[ri]     <= 32'd0;   // ⭐ RETXHI-GHOST: 复位 ⇒ 高水位清零" + NL +
"            end"), 1))

EDITS["rtl"].append(("R18 else cfg_up clear", (
"                fin_sent_r[cfg_up_id]    <= 1'b0;" + NL +
"                rst_sent_r[cfg_up_id]    <= 1'b0;" + NL +
"                fin_retx_pend[cfg_up_id] <= 1'b0;" + NL +
"                // ---- P5c-T1 G4+G6: 跨会话残留清理 (事件脉冲, 坑 9) ----"),
(
"                fin_sent_r[cfg_up_id]    <= 1'b0;" + NL +
"                whi_r[cfg_up_id]         <= 32'd0;   // ⭐ RETXHI-GHOST: 新会话重基 ⇒ 高水位清零" + NL +
"                rst_sent_r[cfg_up_id]    <= 1'b0;" + NL +
"                fin_retx_pend[cfg_up_id] <= 1'b0;" + NL +
"                // ---- P5c-T1 G4+G6: 跨会话残留清理 (事件脉冲, 坑 9) ----"), 1))

EDITS["rtl"].append(("R19 else live-frame whi update", (
"            if (stat_winstall_ev) o_win_at_winstall <= {win_inflight, win_wnd_eff};" + NL +
"            // svc 优先编码寄存器化 (P6 时序, 见 svc_id 声明注释): 每拍刷新,"),
(
"            if (stat_winstall_ev) o_win_at_winstall <= {win_inflight, win_wnd_eff};" + NL +
"            // ⭐ RETXHI-GHOST: 数据端高水位 (仅活帧; ring 重放帧 is_data_r 亦为 1 ⇒ 必须门掉)" + NL +
"            if (upd_wr && is_data_r && !retx_active)" + NL +
"                whi_r[cur_id] <= seq_r + {20'b0, plen_r};" + NL +
"            // svc 优先编码寄存器化 (P6 时序, 见 svc_id 声明注释): 每拍刷新,"), 1))

EDITS["rtl"].append(("R20 else session-load clamp", (
"                        retx_hi <= (fin_sent_r[svc_id] && svc_rewind) ? fin_seq_r[svc_id] :" + NL +
"                                   rb_snd_nxt;" + NL +
"                        if (fin_sent_r[svc_id]) fin_retx_pend[svc_id] <= 1'b1;"),
(
"                        retx_hi <= (fin_sent_r[svc_id] && svc_rewind) ? fin_seq_r[svc_id] :" + NL +
"                                   rb_snd_nxt;" + NL +
"                        // ⭐ RETXHI-GHOST (v2/B-8): 与 OVL 支同款钳位 (wrap-safe)" + NL +
"                        ring_hi <= ((rb_snd_nxt - whi_r[svc_id]) < 32'h8000_0000) ?" + NL +
"                                   whi_r[svc_id] : rb_snd_nxt;" + NL +
"                        if (fin_sent_r[svc_id]) fin_retx_pend[svc_id] <= 1'b1;"), 1))


def apply(path, edits, dry=False):
    b = open(path, "rb").read()
    t = b.decode("utf-8")
    bad = 0
    for (name, old, new, hits) in edits:
        n = t.count(old)
        flag = "OK " if n == hits else "!! "
        if n != hits: bad += 1
        print("%s%-46s hits=%d (declared %d)  OLD[%d B] NEW[%d B]" %
              (flag, name, n, hits, len(old), len(new)))
        if n != hits:
            print("      OLD anchor head: %r" % old[:140])
        if not dry:
            t = t.replace(old, new)
    if bad:
        print("*** %d 处命中数不符 => 不落盘 (fail-closed) ***" % bad)
        return 1
    if dry:
        print("dry-run: 未落盘")
        return 0
    out = t.encode("utf-8")
    open(path, "wb").write(out)
    print("WROTE %s  bytes=%d lines=%d CR=%d CRLF=%d" %
          (os.path.basename(path), len(out), out.count(b"\n"), out.count(b"\r"),
           out.count(b"\r\n")))
    return 0


if __name__ == "__main__":
    which = sys.argv[1] if len(sys.argv) > 1 else "tb"
    dry = "--dry" in sys.argv
    rc = apply(TB if which == "tb" else RTL, EDITS[which], dry)
    sys.exit(rc)
