`timescale 1ns/1ps
//=============================================================================
// wrapper_p4.v — udp_hls_10g 板上 P4a 顶层 (1G RGMII): TCP fast path + HLS 慢路径
//=============================================================================
// 数据面: PC → PHY1 RGMII → util_gmii_to_rgmii → mac_rx_64 → rx_classify
//   fast (IPv4/TCP): tcp_rx → tcp_echo → tcp_tx_frame ─┐
//     (tcp_synp P4-lite 握手保留; CAM/TCB 同 P3 链)     ├→ tx_arb (fast 优先)
//   slow (其他全部):  slow_rx_adp → udp_echo (HLS 慢路径)│
//     udp_echo.tx_stream → slow_tx_adp ─────────────────┘
//   tx_arb → mac_tx_64 → util → PHY1 → PC
//
// 前端 recipe 与 wrapper_tcp.v 逐字一致 (MMCM 200M + IDELAYCTRL + u_rgmii
// 实例名 + RX 再寄存一拍; eco_rgmii_phy1.xdc 原样复用)。
//
// MAC 统一: HLS 编译期 MAC = 00:0A:35:01:FE:C0 (板验资产) — fast path cfg
// 同步改为 C0 (原 C1 作废)。HLS 应答 ARP (who-has 192.168.100.2 → C0),
// PC 免静态 ARP。HLS 自发行文: 上电 ~1s DHCP DISCOVER ×3 + 每 ~5s UDP HELLO
// (白送的慢路径 TX 冒烟, pktmon 可见)。
//
// LED (引脚同 wrapper_1g.v):
//   led_d0 = mac_rx_64.stat_frames[0]   (RX 帧活动)
//   led_d1 = tcp_rx.stat_pass[0]        (TCP 匹配且 FCS 好)
//   led_d2 = slow_rx_adp.stat_commit[0] (提交给 HLS 的慢帧)
//   led_d3 = slow_tx_adp.stat_frames[0] (HLS 发出帧: ARP/ICMP/DHCP 活动)
//=============================================================================

module wrapper_p4 (
    input           reset_n,
    input           fpga_gclk,
    input           phy1_rxc,
    input  [3:0]    phy1_rxd,
    input           phy1_rxctl,
    output          phy1_txc,
    output [3:0]    phy1_txd,
    output          phy1_txctl,
    output          led_d0,
    output          led_d1,
    output          led_d2,
    output          led_d3
);

    // --- 200MHz IDELAYCTRL 参考钟 (逐字照抄 wrapper_tcp.v) ---
    wire ref200_clk, ref200_clk_raw, ref200_fb, mmcm_ref_locked;
    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKIN1_PERIOD(20.0),
        .CLKFBOUT_MULT_F(20.0),
        .CLKFBOUT_PHASE(0.0),
        .DIVCLK_DIVIDE(1),
        .CLKOUT0_DIVIDE_F(5.0),
        .CLKOUT0_DUTY_CYCLE(0.5),
        .CLKOUT0_PHASE(0.0),
        .CLKOUT1_DIVIDE(1), .CLKOUT1_DUTY_CYCLE(0.5), .CLKOUT1_PHASE(0.0),
        .CLKOUT2_DIVIDE(1), .CLKOUT2_DUTY_CYCLE(0.5), .CLKOUT2_PHASE(0.0),
        .CLKOUT3_DIVIDE(1), .CLKOUT3_DUTY_CYCLE(0.5), .CLKOUT3_PHASE(0.0),
        .CLKOUT4_DIVIDE(1), .CLKOUT4_DUTY_CYCLE(0.5), .CLKOUT4_PHASE(0.0),
        .CLKOUT5_DIVIDE(1), .CLKOUT5_DUTY_CYCLE(0.5), .CLKOUT5_PHASE(0.0),
        .CLKOUT6_DIVIDE(1), .CLKOUT6_DUTY_CYCLE(0.5), .CLKOUT6_PHASE(0.0),
        .REF_JITTER1(0.010),
        .STARTUP_WAIT("FALSE")
    ) u_mmcm_ref (
        .CLKIN1(fpga_gclk),
        .CLKOUT0(ref200_clk_raw),
        .CLKOUT0B(),
        .CLKOUT1(), .CLKOUT1B(),
        .CLKOUT2(), .CLKOUT2B(),
        .CLKOUT3(), .CLKOUT3B(),
        .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
        .CLKFBOUT(ref200_fb),
        .CLKFBOUTB(),
        .CLKFBIN(ref200_fb),
        .LOCKED(mmcm_ref_locked),
        .PWRDWN(1'b0),
        .RST(!reset_n)
    );
    BUFG u_bufg_200 (.I(ref200_clk_raw), .O(ref200_clk));

    wire delay_ready;
    (* IODELAY_GROUP = "idelay" *) IDELAYCTRL u_idelayctrl (
        .RDY(delay_ready),
        .REFCLK(ref200_clk),
        .RST(1'b0)
    );

    // --- RGMII 适配 (实例名 u_rgmii 不可改, XDC generated clock 引用) ---
    wire gmii_clk;
    wire [7:0] e_rxd;
    wire       e_rxdv, e_rxer;
    wire [7:0] e_txd;
    wire       e_txen;
    wire       e_txer;

    util_gmii_to_rgmii u_rgmii (
        .reset          (1'b0),
        .rgmii_td       (phy1_txd),
        .rgmii_tx_ctl   (phy1_txctl),
        .rgmii_txc      (phy1_txc),
        .rgmii_rd_i     (phy1_rxd),
        .rgmii_rx_ctl_i (phy1_rxctl),
        .gmii_rx_clk    (gmii_clk),
        .rgmii_rxc      (phy1_rxc),
        .gmii_txd       (e_txd),
        .gmii_tx_en     (e_txen),
        .gmii_tx_er     (e_txer),
        .gmii_tx_clk    (),
        .gmii_crs       (),
        .gmii_col       (),
        .gmii_rxd       (e_rxd),
        .gmii_rx_dv     (e_rxdv),
        .gmii_rx_er     (e_rxer),
        .speed_selection(2'b10),
        .duplex_mode    (1'b1)
    );

    // --- RX 流再寄存一拍 (照抄) ---
    reg [7:0] rx_d1;
    reg       rx_dv_d1, rx_er_d1;
    always @(posedge gmii_clk or negedge reset_n) begin
        if (!reset_n) begin rx_d1<=0; rx_dv_d1<=0; rx_er_d1<=0; end
        else begin rx_d1<=e_rxd; rx_dv_d1<=e_rxdv; rx_er_d1<=e_rxer; end
    end

    // --- mac_rx_64 → rx_classify ---
    wire [63:0] rx_tdata;
    wire [7:0]  rx_tkeep;
    wire        rx_tvalid, rx_tready, rx_tlast, rx_tuser, rx_tcrs, rx_terr;
    wire [31:0] rx_stat_frames, rx_stat_crc_err, rx_stat_drop, rx_stat_bytes;

    wire [63:0] f_tdata;
    wire [7:0]  f_tkeep;
    wire        f_tvalid, f_tready, f_tlast, f_tuser, f_tcrs, f_terr;
    wire [63:0] s_tdata;
    wire [7:0]  s_tkeep;
    wire        s_tvalid, s_tready, s_tlast, s_tuser, s_tcrs, s_terr;
    wire [31:0] cls_stat_fast, cls_stat_slow;

    mac_rx_64 u_mac_rx (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .gmii_rxd       (rx_d1),
        .gmii_rx_dv     (rx_dv_d1),
        .gmii_rx_er     (rx_er_d1),
        .m_axis_tdata   (rx_tdata),
        .m_axis_tkeep   (rx_tkeep),
        .m_axis_tvalid  (rx_tvalid),
        .m_axis_tready  (rx_tready),
        .m_axis_tlast   (rx_tlast),
        .m_axis_tuser   (rx_tuser),
        .m_axis_terr    (rx_terr),
        .m_axis_tcrs    (rx_tcrs),
        .stat_frames    (rx_stat_frames),
        .stat_crc_err   (rx_stat_crc_err),
        .stat_drop      (rx_stat_drop),
        .stat_bytes     (rx_stat_bytes)
    );

    rx_classify u_classify (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .s_axis_tdata   (rx_tdata),
        .s_axis_tkeep   (rx_tkeep),
        .s_axis_tvalid  (rx_tvalid),
        .s_axis_tready  (rx_tready),
        .s_axis_tlast   (rx_tlast),
        .s_axis_tuser   (rx_tuser),
        .s_axis_tcrs    (rx_tcrs),
        .s_axis_terr    (rx_terr),
        .m_fast_tdata   (f_tdata),
        .m_fast_tkeep   (f_tkeep),
        .m_fast_tvalid  (f_tvalid),
        .m_fast_tready  (f_tready),
        .m_fast_tlast   (f_tlast),
        .m_fast_tuser   (f_tuser),
        .m_fast_tcrs    (f_tcrs),
        .m_fast_terr    (f_terr),
        .m_slow_tdata   (s_tdata),
        .m_slow_tkeep   (s_tkeep),
        .m_slow_tvalid  (s_tvalid),
        .m_slow_tready  (s_tready),
        .m_slow_tlast   (s_tlast),
        .m_slow_tuser   (s_tuser),
        .m_slow_tcrs    (s_tcrs),
        .m_slow_terr    (s_terr),
        .stat_fast      (cls_stat_fast),
        .stat_slow      (cls_stat_slow)
    );

    // --- fast 路由: P3 TCP 链 (tcp_rx → tcp_echo → tcp_tx_frame) ---
    wire [63:0] pay_tdata;
    wire [7:0]  pay_tkeep;
    wire        pay_tvalid, pay_tready, pay_tlast;
    wire [1:0]  pay_tuser;
    wire        pay_fend, pay_ferr;
    wire        pay_meta_valid;
    wire [31:0] pay_meta_src_ip;
    wire [15:0] pay_meta_src_port;
    wire [15:0] pay_meta_len;
    wire [3:0]  pay_meta_conn_id;
    wire [31:0] pay_meta_seq;

    wire [63:0] eco_tdata;
    wire [7:0]  eco_tkeep;
    wire        eco_tvalid, eco_tready, eco_tlast;
    wire [3:0]  eco_tid;

    wire [63:0] tx_tdata;
    wire [7:0]  tx_tkeep;
    wire        tx_tvalid, tx_tready, tx_tlast;
    wire [31:0] tx_stat_frames, tx_stat_bytes, tx_stat_abort;

    wire [31:0] rx_stat_pass, rx_stat_nonmatch, rx_stat_ipcsum, rx_stat_crc,
                rx_stat_seq, rx_stat_ack, rx_stat_bytes_tcp;
    wire [31:0] eco_stat_echo, eco_stat_drop_crc;

    wire [3:0]  ra_id;
    wire [31:0] ra_rcv_nxt, ra_snd_nxt, ra_snd_una;
    wire [15:0] ra_rcv_wnd;
    wire [3:0]  ra_state;
    wire [3:0]  rb_id;
    wire [31:0] rb_rcv_nxt, rb_snd_nxt, rb_snd_una;
    wire [15:0] rb_rcv_wnd, rb_snd_wnd;
    wire [3:0]  rb_state;

    // TCB 更新仲裁输出 (tx > rx > cfg) — 显式先声明再供 u_tcb 使用
    // (wrapper_tcp.v 的先使用后声明靠 Vivado 宽容过关, xvlog 直接报错)
    wire        tcb_wr;
    wire [3:0]  tcb_id;
    wire [2:0]  tcb_sel;
    wire [31:0] tcb_val;

    wire        rx_upd_wr, rx_upd_gnt;
    wire [3:0]  rx_upd_id;
    wire [2:0]  rx_upd_sel;
    wire [31:0] rx_upd_val;
    wire        tx_upd_wr;
    wire [3:0]  tx_upd_id;
    wire [2:0]  tx_upd_sel;
    wire [31:0] tx_upd_val;

    wire        rx_ack_req;
    wire [3:0]  rx_ack_id;
    wire [31:0] rx_ack_val;

    wire        syn_v;
    wire [47:0] syn_smac;
    wire [31:0] syn_sip;
    wire [15:0] syn_sport, syn_dport;
    wire [31:0] syn_seq;
    wire [15:0] syn_wnd;

    wire        synp_cfg_wr;
    wire [3:0]  synp_cfg_addr;
    wire [31:0] synp_cfg_sip, synp_cfg_dip;
    wire [15:0] synp_cfg_sport, synp_cfg_dport;
    wire [47:0] synp_cfg_dmac;
    wire        synp_upd_wr;
    wire [3:0]  synp_upd_id;
    wire [2:0]  synp_upd_sel;
    wire [31:0] synp_upd_val;
    wire        synp_sack_req;
    wire [3:0]  synp_sack_id;
    wire [31:0] synp_sack_ackval;

    wire [31:0] cam_q_sip, cam_q_dip;
    wire [15:0] cam_q_sport, cam_q_dport;
    wire        cam_q_hit;
    wire [3:0]  cam_q_id;
    wire [3:0]  cam_rd_id;
    wire [47:0] cam_rd_dmac;
    wire [31:0] cam_rd_sip, cam_rd_dip;
    wire [15:0] cam_rd_sport, cam_rd_dport;

    tcp_rx u_tcp_rx (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .s_axis_tdata   (f_tdata),
        .s_axis_tkeep   (f_tkeep),
        .s_axis_tvalid  (f_tvalid),
        .s_axis_tready  (f_tready),
        .s_axis_tlast   (f_tlast),
        .s_axis_tuser   (f_tuser),
        .s_axis_tcrs    (f_tcrs),
        .s_axis_terr    (f_terr),
        .m_axis_tdata   (pay_tdata),
        .m_axis_tkeep   (pay_tkeep),
        .m_axis_tvalid  (pay_tvalid),
        .m_axis_tready  (pay_tready),
        .m_axis_tlast   (pay_tlast),
        .m_axis_tuser   (pay_tuser),
        .fend           (pay_fend),
        .ferr           (pay_ferr),
        .meta_valid     (pay_meta_valid),
        .meta_src_ip    (pay_meta_src_ip),
        .meta_src_port  (pay_meta_src_port),
        .meta_len       (pay_meta_len),
        .meta_conn_id   (pay_meta_conn_id),
        .meta_seq       (pay_meta_seq),
        .ra_id          (ra_id),
        .ra_rcv_nxt     (ra_rcv_nxt),
        .ra_snd_nxt     (ra_snd_nxt),
        .ra_snd_una     (ra_snd_una),
        .ra_rcv_wnd     (ra_rcv_wnd),
        .ra_state       (ra_state),
        .upd_wr         (rx_upd_wr),
        .upd_id         (rx_upd_id),
        .upd_sel        (rx_upd_sel),
        .upd_val        (rx_upd_val),
        .upd_gnt        (rx_upd_gnt),
        .ack_req        (rx_ack_req),
        .ack_id         (rx_ack_id),
        .ack_val        (rx_ack_val),
        .syn_v          (syn_v),
        .syn_smac       (syn_smac),
        .syn_sip        (syn_sip),
        .syn_sport      (syn_sport),
        .syn_dport      (syn_dport),
        .syn_seq        (syn_seq),
        .syn_wnd        (syn_wnd),
        .cam_q_sip      (cam_q_sip),
        .cam_q_dip      (cam_q_dip),
        .cam_q_sport    (cam_q_sport),
        .cam_q_dport    (cam_q_dport),
        .cam_q_hit      (cam_q_hit),
        .cam_q_id       (cam_q_id),
        .stat_pass          (rx_stat_pass),
        .stat_drop_nonmatch (rx_stat_nonmatch),
        .stat_drop_ipcsum   (rx_stat_ipcsum),
        .stat_drop_crc      (rx_stat_crc),
        .stat_drop_seq      (rx_stat_seq),
        .stat_ack           (rx_stat_ack),
        .stat_bytes         (rx_stat_bytes_tcp)
    );

    tcp_echo u_tcp_echo (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .s_axis_tdata   (pay_tdata),
        .s_axis_tkeep   (pay_tkeep),
        .s_axis_tvalid  (pay_tvalid),
        .s_axis_tready  (pay_tready),
        .s_axis_tlast   (pay_tlast),
        .s_axis_tuser   (pay_tuser),
        .fend           (pay_fend),
        .ferr           (pay_ferr),
        .meta_valid     (pay_meta_valid),
        .meta_conn_id   (pay_meta_conn_id),
        .meta_len       (pay_meta_len),
        .m_axis_tdata   (eco_tdata),
        .m_axis_tkeep   (eco_tkeep),
        .m_axis_tvalid  (eco_tvalid),
        .m_axis_tready  (eco_tready),
        .m_axis_tlast   (eco_tlast),
        .m_axis_tid     (eco_tid),
        .stat_echo      (eco_stat_echo),
        .stat_drop_crc  (eco_stat_drop_crc)
    );

    tcp_cam u_cam (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .cfg_wr         (synp_cfg_wr),
        .cfg_addr       (synp_cfg_addr),
        .cfg_sip        (synp_cfg_sip),
        .cfg_dip        (synp_cfg_dip),
        .cfg_sport      (synp_cfg_sport),
        .cfg_dport      (synp_cfg_dport),
        .cfg_dmac       (synp_cfg_dmac),
        .q_sip          (cam_q_sip),
        .q_dip          (cam_q_dip),
        .q_sport        (cam_q_sport),
        .q_dport        (cam_q_dport),
        .q_id           (cam_q_id),
        .q_hit          (cam_q_hit),
        .rd_id          (cam_rd_id),
        .rd_dmac        (cam_rd_dmac),
        .rd_sip         (cam_rd_sip),
        .rd_dip         (cam_rd_dip),
        .rd_sport       (cam_rd_sport),
        .rd_dport       (cam_rd_dport)
    );

    tcb u_tcb (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .ra_id          (ra_id),
        .ra_rcv_nxt     (ra_rcv_nxt),
        .ra_snd_nxt     (ra_snd_nxt),
        .ra_snd_una     (ra_snd_una),
        .ra_rcv_wnd     (ra_rcv_wnd),
        .ra_snd_wnd     (),
        .ra_state       (ra_state),
        .rb_id          (rb_id),
        .rb_rcv_nxt     (rb_rcv_nxt),
        .rb_snd_nxt     (rb_snd_nxt),
        .rb_snd_una     (rb_snd_una),
        .rb_rcv_wnd     (rb_rcv_wnd),
        .rb_snd_wnd     (rb_snd_wnd),
        .rb_state       (rb_state),
        .upd_wr         (tcb_wr),
        .upd_id         (tcb_id),
        .upd_sel        (tcb_sel),
        .upd_val        (tcb_val)
    );

    // ---- TCB 更新仲裁 (组合, tx > rx > cfg 级; cfg 级 = synp.upd) ----
    wire        sel_tx = tx_upd_wr;
    wire        sel_rx = !sel_tx && rx_upd_wr;
    assign tcb_wr  = sel_tx || sel_rx || synp_upd_wr;
    assign tcb_sel = sel_tx ? tx_upd_sel : (sel_rx ? rx_upd_sel : synp_upd_sel);
    assign tcb_id  = sel_tx ? tx_upd_id  : (sel_rx ? rx_upd_id  : synp_upd_id);
    assign tcb_val = sel_tx ? tx_upd_val : (sel_rx ? rx_upd_val : synp_upd_val);
    assign rx_upd_gnt = sel_rx;

    tcp_synp u_synp (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .syn_v          (syn_v),
        .syn_smac       (syn_smac),
        .syn_sip        (syn_sip),
        .syn_sport      (syn_sport),
        .syn_dport      (syn_dport),
        .syn_seq        (syn_seq),
        .syn_wnd        (syn_wnd),
        .cfg_wr         (synp_cfg_wr),
        .cfg_addr       (synp_cfg_addr),
        .cfg_sip        (synp_cfg_sip),
        .cfg_dip        (synp_cfg_dip),
        .cfg_sport      (synp_cfg_sport),
        .cfg_dport      (synp_cfg_dport),
        .cfg_dmac       (synp_cfg_dmac),
        .upd_wr         (synp_upd_wr),
        .upd_id         (synp_upd_id),
        .upd_sel        (synp_upd_sel),
        .upd_val        (synp_upd_val),
        .sack_req       (synp_sack_req),
        .sack_id        (synp_sack_id),
        .sack_ackval    (synp_sack_ackval),
        .cfg_my_ip      (32'hC0A86402),   // 192.168.100.2
        .cfg_listen     (16'd8080),
        .cfg_iss        (32'd5999)
    );

    wire        tx_ack_req = synp_sack_req | rx_ack_req;
    wire [3:0]  tx_ack_id  = synp_sack_req ? synp_sack_id     : rx_ack_id;
    wire [31:0] tx_ack_val = synp_sack_req ? synp_sack_ackval : rx_ack_val;
    wire        tx_ack_syn = synp_sack_req;

    tcp_tx_frame u_tcp_tx (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .s_axis_tdata   (eco_tdata),
        .s_axis_tkeep   (eco_tkeep),
        .s_axis_tvalid  (eco_tvalid),
        .s_axis_tready  (eco_tready),
        .s_axis_tlast   (eco_tlast),
        .s_axis_tid     (eco_tid),
        .ack_req        (tx_ack_req),
        .ack_id         (tx_ack_id),
        .ack_val        (tx_ack_val),
        .ack_syn        (tx_ack_syn),
        .rb_id          (rb_id),
        .rb_snd_nxt     (rb_snd_nxt),
        .rb_rcv_nxt     (rb_rcv_nxt),
        .rb_rcv_wnd     (rb_rcv_wnd),
        .upd_wr         (tx_upd_wr),
        .upd_id         (tx_upd_id),
        .upd_sel        (tx_upd_sel),
        .upd_val        (tx_upd_val),
        .cam_rd_id      (cam_rd_id),
        .cam_rd_dmac    (cam_rd_dmac),
        .cam_rd_sip     (cam_rd_sip),
        .cam_rd_sport   (cam_rd_sport),
        .cam_rd_dport   (cam_rd_dport),
        .cfg_src_mac    (48'h000A3501FEC0),  // 00:0A:35:01:FE:C0 (P4 统一 HLS MAC)
        .cfg_src_ip     (32'hC0A86402),      // 192.168.100.2
        .m_axis_tdata   (tx_tdata),
        .m_axis_tkeep   (tx_tkeep),
        .m_axis_tvalid  (tx_tvalid),
        .m_axis_tready  (tx_tready),
        .m_axis_tlast   (tx_tlast),
        .stat_frames    (tx_stat_frames),
        .stat_bytes     (tx_stat_bytes),
        .stat_ack       (),
        .stat_ack_drop  ()
    );

    // --- slow 路由: slow_rx_adp → udp_echo (HLS) → slow_tx_adp ---
    wire [15:0] hls_rx_tdata;
    wire        hls_rx_tvalid, hls_rx_tready;
    wire [15:0] hls_tx_tdata;
    wire        hls_tx_tvalid, hls_tx_tready;
    wire [15:0] hls_msg_tdata;
    wire        hls_msg_tvalid;
    wire [31:0] srx_stat_commit, srx_stat_drop;
    wire [63:0] stx_tdata;
    wire [7:0]  stx_tkeep;
    wire        stx_tvalid, stx_tready, stx_tlast;
    wire [31:0] stx_stat_frames, stx_stat_purge;

    slow_rx_adp u_slow_rx (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .s_axis_tdata   (s_tdata),
        .s_axis_tkeep   (s_tkeep),
        .s_axis_tvalid  (s_tvalid),
        .s_axis_tready  (s_tready),
        .s_axis_tlast   (s_tlast),
        .s_axis_tuser   (s_tuser),
        .s_axis_tcrs    (s_tcrs),
        .s_axis_terr    (s_terr),
        .hls_rx_tdata   (hls_rx_tdata),
        .hls_rx_tvalid  (hls_rx_tvalid),
        .hls_rx_tready  (hls_rx_tready),
        .stat_commit    (srx_stat_commit),
        .stat_drop      (srx_stat_drop)
    );

    // HLS 慢路径协议栈 (udp_hls_eco 原样综合产物; ap_ctrl_none;
    //  reset_n 是 ap_none 软复位必须显式接 — 悬空 = phi-mux X 死锁)
    udp_echo u_hls (
        .ap_clk           (gmii_clk),
        .ap_rst_n         (reset_n),
        .reset_n          (reset_n),
        .rx_stream_TDATA  (hls_rx_tdata),
        .rx_stream_TVALID (hls_rx_tvalid),
        .rx_stream_TREADY (hls_rx_tready),
        .tx_stream_TDATA  (hls_tx_tdata),
        .tx_stream_TVALID (hls_tx_tvalid),
        .tx_stream_TREADY (hls_tx_tready),
        .msg_stream_TDATA (hls_msg_tdata),
        .msg_stream_TVALID(hls_msg_tvalid),
        .msg_stream_TREADY(1'b1),
        .led_d0           (),
        .led_d1           (),
        .led_d2           (),
        .led_d3           ()
    );

    slow_tx_adp u_slow_tx (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .hls_tx_tdata   (hls_tx_tdata),
        .hls_tx_tvalid  (hls_tx_tvalid),
        .hls_tx_tready  (hls_tx_tready),
        .m_axis_tdata   (stx_tdata),
        .m_axis_tkeep   (stx_tkeep),
        .m_axis_tvalid  (stx_tvalid),
        .m_axis_tready  (stx_tready),
        .m_axis_tlast   (stx_tlast),
        .stat_frames    (stx_stat_frames),
        .stat_purge     (stx_stat_purge)
    );

    // --- TX 仲裁: fast (TCP) 严格优先于 slow (HLS) ---
    wire [63:0] m_tx_tdata;
    wire [7:0]  m_tx_tkeep;
    wire        m_tx_tvalid, m_tx_tready, m_tx_tlast;

    tx_arb u_tx_arb (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .s_fast_tdata   (tx_tdata),
        .s_fast_tkeep   (tx_tkeep),
        .s_fast_tvalid  (tx_tvalid),
        .s_fast_tready  (tx_tready),
        .s_fast_tlast   (tx_tlast),
        .s_slow_tdata   (stx_tdata),
        .s_slow_tkeep   (stx_tkeep),
        .s_slow_tvalid  (stx_tvalid),
        .s_slow_tready  (stx_tready),
        .s_slow_tlast   (stx_tlast),
        .m_axis_tdata   (m_tx_tdata),
        .m_axis_tkeep   (m_tx_tkeep),
        .m_axis_tvalid  (m_tx_tvalid),
        .m_axis_tready  (m_tx_tready),
        .m_axis_tlast   (m_tx_tlast)
    );

    mac_tx_64 u_mac_tx (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .s_axis_tdata   (m_tx_tdata),
        .s_axis_tkeep   (m_tx_tkeep),
        .s_axis_tvalid  (m_tx_tvalid),
        .s_axis_tready  (m_tx_tready),
        .s_axis_tlast   (m_tx_tlast),
        .gmii_txd       (e_txd),
        .gmii_tx_en     (e_txen),
        .gmii_tx_er     (e_txer),
        .stat_frames    (),
        .stat_abort     (tx_stat_abort)
    );

    // --- LED 观测 ---
    assign led_d0 = rx_stat_frames[0];     // RX 帧活动
    assign led_d1 = rx_stat_pass[0];       // TCP 匹配且 FCS 好
    assign led_d2 = srx_stat_commit[0];    // 提交给 HLS 的慢帧 (ARP/ICMP 活动)
    assign led_d3 = stx_stat_frames[0];    // HLS 发出帧 (应答/自发行文)

endmodule
