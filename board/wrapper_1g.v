`timescale 1ns/1ps
//=============================================================================
// wrapper_1g.v — udp_hls_10g 板上环回 bring-up 顶层 (1G RGMII)
//=============================================================================
// 功能: PC 发帧 → PHY1 RGMII → util_gmii_to_rgmii (GMII 125MHz) → mac_rx_64
//       (前导剥离 + FCS 校验剥离 → 64bit 左对齐 AXI-Stream 字流) → mac_tx_64
//       (字流 → 前导/FCS/pad/IFG 重建 GMII) → util → PHY1 → 线上 → PC 抓包对照
//       (每帧 = 原帧 + 回显两份, 回显帧除前导/FCS 重生成外逐字节相同)。
//       无 UART / 无 ARP/ICMP 应答 — 本阶段最小骨架, 环回即验证。
//
// 前端 recipe 逐字复用 (板上 7/7 PASS 的配方, 不要自创):
//   1. D:\repo\ECO\udp_hls_eco\wrapper_1g.v
//        MMCME2_BASE(50M→200M) + BUFG + IDELAYCTRL   该文件 L67-L110 逐字
//        util_gmii_to_rgmii u_rgmii 实例             该文件 L219-L239 逐字
//        异步低有效复位 (reset_n 直连异步复位)         该文件 L41/L185/L266 等
//   2. D:\repo\ECO\udp_hls_eco\util_gmii_to_rgmii.v (已复制为本目录同名文件)
//        纯 RTL 模块 (非 Xilinx IP/xci): BUFG bufmr_rgmii_rxc 对 ~phy1_rxc
//        倒相 → gmii_rx_clk; 内部 gmii_tx_clk = gmii_rx_clk (该文件 L137-L138)
//        → RX/TX 同域 (125MHz 恢复钟)。
//   3. D:\repo\ECO\udp_hls_eco\xdc\eco_rgmii_phy1.xdc → eco_rgmii_phy1.xdc
//        generated clock 引用 u_rgmii/bufmr_rgmii_rxc/O — 实例名 u_rgmii 与
//        BUFG 名 bufmr_rgmii_rxc 必须保持, 否则约束失效。
//
// 时钟: 全设计同域 gmii_clk (util 的 gmii_rx_clk 输出, 125MHz 恢复钟)。
// 复位: reset_n (KEY1, 低有效) 照抄 wrapper_1g.v 的直连异步复位用法
//       (两 MAC 均 always @(posedge clk or negedge rst_n))。
// LED (板上 8 个 LED 中仅 A23/A24/D23/C24 这 4 个有 demo 验证过的引脚映射,
//      本工程只用这 4 个; led_d4..d7 映射未验证, 不用):
//   led_d0 = RX 帧活动闪烁 (TLAST 字被消费时点亮 ~0.5s)
//   led_d1 = stat_frames[0]   (RX 完整帧计数 LSB, 每帧翻转)
//   led_d2 = stat_crc_err[0]  (FCS 错误计数 LSB, 正常恒灭)
//   led_d3 = stat_abort[0]    (TX 中止计数 LSB, 正常恒灭)
//=============================================================================

module wrapper_1g (
    input           reset_n,        // 异步复位, 低有效 (KEY1)
    input           fpga_gclk,      // 50MHz 板载晶振 (MMCM 参考 → 200M IDELAYCTRL)
    // RGMII RX from PHY (RTL8211E; PHY1 = AB2 引脚组, bank 34 LVCMOS18)
    input           phy1_rxc,       // RX 时钟 (1G 链路 = 125MHz)
    input  [3:0]    phy1_rxd,       // RX 数据 (DDR)
    input           phy1_rxctl,     // RX 控制 (DDR: 上升=RXDV, 下降=RXDV^RXER)
    // RGMII TX to PHY
    output          phy1_txc,       // TX 时钟到 PHY
    output [3:0]    phy1_txd,       // TX 数据 (DDR)
    output          phy1_txctl,     // TX 控制 (DDR: 上升=TXEN, 下降=TXEN^TXER)
    // LEDs
    output          led_d0,
    output          led_d1,
    output          led_d2,
    output          led_d3
);

    // 注意: 与 udp_hls_eco 一致, 不驱动 mdc/mdio/nrst — k720 demo 只驱动 12
    // 根 RGMII 引脚; R3 原理图的 MDC/MDIO/nRST 引脚映射 (W4/W1/V1) 与实物
    // 不符, 未用引脚靠 bitstream 的 UNUSEDPIN Pullup 浮空, 同 demo。

    // --- 200MHz IDELAYCTRL 参考钟: MMCM from 50MHz 板钟 ---
    // 逐字复用 udp_hls_eco/wrapper_1g.v L67-L103
    // 50 × 20 = 1000MHz VCO; ÷5 = 200MHz。CLKFBIN 闭环 (开环不锁)。
    wire ref200_clk, ref200_clk_raw, ref200_fb, mmcm_ref_locked;
    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKIN1_PERIOD(20.0),          // 50MHz 板载晶振
        .CLKFBOUT_MULT_F(20.0),        // VCO = 50 × 20 = 1000MHz
        .CLKFBOUT_PHASE(0.0),
        .DIVCLK_DIVIDE(1),
        .CLKOUT0_DIVIDE_F(5.0),        // 1000/5 = 200MHz
        .CLKOUT0_DUTY_CYCLE(0.5),
        .CLKOUT0_PHASE(0.0),
        .CLKOUT1_DIVIDE(1), .CLKOUT1_DUTY_CYCLE(0.5), .CLKOUT1_PHASE(0.0),
        .CLKOUT2_DIVIDE(1), .CLKOUT2_DUTY_CYCLE(0.5), .CLKOUT2_PHASE(0.0),
        .CLKOUT3_DIVIDE(1), .CLKOUT3_DUTY_CYCLE(0.5), .CLKOUT3_PHASE(0.0),
        .CLKOUT4_DIVIDE(1), .CLKOUT4_DUTY_CYCLE(0.5), .CLKOUT4_PHASE(0.0),
        .CLKOUT5_DIVIDE(1), .CLKOUT5_DUTY_CYCLE(0.5), .CLKOUT5_PHASE(0.0),
        .CLKOUT6_DIVIDE(1), .CLKOUT6_DUTY_CYCLE(0.5), .CLKOUT6_PHASE(0.0),
        .REF_JITTER1(0.010),
        .STARTUP_WAIT("FALSE")
    ) u_mmcm_ref (
        .CLKIN1(fpga_gclk),
        .CLKOUT0(ref200_clk_raw),
        .CLKOUT0B(),
        .CLKOUT1(), .CLKOUT1B(),
        .CLKOUT2(), .CLKOUT2B(),
        .CLKOUT3(), .CLKOUT3B(),
        .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
        .CLKFBOUT(ref200_fb),
        .CLKFBOUTB(),
        .CLKFBIN(ref200_fb),           // 反馈环必须闭合
        .LOCKED(mmcm_ref_locked),
        .PWRDWN(1'b0),
        .RST(!reset_n)
    );
    BUFG u_bufg_200 (.I(ref200_clk_raw), .O(ref200_clk));

    wire delay_ready;
    (* IODELAY_GROUP = "idelay" *) IDELAYCTRL u_idelayctrl (
        .RDY(delay_ready),
        .REFCLK(ref200_clk),
        .RST(1'b0)
    );

    // --- RGMII 适配: k720 demo 的 util_gmii_to_rgmii.v 逐字 ---
    // 实例化逐字复用 udp_hls_eco/wrapper_1g.v L219-L239
    // 自带 BUFG(倒相 RXC) + IDELAYE2(10) + IDDR/ODDR 链, 输出 gmii_rx_clk
    // 供全设计; speed=2'b10 (千兆), duplex=1, reset 接死 (同 demo)。
    wire gmii_clk;
    wire [7:0] e_rxd;
    wire       e_rxdv, e_rxer;
    wire [7:0] e_txd;     // mac_tx_64 输出的 GMII TX
    wire       e_txen;
    wire       e_txer;    // mac_tx_64 预留, 恒 0

    util_gmii_to_rgmii u_rgmii (
        .reset          (1'b0),
        .rgmii_td       (phy1_txd),
        .rgmii_tx_ctl   (phy1_txctl),
        .rgmii_txc      (phy1_txc),
        .rgmii_rd_i     (phy1_rxd),
        .rgmii_rx_ctl_i (phy1_rxctl),
        .gmii_rx_clk    (gmii_clk),
        .rgmii_rxc      (phy1_rxc),
        .gmii_txd       (e_txd),
        .gmii_tx_en     (e_txen),
        .gmii_tx_er     (e_txer),
        .gmii_tx_clk    (),
        .gmii_crs       (),
        .gmii_col       (),
        .gmii_rxd       (e_rxd),
        .gmii_rx_dv     (e_rxdv),
        .gmii_rx_er     (e_rxer),
        .speed_selection(2'b10),   // gigabit
        .duplex_mode    (1'b1)     // full duplex
    );

    // --- RX 流再寄存一拍 (照抄 udp_hls_eco/wrapper_1g.v L266-L270 结构) ---
    // util 输出已是寄存器, 此处再一级: 与板上验证路径的时序结构保持一致。
    reg [7:0] rx_d1;
    reg       rx_dv_d1, rx_er_d1;
    always @(posedge gmii_clk or negedge reset_n) begin
        if (!reset_n) begin rx_d1<=0; rx_dv_d1<=0; rx_er_d1<=0; end
        else begin rx_d1<=e_rxd; rx_dv_d1<=e_rxdv; rx_er_d1<=e_rxer; end
    end

    // --- 环回: mac_rx_64 → mac_tx_64 AXI-Stream 直连 ---
    // tdata/tkeep/tvalid/tready/tlast 一一对接; tuser/terr/tcrs 不接
    // (tx 无此口)。背压合同: mac_rx_64 内部 8 深 FIFO, 满则整帧原子丢弃
    // (mac_tx_64 输入 FIFO 16 深, 环回常态吞吐 1 词/周期, 不会满)。
    wire [63:0] loop_tdata;
    wire [7:0]  loop_tkeep;
    wire        loop_tvalid, loop_tready, loop_tlast;
    wire [31:0] rx_stat_frames, rx_stat_crc_err, rx_stat_drop, rx_stat_bytes;
    wire [31:0] tx_stat_frames, tx_stat_abort;

    mac_rx_64 u_mac_rx (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .gmii_rxd       (rx_d1),
        .gmii_rx_dv     (rx_dv_d1),
        .gmii_rx_er     (rx_er_d1),
        .m_axis_tdata   (loop_tdata),
        .m_axis_tkeep   (loop_tkeep),
        .m_axis_tvalid  (loop_tvalid),
        .m_axis_tready  (loop_tready),
        .m_axis_tlast   (loop_tlast),
        .m_axis_tuser   (),          // 环回不接
        .m_axis_terr    (),          // 环回不接
        .m_axis_tcrs    (),          // 环回不接
        .stat_frames    (rx_stat_frames),
        .stat_crc_err   (rx_stat_crc_err),
        .stat_drop      (rx_stat_drop),
        .stat_bytes     (rx_stat_bytes)
    );

    mac_tx_64 u_mac_tx (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .s_axis_tdata   (loop_tdata),
        .s_axis_tkeep   (loop_tkeep),
        .s_axis_tvalid  (loop_tvalid),
        .s_axis_tready  (loop_tready),
        .s_axis_tlast   (loop_tlast),
        .gmii_txd       (e_txd),
        .gmii_tx_en     (e_txen),
        .gmii_tx_er     (e_txer),
        .stat_frames    (tx_stat_frames),
        .stat_abort     (tx_stat_abort)
    );

    // --- LED 观测 ---
    // led_d0: RX 帧活动闪烁 — TLAST 字被消费时点亮 ~0.5s (125MHz ≈ 62.5M
    // 周期)。结构照抄 wrapper_1g.v L250-L257 的 UART 活动灯。
    wire rx_frame_pulse = loop_tvalid && loop_tready && loop_tlast;
    reg [26:0] rx_act_cnt;
    always @(posedge gmii_clk or negedge reset_n) begin
        if (!reset_n) rx_act_cnt <= 27'd0;
        else if (rx_frame_pulse) rx_act_cnt <= 27'd62500000;
        else if (rx_act_cnt > 0) rx_act_cnt <= rx_act_cnt - 27'd1;
    end
    assign led_d0 = (rx_act_cnt > 0);
    // 计数最低位: 每帧翻转, 直接可观 (stat_* 为 MAC 内寄存器, 同域直连)
    assign led_d1 = rx_stat_frames[0];
    assign led_d2 = rx_stat_crc_err[0];
    assign led_d3 = tx_stat_abort[0];

endmodule
