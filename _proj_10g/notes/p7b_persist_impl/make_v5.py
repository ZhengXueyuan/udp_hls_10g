# -*- coding: utf-8 -*-
# 从 patch_oracle_v4.py 生成 patch_oracle_v5.py: 追加"机制级"追踪
#   (1) 逐条 *落地* 的 snd_nxt 更新 + excess 分解
#   (2) 逐会话装载拍 (svc_x) 的 retx_hi 来源
#   (3) 逐 ring_start 的 retx_hi - 已写高水位
#   (4) 每连接计数在 TB 的 scfg 建连拍复位 (分实例)
src = r"D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_persist_impl\patch_oracle_v4.py"
dst = r"D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_persist_impl\patch_oracle_v5.py"
s = open(src, encoding="utf-8").read()

# ---- 1) 新声明 ----
a = '''    integer     o_rdn, o_rdahead, o_det4;'''
b = '''    integer     o_rdn, o_rdahead, o_det4;
    // ---- v5: 机制级 ----
    integer     o_nupd, o_nupdx, o_exc_max, o_exc_sum, o_det5;
    integer     o_nsess, o_sess_over, o_sess_gap_max, o_sess_gap_sum, o_det6;
    integer     o_nrs, o_rs_over, o_rs_gap_max, o_det7;
    integer     o_nctrl; reg [15:0] o_finp, o_rstp; reg [31:0] o_gap;'''
assert s.count(a) == 1; s = s.replace(a, b, 1)

# ---- 2) 初始化 ----
a = '''        o_rdn=0; o_rdahead=0; o_det4=0; o_rdoff=0; o_wroff=0;'''
b = '''        o_rdn=0; o_rdahead=0; o_det4=0; o_rdoff=0; o_wroff=0;
        o_nupd=0; o_nupdx=0; o_exc_max=0; o_exc_sum=0; o_det5=0;
        o_nsess=0; o_sess_over=0; o_sess_gap_max=0; o_sess_gap_sum=0; o_det6=0;
        o_nrs=0; o_rs_over=0; o_rs_gap_max=0; o_det7=0;
        o_nctrl=0; o_finp=0; o_rstp=0;'''
assert s.count(a) == 1; s = s.replace(a, b, 1)

