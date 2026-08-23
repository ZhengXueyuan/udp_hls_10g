`timescale 1ns/1ps
// mac_rx_64 单模块 TB: 读 stim_*.memh 按 1B/拍 @125MHz 驱动 GMII RX,
// 捕获 AXIS 字流到 resp.memh, 末尾附统计行。
// 驱动为时钟化非阻塞赋值 (无 TB/DUT 竞争)。
// 背压模式 (plusarg): 无 / STALL (周期抖动) / STALL2 (字节窗 [1500,4500) 硬停)。
module tb_mac_rx_64;

    reg        clk, rst_n;
    reg [7:0]  rx_d;
    reg        rx_dv, rx_er;
    reg [7:0]  stim_d [0:65535];
    reg [7:0]  stim_v [0:65535];
    reg [7:0]  stim_e [0:65535];
    integer    nstim;
    reg [16:0] i;
    reg [31:0] stall_cnt;
    reg        tready;
    reg        hardstall;
    reg        done;

    wire [63:0] tdata;
    wire [7:0]  tkeep;
    wire        tvalid, tlast, tuser, terr, tcrs;
    wire [31:0] stat_frames, stat_crc_err, stat_drop, stat_bytes;
    integer     fd, fd2;

    mac_rx_64 dut (
        .clk(clk), .rst_n(rst_n),
        .gmii_rxd(rx_d), .gmii_rx_dv(rx_dv), .gmii_rx_er(rx_er),
        .m_axis_tdata(tdata), .m_axis_tkeep(tkeep), .m_axis_tvalid(tvalid),
        .m_axis_tready(tready), .m_axis_tlast(tlast), .m_axis_tuser(tuser),
        .m_axis_terr(terr), .m_axis_tcrs(tcrs),
        .stat_frames(stat_frames), .stat_crc_err(stat_crc_err),
        .stat_drop(stat_drop), .stat_bytes(stat_bytes)
    );

    always #4 clk = ~clk;     // 125 MHz

    // ---- 时钟化激励驱动 ----
    always @(posedge clk) begin
        if (!rst_n) begin
            i <= 0; rx_d <= 8'h07; rx_dv <= 0; rx_er <= 0;
            tready <= 1; stall_cnt <= 0; done <= 0;
        end else begin
            if (i < nstim) begin
                rx_d  <= stim_d[i];
                rx_dv <= stim_v[i][0];
                rx_er <= stim_e[i][0];
                i <= i + 1;
            end else begin
                rx_dv <= 0; rx_er <= 0; done <= 1;
            end
            if (hardstall && i >= 1500 && i < 4500) tready <= 0;
            else if ($test$plusargs("STALL")) begin
                stall_cnt <= stall_cnt + 1;
                if (stall_cnt % 23 == 0) tready <= 0;
                else if (stall_cnt % 23 == 4) tready <= 1;
            end
            else tready <= 1;
        end
    end

    initial begin
        clk = 0; rst_n = 0; hardstall = 0;
        $readmemh("stim_data.memh", stim_d);
        $readmemh("stim_dv.memh",   stim_v);
        $readmemh("stim_er.memh",   stim_e);
        nstim = 0;
        while (nstim < 65536 && stim_d[nstim] !== 8'hxx) nstim = nstim + 1;
        if ($test$plusargs("STALL2")) hardstall = 1;
        fd = $fopen("resp.memh", "w");
        fd2 = $fopen("crc_log.txt", "w");
        #200; rst_n = 1;
        wait (done == 1);
        repeat (400) @(posedge clk);
        $fwrite(fd, "STATS %0d %0d %0d %0d\n", stat_frames, stat_crc_err, stat_drop, stat_bytes);
        $fclose(fd);
        $display("DONE frames=%0d crc_err=%0d drop=%0d bytes=%0d",
                 stat_frames, stat_crc_err, stat_drop, stat_bytes);
        $finish;
    end

    // ---- AXIS 捕获 + CRC 输入流记录 ----
    always @(posedge clk) begin
        if (rst_n && tvalid && tready) begin
            $fwrite(fd, "%016h %02h %b %b %b %b\n", tdata, tkeep, tuser, tlast, tcrs, terr);
            if (tlast) $display("TL dbg: crc=%08h fbytes=%0d state=%0d bcnt=%0d wreg=%016h wkeep=%02h",
                                dut.u_crc.crc, dut.fbytes, dut.state, dut.bcnt, dut.wreg, dut.wkeep);
        end
        if (rst_n) begin
            if (dut.crc_init) $fwrite(fd2, "INIT\n");
            else if (dut.crc_en) $fwrite(fd2, "%02h\n", rx_d);
        end
    end
endmodule
