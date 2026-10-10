# -*- coding: utf-8 -*-
# v6: 把"21 = 21x(+1) 累积" vs "一帧 f_seq+f_plen 一次越顶" 分开
#   (i) 去掉两个按实例清零钩子 (它们是 v5 里 4 族假象的来源) -> 高水位/交付数改为"全跑最大/全跑累计"
#   (ii) 按连接分别计数 upd_wr_ctrl 拍 (SYN/FIN/RST 控制帧) 与 upd_wr_data 拍
#   (iii) 每次 svc_x 无条件打印 (有上限): nxt-off, wrhi-off, nxt_minus_wrhi, 新 retx_hi-off,
#         ctrl[c], data[c], fins/rsts  => 判读: nxt_minus_wrhi == ctrl[c] ? (a)累加 : (b)一帧越顶
src = r"D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_persist_impl\patch_oracle_v5.py"
dst = r"D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_persist_impl\patch_oracle_v6.py"
s = open(src, encoding="utf-8").read()

# (i) 去掉清零钩子
a = '''            // (0) TB 建连/重建连拍 (scfg 写 TCB) => 按实例清零两个每连接计数
            if (scfg_upd_wr) begin
                o_acc[scfg_upd_id]  <= 32'd0;
                o_wrhi[scfg_upd_id] <= 32'd0;
            end
'''
assert s.count(a) == 1
s = s.replace(a, '''            // (0) v6: 不再按实例清零 (那是我 v5 里 4 族假象的来源) => 高水位 = 全跑最大
''', 1)

# (ii) 新声明
a = '''    integer     o_nctrl; reg [15:0] o_finp, o_rstp; reg [31:0] o_gap;'''
b = '''    integer     o_nctrl; reg [15:0] o_finp, o_rstp; reg [31:0] o_gap;
    integer     o_ctc [0:3]; integer o_dtc [0:3]; integer o_svx;'''
assert s.count(a) == 1; s = s.replace(a, b, 1)

a = '''        o_nctrl=0; o_finp=0; o_rstp=0;'''
b = '''        o_nctrl=0; o_finp=0; o_rstp=0;
        for (o_j = 0; o_j < 4; o_j = o_j + 1) begin o_ctc[o_j] = 0; o_dtc[o_j] = 0; end
        o_svx = 0;'''
assert s.count(a) == 1; s = s.replace(a, b, 1)

# (iii) 计数 + 无条件 svc_x 打印 (替换原 SESS-OVER 段)
a = '''            // (2) 逐会话装载拍 (svc_x): retx_hi 的新值 + 与已写高水位之差
            if (u_dut.svc_x) begin
                o_nsess = o_nsess + 1;'''
b = '''            // (2a) v6: 按连接分别计数两类 TCB snd_nxt 写源
            if (u_dut.upd_wr_ctrl) o_ctc[u_dut.upd_id] = o_ctc[u_dut.upd_id] + 1;
            if (u_dut.upd_wr_data) o_dtc[u_dut.upd_id] = o_dtc[u_dut.upd_id] + 1;
            if (u_dut.svc_x) o_svx = o_svx + 1;
            // (2b) 逐会话装载拍无条件明细 (上限 200): 判读用 nxt_minus_wrhi vs ctrl 计数
            if (u_dut.svc_x && (o_det6 < 200)) begin
                o_det6 = o_det6 + 1;
                $display("ORACLE SVC cyc=%0d c=%0d una_off=%0d nxt_off=%0d wrhi_off=%0d nxt_minus_wrhi=%0d new_retxhi_off=%0d ctrl_n=%0d data_n=%0d fins=%b rsts=%b",
                         cyc, u_dut.svc_id, u_dut.rb_snd_una - isn[u_dut.svc_id],
                         u_dut.rb_snd_nxt - isn[u_dut.svc_id],
                         o_wrhi[u_dut.svc_id] - isn[u_dut.svc_id],
                         ((u_dut.rb_snd_nxt - o_wrhi[u_dut.svc_id]) < 32'h8000_0000 ?
                          (u_dut.rb_snd_nxt - o_wrhi[u_dut.svc_id]) : 32'hFFFF_FFFF),
                         ((u_dut.fin_sent_r[u_dut.svc_id] ? u_dut.fin_seq_r[u_dut.svc_id] : u_dut.rb_snd_nxt)
                          - isn[u_dut.svc_id]) - (o_wrhi[u_dut.svc_id] - isn[u_dut.svc_id]),
                         o_ctc[u_dut.svc_id], o_dtc[u_dut.svc_id],
                         u_dut.fin_sent_r[u_dut.svc_id], u_dut.rst_sent_r[u_dut.svc_id]);
            end
            // (2c) 逐会话装载拍 (svc_x): 旧判据保留
            if (u_dut.svc_x) begin
                o_nsess = o_nsess + 1;'''
assert s.count(a) == 1; s = s.replace(a, b, 1)

# (iv) ORACLE3 加 ctrl/data 计数
a = '''                         cyc, o_nupd, o_nupdx, o_exc_max, o_exc_sum, o_nsess, o_sess_over,
                         o_sess_gap_max, o_sess_gap_sum, o_nrs, o_rs_over, o_rs_gap_max, o_nctrl);'''
b = '''                         cyc, o_nupd, o_nupdx, o_exc_max, o_exc_sum, o_nsess, o_sess_over,
                         o_sess_gap_max, o_sess_gap_sum, o_nrs, o_rs_over, o_rs_gap_max, o_nctrl);
                $display("ORACLE4 @%0d ctrl=%0d/%0d/%0d/%0d data=%0d/%0d/%0d/%0d svx=%0d",
                         cyc, o_ctc[0], o_ctc[1], o_ctc[2], o_ctc[3],
                         o_dtc[0], o_dtc[1], o_dtc[2], o_dtc[3], o_svx);'''
assert s.count(a) == 1; s = s.replace(a, b, 1)

open(dst, "w", encoding="utf-8").write(s)
print("v6 script written len=%d" % len(s))
