`timescale 1ns/1ps
//=============================================================================
// tb_p5e_udp_wrapper — P5e-T3/T5: UDP app **真 wrapper 全链门** (工程坑 8)
//=============================================================================
// 为什么必须另开一门: 单元门 (tb_app_udp) 自己搭链 —— wrapper 的 APP_MODE 接线
// 错 (meta_* 忘接 / app_udp_tx_* 忘接 / app_rx_tready 忘接 / splitter cfg 忘配)
// 在单元门里完全隐身 (P5a W1 与 T2 的 implicit 事故都是这一类)。
//
// 注入边界 (与 T2 的 wrapper 门一致的手法): 用 force 驱动 wrapper 内部 **GMII
// RX 侧** (`u_dut.e_rxd/e_rxdv/e_rxer` = util_gmii_to_rgmii 的 GMII 输出口),
// 于是真实走完 mac_rx_64 → rx_classify → u_udp_split → app RX + meta_* →
// u_udp_tx_cfg (learn-on-RX) → u_udp_tx → u_tx_udp_arb → u_tx_arb → mac_tx_64
// → **wrapper 内部 GMII TX** (u_dut.e_txd/e_txen, 逐字节解码)。
// 未被覆盖的只有 RGMII DDR 转换器本身 (util_gmii_to_rgmii, 本次未改动;
// 其板级正确性属 P1/P4 既有门的职责)。
//
// 判据 (全部只看 wrapper 内部信号/GMII, 无层次 force 参与判据):
//   ① 默认不发送: 注入前 app_udp_tx_ready = 0 且 GMII 上零 UDP 帧
//   ② RX 全链: 注入 1 帧 (UDP/8081 → 本板, 载荷 = RTL 图案) ⇒ app 侧
//      stat_rx_frames = 1 / stat_rx_bytes = 1472 / **stat_mismatch = 0**
//   ③ learn-on-RX: 注入前 peer_v = 0, 注入后 = 1 且 o_dst_mac/o_dst_ip = 注入帧的 src
//   ④ TX 全链: GMII 上出现 UDP 帧, MAC 长 1514, dst = 学到的 peer, src = 板 MAC,
//      IPv4/UDP 头 + IP 校验和 + UDP 校验和 (伪头+头+载荷) 正确, 载荷逐字节
//   ⑤ 共存: app_pattern 的 TCP fast 帧照常上线 (共享 u_tx_arb) 且 mac_tx 无中止
//   ⑥ **RXP_DIAG v4 状态行字段的正的存在性证明** (2026-09-27, ISSUE_RX_BYTE_
//      CORRUPTION §16.7): 再注入**第 2 帧** (载荷 = 图案流续流 + 首字节翻 0x40,
//      FCS 之后仍正确) ⇒ app 恰 1 字节失配; 断言 **NE=1 / NR=1 / MR=1 / EN=1 /
//      EO=0 / QA={帧号 1, 该字节}** 一路穿过 wrapper 到 **app_status_uart 的字段
//      入口** (`u_dut.u_app_status.v4_ne`), 并与 v2 的 OZ 桶 / app 的 stat_mismatch
//      互证; 同相断言其余 6 个 A 部字段仍为 0。为什么需要它: 字段曾经**一个都没接**
//      ⇒ 综合钳 0 ⇒ "全 0"与"从未触发"读数上不可区分; 仅"门绿+无告警"不能排除。
//      (不逐字符解码 UART 的理由见 ⑥ 段注释: 板级 9600 波特一行 916x10x13021 ~ 1.19e8 拍。)
//   ⑧ **RXP_DIAG v5 状态行字段的正的存在性证明** (2026-09-27, ISSUE_RX_BYTE_
//      CORRUPTION §14.6/§18.8): 再注入 1 帧 (载荷 1472B, **帧内偏移 100** 的字节
//      翻 0x40, 翻转在算 FCS 之前 ⇒ 帧仍好) ⇒ 断言一路穿过 wrapper 到
//      `u_dut.u_app_status.v5_*` (状态行模块入口): VZ=1 / DO=100 / DV%1472=100 /
//      DG=DE 的独立复算值 / DM 增量=1 / DV != DO; B 部 PS 增量=1 且 == app 的 URF
//      增量 / SB 增量=1472 / NM=IC=DC 增量=0。同 ⑥ 的理由: v5 字段若没接 = 综合
//      钳 0 = 假 0, "门绿 + 无告警"排除不了。
//   +NOUDP 对照 (xsim -testplusarg NOUDP): 不注入 ⇒ 全程零 UDP 帧 (⑥/⑧ 不执行)
//=============================================================================
module tb_p5e_udp_wrapper;
    // v4-⑦ 的 A 部期望值 (先占位跑一轮取实测, 再冻结成具体值)
    localparam [15:0] CN_EXP_VAL = 16'd15;
    localparam [15:0] WF_EXP_VAL = 16'd400;   // 实测 (见 7b 段注释: 慢消费者注满 512 字缓冲后吞掉的字数)
    localparam [15:0] RL_EXP_VAL = 16'd27;    // 实测 (CN 15 + RD 2 + WF 相被废帧若干)
    localparam [31:0] TB_ISS   = 32'h12345678;
    localparam [31:0] ISN0     = TB_ISS + 32'd1;
    localparam [31:0] PEER_ISN = 32'h20000000;

    // UDP app 目标 (镜像 wrapper 的静态 cfg)
    localparam [47:0] PEER_MAC  = 48'h112233445566;   // 注入帧的 src mac
    localparam [31:0] PEER_IP   = 32'hC0A86401;       // 192.168.100.1
    localparam [15:0] PEER_PORT = 16'h3039;
    localparam [47:0] BOARD_MAC = 48'h000A3501FEC0;
    localparam [31:0] BOARD_IP  = 32'hC0A86402;       // 192.168.100.2
    localparam [15:0] APP_PORT  = 16'h1F91;           // 8081
    localparam integer PLEN     = 1472;               // 注入帧载荷

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

    reg no_udp;
    initial if ($test$plusargs("NOUDP")) no_udp = 1'b1; else no_udp = 1'b0;
    // v4-⑦ 用: 事件条目期望 (got 字节) / 帧 0 的 app 帧号 / B 部基线
    reg  [7:0]  qex [0:9];
    reg  [15:0] frm_base;
    integer     ne0, nr0, mr0;
    // v5-⑧ 用: A/B 两部字段的基线 + 写入口序号的静止采样
    // (必须声明在 initial 之前 —— xvlog 先声明后用)
    integer     v5_dm0, v5_ps0, v5_sb0, v5_nm0, v5_ic0, v5_dc0, v5_uf0, v5_mm0;
    integer     v5_c0, v5_c1;
    integer     v6_cm0, v6_c0, v6_c1, v6_uf0;   // phase 9 (RXP_DIAG v6)
    // v5-⑧ 的**冻结期望值** = 本 wrapper 跑量里**第一个**失配 (相 ⑥ 造成):
    //   帧 2 载荷 = 图案流续流 (bf_base=1472), 只把载荷第 0 字节翻 0x40 (FCS 之前翻)
    //   ⇒ 写入口序号 1472 / 帧内偏移 0 / DG = pattern[1472]^0x40 = 0xA8 / DE = pattern[1472] = 0xE8
    //   (与 §17.5 记的 v4 实测 QA=0x0001A8 同源: 0xA8 = 0xE8 ^ 0x40)
    localparam [31:0] DV_EXP_VAL = 32'd1472;
    localparam [15:0] DO_EXP_VAL = 16'd0;
    localparam [7:0]  DG_EXP_VAL = 8'hA8;
    localparam [7:0]  DE_EXP_VAL = 8'hE8;
    integer errs;
    task chk;
        input          cond;
        input [8*80:1] msg;
        begin
            if (!cond) begin errs = errs + 1; $display("  [FAIL] %0s", msg); end
        end
    endtask

    //=========================================================================
    // RX 注入: GMII 字节流 (前导 8B + MAC 帧 + FCS 4B) → force e_rxd/e_rxdv/e_rxer
    //=========================================================================
    // CRC-32 (反射 0xEDB88320 / init 0xFFFFFFFF); 自检见 initial 段
    function [31:0] crc32_byte;
        input [31:0] c;
        input [7:0]  d;
        integer i;
        reg [31:0] x;
        begin
            x = c ^ {24'b0, d};
            for (i = 0; i < 8; i = i + 1)
                x = x[0] ? ((x >> 1) ^ 32'hEDB88320) : (x >> 1);
            crc32_byte = x;
        end
    endfunction

    // 图案 (xorshift64 先取后推进; 与 app_udp_pattern / peer.cpp 同款)
    function [63:0] xs_next;
        input [63:0] s;
        reg   [63:0] t;
        begin
            t = s ^ (s << 13);
            t = t ^ (t >> 7);
            t = t ^ (t << 17);
            xs_next = t;
        end
    endfunction

    localparam integer RLEN = 8 + 14 + 20 + 8 + PLEN + 4;   // 注入总字节数 (最大载荷时)
    reg  [7:0] rbuf [0:RLEN-1];
    reg  [7:0] pay  [0:PLEN-1];       // 载荷图案 (独立算一遍, 供 TX 侧判据)
    reg [63:0] glfsr;
    // v4 相 (⑥/⑦) 用: 载荷图案起点 + 长度 + 长度字段偏移 + 首字节翻转 + FCS 破坏。
    // **默认值 = 既有行为逐位不变** (bf_plen=PLEN / 其余 0)。
    reg [31:0] bf_base;               // 0 = 自 SEED 起 (既有); PLEN = 图案流续流第 2 帧
    reg [31:0] bf_plen;               // 本次注入的载荷字节数 (0 = 0 长数据报)
    reg [31:0] bf_udplen_ex;          // UDP 长度字段的虚增 (残帧: 声明 > 实际)
    reg        bf_corrupt;            // 1 = 翻转载荷第 0 字节 (造 offset-0 失配)
    reg [7:0]  bf_mask;               // 上述翻转用的掩码 (默认 0x40 = ⑥ 相)
    reg [11:0] bf_coff;               // v5 相 (⑧): 翻转的**载荷内偏移** (默认 0 = 既有行为)
    reg        bf_badfcs;             // 1 = 算完 FCS 后再翻它一字节 (造坏 FCS)
    reg [15:0] bf_rlen;               // 本次注入的总字节数 (前导 8 + 帧 + FCS 4)
    integer    ri;
    task build_rx_frame;
        reg [31:0] c; reg [63:0] s;
        integer k;
        begin
            // 载荷图案 (自 bf_base 处的**图案流续流**; bf_base=0 ⇒ 与既有逐位相同)
            s = 64'h9E3779B97F4A7C15;
            for (k = 0; k < bf_base; k = k + 1) s = xs_next(s);
            for (k = 0; k < bf_plen; k = k + 1) begin
                pay[k] = s[31:24];
                s = xs_next(s);
            end
            // 前导
            for (k = 0; k < 7; k = k + 1) rbuf[k] = 8'h55;
            rbuf[7] = 8'hD5;
            // MAC + IPv4 + UDP 头
            rbuf[8+0]  = BOARD_MAC[47:40]; rbuf[8+1]  = BOARD_MAC[39:32];
            rbuf[8+2]  = BOARD_MAC[31:24]; rbuf[8+3]  = BOARD_MAC[23:16];
            rbuf[8+4]  = BOARD_MAC[15:8];  rbuf[8+5]  = BOARD_MAC[7:0];
            rbuf[8+6]  = PEER_MAC[47:40];  rbuf[8+7]  = PEER_MAC[39:32];
            rbuf[8+8]  = PEER_MAC[31:24];  rbuf[8+9]  = PEER_MAC[23:16];
            rbuf[8+10] = PEER_MAC[15:8];   rbuf[8+11] = PEER_MAC[7:0];
            rbuf[8+12] = 8'h08; rbuf[8+13] = 8'h00;            // ethertype IPv4
            rbuf[8+14] = 8'h45; rbuf[8+15] = 8'h00;            // ver/ihl, dscp
            rbuf[8+16] = ((bf_plen+28) >> 8) & 8'hFF;
            rbuf[8+17] = (bf_plen+28) & 8'hFF;
            rbuf[8+18] = 8'h12; rbuf[8+19] = 8'h34;            // id
            rbuf[8+20] = 8'h40; rbuf[8+21] = 8'h00;            // flags/frag
            rbuf[8+22] = 8'd64;  rbuf[8+23] = 8'h11;           // ttl, proto=UDP
            rbuf[8+24] = 8'h00;  rbuf[8+25] = 8'h00;           // ip csum 占位
            rbuf[8+26] = PEER_IP[31:24];  rbuf[8+27] = PEER_IP[23:16];
            rbuf[8+28] = PEER_IP[15:8];   rbuf[8+29] = PEER_IP[7:0];
            rbuf[8+30] = BOARD_IP[31:24]; rbuf[8+31] = BOARD_IP[23:16];
            rbuf[8+32] = BOARD_IP[15:8];  rbuf[8+33] = BOARD_IP[7:0];
            // IP 校验和
            c = 32'd0;
            for (k = 0; k < 10; k = k + 1)
                c = c + {16'b0, rbuf[8+14+2*k], rbuf[8+15+2*k]};
            c = (c & 32'hFFFF) + (c >> 16);
            c = (c & 32'hFFFF) + (c >> 16);
            c = ~c;
            // IP 校验和是**网络序 (大端)** 的 16 位字段: 高字节在前
            rbuf[8+24] = c[15:8]; rbuf[8+25] = c[7:0];
            // UDP 头
            rbuf[8+34] = PEER_PORT[15:8];  rbuf[8+35] = PEER_PORT[7:0];
            rbuf[8+36] = APP_PORT[15:8];   rbuf[8+37] = APP_PORT[7:0];
            // UDP 长度字段 (= 8 + 载荷 + bf_udplen_ex; 残帧相把 bf_udplen_ex 设成
            // 正数 ⇒ 声明 > 实际, udp_rx 判长度不符 ⇒ 末尾字不交付、无 TLAST ⇒ 残帧)
            rbuf[8+38] = ((bf_plen+8+bf_udplen_ex) >> 8) & 8'hFF;
            rbuf[8+39] = (bf_plen+8+bf_udplen_ex) & 8'hFF;
            rbuf[8+40] = 8'h00; rbuf[8+41] = 8'h00;            // udp csum (板侧不判 RX)
            // 载荷
            for (k = 0; k < bf_plen; k = k + 1) rbuf[8+42+k] = pay[k];
            // v4 相 (⑥): 只翻**载荷第 0 字节**。必须在下面算 FCS **之前**翻 ⇒
            // 帧的 FCS 仍正确 (坏值出现在 CRC 算完之后 = 板级的 "FCS 盲区" 场景)。
            // v5 相 (⑧): 翻转位置由 bf_coff 选 (默认 0 ⇒ 与 ⑥/⑦ 逐位相同)。
            if (bf_corrupt) rbuf[8+42+bf_coff] = pay[bf_coff] ^ bf_mask;
            // FCS: 覆盖 MAC 帧; 线上小端 (LSB 字节先发)
            c = 32'hFFFFFFFF;
            for (k = 8; k < 8+14+20+8+bf_plen; k = k + 1)
                c = crc32_byte(c, rbuf[k]);
            c = ~c;
            bf_rlen = 8 + 14 + 20 + 8 + bf_plen + 4;     // 前导 + 帧 + FCS
            rbuf[8+14+20+8+bf_plen+0] = c[7:0];
            rbuf[8+14+20+8+bf_plen+1] = c[15:8];
            rbuf[8+14+20+8+bf_plen+2] = c[23:16];
            rbuf[8+14+20+8+bf_plen+3] = c[31:24];
            // 坏 FCS 相: 在算完之后翻 FCS 的最低字节 (mac_rx 的 CRC 检查必失败
            // ⇒ tcrs=0 ⇒ udp_rx 判 ferr; 帧身本身仍是合法长度)
            if (bf_badfcs) rbuf[8+14+20+8+bf_plen] = rbuf[8+14+20+8+bf_plen] ^ 8'h01;
        end
    endtask

    // 注入控制 (negedge 驱动 ⇒ 远离 posedge 采样, 坑 17)
    reg  [15:0] inj_i;
    reg         inj_on;
    // 末字节被采样的**同一拍**就必须拉低 dv (帧尾多挂 dv=1 会让那些字节进帧身,
    // FCS 校验位错位 ⇒ stat_crc_err; 实测: 多挂 1 拍 ⇒ mac_rx bytes=1519 且 crc_err)
    wire        inj_dv = inj_on && (inj_i < bf_rlen);
    wire [7:0]  inj_byte = (inj_i < bf_rlen) ? rbuf[inj_i] : 8'h00;
    // v4-⑦ 用: 注入一个已 build 好的帧 + 帧后 IFG (idle 拍 ≥12)
    task inj_frame;
        begin
            inj_i  = 0;
            inj_on = 1'b1;
            repeat (bf_rlen + 20) @(posedge u_dut.gmii_clk);
            inj_on = 1'b0;
        end
    endtask
    // v4-⑦ 用: **慢消费者注入** —— force app 的 rx_tready = 0 ⇒ app 完全不接受
    // ⇒ udp_split 的描述符 FIFO / 载荷缓冲积压 (V5/V8 那两套"消费者跟不上"的
    // 等效物; wrapper 里线上只有 1 字节/拍 ⇒ 无法靠"灌得更快"复现, 只能把消费者
    // 变慢)。sc_en=0 时 release ⇒ DUT 逐位不受影响 (其余相位 sc_en 恒 0)。
    // ⚠️ 在 negedge 落地 (远离 posedge 采样, 坑 17); 只在 sc_en 变化时动作。
    reg sc_en   = 1'b0;
    reg sc_en_r = 1'b0;
    always @(negedge u_dut.gmii_clk) begin
        if (sc_en !== sc_en_r) begin
            if (sc_en) force   u_dut.u_app_udp.rx_tready = 1'b0;
            else       release u_dut.u_app_udp.rx_tready;
            sc_en_r <= sc_en;
        end
    end
    always @(negedge u_dut.gmii_clk) begin
        force u_dut.e_rxd   = inj_byte;
        force u_dut.e_rxdv  = inj_dv;
        force u_dut.e_rxer  = 1'b0;
    end
    always @(posedge u_dut.gmii_clk) begin
        if (inj_on && (inj_i < RLEN)) inj_i <= inj_i + 16'd1;
    end

    //=========================================================================
    // 内部 GMII TX 捕获 + 帧解码 (前导 8B 后是 MAC 帧; 末 4B = mac_tx_64 的 FCS)
    //=========================================================================
    reg [7:0] gb [0:4095];
    integer   gcnt, gnfr, gufr, tcp_fr, i2, uflen;
    reg [7:0] uf [0:2047];
    always @(posedge u_dut.gmii_clk) begin
        if (u_dut.e_txen) begin
            if (gcnt < 4090) gb[gcnt] = u_dut.e_txd;
            gcnt = gcnt + 1;
        end else if (gcnt != 0) begin
            gnfr = gnfr + 1;
            if ((gcnt >= 8 + 14) && (gb[8+12] == 8'h08) && (gb[8+13] == 8'h00) &&
                (gb[8+23] == 8'h11)) begin
                if (gufr == 0) begin
                    uflen = gcnt - 8 - 4;
                    for (i2 = 0; i2 < 2048; i2 = i2 + 1)
                        uf[i2] = (i2 < uflen) ? gb[8+i2] : 8'h00;
                end
                gufr = gufr + 1;
                $display("    [gmii] UDP 帧 #%0d: %0d 字节 (MAC 长 %0d)", gufr, gcnt, gcnt-12);
            end else if (gcnt > 12) tcp_fr = tcp_fr + 1;
            gcnt = 0;
        end
    end

    // 校验和辅助
    reg [31:0] csum_acc;
    task csum_add;
        input integer off; input integer nb;
        integer i;
        begin
            for (i = 0; i + 1 < nb; i = i + 2)
                csum_acc = csum_acc + {uf[off+i], uf[off+i+1]};
            if (nb % 2) csum_acc = csum_acc + {uf[off+nb-1], 8'h00};
        end
    endtask
    function [15:0] fold32;
        input [31:0] s;
        reg [16:0] t;
        begin
            t = s[15:0] + s[31:16];
            t = t[15:0] + t[16];
            fold32 = t[15:0];
        end
    endfunction

    //=========================================================================
    // 主时间线
    //=========================================================================
    integer i;
    reg [31:0] crc_chk;
    initial begin
        errs = 0; gcnt = 0; gnfr = 0; gufr = 0; tcp_fr = 0; uflen = 0;
        inj_i = 0; inj_on = 1'b0;
        fpga_gclk = 0; phy1_rxc = 0; reset_n = 0;
        phy1_rxd = 4'h0; phy1_rxctl = 1'b0;
        // 第 1 帧: 自 SEED 起的干净图案, 长度/长度字段/FCS 全默认
        bf_base = 32'd0; bf_corrupt = 1'b0; bf_mask = 8'h40; bf_coff = 12'd0;
        bf_plen = PLEN[31:0]; bf_udplen_ex = 32'd0; bf_badfcs = 1'b0;
        build_rx_frame;
        // ---- CRC 自检 (标准 check 值: crc32("123456789") = 0xCBF43926) ----
        crc_chk = 32'hFFFFFFFF;
        crc_chk = crc32_byte(crc_chk, 8'h31); crc_chk = crc32_byte(crc_chk, 8'h32);
        crc_chk = crc32_byte(crc_chk, 8'h33); crc_chk = crc32_byte(crc_chk, 8'h34);
        crc_chk = crc32_byte(crc_chk, 8'h35); crc_chk = crc32_byte(crc_chk, 8'h36);
        crc_chk = crc32_byte(crc_chk, 8'h37); crc_chk = crc32_byte(crc_chk, 8'h38);
        crc_chk = crc32_byte(crc_chk, 8'h39);
        crc_chk = ~crc_chk;
        $display("  [dbg] CRC32 self-test = %08h (expect CBF43926)", crc_chk);
        chk(crc_chk === 32'hCBF43926, "TB CRC32 实现 = 标准 CRC-32 (自检)");

        #400; reset_n = 1;
        repeat (4000) @(posedge u_dut.gmii_clk);      // 等 MMCM/复位稳定

        // ---- 预置 TCP 连接 (照抄 T2/T5 手法, 让 TCP fast 路径同时跑) ----
        u_dut.u_tcb.rcv_nxt_r[0] = PEER_ISN + 32'd1;
        u_dut.u_tcb.snd_nxt_r[0] = ISN0;
        u_dut.u_tcb.snd_una_r[0] = ISN0;
        u_dut.u_tcb.rcv_wnd_r[0] = 16'hC000;
        u_dut.u_tcb.snd_wnd_r[0] = 16'h4000;
        u_dut.u_tcb.state_r[0]   = 4'd1;              // ESTABLISHED
        u_dut.u_cam.sip_r[0]     = 32'hC0A86401;
        u_dut.u_cam.dip_r[0]     = 32'hC0A86402;
        u_dut.u_cam.sport_r[0]   = 16'h3039;
        u_dut.u_cam.dport_r[0]   = 16'h1F90;
        u_dut.u_cam.dmac_r[0]    = 48'h112233445566;
        repeat (600) @(posedge u_dut.gmii_clk);

        force u_dut.u_app_ctrl.o_ev_up = 1'b1;
        @(posedge u_dut.gmii_clk);
        release u_dut.u_app_ctrl.o_ev_up;
        repeat (200) @(posedge u_dut.gmii_clk);

        // ================= ① 默认不发送 (peer 表空) =================
        chk(u_dut.app_udp_tx_ready === 1'b0, "① peer 表空 ⇒ app_udp_tx_ready = 0");
        chk(u_dut.u_udp_tx_cfg.peer_v === 1'b0, "① udp_tx_cfg.peer_v = 0 (复位值)");
        chk(u_dut.u_app_udp.stat_tx_frames == 32'd0, "① UDP app 未发任何帧");
        repeat (2000) @(posedge u_dut.gmii_clk);
        chk(gufr == 0, "① 注入前 GMII 上零 UDP 帧");

        // ================= ②③ 注入 RX 帧 (GMII 全链) =================
        if (!no_udp) begin
            inj_i  = 0;
            inj_on = 1'b1;
            repeat (RLEN + 20) @(posedge u_dut.gmii_clk);
            inj_on = 1'b0;
            $display("  [dbg] injected %0d GMII bytes (MAC 帧 %0d + 前导/FCS)",
                     RLEN, 14+20+8+PLEN);
        end else $display("  [dbg] NOUDP: 不注入 RX 帧");

        // 等 app 侧收完 + UDP TX 启动
        repeat (30000) @(posedge u_dut.gmii_clk);

        if (no_udp) begin
            $display("  [dbg] NOUDP: peer_v=%b ready=%b udp_tx_fr=%0d gufr=%0d mac_tx_state=%0d abort=%0d",
                     u_dut.u_udp_tx_cfg.peer_v, u_dut.app_udp_tx_ready,
                     u_dut.u_app_udp.stat_tx_frames, gufr,
                     u_dut.u_mac_tx.state, u_dut.u_mac_tx.stat_abort);
            if (errs == 0) $display("P5E-T5 UDP WRAPPER GATE: OK (NOUDP 对照: 零 UDP 帧)");
            else           $display("P5E-T5 UDP WRAPPER GATE: FAIL errs=%0d", errs);
            $finish;
        end

        $display("  [dbg] RX: app_rx_frames=%0d app_rx_bytes=%0d mismatch=%0d null=%0d split_frames=%0d",
                 u_dut.u_app_udp.stat_rx_frames, u_dut.u_app_udp.stat_rx_bytes,
                 u_dut.u_app_udp.stat_mismatch, u_dut.u_app_udp.stat_rx_null,
                 u_dut.u_udp_split.stat_app_frames);
        $display("  [dbg] mac_rx: frames=%0d crc_err=%0d drop=%0d bytes=%0d | classify fast=%0d slow=%0d | split hls_frames=%0d excl=%0d part=%0d ovf=%0d",
                 u_dut.u_mac_rx.stat_frames, u_dut.u_mac_rx.stat_crc_err,
                 u_dut.u_mac_rx.stat_drop, u_dut.u_mac_rx.stat_bytes,
                 u_dut.cls_stat_fast, u_dut.cls_stat_slow,
                 u_dut.u_udp_split.stat_hls_frames, u_dut.u_udp_split.stat_drop_excl,
                 u_dut.u_udp_split.stat_drop_part, u_dut.u_udp_split.stat_drop_ovf);
        $display("  [dbg] udp_rx: pass=%0d nonmatch=%0d ipcsum=%0d crc=%0d bytes=%0d",
                 u_dut.u_udp_split.u_udp_rx.stat_pass,
                 u_dut.u_udp_split.u_udp_rx.stat_drop_nonmatch,
                 u_dut.u_udp_split.u_udp_rx.stat_drop_ipcsum,
                 u_dut.u_udp_split.u_udp_rx.stat_drop_crc,
                 u_dut.u_udp_split.u_udp_rx.stat_bytes);
        chk(u_dut.u_udp_split.stat_app_frames == 32'd1, "② split 交付 app 1 帧");
        chk(u_dut.u_app_udp.stat_rx_frames == 32'd1,    "② app RX 收到 1 帧");
        chk(u_dut.u_app_udp.stat_rx_bytes == PLEN,      "② app RX 1472 字节");
        chk(u_dut.u_app_udp.stat_mismatch == 32'd0,     "② app RX **零失配** (图案逐字节)");
        chk(u_dut.u_app_udp.stat_rx_null == 32'd0,      "② 无 0 长帧");
        chk(u_dut.u_udp_split.stat_drop_crc == 32'd0,   "② 无 CRC 丢弃");
        chk(u_dut.u_udp_split.stat_hls_split == 32'd1,  "② 该帧被判为 app 帧 (未走 HLS)");

        chk(u_dut.u_udp_tx_cfg.peer_v === 1'b1,         "③ learn-on-RX: peer 表已写入");
        chk(u_dut.app_udp_tx_ready === 1'b1,            "③ app_udp_tx_ready = 1");
        chk(u_dut.u_udp_tx_cfg.peer_mac_r === PEER_MAC, "③ 学到 peer mac = 注入帧 src");
        chk(u_dut.u_udp_tx_cfg.peer_ip_r  === PEER_IP,  "③ 学到 peer ip  = 注入帧 src");

        // ================= ④ UDP 帧上线 (逐字节) =================
        chk(gufr >= 1, "④ GMII 上出现 UDP 帧");
        chk(uflen == (14+20+8+PLEN), "④ MAC 帧长 = 42 + 载荷");
        chk({uf[0],uf[1],uf[2],uf[3],uf[4],uf[5]} === PEER_MAC,  "④ dst mac = 学到的 peer");
        chk({uf[6],uf[7],uf[8],uf[9],uf[10],uf[11]} === BOARD_MAC, "④ src mac = 板 MAC");
        chk({uf[12],uf[13]} === 16'h0800, "④ ethertype = IPv4");
        chk(uf[23] === 8'h11, "④ IP proto = UDP");
        chk({uf[16],uf[17]} === (PLEN + 28), "④ IP total_len");
        csum_acc = 32'd0; csum_add(14, 20);
        chk(fold32(csum_acc) === 16'hFFFF, "④ IP 头校验和正确");
        chk({uf[26],uf[27],uf[28],uf[29]} === BOARD_IP, "④ src ip = 板 IP");
        chk({uf[30],uf[31],uf[32],uf[33]} === PEER_IP,  "④ dst ip = 学到的 peer");
        chk({uf[34],uf[35]} === APP_PORT, "④ src port = 8081");
        chk({uf[36],uf[37]} === APP_PORT, "④ dst port = 8081");
        chk({uf[38],uf[39]} === (PLEN + 8), "④ UDP len");
        csum_acc = 32'd0;
        csum_add(26, 8);
        csum_acc = csum_acc + 16'h0011 + {uf[38], uf[39]};
        csum_add(34, 8 + PLEN);
        chk(fold32(csum_acc) === 16'hFFFF, "④ UDP 校验和正确 (伪头+头+载荷)");
        for (i = 0; i < PLEN; i = i + 1)
            chk(uf[42+i] === pay[i], "④ 载荷逐字节 = 图案 (TX 自 SEED 起)");
        // P5f: 默认 TX_GAP 由 58000 改 0 (板级线速口径) ⇒ 学到 peer 后 app 自由跑,
        // 本窗口内会有多帧上线 ⇒ **帧数判据从 `==1` 放宽为 `>=1`** (逐字节内容判据
        // 一字未动: uf[] 存的仍是**第一帧**, 上面 15 项逐字段校验就是链路正确性的
        // 硬证据)。"恰一帧"这条性质现在由限速参数与 sim/p5e_rate 的量速门负责。
        chk(u_dut.u_udp_tx_cfg.stat_frames >= 32'd1, "④ shim 放行 >=1 帧");
        chk(u_dut.u_udp_tx.stat_frames >= 32'd1,     "④ 帧器发出 >=1 帧");
        // 链路口径自洽: 帧器发出的帧数 <= shim 放行的帧数 (后者不可能少记)
        chk(u_dut.u_udp_tx.stat_frames <= u_dut.u_udp_tx_cfg.stat_frames,
                                                     "④ 帧器帧数 <= shim 放行帧数");
        chk(u_dut.u_udp_tx.stat_drop_len == 32'd0,   "④ 无长度丢弃");

        // ================= ⑤ 与 TCP fast 路径共存 =================
        for (i = 0; i < 40000; i = i + 1) begin
            if (u_dut.u_tcp_tx.stat_frames > 0) i = 40000;
            else @(posedge u_dut.gmii_clk);
        end
        chk(u_dut.u_tcp_tx.stat_frames > 0, "⑤ TCP fast TX 照常 (共享 u_tx_arb)");
        chk(tcp_fr > 0,                     "⑤ GMII 上仍有 TCP 帧");
        chk(u_dut.u_mac_tx.stat_abort == 32'd0, "⑤ mac_tx 无中止 (帧原子性)");
        $display("P5E-T5 UDP WRAPPER: gnfr=%0d udp=%0d tcp=%0d tcp_tx_fr=%0d udp_tx_fr=%0d",
                 gnfr, gufr, tcp_fr, u_dut.u_tcp_tx.stat_frames,
                 u_dut.u_udp_tx.stat_frames);

        // ================= ⑥ RXP_DIAG v4: 状态行字段的**正的存在性证明** ========
        // 【为什么必须有这一相】v4 的 20 个字段在真 wrapper 里曾经**一个都没接**:
        //   综合会把未连接输入钳成常数 0 ⇒ 状态行上"全 0"与"该路径从未触发"在读数上
        //   **不可区分**。所以"门绿 + 无 unconnected 告警"不足以排除这种假 0 ——
        //   必须有一个**非 0、且值可独立复算**的读数穿过 wrapper 走到状态行模块的
        //   字段入口。本相就是这条正证据。
        // 【激励 = 最小新增】第 **2** 个注入帧: 载荷 = 图案流**续流**(自 offset 1472
        //   起, 接第 1 帧之后), 仅把载荷**第 0 字节**翻 0x40, 且翻转在 FCS 计算之前
        //   (⇒ 帧仍好; 坏值出现在 CRC 之后 = 板级的 "FCS 盲区" 场景)。
        // 【期望 (可独立复算, 不是 "!=0")】
        //   app 失配恰 1 字节 (第 2 帧 byte 0); NE=1 NR=1 MR=1 EN=1 EO=0;
        //   QA = {帧号 1, pay[0]^0x40} (pay[0] 此处 = 图案流在 offset 1472 的值)。
        // 【判别依据 (为什么这个非 0 不是 TB 巧合)】
        //   ① 计数由 **DUT 自己的逐字节比对器** 产生 (TB 只喂字节);
        //   ② QA 的 24 位 = {app 自己的帧序, 该帧的收字节} —— 断言的是**具体这一对**
        //      (帧号 1 来自 app 的 SOF 流水, 收字节来自它收到的字, 都不是 TB 的量);
        //   ③ 三条**独立**路径互证: v4 的 NE、v2 的 OZ 桶 (ds_oz)、以及 v4 之前就
        //      存在的 app `stat_mismatch` 必须同时 = 1;
        //   ④ 断言直取**状态行模块的字段入口** `u_dut.u_app_status.v4_ne` (而非只取
        //      wrapper 线) —— 端口若没接, 该引用为 z, `===` 判据必红; 因为本 TB 的
        //      chk 用的是 `if (!cond)` (X 走假分支会静默通过), 所以本相**全部**用
        //      `===` 写成确定值再喂 chk (X/z 一律变红, 不是静默通过)。
        //   ⚠️ 本相**不**去逐字符解码状态行的 UART: wrapper 里的 app_status_uart 用
        //      板级 9600 波特 (BIT_LAST=13020) ⇒ 一行 807 字符x10 位x13021 拍
        //      ≈ **1.05e8 拍**, 且快照在复位时就已锁存 (本 TB 只跑 ~1e5 拍) ⇒ 收不到
        //      更新的一行。**字符布局那一段由
        //      sim/rxpdiag/tb_rxp_diag.v 相 7 逐字符证明** (同一模块、短位周期);
        //      本相补的是它证明不了的那一半: DUT → wrapper 线 → 状态行模块入口。
        // ⚠️ 整段包在 `ifdef RXP_DIAG 内: v4 的线/端口只在 RXP_DIAG 构建里存在 ——
        //    不定义宏时这些层次名不存在, 不包会让另一个配置 (纯 APP_MODE) 的
        //    xelab 直接报 "not declared under prefix" (坑 22)。
