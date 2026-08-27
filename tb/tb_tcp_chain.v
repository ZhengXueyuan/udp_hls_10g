`timescale 1ns/1ps
// #48 TCP fast path 全链 TB: GMII -> mac_rx_64 -> tcp_rx -> (ack_req) -> tcp_tx_frame -> mac_tx_64 -> GMII。
// tcp_rx 载荷 m_axis 悬空 (tready=1, 不环回); app 数据由 TB 脚本直接驱动 tcp_tx_frame (presenting)。
// tcp_synp 接 tcp_rx SYN sideband: conn0 由三次握手建立 (CAM0/TCB0 不预写), SYN+ACK 经
// ACK 请求二选一进 tcp_tx_frame (ack_syn=1)。CAM 配置口二选一: TB 配置阶段优先, 其次 synp。
// TCB 更新仲裁 (组合, 本 TB 顶层): tx > rx > cfg 级 (TB 配置 | synp.upd); rx.upd_gnt = sel_rx。
// CAM 外置: tcp_rx.cam_q_* -> tcp_cam.q_*; tcp_cam.rd_* -> tcp_tx_frame.cam_rd_*。
// 配置阶段 (前 40 拍, cphase): CAM 条目 1 (拍 2) + TCB 条目 1 x 6 字段 (拍 6..11, cfg_tcb.memh)。
// RX 激励: stim_data/dv/er.memh (时钟化非阻塞, 同 tb_tcp_rx); 字节 j 在拍 41+j 上线 (k 计数)。
// TX app 脚本: txp_ty (0=锚点等待 k>=stim_n, 1=载荷词) + txp_data/keep/last/gap/id。
// 捕获 (resp_tcp_chain.memh): 每拍 "%02h %d" (gmii_txd, tx_en) + 事件行
//   FEND k ferr / ACK k id val (含 synp 的 SYN+ACK 请求) / SYNP k拍锁存的对端握手字段 /
//   TUPD k sel id val (实际落 TCB 的写, 含 synp cfg 级) / COLL k sel (tx 与 rx 同拍争用)。
// 末尾 STATS7 (tcp_rx 7 统计) + STATS_TX (frames bytes ack ackdrop) + CAMF (CAM 条目 0)
// + TCBF (conn0/1 全 6 字段)。
module tb_tcp_chain;

    reg        clk, rst_n;
    reg [7:0]  rx_d;
    reg        rx_dv, rx_er;
    reg [7:0]  stim_d [0:65535];
    reg [7:0]  stim_v [0:65535];
    reg [7:0]  stim_e [0:65535];
    integer    nstim;
    reg [16:0] i;
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
    // app 脚本
    reg [7:0]  ap_ty [0:8191];
    reg [63:0] ap_d  [0:8191];
    reg [7:0]  ap_k  [0:8191];
    reg        ap_l  [0:8191];
    reg [31:0] ap_n  [0:8191];
    reg [3:0]  ap_id [0:8191];
    integer    nsapp;
    reg [12:0] si;
    reg        tvalid, tlast, presenting;
    reg [63:0] tdata;
    reg [7:0]  tkeep;
    reg [3:0]  tid;

    // mac_rx -> tcp_rx
    wire [63:0] s_tdata;
    wire [7:0]  s_tkeep;
    wire        s_tvalid, s_tready, s_tlast, s_tuser, s_tcrs, s_terr;
    // tcp_rx 载荷口 (悬空)
    wire [63:0] m_tdata;
    wire [7:0]  m_tkeep;
    wire        m_tvalid, m_tlast;
    wire [1:0]  m_tuser;
    wire        fend, ferr;
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
    // tcp_tx_frame
    wire        tready;
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
    wire [31:0] cam_rd_dip;
    wire [15:0] cam_rd_sport, cam_rd_dport;
    wire [63:0] x_tdata;
    wire [7:0]  x_tkeep;
    wire        x_tvalid, x_tready, x_tlast;
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

    // ---- CAM 配置口二选一: TB 配置阶段优先, 其次 synp (握手静默期无冲突) ----
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

    tcp_rx u_rx (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep), .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_tready), .s_axis_tlast(s_tlast), .s_axis_tuser(s_tuser),
        .s_axis_tcrs(s_tcrs), .s_axis_terr(s_terr),
        .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep), .m_axis_tvalid(m_tvalid),
        .m_axis_tready(1'b1), .m_axis_tlast(m_tlast), .m_axis_tuser(m_tuser),
        .fend(fend), .ferr(ferr),
        .meta_valid(), .meta_src_ip(), .meta_src_port(),
        .meta_len(), .meta_conn_id(), .meta_seq(),
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

    tcp_cam u_cam (
        .clk(clk), .rst_n(rst_n),
        .cfg_wr(cam_cfg_wr), .cfg_addr(cam_cfg_addr),
        .cfg_sip(cam_cfg_sip), .cfg_dip(cam_cfg_dip),
        .cfg_sport(cam_cfg_sport), .cfg_dport(cam_cfg_dport), .cfg_dmac(cam_cfg_dmac),
        .q_sip(cam_q_sip), .q_dip(cam_q_dip),
        .q_sport(cam_q_sport), .q_dport(cam_q_dport),
        .q_id(cam_q_id), .q_hit(cam_q_hit),
        .rd_id(cam_rd_id), .rd_dmac(cam_rd_dmac), .rd_dip(cam_rd_dip),
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
        .s_axis_tdata(tdata), .s_axis_tkeep(tkeep),
        .s_axis_tvalid(tvalid), .s_axis_tready(tready), .s_axis_tlast(tlast),
        .s_axis_tid(tid),
        .ack_req(tx_ack_req), .ack_id(tx_ack_id), .ack_val(tx_ack_val),
        .ack_syn(tx_ack_syn),
        .rb_id(rb_id), .rb_snd_nxt(rb_snd_nxt), .rb_rcv_nxt(rb_rcv_nxt),
        .rb_rcv_wnd(rb_rcv_wnd),
        .upd_wr(tx_upd_wr), .upd_id(tx_upd_id), .upd_sel(tx_upd_sel), .upd_val(tx_upd_val),
        .cam_rd_id(cam_rd_id), .cam_rd_dmac(cam_rd_dmac), .cam_rd_dip(cam_rd_dip),
        .cam_rd_sport(cam_rd_sport), .cam_rd_dport(cam_rd_dport),
        .cfg_src_mac(48'h000A3501FEC1), .cfg_src_ip(32'hC0A86402),
        .m_axis_tdata(x_tdata), .m_axis_tkeep(x_tkeep),
        .m_axis_tvalid(x_tvalid), .m_axis_tready(x_tready), .m_axis_tlast(x_tlast),
        .stat_frames(tx_stat_frames), .stat_bytes(tx_stat_bytes),
        .stat_ack(tx_stat_ack), .stat_ack_drop(tx_stat_ack_drop)
    );

    mac_tx_64 u_mactx (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(x_tdata), .s_axis_tkeep(x_tkeep),
        .s_axis_tvalid(x_tvalid), .s_axis_tready(x_tready), .s_axis_tlast(x_tlast),
        .gmii_txd(gmii_txd), .gmii_tx_en(gmii_tx_en), .gmii_tx_er(),
        .stat_frames(), .stat_abort()
    );

    always #4 clk = ~clk;     // 125 MHz

    // ---- 时钟化激励驱动 + 配置阶段 + app presenting 驱动 (锚点绝对 k) ----
    always @(posedge clk) begin
        if (!rst_n) begin
            i <= 0; k <= 32'hFFFFFFFF; rx_d <= 8'h07; rx_dv <= 0; rx_er <= 0; done <= 0;
            cphase <= 0;
            cfg_wr <= 0; cfg_addr <= 0; cfg_sip <= 0; cfg_dip <= 0;
            cfg_sport <= 0; cfg_dport <= 0; cfg_dmac <= 0;
            cfg_upd_wr <= 0; cfg_upd_id <= 0; cfg_upd_sel <= 0; cfg_upd_val <= 0;
            si <= 0; tvalid <= 0; tdata <= 0; tkeep <= 0; tlast <= 0; tid <= 0;
            presenting <= 0;
        end else begin
            k <= k + 1;
            if (cphase < 40) begin
                rx_dv <= 0; rx_er <= 0; tvalid <= 0; presenting <= 0;
                // CAM 1 条 (拍 2, 条目 1; 条目 0 归 synp 握手建立)
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
                // TCB 条目 1 x 6 字段 (拍 6..11, cfg_tcb.memh; 条目 0 归 synp)
                cfg_upd_wr <= (cphase >= 6 && cphase <= 11);
                cfg_upd_id  <= 4'd1;
                cfg_upd_sel <= (cphase - 6) % 6;
                cfg_upd_val <= tcbc[cphase - 6];
                cphase <= cphase + 1;
            end else begin
                cfg_wr <= 0; cfg_upd_wr <= 0;
                // RX 字节流
                if (i < nstim) begin
                    rx_d  <= stim_d[i];
                    rx_dv <= stim_v[i][0];
                    rx_er <= stim_e[i][0];
                    i <= i + 1;
                end else begin
                    rx_dv <= 0; rx_er <= 0;
                end
                // app presenting 驱动 (ty=0: 锚点等待 k>=ap_n; ty=1: 载荷词)
                if (presenting) begin
                    if (tvalid && tready) begin
                        presenting <= 0; tvalid <= 0;   // 接受拍撤 valid 一拍再装下一词
                    end
                end else if (si < nsapp) begin
                    if (ap_ty[si] == 8'd1) begin
                        tdata <= ap_d[si]; tkeep <= ap_k[si]; tlast <= ap_l[si];
                        tid <= ap_id[si];
                        presenting <= 1; tvalid <= 1; si <= si + 1;
                    end else begin
                        if (k >= ap_n[si]) si <= si + 1;
                    end
                end
                if (i >= nstim && si >= nsapp && !presenting) done <= 1;
            end
        end
    end

    initial begin
        clk = 0; rst_n = 0;
        $readmemh("stim_data.memh", stim_d);
        $readmemh("stim_dv.memh",   stim_v);
        $readmemh("stim_er.memh",   stim_e);
        $readmemh("cfg_tcb.memh",   tcbc);
        $readmemh("txp_ty.memh",   ap_ty);
        $readmemh("txp_data.memh", ap_d);
        $readmemh("txp_keep.memh", ap_k);
        $readmemh("txp_last.memh", ap_l);
        $readmemh("txp_gap.memh",  ap_n);
        $readmemh("txp_id.memh",   ap_id);
        nstim = 0;
        while (nstim < 65536 && stim_d[nstim] !== 8'hxx) nstim = nstim + 1;
        nsapp = 0;
        while (nsapp < 8192 && ap_ty[nsapp] !== 8'hxx) nsapp = nsapp + 1;
        fd = $fopen("resp_tcp_chain.memh", "w");
        #200; rst_n = 1;
        wait (done == 1);
        repeat (3000) @(posedge clk);
        $fwrite(fd, "STATS7 %0d %0d %0d %0d %0d %0d %0d\n",
                rx_stat_pass, rx_stat_nonmatch, rx_stat_ipcsum, rx_stat_crc,
                rx_stat_seq, rx_stat_ack, rx_stat_bytes);
        $fwrite(fd, "STATS_TX %0d %0d %0d %0d\n",
                tx_stat_frames, tx_stat_bytes, tx_stat_ack, tx_stat_ack_drop);
        $fwrite(fd, "CAMF %08h %08h %04h %04h %012h\n",
                u_cam.sip_r[0], u_cam.dip_r[0], u_cam.sport_r[0],
                u_cam.dport_r[0], u_cam.dmac_r[0]);
        $fwrite(fd, "TCBF %08h %08h %08h %04h %04h %0d %08h %08h %08h %04h %04h %0d\n",
                u_tcb.rcv_nxt_r[0], u_tcb.snd_nxt_r[0], u_tcb.snd_una_r[0],
                u_tcb.rcv_wnd_r[0], u_tcb.snd_wnd_r[0], u_tcb.state_r[0],
                u_tcb.rcv_nxt_r[1], u_tcb.snd_nxt_r[1], u_tcb.snd_una_r[1],
                u_tcb.rcv_wnd_r[1], u_tcb.snd_wnd_r[1], u_tcb.state_r[1]);
        $fclose(fd);
        $display("DONE rx(pass=%0d nm=%0d ip=%0d crc=%0d seq=%0d ack=%0d by=%0d) tx(fr=%0d by=%0d ack=%0d drop=%0d)",
                 rx_stat_pass, rx_stat_nonmatch, rx_stat_ipcsum, rx_stat_crc,
                 rx_stat_seq, rx_stat_ack, rx_stat_bytes,
                 tx_stat_frames, tx_stat_bytes, tx_stat_ack, tx_stat_ack_drop);
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
            if (tx_upd_wr)
                $fwrite(fd, "TUPD %0d %0d %0d %08h\n", k, tx_upd_sel, tx_upd_id, tx_upd_val);
            else if (sel_rx)
                $fwrite(fd, "TUPD %0d %0d %0d %08h\n", k, rx_upd_sel, rx_upd_id, rx_upd_val);
            else if (synp_upd_wr)
                $fwrite(fd, "TUPD %0d %0d %0d %08h\n", k, synp_upd_sel, synp_upd_id, synp_upd_val);
            if (tx_upd_wr && rx_upd_wr)
                $fwrite(fd, "COLL %0d %0d\n", k, rx_upd_sel);
        end
    end
endmodule
