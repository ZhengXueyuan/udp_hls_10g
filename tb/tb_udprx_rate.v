`timescale 1ns/1ps
//=============================================================================
// tb_udprx_rate — 独立复核门: app UDP **RX 方向高载荷率**字节保真
//=============================================================================
// 背景: 板级验收 (peer --udp-send-pattern / --rate-mbps) 在 >=400 Mbps 时
//   app_udp_pattern.stat_mismatch != 0 (0.09%..0.21% 字节), 而 100 Mbps 恒 0;
//   URB (收字节) 精确, UOV/UPC/UPA 全 0 (无丢帧/无溢出/无坏 FCS)。
//   ⇒ 缺陷在 "mac_rx FCS 校验之后 → app 比较器之前" 的板内 RX 通路。
//
// 本门: 单元级复现 —— udp_split (app RX 口) + app_udp_pattern (逐字节校验器),
//   以**与板级同构**的字流灌入 (mac_rx_64 输出约定: 左对齐 + SOP tuser +
//   TLAST tcrs), 帧长/载荷 与板级一致 (1472 / 512 / 996), 速率旋钮 = 字间隔
//   WSP (线速 = 每 8 拍 1 字) + 帧间 IPG。
//
// 判据 (全部为 TB 自造的独立期望, 不信 DUT 内部计数):
//   ① s_axis_tready 恒 1 (T1 的"结构性不反压"合同, 高载荷率下的专项断言)
//   ② 每一帧的线上字序列与 UDP 头字段自检 (长度/端口/校验和)
//   ③ **app RX 口逐字节 == 期望图案流** (在线比对, 记录每个失配的
//      {全局字节号, 帧内载荷偏移, 帧内字号, 首字/尾字标志})
//   ④ udp_rx 载荷直出流 (u_m_*) 逐字节 == 期望 (定位: udp_rx vs 帧缓冲/播放器)
//   ⑤ app 内部 stat_rx_bytes == 送出的载荷字节 (URB 精确性)
//   ⑥ 失配按"帧内位置"分类统计 (首字/尾字/帧身) —— 板级"每帧 1~2 字节"模式的判据
//
// 旋钮 (xvlog -d):
//   PLEN: PL512 / PL996 / (默认 1472)
//   NFRM: NFRM8 / NFRM64 / (默认 200)
//   WSP : WSP1 / WSP2 / WSP4 / WSP27 (≈400Mbps) / (默认 8)
//   IPG : NOIPG (0) / (默认 12)
//=============================================================================
module tb_udprx_rate;

`ifdef PL512
    localparam integer PLEN = 512;
`elsif PL996
    localparam integer PLEN = 996;
`elsif PL1471
    localparam integer PLEN = 1471;
`elsif PL1473
    localparam integer PLEN = 1473;
`elsif PL1480
    localparam integer PLEN = 1480;
`else
    localparam integer PLEN = 1472;
`endif
`ifdef NFRM8
    localparam integer NFRM = 8;
`elsif NFRM64
    localparam integer NFRM = 64;
`elsif NFRM1000
    localparam integer NFRM = 1000;
`else
    localparam integer NFRM = 200;
`endif
`ifdef WSP1
    localparam integer WSP = 1;
`elsif WSP2
    localparam integer WSP = 2;
`elsif WSP4
    localparam integer WSP = 4;
`elsif WSP27
    localparam integer WSP = 27;
`elsif WSP16
    localparam integer WSP = 16;
`else
    localparam integer WSP = 8;
`endif
`ifdef NOIPG
    localparam integer IPG = 0;
`else
    localparam integer IPG = 12;
