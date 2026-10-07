`timescale 1ns/1ps
// ===========================================================================
// tb_integ_app_tx.v -- P7b Stage C **同批集成门** (对抗审查 B5):
//     真 `rtl/app_pattern.v` (P7B_10G)  ->  真 `rtl/tcp_tx_frame.v` (TCP_TX_OVL)
// ---------------------------------------------------------------------------
// 为什么必须单开一条: 审查裁定"app_pattern(P7B_10G) 与 tcp_tx_frame(TCP_TX_OVL)
//   的同批交互**无法判定**" —— 主门 TB 的激励是 TB 合成的 (fb() 图案), 只证明
//   **帧器自身**正确; app 的**真实**字流 (1 字节/拍 LFSR、帧首空字、tkeep/tlast
//   细节、app_tx_ready 门、close_req 收尾) 与帧器乒乓/回卷门的交互没有判据。
// 判据:
//   J1 结构   ethertype / ip_len==帧长 / 长度上界 (与主门同款复算)
//   J2 校验和 从**线上字节**独立复算 IP(24) 与 TCP(50, 含伪头) 校验和
//   J3 载荷   **逐字节** = app 的真实 xorshift64 序列 (偏移 = seq - 线上首帧 seq)
//   J4 续接   [seq,seq+plen) 接上前沿 / 整段落在已发区间; 空洞与部分重叠 = 红
//   J5 守恒   peer 前沿推进量 == app.stat_tx_bytes (app 全流上线);
//             线上载荷 >= app 字节 (差额 = 重放量, 打印); DUT stat_bytes 对账
//   J6 静默丢 DUT stat_eend == 0 且两 bank FIFO ovf_pulse 恒 0
//   J7 收尾   app close_req -> TB 转 fin_req -> 线上 FIN
//   J8 节奏   引擎拍数 / 帧周期 min (读数, 与设计值对照)
// oracle 独立性: 图案由 TB 按 app 头注释的 xorshift64 (种子 0x9E3779B97F4A7C15,
//   取 s[31:24], 先取后推进) **预生成 1MB 查表**, 不调 app 内部函数、不读 app 状态;
//   seq->偏移由**线上第一帧的 seq** 锚定 (不看 TCB/不看 ISN)。
// 宏: 必须 -d P7B_10G -d TCP_TX_OVL (缺一个即 $finish, 防"真空门")。
// TB 覆盖边界 (如实登记): 只跑单连接 (槽 0) 单向; ACK 走 TB 的合成 rx_upd
//   (不含真 tcp_rx); 不校验线上 ack/窗口字段 (那是主门的判据)。
// ===========================================================================
`ifndef P7B_10G
  initial begin $display("TB_INTEG_APP_TX: FATAL missing -d P7B_10G"); $finish; end
`endif
`ifndef TCP_TX_OVL
  initial begin $display("TB_INTEG_APP_TX: FATAL missing -d TCP_TX_OVL"); $finish; end
