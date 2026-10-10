# -*- coding: utf-8 -*-
# 单一真值源: 生成 PS_RINGORACLE 探针块并插入 tb/tb_tcp_tx_ovl.v 末尾 endmodule 前 (CRLF 纪律)。
TB = r"D:\repo\XCKU5PMini\udp_hls_10g\tb\tb_tcp_tx_ovl.v"
b = open(TB, "rb").read()
assert b.count(b"PS_RINGORACLE") == 0, "already patched"

BLOCK = r'''`ifdef PS_RINGORACLE
    // ============ PS 环写/读一致性 oracle (P7B-PERSIST Q1 定位; 纯只读层级探针) ============
    // 判读 (事先定死, 全部逐字节/逐拍):
    //   o_e_val  > 0 : 写进环的字节 != 按 **DUT 自己给的 32 位写游标** 推出的字节 ("当场就是错值")
    //   o_e_seq  > 0 : DUT 写游标 != 源侧 live 游标 (qlive+cur_pos)              => 地址归属错
    //   o_e_data > 0 : DUT 写的数据 != TB 同一拍呈现的数据                      => DUT 搬数侧
    //   o_e_conn > 0 : 写拍 w_conn != 源当前连接                                => 连接归属错
    //   ctl_src / ctl_miss : 结构性恒 0 (探针自检; 非 0 说明网名/口径错)
    //   AHEAD    : 某连接 snd_nxt(流偏移) > TB 已交付字节数 (正差>1 = 越过 SYN 的 +1)
    //   RD-AHEAD : 重放读的 32 位游标 > 该连接"已写高水位" (读到本圈未写的地址)
    //   RD-BAD   : 读回的具体值(RD-AHEAD 计数外的) != 影子环同址值
    reg  [31:0] o_acc     [0:15];
    reg  [7:0]  o_ring    [0:3][0:65535];
    integer     o_src_b, o_src_ok, o_wr_b, o_wr_cyc;
    integer     o_e_conn, o_e_seq, o_e_data, o_e_src, o_e_miss, o_e_val;
    integer     o_rd_seen, o_rd_bad, o_det, o_det2, o_pd;
    integer     o_ahead, o_ahead_cyc, o_rdx, o_det3, o_hold;
    integer     o_rdn, o_rdahead, o_det4;
    // ---- v5: 机制级 ----
    integer     o_nupd, o_nupdx, o_exc_max, o_exc_sum, o_det5;
    integer     o_nsess, o_sess_over, o_sess_gap_max, o_sess_gap_sum, o_det6;
    integer     o_nrs, o_rs_over, o_rs_gap_max, o_det7;
    integer     o_nctrl; reg [15:0] o_finp, o_rstp; reg [31:0] o_gap;
    reg  [31:0] o_ahead_was, o_diff, o_wrhi [0:3];
    reg  [31:0] o_rdoff, o_wroff;
    reg         o_rd1, o_rd2;
    reg         o_pw; reg [3:0] o_pwc, o_pwn; reg [15:0] o_pws; reg [63:0] o_pwd;
    reg  [3:0]  o_rc1, o_rc2;
    reg  [15:0] o_rs1, o_rs2;
    integer     o_j, o_k;

    wire        o_acc_cyc = s_tvalid && s_tready;
    wire [31:0] o_q0      = o_acc[cur_c];
    wire [31:0] o_qlive   = u_tcb.snd_nxt_r[cur_c] - isn[cur_c];
    wire [31:0] o_qexp    = o_qlive + {20'b0, cur_pos};
    wire        o_wr_en   = u_dut.u_retx.wr_en;
    wire [3:0]  o_wc      = u_dut.u_retx.w_conn;
    wire [15:0] o_ws      = u_dut.u_retx.w_seq;
    wire [3:0]  o_wn      = u_dut.u_retx.w_n;
    wire [63:0] o_wd      = u_dut.u_retx.w_data;
    wire [31:0] o_wseq32  = u_dut.w_tap_seq;
    wire [31:0] o_woff    = (o_wseq32 - isn[o_wc]);

    initial begin
        for (o_j = 0; o_j < 16; o_j = o_j + 1) o_acc[o_j] = 32'd0;
        for (o_j = 0; o_j < 4; o_j = o_j + 1) begin
            o_wrhi[o_j] = 32'd0;
            for (o_k = 0; o_k < 65536; o_k = o_k + 1) o_ring[o_j][o_k] = 8'h00;
        end
        o_src_b=0; o_src_ok=0; o_wr_b=0; o_wr_cyc=0;
        o_e_conn=0; o_e_seq=0; o_e_data=0; o_e_src=0; o_e_miss=0; o_e_val=0;
        o_rd_seen=0; o_rd_bad=0; o_det=0; o_det2=0; o_pd=0;
        o_ahead=0; o_ahead_cyc=0; o_rdx=0; o_det3=0; o_hold=0; o_ahead_was=0; o_diff=0;
        o_rdn=0; o_rdahead=0; o_det4=0; o_rdoff=0; o_wroff=0;
        o_nupd=0; o_nupdx=0; o_exc_max=0; o_exc_sum=0; o_det5=0;
        o_nsess=0; o_sess_over=0; o_sess_gap_max=0; o_sess_gap_sum=0; o_det6=0;
        o_nrs=0; o_rs_over=0; o_rs_gap_max=0; o_det7=0;
        o_nctrl=0; o_finp=0; o_rstp=0;
        o_rd1=0; o_rd2=0; o_rc1=0; o_rc2=0; o_rs1=0; o_rs2=0;
        o_pw=0; o_pwc=0; o_pwn=0; o_pws=0; o_pwd=0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_rd1 <= 1'b0; o_rd2 <= 1'b0;
        end else begin
            // ---------- 写侧 ----------
            if (o_wr_en) begin
                o_wr_cyc = o_wr_cyc + 1;
                o_wr_b   = o_wr_b + o_wn;
                if ((o_wseq32 + {28'b0, o_wn}) > o_wrhi[o_wc])
                    o_wrhi[o_wc] <= o_wseq32 + {28'b0, o_wn};
                if (o_wc !== cur_c) begin
                    o_e_conn = o_e_conn + 1;
                    if (o_det < 10) begin o_det=o_det+1;
                        $display("ORACLE WR-CONN cyc=%0d src_c=%0d w_c=%0d w_seq=%h n=%0d acc=%0d",
                                 cyc, cur_c, o_wc, o_ws, o_wn, o_q0); end
                end
                if ((o_woff !== o_qexp) && (o_wc === cur_c)) begin
                    o_e_seq = o_e_seq + 1;
                    if (o_det < 10) begin o_det=o_det+1;
                        $display("ORACLE WR-SEQ cyc=%0d c=%0d wseq16=%h off=%0d 源live=%0d cur_pos=%0d 源exp=%0d 偏差=%0d acc=%0d sd=%b tapsq=%h",
                                  cyc, o_wc, o_ws, o_woff, o_qlive, cur_pos, o_qexp,
                                  (o_woff - o_qexp), o_q0, u_dut.start_data, u_dut.tap_seq); end
                end
                for (o_j = 0; o_j < 8; o_j = o_j + 1) begin
                    if (o_j < {4'b0, o_wn}) begin
                        if (o_wd[63-8*o_j -: 8] !== s_tdata[63-8*o_j -: 8]) begin
                            o_e_data = o_e_data + 1;
                            if (o_det < 10) begin o_det=o_det+1;
                                $display("ORACLE WR-DATA cyc=%0d c=%0d lane=%0d dut=%h src=%h",
                                         cyc, o_wc, o_j, o_wd[63-8*o_j -: 8], s_tdata[63-8*o_j -: 8]); end
                        end
                        if (o_wd[63-8*o_j -: 8] !== fb(CBASE*o_wc + o_woff + o_j)) begin
                            o_e_val = o_e_val + 1;
                            if (o_det < 10) begin o_det=o_det+1;
                                $display("ORACLE WR-VAL cyc=%0d c=%0d lane=%0d off=%0d dut=%h exp(addr)=%h src=%h qlive=%0d cur_pos=%0d acc=%0d sd=%b",
                                         cyc, o_wc, o_j, o_woff, o_wd[63-8*o_j -: 8],
                                         fb(CBASE*o_wc + o_woff + o_j),
                                         s_tdata[63-8*o_j -: 8], o_qlive, cur_pos, o_q0, u_dut.start_data); end
                        end
                    end
                end
            end else if (o_acc_cyc && (s_tkeep != 8'h00) && !u_dut.len_bad) begin
                o_e_miss = o_e_miss + 1;
                if (o_det < 10) begin o_det=o_det+1;
                    $display("ORACLE WR-MISS cyc=%0d c=%0d n=%0d w_seq=%h acc=%0d len_bad=%b rxs=%0d rf=%b",
                             cyc, cur_c, pop8(s_tkeep), o_ws, o_q0, u_dut.len_bad,
                             u_dut.rx_state, u_dut.recv_first); end
            end
            // ---------- 读侧决定性测量: 重放读的 32 位游标 vs 已写高水位 ----------
            if (u_dut.u_retx.rd_en && !u_dut.ps_rd) begin
                o_rdn = o_rdn + 1;
                o_rdoff = u_dut.ring_seq - isn[u_dut.u_retx.r_conn];
                o_wroff = o_wrhi[u_dut.u_retx.r_conn] - isn[u_dut.u_retx.r_conn];
                if ((cyc >= 340000) && (cyc <= 360000)) begin
                    if (o_det4 < 3000) begin o_det4 = o_det4 + 1;
                        $display("ORACLE RDZOOM cyc=%0d c=%0d rseq16=%h ring_seq=%0d wr_hi=%0d 差=%0d retxhi=%0d sndnxt=%0d sd=%b act=%b",
                                 cyc, u_dut.u_retx.r_conn, u_dut.u_retx.r_seq, o_rdoff, o_wroff,
                                 (o_rdoff - o_wroff), u_dut.retx_hi - isn[u_dut.u_retx.r_conn],
                                 u_tcb.snd_nxt_r[u_dut.u_retx.r_conn] - isn[u_dut.u_retx.r_conn],
                                 u_dut.start_data, u_dut.retx_active); end
                end
                if ((o_rdoff > (o_wroff + 32'd1)) && ((o_rdoff - o_wroff) < 32'h8000_0000)) begin
                    o_rdahead = o_rdahead + 1;
                    if (o_det4 < 400) begin o_det4 = o_det4 + 1;
                        $display("ORACLE RD-AHEAD cyc=%0d c=%0d rseq16=%h ring_seq=%0d wr_hi=%0d 差=%0d retxhi=%0d sndnxt=%0d sd=%b act=%b",
                                 cyc, u_dut.u_retx.r_conn, u_dut.u_retx.r_seq, o_rdoff, o_wroff,
                                 (o_rdoff - o_wroff), u_dut.retx_hi - isn[u_dut.u_retx.r_conn],
                                 u_tcb.snd_nxt_r[u_dut.u_retx.r_conn] - isn[u_dut.u_retx.r_conn],
                                 u_dut.start_data, u_dut.retx_active); end
                end
            end
            // 影子环按 DUT 实际写口更新 (延后 1 拍 = retx_ram 写口寄存对齐)
            if (o_pw)
                for (o_j = 0; o_j < 8; o_j = o_j + 1)
                    if (o_j < {4'b0, o_pwn})
                        o_ring[o_pwc][o_pws + o_j] <= o_pwd[63-8*o_j -: 8];
            o_pw <= o_wr_en; o_pwc <= o_wc; o_pws <= o_ws; o_pwn <= o_wn; o_pwd <= o_wd;
            // ---------- AHEAD: snd_nxt 越过已交付字节数 (持续 >=8 拍才算) ----------
            if ((o_qlive - o_q0) != 32'd0) begin
                o_diff = o_qlive - o_q0;
                if (o_diff < 32'h8000_0000) begin
                    o_hold = o_hold + 1;
                    if (o_diff > o_ahead_was) o_ahead_was = o_diff;
                    if (o_hold == 8) begin
                        o_ahead = o_ahead + 1;
                        if (o_ahead_cyc == 0) o_ahead_cyc = cyc;
                        if (o_det3 < 24) begin o_det3 = o_det3 + 1;
                            $display("ORACLE AHEAD cyc=%0d c=%0d sndnxt_off=%0d delivered=%0d 差=%0d retxhi=%0d act=%b rs=%0d",
                                     cyc, cur_c, o_qlive, o_q0, o_diff, u_dut.retx_hi,
                                     u_dut.retx_active, u_dut.ring_seq); end
                    end
                end else begin
                    o_hold = 0;
                end
            end else begin
                o_hold = 0;
            end
            // ---------- 源侧 (探针自检: 结构性恒 0) ----------
            if (o_acc_cyc) begin
                o_src_b = o_src_b + pop8(s_tkeep);
                if (!u_dut.len_bad) o_src_ok = o_src_ok + pop8(s_tkeep);
                for (o_j = 0; o_j < 8; o_j = o_j + 1)
                    if ((o_j < {4'b0, pop8(s_tkeep)}) &&
                        (s_tdata[63-8*o_j -: 8] !== fb(CBASE*cur_c + o_qexp + o_j))) begin
                        o_e_src = o_e_src + 1;
                        if (o_det < 10) begin o_det=o_det+1;
                            $display("ORACLE SRC-CTL cyc=%0d c=%0d lane=%0d src=%h exp(live)=%h qlive=%0d cur_pos=%0d acc=%0d",
                                     cyc, cur_c, o_j, s_tdata[63-8*o_j -: 8],
                                     fb(CBASE*cur_c + o_qexp + o_j), o_qlive, cur_pos, o_q0); end
                    end
                o_acc[cur_c] <= o_acc[cur_c] + {28'b0, pop8(s_tkeep)};
            end
            // ---------- 读侧: r_data (rd_en 后 2 拍) vs 影子环 ----------
            o_rd1 <= u_dut.u_retx.rd_en;
            o_rc1 <= u_dut.u_retx.r_conn; o_rs1 <= u_dut.u_retx.r_seq;
            o_rd2 <= o_rd1; o_rc2 <= o_rc1; o_rs2 <= o_rs1;
            if (o_rd2) begin
                o_rd_seen = o_rd_seen + 1;
                for (o_j = 0; o_j < 8; o_j = o_j + 1)
                    if (u_dut.u_retx.r_data[63-8*o_j -: 8] !== o_ring[o_rc2][o_rs2 + o_j]) begin
                        if (^u_dut.u_retx.r_data[63-8*o_j -: 8] === 1'bx) begin
                            o_rdx = o_rdx + 1;
                        end else begin
                            o_rd_bad = o_rd_bad + 1;
                            if (o_det2 < 8) begin o_det2=o_det2+1;
                                $display("ORACLE RD-BAD cyc=%0d c=%0d rseq=%h lane=%0d dut=%h shadow=%h rseq32=%0d",
                                         cyc, o_rc2, o_rs2, o_j,
                                         u_dut.u_retx.r_data[63-8*o_j -: 8],
                                         o_ring[o_rc2][o_rs2 + o_j], u_dut.ring_seq); end
                        end
                    end
            end
            // ==================== v5: 机制级追踪 ====================
            // (1) 逐条 *落地* 的 snd_nxt 更新 (经 TB 自己的 tcb 实例口)
            if (u_tcb.upd_wr && (u_tcb.upd_sel == 3'd1)) begin
                o_nupd = o_nupd + 1;
                if ((((u_tcb.upd_val - isn[u_tcb.upd_id]) - o_acc[u_tcb.upd_id]) > 32'd1) &&
                    (((u_tcb.upd_val - isn[u_tcb.upd_id]) - o_acc[u_tcb.upd_id]) < 32'h8000_0000)) begin
                    o_nupdx = o_nupdx + 1;
                    o_exc_sum = o_exc_sum +
                        ((u_tcb.upd_val - isn[u_tcb.upd_id]) - o_acc[u_tcb.upd_id] - 32'd1);
                    if ((((u_tcb.upd_val - isn[u_tcb.upd_id]) - o_acc[u_tcb.upd_id] - 32'd1)
                         > o_exc_max) &&
                        (((u_tcb.upd_val - isn[u_tcb.upd_id]) - o_acc[u_tcb.upd_id] - 32'd1)
                         < 32'h8000_0000))
                        o_exc_max = (u_tcb.upd_val - isn[u_tcb.upd_id]) - o_acc[u_tcb.upd_id] - 32'd1;
                    if (o_det5 < 60) begin o_det5 = o_det5 + 1;
                        $display("ORACLE UPD-NXT cyc=%0d c=%0d val_off=%0d acc=%0d excess=%0d src=%b/%b/%b sel_tx=%b sel_rx=%b scfg_gnt=%b bank=%0d fseq_off=%0d fplen=%0d txv=%h rxv=%h scv=%h landed=%h ract=%b rid=%0d rs=%b rleft=%0d rfull=%b rjmp=%b svcw=%b sd=%b ovf=%b fins=%b rsts=%b",
                                 cyc, u_tcb.upd_id, u_tcb.upd_val - isn[u_tcb.upd_id], o_acc[u_tcb.upd_id],
                                 ((u_tcb.upd_val - isn[u_tcb.upd_id]) - o_acc[u_tcb.upd_id] - 32'd1),
                                 u_dut.upd_wr_data, u_dut.upd_wr_ctrl, u_dut.upd_wr_rew,
                                 sel_tx, sel_rx, scfg_gnt,
                                 u_dut.rx_bank,
                                 u_dut.f_seq[u_dut.rx_bank] - isn[u_tcb.upd_id],
                                 u_dut.f_plen[u_dut.rx_bank],
                                 tx_upd_val, rx_upd_val, scfg_upd_val, u_tcb.upd_val,
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
                    if (o_gap < 32'h8000_0000) o_sess_gap_sum = o_sess_gap_sum + o_gap;
                    if ((o_gap > o_sess_gap_max) && (o_gap < 32'h8000_0000)) o_sess_gap_max = o_gap;
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
                    if ((((u_dut.retx_hi - isn[u_dut.retx_id_r]) -
                          (o_wrhi[u_dut.retx_id_r] - isn[u_dut.retx_id_r])) > o_rs_gap_max) &&
                        (((u_dut.retx_hi - isn[u_dut.retx_id_r]) -
                          (o_wrhi[u_dut.retx_id_r] - isn[u_dut.retx_id_r])) < 32'h8000_0000))
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
            // (5) 窗口追踪: 330k-360k 的每次会话装载 / 重放帧启动, 无条件打三元组
            if (((cyc >= 330000) && (cyc <= 360000)) && (u_dut.svc_x || u_dut.ring_start)) begin
                $display("ORACLE WTRK cyc=%0d kind=%s c=%0d una_off=%0d nxt_off=%0d retxhi_off=%0d wrhi_off=%0d nxt_minus_wrhi=%0d retxhi_minus_wrhi=%0d fins=%b rstss=%b svcw=%b rjmp=%b rleft=%0d",
                         cyc, u_dut.svc_x ? "SV" : "RS", u_dut.svc_x ? u_dut.svc_id : u_dut.retx_id_r,
                         (u_dut.svc_x ? u_dut.rb_snd_una : u_dut.rb_snd_una) - isn[(u_dut.svc_x ? u_dut.svc_id : u_dut.retx_id_r)],
                         u_dut.rb_snd_nxt - isn[(u_dut.svc_x ? u_dut.svc_id : u_dut.retx_id_r)],
                         u_dut.retx_hi   - isn[(u_dut.svc_x ? u_dut.svc_id : u_dut.retx_id_r)],
                         o_wrhi[(u_dut.svc_x ? u_dut.svc_id : u_dut.retx_id_r)] - isn[(u_dut.svc_x ? u_dut.svc_id : u_dut.retx_id_r)],
                         (u_dut.rb_snd_nxt - o_wrhi[(u_dut.svc_x ? u_dut.svc_id : u_dut.retx_id_r)]),
                         (u_dut.retx_hi   - o_wrhi[(u_dut.svc_x ? u_dut.svc_id : u_dut.retx_id_r)]),
                         u_dut.fin_sent_r[(u_dut.svc_x ? u_dut.svc_id : u_dut.retx_id_r)],
                         u_dut.rst_sent_r[(u_dut.svc_x ? u_dut.svc_id : u_dut.retx_id_r)],
                         u_dut.svc_rewind, u_dut.replay_jump, u_dut.replay_left);
            end
            // ---------- 周期快照 ----------
            if ((cyc % 25000) == 0 && (o_pd < 24) && (cyc != 0)) begin
                o_pd = o_pd + 1;
                $display("ORACLE @%0d src_b=%0d src_ok=%0d wr_b=%0d wr_cyc=%0d e_conn=%0d e_seq=%0d e_val=%0d e_data=%0d ctl_src=%0d ctl_miss=%0d rd=%0d rdbad=%0d",
                         cyc, o_src_b, o_src_ok, o_wr_b, o_wr_cyc,
                         o_e_conn, o_e_seq, o_e_val, o_e_data, o_e_src, o_e_miss, o_rd_seen, o_rd_bad);
                $display("ORACLE2 @%0d ahead_cyc=%0d ahead_max=%0d rdn=%0d rdahead=%0d rdx=%0d wrhi=%0d/%0d/%0d/%0d acc=%0d/%0d/%0d/%0d nxt=%0d/%0d/%0d/%0d",
                         cyc, o_ahead_cyc, o_ahead_was, o_rdn, o_rdahead, o_rdx,
                         o_wrhi[0] - isn[0], o_wrhi[1] - isn[1], o_wrhi[2] - isn[2], o_wrhi[3] - isn[3],
                         o_acc[0], o_acc[1], o_acc[2], o_acc[3],
                         u_tcb.snd_nxt_r[0] - isn[0], u_tcb.snd_nxt_r[1] - isn[1],
                         u_tcb.snd_nxt_r[2] - isn[2], u_tcb.snd_nxt_r[3] - isn[3]);
                $display("ORACLE3 @%0d nupd=%0d nupdx=%0d exc_max=%0d exc_sum=%0d nsess=%0d sess_over=%0d sess_gap_max=%0d sess_gap_sum=%0d nrs=%0d rs_over=%0d rs_gap_max=%0d nctrl=%0d",
                         cyc, o_nupd, o_nupdx, o_exc_max, o_exc_sum, o_nsess, o_sess_over,
                         o_sess_gap_max, o_sess_gap_sum, o_nrs, o_rs_over, o_rs_gap_max, o_nctrl);
            end
        end
    end
`endif
'''

idx = b.rfind(b"endmodule")
assert idx > 0
block = BLOCK.replace("\n", "\r\n").encode("utf-8")
if not block.endswith(b"\r\n"):
    block += b"\r\n"
out = b[:idx] + block + b[idx:]
open(TB, "wb").write(out)
n = out.count(b"\n"); cr = out.count(b"\r\n")
print("lines=%d crlf=%d lone_lf=%d bytes=%d" % (n, cr, n - cr, len(out)))
