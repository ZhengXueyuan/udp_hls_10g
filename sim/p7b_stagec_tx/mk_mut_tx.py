#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mk_mut_tx.py -- 从现役 rtl/tcp_tx_frame.v 生成负对照变异件 (每个 = 1 处改动).
   每个变异在源文件上做**声明过的**替换, 命中数不足/超出 ⇒ 硬失败 (不是"静默没打上").
   输出到 sim/p7b_stagec_tx/mut/*.v
"""
import io
import os
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SRC = os.path.join(ROOT, "rtl", "tcp_tx_frame.v")
OUT = os.path.join(HERE, "mut")

src = io.open(SRC, encoding="utf-8", newline="").read()

MUTS = []   # (name, [(old, new, hits)], note)


def add(name, subs, note):
    MUTS.append((name, subs, note))


# ---- S0a: 推进写值少一帧 (OVL 分支; 与 M-C3 "推进写搬回 S_DONE" 同族) ----
add("mut_s0a", [(
    "assign      upd_val = upd_wr_data ? (f_seq[rx_bank] + {20'b0, f_plen[rx_bank]}) :",
    "assign      upd_val = upd_wr_data ? (f_seq[rx_bank] + 32'd0) :",
    1)], "OVL: 数据推进写不推进 (seq 复用)")

# ---- S0b: 默认 (串行) 分支同族变异: 数据段推进写不推进 ----
add("mut_s0b", [(
    "    assign upd_val = svc_rewind ? rb_snd_una :\n"
    "                     seq_r + (is_data_r ? {20'b0, plen_r} : 32'd1);",
    "    assign upd_val = svc_rewind ? rb_snd_una :\n"
    "                     seq_r + (is_data_r ? 32'd0 : 32'd1);",
    1)], "默认分支: 数据推进写不推进 (S0 灵敏度证明用)")

# ---- M-C1: 撞写口 (upd_wr_ctrl 与 upd_wr_data 同拍) ----
add("mut_c1", [(
    "    wire        upd_wr_ctrl = start_ack && (aq_syn | aq_fin | aq_rst);",
    "    wire        upd_wr_ctrl = upd_wr_data || (start_ack && (aq_syn | aq_fin | aq_rst));",
    1)], "M-C1 同拍撞写口 => $onehot0 红")

# ---- M-C2: 预留写寄存 8 拍 (形 A: (wr,val,id) 三件套一起延) ----
add("mut_c2", [
    ("    wire        upd_wr_ctrl = start_ack && (aq_syn | aq_fin | aq_rst);",
     "    // M-C2 形 A: (wr,val,id) 三件套一起寄存 8 拍\n"
     "    reg [3:0]  mcd; reg [3:0] mcd_id; reg [31:0] mcd_val;\n"
     "    always @(posedge clk or negedge rst_n) begin\n"
     "        if (!rst_n) begin mcd <= 4'd0; mcd_id <= 4'd0; mcd_val <= 32'd0; end\n"
     "        else if (start_ack && (aq_syn | aq_fin | aq_rst)) begin\n"
     "            mcd <= 4'd8; mcd_id <= start_id; mcd_val <= rb_snd_nxt + 32'd1;\n"
     "        end else if (mcd != 4'd0) mcd <= mcd - 4'd1;\n"
     "    end\n"
     "    wire        upd_wr_ctrl = (mcd == 4'd1);", 1),
    ("    assign      upd_id  = upd_wr_data ? f_conn[rx_bank] :\n"
     "                          (upd_wr_ctrl ? start_id : svc_id);",
     "    assign      upd_id  = upd_wr_data ? f_conn[rx_bank] :\n"
     "                          (upd_wr_ctrl ? mcd_id : svc_id);", 1),
    ("    assign      upd_val = upd_wr_data ? (f_seq[rx_bank] + {20'b0, f_plen[rx_bank]}) :\n"
     "                          (upd_wr_ctrl ? (rb_snd_nxt + 32'd1) : rb_snd_una);",
     "    assign      upd_val = upd_wr_data ? (f_seq[rx_bank] + {20'b0, f_plen[rx_bank]}) :\n"
     "                          (upd_wr_ctrl ? mcd_val : rb_snd_una);", 1),
], "M-C2 预留写滞后 8 拍 => J_seq_mono / J_seq_cont 红")

# ---- M-C3: 乒乓退化单 bank (接收门再加 TX 空闲) ----
add("mut_c3", [(
    "          && !fifo_full && !bank_rdy[rx_bank];",
    "          && !fifo_full && (bank_rdy == 2'b00) && (tx_state == T_IDLE);",
    1)], "M-C3 退化单 bank => 帧周期/TX 引擎拍数红")

# ---- M-C6: 撤回卷门 (!ctrl_adv_inflight) ----
add("mut_c6", [(
    "    wire        svc_x     = svc && !ctrl_adv_inflight;    // 回卷门 (§1.4(4))",
    "    wire        svc_x     = svc;",
    1)], "M-C6 撤回卷门 => FIN 预留被当 ring 数据重放 => J_seq_cont 红")

# ---- M-C7: 撤 start_ack 的 !ctrl_slot_busy ----
add("mut_c7", [(
    "    wire        start_ack = rx_idle && ack_pend_r && !ackq_empty && !rx_flush &&\n"
    "                            !ctrl_slot_busy;          // ← 槽跨拍独占门 (C7/C8)",
    "    wire        start_ack = rx_idle && ack_pend_r && !ackq_empty && !rx_flush;",
    1)], "M-C7 撤槽独占 => issued > transmitted => J6 红")

# ---- M-C8: 撤 start_ack 的 rx_idle ----
add("mut_c8", [(
    "    wire        start_ack = rx_idle && ack_pend_r && !ackq_empty && !rx_flush &&\n"
    "                            !ctrl_slot_busy;          // ← 槽跨拍独占门 (C7/C8)",
    "    wire        start_ack = ack_pend_r && !ackq_empty && !rx_flush &&\n"
    "                            !ctrl_slot_busy;",
    1)], "M-C8 撤 rx_idle => 控制帧在收帧期装载 (混拼)")

# ---- M-C9: 仲裁键改回 ctrl_slot_busy (两处帧边界判定) ----
add("mut_c9", [(
    "if (ctrl_tx_pend) begin",
    "if (ctrl_slot_busy) begin",
    2)], "M-C9 仲裁键=busy => 控制帧 T_DONE 自选 => transmitted > issued => J6 红")

# ---- M-F1: 撤回 F1 修复 (两分支同时回退 => "越顶下溢"重现) ----
add("mut_f1", [(
    """    wire        ring_start = ring_eval && (ring_delta != 32'd0) && !retx_ovf &&
                             scan_estab;""",
    """    wire        ring_start = ring_eval && (ring_delta != 32'd0) &&
                             scan_estab;""",
    2)], "M-F1 撒!retx_ovf => delta 下溢当起重放 => 洪水 (两分支)")

# ---- M-C4: 会话自锁 (排空支不清 retx_active) ----
add("mut_c4", [(
    """                        end else begin
                            retx_active <= 1'b0;
                        end""",
    """                        end else begin
                            retx_active <= retx_active;   // M-C4 自锁
                        end""",
    1)], "M-C4 排空支不清会话 => retx 会话永不终止 => stuck 红")

os.makedirs(OUT, exist_ok=True)
fail = 0
for name, subs, note in MUTS:
    t = src
    for old, new, hits in subs:
        n = t.count(old)
        if n != hits:
            print("MUTFAIL %s: pattern hits=%d expect=%d" % (name, n, hits))
            fail += 1
            continue
        t = t.replace(old, new)
    p = os.path.join(OUT, name + ".v")
    io.open(p, "w", encoding="utf-8", newline="").write(t)
    print("WROTE %-10s %s" % (name, note))
if fail:
    print("MUTGEN FAIL %d" % fail)
    sys.exit(1)
print("MUTGEN OK (%d mutants)" % len(MUTS))
