`timescale 1ns/1ps
//=============================================================================
// tb_w9probe.v (v2) -- 只读调查: "W9 口径 vs 线上实测 差 8 B/帧" 的中间路径
//-----------------------------------------------------------------------------
// 链路: app_udp_pattern(i_paylen=12'd1472) -> udp_tx_cfg -> udp_tx_frame -> sink
// 定义: -d P7B_10G / -d UDP_TX_OVL 由命令行给 (与 P7B RATE 位流一致)。
// 选项: -testplusarg STALL  => 下游 sink 每 8 拍停 1 拍 (比 app 产能慢),
//                              复现"帧器被下游拖慢 ⇒ app 字 FIFO 饱和"的板级工况。
// 观测 (全部 TB 侧, 不改 RTL):
//   n_pushdec  = app 决定推入的次数      (含被拒)
//   n_actual   = 真落笔 (txf_wr && !txf_full)
//   n_refused  = 被拒写  (u_txf.ovf_pulse = wr && full)  ← 静默丢字
//   n_fiford   = app FIFO 读出字 (m_tvalid && m_tready) = 交给帧器的字
//   n_frmacc   = 帧器接受字  (s_axis_tvalid && s_axis_tready)
//   帧器输出   : 逐帧长度 / ip_tot / udp_len (前 6 帧整字 hex)
//=============================================================================
module tb_w9probe;

    function [3:0] pc8;
        input [7:0] v;
        integer i;
        reg [3:0] c;
        begin
            c = 4'd0;
            for (i = 0; i < 8; i = i + 1) c = c + {3'b0, v[i]};
            pc8 = c;
        end
    endfunction

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    // ---------------- app -> cfg ----------------
    wire [63:0] a_tdata;
    wire [7:0]  a_tkeep;
    wire        a_tvalid, a_tready, a_tlast;
    wire [31:0] a_tx_bytes, a_tx_frames, a_rx_bytes, a_rx_frames, a_rx_null, a_mismatch;
    wire        a_active, a_done;
    wire [3:0]  a_led;
    // ---------------- cfg -> framer ----------------
    wire [63:0] c_tdata;
    wire [7:0]  c_tkeep;
    wire        c_tvalid, c_tready, c_tlast;
    wire [47:0] c_dst_mac, c_src_mac;
    wire [31:0] c_dst_ip, c_src_ip;
    wire [15:0] c_dst_port, c_src_port;
    wire        c_csum_en, c_ready;
    wire [31:0] c_frames, c_deny;
    // ---------------- framer -> sink ----------------
    wire [63:0] f_tdata;
    wire [7:0]  f_tkeep;
    wire        f_tvalid, f_tready, f_tlast;
    wire [31:0] f_frames, f_bytes, f_drop;
    wire        f_busy;

    reg peer_wr = 1'b0;
    reg stall_en = 1'b0;
    reg [7:0] cyc = 8'd0;

    app_udp_pattern #(.TX_BYTES(32'd0), .TX_GAP(16'd0)) u_app (
        .clk(clk), .rst_n(rst_n),
        .i_en(1'b1), .i_tx_ready(c_ready), .i_paylen(12'd1472),
        .m_tdata(a_tdata), .m_tkeep(a_tkeep), .m_tvalid(a_tvalid),
        .m_tready(a_tready), .m_tlast(a_tlast),
        .rx_tdata(64'd0), .rx_tkeep(8'h00), .rx_tvalid(1'b0), .rx_tready(),
        .rx_tlast(1'b0), .rx_sof(1'b0), .rx_len(16'd0),
        .stat_tx_bytes(a_tx_bytes), .stat_tx_frames(a_tx_frames),
        .stat_rx_bytes(a_rx_bytes), .stat_rx_frames(a_rx_frames),
        .stat_rx_null(a_rx_null), .stat_mismatch(a_mismatch),
        .active(a_active), .done(a_done), .led(a_led),
        .ds_idx(), .ds_b1(), .ds_b2(), .ds_bg(), .ds_dup(),
        .ds_got(), .ds_exp(), .ds_prev(), .ds_v(),
        .ds_gw(), .ds_ew(), .ds_oz(), .ds_ol(), .ds_om(), .ds_oh()
    );

    udp_tx_cfg u_cfg (
        .clk(clk), .rst_n(rst_n),
        .peer_wr(peer_wr), .peer_mac(48'h000A3501FEC1), .peer_ip(32'hC0A86403),
        .frame_busy(f_busy),
        .cfg_my_mac(48'h000A3501FEC0), .cfg_my_ip(32'hC0A86402),
        .cfg_my_port(16'd8081), .cfg_dst_port(16'd8081), .cfg_csum_en(1'b1),
        .s_axis_tdata(a_tdata), .s_axis_tkeep(a_tkeep), .s_axis_tvalid(a_tvalid),
        .s_axis_tready(a_tready), .s_axis_tlast(a_tlast),
        .m_axis_tdata(c_tdata), .m_axis_tkeep(c_tkeep), .m_axis_tvalid(c_tvalid),
        .m_axis_tready(c_tready), .m_axis_tlast(c_tlast),
        .o_dst_mac(c_dst_mac), .o_dst_ip(c_dst_ip), .o_dst_port(c_dst_port),
        .o_src_mac(c_src_mac), .o_src_ip(c_src_ip), .o_src_port(c_src_port),
        .o_csum_en(c_csum_en), .o_ready(c_ready),
        .stat_frames(c_frames), .stat_deny(c_deny)
    );

    udp_tx_frame u_frm (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(c_tdata), .s_axis_tkeep(c_tkeep), .s_axis_tvalid(c_tvalid),
        .s_axis_tready(c_tready), .s_axis_tlast(c_tlast),
        .cfg_src_mac(c_src_mac), .cfg_dst_mac(c_dst_mac),
        .cfg_src_ip(c_src_ip), .cfg_dst_ip(c_dst_ip),
        .cfg_src_port(c_src_port), .cfg_dst_port(c_dst_port),
        .cfg_csum_en(c_csum_en),
        .m_axis_tdata(f_tdata), .m_axis_tkeep(f_tkeep), .m_axis_tvalid(f_tvalid),
        .m_axis_tready(f_tready), .m_axis_tlast(f_tlast),
        .stat_frames(f_frames), .stat_bytes(f_bytes), .stat_drop_len(f_drop),
        .o_busy(f_busy)
    );

    // 下游 sink: 默认恒接收; STALL 模式每 8 拍停 1 拍 (慢于 app 产能)
    assign f_tready = !(stall_en && (cyc[2:0] == 3'd0));
    always @(posedge clk) if (rst_n) cyc <= cyc + 8'd1;

    //=========================================================================
    // 探针
    //=========================================================================
    wire app_push_dec   = u_app.push_now || u_app.nul_push
`ifdef P7B_10G
                          || u_app.wide_ok
