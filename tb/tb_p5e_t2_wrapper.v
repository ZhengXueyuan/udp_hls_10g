`timescale 1ns/1ps
//=============================================================================
// tb_p5e_t2_wrapper — P5e-T2 UDP app TX 的 **真 wrapper 全链门** (工程坑 8)
//=============================================================================
// 为什么必须另开一门: 单元门 (tb_udp_tx_guard) 自己搭链, **不走 wrapper 的
// APP_MODE 接线分支** —— udp_tx_cfg / udp_tx_frame / tx_arb(新) 在 wrapper 里的
// 接线错 (漏接/多驱动/自环/frame_busy 忘接) 在单元门里完全隐身, 只有例化真
// wrapper 才能抓到 (P5a W1 血的教训)。
//
// 本门在 tb_p5_wrapper 的骨架 (TB 预置 TCB/CAM + force CONN_UP + 抓内部 GMII)
// 之上, 增加 UDP app TX 通路:
//   · T2 阶段 wrapper 内没有 app UDP TX 消费者 (端口恒 0) ⇒ TB 用 `force`
//     (negedge 施加, 远离 posedge 采样 = 不踩坑 17) 把一帧 100B 载荷推上
//     app_udp_tx_*;
//   · peer 学习事件 = force wrapper 的 `udp_meta_valid/udp_meta_src_mac/udp_meta_src_ip`
//     一拍 (P5e-T3 起 wrapper 的 `.peer_wr` 源 = udp_split 的 meta 线束;
//     旧写法 force `scfg_ev_*` 已失效 —— UDP 无连接 ⇒ CONN_UP 在板上不存在);
//   · 判据 (全部在 wrapper 内部 GMII 上, e_txd/e_txen 字节流解码):
//     ① 默认不发送: peer 未学习时推帧 ⇒ GMII 零 UDP 帧 + 帧原地等待 (ui 不前进)
//     ② peer 注入 ⇒ 原帧上线: MAC 帧长 142, dst_mac=注入的 peer, src_mac=板 MAC,
//        IPv4/UDP, 端口 8081/8081, IP 头校验和与 UDP 校验和 (伪头+头+载荷) 正确,
//        载荷逐字节
//     ③ 共存: UDP 帧与 app_pattern 的 TCP 帧在同一 TX 仲裁链上 ⇒ TCP 帧计数 >0
//        (证明 UDP 合流没有抢死/破坏 TCP fast 路径)
//=============================================================================
module tb_p5e_t2_wrapper;
    localparam [31:0] TB_ISS   = 32'h12345678;
    localparam [31:0] ISN0     = TB_ISS + 32'd1;
    localparam [31:0] PEER_ISN = 32'h20000000;

    // UDP app TX 目标 (与 wrapper 的 UDP_APP_PORT / 静态 cfg 镜像)
    localparam [47:0] PEER_MAC  = 48'hAABBCCDDEE01;
    localparam [31:0] PEER_IP   = 32'hC0A86401;   // 192.168.100.1
    localparam [47:0] BOARD_MAC = 48'h000A3501FEC0;
    localparam [31:0] BOARD_IP  = 32'hC0A86402;   // 192.168.100.2
    localparam [15:0] APP_PORT  = 16'h1F91;       // 8081
    localparam integer PLEN     = 100;            // 载荷字节数
    localparam integer NBEAT    = (PLEN + 7) / 8; // 13 拍

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

    reg no_udp;      // +NOUDP: 不推 UDP 帧 (诊断用 — 判 mac_tx 卡死是否与 UDP 通路有关)
    initial if ($test$plusargs("NOUDP")) no_udp = 1'b1; else no_udp = 1'b0;
    integer errs;
    task chk;
        input          cond;
        input [8*72:1] msg;
        begin
            if (!cond) begin errs = errs + 1; $display("  [FAIL] %0s", msg); end
        end
    endtask

    //=========================================================================
    // app UDP TX 拍流 (force; negedge 施加 ⇒ 与 posedge 采样零竞争)
    //=========================================================================
    reg         udp_go;          // 允许推帧 (无 peer 时也会被 shim 挡住)
    integer     ui;
    integer     ib;
    reg [63:0]  ud_d;
    reg [7:0]   ud_k;
    // 载荷图案: 第 idx 字节 = (idx*5+7) & 0xFF (与判据逐字节比对的同一函数)
    function [7:0] pbyte;
        input integer idx;
        begin pbyte = (idx * 5 + 7) & 8'hFF; end
    endfunction
    // 拍 ui 的字: 左对齐 (tdata[63:56] = 首字节), 末拍 4 字节 keep=0xF0
    always @(*) begin
        ud_d = 64'd0; ud_k = 8'h00;
        for (ib = 0; ib < 8; ib = ib + 1) begin
            if (ui * 8 + ib < PLEN) begin
                ud_d[63 - 8*ib -: 8] = pbyte(ui * 8 + ib);
                ud_k[7 - ib]         = 1'b1;
            end
        end
    end
    wire        ud_v = udp_go && (ui < NBEAT);
    wire        ud_l = (ui == NBEAT - 1);

    always @(negedge u_dut.gmii_clk) begin
        force u_dut.app_udp_tx_tvalid = ud_v;
        force u_dut.app_udp_tx_tdata  = ud_d;
        force u_dut.app_udp_tx_tkeep  = ud_k;
        force u_dut.app_udp_tx_tlast  = ud_l;
    end
    always @(posedge u_dut.gmii_clk) begin
        if (ud_v && u_dut.app_udp_tx_tready) ui <= ui + 1;
    end

    //=========================================================================
    // 内部 GMII 捕获 + 帧解码 (前导 8B 后是 MAC 帧; 末 4B = mac_tx_64 的 FCS)
    //=========================================================================
    reg [7:0] gb [0:4095];        // 当前帧字节
    integer   gcnt, gnfr, gufr;   // 当前帧字节数 / 完成帧数 / UDP 帧数
    reg [7:0] uf [0:255];         // 第一帧 UDP 的 MAC 帧字节
    integer   uflen;
    integer   tcp_fr;
    integer   i2;

    always @(posedge u_dut.gmii_clk) begin
        if (u_dut.e_txen) begin
            if (gcnt < 4090) gb[gcnt] = u_dut.e_txd;
            gcnt = gcnt + 1;
        end else if (gcnt != 0) begin
            gnfr = gnfr + 1;
            // 前导 8 字节 (7x55 + D5) 之后 = MAC 帧; FCS 4 字节在末尾
            if ((gcnt >= 8 + 14) && (gb[8+12] == 8'h08) && (gb[8+13] == 8'h00) &&
                (gb[8+23] == 8'h11)) begin
                if (gufr == 0) begin
                    uflen = gcnt - 8 - 4;              // MAC 帧长 (不含前导/FCS)
                    for (i2 = 0; i2 < 256; i2 = i2 + 1)
                        uf[i2] = (i2 < uflen) ? gb[8+i2] : 8'h00;
                end
                gufr = gufr + 1;
                $display("    [gmii] UDP 帧 #%0d: %0d 字节 (MAC 长 %0d)", gufr, gcnt, gcnt-12);
            end else if (gcnt > 12) tcp_fr = tcp_fr + 1;   // 非 UDP (TCP/其他)
            gcnt = 0;
        end
    end
    //=========================================================================
    // 校验和辅助 (16 位反码和)
    //=========================================================================
    reg [31:0] csum_acc;
    task csum_add;
        input integer off;
        input integer nb;
        integer i;
        begin
            for (i = 0; i + 1 < nb; i = i + 2)
                csum_acc = csum_acc + {uf[off+i], uf[off+i+1]};
            if (nb % 2)
                csum_acc = csum_acc + {uf[off+nb-1], 8'h00};
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
    initial begin
        errs = 0; ui = 0; gcnt = 0; gnfr = 0; gufr = 0; uflen = 0;
        tcp_fr = 0; udp_go = 0;
        fpga_gclk = 0; phy1_rxc = 0; reset_n = 0;
        phy1_rxd = 4'h0; phy1_rxctl = 1'b0;
        #400; reset_n = 1;
        repeat (4000) @(posedge u_dut.gmii_clk);      // 等 MMCM/复位稳定

        // ---- 预置连接 (TCB + CAM, 绕过 HLS 慢路径; 照抄 tb_p5_wrapper) ----
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

        // ---- CONN_UP 事件 (照抄) ----
        force u_dut.u_app_ctrl.o_ev_up = 1'b1;
        @(posedge u_dut.gmii_clk);
        release u_dut.u_app_ctrl.o_ev_up;
        repeat (200) @(posedge u_dut.gmii_clk);

        // ================= ① 默认不发送 (peer 未学习) =================
        chk(u_dut.app_udp_tx_ready === 1'b0, "① peer 表空 ⇒ app_udp_tx_ready = 0");
        udp_go <= 1'b1;
        repeat (3000) @(posedge u_dut.gmii_clk);
        chk(ui == 0,        "① 默认不发送: 帧首拍未被接受 (app 侧原地等待)");
        chk(gufr == 0,      "① 默认不发送: 内部 GMII 零 UDP 帧");
        chk(u_dut.u_udp_tx_cfg.stat_deny == 32'd1, "① 拒帧计数 = 1 (每帧 1 次)");
        chk(u_dut.u_udp_tx_cfg.stat_frames == 32'd0, "① shim 未放行任何帧");

        // ================= ② 注入 peer =========================================
        // ⚠️ P5e-T3 更新: peer 学习源已从慢路径 CONN_UP (scfg_ev_*) 改为
        //   **learn-on-RX** (u_udp_split.meta_* → u_udp_tx_cfg.peer_wr)。
        //   本 TB 的激励随之改为 force wrapper 的 meta 线束 — 这样仍然覆盖
        //   wrapper 里 "meta → peer_wr/peer_mac/peer_ip" 的**接线本身** (坑 8),
        //   只跳过 udp_split 生成 meta 的那一段 (那段由 T3 的
        //   sim/p5e_udp/run_tb_p5e_udp_wrapper.bat 用真 GMII 注入的 UDP 帧覆盖)。
        //   判据 ①②③ 一字未改。
        if (!no_udp) begin
        force u_dut.udp_meta_src_mac  = PEER_MAC;
        force u_dut.udp_meta_src_ip   = PEER_IP;
        force u_dut.udp_meta_valid = 1'b1;
        @(posedge u_dut.gmii_clk);
        release u_dut.udp_meta_valid;
        release u_dut.udp_meta_src_mac;
        release u_dut.udp_meta_src_ip;
        end else $display("  [dbg] NOUDP: 不注入 peer (UDP 通路全程静默)");
        repeat (20) @(posedge u_dut.gmii_clk);
        chk(u_dut.app_udp_tx_ready === 1'b1, "② peer 学习后 app_udp_tx_ready = 1");
        $display("  [dbg] ready=%b tready=%b ui=%0d peer_v=%b cfg_sync=%b busy=%b o_dip=%08h deny=%0d",
                 u_dut.app_udp_tx_ready, u_dut.app_udp_tx_tready, ui,
                 u_dut.u_udp_tx_cfg.peer_v, u_dut.u_udp_tx_cfg.cfg_sync,
                 u_dut.u_udp_tx_cfg.frame_busy, u_dut.u_udp_tx_cfg.o_dst_ip,
                 u_dut.u_udp_tx_cfg.stat_deny);

        // 等被挡的帧原样上线 (peer 注入后不丢帧)
        for (i = 0; i < 40000; i = i + 1) begin
            if (gufr >= 1) i = 40000; else @(posedge u_dut.gmii_clk);
        end
        repeat (500) @(posedge u_dut.gmii_clk);

        
        
        // ---- 帧字段判据 (wrapper 内部 GMII 解码) ----
        if (no_udp) begin
            $display("  [dbg] NOUDP: mac_tx state=%0d plen=%0d cw_len=%0d ffull=%b abort=%0d tcp_tx_fr=%0d tcp_fr=%0d",
                     u_dut.u_mac_tx.state, u_dut.u_mac_tx.plen, u_dut.u_mac_tx.cw_len,
                     u_dut.u_mac_tx.ffull, u_dut.u_mac_tx.stat_abort,
                     u_dut.u_tcp_tx.stat_frames, tcp_fr);
            if (u_dut.u_mac_tx.state == 3'd0 && u_dut.u_mac_tx.stat_abort == 32'd0)
                $display("P5E-T2 WRAPPER GATE: OK");
            else
                $display("P5E-T2 NOUDP GATE: mac_tx 卡死 state=%0d", u_dut.u_mac_tx.state);
            $finish;
        end
        chk(gufr == 1, "② 内部 GMII 恰 1 帧 UDP");
        chk(uflen == 14 + 20 + 8 + PLEN, "② MAC 帧长 = 42 + 载荷");
        chk({uf[0],uf[1],uf[2],uf[3],uf[4],uf[5]} === PEER_MAC, "② dst mac = 学习的 peer");
        chk({uf[6],uf[7],uf[8],uf[9],uf[10],uf[11]} === BOARD_MAC, "② src mac = 板 MAC");
        chk({uf[12],uf[13]} === 16'h0800, "② ethertype = IPv4");
        chk(uf[23] === 8'h11, "② IP proto = UDP");
        chk({uf[16],uf[17]} === (PLEN + 28), "② IP total_len");
        csum_acc = 32'd0; csum_add(14, 20);
        chk(fold32(csum_acc) === 16'hFFFF, "② IP 头校验和正确");
        chk({uf[26],uf[27],uf[28],uf[29]} === BOARD_IP, "② src ip = 192.168.100.2");
        chk({uf[30],uf[31],uf[32],uf[33]} === PEER_IP, "② dst ip = 学习的 peer");
        chk({uf[34],uf[35]} === APP_PORT, "② src port = 8081");
        chk({uf[36],uf[37]} === APP_PORT, "② dst port = 8081");
        chk({uf[38],uf[39]} === (PLEN + 8), "② UDP len");
        csum_acc = 32'd0;
        csum_add(26, 8);
        csum_acc = csum_acc + 16'h0011 + {uf[38], uf[39]};
        csum_add(34, 8 + PLEN);
        chk(fold32(csum_acc) === 16'hFFFF, "② UDP 校验和正确 (伪头+头+载荷)");
        for (i = 0; i < PLEN; i = i + 1)
            chk(uf[42+i] === pbyte(i), "② 载荷逐字节");
        chk(u_dut.u_udp_tx_cfg.stat_frames == 32'd1, "② shim stat_frames = 1");
        chk(u_dut.u_udp_tx.stat_frames == 32'd1,     "② 帧器 stat_frames = 1");
        chk(u_dut.u_udp_tx.stat_drop_len == 32'd0,   "② 无长度丢弃");
        chk(ui == NBEAT,                             "② 拍流全部被接受");

        // ================= ③ 与 TCP fast 路径共存 =================
        for (i = 0; i < 40000; i = i + 1) begin
            if (u_dut.u_tcp_tx.stat_frames > 0) i = 40000;
            else @(posedge u_dut.gmii_clk);
        end
        chk(u_dut.u_tcp_tx.stat_frames > 0, "③ TCP fast TX 照常 (共享 u_tx_arb)");
        chk(tcp_fr > 0,                     "③ GMII 上仍有 TCP 帧");
        chk(u_dut.u_mac_tx.stat_abort == 32'd0, "③ mac_tx 无中止 (帧原子性)");
        $display("P5E-T2 WRAPPER: gnfr=%0d udp=%0d tcp=%0d tcp_tx_fr=%0d udp_tx_fr=%0d",
                 gnfr, gufr, tcp_fr, u_dut.u_tcp_tx.stat_frames,
                 u_dut.u_udp_tx.stat_frames);

        if (errs == 0) $display("P5E-T2 WRAPPER GATE: OK");
        else           $display("P5E-T2 WRAPPER GATE: FAIL errs=%0d", errs);
        $finish;
    end
endmodule
