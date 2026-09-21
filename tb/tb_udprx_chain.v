`timescale 1ns/1ps
//=============================================================================
// tb_udprx_chain — 高载荷率 RX 全链: GMII 字节流 → mac_rx_64 → rx_classify
//                 → udp_split (app RX 口) → app_udp_pattern 校验器
//=============================================================================
// 与 tb_udprx_rate (单元级, 直灌 udp_split) 的差别 = **上游两级的真实节拍**:
//   · mac_rx_64 的 4 字节 FCS 前瞻 + 保持字 (hwreg) 机制 ⇒ 出词节拍与原字流不同
//   · rx_classify 的 6 字 skid: 非 TCP 帧在 w2 拍定案 ⇒ S_DRAIN 期间 s_tready=0
//     (>=3 拍/帧) ⇒ mac_rx_64 的 8 深 FIFO 蓄水 ⇒ **下游看到的是成串突发词**
//     (不是单元门里的均匀 1 字/8 拍)
//   · 帧尾 tkeep (1518B 帧 = 190 字, 末字 2 字节有效) 由真实 FCS 剥离产生
//
// 判据 (与单元门相同):
//   ① mac_rx 无丢帧/无 CRC 错 (stat_drop=0, stat_crc_err=0)
//   ② udp_rx 载荷直出流逐字节 == 期望图案 (定位上游 vs 帧缓冲/播放器)
//   ③ app RX 口逐字节 == 期望图案 (在线独立比对)
//   ④ app 收字节精确 / 失配分类 (首字/尾字/帧身 + 字内位置)
//=============================================================================
module tb_udprx_chain;

`ifdef PL512
    localparam integer PLEN = 512;
`elsif PL996
    localparam integer PLEN = 996;
`elsif PL1473
    localparam integer PLEN = 1473;
`else
    localparam integer PLEN = 1472;
`endif
`ifdef NFRM8
    localparam integer NFRM = 8;
`elsif NFRM64
    localparam integer NFRM = 64;
`else
    localparam integer NFRM = 200;
`endif
`ifdef IDL64
    localparam integer IDLE = 64;
`elsif IDL120
    localparam integer IDLE = 120;
