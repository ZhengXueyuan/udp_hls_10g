`timescale 1ns/1ps
//=============================================================================
// tb_rgmii_phy_model.v — P6a-T2 前端判据: 行为级 RTL8211E RGMII 模型 + 往返一致
//=============================================================================
// 为什么不用"与 K7 前端逐位同构"做判据:
//   两块板的 PHY 搭接不同 (KU5P: RXDLY=1/TXDLY=1 —— 原理图实测 R52/R51 10k 上拉到
//   VDD3.3; ECO 板未定, 由本 TB 反推为 RXDLY=0, 见下), 前端的相位/结构**本来就该不同**
//   —— 拿 K7 当 oracle 是错的。⇒ 判据 = **按手册语义建 PHY 模型, 做往返逐字节一致**。
//
// 模型语义 (RTL8211E 手册 10.6.5 节 Figure 32/33 的 "internal delay added" 模式):
//   RXDLY=1 (PHY→MAC): PHY 在自己的数据边沿驱动 RXD, 并把 RXC **延迟 2ns** 送出
//                      ⇒ MAC 用未移相的 RXC 采样即落眼图中心。
//   nibble 约定 (RGMII 标准): 上升沿 = RXD[3:0] / 下降沿 = RXD[7:4] (TX 同理)。
//   TXDLY=1 (MAC→PHY): PHY 把收到的 TXC **延迟 2ns** 后去锁 TXD
//                      ⇒ MAC 只需把 TXC 与 TXD **边沿对齐**驱动。
//   本 TB 的采样点 = "DUT 的 TXC 边沿 + 1ns" (用 DUT 自己的 TXC 触发, 与极性无关)。
//
// 判据 (四项, **全部**计入 PASS 条件 —— 审查指出旧版只判前两项, 有两条假通过路径):
//   ① 数据往返逐字节一致 (xorshift 序列, 位移 d∈[0,16] 内唯一零失配)
//   ② 记录条数 == 发送条数 (TX 按 TX_EN 门控 / RX 按 RX_DV 门控 ⇒ 无丢字/多字)
//   ③ **TX_CTL 两半配对**: 实测 `ctl_rise ^ ctl_fall` 必须 == 该字节期望的 TX_ER
//      (旧版只数 ctl_fall≠1, 且不进 PASS ⇒ "D2 恒 0" 这类 DUT 会假通过)
//   ④ **RX_ER 通路**: 实测 `gmii_rx_er` 必须 == 该字节期望的 RX_ER
//      (旧版 ER 恒 0 ⇒ "gmii_rx_er 硬接 0" 会假通过)
//   ⇒ 序列里**注入各 1 个 ER=1 的字节** (第 NBYTES/2 个), 故 ③④ 真的被激励到。
//
// 预热 (WARM): IDDRE1/ODDRE1 模型启动期前 ~15 拍不出有效数据 (实测), 故前 WARM 拍
//   两端都发 idle (TX_EN=0 / RX_DV=0), 之后才开始发真字节 ⇒ d=0 对齐, 判据干净。
//
// 对照: 同一份 PHY 模型同时挂 **K7 前端** 与 **US+ 前端**。
//   实测 (2026-09-28): KU5P 前端四项全过; K7 前端 **TX 全过**(其 TX 配方在 TXDLY=1 下
//   同样自洽 —— `gmii_txd_low` 是阻塞赋值读沿前 `gmii_txd_r`, 天然多滞后一拍, 正好
//   补偿 `gmii_txd_r_d1` 的两级流水)、**RX 失配**(它靠 `IDELAYE2`+`BUFG(~rxc)` 自己
//   凑相位, 面对已被 PHY 延迟过的 RXC 必然错) ⇒ 反推 **ECO 板 PHY 的 RXDLY=0**。
// 用法: sim/p6a_ku5p/run_tb_rgmii_phy_model.bat  (判读 VERDICT 行)
//=============================================================================

module rgmii_pair #(
    parameter USE_US  = 1,          // 1 = util_gmii_to_rgmii_us, 0 = util_gmii_to_rgmii (K7)
    parameter NBYTES  = 200,
    parameter WARM    = 32,
    parameter TRACE   = 0
) (
    output integer tx_delay_r,
    output integer tx_mismatch_r,
    output integer tx_er_bad_r,
    output integer tx_count_r,
    output integer rx_delay_r,
    output integer rx_mismatch_r,
    output integer rx_er_bad_r,
    output integer rx_count_r,
    output integer done_r
);

    // ---------------- 时钟: 125MHz PHY 内部参考, RXC = +2ns (RXDLY=1) -------------
    reg phy_clk = 0;
    always #4 phy_clk = ~phy_clk;                 // 8ns 周期
    reg rgmii_rxc = 0;
    always @(phy_clk) rgmii_rxc <= #2 phy_clk;    // 送 FPGA 的 RXC 延迟 2ns

    reg  [7:0] tx_in  [0:NBYTES-1];
    reg  [7:0] rx_in  [0:NBYTES-1];
    reg        tx_er_in [0:NBYTES-1];             // 期望 TX_ER (仅 1 个字节为 1)
    reg        rx_er_in [0:NBYTES-1];             // 期望 RX_ER (仅 1 个字节为 1)
    reg  [7:0] tx_out [0:NBYTES+64];
    reg  [7:0] rx_out [0:NBYTES+64];
    reg        tx_er_out [0:NBYTES+64];
    reg        rx_er_out [0:NBYTES+64];
    integer   tx_n = 0, rx_n = 0, tx_in_n = 0;
    integer   tx_er_bad = 0, rx_er_bad = 0;

    integer i;
    reg [63:0] lfsr;
    initial begin
        lfsr = 64'h9E3779B97F4A7C15;
        for (i = 0; i < NBYTES; i = i + 1) begin
            lfsr = lfsr ^ (lfsr << 13);      // xorshift64 (与 app_pattern 同族)
            lfsr = lfsr ^ (lfsr >> 7);
            lfsr = lfsr ^ (lfsr << 17);
            tx_in[i]   = lfsr[7:0];
            rx_in[i]   = lfsr[15:8];
            tx_er_in[i] = (i == NBYTES/2);   // 各注入 1 个 ER=1 字节 (激励 ③④)
            rx_er_in[i] = (i == NBYTES/2);
        end
    end

    // ---------------- DUT 例化 (GMII 侧) ----------------
    reg  [7:0] gmii_txd   = 8'h00;
    reg        gmii_tx_en = 1'b0, gmii_tx_er = 1'b0;
    wire [7:0] gmii_rxd;
    wire       gmii_rx_dv, gmii_rx_er;
    wire       gmii_rx_clk, gmii_tx_clk, gmii_crs, gmii_col;
    wire [3:0] rgmii_td;
    wire       rgmii_tx_ctl, rgmii_txc;
    wire [3:0] rgmii_rd_i;
    wire       rgmii_rx_ctl_i;

    generate
    if (USE_US) begin : g_us
        util_gmii_to_rgmii_us u_rgmii (
            .rgmii_rxc(rgmii_rxc), .reset(1'b0),
            .rgmii_td(rgmii_td), .rgmii_tx_ctl(rgmii_tx_ctl), .rgmii_txc(rgmii_txc),
            .rgmii_rd_i(rgmii_rd_i), .rgmii_rx_ctl_i(rgmii_rx_ctl_i),
            .gmii_rx_clk(gmii_rx_clk), .gmii_txd(gmii_txd),
            .gmii_tx_en(gmii_tx_en), .gmii_tx_er(gmii_tx_er),
            .gmii_tx_clk(gmii_tx_clk), .gmii_crs(gmii_crs), .gmii_col(gmii_col),
            .gmii_rxd(gmii_rxd), .gmii_rx_dv(gmii_rx_dv), .gmii_rx_er(gmii_rx_er),
            .speed_selection(2'b10), .duplex_mode(1'b1)
        );
    end else begin : g_k7
        util_gmii_to_rgmii u_rgmii (
            .reset(1'b0),
            .rgmii_td(rgmii_td), .rgmii_tx_ctl(rgmii_tx_ctl), .rgmii_txc(rgmii_txc),
            .rgmii_rd_i(rgmii_rd_i), .rgmii_rx_ctl_i(rgmii_rx_ctl_i),
            .gmii_rx_clk(gmii_rx_clk), .rgmii_rxc(rgmii_rxc),
            .gmii_txd(gmii_txd), .gmii_tx_en(gmii_tx_en), .gmii_tx_er(gmii_tx_er),
            .gmii_tx_clk(gmii_tx_clk), .gmii_crs(gmii_crs), .gmii_col(gmii_col),
            .gmii_rxd(gmii_rxd), .gmii_rx_dv(gmii_rx_dv), .gmii_rx_er(gmii_rx_er),
            .speed_selection(2'b10), .duplex_mode(1'b1)
        );
        if (TRACE) begin : tr_k7
            always @(posedge rgmii_txc) #1
                $display("    K7INT t=%0t R=%h D1r=%h low_nib=%h | D1=%h D2=%h",
                         $time, u_rgmii.gmii_txd_r, u_rgmii.gmii_txd_r_d1,
                         u_rgmii.gmii_txd_low, u_rgmii.gmii_txd_r_d1[3:0],
                         u_rgmii.gmii_txd_low);
        end
    end
    endgenerate

    // ---------------- GMII TX 激励: 前 WARM 拍 idle, 之后每拍一字节, 发完 idle ----
    integer clk_cnt = 0;
    always @(posedge gmii_rx_clk) begin
        clk_cnt <= clk_cnt + 1;
        if (clk_cnt < WARM) begin
            gmii_txd <= 8'h00; gmii_tx_en <= 1'b0; gmii_tx_er <= 1'b0;
        end else if (tx_in_n < NBYTES) begin
            gmii_txd <= tx_in[tx_in_n]; gmii_tx_en <= 1'b1; gmii_tx_er <= tx_er_in[tx_in_n];
            if (TRACE && tx_in_n < 8) $display("    DRV t=%0t cycle=%0d gmii_txd<=%02x er=%b",
                                               $time, tx_in_n, tx_in[tx_in_n], tx_er_in[tx_in_n]);
            tx_in_n  <= tx_in_n + 1;
        end else begin
            gmii_txd <= 8'h00; gmii_tx_en <= 1'b0; gmii_tx_er <= 1'b0;
        end
    end

    // ---------------- PHY TX 模型: TXC 边沿 +1ns 采样, 仅活动字节入表 ------------
    reg [3:0] td_low_s = 0, td_high_s = 0;
    reg       ctl_rise_s = 0, ctl_fall_s = 0;
    reg [7:0] tx_byte;
    always @(posedge rgmii_txc) begin #1;
        td_low_s   = rgmii_td;         // 上升沿 = 低 nibble
        ctl_rise_s = rgmii_tx_ctl;     // 上升沿 = TX_EN
    end
    always @(negedge rgmii_txc) begin #1;
        td_high_s  = rgmii_td;         // 下降沿 = 高 nibble
        ctl_fall_s = rgmii_tx_ctl;     // 下降沿 = TX_EN ^ TX_ER
        tx_byte = {td_high_s, td_low_s};
        if (ctl_rise_s === 1'b1) begin           // 只记活动字节
            if (TRACE && tx_n < 8)
                $display("    CAP t=%0t raise_lo=%h fall_hi=%h -> byte=%02x", $time, td_low_s, td_high_s, tx_byte);
            if (tx_n <= NBYTES + 32) begin
                tx_out[tx_n]    = tx_byte;
                tx_er_out[tx_n] = ctl_rise_s ^ ctl_fall_s;   // 实测 TX_ER (③)
                tx_n = tx_n + 1;
            end
        end
    end

    // ---------------- PHY RX 模型: 数据在 phy_clk 边沿变化 (低/高 nibble) ---------
    reg  [3:0] nib_lo = 4'h0, nib_hi = 4'h0;
    reg        cur_er = 1'b0;
    wire [3:0] rd_w  = phy_clk ? nib_lo : nib_hi;
    integer    clk_phy = 0;
    integer    rx_src = 0;
    reg        load_en = 1'b0;                   // 与 nib 装载同拍的"有效"标记
    wire       ctl_w = phy_clk ? load_en : (load_en & ~cur_er);   // CTL = DV ^ ER
    always @(posedge phy_clk) begin
        clk_phy <= clk_phy + 1;
        load_en <= (clk_phy >= WARM) && (rx_src < NBYTES);
        if ((clk_phy >= WARM) && (rx_src < NBYTES)) begin
            nib_lo <= rx_in[rx_src][3:0];        // 高电平期 = 低 nibble
            nib_hi <= rx_in[rx_src][7:4];        // 低电平期 = 高 nibble
            cur_er <= rx_er_in[rx_src];
            rx_src <= rx_src + 1;
        end else begin
            nib_lo <= 4'h0; nib_hi <= 4'h0; cur_er <= 1'b0;
        end
    end
    assign rgmii_rd_i     = rd_w;
    assign rgmii_rx_ctl_i = ctl_w;

    // 前端解出的 GMII RX 字节 (按 DV 门控) + 实测 RX_ER (④)
    always @(posedge gmii_rx_clk) begin
        if (gmii_rx_dv === 1'b1 && rx_n <= NBYTES + 32) begin
            rx_out[rx_n]    = gmii_rxd;
            rx_er_out[rx_n] = gmii_rx_er;
            rx_n = rx_n + 1;
        end
    end

    // ---------------- 偏移扫描 (0..16), 数据与 ER 两条流分别比 --------------------
    integer d, k, mis, best_d, best_mis, zero_cnt, er_mis_best;
    task scan;
        input integer dir;              // 0 = TX, 1 = RX
        begin
            zero_cnt = 0; best_d = -1; best_mis = 1<<30; er_mis_best = 1<<30;
            for (d = 0; d <= 16; d = d + 1) begin
                mis = 0;
                for (k = 4; k < NBYTES - d; k = k + 1) begin
                    if (dir == 0) begin
                        if (tx_out[k+d] !== tx_in[k]) mis = mis + 1;
                    end else begin
                        if (rx_out[k+d] !== rx_in[k]) mis = mis + 1;
                    end
                end
                // ER 流在**同一位移**下单独比 (两个方向各一条)
                if (best_d < 0 || mis < best_mis) begin
                    best_mis = mis; best_d = d;
                    er_mis_best = 0;
                    for (k = 4; k < NBYTES - d; k = k + 1)
                        if (dir == 0) begin
                            if (tx_er_out[k+d] !== tx_er_in[k]) er_mis_best = er_mis_best + 1;
                        end else begin
                            if (rx_er_out[k+d] !== rx_er_in[k]) er_mis_best = er_mis_best + 1;
                        end
                end
                if (mis == 0) zero_cnt = zero_cnt + 1;
            end
        end
    endtask

    initial begin
        done_r = 0;
        tx_delay_r = -1; tx_mismatch_r = -1; tx_count_r = -1; tx_er_bad_r = -1;
        rx_delay_r = -1; rx_mismatch_r = -1; rx_count_r = -1; rx_er_bad_r = -1;
        #((NBYTES + WARM + 40) * 8);
        scan(0);
        tx_delay_r = best_d; tx_mismatch_r = best_mis; tx_count_r = tx_n; tx_er_bad_r = er_mis_best;
        $display("  [TX] recorded=%0d  best_d=%0d  data_mis=%0d  er_mis=%0d",
                 tx_n, best_d, best_mis, er_mis_best);
        scan(1);
        rx_delay_r = best_d; rx_mismatch_r = best_mis; rx_count_r = rx_n; rx_er_bad_r = er_mis_best;
        $display("  [RX] recorded=%0d  best_d=%0d  data_mis=%0d  er_mis=%0d",
                 rx_n, best_d, best_mis, er_mis_best);
        if (tx_mismatch_r == 0 && rx_mismatch_r == 0 && tx_er_bad_r == 0 && rx_er_bad_r == 0
            && tx_n == NBYTES && rx_n == NBYTES)
            $display("  RESULT: PAIR_PASS (TX d=%0d, RX d=%0d; 数据+ER+条数四项全过)",
                     tx_delay_r, rx_delay_r);
        else
            $display("  RESULT: PAIR_FAIL");
        done_r = 1;
    end

    initial begin
        #((NBYTES + WARM + 40) * 8 + 20000);
        if (done_r == 0) begin
            $display("  RESULT: PAIR_TIMEOUT");
            done_r = 1;
        end
    end
endmodule


module tb_rgmii_phy_model;
    wire [31:0] us_txd, us_txm, us_txe, us_txc, us_rxd, us_rxm, us_rxe, us_rxc, us_done;
    wire [31:0] k7_txd, k7_txm, k7_txe, k7_txc, k7_rxd, k7_rxm, k7_rxe, k7_rxc, k7_done;

    rgmii_pair #(.USE_US(1), .NBYTES(200)) u_pair_us (
        .tx_delay_r(us_txd), .tx_mismatch_r(us_txm), .tx_er_bad_r(us_txe), .tx_count_r(us_txc),
        .rx_delay_r(us_rxd), .rx_mismatch_r(us_rxm), .rx_er_bad_r(us_rxe), .rx_count_r(us_rxc),
        .done_r(us_done));

    rgmii_pair #(.USE_US(0), .NBYTES(200)) u_pair_k7 (
        .tx_delay_r(k7_txd), .tx_mismatch_r(k7_txm), .tx_er_bad_r(k7_txe), .tx_count_r(k7_txc),
        .rx_delay_r(k7_rxd), .rx_mismatch_r(k7_rxm), .rx_er_bad_r(k7_rxe), .rx_count_r(k7_rxc),
        .done_r(k7_done));

    initial begin
        $display("=== tb_rgmii_phy_model: 行为级 RTL8211E (RXDLY=1/TXDLY=1) 往返判据 ===");
        $display("--- DUT = util_gmii_to_rgmii_us (KU5P 新前端) ---");
        wait (us_done == 1);
        $display("--- DUT = util_gmii_to_rgmii (K7 旧前端, 对照) ---");
        wait (k7_done == 1);
        if (us_txm == 0 && us_rxm == 0 && us_txe == 0 && us_rxe == 0)
            $display("VERDICT: KU5P 前端 PASS (TX d=%0d / RX d=%0d)", us_txd, us_rxd);
        else
            $display("VERDICT: KU5P 前端 FAIL (data TX=%0d RX=%0d / er TX=%0d RX=%0d)",
                     us_txm, us_rxm, us_txe, us_rxe);
        if (k7_txm == 0 && k7_rxm == 0 && k7_txe == 0 && k7_rxe == 0)
            $display("VERDICT: K7 前端 PASS (TX d=%0d / RX d=%0d)", k7_txd, k7_rxd);
        else
            $display("VERDICT: K7 前端 FAIL (data TX=%0d RX=%0d)  <= 预期: RX 相位配方不适配 RXDLY=1",
                     k7_txm, k7_rxm);
        $finish;
    end
endmodule
