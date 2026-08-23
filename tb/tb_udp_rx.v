`timescale 1ns/1ps
// udp_rx 全链 TB: mac_rx_64 -> udp_rx。
// GMII 字节流时钟化非阻塞驱动 (stim_data/dv/er.memh, 与 tb_mac_rx_64 同约定),
// 每拍记录 m_axis 接受词 + meta_valid 拍 (META 前缀) + 末尾 STATS 行。
// 背压 (plusarg): 无 / STALL (3 高 1 低) / HARD (字节窗 [hw[0], hw[1]) 硬停)。
// 配置: 初始配置 A, 字节索引 >= cfgsw[0] 后切配置 B (cfgsw[1]=dst_ip, cfgsw[2]=multi_en)。
module tb_udp_rx;

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
    reg [31:0] cfgsw [0:2];
    reg [31:0] hw [0:1];
    reg [31:0] cfg_dst_ip;
    reg        cfg_multi_en;
    reg [15:0] cfg_port0;

    wire [63:0] s_tdata;
    wire [7:0]  s_tkeep;
    wire        s_tvalid, s_tlast, s_tuser, s_tcrs, s_terr;

    wire [63:0] m_tdata;
    wire [7:0]  m_tkeep;
    wire        m_tvalid, m_tlast;
    wire [1:0]  m_tuser;
    wire        meta_valid;
    wire [47:0] meta_src_mac;
    wire [31:0] meta_src_ip;
    wire [15:0] meta_src_port, meta_len;
    wire [31:0] stat_pass, stat_nonmatch, stat_ipcsum, stat_crc, stat_bytes;
    wire [31:0] m_frames, m_crc_err, m_drop, m_bytes;

    integer     fd;
    integer     fddbg;

    mac_rx_64 u_mac (
        .clk(clk), .rst_n(rst_n),
        .gmii_rxd(rx_d), .gmii_rx_dv(rx_dv), .gmii_rx_er(rx_er),
        .m_axis_tdata(s_tdata), .m_axis_tkeep(s_tkeep), .m_axis_tvalid(s_tvalid),
        .m_axis_tready(s_tready), .m_axis_tlast(s_tlast), .m_axis_tuser(s_tuser),
        .m_axis_terr(s_terr), .m_axis_tcrs(s_tcrs),
        .stat_frames(m_frames), .stat_crc_err(m_crc_err),
        .stat_drop(m_drop), .stat_bytes(m_bytes)
    );

    udp_rx u_rx (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep), .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_tready), .s_axis_tlast(s_tlast), .s_axis_tuser(s_tuser),
        .s_axis_tcrs(s_tcrs), .s_axis_terr(s_terr),
        .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep), .m_axis_tvalid(m_tvalid),
        .m_axis_tready(tready), .m_axis_tlast(m_tlast), .m_axis_tuser(m_tuser),
        .meta_valid(meta_valid), .meta_src_mac(meta_src_mac), .meta_src_ip(meta_src_ip),
        .meta_src_port(meta_src_port), .meta_len(meta_len),
        .cfg_dst_ip(cfg_dst_ip), .cfg_multi_en(cfg_multi_en),
        .cfg_port0(cfg_port0), .cfg_port1(16'd0), .cfg_port2(16'd0), .cfg_port3(16'd0),
        .cfg_port_any(1'b0),
        .stat_pass(stat_pass), .stat_drop_nonmatch(stat_nonmatch),
        .stat_drop_ipcsum(stat_ipcsum), .stat_drop_crc(stat_crc), .stat_bytes(stat_bytes)
    );

    always #4 clk = ~clk;     // 125 MHz

    // ---- 时钟化激励驱动 (非阻塞, 无 TB/DUT 竞争) ----
    always @(posedge clk) begin
        if (!rst_n) begin
            i <= 0; rx_d <= 8'h07; rx_dv <= 0; rx_er <= 0;
            tready <= 1; sc <= 0; done <= 0;
            cfg_dst_ip <= 32'hC0A86402; cfg_multi_en <= 0; cfg_port0 <= 16'd8080;
        end else begin
            if (i < nstim) begin
                rx_d  <= stim_d[i];
                rx_dv <= stim_v[i][0];
                rx_er <= stim_e[i][0];
                i <= i + 1;
            end else begin
                rx_dv <= 0; rx_er <= 0; done <= 1;
            end
            if (i >= cfgsw[0]) begin
                cfg_dst_ip <= cfgsw[1]; cfg_multi_en <= cfgsw[2];
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
        $readmemh("cfg_switch.memh", cfgsw);
        nstim = 0;
        while (nstim < 65536 && stim_d[nstim] !== 8'hxx) nstim = nstim + 1;
        if ($test$plusargs("HARD")) begin
            hardstall = 1;
            $readmemh("hardwin.memh", hw);
        end
        if ($test$plusargs("STALL")) fd = $fopen("resp_udp_rx_stall.memh", "w");
        else if ($test$plusargs("HARD")) fd = $fopen("resp_udp_rx_hard.memh", "w");
        else fd = $fopen("resp_udp_rx.memh", "w");
        fddbg = $fopen("dbg_trace.txt", "w");
        #200; rst_n = 1;
        wait (done == 1);
        repeat (800) @(posedge clk);
        $fwrite(fd, "STATS %0d %0d %0d %0d %0d\n",
                stat_pass, stat_nonmatch, stat_ipcsum, stat_crc, stat_bytes);
        $fwrite(fd, "STATM %0d %0d %0d %0d\n",
                m_frames, m_crc_err, m_drop, m_bytes);
        $fclose(fd);
        $display("DONE pass=%0d nonmatch=%0d ipcsum=%0d crc=%0d bytes=%0d | mac fr=%0d crc=%0d drop=%0d",
                 stat_pass, stat_nonmatch, stat_ipcsum, stat_crc, stat_bytes,
                 m_frames, m_crc_err, m_drop);
        $finish;
    end

    // ---- AXIS 输出 + 元数据捕获 ----
    always @(posedge clk) begin
        if (rst_n && m_tvalid && tready)
            $fwrite(fd, "%016h %02h %d %d %d\n",
                    m_tdata, m_tkeep, m_tlast, m_tuser[0], m_tuser[1]);
        if (rst_n && meta_valid)
            $fwrite(fd, "META %012h %08h %04h %04h\n",
                    meta_src_mac, meta_src_ip, meta_src_port, meta_len);
    end

    // ---- 调试: s_axis 接受拍与 udp_rx 内部状态 ----
    always @(posedge clk) begin
        if (rst_n && s_tvalid && s_tready)
            $fwrite(fddbg, "ACC wcnt=%0d st=%0d mch=%b k=%02h last=%b crs=%b d=%016h\n",
                    u_rx.wcnt, u_rx.state, u_rx.matched, s_tkeep, s_tlast, s_tcrs, s_tdata);
        if (rst_n && u_rx.meta_valid)
            $fwrite(fddbg, "META l=%0d ul=%0d\n", u_rx.meta_len_r, u_rx.meta_len_r + 8);
    end
endmodule