`else
    localparam integer IDLE = 12;
`endif

    localparam integer FLEN  = 14 + 20 + 8 + PLEN;        // MAC 帧 (不含 FCS)
    localparam integer NW    = (FLEN + 7) / 8;
    localparam integer LASTN = FLEN - 8*(NW-1);
    localparam integer NPW   = (PLEN + 7) / 8;
    localparam integer FB    = 8 + FLEN + 4;              // 每帧 GMII 字节 (前导+帧+FCS)
    localparam integer TOTB  = NFRM * (FB + IDLE);

    localparam [47:0] PEER_MAC  = 48'h112233445566;
    localparam [47:0] BOARD_MAC = 48'h000A3501FEC0;
    localparam [31:0] PEER_IP   = 32'hC0A86401;
    localparam [31:0] BOARD_IP  = 32'hC0A86402;
    localparam [15:0] PEER_PORT = 16'h3039;
    localparam [15:0] APP_PORT  = 16'h1F91;
    localparam [63:0] SEED      = 64'h9E3779B97F4A7C15;

    reg clk, rst_n;
    always #4 clk = ~clk;      // 125 MHz = 1 Gbps 线速 (1 字节/拍)

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

    function [7:0] byte_at;
        input [63:0] d;
        input [3:0]  i;
        begin
            case (i)
                4'd0: byte_at = d[63:56];
                4'd1: byte_at = d[55:48];
                4'd2: byte_at = d[47:40];
                4'd3: byte_at = d[39:32];
                4'd4: byte_at = d[31:24];
                4'd5: byte_at = d[23:16];
                4'd6: byte_at = d[15:8];
                default: byte_at = d[7:0];
            endcase
        end
    endfunction

    function [3:0] pop8;
        input [7:0] v;
        integer i;
        reg [3:0] c;
        begin
            c = 4'd0;
            for (i = 0; i < 8; i = i + 1) c = c + {3'b0, v[i]};
            pop8 = c;
        end
    endfunction

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

    //=========================================================================
    // GMII 字节缓冲 (一次建好: NFRM 帧, 每帧 = 前导8 + 帧1514 + FCS4 + 空闲IDLE)
    //=========================================================================
    reg  [7:0]  gb [0:TOTB-1];
    reg         gv [0:TOTB-1];        // dv
    reg  [63:0] bg_lfsr;
    integer     ii, jj, fi;

    task build_stream;
        reg [31:0] c;
        integer    base, off, j;
        begin
            bg_lfsr = SEED;
            for (fi = 0; fi < NFRM; fi = fi + 1) begin
                base = fi * (FB + IDLE);
                for (j = 0; j < 7; j = j + 1) begin gb[base+j] = 8'h55; gv[base+j] = 1'b1; end
                gb[base+7] = 8'hD5; gv[base+7] = 1'b1;
                off = base + 8;
                // MAC + IPv4 + UDP
                gb[off+0]  = BOARD_MAC[47:40]; gb[off+1]  = BOARD_MAC[39:32];
                gb[off+2]  = BOARD_MAC[31:24]; gb[off+3]  = BOARD_MAC[23:16];
                gb[off+4]  = BOARD_MAC[15:8];  gb[off+5]  = BOARD_MAC[7:0];
                gb[off+6]  = PEER_MAC[47:40];  gb[off+7]  = PEER_MAC[39:32];
                gb[off+8]  = PEER_MAC[31:24];  gb[off+9]  = PEER_MAC[23:16];
                gb[off+10] = PEER_MAC[15:8];   gb[off+11] = PEER_MAC[7:0];
                gb[off+12] = 8'h08; gb[off+13] = 8'h00;
                gb[off+14] = 8'h45; gb[off+15] = 8'h00;
                gb[off+16] = ((PLEN+28) >> 8) & 8'hFF; gb[off+17] = (PLEN+28) & 8'hFF;
                gb[off+18] = 8'h12; gb[off+19] = 8'h34;
                gb[off+20] = 8'h40; gb[off+21] = 8'h00;
                gb[off+22] = 8'd64;  gb[off+23] = 8'h11;
                gb[off+24] = 8'h00;  gb[off+25] = 8'h00;
                gb[off+26] = PEER_IP[31:24];  gb[off+27] = PEER_IP[23:16];
                gb[off+28] = PEER_IP[15:8];   gb[off+29] = PEER_IP[7:0];
                gb[off+30] = BOARD_IP[31:24]; gb[off+31] = BOARD_IP[23:16];
                gb[off+32] = BOARD_IP[15:8];  gb[off+33] = BOARD_IP[7:0];
                c = 32'd0;
                for (j = 0; j < 10; j = j + 1)
                    c = c + {16'b0, gb[off+14+2*j], gb[off+15+2*j]};
                c = (c & 32'hFFFF) + (c >> 16);
                c = (c & 32'hFFFF) + (c >> 16);
                c = ~c;
                gb[off+24] = c[15:8]; gb[off+25] = c[7:0];
                gb[off+34] = PEER_PORT[15:8];  gb[off+35] = PEER_PORT[7:0];
                gb[off+36] = APP_PORT[15:8];   gb[off+37] = APP_PORT[7:0];
                gb[off+38] = ((PLEN+8) >> 8) & 8'hFF; gb[off+39] = (PLEN+8) & 8'hFF;
                gb[off+40] = 8'h00; gb[off+41] = 8'h00;
                for (j = 0; j < PLEN; j = j + 1) begin
                    gb[off+42+j] = bg_lfsr[31:24];
                    bg_lfsr = xs_next(bg_lfsr);
                end
                for (j = 0; j < FLEN; j = j + 1) gv[off+j] = 1'b1;
                // FCS (小端上线)
                c = 32'hFFFFFFFF;
                for (j = 0; j < FLEN; j = j + 1) c = crc32_byte(c, gb[off+j]);
                c = ~c;
                gb[off+FLEN+0] = c[7:0];  gb[off+FLEN+1] = c[15:8];
                gb[off+FLEN+2] = c[23:16]; gb[off+FLEN+3] = c[31:24];
                for (j = 0; j < 4; j = j + 1) gv[off+FLEN+j] = 1'b1;
                // 空闲 (IFG/限速)
                for (j = 0; j < IDLE; j = j + 1) begin
                    gb[base+FB+j] = 8'h00; gv[base+FB+j] = 1'b0;
                end
            end
        end
    endtask

    // 字节驱动 (寄存计数器 + 组合选字节 ⇒ 无 0 延迟竞争, 坑 17)
    reg  [31:0] bi;
    wire [7:0]  g_rxd  = (bi < TOTB) ? gb[bi] : 8'h00;
    wire        g_dv   = (bi < TOTB) ? gv[bi] : 1'b0;
    wire        g_er   = 1'b0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) bi <= 32'd0;
        else if (bi < TOTB) bi <= bi + 32'd1;
    end

    //=========================================================================
    // 链路: mac_rx_64 → rx_classify → udp_split → app_udp_pattern
    //=========================================================================
    wire [63:0] m_d;   wire [7:0] m_k;   wire m_v, m_l, m_u, m_c, m_e;
    wire        m_r;
    wire [31:0] mac_frames, mac_crc, mac_drop, mac_bytes, mac_words;
    wire [63:0] cf_d;  wire [7:0] cf_k;  wire cf_v, cf_l, cf_u, cf_c, cf_e, cf_r;
    wire [31:0] cls_fast, cls_slow, cls_win, cls_wout;

    mac_rx_64 u_mac (
        .clk(clk), .rst_n(rst_n),
        .gmii_rxd(g_rxd), .gmii_rx_dv(g_dv), .gmii_rx_er(g_er),
        .m_axis_tdata(m_d), .m_axis_tkeep(m_k), .m_axis_tvalid(m_v),
        .m_axis_tready(m_r), .m_axis_tlast(m_l), .m_axis_tuser(m_u),
        .m_axis_terr(m_e), .m_axis_tcrs(m_c),
        .stat_frames(mac_frames), .stat_crc_err(mac_crc), .stat_drop(mac_drop),
        .stat_bytes(mac_bytes), .dbg_stat_words_out(mac_words)
    );

    rx_classify u_cls (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(m_d), .s_axis_tkeep(m_k), .s_axis_tvalid(m_v),
        .s_axis_tready(m_r), .s_axis_tlast(m_l), .s_axis_tuser(m_u),
        .s_axis_tcrs(m_c), .s_axis_terr(m_e),
        .m_fast_tdata(), .m_fast_tkeep(), .m_fast_tvalid(), .m_fast_tready(1'b1),
        .m_fast_tlast(), .m_fast_tuser(), .m_fast_tcrs(), .m_fast_terr(),
        .m_slow_tdata(cf_d), .m_slow_tkeep(cf_k), .m_slow_tvalid(cf_v),
        .m_slow_tready(cf_r), .m_slow_tlast(cf_l), .m_slow_tuser(cf_u),
        .m_slow_tcrs(cf_c), .m_slow_terr(cf_e),
        .stat_fast(cls_fast), .stat_slow(cls_slow),
        .dbg_stat_words_in(cls_win), .dbg_stat_words_out(cls_wout)
    );

    wire [63:0] a_d;  wire [7:0] a_k;  wire a_v, a_l, a_sf;
    wire [15:0] a_len, a_sp;  wire [31:0] a_sip;  wire a_r;
    wire        mu_v; wire [47:0] mu_mac; wire [31:0] mu_ip;
    wire [15:0] mu_port, mu_len;
    wire [31:0] st_frames, st_bytes, st_null, st_crc, st_ovf, st_part, st_excl;
    wire [31:0] st_hf, st_hd, st_hs;

    udp_split u_split (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(cf_d), .s_axis_tkeep(cf_k), .s_axis_tvalid(cf_v),
        .s_axis_tready(cf_r), .s_axis_tlast(cf_l), .s_axis_tuser(cf_u),
        .s_axis_tcrs(cf_c), .s_axis_terr(cf_e),
        .p_axis_tdata(), .p_axis_tkeep(), .p_axis_tvalid(), .p_axis_tready(1'b1),
        .p_axis_tlast(), .p_axis_tuser(), .p_axis_tcrs(), .p_axis_terr(),
        .app_rx_tdata(a_d), .app_rx_tkeep(a_k), .app_rx_tvalid(a_v),
        .app_rx_tready(a_r), .app_rx_tlast(a_l), .app_rx_sof(a_sf),
        .app_rx_len(a_len), .app_rx_src_ip(a_sip), .app_rx_src_port(a_sp),
        .meta_valid(mu_v), .meta_src_mac(mu_mac), .meta_src_ip(mu_ip),
        .meta_src_port(mu_port), .meta_len(mu_len),
        .cfg_dst_ip(BOARD_IP), .cfg_multi_en(1'b0),
        .cfg_port0(APP_PORT), .cfg_port1(16'hFFFF),
        .cfg_port2(16'hFFFF), .cfg_port3(16'hFFFF), .cfg_port_any(1'b0),
        .stat_app_frames(st_frames), .stat_app_bytes(st_bytes), .stat_app_null(st_null),
        .stat_drop_crc(st_crc), .stat_drop_ovf(st_ovf), .stat_drop_part(st_part),
        .stat_drop_excl(st_excl),
        .stat_hls_frames(st_hf), .stat_hls_drop(st_hd), .stat_hls_split(st_hs)
    );

    wire [31:0] ap_txb, ap_txf, ap_rxb, ap_rxf, ap_null, ap_mm;
    app_udp_pattern #(.TX_BYTES(32'd0), .TX_GAP(16'd0)) u_app (
        .clk(clk), .rst_n(rst_n),
        .i_en(1'b1), .i_tx_ready(1'b0), .i_paylen(12'd1472),
        .m_tdata(), .m_tkeep(), .m_tvalid(), .m_tready(1'b1), .m_tlast(),
        .rx_tdata(a_d), .rx_tkeep(a_k), .rx_tvalid(a_v), .rx_tready(a_r),
        .rx_tlast(a_l), .rx_sof(a_sf), .rx_len(a_len),
        .stat_tx_bytes(ap_txb), .stat_tx_frames(ap_txf),
        .stat_rx_bytes(ap_rxb), .stat_rx_frames(ap_rxf),
        .stat_rx_null(ap_null), .stat_mismatch(ap_mm),
        .active(), .done(), .led()
    );

    //=========================================================================
    // 判据侧: 两条独立期望流 (udp_rx 直出 / app 口)
    //=========================================================================
    reg  [63:0] exp_a, exp_m;
    integer     a_bytes, m_bytes, a_mm, m_mm;
    integer     a_widx, m_widx, a_fr, m_fr;
    reg         m_sync;
    integer     cls_first, cls_last, cls_mid, cls_w0, cls_w7, cls_winb;
    integer     nshow;
    reg  [7:0]  got_b, exp_b;
    integer     gi, gidx, gj;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            exp_a <= SEED; exp_m <= SEED;
            a_bytes <= 0; m_bytes <= 0; a_mm <= 0; m_mm <= 0;
            a_widx <= 0; m_widx <= 0; a_fr <= 0; m_fr <= 0; m_sync <= 1'b0;
            cls_first <= 0; cls_last <= 0; cls_mid <= 0;
            cls_w0 <= 0; cls_w7 <= 0; cls_winb <= 0; nshow <= 0;
        end else begin
            if (a_v && a_r) begin
                if (a_sf) begin a_widx <= 1; a_fr <= a_fr + 1; end
                else       a_widx <= a_widx + 1;
                gidx = a_sf ? 0 : a_widx;
                for (gi = 0; gi < 8; gi = gi + 1) begin
                    if (gi < pop8(a_k)) begin
                        got_b = byte_at(a_d, gi[3:0]);
                        exp_b = exp_a[31:24];
                        exp_a = xs_next(exp_a);
                        a_bytes = a_bytes + 1;
                        if (got_b !== exp_b) begin
                            a_mm = a_mm + 1;
                            if (a_l)          cls_last = cls_last + 1;
                            else if (gidx==0) cls_first = cls_first + 1;
                            else              cls_mid = cls_mid + 1;
                            if (gi == 0)      cls_w0 = cls_w0 + 1;
                            else if (gi == 7) cls_w7 = cls_w7 + 1;
                            else              cls_winb = cls_winb + 1;
                            if (nshow < 30) begin
                                $display("  [AMM] app#%0d frm=%0d widx=%0d gi=%0d last=%b got=%02h exp=%02h",
                                         a_mm, a_fr, gidx, gi, a_l, got_b, exp_b);
                                nshow = nshow + 1;
                            end
                        end
                    end
                end
            end
            if (u_split.u_meta_valid) m_sync = 1'b1;
            if (u_split.u_m_v) begin
                if (m_sync) begin m_widx <= 1; m_sync = 1'b0; m_fr <= m_fr + 1; end
                else        m_widx <= m_widx + 1;
                gj = m_sync ? 0 : m_widx;
                for (gi = 0; gi < 8; gi = gi + 1) begin
                    if (gi < pop8(u_split.u_m_k)) begin
                        got_b = byte_at(u_split.u_m_d, gi[3:0]);
                        exp_b = exp_m[31:24];
                        exp_m = xs_next(exp_m);
                        m_bytes = m_bytes + 1;
                        if (got_b !== exp_b) begin
                            m_mm = m_mm + 1;
                            if (m_mm < 20)
                                $display("  [MMM] udprx#%0d frm=%0d widx=%0d gi=%0d last=%b got=%02h exp=%02h",
                                         m_mm, m_fr, gj, gi, u_split.u_m_l, got_b, exp_b);
                        end
                    end
                end
            end
        end
    end

    //=========================================================================
    // 主时间线
    //=========================================================================
    integer errs;
    task chk;
        input          cond;
        input [8*72:1] msg;
        begin
            if (!cond) begin errs = errs + 1; $display("  [FAIL] %0s", msg); end
        end
    endtask

    reg [31:0] crc_chk;
    initial begin
        errs = 0; nshow = 0;
        clk = 0; rst_n = 0;
        build_stream;
        $display("  [cfg] PLEN=%0d FLEN=%0d NW=%0d LASTN=%0d NFRM=%0d IDLE=%0d TOTB=%0d",
                 PLEN, FLEN, NW, LASTN, NFRM, IDLE, TOTB);
        crc_chk = 32'hFFFFFFFF;
        crc_chk = crc32_byte(crc_chk, 8'h31); crc_chk = crc32_byte(crc_chk, 8'h32);
        crc_chk = crc32_byte(crc_chk, 8'h33); crc_chk = crc32_byte(crc_chk, 8'h34);
        crc_chk = crc32_byte(crc_chk, 8'h35); crc_chk = crc32_byte(crc_chk, 8'h36);
        crc_chk = crc32_byte(crc_chk, 8'h37); crc_chk = crc32_byte(crc_chk, 8'h38);
        crc_chk = crc32_byte(crc_chk, 8'h39);
        crc_chk = ~crc_chk;
        chk(crc_chk === 32'hCBF43926, "TB CRC32 自检 (标准 check 值)");
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (TOTB + NFRM*NW*8 + 20000) @(posedge clk);

        $display("  [dbg] mac_rx: frames=%0d crc_err=%0d drop=%0d bytes=%0d words=%0d",
                 mac_frames, mac_crc, mac_drop, mac_bytes, mac_words);
        $display("  [dbg] classify: slow=%0d fast=%0d win=%0d wout=%0d | byteseq=%0d",
                 cls_slow, cls_fast, cls_win, cls_wout, bi);
        $display("  [dbg] split: frames=%0d bytes=%0d crc=%0d ovf=%0d part=%0d excl=%0d hls_fr=%0d",
                 st_frames, st_bytes, st_crc, st_ovf, st_part, st_excl, st_hf);
        $display("  [dbg] app: bytes=%0d frames=%0d null=%0d mismatch=%0d | shadow bytes=%0d mm=%0d",
                 ap_rxb, ap_rxf, ap_null, ap_mm, a_bytes, a_mm);
        $display("  [dbg] udprx tap: bytes=%0d mm=%0d frames=%0d", m_bytes, m_mm, m_fr);
        $display("  [dbg] classes: first=%0d last=%0d mid=%0d | w0=%0d w7=%0d inner=%0d",
                 cls_first, cls_last, cls_mid, cls_w0, cls_w7, cls_winb);

        chk(mac_crc == 0,   "① mac_rx 零 CRC 错");
        chk(mac_drop == 0,  "① mac_rx 零丢帧");
        chk(mac_frames == NFRM, "① mac_rx 帧数 == 注入帧数");
        chk(cls_slow == NFRM, "① classify 全部走 slow");
        chk(st_frames == NFRM, "② udp_split 交付帧数 == 注入帧数");
        chk(ap_rxb == NFRM*PLEN, "④ app 收字节 == 送出载荷");
        chk(a_bytes == NFRM*PLEN, "④ 比对字节 == 送出载荷");
        chk(m_mm == 0, "② udp_rx 直出流零失配");
        chk(a_mm == 0, "③ app RX 口零失配 (TB 独立期望)");
        chk(ap_mm == 0, "④ DUT stat_mismatch == 0");
        if (errs == 0) $display("UDPRX CHAIN GATE: OK (PLEN=%0d NFRM=%0d IDLE=%0d)", PLEN, NFRM, IDLE);
        else           $display("UDPRX CHAIN GATE: FAIL errs=%0d", errs);
        $finish;
    end

    initial begin
        repeat (300000000) @(posedge clk);
        $display("UDPRX CHAIN GATE: TIMEOUT (bi=%0d)", bi);
        $finish;
    end
endmodule
