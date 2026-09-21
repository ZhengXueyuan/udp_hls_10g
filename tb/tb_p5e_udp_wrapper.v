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
//   +NOUDP 对照 (xsim -testplusarg NOUDP): 不注入 ⇒ 全程零 UDP 帧
//=============================================================================
module tb_p5e_udp_wrapper;
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

    localparam integer RLEN = 8 + 14 + 20 + 8 + PLEN + 4;   // 注入总字节数
    reg  [7:0] rbuf [0:RLEN-1];
    reg  [7:0] pay  [0:PLEN-1];       // 载荷图案 (独立算一遍, 供 TX 侧判据)
    reg [63:0] glfsr;
    integer    ri;
    task build_rx_frame;
        reg [31:0] c; reg [63:0] s;
        integer k;
        begin
            // 载荷图案
            s = 64'h9E3779B97F4A7C15;
            for (k = 0; k < PLEN; k = k + 1) begin
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
            rbuf[8+16] = ((PLEN+28) >> 8) & 8'hFF; rbuf[8+17] = (PLEN+28) & 8'hFF;
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
            rbuf[8+38] = ((PLEN+8) >> 8) & 8'hFF; rbuf[8+39] = (PLEN+8) & 8'hFF;
            rbuf[8+40] = 8'h00; rbuf[8+41] = 8'h00;            // udp csum (板侧不判 RX)
            // 载荷
            for (k = 0; k < PLEN; k = k + 1) rbuf[8+42+k] = pay[k];
            // FCS: 覆盖 MAC 帧 (字节 8 .. 8+1513); 线上小端 (LSB 字节先发)
            c = 32'hFFFFFFFF;
            for (k = 8; k < 8+14+20+8+PLEN; k = k + 1)
                c = crc32_byte(c, rbuf[k]);
            c = ~c;
            rbuf[8+14+20+8+PLEN+0] = c[7:0];
            rbuf[8+14+20+8+PLEN+1] = c[15:8];
            rbuf[8+14+20+8+PLEN+2] = c[23:16];
            rbuf[8+14+20+8+PLEN+3] = c[31:24];
        end
    endtask

    // 注入控制 (negedge 驱动 ⇒ 远离 posedge 采样, 坑 17)
    reg  [15:0] inj_i;
    reg         inj_on;
    // 末字节被采样的**同一拍**就必须拉低 dv (帧尾多挂 dv=1 会让那些字节进帧身,
    // FCS 校验位错位 ⇒ stat_crc_err; 实测: 多挂 1 拍 ⇒ mac_rx bytes=1519 且 crc_err)
    wire        inj_dv = inj_on && (inj_i < RLEN);
    wire [7:0]  inj_byte = (inj_i < RLEN) ? rbuf[inj_i] : 8'h00;
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

        if (errs == 0) $display("P5E-T5 UDP WRAPPER GATE: OK");
        else           $display("P5E-T5 UDP WRAPPER GATE: FAIL errs=%0d", errs);
        $finish;
    end
endmodule
