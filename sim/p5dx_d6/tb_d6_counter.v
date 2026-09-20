`timescale 1ns/1ps
//=============================================================================
// P5d-D6: 签名 #4 (槽耗尽) 观测计数的 RTL 取证。
//
// 刺激 = sim/p5dx/exp2 的 frames_b.memh (11 帧: A1/A2/A3, B1/B2, A4/A5,
// X1..X4; X2/X3/X4 是"三个槽都占住后的第 3/4/5 个不同四元组 SYN" = 必被丢弃)。
// 判据只有一条: `tcp_stat_no_slot` 计数 = 3 (X2/X3/X4) —— 该寄存器在生成的
// 网表里位于 udp_echo.grp_tcp_rx_process_fu_NNNN.tcp_stat_no_slot, 层级可读。
// 本 TB 只做取证, 不改任何策略 (exp2 的完整判据门在 tb_hls_slotleak.v)。
//=============================================================================
module tb_d6_counter;
    localparam GAP  = 20000;
    localparam NMAX = 64;

    reg clk = 0, rst_n = 0;
    always #4 clk = ~clk;      // 125 MHz

    reg  [7:0]  FB [0:16383];
    integer     NFR;
    integer     FO [0:NMAX-1];
    integer     FL [0:NMAX-1];

    reg  [15:0] rx_tdata  = 0;
    wire        rx_tvalid;
    wire        rx_tready;
    wire [15:0] tx_tdata;
    wire        tx_tvalid;
    wire [31:0] cfg_tdata;
    wire        cfg_tvalid;

    udp_echo dut (
        .ap_clk(clk), .ap_rst_n(rst_n), .reset_n(rst_n),
        .rx_stream_TDATA(rx_tdata), .rx_stream_TVALID(rx_tvalid),
        .rx_stream_TREADY(rx_tready),
        .tx_stream_TDATA(tx_tdata), .tx_stream_TVALID(tx_tvalid),
        .tx_stream_TREADY(1'b1),
        .msg_stream_TDATA(), .msg_stream_TVALID(), .msg_stream_TREADY(1'b1),
        .cfg_stream_TDATA(cfg_tdata), .cfg_stream_TVALID(cfg_tvalid),
        .cfg_stream_TREADY(1'b1),
        .led_d0(), .led_d1(), .led_d2(), .led_d3()
    );

    integer fi    = 0;
    integer bp    = 0;
    reg     snd_act = 0;
    integer gap   = 0;
    reg     all_done = 0;

    assign rx_tvalid = snd_act;

    always @(posedge clk) begin
        if (!rst_n) begin
            fi <= 0; bp <= 0; snd_act <= 0; gap <= 0; all_done <= 0;
            rx_tdata <= 0;
        end else if (!all_done) begin
            if (snd_act) begin
                if (rx_tready) begin
                    if (bp + 1 >= FL[fi]) begin
                        snd_act <= 0; gap <= GAP; fi <= fi + 1;
                    end else begin
                        bp       <= bp + 1;
                        rx_tdata <= {7'b0, ((bp + 1) == FL[fi] - 1), FB[FO[fi] + bp + 1]};
                    end
                end
            end else if (gap > 0) begin
                gap <= gap - 1;
            end else if (fi >= NFR) begin
                all_done <= 1;
            end else begin
                bp       <= 0;
                snd_act  <= 1;
                rx_tdata <= {7'b0, (FL[fi] == 1), FB[FO[fi]]};
            end
        end
    end

    integer k, r;
    initial begin
        $readmemh("frames_b.memh", FB);
        k = $fopen("frames_meta.memh", "r");
        r = $fscanf(k, "%d", NFR);
        for (fi = 0; fi < NFR; fi = fi + 1) begin
            r = $fscanf(k, "%d %d", FO[fi], FL[fi]);
        end
        $fclose(k);
        fi = 0;
        #200; rst_n = 1;
        wait (all_done);
        repeat (GAP) @(posedge clk);
        // 槽耗尽计数 (3 = X2/X3/X4 三个无空闲槽的 SYN; X1 占下最后一个槽)
        $display("D6COUNTER tcp_stat_no_slot=%0d (expect 3)",
                 dut.grp_tcp_rx_process_fu_1827.tcp_stat_no_slot);
        $finish;
    end
endmodule