`endif

module tb_integ_app_tx;
    reg clk, rst_n;
    initial clk = 1'b0;
    always #3.2 clk = ~clk;                  // 6.4 ns = 156.25 MHz

    localparam integer TXB     = 1048576;    // app_pattern 默认 TX_BYTES (1MB)
    localparam integer NFRAME  = 719;        // 718*1460 + 296 = 1048576
    localparam [31:0] SEQ_ISN  = 32'h0000_1000;
    localparam [31:0] RCV_NXT  = 32'h0000_4000;
    localparam [15:0] RCV_WND  = 16'h4000;
    localparam [15:0] SND_WND  = 16'hC000;
    localparam integer CY_MAX  = 4000000;

    // ===================== 期望图案 (TB 侧独立预生成) =====================
    // app_pattern 头注释: `s ^= s<<13; s ^= s>>7; s ^= s<<17;`, 种子 0x9E3779B97F4A7C15,
    // gen_byte = tx_lfsr[31:24] 且同拍推进 ⇒ 偏移 k 的字节 = S_k[31:24], S_0 = SEED
    // (即"先取后推进")。
    reg [7:0]  exp_b [0:TXB-1];
    integer    ei;
    reg [63:0] es;
    initial begin
        es = 64'h9E3779B97F4A7C15;
        for (ei = 0; ei < TXB; ei = ei + 1) begin
            exp_b[ei] = es[31:24];
            es = es ^ (es << 13); es = es ^ (es >> 7); es = es ^ (es << 17);
        end
        $display("INTEG exp_b[0..3] = %02h %02h %02h %02h", exp_b[0], exp_b[1], exp_b[2], exp_b[3]);
    end
    function [7:0] xo;                       // 图案流偏移 k 的期望字节
        input [31:0] k;
        begin
            xo = (k < TXB) ? exp_b[k] : 8'h00;
        end
    endfunction

    // ===================== 线上帧解析状态 =====================
    reg  [7:0]  fr [0:1663];
    reg  [11:0] fpos;
    integer n_frames, n_data, n_ctrl, n_fin, n_fin_only;
    integer e_parse, e_csum, e_pay, e_seq, e_cons;
    integer n_dead, n_ovf_seen;
    reg [31:0] exp_new;
    reg [31:0] seq0;
    reg        seq0_seen;
    integer cyc;
    always @(posedge clk) cyc <= cyc + 1;
    integer rx_t0, rx_min, tx_t0, tx_min, fp_last, fp_min, fp_n;
    integer full_n;
    reg [31:0] pay_sum;
    integer k, kk, dump_n;

    function [15:0] csum16;
        input [31:0] acc;
        reg [16:0] f1;
        begin
            f1 = {1'b0, acc[15:0]} + {1'b0, acc[31:16]};
            csum16 = ~(f1[15:0] + {15'b0, f1[16]});
        end
    endfunction
    function [15:0] fw;                      // 线上第 i 个 16 位字
        input integer idx;
        begin
            fw = {fr[idx], fr[idx+1]};
        end
    endfunction

    initial begin
        fpos = 0; n_frames = 0; n_data = 0; n_ctrl = 0; n_fin = 0; n_fin_only = 0;
        e_parse = 0; e_csum = 0; e_pay = 0; e_seq = 0; e_cons = 0;
        n_dead = 0; n_ovf_seen = 0;
        exp_new = 32'd0; seq0 = 32'd0; seq0_seen = 1'b0; pay_sum = 32'd0;
        cyc = 0; dump_n = 0;
        rx_t0 = -1; rx_min = 1000000; tx_t0 = -1; tx_min = 1000000;
        fp_last = -1; fp_min = 1000000; fp_n = 0; full_n = 0;
    end

    // ===================== TCB + CAM (与主门同款仲裁) =====================
    reg         scfg_upd_wr; reg [3:0] scfg_upd_id; reg [2:0] scfg_upd_sel;
    reg  [31:0] scfg_upd_val;
    reg         rx_upd_wr;   reg [3:0] rx_upd_id;   reg [2:0] rx_upd_sel;
    reg  [31:0] rx_upd_val;
    wire [3:0]  rb_id, cam_rd_id;
    wire [31:0] rb_snd_nxt, rb_rcv_nxt, rb_snd_una;
    wire [15:0] rb_rcv_wnd, rb_snd_wnd;
    wire [3:0]  rb_state;
    wire        win_open;
    wire [15:0] win_inflight, win_wnd_eff;
    wire        tx_upd_wr; wire [3:0] tx_upd_id; wire [2:0] tx_upd_sel;
    wire [31:0] tx_upd_val;
    wire        sel_tx  = tx_upd_wr;
    wire        sel_rx  = !sel_tx && rx_upd_wr;
    wire        rx_upd_gnt = sel_rx;
    wire        scfg_gnt = !sel_tx && !sel_rx;
    wire        tcb_wr  = sel_tx || sel_rx || (scfg_upd_wr && scfg_gnt);
    wire [2:0]  tcb_sel = sel_tx ? tx_upd_sel : (sel_rx ? rx_upd_sel : scfg_upd_sel);
    wire [3:0]  tcb_id  = sel_tx ? tx_upd_id  : (sel_rx ? rx_upd_id  : scfg_upd_id);
    wire [31:0] tcb_val = sel_tx ? tx_upd_val : (sel_rx ? rx_upd_val : scfg_upd_val);

    wire [31:0] c0_snd_nxt, c0_snd_una, c0_rcv_nxt;
    wire [15:0] c0_snd_wnd;
    wire [3:0]  c0_state;
    tcb #(.N(16), .WIN_CAP(16'hBFFE)) u_tcb (
        .clk(clk), .rst_n(rst_n),
        .ra_id(4'd0), .ra_rcv_nxt(), .ra_snd_nxt(), .ra_snd_una(),
        .ra_rcv_wnd(), .ra_snd_wnd(), .ra_state(), .ra_wscale(),
        .rb_id(rb_id), .rb_rcv_nxt(rb_rcv_nxt), .rb_snd_nxt(rb_snd_nxt),
        .rb_snd_una(rb_snd_una), .rb_rcv_wnd(rb_rcv_wnd), .rb_snd_wnd(rb_snd_wnd),
        .rb_state(rb_state),
        .win_id(rb_id), .win_open(win_open), .win_inflight(win_inflight),
        .win_wnd_eff(win_wnd_eff),
        .rc_id(4'd0), .rc_rcv_nxt(c0_rcv_nxt), .rc_snd_nxt(c0_snd_nxt),
        .rc_snd_una(c0_snd_una), .rc_rcv_wnd(), .rc_snd_wnd(c0_snd_wnd),
        .rc_state(c0_state),
        .dbg_snd_nxt0(), .dbg_snd_una0(), .dbg_rcv_nxt0(), .dbg_snd_wnd0(),
        .dbg_wscale0(), .dbg_state0(),
        .upd_wr(tcb_wr), .upd_id(tcb_id), .upd_sel(tcb_sel), .upd_val(tcb_val)
    );

    reg  [47:0] cam_dmac [0:15];
    reg  [31:0] cam_sip  [0:15];
    reg  [15:0] cam_sport[0:15];
    reg  [15:0] cam_dport[0:15];
    wire [47:0] cam_rd_dmac  = cam_dmac [cam_rd_id];
    wire [31:0] cam_rd_sip   = cam_sip  [cam_rd_id];
    wire [15:0] cam_rd_sport = cam_sport[cam_rd_id];
    wire [15:0] cam_rd_dport = cam_dport[cam_rd_id];
    integer i;
    initial for (i = 0; i < 16; i = i + 1) begin
        cam_dmac[i]  = 48'hAA_BB_CC_DD_EE_00 + i;
        cam_sip[i]   = 32'hC0A8_6400 + (i + 10);
        cam_sport[i] = 16'd40000 + i;
        cam_dport[i] = 16'd8080;
    end

    // ===================== DUT s_axis <- 真 app =====================
    wire tx_s_tready;
    wire [63:0] app_m_tdata;  wire [7:0] app_m_tkeep;  wire app_m_tvalid;
    wire        app_m_tlast;  wire [3:0] app_m_tid;
    wire [15:0] app_tx_ready;
    reg         app_ev_up, app_ev_down; reg [3:0] app_ev_slot;
    wire        app_close_req; wire [3:0] app_close_id;
    wire [31:0] app_tx_bytes, app_tx_frames, app_rx_bytes, app_mismatch;
    wire [31:0] app_bad_frames;
    wire        app_active, app_done;
    wire [31:0] app_dbg_lfsr;
    wire [3:0]  app_led;

    app_pattern #(.TX_BYTES(32'd1048576), .TX_SEGSZ(12'd1460)) u_app (
        .clk(clk), .rst_n(rst_n),
        .ev_up(app_ev_up), .ev_down(app_ev_down), .ev_slot(app_ev_slot),
        .m_tdata(app_m_tdata), .m_tkeep(app_m_tkeep), .m_tvalid(app_m_tvalid),
        .m_tready(tx_s_tready), .m_tlast(app_m_tlast), .m_tid(app_m_tid),
        .app_tx_ready(app_tx_ready),
        .close_req(app_close_req), .close_id(app_close_id),
        .rx_tdata(64'h0), .rx_tkeep(8'h0), .rx_tvalid(1'b0), .rx_tready(),
        .rx_tlast(1'b0), .rx_tid(4'h0),
        .i_bad_frame(16'd0),
        .stat_tx_bytes(app_tx_bytes), .stat_tx_frames(app_tx_frames),
        .stat_bad_frames(app_bad_frames),
        .stat_rx_bytes(app_rx_bytes), .stat_mismatch(app_mismatch),
        .active(app_active), .act_id(), .done(app_done),
        .dbg_lfsr(app_dbg_lfsr), .led(app_led)
    );

    wire [63:0] m_tdata; wire [7:0] m_tkeep; wire m_tvalid, m_tlast;
    reg  m_tready;
    reg  ack_req; reg [3:0] ack_id; reg [31:0] ack_val;
    reg  ack_syn, ack_fin, ack_rst;
    reg  [15:0] fin_req, rst_req;
    reg  cfg_up; reg [3:0] cfg_up_id;
    wire [15:0] o_fin_sent, o_rst_sent;
    reg  wu_req; reg [3:0] wu_id; reg [31:0] wu_val; wire wu_gnt;
    reg  retx_req; reg [3:0] retx_id; wire retx_gnt;
    wire [31:0] stat_retx;
    wire [31:0] stat_frames, stat_bytes, stat_ack, stat_ack_drop, stat_eend,
                stat_drop_len, stat_fin, stat_rst, stat_tlast_in;

    tcp_tx_frame u_dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(app_m_tdata), .s_axis_tkeep(app_m_tkeep),
        .s_axis_tvalid(app_m_tvalid), .s_axis_tready(tx_s_tready),
        .s_axis_tlast(app_m_tlast), .s_axis_tid(app_m_tid),
        .ack_req(ack_req), .ack_id(ack_id), .ack_val(ack_val), .ack_syn(ack_syn),
        .ack_fin(ack_fin), .ack_rst(ack_rst),
        .fin_req(fin_req), .rst_req(rst_req),
        .cfg_up(cfg_up), .cfg_up_id(cfg_up_id),
        .o_fin_sent(o_fin_sent), .o_rst_sent(o_rst_sent),
        .wu_req(wu_req), .wu_id(wu_id), .wu_val(wu_val), .wu_gnt(wu_gnt),
        .rb_id(rb_id), .rb_snd_nxt(rb_snd_nxt), .rb_rcv_nxt(rb_rcv_nxt),
        .rb_rcv_wnd(rb_rcv_wnd), .rb_snd_una(rb_snd_una), .rb_snd_wnd(rb_snd_wnd),
        .rb_state(rb_state),
        .win_open(win_open), .win_inflight(win_inflight), .win_wnd_eff(win_wnd_eff),
        .retx_req(retx_req), .retx_id(retx_id), .retx_gnt(retx_gnt),
        .stat_retx(stat_retx),
        .o_retx_hi(), .o_retx_active(), .o_retx_id(),
        .upd_wr(tx_upd_wr), .upd_id(tx_upd_id), .upd_sel(tx_upd_sel),
        .upd_val(tx_upd_val),
        .cam_rd_id(cam_rd_id), .cam_rd_dmac(cam_rd_dmac), .cam_rd_sip(cam_rd_sip),
        .cam_rd_sport(cam_rd_sport), .cam_rd_dport(cam_rd_dport),
        .cfg_src_mac(48'h02_00_00_00_00_01), .cfg_src_ip(32'hC0A8_6402),
        .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep), .m_axis_tvalid(m_tvalid),
        .m_axis_tready(m_tready), .m_axis_tlast(m_tlast),
        .stat_frames(stat_frames), .stat_bytes(stat_bytes), .stat_ack(stat_ack),
        .stat_ack_drop(stat_ack_drop), .stat_eend(stat_eend),
        .stat_drop_len(stat_drop_len), .stat_fin(stat_fin), .stat_rst(stat_rst),
        .stat_tlast_in(stat_tlast_in),
        .dbg_wnd_open(), .dbg_pay_full(), .dbg_sready(), .dbg_saxis_tvalid(),
        .dbg_plen_r(), .dbg_state(), .dbg_pay_wptr(), .dbg_pay_rptr(),
        .dbg_pay_full2(), .dbg_pay_empty(), .dbg_plen()
    );

    // app_tx_ready: 复刻 app_ctrl.tx_ready_calc (rtl/app_ctrl.v:557 的公式:
    //   ESTAB && 在飞 < min(snd_wnd, WIN_CAP) && !fin_req && !fin_sent && !rst_*)
    //   本 TB 用 live 值 (比 app_ctrl 的 256 拍轮扫快照更紧, 不会放松门)。
    wire [15:0] eff_cap = (c0_snd_wnd < 16'hBFFE) ? c0_snd_wnd : 16'hBFFE;
    wire rd_ok = (c0_state == 4'd1) && ((c0_snd_nxt - c0_snd_una) < {16'b0, eff_cap}) &&
                 !fin_req[0] && !o_fin_sent[0] && !rst_req[0] && !o_rst_sent[0];
    assign app_tx_ready = {15'b0, rd_ok};
    wire tx_ovf_ok = !u_dut.dovf_a && !u_dut.dovf_b;

    // ===================== 帧接收 + 逐帧校验 =====================
    task check_frame;
        reg [3:0]  t_conn;
        reg [31:0] fseq;
        integer    plen;
        reg [31:0] acc;
        reg [15:0] cs;
        reg [7:0]  flags;
        reg [31:0] off;
        integer    kx;
        integer    flen;
        begin
            flen   = fpos;                 // ⚠️ 用 reg 采样: 连续赋值同拍读到的是上拍值
            t_conn = fr[46][3:0];
            plen   = flen - 54;
            fseq   = {fr[38], fr[39], fr[40], fr[41]};
            flags  = fr[47];
            // ---- J1 结构 ----
            if ((fpos < 12'd54) || (fr[12] !== 8'h08) || (fr[13] !== 8'h00) ||
                (fr[14] !== 8'h45) || (fr[23] !== 8'h06)) begin
                e_parse = e_parse + 1;
                if (e_parse < 6)
                $display("[FAIL] integ struct len=%0d et=%02h%02h vihl=%02h proto=%02h ip_len=%04h @%0d",
                         fpos, fr[12], fr[13], fr[14], fr[23], {fr[16],fr[17]}, cyc);
            end else if (plen > 1532) begin
                e_parse = e_parse + 1;
                if (e_parse < 6) $display("[FAIL] integ plen=%0d @%0d", plen, cyc);
            end else if ({fr[16], fr[17]} !== (flen - 16'd14)) begin
                e_parse = e_parse + 1;
                if (e_parse < 6)
                $display("[FAIL] integ ip_len=%04h want=%04h fpos=%0d et=%02h%02h vihl=%02h proto=%02h @%0d",
                         {fr[16],fr[17]}, (flen - 16'd14), fpos, fr[12], fr[13], fr[14], fr[23], cyc);
            end
            // ---- J2 校验和 (算法与主门 tb_tcp_tx_ovl.v:397-415 逐字同款) ----
            acc = 32'd0;
            for (kx = 14; kx < 34; kx = kx + 2)
                if (kx == 24) acc = acc + 32'd0;
                else          acc = acc + {16'b0, fw(kx)};
            cs = csum16(acc);
            if (cs !== fw(24)) begin
                e_csum = e_csum + 1;
                if (e_csum < 8)
                $display("[FAIL] integ ipcsum got=%04h want=%04h @%0d", fw(24), cs, cyc);
            end
            acc = {16'b0, fw(26)} + {16'b0, fw(28)} +     // 伪头: src ip
                  {16'b0, fw(30)} + {16'b0, fw(32)} +     //         dst ip
                  32'h0000_0006 + {16'b0, (flen - 16'd34)};
            for (kx = 34; kx < fpos; kx = kx + 2) begin
                if (kx == 50) acc = acc + 32'd0;
                else if ((kx + 1) < fpos) acc = acc + {16'b0, fw(kx)};
                else                      acc = acc + {16'b0, fr[kx], 8'h00};
            end
            cs = csum16(acc);
            if (cs !== fw(50)) begin
                e_csum = e_csum + 1;
                if (e_csum < 8)
                $display("[FAIL] integ tcpcsum got=%04h want=%04h @%0d", fw(50), cs, cyc);
            end
            // ---- 分帧 ----
            if (dump_n < 6) begin
                dump_n = dump_n + 1;
                $display("DBG frame#%0d fpos=%0d plen=%0d seq=%h flags=%02h iplen16=%04h",
                         dump_n, fpos, plen, fseq, flags, (flen - 16'd14));
                $display("DBG  b0..7 : %02h %02h %02h %02h %02h %02h %02h %02h",
                         fr[0],fr[1],fr[2],fr[3],fr[4],fr[5],fr[6],fr[7]);
                $display("DBG  b8..15: %02h %02h %02h %02h %02h %02h %02h %02h",
                         fr[8],fr[9],fr[10],fr[11],fr[12],fr[13],fr[14],fr[15]);
                $display("DBG  b16.23: %02h %02h %02h %02h %02h %02h %02h %02h",
                         fr[16],fr[17],fr[18],fr[19],fr[20],fr[21],fr[22],fr[23]);
                $display("DBG  b24.31: %02h %02h %02h %02h %02h %02h %02h %02h",
                         fr[24],fr[25],fr[26],fr[27],fr[28],fr[29],fr[30],fr[31]);
                $display("DBG  b32.39: %02h %02h %02h %02h %02h %02h %02h %02h",
                         fr[32],fr[33],fr[34],fr[35],fr[36],fr[37],fr[38],fr[39]);
                $display("DBG  b40.47: %02h %02h %02h %02h %02h %02h %02h %02h",
                         fr[40],fr[41],fr[42],fr[43],fr[44],fr[45],fr[46],fr[47]);
                $display("DBG  b48.55: %02h %02h %02h %02h %02h %02h %02h %02h",
                         fr[48],fr[49],fr[50],fr[51],fr[52],fr[53],fr[54],fr[55]);
            end
            n_frames = n_frames + 1;
            if (plen !== 12'd0) begin
                n_data = n_data + 1;
                pay_sum = pay_sum + plen[31:0];
                if (!seq0_seen) begin seq0_seen = 1'b1; seq0 = fseq; exp_new = fseq; end
                // ---- J3 载荷逐字节 (含重放: 偏移 = seq - seq0) ----
                off = fseq - seq0;
                for (kk = 0; kk < plen; kk = kk + 1) begin
                    if (fr[54 + kk] !== xo(off + kk[31:0])) begin
                        e_pay = e_pay + 1;
                        if (e_pay < 5)
                            $display("[FAIL] integ payload off=%0d got=%02h want=%02h seq=%h @%0d",
                                     off + kk, fr[54+kk], xo(off + kk[31:0]), fseq, cyc);
                        kk = plen;
                    end
                end
                // ---- J4 续接 ----
                if (fseq == exp_new) begin
                    exp_new = exp_new + plen[31:0];
                end else if ((fseq - exp_new) < 32'h8000_0000) begin
                    e_seq = e_seq + 1;
                    $display("[FAIL] integ hole seq=%h plen=%0d exp=%h @%0d", fseq, plen, exp_new, cyc);
                end else if ((((fseq + plen[31:0]) - exp_new) != 32'd0) &&
                             (((fseq + plen[31:0]) - exp_new) < 32'h8000_0000)) begin
                    e_seq = e_seq + 1;
                    if (e_seq < 6)
                    $display("[FAIL] integ overlap seq=%h plen=%0d exp=%h @%0d", fseq, plen, exp_new, cyc);
                end
                // else: 整段落在已发区间 (重放) — 合法, 内容由 J3 逐字节判
            end else begin
                n_ctrl = n_ctrl + 1;
                if (flags[0] || flags[1] || flags[2]) n_fin = n_fin + 1;
            end
        end
    endtask

    always @(posedge clk) begin
        if (m_tvalid && m_tready) begin
            if (m_tkeep[7]) begin fr[fpos] = m_tdata[63:56]; fpos = fpos + 1; end
            if (m_tkeep[6]) begin fr[fpos] = m_tdata[55:48]; fpos = fpos + 1; end
            if (m_tkeep[5]) begin fr[fpos] = m_tdata[47:40]; fpos = fpos + 1; end
            if (m_tkeep[4]) begin fr[fpos] = m_tdata[39:32]; fpos = fpos + 1; end
            if (m_tkeep[3]) begin fr[fpos] = m_tdata[31:24]; fpos = fpos + 1; end
            if (m_tkeep[2]) begin fr[fpos] = m_tdata[23:16]; fpos = fpos + 1; end
            if (m_tkeep[1]) begin fr[fpos] = m_tdata[15:8];  fpos = fpos + 1; end
            if (m_tkeep[0]) begin fr[fpos] = m_tdata[7:0];   fpos = fpos + 1; end
            if (m_tlast) begin
                check_frame;
                fpos = 12'd0;
            end
            if (fpos > 12'd1600) begin
                e_parse = e_parse + 1;
                $display("[FAIL] integ frame overrun fpos=%0d @%0d", fpos, cyc); fpos = 12'd0;
            end
        end
    end

    // 引擎拍数读数 (与主门同口径)
    always @(posedge clk) begin
        if (u_dut.start_data && tx_s_tready && (rx_t0 < 0)) rx_t0 = cyc;
        if ((u_dut.rx_state == 2'd2) && (u_dut.fin_cnt == 3'd4) && (rx_t0 >= 0)) begin
            if (u_dut.f_plen[u_dut.rx_bank] == 12'd1460) begin   // 满帧才是引擎指标
                full_n = full_n + 1;
                if ((cyc - rx_t0 + 1) < rx_min) rx_min = cyc - rx_t0 + 1;
            end
            rx_t0 = -1;
        end
        if ((u_dut.tx_state == 3'd1) && (u_dut.thcnt == 3'd0) && !u_dut.tx_is_ctrl &&
            (tx_t0 < 0)) tx_t0 = cyc;
        if ((u_dut.tx_state == 3'd4) && !u_dut.tx_is_ctrl && (!m_tvalid || m_tready)) begin
            if (tx_t0 >= 0) begin
                if ((cyc - tx_t0) < tx_min) tx_min = cyc - tx_t0;
                tx_t0 = -1;
            end
            if (fp_last >= 0) begin
                if ((cyc - fp_last) < fp_min) fp_min = cyc - fp_last;
                fp_n = fp_n + 1;
            end
            fp_last = cyc;
        end
    end

    // ===================== 激励: 建连 -> ev_up -> ACK/retx -> close =====================
    reg [3:0] st;
    integer   wait_c;
    reg       syn_bumped, ev_pulsed, fin_pushed;
    reg [3:0] ack_burst;
    reg [31:0] ack_mark, ack_point;
    localparam [31:0] LAG = 32'd4380;   // 3 帧 (1460B) 的 ACK 滞后
    reg [31:0] ack_target;              // 目标 ACK 点 (钳在首帧之后, 见下)
    reg        closing_mode;            // app 发完 -> 追上全部前沿 (FIN 需要 snd_nxt==snd_una)
    reg [31:0] trq_next;
    integer   close_wait;
    initial begin
        scfg_upd_wr = 0; scfg_upd_id = 0; scfg_upd_sel = 0; scfg_upd_val = 0;
        rx_upd_wr = 0; rx_upd_id = 0; rx_upd_sel = 0; rx_upd_val = 0;
        ack_req = 0; ack_id = 0; ack_val = RCV_NXT; ack_syn = 0; ack_fin = 0; ack_rst = 0;
        fin_req = 0; rst_req = 0; cfg_up = 0; cfg_up_id = 0;
        wu_req = 0; wu_id = 0; wu_val = 0; retx_req = 0; retx_id = 0;
        m_tready = 1'b1;
        rst_n = 1'b0;
        app_ev_up = 0; app_ev_down = 0; app_ev_slot = 0;
        st = 4'd0; wait_c = 0; syn_bumped = 0; ev_pulsed = 0; fin_pushed = 0;
        ack_burst = 4'd0; ack_mark = RCV_NXT; ack_point = RCV_NXT;
        closing_mode = 1'b0;
        trq_next = 32'd60000;
        close_wait = 0;
        #200 rst_n = 1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= 4'd0;
        end else begin
            begin
                // ---- 主循环 (RUN) ----
                // ACK: 前沿推进后打 4 拍脉冲 (ack_val = 绝对 exp_new)
                if (st >= 4'd11) begin
                    // (1) TCB 的 snd_una <- 对端前沿 (sel=2): 这一步不做的话回卷会退回
                    //     ISN 去"重放"从未发过的字节 (TB 侧假象, 不是 DUT 缺陷)
                    //  ⚠️ ACK 滞后 3 帧 (LAG=4380B): 让 snd_una 落在前沿之后,
                    //     这样 retx_req 的回卷才有**真数据**可重放 (才是真交互);
                    //     滞后量 << 发送帽 (SND_WND/CAP) ⇒ 不会掐死 app 的窗门。
                    //   ⚠️ 触发量必须用"目标点"而不是"前沿": 前沿每进 1 字节就
                    //     重新满足 (会每 ~10 拍发一个 ACK 帧 —— 踩过)
                    //   收尾段 (closing_mode): 取消滞后, 追上全部前沿 —— 否则最后
                    //   3 帧永不 ACK ⇒ snd_una != snd_nxt ⇒ fin_push 门不开 ⇒ 无 FIN
                    ack_target = (!closing_mode && seq0_seen &&
                                  ((exp_new - seq0) >= LAG)) ? (exp_new - LAG) : exp_new;
                    if ((ack_burst == 4'd0) && !rx_upd_wr && seq0_seen &&
                        (closing_mode ? (ack_target != ack_point)
                                      : ((ack_target - ack_point) >= LAG))) begin
                        rx_upd_wr <= 1'b1; rx_upd_id <= 4'd0; rx_upd_sel <= 3'd2;
                        rx_upd_val <= ack_target;
                    end
                    if (rx_upd_wr && rx_upd_gnt) begin
                        rx_upd_wr <= 1'b0; ack_point <= ack_target;
                        ack_burst <= 4'd4;          // (2) 再打线上 ACK 帧脉冲
                    end
                    if (ack_burst != 4'd0) begin
                        ack_req <= 1'b1; ack_id <= 4'd0; ack_val <= ack_point;
                        ack_syn <= 1'b0; ack_fin <= 1'b0; ack_rst <= 1'b0;
                        ack_burst <= ack_burst - 4'd1;
                    end else ack_req <= 1'b0;
                    // 周期 retx_req (逼出回卷会话: 重放载荷也要逐字节 = app 图案)
                    if ((cyc >= trq_next) && !retx_req) begin
                        retx_req <= 1'b1; retx_id <= 4'd0;
                        trq_next <= cyc + 32'd60000;
                    end else if (retx_req && retx_gnt) retx_req <= 1'b0;
                    // close: app 发完 -> close_req -> TB 转 fin_req (app_ctrl 的角色)
                    if (app_close_req && !fin_pushed) begin
                        fin_req[0] <= 1'b1; fin_pushed <= 1'b1;
                        closing_mode <= 1'b1;
                    end
                    if (fin_pushed && o_fin_sent[0]) fin_req[0] <= 1'b0;
                end
            end
            case (st)
            // 建连: TCB 6 项 + cfg_up
            4'd0:  begin scfg_upd_wr <= 1; scfg_upd_id <= 0; scfg_upd_sel <= 3'd2;
                         scfg_upd_val <= SEQ_ISN; st <= 4'd1; end
            4'd1:  if (tcb_wr && (tcb_sel == 3'd2) && (tcb_id == 0))
                       begin scfg_upd_sel <= 3'd1; scfg_upd_val <= SEQ_ISN; st <= 4'd2; end
            4'd2:  if (tcb_wr && (tcb_sel == 3'd1) && (tcb_id == 0))
                       begin scfg_upd_sel <= 3'd0; scfg_upd_val <= RCV_NXT; st <= 4'd3; end
            4'd3:  if (tcb_wr && (tcb_sel == 3'd0) && (tcb_id == 0))
                       begin scfg_upd_sel <= 3'd3; scfg_upd_val <= {16'b0, RCV_WND}; st <= 4'd4; end
            4'd4:  if (tcb_wr && (tcb_sel == 3'd3) && (tcb_id == 0))
                       begin scfg_upd_sel <= 3'd4; scfg_upd_val <= {16'b0, SND_WND}; st <= 4'd5; end
            4'd5:  if (tcb_wr && (tcb_sel == 3'd4) && (tcb_id == 0))
                       begin scfg_upd_sel <= 3'd5; scfg_upd_val <= 32'd1; st <= 4'd14; end
            // sel5 = state <- 1 (ESTAB): 不写这一项 ⇒ TCB 状态恒 0 ⇒ app_ctrl 口径的
            //   app_tx_ready 恒 0 ⇒ app 发完首帧就 frm_wait 静默 (本 TB 踩过)
            4'd14: if (tcb_wr && (tcb_sel == 3'd5) && (tcb_id == 0))
                       begin scfg_upd_wr <= 0; cfg_up <= 1; cfg_up_id <= 0; st <= 4'd6; end
            4'd6:  begin cfg_up <= 0; wait_c <= 0; st <= 4'd7; end
            // SYN 的 seq 消耗 (+1): 一次 rx_upd (同 wrapper 的 tcp_rx 路径)
            4'd7:  if (wait_c < 4) wait_c <= wait_c + 1;
                   else begin rx_upd_wr <= 1; rx_upd_id <= 0; rx_upd_sel <= 3'd1;
                              rx_upd_val <= SEQ_ISN + 32'd1; st <= 4'd8; end
            4'd8:  if (rx_upd_gnt) begin rx_upd_wr <= 0; syn_bumped <= 1; st <= 4'd9; end
            // CONN_UP 事件 -> ev_up (app 起流)
            4'd9:  if (wait_c < 8) wait_c <= wait_c + 1;
                   else begin app_ev_up <= 1; app_ev_slot <= 4'd0; st <= 4'd10; end
            4'd10: begin app_ev_up <= 0; ev_pulsed <= 1; st <= 4'd11; end
            4'd11: begin
                // 全部帧收齐 + FIN 已发 -> 再等 3000 拍让余量落定
                if ((n_data >= NFRAME) && fin_pushed && o_fin_sent[0]) begin
                    if (close_wait < 3000) close_wait <= close_wait + 1;
                    else begin $display("  (all %0d frames + FIN done)", NFRAME);
                               summary_and_exit; end
                end
            end
            default: ;
            endcase
            if (cyc > CY_MAX) begin
                $display("  (cycle budget %0d reached)", CY_MAX);
                summary_and_exit;
            end
        end
    end

    // ===================== 汇总 =====================
    task summary_and_exit;
        reg [31:0] adv;
        begin
            $display("---------------- TB_INTEG_APP_TX SUMMARY ----------------");
            $display("FRAMES recv=%0d data=%0d ctrl=%0d fin=%0d cyc=%0d",
                     n_frames, n_data, n_ctrl, n_fin, cyc);
            $display("WIRE payload_bytes=%0d frontier_adv=%0d  DUT stat_frames=%0d stat_bytes=%0d stat_ack=%0d eend=%0d retx=%0d",
                     pay_sum, exp_new - seq0, stat_frames, stat_bytes, stat_ack,
                     stat_eend, stat_retx);
            $display("APP  tx_bytes=%0d tx_frames=%0d badframes=%0d close_req=%0d mismatch=%0d",
                     app_tx_bytes, app_tx_frames, app_bad_frames, app_close_req, app_mismatch);
            $display("T8   rx1460_min=%0d (主门/设计 189; 差 = 真 app 字流气泡)  full_frames=%0d  ovf_ok=%0d",
                     rx_min, full_n, tx_ovf_ok);
            $display("T8b  avg_cyc_per_data_frame=%0d  bytes_per_cyc_x1000=%0d  (app 8 路 = 8B/拍上限)",
                     cyc / ((n_data == 0) ? 1 : n_data), (pay_sum * 1000) / ((cyc == 0) ? 1 : cyc));
            $display("REDS parse=%0d csum=%0d payload=%0d seq=%0d", e_parse, e_csum, e_pay, e_seq);
            adv = exp_new - seq0;
            e_cons = 0;
            if (adv !== app_tx_bytes) begin e_cons = e_cons + 1;
                $display("[FAIL] integ J5: 前沿推进=%0d != app.tx_bytes=%0d", adv, app_tx_bytes); end
            if (pay_sum < app_tx_bytes) begin e_cons = e_cons + 1;
                $display("[FAIL] integ J5: 线上载荷=%0d < app.tx_bytes=%0d", pay_sum, app_tx_bytes); end
            if ((pay_sum - adv) > 32'd200000) begin e_cons = e_cons + 1;
                $display("[FAIL] integ J5: 重放量=%0d 超界 (只许少量回卷)", pay_sum - adv); end
            if (stat_eend != 32'd0) begin e_cons = e_cons + 1;
                $display("[FAIL] integ J6: stat_eend=%0d", stat_eend); end
            if (!tx_ovf_ok) begin e_cons = e_cons + 1;
                $display("[FAIL] integ J6: FIFO ovf_pulse != 0 (静默丢字)"); end
            if (n_fin < 1) begin e_cons = e_cons + 1;
                $display("[FAIL] integ J7: 线上无 FIN"); end
            if (app_bad_frames != 32'd0) begin e_cons = e_cons + 1;
                $display("[FAIL] integ: app 注入计数非 0"); end
            $display("REDS2 cons=%0d (J5 守恒/J6 静默丢/J7 收尾)", e_cons);
            if ((e_parse + e_csum + e_pay + e_seq + e_cons) == 0)
                $display("TB_INTEG_APP_TX: OK");
            else
                $display("TB_INTEG_APP_TX: FAIL reds=%0d",
                         e_parse + e_csum + e_pay + e_seq + e_cons);
            $finish;
        end
    endtask
endmodule