`endif

    localparam integer FLEN = 14 + 20 + 8 + PLEN;      // 帧字节 (不含 FCS)
    localparam integer NW   = (FLEN + 7) / 8;          // 帧字数
    localparam integer LASTN= FLEN - 8*(NW-1);         // 末字有效字节数
    localparam integer NPW  = (PLEN + 7) / 8;          // 载荷字数

    // 板级同源的地址/端口 (镜像 wrapper_p4 APP_MODE 的 udp_split 配置)
    localparam [47:0] PEER_MAC  = 48'h112233445566;
    localparam [47:0] BOARD_MAC = 48'h000A3501FEC0;
    localparam [31:0] PEER_IP   = 32'hC0A86401;        // 192.168.100.1
    localparam [31:0] BOARD_IP  = 32'hC0A86402;        // 192.168.100.2
    localparam [15:0] PEER_PORT = 16'h3039;            // 12345
    localparam [15:0] APP_PORT  = 16'h1F91;            // 8081
    localparam [63:0] SEED      = 64'h9E3779B97F4A7C15;

    reg clk, rst_n;
    always #4 clk = ~clk;      // 125 MHz

    //=========================================================================
    // 图案 / 打包辅助 (与 app_udp_pattern / peer.cpp 同款: 先取后推进)
    //=========================================================================
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

    // 右对齐 -> 左对齐 (显式 case, 禁变移位量)
    function [63:0] lj8;
        input [63:0] s;
        input [3:0]  n;
        begin
            case (n)
                4'd1: lj8 = {s[7:0],  56'b0};
                4'd2: lj8 = {s[15:0], 48'b0};
                4'd3: lj8 = {s[23:0], 40'b0};
                4'd4: lj8 = {s[31:0], 32'b0};
                4'd5: lj8 = {s[39:0], 24'b0};
                4'd6: lj8 = {s[47:0], 16'b0};
                4'd7: lj8 = {s[55:0],  8'b0};
                default: lj8 = s;
            endcase
        end
    endfunction

    function [7:0] km8;
        input [3:0] n;
        begin
            case (n)
                4'd0: km8 = 8'h00;
                4'd1: km8 = 8'h80;
                4'd2: km8 = 8'hC0;
                4'd3: km8 = 8'hE0;
                4'd4: km8 = 8'hF0;
                4'd5: km8 = 8'hF8;
                4'd6: km8 = 8'hFC;
                4'd7: km8 = 8'hFE;
                default: km8 = 8'hFF;
            endcase
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

    //=========================================================================
    // 帧缓冲 (仅载荷逐帧变化; 头/长度恒定)
    //=========================================================================
    // fb[0..7] = 前导 (仅占位, 不进字流); fb[8+j] = MAC 帧第 j 字节
    reg  [7:0]  fb [0:FLEN+7];
    reg  [63:0] gen_lfsr;         // 发送侧图案流 (跨帧连续)
    integer     k, k2;

    task build_header;
        reg [31:0] c;
        integer    j;
        begin
            for (j = 0; j < 7; j = j + 1) fb[j] = 8'h55;
            fb[7] = 8'hD5;                       // 前导 (TB 内部用, 不注入字流)
            fb[8+0]  = BOARD_MAC[47:40]; fb[8+1]  = BOARD_MAC[39:32];
            fb[8+2]  = BOARD_MAC[31:24]; fb[8+3]  = BOARD_MAC[23:16];
            fb[8+4]  = BOARD_MAC[15:8];  fb[8+5]  = BOARD_MAC[7:0];
            fb[8+6]  = PEER_MAC[47:40];  fb[8+7]  = PEER_MAC[39:32];
            fb[8+8]  = PEER_MAC[31:24];  fb[8+9]  = PEER_MAC[23:16];
            fb[8+10] = PEER_MAC[15:8];   fb[8+11] = PEER_MAC[7:0];
            fb[8+12] = 8'h08; fb[8+13] = 8'h00;
            fb[8+14] = 8'h45; fb[8+15] = 8'h00;
            fb[8+16] = ((PLEN+28) >> 8) & 8'hFF; fb[8+17] = (PLEN+28) & 8'hFF;
            fb[8+18] = 8'h12; fb[8+19] = 8'h34;
            fb[8+20] = 8'h40; fb[8+21] = 8'h00;
            fb[8+22] = 8'd64;  fb[8+23] = 8'h11;
            fb[8+24] = 8'h00;  fb[8+25] = 8'h00;
            fb[8+26] = PEER_IP[31:24];  fb[8+27] = PEER_IP[23:16];
            fb[8+28] = PEER_IP[15:8];   fb[8+29] = PEER_IP[7:0];
            fb[8+30] = BOARD_IP[31:24]; fb[8+31] = BOARD_IP[23:16];
            fb[8+32] = BOARD_IP[15:8];  fb[8+33] = BOARD_IP[7:0];
            c = 32'd0;
            for (j = 0; j < 10; j = j + 1)
                c = c + {16'b0, fb[8+14+2*j], fb[8+15+2*j]};
            c = (c & 32'hFFFF) + (c >> 16);
            c = (c & 32'hFFFF) + (c >> 16);
            c = ~c;
            fb[8+24] = c[15:8]; fb[8+25] = c[7:0];       // 网络序 (大端)
            fb[8+34] = PEER_PORT[15:8];  fb[8+35] = PEER_PORT[7:0];
            fb[8+36] = APP_PORT[15:8];   fb[8+37] = APP_PORT[7:0];
            fb[8+38] = ((PLEN+8) >> 8) & 8'hFF; fb[8+39] = (PLEN+8) & 8'hFF;
            fb[8+40] = 8'h00; fb[8+41] = 8'h00;
        end
    endtask

    task build_payload;                       // 推进 gen_lfsr (跨帧连续)
        integer j;
        begin
            for (j = 0; j < PLEN; j = j + 1) begin
                fb[8 + 42 + j] = gen_lfsr[31:24];
                gen_lfsr = xs_next(gen_lfsr);
            end
        end
    endtask

    //=========================================================================
    // 源: 字流注入 (mac_rx_64 输出约定)
    //=========================================================================
    reg  [63:0] in_d;
    reg  [7:0]  in_k;
    reg         in_v, in_l, in_u, in_c, in_e;
    // 输入侧线网 (先声明后用 —— xvlog 坑 22)
    wire [63:0] s_tdata  = in_d;
    wire [7:0]  s_tkeep  = in_k;
    wire        s_tvalid = in_v;
    wire        s_tlast  = in_l;
    wire        s_tuser  = in_u;
    wire        s_tcrs   = in_c;
    wire        s_terr   = in_e;
    wire        s_tready;
    reg  [63:0] wd;
    reg  [7:0]  wk;
    integer     idx, gap, fidx, ninj;
    reg         inj_run;

    localparam [1:0] SST_IDLE = 2'd0, SST_WORD = 2'd1, SST_GAP = 2'd2, SST_DONE = 2'd3;
    reg  [1:0] sst;

    task present_word;                        // 组合: 由 fb 生成第 idx 字
        integer j; reg [63:0] t; integer nb;
        begin
            nb = (idx == NW-1) ? LASTN : 8;
            t = 64'd0;
            for (j = 0; j < 8; j = j + 1)
                t = {t[55:0], (j < nb) ? fb[8 + 8*idx + j] : 8'h00};
            wd = t;                            // 8 次左移已左对齐 (lj8 再加一次会清零)
            wk = km8(nb[3:0]);
        end
    endtask

    reg src_viol;                             // tready 违约计数
    integer tot_bytes, tot_frames;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_v <= 1'b0; idx <= 0; gap <= 0; fidx <= 0; ninj <= 0;
            sst <= SST_IDLE; inj_run <= 1'b0;
            in_d <= 64'd0; in_k <= 8'h00; in_l <= 1'b0; in_u <= 1'b0;
            in_c <= 1'b0; in_e <= 1'b0;
        end else begin
            in_v <= 1'b0;                     // 脉冲型 (每拍默认清零)
            if (in_v && !s_tready) src_viol <= src_viol + 1;
            case (sst)
                SST_IDLE: if (inj_run) begin
                    build_payload;
                    idx <= 0; gap <= 0;
                    sst <= SST_WORD;
                end
                SST_WORD: begin
                    if (idx < NW) begin
                        if (gap == 0) begin
                            present_word;         // 组合算出 wd/wk
                            in_d <= wd; in_k <= wk;
                            in_l <= (idx == NW-1);
                            in_u <= (idx == 0);
                            in_c <= (idx == NW-1);   // FCS 好
                            in_e <= 1'b0;
                            in_v <= 1'b1;
                            idx  <= idx + 1;
                            ninj <= ninj + 1;
                            gap  <= (WSP > 1) ? (WSP-1) : 0;
                        end else gap <= gap - 1;
                    end else begin
                        gap <= (IPG > 0) ? (IPG-1) : 0;
                        sst <= SST_GAP;
                    end
                end
                SST_GAP: begin
                    if (gap == 0) begin
                        fidx <= fidx + 1;
                        if (fidx + 1 >= NFRM) sst <= SST_DONE;
                        else                  sst <= SST_IDLE;
                    end else gap <= gap - 1;
                end
                default: sst <= SST_DONE;
            endcase
        end
    end

    //=========================================================================
    // DUT
    //=========================================================================
    integer dbg_n;
    always @(posedge clk) begin
        if (in_v && (dbg_n < 8)) begin
            $display("  [inj] t=%0t d=%016h k=%02h u=%b l=%b c=%b",
                     $time, in_d, in_k, in_u, in_l, in_c);
            dbg_n = dbg_n + 1;
        end
    end

    wire [63:0] p_tdata;  wire [7:0] p_tkeep;  wire p_tvalid, p_tlast, p_tuser, p_tcrs, p_terr;
    wire [63:0] a_tdata;  wire [7:0] a_tkeep;  wire a_tvalid, a_tlast, a_sof;
    wire [15:0] a_len, a_sport;  wire [31:0] a_sip;
    wire        a_tready;
    wire        m_valid;  wire [47:0] m_smac;  wire [31:0] m_sip;
    wire [15:0] m_sport, m_len;
    wire [31:0] st_frames, st_bytes, st_null, st_crc, st_ovf, st_part, st_excl;
    wire [31:0] st_hf, st_hd, st_hs;

    udp_split u_split (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep), .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_tready),
        .s_axis_tlast(s_tlast), .s_axis_tuser(s_tuser),
        .s_axis_tcrs(s_tcrs), .s_axis_terr(s_terr),
        .p_axis_tdata(p_tdata), .p_axis_tkeep(p_tkeep), .p_axis_tvalid(p_tvalid),
        .p_axis_tready(1'b1),
        .p_axis_tlast(p_tlast), .p_axis_tuser(p_tuser),
        .p_axis_tcrs(p_tcrs), .p_axis_terr(p_terr),
        .app_rx_tdata(a_tdata), .app_rx_tkeep(a_tkeep), .app_rx_tvalid(a_tvalid),
        .app_rx_tready(a_tready), .app_rx_tlast(a_tlast), .app_rx_sof(a_sof),
        .app_rx_len(a_len), .app_rx_src_ip(a_sip), .app_rx_src_port(a_sport),
        .meta_valid(m_valid), .meta_src_mac(m_smac), .meta_src_ip(m_sip),
        .meta_src_port(m_sport), .meta_len(m_len),
        .cfg_dst_ip(BOARD_IP), .cfg_multi_en(1'b0),
        .cfg_port0(APP_PORT), .cfg_port1(16'hFFFF),
        .cfg_port2(16'hFFFF), .cfg_port3(16'hFFFF),
        .cfg_port_any(1'b0),
        .stat_app_frames(st_frames), .stat_app_bytes(st_bytes), .stat_app_null(st_null),
        .stat_drop_crc(st_crc), .stat_drop_ovf(st_ovf), .stat_drop_part(st_part),
        .stat_drop_excl(st_excl),
        .stat_hls_frames(st_hf), .stat_hls_drop(st_hd), .stat_hls_split(st_hs)
    );

    // 透传口消费者 (slow_rx_adp 同构: 恒 ready, 只计数)
    integer hls_fr, hls_w;
    always @(posedge clk) begin
        if (p_tvalid) hls_w <= hls_w + 1;
        if (p_tvalid && p_tlast) hls_fr <= hls_fr + 1;
    end

    // app 校验器 (板级同构消费者; i_en=1, peer 门关 ⇒ TX 不参与)
    wire [31:0] ap_tx_b, ap_tx_f, ap_rx_b, ap_rx_f, ap_null, ap_mm;

    app_udp_pattern #(.TX_BYTES(32'd0), .TX_GAP(16'd0)) u_app (
        .clk(clk), .rst_n(rst_n),
        .i_en(1'b1), .i_tx_ready(1'b0), .i_paylen(12'd1472),
        .m_tdata(), .m_tkeep(), .m_tvalid(), .m_tready(1'b1), .m_tlast(),
        .rx_tdata(a_tdata), .rx_tkeep(a_tkeep), .rx_tvalid(a_tvalid),
        .rx_tready(a_tready), .rx_tlast(a_tlast), .rx_sof(a_sof),
        .rx_len(a_len),
        .stat_tx_bytes(ap_tx_b), .stat_tx_frames(ap_tx_f),
        .stat_rx_bytes(ap_rx_b), .stat_rx_frames(ap_rx_f),
        .stat_rx_null(ap_null), .stat_mismatch(ap_mm),
        .active(), .done(), .led()
    );

    //=========================================================================
    // 判据侧: 独立期望流 + 逐字节在线比对 (两道: app 口 / udp_rx 直出)
    //=========================================================================
    reg  [63:0] exp_a;          // app 口期望 LFSR
    reg  [63:0] exp_m;          // udp_rx 直出期望 LFSR
    integer     a_bytes, m_bytes, a_mm, m_mm;
    integer     a_widx, m_widx;               // 帧内字号
    integer     a_fr, m_fr;
    // 失配分类: [0]=首字 [1]=尾字 [2]=帧身 [3]=字内偏移非0/7 的中间字节
    integer     cls_first, cls_last, cls_mid;
    integer     cls_w0, cls_w7, cls_win;      // 字内字节位置
    // 前 40 个失配的明细 (不写 marray, 直接打印)
    integer     nshow;
    reg  [7:0]  got_b, exp_b;
    integer     gi, gidx, gj;
    reg         m_sync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            exp_a <= SEED; exp_m <= SEED;
            a_bytes <= 0; m_bytes <= 0; a_mm <= 0; m_mm <= 0;
            a_widx <= 0; m_widx <= 0; a_fr <= 0; m_fr <= 0; m_sync <= 1'b0;
            cls_first <= 0; cls_last <= 0; cls_mid <= 0;
            cls_w0 <= 0; cls_w7 <= 0; cls_win <= 0; nshow <= 0;
        end else begin
            // ---- ① app RX 口 (消费侧: u_app.rx_tready) ----
            if (a_tvalid && a_tready) begin
                if (a_sof) begin a_widx <= 1; a_fr <= a_fr + 1; end
                else       a_widx <= a_widx + 1;
                gidx = a_sof ? 0 : a_widx;
                for (gi = 0; gi < 8; gi = gi + 1) begin
                    if (gi < pop8(a_tkeep)) begin
                        got_b = byte_at(a_tdata, gi[3:0]);
                        exp_b = exp_a[31:24];
                        exp_a = xs_next(exp_a);
                        a_bytes = a_bytes + 1;
                        if (got_b !== exp_b) begin
                            a_mm = a_mm + 1;
                            if (a_tlast)      cls_last = cls_last + 1;
                            else if (gidx == 0) cls_first = cls_first + 1;
                            else              cls_mid = cls_mid + 1;
                            if (gi == 0)      cls_w0 = cls_w0 + 1;
                            else if (gi == 7) cls_w7 = cls_w7 + 1;
                            else              cls_win = cls_win + 1;
                            if (nshow < 40) begin
                                $display("  [AMM] app#%0d frm=%0d widx=%0d gi=%0d sof=%b last=%b got=%02h exp=%02h",
                                         a_mm, a_fr, gidx, gi, a_sof, a_tlast, got_b, exp_b);
                                nshow = nshow + 1;
                            end
                        end
                    end
                end
            end
            // ---- ② udp_rx 载荷直出 (m_axis_tready 恒 1) ----
            if (u_split.u_meta_valid) m_sync = 1'b1;   // 帧首同步待生效
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

    initial begin
        errs = 0; hls_fr = 0; hls_w = 0; src_viol = 0; dbg_n = 0;
        tot_bytes = 0; tot_frames = 0;
        clk = 0; rst_n = 0; inj_run = 0;
        gen_lfsr = SEED;
        build_header;
        $display("  [cfg] PLEN=%0d FLEN=%0d NW=%0d LASTN=%0d NFRM=%0d WSP=%0d IPG=%0d",
                 PLEN, FLEN, NW, LASTN, NFRM, WSP, IPG);
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);
        inj_run = 1'b1;
        // 等发完 (NW*WSP+IPG)*NFRM + 余量
        repeat ((NW*WSP + IPG + 8) * NFRM + 5000) @(posedge clk);
        inj_run = 1'b0;
        // 等 app 侧排空 (每字 8 拍)
        repeat (NPW * 8 * 4 + 2000) @(posedge clk);

        $display("  [dbg] sent: %0d frames x %0d B payload = %0d B (%0d words)",
                 fidx, PLEN, fidx*PLEN, ninj);
        $display("  [dbg] app: bytes=%0d frames=%0d null=%0d mismatch=%0d | tb_shadow: bytes=%0d mm=%0d",
                 ap_rx_b, ap_rx_f, ap_null, ap_mm, a_bytes, a_mm);
        $display("  [dbg] udprx tap: bytes=%0d mm=%0d frames=%0d", m_bytes, m_mm, m_fr);
        $display("  [dbg] split: frames=%0d bytes=%0d crc=%0d ovf=%0d part=%0d excl=%0d | hls fr=%0d w=%0d | tready_viol=%0d",
                 st_frames, st_bytes, st_crc, st_ovf, st_part, st_excl, hls_fr, hls_w, src_viol);
        $display("  [dbg] udp_rx: pass=%0d nonmatch=%0d ipcsum=%0d crc=%0d bytes=%0d | meta=%0d split=%0d excl=%0d dec=%0d",
                 u_split.u_udp_rx.stat_pass, u_split.u_udp_rx.stat_drop_nonmatch,
                 u_split.u_udp_rx.stat_drop_ipcsum, u_split.u_udp_rx.stat_drop_crc,
                 u_split.u_udp_rx.stat_bytes, m_fr, st_hs, st_excl, u_split.stat_drop_part);
        $display("  [dbg] mismatch classes: first_word=%0d last_word=%0d mid=%0d | byteinword: w0=%0d w7=%0d inner=%0d",
                 cls_first, cls_last, cls_mid, cls_w0, cls_w7, cls_win);

        chk(src_viol == 0, "① s_axis_tready 恒 1 (结构性不反压)");
        chk(fidx == NFRM,  "① 送完全部帧");
        chk(ap_rx_b == fidx*PLEN, "⑤ app 收字节 == 送出载荷字节 (URB 精确)");
        chk(st_frames == fidx, "⑤ udp_split 交付帧数 == 送出帧数");
        chk(a_mm == 0,     "③ app RX 口逐字节零失配 (TB 独立期望流)");
        chk(ap_mm == 0,    "③ DUT 校验器 stat_mismatch == 0");
        chk(m_mm == 0,     "④ udp_rx 载荷直出流逐字节零失配");
        chk(a_bytes == fidx*PLEN, "③ 比对字节数 == 送出");
        chk(hls_fr == 0,   "⑥ app-UDP 帧零泄漏到 HLS 慢路径");

        if (errs == 0) $display("UDPRX RATE GATE: OK (PLEN=%0d NFRM=%0d WSP=%0d)", PLEN, NFRM, WSP);
        else           $display("UDPRX RATE GATE: FAIL errs=%0d", errs);
        $finish;
    end

    // 全局超时
    initial begin
        repeat (200000000) @(posedge clk);
        $display("UDPRX RATE GATE: TIMEOUT");
        $finish;
    end
endmodule
