`timescale 1ns/1ps
// 直喂探针: 新 HLS (P4b 版 udp_echo) 孤立测试 — 直接喂 ARP 请求字节流,
// 看 tx_stream 是否出 ARP 应答。排除我的适配器链路。
module tb_hls_probe_old;
    reg clk = 0, rst_n = 0;
    reg  [15:0] rx_tdata = 0;
    reg         rx_tvalid = 0;
    wire        rx_tready;
    wire [15:0] tx_tdata;
    wire        tx_tvalid;
    reg         tx_tready = 1;

    udp_echo dut (
        .ap_clk(clk), .ap_rst_n(rst_n), .reset_n(rst_n),
        .rx_stream_TDATA(rx_tdata), .rx_stream_TVALID(rx_tvalid),
        .rx_stream_TREADY(rx_tready),
        .tx_stream_TDATA(tx_tdata), .tx_stream_TVALID(tx_tvalid),
        .tx_stream_TREADY(tx_tready),
        .msg_stream_TDATA(), .msg_stream_TVALID(), .msg_stream_TREADY(1'b1),
        .led_d0(), .led_d1(), .led_d2(), .led_d3()
    );

    always #4 clk = ~clk;

    // ARP 请求帧 (前导 + who-has 192.168.100.2 tell 192.168.100.1@1122..5566 + FCS)
    reg [7:0] stim [0:255];
    integer i;
    integer fd;
    integer sent;

    // 构造帧: 55*7 D5 | FF*6 112233445566 0806 | ARP 28B | pad 18 | FCS(伪, 不查)
    initial begin
        for (i = 0; i < 256; i = i + 1) stim[i] = 8'h00;
        for (i = 0; i < 7; i = i + 1) stim[i] = 8'h55;
        stim[7] = 8'hD5;
        for (i = 0; i < 6; i = i + 1) stim[8 + i] = 8'hFF;
        for (i = 0; i < 6; i = i + 1) stim[14 + i] = 8'h11 + i * 8'h11; // 112233445566
        stim[20] = 8'h08; stim[21] = 8'h06;
        stim[22] = 8'h00; stim[23] = 8'h01; stim[24] = 8'h08; stim[25] = 8'h00;
        stim[26] = 8'h06; stim[27] = 8'h04; stim[28] = 8'h00; stim[29] = 8'h01;
        for (i = 0; i < 6; i = i + 1) stim[30 + i] = 8'h11 + i * 8'h11;
        stim[36] = 8'hC0; stim[37] = 8'hA8; stim[38] = 8'h64; stim[39] = 8'h01;
        stim[46] = 8'hC0; stim[47] = 8'hA8; stim[48] = 8'h64; stim[49] = 8'h02;
        // FCS 伪值 (HLS MAC RX 不查 FCS)
        stim[64] = 8'hDE; stim[65] = 8'hAD; stim[66] = 8'hBE; stim[67] = 8'hEF;
    end

    integer k = 0;
    // 时钟化非阻塞驱动: held-valid, 接受拍才前进
    always @(posedge clk) begin
        if (!rst_n) begin
            rx_tvalid <= 0; rx_tdata <= 0; i <= 0; k <= 0;
        end else begin
            k <= k + 1;
            if (k >= 25) begin   // 复位后 25 拍起拍
                if (rx_tvalid && rx_tready) rx_tvalid <= 0;
                if (!rx_tvalid) begin
                    if (i < 69) begin
                        rx_tdata  <= {6'b0, (i == 68), stim[i]};
                        rx_tvalid <= 1;
                        i <= i + 1;
                    end
                end
            end
        end
    end

    initial begin
        fd = $fopen("hls_probe_tx.memh", "w");
        #200; rst_n = 1;
        wait (i >= 69 && !rx_tvalid);
        // 等 300k 拍 (HLS 处理慢)
        repeat (300000) @(posedge clk);
        $fwrite(fd, "END\n");
        $fclose(fd);
        $finish;
    end

    always @(posedge clk) begin
        if (rst_n && tx_tvalid && tx_tready)
            $fwrite(fd, "%03h\n", tx_tdata[8:0]);
    end
endmodule
