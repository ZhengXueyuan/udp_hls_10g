`timescale 1ns/1ps
// 全链闭环 TB: GMII 流入 -> mac_rx_64 -> udp_rx -> udp_echo -> udp_tx_frame ->
// mac_tx_64 -> GMII 流出。每拍记录 gmii_tx_en+txd 到 resp_echo[_stall].memh,
// 末尾 STATS (echo/drop_crc | tx frames/bytes)。plusarg STALL = 回发侧周期背压。
module tb_udp_echo;

    reg        clk, rst_n;
    reg [7:0]  rx_d;
    reg        rx_dv, rx_er;
    reg [7:0]  stim_d [0:65535];
    reg [7:0]  stim_v [0:65535];
    reg [7:0]  stim_e [0:65535];
    integer    nstim;
    reg [16:0] i;
    reg        done;

    wire [63:0] s_tdata;
    wire [7:0]  s_tkeep;
    wire        s_tvalid, s_tready, s_tlast, s_tuser, s_tcrs, s_terr;
    wire [63:0] p_tdata;
    wire [7:0]  p_tkeep;
    wire        p_tvalid, p_tready, p_tlast;
    wire [1:0]  p_tuser;
    wire        fend, ferr;
    wire        meta_valid;
    wire [47:0] meta_src_mac;
    wire [31:0] meta_src_ip;
    wire [15:0] meta_src_port, meta_len;
    wire [63:0] e_tdata;
    wire [7:0]  e_tkeep;
    wire        e_tvalid, e_tready, e_tlast;
    wire [47:0] e_dst_mac;
    wire [31:0] e_dst_ip;
    wire [15:0] e_dst_port;
    wire [7:0]  gmii_txd;
    wire        gmii_tx_en;
    wire [31:0] stat_echo, stat_drop_crc, stat_tx_frames, stat_tx_bytes;
    wire [31:0] stat_pass, stat_nonmatch, stat_ipcsum, stat_crc, stat_bytes;

    integer     fd;

    mac_rx_64 u_mac (
        .clk(clk), .rst_n(rst_n),
        .gmii_rxd(rx_d), .gmii_rx_dv(rx_dv), .gmii_rx_er(rx_er),
        .m_axis_tdata(s_tdata), .m_axis_tkeep(s_tkeep), .m_axis_tvalid(s_tvalid),
        .m_axis_tready(s_tready), .m_axis_tlast(s_tlast), .m_axis_tuser(s_tuser),
        .m_axis_terr(s_terr), .m_axis_tcrs(s_tcrs),
        .stat_frames(), .stat_crc_err(), .stat_drop(), .stat_bytes()
    );

    udp_rx u_rx (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep), .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_tready), .s_axis_tlast(s_tlast), .s_axis_tuser(s_tuser),
        .s_axis_tcrs(s_tcrs), .s_axis_terr(s_terr),
        .m_axis_tdata(p_tdata), .m_axis_tkeep(p_tkeep), .m_axis_tvalid(p_tvalid),
        .m_axis_tready(p_tready), .m_axis_tlast(p_tlast), .m_axis_tuser(p_tuser),
        .fend(fend), .ferr(ferr),
        .meta_valid(meta_valid), .meta_src_mac(meta_src_mac), .meta_src_ip(meta_src_ip),
        .meta_src_port(meta_src_port), .meta_len(meta_len),
        .cfg_dst_ip(32'hC0A86402), .cfg_multi_en(1'b0),
        .cfg_port0(16'h1F90), .cfg_port1(16'd0), .cfg_port2(16'd0), .cfg_port3(16'd0),
        .cfg_port_any(1'b0),
        .stat_pass(stat_pass), .stat_drop_nonmatch(stat_nonmatch),
        .stat_drop_ipcsum(stat_ipcsum), .stat_drop_crc(stat_crc), .stat_bytes(stat_bytes)
    );

    udp_echo u_echo (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(p_tdata), .s_axis_tkeep(p_tkeep), .s_axis_tvalid(p_tvalid),
        .s_axis_tready(p_tready), .s_axis_tlast(p_tlast), .s_axis_tuser(p_tuser),
        .fend(fend), .ferr(ferr),
        .meta_valid(meta_valid), .meta_src_mac(meta_src_mac), .meta_src_ip(meta_src_ip),
        .meta_src_port(meta_src_port), .meta_len(meta_len),
        .cfg_my_mac(48'h000A3501FEC1), .cfg_my_ip(32'hC0A86402), .cfg_my_port(16'h1F90),
        .m_axis_tdata(e_tdata), .m_axis_tkeep(e_tkeep), .m_axis_tvalid(e_tvalid),
        .m_axis_tready(e_tready), .m_axis_tlast(e_tlast),
        .tx_cfg_dst_mac(e_dst_mac), .tx_cfg_dst_ip(e_dst_ip), .tx_cfg_dst_port(e_dst_port),
        .stat_echo(stat_echo), .stat_drop_crc(stat_drop_crc)
    );

    udp_tx_frame u_tx (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(e_tdata), .s_axis_tkeep(e_tkeep),
        .s_axis_tvalid(e_tvalid), .s_axis_tready(e_tready), .s_axis_tlast(e_tlast),
        .cfg_src_mac(48'h000A3501FEC1), .cfg_dst_mac(e_dst_mac),
        .cfg_src_ip(32'hC0A86402), .cfg_dst_ip(e_dst_ip),
        .cfg_src_port(16'h1F90), .cfg_dst_port(e_dst_port),
        .cfg_csum_en(1'b1),
        .m_axis_tdata(), .m_axis_tkeep(), .m_axis_tvalid(), .m_axis_tready(),
        .m_axis_tlast(),
        .stat_frames(stat_tx_frames), .stat_bytes(stat_tx_bytes)
    );

    mac_tx_64 u_txmac (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(u_tx.m_axis_tdata), .s_axis_tkeep(u_tx.m_axis_tkeep),
        .s_axis_tvalid(u_tx.m_axis_tvalid), .s_axis_tready(u_tx.m_axis_tready),
        .s_axis_tlast(u_tx.m_axis_tlast),
        .gmii_txd(gmii_txd), .gmii_tx_en(gmii_tx_en), .gmii_tx_er(),
        .stat_frames(), .stat_abort()
    );

    always #4 clk = ~clk;     // 125 MHz

    always @(posedge clk) begin
        if (!rst_n) begin
            i <= 0; rx_d <= 8'h07; rx_dv <= 0; rx_er <= 0; done <= 0;
        end else begin
            if (i < nstim) begin
                rx_d  <= stim_d[i];
                rx_dv <= stim_v[i][0];
                rx_er <= stim_e[i][0];
                i <= i + 1;
            end else begin
                rx_dv <= 0; rx_er <= 0; done <= 1;
            end
        end
    end

    initial begin
        clk = 0; rst_n = 0;
        $readmemh("stim_data.memh", stim_d);
        $readmemh("stim_dv.memh",   stim_v);
        $readmemh("stim_er.memh",   stim_e);
        nstim = 0;
        while (nstim < 65536 && stim_d[nstim] !== 8'hxx) nstim = nstim + 1;
        fd = $fopen("resp_echo.memh", "w");
        #200; rst_n = 1;
        wait (done == 1);
        repeat (20000) @(posedge clk);
        $fwrite(fd, "STATS %0d %0d %0d %0d\n",
                stat_echo, stat_drop_crc, stat_tx_frames, stat_tx_bytes);
        $fclose(fd);
        $display("DONE echo=%0d drop_crc=%0d tx_frames=%0d tx_bytes=%0d | rx pass=%0d",
                 stat_echo, stat_drop_crc, stat_tx_frames, stat_tx_bytes, stat_pass);
        $finish;
    end

    always @(posedge clk)
        if (rst_n) $fwrite(fd, "%b %02h\n", gmii_tx_en, gmii_txd);
endmodule
