`timescale 1ns/1ps
// P4a 全链 TB: GMII -> mac_rx_64 -> rx_classify -> fast(P3 TCP 链) / slow(HLS 慢路径)
//             -> tx_arb -> mac_tx_64 -> GMII。慢路径 = 真 HLS udp_echo (综合 verilog)。
// 结构/配置阶段/仲裁与 tb_tcp_echo 一致 (conn1 TB 预配, conn0 tcp_synp 握手);
// 新增: classify 插入 mac 之后, slow_rx_adp->udp_echo->slow_tx_adp 挂 slow 路由,
// tx_arb 汇合 fast/slow 进 mac_tx_64。cfg_src_mac = C0 (P4 统一)。
// 捕获 (resp_p4_chain.memh): 每拍 "%02h %d" (gmii_txd, tx_en) + 事件行
//   FEND k ferr / ACK k id val / SYNP 对端握手字段; 末尾 STATS7/STATS_TX/STATS_ECO
//   /CAMF/TCBF + SLOWRX (commit drop) / SLOWTX (frames purge)。
// 校验全语义 (gen_stim_p4_chain.py check): HLS 应答拍级不可预期, 快慢流自由交错。
module tb_p4_chain;

    reg        clk, rst_n;
    reg [7:0]  rx_d;
    reg        rx_dv, rx_er;
    reg [7:0]  stim_d [0:524287];
    reg [7:0]  stim_v [0:524287];
    reg [7:0]  stim_e [0:524287];
    integer    nstim;
    reg [19:0] i;
    reg [31:0] k;
    reg        done;
    // 配置阶段
    reg [5:0]  cphase;
    reg [31:0] tcbc [0:95];
    reg        cfg_wr;
    reg [3:0]  cfg_addr;
    reg [31:0] cfg_sip, cfg_dip;
    reg [15:0] cfg_sport, cfg_dport;
    reg [47:0] cfg_dmac;
    reg        cfg_upd_wr;
    reg [3:0]  cfg_upd_id;
    reg [2:0]  cfg_upd_sel;
    reg [31:0] cfg_upd_val;

    // mac_rx -> classify
    wire [63:0] s_tdata;
    wire [7:0]  s_tkeep;
    wire        s_tvalid, s_tready, s_tlast, s_tuser, s_tcrs, s_terr;
    // classify -> fast (tcp_rx)
    wire [63:0] f_tdata;
    wire [7:0]  f_tkeep;
    wire        f_tvalid, f_tready, f_tlast, f_tuser, f_tcrs, f_terr;
    // classify -> slow (slow_rx_adp)
    wire [63:0] w_tdata;
    wire [7:0]  w_tkeep;
    wire        w_tvalid, w_tready, w_tlast, w_tuser, w_tcrs, w_terr;
    // tcp_rx 载荷口 -> tcp_echo
    wire [63:0] m_tdata;
    wire [7:0]  m_tkeep;
    wire        m_tvalid, m_tready, m_tlast;
    wire [1:0]  m_tuser;
    wire        fend, ferr;
    wire        meta_valid;
    wire [3:0]  meta_conn_id;
    wire [15:0] meta_len;
    wire [3:0]  ra_id;
    wire [31:0] ra_rcv_nxt, ra_snd_nxt, ra_snd_una;
    wire [15:0] ra_rcv_wnd;
    wire [3:0]  ra_state;
    wire        rx_upd_wr;
    wire [3:0]  rx_upd_id;
    wire [2:0]  rx_upd_sel;
    wire [31:0] rx_upd_val;
    wire        rx_upd_gnt;
    wire        ack_req;
    wire [3:0]  ack_id;
    wire [31:0] ack_val;
    wire [31:0] cam_q_sip, cam_q_dip;
    wire [15:0] cam_q_sport, cam_q_dport;
    wire        cam_q_hit;
    wire [3:0]  cam_q_id;
    wire [31:0] rx_stat_pass, rx_stat_nonmatch, rx_stat_ipcsum, rx_stat_crc,
                rx_stat_seq, rx_stat_ack, rx_stat_bytes;
    // tcp_echo -> tcp_tx_frame
    wire [63:0] eco_tdata;
    wire [7:0]  eco_tkeep;
    wire        eco_tvalid, eco_tready, eco_tlast;
    wire [3:0]  eco_tid;
    wire [31:0] eco_stat_echo, eco_stat_drop_crc;
    // tcp_tx_frame
    wire [3:0]  rb_id;
    wire [31:0] rb_rcv_nxt, rb_snd_nxt, rb_snd_una;
    wire [15:0] rb_rcv_wnd, rb_snd_wnd;
    wire [3:0]  rb_state;
    wire        tx_upd_wr;
    wire [3:0]  tx_upd_id;
    wire [2:0]  tx_upd_sel;
    wire [31:0] tx_upd_val;
    wire [3:0]  cam_rd_id;
    wire [47:0] cam_rd_dmac;
    wire [31:0] cam_rd_sip, cam_rd_dip;
    wire [15:0] cam_rd_sport, cam_rd_dport;
    // tcp_tx_frame -> tx_arb (fast)
    wire [63:0] x_tdata;
    wire [7:0]  x_tkeep;
    wire        x_tvalid, x_tready, x_tlast;
    // slow_tx_adp -> tx_arb (slow)
    wire [63:0] z_tdata;
    wire [7:0]  z_tkeep;
    wire        z_tvalid, z_tready, z_tlast;
    // tx_arb -> mac_tx_64
    wire [63:0] a_tdata;
    wire [7:0]  a_tkeep;
    wire        a_tvalid, a_tready, a_tlast;
    wire [7:0]  gmii_txd;
    wire        gmii_tx_en;
    wire [31:0] tx_stat_frames, tx_stat_bytes, tx_stat_ack, tx_stat_ack_drop;
    // tcp_rx SYN sideband -> tcp_synp
    wire        syn_v;
    wire [47:0] syn_smac;
    wire [31:0] syn_sip;
    wire [15:0] syn_sport, syn_dport;
    wire [31:0] syn_seq;
    wire [15:0] syn_wnd;
    // tcp_synp 输出
    wire        synp_cfg_wr;
    wire [3:0]  synp_cfg_addr;
    wire [31:0] synp_cfg_sip, synp_cfg_dip;
    wire [15:0] synp_cfg_sport, synp_cfg_dport;
    wire [47:0] synp_cfg_dmac;
    wire        synp_upd_wr;
    wire [3:0]  synp_upd_id;
    wire [2:0]  synp_upd_sel;
    wire [31:0] synp_upd_val;
    wire        sack_req;
    wire [3:0]  sack_id;
    wire [31:0] sack_ackval;
    // 慢路径
    wire [15:0] hls_rx_tdata;
    wire        hls_rx_tvalid, hls_rx_tready;
    wire [15:0] hls_tx_tdata;
    wire        hls_tx_tvalid, hls_tx_tready;
    wire [31:0] srx_commit, srx_drop, stx_frames, stx_purge;

    // ---- CAM 配置口二选一: TB 配置阶段优先, 其次 synp ----
    wire        cam_cfg_wr    = cfg_wr | synp_cfg_wr;
    wire [3:0]  cam_cfg_addr  = cfg_wr ? cfg_addr  : synp_cfg_addr;
    wire [31:0] cam_cfg_sip   = cfg_wr ? cfg_sip   : synp_cfg_sip;
    wire [31:0] cam_cfg_dip   = cfg_wr ? cfg_dip   : synp_cfg_dip;
    wire [15:0] cam_cfg_sport = cfg_wr ? cfg_sport : synp_cfg_sport;
    wire [15:0] cam_cfg_dport = cfg_wr ? cfg_dport : synp_cfg_dport;
    wire [47:0] cam_cfg_dmac  = cfg_wr ? cfg_dmac  : synp_cfg_dmac;

    // ---- TX 的 ACK 请求二选一: synp (SYN+ACK) 优先 ----
    wire        tx_ack_req = sack_req | ack_req;
    wire [3:0]  tx_ack_id  = sack_req ? sack_id     : ack_id;
    wire [31:0] tx_ack_val = sack_req ? sack_ackval : ack_val;
    wire        tx_ack_syn = sack_req;

    // ---- TCB 更新仲裁 (tx > rx > cfg; cfg 级 = TB 配置 | synp) ----
    wire        cfglvl_wr  = cfg_upd_wr | synp_upd_wr;
    wire [2:0]  cfglvl_sel = cfg_upd_wr ? cfg_upd_sel : synp_upd_sel;
    wire [3:0]  cfglvl_id  = cfg_upd_wr ? cfg_upd_id  : synp_upd_id;
    wire [31:0] cfglvl_val = cfg_upd_wr ? cfg_upd_val : synp_upd_val;
    wire        sel_tx = tx_upd_wr;
    wire        sel_rx = !sel_tx && rx_upd_wr;
    wire        tcb_wr  = sel_tx || sel_rx || cfglvl_wr;
    wire [2:0]  tcb_sel = sel_tx ? tx_upd_sel : (sel_rx ? rx_upd_sel : cfglvl_sel);
    wire [3:0]  tcb_id  = sel_tx ? tx_upd_id  : (sel_rx ? rx_upd_id  : cfglvl_id);
    wire [31:0] tcb_val = sel_tx ? tx_upd_val : (sel_rx ? rx_upd_val : cfglvl_val);
    assign rx_upd_gnt = sel_rx;

    integer     fd;

    mac_rx_64 u_mac (
        .clk(clk), .rst_n(rst_n),
        .gmii_rxd(rx_d), .gmii_rx_dv(rx_dv), .gmii_rx_er(rx_er),
        .m_axis_tdata(s_tdata), .m_axis_tkeep(s_tkeep), .m_axis_tvalid(s_tvalid),
        .m_axis_tready(s_tready), .m_axis_tlast(s_tlast), .m_axis_tuser(s_tuser),
        .m_axis_terr(s_terr), .m_axis_tcrs(s_tcrs),
        .stat_frames(), .stat_crc_err(), .stat_drop(), .stat_bytes()
    );

    rx_classify u_classify (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep), .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_tready), .s_axis_tlast(s_tlast), .s_axis_tuser(s_tuser),
        .s_axis_tcrs(s_tcrs), .s_axis_terr(s_terr),
        .m_fast_tdata(f_tdata), .m_fast_tkeep(f_tkeep), .m_fast_tvalid(f_tvalid),
        .m_fast_tready(f_tready), .m_fast_tlast(f_tlast), .m_fast_tuser(f_tuser),
        .m_fast_tcrs(f_tcrs), .m_fast_terr(f_terr),
        .m_slow_tdata(w_tdata), .m_slow_tkeep(w_tkeep), .m_slow_tvalid(w_tvalid),
        .m_slow_tready(w_tready), .m_slow_tlast(w_tlast), .m_slow_tuser(w_tuser),
        .m_slow_tcrs(w_tcrs), .m_slow_terr(w_terr),
        .stat_fast(), .stat_slow()
    );

    tcp_rx u_rx (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(f_tdata), .s_axis_tkeep(f_tkeep), .s_axis_tvalid(f_tvalid),
        .s_axis_tready(f_tready), .s_axis_tlast(f_tlast), .s_axis_tuser(f_tuser),
        .s_axis_tcrs(f_tcrs), .s_axis_terr(f_terr),
        .cfg_suppress_data_ack(1'b1),   // 与板上 wrapper_p4 一致 (echo 应用)
        .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep), .m_axis_tvalid(m_tvalid),
        .m_axis_tready(m_tready), .m_axis_tlast(m_tlast), .m_axis_tuser(m_tuser),
        .fend(fend), .ferr(ferr),
        .meta_valid(meta_valid), .meta_src_ip(), .meta_src_port(),
        .meta_len(meta_len), .meta_conn_id(meta_conn_id), .meta_seq(),
        .ra_id(ra_id),
        .ra_rcv_nxt(ra_rcv_nxt), .ra_snd_nxt(ra_snd_nxt), .ra_snd_una(ra_snd_una),
        .ra_rcv_wnd(ra_rcv_wnd), .ra_state(ra_state),
        .upd_wr(rx_upd_wr), .upd_id(rx_upd_id), .upd_sel(rx_upd_sel), .upd_val(rx_upd_val),
        .upd_gnt(rx_upd_gnt),
        .ack_req(ack_req), .ack_id(ack_id), .ack_val(ack_val),
        .syn_v(syn_v), .syn_smac(syn_smac), .syn_sip(syn_sip),
        .syn_sport(syn_sport), .syn_dport(syn_dport),
        .syn_seq(syn_seq), .syn_wnd(syn_wnd),
        .cam_q_sip(cam_q_sip), .cam_q_dip(cam_q_dip),
        .cam_q_sport(cam_q_sport), .cam_q_dport(cam_q_dport),
        .cam_q_hit(cam_q_hit), .cam_q_id(cam_q_id),
        .stat_pass(rx_stat_pass), .stat_drop_nonmatch(rx_stat_nonmatch),
        .stat_drop_ipcsum(rx_stat_ipcsum), .stat_drop_crc(rx_stat_crc),
        .stat_drop_seq(rx_stat_seq), .stat_ack(rx_stat_ack), .stat_bytes(rx_stat_bytes)
    );

    tcp_echo u_echo (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(m_tdata), .s_axis_tkeep(m_tkeep), .s_axis_tvalid(m_tvalid),
        .s_axis_tready(m_tready), .s_axis_tlast(m_tlast), .s_axis_tuser(m_tuser),
        .fend(fend), .ferr(ferr),
        .meta_valid(meta_valid), .meta_conn_id(meta_conn_id), .meta_len(meta_len),
        .m_axis_tdata(eco_tdata), .m_axis_tkeep(eco_tkeep), .m_axis_tvalid(eco_tvalid),
        .m_axis_tready(eco_tready), .m_axis_tlast(eco_tlast), .m_axis_tid(eco_tid),
        .stat_echo(eco_stat_echo), .stat_drop_crc(eco_stat_drop_crc)
    );

    tcp_cam u_cam (
        .clk(clk), .rst_n(rst_n),
        .cfg_wr(cam_cfg_wr), .cfg_addr(cam_cfg_addr),
        .cfg_sip(cam_cfg_sip), .cfg_dip(cam_cfg_dip),
        .cfg_sport(cam_cfg_sport), .cfg_dport(cam_cfg_dport), .cfg_dmac(cam_cfg_dmac),
        .q_sip(cam_q_sip), .q_dip(cam_q_dip),
        .q_sport(cam_q_sport), .q_dport(cam_q_dport),
        .q_id(cam_q_id), .q_hit(cam_q_hit),
        .rd_id(cam_rd_id), .rd_dmac(cam_rd_dmac), .rd_sip(cam_rd_sip), .rd_dip(cam_rd_dip),
        .rd_sport(cam_rd_sport), .rd_dport(cam_rd_dport)
    );

    tcb u_tcb (
        .clk(clk), .rst_n(rst_n),
        .ra_id(ra_id), .ra_rcv_nxt(ra_rcv_nxt), .ra_snd_nxt(ra_snd_nxt),
        .ra_snd_una(ra_snd_una), .ra_rcv_wnd(ra_rcv_wnd), .ra_snd_wnd(),
        .ra_state(ra_state),
        .rb_id(rb_id), .rb_rcv_nxt(rb_rcv_nxt), .rb_snd_nxt(rb_snd_nxt),
        .rb_snd_una(rb_snd_una), .rb_rcv_wnd(rb_rcv_wnd), .rb_snd_wnd(rb_snd_wnd),
        .rb_state(rb_state),
        .upd_wr(tcb_wr), .upd_id(tcb_id), .upd_sel(tcb_sel), .upd_val(tcb_val)
    );

    tcp_synp u_synp (
        .clk(clk), .rst_n(rst_n),
        .syn_v(syn_v), .syn_smac(syn_smac), .syn_sip(syn_sip),
        .syn_sport(syn_sport), .syn_dport(syn_dport),
        .syn_seq(syn_seq), .syn_wnd(syn_wnd),
        .cfg_wr(synp_cfg_wr), .cfg_addr(synp_cfg_addr),
        .cfg_sip(synp_cfg_sip), .cfg_dip(synp_cfg_dip),
        .cfg_sport(synp_cfg_sport), .cfg_dport(synp_cfg_dport),
        .cfg_dmac(synp_cfg_dmac),
        .upd_wr(synp_upd_wr), .upd_id(synp_upd_id),
        .upd_sel(synp_upd_sel), .upd_val(synp_upd_val),
        .sack_req(sack_req), .sack_id(sack_id), .sack_ackval(sack_ackval),
        .cfg_my_ip(32'hC0A86402), .cfg_listen(16'h1F90), .cfg_iss(32'd5999)
    );

    tcp_tx_frame u_tx (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(eco_tdata), .s_axis_tkeep(eco_tkeep),
        .s_axis_tvalid(eco_tvalid), .s_axis_tready(eco_tready), .s_axis_tlast(eco_tlast),
        .s_axis_tid(eco_tid),
        .ack_req(tx_ack_req), .ack_id(tx_ack_id), .ack_val(tx_ack_val),
        .ack_syn(tx_ack_syn),
        .rb_id(rb_id), .rb_snd_nxt(rb_snd_nxt), .rb_rcv_nxt(rb_rcv_nxt),
        .rb_rcv_wnd(rb_rcv_wnd),
        .upd_wr(tx_upd_wr), .upd_id(tx_upd_id), .upd_sel(tx_upd_sel), .upd_val(tx_upd_val),
        .cam_rd_id(cam_rd_id), .cam_rd_dmac(cam_rd_dmac), .cam_rd_sip(cam_rd_sip),
        .cam_rd_sport(cam_rd_sport), .cam_rd_dport(cam_rd_dport),
        .cfg_src_mac(48'h000A3501FEC0), .cfg_src_ip(32'hC0A86402),
        .m_axis_tdata(x_tdata), .m_axis_tkeep(x_tkeep),
        .m_axis_tvalid(x_tvalid), .m_axis_tready(x_tready), .m_axis_tlast(x_tlast),
        .stat_frames(tx_stat_frames), .stat_bytes(tx_stat_bytes),
        .stat_ack(tx_stat_ack), .stat_ack_drop(tx_stat_ack_drop)
    );

    // ---- 慢路径: slow_rx_adp -> udp_echo (HLS) -> slow_tx_adp ----
    slow_rx_adp u_slow_rx (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(w_tdata), .s_axis_tkeep(w_tkeep), .s_axis_tvalid(w_tvalid),
        .s_axis_tready(w_tready), .s_axis_tlast(w_tlast), .s_axis_tuser(w_tuser),
        .s_axis_tcrs(w_tcrs), .s_axis_terr(w_terr),
        .hls_rx_tdata(hls_rx_tdata), .hls_rx_tvalid(hls_rx_tvalid),
        .hls_rx_tready(hls_rx_tready),
        .stat_commit(srx_commit), .stat_drop(srx_drop)
    );

    udp_echo u_hls (
        .ap_clk(clk), .ap_rst_n(rst_n), .reset_n(rst_n),
        .rx_stream_TDATA(hls_rx_tdata), .rx_stream_TVALID(hls_rx_tvalid),
        .rx_stream_TREADY(hls_rx_tready),
        .tx_stream_TDATA(hls_tx_tdata), .tx_stream_TVALID(hls_tx_tvalid),
        .tx_stream_TREADY(hls_tx_tready),
        .msg_stream_TDATA(), .msg_stream_TVALID(), .msg_stream_TREADY(1'b1),
        .led_d0(), .led_d1(), .led_d2(), .led_d3()
    );

    slow_tx_adp u_slow_tx (
        .clk(clk), .rst_n(rst_n),
        .hls_tx_tdata(hls_tx_tdata), .hls_tx_tvalid(hls_tx_tvalid),
        .hls_tx_tready(hls_tx_tready),
        .m_axis_tdata(z_tdata), .m_axis_tkeep(z_tkeep),
        .m_axis_tvalid(z_tvalid), .m_axis_tready(z_tready), .m_axis_tlast(z_tlast),
        .stat_frames(stx_frames), .stat_purge(stx_purge)
    );

    tx_arb u_tx_arb (
        .clk(clk), .rst_n(rst_n),
        .s_fast_tdata(x_tdata), .s_fast_tkeep(x_tkeep), .s_fast_tvalid(x_tvalid),
        .s_fast_tready(x_tready), .s_fast_tlast(x_tlast),
        .s_slow_tdata(z_tdata), .s_slow_tkeep(z_tkeep), .s_slow_tvalid(z_tvalid),
        .s_slow_tready(z_tready), .s_slow_tlast(z_tlast),
        .m_axis_tdata(a_tdata), .m_axis_tkeep(a_tkeep),
        .m_axis_tvalid(a_tvalid), .m_axis_tready(a_tready), .m_axis_tlast(a_tlast)
    );

    mac_tx_64 u_mactx (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(a_tdata), .s_axis_tkeep(a_tkeep),
        .s_axis_tvalid(a_tvalid), .s_axis_tready(a_tready), .s_axis_tlast(a_tlast),
        .gmii_txd(gmii_txd), .gmii_tx_en(gmii_tx_en), .gmii_tx_er(),
        .stat_frames(), .stat_abort()
    );

    always #4 clk = ~clk;     // 125 MHz

    // ---- 时钟化激励驱动 + 配置阶段 ----
    always @(posedge clk) begin
        if (!rst_n) begin
            i <= 0; k <= 32'hFFFFFFFF; rx_d <= 8'h07; rx_dv <= 0; rx_er <= 0; done <= 0;
            cphase <= 0;
            cfg_wr <= 0; cfg_addr <= 0; cfg_sip <= 0; cfg_dip <= 0;
            cfg_sport <= 0; cfg_dport <= 0; cfg_dmac <= 0;
            cfg_upd_wr <= 0; cfg_upd_id <= 0; cfg_upd_sel <= 0; cfg_upd_val <= 0;
        end else begin
            k <= k + 1;
            if (cphase < 40) begin
                rx_dv <= 0; rx_er <= 0;
                cfg_wr <= (cphase == 6'd2);
                cfg_addr <= 4'd1;
                case (cphase)
                    6'd2: begin
                        cfg_sip <= 32'h0A000009; cfg_dip <= 32'hC0A86409;
                        cfg_sport <= 16'hD431; cfg_dport <= 16'h1F91;
                        cfg_dmac <= 48'hAABBCCDDEE01;
                    end
                    default: ;
                endcase
                cfg_upd_wr <= (cphase >= 6 && cphase <= 11);
                cfg_upd_id  <= 4'd1;
                cfg_upd_sel <= (cphase - 6) % 6;
                cfg_upd_val <= tcbc[cphase - 6];
                cphase <= cphase + 1;
            end else begin
                cfg_wr <= 0; cfg_upd_wr <= 0;
                if (i < nstim) begin
                    rx_d  <= stim_d[i];
                    rx_dv <= stim_v[i][0];
                    rx_er <= stim_e[i][0];
                    i <= i + 1;
                end else begin
                    rx_dv <= 0; rx_er <= 0;
                end
                if (i >= nstim) done <= 1;
            end
        end
    end

    initial begin
        clk = 0; rst_n = 0;
        $readmemh("stim_data.memh", stim_d);
        $readmemh("stim_dv.memh",   stim_v);
        $readmemh("stim_er.memh",   stim_e);
        $readmemh("cfg_tcb.memh",   tcbc);
        nstim = 0;
        while (nstim < 524288 && stim_d[nstim] !== 8'hxx) nstim = nstim + 1;
        fd = $fopen("resp_p4_chain.memh", "w");
        #200; rst_n = 1;
        wait (done == 1);
        repeat (60000) @(posedge clk);   // HLS 应答余量 (拍级不可预期)
        $fwrite(fd, "STATS7 %0d %0d %0d %0d %0d %0d %0d\n",
                rx_stat_pass, rx_stat_nonmatch, rx_stat_ipcsum, rx_stat_crc,
                rx_stat_seq, rx_stat_ack, rx_stat_bytes);
        $fwrite(fd, "STATS_TX %0d %0d %0d %0d\n",
                tx_stat_frames, tx_stat_bytes, tx_stat_ack, tx_stat_ack_drop);
        $fwrite(fd, "STATS_ECO %0d %0d\n", eco_stat_echo, eco_stat_drop_crc);
        $fwrite(fd, "CAMF %08h %08h %04h %04h %012h\n",
                u_cam.sip_r[0], u_cam.dip_r[0], u_cam.sport_r[0],
                u_cam.dport_r[0], u_cam.dmac_r[0]);
        $fwrite(fd, "TCBF %08h %08h %08h %04h %04h %0d %08h %08h %08h %04h %04h %0d\n",
                u_tcb.rcv_nxt_r[0], u_tcb.snd_nxt_r[0], u_tcb.snd_una_r[0],
                u_tcb.rcv_wnd_r[0], u_tcb.snd_wnd_r[0], u_tcb.state_r[0],
                u_tcb.rcv_nxt_r[1], u_tcb.snd_nxt_r[1], u_tcb.snd_una_r[1],
                u_tcb.rcv_wnd_r[1], u_tcb.snd_wnd_r[1], u_tcb.state_r[1]);
        $fwrite(fd, "SLOWRX %0d %0d\n", srx_commit, srx_drop);
        $fwrite(fd, "SLOWTX %0d %0d\n", stx_frames, stx_purge);
        $fclose(fd);
        $display("DONE rx(pass=%0d nm=%0d ack=%0d) tx(fr=%0d ack=%0d) eco(echo=%0d) slow(cmt=%0d drp=%0d tx=%0d pg=%0d)",
                 rx_stat_pass, rx_stat_nonmatch, rx_stat_ack,
                 tx_stat_frames, tx_stat_ack, eco_stat_echo,
                 srx_commit, srx_drop, stx_frames, stx_purge);
        $finish;
    end

    // ---- GMII 字节捕获 + 事件捕获 ----
    always @(posedge clk) begin
        if (rst_n) begin
            $fwrite(fd, "%02h %d\n", gmii_txd, gmii_tx_en);
            if (fend)
                $fwrite(fd, "FEND %0d %0d\n", k, ferr);
            if (tx_ack_req)
                $fwrite(fd, "ACK %0d %0d %08h\n", k, tx_ack_id, tx_ack_val);
            if (syn_v)
                $fwrite(fd, "SYNP %012h %08h %04h %04h %08h %04h\n",
                        syn_smac, syn_sip, syn_sport, syn_dport, syn_seq, syn_wnd);
        end
    end

    // ---- abort 转变沿侦测 (排障) ----
    reg ab_d = 0;
    always @(posedge clk) begin
        if (rst_n && $test$plusargs("PROBE")) begin
            ab_d <= u_slow_rx.abort;
            if (u_slow_rx.abort != ab_d)
                $display("ABCHG k=%0d ab=%b | s_acc=%b ffull=%b snap=%b ifm=%b rsd=%b | ps=%0d cmt=%0d ffw=%0d ffr=%0d",
                         k, u_slow_rx.abort, u_slow_rx.s_acc, u_slow_rx.u_ff.full,
                         u_slow_rx.ff_snap, u_slow_rx.in_frame, u_slow_rx.resync_drop,
                         u_slow_rx.pstate, u_slow_rx.committed,
                         u_slow_rx.u_ff.wptr, u_slow_rx.u_ff.rptr);
            // 细粒度窗口: abort 翻转区逐拍
            if (k >= 8530 && k <= 8560)
                $display("FINE k=%0d ab=%b acc=%b u=%b l=%b crs=%b err=%b ful=%b snap=%b fe=%b te=%b ifm=%b rsd=%b",
                         k, u_slow_rx.abort, u_slow_rx.s_acc, u_slow_rx.s_axis_tuser,
                         u_slow_rx.s_axis_tlast, u_slow_rx.s_axis_tcrs, u_slow_rx.s_axis_terr,
                         u_slow_rx.u_ff.full, u_slow_rx.ff_snap,
                         u_slow_rx.frame_end, u_slow_rx.trunc_evt,
                         u_slow_rx.in_frame, u_slow_rx.resync_drop);
        end
    end

    // ---- PROBE 模式 (+PROBE): 每 5000 拍打印慢路径内部状态 (泛洪排障) ----
    integer fd2 = 0;
    always @(posedge clk) begin
        if (rst_n && $test$plusargs("PROBE")) begin
            if (fd2 == 0) fd2 = $fopen("hls_rx_bytes.memh", "w");
            if (hls_rx_tvalid && hls_rx_tready)
                $fwrite(fd2, "%0d %03h\n", k, hls_rx_tdata[8:0]);
            if (w_tvalid && w_tready)
                $fwrite(fd2, "SRX %0d u=%b l=%b c=%b e=%b k=%02h ab=%b rs=%b if=%b ful=%b cmt=%0d\n",
                        k, w_tuser, w_tlast, w_tcrs, w_terr, w_tkeep,
                        u_slow_rx.abort, u_slow_rx.resync_drop, u_slow_rx.in_frame,
                        u_slow_rx.u_ff.full, u_slow_rx.committed);
            if (k % 32'd5000 == 0)
                $display("PROBE k=%0d | cls state=%0d | srx pstate=%0d cmt=%0d ab=%b rsd=%b ifm=%b ffw=%0d ffr=%0d occw=%0d | hls rxrdy=%b txv=%b txrdy=%b | stx tstate=%0d cmt=%0d",
                         k, u_classify.state, u_slow_rx.pstate, u_slow_rx.committed,
                         u_slow_rx.abort, u_slow_rx.resync_drop, u_slow_rx.in_frame,
                         u_slow_rx.u_ff.wptr, u_slow_rx.u_ff.rptr,
                         (u_slow_rx.u_ofifo.wptr - u_slow_rx.u_ofifo.rptr),
                         hls_rx_tready, hls_tx_tvalid, hls_tx_tready,
                         u_slow_tx.tstate, u_slow_tx.committed);
        end
    end
endmodule
