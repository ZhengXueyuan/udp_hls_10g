`timescale 1ns/1ps
// HLS 孤立探针 (P4b 排障): 直喂新 HLS udp_echo (slowstack_prj) ARP+UDP 两帧,
// 捕 tx_stream 全帧 — 定位 udp echo 载荷 3 字节污染 (HLS RTL 侧 vs 我的适配链)。
module tb_hls_udp_probe;
    reg clk = 0, rst_n = 0;
    reg  [15:0] rx_tdata = 0;
    reg         rx_tvalid = 0;
    wire        rx_tready;
    wire [15:0] tx_tdata;
    wire        tx_tvalid;
    reg         tx_tready = 1;
    wire [31:0] cfg_tdata;
    wire        cfg_tvalid;

    udp_echo dut (
        .ap_clk(clk), .ap_rst_n(rst_n), .reset_n(rst_n),
        .rx_stream_TDATA(rx_tdata), .rx_stream_TVALID(rx_tvalid),
        .rx_stream_TREADY(rx_tready),
        .tx_stream_TDATA(tx_tdata), .tx_stream_TVALID(tx_tvalid),
        .tx_stream_TREADY(tx_tready),
        .msg_stream_TDATA(), .msg_stream_TVALID(), .msg_stream_TREADY(1'b1),
        .cfg_stream_TDATA(cfg_tdata), .cfg_stream_TVALID(cfg_tvalid),
        .cfg_stream_TREADY(1'b1),
        .led_d0(), .led_d1(), .led_d2(), .led_d3()
    );

    always #4 clk = ~clk;

    reg [7:0] stim [0:255];
    reg       slast [0:255];
    integer   nstim, i, k, fd;

    initial begin
        $readmemh("hls_stim.memh", stim);
        $readmemh("hls_stim_last.memh", slast);
        nstim = 0;
        while (nstim < 256 && stim[nstim] !== 8'hxx) nstim = nstim + 1;
        fd = $fopen("hls_udp_probe_tx.memh", "w");
        #200; rst_n = 1;
        wait (i >= nstim && !rx_tvalid);
        repeat (500000) @(posedge clk);
        $fwrite(fd, "END\n");
        $fclose(fd);
        $finish;
    end

    // 时钟化非阻塞驱动: held-valid, 接受拍才前进
    always @(posedge clk) begin
        if (!rst_n) begin
            rx_tvalid <= 0; rx_tdata <= 0; i <= 0; k <= 0;
        end else begin
            k <= k + 1;
            if (k >= 25) begin
                if (rx_tvalid && rx_tready) rx_tvalid <= 0;
                if (!rx_tvalid) begin
                    if (i < nstim) begin
                        rx_tdata  <= {6'b0, slast[i], stim[i]};
                        rx_tvalid <= 1;
                        i <= i + 1;
                    end
                end
            end
        end
    end

    always @(posedge clk) begin
        if (rst_n && tx_tvalid && tx_tready)
            $fwrite(fd, "%03h\n", tx_tdata[8:0]);
    end
endmodule
