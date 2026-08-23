`timescale 1ns/1ps
// udp_tx_frame 全链 TB: 载荷 AXIS (presenting 模式) -> udp_tx_frame -> mac_tx_64 -> GMII。
// 每拍记录 gmii_tx_en + gmii_txd 到 resp_udp_tx[_csum0].memh (plusarg CSUM0 = 校验和置 0),
// 末尾 STATS frames bytes。Python 侧解码帧验证头/校验和/载荷/FCS。
module tb_udp_tx;

    reg        clk, rst_n;
    reg [7:0]  stim_ty [0:4095];
    reg [63:0] stim_d  [0:4095];
    reg [7:0]  stim_k  [0:4095];
    reg        stim_l  [0:4095];
    reg [15:0] stim_n  [0:4095];
    integer    nstim;
    reg [12:0] si;
    reg [15:0] gap_cnt;
    reg        tvalid, tlast, presenting;
    reg [63:0] tdata;
    reg [7:0]  tkeep;
    reg        csum_en;

    wire        tready;
    wire [63:0] m_tdata;
    wire [7:0]  m_tkeep;
    wire        m_tvalid, m_tready, m_tlast;
    wire [7:0]  gmii_txd;
    wire        gmii_tx_en;
    wire [31:0] stat_frames, stat_bytes;
    integer     fd;

    udp_tx_frame dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(tdata), .s_axis_tkeep(tkeep),
        .s_axis_tvalid(tvalid), .s_axis_tready(tready), .s_axis_tlast(tlast),
        .cfg_src_mac(48'h000A3501FEC0), .cfg_dst_mac(48'h112233445566),
        .cfg_src_ip(32'h0A000001), .cfg_dst_ip(32'hC0A86402),
        .cfg_src_port(16'h3039), .cfg_dst_port(16'h1F90),
        .cfg_csum_en(csum_en),
        .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep),
        .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready), .m_axis_tlast(m_tlast),
        .stat_frames(stat_frames), .stat_bytes(stat_bytes)
    );

    mac_tx_64 u_tx (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(m_tdata), .s_axis_tkeep(m_tkeep),
        .s_axis_tvalid(m_tvalid), .s_axis_tready(m_tready), .s_axis_tlast(m_tlast),
        .gmii_txd(gmii_txd), .gmii_tx_en(gmii_tx_en), .gmii_tx_er(),
        .stat_frames(), .stat_abort()
    );

    always #4 clk = ~clk;     // 125 MHz

    // presenting 模式载荷驱动 (抄 tb_mac_tx_64.v: 接受拍撤 valid 一拍再装下一词)
    always @(posedge clk) begin
        if (!rst_n) begin
            si <= 0; tvalid <= 0; tdata <= 0; tkeep <= 0; tlast <= 0;
            gap_cnt <= 0; presenting <= 0;
        end else begin
            if (gap_cnt > 0) begin
                presenting <= 0; tvalid <= 0; gap_cnt <= gap_cnt - 1;
            end else if (!presenting) begin
                if (si < nstim) begin
                    if (stim_ty[si]) begin
                        tdata <= stim_d[si]; tkeep <= stim_k[si]; tlast <= stim_l[si];
                        presenting <= 1; tvalid <= 1; si <= si + 1;
                    end else begin
                        tvalid <= 0; gap_cnt <= stim_n[si] - 1; si <= si + 1;
                    end
                end else begin
                    tvalid <= 0;
                end
            end else begin
                if (tvalid && tready) begin
                    presenting <= 0; tvalid <= 0;      // 空一拍再装下一词
                end
            end
        end
    end

    initial begin
        clk = 0; rst_n = 0; csum_en = 1;
        if ($test$plusargs("CSUM0")) csum_en = 0;
        $readmemh("txp_ty.memh",   stim_ty);
        $readmemh("txp_data.memh", stim_d);
        $readmemh("txp_keep.memh", stim_k);
        $readmemh("txp_last.memh", stim_l);
        $readmemh("txp_gap.memh",  stim_n);
        nstim = 0;
        while (nstim < 4096 && stim_ty[nstim] !== 8'hxx) nstim = nstim + 1;
        if ($test$plusargs("CSUM0")) fd = $fopen("resp_udp_tx_csum0.memh", "w");
        else fd = $fopen("resp_udp_tx.memh", "w");
        #200; rst_n = 1;
        repeat (60000) @(posedge clk);
        $fwrite(fd, "STATS %0d %0d\n", stat_frames, stat_bytes);
        $fclose(fd);
        $display("DONE frames=%0d bytes=%0d", stat_frames, stat_bytes);
        $finish;
    end

    always @(posedge clk)
        if (rst_n) $fwrite(fd, "%b %02h\n", gmii_tx_en, gmii_txd);
endmodule
