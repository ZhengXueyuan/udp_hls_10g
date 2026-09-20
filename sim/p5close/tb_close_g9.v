`timescale 1ns/1ps
// =====================================================================
// tb_close_g9 -- P5c-T2 定向证伪门 G9 (新发现, 最高危):
//   blocked (epoch[slot]==15: 连续 16 次 svc 无 snd_una 进展) 时 svc_rewind=0
//   不回卷; 而 FIN 在飞时 snd_nxt = fin_seq+1 > retx_hi = fin_seq
//   => ring_delta = retx_hi - rb_snd_nxt 下溢成 0xFFFFFFFF => ring_start=1
//   => 以 1460B/帧洪水式重放 ring 内容 (直到 snd_nxt 追平: delta/1460
//      ~= 294 万帧 = ~4.29 GB 陈旧载荷, seq 从 FIN 的 seq 起).
//
// 机理逐行 (rtl/tcp_tx_frame.v 当前工作树行号):
//   L331 blocked = (epoch[svc_id] >= 4'd15)
//   L332 svc_rewind = svc && (rb_snd_nxt != rb_snd_una) && !blocked
//   L644-664 svc 拍: epoch 无进展 +1 (L647-651, 封顶 15);
//        L658 retx_hi <= fin_sent_r ? fin_seq_r : rb_snd_nxt
//             => FIN 在飞时 retx_hi = fin_seq = snd_nxt - 1 (!!)
//        L661 retx_active <= 1 (blocked 也照设)
//   L285 ring_delta = retx_hi - rb_snd_nxt  (无回卷 => snd_nxt 还在 fin_seq+1)
//        = fin_seq - (fin_seq+1) = 0xFFFFFFFF (32 位下溢)
//   L286 ring_start = ring_eval && (ring_delta != 0) => 1
//   L455 plen_preset = (ring_delta >= 1460) ? 1460 : ... => 1460 (下溢值巨大)
//   => 每帧 1460B, S_DONE 把 snd_nxt += 1460, 直到 snd_nxt == retx_hi
//      => 需要 (2^32)/1460 ~= 2941758 帧 (约 4.29 GB 垃圾流量, ~线速 1G)
//
// 真实流程复现 (无任何层次强制/写值):
//   1) 连发 45 帧 x 1460B 活数据 (每帧后 TB 写 snd_una := snd_nxt 模拟对端 ACK)
//      => ring 环形缓冲 (64KB/conn) 被整圈写过 => 环内全部是"已 ACK 过的旧数据"
//   2) close: fin_req[0]=1 => FIN 首发 (seq = fin_seq), snd_nxt = fin_seq+1
//   3) 对端死 (不再 ACK): 16 次重传会话 (每次 svc 无 snd_una 进展 -> epoch++)
//      每次会话正常回卷 + 重推 FIN (fin_retx_pend 路径) => FIN 重发, 无洪水
//   4) 第 17 次 svc: epoch==15 => blocked => svc_rewind=0 不回卷
//      => ring_delta 下溢 => 洪水开始
//   svc 触发用 retx_req (dup-ACK 快速重传通道, 端口语义: 电平保持至 retx_gnt);
//   RTO 路径同一份 svc 代码 (L280/L644), 但生产 RTO_LIM=48828 (12.5M 拍) 在
//   本门里跑不动 => RTO_LIM 保持生产值, 并借它保证 push 阶段绝无早期 RTO 干扰
//   (需 12.5M 拍, 本门总长 ~45k 拍, 结构性不可能).
//
// 判据 (TL 用法: 修复前必 FAIL / 修复后必 PASS):
//   PASS = FIN 之后不再出现 1460B 数据帧 (无下溢重放)
//   FAIL = FIN 之后出现 >=1 帧 1460B 数据帧 (ring_delta 下溢洪水)
// 载荷不变式 (证"重放的是旧数据"): 活帧与重放帧的载荷字节 j 必须等于
//   (seq + j)[7:0] (ring 内容 = pat(seq), 8 位运算 => 65536 周期 => 环内恒定)
// =====================================================================
module tb_close_g9;

    reg         clk, rst_n;
    integer     k;

    // ---- 数据帧参数 ----
    localparam integer PLEN     = 1460;      // 每帧载荷字节 (app 契约上限)
    localparam integer NUM_FRM  = 45;        // 45 x 1460 = 65700 > 65536 (整圈)
    localparam integer NPULSE   = 17;        // 16 次正常重传 + 第 17 次 blocked
    localparam integer FLOOD_CLK= 12000;     // 洪水观察窗 (拍)
    localparam [31:0]  SEQ0     = 32'd6000;  // 起始 snd_nxt == snd_una

    // ---- DUT 输入 ----
    reg  [63:0] s_tdata;
    reg  [7:0]  s_tkeep;
    reg         s_tvalid, s_tlast;
    reg  [3:0]  s_tid;
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
    wire        ack_req = 1'b0;              // 本门不用 ACK 通道 (避免与 G1 路径混)

    // ---- DUT 输出 ----
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

    reg         tb_upd_wr;
    reg  [3:0]  tb_upd_id;
    reg  [2:0]  tb_upd_sel;
    reg  [31:0] tb_upd_val;
    wire        tcb_wr  = tb_upd_wr || dut_upd_wr;
    wire [2:0]  tcb_sel = tb_upd_wr ? tb_upd_sel : dut_upd_sel;
    wire [3:0]  tcb_id  = tb_upd_wr ? tb_upd_id  : dut_upd_id;
    wire [31:0] tcb_val = tb_upd_wr ? tb_upd_val : dut_upd_val;

    reg         cfg_wr;
    reg  [3:0]  cfg_addr;
    reg  [31:0] cfg_sip, cfg_dip;
    reg  [15:0] cfg_sport, cfg_dport;
    reg  [47:0] cfg_dmac;

    // =================================================================
    // DUT (RTO_LIM = 生产默认值: push 阶段结构性不可能早期触发)
    // =================================================================
    tcp_tx_frame u_dut (
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
    // 载荷图案: pat(seq) = seq[7:0]  (8 位运算 => 65536 周期 => ring 内恒定)
    // =================================================================
    function [63:0] pat_part;
        input [31:0] seq;
        input integer n;
        integer j;
        reg [63:0] w;
        begin
            w = 64'd0;
            for (j = 0; j < n; j = j + 1) w[63 - 8*j -: 8] = seq[7:0] + j[7:0];
            pat_part = w;
        end
    endfunction

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

    // =================================================================
    // 帧解析 (AXIS 字流; m_tready 恒 1, 无 mac_tx)
    //   帧 = 14B eth + 20B ip + 20B tcp [+ 载荷]; 数据帧 flags=0x18, len=1514
    // =================================================================
    reg  [7:0]  hdr [0:63];
    integer     fb;
    integer     nfrm, nfin, nack, nother, nd1460;
    integer     nd1460_at_fin;              // FIN 之前的数据帧数 (活帧)
    reg  [31:0] fin_seq_first, fin_seq_last;
    integer     fi, pj;
    reg  [31:0] fseq;
    reg  [7:0]  fflags;
    integer     pm_all, pm_bad, pm_x;        // 载荷不变式: 全对帧 / 有错帧 / 有 X 帧
    integer     pb_ok, pb_bad;               // 字节级
    reg  [63:0] pay_snap;                    // 首帧载荷快照 (打印用)
    integer     flood_frames;                // FIN 之后出现的 1460B 数据帧
    integer     live_frames;                 // FIN 之前的 1460B 数据帧
    reg  [31:0] flood_seq_first;
    reg  [31:0] live_seq_first, live_seq_last;

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
                if (fflags === 8'h18 && fb == (PLEN + 54)) begin
                    // 数据帧: 载荷不变式逐字节校验 (前 10 字节 -> hdr[54..63])
                    nd1460 = nd1460 + 1;
                    pb_ok = 0; pb_bad = 0; pm_x = 0;
                    for (pj = 0; pj < 10; pj = pj + 1) begin
                        if (hdr[54+pj] === 8'hxx) pm_x = pm_x + 1;
                        else if (hdr[54+pj] === (fseq[7:0] + pj[7:0])) pb_ok = pb_ok + 1;
                        else pb_bad = pb_bad + 1;
                    end
                    if (pb_bad == 0 && pm_x == 0) pm_all = pm_all + 1;
                    else pm_bad = pm_bad + 1;
                    if (nd1460 <= 2 || nd1460 <= nd1460_at_fin + 4) begin
                        pay_snap = {hdr[54], hdr[55], hdr[56], hdr[57],
                                    hdr[58], hdr[59], hdr[60], hdr[61]};
                        $display("[DATA] k=%0d frm=%0d len=%0d seq=%08h ack=%08h win=%04h pay[0:7]=%016h pb_ok=%0d pb_bad=%0d pb_x=%0d",
                                 k, nfrm, fb, fseq,
                                 {hdr[42], hdr[43], hdr[44], hdr[45]},
                                 {hdr[48], hdr[49]}, pay_snap, pb_ok, pb_bad, pm_x);
                    end
                    if (nd1460_at_fin == 0) begin
                        // FIN 之前 = 活帧
                        live_frames = live_frames + 1;
                        if (live_frames == 1) live_seq_first = fseq;
                        live_seq_last = fseq;
                    end else begin
                        flood_frames = flood_frames + 1;
                        if (flood_frames == 1) begin
                            flood_seq_first = fseq;
                            $display("[FLOD] k=%0d *** 洪水首帧: len=%0d seq=%08h (FIN 之后) pay[0:7]=%016h",
                                     k, fb, fseq, pay_snap);
                        end
                    end
                end else if (fflags === 8'h11) begin
                    nfin = nfin + 1;
                    if (nfin == 1) fin_seq_first = fseq;
                    fin_seq_last = fseq;
                    $display("[FIN ] k=%0d frm=%0d len=%0d flags=%02h seq=%08h ack=%08h",
                             k, nfrm, fb, fflags, fseq,
                             {hdr[42], hdr[43], hdr[44], hdr[45]});
                end else if (fflags === 8'h10) begin
                    nack = nack + 1;
                end else begin
                    nother = nother + 1;
                    $display("[OTHR] k=%0d frm=%0d len=%0d flags=%02h seq=%08h",
                             k, nfrm, fb, fflags, fseq);
                end
                fb = 0;
            end
        end
    end

    // =================================================================
    // 内部信号监视 (门自检)
    // =================================================================
    integer nsvc, ndrain, nringstart, nrepush, nfinpush, ackq_fin_push;
    reg  [31:0] delta0, delta1;
    integer     proj_frames;
    reg  [31:0] ringseq0;
    reg  [31:0] retxhi0, sndnxt0;
    reg  [63:0] proj_bytes;
    integer     nring_at_flood0;

    always @(posedge clk) begin
        if (rst_n && u_dut.svc) begin
            nsvc = nsvc + 1;
            $display("[SVC ] k=%0d svc#%0d id=%0d rewind=%b blocked=%b epoch=%0d | retx_hi=%08h rb_snd_nxt=%08h rb_snd_una=%08h fin_sent_r[0]=%b",
                     k, nsvc, u_dut.svc_id, u_dut.svc_rewind, u_dut.blocked,
                     u_dut.epoch[0], u_dut.retx_hi, rb_snd_nxt, rb_snd_una,
                     u_dut.fin_sent_r[0]);
        end
    end

    always @(posedge clk) begin
        if (rst_n && u_dut.ring_eval && !u_dut.ring_start) begin
            ndrain = ndrain + 1;
            if (ndrain <= 3 || ndrain == NPULSE - 1)
                $display("[DRAN] k=%0d drain#%0d delta=%08h fin_retx_pend[0]=%b fin_repush=%b => din=%s (session end)",
                         k, ndrain, u_dut.ring_delta, u_dut.fin_retx_pend[0],
                         u_dut.fin_repush,
                         u_dut.fin_repush ? "FIN(ok)" : "NONE");
        end
    end

    always @(posedge clk) begin
        if (rst_n && u_dut.ring_start) begin
            nringstart = nringstart + 1;
            if (nringstart == 1) begin
                delta0        = u_dut.ring_delta;
                ringseq0      = u_tcb.snd_nxt_r[0];
                retxhi0       = u_dut.retx_hi;
                sndnxt0       = u_tcb.snd_nxt_r[0];
                nring_at_flood0 = nd1460_at_fin;
                delta1        = u_dut.ring_delta;      // 供未跑满时收尾
                proj_frames   = delta0 / PLEN;
                proj_bytes    = (proj_frames + 1) * 64'd1460;
                $display("[RING] k=%0d *** ring_start#1: seq=%08h ring_delta=%08h (=retx_hi %08h - snd_nxt %08h, 32bit UNDERFLOW) plen_preset=%0d",
                         k, u_tcb.snd_nxt_r[0], u_dut.ring_delta, u_dut.retx_hi,
                         u_tcb.snd_nxt_r[0], u_dut.plen_preset);
                $display("[RING] k=%0d     delta 需要 %0d 帧 x %0d B = %0d B (~%0d MB) 才能追平 (snd_nxt 追到 retx_hi)",
                         k, proj_frames, PLEN, proj_bytes, proj_bytes / 64'd1048576);
            end else if (nringstart % 20 == 0) begin
                delta1 = u_dut.ring_delta;
                $display("[RING] k=%0d ring_start#%0d: delta=%08h snd_nxt=%08h",
                         k, nringstart, u_dut.ring_delta, u_tcb.snd_nxt_r[0]);
            end else begin
                delta1 = u_dut.ring_delta;
            end
        end
    end

    always @(posedge clk) if (rst_n && u_dut.fin_repush) nrepush = nrepush + 1;
    always @(posedge clk) if (rst_n && u_dut.fin_push)  nfinpush = nfinpush + 1;
    always @(posedge clk) if (rst_n && u_dut.ackq_wr && u_dut.ackq_din[33])
        ackq_fin_push = ackq_fin_push + 1;
    always @(posedge clk) if (rst_n && tb_upd_wr && dut_upd_wr)
        $display("[WARN] k=%0d TCB write conflict: TB cfg and DUT upd_wr same cycle", k);

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
    localparam [3:0] PH_RST=0, PH_CFG=1, PH_PUSH=2, PH_ACKW=3, PH_ACKW2=4,
                     PH_FINREQ=5, PH_WAITFIN=6, PH_FINSET=7, PH_RETX=8,
                     PH_FLOOD=9, PH_END=10;

    reg  [3:0]  ph;
    reg  [5:0]  cphase;
    integer     t_ph, post_until, frm_done, mpulse, wid;
    reg         push_gap;
    reg  [31:0] seq_cur;
    reg  [1:0]  rsub;                  // retx_req 脉冲子状态
    integer     seq_mismatch;          // snd_nxt != seq_cur 自检
    integer     fin_at_verdict, nsvc_at_verdict, ndrain_at_verdict,
                nrepush_at_verdict, ackqfin_at_verdict;
    integer     flood_at_verdict, live_at_verdict;
    reg  [31:0] d0_at_verdict, d1_at_verdict, sndnxt_at_verdict, snduna_at_verdict;
    reg         verdict_fail;
    integer     svc_at_blocked;
    reg         saw_blocked_svc;

    initial begin
        clk = 0; rst_n = 0;
        k = 0; fb = 0; nfrm = 0; nfin = 0; nack = 0; nother = 0; nd1460 = 0;
        nd1460_at_fin = 0; live_frames = 0; flood_frames = 0;
        pm_all = 0; pm_bad = 0; pm_x = 0; pb_ok = 0; pb_bad = 0;
        nsvc = 0; ndrain = 0; nringstart = 0; nrepush = 0; nfinpush = 0;
        ackq_fin_push = 0; delta0 = 0; delta1 = 0; proj_frames = 0;
        retxhi0 = 0; sndnxt0 = 0; proj_bytes = 0; nring_at_flood0 = 0;
        fin_seq_first = 0; fin_seq_last = 0; flood_seq_first = 0;
        live_seq_first = 0; live_seq_last = 0;
        frm_done = 0; mpulse = 0; verdict_fail = 0;
        saw_blocked_svc = 0; svc_at_blocked = 0; seq_mismatch = 0;
    end

    always @(posedge clk) begin
        k <= k + 1;
        if (!rst_n) begin
            ph <= PH_RST; cphase <= 0; t_ph <= 0; post_until <= 0;
            s_tdata <= 0; s_tkeep <= 0; s_tvalid <= 0; s_tlast <= 0; s_tid <= 0;
            ack_id <= 0; ack_val <= 0;
            fin_req <= 16'h0; rst_req <= 16'h0;
            retx_req_i <= 0; retx_id_i <= 0;
            wu_req_i <= 0; wu_id_i <= 0; wu_val_i <= 0;
            cfg_up_i <= 0; cfg_up_id_i <= 0;
            m_tready <= 1'b1;
            push_gap <= 0; wid <= 0; seq_cur <= SEQ0; rsub <= 0;
            tb_upd_wr <= 0; tb_upd_id <= 0; tb_upd_sel <= 0; tb_upd_val <= 0;
            cfg_wr <= 0; cfg_addr <= 0; cfg_sip <= 0; cfg_dip <= 0;
            cfg_sport <= 0; cfg_dport <= 0; cfg_dmac <= 0;
        end else begin
            case (ph)
            // ---- 配置: CAM0 + TCB0 (snd_nxt == snd_una == 6000) ----
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
                tb_upd_wr  <= (cphase >= 6 && cphase <= 11);
                tb_upd_id  <= 4'd0;
                tb_upd_sel <= (cphase - 6);
                case (cphase - 6)
                    6'd0: tb_upd_val <= 32'd1000;    // rcv_nxt
                    6'd1: tb_upd_val <= SEQ0;        // snd_nxt
                    6'd2: tb_upd_val <= SEQ0;        // snd_una (== snd_nxt)
                    6'd3: tb_upd_val <= 32'h2000;    // rcv_wnd
                    6'd4: tb_upd_val <= 32'h2000;    // snd_wnd
                    6'd5: tb_upd_val <= 32'd1;       // ESTAB
                    default: tb_upd_val <= 32'd0;
                endcase
                cphase <= cphase + 1;
                if (cphase == 6'd40) begin
                    cfg_wr <= 0; tb_upd_wr <= 0;
                    ph <= PH_PUSH; t_ph <= k; wid <= 0;
                    $display("[CFG ] k=%0d cfg done: RTO_LIM=%0d TCB0 snd_nxt=%08h snd_una=%08h state=%0d",
                             k, u_dut.RTO_LIM, u_tcb.snd_nxt_r[0], u_tcb.snd_una_r[0],
                             u_tcb.state_r[0]);
                    $display("[PLAN] %0d 帧 x %0d B = %0d B > 65536 (ring 整圈); 之后 close + %0d 次无进展 svc",
                             NUM_FRM, PLEN, NUM_FRM*PLEN, NPULSE);
                end
            end
            // ---- 活数据推送 (presenting 契约: 接受拍撤 valid 一拍) ----
            PH_PUSH: begin
                if (push_gap) begin
                    s_tvalid <= 1'b0; push_gap <= 1'b0;
                end else if (!s_tvalid) begin
                    if (wid < PLEN/8 + 1) begin
                        if (wid == PLEN/8) begin                 // 末词 4 字节
                            s_tdata <= pat_part(seq_cur + PLEN - 4, 4);
                            s_tkeep <= 8'hF0; s_tlast <= 1'b1;
                        end else begin
                            s_tdata <= pat_part(seq_cur + wid*8, 8);
                            s_tkeep <= 8'hFF; s_tlast <= 1'b0;
                        end
                        s_tid <= 4'd0; s_tvalid <= 1'b1; wid <= wid + 1;
                    end else begin
                        ph <= PH_ACKW;                            // 末词已被接受
                    end
                end else if (s_tready) begin
                    s_tvalid <= 1'b0; push_gap <= 1'b1;
                end
            end
            // ---- 等帧完成 (stat_frames++ 且回 S_IDLE 且非 upd 拍) ----
            PH_ACKW: begin
                if (stat_frames >= frm_done + 1 && u_dut.state == 3'd0 && !u_dut.upd_wr) begin
                    tb_upd_wr  <= 1'b1;
                    tb_upd_id  <= 4'd0;
                    tb_upd_sel <= 3'd2;                 // snd_una
                    tb_upd_val <= u_tcb.snd_nxt_r[0];   // 模拟对端 ACK 到最新
                    frm_done   <= frm_done + 1;
                    ph <= PH_ACKW2;
                    if (u_tcb.snd_nxt_r[0] !== (seq_cur + PLEN)) begin
                        seq_mismatch = seq_mismatch + 1;
                        $display("[FAILCHK] k=%0d 帧%0d snd_nxt=%08h != seq_cur+1460=%08h",
                                 k, frm_done, u_tcb.snd_nxt_r[0], seq_cur + PLEN);
                    end
                end
            end
            PH_ACKW2: begin
                tb_upd_wr <= 1'b0;
                seq_cur <= seq_cur + PLEN;
                if (frm_done >= NUM_FRM) begin
                    ph <= PH_FINREQ; t_ph <= k;
                    $display("[PUSH] k=%0d %0d 帧活数据发完: snd_nxt=%08h snd_una=%08h (in-flight=0) ring 已整圈",
                             k, frm_done, u_tcb.snd_nxt_r[0], u_tcb.snd_una_r[0]);
                end else begin
                    wid <= 0; ph <= PH_PUSH;
                end
            end
            // ---- close: 请求 FIN ----
            PH_FINREQ: begin
                fin_req[0] <= 1'b1;
                ph <= PH_WAITFIN; t_ph <= k;
                $display("[FINR] k=%0d close: fin_req[0]=1 (等扫描排队)", k);
            end
            PH_WAITFIN: begin
                if (nfin >= 1) begin
                    nd1460_at_fin <= nd1460;        // 活帧计数冻结值
                    ph <= PH_FINSET; t_ph <= k;
                end else if (k - t_ph > 20000) begin
                    $display("GATE tb_close_g9: INCONCLUSIVE (FIN timeout nfin=%0d)", nfin);
                    $finish;
                end
            end
            PH_FINSET: begin
                // 等 FIN 记账落定 (fin_sent_r/fin_seq_r/snd_nxt)
                if (k - t_ph > 8) begin
                    $display("[FIN1] k=%0d FIN bookkeeping: fin_sent_r[0]=%b fin_seq_r[0]=%08h snd_nxt=%08h snd_una=%08h",
                             k, u_dut.fin_sent_r[0], u_dut.fin_seq_r[0],
                             u_tcb.snd_nxt_r[0], u_tcb.snd_una_r[0]);
                    mpulse <= 0; rsub <= 0;
                    ph <= PH_RETX; t_ph <= k;
                    $display("[RETX] k=%0d 开始 %0d 次重传会话 (retx_req/dup-ACK 通道; 前 %0d 次应重推 FIN, 第 %0d 次应 blocked 洪水)",
                             k, NPULSE, NPULSE-1, NPULSE);
                end
            end
            // ---- 17 次 svc: 每次 retx_req 脉冲, 等 svc 落定 ----
            PH_RETX: begin
                if (rsub == 2'd0) begin
                    if (!u_dut.retx_active) begin
                        retx_req_i <= 1'b1; retx_id_i <= 4'd0;
                        t_ph <= k; rsub <= 2'd1;
                    end else if (k - t_ph > 5000) begin
                        $display("GATE tb_close_g9: INCONCLUSIVE (retx_active 未落, 脉冲 %0d)", mpulse);
                        $finish;
                    end
                end else if (rsub == 2'd1) begin
                    if (retx_gnt) begin
                        retx_req_i <= 1'b0;
                        mpulse <= mpulse + 1;
                        rsub <= 2'd2; t_ph <= k;
                        $display("[PULS] k=%0d retx_req#%0d 已服务 (retx_gnt=1) svc=%0d epoch[0]=%0d nfin=%0d",
                                 k, mpulse + 1, nsvc, u_dut.epoch[0], nfin);
                    end else if (k - t_ph > 5000) begin
                        retx_req_i <= 1'b0;
                        $display("GATE tb_close_g9: INCONCLUSIVE (retx_gnt 未回, 脉冲 %0d)", mpulse);
                        $finish;
                    end
                end else begin
                    if (mpulse >= NPULSE) begin
                        // 第 17 次 (blocked): 会话不会收尾 (ring_start 常 1, 洪水进行中)
                        // 只等洪水起势, 再进观察窗
                        if (k - t_ph > 200) begin
                            post_until <= k + FLOOD_CLK;
                            ph <= PH_FLOOD; t_ph <= k;
                            $display("[FLOOD] k=%0d 进入洪水观察窗 %0d 拍 (nfin=%0d nd1460=%0d nringstart=%0d retx_active=%b ring_start=%b)",
                                     k, FLOOD_CLK, nfin, nd1460, nringstart,
                                     u_dut.retx_active, u_dut.ring_start);
                        end
                    end else if (!u_dut.retx_active && !u_dut.ring_start && k - t_ph > 40) begin
                        // 未 blocked: 会话收尾 (回卷 + 重推 FIN), 起下一次脉冲
                        rsub <= 2'd0; t_ph <= k;
                    end else if (k - t_ph > 20000) begin
                        $display("GATE tb_close_g9: INCONCLUSIVE (会话收尾超时, 脉冲 %0d retx_active=%b ring_start=%b)",
                                 mpulse, u_dut.retx_active, u_dut.ring_start);
                        $finish;
                    end
                end
            end
            // ---- 洪水观察窗 ----
            PH_FLOOD: begin
                if (k >= post_until) begin
                    fin_at_verdict     = nfin;
                    nsvc_at_verdict    = nsvc;
                    ndrain_at_verdict  = ndrain;
                    nrepush_at_verdict = nrepush;
                    ackqfin_at_verdict = ackq_fin_push;
                    flood_at_verdict   = flood_frames;
                    live_at_verdict    = live_frames;
                    d0_at_verdict      = delta0;
                    d1_at_verdict      = delta1;
                    sndnxt_at_verdict  = u_tcb.snd_nxt_r[0];
                    snduna_at_verdict  = u_tcb.snd_una_r[0];
                    ackq_peek;
                    $display("-------- G9 VERDICT (RTO_LIM=production) --------");
                    $display("G9 FIN frames      = %0d (stat_fin=%0d) first_seq=%08h last_seq=%08h",
                             fin_at_verdict, stat_fin, fin_seq_first, fin_seq_last);
                    $display("G9 live data frames= %0d (seq %08h..%08h, %0d B) | payload invariant: ok_frames=%0d bad_frames=%0d x_frames=%0d (byte ok=%0d bad=%0d)",
                             live_at_verdict, live_seq_first, live_seq_last,
                             live_at_verdict*PLEN, pm_all, pm_bad, pm_x, pb_ok, pb_bad);
                    $display("G9 svc sessions    = %0d (stat_retx=%0d) ring_drain_beats=%0d epoch[0]=%0d blocked_at_last_svc=%b",
                             nsvc_at_verdict, stat_retx, ndrain_at_verdict,
                             u_dut.epoch[0], u_dut.blocked);
                    $display("G9 ackq FIN entries= pushed %0d (fin_push=%0d fin_repush_pulse=%0d) occupancy_now=%0d",
                             ackqfin_at_verdict, nfinpush, nrepush_at_verdict, aq_fin_occ);
                    $display("G9 ring_delta      = first %08h (at flood start: retx_hi %08h - snd_nxt %08h, flood seq0=%08h)",
                             d0_at_verdict, retxhi0, sndnxt0, ringseq0);
                    $display("G9 replay flood    = %0d frames x %0d B in %0d clk (ring_start pulses=%0d, last in flight); delta now %08h (march=%0d B = %0d frames); projected total %0d frames (%0d MB)",
                             flood_at_verdict, PLEN, FLOOD_CLK, nringstart, d1_at_verdict,
                             d0_at_verdict - d1_at_verdict,
                             (d0_at_verdict - d1_at_verdict) / PLEN, proj_frames,
                             proj_bytes / 64'd1048576);
                    $display("G9 final state     = snd_nxt=%08h snd_una=%08h retx_active=%b fin_retx_pend[0]=%b o_fin_sent=%04h",
                             sndnxt_at_verdict, snduna_at_verdict, u_dut.retx_active,
                             u_dut.fin_retx_pend[0], o_fin_sent);
                    $display("G9 frame stats     = total %0d (data1460 %0d / fin %0d / ack %0d / other %0d) stat_frames=%0d seq_mismatch=%0d",
                             nfrm, nd1460, nfin, nack, nother, stat_frames, seq_mismatch);
                    if (flood_at_verdict == 0 && fin_seq_last == fin_seq_first) begin
                        verdict_fail = 0;
                        $display("GATE tb_close_g9: PASS  (no replay flood after FIN; FIN frames=%0d)",
                                 fin_at_verdict);
                    end else begin
                        verdict_fail = 1;
                        $display("GATE tb_close_g9: FAIL  (ring_delta underflow flood: %0d frames x %0d B after FIN, delta0=%08h, projected %0d frames / %0d MB)",
                                 flood_at_verdict, PLEN, d0_at_verdict, proj_frames,
                                 proj_bytes / 64'd1048576);
                    end
                    ph <= PH_END;
                end
            end
            PH_END: begin
                $display("GATE tb_close_g9: DONE (verdict_fail=%0d)", verdict_fail);
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
