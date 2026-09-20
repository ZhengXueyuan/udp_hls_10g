`timescale 1ns/1ps
//=============================================================================
// tb_p5_app: P5a app 接口全链 TB (APP_MODE 数据面, 不含 HLS 慢路径)
//
// 拓扑 (与 board/wrapper_p4.v 的 APP_MODE 分支同构):
//   GMII RX -> mac_rx_64 -> vlan_strip -> rx_classify -> tcp_rx -> tcp_echo
//            -> [app RX 端口] -> app_pattern (图案校验)
//   app_pattern (TX 图案) -> axis_pipe -> tcp_tx_frame -> tx_arb -> mac_tx_64 -> GMII
//   cfg: TB 直接注入 8 词 ADD 记录 -> slow_cfg_adp -> CAM/TCB + app_ctrl 事件源
//        (P5a 不引 HLS 网表: 事件/配置路径的时序由 TB 完全确定)
//
// PC 模型 (从 tb_p4_chain.v 移植): 捕获 GMII TX 的 conn0 数据帧, 每帧注入一个
//   纯 ACK (seq = 板侧 rcv_nxt, ack = 帧尾 seq+plen, 12+60+4+12 拍); 可选一次
//   数据段注入 (100B 图案载荷, +PC5RX 或默认开) 驱动 app RX 校验。
//
// 捕获 (resp_p5_app.memh): 每拍 "%02h %d" (gmii_txd, tx_en) + 事件行
//   FEND/ACK; 末尾统计行 (见 initial 尾部): P5EV 事件字 / P5REG 寄存器快照 /
//   P5TX / P5INV / STATS_/TCBF/ECOMAX 等。
//=============================================================================
module tb_p5_app;   // P5p5bWND adversarial copy
`ifdef P5_SMALL
    localparam [31:0] TB_TX_BYTES = 32'd65536;      // 门调试用小传输
`else
    localparam [31:0] TB_TX_BYTES = 32'd1048576;    // P5a 门: 1MB 图案
`endif
    localparam [31:0] TB_ISS      = 32'h12345678;   // 我方 ISS
    localparam [31:0] TB_SND_NXT0 = TB_ISS + 32'd1; // 首数据帧 seq (cfg w7)
    localparam [31:0] TB_PEER_ISS = 32'h20000000;
    localparam [31:0] TB_PEER_IP  = 32'hC0A86401;   // 192.168.100.1
    localparam [31:0] TB_MY_IP    = 32'hC0A86402;   // 192.168.100.2
    localparam [15:0] TB_PEER_PORT = 16'h3039;      // 对端端口 (PC)
    localparam [15:0] TB_MY_PORT   = 16'h1F90;      // 本机端口 8080
    localparam [47:0] TB_PEER_MAC  = 48'h112233445566;
    localparam [31:0] PEER_ISN     = 32'h20000000;  // 对端 ISS (rcv_nxt 基)
    localparam integer PC5RX_LEN   = 100;           // 注入数据段载荷字节
    localparam [63:0]  P5_SEED     = 64'h9E3779B97F4A7C15;   // 与 app_pattern 同种子

    function [63:0] xs_next;
        input [63:0] s;
        reg   [63:0] t;
        begin
            t = s ^ (s << 13);
            t = t ^ (t >> 7);
            t = t ^ (t << 17);
            xs_next = t;
        end
    endfunction

    reg        clk, rst_n;
    reg [7:0]  rx_d;
    reg        rx_dv, rx_er;
    reg [7:0]  stim_d [0:1048575];
    reg [7:0]  stim_v [0:1048575];
    reg [7:0]  stim_e [0:1048575];
    integer    nstim;
    reg [22:0] i;
    reg [31:0] k;
    reg        done;
    integer    fdi;
    integer    fd;    // resp 落盘 (flow 侧的 ACK 日志也要用)

    // ---------------- DUT 线网 ----------------
    wire [63:0] raw_tdata;  wire [7:0] raw_tkeep;
    wire        raw_tvalid, raw_tready, raw_tlast, raw_tuser, raw_tcrs, raw_terr;
    wire [63:0] vs_tdata;   wire [7:0] vs_tkeep;
    wire        vs_tvalid, vs_tready, vs_tlast, vs_tuser, vs_tcrs, vs_terr;
    wire [63:0] f_tdata;    wire [7:0] f_tkeep;
    wire        f_tvalid, f_tready, f_tlast, f_tuser, f_tcrs, f_terr;
    wire [63:0] sl_tdata;   wire [7:0] sl_tkeep;
    wire        sl_tvalid, sl_tready, sl_tlast, sl_tuser, sl_tcrs, sl_terr;
    // tcp_rx 载荷口
    wire [63:0] m_tdata;    wire [7:0] m_tkeep;
    wire        m_tvalid, m_tready, m_tlast;
    wire [1:0]  m_tuser;
    wire        fend, ferr, meta_valid;
    wire [3:0]  meta_conn_id;
    wire [15:0] meta_len;
    wire [3:0]  ra_id;
    wire [31:0] ra_rcv_nxt, ra_snd_nxt, ra_snd_una;
    wire [15:0] ra_rcv_wnd;
    wire [3:0]  ra_state, ra_wscale;
    wire        rx_upd_wr, rx_upd_gnt;
    wire [3:0]  rx_upd_id;
    wire [2:0]  rx_upd_sel;
    wire [31:0] rx_upd_val;
    wire        ack_req, retx_req, retx_gnt;
    wire [3:0]  ack_id, retx_id;
    wire [31:0] ack_val;
    wire [31:0] cam_q_sip, cam_q_dip;
    wire [15:0] cam_q_sport, cam_q_dport;
    wire        cam_q_hit;
    wire [3:0]  cam_q_id;
    wire [31:0] rx_stat_pass, rx_stat_nonmatch, rx_stat_ipcsum, rx_stat_crc,
                rx_stat_seq, rx_stat_ack, rx_stat_bytes, rx_stat_trunc;
    wire        syn_v;
    wire [47:0] syn_smac;
    wire [31:0] syn_sip;
    wire [15:0] syn_sport, syn_dport;
    wire [31:0] syn_seq;
    wire [15:0] syn_wnd;
    // tcp_echo -> pipe -> app RX
    wire [63:0] eco_tdata;  wire [7:0] eco_tkeep;
    wire        eco_tvalid, eco_tready, eco_tlast;
    wire [3:0]  eco_tid;
    wire [63:0] eco2_tdata; wire [7:0] eco2_tkeep;
    wire        eco2_tvalid, eco2_tready, eco2_tlast;
    wire [3:0]  eco2_tid;
    wire [76:0] eco2_pack;
    assign {eco2_tkeep, eco2_tlast, eco2_tdata, eco2_tid} = eco2_pack;
    wire [31:0] eco_stat_echo, eco_stat_drop_crc;
    // app TX -> pipe -> tcp_tx_frame
    wire [63:0] pat_tdata;  wire [7:0] pat_tkeep;
    wire        pat_tvalid, pat_tready, pat_tlast;
    wire [3:0]  pat_tid;
    wire [63:0] app2_tdata; wire [7:0] app2_tkeep;
    wire        app2_tvalid, app2_tready, app2_tlast;
    wire [3:0]  app2_tid;
    wire [76:0] app2_pack;
    assign {app2_tkeep, app2_tlast, app2_tdata, app2_tid} = app2_pack;
    // TCB
    wire [3:0]  rb_id;
    wire [31:0] rb_rcv_nxt, rb_snd_nxt, rb_snd_una;
    wire [15:0] rb_rcv_wnd, rb_snd_wnd;
    wire [3:0]  rb_state;
    wire        win_open;
    wire [15:0] win_inflight, win_wnd_eff;
    wire        tx_upd_wr;
    wire [3:0]  tx_upd_id;
    wire [2:0]  tx_upd_sel;
    wire [31:0] tx_upd_val;
    wire [3:0]  cam_rd_id;
    wire [47:0] cam_rd_dmac;
    wire [31:0] cam_rd_sip, cam_rd_dip;
    wire [15:0] cam_rd_sport, cam_rd_dport;
    // tcb 组合读口 C (app_ctrl)
    wire [3:0]  rc_id;
    wire [31:0] rc_snd_nxt, rc_snd_una, rc_rcv_nxt;
    wire [15:0] rc_rcv_wnd, rc_snd_wnd;
    wire [3:0]  rc_state;
    // tcp_tx_frame 输出
    wire [63:0] x_tdata;    wire [7:0] x_tkeep;
    wire        x_tvalid, x_tready, x_tlast;
    wire [31:0] tx_stat_frames, tx_stat_bytes, tx_stat_ack, tx_stat_ack_drop;
    wire [31:0] tx_stat_eend, tx_stat_retx, tx_stat_drop_len, tx_stat_fin,
                tx_stat_rst;
    wire [31:0] tx_retx_hi;
    wire        tx_retx_active, tx_retx_gnt;
    wire [3:0]  tx_retx_id;
    wire [15:0] tx_fin_sent;
    wire [15:0] app_tx_ready;
    // tx_arb -> mac_tx
    wire [63:0] a_tdata;    wire [7:0] a_tkeep;
    wire        a_tvalid, a_tready, a_tlast;
    wire [7:0]  gmii_txd;
    wire        gmii_tx_en;
    wire [31:0] mac_stat_frames, mac_stat_abort;
    wire [31:0] mac_stat_drop, mac_stat_crc_err;
    // slow_cfg_adp
    wire        scfg_cam_wr;
    wire [3:0]  scfg_cam_addr;
    wire [31:0] scfg_cam_sip, scfg_cam_dip;
    wire [15:0] scfg_cam_sport, scfg_cam_dport;
    wire [47:0] scfg_cam_dmac;
    wire        scfg_upd_wr;
    wire [3:0]  scfg_upd_id;
    wire [2:0]  scfg_upd_sel;
    wire [31:0] scfg_upd_val;
    wire        scfg_gnt;
    wire [31:0] scfg_add, scfg_del;
    wire        ev_up, ev_down;
    wire [3:0]  ev_slot;
    wire [31:0] ev_peer_ip;
    wire [15:0] ev_peer_port;
    wire [47:0] ev_peer_mac;
    reg  [31:0] cfg_tdata;
    reg         cfg_tvalid;
    wire        cfg_tready;
    // app_ctrl
    reg  [7:0]  ac_addr;
    reg         ac_wr;
    reg  [31:0] ac_wdata;
    wire [31:0] ac_rdata;
    wire        ac_ev_up, ac_ev_down;
    wire [3:0]  ac_ev_slot;
    wire [15:0] ac_fin_req, ac_rst_req;
    wire        pat_close_req;
    wire [3:0]  pat_close_id;
    wire [31:0] ac_ev_up_c, ac_ev_down_c, ac_ev_drop, ac_cmd_cls, ac_cmd_abt;
    wire [3:0]  ac_c0_state;
    wire [31:0] ac_c0_snd_nxt, ac_c0_snd_una, ac_c0_rcv_nxt;
    wire [15:0] ac_c0_rcv_wnd;
    wire [16:0] rx_occ;
    wire [13:0] eco_wptr, eco_rptr;
    wire        pat_rx_tready;
    wire [3:0]  pat_led;
    wire [31:0] pat_tx_bytes, pat_tx_frames, pat_rx_bytes, pat_mismatch, pat_lfsr;
    wire        pat_active, pat_done;
    wire [3:0]  pat_act_id;
    reg  [15:0] bad_idx;
    wire [31:0] pat_bad_frames;
