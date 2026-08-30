`timescale 1ns/1ps
// tcp_rx 全链 TB: mac_rx_64 -> tcp_rx + tcb。
// GMII 字节流时钟化非阻塞驱动 (stim_data/dv/er.memh, 与 tb_udp_rx 同约定);
// 配置阶段 (前 40 拍): CAM 3 条 + TCB 2 条 × 6 字段 (cfg_tcb.memh 拍序写入, 慢路径口)。
// 捕获: m_axis 接受词 + META + FEND + ACK 请求 + 末尾 STATS/STATM/TCBF (TCB 终态)。
// 背压 (plusarg): 无 / STALL (3 高 1 低) / HARD (字节窗 [hw[0], hw[1]) 硬停)。
module tb_tcp_rx;

    reg        clk, rst_n;
    reg [7:0]  rx_d;
    reg        rx_dv, rx_er;
    reg [7:0]  stim_d [0:65535];
    reg [7:0]  stim_v [0:65535];
    reg [7:0]  stim_e [0:65535];
    integer    nstim;
    reg [16:0] i;
    reg [31:0] sc;
    reg        tready, hardstall;
    reg        done;
    reg [31:0] hw [0:1];
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

    wire [63:0] s_tdata;
    wire [7:0]  s_tkeep;
    wire        s_tvalid, s_tlast, s_tuser, s_tcrs, s_terr;

    wire [63:0] m_tdata;
    wire [7:0]  m_tkeep;
    wire        m_tvalid, m_tlast;
    wire [1:0]  m_tuser;
    wire        meta_valid;
    wire        fend, ferr;
    wire [31:0] meta_src_ip;
    wire [15:0] meta_src_port, meta_len;
    wire [3:0]  meta_conn_id;
    wire [31:0] meta_seq;
    wire [3:0]  ra_id;
    wire [31:0] ra_rcv_nxt, ra_snd_nxt, ra_snd_una;
    wire [15:0] ra_rcv_wnd;
    wire [3:0]  ra_state;
    wire [3:0]  ra_wscale;
    wire        ack_req;
    wire [3:0]  ack_id;
    wire [31:0] ack_val;
    wire [31:0] stat_pass, stat_nonmatch, stat_ipcsum, stat_crc, stat_seq, stat_ack, stat_bytes;
    wire [31:0] m_frames, m_crc_err, m_drop, m_bytes;
    wire        u_rx_upd_wr;
    wire [3:0]  u_rx_upd_id;
    wire [2:0]  u_rx_upd_sel;
    wire [31:0] u_rx_upd_val;
    wire        s_ready;
    wire [31:0] cam_q_sip, cam_q_dip;
    wire [15:0] cam_q_sport, cam_q_dport;
    wire        cam_q_hit;
    wire [3:0]  cam_q_id;
    // TCB 更新 mux: 慢路径配置优先
    wire [2:0]  tcb_sel = cfg_upd_wr ? cfg_upd_sel : u_rx_upd_sel;
    wire [3:0]  tcb_id  = cfg_upd_wr ? cfg_upd_id  : u_rx_upd_id;
    wire [31:0] tcb_val = cfg_upd_wr ? cfg_upd_val : u_rx_upd_val;
    wire        tcb_wr  = cfg_upd_wr || u_rx_upd_wr;

    integer     fd;

    mac_rx_64 u_mac (
        .clk(clk), .rst_n(rst_n),
        .gmii_rxd(rx_d), .gmii_rx_dv(rx_dv), .gmii_rx_er(rx_er),
        .m_axis_tdata(s_tdata), .m_axis_tkeep(s_tkeep), .m_axis_tvalid(s_tvalid),
        .m_axis_tready(s_ready), .m_axis_tlast(s_tlast), .m_axis_tuser(s_tuser),
        .m_axis_terr(s_terr), .m_axis_tcrs(s_tcrs),
        .stat_frames(m_frames), .stat_crc_err(m_crc_err),
        .stat_drop(m_drop), .stat_bytes(m_bytes)
    );

    tcp_rx u_rx (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep), .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_ready), .s_axis_tlast(s_tlast), .s_axis_tuser(s_tuser),
        .s_axis_tcrs(s_tcrs), .s_axis_terr(s_terr),
        .cfg_suppress_data_ack(1'b0),   // 单元 TB 覆盖未抑制路径
        .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep), .m_axis_tvalid(m_tvalid),
        .m_axis_tready(tready), .m_axis_tlast(m_tlast), .m_axis_tuser(m_tuser),
        .fend(fend), .ferr(ferr),
        .meta_valid(meta_valid), .meta_src_ip(meta_src_ip), .meta_src_port(meta_src_port),
        .meta_len(meta_len), .meta_conn_id(meta_conn_id), .meta_seq(meta_seq),
        .ra_id(ra_id),
        .ra_rcv_nxt(ra_rcv_nxt), .ra_snd_nxt(ra_snd_nxt), .ra_snd_una(ra_snd_una),
        .ra_rcv_wnd(ra_rcv_wnd), .ra_state(ra_state), .ra_wscale(ra_wscale),
        .upd_wr(u_rx_upd_wr), .upd_id(u_rx_upd_id), .upd_sel(u_rx_upd_sel), .upd_val(u_rx_upd_val),
        .upd_gnt(!cfg_upd_wr),
        .ack_req(ack_req), .ack_id(ack_id), .ack_val(ack_val),
        .cam_q_sip(cam_q_sip), .cam_q_dip(cam_q_dip),
        .cam_q_sport(cam_q_sport), .cam_q_dport(cam_q_dport),
        .cam_q_hit(cam_q_hit), .cam_q_id(cam_q_id),
        .stat_pass(stat_pass), .stat_drop_nonmatch(stat_nonmatch),
        .stat_drop_ipcsum(stat_ipcsum), .stat_drop_crc(stat_crc),
        .stat_drop_seq(stat_seq), .stat_ack(stat_ack), .stat_bytes(stat_bytes)
    );

    tcp_cam u_cam (
        .clk(clk), .rst_n(rst_n),
        .cfg_wr(cfg_wr), .cfg_addr(cfg_addr),
        .cfg_sip(cfg_sip), .cfg_dip(cfg_dip),
        .cfg_sport(cfg_sport), .cfg_dport(cfg_dport), .cfg_dmac(cfg_dmac),
        .q_sip(cam_q_sip), .q_dip(cam_q_dip),
        .q_sport(cam_q_sport), .q_dport(cam_q_dport),
        .q_id(cam_q_id), .q_hit(cam_q_hit),
        .rd_id(4'd0), .rd_dmac(), .rd_dip(), .rd_sport(), .rd_dport()
    );

    tcb u_tcb (
        .clk(clk), .rst_n(rst_n),
        .ra_id(ra_id), .ra_rcv_nxt(ra_rcv_nxt), .ra_snd_nxt(ra_snd_nxt),
        .ra_snd_una(ra_snd_una), .ra_rcv_wnd(ra_rcv_wnd), .ra_snd_wnd(),
        .ra_state(ra_state), .ra_wscale(ra_wscale),
        .rb_id(4'd0), .rb_rcv_nxt(), .rb_snd_nxt(), .rb_snd_una(),
        .rb_rcv_wnd(), .rb_snd_wnd(), .rb_state(),
        .upd_wr(tcb_wr), .upd_id(tcb_id), .upd_sel(tcb_sel), .upd_val(tcb_val)
    );

    always #4 clk = ~clk;     // 125 MHz

    // ---- 时钟化激励驱动 + 配置阶段 (非阻塞, 无 TB/DUT 竞争) ----
    always @(posedge clk) begin
        if (!rst_n) begin
            i <= 0; rx_d <= 8'h07; rx_dv <= 0; rx_er <= 0;
            tready <= 1; sc <= 0; done <= 0; cphase <= 0;
            cfg_wr <= 0; cfg_addr <= 0; cfg_sip <= 0; cfg_dip <= 0;
            cfg_sport <= 0; cfg_dport <= 0;
            cfg_dmac <= 48'h112233445566;
            cfg_upd_wr <= 0; cfg_upd_id <= 0; cfg_upd_sel <= 0; cfg_upd_val <= 0;
        end else begin
            if (cphase < 40) begin
                rx_dv <= 0; rx_er <= 0;
                // CAM 3 条 (拍 2..4)
                cfg_wr <= (cphase >= 2 && cphase <= 4);
                cfg_addr <= cphase - 2;
                case (cphase)
                    6'd2: begin
                        cfg_sip <= 32'h0A000001; cfg_dip <= 32'hC0A86402;
                        cfg_sport <= 16'h3039; cfg_dport <= 16'h1F90;
                    end
                    6'd3: begin
                        cfg_sip <= 32'h0A000001; cfg_dip <= 32'hC0A86402;
                        cfg_sport <= 16'hD431; cfg_dport <= 16'h1F91;
                    end
                    6'd4: begin
                        cfg_sip <= 32'h0A00000F; cfg_dip <= 32'hC0A86402;
                        cfg_sport <= 16'h5000; cfg_dport <= 16'h1F92;
                    end
                    default: ;
                endcase
                // TCB 2 条 × 6 字段 (拍 6..17, 条目 e 字段 f: tcbc[e*6+f])
                cfg_upd_wr <= (cphase >= 6 && cphase <= 17);
                cfg_upd_id  <= (cphase - 6) / 6;
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
                    rx_dv <= 0; rx_er <= 0; done <= 1;
                end
            end
            if (hardstall && i >= hw[0] && i < hw[1]) tready <= 0;
            else if ($test$plusargs("STALL")) begin
                tready <= (sc % 4 == 0) ? 1'b0 : 1'b1;   // 3 高 1 低
                sc <= sc + 1;
            end
            else tready <= 1;
        end
    end

    initial begin
        clk = 0; rst_n = 0; hardstall = 0;
        $readmemh("stim_data.memh", stim_d);
        $readmemh("stim_dv.memh",   stim_v);
        $readmemh("stim_er.memh",   stim_e);
        $readmemh("cfg_tcb.memh",   tcbc);
        nstim = 0;
        while (nstim < 65536 && stim_d[nstim] !== 8'hxx) nstim = nstim + 1;
        if ($test$plusargs("HARD")) begin
            hardstall = 1;
            $readmemh("hardwin.memh", hw);
        end
        if ($test$plusargs("STALL")) fd = $fopen("resp_tcp_rx_stall.memh", "w");
        else if ($test$plusargs("HARD")) fd = $fopen("resp_tcp_rx_hard.memh", "w");
        else fd = $fopen("resp_tcp_rx.memh", "w");
        #200; rst_n = 1;
        wait (done == 1);
        repeat (800) @(posedge clk);
        $fwrite(fd, "STATS %0d %0d %0d %0d %0d %0d %0d\n",
                stat_pass, stat_nonmatch, stat_ipcsum, stat_crc, stat_seq, stat_ack, stat_bytes);
        $fwrite(fd, "STATM %0d %0d %0d %0d\n",
                m_frames, m_crc_err, m_drop, m_bytes);
        $fwrite(fd, "TCBF %08h %08h %08h %04h %04h %0d %08h %08h %08h %04h %04h %0d\n",
                u_tcb.rcv_nxt_r[0], u_tcb.snd_nxt_r[0], u_tcb.snd_una_r[0],
                u_tcb.rcv_wnd_r[0], u_tcb.snd_wnd_r[0], u_tcb.state_r[0],
                u_tcb.rcv_nxt_r[1], u_tcb.snd_nxt_r[1], u_tcb.snd_una_r[1],
                u_tcb.rcv_wnd_r[1], u_tcb.snd_wnd_r[1], u_tcb.state_r[1]);
        $fclose(fd);
        $display("DONE pass=%0d nonmatch=%0d ipcsum=%0d crc=%0d seq=%0d ack=%0d bytes=%0d | mac fr=%0d crc=%0d drop=%0d",
                 stat_pass, stat_nonmatch, stat_ipcsum, stat_crc, stat_seq, stat_ack, stat_bytes,
                 m_frames, m_crc_err, m_drop);
        $finish;
    end

    // ---- AXIS 输出 + 元数据 + fend + ACK 捕获 ----
    always @(posedge clk) begin
        if (rst_n && m_tvalid && tready)
            $fwrite(fd, "%016h %02h %d %d %d\n",
                    m_tdata, m_tkeep, m_tlast, m_tuser[0], m_tuser[1]);
        if (rst_n && meta_valid)
            $fwrite(fd, "META %08h %04h %04h %0d %08h\n",
                    meta_src_ip, meta_src_port, meta_len, meta_conn_id, meta_seq);
        if (rst_n && fend)
            $fwrite(fd, "FEND %d\n", ferr);
        if (rst_n && ack_req)
            $fwrite(fd, "ACK %0d %08h\n", ack_id, ack_val);
    end
endmodule
