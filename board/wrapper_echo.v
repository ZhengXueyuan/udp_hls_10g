`timescale 1ns/1ps
//=============================================================================
// wrapper_echo.v — udp_hls_10g 板上 UDP echo 顶层 (1G RGMII)
//=============================================================================
// 功能: PC 发 UDP 帧 → PHY1 RGMII → util_gmii_to_rgmii (GMII 125MHz) →
//       mac_rx_64 (前导剥离 + FCS 校验剥离 → 64bit 左对齐字流) → udp_rx
//       (IP/UDP 头解析 + 过滤: 组播 or 单播 192.168.100.2 / 8080) →
//       udp_echo (整帧判定后入 FIFO, 坏帧回卷) → udp_tx_frame (组 UDP/IP/
//       以太网头, UDP 校验和) → mac_tx_64 (前导/FCS/pad/IFG 重建) → util →
//       PHY1 → PC (回显帧 dst = 原帧 src, 内容为载荷, 端口 8080)。
//       无 UART / 无 ARP/ICMP 应答 — 组播 (cfg_multi_en) 时 PC 发组播
//       无需 ARP 即可直达板子。
//
// 前端 recipe 逐字复用 wrapper_1g.v (板上 PASS 配方):
//   1. MMCME2_BASE(50M→200M) + BUFG + IDELAYCTRL   (本文件, 照抄)
//   2. util_gmii_to_rgmii u_rgmii 实例             (实例名/参数逐行一致,
//       generated clock 引用 u_rgmii/bufmr_rgmii_rxc/O — 名字不能改)
//   3. eco_rgmii_phy1.xdc 原样复用                  (顶层端口名必须相同)
//   4. RX 侧 util 输出再寄存一拍                    (照抄)
//
// 时钟: 全设计同域 gmii_clk (util 的 gmii_rx_clk 输出, 125MHz 恢复钟)。
// 复位: reset_n (KEY1, 低有效) 直连异步复位 (同 wrapper_1g.v)。
// LED (引脚与 wrapper_1g.v 相同, A23/A24/D23/C24):
//   led_d0 = mac_rx_64.stat_frames[0]   (RX 完整帧计数 LSB, 每帧翻转)
//   led_d1 = udp_rx.stat_pass[0]        (UDP 匹配且 FCS 好计数 LSB)
//   led_d2 = udp_echo.stat_echo[0]      (回发帧计数 LSB)
//   led_d3 = udp_echo.stat_drop_crc[0]  (回卷丢弃计数 LSB, 正常恒灭)
//=============================================================================

module wrapper_echo (
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

    // 注意: 与 wrapper_1g.v 一致, 不驱动 mdc/mdio/nrst — k720 demo 只驱动 12
    // 根 RGMII 引脚; 未用引脚靠 bitstream 的 UNUSEDPIN Pullup 浮空, 同 demo。

    // --- 200MHz IDELAYCTRL 参考钟: MMCM from 50MHz 板钟 ---
    // 逐字照抄 wrapper_1g.v: 50 × 20 = 1000MHz VCO; ÷5 = 200MHz。
    // CLKFBIN 闭环 (开环不锁)。
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
    // 实例化与 wrapper_1g.v 逐行一致 (实例名 u_rgmii 必须保持 —
    // eco_rgmii_phy1.xdc 的 generated clock 引用 u_rgmii/bufmr_rgmii_rxc/O)。
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

    // --- RX 流再寄存一拍 (照抄 wrapper_1g.v 结构) ---
    // util 输出已是寄存器, 此处再一级: 与板上验证路径的时序结构保持一致。
    reg [7:0] rx_d1;
    reg       rx_dv_d1, rx_er_d1;
    always @(posedge gmii_clk or negedge reset_n) begin
        if (!reset_n) begin rx_d1<=0; rx_dv_d1<=0; rx_er_d1<=0; end
        else begin rx_d1<=e_rxd; rx_dv_d1<=e_rxdv; rx_er_d1<=e_rxer; end
    end

    // --- 数据面: mac_rx_64 → udp_rx → udp_echo → udp_tx_frame → mac_tx_64 ---
    // 级间接线: tdata/tkeep/tvalid/tready/tlast 一一对接; tuser(SOP)/tcrs/terr
    // 由 mac_rx_64 直连 udp_rx; udp_rx 的 fend/ferr/meta_* 接 udp_echo 判定;
    // echo 的 tx_cfg_dst_* (原帧 src, meta_valid 拍锁存) 接 tx 的 cfg_dst_*。
    // 背压合同: mac_rx_64 内部 8 深 FIFO, 满则整帧原子丢弃 (stat_drop 计数);
    // udp_echo frame_fifo 2048 深, udp_tx_frame 256 深, 常态回显吞吐足够。
    wire [63:0] rx_tdata;
    wire [7:0]  rx_tkeep;
    wire        rx_tvalid, rx_tready, rx_tlast, rx_tuser, rx_tcrs, rx_terr;
    wire [31:0] rx_stat_frames, rx_stat_crc_err, rx_stat_drop, rx_stat_bytes;

    wire [63:0] pay_tdata;
    wire [7:0]  pay_tkeep;
    wire        pay_tvalid, pay_tready, pay_tlast;
    wire [1:0]  pay_tuser;
    wire        pay_fend, pay_ferr;
    wire        pay_meta_valid;
    wire [47:0] pay_meta_src_mac;
    wire [31:0] pay_meta_src_ip;
    wire [15:0] pay_meta_src_port;
    wire [15:0] pay_meta_len;
    wire [31:0] pay_stat_pass, pay_stat_drop_nonmatch, pay_stat_drop_ipcsum;
    wire [31:0] pay_stat_drop_crc, pay_stat_bytes;

    wire [63:0] eco_tdata;
    wire [7:0]  eco_tkeep;
    wire        eco_tvalid, eco_tready, eco_tlast;
    wire [47:0] eco_tx_cfg_dst_mac;
    wire [31:0] eco_tx_cfg_dst_ip;
    wire [15:0] eco_tx_cfg_dst_port;
    wire [31:0] eco_stat_echo, eco_stat_drop_crc;

    wire [63:0] tx_tdata;
    wire [7:0]  tx_tkeep;
    wire        tx_tvalid, tx_tready, tx_tlast;
    wire [31:0] tx_stat_frames, tx_stat_abort;

    mac_rx_64 u_mac_rx (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .gmii_rxd       (rx_d1),
        .gmii_rx_dv     (rx_dv_d1),
        .gmii_rx_er     (rx_er_d1),
        .m_axis_tdata   (rx_tdata),
        .m_axis_tkeep   (rx_tkeep),
        .m_axis_tvalid  (rx_tvalid),
        .m_axis_tready  (rx_tready),
        .m_axis_tlast   (rx_tlast),
        .m_axis_tuser   (rx_tuser),
        .m_axis_terr    (rx_terr),
        .m_axis_tcrs    (rx_tcrs),
        .stat_frames    (rx_stat_frames),
        .stat_crc_err   (rx_stat_crc_err),
        .stat_drop      (rx_stat_drop),
        .stat_bytes     (rx_stat_bytes)
    );

    udp_rx u_udp_rx (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .s_axis_tdata   (rx_tdata),
        .s_axis_tkeep   (rx_tkeep),
        .s_axis_tvalid  (rx_tvalid),
        .s_axis_tready  (rx_tready),
        .s_axis_tlast   (rx_tlast),
        .s_axis_tuser   (rx_tuser),
        .s_axis_tcrs    (rx_tcrs),
        .s_axis_terr    (rx_terr),
        .m_axis_tdata   (pay_tdata),
        .m_axis_tkeep   (pay_tkeep),
        .m_axis_tvalid  (pay_tvalid),
        .m_axis_tready  (pay_tready),
        .m_axis_tlast   (pay_tlast),
        .m_axis_tuser   (pay_tuser),
        .fend           (pay_fend),
        .ferr           (pay_ferr),
        .meta_valid     (pay_meta_valid),
        .meta_src_mac   (pay_meta_src_mac),
        .meta_src_ip    (pay_meta_src_ip),
        .meta_src_port  (pay_meta_src_port),
        .meta_len       (pay_meta_len),
        // 组播放行: PC 发组播 (dst_ip[31:28]==4'hE) 即接受, 无需 ARP
        .cfg_dst_ip     (32'hC0A86402),   // 192.168.100.2 (单播)
        .cfg_multi_en   (1'b1),           // 组播不检查 dst_ip
        .cfg_port0      (16'h1F90),       // 8080
        .cfg_port1      (16'h0000),
        .cfg_port2      (16'h0000),
        .cfg_port3      (16'h0000),
        .cfg_port_any   (1'b0),
        .stat_pass          (pay_stat_pass),
        .stat_drop_nonmatch (pay_stat_drop_nonmatch),
        .stat_drop_ipcsum   (pay_stat_drop_ipcsum),
        .stat_drop_crc      (pay_stat_drop_crc),
        .stat_bytes         (pay_stat_bytes)
    );

    udp_echo u_udp_echo (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .s_axis_tdata   (pay_tdata),
        .s_axis_tkeep   (pay_tkeep),
        .s_axis_tvalid  (pay_tvalid),
        .s_axis_tready  (pay_tready),
        .s_axis_tlast   (pay_tlast),
        .s_axis_tuser   (pay_tuser),
        .fend           (pay_fend),
        .ferr           (pay_ferr),
        .meta_valid     (pay_meta_valid),
        .meta_src_mac   (pay_meta_src_mac),
        .meta_src_ip    (pay_meta_src_ip),
        .meta_src_port  (pay_meta_src_port),
        .meta_len       (pay_meta_len),
        .cfg_my_mac     (48'h000A3501FEC1),  // 00:0A:35:01:FE:C1
        .cfg_my_ip      (32'hC0A86402),      // 192.168.100.2
        .cfg_my_port    (16'h1F90),          // 8080
        .m_axis_tdata   (eco_tdata),
        .m_axis_tkeep   (eco_tkeep),
        .m_axis_tvalid  (eco_tvalid),
        .m_axis_tready  (eco_tready),
        .m_axis_tlast   (eco_tlast),
        .tx_cfg_dst_mac (eco_tx_cfg_dst_mac),
        .tx_cfg_dst_ip  (eco_tx_cfg_dst_ip),
        .tx_cfg_dst_port(eco_tx_cfg_dst_port),
        .stat_echo      (eco_stat_echo),
        .stat_drop_crc  (eco_stat_drop_crc)
    );

    udp_tx_frame u_udp_tx (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .s_axis_tdata   (eco_tdata),
        .s_axis_tkeep   (eco_tkeep),
        .s_axis_tvalid  (eco_tvalid),
        .s_axis_tready  (eco_tready),
        .s_axis_tlast   (eco_tlast),
        .cfg_src_mac    (48'h000A3501FEC1),  // 00:0A:35:01:FE:C1
        .cfg_dst_mac    (eco_tx_cfg_dst_mac),
        .cfg_src_ip     (32'hC0A86402),      // 192.168.100.2
        .cfg_dst_ip     (eco_tx_cfg_dst_ip),
        .cfg_src_port   (16'h1F90),          // 8080
        .cfg_dst_port   (eco_tx_cfg_dst_port),
        .cfg_csum_en    (1'b1),              // 算 UDP 校验和
        .m_axis_tdata   (tx_tdata),
        .m_axis_tkeep   (tx_tkeep),
        .m_axis_tvalid  (tx_tvalid),
        .m_axis_tready  (tx_tready),
        .m_axis_tlast   (tx_tlast),
        .stat_frames    (tx_stat_frames),
        .stat_bytes     (tx_stat_bytes)
    );

    mac_tx_64 u_mac_tx (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .s_axis_tdata   (tx_tdata),
        .s_axis_tkeep   (tx_tkeep),
        .s_axis_tvalid  (tx_tvalid),
        .s_axis_tready  (tx_tready),
        .s_axis_tlast   (tx_tlast),
        .gmii_txd       (e_txd),
        .gmii_tx_en     (e_txen),
        .gmii_tx_er     (e_txer),
        .stat_frames    (tx_stat_frames),
        .stat_abort     (tx_stat_abort)
    );

    // --- LED 观测 (引脚与 wrapper_1g.v 相同; 计数 LSB 直接可观) ---
    assign led_d0 = rx_stat_frames[0];     // RX 帧活动 (每帧翻转)
    assign led_d1 = pay_stat_pass[0];      // UDP 匹配且 FCS 好
    assign led_d2 = eco_stat_echo[0];      // 回发帧计数
    assign led_d3 = eco_stat_drop_crc[0];  // 回卷丢弃 (正常恒灭)

endmodule