`ifdef P5_FLOW
    // ---- P5b flow: 慢消费者 + 对端灌数据模型 线网 ----
    wire        sink_tready, sink_paused;
    wire [31:0] sink_bytes, sink_words, sink_frames, sink_mismatch;
    wire [31:0] sink_kaerr, sink_evfrm, sink_pause_cnt, sink_gap_max;
    wire        flow_fin;                 // flow 完成 (主驱动 done 用)
`endif
    // status uart
    wire        uart_txd;
    // P5b: 流控跨模块线网
    wire        fc_upd_wr, app_wu_req, app_wu_gnt;
    wire [3:0]  fc_upd_id, app_wu_id;
    wire [2:0]  fc_upd_sel;
    wire [31:0] fc_upd_val, app_wu_val;
    wire        fc_gnt;
    wire [15:0] ac_winq0, ac_wu_mark0, ac_stat_wu16, ac_stat_px16;
    wire [16:0] ac_pool;
    wire [31:0] ac_stat_wu, ac_stat_px;
    wire [31:0] tx_stat_ack_d;   // P5b: stat_ack_drop (P5a 未接)

    // ---- cam/tcb 仲裁 (tx > rx > cfg 级; cfg 级 = slow_cfg_adp 带 gnt) ----
    wire        cam_cfg_wr    = scfg_cam_wr;
    wire [3:0]  cam_cfg_addr  = scfg_cam_addr;
    wire [31:0] cam_cfg_sip   = scfg_cam_sip;
    wire [31:0] cam_cfg_dip   = scfg_cam_dip;
    wire [15:0] cam_cfg_sport = scfg_cam_sport;
    wire [15:0] cam_cfg_dport = scfg_cam_dport;
    wire [47:0] cam_cfg_dmac  = scfg_cam_dmac;

    // P5b: 第 4 级 fc 仲裁 (最低优先) — 与 board/wrapper_p4.v APP_MODE 支同构;
    // scfg_gnt 表达式逐字不变 (cfg 语义逐位不变是硬约束)
    wire        sel_tx = tx_upd_wr;
    wire        sel_rx = !sel_tx && rx_upd_wr;
    assign rx_upd_gnt = sel_rx;
    assign scfg_gnt   = !sel_tx && !sel_rx && scfg_upd_wr;
    wire        sel_fc = !sel_tx && !sel_rx && !scfg_upd_wr && fc_upd_wr;
    wire        tcb_wr  = sel_tx || sel_rx || (scfg_upd_wr && scfg_gnt) || sel_fc;
    wire [2:0]  tcb_sel = sel_tx ? tx_upd_sel : (sel_rx ? rx_upd_sel :
                          (scfg_upd_wr ? scfg_upd_sel : fc_upd_sel));
    wire [3:0]  tcb_id  = sel_tx ? tx_upd_id  : (sel_rx ? rx_upd_id  :
                          (scfg_upd_wr ? scfg_upd_id  : fc_upd_id));
    wire [31:0] tcb_val = sel_tx ? tx_upd_val : (sel_rx ? rx_upd_val :
                          (scfg_upd_wr ? scfg_upd_val : fc_upd_val));
    assign      fc_gnt  = sel_fc;

    // ======================= DUT =======================
    mac_rx_64 u_mac (
        .clk(clk), .rst_n(rst_n),
        .gmii_rxd(rx_d), .gmii_rx_dv(rx_dv), .gmii_rx_er(rx_er),
        .m_axis_tdata(raw_tdata), .m_axis_tkeep(raw_tkeep),
        .m_axis_tvalid(raw_tvalid), .m_axis_tready(raw_tready),
        .m_axis_tlast(raw_tlast), .m_axis_tuser(raw_tuser),
        .m_axis_terr(raw_terr), .m_axis_tcrs(raw_tcrs),
        // 只接 stat_drop (flow 判据 ② 要读); stat_frames/stat_crc_err 保持空接 ——
        // mac_rx_64 这两个输出在本工程里是 X (未驱动), 接进 STATS_MAC 落盘行会让
        // P5a checker 的 int() 解析炸掉 (实测)
        .stat_frames(), .stat_crc_err(),
        .stat_drop(mac_stat_drop), .stat_bytes()
    );

    vlan_strip u_vlan (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(raw_tdata), .s_axis_tkeep(raw_tkeep),
        .s_axis_tvalid(raw_tvalid), .s_axis_tready(raw_tready),
        .s_axis_tlast(raw_tlast), .s_axis_tuser(raw_tuser),
        .s_axis_tcrs(raw_tcrs), .s_axis_terr(raw_terr),
        .m_axis_tdata(vs_tdata), .m_axis_tkeep(vs_tkeep),
        .m_axis_tvalid(vs_tvalid), .m_axis_tready(vs_tready),
        .m_axis_tlast(vs_tlast), .m_axis_tuser(vs_tuser),
        .m_axis_tcrs(vs_tcrs), .m_axis_terr(vs_terr),
        .stat_stripped(), .dbg_vlan()
    );

    rx_classify u_classify (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(vs_tdata), .s_axis_tkeep(vs_tkeep),
        .s_axis_tvalid(vs_tvalid), .s_axis_tready(vs_tready),
        .s_axis_tlast(vs_tlast), .s_axis_tuser(vs_tuser),
        .s_axis_tcrs(vs_tcrs), .s_axis_terr(vs_terr),
        .m_fast_tdata(f_tdata), .m_fast_tkeep(f_tkeep),
        .m_fast_tvalid(f_tvalid), .m_fast_tready(f_tready),
        .m_fast_tlast(f_tlast), .m_fast_tuser(f_tuser),
        .m_fast_tcrs(f_tcrs), .m_fast_terr(f_terr),
        .m_slow_tdata(sl_tdata), .m_slow_tkeep(sl_tkeep),
        .m_slow_tvalid(sl_tvalid), .m_slow_tready(1'b1),   // 慢路径本门不用: 排空
        .m_slow_tlast(sl_tlast), .m_slow_tuser(sl_tuser),
        .m_slow_tcrs(sl_tcrs), .m_slow_terr(sl_terr),
        .stat_fast(), .stat_slow()
    );

    tcp_rx u_rx (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(f_tdata), .s_axis_tkeep(f_tkeep),
        .s_axis_tvalid(f_tvalid), .s_axis_tready(f_tready),
        .s_axis_tlast(f_tlast), .s_axis_tuser(f_tuser),
        .s_axis_tcrs(f_tcrs), .s_axis_terr(f_terr),
        .cfg_suppress_data_ack(1'b0),   // APP_MODE: 无 echo 捎带, 逐段纯 ACK
        .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep),
        .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready), .m_axis_tlast(m_tlast),
        .m_axis_tuser(m_tuser),
        .fend(fend), .ferr(ferr),
        .meta_valid(meta_valid), .meta_src_ip(), .meta_src_port(),
        .meta_len(meta_len), .meta_conn_id(meta_conn_id), .meta_seq(),
        .ra_id(ra_id),
        .ra_rcv_nxt(ra_rcv_nxt), .ra_snd_nxt(ra_snd_nxt), .ra_snd_una(ra_snd_una),
        .ra_rcv_wnd(ra_rcv_wnd), .ra_state(ra_state), .ra_wscale(ra_wscale),
        .ra_retx_hi(tx_retx_hi), .ra_retx_active(tx_retx_active),
        .upd_wr(rx_upd_wr), .upd_id(rx_upd_id), .upd_sel(rx_upd_sel),
        .upd_val(rx_upd_val), .upd_gnt(rx_upd_gnt),
        .ack_req(ack_req), .ack_id(ack_id), .ack_val(ack_val),
        .retx_req(retx_req), .retx_id(retx_id), .retx_gnt(retx_gnt),
        .syn_v(syn_v), .syn_smac(syn_smac), .syn_sip(syn_sip),
        .syn_sport(syn_sport), .syn_dport(syn_dport),
        .syn_seq(syn_seq), .syn_wnd(syn_wnd),
        .cam_q_sip(cam_q_sip), .cam_q_dip(cam_q_dip),
        .cam_q_sport(cam_q_sport), .cam_q_dport(cam_q_dport),
        .cam_q_hit(cam_q_hit), .cam_q_id(cam_q_id),
        .stat_pass(rx_stat_pass), .stat_drop_nonmatch(rx_stat_nonmatch),
        .stat_drop_ipcsum(rx_stat_ipcsum), .stat_drop_crc(rx_stat_crc),
        .stat_drop_seq(rx_stat_seq), .stat_ack(rx_stat_ack),
        .stat_bytes(rx_stat_bytes), .stat_drop_trunc(rx_stat_trunc)
    );

    // 零拷贝 app RX 缓冲 (与 wrapper APP_MODE 一致: tcp_echo 保留)
    tcp_echo u_echo (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(m_tdata), .s_axis_tkeep(m_tkeep),
        .s_axis_tvalid(m_tvalid), .s_axis_tready(m_tready), .s_axis_tlast(m_tlast),
        .s_axis_tuser(m_tuser), .fend(fend), .ferr(ferr),
        .meta_valid(meta_valid), .meta_conn_id(meta_conn_id), .meta_len(meta_len),
        .m_axis_tdata(eco_tdata), .m_axis_tkeep(eco_tkeep),
        .m_axis_tvalid(eco_tvalid), .m_axis_tready(eco_tready),
        .m_axis_tlast(eco_tlast), .m_axis_tid(eco_tid),
        .stat_echo(eco_stat_echo), .stat_drop_crc(eco_stat_drop_crc),
        .stat_tlast_wr(), .stat_tlast_fwd(),
        .dbg_fifo_full(), .dbg_state(), .dbg_fifo_empty(),
        .dbg_fifo_wptr(eco_wptr), .dbg_fifo_rptr(eco_rptr),
        .dbg_rd_addr(), .dbg_rd_side()
    );

    axis_pipe #(.W(77)) u_eco_pipe (
        .clk(clk), .rst_n(rst_n),
        .s_data({eco_tkeep, eco_tlast, eco_tdata, eco_tid}),
        .s_valid(eco_tvalid), .s_ready(eco_tready),
        .m_data(eco2_pack), .m_valid(eco2_tvalid), .m_ready(eco2_tready)
    );

    tcp_cam u_cam (
        .clk(clk), .rst_n(rst_n),
        .cfg_wr(cam_cfg_wr), .cfg_addr(cam_cfg_addr),
        .cfg_sip(cam_cfg_sip), .cfg_dip(cam_cfg_dip),
        .cfg_sport(cam_cfg_sport), .cfg_dport(cam_cfg_dport),
        .cfg_dmac(cam_cfg_dmac),
        .q_sip(cam_q_sip), .q_dip(cam_q_dip),
        .q_sport(cam_q_sport), .q_dport(cam_q_dport),
        .q_id(cam_q_id), .q_hit(cam_q_hit),
        .rd_id(cam_rd_id), .rd_dmac(cam_rd_dmac), .rd_sip(cam_rd_sip),
        .rd_dip(cam_rd_dip), .rd_sport(cam_rd_sport), .rd_dport(cam_rd_dport)
    );

    tcb u_tcb (
        .clk(clk), .rst_n(rst_n),
        .ra_id(ra_id), .ra_rcv_nxt(ra_rcv_nxt), .ra_snd_nxt(ra_snd_nxt),
        .ra_snd_una(ra_snd_una), .ra_rcv_wnd(ra_rcv_wnd), .ra_snd_wnd(),
        .ra_state(ra_state), .ra_wscale(ra_wscale),
        .rb_id(rb_id), .rb_rcv_nxt(rb_rcv_nxt), .rb_snd_nxt(rb_snd_nxt),
        .rb_snd_una(rb_snd_una), .rb_rcv_wnd(rb_rcv_wnd), .rb_snd_wnd(rb_snd_wnd),
        .rb_state(rb_state),
        .win_id(rb_id), .win_open(win_open),
        .win_inflight(win_inflight), .win_wnd_eff(win_wnd_eff),
        .dbg_snd_nxt0(), .dbg_snd_una0(), .dbg_rcv_nxt0(), .dbg_snd_wnd0(),
        .dbg_wscale0(), .dbg_state0(),
        // P5: 组合读口 C (app_ctrl 轮扫)
        .rc_id(rc_id), .rc_snd_nxt(rc_snd_nxt), .rc_snd_una(rc_snd_una),
        .rc_rcv_nxt(rc_rcv_nxt), .rc_rcv_wnd(rc_rcv_wnd), .rc_snd_wnd(rc_snd_wnd),
        .rc_state(rc_state),
        .upd_wr(tcb_wr), .upd_id(tcb_id), .upd_sel(tcb_sel), .upd_val(tcb_val)
    );

    slow_cfg_adp u_slow_cfg (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(cfg_tdata), .s_axis_tvalid(cfg_tvalid),
        .s_axis_tready(cfg_tready),
        .cam_cfg_wr(scfg_cam_wr), .cam_cfg_addr(scfg_cam_addr),
        .cam_cfg_sip(scfg_cam_sip), .cam_cfg_dip(scfg_cam_dip),
        .cam_cfg_sport(scfg_cam_sport), .cam_cfg_dport(scfg_cam_dport),
        .cam_cfg_dmac(scfg_cam_dmac),
        .upd_wr(scfg_upd_wr), .upd_id(scfg_upd_id),
        .upd_sel(scfg_upd_sel), .upd_val(scfg_upd_val),
        .cfg_gnt(scfg_gnt), .stat_add(scfg_add), .stat_del(scfg_del),
        // P5: 连接事件源
        .ev_up(ev_up), .ev_down(ev_down), .ev_slot(ev_slot),
        .ev_peer_ip(ev_peer_ip), .ev_peer_port(ev_peer_port),
        .ev_peer_mac(ev_peer_mac)
    );

    tcp_tx_frame u_tx (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(app2_tdata), .s_axis_tkeep(app2_tkeep),
        .s_axis_tvalid(app2_tvalid), .s_axis_tready(app2_tready),
        .s_axis_tlast(app2_tlast), .s_axis_tid(app2_tid),
        .ack_req(ack_req), .ack_id(ack_id), .ack_val(ack_val),
        .ack_syn(1'b0), .ack_fin(1'b0), .ack_rst(1'b0),
        .rb_id(rb_id), .rb_snd_nxt(rb_snd_nxt), .rb_rcv_nxt(rb_rcv_nxt),
        .rb_rcv_wnd(rb_rcv_wnd), .rb_snd_una(rb_snd_una), .rb_snd_wnd(rb_snd_wnd),
        .rb_state(rb_state),
        .win_open(win_open), .win_inflight(win_inflight), .win_wnd_eff(win_wnd_eff),
        .upd_wr(tx_upd_wr), .upd_id(tx_upd_id), .upd_sel(tx_upd_sel),
        .upd_val(tx_upd_val),
        .cam_rd_id(cam_rd_id), .cam_rd_dmac(cam_rd_dmac), .cam_rd_sip(cam_rd_sip),
        .cam_rd_sport(cam_rd_sport), .cam_rd_dport(cam_rd_dport),
        .cfg_src_mac(48'h000A3501FEC0), .cfg_src_ip(TB_MY_IP),
        .m_axis_tdata(x_tdata), .m_axis_tkeep(x_tkeep),
        .m_axis_tvalid(x_tvalid), .m_axis_tready(x_tready), .m_axis_tlast(x_tlast),
        .stat_frames(tx_stat_frames), .stat_bytes(tx_stat_bytes),
        .stat_ack(tx_stat_ack), .stat_ack_drop(tx_stat_ack_drop),
        .stat_eend(tx_stat_eend),
        .stat_drop_len(tx_stat_drop_len), .stat_fin(tx_stat_fin),
        .stat_rst(tx_stat_rst),
        .stat_tlast_in(),
        .retx_req(retx_req), .retx_id(retx_id), .retx_gnt(tx_retx_gnt),
        .stat_retx(tx_stat_retx),
        .o_retx_hi(tx_retx_hi), .o_retx_active(tx_retx_active),
        .o_retx_id(tx_retx_id),
        // P5: FIN/RST 通道 (app_ctrl 驱动)
        .fin_req(ac_fin_req), .rst_req(ac_rst_req), .o_fin_sent(tx_fin_sent),
        // P5a D1: cfg ADD 收尾脉冲清该槽 FIN/RST 已发标志 (同槽重连必需)
        .cfg_up(ev_up), .cfg_up_id(ev_slot),
        // P5b: wu 条目通道 (app_ctrl 驱动)
        .wu_req(app_wu_req), .wu_id(app_wu_id), .wu_val(app_wu_val),
        .wu_gnt(app_wu_gnt),
        .dbg_wnd_open(), .dbg_pay_full(), .dbg_sready(), .dbg_saxis_tvalid(),
        .dbg_plen_r(), .dbg_state(tx_fsm_state_w), .dbg_pay_wptr(), .dbg_pay_rptr(),
        .dbg_pay_full2(), .dbg_pay_empty(), .dbg_plen()
    );

    tx_arb u_tx_arb (
        .clk(clk), .rst_n(rst_n),
        .s_fast_tdata(x_tdata), .s_fast_tkeep(x_tkeep), .s_fast_tvalid(x_tvalid),
        .s_fast_tready(x_tready), .s_fast_tlast(x_tlast),
        .s_slow_tdata(64'd0), .s_slow_tkeep(8'd0), .s_slow_tvalid(1'b0),
        .s_slow_tready(), .s_slow_tlast(1'b0),
        .m_axis_tdata(a_tdata), .m_axis_tkeep(a_tkeep), .m_axis_tvalid(a_tvalid),
        .m_axis_tready(a_tready), .m_axis_tlast(a_tlast)
    );

    mac_tx_64 u_mactx (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(a_tdata), .s_axis_tkeep(a_tkeep),
        .s_axis_tvalid(a_tvalid), .s_axis_tready(a_tready), .s_axis_tlast(a_tlast),
        .gmii_txd(gmii_txd), .gmii_tx_en(gmii_tx_en), .gmii_tx_er(),
        .stat_frames(mac_stat_frames), .stat_abort(mac_stat_abort)
    );

    // ---- app TX 图案 -> 帧器 (1 拍流水寄存器) ----
    axis_pipe #(.W(77)) u_app_pipe (
        .clk(clk), .rst_n(rst_n),
        .s_data({pat_tkeep, pat_tlast, pat_tdata, pat_tid}),
        .s_valid(pat_tvalid), .s_ready(pat_tready),
        .m_data(app2_pack), .m_valid(app2_tvalid), .m_ready(app2_tready)
    );

`ifdef P5_FLOW
    // ==========================================================================
    // P5b flow 模式: app 侧 = 慢消费者 (tb_app_sink), **不发 app 数据**
    // (flow 用例专测 RX 方向: 对端灌数据 -> 板侧窗口收缩/重开 + wu ACK)
    // ==========================================================================
    tb_app_sink #(
        .RATE(8), .RATE2(8),
        .PAUSE_AT(65536), .PAUSE_LEN(150000),
        .PAUSE2_AT(262144), .PAUSE2_LEN(120000)
    ) u_sink (
        .clk(clk), .rst_n(rst_n),
        .tdata(eco2_tdata), .tkeep(eco2_tkeep), .tvalid(eco2_tvalid),
        .tready(sink_tready), .tlast(eco2_tlast), .tid(eco2_tid),
        .stat_bytes(sink_bytes), .stat_words(sink_words),
        .stat_frames(sink_frames), .stat_mismatch(sink_mismatch),
        .stat_kaerr(sink_kaerr), .stat_evfrm(sink_evfrm),
        .dbg_pause_cnt(sink_pause_cnt), .dbg_gap_max(sink_gap_max),
        .paused(sink_paused)
    );
    assign eco2_tready = sink_tready;
    // app TX 通路静默: 帧器 s_axis 恒无有效字 (tvalid=0) ⇒ 板上只出纯 ACK
    assign pat_tdata  = 64'd0;
    assign pat_tkeep  = 8'h00;
    assign pat_tvalid = 1'b0;
    assign pat_tlast  = 1'b0;
    assign pat_tid    = 4'd0;
    assign pat_close_req = 1'b0;
    assign pat_close_id  = 4'd0;
    // 状态行/主驱动替代量 (sink 统计 + 常量; app_pattern 在 flow 模式不存在)
    assign pat_rx_bytes   = sink_bytes;
    assign pat_tx_bytes   = 32'd0;
    assign pat_tx_frames  = 32'd0;
    assign pat_mismatch   = sink_mismatch;
    assign pat_bad_frames = 32'd0;
    assign pat_active     = ~flow_fin;
    assign pat_act_id     = 4'd0;
    assign pat_done       = flow_fin;
    assign pat_lfsr       = 64'd0;
    assign pat_led        = 4'd0;
`else
    app_pattern #(.TX_BYTES(TB_TX_BYTES)) u_app (
        .clk(clk), .rst_n(rst_n),
        .ev_up(ac_ev_up), .ev_down(ac_ev_down), .ev_slot(ac_ev_slot),
        .m_tdata(pat_tdata), .m_tkeep(pat_tkeep), .m_tvalid(pat_tvalid),
        .m_tready(pat_tready), .m_tlast(pat_tlast), .m_tid(pat_tid),
        .app_tx_ready(app_tx_ready),
        .close_req(pat_close_req), .close_id(pat_close_id),
        .rx_tdata(eco2_tdata), .rx_tkeep(eco2_tkeep), .rx_tvalid(eco2_tvalid),
        .rx_tready(pat_rx_tready), .rx_tlast(eco2_tlast), .rx_tid(eco2_tid),
        .i_bad_frame(bad_idx),
        .stat_tx_bytes(pat_tx_bytes), .stat_tx_frames(pat_tx_frames),
        .stat_bad_frames(pat_bad_frames),
        .stat_rx_bytes(pat_rx_bytes), .stat_mismatch(pat_mismatch),
        .active(pat_active), .act_id(pat_act_id), .done(pat_done),
        .dbg_lfsr(pat_lfsr), .led(pat_led)
    );

    // ---- app RX 端口: echo 缓冲输出 -> app_pattern 校验器 ----
    assign eco2_tready = pat_rx_tready;
`endif


`ifdef P5_FLOW
    // ==========================================================================
    // P5b flow: 对端 PC 灌数据模型 (尊重板侧通告窗口) + 逐拍占用断言
    // ==========================================================================
    // 与 P5a 的 "逐帧应答" 模型不同: 这里是**发送方** ——
    //   · 自己的 snd_nxt = psnd_nxt (从 PEER_ISN+1 起连续)
    //   · 允许右沿 praw = 最近一条板侧 ACK 的 (ack + window)
    //     (窗口字段 = TCB.rcv_wnd, 由 app_ctrl 的 fc 写动态维护)
    //   · 段长 = min(1460, praw - psnd_nxt, 剩余); 窗口内可发则立刻发下一段
    //   · 载荷 = xorshift64 图案 (连续; tb_app_sink 逐字节比对)
    // 启动: praw 初值 = ISN + 1460 (TCP 式小初始窗, 不预设板侧窗口值) —— 首段
    // 到达后板侧回 ACK, praw 随即由 ACK 学到真实窗口 (自举, 不作弊)。
    localparam [31:0] FLOW_ISN   = PEER_ISN + 32'd1;
    localparam [31:0] FLOW_TOTAL = 32'd524288;        // 512KB (远超 48KB 窗口)
    localparam [31:0] FLOW_END   = FLOW_ISN + FLOW_TOTAL;
    localparam [11:0] SEG_MAX    = 12'd1460;
    // 逐拍占用断言阈值 (规格 C1b):
    //   实际通告右沿 = redge_old + delta, delta = 扫描拍->ACK 组装拍之间 rcv_nxt
    //   的增长, 上界 = ackq 深 x 每 ACK 帧拍数 x 到达速率 = 32 x 88 x 1 = 2816 B
    //   (1G); U = 单段最大字节 1460 + 54 + 4 = 1518 (在飞段)。
    localparam integer OCC_DELTA = 2816;
    localparam integer OCC_UNIT  = 1518;
    localparam [16:0] WINQ_REF   = 17'hC000;          // 单连接配额 (= WIN_POOL)
    localparam [16:0] OCC_SOFT   = WINQ_REF + OCC_DELTA + OCC_UNIT;
    localparam [16:0] OCC_HARD   = 17'd65528;         // 物理 65536, 留 1 字余量

    reg  [7:0]  fbuf [0:2047];       // 前导 + 帧体 + FCS (<= 1526)
    reg  [12:0] fblen;               // 播放字节数 (8 + 54 + slen + 4)
    reg  [12:0] fpi;                 // 播放索引 (含 12 拍 IFG)
    reg         flow_play;
    reg  [3:0]  flow_gap;            // 帧间 IFG 计数
    reg  [31:0] psnd_nxt, praw, praw_prev;
    reg  [63:0] plfsr;
    reg  [31:0] pack_cnt;            // 收到的板侧 conn0 ACK 数
    reg         praw_seen;
    reg  [31:0] praw_back;           // 右沿回退次数 (序比较; 粘滞计数)
    reg  [31:0] occ_max, occ_soft_v, occ_hard_v;
    reg  [31:0] psent_bytes;
    // ---- TCP 失序恢复 (对端侧) ----
    reg  [31:0] puna;             // 对端 snd_una (= 板侧 ACK 的 ack)
    reg  [31:0] dup_cnt;          // 连续不推进的 ACK 数 (dup-ACK)
    reg  [31:0] rto_cnt;          // 无进展拍数 (RTO 兜底)
    reg         pretx_act;
    reg  [31:0] pretx_seq, pretx_end;
    reg  [63:0] plfsr_rt;         // 重传期间的图案状态 (连续推进)
    reg  [31:0] stat_peer_retx;   // 对端重传段数 (报告用)
    localparam integer RETX_SPAN = 4380;   // 单次 go-back-N 跨度 (3 段)
    localparam [31:0]  RTO_T     = 32'd400_000;  // RTO 兜底拍数 (~3.2ms @125MHz)
    reg  [31:0] flow_quiet;          // 静默拍数 (无 RX 活动)
    reg  [31:0] sink_bytes_r;        // sink 消费快照 (静默判定)

    // ---- 组帧 + 启动播放 (task: 零时间完成) ----
    task flow_build;
        input [31:0] sq;
        input [11:0] slen;
        input [63:0] s0;          // 起始图案状态 (正常发送 = plfsr; 重传 = 定位值)
        reg [15:0] tot, tlen;
        reg [31:0] crc, tsum;
        reg [63:0] tls;
        reg [15:0] cs;
        integer    jj;
        begin
            tls  = s0;
            tlen = 16'd20 + {4'b0, slen};
            tot  = 16'd40 + {4'b0, slen};
            for (jj = 0; jj < 8; jj = jj + 1)
                fbuf[jj] = (jj == 7) ? 8'hD5 : 8'h55;      // 前导
            fbuf[8]=8'h00; fbuf[9]=8'h0A; fbuf[10]=8'h35; fbuf[11]=8'h01;
            fbuf[12]=8'hFE; fbuf[13]=8'hC0;                // dst = 板 MAC
            fbuf[14]=8'h11; fbuf[15]=8'h22; fbuf[16]=8'h33; fbuf[17]=8'h44;
            fbuf[18]=8'h55; fbuf[19]=8'h66;                // src = 对端 MAC
            fbuf[20]=8'h08; fbuf[21]=8'h00;
            fbuf[22]=8'h45; fbuf[23]=8'h00;
            fbuf[24]=tot[15:8]; fbuf[25]=tot[7:0];
            fbuf[26]=8'h77; fbuf[27]=8'h77; fbuf[28]=8'h00; fbuf[29]=8'h00;
            fbuf[30]=8'h40; fbuf[31]=8'h06;
            cs = ip_csum_inj(tot);
            fbuf[32]=cs[15:8]; fbuf[33]=cs[7:0];
            fbuf[34]=8'hC0; fbuf[35]=8'hA8; fbuf[36]=8'h64; fbuf[37]=8'h01;
            fbuf[38]=8'hC0; fbuf[39]=8'hA8; fbuf[40]=8'h64; fbuf[41]=8'h02;
            fbuf[42]=8'h30; fbuf[43]=8'h39;                // sport 3039
            fbuf[44]=8'h1F; fbuf[45]=8'h90;                // dport 1F90
            fbuf[46]=sq[31:24]; fbuf[47]=sq[23:16];
            fbuf[48]=sq[15:8];  fbuf[49]=sq[7:0];
            fbuf[50]=TB_SND_NXT0[31:24]; fbuf[51]=TB_SND_NXT0[23:16];
            fbuf[52]=TB_SND_NXT0[15:8];  fbuf[53]=TB_SND_NXT0[7:0];
            fbuf[54]=8'h50; fbuf[55]=8'h18;                // doff + PSH/ACK
            fbuf[56]=8'h40; fbuf[57]=8'h40;                // 对端自己的窗口
            fbuf[58]=8'h00; fbuf[59]=8'h00;                // csum 占位
            fbuf[60]=8'h00; fbuf[61]=8'h00;                // urg
            // 载荷 (线上字节序; 图案连续)
            for (jj = 0; jj < slen; jj = jj + 1) begin
                fbuf[62 + jj] = tls[31:24];
                tls = xs_next(tls);
            end
            // TCP 校验和 (伪头 + TCP 头 + 载荷; csum 字段按 0 计)
            tsum = 32'hC0A8 + 32'h6401 + 32'hC0A8 + 32'h6402 + 32'h0006 +
                   {16'b0, tlen};
            tsum = tsum + 32'h3039 + 32'h1F90;
            tsum = tsum + {sq[31:16]} + {sq[15:0]};
            tsum = tsum + TB_SND_NXT0[31:16] + TB_SND_NXT0[15:0];
            tsum = tsum + 32'h5018 + 32'h4040;
            for (jj = 0; jj < slen; jj = jj + 2) begin
                if ((jj + 1) < slen) tsum = tsum + {fbuf[62+jj], fbuf[63+jj]};
                else                 tsum = tsum + {fbuf[62+jj], 8'h00};
            end
            tsum = (tsum & 32'hFFFF) + (tsum >> 16);
            tsum = (tsum & 32'hFFFF) + (tsum >> 16);
            fbuf[58] = ~tsum[15:8];
            fbuf[59] = ~tsum[7:0];
            // FCS (帧体 = fbuf[8 .. 61+slen], 共 54+slen 字节; zlib 值小端)
            crc = 32'hFFFFFFFF;
            for (jj = 0; jj < (54 + slen); jj = jj + 1)
                crc = crc32b(crc, fbuf[8 + jj]);
            crc = ~crc;
            fbuf[62 + slen]     = crc[7:0];
            fbuf[62 + slen + 1] = crc[15:8];
            fbuf[62 + slen + 2] = crc[23:16];
            fbuf[62 + slen + 3] = crc[31:24];
            fblen  = 13'd62 + {1'b0, slen} + 13'd4;    // 8 前导 + 54 + slen + 4
            plfsr      <= tls;      // 正常发送: 图案流继续推进
            plfsr_rt   <= tls;      // 重传: 本段的下一段状态 (重传流同样连续)
        end
    endtask

    // ---- 图案流定位: 求 seq = target 处的图案状态 (重传起点用) ----
    // 一次性 O(offset) 循环 (最多几十万步, 只在重传触发时执行)
    task flow_seek;
        input [31:0] target;
        integer      n;
        reg   [63:0] t;
        begin
            t = P5_SEED;
            for (n = 0; n < (target - FLOW_ISN); n = n + 1)
                t = xs_next(t);
            plfsr_rt = t;
        end
    endtask

    // ---- 可发判定: 窗口内有空间且未发完 ----
    wire signed [31:0] flow_room = $signed(praw - psnd_nxt);
    // 段长 = min(1460, 窗口余量, 到 FLOW_END 的余量)。**必须**含 FLOW_END 钳位:
    // 只判"窗口够 1460"就发会让最后一段越界 (实测多发 156B ⇒ 总量 524444 != 524288)
    wire [31:0] flow_end_left = FLOW_END - psnd_nxt;
    wire [11:0] flow_slen =
        (flow_end_left == 32'd0)                            ? 12'd0 :
        ((flow_room >= 32'sd1460) && (flow_end_left >= 32'd1460)) ? SEG_MAX :
        (flow_room >= flow_end_left) ?
            ((flow_end_left >= 32'd1460) ? SEG_MAX : flow_end_left[11:0]) :
        (flow_room > 32'sd0) ? flow_room[11:0] : 12'd0;
    // 发送门还要等连接建立: cfg 序列 (ADD 八字段 + state=1) 完成前发出去的帧
    // 在 CAM 里查不到 ⇒ 被 RX 侧丢 (无 ACK ⇒ praw 永不更新 ⇒ 对端停在自举窗)。
    wire        flow_conn_ok = (u_tcb.state_r[0] == 4'd1);
    // 发送门: 窗口有余量 + 连接已建 + **整段才发** (除非是收尾段)。
    // 为什么要整段: 窗口收缩期会出现 0 < room < 1460 的"零头", 若据此发短段, 实测
    // 触发 DUT 侧 tcp_rx 的 pcount 泄漏异常 (短段紧跟长段时 pcount 未清, 1458 的
    // 残值当场触发"帧身超过 total_len"⇒ 该段被丢弃 ⇒ 空洞 ⇒ 后续全乱序);
    // 真实 TCP 发送端也有同样的整段/收尾约束 (SWS 规避), 故 TB 侧按此建模。
    // [P5b 测试 agent 对抗改造] 去掉实现 agent 的 "整段才发" 绕行 (D9):
    // 真实 TCP 发送端 (peer.cpp:1238) 发的是 min(mss, room) ⇒ 窗口吃紧时必然
    // 产生 "零头段"; 原 flow_can 把这个工况从门里删掉了 ⇒ 门绿但关键路径无人看守。
    wire        flow_can = (flow_room > 32'sd0) && (psnd_nxt < FLOW_END) &&
                           flow_conn_ok;
    // 重传段长: 1460, 或到 pretx_end 的余量 (末段)
    wire [31:0] flow_rt_left = pretx_end - pretx_seq;
    wire [11:0] flow_slen_rt = (flow_rt_left >= 32'd1460) ? 12'd1460 :
                               flow_rt_left[11:0];
    // 重传触发: 连续 3 个 dup-ACK (快速重传) 或 RTO 兜底; 必须有未确认数据
    wire        flow_retx_go = !pretx_act && (psnd_nxt != puna) &&
                               ((dup_cnt >= 32'd3) || (rto_cnt >= RTO_T));

    // ---- 收板侧 conn0 ACK: 右沿 = ack + window ----
    reg [7:0]  fcap [0:63];
    reg [6:0]  fcapn;
    reg        fen_d, finf;
    reg [31:0] f_new_right;
    always @(posedge clk) begin
        if (!rst_n) begin
            fen_d <= 1'b0; finf <= 1'b0; fcapn <= 7'd0;
        end else begin
            fen_d <= gmii_tx_en;
            if (gmii_tx_en) begin
                if (!fen_d) begin finf <= 1'b0; fcapn <= 7'd0; end
                else if (!finf) begin
                    if (gmii_txd == 8'hD5) finf <= 1'b1;
                end else if (fcapn < 7'd56) begin
                    fcap[fcapn] <= gmii_txd;
                    fcapn <= fcapn + 7'd1;
                end
            end else if (fen_d) begin
                // 帧尾: conn0 TCP (sport 1F90 -> dport 3039)
                if (finf && (fcapn >= 7'd50) && fcap[12] == 8'h08 &&
                    fcap[13] == 8'h00 && fcap[23] == 8'h06 &&
                    fcap[34] == 8'h1F && fcap[35] == 8'h90 &&
                    fcap[36] == 8'h30 && fcap[37] == 8'h39) begin
                    f_new_right = {fcap[42], fcap[43], fcap[44], fcap[45]} +
                                  {16'b0, fcap[48], fcap[49]};
                    praw      <= f_new_right;
                    praw_prev <= praw;
                    // snd_una 维护: ack 推进则清 dup/RTO 计数, 否则累计
                    if ({fcap[42], fcap[43], fcap[44], fcap[45]} != puna) begin
                        puna    <= {fcap[42], fcap[43], fcap[44], fcap[45]};
                        dup_cnt <= 32'd0;
                        rto_cnt <= 32'd0;
                    end else if (psnd_nxt != puna) begin
                        dup_cnt <= dup_cnt + 32'd1;
                    end
                    // 右沿回退 (序比较) 观测: 应为 0 (C1 单调)
                    if (praw_seen && ($signed(f_new_right - praw) < 32'sd0))
                        praw_back <= praw_back + 32'd1;
                    praw_seen <= 1'b1;
                    pack_cnt  <= pack_cnt + 32'd1;
                    $fwrite(fd, "P5ACK %0d %08h %04h %08h\n", pack_cnt,
                            {fcap[42], fcap[43], fcap[44], fcap[45]},
                            {fcap[48], fcap[49]}, f_new_right);
                end
            end
        end
    end

    // ---- 丢弃时刻快照 (调试: tcp_rx seq 丢弃 = 超窗/乱序时打印现场) ----
    reg [31:0] dseq_r;
    reg [31:0] dnm_r;
    always @(posedge clk) begin
        if (!rst_n) dseq_r <= 32'd0;
        else begin
            dseq_r <= rx_stat_seq;
            dnm_r  <= rx_stat_nonmatch;
            if ((rx_stat_nonmatch != dnm_r) && (rx_stat_nonmatch != 32'd0))
                $display("NOMATCH k=%0d st=%0d wcnt=%0d pcount=%0d plen=%0d fsm=%0d tdata=%016h tkeep=%02h tlast=%0d psnd=%08h",
                         k, u_tcb.state_r[0], u_rx.wcnt, u_rx.pcount,
                         u_rx.plen_l, u_rx.state, f_tdata, f_tkeep, f_tlast,
                         psnd_nxt);
            if ((rx_stat_seq != dseq_r) && (rx_stat_seq != 32'd0))
                $display("DROP k=%0d rcv_nxt=%08h wnd=%04x occ=%0d redge=%08h right=%08h praw=%08h psnd=%08h lastpraw_ack=%08h",
                         k, u_tcb.rcv_nxt_r[0], u_tcb.rcv_wnd_r[0], rx_occ,
                         u_app_ctrl.redge[0], u_app_ctrl.redge[0] + 0, praw,
                         psnd_nxt, u_tcb.rcv_nxt_r[0] + u_tcb.rcv_wnd_r[0]);
        end
    end

    // ---- 逐拍占用断言 (C1b: 软界 = winq + delta + U; 硬界 = 物理容量) ----
    always @(posedge clk) begin
        if (rst_n) begin
            if (rx_occ > occ_max[16:0]) occ_max <= {15'b0, rx_occ};
            if (rx_occ > OCC_SOFT) occ_soft_v <= occ_soft_v + 32'd1;
            if (rx_occ >= OCC_HARD) occ_hard_v <= occ_hard_v + 32'd1;
        end
    end

    // ---- 失序恢复触发 (断点 = puna, 重放 [puna, min(puna+3段, psnd_nxt)) ) ----
    always @(posedge clk) begin
        if (!rst_n) begin
            pretx_act <= 1'b0; pretx_seq <= 32'd0; pretx_end <= 32'd0;
            dup_cnt <= 32'd0; rto_cnt <= 32'd0; stat_peer_retx <= 32'd0;
        end else begin
            if (flow_retx_go) begin
                pretx_act <= 1'b1;
                pretx_seq <= puna;
                pretx_end <= ((puna + RETX_SPAN[31:0]) > psnd_nxt) ?
                             psnd_nxt : (puna + RETX_SPAN[31:0]);
                dup_cnt   <= 32'd0;
                rto_cnt   <= 32'd0;
                flow_seek(puna);        // 定位图案流 (重传数据必须逐字节原样)
                $display("PRETX k=%0d puna=%08h psnd=%08h dup=%0d rto=%0d", k,
                         puna, psnd_nxt, dup_cnt, rto_cnt);
            end
        end
    end

    // ---- 静默计数 (完成判定: 发完 + 收完 + 无活动) ----
    always @(posedge clk) begin
        if (!rst_n) begin
            flow_quiet <= 32'd0; sink_bytes_r <= 32'd0;
        end else begin
            if ((sink_bytes != sink_bytes_r) || gmii_tx_en || flow_play) begin
                flow_quiet   <= 32'd0;
                sink_bytes_r <= sink_bytes;
            end else if (flow_quiet != 32'hFFFFFFFF) begin
                flow_quiet <= flow_quiet + 32'd1;
            end
            // RTO 兜底计时: 有未确认数据且无进展
            if ((psnd_nxt != puna) && (rto_cnt != 32'hFFFFFFFF))
                rto_cnt <= rto_cnt + 32'd1;
            else if (psnd_nxt == puna)
                rto_cnt <= 32'd0;
        end
    end

    // ---- 调试轨迹 (每 200K 拍; $display 不缓冲, 死锁时能看出卡在哪) ----
    always @(posedge clk) begin
        if (rst_n && ((k % 32'd200_000) == 32'd0))
            $display("FLOWTR k=%0d sent=%0d sink=%0d praw=%08h psnd=%08h occ=%0d rxpass=%0d rxcrc=%0d rxseq=%0d rxnomat=%0d macfr=%0d maccrc=%0d macdrop=%0d ack=%0d pause=%0d st=%0d",
                     k, psent_bytes, sink_bytes, praw, psnd_nxt, rx_occ,
                     rx_stat_pass, rx_stat_crc, rx_stat_seq, rx_stat_nonmatch,
                     mac_stat_frames, mac_stat_crc_err, mac_stat_drop,
                     tx_stat_ack, sink_pause_cnt, u_tcb.state_r[0]);
    end

    // 完成: 全部发完 + 全部消费 + 静默 200K 拍 (窗口重开/收尾 ACK 都跑完)
    assign flow_fin = (psnd_nxt >= FLOW_END) && (sink_bytes >= FLOW_TOTAL) &&
                      (flow_quiet >= 32'd200000);
`endif

    // ---- app RX 缓冲占用 (echo frame_fifo 字节数) ----
    assign rx_occ = {(eco_wptr - eco_rptr), 3'b0};

    app_ctrl #(.WIN_CAP(16'hBFFE)) u_app_ctrl (
        .clk(clk), .rst_n(rst_n),
        .ev_up(ev_up), .ev_down(ev_down), .ev_slot(ev_slot),
        .ev_peer_ip(ev_peer_ip), .ev_peer_port(ev_peer_port),
        .ev_peer_mac(ev_peer_mac),
        .rc_id(rc_id), .rc_snd_nxt(rc_snd_nxt), .rc_snd_una(rc_snd_una),
        .rc_rcv_nxt(rc_rcv_nxt), .rc_rcv_wnd(rc_rcv_wnd),
        .rc_snd_wnd(rc_snd_wnd), .rc_state(rc_state),
        .rx_occ_bytes(rx_occ), .fin_sent(tx_fin_sent),
        // P5b: 窗口纠偏写 + 窗口更新 ACK
        .fc_upd_wr(fc_upd_wr), .fc_upd_id(fc_upd_id),
        .fc_upd_sel(fc_upd_sel), .fc_upd_val(fc_upd_val),
        .fc_gnt(fc_gnt),
        .wu_req(app_wu_req), .wu_id(app_wu_id), .wu_val(app_wu_val),
        .wu_gnt(app_wu_gnt),
        .o_ev_up(ac_ev_up), .o_ev_down(ac_ev_down), .o_ev_slot(ac_ev_slot),
        .fin_req(ac_fin_req), .rst_req(ac_rst_req),
        .close_req(pat_close_req), .close_id(pat_close_id),
        .reg_addr(ac_addr), .reg_wr(ac_wr), .reg_wdata(ac_wdata),
        .reg_rdata(ac_rdata),
        .app_tx_ready(app_tx_ready),
        .stat_ev_up(ac_ev_up_c), .stat_ev_down(ac_ev_down_c),
        .stat_ev_drop(ac_ev_drop), .stat_cmd_close(ac_cmd_cls),
        .stat_cmd_abort(ac_cmd_abt),
        .dbg_c0_state(ac_c0_state), .dbg_c0_snd_nxt(ac_c0_snd_nxt),
        .dbg_c0_snd_una(ac_c0_snd_una), .dbg_c0_rcv_nxt(ac_c0_rcv_nxt),
        .dbg_c0_rcv_wnd(ac_c0_rcv_wnd), .dbg_c0_snd_wnd(),
        .dbg_estab_cnt(), .dbg_ev_cnt(),
        .dbg_redge0(), .dbg_winq0(ac_winq0), .dbg_wu_mark0(ac_wu_mark0),
        .dbg_pool(ac_pool), .stat_wu(ac_stat_wu),
        .stat_pool_exhaust(ac_stat_px)
    );

    app_status_uart #(.GAP_TICKS(28'd625_000)) u_status (
        .clk(clk), .rst_n(rst_n),
        .st0(ac_c0_state),
        .snd_nxt(ac_c0_snd_nxt), .snd_una(ac_c0_snd_una),
        .rcv_wnd(ac_c0_rcv_wnd), .rcv_nxt(ac_c0_rcv_nxt),
        .stat_rx_bytes(pat_rx_bytes), .stat_tx_bytes(pat_tx_bytes),
        .stat_tx_frames(pat_tx_frames[15:0]), .stat_mismatch(pat_mismatch[15:0]),
        .rx_occ(rx_occ), .ev_cnt(ac_ev_up_c[15:0] + ac_ev_down_c[15:0]),
        .ev_drop(ac_ev_drop[15:0]), .app_tx_ready(app_tx_ready),
        .estab_cnt(16'd1),
        // P5b C9: 流控观测字段
        .stat_ack(tx_stat_ack[15:0]), .stat_ack_drop(tx_stat_ack_drop[15:0]),
        .fsm_state(tx_fsm_state_w), .winq0(ac_winq0),
        .wu_mark0(ac_wu_mark0), .stat_wu(ac_stat_wu[15:0]),
        .pool(ac_pool), .stat_pool_exh(ac_stat_px[15:0]),
        .txd(uart_txd)
    );

    always #4 clk = ~clk;

    // ==================== PC 模型 (ACK 注入, 从 tb_p4_chain 移植) ====================
    reg        inj_play;
    reg [8:0]  inj_idx;             // 播放拍索引 (数据段帧 >128 拍, 9 位)
    reg [8:0]  inj_len;             // 播放的线上字节数 (帧体 + FCS)
    reg [8:0]  inj_bidx;            // buffer 有效字节
    reg [31:0] inj_ack_val;
    reg [7:0]  inj_buf [0:255];     // 8 前导 + 帧体 (<=200) + 4 FCS
    reg [31:0] seq_b, ack_b, inj_crc;
    reg [15:0] ipcs_c;
    integer    bi;
    reg        tx_en_d, tx_inf;
    reg [5:0]  txbc;
    reg [7:0]  cap [0:47];
    reg [15:0] echo_seen, inj_done;
    reg [15:0] inj_wnd;
    reg [3:0]  gap_cnt;
    wire       inj_pend = (echo_seen != inj_done);
    reg [31:0] exp_seq;
    reg        hole;
    reg [31:0] s_cur, p_cur;
    // P5 RX 数据段注入 (一次)
    reg        rxdata_go, rxdata_done;
    reg        inj_is_data;
    reg [31:0] hi_wm;
    reg [15:0] frm_seen;            // 已捕获 conn0 数据帧数
    reg [31:0] rxdata_at;           // 触发帧号

    function [7:0] inj_byte;
        input [6:0]  idx;
        input [31:0] sq;
        input [31:0] ak;
        input [15:0] ics;
        input        isd;      // 1 = 数据段 (kind 2)
        input [7:0]  di;       // 数据字节索引 (i*7+3)
        begin
            case (idx)
                7'd0:  inj_byte = 8'h00;  7'd1:  inj_byte = 8'h0A;
                7'd2:  inj_byte = 8'h35;  7'd3:  inj_byte = 8'h01;
                7'd4:  inj_byte = 8'hFE;  7'd5:  inj_byte = 8'hC0;
                7'd6:  inj_byte = 8'h11;  7'd7:  inj_byte = 8'h22;
                7'd8:  inj_byte = 8'h33;  7'd9:  inj_byte = 8'h44;
                7'd10: inj_byte = 8'h55;  7'd11: inj_byte = 8'h66;
                7'd12: inj_byte = 8'h08;  7'd13: inj_byte = 8'h00;
                7'd14: inj_byte = 8'h45;  7'd15: inj_byte = 8'h00;
                7'd16: inj_byte = isd ? 8'h00 : 8'h00;
                7'd17: inj_byte = isd ? (8'd40 + PC5RX_LEN[7:0]) : 8'h28;
                7'd18: inj_byte = 8'h77;  7'd19: inj_byte = 8'h77;
                7'd20: inj_byte = 8'h00;  7'd21: inj_byte = 8'h00;
                7'd22: inj_byte = 8'h40;  7'd23: inj_byte = 8'h06;
                7'd24: inj_byte = ics[15:8]; 7'd25: inj_byte = ics[7:0];
                7'd26: inj_byte = 8'hC0;  7'd27: inj_byte = 8'hA8;
                7'd28: inj_byte = 8'h64;  7'd29: inj_byte = 8'h01;
                7'd30: inj_byte = 8'hC0;  7'd31: inj_byte = 8'hA8;
                7'd32: inj_byte = 8'h64;  7'd33: inj_byte = 8'h02;
                7'd34: inj_byte = 8'h30;  7'd35: inj_byte = 8'h39;   // sport 3039
                7'd36: inj_byte = 8'h1F;  7'd37: inj_byte = 8'h90;   // dport 1F90
                7'd38: inj_byte = sq[31:24]; 7'd39: inj_byte = sq[23:16];
                7'd40: inj_byte = sq[15:8];  7'd41: inj_byte = sq[7:0];
                7'd42: inj_byte = ak[31:24]; 7'd43: inj_byte = ak[23:16];
                7'd44: inj_byte = ak[15:8];  7'd45: inj_byte = ak[7:0];
                7'd46: inj_byte = 8'h50;
                7'd47: inj_byte = isd ? 8'h18 : 8'h10;
                7'd48: inj_byte = inj_wnd[15:8]; 7'd49: inj_byte = inj_wnd[7:0];
                default: inj_byte = isd ? (di * 8'd7 + 8'd3) : 8'h00;
            endcase
        end
    endfunction

    function [15:0] ip_csum_inj;
        input [15:0] tot;
        reg [31:0] s;
        begin
            s = 32'h4500 + {16'b0, tot} + 32'h7777 + 32'h0000 + 32'h4006 +
                32'hC0A8 + 32'h6401 + 32'hC0A8 + 32'h6402;
            s = (s & 32'hFFFF) + (s >> 16);
            s = (s & 32'hFFFF) + (s >> 16);
            ip_csum_inj = ~s[15:0];
        end
    endfunction

    function [31:0] crc32b;
        input [31:0] crc;
        input [7:0]  d;
        integer j;
        reg [31:0] cc;
        begin
            cc = crc ^ {24'b0, d};
            for (j = 0; j < 8; j = j + 1)
                cc = cc[0] ? ((cc >> 1) ^ 32'hEDB88320) : (cc >> 1);
            crc32b = cc;
        end
    endfunction

    // 注入帧组帧 (kind: 0 = 纯 ACK 60B, 1 = 数据段 54+LEN, 载荷 = 图案流)
    task inj_arm;
        input        isd;
        input [31:0] sq;
        input [31:0] ak;
        reg [8:0]  blen;
        reg [15:0] tot;
        integer    jj;
        reg [7:0]  bb;
        reg [63:0] xs;
        begin
            tot  = isd ? (16'd40 + PC5RX_LEN[15:0]) : 16'd40;
            blen = isd ? (9'd54 + PC5RX_LEN[8:0]) : 9'd60;
            for (bi = 0; bi < 8; bi = bi + 1)
                inj_buf[bi] <= (bi == 7) ? 8'hD5 : 8'h55;
            inj_crc = 32'hFFFFFFFF;
            xs = P5_SEED;
            for (jj = 0; jj < 200; jj = jj + 1) begin
                if (jj < blen) begin
                    if (isd && jj >= 54) begin
                        // 数据段载荷 = xorshift64 图案 byte = s[31:24] (先取后推)
                        bb = xs[31:24];
                        xs = xs_next(xs);
                    end else begin
                        // 头字节按 isd 组帧 (IP total_len/flags 随帧类型)
                        bb = inj_byte(jj[6:0], sq, ak, ip_csum_inj(tot), isd, 8'd0);
                    end
                    inj_buf[8 + jj] <= bb;
                    inj_crc = crc32b(inj_crc, bb);
                end
            end
            inj_crc = ~inj_crc;
            inj_buf[8 + blen]     <= inj_crc[7:0];
            inj_buf[8 + blen + 1] <= inj_crc[15:8];
            inj_buf[8 + blen + 2] <= inj_crc[23:16];
            inj_buf[8 + blen + 3] <= inj_crc[31:24];
            // 播放字节数 = 8 前导 + blen 帧体 + 4 FCS (前/后各 12 拍 IFG 另计)
            inj_len  <= blen + 9'd12;
            inj_play <= 1'b1;
            inj_idx  <= 9'd0;
        end
    endtask

    wire inj_go = inj_pend || rxdata_go;

    // 主驱动: 静态流 (本门为极短空闲流) + 注入播放
    always @(posedge clk) begin
        if (!rst_n) begin
            i <= 0; k <= 32'hFFFFFFFF; rx_d <= 8'h07; rx_dv <= 0; rx_er <= 0;
            done <= 0; inj_play <= 0; inj_idx <= 0; inj_done <= 0; gap_cnt <= 0;
        end else begin
            k <= k + 1;
`ifdef P5_FLOW
            // ---- P5b flow: 对端灌数据 (尊重 praw) ----
            if (flow_play) begin
                // 12 拍 IFG + (8 前导 + 帧体 + 4 FCS) + 12 拍 IFG
                if (fpi < 13'd12) begin
                    rx_d <= 8'h07; rx_dv <= 1'b0;
                end else if (fpi < (13'd12 + fblen)) begin
                    rx_d <= fbuf[fpi - 13'd12]; rx_dv <= 1'b1;
                end else begin
                    rx_d <= 8'h07; rx_dv <= 1'b0;
                end
                rx_er <= 1'b0;
                if (fpi == (13'd23 + fblen)) flow_play <= 1'b0;
                fpi <= fpi + 13'd1;
            end else if (flow_can && (flow_gap >= 4'd11) && !pretx_act) begin
                flow_build(psnd_nxt, flow_slen, plfsr);
                if (flow_slen != 12'd1460)
                    $display("PSEGS k=%0d slen=%0d seq=%08h(built %02x%02x%02x%02x) iplen=%02x%02x(exp %04x) ipc=%02x%02x tcp=%02x%02x ports=%02x%02x%02x%02x fcs=%02x%02x%02x%02x fblen=%0d",
                             k, flow_slen, psnd_nxt, fbuf[46], fbuf[47],
                             fbuf[48], fbuf[49], fbuf[24], fbuf[25],
                             16'd40 + flow_slen, fbuf[32], fbuf[33],
                             fbuf[58], fbuf[59], fbuf[42], fbuf[43],
                             fbuf[44], fbuf[45], fbuf[62+flow_slen],
                             fbuf[62+flow_slen+1], fbuf[62+flow_slen+2],
                             fbuf[62+flow_slen+3], fblen);
                psnd_nxt  <= psnd_nxt + {20'b0, flow_slen};
                psent_bytes <= psent_bytes + {20'b0, flow_slen};
                flow_play <= 1'b1;
                fpi       <= 13'd0;
                flow_gap  <= 4'd0;
                rx_dv     <= 1'b0;
                rx_er     <= 1'b0;
            end else if (pretx_act && (flow_gap >= 4'd11)) begin
                // 重传 (go-back-N): 从 puna 起重放已发过的段 (窗口内, 不需新授权)
                flow_build(pretx_seq, flow_slen_rt, plfsr_rt);
                pretx_seq <= pretx_seq + {20'b0, flow_slen_rt};
                stat_peer_retx <= stat_peer_retx + 32'd1;
                flow_play <= 1'b1;
                fpi       <= 13'd0;
                flow_gap  <= 4'd0;
                rx_dv     <= 1'b0;
                rx_er     <= 1'b0;
                if ((pretx_seq + RETX_SPAN[31:0]) >= pretx_end) pretx_act <= 1'b0;
            end else begin
                rx_dv <= 1'b0; rx_er <= 1'b0;
                if (flow_gap != 4'hF) flow_gap <= flow_gap + 4'd1;
            end
`else
            if (inj_play) begin
                // 12 拍 IFG + (8 前导 + 帧体 + 4 FCS) + 12 拍 IFG
                if (inj_idx < 9'd12) begin
                    rx_d <= 8'h07; rx_dv <= 1'b0;
                end else if (inj_idx < (9'd12 + inj_len)) begin
                    rx_d <= inj_buf[inj_idx - 9'd12];
                    rx_dv <= 1'b1;
                end else begin
                    rx_d <= 8'h07; rx_dv <= 1'b0;
                end
                rx_er <= 1'b0;
                if (inj_idx == (9'd23 + inj_len)) inj_play <= 0;
                inj_idx <= inj_idx + 9'd1;
            end else if (i < nstim) begin
                rx_d  <= stim_d[i];
                rx_dv <= stim_v[i][0];
                rx_er <= stim_e[i][0];
                i <= i + 1;
                if (stim_v[i][0]) gap_cnt <= 4'd0;
                else if (gap_cnt != 4'hF) gap_cnt <= gap_cnt + 4'd1;
            end else if (inj_go && gap_cnt >= 4'd11) begin
                // 帧间隙注入 (静态流已尽时也照常)
                if (rxdata_go) begin
                    // 一次数据段: seq = 板侧 rcv_nxt, ack = 高水位
                    inj_arm(1'b1, u_tcb.rcv_nxt_r[0], hi_wm);
                    rxdata_go <= 1'b0;
                    rxdata_done <= 1'b1;
                end else begin
                    seq_b = u_tcb.rcv_nxt_r[0];
                    ack_b = inj_ack_val;
                    inj_arm(1'b0, seq_b, ack_b);
                    inj_done <= echo_seen;
                end
                rx_dv <= 1'b0;
                rx_er <= 1'b0;
            end else begin
                rx_dv <= 0; rx_er <= 0;
                if (gap_cnt != 4'hF) gap_cnt <= gap_cnt + 4'd1;
            end
`endif
`ifdef P5_FLOW
            // 看门狗: 死锁 (对端停等/链路不通) 时也必须收尾, 否则仿真永不退出
            // k 复位态 = 32'hFFFFFFFF (P5a 遗留初值): 首拍必须排除, 否则
            // 看门狗在 rst_n 拉高的第一拍就误触发 (实测 done 在 k=FFFFFFFF 拍置位,
            // 仿真提前 20K 拍收尾, 数据只灌了 18KB)
            if (!flow_play && (flow_fin ||
                ((k != 32'hFFFFFFFF) && (k > 32'd6_000_000)))) begin
                if (!done)
                    $display("FLOWDONE k=%0d fin=%0d q=%0d sb=%0d pn=%08h praw=%08h",
                             k, flow_fin, flow_quiet, sink_bytes, psnd_nxt, praw);
                done <= 1;
            end
`else
            if (i >= nstim && !inj_play && !inj_pend && !rxdata_go &&
                (pat_done || (k > 32'd2_500_000))) done <= 1;
`endif
        end
    end

    // ---- TX 帧捕获 (conn0 数据帧 -> ACK 模型) ----
    wire conn_d0 = (txbc >= 6'd48) && cap[12] == 8'h08 && cap[13] == 8'h00 &&
                   cap[23] == 8'h06 && cap[34] == 8'h1F && cap[35] == 8'h90 &&
                   cap[36] == 8'h30 && cap[37] == 8'h39 && cap[47] == 8'h18 &&
                   {cap[16], cap[17]} > 16'd40;
    always @(posedge clk) begin
        if (!rst_n) begin
            tx_en_d <= 0; tx_inf <= 0; txbc <= 0;
            echo_seen <= 0; inj_ack_val <= 0; exp_seq <= TB_SND_NXT0; hole <= 0;
            hi_wm <= 0; frm_seen <= 0; rxdata_go <= 0; rxdata_done <= 0;
        end else begin
            tx_en_d <= gmii_tx_en;
            if (gmii_tx_en) begin
                if (!tx_en_d) begin tx_inf <= 0; txbc <= 0; end
                else if (!tx_inf) begin
                    if (gmii_txd == 8'hD5) begin tx_inf <= 1; txbc <= 0; end
                end else if (txbc < 6'd48) begin
                    cap[txbc] <= gmii_txd;
                    txbc <= txbc + 6'd1;
                end
            end else if (tx_en_d && conn_d0) begin
                echo_seen <= echo_seen + 16'd1;
                frm_seen  <= frm_seen + 16'd1;
                s_cur = {cap[38], cap[39], cap[40], cap[41]};
                p_cur = {16'b0, cap[16], cap[17]} - 32'd40;
                if ((s_cur + p_cur) > hi_wm) hi_wm <= s_cur + p_cur;
                if (s_cur == exp_seq) begin
                    exp_seq <= s_cur + p_cur;
                    hole    <= 1'b0;
                    inj_ack_val <= s_cur + p_cur;
                end else if (s_cur > exp_seq) begin
                    hole    <= 1'b1;
                    inj_ack_val <= exp_seq;
                end else begin
                    inj_ack_val <= exp_seq;
                end
                // 数据段注入触发: 第 RX_AT 个 conn0 数据帧之后 (一次)
                if (!rxdata_done && !rxdata_go && (frm_seen + 16'd1 >= rxdata_at))
                    rxdata_go <= 1'b1;
            end
        end
    end

    // ---- resp 落盘 + 收尾 ----
    integer fbi;
    reg [11:0] fcl;
    reg [7:0]  fcb [0:2047];
    reg        tx_en_dr;
    wire       tx_frame_end = tx_en_dr && !gmii_tx_en;
    always @(posedge clk) begin
        if (rst_n) begin
            tx_en_dr <= gmii_tx_en;
            if (gmii_tx_en) begin
                if (!tx_en_dr) fcl <= 12'd1;
                else if (fcl != 12'hFFF) fcl <= fcl + 12'd1;
                if ((!tx_en_dr) || (fcl < 12'd2048))
                    fcb[(!tx_en_dr) ? 12'd0 : fcl] <= gmii_txd;
            end else if (tx_en_dr) begin
                for (fbi = 0; fbi < 2048; fbi = fbi + 1)
                    if (fbi < fcl) $fwrite(fd, "%02h 1\n", fcb[fbi]);
                $fwrite(fd, "00 0\n");
            end
            if (fend) $fwrite(fd, "FEND %0d %0d\n", k, ferr);
            if (ack_req) $fwrite(fd, "ACK %0d %0d %08h\n", k, ack_id, ack_val);
        end
    end

    // ---- ECMAX: app TX 端口 (帧器输入) 最长无 tlast 词串 (合并帧哨兵) ----
    integer eco_run, eco_max;
    always @(posedge clk) begin
        if (!rst_n) begin eco_run <= 0; eco_max <= 0; end
        else if (app2_tvalid && app2_tready) begin
            if (app2_tlast) eco_run <= 0;
            else begin
                if (eco_run + 1 > eco_max) eco_max <= eco_run + 1;
                eco_run <= eco_run + 1;
            end
        end
    end

    // ---- 寄存器读序列 (收尾时快照) ----
    task dump_reg;
        input [7:0] a;
        begin
            @(posedge clk); ac_addr <= a;
            @(posedge clk);
            $fwrite(fd, "P5REG %0d %08h\n", a, ac_rdata);
        end
    endtask

    // ---- cfg 记录驱动 (8 词 ADD: 与 HLS cfg_stream 同格式) ----
    task cfg_record;
        input [31:0] w0, w1, w2, w3, w4, w5, w6, w7;
        begin
            @(posedge clk); cfg_tdata <= w0; cfg_tvalid <= 1'b1;
            @(posedge clk); cfg_tdata <= w1;
            @(posedge clk); cfg_tdata <= w2;
            @(posedge clk); cfg_tdata <= w3;
            @(posedge clk); cfg_tdata <= w4;
            @(posedge clk); cfg_tdata <= w5;
            @(posedge clk); cfg_tdata <= w6;
            @(posedge clk); cfg_tdata <= w7;
            @(posedge clk); cfg_tvalid <= 1'b0;
            repeat (64) @(posedge clk);
        end
    endtask

    reg [31:0] rxdata_at_r;
    initial begin
        clk = 0; rst_n = 0;
        inj_wnd = 16'h4000;
        bad_idx = 16'd0;
        rxdata_at = 32'd200;
        // 注入控制文件 (p5bad.memh: "指数"); 缺省 0 = 不注入坏帧
        fdi = $fopen("p5bad.memh", "r");
        if (fdi != 0) begin
            $fscanf(fdi, "%d", bad_idx);
            $fclose(fdi);
        end
`ifdef P5_FLOW
        // flow 侧初值 (praw 自举: 小初始窗 = 1 段; 之后由板侧 ACK 学到真窗口)
        psnd_nxt = FLOW_ISN; praw = FLOW_ISN + 32'd1460; plfsr = P5_SEED;
        praw_seen = 1'b0; praw_back = 32'd0; pack_cnt = 32'd0;
        occ_max = 32'd0; occ_soft_v = 32'd0; occ_hard_v = 32'd0;
        flow_play = 1'b0; fpi = 13'd0; flow_gap = 4'd0; fblen = 13'd0;
        psent_bytes = 32'd0;
        puna = FLOW_ISN; dup_cnt = 32'd0; rto_cnt = 32'd0;
        pretx_act = 1'b0; plfsr_rt = P5_SEED;
`endif
        fdi = $fopen("p5rx.memh", "r");
        if (fdi != 0) begin
            $fscanf(fdi, "%d", rxdata_at);
            $fclose(fdi);
        end
        $readmemh("stim_data.memh", stim_d);
        $readmemh("stim_dv.memh",   stim_v);
        $readmemh("stim_er.memh",   stim_e);
        nstim = 0;
        while (nstim < 1048576 && stim_d[nstim] !== 8'hxx) nstim = nstim + 1;
`ifdef P5_FLOW
        fd = $fopen("resp_p5_flow.memh", "w");
`else
        fd = $fopen("resp_p5_app.memh", "w");
`endif
        cfg_tdata = 32'd0; cfg_tvalid = 1'b0;
        ac_addr = 8'h00; ac_wr = 1'b0; ac_wdata = 32'd0;
        #200; rst_n = 1;
        repeat (200) @(posedge clk);
        // ---- ADD 记录: slot0, cmd=ADD, wscale=8 ----
        cfg_record(32'h0008_0000,      // w0 = (wscale=8 << 16) | (cmd=ADD << 8) | slot0
                   TB_PEER_IP,         // w1 = peer ip
                   TB_MY_IP,           // w2 = local ip
                   {TB_PEER_PORT, TB_MY_PORT},          // w3
                   TB_PEER_MAC[47:16],                 // w4
                   {TB_PEER_MAC[15:0], 16'h4000},      // w5 = mac low | peer wnd
                   PEER_ISN + 32'd1,   // w6 = rcv_nxt
                   TB_SND_NXT0);       // w7 = snd_nxt
        wait (done == 1);
        repeat (20000) @(posedge clk);
        // ---- 统计 ----
        $fwrite(fd, "P5STAT %0d %0d %0d %0d %0d %0d %0d\n",
                pat_tx_bytes, pat_tx_frames, pat_rx_bytes, pat_mismatch,
                pat_done, TB_TX_BYTES, pat_bad_frames);
        $fwrite(fd, "P5TX %0d %0d %0d %0d %0d %0d %0d\n",
                tx_stat_frames, tx_stat_bytes, tx_stat_ack, tx_stat_drop_len,
                tx_stat_fin, tx_stat_rst, tx_stat_eend);
        $fwrite(fd, "P5ARB %0d %0d\n", bad_idx, rxdata_done);
        $fwrite(fd, "STATS7 %0d %0d %0d %0d %0d %0d %0d\n",
                rx_stat_pass, rx_stat_nonmatch, rx_stat_ipcsum, rx_stat_crc,
                rx_stat_seq, rx_stat_ack, rx_stat_bytes);
        $fwrite(fd, "STATS_MAC %0d %0d %0d\n", mac_stat_frames, mac_stat_abort,
                tx_stat_eend);
        $fwrite(fd, "ECOMAX %0d\n", eco_max);
        $fwrite(fd, "RETX %0d\n", tx_stat_retx);
        $fwrite(fd, "TCBF %08h %08h %08h %04h %04h %0d\n",
                u_tcb.rcv_nxt_r[0], u_tcb.snd_nxt_r[0], u_tcb.snd_una_r[0],
                u_tcb.rcv_wnd_r[0], u_tcb.snd_wnd_r[0], u_tcb.state_r[0]);
        $fwrite(fd, "CAMF %08h %08h %04h %04h %012h\n",
                u_cam.sip_r[0], u_cam.dip_r[0], u_cam.sport_r[0],
                u_cam.dport_r[0], u_cam.dmac_r[0]);
        $fwrite(fd, "EVSRC %0d %08h %04h %012h %0d %0d\n",
                ev_up, ev_peer_ip, ev_peer_port, ev_peer_mac, scfg_add, scfg_del);
        // ---- 事件寄存器 ----
        dump_reg(8'h00); dump_reg(8'h01); dump_reg(8'h02);
        dump_reg(8'h03); dump_reg(8'h04); dump_reg(8'h07);
        dump_reg(8'h08); dump_reg(8'h09); dump_reg(8'h0A);
        dump_reg(8'h10); dump_reg(8'h11); dump_reg(8'h12); dump_reg(8'h13);
        dump_reg(8'h50); dump_reg(8'h90); dump_reg(8'h91); dump_reg(8'h92);
        dump_reg(8'h93); dump_reg(8'h94); dump_reg(8'h9F);
        // P5b 流控寄存器 (C9): stat_wu / pool / stat_pool_exhaust / redge0 /
        // winq0 / wu_mark0 / stat_fc_upd
        dump_reg(8'h96); dump_reg(8'h97); dump_reg(8'h98); dump_reg(8'h99);
        dump_reg(8'h9A); dump_reg(8'h9B); dump_reg(8'h9C);
`ifdef P5_FLOW
        dump_reg(8'h08); dump_reg(8'h97); dump_reg(8'h99); dump_reg(8'h9A);
        dump_reg(8'h9B); dump_reg(8'h9C); dump_reg(8'h9D);
`endif
        // ---- 探针快照 ----
        $fwrite(fd, "P5DBG %0d %0d %0d %0d %0d %0d %0d\n",
                u_app_ctrl.scan_round, pat_active, pat_act_id,
                frm_seen, echo_seen, app_tx_ready[0], ev_up);
`ifdef P5_FLOW
        // ---- P5b flow 判据落盘 (规格 §3) ----
        // FLOWB: 消费者侧 (字节/帧/字/图案失配/tkeep 非法/空字/暂停次数/最长间隙)
        $fwrite(fd, "FLOWB %0d %0d %0d %0d %0d %0d %0d %0d\n",
                sink_bytes, sink_frames, sink_words, sink_mismatch, sink_kaerr,
                sink_evfrm, sink_pause_cnt, sink_gap_max);
        // FLOWO: 逐拍占用 (峰值/软界超限拍数/硬界超限拍数)
        $fwrite(fd, "FLOWO %0d %0d %0d\n", occ_max, occ_soft_v, occ_hard_v);
        // FLOWP: 对端侧 (收 ACK 数/右沿回退数/已发字节/板侧重传/板侧 mac 丢帧)
        $fwrite(fd, "FLOWP %0d %0d %0d %0d %0d %0d\n", pack_cnt, praw_back,
                psnd_nxt - FLOW_ISN, tx_stat_retx, mac_stat_drop,
                stat_peer_retx);
        // FLOWM: 板侧 RX/TX 侧计数 (合法性对账)
        $fwrite(fd, "FLOWM %0d %0d %0d %0d %0d %0d %0d %0d\n",
                rx_stat_pass, rx_stat_seq, rx_stat_crc, rx_stat_ipcsum,
                rx_stat_nonmatch, rx_stat_trunc, tx_stat_ack, tx_stat_ack_drop);
        // FLOWS: 汇总 (静默拍数/窗口重开次数/最终 snd_nxt/最终 praw)
        $fwrite(fd, "FLOWS %0d %08h %08h %08h\n", flow_quiet, psnd_nxt, praw,
                ac_c0_rcv_nxt);
`endif
        $fclose(fd);
        $display("P5DONE tx(bytes=%0d fr=%0d) rx(bytes=%0d mm=%0d) drop_len=%0d eend=%0d eco_max=%0d mac(abort=%0d) ev(up=%0d down=%0d drop=%0d) tcbf(st=%0d nx=%08h una=%08h)",
                 pat_tx_bytes, pat_tx_frames, pat_rx_bytes, pat_mismatch,
                 tx_stat_drop_len, tx_stat_eend, eco_max, mac_stat_abort,
                 ac_ev_up_c, ac_ev_down_c, ac_ev_drop, u_tcb.state_r[0],
                 u_tcb.snd_nxt_r[0], u_tcb.snd_una_r[0]);
        $finish;
    end
endmodule
