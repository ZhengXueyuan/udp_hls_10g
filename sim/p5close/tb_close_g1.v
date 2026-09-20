`timescale 1ns/1ps
// =====================================================================
// tb_close_g1 -- P5c-T2 定向证伪门 G1 (W2 缺口的加宽版):
//   FIN 已发出且未被 ACK -> RTO -> svc 回卷 snd_nxt := fin_seq ->
//   **唯一一次** "ring 排空拍" (ring_eval && !ring_start) 被 ack_req 抢走 ->
//   FIN 重推条目进不了 ackq 且 fin_retx_pend 保留 -> retx_active <= 0 ->
//   snd_nxt == snd_una -> RTO 装表条件恒假 -> 再无 svc -> FIN 永不重发.
//
// 机理逐行 (rtl/tcp_tx_frame.v 当前工作树行号):
//   1) FIN 发出: S_DONE 分支 L915-919 -> fin_sent_r[0]=1, fin_seq_r[0]=6000,
//      upd_val (L340) = seq_r+1 => snd_nxt = 6001, snd_una = 6000
//   2) snd_nxt != snd_una => 扫描装 RTO (L726) -> rto_pend -> rto_pend_any
//      (L626) -> svc (L280) 回卷: L658 retx_hi <= fin_seq_r = 6000;
//      L332 svc_rewind=1 -> L339 upd_val = rb_snd_una = 6000 => snd_nxt = 6000
//   3) 回卷后下一拍 = 唯一一次排空拍: L285 ring_delta = 6000-6000 = 0 =>
//      L286 ring_start=0, L283 ring_eval=1
//      L543 fin_repush 组合推 FIN 条目, 但 L706 清 fin_retx_pend 的守卫是
//      (!ackq_full && !ack_req_ok) —— 本拍 ack_req_ok=1 时:
//        (a) L563 ackq_din mux 优先给 ack_req => FIN 条目被吞 (fin_repush=1 无效)
//        (b) L706 守卫不成立 => fin_retx_pend[0] 保持 1
//        (c) L708 retx_active <= 0 (无守卫) => 会话结束
//   4) 此后 snd_nxt == snd_una == 6000 => L726 装表条件恒假 => 再无 rto_pend
//      => 再无 svc => 再无排空拍 (L283 需 retx_active) => fin_repush 永不再评估
//      => FIN 永不重发 (app 侧 fin_sent_r=1 又禁止 fin_push 重排队, L537)
//
// 确定性注入 (不用等概率事件):
//   assign ack_req = ack_req_arm && (u_dut.ring_eval && !u_dut.ring_start);
//   单拍脉冲, 语义 = 端口注释的 "ACK 请求 (tcp_rx 脉冲)"; 位置精确落在唯一一次
//   排空拍 (回卷后 1 拍, 见上) => 100% 命中, 无随机性.
//
// RTO_LIM=2: 仅缩短 RTO 计时器 (L156 参数, 只影响重装值), 触发路径与生产完全
//   一致 (扫描计时 -> rto_pend -> svc). 生产值 48828 x 256 拍 = 12.5M 拍在本
//   单元门里不可行; 判据 (FIN 是否重发) 与计时器长短无关.
//
// 判据 (TL 用法: 修复前必 FAIL / 修复后必 PASS):
//   PASS = 关闭语义可完成 => FIN 帧总数 >= 2 (首发 + 至少一次重发), 且 seq 无漂移
//   FAIL = FIN 帧总数 == 1 => FIN 丢失后关闭永不完成
// 收尾附注 (EPI, 不进判据): 在判据拍后关掉注入, 再用一次 retx_req (dup-ACK 通道)
//   观察挂起位 fin_retx_pend 是否可被外部 svc 触发救回 (证明"唯一机会"丢失后的
//   真实状态: 挂起位仍在, 但 RTO 路径已死).
//
// 例化: tcp_tx_frame + tcb + tcp_cam (rtl/ 不改; 无 mac_tx, m_tready 恒 1)
// =====================================================================
module tb_close_g1;

    reg         clk, rst_n;
    integer     k;                          // 全局拍计数 (诊断/超时)

    // ---- DUT 输入 ----
    reg  [63:0] s_tdata;
    reg  [7:0]  s_tkeep;
    reg         s_tvalid, s_tlast;
    reg  [3:0]  s_tid;
    reg         ack_req_arm;                // TB 侧武装位 (排空拍门控见下)
    reg         ack_inj_fired;              // 单发: 注入只发一次 (脉冲语义)
    wire        ack_req = ack_req_arm && !ack_inj_fired &&
                          (u_dut.ring_eval && !u_dut.ring_start);
    reg  [3:0]  ack_id;
    reg  [31:0] ack_val;
    reg  [15:0] fin_req, rst_req;
    reg         retx_req_i;
    reg  [3:0]  retx_id_i;
    reg         wu_req_i;
    reg  [3:0]  wu_id_i;
    reg  [31:0] wu_val_i;
    reg         cfg_up_i;
    reg  [3:0]  cfg_up_id_i;
    reg         m_tready;
    wire        s_tready;

    // ---- DUT 输出 (帧流 + 统计) ----
    wire [3:0]  rb_id;
    wire [31:0] rb_snd_nxt, rb_rcv_nxt, rb_snd_una;
    wire [15:0] rb_rcv_wnd, rb_snd_wnd;
    wire [3:0]  rb_state;
    wire        win_open;
    wire [15:0] win_inflight, win_wnd_eff;
    wire        dut_upd_wr;
    wire [3:0]  dut_upd_id;
    wire [2:0]  dut_upd_sel;
    wire [31:0] dut_upd_val;
    wire [3:0]  cam_rd_id;
    wire [47:0] cam_rd_dmac;
    wire [31:0] cam_rd_sip, cam_rd_dip;
    wire [15:0] cam_rd_sport, cam_rd_dport;
    wire [63:0] m_tdata;
    wire [7:0]  m_tkeep;
    wire        m_tvalid, m_tlast;
    wire [15:0] o_fin_sent;
    wire        o_retx_active, retx_gnt, wu_gnt;
    wire [31:0] o_retx_hi;
    wire [3:0]  o_retx_id;
    wire [31:0] stat_frames, stat_bytes, stat_ack, stat_ack_drop, stat_eend,
                stat_drop_len, stat_fin, stat_rst, stat_tlast_in, stat_retx;

    // ---- TB 配置写口 (TCB: sel 0=rcv_nxt 1=snd_nxt 2=snd_una 3=rcv_wnd
    //      4=snd_wnd 5=state 6=wscale) ----
    reg         tb_upd_wr;
    reg  [3:0]  tb_upd_id;
    reg  [2:0]  tb_upd_sel;
    reg  [31:0] tb_upd_val;
    wire        tcb_wr  = tb_upd_wr || dut_upd_wr;
    wire [2:0]  tcb_sel = tb_upd_wr ? tb_upd_sel : dut_upd_sel;
    wire [3:0]  tcb_id  = tb_upd_wr ? tb_upd_id  : dut_upd_id;
    wire [31:0] tcb_val = tb_upd_wr ? tb_upd_val : dut_upd_val;

    // ---- CAM 配置口 ----
    reg         cfg_wr;
    reg  [3:0]  cfg_addr;
    reg  [31:0] cfg_sip, cfg_dip;
    reg  [15:0] cfg_sport, cfg_dport;
    reg  [47:0] cfg_dmac;

    // =================================================================
    // DUT
    // =================================================================
    tcp_tx_frame #(.RTO_LIM(2)) u_dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep),
        .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready), .s_axis_tlast(s_tlast),
        .s_axis_tid(s_tid),
        .ack_req(ack_req), .ack_id(ack_id), .ack_val(ack_val), .ack_syn(1'b0),
        .ack_fin(1'b0), .ack_rst(1'b0), .fin_req(fin_req), .rst_req(rst_req),
        .cfg_up(cfg_up_i), .cfg_up_id(cfg_up_id_i),
        .wu_req(wu_req_i), .wu_id(wu_id_i), .wu_val(wu_val_i), .wu_gnt(wu_gnt),
        .o_fin_sent(o_fin_sent), .o_retx_id(o_retx_id),
        .rb_id(rb_id), .rb_snd_nxt(rb_snd_nxt), .rb_rcv_nxt(rb_rcv_nxt),
        .rb_rcv_wnd(rb_rcv_wnd), .rb_snd_una(rb_snd_una), .rb_snd_wnd(rb_snd_wnd),
        .rb_state(rb_state),
        .win_open(win_open), .win_inflight(win_inflight), .win_wnd_eff(win_wnd_eff),
        .retx_req(retx_req_i), .retx_id(retx_id_i), .retx_gnt(retx_gnt),
        .stat_retx(stat_retx),
        .o_retx_hi(o_retx_hi), .o_retx_active(o_retx_active),
        .upd_wr(dut_upd_wr), .upd_id(dut_upd_id), .upd_sel(dut_upd_sel),
        .upd_val(dut_upd_val),
        .cam_rd_id(cam_rd_id), .cam_rd_dmac(cam_rd_dmac), .cam_rd_sip(cam_rd_sip),
        .cam_rd_sport(cam_rd_sport), .cam_rd_dport(cam_rd_dport),
        .cfg_src_mac(48'h000A3501FEC1), .cfg_src_ip(32'hC0A86402),
        .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep),
        .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready), .m_axis_tlast(m_tlast),
        .stat_frames(stat_frames), .stat_bytes(stat_bytes),
        .stat_ack(stat_ack), .stat_ack_drop(stat_ack_drop), .stat_eend(stat_eend),
        .stat_drop_len(stat_drop_len), .stat_fin(stat_fin), .stat_rst(stat_rst),
        .stat_tlast_in(stat_tlast_in)
    );

    tcb u_tcb (
        .clk(clk), .rst_n(rst_n),
        .ra_id(4'd0), .ra_rcv_nxt(), .ra_snd_nxt(), .ra_snd_una(),
        .ra_rcv_wnd(), .ra_snd_wnd(), .ra_state(), .ra_wscale(),
        .rb_id(rb_id), .rb_rcv_nxt(rb_rcv_nxt), .rb_snd_nxt(rb_snd_nxt),
        .rb_snd_una(rb_snd_una), .rb_rcv_wnd(rb_rcv_wnd), .rb_snd_wnd(rb_snd_wnd),
        .rb_state(rb_state),
        .rc_id(4'd0), .rc_rcv_nxt(), .rc_snd_nxt(), .rc_snd_una(),
        .rc_rcv_wnd(), .rc_snd_wnd(), .rc_state(),
        .win_id(rb_id), .win_open(win_open),
        .win_inflight(win_inflight), .win_wnd_eff(win_wnd_eff),
        .upd_wr(tcb_wr), .upd_id(tcb_id), .upd_sel(tcb_sel), .upd_val(tcb_val)
    );

    tcp_cam u_cam (
        .clk(clk), .rst_n(rst_n),
        .cfg_wr(cfg_wr), .cfg_addr(cfg_addr),
        .cfg_sip(cfg_sip), .cfg_dip(cfg_dip),
        .cfg_sport(cfg_sport), .cfg_dport(cfg_dport), .cfg_dmac(cfg_dmac),
        .q_sip(32'h0), .q_dip(32'h0), .q_sport(16'h0), .q_dport(16'h0),
        .q_id(), .q_hit(),
        .rd_id(cam_rd_id), .rd_dmac(cam_rd_dmac), .rd_sip(cam_rd_sip), .rd_dip(cam_rd_dip),
        .rd_sport(cam_rd_sport), .rd_dport(cam_rd_dport)
    );

    always #4 clk = ~clk;      // 125 MHz

    // =================================================================
    // 帧解析 (AXIS 字流; 无 mac_tx => 帧 = 14B eth + 20B ip + 20B tcp [+载荷])
    //   byte 46 = doff, 47 = TCP flags, 38..41 = seq, 42..45 = ack, 48..49 = win
    // =================================================================
    function [7:0] byte_of;
        input [63:0] w;
        input integer i;
        begin
            byte_of = w[63 - 8*i -: 8];
        end
    endfunction

    function [3:0] pop8;
        input [7:0] v;
        integer i;
        reg [3:0] c;
        begin
            c = 4'd0;
            for (i = 0; i < 8; i = i + 1) c = c + {3'b0, v[i]};
            pop8 = c;
        end
    endfunction

    reg  [7:0]  hdr [0:63];         // 本帧前 64 字节快照
    integer     fb;                 // 本帧已输出字节数
    integer     nfrm;               // 总帧数
    integer     nfin;               // FIN 帧数 (flags 0x11)
    integer     nack;               // 纯 ACK 帧数 (flags 0x10)
    integer     nother;             // 其它帧数
    reg  [31:0] fin_seq_first, fin_seq_last;
    integer     fi;
    reg  [31:0] fseq;
    reg  [7:0]  fflags;

    always @(posedge clk) begin
        if (m_tvalid && m_tready) begin
            for (fi = 0; fi < 8; fi = fi + 1) begin
                if (fi < pop8(m_tkeep)) begin
                    if (fb < 64) hdr[fb] = byte_of(m_tdata, fi);
                    fb = fb + 1;
                end
            end
            if (m_tlast) begin
                nfrm = nfrm + 1;
                fflags = hdr[47];
                fseq   = {hdr[38], hdr[39], hdr[40], hdr[41]};
                if (fflags === 8'h11) begin
                    nfin = nfin + 1;
                    if (nfin == 1) fin_seq_first = fseq;
                    fin_seq_last = fseq;
                    $display("[FIN ] k=%0d frm=%0d len=%0d doff=%02h flags=%02h seq=%08h ack=%08h win=%04h",
                             k, nfrm, fb, hdr[46], fflags, fseq,
                             {hdr[42], hdr[43], hdr[44], hdr[45]},
                             {hdr[48], hdr[49]});
                end else if (fflags === 8'h10) begin
                    nack = nack + 1;
                    if (nack <= 6)
                        $display("[ACK ] k=%0d frm=%0d len=%0d flags=%02h seq=%08h ack=%08h",
                                 k, nfrm, fb, fflags, fseq,
                                 {hdr[42], hdr[43], hdr[44], hdr[45]});
                end else begin
                    nother = nother + 1;
                    $display("[OTHR] k=%0d frm=%0d len=%0d flags=%02h seq=%08h",
                             k, nfrm, fb, fflags, fseq);
                end
                fb = 0;
            end
        end
    end

    // ---- 内部信号监视 (门自检: 证明注入确实到达目标路径) ----
    integer nsvc, ndrain, nrto_arm, nrepush, nfinpush, ackq_fin_push;
    reg     rto_prev;
    reg     fin1_stamp_pend;
    integer fin1_stamp_at;
    reg     svc1_stamp_pend;
    integer svc1_stamp_at;

    // svc 拍 (retx_hi/svc_rewind 是组合量, 本拍即最终值)
    always @(posedge clk) begin
        if (rst_n && u_dut.svc) begin
            nsvc = nsvc + 1;
            $display("[SVC ] k=%0d svc=1 svc_id=%0d rewind=%b blocked=%b epoch=%0d | retx_hi(本拍)=%08h rb_snd_nxt=%08h rb_snd_una=%08h fin_sent_r[0]=%b",
                     k, u_dut.svc_id, u_dut.svc_rewind, u_dut.blocked, u_dut.epoch[0],
                     u_dut.retx_hi, rb_snd_nxt, rb_snd_una, u_dut.fin_sent_r[0]);
            svc1_stamp_pend = 1;
            svc1_stamp_at   = k + 1;
        end
    end

    // svc 后 1 拍: 打印锁存后的会话状态 (retx_hi/active 已更新)
    always @(posedge clk) begin
        if (rst_n && svc1_stamp_pend && k >= svc1_stamp_at) begin
            svc1_stamp_pend = 0;
            $display("[SVC+] k=%0d session latched: retx_hi=%08h retx_id=%0d retx_active=%b fin_retx_pend[0]=%b | snd_nxt=%08h snd_una=%08h ring_delta=%08h",
                     k, u_dut.retx_hi, u_dut.retx_id_r, u_dut.retx_active,
                     u_dut.fin_retx_pend[0], u_tcb.snd_nxt_r[0], u_tcb.snd_una_r[0],
                     u_dut.ring_delta);
        end
    end

    // ring 排空拍 (唯一一次重推机会)
    always @(posedge clk) begin
        if (rst_n && u_dut.ring_eval && !u_dut.ring_start) begin
            ndrain = ndrain + 1;
            if (ack_req) ack_inj_fired <= 1'b1;     // 单发锁存 (脉冲只发一次)
            $display("[DRAN] k=%0d drain#%0d: ring_eval=1 ring_start=0 delta=%08h fin_retx_pend[0]=%b | ack_req=%b ack_req_ok=%b ackq_full=%b fin_repush=%b => ackq_din=%s",
                     k, ndrain, u_dut.ring_delta, u_dut.fin_retx_pend[0],
                     ack_req, u_dut.ack_req_ok, u_dut.ackq_full, u_dut.fin_repush,
                     u_dut.ack_req_ok ? "ACK(STEAL)" :
                     (u_dut.fin_repush ? "FIN(ok)" : "NONE"));
        end
    end

    // fin_repush 组合脉冲 / fin_push / 真写进 ackq 的 FIN 条目
    always @(posedge clk) if (rst_n && u_dut.fin_repush) nrepush = nrepush + 1;
    always @(posedge clk) if (rst_n && u_dut.fin_push)  nfinpush = nfinpush + 1;
    always @(posedge clk) if (rst_n && u_dut.ackq_wr && u_dut.ackq_din[33])
        ackq_fin_push = ackq_fin_push + 1;

    // RTO 装表 (rto_pend[0] 上升沿)
    always @(posedge clk) begin
        rto_prev <= u_dut.rto_pend[0];
        if (rst_n && u_dut.rto_pend[0] && !rto_prev) begin
            nrto_arm = nrto_arm + 1;
            $display("[RTO ] k=%0d rto_pend[0] set (arm #%0d) rb_snd_nxt=%08h rb_snd_una=%08h",
                     k, nrto_arm, rb_snd_nxt, rb_snd_una);
        end
    end

    // FIN 首发后 6 拍打印 DUT 记账 (S_DONE 已落定)
    always @(posedge clk) begin
        if (rst_n && fin1_stamp_pend && nfin >= 1 && k >= fin1_stamp_at) begin
            fin1_stamp_pend = 0;
            $display("[FIN1] k=%0d FIN bookkeeping: fin_sent_r[0]=%b fin_seq_r[0]=%08h snd_nxt=%08h snd_una=%08h (snd_nxt=fin+1)",
                     k, u_dut.fin_sent_r[0], u_dut.fin_seq_r[0],
                     u_tcb.snd_nxt_r[0], u_tcb.snd_una_r[0]);
        end
    end

    // TB 写冲突告警 (TB cfg 与 DUT upd_wr 同拍 => DUT 写会丢)
    always @(posedge clk) if (rst_n && tb_upd_wr && dut_upd_wr)
        $display("[WARN] k=%0d TCB write conflict: TB cfg and DUT upd_wr same cycle (DUT write lost)", k);

    // ackq 占用里 FIN 条目数 (FWFT FIFO: 按 rptr..wptr 扫描 mem[..][33])
    integer aq_i, aq_cnt, aq_fin_occ;
    task ackq_peek;
        begin
            aq_cnt = u_dut.u_ackq.wptr - u_dut.u_ackq.rptr;
            aq_fin_occ = 0;
            for (aq_i = 0; aq_i < 32; aq_i = aq_i + 1) begin
                if (aq_i < aq_cnt) begin
                    if (u_dut.u_ackq.mem[(u_dut.u_ackq.rptr[4:0] + aq_i[4:0]) & 5'h1F][33])
                        aq_fin_occ = aq_fin_occ + 1;
                end
            end
        end
    endtask

    // =================================================================
    // 主激励 FSM
    // =================================================================
    localparam [2:0] PH_RST = 0, PH_CFG = 1, PH_FINREQ = 2, PH_WAITFIN = 3,
                     PH_WAITSVC = 4, PH_POST = 5, PH_EPI = 6, PH_END = 7;

    reg  [2:0]  ph;
    reg  [5:0]  cphase;
    integer     t_ph;               // 相位进入拍
    integer     post_until;
    reg  [1:0]  esub;               // EPI 子状态
    integer     fin_at_verdict, nsvc_at_verdict, ndrain_at_verdict,
                nrepush_at_verdict, ackqfin_at_verdict, nrto_at_verdict;
    reg  [31:0] sndnxt_at_verdict, snduna_at_verdict, retxhi_at_verdict;
    reg         pend_at_verdict, act_at_verdict;
    reg         verdict_fail;

    initial begin
        clk = 0; rst_n = 0;
        k = 0; nfrm = 0; nfin = 0; nack = 0; nother = 0; fb = 0;
        nsvc = 0; ndrain = 0; nrto_arm = 0; nrepush = 0; nfinpush = 0;
        ackq_fin_push = 0; rto_prev = 0;
        fin1_stamp_pend = 0; fin1_stamp_at = 0;
        svc1_stamp_pend = 0; svc1_stamp_at = 0;
        fin_seq_first = 32'h0; fin_seq_last = 32'h0;
        verdict_fail = 0;
    end

    always @(posedge clk) begin
        k <= k + 1;
        if (!rst_n) begin
            ph <= PH_RST; cphase <= 0; t_ph <= 0; post_until <= 0; esub <= 0;
            s_tdata <= 0; s_tkeep <= 0; s_tvalid <= 0; s_tlast <= 0; s_tid <= 0;
            ack_req_arm <= 0; ack_inj_fired <= 0; ack_id <= 0; ack_val <= 0;
            fin_req <= 16'h0; rst_req <= 16'h0;
            retx_req_i <= 0; retx_id_i <= 0;
            wu_req_i <= 0; wu_id_i <= 0; wu_val_i <= 0;
            cfg_up_i <= 0; cfg_up_id_i <= 0;
            m_tready <= 1'b1;
            tb_upd_wr <= 0; tb_upd_id <= 0; tb_upd_sel <= 0; tb_upd_val <= 0;
            cfg_wr <= 0; cfg_addr <= 0; cfg_sip <= 0; cfg_dip <= 0;
            cfg_sport <= 0; cfg_dport <= 0; cfg_dmac <= 0;
        end else begin
            case (ph)
            // ---- 配置阶段: CAM0 (拍 2..3) + TCB0 6 字段 (拍 6..11) ----
            PH_RST: begin
                ph <= PH_CFG; cphase <= 0; t_ph <= k;
            end
            PH_CFG: begin
                cfg_wr <= (cphase >= 2 && cphase <= 3);
                cfg_addr <= cphase - 2;
                case (cphase)
                    6'd2: begin
                        cfg_sip <= 32'h0A000001; cfg_dip <= 32'hC0A86402;
                        cfg_sport <= 16'h3039; cfg_dport <= 16'h1F90;
                        cfg_dmac <= 48'h112233445566;
                    end
                    6'd3: begin
                        cfg_sip <= 32'h0A000009; cfg_dip <= 32'hC0A86409;
                        cfg_sport <= 16'hD431; cfg_dport <= 16'h1F91;
                        cfg_dmac <= 48'hAABBCCDDEE01;
                    end
                    default: ;
                endcase
                // TCB0: rcv_nxt=1000 snd_nxt=6000 snd_una=6000 (无在飞!)
                //       rcv_wnd=0x2000 snd_wnd=0x2000 state=1(ESTAB)
                tb_upd_wr  <= (cphase >= 6 && cphase <= 11);
                tb_upd_id  <= 4'd0;
                tb_upd_sel <= (cphase - 6);
                case (cphase - 6)
                    6'd0: tb_upd_val <= 32'd1000;
                    6'd1: tb_upd_val <= 32'd6000;   // snd_nxt
                    6'd2: tb_upd_val <= 32'd6000;   // snd_una (== snd_nxt: 无在飞)
                    6'd3: tb_upd_val <= 32'h2000;
                    6'd4: tb_upd_val <= 32'h2000;
                    6'd5: tb_upd_val <= 32'd1;      // ESTAB
                    default: tb_upd_val <= 32'd0;
                endcase
                cphase <= cphase + 1;
                if (cphase == 6'd40) begin
                    cfg_wr <= 0; tb_upd_wr <= 0;
                    ph <= PH_FINREQ; t_ph <= k;
                    $display("[CFG ] k=%0d cfg done: RTO_LIM=%0d TCB0 snd_nxt=%08h snd_una=%08h state=%0d snd_wnd=%04h",
                             k, u_dut.RTO_LIM, u_tcb.snd_nxt_r[0], u_tcb.snd_una_r[0],
                             u_tcb.state_r[0], u_tcb.snd_wnd_r[0]);
                end
            end
            // ---- 请求 FIN (fin_req[0] 电平) ----
            PH_FINREQ: begin
                fin_req[0] <= 1'b1;
                ph <= PH_WAITFIN; t_ph <= k;
                $display("[FINR] k=%0d fin_req[0]=1 (opt scan -> FIN queue)", k);
            end
            PH_WAITFIN: begin
                if (nfin >= 1) begin
                    if (fin1_stamp_at == 0) begin
                        fin1_stamp_at = k + 6;      // S_DONE 落定后再打印
                        fin1_stamp_pend = 1;
                    end
                    ack_req_arm <= 1'b1;
                    ph <= PH_WAITSVC; t_ph <= k;
                    $display("[ARMS] k=%0d injection armed: ack_req = arm && (ring_eval && !ring_start)", k);
                end else if (k - t_ph > 20000) begin
                    $display("GATE tb_close_g1: INCONCLUSIVE (FIN first-send timeout, nfin=%0d)", nfin);
                    $finish;
                end
            end
            // ---- 等 RTO -> svc (回卷) 与随后的排空拍 (注入在此拍命中) ----
            PH_WAITSVC: begin
                if (nsvc >= 1) begin
                    post_until <= k + 8000;      // 观察窗 (>= 15 个 RTO 轮次)
                    ph <= PH_POST; t_ph <= k;
                end else if (k - t_ph > 20000) begin
                    $display("GATE tb_close_g1: INCONCLUSIVE (no RTO svc, nsvc=%0d nrto=%0d)",
                             nsvc, nrto_arm);
                    $finish;
                end
            end
            // ---- 观察窗: 记录判据快照 ----
            PH_POST: begin
                if (k >= post_until) begin
                    fin_at_verdict    = nfin;
                    nsvc_at_verdict   = nsvc;
                    ndrain_at_verdict = ndrain;
                    nrepush_at_verdict= nrepush;
                    ackqfin_at_verdict= ackq_fin_push;
                    nrto_at_verdict   = nrto_arm;
                    sndnxt_at_verdict = u_tcb.snd_nxt_r[0];
                    snduna_at_verdict = u_tcb.snd_una_r[0];
                    retxhi_at_verdict = u_dut.retx_hi;
                    pend_at_verdict   = u_dut.fin_retx_pend[0];
                    act_at_verdict    = u_dut.retx_active;
                    ackq_peek;
                    $display("-------- G1 VERDICT (RTO_LIM=2) --------");
                    $display("G1 FIN frames      = %0d  (stat_fin=%0d) first_seq=%08h last_seq=%08h",
                             fin_at_verdict, stat_fin, fin_seq_first, fin_seq_last);
                    $display("G1 svc sessions    = %0d  (stat_retx=%0d) ring_drain_beats=%0d",
                             nsvc_at_verdict, stat_retx, ndrain_at_verdict);
                    $display("G1 ackq FIN entries= pushed %0d (fin_push=%0d fin_repush_pulse=%0d) occupancy_now=%0d",
                             ackqfin_at_verdict, nfinpush, nrepush_at_verdict, aq_fin_occ);
                    $display("G1 RTO re-arm      = %0d total | retx_active=%b fin_retx_pend[0]=%b",
                             nrto_at_verdict, act_at_verdict, pend_at_verdict);
                    $display("G1 final state     = snd_nxt=%08h snd_una=%08h retx_hi=%08h o_fin_sent=%04h",
                             sndnxt_at_verdict, snduna_at_verdict, retxhi_at_verdict, o_fin_sent);
                    $display("G1 frame stats     = total %0d (ack %0d / fin %0d / other %0d) stat_frames=%0d",
                             nfrm, nack, nfin, nother, stat_frames);
                    $display("G1 injection       = fired=%b (single ack_req pulse on drain beat; 1 drain beat total => 100%% hit)",
                             ack_inj_fired);
                    if (fin_at_verdict >= 2 && fin_seq_last == fin_seq_first) begin
                        verdict_fail = 0;
                        $display("GATE tb_close_g1: PASS  (FIN retransmitted %0d frames, seq stable)",
                                 fin_at_verdict);
                    end else begin
                        verdict_fail = 1;
                        $display("GATE tb_close_g1: FAIL  (FIN frames=%0d, close never completes -- G1 reproduced on current RTL: single drain beat stolen by ack_req, fin_retx_pend stuck=1)",
                                 fin_at_verdict);
                    end
                    ack_req_arm <= 1'b0;             // EPI 不再注入, 观察挂起位可否被外部 svc 救回
                    ph <= PH_EPI; t_ph <= k; esub <= 0;
                end
            end
            // ---- EPI: 一次 retx_req (dup-ACK 通道) 观察挂起位能否被救回 ----
            PH_EPI: begin
                if (esub == 2'd0) begin
                    retx_req_i <= 1'b1; retx_id_i <= 4'd0;
                    esub <= 2'd1;
                    $display("[EPI ] k=%0d issue one retx_req (dup-ACK channel) to probe stranded fin_retx_pend", k);
                end else if (esub == 2'd1) begin
                    if (retx_gnt) begin
                        retx_req_i <= 1'b0;
                        esub <= 2'd2; t_ph <= k;
                        $display("[EPI ] k=%0d retx_gnt=1 (svc served)", k);
                    end else if (k - t_ph > 1000) begin
                        retx_req_i <= 1'b0; esub <= 2'd2; t_ph <= k;
                    end
                end else if (esub == 2'd2) begin
                    if (k - t_ph > 400) begin
                        $display("[EPI ] k=%0d tail: FIN frames=%0d (verdict already printed above) fin_retx_pend[0]=%b snd_nxt=%08h snd_una=%08h",
                                 k, nfin, u_dut.fin_retx_pend[0],
                                 u_tcb.snd_nxt_r[0], u_tcb.snd_una_r[0]);
                        ph <= PH_END;
                    end
                end
            end
            PH_END: begin
                $display("GATE tb_close_g1: DONE (verdict_fail=%0d)", verdict_fail);
                $finish;
            end
            default: ph <= PH_RST;
            endcase
        end
    end

    initial begin
        #200 rst_n = 1;
    end

endmodule
