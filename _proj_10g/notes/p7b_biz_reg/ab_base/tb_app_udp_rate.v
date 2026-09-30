`timescale 1ns/1ps
//=============================================================================
// tb_app_udp_rate: app UDP TX 通路**线速**测量 TB (P5f 验收)
//
// 链: app_udp_pattern → udp_tx_cfg (peer 门) → udp_tx_frame (组帧) → mac_tx_64
//     (tx_arb 不参与: 本门只看"无人竞争时 app 通路能跑多快")
//
// 判据: mac_tx 的 GMII 前导沿之间的**拍数** (= 帧周期) 与 1472B 载荷比
//   ⇒ 载荷速率 = 1472*8 / (周期/125MHz) bps。
//   理论口径: 1538 拍/帧 (8 前导 + 1514 内容 + 4 FCS + 12 IFG) ⇒ 957 Mbps 载荷。
//
// TX_GAP 由 `-d TXGAP=<value>` 覆盖 (默认 0), 便于一版 RTL 跑多档。
// 编译 (独立目录 sim/p5e_rate):
//   xvlog tb/tb_app_udp_rate.v rtl/{app_udp_pattern,udp_tx_cfg,udp_tx_frame,
//                                  checksum16,fifo_sync,mac_tx_64,crc32_8b}.v
//   xelab -d TXGAP=16'd0 xil_defaultlib.tb_app_udp_rate -s s -timescale 1ns/1ps
//=============================================================================
// 档位选择: 本版 xvlog 的 -d 只接受**裸宏名** (不能带 =值) ⇒ 用具名档位宏。
`ifdef GAP58000
  `define TXGAP 16'd58000
`elsif GAP5000
  `define TXGAP 16'd5000
`elsif GAP2760
  `define TXGAP 16'd2760
`elsif GAP1380
  `define TXGAP 16'd1380
`else
  `define TXGAP 16'd0
`endif
`ifdef PL512
  `define PAYLEN 12'd512
`elsif PL996
  `define PAYLEN 12'd996
`else
  `define PAYLEN 12'd1472
`endif
`define MAXCYC 8000000