`ifdef RXP_DIAG
        bf_base = PLEN[31:0]; bf_corrupt = 1'b1; bf_mask = 8'h40;
        bf_plen = PLEN[31:0]; bf_udplen_ex = 32'd0; bf_badfcs = 1'b0;
        build_rx_frame;
        inj_i  = 0;
        inj_on = 1'b1;
        repeat (RLEN + 20) @(posedge u_dut.gmii_clk);
        inj_on = 1'b0;
        for (i = 0; i < 200000; i = i + 1) begin      // 有界等待第 2 帧被收完
            if (u_dut.u_app_udp.stat_rx_frames >= 32'd2) i = 200000;
            else @(posedge u_dut.gmii_clk);
        end
        repeat (2000) @(posedge u_dut.gmii_clk);
        $display("  [dbg] v4: NE=%0d NR=%0d MR=%0d EN=%0d EO=%0d QA=%06X (期望 {0001,%02X})",
                 u_dut.v4_ne_w, u_dut.v4_nr_w, u_dut.v4_mr_w, u_dut.v4_en_w,
                 u_dut.v4_eo_w, u_dut.v4_qa_w, pay[0] ^ 8'h40);
        $display("  [dbg] v4: 状态行模块入口 NE=%0d QA=%06X | wrapper 线 NE=%0d | CN/RD/WF/WC=%0d/%0d/%0d/%0d (期望 1/1/0/0)",
                 u_dut.u_app_status.v4_ne, u_dut.u_app_status.v4_qa, u_dut.v4_ne_w,
                 u_dut.v4_cn_w, u_dut.v4_rd_w, u_dut.v4_wf_w, u_dut.v4_wc_w);
        $display("  [dbg] v4: app frames=%0d mismatch=%0d | ds_idx=%0d ds_got=%02X ds_exp=%02X ds_oz=%0d",
                 u_dut.u_app_udp.stat_rx_frames, u_dut.u_app_udp.stat_mismatch,
                 u_dut.u_app_udp.ds_idx, u_dut.u_app_udp.ds_got,
                 u_dut.u_app_udp.ds_exp, u_dut.u_app_udp.ds_oz);
        // 前置: 第 2 帧真的被交付且真的失配 (否则下面的非 0 判据无意义)
        chk(u_dut.u_app_udp.stat_rx_frames === 32'd2,   "V4 phase: frame2 not delivered (stim inert)");
        chk(u_dut.u_app_udp.stat_mismatch === 32'd1,    "V4 phase: app stat_mismatch != 1");
        // ★ 正的存在性证明: 非 0 且值可独立复算, 且直取状态行模块的字段入口
        chk(u_dut.v4_ne_w === 16'd1,                    "V4 phase: wrapper wire v4_ne_w != 1");
        chk(u_dut.u_app_status.v4_ne === 16'd1,
            "V4 phase: uart port v4_ne != 1 (unwired?)");
        chk(u_dut.u_app_status.v4_nr === 16'd1,         "V4 phase: uart port v4_nr != 1");
        chk(u_dut.u_app_status.v4_mr === 16'd1,         "V4 phase: uart port v4_mr != 1");
        chk(u_dut.u_app_status.v4_en === 4'd1,          "V4 phase: uart port v4_en != 1");
        chk(u_dut.u_app_status.v4_eo === 1'b0,          "V4 phase: uart port v4_eo != 0");
        chk(u_dut.u_app_status.v4_qa === {16'd1, pay[0] ^ 8'h40},
            "V4 phase: uart port QA != {frm 1, byte}");
        // 同相的反向判据: 其余 6 个 A 部字段**必须仍是 0** (它们现在真的接进去了,
        // 所以这里的 0 是"测过且为 0", 与修复前的"未接假 0"不是同一回事)
        chk(u_dut.u_app_status.v4_cn === 16'd0,         "V4 phase: uart port v4_cn != 0");
        chk(u_dut.u_app_status.v4_rd === 16'd0,         "V4 phase: uart port v4_rd != 0");
        chk(u_dut.u_app_status.v4_nc === 16'd0,         "V4 phase: uart port v4_nc != 0");
        chk(u_dut.u_app_status.v4_np === 16'd0,         "V4 phase: uart port v4_np != 0");
        chk(u_dut.u_app_status.v4_wf === 16'd0,         "V4 phase: uart port v4_wf != 0");
        chk(u_dut.u_app_status.v4_rl === 16'd0,         "V4 phase: uart port v4_rl != 0");
        chk(u_dut.u_app_status.v4_wc === 16'd0,         "V4 phase: uart port v4_wc != 0");
        // 三条独立路径互证 (v4 的 NE / v2 的 OZ 桶 / v4 之前的 app 失配计数)
        chk(u_dut.u_app_udp.ds_oz  === 32'd1,           "V4 phase: v2 OZ bucket != 1 (cross-check)");
        chk(u_dut.u_app_udp.ds_idx === 32'd1472,        "V4 phase: ds_idx != 1472");
        chk(u_dut.u_app_udp.ds_got === (pay[0] ^ 8'h40), "V4 phase: ds_got != injected bad byte");
        chk(u_dut.u_app_udp.ds_exp === pay[0],          "V4 phase: ds_exp != clean pattern byte");
        $display("P5E-T5 UDP WRAPPER V4: NE=%0d QA=%06X (状态行模块入口 NE=%0d)",
                 u_dut.v4_ne_w, u_dut.v4_qa_w, u_dut.u_app_status.v4_ne);

        // ================= ⑦ RXP_DIAG v4: 三组字段的**逐口判别力** (审查 C1) =====
        // 【为什么必须有这一相】⑥ 相里 {NE,NR,MR,EN} 全 = 1、A 部 7 个全 = 0、
        //   QB..QH 全 0 是**判别力最差**的取值组合 ⇒ 下列编辑类别完全不可见:
        //     ① {CN,RD,NC,NP,WF,RL,WC} 组内任意置换;
        //     ② QB..QH 组内任意置换 / 移位;
        //     ③ {NE,NR,MR} 之间互换、或 EN 错接到 NE/NR/MR (16→4 位截断);
        //     ④ 任意一根 `.name()` 掉了而落到 0。
        //   本相把三组都做成**两两不同的非 0 值**并**逐口断言具体值** ⇒ 四类编辑
        //   都会让某条断言变红 (变异证据见 sim/rxpdiag/mutate_wrap_v4.sh)。
        // 【顺序很关键】⑦α 必须紧跟 ⑥: ⑥ 只占了 1 条事件条目, 且图案流仍然对齐 ⇒
        //   ⑦α 的 9 个事件是**设计出来的**、并且是**头 7 个被记录**的 (QB..QH);
        //   ⑦β 的丢弃会打断图案流, 但那时条目已满 (EO=1), 只计数不入队。
        // ---- ⑦α B 部结构 (11 帧, 载荷 = 图案流续流, base = 2944 + 1472k) ----
        //   帧 0 干净(分隔) → 帧 1,2,3 坏 (**连续段 A**, 3 帧) → 帧 4 干净(分隔)
        //   → 帧 5..10 坏 (**连续段 B**, 6 帧)
        //   ⇒ 事件帧 = {frm+1, frm+2, frm+3} ∪ {frm+5..frm+10}: NE +9, NR +2, MR=6
        //   (两段都与 ⑥ 的孤立事件被"干净帧"隔开 ⇒ NR 恰 +2; 各帧掩码互不相同 ⇒
        //    7 条被记录条目的 24 位 {帧号, got} 两两不同)
        repeat (4000) @(posedge u_dut.gmii_clk);          // 等 ⑥ 的帧彻底收完
        ne0 = u_dut.u_app_status.v4_ne; nr0 = u_dut.u_app_status.v4_nr; mr0 = u_dut.u_app_status.v4_mr;
        bf_plen = PLEN[31:0]; bf_udplen_ex = 32'd0; bf_badfcs = 1'b0;
        for (i = 0; i < 11; i = i + 1) begin
            bf_base    = 32'd2944 + i * 1472;
            bf_corrupt = ((i >= 1) && (i <= 3)) || (i >= 5);
            case (i)
                1: bf_mask = 8'h11;  2: bf_mask = 8'h22;  3: bf_mask = 8'h44;
                5: bf_mask = 8'h88;  6: bf_mask = 8'h13;  7: bf_mask = 8'h26;
                8: bf_mask = 8'h4C;  9: bf_mask = 8'h91; 10: bf_mask = 8'hA2;
                default: bf_mask = 8'h00;
            endcase
            if (i == 0) frm_base = u_dut.u_app_udp.stat_rx_frames[15:0];
            build_rx_frame;
            if (i == 1) qex[0] = pay[0] ^ bf_mask;
            if (i == 2) qex[1] = pay[0] ^ bf_mask;
            if (i == 3) qex[2] = pay[0] ^ bf_mask;
            if (i == 5) qex[3] = pay[0] ^ bf_mask;
            if (i == 6) qex[4] = pay[0] ^ bf_mask;
            if (i == 7) qex[5] = pay[0] ^ bf_mask;
            if (i == 8) qex[6] = pay[0] ^ bf_mask;
            inj_frame;
            repeat (2600) @(posedge u_dut.gmii_clk);      // 逐帧喂 (不撞缓冲/描述符)
        end
        repeat (4000) @(posedge u_dut.gmii_clk);
        $display("RXPV4-7a B: NE=%0d NR=%0d MR=%0d EN=%0d EO=%0d (prev: NE=%0d NR=%0d MR=%0d, frm_base=%0d)",
                 u_dut.u_app_status.v4_ne, u_dut.u_app_status.v4_nr, u_dut.u_app_status.v4_mr, u_dut.u_app_status.v4_en,
                 u_dut.u_app_status.v4_eo, ne0, nr0, mr0, frm_base);
        $display("RXPV4-7a Q: QA=%06X QB=%06X QC=%06X QD=%06X QE=%06X QF=%06X QG=%06X QH=%06X",
                 u_dut.u_app_status.v4_qa, u_dut.u_app_status.v4_qb, u_dut.u_app_status.v4_qc, u_dut.u_app_status.v4_qd,
                 u_dut.u_app_status.v4_qe, u_dut.u_app_status.v4_qf, u_dut.u_app_status.v4_qg, u_dut.u_app_status.v4_qh);
        chk(u_dut.u_app_status.v4_ne === (ne0 + 16'd9), "7a: NE delta != 9 (3+6)");
        chk(u_dut.u_app_status.v4_nr === (nr0 + 16'd2), "7a: NR delta != 2 (two runs)");
        chk(u_dut.u_app_status.v4_mr === 16'd6,         "7a: MR != 6 (longest run)");
        chk(u_dut.u_app_status.v4_ne !== u_dut.u_app_status.v4_nr && u_dut.u_app_status.v4_ne !== u_dut.u_app_status.v4_mr &&
            u_dut.u_app_status.v4_nr !== u_dut.u_app_status.v4_mr, "7a: NE/NR/MR not pairwise distinct");
        chk(u_dut.u_app_status.v4_en === 4'd8, "7a: EN != 8 (FIFO not saturated)");
        chk(u_dut.u_app_status.v4_eo === 1'b1, "7a: EO != 1 (overflow not flagged)");
        chk({12'd0, u_dut.u_app_status.v4_en} !== u_dut.u_app_status.v4_ne, "7a: EN == NE (wrong wire?)");
        chk(u_dut.u_app_status.v4_qa === 24'h0001A8, "7a: QA != {1,0xA8} (phase 6 event)");
        chk(u_dut.u_app_status.v4_qb === {frm_base + 16'd1, qex[0]}, "7a: QB != {f+1, got}");
        chk(u_dut.u_app_status.v4_qc === {frm_base + 16'd2, qex[1]}, "7a: QC != {f+2, got}");
        chk(u_dut.u_app_status.v4_qd === {frm_base + 16'd3, qex[2]}, "7a: QD != {f+3, got}");
        chk(u_dut.u_app_status.v4_qe === {frm_base + 16'd5, qex[3]}, "7a: QE != {f+5, got}");
        chk(u_dut.u_app_status.v4_qf === {frm_base + 16'd6, qex[4]}, "7a: QF != {f+6, got}");
        chk(u_dut.u_app_status.v4_qg === {frm_base + 16'd7, qex[5]}, "7a: QG != {f+7, got}");
        chk(u_dut.u_app_status.v4_qh === {frm_base + 16'd8, qex[6]}, "7a: QH != {f+8, got}");
        chk(u_dut.u_app_status.v4_qa !== u_dut.u_app_status.v4_qb, "7a: QA == QB");
        chk(u_dut.u_app_status.v4_qb !== u_dut.u_app_status.v4_qc, "7a: QB == QC");
        chk(u_dut.u_app_status.v4_qb !== u_dut.u_app_status.v4_qd, "7a: QB == QD");
        chk(u_dut.u_app_status.v4_qb !== u_dut.u_app_status.v4_qe, "7a: QB == QE");
        chk(u_dut.u_app_status.v4_qc !== u_dut.u_app_status.v4_qd, "7a: QC == QD");
        chk(u_dut.u_app_status.v4_qc !== u_dut.u_app_status.v4_qe, "7a: QC == QE");
        chk(u_dut.u_app_status.v4_qd !== u_dut.u_app_status.v4_qe, "7a: QD == QE");
        chk(u_dut.u_app_status.v4_qg !== u_dut.u_app_status.v4_qh, "7a: QG == QH");
        chk(u_dut.u_app_udp.stat_rx_frames[15:0] === (frm_base + 16'd11),
            "7a: not all 11 frames delivered");
        // ---- ⑦β A 部: RD / CN / WF / WC / NC / NP ----
        // 【与 V5/V8 的关系】单元门 (tb_rxp_v4.v) 用"TB 灌得比消费者快"造 CN/WF;
        //   wrapper 里线上只有 1 字节/拍 (= 消费者 1 字/8 拍) ⇒ **结构性无法靠灌快**
        //   ⇒ 这里把**消费者变慢** (force app rx_tready=0, 见 sc_en) 造同一个条件。
        //   这是本相唯一的新手法 (报告里已显式说明)。
        // β1 RD x2: "声明 > 实际"的残帧 (各后随一帧好帧触发边界回卷, 载荷 104B)
        for (i = 0; i < 2; i = i + 1) begin
            bf_plen = 32'd104; bf_base = 32'd0; bf_corrupt = 1'b0;
            bf_udplen_ex = 32'd58; bf_badfcs = 1'b0; bf_mask = 8'h00;
            build_rx_frame; inj_frame;
            bf_udplen_ex = 32'd0; bf_plen = PLEN[31:0];
            build_rx_frame; inj_frame;
            repeat (2500) @(posedge u_dut.gmii_clk);
        end
        repeat (4000) @(posedge u_dut.gmii_clk);
        // β2 CN: 慢消费者 + 80 个小帧 (8B = 1 字) 背靠背 ⇒ 描述符 FIFO 注满
        sc_en = 1'b1;
        repeat (8) @(posedge u_dut.gmii_clk);
        for (i = 0; i < 80; i = i + 1) begin
            bf_plen = 32'd8; bf_base = 32'd0; bf_corrupt = 1'b0;
            bf_udplen_ex = 32'd0; bf_badfcs = 1'b0;
            build_rx_frame; inj_frame;
        end
        repeat (2000) @(posedge u_dut.gmii_clk);
        sc_en = 1'b0;                                     // 放行 + 排空积压
        repeat (40000) @(posedge u_dut.gmii_clk);
        // β3 WF: 慢消费者 + 12 个整帧 (1472B) 背靠背 ⇒ 载荷缓冲 (512 字) 注满
        sc_en = 1'b1;
        repeat (8) @(posedge u_dut.gmii_clk);
        for (i = 0; i < 12; i = i + 1) begin
            bf_plen = PLEN[31:0]; bf_base = 32'd0; bf_corrupt = 1'b0;
            bf_udplen_ex = 32'd0; bf_badfcs = 1'b0;
            build_rx_frame; inj_frame;
        end
        repeat (2000) @(posedge u_dut.gmii_clk);
        sc_en = 1'b0;                                     // 放行 + 排空
        repeat (40000) @(posedge u_dut.gmii_clk);
        // β4 WC: 强偏 u_meta_len (+8) 下投 5 个干净整帧 ⇒ 每帧恰 1 次违例
        @(negedge u_dut.gmii_clk);
        force u_dut.u_udp_split.u_meta_len = 16'd1480;
        for (i = 0; i < 5; i = i + 1) begin
            bf_plen = PLEN[31:0]; bf_base = 32'd0; bf_corrupt = 1'b0;
            bf_udplen_ex = 32'd0; bf_badfcs = 1'b0;
            build_rx_frame; inj_frame;
            repeat (2500) @(posedge u_dut.gmii_clk);
        end
        @(negedge u_dut.gmii_clk);
        release u_dut.u_udp_split.u_meta_len;
        repeat (3000) @(posedge u_dut.gmii_clk);
        // β5 NC/NP: 6 个 0 长数据报 (4 好 FCS + 2 坏 FCS) ⇒ NC=6, NP=4
        for (i = 0; i < 6; i = i + 1) begin
            bf_plen = 32'd0; bf_base = 32'd0; bf_corrupt = 1'b0;
            bf_udplen_ex = 32'd0; bf_badfcs = (i >= 4) ? 1'b1 : 1'b0;
            build_rx_frame; inj_frame;
            repeat (300) @(posedge u_dut.gmii_clk);
        end
        repeat (3000) @(posedge u_dut.gmii_clk);
        $display("RXPV4-7b A: CN=%0d RD=%0d NC=%0d NP=%0d WF=%0d RL=%0d WC=%0d",
                 u_dut.u_app_status.v4_cn, u_dut.u_app_status.v4_rd, u_dut.u_app_status.v4_nc, u_dut.u_app_status.v4_np,
                 u_dut.u_app_status.v4_wf, u_dut.u_app_status.v4_rl, u_dut.u_app_status.v4_wc);
        $display("RXPV4-7b B: NE=%0d NR=%0d MR=%0d EN=%0d EO=%0d",
                 u_dut.u_app_status.v4_ne, u_dut.u_app_status.v4_nr, u_dut.u_app_status.v4_mr, u_dut.u_app_status.v4_en,
                 u_dut.u_app_status.v4_eo);
        // 逐口具体值 (模型精确的: RD/NC/NP/WC 由注入次数直接定; CN/WF/RL 见常量)
        chk(u_dut.u_app_status.v4_rd === 16'd2, "7b: RD != 2");
        chk(u_dut.u_app_status.v4_nc === 16'd6, "7b: NC != 6");
        chk(u_dut.u_app_status.v4_np === 16'd4, "7b: NP != 4");
        chk(u_dut.u_app_status.v4_wc === 16'd5, "7b: WC != 5");
        chk(u_dut.u_app_status.v4_cn === CN_EXP_VAL, "7b: CN != CN_EXP_VAL");
        chk(u_dut.u_app_status.v4_wf === WF_EXP_VAL, "7b: WF != WF_EXP_VAL");
        chk(u_dut.u_app_status.v4_rl === RL_EXP_VAL, "7b: RL != RL_EXP_VAL");
        // RL 与 v3 的 RC 同源 ⇒ 两处读数必须一致
        chk(u_dut.u_udp_split.v3_rc === u_dut.u_app_status.v4_rl, "7b: RL != v3 RC");
        // A 部 7 个值两两不同 (组内任意置换必被逐值断言或这 21 条之一抓到)
        chk(u_dut.u_app_status.v4_cn !== u_dut.u_app_status.v4_rd, "7b: CN == RD");
        chk(u_dut.u_app_status.v4_cn !== u_dut.u_app_status.v4_nc, "7b: CN == NC");
        chk(u_dut.u_app_status.v4_cn !== u_dut.u_app_status.v4_np, "7b: CN == NP");
        chk(u_dut.u_app_status.v4_cn !== u_dut.u_app_status.v4_wf, "7b: CN == WF");
        chk(u_dut.u_app_status.v4_cn !== u_dut.u_app_status.v4_rl, "7b: CN == RL");
        chk(u_dut.u_app_status.v4_cn !== u_dut.u_app_status.v4_wc, "7b: CN == WC");
        chk(u_dut.u_app_status.v4_rd !== u_dut.u_app_status.v4_nc, "7b: RD == NC");
        chk(u_dut.u_app_status.v4_rd !== u_dut.u_app_status.v4_np, "7b: RD == NP");
        chk(u_dut.u_app_status.v4_rd !== u_dut.u_app_status.v4_wf, "7b: RD == WF");
        chk(u_dut.u_app_status.v4_rd !== u_dut.u_app_status.v4_rl, "7b: RD == RL");
        chk(u_dut.u_app_status.v4_rd !== u_dut.u_app_status.v4_wc, "7b: RD == WC");
        chk(u_dut.u_app_status.v4_nc !== u_dut.u_app_status.v4_np, "7b: NC == NP");
        chk(u_dut.u_app_status.v4_nc !== u_dut.u_app_status.v4_wf, "7b: NC == WF");
        chk(u_dut.u_app_status.v4_nc !== u_dut.u_app_status.v4_rl, "7b: NC == RL");
        chk(u_dut.u_app_status.v4_nc !== u_dut.u_app_status.v4_wc, "7b: NC == WC");
        chk(u_dut.u_app_status.v4_np !== u_dut.u_app_status.v4_wf, "7b: NP == WF");
        chk(u_dut.u_app_status.v4_np !== u_dut.u_app_status.v4_rl, "7b: NP == RL");
        chk(u_dut.u_app_status.v4_np !== u_dut.u_app_status.v4_wc, "7b: NP == WC");
        chk(u_dut.u_app_status.v4_wf !== u_dut.u_app_status.v4_rl, "7b: WF == RL");
        chk(u_dut.u_app_status.v4_wf !== u_dut.u_app_status.v4_wc, "7b: WF == WC");
        chk(u_dut.u_app_status.v4_rl !== u_dut.u_app_status.v4_wc, "7b: RL == WC");
        // B 部终值也必须两两不同 (⑦β 的丢弃让 NE 涨, 但结构不塌到相等)
        chk(u_dut.u_app_status.v4_ne !== u_dut.u_app_status.v4_nr, "7b: NE == NR");
        chk(u_dut.u_app_status.v4_ne !== u_dut.u_app_status.v4_mr, "7b: NE == MR");
        chk(u_dut.u_app_status.v4_nr !== u_dut.u_app_status.v4_mr, "7b: NR == MR");
        chk({12'd0, u_dut.u_app_status.v4_en} !== u_dut.u_app_status.v4_ne, "7b: EN == NE (wrong wire?)");

        // ================= ⑧ RXP_DIAG v5: 新字段的**正的存在性证明** ==========
        // 【为什么必须有这一相】与 ⑥ 同一条铁律 (§17.5): v5 的 11 个字段若在
        //   wrapper 里没接, 综合把未连接输入**钳成常数 0** ⇒ 状态行上的"全 0"与
        //   "该路径从未触发"在读数上**不可区分**。⇒ 必须有一个**非 0 且可独立复算**
        //   的读数穿过 wrapper 走到**状态行模块的字段入口** (`u_dut.u_app_status.v5_*`)。
        // 【A 部快照是**粘滞**的 (只记首个失配) ⇒ 本相分两段用】
        //   ① 冻结值 = 本 wrapper 跑量里**第一个**失配 (由相 ⑥ 造成): 帧 2 的载荷是
        //      图案流续流 (bf_base=1472), 只有载荷第 0 字节被翻 0x40 ⇒
        //        DV = 1472 (该字节写进 u_uf 时的**累计字节序号**)
        //        DO = 0    DG = 0xA8 = pattern[1472]^0x40   DE = 0xE8 = pattern[1472]
        //      这四个值 TB **可独立复算** (pattern[1472] 由 bf_base=1472 的图案流迭代给出),
        //      且与 app 自己的 ds_idx/ds_got/ds_exp **互证** (两条机制不同, 见下)。
        //   ② 增量值: 本相再注入 1 帧, 载荷 = **当前写入口序号的续流**
        //      (bf_base = u_udp_split.v5_cnt, 先采样两次确认已静止) ⇒ 这一帧的每个字节
        //      都恰好落在期望序列上 ⇒ **DM 增量必须恰为 1** (只算那一个被翻的字节)。
        //      ⚠️ 这条是**有牙的**: 若锚(累计计数)或 LFSR 约定错一字节, 增量会是 ~1471。
        // 【B 部 (解析器计数)】PS 增量=1 且 == app 的 URF 增量 (§16.7 判据) / SB 增量
        //   =1472 / NM=IC=DC 增量=0。
        // ⚠️ 断言直取**状态行模块入口** (端口若没接 ⇒ z ⇒ 本 TB 的 `chk` 用 `if(!cond)`
        //    会静默通过 ⇒ 故关键量用 `===` 写成确定值, z/X 一律变红)。
        repeat (20000) @(posedge u_dut.gmii_clk);
        v5_c0 = u_dut.u_udp_split.v5_cnt;
        repeat (2000) @(posedge u_dut.gmii_clk);
        v5_c1 = u_dut.u_udp_split.v5_cnt;
        chk(v5_c0 === v5_c1, "8: v5_cnt still moving (DUT not idle, anchor unsafe)");
        v5_dm0 = u_dut.u_app_status.v5_dv_mm;
        v5_mm0 = u_dut.u_app_udp.stat_mismatch;
        v5_ps0 = u_dut.u_app_status.v5_up_pass;
        v5_sb0 = u_dut.u_app_status.v5_up_bytes;
        v5_nm0 = u_dut.u_app_status.v5_up_nm;
        v5_ic0 = u_dut.u_app_status.v5_up_ipc;
        v5_dc0 = u_dut.u_app_status.v5_up_crc;
        v5_uf0 = u_dut.u_app_udp.stat_rx_frames;
        bf_base = v5_c0;                        // 图案流续流 = 写入口序号的续流
        bf_corrupt = 1'b1; bf_mask = 8'h40; bf_coff = 12'd100;
        bf_plen = PLEN[31:0]; bf_udplen_ex = 32'd0; bf_badfcs = 1'b0;
        build_rx_frame;
        inj_frame;
        repeat (30000) @(posedge u_dut.gmii_clk);
        bf_corrupt = 1'b0; bf_coff = 12'd0; bf_base = 32'd0;
        $display("RXPV5-8 frozen: DV=%0d DO=%0d DG=%02X DE=%02X VZ=%0d (期望 %0d/%0d/%02X/%02X/1)",
                 u_dut.u_app_status.v5_dv_idx, u_dut.u_app_status.v5_dv_off,
                 u_dut.u_app_status.v5_dv_got, u_dut.u_app_status.v5_dv_exp,
                 u_dut.u_app_status.v5_dv_v,
                 DV_EXP_VAL, DO_EXP_VAL, DG_EXP_VAL, DE_EXP_VAL);
        $display("RXPV5-8 delta : dDM=%0d (期望 1) | dPS=%0d dSB=%0d dNM=%0d dIC=%0d dDC=%0d dURF=%0d dMM=%0d",
                 u_dut.u_app_status.v5_dv_mm - v5_dm0,
                 u_dut.u_app_status.v5_up_pass - v5_ps0,
                 u_dut.u_app_status.v5_up_bytes - v5_sb0,
                 u_dut.u_app_status.v5_up_nm - v5_nm0,
                 u_dut.u_app_status.v5_up_ipc - v5_ic0,
                 u_dut.u_app_status.v5_up_crc - v5_dc0,
                 u_dut.u_app_udp.stat_rx_frames - v5_uf0,
                 u_dut.u_app_udp.stat_mismatch - v5_mm0);
        // 前置: 本帧真的被交付 (否则下面的增量无意义)
        chk(u_dut.u_app_udp.stat_rx_frames - v5_uf0 === 32'd1, "8: frame not delivered (stim inert)");
        // ★ A 部冻结值 = **非 0 且可独立复算** (相 ⑥ 的那次失配)
        chk(u_dut.u_app_status.v5_dv_v === 1'b1, "8: uart port VZ != 1 (unwired?)");
        chk(u_dut.u_app_status.v5_dv_idx === DV_EXP_VAL, "8: uart port DV != 1472");
        chk(u_dut.u_app_status.v5_dv_off === DO_EXP_VAL, "8: uart port DO != 0");
        chk(u_dut.u_app_status.v5_dv_got === DG_EXP_VAL, "8: uart port DG != 0xA8");
        chk(u_dut.u_app_status.v5_dv_exp === DE_EXP_VAL, "8: uart port DE != 0xE8");
        chk((u_dut.u_app_status.v5_dv_idx % 32'd1472) === {16'd0, u_dut.u_app_status.v5_dv_off},
            "8: DV % paylen != DO (the count anchor and the frame offset disagree)");
        // ★ 跨机制互证: din 的纯计数锚 vs app 的帧内校验器 (两条路径机制不同)
        chk(u_dut.u_app_status.v5_dv_idx === u_dut.u_app_udp.ds_idx, "8: DV != app ds_idx");
        chk(u_dut.u_app_status.v5_dv_got === u_dut.u_app_udp.ds_got, "8: DG != app ds_got");
        chk(u_dut.u_app_status.v5_dv_exp === u_dut.u_app_udp.ds_exp, "8: DE != app ds_exp");
        // ★ A 部增量: 续流载荷 ⇒ 恰 1 个坏字节 (锚/LFSR 错一字节 ⇒ ~1471)
        chk(u_dut.u_app_status.v5_dv_mm - v5_dm0 === 32'd1, "8: DM delta != 1 (anchor or LFSR wrong?)");
        // ⚠️ app 侧的失配数**不能**与 din 侧的 DM 增量比: ⑦β 的丢弃 (回卷/满吞) 让 app 的
        //   字节序号相对写入口序号产生了**固定相位偏移** ⇒ 这一帧在 app 眼里整段都对不上。
        //   (两条锚"逐字节可比"的证据在干净的单元门里: tb_rxp_v5 的 W1/W3/W4 断言
        //    `DV == ds_idx` 且 `DM == stat_mismatch`; 板级 8/8 轮 RL=WF=0 同样成立。)
        chk(u_dut.u_app_udp.stat_mismatch - v5_mm0 >= 32'd1, "8: app mismatch delta == 0 (frame not compared)");
        // ★ B 部 (解析器计数器) 的正证据 + §16.7 的 URF 判据
        chk(u_dut.u_app_status.v5_up_pass - v5_ps0 === 32'd1, "8: PS delta != 1");
        chk(u_dut.u_app_status.v5_up_bytes - v5_sb0 === 32'd1472, "8: SB delta != 1472");
        chk((u_dut.u_app_status.v5_up_pass - v5_ps0) ===
            (u_dut.u_app_udp.stat_rx_frames - v5_uf0), "8: PS delta != URF delta (frame lost/dup)");
        chk(u_dut.u_app_status.v5_up_nm - v5_nm0 === 32'd0, "8: NM delta != 0");
        chk(u_dut.u_app_status.v5_up_ipc - v5_ic0 === 32'd0, "8: IC delta != 0");
        chk(u_dut.u_app_status.v5_up_crc - v5_dc0 === 32'd0, "8: DC delta != 0");
        // 字段互相可区分 (组内任意置换/串位都该被抓到)
        chk(u_dut.u_app_status.v5_dv_idx !== u_dut.u_app_status.v5_dv_mm, "8: DV == DM");
        chk(u_dut.u_app_status.v5_up_pass !== u_dut.u_app_status.v5_up_bytes, "8: PS == SB");
        chk(u_dut.u_app_status.v5_dv_got !== u_dut.u_app_status.v5_dv_exp, "8: DG == DE");
        $display("P5E-T5 UDP WRAPPER V5: DV=%0d DO=%0d DG=%02X DE=%02X DM=%0d VZ=%0d PS=%0d SB=%0d (模块入口)",
                 u_dut.u_app_status.v5_dv_idx, u_dut.u_app_status.v5_dv_off,
                 u_dut.u_app_status.v5_dv_got, u_dut.u_app_status.v5_dv_exp,
                 u_dut.u_app_status.v5_dv_mm, u_dut.u_app_status.v5_dv_v,
                 u_dut.u_app_status.v5_up_pass, u_dut.u_app_status.v5_up_bytes);

        // ================= ⑨ RXP_DIAG v6: 新字段的**正的存在性证明** ==========
        // 【为什么必须有这一相】与 ⑥/⑧ 同一条铁律 (§17.5): v6 的 7 个字段若在
        //   wrapper 里没接, 综合把未连接输入**钳成常数 0** ⇒ 状态行上的"全 0"与
        //   "该路径从未触发"在读数上**不可区分**。⇒ 必须有一个**非 0 且可独立复算**
        //   的读数穿过 wrapper 走到**状态行模块的字段入口** (`u_dut.u_app_status.v6_*`)。
        // 【与 ⑧ 的关键差别】v6 的 CV 是**输入侧**累计载荷字节序号 (udp_split 的
        //   s_axis), 而 v5 的 DV 是**写口**累计序号。两者只在"输入流与写入流逐字节
        //   相同"时相等 —— 相 ⑦β 的满吞 (WF>0) 会让 v5 少算被吞的字, 所以本相
        //   **不**断言 CV == DV (那是 ⑧ 里 v5↔app 的对照口径, 有它自己的前置闸)。
        //   本相断言的是**与序号无关**的量 (CO/CG/CE, 全部可独立复算) 加上一条
        //   **有牙的增量** (CM delta == 1)。
        // 【A 部快照是**粘滞**的 (只记首个失配) ⇒ 本相分两段用】
        //   ① 冻结值 = 本 wrapper 跑量里第一个失配 (由相 ⑥ 造成): 帧 2 的载荷是
        //      图案流续流, 只有载荷第 0 字节被翻 0x40 ⇒ CO = 0,
        //      CG = 0xA8 = pattern[1472]^0x40, CE = 0xE8 = pattern[1472]。
        //   ② 增量值: 再注入 1 帧, 载荷 = **v6 自己的写入口序号的续流**
        //      (`bf_base = u_dut.u_udp_split.v6_cnt`, 先采样两次确认已静止) ⇒ 这一帧
        //      的每个字节都恰好落在 v6 的期望序列上 ⇒ **CM 增量必须恰为 1**。
        //      ⚠️ 这条是**有牙的**: 若锚 (累计计数) 或 LFSR 约定错一字节, 增量会是 ~1471。
        // ⚠️ 断言直取**状态行模块入口** (端口若没接 ⇒ z ⇒ 关键量用 `===` 写成确定值,
        //    z/X 一律变红)。
        $display("P5E-T5 UDP WRAPPER V6: CV=%0d CO=%0d CG=%02X CE=%02X CM=%0d CZ=%0d CS=%0d | v6_cnt=%0d v5_cnt=%0d (模块入口)",
                 u_dut.u_app_status.v6_dv_idx, u_dut.u_app_status.v6_dv_off,
                 u_dut.u_app_status.v6_dv_got, u_dut.u_app_status.v6_dv_exp,
                 u_dut.u_app_status.v6_dv_mm, u_dut.u_app_status.v6_dv_v,
                 u_dut.u_app_status.v6_dv_sk,
                 u_dut.u_udp_split.v6_cnt, u_dut.u_udp_split.v5_cnt);
        chk(u_dut.u_app_status.v6_dv_v === 1'b1, "9: uart port CZ != 1 (unwired?)");
        // ★ CV = 1472 = 相 ⑥ 那一帧的图案流基 (可独立复算): 在 ⑥ 之前输入流与写口流
        //   逐字节相同 ⇒ 两条计数锚必须给同一个序号。**实测确认**后才写死 (见本节
        //   $display 的实测行: v6_cnt=49424 与 v5_cnt=46208 在**本相**已经分叉 ——
        //   分叉发生在 ⑦β 的满吞之后, 与本条的时点无关)。
        chk(u_dut.u_app_status.v6_dv_idx === DV_EXP_VAL, "9: uart port CV != 1472");
        chk(u_dut.u_app_status.v6_dv_idx === u_dut.u_app_status.v5_dv_idx, "9: CV != v5 DV");
        chk(u_dut.u_app_status.v6_dv_off === 16'd0, "9: uart port CO != 0");
        chk(u_dut.u_app_status.v6_dv_got === DG_EXP_VAL, "9: uart port CG != 0xA8");
        chk(u_dut.u_app_status.v6_dv_exp === DE_EXP_VAL, "9: uart port CE != 0xE8");
        chk((u_dut.u_app_status.v6_dv_idx % 32'd1472) ===
            {16'd0, u_dut.u_app_status.v6_dv_off},
            "9: CV % paylen != CO (the count anchor and the frame offset disagree)");
        // ★ 跨机制互证: 输入侧 (v6) 与写口侧 (v5) 的**帧内偏移与字节值**必须相同
        //   (这两组量都与序号无关 ⇒ 不受 WF/RL 影响; 序号本身可能被满吞错开)
        chk(u_dut.u_app_status.v6_dv_off === u_dut.u_app_status.v5_dv_off, "9: CO != v5 DO");
        chk(u_dut.u_app_status.v6_dv_got === u_dut.u_app_status.v5_dv_got, "9: CG != v5 DG");
        chk(u_dut.u_app_status.v6_dv_exp === u_dut.u_app_status.v5_dv_exp, "9: CE != v5 DE");
        // 字段互相可区分 (组内任意置换/串位都该被抓到)
        chk(u_dut.u_app_status.v6_dv_got !== u_dut.u_app_status.v6_dv_exp, "9: CG == CE");
        chk(u_dut.u_app_status.v6_dv_idx !== u_dut.u_app_status.v6_dv_mm, "9: CV == CM");
        chk(u_dut.u_app_status.v6_dv_idx !== {16'd0, u_dut.u_app_status.v6_dv_off},
            "9: CV == CO (fields not distinguishable)");
        // ★ 增量: 用 **v6 自己的** 累计计数作图案续流基 ⇒ 恰 1 个坏字节
        v6_cm0 = u_dut.u_app_status.v6_dv_mm;
        v6_c0 = u_dut.u_udp_split.v6_cnt;
        repeat (2000) @(posedge u_dut.gmii_clk);
        v6_c1 = u_dut.u_udp_split.v6_cnt;
        chk(v6_c0 === v6_c1, "9: v6_cnt still moving (DUT not idle, anchor unsafe)");
        v6_uf0 = u_dut.u_app_udp.stat_rx_frames;
        bf_base = v6_c0;                        // 图案流续流 = v6 输入口序号的续流
        bf_corrupt = 1'b1; bf_mask = 8'h20; bf_coff = 12'd100;
        bf_plen = PLEN[31:0]; bf_udplen_ex = 32'd0; bf_badfcs = 1'b0;
        build_rx_frame;
        inj_frame;
        repeat (30000) @(posedge u_dut.gmii_clk);
        bf_corrupt = 1'b0; bf_coff = 12'd0; bf_base = 32'd0;
        $display("P5E-T5 UDP WRAPPER V6 delta: dCM=%0d (期望 1) dURF=%0d dCS=%0d",
                 u_dut.u_app_status.v6_dv_mm - v6_cm0,
                 u_dut.u_app_udp.stat_rx_frames - v6_uf0,
                 u_dut.u_app_status.v6_dv_sk);
        chk(u_dut.u_app_udp.stat_rx_frames - v6_uf0 === 32'd1, "9: frame not delivered (stim inert)");
        chk(u_dut.u_app_status.v6_dv_mm - v6_cm0 === 32'd1,
            "9: CM delta != 1 (anchor or LFSR wrong?)");
        // ★ CS = 输入 skid 丢字计数: 真链路上是 1 字/8 拍, 必须恒 0 (非 0 = 读数不可用)
        chk(u_dut.u_app_status.v6_dv_sk === 8'd0, "9: CS != 0 (skid overflowed)");
`endif

        if (errs == 0) $display("P5E-T5 UDP WRAPPER GATE: OK");
        else           $display("P5E-T5 UDP WRAPPER GATE: FAIL errs=%0d", errs);
        $finish;
    end
endmodule
