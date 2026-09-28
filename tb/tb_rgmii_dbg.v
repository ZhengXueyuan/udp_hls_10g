`timescale 1ns/1ps
// tb_rgmii_dbg.v — RGMII 前端逐沿语义轨迹 (调试用: 慢速保持图案, 肉眼可读)
// TX: gmii_txd 每 4 拍换一个字节; 打印每个 TXC 沿 +1ns 采到的 nibble 与拼回字节
// RX: PHY 侧每 8 拍发一个字节 (低 nibble 在 phy_clk 高电平期 / 高 nibble 在低电平期),
//     RXC = phy_clk 延迟 2ns; 打印前端解出的 gmii_rxd
module tb_rgmii_dbg;
    reg phy_clk = 0;
    always #4 phy_clk = ~phy_clk;
    reg rgmii_rxc = 0;
    always @(phy_clk) rgmii_rxc <= #2 phy_clk;

    reg  [7:0] gmii_txd = 8'h11;
    reg        gmii_tx_en = 1'b1, gmii_tx_er = 1'b0;
    wire [7:0] gmii_rxd;
    wire       gmii_rx_dv, gmii_rx_er, gmii_rx_clk, gmii_tx_clk, gmii_crs, gmii_col;
    wire [3:0] rgmii_td;
    wire       rgmii_tx_ctl, rgmii_txc;

    // PHY RX 侧: 每 8 个 phy 周期换一个字节; 高电平期驱动低 nibble, 低电平期驱动高 nibble
    reg  [3:0] nib_lo = 4'h5, nib_hi = 4'h7;
    wire [3:0] rd_w   = phy_clk ? nib_lo : nib_hi;
    wire       ctl_w  = 1'b1;                     // DV=1, ER=0 ⇒ CTL = 1
    reg  [3:0] rd_drv;
    reg        rx_ctl_drv;
    always @* begin rd_drv = rd_w; rx_ctl_drv = ctl_w; end

    util_gmii_to_rgmii_us u_us (
        .rgmii_rxc(rgmii_rxc), .reset(1'b0),
        .rgmii_td(rgmii_td), .rgmii_tx_ctl(rgmii_tx_ctl), .rgmii_txc(rgmii_txc),
        .rgmii_rd_i(rd_drv), .rgmii_rx_ctl_i(rx_ctl_drv),
        .gmii_rx_clk(gmii_rx_clk), .gmii_txd(gmii_txd),
        .gmii_tx_en(gmii_tx_en), .gmii_tx_er(gmii_tx_er),
        .gmii_tx_clk(gmii_tx_clk), .gmii_crs(gmii_crs), .gmii_col(gmii_col),
        .gmii_rxd(gmii_rxd), .gmii_rx_dv(gmii_rx_dv), .gmii_rx_er(gmii_rx_er),
        .speed_selection(2'b10), .duplex_mode(1'b1)
    );

    // TX 图案: 每 4 拍换一个字节
    integer tc = 0;
    always @(posedge gmii_rx_clk) begin
        tc <= tc + 1;
        case (tc / 4)
          0: gmii_txd <= 8'h11;   // 低 nibble=1 高 nibble=1
          1: gmii_txd <= 8'h2A;   // 低=A 高=2  (区分 nibble 顺序)
          2: gmii_txd <= 8'h3B;
          3: gmii_txd <= 8'h4C;
          4: gmii_txd <= 8'h5D;
          default: gmii_txd <= 8'h6E;
        endcase
    end

    // PHY RX 图案: 每 8 拍换字节 (低/高 nibble 不同 ⇒ 能判 nibble 顺序)
    integer rc = 0;
    always @(posedge phy_clk) begin
        rc <= rc + 1;
        case (rc / 8)
          0: begin nib_lo <= 4'h5; nib_hi <= 4'h7; end   // 期望解出 0x75
          1: begin nib_lo <= 4'hA; nib_hi <= 4'h2; end   // 0x2A
          2: begin nib_lo <= 4'h3; nib_hi <= 4'hC; end   // 0xC3
          default: begin nib_lo <= 4'hC; nib_hi <= 4'h3; end // 0x3C
        endcase
    end

    reg [3:0] low_s = 0, high_s = 0;
    reg [7:0] tx_byte = 0;
    always @(posedge rgmii_txc) begin #1;
        low_s = rgmii_td;
        $display("%6t TXC^ td=%h", $time, rgmii_td);
    end
    always @(negedge rgmii_txc) begin #1;
        high_s = rgmii_td;
        tx_byte = {high_s, low_s};
        $display("%6t TXCv td=%h  (拼回字节=%h)", $time, rgmii_td, tx_byte);
    end

    integer rxc_n = 0;
    always @(posedge gmii_rx_clk) begin
        rxc_n = rxc_n + 1;
        if (rxc_n < 20)
            $display("%6t gmii_clk^ gmii_rxd=%h dv=%b er=%b (PHY 发 nib_lo=%h nib_hi=%h)",
                     $time, gmii_rxd, gmii_rx_dv, gmii_rx_er, nib_lo, nib_hi);
    end

    initial begin
        $display("=== tb_rgmii_dbg (US+ 前端) ===");
        $display("-- TX: gmii_txd 11/2A/3B/4C/5D/6E 各 4 拍; 看 拼回字节 是否等于 4 拍前的输入 --");
        $display("-- RX: PHY 发 0x75/0x2A/0xC3/0x3C 各 8 拍; 看 gmii_rxd 是否等于 PHY 刚发的字节 --");
        #900;
        $display("=== done ===");
        $finish;
    end
endmodule