module tb_app_udp_rate;
    reg clk, rst_n;
    always #4 clk = ~clk;                  // 125 MHz @8ns

    reg         i_en;
    reg  [11:0] i_paylen;
    wire [63:0] a_td;  wire [7:0] a_tk;
    wire        a_tv, a_tr, a_tl;
    wire [31:0] a_tx_bytes, a_tx_frames, a_rx_bytes, a_rx_frames, a_rx_null, a_mm;
    wire        a_active, a_done;  wire [3:0] a_led;

    reg         peer_wr;
    reg  [47:0] peer_mac;
    reg  [31:0] peer_ip;

    wire        u_ready;
    wire [63:0] u_td;  wire [7:0] u_tk;
    wire        u_tv, u_tr, u_tl;
    wire [47:0] c_dmac, c_smac;
    wire [31:0] c_dip,  c_sip;
    wire [15:0] c_dport, c_sport;
    wire        c_csen;

    wire [63:0] m_td;  wire [7:0] m_tk;
    wire        m_tv, m_tr, m_tl;
    wire [31:0] utx_frames, utx_bytes, utx_drop;
    wire        utx_busy;

    wire [7:0]  gmii_txd;
    wire        gmii_tx_en, gmii_tx_er;
    wire [31:0] mac_frames, mac_abort;

    // ---- 测量寄存器 (声明必须在 always 之前: xvlog 先声明后用) ----
    reg  prev_en;
    reg  DBG;
    integer cyc, npre, last_pre, acc_wire;
    integer sum_p, sum_w, k, n, i;

    app_udp_pattern #(.TX_BYTES(32'd0), .TX_GAP(`TXGAP)) u_app (
        .clk(clk), .rst_n(rst_n),
        .i_en(i_en), .i_tx_ready(u_ready), .i_paylen(i_paylen),
        .m_tdata(a_td), .m_tkeep(a_tk), .m_tvalid(a_tv),
        .m_tready(a_tr), .m_tlast(a_tl),
        .rx_tdata(64'd0), .rx_tkeep(8'h00), .rx_tvalid(1'b0), .rx_tready(),
        .rx_tlast(1'b0), .rx_sof(1'b0), .rx_len(16'd0),
        .stat_tx_bytes(a_tx_bytes), .stat_tx_frames(a_tx_frames),
        .stat_rx_bytes(a_rx_bytes), .stat_rx_frames(a_rx_frames),
        .stat_rx_null(a_rx_null), .stat_mismatch(a_mm),
        .active(a_active), .done(a_done), .led(a_led)
    );

    udp_tx_cfg u_cfg (
        .clk(clk), .rst_n(rst_n),
        .peer_wr(peer_wr), .peer_mac(peer_mac), .peer_ip(peer_ip),
        .frame_busy(utx_busy),
        .cfg_my_mac(48'h000A3501FEC0), .cfg_my_ip(32'hC0A86402),
        .cfg_my_port(16'h1F91), .cfg_dst_port(16'h1F91), .cfg_csum_en(1'b1),
        .s_axis_tdata(a_td), .s_axis_tkeep(a_tk), .s_axis_tvalid(a_tv),
        .s_axis_tready(a_tr), .s_axis_tlast(a_tl),
        .m_axis_tdata(u_td), .m_axis_tkeep(u_tk), .m_axis_tvalid(u_tv),
        .m_axis_tready(u_tr), .m_axis_tlast(u_tl),
        .o_dst_mac(c_dmac), .o_dst_ip(c_dip), .o_dst_port(c_dport),
        .o_src_mac(c_smac), .o_src_ip(c_sip), .o_src_port(c_sport),
        .o_csum_en(c_csen), .o_ready(u_ready),
        .stat_frames(), .stat_deny()
    );

    udp_tx_frame u_utx (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(u_td), .s_axis_tkeep(u_tk), .s_axis_tvalid(u_tv),
        .s_axis_tready(u_tr), .s_axis_tlast(u_tl),
        .cfg_src_mac(c_smac), .cfg_dst_mac(c_dmac),
        .cfg_src_ip(c_sip),  .cfg_dst_ip(c_dip),
        .cfg_src_port(c_sport), .cfg_dst_port(c_dport), .cfg_csum_en(c_csen),
        .m_axis_tdata(m_td), .m_axis_tkeep(m_tk), .m_axis_tvalid(m_tv),
        .m_axis_tready(m_tr), .m_axis_tlast(m_tl),
        .stat_frames(utx_frames), .stat_bytes(utx_bytes),
        .stat_drop_len(utx_drop), .o_busy(utx_busy)
    );

    mac_tx_64 u_mac (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(m_td), .s_axis_tkeep(m_tk), .s_axis_tvalid(m_tv),
        .s_axis_tready(m_tr), .s_axis_tlast(m_tl),
        .gmii_txd(gmii_txd), .gmii_tx_en(gmii_tx_en), .gmii_tx_er(gmii_tx_er),
        .stat_frames(mac_frames), .stat_abort(mac_abort)
    );

    // ---- 测量: gmii_tx_en 上升沿 = 帧起 (前导首拍); 周期 = 相邻上升沿拍差 ----
    always @(posedge clk) begin
        if (!rst_n) begin
            cyc <= 0; npre <= 0; acc_wire <= 0; last_pre <= 0;
            prev_en <= 1'b0;
        end else begin
            cyc <= cyc + 1;
            prev_en <= gmii_tx_en;
            if (gmii_tx_en) acc_wire <= acc_wire + 1;
            if (gmii_tx_en && !prev_en) begin
                if (npre > 5) begin                      // 跳过前 6 帧热机 (含首帧)
                    sum_p <= sum_p + (cyc - last_pre);   // 周期 (含本帧前导沿)
                    sum_w <= sum_w + acc_wire;           // 上一帧线上字节数
                    k     <= k + 1;
                end
                if (npre < 12 && DBG)
                    $display("  [pre %0d] cyc=%0d d=%0d wire=%0d | app txs=%0d gap=%0d sent=%0d bcnt=%0d wr=%b fifo_full=%b utx_busy=%b",
                             npre, cyc, cyc - last_pre, acc_wire,
                             u_app.txs, u_app.gap_cnt, u_app.seg_sent,
                             u_app.bcnt, u_app.txf_wr, u_app.txf_full, utx_busy);
                last_pre <= cyc;
                acc_wire <= 0;
                npre <= npre + 1;
            end
        end
    end

    initial begin
        clk = 0; rst_n = 0; i_en = 0; i_paylen = `PAYLEN;
        peer_wr = 0; peer_mac = 48'h112233445566; peer_ip = 32'hC0A86401;
        sum_p = 0; sum_w = 0; k = 0; n = 0; DBG = 1'b1;
        repeat (20) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);
        peer_wr = 1; @(posedge clk); peer_wr = 0;     // peer 表写 1 拍
        i_en = 1;
        while (k < 35 && cyc < `MAXCYC) @(posedge clk);
        n = k;
        $display("--- tb_app_udp_rate: TXGAP=%0d paylen=%0d ---", `TXGAP, `PAYLEN);
        $display("  frames on wire      = %0d (period samples %0d)", npre, n);
        if (n > 0) begin
            $display("  mean frame period   = %0d cycles (%0.3f us)",
                     sum_p/n, (sum_p/n) * 8.0 / 1000.0);
            $display("  mean wire len       = %0d B", sum_w/n);
            $display("  PAYLOAD RATE        = %0.1f Mbps",
                     (`PAYLEN * 8.0) / ((sum_p/n) * 8.0e-9) / 1e6);
            $display("  WIRE RATE           = %0.1f Mbps",
                     ((sum_w * 1.0/n) * 8.0) / ((sum_p/n) * 8.0e-9) / 1e6);
        end
        $display("  app tx_frames=%0d bytes=%0d | utx frames=%0d bytes=%0d drop=%0d | mac frames=%0d abort=%0d",
                 a_tx_frames, a_tx_bytes, utx_frames, utx_bytes, utx_drop,
                 mac_frames, mac_abort);
        $display("RATE TB DONE");
        $finish;
    end
endmodule
