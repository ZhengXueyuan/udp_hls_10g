`timescale 1ns/1ps
//=============================================================================
// tb_p5_wrapper: wrapper 级 APP_MODE 门 (P5a 复核 W1 附带要求)
//
// 为什么需要它: P5 全链 TB (tb_p5_app) 自己搭数据面, **不走 wrapper 的
// APP_MODE 接线分支** — 所以 W1 (app TX 通路 `assign app_tx_tready =
// app2_tready` 与 u_app_pipe.s_ready 抢同一根线 = 组合自环 + 背压丢失) 在
// xsim 里完全隐身, 直到 Vivado DRC/bitgen 才炸。本门直接例化 wrapper_p4
// (需 `-d APP_MODE` 编译), 观察 wrapper **内部 GMII** (u_dut.e_txd/e_txen),
// 把 "app_pattern -> axis_pipe(u_app_pipe) -> tcp_tx_frame -> tx_arb ->
// mac_tx_64" 整条 wrapper 接线跑通并逐字节校验图案:
//   - 若 app 侧 tready 退化成 m_ready (W1 原症状), axis_pipe 会在 m_valid=1
//     期间再收一个字 => 每帧载荷整字丢失/重复 => 图案逐字节比对当场 FAIL。
//
// 连接配置: TCB/CAM 由层次赋值直接预置 (绕过 HLS 慢路径, 本门只验 wrapper
// 数据面接线); CONN_UP 事件用 force 一拍注入 app_ctrl.o_ev_up。
// 捕获: resp_p5_wrapper.memh ("%02h %d" 同 tb_p5_app) 供 gen_stim_p5_app.py
// checkwrapper 判据 (FCS + 图案逐字节 + seq 连续)。
//=============================================================================
module tb_p5_wrapper;
    localparam [31:0] TB_ISS   = 32'h12345678;
    localparam [31:0] ISN0     = TB_ISS + 32'd1;
    localparam [31:0] PEER_ISN = 32'h20000000;

    reg        reset_n, fpga_gclk, phy1_rxc;
    reg  [3:0] phy1_rxd;
    reg        phy1_rxctl;
    wire       phy1_txc;
    wire [3:0] phy1_txd;
    wire       phy1_txctl;
    wire       led_d0, led_d1, led_d2, led_d3;
    wire       uart_txd;

    wrapper_p4 u_dut (
        .reset_n     (reset_n),
        .fpga_gclk   (fpga_gclk),
        .phy1_rxc    (phy1_rxc),
        .phy1_rxd    (phy1_rxd),
        .phy1_rxctl  (phy1_rxctl),
        .phy1_txc    (phy1_txc),
        .phy1_txd    (phy1_txd),
        .phy1_txctl  (phy1_txctl),
        .led_d0      (led_d0),
        .led_d1      (led_d1),
        .led_d2      (led_d2),
        .led_d3      (led_d3),
        .uart_txd    (uart_txd)
    );

    always #10 fpga_gclk = ~fpga_gclk;   // 50MHz (MMCM CLKIN1_PERIOD=20ns)
    always #4  phy1_rxc   = ~phy1_rxc;   // 125MHz RGMII RX 时钟 -> gmii_clk

    // ---- wrapper 内部 GMII 捕获 (mac_tx_64 -> u_rgmii 之间) ----
    integer fd;
    reg     en_d;
    always @(posedge u_dut.gmii_clk) begin
        if (u_dut.e_txen) $fwrite(fd, "%02h 1\n", u_dut.e_txd);
        else if (en_d)    $fwrite(fd, "00 0\n");
        en_d <= u_dut.e_txen;
    end

    integer i;
    initial begin
        fpga_gclk = 0; phy1_rxc = 0; reset_n = 0;
        phy1_rxd = 4'h0; phy1_rxctl = 1'b0; en_d = 0;
        fd = $fopen("resp_p5_wrapper.memh", "w");
        #400; reset_n = 1;
        repeat (4000) @(posedge u_dut.gmii_clk);      // 等 MMCM/复位稳定

        // ---- 预置连接 (TCB + CAM, 绕过 HLS 慢路径) ----
        u_dut.u_tcb.rcv_nxt_r[0] = PEER_ISN + 32'd1;
        u_dut.u_tcb.snd_nxt_r[0] = ISN0;
        u_dut.u_tcb.snd_una_r[0] = ISN0;
        u_dut.u_tcb.rcv_wnd_r[0] = 16'hC000;
        u_dut.u_tcb.snd_wnd_r[0] = 16'h4000;
        u_dut.u_tcb.state_r[0]   = 4'd1;              // ESTABLISHED
        u_dut.u_cam.sip_r[0]     = 32'hC0A86401;      // 对端 IP
        u_dut.u_cam.dip_r[0]     = 32'hC0A86402;      // 本机 IP
        u_dut.u_cam.sport_r[0]   = 16'h3039;          // 对端端口
        u_dut.u_cam.dport_r[0]   = 16'h1F90;          // 本机端口
        u_dut.u_cam.dmac_r[0]    = 48'h112233445566;  // 对端 MAC
        repeat (600) @(posedge u_dut.gmii_clk);       // app_ctrl 轮扫采到

        // ---- CONN_UP 事件 (force 一拍; 事件 FIFO 本门不判) ----
        force u_dut.u_app_ctrl.o_ev_up = 1'b1;
        @(posedge u_dut.gmii_clk);
        release u_dut.u_app_ctrl.o_ev_up;

        // ---- 抓 ~7 帧 (app 产字 8B/9 拍 -> 1460B 帧 ~1650 拍) ----
        repeat (12000) @(posedge u_dut.gmii_clk);
        $fclose(fd);

        $display("P5W state st0=%0d ready=%04h app(tx_bytes=%0d fr=%0d bad=%0d)",
                 u_dut.u_app_ctrl.dbg_c0_state, u_dut.app_tx_ready,
                 u_dut.u_app.stat_tx_bytes, u_dut.u_app.stat_tx_frames,
                 u_dut.u_app.stat_bad_frames);
        $display("P5W tx(frames=%0d bytes=%0d) drop=%0d fin=%0d rst=%0d eend=%0d mac_abort=%0d",
                 u_dut.u_tcp_tx.stat_frames, u_dut.u_tcp_tx.stat_bytes,
                 u_dut.u_tcp_tx.stat_drop_len, u_dut.u_tcp_tx.stat_fin,
                 u_dut.u_tcp_tx.stat_rst, u_dut.u_tcp_tx.stat_eend,
                 u_dut.u_mac_tx.stat_abort);
        $display("P5W led=%b%b%b%b uart_idle=%b", led_d3, led_d2, led_d1, led_d0,
                 uart_txd);
        $display("P5W DONE");
        $finish;
    end
endmodule
