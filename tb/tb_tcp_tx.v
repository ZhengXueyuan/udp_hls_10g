`timescale 1ns/1ps
// tcp_tx_frame 全链 TB: 载荷 AXIS (presenting 模式) + ack_req 脉冲 -> tcp_tx_frame -> mac_tx_64 -> GMII。
// stim memh: txp_ty (0=gap, 1=data word, 2=ack_req 脉冲) + txp_data/keep/last/gap/id/av。
//   data word: tid=stim_id (conn id); ack 脉冲: id/val = stim_id/stim_av (单拍)。
// 配置阶段 (复位后前 40 拍, cphase 风格, 时钟化非阻塞):
//   CAM 2 条 (拍 2..3) + TCB 2 条 x 6 字段 (拍 6..17, sel 0..5 顺序同 tb_tcp_rx)。
// 捕获: 每拍 gmii_tx_en/txd -> resp_tcp_tx.memh ("%b %02h"); 末尾
//   STATS frames bytes ack ackdrop + TCBF snd_nxt[0] snd_nxt[1] (%08h)。
// Python 侧 (tools/gen_stim_tcp_tx.py) 解码帧验证头/校验和/载荷/FCS/统计/TCB 终态。
module tb_tcp_tx;

    reg        clk, rst_n;
    reg [7:0]  stim_ty [0:4095];
    reg [63:0] stim_d  [0:4095];
    reg [7:0]  stim_k  [0:4095];
    reg        stim_l  [0:4095];
    reg [15:0] stim_n  [0:4095];
    reg [3:0]  stim_id [0:4095];
    reg [31:0] stim_av [0:4095];
    integer    nstim;
    reg [12:0] si;
    reg [15:0] gap_cnt;
    reg        tvalid, tlast, presenting;
    reg [63:0] tdata;
    reg [7:0]  tkeep;
    reg [3:0]  tid;
    reg        ack_req;
    reg [3:0]  ack_id;
    reg [31:0] ack_val;
    // 配置阶段
    reg [5:0]  cphase;
    reg [31:0] tcbc [0:63];
    reg        cfg_wr;
    reg [3:0]  cfg_addr;
    reg [31:0] cfg_sip, cfg_dip;
    reg [15:0] cfg_sport, cfg_dport;
    reg [47:0] cfg_dmac;
    reg        cfg_upd_wr;
    reg [3:0]  cfg_upd_id;
    reg [2:0]  cfg_upd_sel;
    reg [31:0] cfg_upd_val;

    wire        tready;
    wire [3:0]  rb_id;
    wire [31:0] rb_rcv_nxt, rb_snd_nxt, rb_snd_una;
    wire [15:0] rb_rcv_wnd, rb_snd_wnd;
    wire [3:0]  rb_state;
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
    wire        m_tvalid, m_tready, m_tlast;
    wire [7:0]  gmii_txd;
    wire        gmii_tx_en;
    wire [31:0] stat_frames, stat_bytes, stat_ack, stat_ack_drop;
    integer     fd;

    // TCB 更新 mux: 慢路径配置优先 (配置阶段与 DUT 更新不会同拍)
    wire        tcb_wr  = cfg_upd_wr || dut_upd_wr;
    wire [2:0]  tcb_sel = cfg_upd_wr ? cfg_upd_sel : dut_upd_sel;
    wire [3:0]  tcb_id  = cfg_upd_wr ? cfg_upd_id  : dut_upd_id;
    wire [31:0] tcb_val = cfg_upd_wr ? cfg_upd_val : dut_upd_val;

    tcp_tx_frame dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(tdata), .s_axis_tkeep(tkeep),
        .s_axis_tvalid(tvalid), .s_axis_tready(tready), .s_axis_tlast(tlast),
        .s_axis_tid(tid),
        .ack_req(ack_req), .ack_id(ack_id), .ack_val(ack_val), .ack_syn(1'b0),
        .rb_id(rb_id), .rb_snd_nxt(rb_snd_nxt), .rb_rcv_nxt(rb_rcv_nxt),
        .rb_rcv_wnd(rb_rcv_wnd), .rb_snd_una(rb_snd_una), .rb_snd_wnd(rb_snd_wnd),
        .upd_wr(dut_upd_wr), .upd_id(dut_upd_id), .upd_sel(dut_upd_sel), .upd_val(dut_upd_val),
        .cam_rd_id(cam_rd_id), .cam_rd_dmac(cam_rd_dmac), .cam_rd_sip(cam_rd_sip),
        .cam_rd_sport(cam_rd_sport), .cam_rd_dport(cam_rd_dport),
        .cfg_src_mac(48'h000A3501FEC1), .cfg_src_ip(32'hC0A86402),
        .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep),
        .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready), .m_axis_tlast(m_tlast),
        .stat_frames(stat_frames), .stat_bytes(stat_bytes),
        .stat_ack(stat_ack), .stat_ack_drop(stat_ack_drop), .stat_eend()
    );

    tcb u_tcb (
        .clk(clk), .rst_n(rst_n),
        .ra_id(4'd0), .ra_rcv_nxt(), .ra_snd_nxt(), .ra_snd_una(),
        .ra_rcv_wnd(), .ra_snd_wnd(), .ra_state(), .ra_wscale(),
        .rb_id(rb_id), .rb_rcv_nxt(rb_rcv_nxt), .rb_snd_nxt(rb_snd_nxt),
        .rb_snd_una(rb_snd_una), .rb_rcv_wnd(rb_rcv_wnd), .rb_snd_wnd(rb_snd_wnd),
        .rb_state(rb_state),
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

    mac_tx_64 u_tx (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(m_tdata), .s_axis_tkeep(m_tkeep),
        .s_axis_tvalid(m_tvalid), .s_axis_tready(m_tready), .s_axis_tlast(m_tlast),
        .gmii_txd(gmii_txd), .gmii_tx_en(gmii_tx_en), .gmii_tx_er(),
        .stat_frames(), .stat_abort()
    );

    always #4 clk = ~clk;     // 125 MHz

    // ---- 时钟化激励驱动 + 配置阶段 (非阻塞, 无 TB/DUT 竞争) ----
    always @(posedge clk) begin
        if (!rst_n) begin
            si <= 0; tvalid <= 0; tdata <= 0; tkeep <= 0; tlast <= 0; tid <= 0;
            gap_cnt <= 0; presenting <= 0;
            ack_req <= 0; ack_id <= 0; ack_val <= 0;
            cphase <= 0;
            cfg_wr <= 0; cfg_addr <= 0; cfg_sip <= 0; cfg_dip <= 0;
            cfg_sport <= 0; cfg_dport <= 0; cfg_dmac <= 0;
            cfg_upd_wr <= 0; cfg_upd_id <= 0; cfg_upd_sel <= 0; cfg_upd_val <= 0;
        end else begin
            if (cphase < 40) begin
                tvalid <= 0; presenting <= 0; ack_req <= 0;
                // CAM 2 条 (拍 2..3)
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
                // TCB 2 条 x 6 字段 (拍 6..17, 条目 e 字段 f: tcbc[e*6+f])
                cfg_upd_wr <= (cphase >= 6 && cphase <= 17);
                cfg_upd_id  <= (cphase - 6) / 6;
                cfg_upd_sel <= (cphase - 6) % 6;
                cfg_upd_val <= tcbc[cphase - 6];
                cphase <= cphase + 1;
            end else begin
                cfg_wr <= 0; cfg_upd_wr <= 0;
                // presenting 模式 (抄 tb_udp_tx: 接受拍撤 valid 一拍再装下一词)
                if (gap_cnt > 0) begin
                    presenting <= 0; tvalid <= 0; ack_req <= 0; gap_cnt <= gap_cnt - 1;
                end else if (!presenting) begin
                    if (si < nstim) begin
                        if (stim_ty[si] == 8'd1) begin
                            tdata <= stim_d[si]; tkeep <= stim_k[si]; tlast <= stim_l[si];
                            tid <= stim_id[si];
                            presenting <= 1; tvalid <= 1; ack_req <= 0; si <= si + 1;
                        end else if (stim_ty[si] == 8'd2) begin
                            // ack_req 单拍脉冲 (背靠背 ack = 连续拍)
                            ack_req <= 1; ack_id <= stim_id[si]; ack_val <= stim_av[si];
                            tvalid <= 0; si <= si + 1;
                        end else begin
                            tvalid <= 0; ack_req <= 0; gap_cnt <= stim_n[si] - 1; si <= si + 1;
                        end
                    end else begin
                        tvalid <= 0; ack_req <= 0;
                    end
                end else begin
                    ack_req <= 0;
                    if (tvalid && tready) begin
                        presenting <= 0; tvalid <= 0;      // 空一拍再装下一词
                    end
                end
            end
        end
    end

    initial begin
        clk = 0; rst_n = 0;
        // TCB0: rcv_nxt=1000 snd_nxt=6000 snd_una=5000 rcv_wnd=0x2000 snd_wnd=0x2000 state=1
        tcbc[0] = 32'd1000; tcbc[1] = 32'd6000; tcbc[2]  = 32'd5000;
        tcbc[3] = 32'h2000; tcbc[4] = 32'h2000; tcbc[5]  = 32'd1;
        // TCB1: rcv_nxt=77 snd_nxt=900 snd_una=900 rcv_wnd=0x1800 snd_wnd=0x2000 state=1
        tcbc[6] = 32'd77;   tcbc[7] = 32'd900;  tcbc[8]  = 32'd900;
        tcbc[9] = 32'h1800; tcbc[10] = 32'h2000; tcbc[11] = 32'd1;
        $readmemh("txp_ty.memh",   stim_ty);
        $readmemh("txp_data.memh", stim_d);
        $readmemh("txp_keep.memh", stim_k);
        $readmemh("txp_last.memh", stim_l);
        $readmemh("txp_gap.memh",  stim_n);
        $readmemh("txp_id.memh",   stim_id);
        $readmemh("txp_av.memh",   stim_av);
        nstim = 0;
        while (nstim < 4096 && stim_ty[nstim] !== 8'hxx) nstim = nstim + 1;
        fd = $fopen("resp_tcp_tx.memh", "w");
        #200; rst_n = 1;
        repeat (60000) @(posedge clk);
        $fwrite(fd, "STATS %0d %0d %0d %0d\n",
                stat_frames, stat_bytes, stat_ack, stat_ack_drop);
        $fwrite(fd, "TCBF %08h %08h\n", u_tcb.snd_nxt_r[0], u_tcb.snd_nxt_r[1]);
        $fclose(fd);
        $display("DONE frames=%0d bytes=%0d ack=%0d ackdrop=%0d",
                 stat_frames, stat_bytes, stat_ack, stat_ack_drop);
        $finish;
    end

    // ---- GMII 字节捕获 ----
    always @(posedge clk)
        if (rst_n) $fwrite(fd, "%b %02h\n", gmii_tx_en, gmii_txd);
endmodule