`endif
                          ;
    wire app_wr_actual  = u_app.txf_wr && !u_app.txf_full;
    wire app_wr_refused = u_app.u_txf.ovf_pulse;
    wire app_fifo_rd    = a_tvalid && a_tready;      // app FIFO 读出 = 交给帧器
    wire frm_accept     = c_tvalid && c_tready;      // 帧器接受 (透明 cfg)

    integer n_pushdec = 0, n_actual = 0, n_refused = 0, n_fiford = 0, n_frmacc = 0;
    integer occ_now = 0, occ_max = 0, n_full_cyc = 0;
    integer ref_in_frame = 0;                 // 本帧内的被拒写数
    integer cyc_no = 0;
    integer refuse_at [0:15];
    integer refuse_n = 0;

    always @(posedge clk) begin
        if (rst_n) begin
            cyc_no <= cyc_no + 1;
            if (app_push_dec)   n_pushdec <= n_pushdec + 1;
            if (app_wr_actual)  n_actual  <= n_actual  + 1;
            if (app_wr_refused) n_refused <= n_refused + 1;
            if (app_fifo_rd)    n_fiford  <= n_fiford  + 1;
            if (frm_accept)     n_frmacc  <= n_frmacc  + 1;
            occ_now <= u_app.u_txf.dbg_wptr - u_app.u_txf.dbg_rptr;
            if ((u_app.u_txf.dbg_wptr - u_app.u_txf.dbg_rptr) > occ_max)
                occ_max <= u_app.u_txf.dbg_wptr - u_app.u_txf.dbg_rptr;
            if (u_app.txf_full) n_full_cyc <= n_full_cyc + 1;
            if (app_wr_refused) begin
                ref_in_frame <= ref_in_frame + 1;
                if (refuse_n < 16) begin
                    refuse_at[refuse_n] = cyc_no;
                    refuse_n = refuse_n + 1;
                end
                $display("W9PROBE REFUSE cyc=%0d seg_sent=%0d seg_len=%0d occ=%0d full=%0d rd=%0d valid=%0d tready=%0d",
                         cyc_no, u_app.seg_sent, u_app.seg_len,
                         u_app.u_txf.dbg_wptr - u_app.u_txf.dbg_rptr,
                         u_app.txf_full, app_fifo_rd, a_tvalid, a_tready);
            end
        end
    end

    // ---- 帧器输出逐帧解码 ----
    integer frm_cnt   = 0;
    integer frm_bytes = 0;
    integer word_i    = 0;
    reg [63:0] cap_w [0:5][0:7];              // 前 6 帧的前 8 个整字
    integer len_min = 100000, len_max = 0;
    integer n1506 = 0, n1510 = 0, n1514 = 0, n1518 = 0, n_other = 0;
    integer ref_first = 0;                    // 首帧内是否出现过被拒写

    always @(posedge clk) begin
        if (rst_n && f_tvalid && f_tready) begin
            frm_bytes <= frm_bytes + pc8(f_tkeep);
            if ((frm_cnt < 6) && (word_i < 8)) cap_w[frm_cnt][word_i] <= f_tdata;
            word_i <= word_i + 1;
            if (f_tlast) begin
                if ((frm_bytes + pc8(f_tkeep)) < len_min) len_min <= frm_bytes + pc8(f_tkeep);
                if ((frm_bytes + pc8(f_tkeep)) > len_max) len_max <= frm_bytes + pc8(f_tkeep);
                case (frm_bytes + pc8(f_tkeep))
                    1506: n1506 <= n1506 + 1;
                    1510: n1510 <= n1510 + 1;
                    1514: n1514 <= n1514 + 1;
                    1518: n1518 <= n1518 + 1;
                    default: n_other <= n_other + 1;
                endcase
                if (frm_cnt < 6)
                    $display("W9PROBE FRAME %0d len=%0d ref_in_frame=%0d",
                             frm_cnt, frm_bytes + pc8(f_tkeep), ref_in_frame);
                frm_cnt <= frm_cnt + 1;
                ref_in_frame <= 0;
                frm_bytes <= 0;
                word_i <= 0;
            end
        end
    end

    //=========================================================================
    integer i, j, k;
    initial begin
        for (i = 0; i < 6; i = i + 1)
            for (j = 0; j < 8; j = j + 1) cap_w[i][j] = 64'd0;
        for (k = 0; k < 16; k = k + 1) refuse_at[k] = -1;
        if ($test$plusargs("STALL")) stall_en = 1'b1;
        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (20) @(posedge clk);
        peer_wr = 1'b1;                        // learn-on-RX 的 peer 表写事件
        @(posedge clk);
        peer_wr = 1'b0;
        repeat (20000) @(posedge clk);
        $display("W9PROBE STALL=%0d", stall_en);
        $display("W9PROBE app: bytes=%0d frames=%0d pushdec=%0d actual=%0d refused=%0d",
                 a_tx_bytes, a_tx_frames, n_pushdec, n_actual, n_refused);
        $display("W9PROBE xfer: fiford=%0d frmacc=%0d  (delta_to_framer=%0d)",
                 n_fiford, n_frmacc, n_actual - n_fiford);
        $display("W9PROBE fifo: occ_max=%0d full_cyc=%0d nfrms=%0d",
                 occ_max, n_full_cyc, a_tx_frames);
        $display("W9PROBE framer: frames=%0d bytes=%0d drop_len=%0d",
                 f_frames, f_bytes, f_drop);
        $display("W9PROBE wire: frames=%0d len_min=%0d len_max=%0d n1506=%0d n1510=%0d n1514=%0d n1518=%0d nother=%0d",
                 frm_cnt, len_min, len_max, n1506, n1510, n1514, n1518, n_other);
        for (i = 0; i < 6; i = i + 1)
            $display("W9PROBE FRAME %0d w0=%h w1=%h w2=%h w4=%h",
                     i, cap_w[i][0], cap_w[i][1], cap_w[i][2], cap_w[i][4]);
        $display("W9PROBE END");
        $finish;
    end

endmodule
