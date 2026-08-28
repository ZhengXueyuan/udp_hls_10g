`timescale 1ns/1ps
//=============================================================================
// wrapper_tcp.v — udp_hls_10g 板上 TCP echo 顶层 (1G RGMII, P3 阶段)
//=============================================================================
// 功能: PC 发 TCP 帧 → PHY1 RGMII → util_gmii_to_rgmii (GMII 125MHz) →
//       mac_rx_64 (前导剥离 + FCS 校验剥离 → 64bit 左对齐字流) → tcp_rx
//       (IP/TCP 头解析 + CAM 匹配 + seq 顺序检查 + 载荷直出 + TCB 更新 +
//        ACK 请求 + SYN sideband) → tcp_echo (整帧判定后入 FIFO, 坏帧回卷,
//        conn_id 随帧排队) → tcp_tx_frame (组 TCP/IP/以太网头, TCP 校验和,
//        ACK 优先于数据) → mac_tx_64 (前导/FCS/pad/IFG 重建) → util → PHY1 → PC。
//       tcp_synp: SYN 监听 → 占用 CAM0+TCB0 → 回 SYN+ACK (P4-lite 握手);
//       CAM 配置口板上由 synp 独占 (无其它写者, 直连)。
//
// 前端 recipe 逐字复用 wrapper_1g.v (板上 PASS 配方, 与 wrapper_echo 一致):
//   1. MMCME2_BASE(50M→200M) + BUFG + IDELAYCTRL   (本文件, 照抄)
//   2. util_gmii_to_rgmii u_rgmii 实例             (实例名/参数逐行一致,
//       generated clock 引用 u_rgmii/bufmr_rgmii_rxc/O — 名字不能改)
//   3. eco_rgmii_phy1.xdc 原样复用                  (顶层端口名必须相同)
//   4. RX 侧 util 输出再寄存一拍                    (照抄)
//
// 时钟: 全设计同域 gmii_clk (util 的 gmii_rx_clk 输出, 125MHz 恢复钟)。
// 复位: reset_n (KEY1, 低有效) 直连异步复位 (同 wrapper_1g.v)。
// LED (引脚与 wrapper_1g.v 相同, A23/A24/D23/C24):
//   led_d0 = mac_rx_64.stat_frames[0]   (RX 完整帧计数 LSB, 每帧翻转)
//   led_d1 = tcp_rx.stat_pass[0]        (TCP 匹配且 FCS 好计数 LSB)
//   led_d2 = tcp_echo.stat_echo[0]      (回发帧计数 LSB)
//   led_d3 = tcp_echo.stat_drop_crc[0]  (回卷丢弃计数 LSB, 正常恒灭)
//=============================================================================

module wrapper_tcp (
    input           reset_n,        // 异步复位, 低有效 (KEY1)
    input           fpga_gclk,      // 50MHz 板载晶振 (MMCM 参考 → 200M IDELAYCTRL)
    // RGMII RX from PHY (RTL8211E; PHY1 = AB2 引脚组, bank 34 LVCMOS18)
    input           phy1_rxc,       // RX 时钟 (1G 链路 = 125MHz)
    input  [3:0]    phy1_rxd,       // RX 数据 (DDR)
    input           phy1_rxctl,     // RX 控制 (DDR: 上升=RXDV, 下降=RXDV^RXER)
    // RGMII TX to PHY
    output          phy1_txc,       // TX 时钟到 PHY
    output [3:0]    phy1_txd,       // TX 数据 (DDR)
    output          phy1_txctl,     // TX 控制 (DDR: 上升=TXEN, 下降=TXEN^TXER)
    // LEDs
    output          led_d0,
    output          led_d1,
    output          led_d2,
    output          led_d3
);

    // 注意: 与 wrapper_1g.v 一致, 不驱动 mdc/mdio/nrst — k720 demo 只驱动 12
    // 根 RGMII 引脚; 未用引脚靠 bitstream 的 UNUSEDPIN Pullup 浮空, 同 demo。

    // --- 200MHz IDELAYCTRL 参考钟: MMCM from 50MHz 板钟 ---
    // 逐字照抄 wrapper_1g.v: 50 × 20 = 1000MHz VCO; ÷5 = 200MHz。
    // CLKFBIN 闭环 (开环不锁)。
    wire ref200_clk, ref200_clk_raw, ref200_fb, mmcm_ref_locked;
    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKIN1_PERIOD(20.0),          // 50MHz 板载晶振
        .CLKFBOUT_MULT_F(20.0),        // VCO = 50 × 20 = 1000MHz
        .CLKFBOUT_PHASE(0.0),
        .DIVCLK_DIVIDE(1),
        .CLKOUT0_DIVIDE_F(5.0),        // 1000/5 = 200MHz
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
        .CLKFBIN(ref200_fb),           // 反馈环必须闭合
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

    // --- RGMII 适配: k720 demo 的 util_gmii_to_rgmii.v 逐字 ---
    // 实例化与 wrapper_1g.v 逐行一致 (实例名 u_rgmii 必须保持 —
    // eco_rgmii_phy1.xdc 的 generated clock 引用 u_rgmii/bufmr_rgmii_rxc/O)。
    // 自带 BUFG(倒相 RXC) + IDELAYE2(10) + IDDR/ODDR 链, 输出 gmii_rx_clk
    // 供全设计; speed=2'b10 (千兆), duplex=1, reset 接死 (同 demo)。
    wire gmii_clk;
    wire [7:0] e_rxd;
    wire       e_rxdv, e_rxer;
    wire [7:0] e_txd;     // mac_tx_64 输出的 GMII TX
    wire       e_txen;
    wire       e_txer;    // mac_tx_64 预留, 恒 0

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
        .speed_selection(2'b10),   // gigabit
        .duplex_mode    (1'b1)     // full duplex
    );

    // --- RX 流再寄存一拍 (照抄 wrapper_1g.v 结构) ---
    // util 输出已是寄存器, 此处再一级: 与板上验证路径的时序结构保持一致。
    reg [7:0] rx_d1;
    reg       rx_dv_d1, rx_er_d1;
    always @(posedge gmii_clk or negedge reset_n) begin
        if (!reset_n) begin rx_d1<=0; rx_dv_d1<=0; rx_er_d1<=0; end
        else begin rx_d1<=e_rxd; rx_dv_d1<=e_rxdv; rx_er_d1<=e_rxer; end
    end

    // --- 数据面: mac_rx_64 → tcp_rx → tcp_echo → tcp_tx_frame → mac_tx_64 ---
    // 级间接线: tdata/tkeep/tvalid/tready/tlast 一一对接; tuser(SOP)/tcrs/terr
    // 由 mac_rx_64 直连 tcp_rx; tcp_rx 的 fend/ferr/meta_* 接 tcp_echo 判定;
    // echo 的 m_axis_tid (conn_id 随帧排队) 接 tcp_tx_frame 的 s_axis_tid。
    // 背压合同: mac_rx_64 内部 8 深 FIFO, 满则整帧原子丢弃 (stat_drop 计数);
    // tcp_echo frame_fifo 2048 深, tcp_tx_frame 256 深, 常态回显吞吐足够。
    wire [63:0] rx_tdata;
    wire [7:0]  rx_tkeep;
    wire        rx_tvalid, rx_tready, rx_tlast, rx_tuser, rx_tcrs, rx_terr;
    wire [31:0] rx_stat_frames, rx_stat_crc_err, rx_stat_drop, rx_stat_bytes;

    // tcp_rx 载荷直出 → tcp_echo
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

    // tcp_echo → tcp_tx_frame
    wire [63:0] eco_tdata;
    wire [7:0]  eco_tkeep;
    wire        eco_tvalid, eco_tready, eco_tlast;
    wire [3:0]  eco_tid;

    // tcp_tx_frame → mac_tx_64
    wire [63:0] tx_tdata;
    wire [7:0]  tx_tkeep;
    wire        tx_tvalid, tx_tready, tx_tlast;
    wire [31:0] tx_stat_frames, tx_stat_bytes, tx_stat_abort;

    // tcp_rx 统计
    wire [31:0] rx_stat_pass, rx_stat_nonmatch, rx_stat_ipcsum, rx_stat_crc,
                rx_stat_seq, rx_stat_ack, rx_stat_bytes_tcp;
    // tcp_echo 统计
    wire [31:0] eco_stat_echo, eco_stat_drop_crc;

    // ---- TCB 读口 A (RX) ----
    wire [3:0]  ra_id;
    wire [31:0] ra_rcv_nxt, ra_snd_nxt, ra_snd_una;
    wire [15:0] ra_rcv_wnd;
    wire [3:0]  ra_state;
    // ---- TCB 读口 B (TX) ----
    wire [3:0]  rb_id;
    wire [31:0] rb_rcv_nxt, rb_snd_nxt, rb_snd_una;
    wire [15:0] rb_rcv_wnd, rb_snd_wnd;
    wire [3:0]  rb_state;

    // ---- TCB 更新仲裁 (tx > rx > cfg 级; cfg 级 = synp.upd) ----
    wire        rx_upd_wr, rx_upd_gnt;
    wire [3:0]  rx_upd_id;
    wire [2:0]  rx_upd_sel;
    wire [31:0] rx_upd_val;
    wire        tx_upd_wr;
    wire [3:0]  tx_upd_id;
    wire [2:0]  tx_upd_sel;
    wire [31:0] tx_upd_val;

    // ---- ACK 请求二选一: synp (SYN+ACK) 优先 ----
    wire        rx_ack_req;
    wire [3:0]  rx_ack_id;
    wire [31:0] rx_ack_val;

    // ---- tcp_rx SYN sideband → tcp_synp ----
    wire        syn_v;
    wire [47:0] syn_smac;
    wire [31:0] syn_sip;
    wire [15:0] syn_sport, syn_dport;
    wire [31:0] syn_seq;
    wire [15:0] syn_wnd;

    // ---- tcp_synp 输出 ----
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

    // ---- CAM 查询 (tcp_rx → tcp_cam) ----
    wire [31:0] cam_q_sip, cam_q_dip;
    wire [15:0] cam_q_sport, cam_q_dport;
    wire        cam_q_hit;
    wire [3:0]  cam_q_id;
    // ---- CAM 读回 (tcp_cam → tcp_tx_frame) ----
    wire [3:0]  cam_rd_id;
    wire [47:0] cam_rd_dmac;
    wire [31:0] cam_rd_sip, cam_rd_dip;
    wire [15:0] cam_rd_sport, cam_rd_dport;

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

    tcp_rx u_tcp_rx (
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

    // ---- CAM: 板上配置口由 synp 独占 (无其它写者, 直连) ----
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

    // ---- TCB: ra 给 rx, rb 给 tx ----
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
    wire        tcb_wr  = sel_tx || sel_rx || synp_upd_wr;
    wire [2:0]  tcb_sel = sel_tx ? tx_upd_sel : (sel_rx ? rx_upd_sel : synp_upd_sel);
    wire [3:0]  tcb_id  = sel_tx ? tx_upd_id  : (sel_rx ? rx_upd_id  : synp_upd_id);
    wire [31:0] tcb_val = sel_tx ? tx_upd_val : (sel_rx ? rx_upd_val : synp_upd_val);
    assign rx_upd_gnt = sel_rx;

    // ---- SYN 应答器 (P4-lite 握手) ----
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
        .cfg_listen     (16'd8080),        // 只应答此本地端口的 SYN
        .cfg_iss        (32'd5999)         // 初始序列号
    );

    // ---- TX ACK 请求二选一: synp (SYN+ACK) 优先 ----
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
        .cfg_src_mac    (48'h000A3501FEC1),  // 00:0A:35:01:FE:C1
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

    mac_tx_64 u_mac_tx (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .s_axis_tdata   (tx_tdata),
        .s_axis_tkeep   (tx_tkeep),
        .s_axis_tvalid  (tx_tvalid),
        .s_axis_tready  (tx_tready),
        .s_axis_tlast   (tx_tlast),
        .gmii_txd       (e_txd),
        .gmii_tx_en     (e_txen),
        .gmii_tx_er     (e_txer),
        .stat_frames    (),
        .stat_abort     (tx_stat_abort)
    );

    // --- LED 观测 (引脚与 wrapper_1g.v 相同; 计数 LSB 直接可观) ---
    assign led_d0 = rx_stat_frames[0];     // RX 帧活动 (每帧翻转)
    assign led_d1 = rx_stat_pass[0];       // TCP 匹配且 FCS 好
    assign led_d2 = eco_stat_echo[0];      // 回发帧计数
    assign led_d3 = eco_stat_drop_crc[0];  // 回卷丢弃 (正常恒灭)

endmodule