# ---- 3) 机制级代码块: 插在"周期快照"之前 ----
a = '''            // ---------- 周期快照 ----------'''
b = '''            // ==================== v5: 机制级追踪 ====================
            // (1) 逐条 *落地* 的 snd_nxt 更新 (经 TB 自己的 tcb 实例口)
            if (u_tcb.upd_wr && (u_tcb.upd_sel == 3'd1)) begin
                o_nupd = o_nupd + 1;
                if (((u_tcb.upd_val - isn[u_tcb.upd_id]) - o_acc[u_tcb.upd_id]) > 32'd1) begin
                    o_nupdx = o_nupdx + 1;
                    o_exc_sum = o_exc_sum +
                        ((u_tcb.upd_val - isn[u_tcb.upd_id]) - o_acc[u_tcb.upd_id] - 32'd1);
                    if (((u_tcb.upd_val - isn[u_tcb.upd_id]) - o_acc[u_tcb.upd_id] - 32'd1)
                        > o_exc_max)
                        o_exc_max = (u_tcb.upd_val - isn[u_tcb.upd_id]) - o_acc[u_tcb.upd_id] - 32'd1;
                    if (o_det5 < 60) begin o_det5 = o_det5 + 1;
                        $display("ORACLE UPD-NXT cyc=%0d c=%0d val_off=%0d acc=%0d excess=%0d ract=%b rid=%0d rs=%b rleft=%0d rfull=%b rjmp=%b svcw=%b sd=%b ovf=%b fins=%b rsts=%b",
                                 cyc, u_tcb.upd_id, u_tcb.upd_val - isn[u_tcb.upd_id], o_acc[u_tcb.upd_id],
                                 ((u_tcb.upd_val - isn[u_tcb.upd_id]) - o_acc[u_tcb.upd_id] - 32'd1),
                                 u_dut.retx_active, u_dut.retx_id_r, u_dut.ring_start,
                                 u_dut.replay_left, u_dut.replay_full, u_dut.replay_jump,
                                 u_dut.svc_rewind, u_dut.start_data, u_dut.retx_ovf,
                                 u_dut.fin_sent_r[u_tcb.upd_id], u_dut.rst_sent_r[u_tcb.upd_id]); end
                end
            end
            // (2) 逐会话装载拍 (svc_x): retx_hi 的新值 + 与已写高水位之差
            if (u_dut.svc_x) begin
                o_nsess = o_nsess + 1;
                o_gap = (u_dut.retx_hi - isn[u_dut.svc_id]) - (o_wrhi[u_dut.svc_id] - isn[u_dut.svc_id]);
                if ((((u_dut.retx_hi - isn[u_dut.svc_id]) -
                      (o_wrhi[u_dut.svc_id] - isn[u_dut.svc_id])) != 32'd0) &&
                    (((u_dut.retx_hi - isn[u_dut.svc_id]) -
                      (o_wrhi[u_dut.svc_id] - isn[u_dut.svc_id])) < 32'h8000_0000)) begin
                    o_sess_over = o_sess_over + 1;
                    o_sess_gap_sum = o_sess_gap_sum + o_gap;
                    if (o_gap > o_sess_gap_max) o_sess_gap_max = o_gap;
                    if (o_det6 < 40) begin o_det6 = o_det6 + 1;
                        $display("ORACLE SESS-OVER cyc=%0d c=%0d una_off=%0d nxt_off=%0d retxhi_off=%0d wrhi_off=%0d gap=%0d rew=%b fins=%b finseq_off=%0d",
                                 cyc, u_dut.svc_id, u_dut.rb_snd_una - isn[u_dut.svc_id],
                                 u_dut.rb_snd_nxt - isn[u_dut.svc_id],
                                 u_dut.retx_hi - isn[u_dut.svc_id],
                                 o_wrhi[u_dut.svc_id] - isn[u_dut.svc_id], o_gap, u_dut.svc_rewind,
                                 u_dut.fin_sent_r[u_dut.svc_id], u_dut.fin_seq_r[u_dut.svc_id] - isn[u_dut.svc_id]); end
                end
            end
            // (3) 逐 ring_start: retx_hi - 已写高水位
            if (u_dut.ring_start) begin
                o_nrs = o_nrs + 1;
                if ((((u_dut.retx_hi - isn[u_dut.retx_id_r]) -
                      (o_wrhi[u_dut.retx_id_r] - isn[u_dut.retx_id_r])) != 32'd0) &&
                    (((u_dut.retx_hi - isn[u_dut.retx_id_r]) -
                      (o_wrhi[u_dut.retx_id_r] - isn[u_dut.retx_id_r])) < 32'h8000_0000)) begin
                    o_rs_over = o_rs_over + 1;
                    if (((u_dut.retx_hi - isn[u_dut.retx_id_r]) -
                         (o_wrhi[u_dut.retx_id_r] - isn[u_dut.retx_id_r])) > o_rs_gap_max)
                        o_rs_gap_max = (u_dut.retx_hi - isn[u_dut.retx_id_r]) -
                                       (o_wrhi[u_dut.retx_id_r] - isn[u_dut.retx_id_r]);
                    if (o_det7 < 40) begin o_det7 = o_det7 + 1;
                        $display("ORACLE RS-OVER cyc=%0d c=%0d nxt_off=%0d retxhi_off=%0d wrhi_off=%0d gap=%0d delta=%0d rleft=%0d rfull=%b",
                                 cyc, u_dut.retx_id_r, u_dut.rb_snd_nxt - isn[u_dut.retx_id_r],
                                 u_dut.retx_hi - isn[u_dut.retx_id_r],
                                 o_wrhi[u_dut.retx_id_r] - isn[u_dut.retx_id_r],
                                 (u_dut.retx_hi - isn[u_dut.retx_id_r]) -
                                 (o_wrhi[u_dut.retx_id_r] - isn[u_dut.retx_id_r]),
                                 u_dut.retx_hi - u_dut.rb_snd_nxt,
                                 u_dut.replay_left, u_dut.replay_full);
                        end
                end
            end
            // (0) TB 建连/重建连拍 (scfg 写 TCB) => 按实例清零两个每连接计数
            if (scfg_upd_wr) begin
                o_acc[scfg_upd_id]  <= 32'd0;
                o_wrhi[scfg_upd_id] <= 32'd0;
            end
            // (4) 控制帧 (+1 预留族) 计数: FIN/RST 发出沿
            o_finp = {o_finp[14:0], (u_dut.fin_sent_r[0] | u_dut.fin_sent_r[1] |
                                     u_dut.fin_sent_r[2] | u_dut.fin_sent_r[3])};
            if ((u_dut.fin_sent_r[0] | u_dut.fin_sent_r[1] | u_dut.fin_sent_r[2] |
                 u_dut.fin_sent_r[3]) && !o_finp[15]) o_nctrl = o_nctrl + 1;
            o_rstp = {o_rstp[14:0], (u_dut.rst_sent_r[0] | u_dut.rst_sent_r[1] |
                                     u_dut.rst_sent_r[2] | u_dut.rst_sent_r[3])};
            if ((u_dut.rst_sent_r[0] | u_dut.rst_sent_r[1] | u_dut.rst_sent_r[2] |
                 u_dut.rst_sent_r[3]) && !o_rstp[15]) o_nctrl = o_nctrl + 1;
            // ---------- 周期快照 ----------'''
assert s.count(a) == 1; s = s.replace(a, b, 1)

# ---- 4) 快照加 v5 列 ----
a = '''                         u_tcb.snd_nxt_r[2] - isn[2], u_tcb.snd_nxt_r[3] - isn[3]);'''
b = '''                         u_tcb.snd_nxt_r[2] - isn[2], u_tcb.snd_nxt_r[3] - isn[3]);
                $display("ORACLE3 @%0d nupd=%0d nupdx=%0d exc_max=%0d exc_sum=%0d nsess=%0d sess_over=%0d sess_gap_max=%0d sess_gap_sum=%0d nrs=%0d rs_over=%0d rs_gap_max=%0d nctrl=%0d",
                         cyc, o_nupd, o_nupdx, o_exc_max, o_exc_sum, o_nsess, o_sess_over,
                         o_sess_gap_max, o_sess_gap_sum, o_nrs, o_rs_over, o_rs_gap_max, o_nctrl);'''
assert s.count(a) == 1; s = s.replace(a, b, 1)


open(dst, "w", encoding="utf-8").write(s)
print("v5 script written, len=%d" % len(s))
